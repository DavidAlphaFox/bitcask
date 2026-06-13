#include <gtest/gtest.h>

#include "bitcask/wildcard_matcher.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/search_layer.hpp"
#include "bitcask/analyzer.hpp"
#include "test_support.hpp"

using namespace bitcask::bm25;
using namespace bitcask::text;
using namespace bitcask::search;

namespace {

SearchLayerConfig default_config() {
    return SearchLayerConfig{
        .analyzer_config = AnalyzerConfig{},
        .bm25_params = Bm25Params{1.2F, 0.75F}
    };
}

}

TEST(WildcardMatch, Prefix) {
    EXPECT_TRUE(wildcard_match("te*", "test"));
    EXPECT_TRUE(wildcard_match("te*", "text"));
    EXPECT_TRUE(wildcard_match("te*", "tea"));
    EXPECT_FALSE(wildcard_match("te*", "hello"));
}

TEST(WildcardMatch, Suffix) {
    EXPECT_TRUE(wildcard_match("*st", "test"));
    EXPECT_TRUE(wildcard_match("*st", "first"));
    EXPECT_FALSE(wildcard_match("*st", "hello"));
}

TEST(WildcardMatch, SingleChar) {
    EXPECT_TRUE(wildcard_match("te?t", "test"));
    EXPECT_TRUE(wildcard_match("te?t", "text"));
    EXPECT_FALSE(wildcard_match("te?t", "tet"));
    EXPECT_FALSE(wildcard_match("te?t", "testt"));
}

TEST(WildcardMatch, Infix) {
    EXPECT_TRUE(wildcard_match("*ll*", "hello"));
    EXPECT_TRUE(wildcard_match("*ll*", "yellow"));
    EXPECT_FALSE(wildcard_match("*ll*", "world"));
}

TEST(WildcardMatch, StarMatchesEverything) {
    EXPECT_TRUE(wildcard_match("*", "hello"));
    EXPECT_TRUE(wildcard_match("*", ""));
    EXPECT_TRUE(wildcard_match("*", "a"));
}

TEST(WildcardMatch, QuestionMatchesSingleChar) {
    EXPECT_TRUE(wildcard_match("?", "a"));
    EXPECT_FALSE(wildcard_match("?", ""));
    EXPECT_FALSE(wildcard_match("?", "ab"));
}

TEST(WildcardMatch, ComplexPatterns) {
    EXPECT_TRUE(wildcard_match("h*o", "hello"));
    EXPECT_TRUE(wildcard_match("h*o", "ho"));
    EXPECT_FALSE(wildcard_match("h*o", "help"));
    EXPECT_TRUE(wildcard_match("te*t", "test"));
    EXPECT_TRUE(wildcard_match("te*t", "teat"));
}

TEST(WildcardMatch, EmptyPattern) {
    EXPECT_TRUE(wildcard_match("", ""));
    EXPECT_FALSE(wildcard_match("", "a"));
}

