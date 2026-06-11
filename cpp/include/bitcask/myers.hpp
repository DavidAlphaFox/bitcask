// Myers 位并行编辑距离（P2.3）。原理与公式推导见
// doc/myers-bitparallel-zh.md；本实现为单字版本（模式串 ≤64 字节，
// 分词产物恒满足；超长时退回经典 DP）。
//
// 用法：每个查询词构造一次 MyersMatcher（Peq 表 O(256) 一次性построй，
// 摊销于整个词典扫描），对每个词典词调 within(term, k)。
//
// 与 fuzzy_matcher.hpp 的 levenshtein_distance 字节语义一致
// （按字节比较，多字节 UTF-8 串行为相同），black-box 对拍见
// fuzzy_test.cpp 的 MyersAgreesWithLevenshtein。

#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <string_view>

#include "bitcask/fuzzy_matcher.hpp"

namespace bitcask::bm25 {

class MyersMatcher {
public:
    explicit MyersMatcher(std::string_view pattern)
        : m_(pattern.size()),
          // 仅 m>64 回退路径需要原串；持 owned string 而非 string_view，
          // 避免 caller 用临时串构造（如 MyersMatcher(make_token())）时
          // 在那条最冷、最难复现的路径上悬垂读。≤64 路径不碰它。
          pattern_(m_ > 64 ? std::string(pattern) : std::string()) {
        if (m_ == 0 || m_ > 64) return;  // 空串/超长走特判与回退
        for (std::size_t i = 0; i < m_; ++i) {
            peq_[static_cast<unsigned char>(pattern[i])] |= 1ULL << i;
        }
    }

    // 编辑距离 distance(pattern, text) 是否 ≤ k。
    // 提前终止：score 是 pattern 对 text 前缀的距离，剩余每列最多 −1，
    // score > k + 剩余列数 时必然超界，立即放弃。
    [[nodiscard]] bool within(std::string_view text, std::uint32_t k) const {
        if (m_ == 0) return text.size() <= k;
        if (m_ > 64) {
            // 超长模式串（分词产物中不该出现）：退回经典 DP 保正确。
            return levenshtein_distance(pattern_, text) <= k;
        }

        std::uint64_t vp = ~0ULL;
        std::uint64_t vn = 0;
        auto score = static_cast<std::int64_t>(m_);
        const std::uint64_t last = 1ULL << (m_ - 1);
        const auto n = static_cast<std::int64_t>(text.size());

        for (std::int64_t j = 0; j < n; ++j) {
            const std::uint64_t eq = peq_[static_cast<unsigned char>(
                text[static_cast<std::size_t>(j)])];
            const std::uint64_t xv = eq | vn;
            const std::uint64_t xh = (((eq & vp) + vp) ^ vp) | eq;
            std::uint64_t ph = vn | ~(xh | vp);
            std::uint64_t mh = vp & xh;
            if (ph & last) {
                ++score;
            } else if (mh & last) {
                --score;
            }
            ph = (ph << 1) | 1;
            mh <<= 1;
            vp = mh | ~(xv | ph);
            vn = ph & xv;

            if (score > static_cast<std::int64_t>(k) + (n - j - 1)) {
                return false;
            }
        }
        return score <= static_cast<std::int64_t>(k);
    }

private:
    std::array<std::uint64_t, 256> peq_{};
    std::size_t m_ = 0;
    std::string pattern_;  // 仅 m>64 回退路径用（owned，无生命周期前提）
};

}  // namespace bitcask::bm25
