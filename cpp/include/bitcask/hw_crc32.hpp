// bitcask/hw_crc32.hpp — CRC32 IEEE 802.3 (polynomial 0xEDB88320) with
// PCLMULQDQ hardware acceleration.
//
// Three tiers, picked at runtime via __builtin_cpu_supports():
//   1. SSE4.2 + PCLMULQDQ: 16-byte-at-a-time carryless folding. ~10 GB/s on
//      modern x86. Used for inputs >= 16 bytes (after head-alignment).
//   2. Slice-by-1 bytewise table: head-alignment bytes + tail < 16 bytes.
//      Same polynomial as zlib; always bit-identical to zlib::crc32().
//   3. zlib ::crc32() — portable scalar fallback for non-x86.
//
// === Streaming / incrementality ===
// Public API matches bitcask::codec::crc32_update:
//   seed is the previous CRC32 result (zlib format: invert at start, invert
//   at end). Returns the CRC32 of (seed_so_far || data) in zlib format.
//
// Internal computation works on the non-inverted polynomial state, because
// that's what PCLMULQDQ folding expects. The wrapper does the initial/final
// inversion around the call.
//
// === Correctness ===
// All three paths produce bit-identical results to zlib's ::crc32() on every
// length from 0 to a few KiB. The benchmark's startup self-test enforces this.
//
// === Thread safety ===
// All functions are pure (read-only on the input span) and noexcept. Safe to
// call concurrently from multiple threads.

#pragma once

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#include <wmmintrin.h>   // _mm_clmulepi64_si128
#endif

#include <zlib.h>

