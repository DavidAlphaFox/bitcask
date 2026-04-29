// M3.4 unit tests: Cask facade end-to-end.

#include <unistd.h>

#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/cask.hpp"
#include "bitcask/keydir_registry.hpp"

namespace fs = std::filesystem;

using bitcask::Cask;
using bitcask::CaskError;
using bitcask::CaskOptions;
using bitcask::keydir::KeyDirRegistry;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_cask_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string path() const { return path_.string(); }
private:
    fs::path path_;
};

std::span<const std::byte> sb(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}
std::string vs(std::span<const std::byte> b) {
    return {reinterpret_cast<const char*>(b.data()), b.size()};
}

CaskOptions rw_opts() {
    CaskOptions o;
    o.read_write = true;
    return o;
}

}  // namespace

// ---------------------------------------------------------------------------
TEST(Cask, OpenReadOnlyEmptyDirectory) {
    TempDir td;
    auto c = Cask::open(td.path(), CaskOptions{});
    ASSERT_TRUE(c);
    EXPECT_TRUE((*c)->is_empty_estimate());
    EXPECT_TRUE((*c)->status().files.empty());
}

TEST(Cask, PutGetRoundTrip) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->put(sb("k1"), sb("hello")));
    auto v = (*c)->get(sb("k1"));
    ASSERT_TRUE(v) << static_cast<int>(v.error().kind);
    EXPECT_EQ(vs(v->value), "hello");
}

TEST(Cask, GetMissingReturnsNotFound) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    auto v = (*c)->get(sb("ghost"));
    ASSERT_FALSE(v);
    EXPECT_EQ(v.error().kind, CaskError::kNotFound);
}

TEST(Cask, OverwriteReturnsLatest) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("k"), sb("v1")));
    ASSERT_TRUE((*c)->put(sb("k"), sb("v2")));
    auto v = (*c)->get(sb("k"));
    ASSERT_TRUE(v);
    EXPECT_EQ(vs(v->value), "v2");
}

TEST(Cask, DeleteHidesKey) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
    ASSERT_TRUE((*c)->remove(sb("k")));
    auto v = (*c)->get(sb("k"));
    ASSERT_FALSE(v);
    EXPECT_EQ(v.error().kind, CaskError::kNotFound);
}

TEST(Cask, ReadOnlyCannotPut) {
    TempDir td;
    {  // create dir with one record
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
    }
    auto c = Cask::open(td.path(), CaskOptions{});  // read-only
    ASSERT_TRUE(c);
    auto p = (*c)->put(sb("x"), sb("y"));
    ASSERT_FALSE(p);
    EXPECT_EQ(p.error().kind, CaskError::kReadOnly);
}

TEST(Cask, ReopenSeesPreviousData) {
    TempDir td;
    {
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->put(sb("a"), sb("alpha")));
        ASSERT_TRUE((*c)->put(sb("b"), sb("bravo")));
    }
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    auto a = (*c)->get(sb("a"));
    ASSERT_TRUE(a);
    EXPECT_EQ(vs(a->value), "alpha");
    auto b = (*c)->get(sb("b"));
    ASSERT_TRUE(b);
    EXPECT_EQ(vs(b->value), "bravo");
}

TEST(Cask, ReopenAfterDeleteSeesAbsence) {
    TempDir td;
    {
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
        ASSERT_TRUE((*c)->remove(sb("k")));
    }
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    auto v = (*c)->get(sb("k"));
    ASSERT_FALSE(v);
    EXPECT_EQ(v.error().kind, CaskError::kNotFound);
}

TEST(Cask, FoldVisitsLiveKeys) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("a"), sb("1")));
    ASSERT_TRUE((*c)->put(sb("b"), sb("2")));
    ASSERT_TRUE((*c)->put(sb("c"), sb("3")));
    ASSERT_TRUE((*c)->remove(sb("b")));

    auto it = (*c)->make_iter();
    ASSERT_TRUE(it->start());
    std::vector<std::pair<std::string, std::string>> seen;
    while (true) {
        auto r = it->next();
        ASSERT_TRUE(r);
        if (!r->has_value()) break;
        seen.emplace_back(vs(r->value().key), vs(r->value().value));
    }
    std::sort(seen.begin(), seen.end());
    ASSERT_EQ(seen.size(), 2u);
    EXPECT_EQ(seen[0].first,  "a"); EXPECT_EQ(seen[0].second, "1");
    EXPECT_EQ(seen[1].first,  "c"); EXPECT_EQ(seen[1].second, "3");
}

