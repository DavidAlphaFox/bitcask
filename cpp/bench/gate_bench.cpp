// P7/P12 gate benchmarks.
//
// P7: Is derive cost (nfkc_fold + analyze_with_offsets / dequant) >> mmap read?
//     If yes → compute cache (P7) worth building.
// P12: How much memory does meta_blobs_ use, and what's access latency?
//      If significant → bounded LRU worth building.
//
// Run: ./bitcask_bench --benchmark_filter=P7
// Run: ./bitcask_bench --benchmark_filter=P12

#include <benchmark/benchmark.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <random>
#include <string>
#include <unistd.h>
#include <vector>

#include "bitcask/analyzer.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/detail/int8_kernels.hpp"
#include "bitcask/highlighter.hpp"
#include "bitcask/index.hpp"
#include "bitcask/search_layer.hpp"
#include "bitcask/text_utils.hpp"

namespace fs = std::filesystem;
using bitcask::Cask;
using bitcask::CaskOptions;
using namespace bitcask::text;
using namespace bitcask::search;

// ============================================================================
// Shared helpers
// ============================================================================

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_gate_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string path() const { return path_.string(); }
private:
    fs::path path_;
};

std::span<const std::byte> as_bytes(const std::string& s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

std::string make_latin_text(std::size_t target_sz) {
    std::string t;
    while (t.size() < target_sz) {
        t += "the quick brown fox jumps over the lazy dog and search engines ";
    }
    return t.substr(0, target_sz);
}

std::string make_mixed_text(std::size_t target_sz) {
    std::string t;
    while (t.size() < target_sz) {
        t += "bitcask 引擎 supports 中英 mixed 文本 tokenization 流程 ";
    }
    return t.substr(0, target_sz);
}

std::size_t read_rss_kb() {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
        if (line.starts_with("VmRSS:")) {
            std::size_t val = 0;
            std::sscanf(line.c_str(), "VmRSS: %zu kB", &val);
            return val;
        }
    }
    return 0;
}

}  // namespace

// ============================================================================
// P7 Gate: Compute Cache Derive Cost
// ============================================================================

// ---- Component: analyze_with_offsets (highlight-specific derive path) -------

static void BM_P7_AnalyzeWithOffsets_Latin1K(benchmark::State& state) {
    AnalyzerConfig cfg;
    cfg.type = AnalyzerType::Whitespace;
    auto analyzer = AnalyzerFactory::create(cfg);
    auto text = make_latin_text(1024);
    for (auto _ : state) {
        auto r = analyzer->analyze_with_offsets(text);
        benchmark::DoNotOptimize(r);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations()) * 1024);
}
BENCHMARK(BM_P7_AnalyzeWithOffsets_Latin1K)->Unit(benchmark::kMicrosecond);

static void BM_P7_AnalyzeWithOffsets_Mixed1K(benchmark::State& state) {
    AnalyzerConfig cfg;
    cfg.type = AnalyzerType::Ngram;
    auto analyzer = AnalyzerFactory::create(cfg);
    auto text = make_mixed_text(1024);
    for (auto _ : state) {
        auto r = analyzer->analyze_with_offsets(text);
        benchmark::DoNotOptimize(r);
    }
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * 1024);
}
BENCHMARK(BM_P7_AnalyzeWithOffsets_Mixed1K)->Unit(benchmark::kMicrosecond);

// ---- Component: highlight() algorithm (offsets pre-computed) ----------------

