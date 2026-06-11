// 升序去重 u32 数组求交的三路实现。接口语义见 intersect.hpp。

#include "bitcask/intersect.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#define BITCASK_INTERSECT_AVX2 1
#include <immintrin.h>
#endif

namespace bitcask::bm25 {
namespace {

// 标量双指针归并。
void intersect_scalar(const std::uint32_t* a, std::size_t na,
                      const std::uint32_t* b, std::size_t nb,
                      std::vector<std::uint32_t>& out) {
    std::size_t i = 0;
    std::size_t j = 0;
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

// galloping：s（小）驱动，l（大）上指数探查 + 二分。
void intersect_galloping(const std::uint32_t* s, std::size_t ns,
                         const std::uint32_t* l, std::size_t nl,
                         std::vector<std::uint32_t>& out) {
    std::size_t lo = 0;
    for (std::size_t i = 0; i < ns && lo < nl; ++i) {
        const std::uint32_t v = s[i];
        // 指数探查找到包含 v 的窗口，再二分。
        std::size_t step = 1;
        std::size_t hi = lo;
        while (hi < nl && l[hi] < v) {
            lo = hi + 1;
            hi += step;
            step <<= 1;
        }
        if (hi >= nl) hi = nl - 1;
        if (l[hi] < v) break;  // 大数组耗尽
        const auto* it = std::lower_bound(l + lo, l + hi + 1, v);
        lo = static_cast<std::size_t>(it - l);
        if (lo < nl && l[lo] == v) {
            out.push_back(v);
            ++lo;
        }
    }
}

#ifdef BITCASK_INTERSECT_AVX2

// mask（8 bit）→ 压缩置换索引：把被置位 lane 的下标紧凑排到前部。
// 8KB，进程内一次性构造。
struct CompressLut {
    alignas(32) std::array<std::array<std::uint32_t, 8>, 256> idx{};
    CompressLut() {
        for (unsigned mask = 0; mask < 256; ++mask) {
            unsigned dst = 0;
            for (unsigned bit = 0; bit < 8; ++bit) {
                if (mask & (1U << bit)) idx[mask][dst++] = bit;
            }
        }
    }
};

__attribute__((target("avx2")))
void intersect_avx2(const std::uint32_t* a, std::size_t na,
                    const std::uint32_t* b, std::size_t nb,
                    std::vector<std::uint32_t>& out) {
    static const CompressLut lut;

    // 输出上限 min(na,nb)；末尾留 8 lane 余量给整组 storeu。
    const std::size_t cap = std::min(na, nb);
    out.resize(cap + 8);
    std::uint32_t* dst = out.data();
    std::size_t cnt = 0;

    // b 块的 8 个循环旋转索引（permutevar8x32 跨 128-bit lane 旋转）。
    alignas(32) static constexpr std::uint32_t kRot[8][8] = {
        {0, 1, 2, 3, 4, 5, 6, 7}, {1, 2, 3, 4, 5, 6, 7, 0},
        {2, 3, 4, 5, 6, 7, 0, 1}, {3, 4, 5, 6, 7, 0, 1, 2},
        {4, 5, 6, 7, 0, 1, 2, 3}, {5, 6, 7, 0, 1, 2, 3, 4},
        {6, 7, 0, 1, 2, 3, 4, 5}, {7, 0, 1, 2, 3, 4, 5, 6}};

    std::size_t i = 0;
    std::size_t j = 0;
    while (i + 8 <= na && j + 8 <= nb) {
        const __m256i va =
            _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(a + i));
        const __m256i vb =
            _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(b + j));

        // va 各 lane 与 vb 的 8 个旋转逐一全比较，命中掩码落在 va 的 lane 位。
        __m256i cmp = _mm256_cmpeq_epi32(va, vb);
        for (int r = 1; r < 8; ++r) {
            const __m256i ridx = _mm256_load_si256(
                reinterpret_cast<const __m256i*>(kRot[r]));
            const __m256i vbr = _mm256_permutevar8x32_epi32(vb, ridx);
            cmp = _mm256_or_si256(cmp, _mm256_cmpeq_epi32(va, vbr));
        }
        const unsigned mask = static_cast<unsigned>(
            _mm256_movemask_ps(_mm256_castsi256_ps(cmp)));

        const __m256i perm = _mm256_load_si256(
            reinterpret_cast<const __m256i*>(lut.idx[mask].data()));
        const __m256i packed = _mm256_permutevar8x32_epi32(va, perm);
        // 纵深防御：每轮整组 storeu 8 lane，需 cnt+8 ≤ capacity。无重复输入
        // 下 cnt ≤ min(na,nb)=cap 恒成立、守卫永不触发（零开销）；若调用方
        // 违反「严格升序无重复」前置（如崩溃恢复的重复 ord），输出可超 cap，
        // 此处扩容避免写穿堆（不保证结果正确，只保证不 UB）。
        if (cnt + 8 > out.size()) {
            out.resize(out.size() * 2 + 8);
            dst = out.data();
        }
        _mm256_storeu_si256(reinterpret_cast<__m256i_u*>(dst + cnt), packed);
        cnt += static_cast<std::size_t>(std::popcount(mask));

        // 块推进：最大值较小的一侧整组前进（相等则双进）。
        // 正确性：a 块内任何 ≤ max(b 块) 的元素已与全部可能相等者比较过。
        const std::uint32_t amax = a[i + 7];
        const std::uint32_t bmax = b[j + 7];
        if (amax <= bmax) i += 8;
        if (bmax <= amax) j += 8;
    }

    out.resize(cnt);
    // 尾部（不足一块）标量归并。
    intersect_scalar(a + i, na - i, b + j, nb - j, out);
}

#endif  // BITCASK_INTERSECT_AVX2

}  // namespace

void intersect_u32(std::span<const std::uint32_t> a,
                   std::span<const std::uint32_t> b,
                   std::vector<std::uint32_t>& out) {
    out.clear();
    if (a.empty() || b.empty()) return;

    // 悬殊形态：galloping（SIMD 块交集对此无益）。
    if (a.size() * 32 < b.size()) {
        intersect_galloping(a.data(), a.size(), b.data(), b.size(), out);
        return;
    }
    if (b.size() * 32 < a.size()) {
        intersect_galloping(b.data(), b.size(), a.data(), a.size(), out);
        return;
    }

#ifdef BITCASK_INTERSECT_AVX2
    static const bool kHasAvx2 = __builtin_cpu_supports("avx2");
    if (kHasAvx2) {
        intersect_avx2(a.data(), a.size(), b.data(), b.size(), out);
        return;
    }
#endif
    intersect_scalar(a.data(), a.size(), b.data(), b.size(), out);
}

}  // namespace bitcask::bm25
