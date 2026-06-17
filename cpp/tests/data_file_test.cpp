// M3.1 unit tests: DataFile + HintFile.

#include <unistd.h>

#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/codec.hpp"
#include "bitcask/data_file.hpp"
#include "bitcask/format.hpp"
#include "bitcask/hint_file.hpp"
#include "bitcask/migrate.hpp"
#include "bitcask/search_checkpoint.hpp"

using bitcask::fileops::DataFile;
using bitcask::fileops::DataFileError;
using bitcask::fileops::HintFile;
using bitcask::fileops::ReadRecord;
using bitcask::format::RecordType;
using bitcask::format::kHeaderSize;

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

// 大端编码器（仅迁移测试用——构造 v1 legacy 字节固件）。
void be_put16(std::vector<std::byte>& b, std::uint16_t v) {
    b.push_back(static_cast<std::byte>((v >> 8) & 0xFF));
    b.push_back(static_cast<std::byte>(v & 0xFF));
}
void be_put32(std::vector<std::byte>& b, std::uint32_t v) {
    for (int i = 3; i >= 0; --i)
        b.push_back(static_cast<std::byte>((v >> (8 * i)) & 0xFF));
}
void be_put64(std::vector<std::byte>& b, std::uint64_t v) {
    for (int i = 7; i >= 0; --i)
        b.push_back(static_cast<std::byte>((v >> (8 * i)) & 0xFF));
}
// 一条 v1 大端 data record：[crc BE][type][tstamp BE][ord BE][keysz BE][valsz BE][key][val]。
std::vector<std::byte> be_data_record(bitcask::format::RecordType type,
                                      std::uint32_t ts, std::uint64_t ord,
                                      std::string_view key,
                                      std::string_view val) {
    std::vector<std::byte> covered;
    covered.push_back(static_cast<std::byte>(type));
    be_put32(covered, ts);
    be_put64(covered, ord);
    be_put16(covered, static_cast<std::uint16_t>(key.size()));
    be_put32(covered, static_cast<std::uint32_t>(val.size()));
    auto kb = as_bytes(key);
    covered.insert(covered.end(), kb.begin(), kb.end());
    auto vb = as_bytes(val);
    covered.insert(covered.end(), vb.begin(), vb.end());
    std::vector<std::byte> rec;
    be_put32(rec, bitcask::codec::crc32(covered));  // CRC 字段（大端）
    rec.insert(rec.end(), covered.begin(), covered.end());
    return rec;
}

void write_file_bytes(const std::string& path, std::span<const std::byte> b) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    ASSERT_NE(f, nullptr);
    if (!b.empty()) ASSERT_EQ(std::fwrite(b.data(), 1, b.size(), f), b.size());
    std::fclose(f);
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

    auto w1 = f->write(RecordType::kDoc, /*tstamp*/ 100, /*ord*/ 1,
                       as_bytes("k1"), as_bytes("v1"));
    ASSERT_TRUE(w1);
    EXPECT_EQ(w1->offset, 0u);

    auto w2 = f->write(RecordType::kDoc, /*tstamp*/ 101, /*ord*/ 2,
                       as_bytes("k2"), as_bytes("vvv"));
    ASSERT_TRUE(w2);
    EXPECT_EQ(w2->offset, w1->total_size);

    auto r1 = f->read(w1->offset, w1->total_size);
    ASSERT_TRUE(r1);
    EXPECT_EQ(r1->type, RecordType::kDoc);
    EXPECT_EQ(r1->tstamp, 100u);
    EXPECT_EQ(r1->ord, 1u);
    EXPECT_EQ(view_str(r1->key),   "k1");
    EXPECT_EQ(view_str(r1->value), "v1");

    auto r2 = f->read(w2->offset, w2->total_size);
    ASSERT_TRUE(r2);
    EXPECT_EQ(r2->tstamp, 101u);
    EXPECT_EQ(r2->ord, 2u);
    EXPECT_EQ(view_str(r2->key),   "k2");
    EXPECT_EQ(view_str(r2->value), "vvv");
}

