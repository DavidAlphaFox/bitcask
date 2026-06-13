// jieba 词典分词器（CutForSearch + CJK 回退 n-gram）。
//
// JiebaAnalyzer 是 bitcask::text::Analyzer 接口的中文分词实现（V2.10）。
// 处理管线：NFKC 归一化 → case fold → jieba CutForSearch 切词 →
// 对 jieba 未覆盖的 CJK 字符段回退 bi/tri-gram → 停用词过滤。
//
// 线程安全：analyze() 是 const 方法；cppjieba::Jieba 内部线程安全。

#pragma once

#include <cstdint>
#include <string>
#include <unordered_set>

#include "bitcask/analyzer.hpp"

namespace bitcask::text {

class JiebaAnalyzer final : public Analyzer {
public:
    // dict_dir: jieba 词典文件所在目录，需包含 jieba.dict.utf8 / hmm_model.utf8 等。
    //           必须是有效目录——当前实现无空路径回退，空串会拼成 "/jieba.dict.utf8"
    //           导致加载失败。运行时由 Erlang facade（bitcask:open）默认填 priv/dict。
    explicit JiebaAnalyzer(const std::string& dict_dir = {},
                           std::uint32_t min_n = 2, std::uint32_t max_n = 3,
                           bool enable_stop_words = false,
                           std::vector<std::string> custom_stop_words = {},
                           std::uint32_t min_token_length = 1);

    ~JiebaAnalyzer() override;

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override;

    [[nodiscard]] auto analyze_with_offsets(std::string_view text) const
        -> TermTokenMap override;

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return AnalyzerType::Jieba;
    }

private:
    // 对归一化文本执行 jieba CutForSearch 切词。
    // 返回 (word, byte_offset) 列表。
    auto jieba_cut(std::string_view text) const
        -> std::vector<std::pair<std::string, std::uint32_t>>;

    // 切词的中间产物：单条 token + 其在「归一化文本」上的字节区间。
    // 是 analyze_with_positions / analyze_with_offsets 的共同数据来源，
    // 保证两者对同一文本得到完全一致的 token 集与顺序。
    // 注意：byte 区间相对 NFKC 归一化后的文本，与 ngram/whitespace 路径的
    // 契约一致（highlighter 在纯规范文本下正确；非规范文本的系统性错位见 S9.19）。
    struct JiebaToken {
        std::string   term;
        std::uint32_t position;
        std::uint32_t start_byte;  // 归一化文本字节偏移
        std::uint32_t end_byte;    // 归一化文本字节偏移（不含）
    };
    // need_offsets=false（索引路径）时跳过非 CJK 词的 byte offset 定位扫描，
    // 仅 has_cjk 词仍定位（cjk_covered 标记是索引必需）。need_offsets=true
    // （高亮路径）时所有词都定位以填 start_byte/end_byte。
    [[nodiscard]] auto collect_tokens(std::string_view text,
                                      bool need_offsets) const
        -> std::vector<JiebaToken>;

    struct JiebaImpl;
    std::unique_ptr<JiebaImpl> jieba_;

    std::uint32_t min_n_;
    std::uint32_t max_n_;
    bool enable_stop_words_;
    std::unordered_set<std::string> stop_words_;
    std::uint32_t min_token_length_ = 1;   // 拉丁整词最小 codepoint 长度（S9.8），1=不过滤
};

}  // namespace bitcask::text
