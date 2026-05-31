#include <gtest/gtest.h>

#include "bitcask/search_layer.hpp"
#include "bitcask/highlighter.hpp"

#include <string_view>

using namespace bitcask::search;

namespace {

SearchLayerConfig whitespace_config() {
    return SearchLayerConfig{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace
        },
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
}

}  // namespace

TEST(Highlighter, BasicEnglish) {
    auto layer = SearchLayer(whitespace_config());
    layer.on_write("key1", 0, "hello world foo bar", 1, 100, 50, 1000);

    auto result = layer.search_text_highlight("foo", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);

    auto& hit = result->at(0);
    EXPECT_EQ(hit.key, "key1");
    EXPECT_FALSE(hit.highlights.empty());
    EXPECT_TRUE(hit.highlights[0].text.find("<em>foo</em>") != std::string::npos);
}

TEST(Highlighter, MultipleTerms) {
    auto layer = SearchLayer(whitespace_config());
    layer.on_write("key1", 0, "the quick brown fox jumps over the lazy dog", 1, 100, 50, 1000);

    auto result = layer.search_text_highlight("quick fox", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);

    auto& hit = result->at(0);
    ASSERT_FALSE(hit.highlights.empty());
    bool has_quick = hit.highlights[0].text.find("<em>quick</em>") != std::string::npos;
    bool has_fox = hit.highlights[0].text.find("<em>fox</em>") != std::string::npos;
    EXPECT_TRUE(has_quick || has_fox) << "text: " << hit.highlights[0].text;
}

TEST(Highlighter, NoMatch) {
    auto layer = SearchLayer(whitespace_config());
    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_text_highlight("xyz", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_TRUE(result->empty());
}

TEST(Highlighter, FragmentSize) {
    auto layer = SearchLayer(whitespace_config());
    std::string long_text = "hello world foo bar baz qux quux corge grault garply waldo "
                           "fred plugh xyzzy thud hoge fuga piyo";
    layer.on_write("key1", 0, long_text, 1, 100, 50, 1000);

    HighlightOptions opts;
    opts.fragment_size = 30;
    opts.max_fragments = 1;

    auto result = layer.search_text_highlight("foo", 10, opts);
    ASSERT_TRUE(result.has_value());
    ASSERT_FALSE(result->empty());

    EXPECT_LE(result->at(0).highlights[0].text.size(), opts.fragment_size + 64);
}

TEST(Highlighter, MultipleFragments) {
    auto layer = SearchLayer(whitespace_config());
    layer.on_write("key1", 0, "foo bar foo baz foo qux", 1, 100, 50, 1000);

    HighlightOptions opts;
    opts.fragment_size = 15;
    opts.max_fragments = 3;

    auto result = layer.search_text_highlight("foo", 10, opts);
    ASSERT_TRUE(result.has_value());

    EXPECT_GE(result->at(0).highlights.size(), 1u);
}

TEST(Highlighter, SearchTextHighlightIntegration) {
    auto layer = SearchLayer(whitespace_config());

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hello bitcask search", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "world of search", 1, 300, 50, 1002);

    auto result = layer.search_text_highlight("hello search", 10);
    ASSERT_TRUE(result.has_value());

    bool found_doc1 = false;
    bool found_doc2 = false;
    for (auto& hit : *result) {
        if (hit.key == "doc1") {
            found_doc1 = true;
            EXPECT_FALSE(hit.highlights.empty());
        }
        if (hit.key == "doc2") {
            found_doc2 = true;
            EXPECT_FALSE(hit.highlights.empty());
        }
    }
    EXPECT_TRUE(found_doc1 || found_doc2);
}