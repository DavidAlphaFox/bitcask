#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "bitcask/analyzer.hpp"
#include "bitcask/porter_stemmer.hpp"

namespace bitcask::text {

class StemmingAnalyzer final : public Analyzer {
public:
    explicit StemmingAnalyzer(std::unique_ptr<Analyzer> inner)
        : inner_(std::move(inner)) {}

    [[nodiscard]] auto analyze(std::string_view text) const
        -> TermFreqMap override {
        auto inner_result = inner_->analyze(text);
        TermFreqMap result;
        for (auto& [term, tf] : inner_result) {
            auto stemmed = porter_stem(term);
            result[stemmed] += tf;
        }
        return result;
    }

    [[nodiscard]] auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap override {
        auto inner_result = inner_->analyze_with_positions(text);
        TermPositionsMap result;
        for (auto& [term, data] : inner_result) {
            auto stemmed = porter_stem(term);
            auto& entry = result[stemmed];
            entry.first += data.first;
            for (auto pos : data.second) {
                entry.second.push_back(pos);
            }
        }
        return result;
    }

    [[nodiscard]] auto analyze_with_offsets(std::string_view text) const
        -> TermTokenMap override {
        auto inner_result = inner_->analyze_with_offsets(text);
        TermTokenMap result;
        for (auto& [term, infos] : inner_result) {
            auto stemmed = porter_stem(term);
            result[stemmed] = std::move(infos);
        }
        return result;
    }

    [[nodiscard]] auto type() const noexcept -> AnalyzerType override {
        return inner_->type();
    }

private:
    std::unique_ptr<Analyzer> inner_;
};

}  // namespace bitcask::text