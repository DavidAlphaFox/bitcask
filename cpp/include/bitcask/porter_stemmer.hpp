// 英文 Porter 词干提取器（S8.1）。
//
// 实现 Martin Porter 经典的 5 步词干提取算法。
// 将英文单词还原为词干形式："running" → "run"，"generalization" → "general"。
// 仅处理纯 ASCII 字母组成、长度大于 2 的拉丁词；
// CJK 字符、短词或含非字母字符的词直接返回原样。

#pragma once

#include <cstring>
#include <string>
#include <string_view>

namespace bitcask::text {
namespace detail {

inline bool is_consonant(const std::string& s, std::size_t i) {
    switch (s[i]) {
        case 'a': case 'e': case 'i': case 'o': case 'u': return false;
        case 'y': return i == 0 ? true : !is_consonant(s, i - 1);
        default: return true;
    }
}

// 计算词干测量值 m。
// m = VC 序列个数。VC 序列 = 一个元音后面跟零个或多个辅音。
// (C)VC^m = m 个 VC 序列，前面可以有零个或多个辅音。
inline int measure(const std::string& s) {
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

inline bool ends_with_vowel(const std::string& s) {
    if (s.empty()) return false;
    return !is_consonant(s, s.size() - 1);
}

inline bool ends_with_double_consonant(const std::string& s) {
    return s.size() >= 2 &&
           s[s.size() - 1] == s[s.size() - 2] &&
           is_consonant(s, s.size() - 1);
}

// CVC 模式：辅音-元音-辅音，最后辅音非 w/x/y。
inline bool cvc(const std::string& s) {
    if (s.size() < 3) return false;
    auto n = s.size();
    return is_consonant(s, n - 1) &&
           !is_consonant(s, n - 2) &&
           is_consonant(s, n - 3) &&
           s[n - 1] != 'w' && s[n - 1] != 'x' && s[n - 1] != 'y';
}

inline void step1a(std::string& w) {
    if (w.size() >= 4 && w.ends_with("sses")) {
        w.erase(w.size() - 4);  // sses → ss
        w += "ss";
    } else if (w.size() >= 4 && w.ends_with("ies")) {
        w.erase(w.size() - 2);  // ies → i
        w += 'i';
    } else if (w.size() >= 2 && w.ends_with("s") && !w.ends_with("ss")) {
        std::string stem = w.substr(0, w.size() - 1);
        if (measure(stem) > 0) w = stem;
    }
}

inline void step1b(std::string& w) {
    if (w.size() >= 3 && w.ends_with("ed")) {
        std::string stem = w.substr(0, w.size() - 2);
        if (measure(stem) > 0) {
            w = stem;
            if (ends_with_double_consonant(w) && w.back() != 'l' && w.back() != 's' && w.back() != 'z') {
                w.pop_back();
            } else if (w.ends_with("at") || w.ends_with("bl") || w.ends_with("iz")) {
                w.push_back('e');
            }
        }
    } else if (w.size() >= 4 && w.ends_with("ing")) {
        std::string stem = w.substr(0, w.size() - 3);
        if (measure(stem) > 0) {
            w = stem;
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
        std::string stem = w.substr(0, w.size() - 1);
        if (measure(stem) > 0) {
            w = stem;
            w.push_back('i');
        }
    }
}

inline void step2(std::string& w) {
    static const std::pair<const char*, const char*> rules[] = {
        {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"}, {"anci", "ance"},
        {"izer", "ize"}, {"biliti", "ble"}, {"alli", "al"}, {"entli", "ent"},
        {"eli", "e"}, {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
        {"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"}, {"fulness", "ful"},
        {"ousness", "ous"}, {"aliti", "al"}, {"iviti", "ive"}, {"iciti", "ic"}
    };
    for (const auto& r : rules) {
        auto suf = std::string(r.first);
        if (w.size() >= suf.size() + 2 && w.ends_with(suf)) {
            std::string stem = w.substr(0, w.size() - suf.size());
            if (measure(stem) > 0) {
                w = stem + r.second;
                return;
            }
        }
    }
}

inline void step3(std::string& w) {
    static const std::pair<const char*, const char*> rules[] = {
        {"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
        {"ical", "ic"}, {"ful", ""}, {"ness", ""}
    };
    for (const auto& r : rules) {
        auto suf = std::string(r.first);
        if (w.size() >= suf.size() + 2 && w.ends_with(suf)) {
            std::string stem = w.substr(0, w.size() - suf.size());
            int m = measure(stem);
            bool cond = (suf == std::string("ful")) ? (m > 1) : (m > 0);
            if (cond) {
                w = stem + r.second;
                return;
            }
        }
    }
}

inline void step4(std::string& w) {
    static const std::pair<const char*, int> rules[] = {
        {"al", 1}, {"ance", 1}, {"ence", 1}, {"er", 1}, {"ic", 1},
        {"able", 1}, {"ible", 1}, {"ant", 1}, {"ement", 1}, {"ment", 1},
        {"ent", 1}, {"ism", 1}, {"ate", 1}, {"iti", 1}, {"ous", 1},
        {"ive", 1}, {"ize", 1}
    };
    for (const auto& r : rules) {
        auto suf = std::string(r.first);
        if (w.size() >= suf.size() + 2 && w.ends_with(suf)) {
            std::string stem = w.substr(0, w.size() - suf.size());
            if (measure(stem) > r.second) {
                w = stem;
                return;
            }
        }
    }
}

inline void step5a(std::string& w) {
    if (w.size() >= 2 && w.ends_with("e")) {
        std::string stem = w.substr(0, w.size() - 1);
        int m = measure(stem);
        if (m > 1 || (m == 1 && !cvc(stem))) {
            w = stem;
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
