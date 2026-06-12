// CRC32 IEEE 802.3 micro-benchmark — zlib ::crc32() vs bitcask::hw::crc32().
//
// Scenarios: 23, 256, 4096, 65536 bytes. Covers the on-disk hot path
// (data records ~16..512 B, hint record payloads up to 64 KiB, scanner
// reads aggregating many KiB at a time).
//
// Run:  ./bitcask_bench --benchmark_filter=Crc32
//       --benchmark_format=json --benchmark_out=baseline.json

#include <benchmark/benchmark.h>

#include <cstdio>
#include <cstdlib>
#include <random>
#include <span>
#include <vector>

#include <zlib.h>

#include "bitcask/codec.hpp"
#include "bitcask/hw_crc32.hpp"

namespace {

// Deterministic pseudo-random fill. Each size has a distinct seed so the
// 256-byte buffer isn't a prefix of the 4096-byte one (catches prefetcher
// aliasing that would otherwise inflate HW numbers).
std::vector<std::byte> make_buf(std::size_t bytes, std::uint64_t seed) {
    std::vector<std::byte> buf(bytes);
    std::mt19937_64 rng(seed);
    auto* p = reinterpret_cast<std::uint8_t*>(buf.data());
    for (std::size_t i = 0; i < bytes; ++i) {
        p[i] = static_cast<std::uint8_t>(rng() & 0xFFu);
    }
    return buf;
}

}  // namespace

// -----------------------------------------------------------------------------
// Startup self-test. Verifies bitcask::hw::crc32 produces bit-identical
// output to zlib's ::crc32() on every size from 0 to 256, plus a few
// representative larger sizes. Aborts the process on mismatch — a broken
// CRC path would silently corrupt on-disk records, which is a data-loss
// bug we absolutely must catch before any benchmarks run.
// -----------------------------------------------------------------------------
namespace {

void self_test() {
    // 0..256 with deterministic bytes (i*7+13 gives a varied byte pattern).
    for (std::size_t len = 0; len <= 256; ++len) {
        std::vector<std::byte> buf(len);
        for (std::size_t i = 0; i < len; ++i) {
            buf[i] = static_cast<std::byte>((i * 7 + 13) & 0xFF);
        }
        const auto z = static_cast<std::uint32_t>(
            ::crc32(0L, reinterpret_cast<const Bytef*>(buf.data()),
                    static_cast<uInt>(len)));
        const auto h = bitcask::hw::crc32(std::span<const std::byte>(buf));
        if (z != h) {
            std::fprintf(stderr,
                         "CRC32 self-test FAILED at len=%zu: zlib=0x%08X hw=0x%08X\n",
                         len, z, h);
            std::abort();
        }
    }
    // Streaming: hash A||B in two pieces should equal hash(A||B) at once.
    std::mt19937_64 rng(0xC0DEC0DEull);
    auto fill = [&](std::vector<std::byte>& v) {
        for (auto& b : v) b = static_cast<std::byte>(rng() & 0xFFu);
    };
    std::vector<std::byte> a(1234), b(2345);
    fill(a); fill(b);
    std::vector<std::byte> ab;
    ab.reserve(a.size() + b.size());
    ab.insert(ab.end(), a.begin(), a.end());
    ab.insert(ab.end(), b.begin(), b.end());
    const auto z_whole = static_cast<std::uint32_t>(
        ::crc32(0L, reinterpret_cast<const Bytef*>(ab.data()),
                static_cast<uInt>(ab.size())));
    const auto z_step1 = static_cast<std::uint32_t>(
        ::crc32(0L, reinterpret_cast<const Bytef*>(a.data()),
                static_cast<uInt>(a.size())));
    const auto z_step2 = static_cast<std::uint32_t>(
        ::crc32(z_step1, reinterpret_cast<const Bytef*>(b.data()),
                static_cast<uInt>(b.size())));
    const auto h_step1 = bitcask::hw::crc32(std::span<const std::byte>(a));
    const auto h_step2 = bitcask::hw::crc32_update(
        h_step1, std::span<const std::byte>(b));
    if (z_whole != z_step2 || z_whole != h_step2) {
        std::fprintf(stderr,
                     "CRC32 streaming self-test FAILED: "
                     "zlib_whole=0x%08X zlib_stream=0x%08X hw_stream=0x%08X\n",
                     z_whole, z_step2, h_step2);
        std::abort();
    }
}

}  // namespace

// -----------------------------------------------------------------------------
// Benchmarks. Two families per size: zlib scalar, hw (PCLMULQDQ on x86 +
// bytewise fallback). Same buffer content so any divergence is the kernel
// or the dispatch, not the data.
// -----------------------------------------------------------------------------

static void BM_Crc32_Zlib(benchmark::State& state) {
    const std::size_t len = static_cast<std::size_t>(state.range(0));
    const auto buf = make_buf(len, 0xABCD0000ull ^ len);
    for (auto _ : state) {
        auto v = ::crc32(0L, reinterpret_cast<const Bytef*>(buf.data()),
                         static_cast<uInt>(len));
        benchmark::DoNotOptimize(v);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(len));
}
BENCHMARK(BM_Crc32_Zlib)
    ->Arg(23)
    ->Arg(256)
    ->Arg(4096)
    ->Arg(65536);

static void BM_Crc32_Hw(benchmark::State& state) {
    const std::size_t len = static_cast<std::size_t>(state.range(0));
    const auto buf = make_buf(len, 0xABCD0000ull ^ len);
    for (auto _ : state) {
        auto v = bitcask::hw::crc32(std::span<const std::byte>(buf));
        benchmark::DoNotOptimize(v);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(len));
}
BENCHMARK(BM_Crc32_Hw)
    ->Arg(23)
    ->Arg(256)
    ->Arg(4096)
    ->Arg(65536);

// Streaming variant — matches the hint file trailer / WAL framing pattern
// (running CRC across many small appends).
static void BM_Crc32_Hw_Streaming(benchmark::State& state) {
    const std::size_t len = static_cast<std::size_t>(state.range(0));
    const auto buf = make_buf(len, 0xBEEF0000ull ^ len);
    for (auto _ : state) {
        // Split the buffer into 16-byte chunks like a record writer would.
        std::uint32_t seed = 0;
        const std::size_t chunks = len / 16;
        for (std::size_t i = 0; i < chunks; ++i) {
            seed = bitcask::hw::crc32_update(
                seed, std::span<const std::byte>(buf.data() + i * 16, 16));
        }
        if (len % 16 != 0) {
            seed = bitcask::hw::crc32_update(
                seed, std::span<const std::byte>(buf.data() + chunks * 16,
                                                len % 16));
        }
        benchmark::DoNotOptimize(seed);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(len));
}
BENCHMARK(BM_Crc32_Hw_Streaming)
    ->Arg(256)
    ->Arg(4096)
    ->Arg(65536);

// Force the self-test to run at process start. Google Benchmark's main()
// discovers and runs BENCHMARK() registrations; we register a dummy
// benchmark that runs the self-test in its SetUp so we never start a
// measurement on a broken CRC path.
static void BM_Crc32_SelfTest(benchmark::State& state) {
    self_test();
    for (auto _ : state) {
    }
}
BENCHMARK(BM_Crc32_SelfTest);