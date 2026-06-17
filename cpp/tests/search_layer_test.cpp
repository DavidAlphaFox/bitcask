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

    auto snapshot_path = std::filesystem::temp_directory_path() / "bitcask_search_ckpt_test.bin";
    std::filesystem::remove(snapshot_path);
    std::filesystem::remove(std::string(snapshot_path.string()) + ".prev");

    ASSERT_TRUE(layer1.save_search_ckpt(snapshot_path.string(), 2));

    SearchLayer layer2(config);
    auto result = layer2.load_search_ckpt(snapshot_path.string());
    ASSERT_TRUE(result.loaded);
    ASSERT_TRUE(result.all_segments_ok);

    auto search_result = layer2.search_text("hello", 10);
    ASSERT_TRUE(search_result.has_value());
    ASSERT_EQ(search_result->size(), 1u);
    EXPECT_EQ(search_result->at(0).key, "key1");

    std::filesystem::remove(snapshot_path);
    std::filesystem::remove(std::string(snapshot_path.string()) + ".prev");
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

// S9.28：短语词序敏感——逆序文档不应匹配正序短语。
// 用 whitespace analyzer + 3 词短语（更易暴露 map 无序导致的词序丢失）。
TEST(SearchLayer, PhraseOrderSensitive) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);
    layer.on_write("doc1", 0, "alpha beta gamma", 1, 100, 50, 1000);   // 正序
    layer.on_write("doc2", 1, "gamma beta alpha", 1, 200, 50, 1001);   // 逆序

    // 查正序短语 "alpha beta gamma" → 只命中 doc1。
    auto r = layer.search_phrase("alpha beta gamma", 10);
    ASSERT_TRUE(r.has_value());
    ASSERT_EQ(r->size(), 1u);
    EXPECT_EQ(r->at(0).key, "doc1");

    // 查逆序短语 "gamma beta alpha" → 只命中 doc2。
    auto r2 = layer.search_phrase("gamma beta alpha", 10);
    ASSERT_TRUE(r2.has_value());
    ASSERT_EQ(r2->size(), 1u);
    EXPECT_EQ(r2->at(0).key, "doc2");
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

// 回归 S9.19：非规范文本（全角字母）的高亮。analyze_with_offsets 的 offset
// 相对归一化文本，highlight 必须也在归一化文本上切片，否则会切出 UTF-8 乱码
// （修复前 "ＨＥＬＬＯ world" 查 "world" 会高亮成 "<em>Ｌ\xef\xbf\xbd</em>"）。
TEST(SearchLayer, HighlightFullwidthText) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);

    // 全角 "ＨＥＬＬＯ"（每字符 3 字节）+ 半角 " world"。NFKC 折成 "hello world"。
    layer.on_write("doc1", 0, "ＨＥＬＬＯ world", 1, 100, 50, 1000);

    auto hits = layer.search_text_highlight("world", 10);
    ASSERT_TRUE(hits.has_value());
    ASSERT_EQ(hits->size(), 1u);
    ASSERT_FALSE(hits->at(0).highlights.empty());

    // 片段必须精确高亮 "world"，且不含 UTF-8 替换字符（U+FFFD = EF BF BD）。
    const auto& snippet = hits->at(0).highlights[0].text;
    EXPECT_NE(snippet.find("<em>world</em>"), std::string::npos) << "snippet=" << snippet;
    EXPECT_EQ(snippet.find("\xEF\xBF\xBD"), std::string::npos)
        << "snippet contains UTF-8 replacement char (garbage): " << snippet;
}

// S8.10：BM25+ 的 δ 应提升分数（每个命中 term 加 idf*δ），且 explain 与 search
// 在 δ>0 下仍一致（δ 加在所有评分路径）。
TEST(SearchLayer, Bm25PlusDeltaBoostsScore) {
    auto config = default_config();
    SearchLayer layer(config);
    layer.on_write("doc1", 0, "hello world foo bar baz", 1, 100, 50, 1000);

    auto def = layer.search_text("hello", 10);
    ASSERT_TRUE(def.has_value());
    ASSERT_FALSE(def->empty());

    bitcask::bm25::Bm25Params p{1.2F, 0.75F, 1.0F};  // delta=1.0
    auto plus = layer.search_text("hello", 10, &p);
    ASSERT_TRUE(plus.has_value());
    ASSERT_FALSE(plus->empty());

    // BM25+ 分数应高于标准 BM25（δ 加了正的下界贡献）。
    EXPECT_GT(plus->at(0).score, def->at(0).score);

    // explain 在同样 δ 下 total 应与 search 分数一致。
    auto exp = layer.explain("hello", "doc1", &p);
    ASSERT_TRUE(exp.has_value());
    EXPECT_NEAR(exp->total, plus->at(0).score, 1e-4);
}

