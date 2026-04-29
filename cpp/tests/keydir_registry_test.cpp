// M2.3 unit tests: process-global registry of named keydirs + refcount +
// biggest_file_id persistence across release/reacquire.

#include <atomic>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/keydir_registry.hpp"

using bitcask::keydir::AcquireResult;
using bitcask::keydir::AcquireStatus;
using bitcask::keydir::KeyDir;
using bitcask::keydir::KeyDirRegistry;

TEST(KeyDirRegistry, FirstAcquireReportsCreatedAndNotReady) {
    KeyDirRegistry reg;
    auto r = reg.acquire("dir-1");
    EXPECT_EQ(r.status, AcquireStatus::kCreated);
    ASSERT_TRUE(r.keydir);
    EXPECT_FALSE(r.keydir->is_ready());
    EXPECT_EQ(reg.size(), 1u);
}

TEST(KeyDirRegistry, SecondAcquireBeforeMarkReadyReturnsNotReady) {
    KeyDirRegistry reg;
    auto r1 = reg.acquire("dir-1");
    ASSERT_EQ(r1.status, AcquireStatus::kCreated);

    auto r2 = reg.acquire("dir-1");
    EXPECT_EQ(r2.status, AcquireStatus::kNotReady);
    EXPECT_EQ(r2.keydir, nullptr);
    EXPECT_EQ(reg.size(), 1u);
}

TEST(KeyDirRegistry, AcquireAfterMarkReadyReturnsReady) {
    KeyDirRegistry reg;
    auto r1 = reg.acquire("dir-1");
    r1.keydir->mark_ready();

    auto r2 = reg.acquire("dir-1");
    EXPECT_EQ(r2.status, AcquireStatus::kReady);
    EXPECT_EQ(r2.keydir, r1.keydir) << "must hand out same instance";
}

TEST(KeyDirRegistry, AcquireDifferentNamesReturnDistinctInstances) {
    KeyDirRegistry reg;
    auto a = reg.acquire("a");
    auto b = reg.acquire("b");
    EXPECT_NE(a.keydir, b.keydir);
    EXPECT_EQ(reg.size(), 2u);
}

TEST(KeyDirRegistry, ReleaseDecrementsRefcount) {
    KeyDirRegistry reg;
    auto r1 = reg.acquire("dir-1");
    r1.keydir->mark_ready();
    auto r2 = reg.acquire("dir-1");
    auto r3 = reg.acquire("dir-1");
    EXPECT_EQ(reg.size(), 1u);

    reg.release("dir-1");
    reg.release("dir-1");
    EXPECT_EQ(reg.size(), 1u) << "still has 1 holder";

    reg.release("dir-1");
    EXPECT_EQ(reg.size(), 0u);
}

TEST(KeyDirRegistry, ReleaseUnknownNameIsNoop) {
    KeyDirRegistry reg;
    reg.release("nope");  // must not crash
    EXPECT_EQ(reg.size(), 0u);
}

TEST(KeyDirRegistry, BiggestFileIdPersistsAcrossReleaseAndReacquire) {
    KeyDirRegistry reg;
    auto r1 = reg.acquire("d");
    r1.keydir->increment_file_id();          // -> 1
    r1.keydir->increment_file_id();          // -> 2
    r1.keydir->increment_file_id();          // -> 3
    r1.keydir->mark_ready();
    EXPECT_EQ(r1.keydir->biggest_file_id(), 3u);

    auto cached = r1.keydir;
    cached.reset();          // drop our handle (registry still holds 1)
    reg.release("d");        // refcount 1 -> 0, registry persists 4

    auto saved = reg.saved_biggest_file_id("d");
    ASSERT_TRUE(saved.has_value());
    EXPECT_EQ(*saved, 4u) << "must save biggest_file_id + 1";

    auto r2 = reg.acquire("d");
    EXPECT_EQ(r2.status, AcquireStatus::kCreated);
    EXPECT_EQ(r2.keydir->biggest_file_id(), 4u)
        << "new acquirer must inherit the saved id";
}

TEST(KeyDirRegistry, BiggestFileIdMonotonicAcrossMultipleCycles) {
    KeyDirRegistry reg;
    {
        auto r = reg.acquire("d");
        r.keydir->increment_file_id_at_least(10);
        r.keydir->mark_ready();
    }
    reg.release("d");

    {
        auto r = reg.acquire("d");
        EXPECT_EQ(r.keydir->biggest_file_id(), 11u);  // 10 + 1
        r.keydir->increment_file_id_at_least(5);       // ignored — already 11
        r.keydir->increment_file_id_at_least(20);
        r.keydir->mark_ready();
    }
    reg.release("d");

    {
        auto r = reg.acquire("d");
        EXPECT_EQ(r.keydir->biggest_file_id(), 21u);   // 20 + 1
    }
}

TEST(KeyDirRegistry, QueryDoesNotCreateOrIncrementRefcount) {
    KeyDirRegistry reg;
    auto q1 = reg.query("ghost");
    EXPECT_EQ(q1.status, AcquireStatus::kNotReady);
    EXPECT_EQ(q1.keydir, nullptr);
    EXPECT_EQ(reg.size(), 0u);

    auto a = reg.acquire("dir");
    auto q2 = reg.query("dir");
    EXPECT_EQ(q2.status, AcquireStatus::kNotReady)
        << "exists but not ready -> kNotReady";
    EXPECT_EQ(q2.keydir, nullptr);

    a.keydir->mark_ready();
    auto q3 = reg.query("dir");
    EXPECT_EQ(q3.status, AcquireStatus::kReady);
    EXPECT_EQ(q3.keydir, a.keydir);

    // Query did not bump refcount; one release still drops the entry.
    reg.release("dir");
    EXPECT_EQ(reg.size(), 0u);
}

TEST(KeyDirRegistry, NameWithEmbeddedNul) {
    KeyDirRegistry reg;
    std::string n("a\0b", 3);
    auto r1 = reg.acquire(n);
    r1.keydir->mark_ready();
    auto r2 = reg.acquire(n);
    EXPECT_EQ(r2.status, AcquireStatus::kReady);
    EXPECT_EQ(r1.keydir, r2.keydir);
}

TEST(KeyDirRegistry, ConcurrentAcquireReleaseStress) {
    KeyDirRegistry reg;
    constexpr int kNames    = 8;
    constexpr int kThreads  = 8;
    constexpr int kIters    = 500;

    std::atomic<int> created_count{0};
    std::atomic<int> not_ready_count{0};
    std::atomic<int> ready_count{0};

    auto worker = [&](int /*tid*/) {
        for (int i = 0; i < kIters; ++i) {
            const std::string name = "n" + std::to_string(i % kNames);
            auto r = reg.acquire(name);
            switch (r.status) {
            case AcquireStatus::kCreated:
                created_count.fetch_add(1);
                r.keydir->mark_ready();
                reg.release(name);
                break;
            case AcquireStatus::kReady:
                ready_count.fetch_add(1);
                reg.release(name);
                break;
            case AcquireStatus::kNotReady:
                not_ready_count.fetch_add(1);
                // Don't release — never owned a refcount.
                break;
            }
        }
    };

    std::vector<std::thread> ts;
    ts.reserve(kThreads);
    for (int t = 0; t < kThreads; ++t) ts.emplace_back(worker, t);
    for (auto& th : ts) th.join();

    // Registry must end empty (every successful acquire was released).
    EXPECT_EQ(reg.size(), 0u);
    EXPECT_GT(ready_count.load() + created_count.load(), 0);
}