TEST(Cask, StatusReportsKeyBytesAndEpoch) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("alpha"), sb("xx")));
    ASSERT_TRUE((*c)->put(sb("beta"),  sb("yyy")));

    auto s = (*c)->status();
    EXPECT_EQ(s.key_count, 2u);
    EXPECT_EQ(s.key_bytes, 9u);  // 5 + 4 = 9 bytes of key data
    EXPECT_GT(s.epoch, 0u);      // monotonic clock advanced after puts
    EXPECT_FALSE(s.files.empty());
}

TEST(Cask, RollsActiveFileAtMaxSize) {
    TempDir td;
    CaskOptions opts = rw_opts();
    opts.max_file_size = 100;  // tiny — each ~22B record fits ~4 per file
    auto c = Cask::open(td.path(), opts);
    ASSERT_TRUE(c);

    // 12 puts of ~22 bytes each => ~3 files (with overhead it's even more).
    for (int i = 0; i < 12; ++i) {
        std::string k = "k" + std::to_string(i);
        std::string v = "value" + std::to_string(i);
        ASSERT_TRUE((*c)->put(sb(k), sb(v))) << "put " << i;
    }

    // All keys still readable.
    for (int i = 0; i < 12; ++i) {
        std::string k = "k" + std::to_string(i);
        auto v = (*c)->get(sb(k));
        ASSERT_TRUE(v) << "get " << i;
    }

    int count = 0;
    for (auto& e : fs::directory_iterator(td.path())) {
        if (e.path().extension() == ".data") ++count;
    }
    EXPECT_GE(count, 2);
}

TEST(Cask, NeedsMergeOnFragmentedFiles) {
    TempDir td;
    CaskOptions opts = rw_opts();
    opts.max_file_size            = 200;
    opts.policy.frag_merge_trigger = 50;
    opts.policy.frag_threshold     = 50;
    opts.policy.small_file_threshold = 0;  // isolate frag rule
    auto c = Cask::open(td.path(), opts);
    ASSERT_TRUE(c);

    // Force two files by overwriting same key many times.
    for (int i = 0; i < 30; ++i) {
        std::string v = "value-" + std::string(i & 0xF, 'x');
        ASSERT_TRUE((*c)->put(sb("k"), sb(v)));
    }

    auto n = (*c)->needs_merge();
    EXPECT_TRUE(n.needs);
    EXPECT_FALSE(n.files.empty());
}

// Verifies merge actually unlinks the .data + .hint files it consumed —
// previously the merge wrote a new file but left the old ones on disk.
TEST(Cask, MergeUnlinksMergedAwayFiles) {
    TempDir td;
    CaskOptions opts = rw_opts();
    opts.max_file_size               = 100;
    opts.policy.frag_merge_trigger    = 30;
    opts.policy.frag_threshold        = 30;
    opts.policy.small_file_threshold  = 0;
    auto c = Cask::open(td.path(), opts);
    ASSERT_TRUE(c);

    // Force several rollovers + heavy fragmentation by overwriting same key.
    for (int i = 0; i < 30; ++i) {
        std::string v = "v-" + std::string(i & 0x7, 'x');
        ASSERT_TRUE((*c)->put(sb("k"), sb(v)));
    }

    auto count_data = [&] {
        int n = 0;
        for (auto& e : fs::directory_iterator(td.path())) {
            if (e.path().extension() == ".data") ++n;
        }
        return n;
    };
    auto count_hint = [&] {
        int n = 0;
        for (auto& e : fs::directory_iterator(td.path())) {
            if (e.path().extension() == ".hint") ++n;
        }
        return n;
    };

    const int data_before = count_data();
    const int hint_before = count_hint();
    ASSERT_GE(data_before, 2) << "test setup expected multiple data files";

    // Take the snapshot of which files needs_merge picks; merge should
    // unlink exactly those (+ their hints).
    auto n = (*c)->needs_merge();
    ASSERT_TRUE(n.needs);
    const auto picked = n.files;
    ASSERT_FALSE(picked.empty());

    auto m = (*c)->merge();
    ASSERT_TRUE(m);

    // Each picked input must no longer exist; nor must its hint.
    for (const auto& p : picked) {
        EXPECT_FALSE(fs::exists(p)) << "data file should be unlinked: " << p;
        const std::string h =
            bitcask::fileops::mk_hint_filename(p);
        EXPECT_FALSE(fs::exists(h)) << "hint file should be unlinked: " << h;
    }

    // Disk-level invariants: file count strictly decreased; the merge
    // produced exactly one new (data, hint) pair, so net change is
    // (added 1) - (removed |picked|).
    EXPECT_EQ(count_data(), data_before + 1 - static_cast<int>(picked.size()));
    EXPECT_EQ(count_hint(), hint_before + 1 - static_cast<int>(picked.size()));

    // Live data still readable.
    auto v = (*c)->get(sb("k"));
    ASSERT_TRUE(v);
}

