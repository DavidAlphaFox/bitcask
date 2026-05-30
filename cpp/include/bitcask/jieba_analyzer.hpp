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
    //           为空时使用内嵌默认路径。
    explicit JiebaAnalyzer(const std::string& dict_dir = {},
                           std::uint32_t min_n = 2, std::uint32_t max_n = 3,
                           bool enable_stop_words = false,
                           std::vector<std::string> custom_stop_words = {});

    ~JiebaAnalyzer() override;

    [[nodiscard]] auto analyze(std::string_view text) const
        -> TermFreqMap override;

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override;

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return AnalyzerType::Jieba;
    }

private:
    // 对归一化文本执行 jieba CutForSearch 切词。
    // 返回 (word, byte_offset) 列表。
    auto jieba_cut(std::string_view text) const
        -> std::vector<std::pair<std::string, std::uint32_t>>;

    struct JiebaImpl;
    std::unique_ptr<JiebaImpl> jieba_;

    std::uint32_t min_n_;
    std::uint32_t max_n_;
    bool enable_stop_words_;
    std::unordered_set<std::string> stop_words_;
};

}  // namespace bitcask::text