namespace bitcask::hw {

// ---------------------------------------------------------------------------
// Scalar (bytewise) CRC32 — IEEE 802.3 reflected polynomial 0xEDB88320.
// Used for short inputs (< 16 bytes) and for head/tail bytes around the
// PCLMULQDQ fast path. Bit-identical to zlib::crc32().
// ---------------------------------------------------------------------------
namespace detail {

// Standard reflected CRC32 lookup table: t[i] = CRC32(i). Generated at
// compile time from the polynomial 0xEDB88320 (see gen_crc_table logic in
// the test setup). alignas(64) so an aggressive compiler can vectorize a
// table-driven inner loop if it ever wants to.
inline constexpr std::array<std::uint32_t, 256> kCrc32Table = {
    0x00000000u, 0x77073096u, 0xEE0E612Cu, 0x990951BAu, 0x076DC419u, 0x706AF48Fu, 0xE963A535u, 0x9E6495A3u,
    0x0EDB8832u, 0x79DCB8A4u, 0xE0D5E91Eu, 0x97D2D988u, 0x09B64C2Bu, 0x7EB17CBDu, 0xE7B82D07u, 0x90BF1D91u,
    0x1DB71064u, 0x6AB020F2u, 0xF3B97148u, 0x84BE41DEu, 0x1ADAD47Du, 0x6DDDE4EBu, 0xF4D4B551u, 0x83D385C7u,
    0x136C9856u, 0x646BA8C0u, 0xFD62F97Au, 0x8A65C9ECu, 0x14015C4Fu, 0x63066CD9u, 0xFA0F3D63u, 0x8D080DF5u,
    0x3B6E20C8u, 0x4C69105Eu, 0xD56041E4u, 0xA2677172u, 0x3C03E4D1u, 0x4B04D447u, 0xD20D85FDu, 0xA50AB56Bu,
    0x35B5A8FAu, 0x42B2986Cu, 0xDBBBC9D6u, 0xACBCF940u, 0x32D86CE3u, 0x45DF5C75u, 0xDCD60DCFu, 0xABD13D59u,
    0x26D930ACu, 0x51DE003Au, 0xC8D75180u, 0xBFD06116u, 0x21B4F4B5u, 0x56B3C423u, 0xCFBA9599u, 0xB8BDA50Fu,
    0x2802B89Eu, 0x5F058808u, 0xC60CD9B2u, 0xB10BE924u, 0x2F6F7C87u, 0x58684C11u, 0xC1611DABu, 0xB6662D3Du,
    0x76DC4190u, 0x01DB7106u, 0x98D220BCu, 0xEFD5102Au, 0x71B18589u, 0x06B6B51Fu, 0x9FBFE4A5u, 0xE8B8D433u,
    0x7807C9A2u, 0x0F00F934u, 0x9609A88Eu, 0xE10E9818u, 0x7F6A0DBBu, 0x086D3D2Du, 0x91646C97u, 0xE6635C01u,
    0x6B6B51F4u, 0x1C6C6162u, 0x856530D8u, 0xF262004Eu, 0x6C0695EDu, 0x1B01A57Bu, 0x8208F4C1u, 0xF50FC457u,
    0x65B0D9C6u, 0x12B7E950u, 0x8BBEB8EAu, 0xFCB9887Cu, 0x62DD1DDFu, 0x15DA2D49u, 0x8CD37CF3u, 0xFBD44C65u,
    0x4DB26158u, 0x3AB551CEu, 0xA3BC0074u, 0xD4BB30E2u, 0x4ADFA541u, 0x3DD895D7u, 0xA4D1C46Du, 0xD3D6F4FBu,
    0x4369E96Au, 0x346ED9FCu, 0xAD678846u, 0xDA60B8D0u, 0x44042D73u, 0x33031DE5u, 0xAA0A4C5Fu, 0xDD0D7CC9u,
    0x5005713Cu, 0x270241AAu, 0xBE0B1010u, 0xC90C2086u, 0x5768B525u, 0x206F85B3u, 0xB966D409u, 0xCE61E49Fu,
    0x5EDEF90Eu, 0x29D9C998u, 0xB0D09822u, 0xC7D7A8B4u, 0x59B33D17u, 0x2EB40D81u, 0xB7BD5C3Bu, 0xC0BA6CADu,
    0xEDB88320u, 0x9ABFB3B6u, 0x03B6E20Cu, 0x74B1D29Au, 0xEAD54739u, 0x9DD277AFu, 0x04DB2615u, 0x73DC1683u,
    0xE3630B12u, 0x94643B84u, 0x0D6D6A3Eu, 0x7A6A5AA8u, 0xE40ECF0Bu, 0x9309FF9Du, 0x0A00AE27u, 0x7D079EB1u,
    0xF00F9344u, 0x8708A3D2u, 0x1E01F268u, 0x6906C2FEu, 0xF762575Du, 0x806567CBu, 0x196C3671u, 0x6E6B06E7u,
    0xFED41B76u, 0x89D32BE0u, 0x10DA7A5Au, 0x67DD4ACCu, 0xF9B9DF6Fu, 0x8EBEEFF9u, 0x17B7BE43u, 0x60B08ED5u,
    0xD6D6A3E8u, 0xA1D1937Eu, 0x38D8C2C4u, 0x4FDFF252u, 0xD1BB67F1u, 0xA6BC5767u, 0x3FB506DDu, 0x48B2364Bu,
    0xD80D2BDAu, 0xAF0A1B4Cu, 0x36034AF6u, 0x41047A60u, 0xDF60EFC3u, 0xA867DF55u, 0x316E8EEFu, 0x4669BE79u,
    0xCB61B38Cu, 0xBC66831Au, 0x256FD2A0u, 0x5268E236u, 0xCC0C7795u, 0xBB0B4703u, 0x220216B9u, 0x5505262Fu,
    0xC5BA3BBEu, 0xB2BD0B28u, 0x2BB45A92u, 0x5CB36A04u, 0xC2D7FFA7u, 0xB5D0CF31u, 0x2CD99E8Bu, 0x5BDEAE1Du,
    0x9B64C2B0u, 0xEC63F226u, 0x756AA39Cu, 0x026D930Au, 0x9C0906A9u, 0xEB0E363Fu, 0x72076785u, 0x05005713u,
    0x95BF4A82u, 0xE2B87A14u, 0x7BB12BAEu, 0x0CB61B38u, 0x92D28E9Bu, 0xE5D5BE0Du, 0x7CDCEFB7u, 0x0BDBDF21u,
    0x86D3D2D4u, 0xF1D4E242u, 0x68DDB3F8u, 0x1FDA836Eu, 0x81BE16CDu, 0xF6B9265Bu, 0x6FB077E1u, 0x18B74777u,
    0x88085AE6u, 0xFF0F6A70u, 0x66063BCAu, 0x11010B5Cu, 0x8F659EFFu, 0xF862AE69u, 0x616BFFD3u, 0x166CCF45u,
    0xA00AE278u, 0xD70DD2EEu, 0x4E048354u, 0x3903B3C2u, 0xA7672661u, 0xD06016F7u, 0x4969474Du, 0x3E6E77DBu,
    0xAED16A4Au, 0xD9D65ADCu, 0x40DF0B66u, 0x37D83BF0u, 0xA9BCAE53u, 0xDEBB9EC5u, 0x47B2CF7Fu, 0x30B5FFE9u,
    0xBDBDF21Cu, 0xCABAC28Au, 0x53B39330u, 0x24B4A3A6u, 0xBAD03605u, 0xCDD70693u, 0x54DE5729u, 0x23D967BFu,
    0xB3667A2Eu, 0xC4614AB8u, 0x5D681B02u, 0x2A6F2B94u, 0xB40BBE37u, 0xC30C8EA1u, 0x5A05DF1Bu, 0x2D02EF8Du,
};

// Apply CRC32 IEEE 802.3 to (buf, len) starting from internal state
// `crc_internal` (the polynomial state zlib would see as `seed ^ 0xFFFFFFFF`
// before processing its first byte — i.e., `0xFFFFFFFF` for a fresh call).
// Returns the new internal state in the same convention.
//
// Matches zlib's table-driven base (crc32_l / crc32_z) modulo the inversion
// convention. zlib inverts input and output around its base, so its internal
// `c` accumulator sees:
//   c = (zlib_seed ^ 0xFFFFFFFF) initially;
//   for each byte b: c = table[(c ^ b) & 0xFF] ^ (c >> 8);
//   return c ^ 0xFFFFFFFF;
// Our `crc_internal` IS zlib's internal `c` — no further inversion here.
inline std::uint32_t crc32_bytewise(std::uint32_t crc_internal,
                                    const std::byte* buf,
                                    std::size_t len) noexcept {
    std::uint32_t c = crc_internal;
    const auto* p = reinterpret_cast<const std::uint8_t*>(buf);
    // Process 8 bytes per iteration when possible — better i-cache behavior
    // on the small 1KB table (still tiny but halves loop overhead).
    while (len >= 8) {
        c = kCrc32Table[(c ^ p[0]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[1]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[2]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[3]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[4]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[5]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[6]) & 0xFF] ^ (c >> 8);
        c = kCrc32Table[(c ^ p[7]) & 0xFF] ^ (c >> 8);
        p += 8;
        len -= 8;
    }
    for (std::size_t i = 0; i < len; ++i) {
        c = kCrc32Table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    }
    return c;
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))

// ---------------------------------------------------------------------------
// PCLMULQDQ hardware path. Bit-reflected CRC32 IEEE 802.3 (poly 0xEDB88320).
//
// Constants are from Intel's paper "Fast CRC Computation for Generic
// Polynomials Using PCLMULQDQ Instruction" and match the Linux kernel
// arch/x86/crypto/crc32-pclmul_asm.S implementation (kernel 5.10+). All
// values are stored as 64-bit big-endian hex (low bit of exponent is at
// bit 63, after the implicit <<1 for the reflected polynomial).
//
//   k1 (R1): x^(4*128+32) mod P, <<32 reflected & xored = 0x0000000154442bd4
//   k2 (R2): x^(4*128-32) mod P, <<32 reflected & xored = 0x00000001c6e41596
//   k3 (R3): x^(  128+32) mod P, <<32 reflected & xored = 0x00000001751997d0
//   k4 (R4): x^(  128-32) mod P, <<32 reflected & xored = 0x00000000ccaa009e
//   k5 (R5): x^(   64+32) mod P, <<32 reflected & xored = 0x0000000163cd6124
//   mu:      floor(x^64 / P)         reflected          = 0x00000001f7011641
//   poly:    P(x) << 1 reflected                         = 0x00000001db710641
//
// We use 128-bit SSE (_mm_*) intrinsics — no AVX-512, so this works on every
// x86_64 with PCLMULQDQ (Westmere 2010+, Bulldozer 2011+, all Silvermont,
// all current server/consumer chips).
// ---------------------------------------------------------------------------
alignas(16) inline constexpr std::uint8_t kK1K2Bytes[16] = {
    // low qword  = 0x0000000154442bd4  (Intel's k2 = x^(4*128+32) mod P)
    0xd4, 0x2b, 0x44, 0x54, 0x01, 0x00, 0x00, 0x00,
    // high qword = 0x00000001c6e41596  (Intel's k1 = x^(4*128-32) mod P)
    0x96, 0x15, 0xe4, 0xc6, 0x01, 0x00, 0x00, 0x00,
};
alignas(16) inline constexpr std::uint8_t kK3K4Bytes[16] = {
    // low qword  = 0x00000001751997d0  (Intel's k3 = x^(128+32) mod P)
    0xd0, 0x97, 0x19, 0x75, 0x01, 0x00, 0x00, 0x00,
    // high qword = 0x00000000ccaa009e  (Intel's k4 = x^(128-32) mod P)
    0x9e, 0x00, 0xaa, 0xcc, 0x00, 0x00, 0x00, 0x00,
};
alignas(16) inline constexpr std::uint8_t kK5K0Bytes[16] = {
    // low qword  = 0x0000000163cd6124  (Intel's k5 = x^(64+32) mod P)
    0x24, 0x61, 0xcd, 0x63, 0x01, 0x00, 0x00, 0x00,
    // high qword = 0  (unused; k5 fits in the low qword)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
alignas(16) inline constexpr std::uint8_t kMask32Bytes[16] = {
    // mask of 0xFFFFFFFF in the low 32 bits — used both as the bit-mask for
    // the 64→32 fold (simd_crc uses x3 = {~0, 0, ~0, 0}; same mask shape).
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
alignas(16) inline constexpr std::uint8_t kMuPolyBytes[16] = {
    // low qword  = 0x00000001db710641  (P(x) << 1 reflected)
    0x41, 0x06, 0x71, 0xdb, 0x01, 0x00, 0x00, 0x00,
    // high qword = 0x00000001f7011641  (floor(x^64 / P) reflected = mu)
    0x41, 0x16, 0x01, 0xf7, 0x01, 0x00, 0x00, 0x00,
};

// Fold one __m128i lane with (k1, k2) and XOR the next 16 bytes of input.
// `xmm` is in/out; `next` is XOR'd in after the fold. Mirrors the kernel's
// loop_64 step (and simd_crc's main loop), with our constant layout where
// k1k2.low = k2 (high-exponent constant) and k1k2.high = k1 (low-exponent
// constant) — see kK1K2Bytes comment above.
[[gnu::target("sse4.2,pclmul")]]
inline __m128i fold_one(__m128i xmm, __m128i k1k2, __m128i next) noexcept {
    const __m128i lo = _mm_clmulepi64_si128(xmm, k1k2, 0x00);  // xmm.low × k2
    const __m128i hi = _mm_clmulepi64_si128(xmm, k1k2, 0x11);  // xmm.high × k1
    return _mm_xor_si128(_mm_xor_si128(lo, hi), next);
}

// PCLMULQDQ-based CRC32 on an aligned body of length len (must be >= 64 and
// a multiple of 16). Caller must have already processed any leading
// head-alignment bytes via crc32_bytewise. `crc_internal` is the
// non-inverted polynomial state from the previous call (or `~0` for the
// start of a fresh computation).
//
// Returns the new non-inverted internal state.
//
// Algorithm structure mirrors Chromium's crc32_sse42_simd_ (used in zlib):
//   1. Load 4 × 16 bytes; XOR seed into lane 0's low 32 bits.
//   2. Fold next 64-byte blocks in parallel (4 lanes × 16-byte fold).
//   3. Reduce 4 lanes → 1 lane (three 16-byte folds using k3/k4).
//   4. Reduce remaining 16-byte tail blocks to 1 lane.
//   5. 128 → 64 fold (one PCLMULQDQ + shift).
//   6. 64 → 32 fold (mask + PCLMULQDQ + XOR).
//   7. Barrett reduction 64 → 32.
//
// The 64-byte minimum matches the kernel's crc32_pclmul_le_16 contract:
// Step 1 unconditionally reads 4 × 16 bytes, so the body must contain at
// least that much.
[[gnu::target("sse4.2,pclmul")]]
inline std::uint32_t crc32_pclmul(std::uint32_t crc_internal,
                                  const std::byte* buf,
                                  std::size_t len) noexcept {
    const __m128i k1k2   = _mm_load_si128(reinterpret_cast<const __m128i*>(kK1K2Bytes));
    const __m128i k3k4   = _mm_load_si128(reinterpret_cast<const __m128i*>(kK3K4Bytes));
    const __m128i k5     = _mm_loadl_epi64(reinterpret_cast<const __m128i*>(kK5K0Bytes));
    const __m128i mask32 = _mm_load_si128(reinterpret_cast<const __m128i*>(kMask32Bytes));
    const __m128i mupoly = _mm_load_si128(reinterpret_cast<const __m128i*>(kMuPolyBytes));

    // Step 1: load the first 4 × 16 bytes; XOR the seed into lane 0's low
    // 32 bits. (XORing into the low 32 bits, with the rest of the seed_vec
    // zeroed, leaves the rest of xmm1 = the original 16 bytes of input.)
    __m128i xmm1 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(buf + 0x00));
    __m128i xmm2 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(buf + 0x10));
    __m128i xmm3 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(buf + 0x20));
    __m128i xmm4 = _mm_loadu_si128(reinterpret_cast<const __m128i*>(buf + 0x30));
    xmm1 = _mm_xor_si128(xmm1, _mm_cvtsi32_si128(static_cast<int>(crc_internal)));