TEST(DataFile, FoldVisitsAllRecords) {
    TempDir td;
    const auto path = td / "2.bitcask.data";

    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    ASSERT_TRUE(f);
    ASSERT_TRUE(f->write(RecordType::kDoc, 1, 1, as_bytes("a"),   as_bytes("AA")));
    ASSERT_TRUE(f->write(RecordType::kDoc, 2, 2, as_bytes("b"),   as_bytes("BBBB")));
    ASSERT_TRUE(f->write(RecordType::kDoc, 3, 3, as_bytes("ccc"), as_bytes(std::string(257, 'x'))));

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
        ASSERT_TRUE(f->write(RecordType::kDoc, 1, 1, as_bytes("k"), as_bytes("v")));
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
        auto w = f->write(RecordType::kDoc, 1, 1, as_bytes("k"), as_bytes("vvvv"));
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
    auto rec = r->read(0, kHeaderSize + 1 + 4);
    ASSERT_FALSE(rec);
    EXPECT_EQ(rec.error().kind, DataFileError::kBadCrc);
}

TEST(DataFile, ReuseOffsetMatchesIndex) {
    TempDir td;
    const auto path = td / "5.bitcask.data";
    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    ASSERT_TRUE(f);
    auto w = f->write(RecordType::kDoc, 7, 1, as_bytes("hello"), as_bytes("world"));
    ASSERT_TRUE(w);
    EXPECT_EQ(w->offset, 0u);
    EXPECT_EQ(w->total_size, kHeaderSize + 5u + 5u);
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
// Hint 字节 golden（自洽,非跨语言）。
//   P:flag-day 后全盘统一小端——**不再与 legacy Erlang 大端字节互通**,故原
//   "cross-language golden" 失效。下方 hex 是当前 LE 编码对三条 record + trailer
//   的钉死字节(字段全小端;packed u64 的 tomb 标记落在最后一字节;trailer 的
//   totalsz=running CRC 随 LE 字节重算)。任何编码漂移在此失败。
//
//     R1: key="a"    tstamp=100 totalsz=19 offset=0    tomb=false
//     R2: key="bb"   tstamp=101 totalsz=20 offset=19   tomb=true
//     R3: key="cccc" tstamp=102 totalsz=22 offset=39   tomb=false
//     trailer:       tstamp=0   keysz=0   totalsz=CRC  offset=0x7FFFFFFFFFFFFFFF
//
// 重新生成:跑 EncodingMatchesGoldenByteForByte,取 stderr 的 CAPTURE_LE_HINT_HEX。
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

// 158 chars = 79 bytes total（小端 golden,见上方注释生成方式）。
constexpr std::string_view kGoldenHintHex =
    "64000000010013000000000000000000000061"            // R1: 19 B
    "6500000002001400000013000000000000806262"          // R2: 20 B
    "66000000040016000000270000000000000063636363"      // R3: 22 B
    "0000000000002d272b6cffffffffffffff7f";              // trailer: 18 B

}  // namespace

