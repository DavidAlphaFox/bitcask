#include <gtest/gtest.h>
#include <filesystem>

#include "bitcask/inverted.hpp"
#include "bitcask/inverted_wal.hpp"
#include "bitcask/query.hpp"

using namespace bitcask::bm25;

namespace {

auto tp(std::uint32_t tf, std::vector<std::uint32_t> positions = {})
    -> std::pair<std::uint32_t, std::vector<std::uint32_t>> {
    return {tf, std::move(positions)};
}

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

TEST(WalCreateAndReplay, Basic) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_basic_test.wal";
    std::filesystem::remove(tmp);

    InvertedWal wal(tmp.string());
    ASSERT_TRUE(wal.valid());

    TermPositions terms1;
    terms1.emplace("hello", tp(1, {0}));
    terms1.emplace("world", tp(2, {1, 2}));
    wal.append_add_doc(0, terms1);

    TermPositions terms2;
    terms2.emplace("foo", tp(3, {0, 1, 2}));
    wal.append_add_doc(1, terms2);

    InvertedIndex idx;
    idx.enable_wal(tmp.string());

    FakeLiveChecker checker;
    checker.doc_lens[0] = 3;
    checker.doc_lens[1] = 3;

    int count = idx.replay_wal();
    EXPECT_EQ(count, 2);
    EXPECT_EQ(idx.live_doc_count(), 2u);
    EXPECT_EQ(idx.df("hello"), 1u);
    EXPECT_EQ(idx.df("world"), 1u);
    EXPECT_EQ(idx.df("foo"), 1u);

    auto results = idx.search({"hello"}, 10, checker);
    ASSERT_EQ(results.size(), 1u);
    EXPECT_EQ(results[0].ord, 0u);

    std::filesystem::remove(tmp);
}

TEST(WalAddAndRemove, AddThenRemove) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_add_remove_test.wal";
    std::filesystem::remove(tmp);

    InvertedWal wal(tmp.string());
    ASSERT_TRUE(wal.valid());

    TermPositions terms;
    terms.emplace("apple", tp(1, {0}));
    wal.append_add_doc(0, terms);
    wal.append_add_doc(1, terms);

    std::unordered_map<std::string, std::uint32_t> tfs;
    tfs.emplace("apple", 1);
    wal.append_remove_doc(1, tfs);

    InvertedIndex idx;
    idx.enable_wal(tmp.string());

    FakeLiveChecker checker;
    checker.doc_lens[1] = 1;

    int count = idx.replay_wal();
    EXPECT_EQ(count, 3);
    EXPECT_EQ(idx.live_doc_count(), 1u);

    std::filesystem::remove(tmp);
}

TEST(WalTruncate, TruncateEmptiesWal) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_truncate_test.wal";
    std::filesystem::remove(tmp);

    InvertedWal wal(tmp.string());
    ASSERT_TRUE(wal.valid());

    TermPositions terms;
    terms.emplace("x", tp(1, {0}));
    wal.append_add_doc(0, terms);
    wal.append_add_doc(1, terms);

    ASSERT_TRUE(wal.truncate());

    InvertedIndex idx;
    idx.enable_wal(tmp.string());

    int count = idx.replay_wal();
    EXPECT_EQ(count, 0);
    EXPECT_EQ(idx.live_doc_count(), 0u);

    std::filesystem::remove(tmp);
}

TEST(WalCorruptedEntry, GracefulDegradation) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_corrupt_test.wal";
    std::filesystem::remove(tmp);

    {
        InvertedWal wal(tmp.string());
        ASSERT_TRUE(wal.valid());

        TermPositions terms;
        terms.emplace("good", tp(1, {0}));
        wal.append_add_doc(0, terms);
        wal.append_add_doc(1, terms);

        std::FILE* f = std::fopen(tmp.string().c_str(), "ab");
        if (f) {
            std::fwrite("GARBAGE", 1, 7, f);
            std::fclose(f);
        }
    }

    InvertedIndex idx;
    idx.enable_wal(tmp.string());

    FakeLiveChecker checker;
    checker.doc_lens[0] = 1;
    checker.doc_lens[1] = 1;

    int count = idx.replay_wal();
    EXPECT_EQ(count, 2);
    EXPECT_EQ(idx.live_doc_count(), 2u);

    std::filesystem::remove(tmp);
}

TEST(WalNoFile, ReplayNonexistent) {
    InvertedIndex idx;
    idx.enable_wal("/nonexistent/path/to/wal.wal");
    int count = idx.replay_wal();
    EXPECT_EQ(count, 0);
}

