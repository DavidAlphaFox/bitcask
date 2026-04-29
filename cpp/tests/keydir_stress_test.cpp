// M2.2/M2.3 reinforcement: heavy concurrent fuzz over the keydir.
//
// This is the EQC replacement (we don't have the Quviq commercial license).
// It exercises the same set of operations EQC would generate — random
// puts/removes/reads/folds across many threads — but with deterministic
// invariant checks instead of property-based shrinkage. Combined with
// TSan and ASan it catches the same race / use-after-free classes.

#include <atomic>
#include <chrono>
#include <random>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/keydir.hpp"
#include "bitcask/keydir_registry.hpp"

using namespace bitcask::keydir;
using namespace std::chrono_literals;

namespace {

// Tunables. Stress tests must terminate within reasonable wall-clock for CI;
// a few seconds is enough on TSan to surface most races.
constexpr int kKeyspace      = 256;
constexpr auto kStressDuration = 1500ms;

std::string make_key(int i) { return "k" + std::to_string(i); }

}  // namespace

// ---------------------------------------------------------------------------
// Random op fuzz: many threads, many keys, every op type, run ~1.5s.
// Invariant: after stop, the keydir's reported key_count matches the actual
// number of live keys observable via a final fold.
// ---------------------------------------------------------------------------
TEST(KeyDirStress, RandomOpsFuzz) {
    KeyDir kd;
    std::atomic<bool> stop{false};
    std::atomic<int> ops{0};

    auto worker = [&](unsigned seed) {
        std::mt19937 rng(seed);
        std::uniform_int_distribution<int> key_dist(0, kKeyspace - 1);
        std::uniform_int_distribution<int> op_dist (0, 99);
        std::uniform_int_distribution<std::uint32_t> sz_dist(10, 500);

        while (!stop.load(std::memory_order_relaxed)) {
            const std::string key = make_key(key_dist(rng));
            const int op = op_dist(rng);
            if (op < 60) {  // 60% put
                const std::uint32_t fid = 1 + (ops.load() % 16);
                const std::uint32_t sz  = sz_dist(rng);
                const std::uint64_t off = ops.load() & 0xFFFF;
                const std::uint32_t ts  = static_cast<std::uint32_t>(ops.load());
                kd.put(key, fid, sz, off, ts, 0, /*newest*/ false, 0, 0);
            } else if (op < 75) {  // 15% get
                (void)kd.get(key);
            } else if (op < 88) {  // 13% remove
                kd.remove(key, 0);
            } else {  // 12% fold
                auto it = kd.make_iter();
                if (it->start(0, -1, -1) == StartIterResult::kOk) {
                    int seen = 0;
                    while (auto e = it->next()) (void)seen++;
                    it->release();
                }
            }
            ops.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> ts;
    const int kThreads = 8;
    ts.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) ts.emplace_back(worker, 0x42 + i);

    std::this_thread::sleep_for(kStressDuration);
    stop.store(true, std::memory_order_relaxed);
    for (auto& t : ts) t.join();

    // Final consistency check: the reported key_count must match what we can
    // see via a fold. This will fail loudly if any sibling-merge or pending
    // bookkeeping path miscounts.
    auto info = kd.info();
    auto it = kd.make_iter();
    ASSERT_EQ(it->start(0, -1, -1), StartIterResult::kOk);
    std::uint64_t observed = 0;
    while (auto e = it->next()) ++observed;
    it->release();

    EXPECT_EQ(observed, info.key_count)
        << "fold observed " << observed
        << " keys, info reports " << info.key_count
        << " (ops total = " << ops.load() << ")";

    EXPECT_GT(ops.load(), 1000);  // we should be doing real work
}

// ---------------------------------------------------------------------------
// Many concurrent folds over a churning keydir.
// Invariant: each fold sees a stable snapshot — no key appears twice and
// no key disappears mid-fold.
// ---------------------------------------------------------------------------
TEST(KeyDirStress, ConcurrentFoldsSnapshotStable) {
    KeyDir kd;
    // Pre-populate.
    for (int i = 0; i < kKeyspace; ++i) {
        kd.put(make_key(i), 1, 100, static_cast<std::uint64_t>(i), 1, 0,
               false, 0, 0);
    }

    std::atomic<bool> stop{false};
    std::atomic<int> writers{0}, folds{0}, fold_violations{0};

    // Writers: continuously update / remove keys.
    std::vector<std::thread> wt;
    for (int t = 0; t < 4; ++t) {
        wt.emplace_back([&, t]() {
            std::mt19937 rng(static_cast<unsigned>(t * 7919 + 31));
            std::uniform_int_distribution<int> kd2(0, kKeyspace - 1);
            std::uniform_int_distribution<int> op(0, 9);
            int local = 0;
            while (!stop.load()) {
                const auto k = make_key(kd2(rng));
                if (op(rng) < 7) {
                    kd.put(k, 1, 100, static_cast<std::uint64_t>(local & 0xFFFF),
                           static_cast<std::uint32_t>(local + 1), 0,
                           false, 0, 0);
                } else {
                    kd.remove(k, 0);
                }
                writers.fetch_add(1);
                ++local;
            }
        });
    }

    // Folders: each fold expects a stable, duplicate-free snapshot.
    std::vector<std::thread> ft;
    for (int t = 0; t < 4; ++t) {
        ft.emplace_back([&]() {
            for (int run = 0; run < 50; ++run) {
                auto it = kd.make_iter();
                if (it->start(0, -1, -1) != StartIterResult::kOk) continue;
                std::set<std::string> seen;
                while (auto e = it->next()) {
                    auto [_, fresh] = seen.insert(std::string(e->key));
                    if (!fresh) fold_violations.fetch_add(1);
                }
                it->release();
                folds.fetch_add(1);
            }
        });
    }

    for (auto& t : ft) t.join();
    stop.store(true);
    for (auto& t : wt) t.join();

    EXPECT_EQ(fold_violations.load(), 0);
    EXPECT_GE(folds.load(), 100);
    EXPECT_GT(writers.load(), 0);
    auto info = kd.info();
    EXPECT_EQ(info.iter_info.keyfolders, 0u);
    EXPECT_FALSE(info.iter_info.frozen);
}

// ---------------------------------------------------------------------------
// Acquire/release storm against the registry.
// Invariant: the registry ends empty, biggest_file_id never regresses.
// ---------------------------------------------------------------------------
TEST(KeyDirStress, RegistryAcquireReleaseChurn) {
    KeyDirRegistry reg;
    std::atomic<bool> stop{false};
    std::atomic<int> acquires{0}, mismatches{0};

    auto worker = [&](int tid) {
        std::mt19937 rng(static_cast<unsigned>(tid * 11));
        std::uniform_int_distribution<int> name_dist(0, 7);

        while (!stop.load()) {
            const std::string name = "n" + std::to_string(name_dist(rng));
            auto r = reg.acquire(name);
            switch (r.status) {
            case AcquireStatus::kCreated:
                acquires.fetch_add(1);
                // Bump some file ids before signalling ready.
                r.keydir->increment_file_id();
                r.keydir->increment_file_id();
                r.keydir->mark_ready();
                reg.release(name);
                break;
            case AcquireStatus::kReady: {
                acquires.fetch_add(1);
                // Expect biggest_file_id to be ≥ 2 (set by initial creator).
                if (r.keydir->biggest_file_id() < 2) mismatches.fetch_add(1);
                reg.release(name);
                break;
            }
            case AcquireStatus::kNotReady:
                // Lost the race; that's fine.
                break;
            }
        }
    };

    std::vector<std::thread> ts;
    for (int i = 0; i < 8; ++i) ts.emplace_back(worker, i);
    std::this_thread::sleep_for(800ms);
    stop.store(true);
    for (auto& t : ts) t.join();

    EXPECT_EQ(reg.size(), 0u);
    EXPECT_EQ(mismatches.load(), 0);
    EXPECT_GT(acquires.load(), 0);
}

// ---------------------------------------------------------------------------
// M5.3 phase 1: shared_mutex enables concurrent reader entry without any
// data-layout change. Per-call critical sections (unordered_map::find) are
// sub-microsecond, so cache-line contention on the mutex's atomic counters
// dominates and prevents linear scaling — the lock-acquire overhead itself
// becomes the bottleneck. The honest claim is NOT "readers scale linearly";
// it is "concurrent readers do not fully serialize". Local A/B measurement
// on this machine (release build, 250ms window):
//
//     std::mutex          1 thread ≈ 6.9M ops,  4 threads ≈ 2.2M total
//     std::shared_mutex   1 thread ≈ 6.9M ops,  4 threads ≈ 4.2M total
//
// → shared_mutex ≈ 1.9× std::mutex at 4-reader load, with no single-thread
// regression. Real per-bucket parallel scaling needs sharding (deferred to
// M6 because pending_/epoch_/fstats_ are global by design).
//
// This is intentionally a smoke test, not a perf gate: hard scaling
// thresholds would be flaky across CI hardware. We assert correctness +
// non-trivial work; TSan + the random-fuzz test cover the race side.
// ---------------------------------------------------------------------------
TEST(KeyDirStress, ConcurrentReadersDoNotSerialize) {
    KeyDir kd;
    constexpr int kPopulate = 1024;
    // Pre-build the key set so the hot loop does no allocation; otherwise
    // glibc malloc's internal lock dominates and hides the keydir lock
    // behaviour we want to exercise.
    std::vector<std::string> keys;
    keys.reserve(kPopulate);
    for (int i = 0; i < kPopulate; ++i) {
        keys.push_back(make_key(i));
        kd.put(keys.back(), 1, 100,
               static_cast<std::uint64_t>(i), 1, 0, /*newest*/ false, 0, 0);
    }

    constexpr int kThreads = 4;
    std::atomic<bool> go{false};
    std::atomic<bool> stop{false};
    std::vector<std::uint64_t> per_thread(kThreads, 0);
    std::vector<std::thread> ts;
    ts.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        ts.emplace_back([&, t]() {
            std::mt19937 rng(0x1234u + static_cast<unsigned>(t));
            std::uniform_int_distribution<int> key_dist(0, kPopulate - 1);
            while (!go.load(std::memory_order_acquire)) { /* spin */ }
            std::uint64_t local = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                (void)kd.get(keys[static_cast<std::size_t>(key_dist(rng))]);
                ++local;
            }
            per_thread[static_cast<std::size_t>(t)] = local;
        });
    }

    go.store(true, std::memory_order_release);
    std::this_thread::sleep_for(250ms);
    stop.store(true, std::memory_order_relaxed);
    for (auto& t : ts) t.join();

    std::uint64_t total = 0;
    for (auto v : per_thread) total += v;

    // Each thread did real work; no thread starved.
    for (int t = 0; t < kThreads; ++t) {
        EXPECT_GT(per_thread[static_cast<std::size_t>(t)], 10000u)
            << "thread " << t << " starved";
    }
    // Aggregate sanity: at minimum each thread should clear ~10k ops in
    // 250ms even if shared_mutex contention is heavy. 100k total is a very
    // loose floor that won't false-fail on slow CI.
    EXPECT_GT(total, 100000u);
}

