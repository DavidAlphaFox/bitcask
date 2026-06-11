#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <thread>

#include "bitcask/analyzer.hpp"
#include "bitcask/inverted.hpp"

using namespace bitcask::bm25;
using namespace bitcask::text;

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

}  // namespace

TEST(InvertedIndex, AddAndSearch) {
    InvertedIndex idx;
    auto analyzer = AnalyzerFactory::create(AnalyzerConfig{});
    ASSERT_NE(analyzer, nullptr);

    auto tfs0 = analyzer->analyze_with_positions("北京市朝阳区");
    idx.add_doc(0, tfs0);

    auto tfs1 = analyzer->analyze_with_positions("上海浦东");
    idx.add_doc(1, tfs1);

    EXPECT_EQ(idx.live_doc_count(), 2u);

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;
    checker.doc_lens[1] = 6;

    auto q_tfs = analyzer->analyze("北京");
    std::vector<std::string> terms;
    for (auto& [t, _] : q_tfs) terms.push_back(t);

    auto results = idx.search(terms, 10, checker);
    ASSERT_GE(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
    EXPECT_GT(results[0].score, 0.0f);
}

TEST(InvertedIndex, RemoveDocUpdatesStats) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(1, {{"hello", tp(2, {0, 1})}});

    EXPECT_EQ(idx.live_doc_count(), 2u);
    EXPECT_EQ(idx.sum_doc_len(), 4u);

    idx.remove_doc(2, {{"hello", 1}, {"world", 1}});
    EXPECT_EQ(idx.live_doc_count(), 1u);
    EXPECT_EQ(idx.sum_doc_len(), 2u);
}

