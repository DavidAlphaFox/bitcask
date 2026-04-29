// M2.1 unit tests for bitcask::keydir::KeyDir.
// Covers single-mutex, single-revision behavior. Multi-revision (sibling chain)
// and pending-table tests come in M2.2.

#include <algorithm>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/keydir.hpp"

using bitcask::keydir::Entry;
using bitcask::keydir::EntryProxy;
using bitcask::keydir::FStatsEntry;
using bitcask::keydir::KeyDir;
using bitcask::keydir::PutResult;
using bitcask::keydir::kMaxEpoch;

namespace {

// Helper: unconditional put with sensible defaults for "fresh write" callers.
PutResult put_simple(KeyDir& kd, std::string_view key, std::uint32_t file_id,
                     std::uint64_t offset, std::uint32_t total_sz = 100,
                     std::uint32_t tstamp = 1) {
    return kd.put(key, file_id, total_sz, offset, tstamp,
                  /*now_sec*/ 0, /*newest_put*/ false,
                  /*old_file_id*/ 0, /*old_offset*/ 0);
}

}  // namespace

TEST(KeyDir, EmptyKeyDirReportsZeros) {
    KeyDir kd;
    auto info = kd.info();
    EXPECT_EQ(info.key_count, 0u);
    EXPECT_EQ(info.key_bytes, 0u);
    EXPECT_EQ(info.epoch, 0u);
    EXPECT_TRUE(info.fstats.empty());
    EXPECT_EQ(kd.biggest_file_id(), 0u);
}

TEST(KeyDir, BasicPutGet) {
    KeyDir kd;
    EXPECT_EQ(put_simple(kd, "k1", /*fid*/ 1, /*off*/ 0), PutResult::kOk);
    auto v = kd.get("k1");
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(v->file_id, 1u);
    EXPECT_EQ(v->offset, 0u);
    EXPECT_EQ(v->key, "k1");
    EXPECT_FALSE(v->is_tombstone);
    EXPECT_EQ(kd.biggest_file_id(), 1u);
}

TEST(KeyDir, PutBumpsEpoch) {
    KeyDir kd;
    EXPECT_EQ(kd.get_epoch(), 0u);
    put_simple(kd, "a", 1, 0);
    EXPECT_EQ(kd.get_epoch(), 1u);
    put_simple(kd, "b", 1, 100);
    EXPECT_EQ(kd.get_epoch(), 2u);
}

TEST(KeyDir, GetMissingKeyReturnsNullopt) {
    KeyDir kd;
    EXPECT_FALSE(kd.get("ghost").has_value());
}

TEST(KeyDir, RemoveExistingKey) {
    KeyDir kd;
    put_simple(kd, "k", 1, 0);
    EXPECT_TRUE(kd.remove("k", 0));
    EXPECT_FALSE(kd.get("k").has_value());
    auto info = kd.info();
    EXPECT_EQ(info.key_count, 0u);
}

TEST(KeyDir, RemoveMissingKeyReturnsFalse) {
    KeyDir kd;
    EXPECT_FALSE(kd.remove("nope", 0));
}

TEST(KeyDir, ConditionalRemoveExactMatch) {
    KeyDir kd;
    kd.put("k", /*fid*/ 5, /*sz*/ 200, /*off*/ 1234, /*ts*/ 7,
           0, false, 0, 0);
    EXPECT_EQ(kd.conditional_remove("k", 7, 5, 1234, 0), PutResult::kOk);
    EXPECT_FALSE(kd.get("k").has_value());
}

TEST(KeyDir, ConditionalRemoveMismatchKeepsEntry) {
    KeyDir kd;
    kd.put("k", 5, 200, 1234, 7, 0, false, 0, 0);
    EXPECT_EQ(kd.conditional_remove("k", 8, 5, 1234, 0),
              PutResult::kAlreadyExists);
    EXPECT_TRUE(kd.get("k").has_value());
}

TEST(KeyDir, ConditionalRemoveMissingKeyIsOk) {
    KeyDir kd;
    EXPECT_EQ(kd.conditional_remove("ghost", 1, 1, 0, 0), PutResult::kOk);
}

TEST(KeyDir, FStatsTrackedOnFreshPut) {
    KeyDir kd;
    put_simple(kd, "a", 1, 0, /*sz*/ 50);
    put_simple(kd, "b", 1, 50, /*sz*/ 75);
    auto info = kd.info();
    ASSERT_EQ(info.fstats.size(), 1u);
    const auto& f = info.fstats[0];
    EXPECT_EQ(f.file_id, 1u);
    EXPECT_EQ(f.live_keys, 2u);
    EXPECT_EQ(f.total_keys, 2u);
    EXPECT_EQ(f.live_bytes, 125u);
    EXPECT_EQ(f.total_bytes, 125u);
}

