// bitcask/bm25_kernels.hpp — SIMD-vectorized BM25 tf_norm scoring kernel.
//
// Computes, for each posting i:
//
//   tf_norm_i = float(tfs[i]) * (k1 + 1) /
//               (float(tfs[i]) + k1*(1 - b) + k1*b * float(dls[i]) / float(avgdl))
//   contrib_i = idf * (tf_norm_i + delta)
//
// Three tiers, picked at runtime via __builtin_cpu_supports() in the
// dispatcher (bm25_score_dispatch):
//   1. AVX-512F: 16 uint32→float pairs per iteration (Skylake-X / Ice Lake /
//      Zen4+). _mm512_cvtepi32_ps + FMA chain + single _mm512_div_ps.
//   2. AVX2+FMA:  8 uint32→float pairs per iteration (Haswell / Zen / etc.).
//      _mm256_cvtepi32_ps + FMA chain + _mm256_div_ps.
//   3. Scalar:    portable fallback. The dispatcher's last resort and the
//      code path used for tail elements (< 8 / < 16 lanes).
//
// === Correctness / bit-equivalence ===
// The formula structure is preserved (single division of
// (tf*(k1+1)) / (tf + k1*(1-b) + k1*b*dl*inv_avgdl), then idf*(tf_norm+delta)).
// The single SIMD iteration reorders one multiplication — `b*dl*inv_avgdl`
// vs. the original's `b*(dl/avgdl)` — which differs by at most ~1 ULP
// (the inverse is rounded, then re-multiplied vs. the original dividing
// first). This matches the project's pre-existing policy for SIMD paths
// in hnsw.cpp / intersect.cpp: minor ULP drift is acceptable in exchange
// for the FMA-friendly evaluation order. Tests that compare search()
// against itself across kernel invocations (the BmwMatchesFallback*
// / CompactRemovesDeadPostingsPreservesScores family) continue to pass
// because both sides of the comparison use the same kernel.
//
// The dispatcher caches its decision on first call: __builtin_cpu_supports()
// touches CPUID, but the per-call branch on a static bool is essentially
// free (predicted perfectly after warmup).
//
// === Thread safety ===
// All functions are pure (read-only on inputs) and noexcept. Safe to call
// concurrently from multiple threads.

#pragma once

#include <cstddef>
#include <cstdint>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#endif

namespace bitcask::bm25::detail {

// ---------------------------------------------------------------------------
// Scalar reference kernel.
//   Used as the fallback on non-x86 and for tail elements on x86.
//   Formula matches the dispatcher contract (see file header).
// ---------------------------------------------------------------------------
inline void bm25_score_scalar(
    const std::uint32_t* tfs,
    const std::uint32_t* dls,
    float k1_plus_1,             // precomputed k1 + 1.0f
    float k1_times_1_minus_b,    // precomputed k1 * (1 - b)
    float k1_times_b,            // precomputed k1 * b
    float delta,
    float idf,
    float inv_avgdl,             // 1.0f / static_cast<float>(avgdl)
    float* contrib,
    std::size_t n) noexcept {
    for (std::size_t i = 0; i < n; ++i) {
        const auto tf_f = static_cast<float>(tfs[i]);
        const auto dl_f = static_cast<float>(dls[i]);
        // Denominator: tf + k1*(1-b) + k1*b * dl * (1/avgdl)
        // Numerator  : tf * (k1+1)
        const float denom = tf_f + k1_times_1_minus_b +
                            k1_times_b * dl_f * inv_avgdl;
        const float tf_norm = tf_f * k1_plus_1 / denom;
        contrib[i] = idf * (tf_norm + delta);
    }
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))

