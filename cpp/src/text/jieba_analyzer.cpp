// JiebaAnalyzer 实现：jieba CutForSearch + CJK 回退 n-gram。

#include "bitcask/analyzer.hpp"
#include "bitcask/cjk_detect.hpp"
#include "bitcask/jieba_analyzer.hpp"
#include "bitcask/text_utils.hpp"

#include <algorithm>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <utf8proc.h>

#include <cppjieba/Jieba.hpp>

namespace bitcask::text {

// pimpl 包装：将 cppjieba::Jieba 完整定义隐藏到 .cpp 内，
// 避免头文件暴露 cppjieba 的 include 路径。
struct JiebaAnalyzer::JiebaImpl {
    cppjieba::Jieba jieba;

    explicit JiebaImpl(const std::string& dict_dir)
        : jieba(dict_dir + "/jieba.dict.utf8",
                dict_dir + "/hmm_model.utf8",
                dict_dir + "/user.dict.utf8",
                dict_dir + "/idf.utf8",
                dict_dir + "/stop_words.utf8") {}
};

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

JiebaAnalyzer::~JiebaAnalyzer() = default;

JiebaAnalyzer::JiebaAnalyzer(const std::string& dict_dir,
                             std::uint32_t min_n, std::uint32_t max_n,
                             bool enable_stop_words,
                             std::vector<std::string> custom_stop_words)
    : min_n_(min_n), max_n_(max_n), enable_stop_words_(enable_stop_words) {
    jieba_ = std::make_unique<JiebaImpl>(dict_dir);

    if (enable_stop_words_) {
        const auto& defaults = default_stop_words();
        const auto& src = custom_stop_words.empty()
                              ? defaults
                              : custom_stop_words;
        stop_words_.insert(src.begin(), src.end());
    }
}

// ===========================================================================
// jieba 切词（内部）
// ===========================================================================

auto JiebaAnalyzer::jieba_cut(std::string_view text) const
    -> std::vector<std::pair<std::string, std::uint32_t>>
{
    // cppjieba 接口要求 std::string，走一次拷贝。
    std::string sentence(text);
    std::vector<cppjieba::Word> words;
    jieba_->jieba.CutForSearch(sentence, words, true);

    std::vector<std::pair<std::string, std::uint32_t>> result;
    result.reserve(words.size());
    for (auto& w : words) {
        if (!w.word.empty()) {
            result.emplace_back(std::move(w.word), w.offset);
        }
    }
    return result;
}

// ===========================================================================
// analyze_with_positions
// ===========================================================================

auto JiebaAnalyzer::analyze_with_positions(std::string_view text) const
    -> TermPositionsMap
{
    if (text.empty()) return {};

    // Step 1: NFKC 归一化（用于 n-gram 回退路径和最终输出一致性）。
    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    // Step 2: jieba CutForSearch 对原始文本切词。
    //         cppjieba 内部已做归一化处理，直接传入原始文本即可。
    auto jieba_words = jieba_cut(text);

    // Step 3: 收集 jieba 已识别的 CJK 字符的 byte offset，
    //         用于检测 jieba 未覆盖的 CJK 段（回退 n-gram）。
    //         我们用归一化后的文本做 codepoint 分析。
    auto cps = detail::to_codepoints(normalized);

    // 构建 jieba 已覆盖的字节范围集合（在归一化文本上的投影）。
    // 简化策略：直接用 jieba 输出的词记录 position，对未识别 CJK 做回退。

    TermPositionsMap tpm;
    std::uint32_t pos = 0;

    // 将 jieba 词直接记录到 tpm。
    for (auto& [word, byte_off] : jieba_words) {
        auto& [tf, positions] = tpm[word];
        ++tf;
        positions.push_back(pos);
        ++pos;
    }

    // Step 4: 对 jieba 未覆盖的 CJK 字符段做 n-gram 回退。
    //         策略：在归一化文本上，找出所有 jieba 没有覆盖的 CJK 连续段，
    //         对这些段做 bi/tri-gram 切分。
    //
    //         简化实现：遍历归一化文本的 codepoint 序列，找出 CJK 连续段，
    //         检查该段是否已被 jieba 完全覆盖。未覆盖部分做 n-gram。

    // 构建已覆盖的字节范围（在原始文本上）
    // 由于归一化可能改变字节偏移，我们用简化策略：
    // 对 jieba 输出的每个词，检查它是否为纯 CJK。如果 jieba 把一段 CJK
    // 输出为单个词（如"北京"），则该段已覆盖。
    // 对于 jieba 未能识别的孤立 CJK 字符（如日文字符），回退 n-gram。

    // 收集 jieba 已处理的 CJK 字符（通过在归一化文本上匹配）
    std::vector<bool> cjk_covered(cps.size(), false);

    for (auto& [word, _] : jieba_words) {
        // 对每个 jieba 词，在归一化文本中查找匹配的 CJK codepoint 段
        auto word_norm = detail::nfkc_fold(word);
        auto word_cps = detail::to_codepoints(word_norm);

        if (word_cps.empty()) continue;
        // 只标记 CJK 字符的覆盖
        bool has_cjk = false;
        for (auto& wc : word_cps) {
            if (detail::is_cjk(wc.cp) && !detail::is_cjk_punct(wc.cp)) {
                has_cjk = true;
                break;
            }
        }
        if (!has_cjk) continue;

        // 在 cps 序列中查找匹配位置（朴素搜索）
        for (std::size_t si = 0; si + word_cps.size() <= cps.size(); ++si) {
            bool match = true;
            for (std::size_t wi = 0; wi < word_cps.size(); ++wi) {
                if (cps[si + wi].cp != word_cps[wi].cp) {
                    match = false;
                    break;
                }
            }
            if (match) {
                for (std::size_t wi = 0; wi < word_cps.size(); ++wi) {
                    cjk_covered[si + wi] = true;
                }
                si += word_cps.size() - 1;
                break;
            }
        }
    }

    // 找出未覆盖的 CJK 连续段，做 n-gram 回退
    {
        std::size_t i = 0;
        while (i < cps.size()) {
            if (detail::is_cjk(cps[i].cp) && !detail::is_cjk_punct(cps[i].cp) && !cjk_covered[i]) {
                std::size_t run_start = i;
                while (i < cps.size() &&
                       detail::is_cjk(cps[i].cp) &&
                       !detail::is_cjk_punct(cps[i].cp) &&
                       !cjk_covered[i]) {
                    ++i;
                }
                // 对这段未覆盖的 CJK 做 n-gram
                auto n = i - run_start;
                for (std::size_t gram = min_n_; gram <= max_n_; ++gram) {
                    if (gram > n) break;
                    for (std::size_t j = run_start; j + gram <= i; ++j) {
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
            } else {
                ++i;
            }
        }
    }

    // Step 5: 停用词过滤
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

// ===========================================================================
// analyze
// ===========================================================================

auto JiebaAnalyzer::analyze(std::string_view text) const -> TermFreqMap {
    auto tpm = analyze_with_positions(text);
    TermFreqMap tfs;
    tfs.reserve(tpm.size());
    for (auto& [term, data] : tpm) {
        tfs.emplace(term, data.first);
    }
    return tfs;
}

}  // namespace bitcask::text
