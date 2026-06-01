#include <gtest/gtest.h>

#include "bitcask/wildcard_matcher.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/search_layer.hpp"
#include "bitcask/analyzer.hpp"

using namespace bitcask::bm25;
using namespace bitcask::text;
using namespace bitcask::search;

namespace {

class FakeLiveChecker : public LiveChecker {
public:
    std::unordered_map<std::uint64_t, std::uint32_t> doc_lens;

    [[nodiscard]] bool is_live(std::uint64_t ord) const override {
        return doc_lens.count(ord) > 0;
    }
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t ord) const override {
        auto it = doc_lens.find(ord);
        return it != doc_lens.end() ? it->second : 0;
    }
};

auto tp(std::uint32_t tf, std::vector<std::uint32_t> positions = {})
    -> std::pair<std::uint32_t, std::vector<std::uint32_t>> {
    return {tf, std::move(positions)};
}

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
