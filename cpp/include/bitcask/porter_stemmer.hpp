// 英文 Porter 词干提取器（S8.1）。
//
// 实现 Martin Porter 经典的 5 步词干提取算法。
// 将英文单词还原为词干形式："running" → "run"，"generalization" → "general"。
// 仅处理纯 ASCII 字母组成、长度大于 2 的拉丁词；
// CJK 字符、短词或含非字母字符的词直接返回原样。
//
// O6：所有谓词/measure 基于 string_view（前缀直接取 substr 视图，不再
// 物化 std::string），后缀替换用 resize+append 原地改。stemming 开启时
// 该文件在每个英文 token 上跑 5 步，此前每步多次堆分配。

#pragma once

#include <string>
#include <string_view>
#include <utility>

namespace bitcask::text {
namespace detail {

inline bool is_consonant(std::string_view s, std::size_t i) {
    switch (s[i]) {
        case 'a': case 'e': case 'i': case 'o': case 'u': return false;
        case 'y': return i == 0 ? true : !is_consonant(s, i - 1);
        default: return true;
    }
}

// 计算词干测量值 m。
// m = VC 序列个数。VC 序列 = 一个元音后面跟零个或多个辅音。
// (C)VC^m = m 个 VC 序列，前面可以有零个或多个辅音。
inline int measure(std::string_view s) {
    int m = 0;
    std::size_t i = 0;
    // 跳过前导辅音
    while (i < s.size() && is_consonant(s, i)) ++i;
    while (i < s.size()) {
        // 现在在元音位置
        ++i;  // 跳过元音
        ++m;  // 计数一个 VC
        // 跳过后续辅音
        while (i < s.size() && is_consonant(s, i)) ++i;
    }
    return m;
}

// w 去掉末尾 n 个字符后的前缀视图（measure/cvc 都在视图上算，零拷贝）。
inline std::string_view stem_of(const std::string& w, std::size_t suffix_len) {
    return std::string_view(w).substr(0, w.size() - suffix_len);
}

inline bool ends_with_vowel(std::string_view s) {
    if (s.empty()) return false;
    return !is_consonant(s, s.size() - 1);
}

inline bool ends_with_double_consonant(std::string_view s) {
    return s.size() >= 2 &&
           s[s.size() - 1] == s[s.size() - 2] &&
           is_consonant(s, s.size() - 1);
}

// CVC 模式：辅音-元音-辅音，最后辅音非 w/x/y。
inline bool cvc(std::string_view s) {
    if (s.size() < 3) return false;
    auto n = s.size();
    return is_consonant(s, n - 1) &&
           !is_consonant(s, n - 2) &&
           is_consonant(s, n - 3) &&
           s[n - 1] != 'w' && s[n - 1] != 'x' && s[n - 1] != 'y';
}

inline void step1a(std::string& w) {
    if (w.size() >= 4 && w.ends_with("sses")) {
        w.resize(w.size() - 2);  // sses → ss
    } else if (w.size() >= 4 && w.ends_with("ies")) {
        w.resize(w.size() - 2);  // ies → i
    } else if (w.size() >= 2 && w.ends_with("s") && !w.ends_with("ss")) {
        if (measure(stem_of(w, 1)) > 0) w.resize(w.size() - 1);
    }
}

inline void step1b(std::string& w) {
    if (w.size() >= 3 && w.ends_with("ed")) {
        if (measure(stem_of(w, 2)) > 0) {
            w.resize(w.size() - 2);
            if (ends_with_double_consonant(w) && w.back() != 'l' && w.back() != 's' && w.back() != 'z') {
                w.pop_back();
            } else if (w.ends_with("at") || w.ends_with("bl") || w.ends_with("iz")) {
                w.push_back('e');
            }
        }
    } else if (w.size() >= 4 && w.ends_with("ing")) {
        if (measure(stem_of(w, 3)) > 0) {
            w.resize(w.size() - 3);
            if (ends_with_double_consonant(w) && w.back() != 'l' && w.back() != 's' && w.back() != 'z') {
                w.pop_back();
            } else if (w.ends_with("at") || w.ends_with("bl") || w.ends_with("iz")) {
                w.push_back('e');
            }
        }
    }
}

inline void step1c(std::string& w) {
    if (w.size() >= 2 && w.ends_with("y")) {
        if (measure(stem_of(w, 1)) > 0) {
            w.back() = 'i';
        }
    }
}

inline void step2(std::string& w) {
    static constexpr std::pair<std::string_view, std::string_view> rules[] = {
        {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"}, {"anci", "ance"},
        {"izer", "ize"}, {"biliti", "ble"}, {"alli", "al"}, {"entli", "ent"},
        {"eli", "e"}, {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
        {"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"}, {"fulness", "ful"},
        {"ousness", "ous"}, {"aliti", "al"}, {"iviti", "ive"}, {"iciti", "ic"}
    };
    for (const auto& r : rules) {
        if (w.size() >= r.first.size() + 2 && w.ends_with(r.first)) {
            if (measure(stem_of(w, r.first.size())) > 0) {
                w.resize(w.size() - r.first.size());
                w += r.second;
                return;
            }
        }
    }
}

inline void step3(std::string& w) {
    static constexpr std::pair<std::string_view, std::string_view> rules[] = {
        {"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
        {"ical", "ic"}, {"ful", ""}, {"ness", ""}
    };
    for (const auto& r : rules) {
        if (w.size() >= r.first.size() + 2 && w.ends_with(r.first)) {
            int m = measure(stem_of(w, r.first.size()));
            bool cond = (r.first == "ful") ? (m > 1) : (m > 0);
            if (cond) {
                w.resize(w.size() - r.first.size());
                w += r.second;
                return;
            }
        }
    }
}

inline void step4(std::string& w) {
    static constexpr std::pair<std::string_view, int> rules[] = {
        {"al", 1}, {"ance", 1}, {"ence", 1}, {"er", 1}, {"ic", 1},
        {"able", 1}, {"ible", 1}, {"ant", 1}, {"ement", 1}, {"ment", 1},
        {"ent", 1}, {"ism", 1}, {"ate", 1}, {"iti", 1}, {"ous", 1},
        {"ive", 1}, {"ize", 1}
    };
    for (const auto& r : rules) {
        if (w.size() >= r.first.size() + 2 && w.ends_with(r.first)) {
            if (measure(stem_of(w, r.first.size())) > r.second) {
                w.resize(w.size() - r.first.size());
                return;
            }
        }
    }
}

inline void step5a(std::string& w) {
    if (w.size() >= 2 && w.ends_with("e")) {
        auto stem = stem_of(w, 1);
        int m = measure(stem);
        if (m > 1 || (m == 1 && !cvc(stem))) {
            w.resize(w.size() - 1);
        }
    }
}

inline void step5b(std::string& w) {
    if (measure(w) > 1 && ends_with_double_consonant(w)) {
        char last = w.back();
        // ll, ss, zz 例外不删（它们本身就是双辅音）
        if (last != 'l' && last != 's' && last != 'z') {
            w.pop_back();
        }
    }
}

}  // namespace detail

[[nodiscard]] inline std::string porter_stem(std::string_view sv) {
    if (sv.size() <= 2) return std::string(sv);
    for (char c : sv) {
        if (c < 'a' || c > 'z') return std::string(sv);
    }
    std::string w(sv);
    detail::step1a(w);
    detail::step1b(w);
    detail::step1c(w);
    detail::step2(w);
    detail::step3(w);
    detail::step4(w);
    detail::step5a(w);
    detail::step5b(w);
    return w;
}

}  // namespace bitcask::text
