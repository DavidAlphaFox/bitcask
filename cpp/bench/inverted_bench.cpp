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

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <shared_mutex>
#include <span>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "bitcask/index.hpp"
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
    // P2.1：批量覆写（生产 Index 实现为持锁数组直读，这里等价的平价填充）。
    void fill_is_live(std::span<const std::uint64_t>,
                      std::span<char> out) const override {
        std::fill(out.begin(), out.end(), char{1});
    }
    void fill_doc_lens(std::span<const std::uint64_t>,
                       std::span<std::uint32_t> out) const override {
        std::fill(out.begin(), out.end(), 8U);
    }
};

// 模拟生产 Index 形态：is_live/doc_len 每次调用拿一次 shared_lock（与
// index.cpp 实现同构）。不覆写批量接口 → 默认回退逐条调用 = P2.1 之前的
// 生产成本形态。
class LockedScalarChecker : public LiveChecker {
public:
    explicit LockedScalarChecker(std::size_t n) : live_(n, 1), lens_(n, 8) {}
    [[nodiscard]] bool is_live(std::uint64_t o) const override {
        std::shared_lock lk(mu_);
        return o < live_.size() && live_[o];
    }
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t o) const override {
        std::shared_lock lk(mu_);
        return o < lens_.size() ? lens_[o] : 0;
    }

protected:
    mutable std::shared_mutex mu_;
    std::vector<char> live_;
    std::vector<std::uint32_t> lens_;
};

// 覆写批量接口：一次锁扫整列 = P2.1 之后的生产成本形态。
class LockedBatchChecker : public LockedScalarChecker {
public:
    using LockedScalarChecker::LockedScalarChecker;
    void fill_is_live(std::span<const std::uint64_t> ords,
                      std::span<char> out) const override {
        std::shared_lock lk(mu_);
        for (std::size_t i = 0; i < ords.size(); ++i) {
            out[i] = static_cast<char>(ords[i] < live_.size() && live_[ords[i]]);
        }
    }
    void fill_doc_lens(std::span<const std::uint64_t> ords,
                       std::span<std::uint32_t> out) const override {
        std::shared_lock lk(mu_);
        for (std::size_t i = 0; i < ords.size(); ++i) {
            out[i] = ords[i] < lens_.size() ? lens_[ords[i]] : 0;
        }
    }
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

// K1:3 个 MUST 热词——k-way leapfrog 路径(k≥3)。三词命中率
// 全/偶/3 的倍数,交集 = n/6,覆盖"被挡住 → 驱动游标跳跃"分支。
void BM_Inverted_BoolMustHot3(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto idx = std::make_unique<InvertedIndex>();
    for (std::size_t i = 0; i < n; ++i) {
        bitcask::bm25::TermPositions m;
        m.emplace("alpha", std::make_pair(2u, std::vector<std::uint32_t>{0, 4}));
        if (i % 2 == 0) {
            m.emplace("beta", std::make_pair(2u, std::vector<std::uint32_t>{1, 5}));
        }
        if (i % 3 == 0) {
            m.emplace("gamma", std::make_pair(1u, std::vector<std::uint32_t>{2}));
        }
        m.emplace("filler", std::make_pair(4u, std::vector<std::uint32_t>{3, 6}));
        idx->add_doc(static_cast<std::uint64_t>(i), m);
    }
    AllLiveChecker live;
    auto query = bitcask::bm25::QueryNode::must_all(
        {bitcask::bm25::QueryNode::must_term("alpha"),
         bitcask::bm25::QueryNode::must_term("beta"),
         bitcask::bm25::QueryNode::must_term("gamma")});

    for (auto _ : state) {
        auto results = idx->bool_search(query, 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(n));
}
BENCHMARK(BM_Inverted_BoolMustHot3)->Arg(4096)->Arg(100000)
    ->Unit(benchmark::kMicrosecond);

// B1 上界松弛度 canary:偏斜 tf + dl 一致数据。实测结论(2026-06-12):
// upper_bound_from 的 dl=1 假设带来 ~25% 固有松弛,dl 一致时高 tf 钉子
// 被 BM25 长度归一压平(tf=50 ⇒ dl≥50),θ≈真实最高分≈上界/1.25 →
// 剪枝不触发。本基准的意义:v5 块元数据若改存「量化块级最高分」
// (真实 tf+dl 计算),此数字应显著下降——它是 v5 收益的验收标尺。
// doc_len 与 add_doc 累计的 sum_doc_len 一致的 checker(AllLiveChecker
// 的硬编码 dl=8 与 avgdl≈2 自相矛盾,会把真实分数压到 dl=1 上界之下,
// 使剪枝假性失效)。
class VecLenChecker : public AllLiveChecker {
public:
    std::vector<std::uint32_t> lens;
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t ord) const override {
        return lens[static_cast<std::size_t>(ord)];
    }
    void fill_doc_lens(std::span<const std::uint64_t> ords,
                       std::span<std::uint32_t> out) const override {
        for (std::size_t i = 0; i < ords.size(); ++i) {
            out[i] = lens[static_cast<std::size_t>(ords[i])];
        }
    }
};

void BM_Inverted_BoolMustSkewed(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    auto idx = std::make_unique<InvertedIndex>();
    VecLenChecker live;
    live.lens.resize(n);
    for (std::size_t i = 0; i < n; ++i) {
        const std::uint32_t tf_a = (i % 997 == 0) ? 50 : 1;
        const std::uint32_t tf_b = (i % 991 == 0) ? 40 : 1;
        idx->add_doc(static_cast<std::uint64_t>(i),
                     {{"alpha", {tf_a, {0}}}, {"beta", {tf_b, {1}}}});
        live.lens[i] = tf_a + tf_b;  // = add_doc 累计的 doc_len
    }
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
BENCHMARK(BM_Inverted_BoolMustSkewed)->Arg(100000)
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

// P2.1 生产形态 A/B：同一查询代码，checker 决定 live/doc_len 是逐 posting
// 锁+虚调用（LockedScalar = P2.1 前形态）还是一次锁批量（LockedBatch）。
template <typename Checker>
void run_search_locked(benchmark::State& state) {
    auto idx = build_index(100000);
    Checker checker(200000);
    for (auto _ : state) {
        auto results = idx->search({"hot"}, 10, checker);
        benchmark::DoNotOptimize(results);
    }
}
void BM_Inverted_SearchLockedScalar(benchmark::State& state) {
    run_search_locked<LockedScalarChecker>(state);
}
void BM_Inverted_SearchLockedBatch(benchmark::State& state) {
    run_search_locked<LockedBatchChecker>(state);
}
BENCHMARK(BM_Inverted_SearchLockedScalar)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Inverted_SearchLockedBatch)->Unit(benchmark::kMicrosecond);

// fuzzy 热词：命中 10 万 posting 的 vocab term + 1024 个冷词（走 P2.1
// 向量化的两阶段评分块 + levenshtein 词典扫描）。
void BM_Inverted_FuzzyHot(benchmark::State& state) {
    auto idx = build_index(100000);
    for (std::uint64_t i = 0; i < 1024; ++i) {
        idx->add_doc(500000 + i, doc_with("cold" + std::to_string(i)));
    }
    AllLiveChecker live;
    for (auto _ : state) {
        auto results = idx->search_fuzzy({"hoot"}, 10, 1, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) * 100000);
}
BENCHMARK(BM_Inverted_FuzzyHot)->Unit(benchmark::kMicrosecond);

// P2.3 基准：大词典 fuzzy 扫描（20 万词表，d=2 → 长度剪枝放过大部分词，
// 编辑距离计算本体成为主导）。与 FuzzyHot（评分主导）互补。
void BM_Inverted_FuzzyVocabScan(benchmark::State& state) {
    auto idx = std::make_unique<InvertedIndex>();
    for (std::uint64_t i = 0; i < 200000; ++i) {
        idx->add_doc(i, {{"term" + std::to_string(i), {1, {0}}}});
    }
    AllLiveChecker live;
    for (auto _ : state) {
        auto results = idx->search_fuzzy({"term12345"}, 10, 2, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) * 200000);
}
BENCHMARK(BM_Inverted_FuzzyVocabScan)->Unit(benchmark::kMicrosecond);

// P2.4 基准：用真实 index::Index 做 LiveChecker。1M 文档登记侧表，
// 热词 posting 以步长 10 散布（10 万 posting 横跨 1M ord 空间）——
// fill_doc_lens 对 slots_（32B/项）做稀疏 gather，暴露 AoS 布局的
// cache line 浪费（每 64B 行只用 4B）。
void BM_Inverted_SearchIndexChecker(benchmark::State& state) {
    auto idx = std::make_unique<InvertedIndex>();
    bitcask::index::Index side;
    for (std::uint64_t ord = 0; ord < 1000000; ++ord) {
        side.put_doc("k" + std::to_string(ord), ord,
                     bitcask::index::DocSlot{{}, 0, 8, 0});
        if (ord % 10 == 0) {
            idx->add_doc(ord, doc_with("hot"));
        }
    }
    for (auto _ : state) {
        auto results = idx->search({"hot"}, 10, side);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) * 100000);
}
BENCHMARK(BM_Inverted_SearchIndexChecker)->Unit(benchmark::kMicrosecond);