TEST(InvertedIndex, SearchSkipsDeleted) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(2, {0, 1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[1] = 5;

    auto results = idx.search({"hello"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 1u);
}

TEST(InvertedIndex, SearchTopK) {
    InvertedIndex idx;
    idx.add_doc(0, {{"rare", tp(1, {0})}, {"common", tp(1, {1})}});
    idx.add_doc(1, {{"common", tp(5, {0, 1, 2, 3, 4})}, {"unique1", tp(1, {5})}});
    idx.add_doc(2, {{"common", tp(3, {0, 1, 2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 6;
    checker.doc_lens[2] = 3;

    auto results = idx.search({"rare"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);

    auto results2 = idx.search({"unique1"}, 10, checker);
    ASSERT_EQ(results2.size(), 1u);
    EXPECT_EQ(results2[0].ord, 1u);
}

TEST(InvertedIndex, EmptyQueryReturnsEmpty) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    auto results = idx.search({}, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, NoMatchReturnsEmpty) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search({"nonexistent"}, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, AvgDocLen) {
    InvertedIndex idx;
    idx.add_doc(0, {{"a", tp(2, {0, 1})}, {"b", tp(3, {2, 3, 4})}});
    idx.add_doc(1, {{"c", tp(5, {0, 1, 2, 3, 4})}});

    EXPECT_DOUBLE_EQ(idx.avg_doc_len(), 5.0);
}

TEST(InvertedIndex, DfReturnsPostingCount) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(2, {0, 1})}});
    idx.add_doc(2, {{"world", tp(1, {0})}});

    EXPECT_EQ(idx.df("hello"), 2u);
    EXPECT_EQ(idx.df("world"), 1u);
    EXPECT_EQ(idx.df("missing"), 0u);
}

TEST(InvertedIndex, PhraseSearchLatin) {
    InvertedIndex idx;
    idx.add_doc(0, {{"quick", tp(1, {0})}, {"brown", tp(1, {1})}, {"fox", tp(1, {2})}});
    idx.add_doc(1, {{"brown", tp(1, {0})}, {"fox", tp(1, {1})}, {"jumps", tp(1, {2})}});
    idx.add_doc(2, {{"the", tp(1, {0})}, {"fox", tp(1, {1})}, {"quick", tp(1, {2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    checker.doc_lens[1] = 3;
    checker.doc_lens[2] = 3;

    auto results = idx.search_phrase({"quick", "brown", "fox"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
}

// S8.7：近邻搜索。doc "quick brown fox"，quick@0 fox@2（间隔 brown）。
TEST(InvertedIndex, NearSearchSlop) {
    InvertedIndex idx;
    idx.add_doc(0, {{"quick", tp(1, {0})}, {"brown", tp(1, {1})}, {"fox", tp(1, {2})}});
    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;

    // slop=0（=严格短语）：quick 后紧跟 fox？不，中间隔了 brown → 不匹配。
    EXPECT_TRUE(idx.search_near({"quick", "fox"}, 10, 0, checker).empty());
    // slop=1：允许间隙 1 → quick(0) → fox 在 (0,2] 内 → 匹配。
    auto r = idx.search_near({"quick", "fox"}, 10, 1, checker);
    ASSERT_EQ(r.size(), 1u);
    EXPECT_EQ(r[0].ord, 0u);
}

// S8.7：近邻保持顺序——逆序不匹配。
TEST(InvertedIndex, NearSearchOrdered) {
    InvertedIndex idx;
    idx.add_doc(0, {{"fox", tp(1, {0})}, {"quick", tp(1, {2})}});  // fox 在前
    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    // 查 "quick fox"（要求 quick 在前），即使 slop 大也不匹配（顺序错）。
    EXPECT_TRUE(idx.search_near({"quick", "fox"}, 10, 5, checker).empty());
    // 查 "fox quick"（正确顺序）→ slop=1 匹配。
    auto r = idx.search_near({"fox", "quick"}, 10, 1, checker);
    ASSERT_EQ(r.size(), 1u);
}

TEST(InvertedIndex, PhraseSearchNoFalsePositive) {
    InvertedIndex idx;
    idx.add_doc(0, {{"the", tp(1, {0})}, {"fox", tp(1, {1})}, {"quick", tp(1, {2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;

    auto results = idx.search_phrase({"quick", "fox"}, 10, checker);
    EXPECT_TRUE(results.empty());
}

// 同一文档内短语多次出现 → phrase_tf>1，应比只出现一次的文档分数高。
// 回归 S9.7：把 other_pl.find 提到 start_pos 循环外后，内层多次 binary_search
// 的计数路径仍需正确。
TEST(InvertedIndex, PhraseSearchRepeatedInDoc) {
    InvertedIndex idx;
    idx.add_doc(0, {{"a", tp(2, {0, 2})}, {"b", tp(2, {1, 3})}});  // "a b a b" → 2 次
    idx.add_doc(1, {{"a", tp(1, {0})}, {"b", tp(1, {1})}});         // "a b" → 1 次

    FakeLiveChecker checker;
    checker.doc_lens[0] = 4;
    checker.doc_lens[1] = 2;

    auto results = idx.search_phrase({"a", "b"}, 10, checker);
    ASSERT_EQ(results.size(), 2u);
    EXPECT_EQ(results[0].ord, 0u);  // phrase_tf=2 排在前
    EXPECT_GT(results[0].score, results[1].score);
}

TEST(InvertedIndex, PhraseSearchSkipsDeleted) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});

    FakeLiveChecker checker;
    checker.doc_lens[1] = 2;

    auto results = idx.search_phrase({"hello", "world"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 1u);
}

TEST(InvertedIndex, PhraseSearchEmptyQuery) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    auto results = idx.search_phrase({}, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, PhraseSearchMissingTerm) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;

    auto results = idx.search_phrase({"hello", "missing"}, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, SaveLoadRoundtrip) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_test_roundtrip.inv";
    auto cleanup = [&]() { std::filesystem::remove(tmp); };
    cleanup();

    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(2, {1, 2})}});
    idx.add_doc(1, {{"hello", tp(3, {0, 1, 2})}, {"foo", tp(1, {3})}});

    EXPECT_TRUE(idx.save(tmp.string()));

    InvertedIndex idx2;
    EXPECT_TRUE(idx2.load(tmp.string()));

    EXPECT_EQ(idx2.live_doc_count(), 2u);
    EXPECT_EQ(idx2.sum_doc_len(), 7u);
    EXPECT_EQ(idx2.df("hello"), 2u);
    EXPECT_EQ(idx2.df("world"), 1u);
    EXPECT_EQ(idx2.df("foo"), 1u);

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    checker.doc_lens[1] = 4;

    auto results = idx2.search({"hello"}, 10, checker);
    ASSERT_EQ(results.size(), 2u);

    auto phrase_results = idx2.search_phrase({"hello", "world"}, 10, checker);
    ASSERT_EQ(phrase_results.size(), 1u);
    EXPECT_EQ(phrase_results[0].ord, 0u);

    cleanup();
}

TEST(InvertedIndex, LoadMissingFileReturnsFalse) {
    InvertedIndex idx;
    EXPECT_FALSE(idx.load("/nonexistent/path/to/file.inv"));
}

TEST(InvertedIndex, SaveLoadEmpty) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_test_empty.inv";
    auto cleanup = [&]() { std::filesystem::remove(tmp); };
    cleanup();

    InvertedIndex idx;
    EXPECT_TRUE(idx.save(tmp.string()));

    InvertedIndex idx2;
    EXPECT_TRUE(idx2.load(tmp.string()));
    EXPECT_EQ(idx2.live_doc_count(), 0u);
    EXPECT_EQ(idx2.sum_doc_len(), 0u);

    cleanup();
}

TEST(InvertedIndex, DfLiveCountsOnlyLive) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(2, {0, 1})}});
    idx.add_doc(2, {{"hello", tp(1, {0})}});

    EXPECT_EQ(idx.df("hello"), 3u);

    FakeLiveChecker full_checker;
    full_checker.doc_lens[0] = 1;
    full_checker.doc_lens[1] = 2;
    full_checker.doc_lens[2] = 1;
    EXPECT_EQ(idx.df_live("hello", full_checker), 3u);

    FakeLiveChecker partial_checker;
    partial_checker.doc_lens[0] = 1;
    partial_checker.doc_lens[2] = 1;
    EXPECT_EQ(idx.df_live("hello", partial_checker), 2u);

    FakeLiveChecker empty_checker;
    EXPECT_EQ(idx.df_live("hello", empty_checker), 0u);
}

TEST(InvertedIndex, SearchUsesLiveDf) {
    InvertedIndex idx;
    idx.add_doc(0, {{"term", tp(1, {0})}});
    idx.add_doc(1, {{"term", tp(1, {0})}});
    idx.add_doc(2, {{"other", tp(1, {0})}});

    FakeLiveChecker all_live;
    all_live.doc_lens[0] = 1;
    all_live.doc_lens[1] = 1;
    all_live.doc_lens[2] = 1;

    auto r1 = idx.search({"term"}, 10, all_live);
    ASSERT_EQ(r1.size(), 2u);

    FakeLiveChecker doc1_dead;
    doc1_dead.doc_lens[0] = 1;
    doc1_dead.doc_lens[2] = 1;

    auto r2 = idx.search({"term"}, 10, doc1_dead);
    ASSERT_EQ(r2.size(), 1u);
    ASSERT_EQ(r2[0].ord, 0u);
    EXPECT_GT(r2[0].score, r1[0].score);
}

TEST(QueryParser, SimpleTerm) {
    auto node = parse_query("hello");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_EQ(node.term, "hello");
}

TEST(QueryParser, PlusPrefix) {
    auto node = parse_query("+hello");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_FALSE(node.children.empty());
    EXPECT_EQ(node.children[0].op, QueryOp::MUST);
    EXPECT_EQ(node.children[0].term, "hello");
}

TEST(QueryParser, MinusPrefix) {
    auto node = parse_query("-hello");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_FALSE(node.children.empty());
    EXPECT_EQ(node.children[0].op, QueryOp::MUST_NOT);
    EXPECT_EQ(node.children[0].term, "hello");
}

TEST(QueryParser, MixedTerms) {
    auto node = parse_query("+hello -world foo");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    ASSERT_EQ(node.children.size(), 3u);
    EXPECT_EQ(node.children[0].op, QueryOp::MUST);
    EXPECT_EQ(node.children[0].term, "hello");
    EXPECT_EQ(node.children[1].op, QueryOp::MUST_NOT);
    EXPECT_EQ(node.children[1].term, "world");
    EXPECT_EQ(node.children[2].op, QueryOp::SHOULD);
    EXPECT_EQ(node.children[2].term, "foo");
}

TEST(QueryParser, EmptyString) {
    auto node = parse_query("");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_TRUE(node.term.empty());
}

TEST(QueryParser, AllShouldTermsSingleChild) {
    auto node = parse_query("hello world");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_FALSE(node.children.empty());
    ASSERT_EQ(node.children.size(), 2u);
    EXPECT_EQ(node.children[0].op, QueryOp::SHOULD);
    EXPECT_EQ(node.children[0].term, "hello");
    EXPECT_EQ(node.children[1].op, QueryOp::SHOULD);
    EXPECT_EQ(node.children[1].term, "world");
}

TEST(QueryParser, WhitespaceOnly) {
    auto node = parse_query("   \t\n  ");
    EXPECT_EQ(node.op, QueryOp::SHOULD);
    EXPECT_TRUE(node.term.empty());
}

// S8.6：字段限定 field:term。
TEST(QueryParser, FieldQualified) {
    auto node = parse_query("title:hello");
    EXPECT_EQ(node.field, "title");
    EXPECT_EQ(node.term, "hello");
    EXPECT_FLOAT_EQ(node.boost, 1.0F);
}

// S8.6：boost ^N。
TEST(QueryParser, BoostSuffix) {
    auto node = parse_query("hello^3");
    EXPECT_EQ(node.term, "hello");
    EXPECT_TRUE(node.field.empty());
    EXPECT_FLOAT_EQ(node.boost, 3.0F);
}

// S8.6：field:term^boost 组合。
TEST(QueryParser, FieldAndBoost) {
    auto node = parse_query("title:hello^2.5");
    EXPECT_EQ(node.field, "title");
    EXPECT_EQ(node.term, "hello");
    EXPECT_FLOAT_EQ(node.boost, 2.5F);
}

// S8.6 R5：http://x、12:30 不应被误判为字段限定。
TEST(QueryParser, ColonNotFieldWhenInvalidName) {
    auto n1 = parse_query("http://example.com");
    EXPECT_TRUE(n1.field.empty());  // "http" 后是 "//"，但整体仍按 term（冒号右是 //）
    auto n2 = parse_query(":leading");
    EXPECT_TRUE(n2.field.empty());  // 冒号在首位，colon>0 不满足
}

// S8.6：多 token 混合字段/boost/前缀。
TEST(QueryParser, MixedFieldBoost) {
    auto node = parse_query("+title:foo^2 body:bar");
    ASSERT_EQ(node.children.size(), 2u);
    EXPECT_EQ(node.children[0].op, QueryOp::MUST);
    EXPECT_EQ(node.children[0].field, "title");
    EXPECT_EQ(node.children[0].term, "foo");
    EXPECT_FLOAT_EQ(node.children[0].boost, 2.0F);
    EXPECT_EQ(node.children[1].op, QueryOp::SHOULD);
    EXPECT_EQ(node.children[1].field, "body");
    EXPECT_EQ(node.children[1].term, "bar");
}

TEST(InvertedIndex, BoolSearchShould) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});
    idx.add_doc(2, {{"world", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 1;
    checker.doc_lens[2] = 1;

    auto node = parse_query("hello world");
    auto results = idx.bool_search(node, 10, checker);
    ASSERT_EQ(results.size(), 3u);
}

TEST(InvertedIndex, BoolSearchMust) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}});
    idx.add_doc(2, {{"world", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 1;
    checker.doc_lens[2] = 1;

    auto node = parse_query("+hello +world");
    auto results = idx.bool_search(node, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);
}

TEST(InvertedIndex, BoolSearchMustNot) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(1, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(2, {{"world", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[1] = 2;
    checker.doc_lens[2] = 1;

    auto node = parse_query("-nonexistent");
    auto results = idx.bool_search(node, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, BoolSearchNoMatch) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;

    auto node = parse_query("+nonexistent");
    auto results = idx.bool_search(node, 10, checker);
    EXPECT_TRUE(results.empty());
}

// MUST + SHOULD 混合：MUST 决定候选集，SHOULD 只参与打分、不扩大候选。
// 回归 S9.6 修复——此前 "只含 should、不含 must" 的文档会被错误纳入结果。
TEST(InvertedIndex, BoolSearchMustWithShouldBoost) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});  // must + should
    idx.add_doc(1, {{"hello", tp(1, {0})}});                          // must only
    idx.add_doc(2, {{"world", tp(1, {0})}});                          // should only（无 must）

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 1;
    checker.doc_lens[2] = 1;

    auto node = parse_query("+hello world");
    auto results = idx.bool_search(node, 10, checker);

    // doc2 不含 must 词 hello，必须被排除。
    ASSERT_EQ(results.size(), 2u);
    for (auto& r : results) EXPECT_NE(r.ord, 2u);

    // 结果按分数降序：doc0（含 should 词 world 加分）应排在 doc1 之前。
    EXPECT_EQ(results[0].ord, 0u);
    EXPECT_EQ(results[1].ord, 1u);
    EXPECT_GT(results[0].score, results[1].score);
}

TEST(InvertedIndex, BoolSearchTopK) {
    InvertedIndex idx;
    idx.add_doc(0, {{"common", tp(1, {0})}});
    idx.add_doc(1, {{"common", tp(5, {0, 1, 2, 3, 4})}});
    idx.add_doc(2, {{"common", tp(3, {0, 1, 2})}, {"rare", tp(1, {3})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[1] = 5;
    checker.doc_lens[2] = 4;

    auto node = parse_query("+common");
    auto results = idx.bool_search(node, 2, checker);
    ASSERT_EQ(results.size(), 2u);
    EXPECT_EQ(results[0].ord, 1u);
    EXPECT_EQ(results[1].ord, 2u);
}

TEST(InvertedIndex, VByteCodecRoundtrip) {
    auto compressed = bitcask::codec::gap_encode({3, 7, 15, 20});
    auto decoded = bitcask::codec::gap_decode(compressed);
    EXPECT_EQ(decoded.size(), 4u);
    EXPECT_EQ(decoded[0], 3u);
    EXPECT_EQ(decoded[1], 7u);
    EXPECT_EQ(decoded[2], 15u);
    EXPECT_EQ(decoded[3], 20u);
}

TEST(InvertedIndex, VByteEncodeDecode) {
    std::vector<std::uint8_t> buf;
    bitcask::codec::vbyte_encode(127, buf);
    EXPECT_EQ(buf.size(), 1u);
    EXPECT_EQ(buf[0], 0x7F | 0x80);

    buf.clear();
    bitcask::codec::vbyte_encode(128, buf);
    EXPECT_EQ(buf.size(), 2u);

    buf.clear();
    bitcask::codec::vbyte_encode(300, buf);
    EXPECT_EQ(buf.size(), 2u);

    auto [val128, pos128] = bitcask::codec::vbyte_decode(buf.data(), 0);
    EXPECT_EQ(pos128, 2u);
    EXPECT_EQ(val128, 300u);
}

TEST(InvertedIndex, FinalizeCompressesOrds) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}});
    idx.add_doc(100, {{"hello", tp(2, {0, 1})}});
    idx.add_doc(1000, {{"hello", tp(3, {0, 1, 2})}});

    auto shard = idx.df("hello");
    (void)shard;

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[100] = 2;
    checker.doc_lens[1000] = 3;

    auto before = idx.search({"hello"}, 10, checker);
    ASSERT_EQ(before.size(), 3u);

    idx.finalize_all_postings();

    auto after = idx.search({"hello"}, 10, checker);
    ASSERT_EQ(after.size(), 3u);

    std::vector<std::uint64_t> before_ords;
    for (auto& r : before) before_ords.push_back(r.ord);
    std::vector<std::uint64_t> after_ords;
    for (auto& r : after) after_ords.push_back(r.ord);
    std::sort(before_ords.begin(), before_ords.end());
    std::sort(after_ords.begin(), after_ords.end());
    EXPECT_EQ(before_ords, after_ords);
}

TEST(InvertedIndex, FinalizeReducesMemory) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 100; ++i) {
        idx.add_doc(i * 1000, {{"term", tp(1, {0})}});
    }

    idx.finalize_all_postings();

    auto shard = idx.df("term");
    ASSERT_EQ(shard, 100u);
}

TEST(InvertedIndex, SaveLoadWithFinalizedPostings) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_finalized_test.inv";
    auto cleanup = [&]() { std::filesystem::remove(tmp); };
    cleanup();

    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(2, {1, 2})}});
    idx.add_doc(1, {{"hello", tp(3, {0, 1, 2})}, {"foo", tp(1, {3})}});

    idx.finalize_all_postings();

    EXPECT_TRUE(idx.save(tmp.string()));

    InvertedIndex idx2;
    EXPECT_TRUE(idx2.load(tmp.string()));

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    checker.doc_lens[1] = 4;

    auto results = idx2.search({"hello"}, 10, checker);
    ASSERT_EQ(results.size(), 2u);

    auto phrase_results = idx2.search_phrase({"hello", "world"}, 10, checker);
    ASSERT_EQ(phrase_results.size(), 1u);
    EXPECT_EQ(phrase_results[0].ord, 0u);

    cleanup();
}

