// Cask end-to-end micro-benchmarks. These hit the data file on disk via
// pwrite / pread, so numbers depend on the underlying FS (typically tmpfs
// in /tmp). Useful for spotting regressions in the encode/decode + I/O
// path; not meant to compare against legacy bitcask without aligning the
// underlying storage layer first.

#include <benchmark/benchmark.h>

#include <unistd.h>
#include <cstdio>
#include <filesystem>
#include <random>
#include <string>
#include <vector>
#include <utility>

#include "bitcask/cask.hpp"
#include "bitcask/inverted_wal.hpp"

namespace fs = std::filesystem;
using bitcask::Cask;
using bitcask::CaskOptions;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_bench_" + std::to_string(::getpid()) + "_" +
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

CaskOptions rw_opts() {
    CaskOptions o;
    o.read_write = true;
    return o;
}

}  // namespace

// -----------------------------------------------------------------------------
// Steady-state put. Pre-populates so we benchmark the overwrite path (most
// realistic — production workloads almost always overwrite existing keys).
// -----------------------------------------------------------------------------
static void BM_Cask_Put_Overwrite(benchmark::State& state) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    if (!c) state.SkipWithError("Cask::open failed");
    auto& cask = **c;

    constexpr int kKeyspace = 1024;
    std::vector<std::string> keys;
    keys.reserve(kKeyspace);
    for (int i = 0; i < kKeyspace; ++i) {
        keys.push_back("k" + std::to_string(i));
    }

    const std::string value(128, 'v');  // 128-byte value, fixed
    for (const auto& k : keys) {
        auto r = cask.put(as_bytes(k), as_bytes(value));
        if (!r) state.SkipWithError("populate put failed");
    }

    std::mt19937 rng(0xCAFE);
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

    for (auto _ : state) {
        auto& k = keys[static_cast<std::size_t>(dist(rng))];
        auto r = cask.put(as_bytes(k), as_bytes(value));
        benchmark::DoNotOptimize(r);
    }
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(state.iterations() * static_cast<int64_t>(value.size()));
}
BENCHMARK(BM_Cask_Put_Overwrite);

// -----------------------------------------------------------------------------
// Hot get. Pre-populated dir; every get hits the keydir + reads back from
// the file. Page cache is warm after the first iteration.
// -----------------------------------------------------------------------------
static void BM_Cask_Get_Hot(benchmark::State& state) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    if (!c) state.SkipWithError("Cask::open failed");
    auto& cask = **c;

    constexpr int kKeyspace = 1024;
    std::vector<std::string> keys;
    keys.reserve(kKeyspace);
    for (int i = 0; i < kKeyspace; ++i) {
        keys.push_back("k" + std::to_string(i));
    }
    const std::string value(128, 'v');
    for (const auto& k : keys) {
        auto r = cask.put(as_bytes(k), as_bytes(value));
        if (!r) state.SkipWithError("populate put failed");
    }

    std::mt19937 rng(0xCAFE);
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

    for (auto _ : state) {
        auto& k = keys[static_cast<std::size_t>(dist(rng))];
        auto r = cask.get_owned(as_bytes(k));
        benchmark::DoNotOptimize(r);
    }
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(state.iterations() * static_cast<int64_t>(value.size()));
}
BENCHMARK(BM_Cask_Get_Hot);

// V6.1.5: 零拷贝 get() benchmark——与上方 get_owned() 对比。
// 目标：get() (view) 耗时 < 90% get_owned() (owned)。
static void BM_Cask_Get_Hot_View(benchmark::State& state) {
    TempDir td;
    auto c = Cask::open(td.path(), rw_opts());
    if (!c) state.SkipWithError("Cask::open failed");
    auto& cask = **c;

    constexpr int kKeyspace = 1024;
    std::vector<std::string> keys;
    keys.reserve(kKeyspace);
    for (int i = 0; i < kKeyspace; ++i) {
        keys.push_back("k" + std::to_string(i));
    }
    const std::string value(128, 'v');
    for (const auto& k : keys) {
        auto r = cask.put(as_bytes(k), as_bytes(value));
        if (!r) state.SkipWithError("populate put failed");
    }

    std::mt19937 rng(0xCAFE);
    std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

    for (auto _ : state) {
        auto& k = keys[static_cast<std::size_t>(dist(rng))];
        auto r = cask.get(as_bytes(k));  // zero-copy GetResultView
        benchmark::DoNotOptimize(r);
    }
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(state.iterations() * static_cast<int64_t>(value.size()));
}
BENCHMARK(BM_Cask_Get_Hot_View);

