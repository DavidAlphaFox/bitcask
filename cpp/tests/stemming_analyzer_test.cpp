#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/stemming_analyzer.hpp"
#include "bitcask/whitespace_analyzer.hpp"

using namespace bitcask::text;

TEST(StemmingAnalyzer, WrapWhitespace) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto result = analyzer->analyze("running cats");
    EXPECT_EQ(result.size(), 2u);
    EXPECT_GT(result.count("run"), 0u);
    EXPECT_GT(result.count("cat"), 0u);
    EXPECT_EQ(result.count("running"), 0u);
    EXPECT_EQ(result.count("cats"), 0u);
}

TEST(StemmingAnalyzer, IndexQueryMatch) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto indexed = analyzer->analyze("generalization");
    auto queried = analyzer->analyze("generalized");

    for (auto& [term, tf] : indexed) {
        (void)tf;
        EXPECT_GT(queried.count(term), 0u)
            << "Indexed term '" << term << "' not found in query terms";
    }
}

TEST(StemmingAnalyzer, Positions) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto result = analyzer->analyze_with_positions("the running fox");

    EXPECT_GT(result.count("run"), 0u);
    auto& run_data = result.at("run");
    EXPECT_EQ(run_data.first, 1u);
    ASSERT_EQ(run_data.second.size(), 1u);
    EXPECT_EQ(run_data.second[0], 1u);
}

TEST(StemmingAnalyzer, Offsets) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto result = analyzer->analyze_with_offsets("the running fox");

    EXPECT_GT(result.count("run"), 0u);
    auto& run_infos = result.at("run");
    ASSERT_EQ(run_infos.size(), 1u);
    EXPECT_EQ(run_infos[0].position, 1u);
    EXPECT_GT(run_infos[0].start_byte, 0u);
}

TEST(StemmingAnalyzer, TypeDelegated) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    EXPECT_EQ(analyzer->type(), AnalyzerType::Whitespace);
}

TEST(StemmingAnalyzer, EmptyText) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto result = analyzer->analyze("");
    EXPECT_TRUE(result.empty());
}

TEST(StemmingAnalyzer, CJKNotStemmed) {
    auto inner = std::make_unique<WhitespaceAnalyzer>();
    auto analyzer = std::make_unique<StemmingAnalyzer>(std::move(inner));

    auto result = analyzer->analyze("北京 朝阳");
    EXPECT_GT(result.count("北京"), 0u);
    EXPECT_GT(result.count("朝阳"), 0u);
}