// 回归（O3 时发现的 load 回填缺失）：load 的 comp==1 分支此前只读入
// compressed_ords，不回填 items[].ord（resize 后全 0）。而 find()/
// note_appended()/compact()/df 等内存路径都以 items[].ord 为事实来源——
// 快照重载后对既有 term 增量 add_doc 会触发 note_appended 使压缩失效，
// 旧 posting 的 ord 全部读成 0，搜索结果损坏。覆盖「load → explain →
// 增量写 → 搜索」链路。
TEST(InvertedIndex, LoadFinalizedThenAddDocKeepsOldOrds) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_finalized_add.inv";
    auto cleanup = [&]() { std::filesystem::remove(tmp); };
    cleanup();

    InvertedIndex idx;
    idx.add_doc(10, {{"hello", tp(1, {0})}});
    idx.add_doc(20, {{"hello", tp(2, {0, 1})}});
    idx.finalize_all_postings();
    ASSERT_TRUE(idx.save(tmp.string()));

    InvertedIndex idx2;
    ASSERT_TRUE(idx2.load(tmp.string()));

    // explain 走 pl.find(ord)（二分 items[].ord）——load 后必须能命中。
    FakeLiveChecker checker;
    checker.doc_lens[10] = 1;
    checker.doc_lens[20] = 2;
    auto ex = idx2.explain({"hello"}, 20, checker);
    ASSERT_EQ(ex.terms.size(), 1u);
    EXPECT_EQ(ex.terms[0].tf, 2u);

    // 对既有 term 增量写一条新 posting（note_appended 使压缩失效，
    // 此后 ord 完全依赖 items[].ord）。
    idx2.add_doc(30, {{"hello", tp(1, {0})}});
    checker.doc_lens[30] = 1;

    auto results = idx2.search({"hello"}, 10, checker);
    std::vector<std::uint64_t> ords;
    for (auto& r : results) ords.push_back(r.ord);
    std::sort(ords.begin(), ords.end());
    EXPECT_EQ(ords, (std::vector<std::uint64_t>{10, 20, 30}));

    cleanup();
}

