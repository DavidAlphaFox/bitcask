// M3.3 unit tests: MergePolicy.

#include <gtest/gtest.h>

#include "bitcask/keydir.hpp"
#include "bitcask/merge_policy.hpp"

using bitcask::keydir::FStatsEntry;
using bitcask::merge::Decision;
using bitcask::merge::FileStatus;
using bitcask::merge::PolicyOptions;
using bitcask::merge::Reason;
using bitcask::merge::cap_size;
using bitcask::merge::decide;
using bitcask::merge::per_file_reasons;
using bitcask::merge::summarize;

namespace {

FStatsEntry mk_fstats(std::uint32_t fid, std::uint64_t live_keys,
                      std::uint64_t total_keys, std::uint64_t live_bytes,
                      std::uint64_t total_bytes,
                      std::uint32_t oldest = 0, std::uint32_t newest = 0) {
    FStatsEntry f;
    f.file_id     = fid;
    f.live_keys   = live_keys;
    f.total_keys  = total_keys;
    f.live_bytes  = live_bytes;
    f.total_bytes = total_bytes;
    f.oldest_tstamp = oldest;
    f.newest_tstamp = newest;
    return f;
}

}  // namespace

// ---------------------------------------------------------------------------
// summarize
// ---------------------------------------------------------------------------
TEST(MergePolicy, SummarizeComputesFragAndDead) {
    auto s = summarize("/tmp/db",
                       mk_fstats(/*fid*/ 5, /*live_k*/ 4, /*total_k*/ 10,
                                  /*live_b*/ 400, /*total_b*/ 1000,
                                  /*old*/ 100, /*new*/ 200));
    EXPECT_EQ(s.file_id,     5u);
    EXPECT_EQ(s.filename,    "/tmp/db/5.bitcask.data");
    EXPECT_EQ(s.fragmented,  60);    // (1 - 4/10)*100 = 60
    EXPECT_EQ(s.dead_bytes,  600u);
    EXPECT_EQ(s.total_bytes, 1000u);
    EXPECT_EQ(s.oldest_tstamp, 100u);
    EXPECT_EQ(s.newest_tstamp, 200u);
}

TEST(MergePolicy, SummarizeEmptyFileFragmentationZero) {
    auto s = summarize("/tmp/db", mk_fstats(1, 0, 0, 0, 0));
    EXPECT_EQ(s.fragmented,  0);
    EXPECT_EQ(s.dead_bytes,  0u);
    EXPECT_EQ(s.total_bytes, 0u);
}

// ---------------------------------------------------------------------------
// per_file_reasons
// ---------------------------------------------------------------------------
TEST(MergePolicy, PerFileFragThreshold) {
    PolicyOptions opts;
    opts.frag_threshold = 40;
    opts.small_file_threshold = 0;  // isolate frag rule
    FileStatus f{1, "/x/1.bitcask.data", /*frag*/ 50,
                 /*dead*/ 0, /*total*/ 5000, 0, 0, 0};
    auto rs = per_file_reasons(f, opts, /*now*/ 0);
    ASSERT_EQ(rs.size(), 1u);
    EXPECT_EQ(rs[0].kind, Reason::Kind::kFragmented);
    EXPECT_EQ(rs[0].value, 50u);
}

TEST(MergePolicy, PerFileSmallFileThreshold) {
    PolicyOptions opts;
    opts.small_file_threshold = 10000;
    FileStatus f{1, "/x/1.bitcask.data", 0, 0, /*total*/ 1000, 0, 0, 0};
    auto rs = per_file_reasons(f, opts, 0);
    ASSERT_FALSE(rs.empty());
    EXPECT_EQ(rs[0].kind, Reason::Kind::kSmallFile);
}

TEST(MergePolicy, PerFileSmallFileDisabledWhenZero) {
    PolicyOptions opts;
    opts.small_file_threshold = 0;
    FileStatus f{1, "/x/1.bitcask.data", 0, 0, /*total*/ 1000, 0, 0, 0};
    auto rs = per_file_reasons(f, opts, 0);
    EXPECT_TRUE(rs.empty());
}

TEST(MergePolicy, PerFileDeadBytesThreshold) {
    PolicyOptions opts;
    opts.dead_bytes_threshold = 100;
    opts.small_file_threshold = 0;
    FileStatus f{1, "/x", 0, /*dead*/ 200, /*total*/ 500, 0, 0, 0};
    auto rs = per_file_reasons(f, opts, 0);
    ASSERT_EQ(rs.size(), 1u);
    EXPECT_EQ(rs[0].kind, Reason::Kind::kDeadBytes);
}

TEST(MergePolicy, PerFileDataExpired) {
    PolicyOptions opts;
    opts.expiry_secs = 100;
    opts.small_file_threshold = 0;
    FileStatus f{1, "/x", 0, 0, 1000,
                 /*oldest*/ 50, /*newest*/ 200, 0};
    // now=400, cutoff=now-expiry_secs=300; newest=200 < 300 → expired.
    auto rs = per_file_reasons(f, opts, /*now*/ 400);
    ASSERT_FALSE(rs.empty());
    EXPECT_EQ(rs[0].kind, Reason::Kind::kDataExpired);
    EXPECT_EQ(rs[0].value, 200u);
    EXPECT_EQ(rs[0].cutoff, 300u);
}

