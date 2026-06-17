#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <random>
#include <set>
#include <filesystem>
#include <fstream>
#include <thread>

#include "bitcask/analyzer.hpp"
#include "bitcask/inverted.hpp"
#include "test_support.hpp"

using namespace bitcask::bm25;
using namespace bitcask::text;

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

// P14e/S2:serialize/deserialize 到字节缓冲(供 search.ckpt 段),与 save/load
// 等价。直接测缓冲 round-trip 守护新 API。
TEST(InvertedIndex, SerializeDeserializeRoundtrip) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(2, {1, 2})}});
    idx.add_doc(1, {{"hello", tp(3, {0, 1, 2})}, {"foo", tp(1, {3})}});

    std::vector<std::byte> buf;
    idx.serialize(buf);
    EXPECT_FALSE(buf.empty());

    InvertedIndex idx2;
    ASSERT_TRUE(idx2.deserialize(buf));
    EXPECT_EQ(idx2.live_doc_count(), 2u);
    EXPECT_EQ(idx2.sum_doc_len(), 7u);
    EXPECT_EQ(idx2.df("hello"), 2u);
    EXPECT_EQ(idx2.df("foo"), 1u);

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    checker.doc_lens[1] = 4;
    auto results = idx2.search({"hello"}, 10, checker);
    EXPECT_EQ(results.size(), 2u);
    auto phrase = idx2.search_phrase({"hello", "world"}, 10, checker);
    ASSERT_EQ(phrase.size(), 1u);
    EXPECT_EQ(phrase[0].ord, 0u);

    // 截断缓冲 → 干净拒绝。
    InvertedIndex idx3;
    EXPECT_FALSE(idx3.deserialize(
        std::span<const std::byte>(buf.data(), buf.size() / 2)));
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

