#include <gtest/gtest.h>

#include "bitcask/keydir.hpp"

namespace {

using bitcask::keydir::EntryProxy;
using bitcask::keydir::KeyDir;
using bitcask::keydir::PutResult;

}  // namespace

TEST(KeyDir, AllocOrdMonotonic) {
    KeyDir kd;
    EXPECT_EQ(kd.alloc_ord(), 0u);
    EXPECT_EQ(kd.alloc_ord(), 1u);
    EXPECT_EQ(kd.alloc_ord(), 2u);
    EXPECT_EQ(kd.get_epoch(), 0u);
}

TEST(KeyDir, AdvanceOrd) {
    KeyDir kd;
    kd.alloc_ord();
    kd.alloc_ord();
    EXPECT_EQ(kd.alloc_ord(), 2u);

    kd.advance_ord(5);
    EXPECT_EQ(kd.alloc_ord(), 6u);

    kd.advance_ord(3);
    EXPECT_EQ(kd.alloc_ord(), 7u);

    kd.advance_ord(100);
    EXPECT_EQ(kd.alloc_ord(), 101u);
}

TEST(KeyDir, PutAndGetWithOrd) {
    KeyDir kd;

    auto r1 = kd.put("k1",
                     /*file_id*/ 1, /*total_sz*/ 10,
                     /*offset*/ 100, /*tstamp*/ 1000,
                     /*now_sec*/ 0,
                     /*newest_put*/ true,
                     /*old_file_id*/ 0, /*old_offset*/ 0,
                     /*ord*/ 5);
    EXPECT_EQ(r1, PutResult::kOk);

    auto e1 = kd.get("k1");
    ASSERT_TRUE(e1.has_value());
    EXPECT_EQ(e1->ord, 5u);
    EXPECT_EQ(e1->file_id, 1u);
    EXPECT_EQ(e1->offset, 100u);

    auto r2 = kd.put("k1",
                     /*file_id*/ 2, /*total_sz*/ 20,
                     /*offset*/ 200, /*tstamp*/ 2000,
                     /*now_sec*/ 0,
                     /*newest_put*/ true,
                     /*old_file_id*/ 0, /*old_offset*/ 0,
                     /*ord*/ 10);
    EXPECT_EQ(r2, PutResult::kOk);

    auto e2 = kd.get("k1");
    ASSERT_TRUE(e2.has_value());
    EXPECT_EQ(e2->ord, 10u);
    EXPECT_EQ(e2->file_id, 2u);
}

TEST(KeyDir, PutWithDefaultOrd) {
    KeyDir kd;

    auto r = kd.put("k1",
                    /*file_id*/ 1, /*total_sz*/ 10,
                    /*offset*/ 100, /*tstamp*/ 1000,
                    /*now_sec*/ 0,
                    /*newest_put*/ true,
                    /*old_file_id*/ 0, /*old_offset*/ 0);
    EXPECT_EQ(r, PutResult::kOk);

    auto e = kd.get("k1");
    ASSERT_TRUE(e.has_value());
    EXPECT_EQ(e->ord, 0u);
}

TEST(KeyDir, PutMultipleKeysDifferentOrd) {
    KeyDir kd;

    kd.put("a", 1, 10, 100, 1000, 0, true, 0, 0, 1);
    kd.put("b", 1, 10, 100, 1000, 0, true, 0, 0, 2);
    kd.put("c", 1, 10, 100, 1000, 0, true, 0, 0, 3);

    EXPECT_EQ(kd.get("a")->ord, 1u);
    EXPECT_EQ(kd.get("b")->ord, 2u);
    EXPECT_EQ(kd.get("c")->ord, 3u);
}

TEST(KeyDir, AdvanceOrdAfterPut) {
    KeyDir kd;

    kd.put("k1", 1, 10, 100, 1000, 0, true, 0, 0, 0);
    kd.advance_ord(50);

    auto o = kd.alloc_ord();
    EXPECT_EQ(o, 51u);

    auto r = kd.put("k2", 1, 10, 100, 1000, 0, true, 0, 0, o);
    EXPECT_EQ(r, PutResult::kOk);
    EXPECT_EQ(kd.get("k2")->ord, 51u);
}

TEST(KeyDir, AllocOrdThreadSafety) {
    KeyDir kd;

    std::vector<std::uint64_t> ords;
    std::mutex m;
    const int N = 100;

    std::vector<std::thread> threads;
    threads.reserve(N);
    for (int i = 0; i < N; ++i) {
        threads.emplace_back([&]() {
            auto o = kd.alloc_ord();
            std::lock_guard<std::mutex> l(m);
            ords.push_back(o);
        });
    }
    for (auto& t : threads) t.join();

    std::sort(ords.begin(), ords.end());
    for (int i = 0; i < N; ++i) {
        EXPECT_EQ(ords[i], static_cast<std::uint64_t>(i));
    }
}