TEST(MergePolicy, PerFileMultipleReasons) {
    PolicyOptions opts;
    opts.frag_threshold = 40;
    opts.dead_bytes_threshold = 100;
    opts.small_file_threshold = 0;
    FileStatus f{1, "/x", /*frag*/ 90, /*dead*/ 500, /*total*/ 600, 0, 0, 0};
    auto rs = per_file_reasons(f, opts, 0);
    EXPECT_EQ(rs.size(), 2u);  // frag + dead
}

// ---------------------------------------------------------------------------
// decide (the main entrypoint)
// ---------------------------------------------------------------------------
TEST(MergePolicy, DecideEmptyReturnsFalse) {
    auto d = decide({}, PolicyOptions{}, 0);
    EXPECT_FALSE(d.needs_merge);
}

TEST(MergePolicy, DecideNoTriggerReturnsFalse) {
    PolicyOptions opts;  // defaults
    // A clean file: 0% frag, 0 dead bytes — neither trigger fires.
    FileStatus f{1, "/x/1", 0, 0, 100, 0, 0, 0};
    auto d = decide({f}, opts, 0);
    EXPECT_FALSE(d.needs_merge);
    EXPECT_TRUE(d.files.empty());
}

TEST(MergePolicy, DecideFragTriggerFires) {
    PolicyOptions opts;
    opts.frag_merge_trigger = 60;
    opts.frag_threshold     = 40;
    opts.small_file_threshold = 0;   // isolate frag rule
    FileStatus a{1, "/x/1.bitcask.data", 70, 0, 1000, 0, 0, 0};
    FileStatus b{2, "/x/2.bitcask.data", 30, 0, 1000, 0, 0, 0};

    auto d = decide({a, b}, opts, 0);
    ASSERT_TRUE(d.needs_merge);
    // Both files exceed frag_threshold=40? a:70 yes; b:30 no.
    ASSERT_EQ(d.files.size(), 1u);
    EXPECT_EQ(d.files[0].file_id, 1u);
}

TEST(MergePolicy, DecideExpiredFileMarkedSeparately) {
    PolicyOptions opts;
    opts.expiry_secs = 100;
    opts.frag_threshold = 999;          // disable other rules
    opts.dead_bytes_threshold = (1ULL << 60);
    opts.small_file_threshold = 0;

    FileStatus f{1, "/x/1.bitcask.data", 0, 0, 1000,
                 /*oldest*/ 50, /*newest*/ 100, 0};

    auto d = decide({f}, opts, /*now*/ 500);
    ASSERT_TRUE(d.needs_merge);
    ASSERT_EQ(d.files.size(), 1u);
    ASSERT_EQ(d.expired_files.size(), 1u);
    EXPECT_EQ(d.expired_files[0].file_id, 1u);
}

TEST(MergePolicy, DecideTriggerOnGraceTime) {
    PolicyOptions opts;
    opts.expiry_secs = 100;
    opts.expiry_grace_time = 50;
    opts.frag_merge_trigger = 999;
    opts.dead_bytes_merge_trigger = (1ULL << 60);
    opts.frag_threshold = 0;            // any-frag matches per-file
    opts.dead_bytes_threshold = (1ULL << 60);
    opts.small_file_threshold = 0;

    // newest=100, now=300 → trigger_cutoff = 300-(100+50) = 150 > 100 → triggers.
    FileStatus f{1, "/x/1.bitcask.data", 5,
                 0, 1000, /*old*/ 50, /*new*/ 100, 0};

    auto d = decide({f}, opts, /*now*/ 300);
    EXPECT_TRUE(d.needs_merge);
}

// ---------------------------------------------------------------------------
// cap_size
// ---------------------------------------------------------------------------
TEST(MergePolicy, CapSizeStopsBeforeOverflowFile) {
    FileStatus a{1, "/x/1", 0, 0, 100, 0, 0, 0};
    FileStatus b{2, "/x/2", 0, 0, 100, 0, 0, 0};
    FileStatus c{3, "/x/3", 0, 0, 100, 0, 0, 0};
    auto out = cap_size({a, b, c}, /*sizes*/ {100, 100, 100},
                        /*cap*/ 150);
    // legacy: include a (acc=100), then b would push to 200 > 150 → stop.
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0].file_id, 1u);
}

TEST(MergePolicy, CapSizeUnlimitedReturnsAll) {
    FileStatus a{1, "/x/1", 0, 0, 100, 0, 0, 0};
    FileStatus b{2, "/x/2", 0, 0, 100, 0, 0, 0};
    auto out = cap_size({a, b}, {100, 100}, /*cap*/ 0);
    EXPECT_EQ(out.size(), 2u);
}

TEST(MergePolicy, CapSizeFirstFileAlreadyOverBudgetReturnsEmpty) {
    FileStatus a{1, "/x/1", 0, 0, 5000, 0, 0, 0};
    auto out = cap_size({a}, {5000}, /*cap*/ 100);
    // legacy semantics: do NOT include a file that crosses the cap.
    EXPECT_TRUE(out.empty());
}