    const std::byte* p = buf + 0x40;
    std::size_t remaining = len - 0x40;

    // Step 2: 64-byte fold loop. Each iteration folds 4 × 16-byte blocks
    // (already in xmm1..xmm4) and pulls in the next 64 bytes from input.
    while (remaining >= 0x40) {
        xmm1 = fold_one(xmm1, k1k2, _mm_loadu_si128(reinterpret_cast<const __m128i*>(p + 0x00)));
        xmm2 = fold_one(xmm2, k1k2, _mm_loadu_si128(reinterpret_cast<const __m128i*>(p + 0x10)));
        xmm3 = fold_one(xmm3, k1k2, _mm_loadu_si128(reinterpret_cast<const __m128i*>(p + 0x20)));
        xmm4 = fold_one(xmm4, k1k2, _mm_loadu_si128(reinterpret_cast<const __m128i*>(p + 0x30)));
        p         += 0x40;
        remaining -= 0x40;
    }

    // Step 3: fold the remaining 3 lanes (xmm2..xmm4) into xmm1 using (k3, k4).
    {
        __m128i tmp;
        tmp  = _mm_clmulepi64_si128(xmm1, k3k4, 0x00);  // xmm1.low × k3
        xmm1 = _mm_clmulepi64_si128(xmm1, k3k4, 0x11);  // xmm1.high × k4
        xmm1 = _mm_xor_si128(xmm1, tmp);
        xmm1 = _mm_xor_si128(xmm1, xmm2);

        tmp  = _mm_clmulepi64_si128(xmm1, k3k4, 0x00);
        xmm1 = _mm_clmulepi64_si128(xmm1, k3k4, 0x11);
        xmm1 = _mm_xor_si128(xmm1, tmp);
        xmm1 = _mm_xor_si128(xmm1, xmm3);

        tmp  = _mm_clmulepi64_si128(xmm1, k3k4, 0x00);
        xmm1 = _mm_clmulepi64_si128(xmm1, k3k4, 0x11);
        xmm1 = _mm_xor_si128(xmm1, tmp);
        xmm1 = _mm_xor_si128(xmm1, xmm4);
    }

