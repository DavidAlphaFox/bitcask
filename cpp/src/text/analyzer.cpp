// 分词器工厂实现 + NgramAnalyzer / WhitespaceAnalyzer 实现。

#include "bitcask/analyzer.hpp"
#include "bitcask/cjk_detect.hpp"
#include "bitcask/jieba_analyzer.hpp"
#include "bitcask/ngram_analyzer.hpp"
#include "bitcask/text_utils.hpp"
#include "bitcask/whitespace_analyzer.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <utf8proc.h>

namespace bitcask::text {

// ===========================================================================
// 工厂
// ===========================================================================

auto AnalyzerFactory::create(const AnalyzerConfig& config)
    -> std::unique_ptr<Analyzer>
{
    switch (config.type) {
        case AnalyzerType::Ngram:
            if (config.min_n < 1 || config.max_n < config.min_n) {
                return nullptr;
            }
            return std::make_unique<NgramAnalyzer>(
                config.min_n, config.max_n,
                config.enable_stop_words, config.stop_words,
                config.min_token_length);
        case AnalyzerType::Whitespace:
            return std::make_unique<WhitespaceAnalyzer>(config.min_token_length);
        case AnalyzerType::Jieba:
            return std::make_unique<JiebaAnalyzer>(
                config.dict_path, config.min_n, config.max_n,
                config.enable_stop_words, config.stop_words,
                config.min_token_length);
    }
    return nullptr;
}

// ===========================================================================
// Analyzer 默认实现
// ===========================================================================

auto Analyzer::analyze_with_offsets(std::string_view text) const -> TermTokenMap {
    auto tpm = analyze_with_positions(text);
    TermTokenMap ttm;
    ttm.reserve(tpm.size());
    for (auto& [term, data] : tpm) {
        auto& infos = ttm[term];
        infos.reserve(data.second.size());
        for (auto p : data.second) {
            infos.push_back(TokenInfo{p, 0, 0});
        }
    }
    return ttm;
}

// ===========================================================================
// 内部辅助（detail 命名空间中仅 analyzer.cpp 使用的函数）
// ===========================================================================

namespace detail {

[[nodiscard]] bool is_unicode_space(char32_t cp) noexcept {
    auto cat = utf8proc_category(static_cast<utf8proc_int32_t>(cp));
    if (cat == UTF8PROC_CATEGORY_ZS) return true;
    if (cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0x0B || cp == 0x0C) {
        return true;
    }
    return false;
}

[[nodiscard]] bool is_ascii_punct(char32_t cp) noexcept {
    if (cp >= 0x21 && cp <= 0x2F) return true;
    if (cp >= 0x3A && cp <= 0x40) return true;
    if (cp >= 0x5B && cp <= 0x60) return true;
    if (cp >= 0x7B && cp <= 0x7E) return true;
    return false;
}

}  // namespace detail

namespace {

const std::vector<std::string>& default_stop_words() {
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

}  // namespace

// ===========================================================================
// NgramAnalyzer
// ===========================================================================

NgramAnalyzer::NgramAnalyzer(std::uint32_t min_n, std::uint32_t max_n,
                             bool enable_stop_words,
                             std::vector<std::string> custom_stop_words,
                             std::uint32_t min_token_length)
    : min_n_(min_n), max_n_(max_n), enable_stop_words_(enable_stop_words),
      min_token_length_(min_token_length) {
    if (enable_stop_words_) {
        const auto& defaults = default_stop_words();
        const auto& src = custom_stop_words.empty()
                              ? defaults
                              : custom_stop_words;
        stop_words_.insert(src.begin(), src.end());
    }
}

auto NgramAnalyzer::analyze_with_positions(std::string_view text) const -> TermPositionsMap {
    if (text.empty()) return {};

    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    auto cps = detail::to_codepoints(normalized);
    if (cps.empty()) return {};

    TermPositionsMap tpm;
    std::size_t i = 0;
    std::uint32_t pos = 0;

    auto emit_ngrams = [&](std::size_t start, std::size_t end) {
        auto n = end - start;
        for (std::size_t gram = min_n_; gram <= max_n_; ++gram) {
            if (gram > n) break;
            for (std::size_t j = start; j + gram <= end; ++j) {
                auto& first_cp = cps[j];
                auto& last_cp = cps[j + gram - 1];
                auto term = std::string(
                    normalized.data() + first_cp.byte_off,
                    (last_cp.byte_off + last_cp.byte_len) - first_cp.byte_off);
                auto& [tf, positions] = tpm[std::move(term)];
                ++tf;
                positions.push_back(pos);
            }
        }
        ++pos;
    };

    auto emit_word = [&](std::size_t start, std::size_t end) {
        // S9.8：拉丁整词按 codepoint 长度过滤；短词丢弃但 pos 仍递增（位置语义不变）。
        if (end - start >= min_token_length_) {
            auto& first = cps[start];
            auto& last = cps[end - 1];
            auto term = std::string(
                normalized.data() + first.byte_off,
                (last.byte_off + last.byte_len) - first.byte_off);
            if (!term.empty()) {
                auto& [tf, positions] = tpm[std::move(term)];
                ++tf;
                positions.push_back(pos);
            }
        }
        ++pos;
    };

    while (i < cps.size()) {
        if (detail::is_cjk(cps[i].cp) && !detail::is_cjk_punct(cps[i].cp)) {
            std::size_t run_start = i;
            while (i < cps.size() &&
                   detail::is_cjk(cps[i].cp) &&
                   !detail::is_cjk_punct(cps[i].cp)) {
                ++i;
            }
            emit_ngrams(run_start, i);
            if (i < cps.size() && detail::is_cjk_punct(cps[i].cp)) {
                ++i;
            }
        } else if (detail::is_unicode_space(cps[i].cp)) {
            ++i;
        } else if (detail::is_cjk_punct(cps[i].cp) || detail::is_ascii_punct(cps[i].cp)) {
            ++i;
        } else {
            std::size_t word_start = i;
            while (i < cps.size() &&
                   !detail::is_cjk(cps[i].cp) &&
                   !detail::is_unicode_space(cps[i].cp) &&
                   !detail::is_cjk_punct(cps[i].cp) &&
                   !detail::is_ascii_punct(cps[i].cp)) {
                ++i;
            }
            emit_word(word_start, i);
        }
    }

    if (enable_stop_words_ && !stop_words_.empty()) {
        for (auto it = tpm.begin(); it != tpm.end();) {
            if (stop_words_.count(it->first)) {
                it = tpm.erase(it);
            } else {
                ++it;
            }
        }
    }

    return tpm;
}

auto NgramAnalyzer::analyze(std::string_view text) const -> TermFreqMap {
    auto tpm = analyze_with_positions(text);
    TermFreqMap tfs;
    tfs.reserve(tpm.size());
    for (auto& [term, data] : tpm) {
        tfs.emplace(term, data.first);
    }
    return tfs;
}

// ===========================================================================
// WhitespaceAnalyzer
// ===========================================================================

auto WhitespaceAnalyzer::analyze_with_positions(std::string_view text) const -> TermPositionsMap {
    if (text.empty()) return {};

    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    auto cps = detail::to_codepoints(normalized);
    if (cps.empty()) return {};

    TermPositionsMap tpm;
    std::size_t i = 0;
    std::uint32_t pos = 0;

    while (i < cps.size()) {
        if (detail::is_unicode_space(cps[i].cp)) {
            ++i;
            continue;
        }
        std::size_t word_start = i;
        while (i < cps.size() && !detail::is_unicode_space(cps[i].cp)) {
            ++i;
        }
        // S9.8：按 codepoint 长度过滤短词；短词丢弃但 pos 仍递增。
        if (i - word_start >= min_token_length_) {
            auto& first = cps[word_start];
            auto& last = cps[i - 1];
            auto term = std::string(
                normalized.data() + first.byte_off,
                (last.byte_off + last.byte_len) - first.byte_off);
            if (!term.empty()) {
                auto& [tf, positions] = tpm[std::move(term)];
                ++tf;
                positions.push_back(pos);
            }
        }
        ++pos;
    }

    return tpm;
}

auto WhitespaceAnalyzer::analyze(std::string_view text) const -> TermFreqMap {
    auto tpm = analyze_with_positions(text);
    TermFreqMap tfs;
    tfs.reserve(tpm.size());
    for (auto& [term, data] : tpm) {
        tfs.emplace(term, data.first);
    }
    return tfs;
}

auto WhitespaceAnalyzer::analyze_with_offsets(std::string_view text) const -> TermTokenMap {
    if (text.empty()) return {};

    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    auto cps = detail::to_codepoints(normalized);
    if (cps.empty()) return {};

    TermTokenMap ttm;
    std::size_t i = 0;
    std::uint32_t pos = 0;

    while (i < cps.size()) {
        if (detail::is_unicode_space(cps[i].cp)) {
            ++i;
            continue;
        }
        std::size_t word_start = i;
        while (i < cps.size() && !detail::is_unicode_space(cps[i].cp)) {
            ++i;
        }
        // S9.8：按 codepoint 长度过滤短词；短词丢弃但 pos 仍递增。
        if (i - word_start >= min_token_length_) {
            auto& first = cps[word_start];
            auto& last = cps[i - 1];
            auto term = std::string(
                normalized.data() + first.byte_off,
                (last.byte_off + last.byte_len) - first.byte_off);
            if (!term.empty()) {
                auto& infos = ttm[std::move(term)];
                infos.push_back(TokenInfo{pos,
                                          static_cast<std::uint32_t>(first.byte_off),
                                          static_cast<std::uint32_t>(last.byte_off + last.byte_len)});
            }
        }
        ++pos;
    }

    return ttm;
}

// ===========================================================================
// NgramAnalyzer
// ===========================================================================

auto NgramAnalyzer::analyze_with_offsets(std::string_view text) const -> TermTokenMap {
    auto tpm = analyze_with_positions(text);
    TermTokenMap ttm;
    ttm.reserve(tpm.size());
    for (auto& [term, data] : tpm) {
        auto& infos = ttm[term];
        infos.reserve(data.second.size());
        for (auto p : data.second) {
            infos.push_back(TokenInfo{p, 0, 0});
        }
    }
    return ttm;
}

}  // namespace bitcask::text
