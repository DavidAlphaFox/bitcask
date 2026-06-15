// JiebaAnalyzer 实现：jieba CutForSearch + CJK 回退 n-gram。

#include "bitcask/analyzer.hpp"
#include "bitcask/cjk_detect.hpp"
#include "bitcask/detail/stop_words.hpp"
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

// 判断一个 codepoint 是否「无检索意义」：空白（Zs / 控制空白）或标点（P*）。
// 用于过滤 jieba CutForSearch 偶尔输出的纯空白/标点词（S9.26）。
[[nodiscard]] bool is_noise_cp(char32_t cp) noexcept {
    auto cat = utf8proc_category(static_cast<utf8proc_int32_t>(cp));
    switch (cat) {
        case UTF8PROC_CATEGORY_ZS:  // 空格分隔符
        case UTF8PROC_CATEGORY_ZL:  // 行分隔符
        case UTF8PROC_CATEGORY_ZP:  // 段分隔符
        case UTF8PROC_CATEGORY_CC:  // 控制字符
        case UTF8PROC_CATEGORY_PC:  // 标点（连接）
        case UTF8PROC_CATEGORY_PD:  // 标点（破折）
        case UTF8PROC_CATEGORY_PS:  // 标点（开）
        case UTF8PROC_CATEGORY_PE:  // 标点（闭）
        case UTF8PROC_CATEGORY_PI:  // 标点（首引号）
        case UTF8PROC_CATEGORY_PF:  // 标点（尾引号）
        case UTF8PROC_CATEGORY_PO:  // 标点（其它）
            return true;
        default:
            return false;
    }
}

// word 的所有 codepoint 都是噪声（空白/标点）→ 不应进索引。
[[nodiscard]] bool is_noise_word(const std::vector<detail::CpInfo>& cps) noexcept {
    if (cps.empty()) return true;
    for (auto& c : cps) {
        if (!is_noise_cp(c.cp)) return false;
    }
    return true;
}

}  // namespace

JiebaAnalyzer::~JiebaAnalyzer() = default;

