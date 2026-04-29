// M3.1 unit tests: DataFile + HintFile.

#include <unistd.h>

#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/data_file.hpp"
#include "bitcask/hint_file.hpp"

using bitcask::fileops::DataFile;
using bitcask::fileops::DataFileError;
using bitcask::fileops::HintFile;
using bitcask::fileops::ReadRecord;

namespace fs = std::filesystem;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_dfile_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string operator/(const std::string& s) const {
        return (path_ / s).string();
    }
private:
    fs::path path_;
};

std::span<const std::byte> as_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

std::string view_str(std::span<const std::byte> b) {
    return std::string(reinterpret_cast<const char*>(b.data()), b.size());
}

}  // namespace

// ---------------------------------------------------------------------------
// Filename helpers
// ---------------------------------------------------------------------------
TEST(Filename, MkAndParse) {
    using bitcask::fileops::mk_data_filename;
    using bitcask::fileops::mk_hint_filename;
    using bitcask::fileops::parse_data_tstamp;

    EXPECT_EQ(mk_data_filename("/tmp/foo", 12345), "/tmp/foo/12345.bitcask.data");
    EXPECT_EQ(mk_hint_filename("/tmp/foo/12345.bitcask.data"),
              "/tmp/foo/12345.bitcask.hint");

    EXPECT_EQ(parse_data_tstamp("/tmp/x/12345.bitcask.data"), 12345u);
    EXPECT_EQ(parse_data_tstamp("12345.bitcask.data"), 12345u);
    EXPECT_FALSE(parse_data_tstamp("not-a-bitcask").has_value());
    EXPECT_FALSE(parse_data_tstamp("abc.bitcask.data").has_value());
}

// ---------------------------------------------------------------------------
// DataFile
// ---------------------------------------------------------------------------
TEST(DataFile, CreateAppendReadRoundTrip) {
    TempDir td;
    const auto path = td / "1.bitcask.data";

    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    ASSERT_TRUE(f);

    auto w1 = f->write(/*tstamp*/ 100, as_bytes("k1"), as_bytes("v1"));
    ASSERT_TRUE(w1);
    EXPECT_EQ(w1->offset, 0u);

    auto w2 = f->write(/*tstamp*/ 101, as_bytes("k2"), as_bytes("vvv"));
    ASSERT_TRUE(w2);
    EXPECT_EQ(w2->offset, w1->total_size);

    auto r1 = f->read(w1->offset, w1->total_size);
    ASSERT_TRUE(r1);
    EXPECT_EQ(r1->tstamp, 100u);
    EXPECT_EQ(view_str(r1->key),   "k1");
    EXPECT_EQ(view_str(r1->value), "v1");

    auto r2 = f->read(w2->offset, w2->total_size);
    ASSERT_TRUE(r2);
    EXPECT_EQ(r2->tstamp, 101u);
    EXPECT_EQ(view_str(r2->key),   "k2");
    EXPECT_EQ(view_str(r2->value), "vvv");
}

TEST(DataFile, FoldVisitsAllRecords) {
    TempDir td;
    const auto path = td / "2.bitcask.data";

    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    ASSERT_TRUE(f);
    ASSERT_TRUE(f->write(1, as_bytes("a"),   as_bytes("AA")));
    ASSERT_TRUE(f->write(2, as_bytes("b"),   as_bytes("BBBB")));
    ASSERT_TRUE(f->write(3, as_bytes("ccc"), as_bytes(std::string(257, 'x'))));

    std::vector<std::pair<std::string, std::string>> seen;
    auto fold_res = f->fold(
        [&](const auto& v, std::uint64_t /*off*/, std::uint32_t /*total*/) {
            seen.emplace_back(view_str(v.key), view_str(v.value));
        });
    ASSERT_TRUE(fold_res);
    ASSERT_EQ(seen.size(), 3u);
    EXPECT_EQ(seen[0].first,  "a");
    EXPECT_EQ(seen[1].first,  "b");
    EXPECT_EQ(seen[2].first,  "ccc");
    EXPECT_EQ(seen[2].second.size(), 257u);
}

TEST(DataFile, OpenForReadAndFold) {
    TempDir td;
    const auto path = td / "3.bitcask.data";

    {
        auto f = DataFile::open(path, DataFile::Mode::kCreate);
        ASSERT_TRUE(f);
        ASSERT_TRUE(f->write(1, as_bytes("k"), as_bytes("v")));
    }
    auto r = DataFile::open(path, DataFile::Mode::kRead);
    ASSERT_TRUE(r);
    int n = 0;
    auto fr = r->fold([&](const auto&, std::uint64_t, std::uint32_t) { ++n; });
    ASSERT_TRUE(fr);
    EXPECT_EQ(n, 1);
}

