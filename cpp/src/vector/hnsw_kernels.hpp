// V3.9:距离内核内部声明。仅供 cpp/bench/distance_bench.cpp 等 micro-bench
// 直接调用同一编译单元外的实现做对拍/计时;不进入 public include/。
// 这些函数与 hnsw.cpp 的实现在同一份代码,只是把"匿名命名空间"换成
// bitcask::vec::detail 让外部 TU 可见;签名、算法、target 属性一致。

#pragma once

#include <cstddef>

namespace bitcask::vec::detail {

// 标量内核(始终可用,无 ISA 守卫)。
float dot_scalar(const float* a, const float* b, std::size_t n);
float l2_scalar(const float* a, const float* b, std::size_t n);

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
// AVX2+FMA 内核。仅在支持的目标上调用;bench 用 __builtin_cpu_supports
// 运行时探测,见 distance_bench.cpp。target 属性让函数体只在该 ISA 上
// 发射,跨 ISA 调用由 ifunc / target_clones 解析。
__attribute__((target("avx2,fma"))) float dot_avx2(const float* a,
                                                  const float* b, std::size_t n);
__attribute__((target("avx2,fma"))) float l2_avx2(const float* a,
                                                  const float* b, std::size_t n);

// AVX-512F 内核。AVX512F 子集(无 BW/VL/IFMA/DQ 等)→ 覆盖 Skylake-X /
// Ice Lake / Zen4 起的所有 AVX-512 设备。
__attribute__((target("avx512f"))) float dot_avx512(const float* a,
                                                    const float* b,
                                                    std::size_t n);
__attribute__((target("avx512f"))) float l2_avx512(const float* a,
                                                    const float* b,
                                                    std::size_t n);
#endif

}  // namespace bitcask::vec::detail
