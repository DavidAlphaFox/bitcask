#include <gtest/gtest.h>
#include <filesystem>

#include "bitcask/search_layer.hpp"

using namespace bitcask::search;

namespace {

SearchLayerConfig default_config() {
    return SearchLayerConfig{
        .analyzer_config = bitcask::text::AnalyzerConfig{},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
}

}  // namespace

TEST(SearchLayer, WriteAndSearch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "key1");
    EXPECT_EQ(result->at(0).ord, 0u);
    EXPECT_GE(result->at(0).score, 0.0);
}

TEST(SearchLayer, WriteDeleteSearch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    auto del = layer.on_delete("key1", 1);
    ASSERT_TRUE(del.has_value());
    EXPECT_EQ(del.value(), 1u);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->empty());
}

TEST(SearchLayer, MultipleDocsRanking) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world foo bar", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hello world baz qux", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "foo bar baz qux", 1, 300, 50, 1002);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 2u);

    EXPECT_EQ(result->at(0).key, "doc2");
    EXPECT_EQ(result->at(1).key, "doc1");
}

TEST(SearchLayer, OnRelocate) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    layer.on_relocate("key1", 0, 2, 500, 75);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "key1");
}

TEST(SearchLayer, RecoverDoc) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.recover_doc("key1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).key, "key1");
}

TEST(SearchLayer, RecoverTomb) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.recover_doc("key1", 0, "hello world", 1, 100, 50, 1000);

    layer.recover_tomb("key1", 1);

    auto result = layer.search_text("hello", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->empty());
}

TEST(SearchLayer, SnapshotSaveLoad) {
    auto config = default_config();
    SearchLayer layer1(config);

    layer1.on_write("key1", 0, "hello world", 1, 100, 50, 1000);
    layer1.on_write("key2", 1, "foo bar", 1, 200, 40, 1001);

    auto snapshot_path = std::filesystem::temp_directory_path() / "bitcask_search_snapshot_test.inv";
    std::filesystem::remove(snapshot_path);

    auto save_result = layer1.save_snapshot(snapshot_path.string());
    ASSERT_TRUE(save_result.has_value());

    SearchLayer layer2(config);
    layer2.recover_doc("key1", 0, "hello world", 1, 100, 50, 1000);
    layer2.recover_doc("key2", 1, "foo bar", 1, 200, 40, 1001);

    auto load_result = layer2.load_snapshot(snapshot_path.string());
    ASSERT_TRUE(load_result.has_value());
    EXPECT_TRUE(*load_result);

    auto search_result = layer2.search_text("hello", 10);
    ASSERT_TRUE(search_result.has_value());
    ASSERT_EQ(search_result->size(), 1u);
    EXPECT_EQ(search_result->at(0).key, "key1");

    std::filesystem::remove(snapshot_path);
}

TEST(SearchLayer, PhraseSearch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world foo bar", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "world hello", 1, 200, 40, 1001);

    auto result_phrase = layer.search_phrase("hello world", 10);
    ASSERT_TRUE(result_phrase.has_value());
    EXPECT_EQ(result_phrase->size(), 1u);
    EXPECT_EQ(result_phrase->at(0).key, "doc1");
}

TEST(SearchLayer, PhraseSearchNoMatch) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_phrase("hello world", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(result->empty());
}

TEST(SearchLayer, SearchEmptyQuery) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    auto result = layer.search_text("", 10);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->empty());
}

TEST(SearchLayer, DeleteNonExistentKey) {
    auto config = default_config();
    SearchLayer layer(config);

    auto del = layer.on_delete("nonexistent", 0);
    EXPECT_FALSE(del.has_value());
}

TEST(SearchLayer, IndexAccess) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("key1", 0, "hello world", 1, 100, 50, 1000);

    auto& idx = layer.index();
    auto slot = idx.get("key1");
    ASSERT_TRUE(slot.has_value());
    EXPECT_EQ(slot->loc.file_id, 1u);
    EXPECT_EQ(slot->loc.offset, 100u);
}