// ord > 2^32 的 bool_search MUST 交集（intersect_u64 Inoue 原生 u64 SIMD 路径）。
TEST(InvertedIndex, BoolSearchMustU64Fallback) {
    InvertedIndex idx;
    const std::uint64_t base = 5'000'000'000ULL;
    idx.add_doc(base + 0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
    idx.add_doc(base + 1, {{"hello", tp(1, {0})}});
    idx.add_doc(base + 2, {{"world", tp(1, {0})}});
    idx.add_doc(base + 3, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});

    FakeLiveChecker checker;
    checker.doc_lens[base + 0] = 2;
    checker.doc_lens[base + 1] = 1;
    checker.doc_lens[base + 2] = 1;
    checker.doc_lens[base + 3] = 2;

    auto node = parse_query("+hello +world");
    auto results = idx.bool_search(node, 10, checker);
    ASSERT_EQ(results.size(), 2u);  // hello AND world → base+0, base+3
    std::set<std::uint64_t> ords;
    for (auto& r : results) ords.insert(r.ord);
    EXPECT_TRUE(ords.count(base + 0));
    EXPECT_TRUE(ords.count(base + 3));
    EXPECT_FALSE(ords.count(base + 1));  // 只含 hello
    EXPECT_FALSE(ords.count(base + 2));  // 只含 world
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

// finalize_all_postings 不改变 search 结果（幂等、不损坏 items）。
TEST(InvertedIndex, FinalizePreservesSearchResults) {
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

// finalize_all_postings 后 df 不变（不丢/不增 posting）。
TEST(InvertedIndex, FinalizeKeepsDfStable) {
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

// 回归 S9.4 验证缺口：已删除——v6 不再兼容 v1..v5 旧快照（项目规则
// 「不考虑向后兼容性」），由外部迁移工具或直接重新索引处理。
//
// 此前（v5）的 LoadV3SnapshotBackwardCompat 测试手工构造 v3 格式
// 快照（positions 为原始 u32 数组，非 v4 的 gap 压缩），确认 v4/v5
// 代码能向后兼容读入。v6 load 严格校验 version==6，v3 会被拒；
// 此处不再保留该测试。

TEST(PostingList, BlockMetadata) {
    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 300; ++i) {
        std::uint32_t tf = static_cast<std::uint32_t>((i % 10) + 1);
        idx.add_doc(i, {{"term", tp(tf, {0})}});
    }

    idx.finalize_all_postings();

    auto& shard = idx.shard_for("term");
    InvertedIndex::PostingMap::const_accessor acc;
    ASSERT_TRUE(shard.inverted.find(acc, "term"));
    auto& pl = *acc->second;

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
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "common"));
        ASSERT_EQ(acc->second->blocks.size(), kDocs / PostingList::kBlockSize);  // 600/128=4 满块
        for (auto& blk : acc->second->blocks) {
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
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "common"));
        EXPECT_EQ(acc->second->blocks.size(),
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
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(shard.inverted.find(acc, "quick"));
        for (auto& p : acc->second->items) {
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

// P2-min：CoW 协议确定性验证。读者持 shared_ptr 引用期间（use_count>1），
// 写者对同 term 的 add_doc 必须克隆替换而非原地改——读者持有的对象冻结，
// 索引侧换上含新 posting 的新对象。无读者持引用时（use_count==1）原地改。
TEST(InvertedIndex, CowClonesWhenReaderHoldsReference) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hot", tp(1, {0})}});

    // 模拟 phrase 读者：取引用后释放桶锁。
    std::shared_ptr<const PostingList> held;
    {
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(idx.shard_for("hot").inverted.find(acc, "hot"));
        held = acc->second;
    }
    ASSERT_EQ(held->items.size(), 1u);

    // 写者追加同 term → CoW：held 冻结，索引换新对象。
    idx.add_doc(1, {{"hot", tp(1, {0})}});
    EXPECT_EQ(held->items.size(), 1u);  // 读者视图不变
    {
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(idx.shard_for("hot").inverted.find(acc, "hot"));
        EXPECT_EQ(acc->second->items.size(), 2u);   // 索引侧已更新
        EXPECT_NE(acc->second.get(), held.get());   // 确实是克隆出的新对象
    }

    // 读者释放后（use_count 回到 1）→ 原地改，不再克隆。
    held.reset();
    const PostingList* before;
    {
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(idx.shard_for("hot").inverted.find(acc, "hot"));
        before = acc->second.get();
    }
    idx.add_doc(2, {{"hot", tp(1, {0})}});
    {
        InvertedIndex::PostingMap::const_accessor acc;
        ASSERT_TRUE(idx.shard_for("hot").inverted.find(acc, "hot"));
        EXPECT_EQ(acc->second.get(), before);       // 同一对象（原地追加）
        EXPECT_EQ(acc->second->items.size(), 3u);
    }
}

// P2-min 回归：phrase 读者（零拷贝持引用）× 单写者同 term 追加并发。
// 读者持引用期间写者每次 add_doc 都触发 CoW；读者的快照自洽（短语命中数
// 不超过其取引用时刻的发布量）。TSan 构建下验证无 data race。
TEST(InvertedIndex, PhraseSearchConcurrentWithSingleWriter) {
    class AllLive : public LiveChecker {
    public:
        [[nodiscard]] bool is_live(std::uint64_t) const override { return true; }
        [[nodiscard]] std::uint32_t doc_len(std::uint64_t) const override { return 2; }
    };

    InvertedIndex idx;
    for (std::uint64_t i = 0; i < 1000; ++i) {
        idx.add_doc(i, {{"p0", tp(1, {0})}, {"p1", tp(1, {1})}});
    }

    AllLive checker;
    std::atomic<bool> stop{false};
    std::atomic<bool> bad{false};

    std::vector<std::thread> readers;
    readers.reserve(4);
    for (int r = 0; r < 4; ++r) {
        readers.emplace_back([&] {
            while (!stop.load(std::memory_order_relaxed)) {
                auto res = idx.search_phrase({"p0", "p1"}, 5, checker);
                if (res.size() > 5) { bad.store(true); return; }
                for (auto& h : res) {
                    if (h.ord >= 3000) { bad.store(true); return; }
                }
            }
        });
    }

    for (std::uint64_t i = 1000; i < 3000; ++i) {
        idx.add_doc(i, {{"p0", tp(1, {0})}, {"p1", tp(1, {1})}});
    }
    stop.store(true);
    for (auto& t : readers) t.join();

    EXPECT_FALSE(bad.load());
    auto final_res = idx.search_phrase({"p0", "p1"}, 5, checker);
    EXPECT_EQ(final_res.size(), 5u);
}

// =========================================================================
// intersect_u64（Inoue 块过滤 + u64 AVX2 / galloping / 标量）黑盒对拍
// =========================================================================

#include "bitcask/intersect.hpp"

namespace {
std::vector<std::uint64_t> ref_intersect(const std::vector<std::uint64_t>& a,
                                         const std::vector<std::uint64_t>& b) {
    std::vector<std::uint64_t> r;
    std::set_intersection(a.begin(), a.end(), b.begin(), b.end(),
                          std::back_inserter(r));
    return r;
}
std::vector<std::uint64_t> make_sorted_unique(std::uint64_t& seed, std::size_t n,
                                              std::uint64_t value_range,
                                              std::uint64_t base = 0) {
    auto next = [&seed] {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return seed >> 33;
    };
    std::vector<std::uint64_t> v(n);
    for (auto& x : v) x = base + static_cast<std::uint64_t>(next() % value_range);
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v;
}
}  // namespace

TEST(IntersectU64, AgreesWithSetIntersectionRandomized) {
    std::uint64_t seed = 7;
    std::vector<std::uint64_t> out;
    const std::size_t sizes[] = {0, 1, 3, 4, 5, 7, 8, 9, 15, 16, 17, 63, 64, 200, 777};
    for (auto na : sizes) {
        for (auto nb : sizes) {
            for (std::uint64_t range : {50ULL, 1000ULL, 1000000ULL}) {
                auto a = make_sorted_unique(seed, na, range);
                auto b = make_sorted_unique(seed, nb, range);
                intersect_u64(a, b, out);
                ASSERT_EQ(out, ref_intersect(a, b))
                    << "na=" << na << " nb=" << nb << " range=" << range;
            }
        }
    }
}

TEST(IntersectU64, HighValuesAcross232Boundary) {
    std::uint64_t seed = 42;
    std::vector<std::uint64_t> out;
    const std::uint64_t bases[] = {0ULL, 0xFFFFFF00ULL, 5'000'000'000ULL,
                                   0x7FFFFFFFFFFFFF00ULL};
    const std::size_t sizes[] = {0, 1, 3, 4, 5, 8, 9, 64, 200};
    for (auto base : bases) {
        for (auto na : sizes) {
            for (auto nb : sizes) {
                auto a = make_sorted_unique(seed, na, 1000, base);
                auto b = make_sorted_unique(seed, nb, 1000, base);
                intersect_u64(a, b, out);
                ASSERT_EQ(out, ref_intersect(a, b))
                    << "base=" << base << " na=" << na << " nb=" << nb;
            }
        }
    }
}

TEST(IntersectU64, Low32BitCollision) {
    std::vector<std::uint64_t> a, b, out;
    for (std::uint64_t k = 0; k < 64; ++k) a.push_back((1ULL << 32) | (k * 7));
    for (std::uint64_t k = 0; k < 64; ++k) b.push_back((2ULL << 32) | (k * 7));
    intersect_u64(a, b, out);
    EXPECT_TRUE(out.empty());
    intersect_u64(a, a, out);
    EXPECT_EQ(out, a);
}

TEST(IntersectU64, GallopingPathSkewed) {
    std::uint64_t seed = 99;
    std::vector<std::uint64_t> out;
    auto small_v = make_sorted_unique(seed, 20, 100000);
    auto large_v = make_sorted_unique(seed, 5000, 100000);
    intersect_u64(small_v, large_v, out);
    EXPECT_EQ(out, ref_intersect(small_v, large_v));
    intersect_u64(large_v, small_v, out);
    EXPECT_EQ(out, ref_intersect(small_v, large_v));
}

TEST(IntersectU64, FullAndNoOverlap) {
    std::vector<std::uint64_t> a, out;
    for (std::uint64_t i = 0; i < 1000; ++i) a.push_back(i * 2);
    intersect_u64(a, a, out);
    EXPECT_EQ(out, a);
    std::vector<std::uint64_t> b;
    for (std::uint64_t i = 0; i < 1000; ++i) b.push_back(i * 2 + 1);
    intersect_u64(a, b, out);
    EXPECT_TRUE(out.empty());
}

// ── K1:k-way 交集专项(run_must_intersect 从 pairwise 改 leapfrog)──────

// 三词 MUST:A=全部,B=偶数,C=3 的倍数 → 交集 = 6 的倍数。
TEST(InvertedIndex, BoolMustKwayThreeTerms) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < 100; ++d) {
        TermPositions m;
        m.emplace("aaa", tp(1, {0}));
        if (d % 2 == 0) m.emplace("bbb", tp(1, {1}));
        if (d % 3 == 0) m.emplace("ccc", tp(1, {2}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = 3;
    }

    auto node = parse_query("+aaa +bbb +ccc");
    auto results = idx.bool_search(node, 100, checker);
    ASSERT_EQ(results.size(), 17u);  // 0,6,...,96
    for (auto& r : results) {
        EXPECT_EQ(r.ord % 6, 0u) << r.ord;
    }
}

// 三词 MUST + 删除:交集内被删的文档必须被 liveness 全检排除。
TEST(InvertedIndex, BoolMustKwayDeletedExcluded) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < 60; ++d) {
        TermPositions m;
        m.emplace("aaa", tp(1, {0}));
        m.emplace("bbb", tp(1, {1}));
        if (d % 2 == 0) m.emplace("ccc", tp(1, {2}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = 3;
    }
    // 删掉交集(偶数)里的 0、6、12(FakeLiveChecker:不在 doc_lens 即死)。
    checker.doc_lens.erase(0);
    checker.doc_lens.erase(6);
    checker.doc_lens.erase(12);

    auto node = parse_query("+aaa +bbb +ccc");
    auto results = idx.bool_search(node, 100, checker);
    ASSERT_EQ(results.size(), 27u);  // 30 个偶数 - 3 个被删
    for (auto& r : results) {
        EXPECT_NE(r.ord, 0u);
        EXPECT_NE(r.ord, 6u);
        EXPECT_NE(r.ord, 12u);
    }
}

// 极不对称:冷词(5 docs)∩ 热词(5000 docs)——驱动游标走冷词,
// 热词侧全靠 galloping advance。
TEST(InvertedIndex, BoolMustKwayAsymmetric) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < 5000; ++d) {
        TermPositions m;
        m.emplace("hot", tp(1, {0}));
        if (d % 1000 == 7) m.emplace("rare", tp(1, {1}));  // 7,1007,...,4007
        idx.add_doc(d, m);
        checker.doc_lens[d] = 2;
    }

    auto node = parse_query("+hot +rare");
    auto results = idx.bool_search(node, 100, checker);
    ASSERT_EQ(results.size(), 5u);
    for (auto& r : results) {
        EXPECT_EQ(r.ord % 1000, 7u);
    }
}

