#pragma once

#include <string_view>

namespace bitcask::bm25 {

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