TEST(Cask, MergeKeepsLatestValueAndRemovesStale) {
    TempDir td;
    CaskOptions opts = rw_opts();
    opts.max_file_size               = 100;
    opts.policy.frag_merge_trigger    = 50;
    opts.policy.frag_threshold        = 50;
    opts.policy.small_file_threshold  = 0;
    auto c = Cask::open(td.path(), opts);
    ASSERT_TRUE(c);

    // Many overwrites of the same key force file rollover. Most of those
    // records become stale; only the latest survives in the active file
    // (which the merger ignores since it's the live writer).
    for (int i = 0; i < 30; ++i) {
        std::string v = "v-" + std::string(i & 0x7, 'x');
        ASSERT_TRUE((*c)->put(sb("k"), sb(v)));
    }
    auto last = (*c)->get(sb("k"));
    ASSERT_TRUE(last);
    const std::string final_value = vs(last->value);

    auto m = (*c)->merge();
    ASSERT_TRUE(m);
    // All input records were stale — the latest is in the active writer
    // file which the merger filters out, so nothing is "kept" by the merge,
    // but the stale skip count documents it ran.
    EXPECT_GT(m->records_seen, 0u);
    EXPECT_EQ(m->records_kept, 0u);
    EXPECT_GT(m->records_stale, 0u);

    // After merge the live value is still observable.
    auto v = (*c)->get(sb("k"));
    ASSERT_TRUE(v);
    EXPECT_EQ(vs(v->value), final_value);
}

TEST(Cask, WriteLockExclusiveBetweenProcesses) {
    TempDir td;
    auto c1 = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c1);

    // Second writer must fail with kWriteLocked.
    auto c2 = Cask::open(td.path(), rw_opts());
    ASSERT_FALSE(c2);
    EXPECT_EQ(c2.error().kind, CaskError::kWriteLocked);
}

TEST(Cask, SharedKeydirAcrossCaskInstancesViaRegistry) {
    TempDir td;
    KeyDirRegistry reg;
    {
        auto c1 = Cask::open(td.path(), rw_opts(), &reg);
        ASSERT_TRUE(c1);
        ASSERT_TRUE((*c1)->put(sb("k"), sb("v")));
    }
    // After c1 closes, registry should preserve biggest_file_id;
    // a fresh acquirer should see no live key but valid keydir.
    auto c2 = Cask::open(td.path(), rw_opts(), &reg);
    ASSERT_TRUE(c2);
    auto v = (*c2)->get(sb("k"));
    ASSERT_TRUE(v);
    EXPECT_EQ(vs(v->value), "v");
}

// Reproduces a real-world bug:
//   1. Process A opens a cask read_write — write.lock created.
//   2. A crashes, leaving the lock file behind.
//   3. Process B (or A restarted) tries to open same dir read_write.
//   Legacy uses `kill -0 <pid>` to detect the dead owner and wipe the
//   stale lock; cask must do the same.
TEST(Cask, StaleWriteLockFromDeadPidIsReclaimed) {
    TempDir td;
    const auto lock_path =
        std::filesystem::path(td.path()) / "bitcask.write.lock";

    // Simulate a previous crashed writer: hand-write a lock file containing
    // a clearly-dead PID. PID 1 is init/systemd and always alive on Linux,
    // so we use a synthesised never-allocated PID. /proc/sys/kernel/pid_max
    // bounds future PIDs; 4194305 is past that on every default Linux.
    {
        std::FILE* fp = std::fopen(lock_path.c_str(), "wb");
        ASSERT_NE(fp, nullptr);
        const char* payload = "4194305\n";
        std::fwrite(payload, 1, std::strlen(payload), fp);
        std::fclose(fp);
    }
    ASSERT_TRUE(std::filesystem::exists(lock_path));

    // Open should succeed by reclaiming the stale lock.
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c) << "expected stale lock to be reclaimed; got error "
                    << static_cast<int>(c.error().kind);
    ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
    ASSERT_TRUE((*c)->get(sb("k")));
}

