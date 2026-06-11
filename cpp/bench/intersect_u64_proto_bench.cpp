// u64 AVX2 交集原型（备选实现附录，**未接线生产代码**）。
//
// 背景：bool_search 的 MUST 交集在 ord ≤ 2^32 时走 u32 窄化 + SIMD 快路径
// （intersect.cpp），超界回退 u64 标量 set_intersection。本文件是该回退的
// SIMD 化备选方案的可运行原型——核心技巧：AVX2 没有 64 位变量跨 lane
// shuffle（permutexvar_epi64 是 AVX-512），用**成对索引的 permutevar8x32**
// 模拟（每个 u64 视为两个相邻 u32 lane 整体搬移）；相等比较用 AVX2 原生
// cmpeq_epi64（真 64 位，对抗性自检覆盖「低 32 位相同高 32 位不同」）。
//
// 触发条件 / 设计推导 / 实证记录：doc/bool-search-intersection-zh.md §7.1。
// 实证（i9-13900H）：对拍 2354 组全过 + ASan/UBSan 干净；2M×2M 相对标量
// 归并 ~3.46x（标量瓶颈是数据相关分支预测失败，SIMD 无分支整体消掉）。
//
// 接线路径（当 ord 突破 2^32、回退变热时）：本内核移入 intersect.cpp 做
// intersect_u64（复刻 u32 的三路分发：悬殊 galloping / AVX2 / 标量），
// bool_search 的 run_must_intersect u64 侧 lambda 换调用即可（P4.5 已合并
// 骨架）；测试复刻 IntersectU32 系列对拍 + 越界守卫 teeth 流程。
//
// Run:  ./bitcask_bench --benchmark_filter=IntersectU64Proto

#include <benchmark/benchmark.h>

#include <algorithm>
#include <bit>
#include <cstdint>
#include <vector>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#define BITCASK_U64PROTO_AVX2 1
#include <immintrin.h>
#endif

namespace {

void intersect_u64_scalar(const std::uint64_t* a, std::size_t na,
                          const std::uint64_t* b, std::size_t nb,
                          std::vector<std::uint64_t>& out) {
    out.clear();
    std::size_t i = 0, j = 0;
    while (i < na && j < nb) {
        if (a[i] < b[j]) {
            ++i;
        } else if (b[j] < a[i]) {
            ++j;
        } else {
            out.push_back(a[i]);
            ++i;
            ++j;
        }
    }
}

std::uint64_t g_proto_seed = 42;
std::uint64_t proto_rand() {
    g_proto_seed = g_proto_seed * 6364136223846793005ULL + 1442695040888963407ULL;
    return g_proto_seed >> 17;
}

std::vector<std::uint64_t> proto_sorted_unique(std::size_t n, std::uint64_t base,
                                               std::uint64_t range) {
    std::vector<std::uint64_t> v(n);
    for (auto& x : v) x = base + proto_rand() % range;
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v;
}

#ifdef BITCASK_U64PROTO_AVX2

// 16 个 4-bit mask → 成对 u32 压缩置换索引（512B，单 cache line 量级）。
struct PairLut {
    alignas(32) std::uint32_t idx[16][8];
    PairLut() {
        for (unsigned m = 0; m < 16; ++m) {
            unsigned d = 0;
            for (unsigned k = 0; k < 4; ++k) {
                if (m >> k & 1U) {
                    idx[m][2 * d] = 2 * k;
                    idx[m][2 * d + 1] = 2 * k + 1;
                    ++d;
                }
            }
            for (; d < 4; ++d) {
                idx[m][2 * d] = 0;
                idx[m][2 * d + 1] = 1;
            }
        }
    }
};

__attribute__((target("avx2")))
void intersect_u64_avx2(const std::uint64_t* a, std::size_t na,
                        const std::uint64_t* b, std::size_t nb,
                        std::vector<std::uint64_t>& out) {
    static const PairLut lut;
    out.clear();
    out.resize(std::min(na, nb) + 4);
    std::uint64_t* dst = out.data();
    std::size_t cnt = 0;

    // 4 个 u64-lane 的循环旋转 = 成对 u32 索引（r=0 恒等免 permute）。
    alignas(32) static constexpr std::uint32_t kRot[4][8] = {
        {0, 1, 2, 3, 4, 5, 6, 7},
        {2, 3, 4, 5, 6, 7, 0, 1},
        {4, 5, 6, 7, 0, 1, 2, 3},
        {6, 7, 0, 1, 2, 3, 4, 5}};

    std::size_t i = 0, j = 0;
    while (i + 4 <= na && j + 4 <= nb) {
        const __m256i va =
            _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(a + i));
        const __m256i vb =
            _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(b + j));
        __m256i cmp = _mm256_cmpeq_epi64(va, vb);  // r=0
        for (int r = 1; r < 4; ++r) {
            const __m256i ridx =
                _mm256_load_si256(reinterpret_cast<const __m256i*>(kRot[r]));
            const __m256i vbr = _mm256_permutevar8x32_epi32(vb, ridx);
            cmp = _mm256_or_si256(cmp, _mm256_cmpeq_epi64(va, vbr));
        }
        const unsigned mask = static_cast<unsigned>(
            _mm256_movemask_pd(_mm256_castsi256_pd(cmp)));  // 4-bit

