#include <gtest/gtest.h>

#include "bitcask/fuzzy_matcher.hpp"
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

// =========================================================================
// P2.3：Myers 位并行 vs 经典 levenshtein 黑盒对拍
// =========================================================================

#include "bitcask/myers.hpp"

// 确定性 LCG（不用 std::random_device，保证可复现）。
namespace {
struct Lcg {
    std::uint64_t s;
    std::uint64_t next() { s = s * 6364136223846793005ULL + 1442695040888963407ULL; return s >> 33; }
};
}  // namespace

TEST(MyersMatcher, AgreesWithLevenshteinRandomized) {
    Lcg rng{42};
    const char alphabet[] = "abc";  // 小字母表逼出高碰撞/重复字符场景
    for (int iter = 0; iter < 5000; ++iter) {
        std::string a, b;
        auto la = rng.next() % 9, lb = rng.next() % 9;
        for (std::uint64_t i = 0; i < la; ++i) a.push_back(alphabet[rng.next() % 3]);
        for (std::uint64_t i = 0; i < lb; ++i) b.push_back(alphabet[rng.next() % 3]);
        MyersMatcher m(a);
        auto d = levenshtein_distance(a, b);
        for (std::uint32_t k = 0; k <= 3; ++k) {
            ASSERT_EQ(m.within(b, k), d <= k)
                << "a=" << a << " b=" << b << " d=" << d << " k=" << k;
        }
    }
}

TEST(MyersMatcher, BoundaryAndFallback) {
    // m=64 边界（位并行的满字宽路径）。
    std::string p64(64, 'x');
    MyersMatcher m64(p64);
    EXPECT_TRUE(m64.within(p64, 0));
    std::string q = p64; q[10] = 'y';
    EXPECT_FALSE(m64.within(q, 0));
    EXPECT_TRUE(m64.within(q, 1));

    // m=65 → 退回经典 DP。
    std::string p65(65, 'x');
    MyersMatcher m65(p65);
    EXPECT_TRUE(m65.within(p65, 0));
    std::string q65 = p65; q65.pop_back();
    EXPECT_TRUE(m65.within(q65, 1));
    EXPECT_FALSE(m65.within(q65, 0));

    // 空模式串。
    MyersMatcher me("");
    EXPECT_TRUE(me.within("", 0));
    EXPECT_TRUE(me.within("ab", 2));
    EXPECT_FALSE(me.within("ab", 1));

    // UTF-8 多字节：按字节语义，与 levenshtein_distance 一致。
    MyersMatcher mc("北京");
    EXPECT_TRUE(mc.within("北京", 0));
    auto d = levenshtein_distance("北京", "北亰");
    EXPECT_EQ(mc.within("北亰", d), true);
    EXPECT_EQ(mc.within("北亰", d - 1), false);
}
