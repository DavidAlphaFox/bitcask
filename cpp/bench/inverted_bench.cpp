// InvertedIndex 查询路径基准（P1 前置，见 doc/posting-zero-copy-design-zh.md §6）。
//
// Workloads:
//   - SearchHotTerm/N      : 单线程查 N-posting 热词。N=512 走标量路径，
//                            N≥1024 触发 Block-Max WAND（kWandThreshold）。
//                            P1 的主指标——当前每次查询深拷贝整个 PostingList。
//   - BoolMustHot          : 2 个 MUST 热词的 bool_search（交集路径）。
//   - SearchWhileIndexing  : 4 reader 并发查热词 × 1 writer 持续 add_doc。
//                            writer 写「轮换冷词」而非热词本身——热词 posting
//                            数在测量期间保持稳定（否则搜索成本随基准运行漂移，
//                            数字不可比）；本项测的是读写流水线干扰（分配器、
//                            cache、TBB），不是同桶锁竞争。
//
// Run:  ./bitcask_bench --benchmark_filter=Inverted
//       ./bitcask_bench --benchmark_filter=Inverted --benchmark_format=json \
//                       --benchmark_out=inverted_baseline.json

#include <benchmark/benchmark.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "bitcask/inverted.hpp"
#include "bitcask/query.hpp"

using bitcask::bm25::InvertedIndex;
using bitcask::bm25::LiveChecker;
using bitcask::bm25::TermPositions;

namespace {

// 全量存活、定长文档——LiveChecker 开销在 before/after 两侧恒定，
// 不影响对比（虚调用本身的优化是另一项，见审计 #4）。
class AllLiveChecker : public LiveChecker {
public:
    [[nodiscard]] bool is_live(std::uint64_t) const override { return true; }
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t) const override { return 8; }
};

TermPositions doc_with(const std::string& term) {
    // 每文档 8 token：热词 tf=2 带 2 个 position，填充词 tf=6。
    return {
        {term,     {2, {0, 4}}},
        {"filler", {6, {1, 2, 3, 5, 6, 7}}},
    };
}

// 构造含一个 n-posting 热词的索引（外加 filler 词制造真实词表形态）。
std::unique_ptr<InvertedIndex> build_index(std::size_t hot_postings) {
    auto idx = std::make_unique<InvertedIndex>();
    for (std::size_t i = 0; i < hot_postings; ++i) {
        idx->add_doc(static_cast<std::uint64_t>(i), doc_with("hot"));
    }
    return idx;
}

void BM_Inverted_SearchHotTerm(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto idx = build_index(n);
    AllLiveChecker live;

    for (auto _ : state) {
        auto results = idx->search({"hot"}, 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(n));
}
BENCHMARK(BM_Inverted_SearchHotTerm)->Arg(512)->Arg(4096)->Arg(100000)
    ->Unit(benchmark::kMicrosecond);

void BM_Inverted_BoolMustHot(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto idx = std::make_unique<InvertedIndex>();
    for (std::size_t i = 0; i < n; ++i) {
        idx->add_doc(static_cast<std::uint64_t>(i),
                     {{"alpha", {2, {0, 4}}}, {"beta", {2, {1, 5}}},
                      {"filler", {4, {2, 3, 6, 7}}}});
    }
    AllLiveChecker live;
    auto query = bitcask::bm25::QueryNode::must_all(
        {bitcask::bm25::QueryNode::must_term("alpha"),
         bitcask::bm25::QueryNode::must_term("beta")});

    for (auto _ : state) {
        auto results = idx->bool_search(query, 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(n));
}
BENCHMARK(BM_Inverted_BoolMustHot)->Arg(4096)->Arg(100000)
    ->Unit(benchmark::kMicrosecond);

// 多线程：thread 0 负责建索引 + 启动 writer（Google Benchmark 保证全部
// 线程在计时循环入口汇合，setup 先于其他线程的首次迭代）。
struct IndexingFixtureState {
    std::unique_ptr<InvertedIndex> idx;
    std::atomic<bool> stop{false};
    std::thread writer;
    std::atomic<std::uint64_t> next_ord{0};
};
IndexingFixtureState* g_fx = nullptr;

void BM_Inverted_SearchWhileIndexing(benchmark::State& state) {
    if (state.thread_index() == 0) {
        g_fx = new IndexingFixtureState();
        g_fx->idx = build_index(100000);
        g_fx->next_ord.store(200000);
        g_fx->writer = std::thread([] {
            // 轮换 1024 个冷词写入：不增长热词 posting（见文件头说明）。
            std::uint64_t i = 0;
            while (!g_fx->stop.load(std::memory_order_relaxed)) {
                auto ord = g_fx->next_ord.fetch_add(1, std::memory_order_relaxed);
                g_fx->idx->add_doc(ord,
                                   doc_with("cold" + std::to_string(i % 1024)));
                ++i;
            }
        });
    }

    AllLiveChecker live;
    for (auto _ : state) {
        auto results = g_fx->idx->search({"hot"}, 10, live);
        benchmark::DoNotOptimize(results);
    }

    if (state.thread_index() == 0) {
        g_fx->stop.store(true);
        g_fx->writer.join();
        delete g_fx;
        g_fx = nullptr;
    }
}
BENCHMARK(BM_Inverted_SearchWhileIndexing)->Threads(4)
    ->Unit(benchmark::kMicrosecond)->UseRealTime();

}  // namespace

// P2-min 基准：phrase 路径（唯一仍深拷贝 PostingList 的查询路径）。
// 每文档 "p0 p1" 相邻 → 短语全命中，posting 含 positions，深拷贝成本最大化。
void BM_Inverted_PhraseHotTerm(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto idx = std::make_unique<InvertedIndex>();
    for (std::size_t i = 0; i < n; ++i) {
        idx->add_doc(static_cast<std::uint64_t>(i),
                     {{"p0", {1, {0}}}, {"p1", {1, {1}}},
                      {"filler", {6, {2, 3, 4, 5, 6, 7}}}});
    }
    AllLiveChecker live;

    for (auto _ : state) {
        auto results = idx->search_phrase({"p0", "p1"}, 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(n));
}
BENCHMARK(BM_Inverted_PhraseHotTerm)->Arg(4096)->Arg(100000)
    ->Unit(benchmark::kMicrosecond);
