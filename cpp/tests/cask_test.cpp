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