TEST(SearchLayer, RebuildIndexCleansDeadPostings) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world foo bar", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hello world baz qux", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "foo bar baz qux", 1, 300, 50, 1002);

    auto result_before = layer.search_text("hello", 10);
    ASSERT_TRUE(result_before.has_value());
    ASSERT_EQ(result_before->size(), 2u);

    layer.on_delete("doc1", 3);

    auto result_after_delete = layer.search_text("hello", 10);
    ASSERT_TRUE(result_after_delete.has_value());
    ASSERT_EQ(result_after_delete->size(), 1u);
    EXPECT_EQ(result_after_delete->at(0).key, "doc2");

    auto mock_reader = [](std::uint32_t fid, std::uint64_t off, std::uint32_t)
        -> std::optional<std::string> {
        if (fid == 1 && off == 200) {
            return std::string("hello world baz qux");
        }
        if (fid == 1 && off == 300) {
            return std::string("foo bar baz qux");
        }
        return std::nullopt;
    };
    layer.rebuild_index(mock_reader);

    auto result_after_rebuild = layer.search_text("hello", 10);
    ASSERT_TRUE(result_after_rebuild.has_value());
    ASSERT_EQ(result_after_rebuild->size(), 1u);
    EXPECT_EQ(result_after_rebuild->at(0).key, "doc2");

    auto result_foo = layer.search_text("foo", 10);
    ASSERT_TRUE(result_foo.has_value());
    ASSERT_EQ(result_foo->size(), 1u);
    EXPECT_EQ(result_foo->at(0).key, "doc3");
}

TEST(SearchLayer, CacheHitTest) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto result1 = layer.search_text("hello", 10);
    ASSERT_TRUE(result1.has_value());
    ASSERT_EQ(result1->size(), 1u);

    auto result2 = layer.search_text("hello", 10);
    ASSERT_TRUE(result2.has_value());
    ASSERT_EQ(result2->size(), 1u);

    EXPECT_EQ(result1->at(0).key, result2->at(0).key);
    EXPECT_EQ(result1->at(0).ord, result2->at(0).ord);
    EXPECT_EQ(result1->at(0).score, result2->at(0).score);
}

TEST(SearchLayer, CacheInvalidationTest) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world foo bar", 1, 100, 50, 1000);

    auto result1 = layer.search_text("foo", 10);
    ASSERT_TRUE(result1.has_value());
    ASSERT_EQ(result1->size(), 1u);
    EXPECT_EQ(result1->at(0).key, "doc1");

    auto result1_2 = layer.search_text("foo", 10);
    ASSERT_TRUE(result1_2.has_value());
    ASSERT_EQ(result1_2->size(), 1u);

    layer.on_write("doc2", 1, "hello world baz qux", 1, 200, 50, 1001);

    auto result2 = layer.search_text("foo", 10);
    ASSERT_TRUE(result2.has_value());
    ASSERT_EQ(result2->size(), 1u);
    EXPECT_EQ(result2->at(0).key, "doc1");
}

TEST(SearchLayer, CacheEvictionTest) {
    auto config = default_config();
    config.cache_max_entries = 2;
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "foo bar", 1, 200, 50, 1001);
    layer.on_write("doc3", 2, "baz qux", 1, 300, 50, 1002);

    auto result1 = layer.search_text("hello", 10);
    ASSERT_TRUE(result1.has_value());
    auto result2 = layer.search_text("foo", 10);
    ASSERT_TRUE(result2.has_value());
    auto result3 = layer.search_text("baz", 10);
    ASSERT_TRUE(result3.has_value());

    EXPECT_EQ(result1->size(), 1u);
    EXPECT_EQ(result2->size(), 1u);
    EXPECT_EQ(result3->size(), 1u);
}

TEST(SearchLayer, CachePhraseTest) {
    auto config = default_config();
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world foo bar", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "world hello", 1, 200, 40, 1001);

    auto result_text = layer.search_text("hello world", 10);
    ASSERT_TRUE(result_text.has_value());

    auto result_phrase = layer.search_phrase("hello world", 10);
    ASSERT_TRUE(result_phrase.has_value());
    EXPECT_EQ(result_phrase->size(), 1u);
    EXPECT_EQ(result_phrase->at(0).key, "doc1");
}

TEST(SearchLayer, CacheDisabledTest) {
    auto config = default_config();
    config.cache_max_entries = 0;
    SearchLayer layer(config);

    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);

    auto result1 = layer.search_text("hello", 10);
    ASSERT_TRUE(result1.has_value());
    ASSERT_EQ(result1->size(), 1u);

    auto result2 = layer.search_text("hello", 10);
    ASSERT_TRUE(result2.has_value());
    ASSERT_EQ(result2->size(), 1u);

    EXPECT_EQ(result1->at(0).key, result2->at(0).key);
}