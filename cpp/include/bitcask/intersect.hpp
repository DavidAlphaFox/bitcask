// 升序去重 u64 数组求交（Inoue 块过滤 + SIMD 精确匹配）。
//
// 三路实现，按输入形态与硬件自动选择：
//   - 大小悬殊（>32x）：galloping——小数组驱动、指数探查+二分大数组，
//     O(|小| · log|大|)，SIMD 对此形态无益；
//   - 相近大小 + AVX2：Inoue 块过滤 + 原生 u64 SIMD 精确匹配——
//     非重叠块 O(1) 标量跳过，重叠块 4-lane permute4x64 全对全比较 +
//     条件提取（零 LUT）；
//   - 其余：标量双指针归并。
//
// 前置：两输入均严格升序且无重复（PostingList 不变量：ord 单调分配、
// add_doc 不重复，live 过滤保序）。结果同样升序无重复。

#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace bitcask::bm25 {

// 结果写入 out（内部先 clear）。
void intersect_u64(std::span<const std::uint64_t> a,
                   std::span<const std::uint64_t> b,
                   std::vector<std::uint64_t>& out);

}  // namespace bitcask::bm25