// -----------------------------------------------------------------------------
// A4:open 冷启动——keydir 段快照 vs 全量 fold(20k 记录)。
// 两者共用同一份预生成目录;FullFold 变体每轮删快照(close 会重写)。
// -----------------------------------------------------------------------------
namespace {
std::string prepare_open_dir() {
    static TempDir td;
    static bool done = false;
    if (!done) {
        auto c = Cask::open(td.path(), rw_opts());
        const std::string value(64, 'v');
        for (int i = 0; i < 20000; ++i) {
            (void)(*c)->put(as_bytes("key" + std::to_string(i)), as_bytes(value));
        }
        (*c)->close();  // 写下快照
        done = true;
    }
    return td.path();
}
}  // namespace

static void BM_Cask_Open_Snapshot(benchmark::State& state) {
    auto dir = prepare_open_dir();
    for (auto _ : state) {
        auto c = Cask::open(dir, rw_opts());
        if (!c) state.SkipWithError("open failed");
        benchmark::DoNotOptimize(c);
        (*c)->close();  // 重写快照,下一轮仍走快路径
    }
}
BENCHMARK(BM_Cask_Open_Snapshot)->Unit(benchmark::kMicrosecond);

static void BM_Cask_Open_FullFold(benchmark::State& state) {
    auto dir = prepare_open_dir();
    for (auto _ : state) {
        state.PauseTiming();
        std::error_code ec;
        fs::remove(fs::path(dir) / "kv.keydir.ckpt", ec);
        state.ResumeTiming();
        auto c = Cask::open(dir, rw_opts());
        if (!c) state.SkipWithError("open failed");
        benchmark::DoNotOptimize(c);
        (*c)->close();
    }
}
BENCHMARK(BM_Cask_Open_FullFold)->Unit(benchmark::kMicrosecond);

// -----------------------------------------------------------------------------
// V3.5:vector 集合 open——hnsw 快照(BCVS)快路径 vs 全量 fold 重插。
// 1 万条 384d(归一化)向量文档;FullFold 变体每轮删 search.vec.ckpt(covers 门
// 关闭 → 整库 fold,重分词 + 重插 HNSW)。无红线,只记实测(设计 §6)。
// -----------------------------------------------------------------------------
namespace {
CaskOptions vec_opts() {
    CaskOptions o;
    o.read_write = true;
    o.enable_search = true;
    bitcask::search::SearchLayerConfig sc;
    sc.analyzer_config.type = bitcask::text::AnalyzerType::Whitespace;
    o.search_config = sc;
    o.vector_dim = 384;
    return o;
}

std::string prepare_vec_open_dir() {
    static TempDir td;
    static bool done = false;
    if (!done) {
        auto c = Cask::open(td.path(), vec_opts());
        std::mt19937 rng(0xBC35);
        std::normal_distribution<float> nd(0.0f, 1.0f);
        std::vector<float> v(384);
        for (int i = 0; i < 10000; ++i) {
            double sq = 0.0;
            for (auto& x : v) {
                x = nd(rng);
                sq += static_cast<double>(x) * x;
            }
            const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
            for (auto& x : v) x *= inv;
            bitcask::DocInput doc;
            const std::string key = "d" + std::to_string(i);
            const std::string text = "doc " + std::to_string(i);
            doc.text = as_bytes(text);
            doc.vector = std::span<const float>(v.data(), v.size());
            (void)(*c)->put_doc(as_bytes(key), doc);
        }
        (*c)->flush_index();
        (*c)->close();  // 落四块快照(bm25/sidecar/hnsw/keydir)
        done = true;
    }
    return td.path();
}
}  // namespace

static void BM_Cask_Open_VecSnapshot(benchmark::State& state) {
    auto dir = prepare_vec_open_dir();
    for (auto _ : state) {
        auto c = Cask::open(dir, vec_opts());
        if (!c) state.SkipWithError("open failed");
        benchmark::DoNotOptimize(c);
        (*c)->close();
    }
}
BENCHMARK(BM_Cask_Open_VecSnapshot)
    ->Unit(benchmark::kMillisecond)
    ->Iterations(5);