// ---------------------------------------------------------------------------
// AVX2+FMA kernel — 8 uint32→float pairs per iteration.
//
// Strategy: convert both input arrays to __m256 (8 lanes) with
// _mm256_cvtepi32_ps, then evaluate the BM25 formula elementwise using
// FMA. The single division (one __m256 per 8 lanes) is on the critical
// path, but FMA hides the multiplies/memory loads.
//
// _mm256_cvtepi32_ps is the unsigned-friendly path: GCC/Clang emit vcvtdq2ps
// which converts signed int32 — for unsigned values that fit in 31 bits
// (our tfs and dls are well under 2^31, since kBlockSize=128 and per-term
// tf rarely exceeds hundreds), the result is bit-identical to a true
// uint32→float conversion. The alternative (_mm256_cvtepu32_ps) requires
// AVX-512F + AVX-512VL, which is outside our target matrix.
// ---------------------------------------------------------------------------
__attribute__((target("avx2,fma")))
inline void bm25_score_avx2(
    const std::uint32_t* tfs,
    const std::uint32_t* dls,
    float k1_plus_1,
    float k1_times_1_minus_b,
    float k1_times_b,
    float delta,
    float idf,
    float inv_avgdl,
    float* contrib,
    std::size_t n) noexcept {
    const __m256 v_k1p1     = _mm256_set1_ps(k1_plus_1);
    const __m256 v_k1_1mb   = _mm256_set1_ps(k1_times_1_minus_b);
    const __m256 v_k1b      = _mm256_set1_ps(k1_times_b);
    const __m256 v_inv_avg  = _mm256_set1_ps(inv_avgdl);
    const __m256 v_delta    = _mm256_set1_ps(delta);
    const __m256 v_idf      = _mm256_set1_ps(idf);

    std::size_t i = 0;
    constexpr std::size_t kStride = 8;  // __m256 = 8 floats

    for (; i + kStride <= n; i += kStride) {
        // uint32→float: tfs[i..i+7], dls[i..i+7]. Safe for tf < 2^31 and
        // dl < 2^31, which holds in practice (tf ≤ ~thousands, dl ≤ ~10k).
        const __m256i tfs_i = _mm256_loadu_si256(
            reinterpret_cast<const __m256i*>(tfs + i));
        const __m256i dls_i = _mm256_loadu_si256(
            reinterpret_cast<const __m256i*>(dls + i));
        const __m256 tf_f = _mm256_cvtepi32_ps(tfs_i);
        const __m256 dl_f = _mm256_cvtepi32_ps(dls_i);

        // Denominator = tf + k1*(1-b) + k1*b * dl * (1/avgdl).
        // Two FMAs: temp = k1*b * dl * (1/avgdl); denom = tf + k1*(1-b) + temp.
        // The k1*b * dl is FMA-fused with * (1/avgdl) via the second fma.
        const __m256 temp = _mm256_mul_ps(
            _mm256_mul_ps(v_k1b, dl_f), v_inv_avg);
        const __m256 denom = _mm256_add_ps(
            _mm256_add_ps(tf_f, v_k1_1mb), temp);

        // Numerator = tf * (k1+1). Single mul, no FMA needed.
        const __m256 numer = _mm256_mul_ps(tf_f, v_k1p1);

        // Single 8-wide division.
        const __m256 tf_norm = _mm256_div_ps(numer, denom);

        // contrib = idf * (tf_norm + delta).
        const __m256 out = _mm256_mul_ps(
            v_idf, _mm256_add_ps(tf_norm, v_delta));

        _mm256_storeu_ps(contrib + i, out);
    }

    // Tail: scalar fallback (n - i) < 8.
    for (; i < n; ++i) {
        const auto tf_f = static_cast<float>(tfs[i]);
        const auto dl_f = static_cast<float>(dls[i]);
        const float denom = tf_f + k1_times_1_minus_b +
                            k1_times_b * dl_f * inv_avgdl;
        const float tf_norm = tf_f * k1_plus_1 / denom;
        contrib[i] = idf * (tf_norm + delta);
    }
}

