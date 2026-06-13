#pragma once
//
// Levenshtein 编辑距离：Levenshtein 1966, "Binary codes capable of correcting
//   deletions, insertions and reversals". 经典 O(n*m) 动态规划实现，维护完整矩阵。

#include <algorithm>
#include <cstdint>
#include <string_view>
#include <vector>

namespace bitcask::bm25 {

[[nodiscard]] inline uint32_t levenshtein_distance(std::string_view a, std::string_view b) {
    if (a.empty()) return static_cast<uint32_t>(b.size());
    if (b.empty()) return static_cast<uint32_t>(a.size());

    std::vector<uint32_t> prev(b.size() + 1);
    std::vector<uint32_t> curr(b.size() + 1);

    for (size_t j = 0; j <= b.size(); ++j) {
        prev[j] = static_cast<uint32_t>(j);
    }

    for (size_t i = 0; i < a.size(); ++i) {
        curr[0] = static_cast<uint32_t>(i + 1);
        for (size_t j = 0; j < b.size(); ++j) {
            uint32_t cost = (a[i] == b[j]) ? 0 : 1;
            curr[j + 1] = std::min({
                prev[j + 1] + 1,
                curr[j] + 1,
                prev[j] + cost
            });
        }
        std::swap(prev, curr);
    }

    return prev[b.size()];
}

}
