// KeyDir micro-benchmarks. Targets the in-memory hash, not the data files.
//
// Workloads:
//   - Get_Single        : hot get, one thread, fully cached
//   - Get_MultiThreaded : hot get, N threads, validates the M5.3 shared_mutex
//                          claim (1.9× over std::mutex at 4 threads)
//   - Put_Overwrite     : put on existing key, single thread
//
// Run:  ./bitcask_bench --benchmark_filter=KeyDir
//       ./bitcask_bench --benchmark_format=json --benchmark_out=baseline.json

#include <benchmark/benchmark.h>

#include <random>
#include <string>
#include <vector>

#include "bitcask/keydir.hpp"

using bitcask::keydir::KeyDir;

namespace {

constexpr int kKeyspace = 1024;

std::vector<std::string> make_key_pool() {
    std::vector<std::string> pool;
    pool.reserve(kKeyspace);
    for (int i = 0; i < kKeyspace; ++i) {
        pool.push_back("k" + std::to_string(i));
    }
    return pool;
}

void populate(KeyDir& kd, const std::vector<std::string>& keys) {
    for (std::size_t i = 0; i < keys.size(); ++i) {
        kd.put(keys[i], 1, 100, static_cast<std::uint64_t>(i), 1, 0,
               /*newest*/ false, 0, 0);
    }
}

}  // namespace

// -----------------------------------------------------------------------------
// Single-threaded get. Each iteration picks a random key from a pre-built
// pool — no allocation in the hot loop, so we measure the lock + map::find,
// not malloc.
// -----------------------------------------------------------------------------
static void BM_KeyDir_Get_Single(benchmark::State& state) {
    KeyDir kd;
    auto keys = make_key_pool();
    populate(kd, keys);

    std::mt19937 rng(0xCAFE);
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

    for (auto _ : state) {
        const std::string& k = keys[static_cast<std::size_t>(dist(rng))];
        auto v = kd.get(k);
        benchmark::DoNotOptimize(v);
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_KeyDir_Get_Single);

// -----------------------------------------------------------------------------
// Multi-threaded get. Google Benchmark's Threads(n) runs the body across n
// threads sharing the State. The same KeyDir is fixtured across threads via
// a function-local static so SetUp work isn't repeated. Throughput numbers
// are aggregate across all threads.
// -----------------------------------------------------------------------------
static void BM_KeyDir_Get_MultiThreaded(benchmark::State& state) {
    // Fixture lives across all threads of a single benchmark run.
    static KeyDir kd;
    static std::vector<std::string> keys;
    static bool initialized = false;
    if (state.thread_index() == 0 && !initialized) {
        keys = make_key_pool();
        populate(kd, keys);
        initialized = true;
    }

    std::mt19937 rng(0xCAFE + static_cast<unsigned>(state.thread_index()));
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

    for (auto _ : state) {
        const std::string& k = keys[static_cast<std::size_t>(dist(rng))];
        auto v = kd.get(k);
        benchmark::DoNotOptimize(v);
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_KeyDir_Get_MultiThreaded)
    ->Threads(1)
    ->Threads(2)
    ->Threads(4)
    ->Threads(8);

// -----------------------------------------------------------------------------
// Overwriting put on an existing key. Exercises the path-2 branch of put()
// (live entry replace) which is the steady-state write workload for a
// busy bitcask.
// -----------------------------------------------------------------------------
static void BM_KeyDir_Put_Overwrite(benchmark::State& state) {
    KeyDir kd;
    auto keys = make_key_pool();
    populate(kd, keys);

    std::mt19937 rng(0xBEEF);
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);
    std::uint32_t fid = 1;

    for (auto _ : state) {
        const std::string& k = keys[static_cast<std::size_t>(dist(rng))];
        kd.put(k, fid, 200, /*offset*/ 0, /*tstamp*/ 1, /*now_sec*/ 0,
               /*newest*/ false, 0, 0);
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_KeyDir_Put_Overwrite);

// M6 验收护栏:多线程混合负载(每线程 90% get + 10% put 覆写)。
// 分片前的 before 数字 = 全局 shared_mutex 下写者互斥 + 读写互踩;
// 分片后预期按 shard 数接近线性,本基准是 M6 的合格线。
static void BM_KeyDir_Mixed_MultiThreaded(benchmark::State& state) {
    static KeyDir kd;
    static std::vector<std::string> keys = make_key_pool();
    if (state.thread_index() == 0) {
        populate(kd, keys);
    }
    std::mt19937 rng(0xC0FFEE + static_cast<unsigned>(state.thread_index()));
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);
    std::uniform_int_distribution<int> op(0, 9);

    for (auto _ : state) {
        const auto& k = keys[static_cast<std::size_t>(dist(rng))];
        if (op(rng) == 0) {
            kd.put(k, 1, 100, 0, 1, 0, /*newest*/ true, 0, 0);
        } else {
            benchmark::DoNotOptimize(kd.get(k));
        }
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_KeyDir_Mixed_MultiThreaded)
    ->Threads(1)->Threads(2)->Threads(4)->Threads(8)
    ->UseRealTime()
    ->Unit(benchmark::kNanosecond);