static void BM_Cask_Open_VecFullFold(benchmark::State& state) {
    auto dir = prepare_vec_open_dir();
    for (auto _ : state) {
        state.PauseTiming();
        std::error_code ec;
        fs::remove(fs::path(dir) / "search.vec.ckpt", ec);
        state.ResumeTiming();
        auto c = Cask::open(dir, vec_opts());
        if (!c) state.SkipWithError("open failed");
        benchmark::DoNotOptimize(c);
        (*c)->close();
    }
}
BENCHMARK(BM_Cask_Open_VecFullFold)
    ->Unit(benchmark::kMillisecond)
    ->Iterations(2);

// -----------------------------------------------------------------------------
// V3.7:hybrid 端到端(BM25 ∥ HNSW → RRF)。同语料 1 万条 384d;查询 =
// 轮转文本词 + 随机归一化向量,k=10。库在计时区外开关(度量纯查询)。
// -----------------------------------------------------------------------------
static void BM_Cask_SearchHybrid(benchmark::State& state) {
    auto dir = prepare_vec_open_dir();
    auto c = Cask::open(dir, vec_opts());
    if (!c) { state.SkipWithError("open failed"); return; }
    std::mt19937 rng(0x9337);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> qs(1000 * 384);
    for (int i = 0; i < 1000; ++i) {
        double sq = 0.0;
        float* p = &qs[static_cast<std::size_t>(i) * 384];
        for (int d = 0; d < 384; ++d) {
            p[d] = nd(rng);
            sq += static_cast<double>(p[d]) * p[d];
        }
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        for (int d = 0; d < 384; ++d) p[d] *= inv;
    }
    std::size_t qi = 0;
    for (auto _ : state) {
        const auto i = qi++ % 1000;
        const std::string tq = "doc " + std::to_string(i * 7 % 10000);
        auto r = (*c)->search_hybrid(
            tq, std::span<const float>(&qs[i * 384], 384), 10);
        if (!r) { state.SkipWithError("hybrid failed"); break; }
        benchmark::DoNotOptimize(r->hits);
    }
    (*c)->close();
}
BENCHMARK(BM_Cask_SearchHybrid)->Unit(benchmark::kMicrosecond);

// V6.2.4: WAL batch flush throughput — batch_size=1 vs batch_size=64.
// Opens a cask with search (analyzer=Whitespace) enabled so that put()
// flows through the IndexPool worker and writes the InvertedIndex WAL.
// batch_size=1 is the legacy immediate-flush path; batch_size=64
// accumulates entries in batch_buf_ and fwrite+fflush once per 64.
static void BM_Put_WalBatch(benchmark::State& state) {
    auto batch_size = static_cast<std::size_t>(state.range(0));

    TempDir td;
    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    bitcask::search::SearchLayerConfig sc;
    sc.analyzer_config.type = bitcask::text::AnalyzerType::Whitespace;
    sc.wal_batch_size = batch_size;
    opts.search_config = sc;

    auto c = Cask::open(td.path(), opts);
    if (!c) state.SkipWithError("Cask::open failed");
    auto& cask = **c;

    const std::string text(64, 'x');  // simple text, no special chars
    std::uint64_t ord = 0;

    for (auto _ : state) {
        auto key = "key" + std::to_string(ord++);
        auto r = cask.put(as_bytes(key), as_bytes(text));
        if (!r) state.SkipWithError("put failed");
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_Put_WalBatch)->Arg(1)->Arg(64);

// V6.2.4: 隔离 WAL 写入的微基准——绕过 full put path，直测 append_add_doc。
// 这才是 batch flush 的直接收益面（full put 中 analyzer + index update 主导）。
static void BM_Wal_AppendOnly(benchmark::State& state) {
    auto batch_size = static_cast<std::size_t>(state.range(0));
    TempDir td;
    std::string wal_path = std::string(td.path()) + "/wal_only.wal";

    bitcask::bm25::WalTermPositions term_data;
    term_data.emplace("alpha", std::make_pair(std::uint32_t(1), std::vector<std::uint32_t>{0}));
    term_data.emplace("beta", std::make_pair(std::uint32_t(1), std::vector<std::uint32_t>{1}));

    bitcask::bm25::InvertedWal wal(wal_path, batch_size);
    std::uint64_t ord = 0;
    for (auto _ : state) {
        wal.append_add_doc(ord++, term_data);
    }
    state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_Wal_AppendOnly)->Arg(1)->Arg(64);
