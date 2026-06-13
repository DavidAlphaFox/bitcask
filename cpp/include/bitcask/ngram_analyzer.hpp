// CJK 字符级 n-gram + 拉丁空白切分分词器。
//
// NgramAnalyzer 是 bitcask::text::Analyzer 接口的默认实现（V2.1）。
// 处理管线：NFKC 归一化 → case fold → CJK 检测 → 分流：
//   - CJK 字符序列：滑窗生成 [min_n, max_n] 字符的 n-gram
//   - 拉丁 / 其他：按空白切分 + 小写
// 两条路径的 term 合并后统计词频（tf），返回 TermFreqMap。
//
// 线程安全：analyze() 是 const 方法，内部无 mutable 状态，天然线程安全。

#pragma once

#include <cstdint>

#include <string>
#include <unordered_set>

#include "bitcask/analyzer.hpp"

namespace bitcask::text {

class NgramAnalyzer final : public Analyzer {
public:
    explicit NgramAnalyzer(std::uint32_t min_n = 2, std::uint32_t max_n = 3,
                           bool enable_stop_words = false,
                           std::vector<std::string> custom_stop_words = {},
                           std::uint32_t min_token_length = 1);

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override;

    [[nodiscard]] auto analyze_with_offsets(std::string_view text) const
        -> TermTokenMap override;

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return AnalyzerType::Ngram;
    }

    [[nodiscard]] auto min_n() const noexcept -> std::uint32_t { return min_n_; }
    [[nodiscard]] auto max_n() const noexcept -> std::uint32_t { return max_n_; }

private:
    std::uint32_t min_n_;
    std::uint32_t max_n_;
    bool enable_stop_words_;
    std::unordered_set<std::string> stop_words_;
    std::uint32_t min_token_length_;   // 拉丁整词最小 codepoint 长度（S9.8），1=不过滤
};

}  // namespace bitcask::text