    // Step 4: 16-byte tail loop. Each remaining full 16-byte block gets
    // folded into xmm1 with (k3, k4).
    while (remaining >= 0x10) {
        __m128i tmp;
        tmp  = _mm_clmulepi64_si128(xmm1, k3k4, 0x00);
        xmm1 = _mm_clmulepi64_si128(xmm1, k3k4, 0x11);
        xmm1 = _mm_xor_si128(xmm1, tmp);
        xmm1 = _mm_xor_si128(
            xmm1, _mm_loadu_si128(reinterpret_cast<const __m128i*>(p)));
        p         += 0x10;
        remaining -= 0x10;
    }

    // Step 5: 128 → 64 fold. Appends 32 zero bits to the stream; reduces
    // 128 bits to 64. PCLMULQDQ imm=0x10 = (xmm.low × k3k4.high) =
    // (xmm.low × k4); then shift xmm right by 64 bits and XOR the product
    // in. (Kernel's $0x01 form is equivalent under the k3k4 layout used
    // here — see kK3K4Bytes comment.)
    {
        __m128i tmp = _mm_clmulepi64_si128(xmm1, k3k4, 0x10);
        xmm1 = _mm_srli_si128(xmm1, 8);
        xmm1 = _mm_xor_si128(xmm1, tmp);
    }