// Same scenario, but the lock owner IS our own PID (so it's "alive"). We
// must NOT reclaim it — a second writer in the same process must still
// be rejected with kWriteLocked.
TEST(Cask, LiveOwnerLockIsNotReclaimed) {
    TempDir td;
    auto c1 = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c1);
    // Second open in same process: lock is live (we hold it), must fail.
    auto c2 = Cask::open(td.path(), rw_opts());
    ASSERT_FALSE(c2);
    EXPECT_EQ(c2.error().kind, CaskError::kWriteLocked);
}

// An empty lock file (writer crashed before writing PID) is treated as stale.
TEST(Cask, EmptyLockFileTreatedAsStale) {
    TempDir td;
    const auto lock_path =
        std::filesystem::path(td.path()) / "bitcask.write.lock";
    {
        std::FILE* fp = std::fopen(lock_path.c_str(), "wb");
        ASSERT_NE(fp, nullptr);
        std::fclose(fp);
    }
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
}

// ---------------------------------------------------------------------------
// M5.1 task 4: a writer's mid-record crash leaves trailing bytes that fold()
// can skip but that still consume disk and confuse fstats. Reopening the dir
// in writer mode should chop the file back to the last valid record.

namespace {
fs::path only_data_file(const fs::path& dir) {
    for (auto& e : fs::directory_iterator(dir)) {
        auto s = e.path().filename().string();
        if (s.size() > 13 &&
            s.compare(s.size() - 13, 13, ".bitcask.data") == 0) {
            return e.path();
        }
    }
    return {};
}

// Strip every .bitcask.hint file so the next open is forced down the
// data-file fold path (mimicking a crash that finalized no hint trailer).
void remove_all_hints(const fs::path& dir) {
    for (auto& e : fs::directory_iterator(dir)) {
        auto s = e.path().filename().string();
        if (s.size() > 13 &&
            s.compare(s.size() - 13, 13, ".bitcask.hint") == 0) {
            fs::remove(e.path());
        }
    }
}
}  // namespace

TEST(Cask, ReopenTruncatesTornWriteTail) {
    TempDir td;
    {
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->put(sb("k1"), sb("v1")));
        ASSERT_TRUE((*c)->put(sb("k2"), sb("v2")));
    }

    // Simulate a writer crash: the in-flight hint trailer wasn't finalized
    // and the data file got an unparsable trailing fragment.
    remove_all_hints(td.path());
    auto data_path = only_data_file(td.path());
    ASSERT_FALSE(data_path.empty());
    const auto good_size = fs::file_size(data_path);
    {
        std::FILE* fp = std::fopen(data_path.c_str(), "ab");
        ASSERT_NE(fp, nullptr);
        const unsigned char garbage[8] = {0,0,0,0, 0xFF,0xFF, 0xFF,0xFF};
        ASSERT_EQ(8u, std::fwrite(garbage, 1, sizeof(garbage), fp));
        std::fclose(fp);
    }
    ASSERT_EQ(fs::file_size(data_path), good_size + 8u);

    // Reopen as writer: should truncate back to good_size.
    {
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        EXPECT_EQ(fs::file_size(data_path), good_size);

        auto v1 = (*c)->get(sb("k1"));
        ASSERT_TRUE(v1);
        EXPECT_EQ(vs(v1->value), "v1");
        auto v2 = (*c)->get(sb("k2"));
        ASSERT_TRUE(v2);
        EXPECT_EQ(vs(v2->value), "v2");

        // Subsequent writes still work and land cleanly at the trimmed end.
        ASSERT_TRUE((*c)->put(sb("k3"), sb("v3")));
        auto v3 = (*c)->get(sb("k3"));
        ASSERT_TRUE(v3);
        EXPECT_EQ(vs(v3->value), "v3");
    }
}