// S8.6：多字段写入 + field:term 字段路由。
TEST(SearchLayer, MultiFieldRouting) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);
    // doc1: title 含 "apple"，body 含 "banana"
    layer.on_write_fields("doc1", 0,
        {{"title", "apple fruit"}, {"body", "banana split dessert"}},
        1, 100, 50, 1000);
    // doc2: title 含 "banana"，body 含 "apple"
    layer.on_write_fields("doc2", 1,
        {{"title", "banana bread"}, {"body", "apple pie recipe"}},
        1, 200, 50, 1001);

    // title:apple 只应命中 doc1（apple 在 doc1 的 title、doc2 的 body）。
    auto r = layer.search_fields("title:apple", 10);
    ASSERT_TRUE(r.has_value());
    ASSERT_EQ(r->size(), 1u);
    EXPECT_EQ(r->at(0).key, "doc1");

    // title:banana 只应命中 doc2。
    auto r2 = layer.search_fields("title:banana", 10);
    ASSERT_TRUE(r2.has_value());
    ASSERT_EQ(r2->size(), 1u);
    EXPECT_EQ(r2->at(0).key, "doc2");
}

// S8.6 catch-all 修复（Erlang REPL 实测发现）：多字段文档必须能被普通
// search_text（只查默认字段）命中——on_write_fields 把字段文本合并进默认字段。
TEST(SearchLayer, MultiFieldVisibleToPlainSearch) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);
    layer.on_write_fields("doc1", 0,
        {{"title", "quick brown"}, {"body", "lazy dog"}}, 1, 100, 50, 1000);
    layer.on_write_fields("doc2", 1,
        {{"title", "lazy cat"}, {"body", "quick fox"}}, 1, 200, 50, 1001);

    // 普通词袋搜索（默认字段）应命中两文档（quick 各在某字段）。
    auto r = layer.search_text("quick", 10);
    ASSERT_TRUE(r.has_value());
    EXPECT_EQ(r->size(), 2u);

    // 短语（默认字段 catch-all）："quick brown" 来自 doc1 的 title。
    auto rp = layer.search_phrase("quick brown", 10);
    ASSERT_TRUE(rp.has_value());
    ASSERT_EQ(rp->size(), 1u);
    EXPECT_EQ(rp->at(0).key, "doc1");

    // 字段限定仍精确：title:quick 只命中 doc1。
    auto rf = layer.search_fields("title:quick", 10);
    ASSERT_TRUE(rf.has_value());
    ASSERT_EQ(rf->size(), 1u);
    EXPECT_EQ(rf->at(0).key, "doc1");
}

// S8.6：跨字段查询 + boost 影响排序。
TEST(SearchLayer, MultiFieldBoostRanking) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);
    layer.on_write_fields("doc1", 0, {{"title", "x"}, {"body", "apple"}}, 1, 100, 50, 1000);
    layer.on_write_fields("doc2", 1, {{"title", "apple"}, {"body", "y"}}, 1, 200, 50, 1001);

    // title:apple^5 body:apple：doc2(title 命中×5) 应排在 doc1(body 命中×1) 前。
    auto r = layer.search_fields("title:apple^5 body:apple", 10);
    ASSERT_TRUE(r.has_value());
    ASSERT_EQ(r->size(), 2u);
    EXPECT_EQ(r->at(0).key, "doc2");
    EXPECT_GT(r->at(0).score, r->at(1).score);
}

