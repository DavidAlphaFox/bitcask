// 搜索结果高亮/摘要生成器。

#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/analyzer.hpp"

namespace bitcask::search {

// 高亮片段。
struct Snippet {
    std::string text;
    double      score;
};

// 高亮配置。
struct HighlightOptions {
    std::string pre_tag  = "<em>";
    std::string post_tag = "</em>";
    std::size_t fragment_size = 120;
    std::size_t max_fragments = 3;
};

// 高亮结果。
struct HighlightResult {
    std::vector<Snippet> snippets;
};

// 生成高亮片段。
HighlightResult highlight(
    std::string_view text,
    const std::unordered_map<std::string, std::vector<text::TokenInfo>>& query_token_offsets,
    const HighlightOptions& opts = {});

}  // namespace bitcask::search