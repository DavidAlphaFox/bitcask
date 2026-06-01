#include <filesystem>
#include <fstream>
#include <gtest/gtest.h>

#include "bitcask/search_layer.hpp"
#include "bitcask/synonym_map.hpp"

using namespace bitcask::text;
using namespace bitcask::search;

TEST(SynonymMap, AddGroupAndExpand) {
    SynonymMap map;
    map.add_group({"NYC", "New York", "Big Apple"});

    auto r1 = map.expand("NYC");
    EXPECT_EQ(r1.size(), 3u);
    EXPECT_TRUE(std::find(r1.begin(), r1.end(), "NYC") != r1.end());
    EXPECT_TRUE(std::find(r1.begin(), r1.end(), "New York") != r1.end());
    EXPECT_TRUE(std::find(r1.begin(), r1.end(), "Big Apple") != r1.end());

    auto r2 = map.expand("New York");
    EXPECT_EQ(r2.size(), 3u);
}

TEST(SynonymMap, ExpandUnknownTerm) {
    SynonymMap map;
    auto r = map.expand("unknown");
    EXPECT_EQ(r.size(), 1u);
    EXPECT_EQ(r[0], "unknown");
}

TEST(SynonymMap, ExpandTermsDedup) {
    SynonymMap map;
    map.add_group({"NYC", "New York", "Big Apple"});
    map.add_group({"car", "automobile", "vehicle"});

    auto r = map.expand_terms({"NYC", "car"});
    EXPECT_EQ(r.size(), 6u);
}

TEST(SynonymMap, ExpandTermsWithUnknown) {
    SynonymMap map;
    map.add_group({"NYC", "New York"});

    auto r = map.expand_terms({"NYC", "hello"});
    EXPECT_EQ(r.size(), 3u);
    EXPECT_TRUE(std::find(r.begin(), r.end(), "NYC") != r.end());
    EXPECT_TRUE(std::find(r.begin(), r.end(), "New York") != r.end());
    EXPECT_TRUE(std::find(r.begin(), r.end(), "hello") != r.end());
}

TEST(SynonymMap, LoadFromFile) {
    auto path = std::filesystem::temp_directory_path() / "bitcask_synonym_test.txt";
    {
        std::ofstream ofs(path);
        ofs << "NYC, New York, Big Apple\n";
        ofs << "car, automobile\n";
    }

    SynonymMap map;
    map.load_from_file(path.string());

    auto r = map.expand("NYC");
    EXPECT_EQ(r.size(), 3u);

    auto r2 = map.expand("car");
    EXPECT_EQ(r2.size(), 2u);

    std::filesystem::remove(path);
}

TEST(SynonymMap, LoadFromFileEmptyLine) {
    auto path = std::filesystem::temp_directory_path() / "bitcask_synonym_empty.txt";
    {
        std::ofstream ofs(path);
        ofs << "\n";
        ofs << "a, b\n";
    }

    SynonymMap map;
    map.load_from_file(path.string());

    auto r = map.expand("a");
    EXPECT_EQ(r.size(), 2u);

    std::filesystem::remove(path);
}

TEST(SearchLayerSynonym, SearchTextWithSynonym) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "nyc is great", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "automobile is great", 1, 200, 50, 1001);

    auto result_before = layer.search_text("nyc", 10);
    ASSERT_TRUE(result_before.has_value());
    EXPECT_EQ(result_before->size(), 1u);

    auto sm = std::make_unique<SynonymMap>();
    sm->add_group({"nyc", "automobile"});
    layer.set_synonym_map(std::move(sm));

    auto result_after = layer.search_text("nyc", 10);
    ASSERT_TRUE(result_after.has_value());
    EXPECT_EQ(result_after->size(), 2u);
}

TEST(SearchLayerSynonym, SearchTextWithSynonymViaAlias) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto sm = std::make_unique<SynonymMap>();
    sm->add_group({"hi", "hello"});
    layer.set_synonym_map(std::move(sm));

    auto result = layer.search_text("hi", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc1");
}

TEST(SearchLayerSynonym, PhraseSearchDoesNotExpand) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hi world", 1, 200, 50, 1001);

    auto sm = std::make_unique<SynonymMap>();
    sm->add_group({"hi", "hello"});
    layer.set_synonym_map(std::move(sm));

    auto result = layer.search_phrase("hi world", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc2");
}

TEST(SearchLayerSynonym, NearSearchDoesNotExpand) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hi world", 1, 200, 50, 1001);

    auto sm = std::make_unique<SynonymMap>();
    sm->add_group({"hi", "hello"});
    layer.set_synonym_map(std::move(sm));

    auto result = layer.search_near("hi world", 0, 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "doc2");
}

TEST(SearchLayerSynonym, SearchFieldsWithSynonym) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "nyc is great", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "automobile is great", 1, 200, 50, 1001);

    auto sm = std::make_unique<SynonymMap>();
    sm->add_group({"nyc", "automobile"});
    layer.set_synonym_map(std::move(sm));

    auto result = layer.search_fields("nyc", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->size(), 2u);
}