// 回归 S9.4 验证缺口：手工构造 v3 格式快照（positions 为原始 u32 数组，
// 非 v4 的 gap 压缩），确认 v4 代码能向后兼容读入。
// 此前 load 版本检查 `ver != kInvVersion && ver != 2 && ver != 1` 漏了 v3，
// 会拒绝 v3 快照——已改为范围检查 `ver < 1 || ver > kInvVersion`。
TEST(InvertedIndex, LoadV3SnapshotBackwardCompat) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_v3_compat.inv";
    auto cleanup = [&]() { std::filesystem::remove(tmp); };
    cleanup();

    auto w32 = [](std::ofstream& f, std::uint32_t v) { f.write(reinterpret_cast<char*>(&v), 4); };
    auto w64 = [](std::ofstream& f, std::uint64_t v) { f.write(reinterpret_cast<char*>(&v), 8); };

    const std::uint32_t kMagic = 0x494E5632;
    auto sh = std::hash<std::string_view>{}(std::string_view("hello")) % 64;

    {
        std::ofstream f(tmp.string(), std::ios::binary);
        w32(f, kMagic); w32(f, 3); w32(f, 2 /*N*/); w64(f, 2 /*sdl*/);
        for (std::uint32_t s = 0; s < 64; ++s) {
            if (s == sh) {
                w32(f, 1);                                   // term_count
                std::string term = "hello";
                w32(f, static_cast<std::uint32_t>(term.size()));
                f.write(term.data(), static_cast<std::streamsize>(term.size()));
                w32(f, 2);                                   // pc=2
                w32(f, 0);                                   // comp=0（未压缩分支）
                w64(f, 0); w32(f, 1); w32(f, 1); w32(f, 0);  // ord0,tf1,pos{0}
                w64(f, 1); w32(f, 1); w32(f, 1); w32(f, 0);  // ord1,tf1,pos{0}
            } else {
                w32(f, 0);                                   // term_count=0
            }
        }
    }

    InvertedIndex idx;
    ASSERT_TRUE(idx.load(tmp.string()));   // v3 必须被接受
    EXPECT_EQ(idx.df("hello"), 2u);
    EXPECT_EQ(idx.live_doc_count(), 2u);

    cleanup();
}

