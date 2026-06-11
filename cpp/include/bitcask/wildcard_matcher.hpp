#pragma once

#include <string_view>

namespace bitcask::bm25 {

// P2.5：取模式中最长的字面量段（不含 * 和 ?）。任何能匹配该模式的文本
// 必然包含每个字面量段作为子串（* 任意填充、? 恰一字符，都不改变段本身）
// —— 所以「不含最长段」是充分的拒绝条件，可用 string_view::find（glibc
// memchr/memcmp 已 SIMD 化）做词典扫描预过滤；通过预过滤的词再跑完整
// wildcard_match。
[[nodiscard]] inline std::string_view longest_literal(std::string_view pattern) {
    std::string_view best;
    std::size_t start = 0;
    for (std::size_t i = 0; i <= pattern.size(); ++i) {
        if (i == pattern.size() || pattern[i] == '*' || pattern[i] == '?') {
            if (i - start > best.size()) {
                best = pattern.substr(start, i - start);
            }
            start = i + 1;
        }
    }
    return best;
}

inline bool wildcard_match(std::string_view pattern, std::string_view text) {
    std::size_t p = 0, t = 0;
    std::size_t star_idx = pattern.size();
    std::size_t match = 0;

    while (t < text.size()) {
        if (p < pattern.size() && (pattern[p] == text[t] || pattern[p] == '?')) {
            ++p;
            ++t;
        } else if (p < pattern.size() && pattern[p] == '*') {
            star_idx = p;
            match = t;
            ++p;
        } else if (star_idx != pattern.size()) {
            p = star_idx + 1;
            ++match;
            t = match;
        } else {
            return false;
        }
    }

    while (p < pattern.size() && pattern[p] == '*') {
        ++p;
    }

    return p == pattern.size();
}

}
