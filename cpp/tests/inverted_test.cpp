#include <gtest/gtest.h>

#include <filesystem>

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

TEST(InvertedIndex, PhraseSearchNoFalsePositive) {
    InvertedIndex idx;
    idx.add_doc(0, {{"the", tp(1, {0})}, {"fox", tp(1, {1})}, {"quick", tp(1, {2})}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;

    auto results = idx.search_phrase({"quick", "fox"}, 10, checker);
    EXPECT_TRUE(results.empty());
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