static void BM_P7_HighlightAlgo_1K(benchmark::State& state) {
    auto text = make_latin_text(1024);

    // Pre-compute token offsets (simulate what search_text_highlight does
    // after nfkc_fold + analyze_with_offsets).
    AnalyzerConfig cfg;
    cfg.type = AnalyzerType::Whitespace;
    auto analyzer = AnalyzerFactory::create(cfg);
    auto token_offsets = analyzer->analyze_with_offsets(text);

    // Pick a few query terms that exist in the text.
    std::unordered_map<std::string, std::vector<TokenInfo>> query_tokens;
    for (auto& [term, infos] : token_offsets) {
        if (term == "the" || term == "fox" || term == "search") {
            query_tokens[term] = infos;
        }
        if (query_tokens.size() >= 3) break;
    }

    HighlightOptions opts;
    for (auto _ : state) {
        auto r = highlight(text, query_tokens, opts);
        benchmark::DoNotOptimize(r);
    }
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * 1024);
}
BENCHMARK(BM_P7_HighlightAlgo_1K)->Unit(benchmark::kMicrosecond);

// ---- Component: int8→f32 dequant (vector derive cost) ----------------------

static void BM_P7_Dequant(benchmark::State& state) {
    const auto dim = static_cast<std::size_t>(state.range(0));

    // Build a realistic QVector.
    std::mt19937 rng(0xDEAD);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> raw(dim);
    float max_abs = 0.0f;
    for (auto& x : raw) {
        x = nd(rng);
        if (std::abs(x) > max_abs) max_abs = std::abs(x);
    }
    if (max_abs == 0.0f) max_abs = 1.0f;

    bitcask::vec::int8::QVector qv;
    qv.codes.resize(dim);
    qv.scale = max_abs;
    std::int32_t sum = 0;
    for (std::size_t i = 0; i < dim; ++i) {
        auto c = static_cast<int>(std::round(raw[i] / max_abs * 127.0f));
        c = std::clamp(c, -127, 127);
        qv.codes[i] = static_cast<std::int8_t>(c);
        sum += c;
    }
    qv.sum_codes = sum;

    std::vector<float> out(dim);
    for (auto _ : state) {
        bitcask::vec::int8::dequantize(qv, out.data(), dim);
        benchmark::DoNotOptimize(out);
    }
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) *
                            static_cast<int64_t>(dim * 4));
}
BENCHMARK(BM_P7_Dequant)
    ->Arg(384)->Arg(768)->Arg(1536)->Arg(2560)
    ->Unit(benchmark::kNanosecond);

// ---- Component: DocTextLru hit (compute cache proxy) -----------------------

static void BM_P7_DocTextLruHit(benchmark::State& state) {
    const auto n_docs = static_cast<std::size_t>(state.range(0));
    TempDir td;

    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sc;
    sc.analyzer_config.type = AnalyzerType::Whitespace;
    sc.doc_text_cache_max = n_docs;
    opts.search_config = sc;

    auto c = Cask::open(td.path(), opts);
    if (!c) { state.SkipWithError("open failed"); return; }
    auto& cask = **c;

    for (std::size_t i = 0; i < n_docs; ++i) {
        std::string key = "k" + std::to_string(i);
        std::string text = make_latin_text(256);
        cask.put(as_bytes(key), as_bytes(text));
    }
    cask.flush_index();

    auto* sl = cask.search();
    if (!sl) { state.SkipWithError("no search layer"); return; }

    // Warm DocTextLru: one search per doc populates text cache.
    for (std::size_t i = 0; i < n_docs; ++i) {
        std::string key = "k" + std::to_string(i);
        (void)sl->search_text_highlight(key, 1);
    }

    std::mt19937 rng(42);
    std::uniform_int_distribution<std::size_t> dist(0, n_docs - 1);

    for (auto _ : state) {
        auto key = "k" + std::to_string(dist(rng));
        auto r = sl->search_text_highlight(key, 1);
        benchmark::DoNotOptimize(r);
    }
    cask.close();
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_P7_DocTextLruHit)
    ->Arg(64)->Arg(256)->Arg(1024)
    ->Unit(benchmark::kMicrosecond);

// ---- End-to-end: search_text_highlight (warm DocTextLru) -------------------

