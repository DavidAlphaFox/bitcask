// 升序去重 u32 数组求交（P2.2，bool_search MUST 交集用）。
//
// 三路实现，按输入形态与硬件自动选择：
//   - 大小悬殊（>32x）：galloping——小数组驱动、指数探查+二分大数组，
//     O(|小| · log|大|)，SIMD 对此形态无益；
//   - 相近大小 + AVX2（运行时 __builtin_cpu_supports 探测）：shuffle 块
//     交集（Schlegel/Lemire 系方案）——8 lane 全对全比较 + LUT 压缩存储；
//   - 其余：标量双指针归并。
//
// 前置：两输入均严格升序且无重复（PostingList 不变量：ord 单调分配、
// add_doc 不重复，live 过滤保序）。结果同样升序无重复。
//
// ord 是 u64，本接口收 u32——caller 在查询内做安全窄化（fp.ords 升序，
// 检查 back() ≤ 0xFFFFFFFF 即可，见 bool_search；超界走 u64 标量旧路径）。

#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace bitcask::bm25 {

// 结果写入 out（内部先 clear）。
void intersect_u32(std::span<const std::uint32_t> a,
                   std::span<const std::uint32_t> b,
                   std::vector<std::uint32_t>& out);

}  // namespace bitcask::bm25
