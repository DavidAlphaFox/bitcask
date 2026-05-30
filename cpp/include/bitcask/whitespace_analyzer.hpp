// 纯空白切分分词器（调试 / 纯拉丁场景）。
//
// WhitespaceAnalyzer 按 Unicode 空白字符切分，对小写拉丁文本做 case fold。
// 不做 n-gram，不识别 CJK。适用于调试基准或纯英文文档。

#pragma once

#include "bitcask/analyzer.hpp"

namespace bitcask::text {

class WhitespaceAnalyzer final : public Analyzer {
public:
    WhitespaceAnalyzer() = default;

    [[nodiscard]] auto analyze(std::string_view text) const
        -> TermFreqMap override;

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override;

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return AnalyzerType::Whitespace;
    }
};

}  // namespace bitcask::text