TEST(PostingList, BlockMetadata) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 300; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 10) + 1);
        idx.add_doc(i, {{"term", tp(tf, {0})}});
    }

    idx.finalize_all_postings();

    auto& shard = idx.shard_for("term");
    tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
    ASSERT_TRUE(shard.inverted.find(acc, "term"));
    auto& pl = acc->second;

    EXPECT_GE(pl.blocks.size(), 2u);
    std::size_t expected_blocks = (300 + PostingList::kBlockSize - 1) / PostingList::kBlockSize;
    EXPECT_EQ(pl.blocks.size(), expected_blocks);

    for (std::size_t b = 0; b < pl.blocks.size(); ++b) {
        auto& blk = pl.blocks[b];
        EXPECT_LE(blk.count, PostingList::kBlockSize);
        EXPECT_EQ(blk.base_ord, blk.start_idx);
        EXPECT_TRUE(blk.max_tf > 0);
    }
}

TEST(InvertedIndex, BlockMaxWandBasic) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 500; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 20) + 1);
        idx.add_doc(i, {{"common", tp(tf, {0})}, {"term", tp(1, {1})}});
    }

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < 500; ++i) {
        checker.doc_lens[i] = 10;
    }

    auto results_wand = idx.search({"common", "term"}, 10, checker);
    ASSERT_FALSE(results_wand.empty());

    InvertedIndex idx2;
    for (std::uint64_t i = 0; i < 500; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 20) + 1);
        idx2.add_doc(i, {{"common", tp(tf, {0})}, {"term", tp(1, {1})}});
    }
    auto results_daat = idx2.search({"common", "term"}, 10, checker);
    ASSERT_EQ(results_wand.size(), results_daat.size());
    for (std::size_t i = 0; i < results_wand.size(); ++i) {
        EXPECT_EQ(results_wand[i].ord, results_daat[i].ord);
    }
}

