// 升序去重 u64 数组求交（Inoue 块过滤 + SIMD 精确匹配）。
// 接口语义见 intersect.hpp。
//
// 写出路径：入口一次性 resize 到结果上界 min(na, nb)，各内核通过裸指针
// 游标写出（消除热循环内 push_back 的容量检查与 size 读改写），结束后
// 一次 resize 截断到实际长度。见 doc/intersect-kernel-internals-zh.md §2。

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

std::uint64_t* intersect_scalar(const std::uint64_t* a, std::size_t na,
                                const std::uint64_t* b, std::size_t nb,
                                std::uint64_t* cur) {
    std::size_t i = 0;
    std::size_t j = 0;
    while (i < na && j < nb) {
        if (a[i] < b[j]) {
            ++i;
        } else if (b[j] < a[i]) {
            ++j;
        } else {
            *cur++ = a[i];
            ++i;
            ++j;
        }
    }
    return cur;
}

std::uint64_t* intersect_galloping(const std::uint64_t* s, std::size_t ns,
                                   const std::uint64_t* l, std::size_t nl,
                                   std::uint64_t* cur) {
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
            *cur++ = v;
            ++lo;
        }
    }
    return cur;
}

#ifdef BITCASK_INTERSECT_SIMD

// ── AVX2 内核（block=4，permute4x64 立即数旋转 + 条件提取）──────────────
// 压缩段维持分支形式；分支 vs PairLut 无分支版的选型待实测
// （doc/intersect-kernel-internals-zh.md §3）。

__attribute__((target("avx2")))
std::uint64_t* exact_match_u64_avx2(const std::uint64_t* a,
                                    const std::uint64_t* b,
                                    std::uint64_t* cur) {
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

    if (mask & 1u) *cur++ = a[0];
    if (mask & 2u) *cur++ = a[1];
    if (mask & 4u) *cur++ = a[2];
    if (mask & 8u) *cur++ = a[3];
    return cur;
}

__attribute__((target("avx2")))
std::uint64_t* intersect_inoue_avx2(const std::uint64_t* a, std::size_t na,
                                    const std::uint64_t* b, std::size_t nb,
                                    std::uint64_t* cur) {
    constexpr std::size_t B = 4;
    std::size_t i = 0;
    std::size_t j = 0;

    while (i + B <= na && j + B <= nb) {
        if (a[i + B - 1] < b[j]) { i += B; continue; }
        if (b[j + B - 1] < a[i]) { j += B; continue; }

        cur = exact_match_u64_avx2(a + i, b + j, cur);

        const std::uint64_t amax = a[i + B - 1];
        const std::uint64_t bmax = b[j + B - 1];
        if (amax <= bmax) i += B;
        if (bmax <= amax) j += B;
    }

    return intersect_scalar(a + i, na - i, b + j, nb - j, cur);
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
std::uint64_t* exact_match_u64_avx512(const std::uint64_t* a,
                                      const std::uint64_t* b,
                                      std::uint64_t* cur) {
    const __m512i va = _mm512_loadu_si512(a);
    const __m512i vb = _mm512_loadu_si512(b);
    // 对8个int64逐个比较，返回的mask,如果bit设置为1，代表a[i] == b[i]
    __mmask8 cmp = _mm512_cmpeq_epi64_mask(va, vb);
    for (int r = 1; r < 8; ++r) {
        const __m512i ridx = _mm512_load_si512(kRot512[r]);
        const __m512i vbr = _mm512_permutexvar_epi64(ridx, vb);
        // 循环比较的时候A不动，只移动B，这样设置位掩码，就代表A中该位命中了
        cmp |= _mm512_cmpeq_epi64_mask(va, vbr);
    }

    // compressstoreu 按 mask 只写 popcount(cmp) 个元素，预分配缓冲下
    // 无需逐块 resize，也无需 cmp==0 早退分支。
    _mm512_mask_compressstoreu_epi64(cur, cmp, va);
    //通过std::popcount来计算2进制中的1的个数，然后移动指针
    return cur + std::popcount(static_cast<unsigned>(cmp));
}

__attribute__((target("avx512f")))
std::uint64_t* intersect_inoue_avx512(const std::uint64_t* a, std::size_t na,
                                      const std::uint64_t* b, std::size_t nb,
                                      std::uint64_t* cur) {
    constexpr std::size_t B = 8;
    std::size_t i = 0;
    std::size_t j = 0;

    while (i + B <= na && j + B <= nb) {
        if (a[i + B - 1] < b[j]) { i += B; continue; }
        if (b[j + B - 1] < a[i]) { j += B; continue; }

        cur = exact_match_u64_avx512(a + i, b + j, cur);

        const std::uint64_t amax = a[i + B - 1];
        const std::uint64_t bmax = b[j + B - 1];
        if (amax <= bmax) i += B;
        if (bmax <= amax) j += B;
    }

    return intersect_scalar(a + i, na - i, b + j, nb - j, cur);
}

#endif  // BITCASK_INTERSECT_SIMD

}  // namespace

void intersect_u64(std::span<const std::uint64_t> a,
                   std::span<const std::uint64_t> b,
                   std::vector<std::uint64_t>& out) {
    out.clear();
    if (a.empty() || b.empty()) return;

    // 结果上界 = min(na, nb)。一次性 resize,内核经裸指针游标写出,
    // 末尾截断。resize 的零填充是一趟顺序写,远比每元素一次
    // push_back 容量检查 + size 读改写便宜。
    const std::size_t bound = std::min(a.size(), b.size());
    out.resize(bound);
    std::uint64_t* const base = out.data();
    std::uint64_t* cur = base;

    if (a.size() * 32 < b.size()) {
        cur = intersect_galloping(a.data(), a.size(), b.data(), b.size(), cur);
        out.resize(static_cast<std::size_t>(cur - base));
        return;
    }
    if (b.size() * 32 < a.size()) {
        cur = intersect_galloping(b.data(), b.size(), a.data(), a.size(), cur);
        out.resize(static_cast<std::size_t>(cur - base));
        return;
    }

#ifdef BITCASK_INTERSECT_SIMD
    static const bool kHasAvx512f = __builtin_cpu_supports("avx512f");
    if (kHasAvx512f) {
        cur = intersect_inoue_avx512(a.data(), a.size(), b.data(), b.size(),
                                     cur);
        out.resize(static_cast<std::size_t>(cur - base));
        return;
    }
    static const bool kHasAvx2 = __builtin_cpu_supports("avx2");
    if (kHasAvx2) {
        cur = intersect_inoue_avx2(a.data(), a.size(), b.data(), b.size(),
                                   cur);
        out.resize(static_cast<std::size_t>(cur - base));
        return;
    }
#endif
    cur = intersect_scalar(a.data(), a.size(), b.data(), b.size(), cur);
    out.resize(static_cast<std::size_t>(cur - base));
}

}  // namespace bitcask::bm25