TEST(InvertedIndexWildcard, PrefixSearch) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"help", tp(1, {1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});
    idx.add_doc(2, {{"world", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;
    checker.doc_lens[1] = 10;
    checker.doc_lens[2] = 10;

    auto results = idx.search_wildcard("hel*", 10, checker);
    ASSERT_EQ(results.size(), 2u);
    EXPECT_EQ(results[0].ord, 0u);
    EXPECT_EQ(results[1].ord, 1u);
}

TEST(InvertedIndexWildcard, SuffixSearch) {
    InvertedIndex idx;
    idx.add_doc(0, {{"test", tp(1, {0})}});
    idx.add_doc(1, {{"first", tp(1, {0})}});
    idx.add_doc(2, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;
    checker.doc_lens[1] = 10;
    checker.doc_lens[2] = 10;

    auto results = idx.search_wildcard("*st", 10, checker);
    ASSERT_EQ(results.size(), 2u);
}

TEST(InvertedIndexWildcard, NoMatch) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search_wildcard("xyz*", 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndexWildcard, SkipsDeletedDocs) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(2, {0, 1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search_wildcard("hel*", 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
}

TEST(InvertedIndexWildcard, TopK) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(5, {0, 1, 2, 3, 4})}});
    idx.add_doc(2, {{"hello", tp(3, {0, 1, 2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;
    checker.doc_lens[1] = 10;
    checker.doc_lens[2] = 10;

    auto results = idx.search_wildcard("hel*", 2, checker);
    ASSERT_EQ(results.size(), 2u);
    EXPECT_EQ(results[0].ord, 1u);
}

// S10.4 回归：词表跨多个 shard，并行扫描须收齐全部匹配项、不漏不重。
// 200 个匹配 "termNNN" 的词（各落不同 doc，hash 后散布在 64 个 shard）+ 干扰词。
TEST(InvertedIndexWildcard, ParallelScanCollectsAllMatches) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    constexpr std::uint64_t kMatch = 200;
    for (std::uint64_t i = 0; i < kMatch; ++i) {
        idx.add_doc(i, {{"term" + std::to_string(i), tp(1, {0})}});
        checker.doc_lens[i] = 10;
    }
    // 干扰词：不匹配 "term*"。
    for (std::uint64_t i = 0; i < 50; ++i) {
        std::uint64_t ord = kMatch + i;
        idx.add_doc(ord, {{"other" + std::to_string(i), tp(1, {0})}});
        checker.doc_lens[ord] = 10;
    }

    auto results = idx.search_wildcard("term*", 1000, checker);
    EXPECT_EQ(results.size(), kMatch);  // 每个匹配词各 1 篇 doc，应全部命中

    std::vector<std::uint64_t> ords;
    for (auto& r : results) ords.push_back(r.ord);
    std::sort(ords.begin(), ords.end());
    ASSERT_EQ(ords.size(), kMatch);
    EXPECT_TRUE(std::unique(ords.begin(), ords.end()) == ords.end());  // 无重复
    EXPECT_EQ(ords.front(), 0u);
    EXPECT_EQ(ords.back(), kMatch - 1);
}

TEST(SearchLayerWildcard, PrefixSearch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "help me", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "world only", 1, 300, 50, 1002);

    auto result = layer.search_wildcard("hel*", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 2u);
    EXPECT_EQ(result->at(0).key, "doc2");
    EXPECT_EQ(result->at(1).key, "doc1");
}

TEST(SearchLayerWildcard, SuffixSearch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "test case", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "first try", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "hello world", 1, 300, 50, 1002);

    auto result = layer.search_wildcard("*st", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 2u);
}

TEST(SearchLayerWildcard, NoMatch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_wildcard("xyz*", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->empty());
}

TEST(SearchLayerWildcard, DeletedDocSkipped) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "help me", 1, 200, 50, 1001);
    layer.on_delete("doc1", 2);

    auto result = layer.search_wildcard("hel*", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc2");
}

// =========================================================================
// P2.5：最长字面量预过滤的必要性对拍——预过滤绝不能拒绝真命中
// =========================================================================

TEST(WildcardPrefilter, NeverRejectsRealMatch) {
    using bitcask::bm25::longest_literal;
    using bitcask::bm25::wildcard_match;
    // 确定性 LCG 生成随机 pattern（含 */?）与 text，验证必要性：
    // wildcard_match(p, t) == true ⟹ t 包含 longest_literal(p)。
    std::uint64_t seed = 11;
    auto next = [&seed] {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return seed >> 33;
    };
    const char syms[] = "ab*?";
    for (int iter = 0; iter < 20000; ++iter) {
        std::string pat, text;
        auto lp = next() % 8, lt = next() % 8;
        for (std::uint64_t i = 0; i < lp; ++i) pat.push_back(syms[next() % 4]);
        for (std::uint64_t i = 0; i < lt; ++i) text.push_back(syms[next() % 2]);
        if (!wildcard_match(pat, text)) continue;
        auto lit = longest_literal(pat);
        ASSERT_TRUE(lit.empty() || text.find(lit) != std::string::npos)
            << "pat=" << pat << " text=" << text << " lit=" << lit;
    }
}

TEST(WildcardPrefilter, LongestLiteralExtraction) {
    using bitcask::bm25::longest_literal;
    EXPECT_EQ(longest_literal("term1234*"), "term1234");
    EXPECT_EQ(longest_literal("*ing"), "ing");
    EXPECT_EQ(longest_literal("a?bcd*ef"), "bcd");
    EXPECT_EQ(longest_literal("***"), "");
    EXPECT_EQ(longest_literal("???"), "");
    EXPECT_EQ(longest_literal("plain"), "plain");
}