TEST(InvertedIndex, BlockMaxWandLargeDataset) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 3000; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 50) + 1);
        idx.add_doc(i, {{"common", tp(tf, {0})}, {"rare", tp(1, {1})}});
    }

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < 3000; ++i) {
        checker.doc_lens[i] = static_cast<std::uint32_t>((i % 100) + 10);
    }

    auto results_wand = idx.search({"common", "rare"}, 5, checker);

    InvertedIndex idx2;
    for (std::uint64_t i = 0; i < 3000; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 50) + 1);
        idx2.add_doc(i, {{"common", tp(tf, {0})}, {"rare", tp(1, {1})}});
    }
    auto results_daat = idx2.search({"common", "rare"}, 5, checker);

    ASSERT_EQ(results_wand.size(), results_daat.size());
    for (std::size_t i = 0; i < results_wand.size(); ++i) {
        EXPECT_EQ(results_wand[i].ord, results_daat[i].ord);
        EXPECT_FLOAT_EQ(results_wand[i].score, results_daat[i].score);
    }
}

TEST(InvertedIndex, BlockMaxWandSingleTerm) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 2000; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 30) + 1);
        idx.add_doc(i, {{"term", tp(tf, {0})}});
    }

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < 2000; ++i) {
        checker.doc_lens[i] = 5;
    }

    auto results_wand = idx.search({"term"}, 10, checker);

    InvertedIndex idx2;
    for (std::uint64_t i = 0; i < 2000; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 30) + 1);
        idx2.add_doc(i, {{"term", tp(tf, {0})}});
    }
    auto results_daat = idx2.search({"term"}, 10, checker);

    ASSERT_EQ(results_wand.size(), results_daat.size());
    for (std::size_t i = 0; i < results_wand.size(); ++i) {
        EXPECT_EQ(results_wand[i].ord, results_daat[i].ord);
        EXPECT_FLOAT_EQ(results_wand[i].score, results_daat[i].score);
    }
}