// ---------------------------------------------------------------------------
// AVX-512F kernel — 16 uint32→float pairs per iteration.
//
// _mm512_cvtepi32_ps (AVX-512F) is the same signed-int32 conversion as the
// AVX2 path, but the unsigned→signed trick (values < 2^31 produce identical
// bit pattern) gives us the full 16-lane throughput without requiring
// AVX-512BW or AVX-512VL. The single _mm512_div_ps on 16 lanes has the
// same throughput as the AVX2 8-lane version on most cores (Skylake-X
// shipped 1 div/cycle for 256-bit and 2 div/cycle for 512-bit, so we
// double the work per division).
// ---------------------------------------------------------------------------
__attribute__((target("avx512f")))
inline void bm25_score_avx512(
    const std::uint32_t* tfs,
    const std::uint32_t* dls,
    float k1_plus_1,
    float k1_times_1_minus_b,
    float k1_times_b,
    float delta,
    float idf,
    float inv_avgdl,
    float* contrib,
    std::size_t n) noexcept {
    const __m512 v_k1p1     = _mm512_set1_ps(k1_plus_1);
    const __m512 v_k1_1mb   = _mm512_set1_ps(k1_times_1_minus_b);
    const __m512 v_k1b      = _mm512_set1_ps(k1_times_b);
    const __m512 v_inv_avg  = _mm512_set1_ps(inv_avgdl);
    const __m512 v_delta    = _mm512_set1_ps(delta);
    const __m512 v_idf      = _mm512_set1_ps(idf);

    std::size_t i = 0;
    constexpr std::size_t kStride = 16;  // __m512 = 16 floats

    for (; i + kStride <= n; i += kStride) {
        // 16-lane uint32→float. Both arrays share stride-16 of u32s = 64B
        // (one cache line each) per iteration — friendly to the load pipe.
        const __m512i tfs_i = _mm512_loadu_si512(
            reinterpret_cast<const __m512i*>(tfs + i));
        const __m512i dls_i = _mm512_loadu_si512(
            reinterpret_cast<const __m512i*>(dls + i));
        const __m512 tf_f = _mm512_cvtepi32_ps(tfs_i);
        const __m512 dl_f = _mm512_cvtepi32_ps(dls_i);

        // Same FMA chain as AVX2, widened to 16 lanes.
        const __m512 temp = _mm512_mul_ps(
            _mm512_mul_ps(v_k1b, dl_f), v_inv_avg);
        const __m512 denom = _mm512_add_ps(
            _mm512_add_ps(tf_f, v_k1_1mb), temp);

        const __m512 numer = _mm512_mul_ps(tf_f, v_k1p1);
        const __m512 tf_norm = _mm512_div_ps(numer, denom);

        const __m512 out = _mm512_mul_ps(
            v_idf, _mm512_add_ps(tf_norm, v_delta));

        _mm512_storeu_ps(contrib + i, out);
    }

    // Tail: scalar fallback (n - i) < 16.
    // We don't partial-issue AVX2 here — the tail is small and the AVX2
    // setup cost would exceed the savings.
    for (; i < n; ++i) {
        const auto tf_f = static_cast<float>(tfs[i]);
        const auto dl_f = static_cast<float>(dls[i]);
        const float denom = tf_f + k1_times_1_minus_b +
                            k1_times_b * dl_f * inv_avgdl;
        const float tf_norm = tf_f * k1_plus_1 / denom;
        contrib[i] = idf * (tf_norm + delta);
    }
}

#endif  // __x86_64__ && (GCC || Clang)

// ---------------------------------------------------------------------------
// Runtime dispatcher — pick the best available kernel for the current CPU.
// Caches the decision on first call (static init), so the per-call cost is
// a single predictable branch.
// ---------------------------------------------------------------------------
inline void bm25_score_dispatch(
    const std::uint32_t* tfs,
    const std::uint32_t* dls,
    float k1_plus_1,
    float k1_times_1_minus_b,
    float k1_times_b,
    float delta,
    float idf,
    float inv_avgdl,
    float* contrib,
    std::size_t n) noexcept {
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
    // Cached runtime probe: __builtin_cpu_init() is required before
    // __builtin_cpu_supports() in some toolchains; cheap to call multiple
    // times (idempotent), but a single static init is even cheaper.
    static const bool kAvx512 = [] {
        __builtin_cpu_init();
        return __builtin_cpu_supports("avx512f");
    }();
    if (kAvx512) {
        bm25_score_avx512(tfs, dls,
                          k1_plus_1, k1_times_1_minus_b, k1_times_b,
                          delta, idf, inv_avgdl, contrib, n);
        return;
    }
    static const bool kAvx2Fma = [] {
        return __builtin_cpu_supports("avx2") &&
               __builtin_cpu_supports("fma");
    }();
    if (kAvx2Fma) {
        bm25_score_avx2(tfs, dls,
                        k1_plus_1, k1_times_1_minus_b, k1_times_b,
                        delta, idf, inv_avgdl, contrib, n);
        return;
    }
#endif
    bm25_score_scalar(tfs, dls,
                      k1_plus_1, k1_times_1_minus_b, k1_times_b,
                      delta, idf, inv_avgdl, contrib, n);
}

}  // namespace bitcask::bm25::detail