    // Step 6: 64 → 32 fold. Mask low 32 bits, fold with k5 (R5 sits in the
    // low 64 bits of xmm loaded from k5k0), XOR with the upper 32 bits
    // (shifted into the low 32 of hi32) to get the 32-bit folded state.
    {
        __m128i hi32 = _mm_srli_si128(xmm1, 4);
        __m128i lo32 = _mm_and_si128(xmm1, mask32);
        __m128i fold = _mm_clmulepi64_si128(lo32, k5, 0x00);
        xmm1 = _mm_xor_si128(fold, hi32);
    }

    // Step 7: Barrett reduction 64 → 32. mupoly = {poly, mu}; the fold is
    //   tmp = (state & mask32)              // low 32 bits
    //   tmp = clmul(tmp, mupoly, 0x10)      // (tmp.low × mu)
    //   tmp &= mask32                       // keep low 32 bits of mu * low
    //   tmp = clmul(tmp, mupoly, 0x00)      // (tmp × poly)
    //   result = tmp ^ state
    //   final  = bits 32-63 of result
    {
        const __m128i state = xmm1;
        __m128i tmp = _mm_and_si128(state, mask32);
        tmp = _mm_clmulepi64_si128(tmp, mupoly, 0x10);
        tmp = _mm_and_si128(tmp, mask32);
        tmp = _mm_clmulepi64_si128(tmp, mupoly, 0x00);
        tmp = _mm_xor_si128(tmp, state);
        return static_cast<std::uint32_t>(
            _mm_extract_epi32(tmp, 1));
    }
}