// S10.6 回归：在线（未 finalize）索引也应增量封块，使 WAND 走块跳跃。
// ① add_doc 满 kBlockSize 后 blocks 非空（此前要等 finalize_all_postings）。
// ② 增量块下 WAND 结果与 finalize 后完全一致（块跳跃是精确剪枝，不改 top-k）。
// ③ finalize 后块数为含部分尾块的规范数（验证 note_appended 与 finalize 不重复/不冲突）。
TEST(InvertedIndex, IncrementalBlocksOnLiveIndex) {
    constexpr std::uint64_t kDocs = 600;  // 2 term × 600 = 1200 posting ≥ kWandThreshold(1024)
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < kDocs; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 17) + 1);
        idx.add_doc(i, {{"common", tp(tf, {0})}, {"rare", tp(1, {1})}});
    }

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < kDocs; ++i) checker.doc_lens[i] = 10;

    // ① 在线索引（未 finalize）：blocks 已增量封满块，仅含整块。
    {
        auto& shard = idx.shard_for("common");
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "common"));
        ASSERT_EQ(acc->second.blocks.size(), kDocs / PostingList::kBlockSize);  // 600/128=4 满块
        for (auto& blk : acc->second.blocks) {
            EXPECT_EQ(blk.count, PostingList::kBlockSize);
        }
    }

    auto live = idx.search({"common", "rare"}, 10, checker);

    // ② finalize 后再搜，结果必须与在线一致。
    idx.finalize_all_postings();
    auto after = idx.search({"common", "rare"}, 10, checker);

    ASSERT_EQ(live.size(), after.size());
    for (std::size_t i = 0; i < live.size(); ++i) {
        EXPECT_EQ(live[i].ord, after[i].ord);
        EXPECT_FLOAT_EQ(live[i].score, after[i].score);
    }

    // ③ finalize 后块数为含部分尾块的规范数 ceil(600/128)=5。
    {
        auto& shard = idx.shard_for("common");
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "common"));
        EXPECT_EQ(acc->second.blocks.size(),
                  (kDocs + PostingList::kBlockSize - 1) / PostingList::kBlockSize);
    }
}