TEST(KeyDir, FStatsCorrectlyMovesBetweenFilesOnUpdate) {
    KeyDir kd;
    put_simple(kd, "k", 1, 0, /*sz*/ 50, /*ts*/ 1);
    // Update with newer tstamp -> moves to file 2
    put_simple(kd, "k", 2, 0, /*sz*/ 60, /*ts*/ 2);

    auto info = kd.info();
    std::sort(info.fstats.begin(), info.fstats.end(),
              [](const FStatsEntry& a, const FStatsEntry& b) {
                  return a.file_id < b.file_id;
              });
    ASSERT_EQ(info.fstats.size(), 2u);
    EXPECT_EQ(info.fstats[0].file_id,    1u);
    EXPECT_EQ(info.fstats[0].live_keys,  0u);  // moved away
    EXPECT_EQ(info.fstats[0].live_bytes, 0u);
    EXPECT_EQ(info.fstats[1].file_id,    2u);
    EXPECT_EQ(info.fstats[1].live_keys,  1u);
    EXPECT_EQ(info.fstats[1].live_bytes, 60u);
}

TEST(KeyDir, FStatsRemoveDecrementsLive) {
    KeyDir kd;
    put_simple(kd, "k", 1, 0, /*sz*/ 50);
    EXPECT_TRUE(kd.remove("k", 0));
    auto info = kd.info();
    ASSERT_EQ(info.fstats.size(), 1u);
    EXPECT_EQ(info.fstats[0].live_keys, 0u);
    EXPECT_EQ(info.fstats[0].live_bytes, 0u);
    EXPECT_EQ(info.fstats[0].total_keys, 1u);  // total never decremented
    EXPECT_EQ(info.fstats[0].total_bytes, 50u);
}

TEST(KeyDir, BiggestFileIdTracksMax) {
    KeyDir kd;
    put_simple(kd, "a", 3, 0);
    put_simple(kd, "b", 7, 0);
    put_simple(kd, "c", 2, 0);
    EXPECT_EQ(kd.biggest_file_id(), 7u);
}

TEST(KeyDir, IncrementFileId) {
    KeyDir kd;
    EXPECT_EQ(kd.increment_file_id(), 1u);
    EXPECT_EQ(kd.increment_file_id(), 2u);
    EXPECT_EQ(kd.biggest_file_id(),    2u);
}

TEST(KeyDir, IncrementFileIdAtLeastOnlyAdvancesIfBigger) {
    KeyDir kd;
    kd.increment_file_id();   // -> 1
    EXPECT_EQ(kd.increment_file_id_at_least(0),  1u);
    EXPECT_EQ(kd.increment_file_id_at_least(5),  5u);
    EXPECT_EQ(kd.increment_file_id_at_least(3),  5u);  // no regression
}

TEST(KeyDir, ConditionalPutFailsWhenKeyMissing) {
    KeyDir kd;
    auto r = kd.put("ghost", 1, 100, 0, 1, 0, /*newest*/ false,
                    /*old_fid*/ 1, /*old_off*/ 0);
    EXPECT_EQ(r, PutResult::kAlreadyExists);
    EXPECT_FALSE(kd.get("ghost").has_value());
}

TEST(KeyDir, ConditionalPutWithMatchingFileOffsetReplaces) {
    KeyDir kd;
    put_simple(kd, "k", 1, 0, /*sz*/ 50);
    auto r = kd.put("k", /*new fid*/ 2, /*sz*/ 60, /*off*/ 0, /*ts*/ 5,
                    0, /*newest*/ true,
                    /*old_fid*/ 1, /*old_off*/ 0);
    EXPECT_EQ(r, PutResult::kOk);
    auto v = kd.get("k");
    ASSERT_TRUE(v);
    EXPECT_EQ(v->file_id, 2u);
}

TEST(KeyDir, ConditionalPutWithStaleFileOffsetFails) {
    KeyDir kd;
    put_simple(kd, "k", 5, 100, 50);
    auto r = kd.put("k", 6, 50, 200, 1, 0, /*newest*/ true,
                    /*old_fid*/ 1, /*old_off*/ 0);
    EXPECT_EQ(r, PutResult::kAlreadyExists);
    EXPECT_EQ(kd.get("k")->file_id, 5u);
}

TEST(KeyDir, NotReadyTotalStatsBumpEvenOnReject) {
    KeyDir kd;
    // First put establishes "current" entry.
    put_simple(kd, "k", 5, 100, /*sz*/ 50, /*ts*/ 10);
    // Second put is older (smaller tstamp, smaller file id) — rejected as stale.
    auto r = kd.put("k", 3, /*sz*/ 70, /*off*/ 0, /*ts*/ 5,
                    0, /*newest*/ false, 0, 0);
    EXPECT_EQ(r, PutResult::kAlreadyExists);
    auto info = kd.info();
    // Both files should appear; file 3 should have total_keys=1, total_bytes=70
    // even though no live entry exists there.
    auto find = [&](std::uint32_t fid) -> const FStatsEntry* {
        for (auto& f : info.fstats) if (f.file_id == fid) return &f;
        return nullptr;
    };
    auto* f3 = find(3);
    ASSERT_NE(f3, nullptr);
    EXPECT_EQ(f3->total_keys, 1u);
    EXPECT_EQ(f3->total_bytes, 70u);
    EXPECT_EQ(f3->live_keys, 0u);
}