JiebaAnalyzer::JiebaAnalyzer(const std::string& dict_dir,
                             std::uint32_t min_n, std::uint32_t max_n,
                             bool enable_stop_words,
                             std::vector<std::string> custom_stop_words,
                             std::uint32_t min_token_length)
    : min_n_(min_n), max_n_(max_n), enable_stop_words_(enable_stop_words),
      min_token_length_(min_token_length) {
    jieba_ = std::make_unique<JiebaImpl>(dict_dir);

    if (enable_stop_words_) {
        const auto& defaults = bitcask::detail::default_stop_words();
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
// collect_tokens —— analyze_with_positions / analyze_with_offsets 的共同来源
// ===========================================================================
//
// 产出有序 token 列表，每条带「归一化文本」上的字节区间。
// jieba 词的 term key 沿用原始词（与索引/查询一致），但 byte 区间是它在
// 归一化文本中匹配到的位置；jieba 未覆盖的 CJK 段回退 n-gram，term 与 byte
// 区间都直接取自归一化文本。停用词过滤在此统一完成。

auto JiebaAnalyzer::collect_tokens(std::string_view text, bool need_offsets) const
    -> std::vector<JiebaToken>
{
    std::vector<JiebaToken> tokens;
    if (text.empty()) return tokens;

    // Step 1: NFKC 归一化（n-gram 回退路径 + 高亮 offset 的统一坐标系）。
    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return tokens;

    // Step 2: jieba CutForSearch 切词。
    auto jieba_words = jieba_cut(text);

    // Step 3: 在归一化文本上做 codepoint 分析（定位 jieba 词 + 检测未覆盖 CJK 段）。
    auto cps = detail::to_codepoints(normalized);

    std::uint32_t pos = 0;
    std::vector<bool> cjk_covered(cps.size(), false);

    // jieba 词：在归一化 cps 序列中定位，记录 byte 区间。
    // CutForSearch 会对同一段输出重叠的子词与全词（如"北京""大学""北京大学"），
    // 其顺序与文本位置并不单调，故不能用单调游标定位——每个词独立从头查找
    // 首次匹配。同词多次出现时高亮取首次位置（高亮为尽力而为，非索引正确性）。
    for (auto& [word, _] : jieba_words) {
        auto word_norm = detail::nfkc_fold(word);
        auto word_cps = detail::to_codepoints(word_norm);
        if (word_cps.empty()) continue;

        // S9.26：jieba CutForSearch 偶尔把空格/标点也输出为词，过滤掉纯噪声词
        // （pos 仍递增以保持位置语义一致）。
        if (is_noise_word(word_cps)) {
            ++pos;
            continue;
        }

        bool has_cjk = false;
        for (auto& wc : word_cps) {
            if (detail::is_cjk(wc.cp) && !detail::is_cjk_punct(wc.cp)) {
                has_cjk = true;
                break;
            }
        }

        // S9.8：非 CJK 的短拉丁词按 codepoint 长度过滤（CJK 词不受限）；
        // 跳过该词但 pos 仍递增，保持位置语义一致。
        if (!has_cjk && word_cps.size() < min_token_length_) {
            ++pos;
            continue;
        }

        // 在整个 cps 中朴素查找该词的 codepoint 序列首次出现位置。
        // 该查找有两个用途：①填 byte offset（仅高亮需要）；②标记 cjk_covered
        // （索引必需，决定哪些 CJK 段回退 n-gram）。因此 has_cjk 词必须查；
        // 非 CJK 词只为 offset，若 !need_offsets（索引路径）则跳过——省掉纯拉丁
        // 词的 O(cps长度) 扫描（S9 复审：S9.9 把高亮开销带进了索引路径）。
        std::size_t found = cps.size();
        if (has_cjk || need_offsets) {
            for (std::size_t si = 0; si + word_cps.size() <= cps.size(); ++si) {
                bool match = true;
                for (std::size_t wi = 0; wi < word_cps.size(); ++wi) {
                    if (cps[si + wi].cp != word_cps[wi].cp) { match = false; break; }
                }
                if (match) { found = si; break; }
            }
        }

        std::uint32_t sb = 0, eb = 0;
        if (found < cps.size()) {
            auto& first_cp = cps[found];
            auto& last_cp  = cps[found + word_cps.size() - 1];
            sb = static_cast<std::uint32_t>(first_cp.byte_off);
            eb = static_cast<std::uint32_t>(last_cp.byte_off + last_cp.byte_len);
            if (has_cjk) {
                for (std::size_t wi = 0; wi < word_cps.size(); ++wi) {
                    cjk_covered[found + wi] = true;
                }
            }
        }
        // 未定位到（罕见，如归一化差异）时 sb==eb==0：高亮跳过该 token，
        // 但仍保留它进索引语义（term/position 不丢）。

        tokens.push_back({word, pos, sb, eb});
        ++pos;
    }

    // jieba 未覆盖的 CJK 连续段 → bi/tri-gram 回退（term 与 byte 均取归一化文本）。
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
                auto n = i - run_start;
                for (std::size_t gram = min_n_; gram <= max_n_; ++gram) {
                    if (gram > n) break;
                    for (std::size_t j = run_start; j + gram <= i; ++j) {
                        auto& first_cp = cps[j];
                        auto& last_cp = cps[j + gram - 1];
                        auto sb = static_cast<std::uint32_t>(first_cp.byte_off);
                        auto eb = static_cast<std::uint32_t>(last_cp.byte_off + last_cp.byte_len);
                        tokens.push_back({
                            std::string(normalized.data() + sb, eb - sb),
                            pos, sb, eb});
                    }
                }
                ++pos;
            } else {
                ++i;
            }
        }
    }

    // 停用词过滤（与原 analyze_with_positions 行为一致）。
    if (enable_stop_words_ && !stop_words_.empty()) {
        tokens.erase(
            std::remove_if(tokens.begin(), tokens.end(),
                           [&](const JiebaToken& t) { return stop_words_.count(t.term) != 0; }),
            tokens.end());
    }

    return tokens;
}

// ===========================================================================
// analyze_with_positions
// ===========================================================================

auto JiebaAnalyzer::analyze_with_positions(std::string_view text) const
    -> TermPositionsMap
{
    TermPositionsMap tpm;
    for (auto& tok : collect_tokens(text, /*need_offsets=*/false)) {
        auto& [tf, positions] = tpm[tok.term];
        ++tf;
        positions.push_back(tok.position);
    }
    return tpm;
}

// ===========================================================================
// analyze
// ===========================================================================

auto JiebaAnalyzer::analyze_with_offsets(std::string_view text) const -> TermTokenMap {
    TermTokenMap ttm;
    for (auto& tok : collect_tokens(text, /*need_offsets=*/true)) {
        ttm[tok.term].push_back(TokenInfo{tok.position, tok.start_byte, tok.end_byte});
    }
    return ttm;
}

}  // namespace bitcask::text

// 注：Jieba 工厂注册已移到 analyzer.cpp（工厂同 TU，必被链接）。bitcask_text
// 是 STATIC 库，本 TU 的自注册曾因无外部符号引用被链接器丢弃 → create(Jieba)
// 返回 nullptr → put 段错误。移走后由 analyzer.cpp 的 lambda 引用本类构造符号
// 强制拉入本 TU 并完成注册。