TEST(HintFileGolden, ReadsGoldenEncodedFile) {
    TempDir td;
    auto bytes = hex_to_bytes(kGoldenHintHex);
    ASSERT_EQ(bytes.size(), 79u);
    const auto path = write_temp_with_bytes(td, "golden.bitcask.hint", bytes);

    auto h = HintFile::open(path, HintFile::Mode::kRead);
    ASSERT_TRUE(h);

    auto valid = h->validate_trailer();
    ASSERT_TRUE(valid);
    EXPECT_TRUE(*valid) << "trailer CRC must validate against golden LE bytes";

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

// Inverse direction: bytes our HintFile produces must match the pinned LE
// golden for the same logical inputs (drift guard).
TEST(HintFileGolden, EncodingMatchesGoldenByteForByte) {
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

    auto expected = hex_to_bytes(kGoldenHintHex);
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

    struct Rec { std::string k, v; std::uint32_t ts; std::uint64_t ord; };
    std::vector<Rec> input = {
        {"alpha",   "1",   100, 1},
        {"bravo",   "22",  101, 2},
        {"charlie", "333", 102, 3},
    };

    for (const auto& r : input) {
        auto w = df->write(RecordType::kDoc, r.ts, r.ord, as_bytes(r.k), as_bytes(r.v));
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

// ---------------------------------------------------------------------------
// migrate_le：v1 大端目录 → v2 小端目录端到端。手工构造 v1 大端 meta /
// field.schema / data（含墓碑 + 4 字节 shadow），迁移后用小端读路径校验。
// ---------------------------------------------------------------------------
TEST(MigrateBEtoLE, RoundTrip) {
    using bitcask::format::RecordType;
    TempDir td;
    const std::string src = td / "src";
    const std::string dst = td / "dst";
    fs::create_directories(src);

    // v1 大端 meta：index 模式(1)、metric=cosine(1)、dim=4(大端 00 04)。
    {
        std::vector<std::byte> m(18, std::byte{0});
        std::memcpy(m.data(), "BCME", 4);
        m[4] = static_cast<std::byte>(1);  // version 1 (legacy 大端)
        m[5] = static_cast<std::byte>(1);  // mode = index
        m[6] = static_cast<std::byte>(1);  // metric = cosine
        m[7] = static_cast<std::byte>(0);  // dim hi (大端)
        m[8] = static_cast<std::byte>(4);  // dim lo → dim=4
        write_file_bytes((fs::path(src) / "bitcask.meta").string(), m);
    }
    // v1 大端 field.schema：title(id0)、body(id1)，NameLen u16 大端。
    {
        std::vector<std::byte> f;
        be_put16(f, 5);
        auto t = as_bytes("title"); f.insert(f.end(), t.begin(), t.end());
        be_put16(f, 4);
        auto b = as_bytes("body");  f.insert(f.end(), b.begin(), b.end());
        write_file_bytes((fs::path(src) / "field.schema").string(), f);
    }
    // data 文件：doc k1->v1、doc k2->v2、墓碑 k1（4 字节大端 shadow file_id=1）。
    {
        std::vector<std::byte> data;
        auto r1 = be_data_record(RecordType::kDoc, 100, 1, "k1", "v1");
        auto r2 = be_data_record(RecordType::kDoc, 101, 2, "k2", "v2");
        const char shadow_be[4] = {0, 0, 0, 1};  // 大端 u32 = 1
        auto r3 = be_data_record(RecordType::kTombstone, 102, 3, "k1",
                                 std::string_view(shadow_be, 4));
        for (auto* r : {&r1, &r2, &r3}) data.insert(data.end(), r->begin(), r->end());
        write_file_bytes((fs::path(src) / "1.bitcask.data").string(), data);
    }

    auto res = bitcask::migrate::migrate_be_to_le(src, dst);
    ASSERT_TRUE(res) << (res ? "" : res.error());
    EXPECT_EQ(res->data_files, 1u);
    EXPECT_EQ(res->records, 3u);
    EXPECT_EQ(res->tombstones, 1u);
    EXPECT_EQ(res->skipped_bad_crc, 0u);
    EXPECT_TRUE(res->meta_migrated);
    EXPECT_TRUE(res->field_schema_migrated);

    // dst meta：version 2、dim 小端 = 4。
    {
        std::FILE* f = std::fopen((fs::path(dst) / "bitcask.meta").c_str(), "rb");
        ASSERT_NE(f, nullptr);
        unsigned char m[18];
        ASSERT_EQ(std::fread(m, 1, 18, f), 18u);
        std::fclose(f);
        EXPECT_EQ(m[4], 2u);
        EXPECT_EQ(static_cast<std::uint16_t>(m[7] | (m[8] << 8)), 4u);
    }

    // dst data：用小端读路径 fold，逐 record 校验（CRC 重算后必须通过）。
    {
        auto df = DataFile::open((fs::path(dst) / "1.bitcask.data").string(),
                                 DataFile::Mode::kRead, false, false);
        ASSERT_TRUE(df);
        struct Rec { RecordType type; std::uint32_t ts; std::uint64_t ord;
                     std::string key; std::string val; };
        std::vector<Rec> recs;
        auto fr = df->fold([&](const bitcask::codec::DataRecordView& v,
                               std::uint64_t, std::uint32_t) {
            recs.push_back({v.type, v.tstamp, v.ord, view_str(v.key),
                            view_str(v.value)});
        });
        ASSERT_TRUE(fr);
        ASSERT_EQ(recs.size(), 3u);
        EXPECT_EQ(recs[0].ts, 100u); EXPECT_EQ(recs[0].ord, 1u);
        EXPECT_EQ(recs[0].key, "k1"); EXPECT_EQ(recs[0].val, "v1");
        EXPECT_EQ(recs[1].key, "k2"); EXPECT_EQ(recs[1].val, "v2");
        EXPECT_EQ(recs[2].type, RecordType::kTombstone);
        EXPECT_EQ(recs[2].key, "k1");
        // 4 字节 shadow 大端→小端：file_id=1 → 01 00 00 00。
        ASSERT_EQ(recs[2].val.size(), 4u);
        EXPECT_EQ(static_cast<unsigned char>(recs[2].val[0]), 1u);
        EXPECT_EQ(static_cast<unsigned char>(recs[2].val[3]), 0u);
    }

    // dst hint：重生成，fold 出 3 条，墓碑标志正确。
    {
        auto h = HintFile::open((fs::path(dst) / "1.bitcask.hint").string(),
                                HintFile::Mode::kRead);
        ASSERT_TRUE(h);
        auto v = h->validate_trailer();
        ASSERT_TRUE(v); EXPECT_TRUE(*v);
        std::vector<std::string> keys; std::vector<bool> tombs;
        auto fr = h->fold([&](const auto& rec) {
            keys.push_back(view_str(rec.key));
            tombs.push_back(rec.tombstone);
        });
        ASSERT_TRUE(fr);
        EXPECT_EQ(keys, (std::vector<std::string>{"k1", "k2", "k1"}));
        EXPECT_EQ(tombs, (std::vector<bool>{false, false, true}));
    }
}

// 已是小端(v2)的目录再迁移 → 干净报错(不重复迁移)。
TEST(MigrateBEtoLE, RejectsAlreadyV2) {
    TempDir td;
    const std::string src = td / "src2";
    fs::create_directories(src);
    std::vector<std::byte> m(18, std::byte{0});
    std::memcpy(m.data(), "BCME", 4);
    m[4] = static_cast<std::byte>(2);  // 已是 v2
    write_file_bytes((fs::path(src) / "bitcask.meta").string(), m);
    auto res = bitcask::migrate::migrate_be_to_le(src, td / "dst2");
    EXPECT_FALSE(res);
}

// ---------------------------------------------------------------------------
// P14e：search.ckpt 分段容器（SearchCheckpoint）。
// ---------------------------------------------------------------------------
namespace {
using bitcask::search::SearchCheckpoint;
using bitcask::search::CkptSection;

std::span<const std::byte> sp(const std::string& s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}
// 翻转文件第 off 字节的一个 bit。
void flip_byte(const std::string& path, long off) {
    std::FILE* f = std::fopen(path.c_str(), "rb+");
    ASSERT_NE(f, nullptr);
    std::fseek(f, off, SEEK_SET);
    unsigned char c = 0;
    ASSERT_EQ(std::fread(&c, 1, 1, f), 1u);
    c ^= 0x01;
    std::fseek(f, off, SEEK_SET);
    ASSERT_EQ(std::fwrite(&c, 1, 1, f), 1u);
    std::fclose(f);
}
long file_size(const std::string& path) {
    return static_cast<long>(fs::file_size(path));
}
}  // namespace

TEST(SearchCheckpoint, RoundTrip) {
    TempDir td;
    const std::string path = td / "search.ckpt";
    const std::string s1 = "docmap-bytes", s2 = "bm25-bytes!", s3 = "hnsw";
    std::vector<CkptSection> secs = {
        {1, 0, sp(s1)}, {2, 0, sp(s2)}, {4, 7, sp(s3)}};
    ASSERT_TRUE(SearchCheckpoint::write(path, /*watermark*/ 4242, secs));

    auto lc = SearchCheckpoint::read(path);
    ASSERT_TRUE(lc.has_value());
    EXPECT_EQ(lc->watermark, 4242u);
    ASSERT_EQ(lc->sections.size(), 3u);
    EXPECT_EQ(lc->sections[0].type, 1u);
    EXPECT_EQ(lc->sections[1].type, 2u);
    EXPECT_EQ(lc->sections[2].type, 4u);
    EXPECT_EQ(lc->sections[2].flags, 7u);
    EXPECT_EQ(view_str(lc->sections[0].payload), s1);
    EXPECT_EQ(view_str(lc->sections[1].payload), s2);
    EXPECT_EQ(view_str(lc->sections[2].payload), s3);
    for (auto& ls : lc->sections) EXPECT_TRUE(ls.crc_ok);
}

// 单段 payload 损坏 → 仅该段 crc_ok=false，其余段正常、结构完整（损坏隔离）。
TEST(SearchCheckpoint, SectionCorruptionIsolated) {
    TempDir td;
    const std::string path = td / "search.ckpt";
    const std::string s1 = "AAAA", s2 = "BBBBBB";  // 段0[16,20) 段1[20,26)
    std::vector<CkptSection> secs = {{2, 0, sp(s1)}, {4, 0, sp(s2)}};
    ASSERT_TRUE(SearchCheckpoint::write(path, 9, secs));

    flip_byte(path, 16);  // 段0 第一字节(payload 区)。
    auto lc = SearchCheckpoint::read(path);
    ASSERT_TRUE(lc.has_value());  // 结构仍完整。
    ASSERT_EQ(lc->sections.size(), 2u);
    EXPECT_FALSE(lc->sections[0].crc_ok);  // 坏段。
    EXPECT_TRUE(lc->sections[1].crc_ok);   // 好段照常。
}

// 页脚损坏（trailer / footerCrc）→ 结构性拒绝（read 返回 nullopt）。
TEST(SearchCheckpoint, FooterCorruptRejected) {
    TempDir td;
    const std::string path = td / "search.ckpt";
    const std::string s1 = "x";
    std::vector<CkptSection> secs = {{1, 0, sp(s1)}};
    ASSERT_TRUE(SearchCheckpoint::write(path, 1, secs));
    const long sz = file_size(path);
    flip_byte(path, sz - 1);  // trailer 最后一字节。
    EXPECT_FALSE(SearchCheckpoint::read(path).has_value());

    // footerCrc 区损坏(dir 内容与 crc 不符)。
    ASSERT_TRUE(SearchCheckpoint::write(path, 1, secs));
    flip_byte(path, file_size(path) - 12);  // footerCrc 首字节。
    EXPECT_FALSE(SearchCheckpoint::read(path).has_value());
}

// 截断 → 拒绝。
TEST(SearchCheckpoint, TruncatedRejected) {
    TempDir td;
    const std::string path = td / "search.ckpt";
    std::vector<CkptSection> secs = {{1, 0, sp(std::string("payload"))}};
    ASSERT_TRUE(SearchCheckpoint::write(path, 1, secs));
    const long sz = file_size(path);
    std::filesystem::resize_file(path, static_cast<std::uintmax_t>(sz / 2));
    EXPECT_FALSE(SearchCheckpoint::read(path).has_value());
}

// 空段集 round-trip（仅头部+空目录+页脚）。
TEST(SearchCheckpoint, EmptySections) {
    TempDir td;
    const std::string path = td / "search.ckpt";
    ASSERT_TRUE(SearchCheckpoint::write(path, 77, {}));
    auto lc = SearchCheckpoint::read(path);
    ASSERT_TRUE(lc.has_value());
    EXPECT_EQ(lc->watermark, 77u);
    EXPECT_TRUE(lc->sections.empty());
}
