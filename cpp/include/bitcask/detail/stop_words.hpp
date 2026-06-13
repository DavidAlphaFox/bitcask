// 默认停用词表（英文 + 中文高频虚词）。
// NgramAnalyzer 与 JiebaAnalyzer 共用此表，避免两处各维护一份副本。

#pragma once

#include <string>
#include <vector>

namespace bitcask::detail {

inline const std::vector<std::string>& default_stop_words() {
    static const std::vector<std::string> words = {
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "dare", "ought",
        "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "as", "into", "through", "during", "before", "after", "above", "below",
        "between", "out", "off", "over", "under", "again", "further", "then",
        "once", "and", "but", "or", "nor", "not", "so", "yet", "both",
        "either", "neither", "each", "every", "all", "any", "few", "more",
        "most", "other", "some", "such", "no", "only", "own", "same", "than",
        "too", "very", "just", "because", "if", "when", "while", "where",
        "how", "what", "which", "who", "whom", "this", "that", "these",
        "those", "it", "its", "he", "she", "they", "them", "his", "her",
        "their", "my", "your", "our", "me", "him", "us", "i",
        "的", "了", "在", "是", "我", "有", "和", "就", "不", "人", "都",
        "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你",
        "会", "着", "没有", "看", "好", "自己", "这",
    };
    return words;
}

}  // namespace bitcask::detail