TEST(DataFile, BadCrcReturnsKBadCrc) {
    TempDir td;
    const auto path = td / "4.bitcask.data";
    {
        auto f = DataFile::open(path, DataFile::Mode::kCreate);
        ASSERT_TRUE(f);
        auto w = f->write(1, as_bytes("k"), as_bytes("vvvv"));
        ASSERT_TRUE(w);
    }
    // Corrupt the value.
    {
        std::FILE* fp = std::fopen(path.c_str(), "rb+");
        ASSERT_NE(fp, nullptr);
        std::fseek(fp, -1, SEEK_END);
        char c;
        std::fread(&c, 1, 1, fp);
        c ^= 0x01;
        std::fseek(fp, -1, SEEK_END);
        std::fwrite(&c, 1, 1, fp);
        std::fclose(fp);
    }
    auto r = DataFile::open(path, DataFile::Mode::kRead);
    ASSERT_TRUE(r);
    auto rec = r->read(0, 14 + 1 + 4);
    ASSERT_FALSE(rec);
    EXPECT_EQ(rec.error().kind, DataFileError::kBadCrc);
}

TEST(DataFile, ReuseOffsetMatchesIndex) {
    TempDir td;
    const auto path = td / "5.bitcask.data";
    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    ASSERT_TRUE(f);
    auto w = f->write(7, as_bytes("hello"), as_bytes("world"));
    ASSERT_TRUE(w);
    EXPECT_EQ(w->offset, 0u);
    EXPECT_EQ(w->total_size, 14u + 5u + 5u);
    EXPECT_EQ(f->size(), w->total_size);

    auto rec = f->read(w->offset, w->total_size);
    ASSERT_TRUE(rec);
    EXPECT_EQ(view_str(rec->key),   "hello");
    EXPECT_EQ(view_str(rec->value), "world");
}

// ---------------------------------------------------------------------------
// HintFile
// ---------------------------------------------------------------------------
TEST(HintFile, AppendFinalizeFold) {
    TempDir td;
    const auto path = td / "1.bitcask.hint";

    auto h = HintFile::open(path, HintFile::Mode::kCreate);
    ASSERT_TRUE(h);
    ASSERT_TRUE(h->write(1, /*total_sz*/ 30, /*off*/ 0,   /*tomb*/ false, as_bytes("a")));
    ASSERT_TRUE(h->write(2, /*total_sz*/ 40, /*off*/ 30,  /*tomb*/ true,  as_bytes("bb")));
    ASSERT_TRUE(h->write(3, /*total_sz*/ 50, /*off*/ 70,  /*tomb*/ false, as_bytes("ccc")));
    ASSERT_TRUE(h->finalize());

    auto r = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(r);
    std::vector<std::string> keys;
    std::vector<bool> tombs;
    auto fr = r->fold([&](const auto& rec) {
        keys.push_back(view_str(rec.key));
        tombs.push_back(rec.tombstone);
    });
    ASSERT_TRUE(fr);
    EXPECT_EQ(keys, (std::vector<std::string>{"a", "bb", "ccc"}));
    EXPECT_EQ(tombs, (std::vector<bool>{false, true, false}));
}

TEST(HintFile, ValidateTrailerHappyPath) {
    TempDir td;
    const auto path = td / "good.bitcask.hint";
    auto h = HintFile::open(path, HintFile::Mode::kCreate);
    ASSERT_TRUE(h);
    ASSERT_TRUE(h->write(1, 30, 0, false, as_bytes("a")));
    ASSERT_TRUE(h->write(2, 40, 30, false, as_bytes("bb")));
    ASSERT_TRUE(h->finalize());

    auto r = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(r);
    auto v = r->validate_trailer();
    ASSERT_TRUE(v);
    EXPECT_TRUE(*v);
}