TEST(WalMultipleAddDocs, ManyAdds) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_many_test.wal";
    std::filesystem::remove(tmp);

    InvertedWal wal(tmp.string());
    ASSERT_TRUE(wal.valid());

    TermPositions terms;
    terms.emplace("term", tp(1, {0}));

    constexpr std::uint64_t N = 100;
    for (std::uint64_t i = 0; i < N; ++i) {
        wal.append_add_doc(i, terms);
    }

    InvertedIndex idx;
    idx.enable_wal(tmp.string());

    FakeLiveChecker checker;
    for (std::uint64_t i = 0; i < N; ++i) {
        checker.doc_lens[i] = 1;
    }

    int count = idx.replay_wal();
    EXPECT_EQ(count, static_cast<int>(N));
    EXPECT_EQ(idx.live_doc_count(), N);
    EXPECT_EQ(idx.df("term"), N);

    std::filesystem::remove(tmp);
}
// add_doc 水位幂等（review #1 根因）：重复 ord 的整文档被丢弃，items 不重复。
TEST(AddDocIdempotent, DuplicateOrdDropped) {
    InvertedIndex idx;
    idx.add_doc(0, {{"a", tp(1, {0})}, {"b", tp(1, {1})}});
    idx.add_doc(1, {{"a", tp(1, {0})}});
    EXPECT_EQ(idx.live_doc_count(), 2u);
    EXPECT_EQ(idx.df("a"), 2u);

    // 重放 ord 0（≤ 水位）→ 整文档丢弃：df/count 不变。
    idx.add_doc(0, {{"a", tp(1, {0})}, {"b", tp(1, {1})}});
    EXPECT_EQ(idx.live_doc_count(), 2u);
    EXPECT_EQ(idx.df("a"), 2u);
    EXPECT_EQ(idx.df("b"), 1u);

    // 重放 ord 1（= 水位）→ 同样丢弃。
    idx.add_doc(1, {{"a", tp(1, {0})}});
    EXPECT_EQ(idx.df("a"), 2u);

    // 新 ord 2（> 水位）→ 正常追加。
    idx.add_doc(2, {{"a", tp(1, {0})}});
    EXPECT_EQ(idx.live_doc_count(), 3u);
    EXPECT_EQ(idx.df("a"), 3u);
}

// 崩溃恢复端到端（review #1）：save 后不 truncate（模拟 save/truncate_wal
// 之间崩溃）→ 重启 load + replay_wal 重放快照已含条目 → 水位幂等保证
// items 严格升序无重复 → bool_search 的 intersect_u32 不崩、结果正确。
TEST(CrashRecovery, ReplayDuplicateKeepsItemsSortedUnique) {
    auto snap = std::filesystem::temp_directory_path() / "inv_crash_snap.inv";
    auto wal  = std::filesystem::temp_directory_path() / "inv_crash_snap.inv.wal";
    std::filesystem::remove(snap);
    std::filesystem::remove(wal);

    FakeLiveChecker checker;
    {
        // 原索引：enable_wal 后写若干含两个 MUST 词的文档（同时进内存+WAL），
        // 然后 save——此时快照与 WAL 含同一批文档。刻意不 truncate_wal。
        InvertedIndex idx;
        idx.enable_wal(wal.string());
        for (std::uint64_t ord = 0; ord < 50; ++ord) {
            idx.add_doc(ord, {{"alpha", tp(1, {0})}, {"beta", tp(1, {1})}});
            checker.doc_lens[ord] = 2;
        }
        ASSERT_TRUE(idx.save(snap.string()));
        // 崩溃：save 完成，truncate_wal 未执行。
    }

    // 重启：load 快照 + replay_wal（重放 0..49，全部 ≤ 水位 → 幂等丢弃）。
    InvertedIndex idx2;
    ASSERT_TRUE(idx2.load(snap.string()));
    idx2.enable_wal(wal.string());
    idx2.replay_wal();

    // items 严格升序无重复（幂等生效）。
    EXPECT_EQ(idx2.df("alpha"), 50u);
    EXPECT_EQ(idx2.df("beta"), 50u);
    EXPECT_EQ(idx2.live_doc_count(), 50u);

    // bool_search 两个 MUST：触发 intersect_u32；修复前重复 ord 会让 AVX2
    // 越界写崩溃，且交集结果错。
    auto q = QueryNode::must_all(
        {QueryNode::must_term("alpha"), QueryNode::must_term("beta")});
    auto hits = idx2.bool_search(q, 100, checker);
    EXPECT_EQ(hits.size(), 50u);  // 全部 50 文档同时含 alpha+beta

    std::filesystem::remove(snap);
    std::filesystem::remove(wal);
}
