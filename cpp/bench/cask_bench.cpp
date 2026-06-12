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

#include "bitcask/cask.hpp"

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
        auto r = cask.get(as_bytes(k));
        benchmark::DoNotOptimize(r);
    }
    state.SetItemsProcessed(state.iterations());
    state.SetBytesProcessed(state.iterations() * static_cast<int64_t>(value.size()));
}
BENCHMARK(BM_Cask_Get_Hot);

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
        fs::remove(fs::path(dir) / "bitcask.keydir.snap", ec);
        state.ResumeTiming();
        auto c = Cask::open(dir, rw_opts());
        if (!c) state.SkipWithError("open failed");
        benchmark::DoNotOptimize(c);
        (*c)->close();
    }
}
BENCHMARK(BM_Cask_Open_FullFold)->Unit(benchmark::kMicrosecond);