TEST(HintFile, ValidateTrailerCorrupted) {
    TempDir td;
    const auto path = td / "bad.bitcask.hint";
    {
        auto h = HintFile::open(path, HintFile::Mode::kCreate);
        ASSERT_TRUE(h);
        ASSERT_TRUE(h->write(1, 30, 0, false, as_bytes("a")));
        ASSERT_TRUE(h->write(2, 40, 30, false, as_bytes("bb")));
        ASSERT_TRUE(h->finalize());
    }
    // Flip a byte in the body.
    {
        std::FILE* fp = std::fopen(path.c_str(), "rb+");
        ASSERT_NE(fp, nullptr);
        std::fseek(fp, 5, SEEK_SET);
        char c;
        std::fread(&c, 1, 1, fp);
        c ^= 0x01;
        std::fseek(fp, 5, SEEK_SET);
        std::fwrite(&c, 1, 1, fp);
        std::fclose(fp);
    }
    auto r = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(r);
    auto v = r->validate_trailer();
    ASSERT_TRUE(v);
    EXPECT_FALSE(*v);
}

TEST(HintFile, ValidateMissingTrailer) {
    TempDir td;
    const auto path = td / "trunc.bitcask.hint";
    auto h = HintFile::open(path, HintFile::Mode::kCreate);
    ASSERT_TRUE(h);
    ASSERT_TRUE(h->write(1, 30, 0, false, as_bytes("a")));
    // No finalize() — trailer missing.

    auto r = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(r);
    auto v = r->validate_trailer();
    ASSERT_TRUE(v);
    EXPECT_FALSE(*v);
}

TEST(HintFile, EmptyFileFoldReturnsNoRecords) {
    TempDir td;
    const auto path = td / "empty.bitcask.hint";
    {
        auto h = HintFile::open(path, HintFile::Mode::kCreate);
        ASSERT_TRUE(h);
        ASSERT_TRUE(h->finalize());
    }
    auto r = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(r);
    int n = 0;
    auto fr = r->fold([&](const auto&) { ++n; });
    ASSERT_TRUE(fr);
    EXPECT_EQ(n, 0);
}

// ---------------------------------------------------------------------------
// Cross-language golden:
//   The hex below was emitted by Erlang (legacy bit-syntax encoding —
//   identical to bitcask_fileops:hintfile_entry / close_hintfile) for three
//   records and the trailer:
//
//     R1: key="a"    tstamp=100 totalsz=19 offset=0    tomb=false
//     R2: key="bb"   tstamp=101 totalsz=20 offset=19   tomb=true
//     R3: key="cccc" tstamp=102 totalsz=22 offset=39   tomb=false
//     trailer:       tstamp=0   keysz=0   totalsz=CRC=0xED5B567A
//                    tomb=0     offset=0x7FFFFFFFFFFFFFFF
//
// To regenerate:  escript scripts/gen_golden_hint.escript
// ---------------------------------------------------------------------------
namespace {

std::vector<std::byte> hex_to_bytes(std::string_view h) {
    auto nyb = [](char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return 10 + c - 'a';
        return 0;
    };
    std::vector<std::byte> out;
    out.reserve(h.size() / 2);
    for (std::size_t i = 0; i + 1 < h.size(); i += 2) {
        out.push_back(static_cast<std::byte>((nyb(h[i]) << 4) | nyb(h[i + 1])));
    }
    return out;
}

std::string write_temp_with_bytes(const TempDir& td, std::string_view name,
                                   std::span<const std::byte> bytes) {
    const auto path = td / std::string(name);
    std::FILE* fp = std::fopen(path.c_str(), "wb");
    EXPECT_NE(fp, nullptr);
    std::fwrite(bytes.data(), 1, bytes.size(), fp);
    std::fclose(fp);
    return path;
}

// Single literal to avoid splitting bugs. 158 chars = 79 bytes total.
constexpr std::string_view kLegacyHintHex =
    "00000064000100000013000000000000000061"            // R1: 19 B
    "00000065000200000014800000000000001362"  "62"      // R2: 20 B
    "00000066000400000016000000000000002763636363"      // R3: 22 B
    "00000000" "0000" "ed5b567a" "7fffffffffffffff";    // trailer: 18 B

}  // namespace