// Read-only / merge_only opens must NOT mutate the file even when fold sees
// trailing garbage — only the writer that owns write.lock may truncate.
TEST(Cask, ReadOnlyReopenLeavesTornTailIntact) {
    TempDir td;
    {
        auto c = Cask::open(td.path(), rw_opts());
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
    }
    remove_all_hints(td.path());
    auto data_path = only_data_file(td.path());
    ASSERT_FALSE(data_path.empty());
    {
        std::FILE* fp = std::fopen(data_path.c_str(), "ab");
        ASSERT_NE(fp, nullptr);
        const unsigned char garbage[8] = {0,0,0,0, 0xFF,0xFF, 0xFF,0xFF};
        ASSERT_EQ(8u, std::fwrite(garbage, 1, sizeof(garbage), fp));
        std::fclose(fp);
    }
    const auto torn_size = fs::file_size(data_path);

    {
        CaskOptions ro;  // read_only by default
        auto c = Cask::open(td.path(), ro);
        ASSERT_TRUE(c);
        auto v = (*c)->get(sb("k"));
        ASSERT_TRUE(v);
        EXPECT_EQ(vs(v->value), "v");
    }
    EXPECT_EQ(fs::file_size(data_path), torn_size);
}

// v2 tombstone: remove() writes "bitcask_tombstone2" + FileId32 (BE). The
// bytes land in the active data file; reads still see not_found and any
// future scan rebuilds the same delete.
TEST(Cask, RemoveWritesTombstoneV2WhenConfigured) {
    TempDir td;
    CaskOptions opts = rw_opts();
    opts.tombstone_version = 2;
    auto c = Cask::open(td.path(), opts);
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("k"), sb("v")));

    // Capture the file size BEFORE the delete so we can read just the
    // tombstone record's value.
    auto data_path = only_data_file(td.path());
    ASSERT_FALSE(data_path.empty());
    const auto pre_size = fs::file_size(data_path);

    ASSERT_TRUE((*c)->remove(sb("k")));

    auto post_size = fs::file_size(data_path);
    ASSERT_GT(post_size, pre_size);

    // The tombstone record on disk: 14B header + key("k", 1B) + value (22B v2).
    // Read the last 22 bytes — the value.
    std::FILE* fp = std::fopen(data_path.c_str(), "rb");
    ASSERT_NE(fp, nullptr);
    ASSERT_EQ(0, std::fseek(fp, static_cast<long>(post_size - 22), SEEK_SET));
    char buf[22];
    ASSERT_EQ(22u, std::fread(buf, 1, 22, fp));
    std::fclose(fp);
    EXPECT_EQ(0, std::memcmp(buf, "bitcask_tombstone2", 18));
    // Trailing 4 bytes are the shadowed file_id (BE). Non-zero (we wrote
    // the live record before deleting it).
    const std::uint32_t shadow =
        (static_cast<std::uint8_t>(buf[18]) << 24) |
        (static_cast<std::uint8_t>(buf[19]) << 16) |
        (static_cast<std::uint8_t>(buf[20]) <<  8) |
        (static_cast<std::uint8_t>(buf[21]));
    EXPECT_GT(shadow, 0u);

    // Reopen — key still gone, no panics. Close the first writer so it
    // releases bitcask.write.lock.
    (*c)->close();
    auto c2 = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c2);
    auto g = (*c2)->get(sb("k"));
    EXPECT_FALSE(g);
    EXPECT_EQ(g.error().kind, CaskError::kNotFound);
}

TEST(Cask, RemoveWithoutOptStillWritesV0) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());  // tombstone_version default 0
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->put(sb("k"), sb("v")));
    ASSERT_TRUE((*c)->remove(sb("k")));

    auto data_path = only_data_file(td.path());
    ASSERT_FALSE(data_path.empty());
    const auto sz = fs::file_size(data_path);
    std::FILE* fp = std::fopen(data_path.c_str(), "rb");
    ASSERT_NE(fp, nullptr);
    ASSERT_EQ(0, std::fseek(fp, static_cast<long>(sz - 17), SEEK_SET));
    char buf[17];
    ASSERT_EQ(17u, std::fread(buf, 1, 17, fp));
    std::fclose(fp);
    EXPECT_EQ(0, std::memcmp(buf, "bitcask_tombstone", 17));
}

TEST(Cask, BinaryKeyAndValueWithNul) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    ASSERT_TRUE(c);
    std::string k("k\0a", 3);
    std::string v("v\0\0\0", 4);
    ASSERT_TRUE((*c)->put(sb(k), sb(v)));
    auto g = (*c)->get(sb(k));
    ASSERT_TRUE(g);
    EXPECT_EQ(g->value.size(), 4u);
    EXPECT_EQ(0, std::memcmp(g->value.data(), v.data(), 4));
}
