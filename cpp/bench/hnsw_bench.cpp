// V3.7 基准:HNSW 纯内核(脱离 Cask 的 insert/search 矩阵)。
// 红线(hnsw-design §6):100k/ef64 查询 < 1ms;插入 > 2k/s(384d,本机)。
// 跑法:--benchmark_filter='BM_Hnsw' --benchmark_repetitions=3
//       --benchmark_report_aggregates_only=true(取 median 对账 baseline)。

#include <benchmark/benchmark.h>

#include <cmath>
#include <map>
#include <memory>
#include <random>
#include <span>
#include <vector>

#include <bitcask/hnsw.hpp>

namespace {

using bitcask::vec::HnswConfig;
using bitcask::vec::HnswIndex;
using bitcask::vec::HnswMetric;

constexpr std::size_t kDim = 384;

HnswConfig bench_cfg() {
    HnswConfig c;
    c.dim = kDim;
    c.metric = HnswMetric::kDot;  // M=16 / efC=200 / seed 取默认
    return c;
}

// 归一化随机高斯向量(纯随机高维是召回最坏形态,但作吞吐/延迟负载
// 正合适:无簇结构,导航跳数取上界一侧)。
std::vector<float> make_vecs(std::size_t n, std::uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> v(n * kDim);
    for (std::size_t i = 0; i < n; ++i) {
        float* p = &v[i * kDim];
        double sq = 0.0;
        for (std::size_t d = 0; d < kDim; ++d) {
            p[d] = nd(rng);
            sq += static_cast<double>(p[d]) * p[d];
        }
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        for (std::size_t d = 0; d < kDim; ++d) p[d] *= inv;
    }
    return v;
}

// 查询基准的共享图:按规模建一次,进程内复用(建 100k 图 ~分钟级,
// 不能进计时区也不该每个 ef 档重建)。
const HnswIndex& shared_graph(std::size_t n) {
    static std::map<std::size_t, std::unique_ptr<HnswIndex>> cache;
    auto& slot = cache[n];
    if (!slot) {
        slot = std::make_unique<HnswIndex>(bench_cfg());
        auto vs = make_vecs(n, 0xBC37);
        for (std::size_t i = 0; i < n; ++i) {
            slot->insert(i, std::span<const float>(&vs[i * kDim], kDim));
        }
    }
    return *slot;
}

}  // namespace

// 插入吞吐:每轮全新图重插 n 条(计时含图构建全程,items/s 即插入速率)。
static void BM_Hnsw_Insert(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto vs = make_vecs(n, 0xBC37);
    for (auto _ : state) {
        HnswIndex idx(bench_cfg());
        for (std::size_t i = 0; i < n; ++i) {
            idx.insert(i, std::span<const float>(&vs[i * kDim], kDim));
        }
        benchmark::DoNotOptimize(idx.size());
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(n));
}
BENCHMARK(BM_Hnsw_Insert)
    ->Arg(10000)
    ->Arg(100000)
    ->Unit(benchmark::kMillisecond)
    ->Iterations(1);

// 查询延迟:k=10,1000 条独立查询轮转(防单查询缓存驻留失真)。
// Args = {规模, ef}。
static void BM_Hnsw_Search(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    const auto ef = static_cast<std::size_t>(state.range(1));
    const HnswIndex& g = shared_graph(n);
    auto qs = make_vecs(1000, 0x9337);
    std::size_t qi = 0;
    for (auto _ : state) {
        auto hits = g.search(
            std::span<const float>(&qs[(qi++ % 1000) * kDim], kDim), 10, ef);
        benchmark::DoNotOptimize(hits);
    }
}
BENCHMARK(BM_Hnsw_Search)
    ->Args({10000, 64})
    ->Args({10000, 256})
    ->Args({100000, 64})
    ->Args({100000, 256})
    ->Unit(benchmark::kMicrosecond);
