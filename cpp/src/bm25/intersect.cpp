// 升序去重 u64 数组求交（Inoue 块过滤 + SIMD 精确匹配）。
// 接口语义见 intersect.hpp。

#include "bitcask/intersect.hpp"

#include <algorithm>
#include <bit>
#include <cstddef>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#define BITCASK_INTERSECT_SIMD 1
#include <immintrin.h>
#endif

namespace bitcask::bm25 {
namespace {

void intersect_scalar(const std::uint64_t* a, std::size_t na,
                      const std::uint64_t* b, std::size_t nb,
                      std::vector<std::uint64_t>& out) {
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

void intersect_galloping(const std::uint64_t* s, std::size_t ns,
                         const std::uint64_t* l, std::size_t nl,
                         std::vector<std::uint64_t>& out) {
    std::size_t lo = 0;
    for (std::size_t i = 0; i < ns && lo < nl; ++i) {
        const std::uint64_t v = s[i];
        std::size_t step = 1;
        std::size_t hi = lo;
        while (hi < nl && l[hi] < v) {
            lo = hi + 1;
            hi += step;
            step <<= 1;
        }
        if (hi >= nl) hi = nl - 1;
        if (l[hi] < v) break;
        const auto* it = std::lower_bound(l + lo, l + hi + 1, v);
        lo = static_cast<std::size_t>(it - l);
        if (lo < nl && l[lo] == v) {
            out.push_back(v);
            ++lo;
        }
    }
}

#ifdef BITCASK_INTERSECT_SIMD

// ── AVX2 内核（block=4，permute4x64 立即数旋转 + 条件 push_back）─────────

__attribute__((target("avx2")))
void exact_match_u64_avx2(const std::uint64_t* a, const std::uint64_t* b,
                           std::vector<std::uint64_t>& out) {
    const __m256i va =
        _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(a));
    const __m256i vb =
        _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(b));

    const __m256i cmp01 = _mm256_or_si256(
        _mm256_cmpeq_epi64(va, vb),
        _mm256_cmpeq_epi64(va,
                           _mm256_permute4x64_epi64(vb, 0x39)));
    const __m256i cmp23 = _mm256_or_si256(
        _mm256_cmpeq_epi64(
            va, _mm256_permute4x64_epi64(vb, 0x4E)),
        _mm256_cmpeq_epi64(
            va, _mm256_permute4x64_epi64(vb, 0x93)));
    const __m256i cmp = _mm256_or_si256(cmp01, cmp23);

    const unsigned mask = static_cast<unsigned>(
        _mm256_movemask_pd(_mm256_castsi256_pd(cmp)));

    if (mask & 1u) out.push_back(a[0]);
    if (mask & 2u) out.push_back(a[1]);
    if (mask & 4u) out.push_back(a[2]);
    if (mask & 8u) out.push_back(a[3]);
}

__attribute__((target("avx2")))
void intersect_inoue_avx2(const std::uint64_t* a, std::size_t na,
                          const std::uint64_t* b, std::size_t nb,
                          std::vector<std::uint64_t>& out) {
    constexpr std::size_t B = 4;
    std::size_t i = 0;
    std::size_t j = 0;

    while (i + B <= na && j + B <= nb) {
        if (a[i + B - 1] < b[j]) { i += B; continue; }
        if (b[j + B - 1] < a[i]) { j += B; continue; }

        exact_match_u64_avx2(a + i, b + j, out);

        const std::uint64_t amax = a[i + B - 1];
        const std::uint64_t bmax = b[j + B - 1];
        if (amax <= bmax) i += B;
        if (bmax <= amax) j += B;
    }

    intersect_scalar(a + i, na - i, b + j, nb - j, out);
}

// ── AVX-512 内核（block=8，permutexvar + cmpeq_mask + compressstoreu）─────

alignas(64) static constexpr std::uint64_t kRot512[8][8] = {
    {0, 1, 2, 3, 4, 5, 6, 7},
    {1, 2, 3, 4, 5, 6, 7, 0},
    {2, 3, 4, 5, 6, 7, 0, 1},
    {3, 4, 5, 6, 7, 0, 1, 2},
    {4, 5, 6, 7, 0, 1, 2, 3},
    {5, 6, 7, 0, 1, 2, 3, 4},
    {6, 7, 0, 1, 2, 3, 4, 5},
    {7, 0, 1, 2, 3, 4, 5, 6},
};

__attribute__((target("avx512f")))
void exact_match_u64_avx512(const std::uint64_t* a, const std::uint64_t* b,
                              std::vector<std::uint64_t>& out) {
    const __m512i va = _mm512_loadu_si512(a);
    const __m512i vb = _mm512_loadu_si512(b);

    __mmask8 cmp = _mm512_cmpeq_epi64_mask(va, vb);
    for (int r = 1; r < 8; ++r) {
        const __m512i ridx = _mm512_load_si512(kRot512[r]);
        const __m512i vbr = _mm512_permutexvar_epi64(ridx, vb);
        cmp |= _mm512_cmpeq_epi64_mask(va, vbr);
    }

    if (cmp == 0) return;
    const std::size_t cnt =
        static_cast<std::size_t>(std::popcount(static_cast<unsigned>(cmp)));
    const std::size_t old = out.size();
    out.resize(old + cnt);
    _mm512_mask_compressstoreu_epi64(out.data() + old, cmp, va);
}

__attribute__((target("avx512f")))
void intersect_inoue_avx512(const std::uint64_t* a, std::size_t na,
                             const std::uint64_t* b, std::size_t nb,
                             std::vector<std::uint64_t>& out) {
    constexpr std::size_t B = 8;
    std::size_t i = 0;
    std::size_t j = 0;

    while (i + B <= na && j + B <= nb) {
        if (a[i + B - 1] < b[j]) { i += B; continue; }
        if (b[j + B - 1] < a[i]) { j += B; continue; }

        exact_match_u64_avx512(a + i, b + j, out);

        const std::uint64_t amax = a[i + B - 1];
        const std::uint64_t bmax = b[j + B - 1];
        if (amax <= bmax) i += B;
        if (bmax <= amax) j += B;
    }

    intersect_scalar(a + i, na - i, b + j, nb - j, out);
}

#endif  // BITCASK_INTERSECT_SIMD

}  // namespace

void intersect_u64(std::span<const std::uint64_t> a,
                   std::span<const std::uint64_t> b,
                   std::vector<std::uint64_t>& out) {
    out.clear();
    if (a.empty() || b.empty()) return;

    if (a.size() * 32 < b.size()) {
        intersect_galloping(a.data(), a.size(), b.data(), b.size(), out);
        return;
    }
    if (b.size() * 32 < a.size()) {
        intersect_galloping(b.data(), b.size(), a.data(), a.size(), out);
        return;
    }

#ifdef BITCASK_INTERSECT_SIMD
    static const bool kHasAvx512f = __builtin_cpu_supports("avx512f");
    if (kHasAvx512f) {
        intersect_inoue_avx512(a.data(), a.size(), b.data(), b.size(), out);
        return;
    }
    static const bool kHasAvx2 = __builtin_cpu_supports("avx2");
    if (kHasAvx2) {
        intersect_inoue_avx2(a.data(), a.size(), b.data(), b.size(), out);
        return;
    }
#endif
    intersect_scalar(a.data(), a.size(), b.data(), b.size(), out);
}

}  // namespace bitcask::bm25