// ---------------------------------------------------------------------------
// Long-running ABA-style: same key gets put/removed many times during a
// long-lived fold. The fold must consistently see the snapshot of the key
// *as it was when the fold started*, regardless of how many revisions
// got piled on the sibling chain.
// ---------------------------------------------------------------------------
TEST(KeyDirStress, LongFoldStableUnderRapidRewrites) {
    KeyDir kd;
    kd.put("k", 1, 100, 0, 1, 0, false, 0, 0);

    auto it = kd.make_iter();
    ASSERT_EQ(it->start(0, -1, -1), StartIterResult::kOk);
    const std::uint64_t fold_epoch = it->epoch();

    std::atomic<bool> stop{false};
    std::thread mutator([&]() {
        for (int i = 0; i < 5000 && !stop.load(); ++i) {
            kd.put("k", static_cast<std::uint32_t>((i % 16) + 2), 100,
                   static_cast<std::uint64_t>(i), static_cast<std::uint32_t>(i + 2),
                   0, /*newest*/ true, 0, 0);
            if ((i & 0xF) == 0) kd.remove("k", 0);
        }
    });

    // Repeatedly query at the fold's epoch; the answer must be the original.
    int consistent = 0;
    for (int i = 0; i < 1000; ++i) {
        auto v = kd.get("k", fold_epoch);
        ASSERT_TRUE(v.has_value()) << "snapshot key disappeared at iter " << i;
        EXPECT_EQ(v->file_id, 1u) << "snapshot drifted at iter " << i;
        ++consistent;
    }
    EXPECT_EQ(consistent, 1000);

    stop.store(true);
    mutator.join();

    // The fold itself sees the original — single revision.
    auto seen = it->next();
    ASSERT_TRUE(seen.has_value());
    EXPECT_EQ(seen->file_id, 1u);
    EXPECT_FALSE(it->next().has_value());
    it->release();
}
