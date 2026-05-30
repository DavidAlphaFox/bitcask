#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/inverted.hpp"

using namespace bitcask::bm25;
using namespace bitcask::text;

namespace {

// 简易 LiveChecker 实现：所有 ord 都 live，doc_len 按给定 map 返回。
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

}  // namespace

TEST(InvertedIndex, AddAndSearch) {
    InvertedIndex idx;
    auto analyzer = AnalyzerFactory::create(AnalyzerConfig{});
    ASSERT_NE(analyzer, nullptr);

    // 文档 0: "北京市朝阳区"
    auto tfs0 = analyzer->analyze("北京市朝阳区");
    idx.add_doc(0, tfs0);

    // 文档 1: "上海浦东"
    auto tfs1 = analyzer->analyze("上海浦东");
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
    idx.add_doc(0, {{"hello", 1}, {"world", 1}});
    idx.add_doc(1, {{"hello", 2}});

    EXPECT_EQ(idx.live_doc_count(), 2u);
    EXPECT_EQ(idx.sum_doc_len(), 4u);  // doc0: tf=1+1=2, doc1: tf=2=2

    idx.remove_doc(2, {{"hello", 1}, {"world", 1}});
    EXPECT_EQ(idx.live_doc_count(), 1u);
    EXPECT_EQ(idx.sum_doc_len(), 2u);
}

TEST(InvertedIndex, SearchSkipsDeleted) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", 2}});
    idx.add_doc(1, {{"hello", 1}});

    FakeLiveChecker checker;
    // ord 0 已删，ord 1 live
    checker.doc_lens[1] = 5;

    auto results = idx.search({"hello"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 1u);
}

TEST(InvertedIndex, SearchTopK) {
    InvertedIndex idx;
    // doc0: 包含 "rare" + "common"
    idx.add_doc(0, {{"rare", 1}, {"common", 1}});
    // doc1: 包含 "common"（高 tf）+ "unique1"
    idx.add_doc(1, {{"common", 5}, {"unique1", 1}});
    // doc2: 包含 "common"（中 tf）
    idx.add_doc(2, {{"common", 3}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 2;
    checker.doc_lens[1] = 6;
    checker.doc_lens[2] = 3;

    // 查询 "rare"：df=1，IDF > 0，只有 doc0 命中
    auto results = idx.search({"rare"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);

    // 查询 "unique1"：df=1，只有 doc1 命中
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
    idx.add_doc(0, {{"hello", 1}});

    FakeLiveChecker checker;
    checker.doc_lens[0] = 10;

    auto results = idx.search({"nonexistent"}, 10, checker);
    EXPECT_TRUE(results.empty());
}

TEST(InvertedIndex, AvgDocLen) {
    InvertedIndex idx;
    idx.add_doc(0, {{"a", 2}, {"b", 3}});
    idx.add_doc(1, {{"c", 5}});

    EXPECT_DOUBLE_EQ(idx.avg_doc_len(), 5.0);
}

TEST(InvertedIndex, DfReturnsPostingCount) {
    InvertedIndex idx;
    idx.add_doc(0, {{"hello", 1}});
    idx.add_doc(1, {{"hello", 2}});
    idx.add_doc(2, {{"world", 1}});

    EXPECT_EQ(idx.df("hello"), 2u);
    EXPECT_EQ(idx.df("world"), 1u);
    EXPECT_EQ(idx.df("missing"), 0u);
}