static void BM_P7_SearchHighlightE2E_Warm(benchmark::State& state) {
    TempDir td;

    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sc;
    sc.analyzer_config.type = AnalyzerType::Whitespace;
    sc.doc_text_cache_max = 1024;
    opts.search_config = sc;

    auto c = Cask::open(td.path(), opts);
    if (!c) { state.SkipWithError("open failed"); return; }
    auto& cask = **c;

    // Populate 2K docs with 256B text each.
    constexpr int kDocs = 2000;
    for (int i = 0; i < kDocs; ++i) {
        std::string key = "doc" + std::to_string(i);
        std::string text = make_latin_text(256);
        auto r = cask.put(as_bytes(key), as_bytes(text));
        if (!r) { state.SkipWithError("put failed"); return; }
    }
    cask.flush_index();
    cask.close();

    // Reopen — sealed files → mmap active, DocTextLru empty.
    auto c2 = Cask::open(td.path(), opts);
    if (!c2) { state.SkipWithError("reopen failed"); return; }
    auto& cask2 = **c2;

    auto* sl = cask2.search();
    if (!sl) { state.SkipWithError("no search layer"); return; }

    // Warm up: one search to populate DocTextLru for matching docs.
    (void)sl->search_text_highlight("fox", 10);

    std::mt19937 rng(0xBEEF);
    for (auto _ : state) {
        auto i = rng() % kDocs;
        std::string q = (i % 3 == 0) ? "fox" : (i % 3 == 1) ? "the" : "search";
        auto r = sl->search_text_highlight(q, 10);
        benchmark::DoNotOptimize(r);
    }
    cask2.close();
}
BENCHMARK(BM_P7_SearchHighlightE2E_Warm)->Unit(benchmark::kMicrosecond);

// ---- Baseline: cask.get() DocValue text (mmap read cost, no derive) --------

static void BM_P7_CaskGet_DocValueText(benchmark::State& state) {
    TempDir td;

    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sc;
    sc.analyzer_config.type = AnalyzerType::Whitespace;
    opts.search_config = sc;

    auto c = Cask::open(td.path(), opts);
    if (!c) { state.SkipWithError("open failed"); return; }
    auto& cask = **c;

    constexpr int kDocs = 1024;
    for (int i = 0; i < kDocs; ++i) {
        std::string key = "k" + std::to_string(i);
        std::string val(256, 'v');
        cask.put(as_bytes(key), as_bytes(val));
    }
    cask.close();

    // Reopen → sealed files → mmap path.
    auto c2 = Cask::open(td.path(), opts);
    if (!c2) { state.SkipWithError("reopen failed"); return; }
    auto& cask2 = **c2;

    std::mt19937 rng(0xCAFE);
    std::uniform_int_distribution<int> dist(0, kDocs - 1);

    for (auto _ : state) {
        auto key = "k" + std::to_string(dist(rng));
        auto r = cask2.get(as_bytes(key));
        benchmark::DoNotOptimize(r);
    }
    cask2.close();
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(static_cast<int64_t>(state.iterations()) * 256);
}
BENCHMARK(BM_P7_CaskGet_DocValueText)->Unit(benchmark::kNanosecond);

// ---- Baseline: cask.get() quantized vector (mmap + dequant) ----------------

