// 纯空白切分分词器（调试 / 纯拉丁场景）。
//
// WhitespaceAnalyzer 按 Unicode 空白字符切分，对小写拉丁文本做 case fold。
// 不做 n-gram，不识别 CJK。适用于调试基准或纯英文文档。

#pragma once

#include <cstdint>

#include "bitcask/analyzer.hpp"

namespace bitcask::text {

class WhitespaceAnalyzer final : public Analyzer {
public:
    WhitespaceAnalyzer() = default;
    explicit WhitespaceAnalyzer(std::uint32_t min_token_length)
        : min_token_length_(min_token_length) {}

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override;

    [[nodiscard]] auto analyze_with_offsets(std::string_view text) const
        -> TermTokenMap override;

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return AnalyzerType::Whitespace;
    }

private:
    std::uint32_t min_token_length_ = 1;   // 整词最小 codepoint 长度（S9.8），1=不过滤
};

}  // namespace bitcask::text