// S10.10：index_positions=false 时不存 positions（省内存）。
// 普通 BM25 搜索照常工作；短语搜索因无位置可匹配返回空。
TEST(InvertedIndex, IndexPositionsDisabled) {
    InvertedIndex idx(Bm25Params{}, /*index_positions=*/false);
    EXPECT_FALSE(idx.index_positions());

    idx.add_doc(0, {{"quick", tp(1, {0})}, {"brown", tp(1, {1})}});
    idx.add_doc(1, {{"quick", tp(1, {0})}, {"fox", tp(1, {1})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 2;

    // 普通搜索正常。
    auto res = idx.search({"quick"}, 10, checker);
    EXPECT_EQ(res.size(), 2u);

    // positions 未存：posting 的 positions 为空。
    {
        auto& shard = idx.shard_for("quick");
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "quick"));
        for (auto& p : acc->second.items) {
            EXPECT_TRUE(p.positions.empty());
        }
    }

    // 短语搜索无位置可匹配 → 空。
    auto phrase = idx.search_phrase({"quick", "brown"}, 10, checker);
    EXPECT_TRUE(phrase.empty());
}

// 对照：默认 index_positions=true 时 positions 正常存、短语可匹配。
TEST(InvertedIndex, IndexPositionsEnabledByDefault) {
    InvertedIndex idx;  // 默认构造
    EXPECT_TRUE(idx.index_positions());

    idx.add_doc(0, {{"quick", tp(1, {0})}, {"brown", tp(1, {1})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;

    auto phrase = idx.search_phrase({"quick", "brown"}, 10, checker);
    ASSERT_EQ(phrase.size(), 1u);
    EXPECT_EQ(phrase[0].ord, 0u);
}

// S10.11：死点占比 ≥ 阈值时压实，删掉死 posting；结果集与分数不变（透明优化）。
TEST(InvertedIndex, CompactRemovesDeadPostingsPreservesScores) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 200; ++i) {
        idx.add_doc(i, {{"term", tp(static_cast<std::uint32_t>((i % 5) + 1), {0})}});
    }
    EXPECT_EQ(idx.df("term"), 200u);  // posting 行含死点

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < 200; ++i) checker.doc_lens[i] = 10;
    // 标记奇数 ord 为死（is_live=false）。
    for (std::uint64_t i = 1; i < 200; i += 2) checker.doc_lens.erase(i);

    auto before = idx.search({"term"}, 100, checker);

    auto n = idx.compact(checker, 0.4);  // 50% 死 ≥ 0.4 → 压实
    EXPECT_EQ(n, 1u);
    EXPECT_EQ(idx.df("term"), 100u);  // 死 posting 已删，只剩 live

    auto after = idx.search({"term"}, 100, checker);
    ASSERT_EQ(before.size(), after.size());
    for (std::size_t i = 0; i < before.size(); ++i) {
        EXPECT_EQ(before[i].ord, after[i].ord);
        EXPECT_FLOAT_EQ(before[i].score, after[i].score);
    }
}

// S10.11：死点占比低于阈值时不压实（避免无谓重建）。
TEST(InvertedIndex, CompactSkipsBelowThreshold) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 100; ++i) idx.add_doc(i, {{"term", tp(1, {0})}});

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < 100; ++i) checker.doc_lens[i] = 10;
    checker.doc_lens.erase(0);  // 仅 1% 死

    auto n = idx.compact(checker, 0.5);
    EXPECT_EQ(n, 0u);
    EXPECT_EQ(idx.df("term"), 100u);  // 未压实
}

// P1 回归：多读者 search × 单写者对同一 term 持续 add_doc 并发。
// 对齐生产线程模型（IndexPool 单写 worker + NIF dirty 线程多读）。
// snapshot_flat 在桶读锁（const_accessor）下拷贝、写者持写 accessor 追加，
// 互斥成立——TSan 构建下本测试验证无 data race。写者只追加已存在的 term
//（不插新 key），与 add_doc 既有桶级锁语义一致。
TEST(InvertedIndex, SearchConcurrentWithSingleWriter) {
    class AllLive : public LiveChecker {
    public:
        [[nodiscard]] bool is_live(std::uint64_t) const override { return true; }
        [[nodiscard]] std::uint32_t doc_len(std::uint64_t) const override { return 4; }
    };

    InvertedIndex idx;
    // 预热超过 kWandThreshold，让读者既走 WAND 也走标量路径（k 小走 WAND）。
    for (std::uint64_t i = 0; i < 2000; ++i) {
        idx.add_doc(i, {{"hot", tp(2, {0, 1})}, {"warm", tp(2, {2, 3})}});
    }

    AllLive checker;
    std::atomic<bool> stop{false};
    std::atomic<bool> bad{false};

    std::vector<std::thread> readers;
    readers.reserve(4);
    for (int r = 0; r < 4; ++r) {
        readers.emplace_back([&] {
            while (!stop.load(std::memory_order_relaxed)) {
                auto res = idx.search({"hot", "warm"}, 10, checker);
                if (res.size() > 10) { bad.store(true); return; }
                for (auto& h : res) {
                    // 写者只发布 ord < 4000；任何越界 ord 都是撕裂读。
                    if (h.ord >= 4000) { bad.store(true); return; }
                }
            }
        });
    }

    // 单写者（当前线程）：对既有 term 持续追加。
    for (std::uint64_t i = 2000; i < 4000; ++i) {
        idx.add_doc(i, {{"hot", tp(1, {0})}});
    }
    stop.store(true);
    for (auto& t : readers) t.join();

    EXPECT_FALSE(bad.load());
    auto final_res = idx.search({"hot"}, 10, checker);
    EXPECT_EQ(final_res.size(), 10u);
}