TEST(KeyDir, MarkReadyChangesAcceptanceRule) {
    KeyDir kd;
    put_simple(kd, "k", 5, 100, /*sz*/ 50, /*ts*/ 10);
    kd.mark_ready();
    EXPECT_TRUE(kd.is_ready());
    auto r = kd.put("k", 3, 70, 0, 5, 0, false, 0, 0);
    EXPECT_EQ(r, PutResult::kAlreadyExists);
    auto info = kd.info();
    auto find = [&](std::uint32_t fid) -> const FStatsEntry* {
        for (auto& f : info.fstats) if (f.file_id == fid) return &f;
        return nullptr;
    };
    // File 3 must NOT have been created when ready and reject.
    EXPECT_EQ(find(3), nullptr);
}

TEST(KeyDir, NewestPutAcceptedWhenFileIdGteBiggest) {
    KeyDir kd;
    kd.increment_file_id_at_least(7);  // biggest = 7
    auto r = kd.put("k", 7, 100, 0, 5, 0, /*newest*/ true, 0, 0);
    EXPECT_EQ(r, PutResult::kOk);
    EXPECT_EQ(kd.get("k")->file_id, 7u);
}

TEST(KeyDir, NewestPutRejectedWhenFileIdLessThanBiggest) {
    KeyDir kd;
    kd.increment_file_id_at_least(7);  // biggest = 7
    // No prior key with this name; conditional put with old_file_id=0 still
    // hits the merge-race rule (file_id < biggest && newest_put).
    auto r = kd.put("k", 5, 100, 0, 5, 0, /*newest*/ true, 0, 0);
    EXPECT_EQ(r, PutResult::kAlreadyExists);
}

TEST(KeyDir, SetPendingDeleteSetsExpirationEpoch) {
    KeyDir kd;
    put_simple(kd, "k", 3, 0, /*sz*/ 100, /*ts*/ 1);
    const auto epoch_before = kd.get_epoch();
    kd.set_pending_delete(3);
    auto info = kd.info();
    auto find = [&](std::uint32_t fid) -> const FStatsEntry* {
        for (auto& f : info.fstats) if (f.file_id == fid) return &f;
        return nullptr;
    };
    auto* f = find(3);
    ASSERT_NE(f, nullptr);
    EXPECT_EQ(f->expiration_epoch, epoch_before);
}

TEST(KeyDir, TrimFstatsRemovesEntriesAndCountsMissing) {
    KeyDir kd;
    put_simple(kd, "a", 1, 0);
    put_simple(kd, "b", 2, 0);
    std::vector<std::uint32_t> ids = {1, 2, 99};
    auto missing = kd.trim_fstats(ids);
    EXPECT_EQ(missing, 1u);
    auto info = kd.info();
    EXPECT_TRUE(info.fstats.empty());
}

TEST(KeyDir, DeepCopyIsIndependent) {
    KeyDir kd;
    put_simple(kd, "k", 1, 0, /*sz*/ 50);
    auto copy = kd.deep_copy();

    EXPECT_TRUE(copy->get("k").has_value());
    EXPECT_EQ(copy->info().key_count, 1u);

    // Mutating the original must not affect the copy.
    EXPECT_TRUE(kd.remove("k", 0));
    EXPECT_FALSE(kd.get("k").has_value());
    EXPECT_TRUE(copy->get("k").has_value());
}

TEST(KeyDir, ConcurrentPutsAreSerialized) {
    KeyDir kd;
    constexpr int kThreads = 8;
    constexpr int kPerThread = 1000;

    std::vector<std::thread> ts;
    ts.reserve(kThreads);
    for (int t = 0; t < kThreads; ++t) {
        ts.emplace_back([t, &kd]() {
            for (int i = 0; i < kPerThread; ++i) {
                std::string k = "k_" + std::to_string(t) + "_" + std::to_string(i);
                put_simple(kd, k, /*fid*/ 1,
                           /*off*/ static_cast<std::uint64_t>(i),
                           /*sz*/ 10, /*ts*/ 1);
            }
        });
    }
    for (auto& th : ts) th.join();

    auto info = kd.info();
    EXPECT_EQ(info.key_count, static_cast<std::uint64_t>(kThreads * kPerThread));
    EXPECT_EQ(info.epoch,     static_cast<std::uint64_t>(kThreads * kPerThread));
}

TEST(KeyDir, BinaryKeyWithEmbeddedNul) {
    KeyDir kd;
    std::string key("a\0b\0c", 5);
    put_simple(kd, key, 1, 0);
    auto v = kd.get(key);
    ASSERT_TRUE(v);
    EXPECT_EQ(v->key.size(), 5u);
    EXPECT_EQ(std::string(v->key), key);
}
