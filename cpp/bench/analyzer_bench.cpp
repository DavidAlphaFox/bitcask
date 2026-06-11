// 分词/文本层基准（P2.5 前置：先量化 nfkc_fold / to_codepoints 在
// analyze 中的占比，再决定是否引 simdutf）。
//
// Run: ./bitcask_bench --benchmark_filter=Text

#include <benchmark/benchmark.h>

#include <memory>
#include <string>

#include "bitcask/analyzer.hpp"
#include "bitcask/text_utils.hpp"

using namespace bitcask::text;

namespace {

// 代表性文本：拉丁 ~1KB / CJK ~1KB / 混合。
std::string latin_text() {
    std::string t;
    while (t.size() < 1024) {
        t += "the quick brown fox jumps over the lazy dog and searches engines ";
    }
    return t;
}
std::string cjk_text() {
    std::string t;
    while (t.size() < 1024) {
        t += "北京市朝阳区的搜索引擎正在对中文文本进行分词处理，";
    }
    return t;
}
// P2.5b 目标语料：中文 + 半角英文/数字/标点（无全角标点）。
std::string cjk_halfwidth_text() {
    std::string t;
    while (t.size() < 1024) {
        t += "北京市朝阳区的搜索引擎对bitcask引擎进行GPU加速测试, 性能提升明显. ";
    }
    return t;
}
std::string mixed_text() {
    std::string t;
    while (t.size() < 1024) {
        t += "bitcask 引擎 supports 中英 mixed 文本 tokenization 流程，";
    }
    return t;
}

void bench_analyze(benchmark::State& state, AnalyzerType type, std::string text) {
    AnalyzerConfig cfg;
    cfg.type = type;
    auto analyzer = AnalyzerFactory::create(cfg);
    for (auto _ : state) {
        auto r = analyzer->analyze_with_positions(text);
        benchmark::DoNotOptimize(r);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(text.size()));
}

void BM_Text_AnalyzeWhitespaceLatin(benchmark::State& s) {
    bench_analyze(s, AnalyzerType::Whitespace, latin_text());
}
void BM_Text_AnalyzeNgramCjk(benchmark::State& s) {
    bench_analyze(s, AnalyzerType::Ngram, cjk_text());
}
void BM_Text_AnalyzeNgramMixed(benchmark::State& s) {
    bench_analyze(s, AnalyzerType::Ngram, mixed_text());
}
BENCHMARK(BM_Text_AnalyzeWhitespaceLatin)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_AnalyzeNgramCjk)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_AnalyzeNgramMixed)->Unit(benchmark::kMicrosecond);

// 组件分解：归一化与解码各占多少。
void BM_Text_NfkcFoldLatin(benchmark::State& s) {
    auto t = latin_text();
    for (auto _ : s) {
        auto r = detail::nfkc_fold(t);
        benchmark::DoNotOptimize(r);
    }
    s.SetBytesProcessed(static_cast<std::int64_t>(s.iterations()) *
                        static_cast<std::int64_t>(t.size()));
}
void BM_Text_NfkcFoldCjkHalfwidth(benchmark::State& s) {
    auto t = cjk_halfwidth_text();
    for (auto _ : s) {
        auto r = detail::nfkc_fold(t);
        benchmark::DoNotOptimize(r);
    }
    s.SetBytesProcessed(static_cast<std::int64_t>(s.iterations()) *
                        static_cast<std::int64_t>(t.size()));
}
void BM_Text_AnalyzeNgramCjkHalfwidth(benchmark::State& s) {
    bench_analyze(s, AnalyzerType::Ngram, cjk_halfwidth_text());
}
void BM_Text_NfkcFoldCjk(benchmark::State& s) {
    auto t = cjk_text();
    for (auto _ : s) {
        auto r = detail::nfkc_fold(t);
        benchmark::DoNotOptimize(r);
    }
    s.SetBytesProcessed(static_cast<std::int64_t>(s.iterations()) *
                        static_cast<std::int64_t>(t.size()));
}
void BM_Text_ToCodepointsLatin(benchmark::State& s) {
    auto t = latin_text();
    for (auto _ : s) {
        auto r = detail::to_codepoints(t);
        benchmark::DoNotOptimize(r);
    }
    s.SetBytesProcessed(static_cast<std::int64_t>(s.iterations()) *
                        static_cast<std::int64_t>(t.size()));
}
void BM_Text_ToCodepointsCjk(benchmark::State& s) {
    auto t = cjk_text();
    for (auto _ : s) {
        auto r = detail::to_codepoints(t);
        benchmark::DoNotOptimize(r);
    }
    s.SetBytesProcessed(static_cast<std::int64_t>(s.iterations()) *
                        static_cast<std::int64_t>(t.size()));
}
BENCHMARK(BM_Text_NfkcFoldCjkHalfwidth)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_AnalyzeNgramCjkHalfwidth)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_NfkcFoldLatin)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_NfkcFoldCjk)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_ToCodepointsLatin)->Unit(benchmark::kMicrosecond);
BENCHMARK(BM_Text_ToCodepointsCjk)->Unit(benchmark::kMicrosecond);

}  // namespace