static void BM_P7_CaskGet_QuantizedVec(benchmark::State& state) {
    const auto dim = static_cast<std::uint16_t>(state.range(0));
    TempDir td;

    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    opts.vector_dim = dim;
    opts.vector_quantized = true;
    SearchLayerConfig sc;
    sc.analyzer_config.type = AnalyzerType::Whitespace;
    sc.vector_dim = dim;
    opts.search_config = sc;

    auto c = Cask::open(td.path(), opts);
    if (!c) { state.SkipWithError("open failed"); return; }
    auto& cask = **c;

    constexpr int kDocs = 512;
    std::mt19937 rng(0xBEEF);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> v(dim);
    for (int i = 0; i < kDocs; ++i) {
        std::string key = "k" + std::to_string(i);
        double sq = 0.0;
        for (int d = 0; d < dim; ++d) { v[d] = nd(rng); sq += (double)v[d] * v[d]; }
        float inv = 1.0f / std::sqrt((float)sq);
        for (auto& x : v) x *= inv;

        bitcask::DocInput doc;
        std::string text = "doc " + std::to_string(i);
        doc.text = as_bytes(text);
        doc.vector = std::span<const float>(v.data(), dim);
        cask.put_doc(as_bytes(key), doc);
    }
    cask.flush_index();
    cask.close();

    // Reopen → sealed files → mmap path + dequant on get.
    auto c2 = Cask::open(td.path(), opts);
    if (!c2) { state.SkipWithError("reopen failed"); return; }
    auto& cask2 = **c2;

    std::uniform_int_distribution<int> dist(0, kDocs - 1);
    for (auto _ : state) {
        auto key = "k" + std::to_string(dist(rng));
        auto r = cask2.get(as_bytes(key));
        benchmark::DoNotOptimize(r);
    }
    cask2.close();
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_P7_CaskGet_QuantizedVec)
    ->Arg(384)->Arg(2560)
    ->Unit(benchmark::kMicrosecond);

// ============================================================================
// P12 Gate: meta_blobs_ Memory + Access Latency
// ============================================================================

// ---- Access latency: Index::meta_blob(ord) ---------------------------------

static void BM_P12_MetaBlobAccess(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    const auto blob_sz = static_cast<std::size_t>(state.range(1));

    bitcask::index::Index idx;
    std::vector<std::byte> blob(blob_sz, std::byte{0xAB});
    for (std::size_t i = 0; i < n; ++i) {
        idx.set_meta(i, std::span<const std::byte>(blob.data(), blob_sz));
    }

    std::mt19937 rng(42);
    std::uniform_int_distribution<std::size_t> dist(0, n - 1);

    for (auto _ : state) {
        auto r = idx.meta_blob(dist(rng));
        benchmark::DoNotOptimize(r);
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_P12_MetaBlobAccess)
    ->ArgsProduct({
        {10000, 100000, 1000000},
        {64, 256}
    })
    ->Unit(benchmark::kNanosecond);

// ---- Memory footprint: RSS delta from meta_blobs_ --------------------------

static void BM_P12_MetaBlobFootprint(benchmark::State& state) {
    const auto n = static_cast<std::size_t>(state.range(0));
    const auto blob_sz = static_cast<std::size_t>(state.range(1));

    for (auto _ : state) {
        state.PauseTiming();
        auto rss_before = read_rss_kb();
        state.ResumeTiming();

        bitcask::index::Index idx;
        std::vector<std::byte> blob(blob_sz, std::byte{0xAB});
        for (std::size_t i = 0; i < n; ++i) {
            idx.set_meta(i, std::span<const std::byte>(blob.data(), blob_sz));
        }

        state.PauseTiming();
        auto rss_after = read_rss_kb();
        state.ResumeTiming();

        // Prevent optimizer from removing idx.
        benchmark::DoNotOptimize(idx);

        state.counters["rss_delta_mb"] = benchmark::Counter(
            static_cast<double>(rss_after > rss_before ? rss_after - rss_before : 0) / 1024.0,
            benchmark::Counter::kDefaults,
            benchmark::Counter::kIs1024);
        state.counters["per_ord_bytes"] = benchmark::Counter(
            static_cast<double>(rss_after > rss_before
                ? (rss_after - rss_before) * 1024 / static_cast<double>(n)
                : static_cast<double>(blob_sz)),
            benchmark::Counter::kDefaults);
    }
    state.counters["n_docs"] = benchmark::Counter(static_cast<double>(n));
    state.counters["blob_bytes"] = benchmark::Counter(static_cast<double>(blob_sz));
}
BENCHMARK(BM_P12_MetaBlobFootprint)
    ->ArgsProduct({
        {10000, 100000, 1000000},
        {64, 256}
    })
    ->Iterations(1)
    ->Unit(benchmark::kMillisecond);