// True iff CPU supports both sse4.2 and pclmul. Cached after first call.
inline bool has_pclmul_crc32() noexcept {
#if defined(__GNUC__) || defined(__clang__)
    static const bool k = __builtin_cpu_supports("sse4.2") &&
                          __builtin_cpu_supports("pclmul");
    return k;
#else
    return false;
#endif
}

#endif  // __x86_64__

}  // namespace detail

// ---------------------------------------------------------------------------
// Public API (matches bitcask::codec::crc32 / crc32_update signatures).
// ---------------------------------------------------------------------------

// Streaming CRC32. `seed` is the previous result (zlib format: invert-at-
// start, invert-at-end). Returns CRC32(seed||data) in zlib format.
inline std::uint32_t crc32_update(std::uint32_t seed,
                                  std::span<const std::byte> data) noexcept {
    if (data.empty()) return seed;

    // zlib's ::crc32 handles the inversion in/out for us. Use it for very
    // short inputs to avoid the PCLMULQDQ setup overhead.
    if (data.size() < 16) {
        return static_cast<std::uint32_t>(
            ::crc32(static_cast<uLong>(seed),
                    reinterpret_cast<const Bytef*>(data.data()),
                    static_cast<uInt>(data.size())));
    }

    const std::byte* p   = data.data();
    std::size_t      len = data.size();

    // Internal (non-inverted) state corresponding to zlib's seed.
    const std::uint32_t inv_seed = ~seed;

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
    if (detail::has_pclmul_crc32()) {
        // Step A: process 0..15 leading bytes bytewise to align p to 16.
        // Mirrors the Linux kernel's crc32_le_arch() head-alignment step.
        const std::uintptr_t misalign =
            (16u - (reinterpret_cast<std::uintptr_t>(p) & 15u)) & 15u;
        std::uint32_t c = inv_seed;
        if (misalign) {
            const std::size_t take = std::min<std::size_t>(misalign, len);
            c = detail::crc32_bytewise(c, p, take);
            p   += take;
            len -= take;
        }
        // Step B: PCLMULQDQ on the aligned body. The hardware kernel
        // requires at least 64 bytes (Step 1 reads 4 × 16 unconditionally).
        // Smaller aligned bodies fall through to bytewise — still vectorized
        // by the compiler as a tight loop over the 1 KB table, no big deal.
        if (len >= 64) {
            const std::size_t body = len & ~std::size_t{15};
            c = detail::crc32_pclmul(c, p, body);
            p   += body;
            len -= body;
        }
        // Step C: trailing bytes (< 16) handled bytewise. Also covers the
        // small-aligned case (16..63) where we skipped the hardware path.
        if (len) {
            c = detail::crc32_bytewise(c, p, len);
        }
        return ~c;
    }
#endif

    // Generic x86 / non-x86: bytewise path. Equivalent to zlib for all sizes.
    return static_cast<std::uint32_t>(
        ::crc32(static_cast<uLong>(seed),
                reinterpret_cast<const Bytef*>(data.data()),
                static_cast<uInt>(data.size())));
}

// One-shot CRC32 of a single span.
inline std::uint32_t crc32(std::span<const std::byte> data) noexcept {
    return crc32_update(0u, data);
}

}  // namespace bitcask::hw