// 随机对拍:4 词 MUST,与暴力参考集逐 ord 比对(固定种子可复现)。
TEST(InvertedIndex, BoolMustKwayRandomizedReference) {
    std::mt19937_64 rng(0x5EEDBA5E);
    InvertedIndex idx;
    FakeLiveChecker checker;
    const char* terms[4] = {"t0", "t1", "t2", "t3"};
    std::set<std::uint64_t> reference;

    for (std::uint64_t d = 0; d < 2000; ++d) {
        TermPositions m;
        bool in_all = true;
        for (auto* t : terms) {
            // 各词 60% 概率包含该文档 → 四词交集 ~13%。
            if (rng() % 100 < 60) {
                m.emplace(t, tp(1, {0}));
            } else {
                in_all = false;
            }
        }
        if (m.empty()) m.emplace("filler", tp(1, {0}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = 4;
        if (in_all) reference.insert(d);
    }
    ASSERT_GT(reference.size(), 50u);  // 种子固定,交集非平凡

    auto node = parse_query("+t0 +t1 +t2 +t3");
    auto results = idx.bool_search(node, 5000, checker);
    std::set<std::uint64_t> got;
    for (auto& r : results) got.insert(r.ord);
    EXPECT_EQ(got, reference);
}

// ── B1:must-only 合取 BMW 专项 ──────────────────────────────────────

// 无删除等价性:BMW(+a +b)与原路径(+a +b zzz——不存在的 should 词
// 强制走原路径且不影响分数)逐 ord/score 对比。tf 取变化值避免并列分。
TEST(InvertedIndex, BmwMatchesFallbackNoDeletions) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    std::mt19937_64 rng(0xB1B1);
    for (std::uint64_t d = 0; d < 3000; ++d) {
        TermPositions m;
        if (rng() % 100 < 70) {
            m.emplace("aaa", tp(1 + static_cast<std::uint32_t>(rng() % 7), {0}));
        }
        if (rng() % 100 < 50) {
            m.emplace("bbb", tp(1 + static_cast<std::uint32_t>(rng() % 5), {1}));
        }
        if (m.empty()) m.emplace("filler", tp(1, {0}));
        idx.add_doc(d, m);
        // v5 不变量:checker 的 doc_len 必须等于 add_doc 的 Σtf
        // (生产里 SearchLayer 同源保证;见 LiveChecker 文档)。
        std::uint32_t dl = 0;
        for (auto& [t, pr] : m) dl += pr.first;
        checker.doc_lens[d] = dl;
    }

    for (std::size_t k : {5UL, 37UL, 2000UL}) {
        auto bmw = idx.bool_search(parse_query("+aaa +bbb"), k, checker);
        auto ref = idx.bool_search(parse_query("+aaa +bbb zzz_nonexistent"),
                                   k, checker);
        ASSERT_EQ(bmw.size(), ref.size()) << "k=" << k;
        for (std::size_t i = 0; i < bmw.size(); ++i) {
            EXPECT_EQ(bmw[i].ord, ref[i].ord) << "k=" << k << " i=" << i;
            EXPECT_FLOAT_EQ(bmw[i].score, ref[i].score)
                << "k=" << k << " i=" << i;
        }
    }
}

// 有删除:死文档必须被排除(懒 live 检查),活文档成员集与参考一致
// (k 取满,只断言成员不断言排序——BMW 的 idf 基于 df,删除下与原路径
// 的 live_df idf 有意不同,见设计 §6)。
TEST(InvertedIndex, BmwDeletedDocsExcluded) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    std::set<std::uint64_t> expect;
    for (std::uint64_t d = 0; d < 1000; ++d) {
        TermPositions m;
        m.emplace("aaa", tp(1, {0}));
        if (d % 3 == 0) m.emplace("bbb", tp(2, {1}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = (d % 3 == 0) ? 3 : 1;  // = Σtf(v5 不变量)
        if (d % 3 == 0) expect.insert(d);
    }
    // 删掉交集里的每第 5 个(0,15,30,...)。
    for (std::uint64_t d = 0; d < 1000; d += 15) {
        checker.doc_lens.erase(d);
        expect.erase(d);
    }

    auto results = idx.bool_search(parse_query("+aaa +bbb"), 1000, checker);
    std::set<std::uint64_t> got;
    for (auto& r : results) got.insert(r.ord);
    EXPECT_EQ(got, expect);
}

// 剪枝正确性:高分文档藏在列表深处(后段块的高 tf),小 k 下 BMW 的块
// 跳跃不允许漏掉它们——与原路径 top-k 集逐一对比。
TEST(InvertedIndex, BmwHighScoreInLateBlocksNotPruned) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < 5000; ++d) {
        // 大部分 tf=1;每 997 个一个 tf=50 的"高分钉子",分散在各块。
        const std::uint32_t tf_a = (d % 997 == 0) ? 50 : 1;
        const std::uint32_t tf_b = (d % 991 == 0) ? 40 : 1;
        TermPositions m;
        m.emplace("aaa", tp(tf_a, {0}));
        m.emplace("bbb", tp(tf_b, {1}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = tf_a + tf_b;  // = Σtf(v5 不变量)
    }

    auto bmw = idx.bool_search(parse_query("+aaa +bbb"), 10, checker);
    auto ref = idx.bool_search(parse_query("+aaa +bbb zzz_nonexistent"),
                               10, checker);
    ASSERT_EQ(bmw.size(), ref.size());
    for (std::size_t i = 0; i < bmw.size(); ++i) {
        EXPECT_EQ(bmw[i].ord, ref[i].ord) << i;
        EXPECT_FLOAT_EQ(bmw[i].score, ref[i].score) << i;
    }
}

// v5 impacts:封块记录块内最小索引时 doc_len;save/load round-trip 保留。
TEST(InvertedIndex, V5BlockMinDlTrackedAndPersisted) {
    InvertedIndex idx;
    // 200 docs → alpha 列表 1 个满块(128)+ 尾巴。doc_len = Σtf 受控:
    // d<128 块内 dl ∈ {5,9}(min=5);其余 dl=7。
    for (std::uint64_t d = 0; d < 200; ++d) {
        TermPositions m;
        if (d < 128) {
            m.emplace("alpha", tp(2, {0}));
            m.emplace("pad", tp((d % 2 == 0) ? 3u : 7u, {1}));  // Σtf = 5 或 9
        } else {
            m.emplace("alpha", tp(3, {0}));
            m.emplace("pad", tp(4, {1}));                       // Σtf = 7
        }
        idx.add_doc(d, m);
    }

    auto tmp = std::filesystem::temp_directory_path() / "inv_v5_mindl.snap";
    std::filesystem::remove(tmp);
    ASSERT_TRUE(idx.save(tmp.string()));

    InvertedIndex idx2;
    ASSERT_TRUE(idx2.load(tmp.string()));

    // 经查询路径间接验证不可行(min_dl 不外露),直接检查快照重载后的
    // 块元数据:save 前 finalize 会重建块(满块+尾块)。
    // 通过再 save 一次比较字节一致性来确认 round-trip 无损。
    auto tmp2 = std::filesystem::temp_directory_path() / "inv_v5_mindl2.snap";
    std::filesystem::remove(tmp2);
    ASSERT_TRUE(idx2.save(tmp2.string()));

    std::ifstream f1(tmp, std::ios::binary), f2(tmp2, std::ios::binary);
    std::vector<char> b1((std::istreambuf_iterator<char>(f1)),
                         std::istreambuf_iterator<char>());
    std::vector<char> b2((std::istreambuf_iterator<char>(f2)),
                         std::istreambuf_iterator<char>());
    EXPECT_EQ(b1, b2);  // load→save 幂等 ⇒ min_dl 等块字段全数保留

    std::filesystem::remove(tmp);
    std::filesystem::remove(tmp2);
}

// A1:WAND 块跳跃修复(remaining_needed 死代码)后的安全网——
// 小 k(剪枝激进)的 top-k 必须与大 k(堆不满,零剪枝)的前缀一致。
// BM25 分数只取决于 (tf, dl) 离散对,随机取值会大量并列(首版测试
// 因此误报"丢结果"——实为并列层内的合法自由度);这里构造 (tf, dl)
// 与 d 双射使分数几乎唯一,并对仍可能的同分位放宽 ord 断言。
TEST(InvertedIndex, WandSkipTopKEqualsUnprunedPrefix) {
    InvertedIndex idx;
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < 4000; ++d) {
        const auto tf = 1 + static_cast<std::uint32_t>(d % 50);
        const auto pad = 1 + static_cast<std::uint32_t>(d / 50);
        TermPositions m;
        m.emplace("hot", tp(tf, {0}));
        m.emplace("pad", tp(pad, {1}));
        idx.add_doc(d, m);
        checker.doc_lens[d] = tf + pad;  // v5 不变量:= Σtf
    }

    // k=4000 → 堆永不满 → threshold 恒 0 → 块跳跃不触发 → 全量评分,
    // 其排序前缀即真值。
    auto full = idx.search({"hot"}, 4000, checker);
    ASSERT_EQ(full.size(), 4000u);

    for (std::size_t k : {1UL, 5UL, 10UL, 100UL}) {
        auto pruned = idx.search({"hot"}, k, checker);
        ASSERT_EQ(pruned.size(), k) << "k=" << k;
        for (std::size_t i = 0; i < k; ++i) {
            EXPECT_FLOAT_EQ(pruned[i].score, full[i].score)
                << "k=" << k << " i=" << i;
            // 同分层内成员可互换,只在该位分数唯一时断言 ord。
            const bool tie_above =
                i > 0 && full[i].score == full[i - 1].score;
            const bool tie_below =
                i + 1 < full.size() && full[i].score == full[i + 1].score;
            if (!tie_above && !tie_below) {
                EXPECT_EQ(pruned[i].ord, full[i].ord)
                    << "k=" << k << " i=" << i;
            }
        }
    }
}

// ===========================================================================
// V6.3.1：排序词典侧表懒重建回归
// ===========================================================================
//
// 验证 lazy rebuild 协议的核心契约：
//   ① ensure_vocab 在 dirty 时重建，清 dirty，发布新 shared_ptr
//   ② add_doc 新增 term 后，相应 shard.vocab_dirty_ 被置 true
//   ③ 旧 term 不触发 dirty（is_new_term=false → 不写）
//   ④ load 后所有 shard 的 vocab_dirty_ 为 true（首搜重建）
//   ⑤ 搜索路径吃 ensure_vocab → 跨 add_doc 边界能找到新 term

TEST(InvertedIndex, SortedVocabSidecarRebuilds) {
    InvertedIndex idx;

    // 起始：所有 shard vocab_dirty_ = true（Shard 默认构造）。
    for (std::size_t s = 0; s < 64; ++s) {
        EXPECT_TRUE(idx.shard_for("dummy_" + std::to_string(s)).vocab_dirty_.load())
            << "shard=" << s << " 起始应为 dirty";
    }

    // 加 3 个 term，hash 后大概率落在 3 个不同 shard（"alpha"/"beta"/"gamma"）。
    idx.add_doc(0, {{"alpha", tp(1, {0})}});
    idx.add_doc(1, {{"beta",  tp(1, {0})}});
    idx.add_doc(2, {{"gamma", tp(1, {0})}});

    // 持有"alpha"/"beta"/"gamma"的 shard 必被标脏；其它 shard 仍为 dirty=true
    // （因为默认构造就是 dirty）。我们断言持有 alpha 的 shard 被标脏。
    EXPECT_TRUE(idx.shard_for("alpha").vocab_dirty_.load())
        << "持有 'alpha' 的 shard 应被标脏";

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[1] = 1;
    checker.doc_lens[2] = 1;
    // 跑 fuzzy 命中 alpha → 持有 alpha 的 shard 走 dirty 路径 rebuild + clean。
    auto warmup = idx.search_fuzzy({"alpha"}, 10, 1, checker);
    ASSERT_EQ(warmup.size(), 1u);
    EXPECT_FALSE(idx.shard_for("alpha").vocab_dirty_.load())
        << "持有 'alpha' 的 shard 在首搜后应 clean";

    // 旧 term 再 add → 不该标脏（is_new_term=false 路径）。此时 alpha 所在
    // shard 已 clean；add_doc 不应再标脏。
    idx.add_doc(3, {{"alpha", tp(1, {0})}});
    EXPECT_FALSE(idx.shard_for("alpha").vocab_dirty_.load())
        << "旧 term 'alpha' add_doc 后所在 shard 不应被重标脏";

    // 新 term add → 持有该 term 的 shard 必 dirty。
    idx.add_doc(4, {{"delta", tp(1, {0})}});
    EXPECT_TRUE(idx.shard_for("delta").vocab_dirty_.load())
        << "新 term 'delta' 所在 shard 必被标脏";

    // 搜索应能找到 delta（走 lazy rebuild 路径）。需要 doc 3、doc 4 在 live 表中。
    checker.doc_lens[3] = 1;
    checker.doc_lens[4] = 1;
    auto fuzzy_with_delta = idx.search_fuzzy({"delta"}, 10, 0, checker);
    EXPECT_EQ(fuzzy_with_delta.size(), 1u)
        << "lazy rebuild 后搜索能找到 add_doc 时新增的 term";

    // rebuild 后 delta_shard 再次 clean。
    EXPECT_FALSE(idx.shard_for("delta").vocab_dirty_.load())
        << "lazy rebuild 后 dirty 应被清";

    // 模糊搜索仍能找到 alpha（rebuild 保留旧 key，doc 0 + doc 3）。
    auto fuzzy_alpha = idx.search_fuzzy({"alpha"}, 10, 0, checker);
    EXPECT_EQ(fuzzy_alpha.size(), 2u) << "alpha 应在 doc 0 和 doc 3 各命中一次";
}

// load → fuzzy 跨边界：load 后所有 shard dirty；fuzzy 遍历 64 个 shard
// 触发 ensure_vocab，全部 clean。
TEST(InvertedIndex, SortedVocabSidecarLoadMarksAllDirty) {
    auto tmp = std::filesystem::temp_directory_path() / "inv_vocab_sidecar.inv";
    std::filesystem::remove(tmp);

    {
        InvertedIndex idx;
        idx.add_doc(0, {{"hello", tp(1, {0})}, {"world", tp(1, {1})}});
        EXPECT_TRUE(idx.save(tmp.string()));
    }
    {
        InvertedIndex idx2;
        EXPECT_TRUE(idx2.load(tmp.string()));

        // load 后所有 shard 都应是 dirty。
        for (std::size_t s = 0; s < 64; ++s) {
            EXPECT_TRUE(idx2.shard_for("dummy_" + std::to_string(s)).vocab_dirty_.load())
                << "load 后 shard " << s << " 应为 dirty";
        }

        FakeLiveChecker checker;
        checker.doc_lens[0] = 2;
        // fuzzy 遍历 64 个 shard 触发 ensure_vocab，全部 clean。
        auto results = idx2.search_fuzzy({"hello"}, 10, 0, checker);
        ASSERT_EQ(results.size(), 1u);

        std::size_t clean_count = 0;
        for (std::size_t s = 0; s < 64; ++s) {
            if (!idx2.shard_for("dummy_" + std::to_string(s)).vocab_dirty_.load()) {
                ++clean_count;
            }
        }
        EXPECT_EQ(clean_count, 64u) << "fuzzy 遍历 64 个 shard 应清掉所有 dirty";
    }
    std::filesystem::remove(tmp);
}

// V6.3.1 通配符 binary search 路径：prefix 模式命中走区间 + lit 预过滤 + wildcard。
TEST(InvertedIndex, SortedVocabSidecarWildcardPrefixRebuild) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello",  tp(1, {0})}});
    idx.add_doc(1, {{"help",   tp(1, {0})}});
    idx.add_doc(2, {{"helmet", tp(1, {0})}});
    idx.add_doc(3, {{"world",  tp(1, {0})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[1] = 1;
    checker.doc_lens[2] = 1;
    checker.doc_lens[3] = 1;

    // 首次搜索触发 lazy rebuild。
    auto r1 = idx.search_wildcard("hel*", 10, checker);
    EXPECT_EQ(r1.size(), 3u) << "hel* 应匹配 hello/help/helmet 三词";

    // 加新 term 走 dirty 路径。
    idx.add_doc(4, {{"helicopter", tp(1, {0})}});
    checker.doc_lens[4] = 1;
    auto r2 = idx.search_wildcard("hel*", 10, checker);
    EXPECT_EQ(r2.size(), 4u) << "lazy rebuild 后应能找到新 term helicopter";

    // 中缀/后缀模式（pattern[0]=='*'）走全扫。
    auto r3 = idx.search_wildcard("*lo", 10, checker);
    EXPECT_EQ(r3.size(), 1u) << "*lo 应匹配 hello（精确）";
    auto r4 = idx.search_wildcard("*lp", 10, checker);
    EXPECT_EQ(r4.size(), 1u) << "*lp 应匹配 help";
}

// V6.3.4：v6 快照 save/load round-trip + 文件头校验。
// 体积对比在生产规模（1M docs）下验证；此处验证格式正确性与 round-trip。
TEST(InvertedIndex, V6SnapshotRoundtripWithPositions) {
    InvertedIndex idx;
    constexpr std::uint64_t kDocs = 500;
    constexpr int kTermsPerDoc = 5;
    for (std::uint64_t d = 0; d < kDocs; ++d) {
        TermPositions tp;
        for (int t = 0; t < kTermsPerDoc; ++t) {
            std::string term = "term" + std::to_string(t);
            std::uint32_t tf = static_cast<std::uint32_t>((d + t) % 3) + 1;
            tp.emplace(term, std::make_pair(tf, std::vector<std::uint32_t>{0}));
        }
        idx.add_doc(d, tp);
    }
    idx.finalize_all_postings();

    auto tmp = std::filesystem::temp_directory_path() / "inv_v6_rt.inv";
    std::filesystem::remove(tmp);
    ASSERT_TRUE(idx.save(tmp.string()));
    EXPECT_GT(std::filesystem::file_size(tmp), 0u);

    // 校验文件头：magic(4B) + version=6(4B)
    {
        std::FILE* f = std::fopen(tmp.string().c_str(), "rb");
        ASSERT_NE(f, nullptr);
        std::uint32_t magic = 0, ver = 0;
        ASSERT_EQ(std::fread(&magic, 4, 1, f), 1u);
        ASSERT_EQ(std::fread(&ver, 4, 1, f), 1u);
        std::fclose(f);
        EXPECT_EQ(magic, 0x494E5632u);
        EXPECT_EQ(ver, 6u);
    }

    InvertedIndex idx2;
    ASSERT_TRUE(idx2.load(tmp.string()));
    FakeLiveChecker checker;
    for (std::uint64_t d = 0; d < kDocs; ++d) {
        checker.doc_lens[d] = kTermsPerDoc;
    }
    auto results = idx2.search({"term0"}, 10, checker);
    EXPECT_EQ(results.size(), 10u);

    std::filesystem::remove(tmp);
}