TEST(HintFileGolden, ReadsLegacyEncodedFile) {
    TempDir td;
    auto bytes = hex_to_bytes(kLegacyHintHex);
    ASSERT_EQ(bytes.size(), 79u);
    const auto path = write_temp_with_bytes(td, "legacy.bitcask.hint", bytes);

    auto h = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(h);

    auto valid = h->validate_trailer();
    ASSERT_TRUE(valid);
    EXPECT_TRUE(*valid) << "trailer CRC must validate against legacy bytes";

    struct R { std::string key; std::uint32_t ts; std::uint32_t sz;
               std::uint64_t off; bool tomb; };
    std::vector<R> seen;
    auto fr = h->fold([&](const auto& rec) {
        seen.push_back({view_str(rec.key), rec.tstamp, rec.total_sz,
                        rec.offset, rec.tombstone});
    });
    ASSERT_TRUE(fr);

    ASSERT_EQ(seen.size(), 3u);
    EXPECT_EQ(seen[0].key, "a");    EXPECT_EQ(seen[0].ts, 100u);
    EXPECT_EQ(seen[0].sz,  19u);    EXPECT_EQ(seen[0].off, 0u);
    EXPECT_FALSE(seen[0].tomb);

    EXPECT_EQ(seen[1].key, "bb");   EXPECT_EQ(seen[1].ts, 101u);
    EXPECT_EQ(seen[1].sz,  20u);    EXPECT_EQ(seen[1].off, 19u);
    EXPECT_TRUE (seen[1].tomb);

    EXPECT_EQ(seen[2].key, "cccc"); EXPECT_EQ(seen[2].ts, 102u);
    EXPECT_EQ(seen[2].sz,  22u);    EXPECT_EQ(seen[2].off, 39u);
    EXPECT_FALSE(seen[2].tomb);
}

// Inverse direction: bytes our HintFile produces must match what legacy
// would have produced for the same logical inputs.
TEST(HintFileGolden, EncodingMatchesLegacyByteForByte) {
    TempDir td;
    const auto path = td / "ours.bitcask.hint";
    auto h = HintFile::open(path, HintFile::Mode::kCreate);
    ASSERT_TRUE(h);
    ASSERT_TRUE(h->write(100, 19, 0,   false, as_bytes("a")));
    ASSERT_TRUE(h->write(101, 20, 19,  true,  as_bytes("bb")));
    ASSERT_TRUE(h->write(102, 22, 39,  false, as_bytes("cccc")));
    ASSERT_TRUE(h->finalize());

    // Slurp back the bytes and compare.
    std::FILE* fp = std::fopen(path.c_str(), "rb");
    ASSERT_NE(fp, nullptr);
    std::fseek(fp, 0, SEEK_END);
    const auto sz = static_cast<std::size_t>(std::ftell(fp));
    std::fseek(fp, 0, SEEK_SET);
    std::vector<std::byte> got(sz);
    ASSERT_EQ(std::fread(got.data(), 1, sz, fp), sz);
    std::fclose(fp);

    auto expected = hex_to_bytes(kLegacyHintHex);
    ASSERT_EQ(got.size(), expected.size());
    for (std::size_t i = 0; i < got.size(); ++i) {
        EXPECT_EQ(got[i], expected[i])
            << "mismatch at byte " << i << " (0x" << std::hex << i << ")";
    }
}

// ---------------------------------------------------------------------------
// DataFile <-> HintFile pair (typical bitcask scenario)
// ---------------------------------------------------------------------------
TEST(DataAndHint, ParallelStreamsAreConsistent) {
    TempDir td;
    const auto data_path = td / "10.bitcask.data";
    const auto hint_path = td / "10.bitcask.hint";

    auto df = DataFile::open(data_path, DataFile::Mode::kCreate);
    ASSERT_TRUE(df);
    auto hf = HintFile::open(hint_path, HintFile::Mode::kCreate);
    ASSERT_TRUE(hf);

    struct Rec { std::string k, v; std::uint32_t ts; };
    std::vector<Rec> input = {
        {"alpha",   "1",   100},
        {"bravo",   "22",  101},
        {"charlie", "333", 102},
    };

    for (const auto& r : input) {
        auto w = df->write(r.ts, as_bytes(r.k), as_bytes(r.v));
        ASSERT_TRUE(w);
        ASSERT_TRUE(hf->write(r.ts, w->total_size, w->offset,
                              /*tomb*/ false, as_bytes(r.k)));
    }
    ASSERT_TRUE(hf->finalize());

    // Re-open hint and use it to fetch from data.
    auto h_read = HintFile::open(hint_path, HintFile::Mode::kRead);
    ASSERT_TRUE(h_read);
    EXPECT_TRUE(*h_read->validate_trailer());

    auto d_read = DataFile::open(data_path, DataFile::Mode::kRead);
    ASSERT_TRUE(d_read);

    std::set<std::string> keys_seen;
    auto fr = h_read->fold([&](const auto& hint) {
        auto rec = d_read->read(hint.offset, hint.total_sz);
        ASSERT_TRUE(rec);
        EXPECT_EQ(view_str(rec->key), view_str(hint.key));
        keys_seen.insert(view_str(rec->key));
    });
    ASSERT_TRUE(fr);
    EXPECT_EQ(keys_seen.size(), input.size());
}