        const __m256i perm =
            _mm256_load_si256(reinterpret_cast<const __m256i*>(lut.idx[mask]));
        const __m256i packed = _mm256_permutevar8x32_epi32(va, perm);
        // 纵深防御（同 intersect.cpp 的 P3.1 守卫，u64 版余量 +4）。
        if (cnt + 4 > out.size()) {
            out.resize(out.size() * 2 + 4);
            dst = out.data();
        }
        _mm256_storeu_si256(reinterpret_cast<__m256i_u*>(dst + cnt), packed);
        cnt += static_cast<std::size_t>(std::popcount(mask));

        const std::uint64_t amax = a[i + 3];
        const std::uint64_t bmax = b[j + 3];
        if (amax <= bmax) i += 4;
        if (bmax <= amax) j += 4;
    }
    out.resize(cnt);
    // 尾部标量归并。
    std::size_t ti = i, tj = j;
    while (ti < na && tj < nb) {
        if (a[ti] < b[tj]) ++ti;
        else if (b[tj] < a[ti]) ++tj;
        else { out.push_back(a[ti]); ++ti; ++tj; }
    }
}

// 每次 bench 进程运行一次的自检对拍（缩减集）：尺寸覆盖 4 块边界、值域
// 覆盖跨 2^32 边界/高位大值，外加对抗性「低 32 位碰撞」。失败返回 false，
// bench 以 SkipWithError 显式报红——原型烂掉时基准不会静默输出假数字。
bool proto_self_check() {
    std::vector<std::uint64_t> out, ref;
    const std::size_t sizes[] = {0, 1, 3, 4, 5, 8, 9, 64, 200};
    const std::uint64_t bases[] = {0ULL, 0xFFFFFF00ULL, 5'000'000'000ULL,
                                   0x7FFFFFFFFFFFFF00ULL};
    for (auto na : sizes) {
        for (auto nb : sizes) {
            for (auto base : bases) {
                auto a = proto_sorted_unique(na, base, 1000);
                auto b = proto_sorted_unique(nb, base, 1000);
                intersect_u64_avx2(a.data(), a.size(), b.data(), b.size(), out);
                ref.clear();
                std::set_intersection(a.begin(), a.end(), b.begin(), b.end(),
                                      std::back_inserter(ref));
                if (out != ref) return false;
            }
        }
    }
    // 对抗性：低 32 位相同、高 32 位不同 → 必须零命中。
    std::vector<std::uint64_t> a, b;
    for (std::uint64_t k = 0; k < 64; ++k) a.push_back((1ULL << 32) | (k * 7));
    for (std::uint64_t k = 0; k < 64; ++k) b.push_back((2ULL << 32) | (k * 7));
    intersect_u64_avx2(a.data(), a.size(), b.data(), b.size(), out);
    if (!out.empty()) return false;
    intersect_u64_avx2(a.data(), a.size(), a.data(), a.size(), out);
    return out == a;
}

void BM_Inverted_IntersectU64ProtoSimd(benchmark::State& state) {
    if (!__builtin_cpu_supports("avx2")) {
        state.SkipWithError("no AVX2");
        return;
    }
    static const bool ok = proto_self_check();
    if (!ok) {
        state.SkipWithError("u64 proto self-check FAILED");
        return;
    }
    auto a = proto_sorted_unique(2'000'000, 5'000'000'000ULL, 4'000'000);
    auto b = proto_sorted_unique(2'000'000, 5'000'000'000ULL, 4'000'000);
    std::vector<std::uint64_t> out;
    for (auto _ : state) {
        intersect_u64_avx2(a.data(), a.size(), b.data(), b.size(), out);
        benchmark::DoNotOptimize(out);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(a.size() + b.size()));
}
BENCHMARK(BM_Inverted_IntersectU64ProtoSimd)->Unit(benchmark::kMillisecond);

#endif  // BITCASK_U64PROTO_AVX2

void BM_Inverted_IntersectU64ProtoScalar(benchmark::State& state) {
    auto a = proto_sorted_unique(2'000'000, 5'000'000'000ULL, 4'000'000);
    auto b = proto_sorted_unique(2'000'000, 5'000'000'000ULL, 4'000'000);
    std::vector<std::uint64_t> out;
    for (auto _ : state) {
        intersect_u64_scalar(a.data(), a.size(), b.data(), b.size(), out);
        benchmark::DoNotOptimize(out);
    }
    state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                            static_cast<std::int64_t>(a.size() + b.size()));
}
BENCHMARK(BM_Inverted_IntersectU64ProtoScalar)->Unit(benchmark::kMillisecond);

}  // namespace