// S8.6：on_write_fields 后 on_delete 清掉所有字段。
TEST(SearchLayer, MultiFieldDelete) {
    SearchLayerConfig config{
        .analyzer_config = bitcask::text::AnalyzerConfig{
            .type = bitcask::text::AnalyzerType::Whitespace},
        .bm25_params = bitcask::bm25::Bm25Params{1.2F, 0.75F}
    };
    SearchLayer layer(config);
    layer.on_write_fields("doc1", 0, {{"title", "apple"}, {"body", "banana"}}, 1, 100, 50, 1000);
    ASSERT_EQ(layer.search_fields("title:apple", 10)->size(), 1u);

    layer.on_delete("doc1", 1);
    EXPECT_TRUE(layer.search_fields("title:apple", 10)->empty());
    EXPECT_TRUE(layer.search_fields("body:banana", 10)->empty());
}

// S8.8：explain() 的分项总分应等于 search() 返回的实际 BM25 分数（同一公式）。
TEST(SearchLayer, ExplainMatchesSearchScore) {
    auto config = default_config();
    SearchLayer layer(config);
    layer.on_write("doc1", 0, "hello world foo", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hello hello bar baz", 1, 200, 50, 1001);

    auto results = layer.search_text("hello world", 10);
    ASSERT_TRUE(results.has_value());
    ASSERT_FALSE(results->empty());

    for (auto& hit : *results) {
        auto exp = layer.explain("hello world", hit.key);
        ASSERT_TRUE(exp.has_value()) << "key=" << hit.key;
        // explain 的 total 应与 search 给出的 score 一致（同一评分公式）。
        EXPECT_NEAR(exp->total, hit.score, 1e-4) << "key=" << hit.key;
        // 至少有一个 term 有非零贡献（hello 命中两篇）。
        bool any_contrib = false;
        for (auto& ts : exp->terms) if (ts.contribution > 0.0F) any_contrib = true;
        EXPECT_TRUE(any_contrib);
    }
}

// explain 对不存在的 key 返回 nullopt。
TEST(SearchLayer, ExplainMissingKey) {
    auto config = default_config();
    SearchLayer layer(config);
    layer.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    EXPECT_FALSE(layer.explain("hello", "nonexistent").has_value());
}

// S8.5：查询时覆盖 k1/b 应改变 BM25 分数（验证 params_override 真正生效）。
TEST(SearchLayer, QueryTimeBm25ParamsOverride) {
    auto config = default_config();
    SearchLayer layer(config);
    // 两篇文档 doc_len 不同，b 参数（长度归一化）会影响其相对分数。
    layer.on_write("doc1", 0, "hello hello hello", 1, 100, 50, 1000);
    layer.on_write("doc2", 1, "hello world foo bar baz qux quux corge", 1, 200, 50, 1001);

    auto def = layer.search_text("hello", 10);
    ASSERT_TRUE(def.has_value());
    ASSERT_FALSE(def->empty());
    double def_top_score = def->at(0).score;

    // b=0 关闭长度归一化，分数应与默认（b=0.75）不同。
    bitcask::bm25::Bm25Params p{1.2F, 0.0F};
    auto ovr = layer.search_text("hello", 10, &p);
    ASSERT_TRUE(ovr.has_value());
    ASSERT_FALSE(ovr->empty());
    double ovr_top_score = ovr->at(0).score;

    EXPECT_NE(def_top_score, ovr_top_score)
        << "override b=0 should change score vs default b=0.75";
}

TEST(SearchLayer, CheckpointRoundTrip) {
    auto config = default_config();
    SearchLayer layer1(config);

    layer1.on_write("doc1", 0, "hello world", 1, 100, 50, 1000);
    layer1.on_write("doc2", 1, "foo bar", 1, 200, 40, 1001);

    auto ckpt_path = std::filesystem::temp_directory_path() / "bitcask_ckpt_roundtrip.bin";
    std::filesystem::remove(ckpt_path);
    std::filesystem::remove(std::string(ckpt_path.string()) + ".prev");

    ASSERT_TRUE(layer1.save_search_ckpt(ckpt_path.string(), 2));

    SearchLayer layer2(config);
    auto result = layer2.load_search_ckpt(ckpt_path.string());
    ASSERT_TRUE(result.loaded);
    ASSERT_TRUE(result.all_segments_ok);

    auto search_hello = layer2.search_text("hello", 10);
    ASSERT_TRUE(search_hello.has_value());
    ASSERT_EQ(search_hello->size(), 1u);
    EXPECT_EQ(search_hello->at(0).key, "doc1");

    auto search_foo = layer2.search_text("foo", 10);
    ASSERT_TRUE(search_foo.has_value());
    ASSERT_EQ(search_foo->size(), 1u);
    EXPECT_EQ(search_foo->at(0).key, "doc2");

    std::filesystem::remove(ckpt_path);
    std::filesystem::remove(std::string(ckpt_path.string()) + ".prev");
}

// CRC 段隔离：search.ckpt 中某段 CRC 失败不应影响其他段的加载。
// 写入 3 篇文档 → 保存 → 位翻转中部（破坏 payload）→ 加载后
// all_segments_ok=false，但结构本身仍可解析（loaded=true）。
TEST(SearchLayer, CheckpointCrcCorruptionDetected) {
    auto config = default_config();
    SearchLayer layer1(config);
    layer1.on_write("a", 0, "alpha beta", 1, 0, 50, 1000);
    layer1.on_write("b", 1, "gamma delta", 1, 100, 50, 1001);
    layer1.on_write("c", 2, "epsilon zeta", 1, 200, 50, 1002);

    auto path = std::filesystem::temp_directory_path() / "bitcask_crc_test.ckpt";
    std::filesystem::remove(path);
    std::filesystem::remove(std::string(path.string()) + ".prev");
    ASSERT_TRUE(layer1.save_search_ckpt(path.string(), 3));
    ASSERT_TRUE(std::filesystem::exists(path));

    {
        std::FILE* f = std::fopen(path.string().c_str(), "rb+");
        ASSERT_NE(f, nullptr);
        std::fseek(f, 0, SEEK_END);
        const long mid = std::ftell(f) / 2;
        std::fseek(f, mid, SEEK_SET);
        int ch = std::fgetc(f);
        std::fseek(f, mid, SEEK_SET);
        std::fputc(ch ^ 0xFF, f);
        std::fclose(f);
    }

    SearchLayer layer2(config);
    auto result = layer2.load_search_ckpt(path.string());
    EXPECT_TRUE(result.loaded);
    EXPECT_FALSE(result.all_segments_ok);

    std::filesystem::remove(path);
    std::filesystem::remove(std::string(path.string()) + ".prev");
}

// .prev 代际回退：第一次保存正常 search.ckpt；第二次保存时刻意损坏
// （截断为一半）→ load 应回退到 .prev 并恢复健康状态。
TEST(SearchLayer, CheckpointPrevFallback) {
    auto config = default_config();
    SearchLayer layer1(config);
    layer1.on_write("k1", 0, "hello world", 1, 0, 50, 1000);
    layer1.on_write("k2", 1, "foo bar baz", 1, 100, 50, 1001);
    layer1.on_write("k3", 2, "test data here", 1, 200, 50, 1002);

    auto path = std::filesystem::temp_directory_path() / "bitcask_prev_test.ckpt";
    auto prev = std::filesystem::path(std::string(path.string()) + ".prev");
    std::filesystem::remove(path);
    std::filesystem::remove(prev);

    ASSERT_TRUE(layer1.save_search_ckpt(path.string(), 3));
    ASSERT_TRUE(std::filesystem::exists(path));
    ASSERT_FALSE(std::filesystem::exists(prev));

    SearchLayer layer_more(config);
    layer_more.on_write("k4", 3, "extra doc", 1, 300, 50, 1003);
    layer_more.on_write("k5", 4, "another doc", 1, 400, 50, 1004);
    ASSERT_TRUE(layer_more.save_search_ckpt(path.string(), 5));
    ASSERT_TRUE(std::filesystem::exists(prev))
        << ".prev should exist after second save";

    // 损坏当前 search.ckpt → load 应回退到 .prev。
    std::filesystem::resize_file(path, std::filesystem::file_size(path) / 2);

    SearchLayer layer2(config);
    auto result = layer2.load_search_ckpt(path.string());
    EXPECT_TRUE(result.loaded) << "should fall back to .prev";
    EXPECT_TRUE(result.all_segments_ok) << ".prev should be healthy";
    EXPECT_EQ(result.watermark, 3u) << ".prev has watermark from first save";

    // k1/k2/k3 在 .prev 中；k4/k5 不在（需要 fold 回放）。
    auto sr = layer2.search_text("hello", 10);
    ASSERT_TRUE(sr.has_value());
    ASSERT_EQ(sr->size(), 1u);
    EXPECT_EQ(sr->at(0).key, "k1");

    std::filesystem::remove(path);
    std::filesystem::remove(prev);
}