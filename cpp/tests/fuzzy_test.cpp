#include <gtest/gtest.h>

#include "bitcask/fuzzy_matcher.hpp"
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
        .analyzer_config = AnalyzerConfig{
            .type = AnalyzerType::Whitespace},
        .bm25_params = Bm25Params{1.2F, 0.75F}
    };
}

}

TEST(LevenshteinDistance, IdenticalStrings) {
    EXPECT_EQ(levenshtein_distance("hello", "hello"), 0u);
}

TEST(LevenshteinDistance, SingleDeletion) {
    EXPECT_EQ(levenshtein_distance("hello", "helo"), 1u);
}

TEST(LevenshteinDistance, SingleSubstitution) {
    EXPECT_EQ(levenshtein_distance("hello", "hallo"), 1u);
}

TEST(LevenshteinDistance, LargeDistance) {
    EXPECT_EQ(levenshtein_distance("hello", "world"), 4u);
}

TEST(LevenshteinDistance, EmptyStrings) {
    EXPECT_EQ(levenshtein_distance("", ""), 0u);
    EXPECT_EQ(levenshtein_distance("abc", ""), 3u);
    EXPECT_EQ(levenshtein_distance("", "abc"), 3u);
}

TEST(LevenshteinDistance, Insertion) {
    EXPECT_EQ(levenshtein_distance("helo", "hello"), 1u);
}

TEST(LevenshteinDistance, Transposition) {
    EXPECT_EQ(levenshtein_distance("ab", "ba"), 2u);
}

TEST(InvertedIndexFuzzy, FindsNearMatch) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search_fuzzy({"helo"}, 10, 1, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
}

TEST(InvertedIndexFuzzy, RespectsMaxDistance) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search_fuzzy({"world"}, 10, 1, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndexFuzzy, SkipsDeletedDocs) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search_fuzzy({"helo"}, 10, 1, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
}

TEST(InvertedIndexFuzzy, TopK) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(5, {0, 1, 2, 3, 4})}});
    idx.add_doc(2, {{"hello", tp(3, {0, 1, 2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;
    checker.doc_lens[1] = 10;
    checker.doc_lens[2] = 10;

    auto results = idx.search_fuzzy({"helo"}, 2, 1, checker);
    ASSERT_EQ(results.size(), 2u);
    EXPECT_EQ(results[0].ord, 1u);
}

// S10.2 回归：两个 query 词同时模糊命中同一 vocab term（"hello"），
// 该 term 只应被计分一次。修复前翻倍 IDF 贡献，分数约为单词查询的 2 倍。
TEST(InvertedIndexFuzzy, NoDoubleCountWhenTwoQueryTermsMatchSameTerm) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto single = idx.search_fuzzy({"helo"}, 10, 1, checker);
    auto doubled = idx.search_fuzzy({"helo", "hallo"}, 10, 1, checker);

    ASSERT_EQ(single.size(), 1u);
    ASSERT_EQ(doubled.size(), 1u);
    EXPECT_EQ(single[0].ord, doubled[0].ord);
    // 去重后分数与单词查询一致（修复前 doubled 约为 single 的 2 倍）。
    EXPECT_NEAR(single[0].score, doubled[0].score, 1e-5F);
}

TEST(SearchLayerFuzzy, FindsDocsWithTypos) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "foo bar", 1, 200, 50, 1001);

    auto result = layer.search_fuzzy("helo", 10, 1);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc1");
}

TEST(SearchLayerFuzzy, NoMatchBeyondDistance) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_fuzzy("world", 10, 0);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 1u);

    auto result2 = layer.search_fuzzy("xyz", 10, 1);
    ASSERT_TRUE(result2.has_value());
    EXPECT_TRUE(result2->empty());
}

TEST(SearchLayerFuzzy, DeletedDocSkipped) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "help me", 1, 200, 50, 1001);
    layer.on_delete("doc1", 2);

    auto result = layer.search_fuzzy("helo", 10, 1);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc2");
}
