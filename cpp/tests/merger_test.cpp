// M3.3 unit tests: Merger (orchestrates DataFile + HintFile + KeyDir).

#include <unistd.h>

#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/data_file.hpp"
#include "bitcask/hint_file.hpp"
#include "bitcask/keydir.hpp"
#include "bitcask/merger.hpp"

namespace fs = std::filesystem;

using bitcask::fileops::DataFile;
using bitcask::fileops::HintFile;
using bitcask::fileops::mk_data_filename;
using bitcask::fileops::mk_hint_filename;
using bitcask::keydir::KeyDir;
using bitcask::merge::MergeStats;
using bitcask::merge::run_merge;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_merge_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string path() const { return path_.string(); }
private:
    fs::path path_;
};

std::span<const std::byte> as_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}
std::string view_str(std::span<const std::byte> b) {
    return std::string(reinterpret_cast<const char*>(b.data()), b.size());
}

// Build a data file with the given (key,value,tstamp) triples; return the
// list of (offset, total_size) for each record so callers can populate the
// keydir.
struct WrittenRec { std::uint64_t offset; std::uint32_t total_size; };
std::vector<WrittenRec>
write_data_file(const std::string& dirname, std::uint32_t file_id,
                const std::vector<std::tuple<std::string,std::string,std::uint32_t>>& recs) {
    auto path = mk_data_filename(dirname, file_id);
    auto f = DataFile::open(path, DataFile::Mode::kCreate);
    EXPECT_TRUE(f);
    std::vector<WrittenRec> out;
    for (const auto& [k, v, ts] : recs) {
        auto w = f->write(ts, as_bytes(k), as_bytes(v));
        EXPECT_TRUE(w);
        out.push_back({w->offset, w->total_size});
    }
    return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// Simple happy path
// ---------------------------------------------------------------------------
TEST(Merger, MergesLiveRecordsFromOneFile) {
    TempDir td;
    KeyDir kd;

    // File 1 holds three live records.
    auto offsets = write_data_file(td.path(), 1, {
        {"a", "alpha",   100},
        {"b", "bravo",   101},
        {"c", "charlie", 102},
    });
    // Populate keydir so each key points at its real (file_id, offset).
    for (std::size_t i = 0; i < offsets.size(); ++i) {
        const std::vector<std::string> keys = {"a", "b", "c"};
        kd.put(keys[i], 1, offsets[i].total_size, offsets[i].offset,
               static_cast<std::uint32_t>(100 + i),
               0, false, 0, 0);
    }
    kd.mark_ready();

    std::vector<std::string> inputs = {mk_data_filename(td.path(), 1)};
    auto result = run_merge(inputs, td.path(), kd);
    ASSERT_TRUE(result);
    EXPECT_EQ(result->records_seen, 3u);
    EXPECT_EQ(result->records_kept, 3u);
    EXPECT_EQ(result->records_stale, 0u);

    // The output file id is one above the input.
    EXPECT_GT(result->output_file_id, 1u);

    // After merge, each key now points at the new file via keydir.
    for (auto k : {"a", "b", "c"}) {
        auto v = kd.get(k);
        ASSERT_TRUE(v) << k;
        EXPECT_EQ(v->file_id, result->output_file_id) << k;
    }
}

// ---------------------------------------------------------------------------
// Stale records: keydir points elsewhere, merge skips them.
// ---------------------------------------------------------------------------
TEST(Merger, SkipsStaleRecords) {
    TempDir td;
    KeyDir kd;

    // File 1 has 'a' at file_id=1, but keydir says 'a' is at file 2.
    auto offsets = write_data_file(td.path(), 1, {{"a", "stale", 100}});
    // Pretend a newer file 2 superseded it.
    kd.put("a", /*fid*/ 2, /*sz*/ 50, /*off*/ 0, /*ts*/ 200,
           0, true, 0, 0);

    auto result = run_merge(std::vector<std::string>{mk_data_filename(td.path(), 1)},
                             td.path(), kd);
    ASSERT_TRUE(result);
    EXPECT_EQ(result->records_seen, 1u);
    EXPECT_EQ(result->records_kept, 0u);
    EXPECT_EQ(result->records_stale, 1u);
}

// ---------------------------------------------------------------------------
// Tombstones in source are skipped.
// ---------------------------------------------------------------------------
TEST(Merger, SkipsTombstoneRecords) {
    TempDir td;
    KeyDir kd;

    // Use the canonical legacy v0 tombstone literal as the value.
    auto offsets = write_data_file(td.path(), 1, {
        {"a", "alive",                100},
        {"x", "bitcask_tombstone",    101},  // matches format::is_tombstone_value
    });
    kd.put("a", 1, offsets[0].total_size, offsets[0].offset, 100,
           0, false, 0, 0);
    kd.put("x", 1, offsets[1].total_size, offsets[1].offset, 101,
           0, false, 0, 0);

    auto result = run_merge(std::vector<std::string>{mk_data_filename(td.path(), 1)},
                             td.path(), kd);
    ASSERT_TRUE(result);
    EXPECT_EQ(result->records_seen,  2u);
    EXPECT_EQ(result->records_kept,  1u);
    EXPECT_EQ(result->records_tombs, 1u);
}

// ---------------------------------------------------------------------------
// Multi-file input: dedup across files keeps only the latest revision.
// ---------------------------------------------------------------------------
TEST(Merger, DeduplicatesAcrossMultipleInputs) {
    TempDir td;
    KeyDir kd;

    // File 1: old version of "k"; File 2: newer version.
    auto o1 = write_data_file(td.path(), 1, {{"k", "old", 100}});
    auto o2 = write_data_file(td.path(), 2, {{"k", "new", 101}});

    // keydir says current is file 2.
    kd.put("k", 2, o2[0].total_size, o2[0].offset, 101,
           0, true, 0, 0);

    std::vector<std::string> inputs = {
        mk_data_filename(td.path(), 1),
        mk_data_filename(td.path(), 2),
    };
    auto result = run_merge(inputs, td.path(), kd);
    ASSERT_TRUE(result);
    EXPECT_EQ(result->records_seen,  2u);
    EXPECT_EQ(result->records_kept,  1u);
    EXPECT_EQ(result->records_stale, 1u);   // file 1's "k" was stale

    // After merge, "k" points at the new merge output (one file id higher).
    auto v = kd.get("k");
    ASSERT_TRUE(v);
    EXPECT_EQ(v->file_id, result->output_file_id);
}

// ---------------------------------------------------------------------------
// Output files are valid: hint trailer validates, data records readable.
// ---------------------------------------------------------------------------
TEST(Merger, OutputHintIsValidAndReadable) {
    TempDir td;
    KeyDir kd;

    auto offsets = write_data_file(td.path(), 1, {
        {"x", "1", 100},
        {"y", "22", 101},
        {"z", "333", 102},
    });
    const std::vector<std::string> keys = {"x", "y", "z"};
    for (std::size_t i = 0; i < offsets.size(); ++i) {
        kd.put(keys[i], 1, offsets[i].total_size, offsets[i].offset,
               static_cast<std::uint32_t>(100 + i), 0, false, 0, 0);
    }

    auto result = run_merge(std::vector<std::string>{mk_data_filename(td.path(), 1)},
                             td.path(), kd);
    ASSERT_TRUE(result);

    // Hint file's trailer must validate.
    auto hf = HintFile::open(result->output_hint_path,
                              HintFile::Mode::kRead);
    ASSERT_TRUE(hf);
    auto v = hf->validate_trailer();
    ASSERT_TRUE(v);
    EXPECT_TRUE(*v);

    // The hint must list exactly our 3 keys.
    std::vector<std::string> hint_keys;
    auto fr = hf->fold([&](const auto& rec) {
        hint_keys.push_back(view_str(rec.key));
    });
    ASSERT_TRUE(fr);
    std::sort(hint_keys.begin(), hint_keys.end());
    EXPECT_EQ(hint_keys, (std::vector<std::string>{"x", "y", "z"}));
}

// ---------------------------------------------------------------------------
// Empty merge produces a valid empty hint file.
// ---------------------------------------------------------------------------
TEST(Merger, EmptyInputsProduceEmptyOutput) {
    TempDir td;
    KeyDir kd;

    auto result = run_merge(std::vector<std::string>{}, td.path(), kd);
    ASSERT_TRUE(result);
    EXPECT_EQ(result->records_seen,  0u);
    EXPECT_EQ(result->records_kept,  0u);

    auto hf = HintFile::open(result->output_hint_path, HintFile::Mode::kRead);
    ASSERT_TRUE(hf);
    auto v = hf->validate_trailer();
    ASSERT_TRUE(v);
    EXPECT_TRUE(*v);
}