// P2.5 基准：大词典 wildcard 扫描（20 万词表）。
void BM_Inverted_WildcardScan(benchmark::State& state) {
    auto idx = std::make_unique<InvertedIndex>();
    for (std::uint64_t i = 0; i < 200000; ++i) {
        idx->add_doc(i, {{"term" + std::to_string(i), {1, {0}}}});
    }
    AllLiveChecker live;
    for (auto _ : state) {
        auto results = idx->search_wildcard("term1234*", 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) * 200000);
}
BENCHMARK(BM_Inverted_WildcardScan)->Unit(benchmark::kMicrosecond);

// V6.5.1：中缀 wildcard 全扫基线（`*1234*` 模式，20 万词表）。
// V6.3.1 sorted vocab 已给 cache 局部性收益，但无法 binary search。
// 本基准为 suffix array / n-gram 索引优化的对照基线。
void BM_Inverted_WildcardInfixScan(benchmark::State& state) {
    auto idx = std::make_unique<InvertedIndex>();
    for (std::uint64_t i = 0; i < 200000; ++i) {
        idx->add_doc(i, {{"term" + std::to_string(i), {1, {0}}}});
    }
    AllLiveChecker live;
    for (auto _ : state) {
        auto results = idx->search_wildcard("*1234*", 10, live);
        benchmark::DoNotOptimize(results);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) * 200000);
}
BENCHMARK(BM_Inverted_WildcardInfixScan)->Unit(benchmark::kMicrosecond);
