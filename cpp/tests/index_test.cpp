// Unit tests for the in-memory Index side tables (doc/vector-db-design-zh.md §3.1).

#include <gtest/gtest.h>

#include "bitcask/index.hpp"

using bitcask::index::DocLoc;
using bitcask::index::DocSlot;
using bitcask::index::Index;

namespace {

DocSlot slot(std::uint32_t file_id, std::uint64_t off, std::uint32_t sz,
             std::uint32_t ts = 0) {
    return DocSlot{DocLoc{file_id, off, sz}, ts, /*doc_len*/ 0};
}

}  // namespace

TEST(Index, AllocOrdMonotonic) {
    Index idx;
    EXPECT_EQ(idx.alloc_ord(), 0u);
    EXPECT_EQ(idx.alloc_ord(), 1u);
    EXPECT_EQ(idx.alloc_ord(), 2u);
    EXPECT_EQ(idx.info().next_ord, 3u);
}

TEST(Index, InsertThenGet) {
    Index idx;
    const std::uint64_t ord = idx.alloc_ord();
    idx.put_doc("doc-1", ord, slot(1, 100, 50, 42));

    auto s = idx.get("doc-1");
    ASSERT_TRUE(s.has_value());
    EXPECT_EQ(s->loc.file_id, 1u);
    EXPECT_EQ(s->loc.offset, 100u);
    EXPECT_EQ(s->loc.total_sz, 50u);
    EXPECT_EQ(s->tstamp, 42u);
    EXPECT_TRUE(idx.is_live(ord));

    auto info = idx.info();
    EXPECT_EQ(info.live_docs, 1u);

    EXPECT_FALSE(idx.get("missing").has_value());
}

TEST(Index, UpdateSoftDeletesOldOrd) {
    Index idx;
    const std::uint64_t o1 = idx.alloc_ord();
    idx.put_doc("doc-1", o1, slot(1, 0, 10));

    const std::uint64_t o2 = idx.alloc_ord();
    idx.put_doc("doc-1", o2, slot(1, 10, 20));

    // 旧 ord 软删，新 ord 存活。
    EXPECT_FALSE(idx.is_live(o1));
    EXPECT_TRUE(idx.is_live(o2));

    // get 返回最新版本。
    auto s = idx.get("doc-1");
    ASSERT_TRUE(s.has_value());
    EXPECT_EQ(s->loc.offset, 10u);
    EXPECT_EQ(s->loc.total_sz, 20u);

    // 同一文档更新，存活文档数不变。
    EXPECT_EQ(idx.info().live_docs, 1u);
    // 历史 ord 数 = 2（含已死）。
    EXPECT_EQ(idx.info().total_ords, 2u);
}

TEST(Index, RemoveErasesAndSoftDeletes) {
    Index idx;
    const std::uint64_t o1 = idx.alloc_ord();
    idx.put_doc("doc-1", o1, slot(1, 0, 10));

    const std::uint64_t tomb = idx.alloc_ord();
    EXPECT_TRUE(idx.remove("doc-1", tomb));

    EXPECT_FALSE(idx.get("doc-1").has_value());
    EXPECT_FALSE(idx.is_live(o1));
    EXPECT_EQ(idx.info().live_docs, 0u);
}

TEST(Index, RemoveMissingReturnsFalse) {
    Index idx;
    EXPECT_FALSE(idx.remove("nope", idx.alloc_ord()));
    EXPECT_EQ(idx.info().live_docs, 0u);
}

TEST(Index, ReinsertAfterRemove) {
    Index idx;
    idx.put_doc("doc-1", idx.alloc_ord(), slot(1, 0, 10));
    idx.remove("doc-1", idx.alloc_ord());

    const std::uint64_t o = idx.alloc_ord();
    idx.put_doc("doc-1", o, slot(2, 0, 30));
    auto s = idx.get("doc-1");
    ASSERT_TRUE(s.has_value());
    EXPECT_EQ(s->loc.file_id, 2u);
    EXPECT_EQ(idx.info().live_docs, 1u);
}

TEST(Index, OrdToExt) {
    Index idx;
    const std::uint64_t o = idx.alloc_ord();
    idx.put_doc("hello", o, slot(1, 0, 10));
    auto e = idx.ord_to_ext(o);
    ASSERT_TRUE(e.has_value());
    EXPECT_EQ(*e, "hello");
    EXPECT_FALSE(idx.ord_to_ext(9999).has_value());
}

// 恢复路径：按 ord 序回放磁盘 record（显式 ord，不经 alloc_ord）。
// put_doc/remove 内部推进 next_ord，后写自动覆盖旧版本。
TEST(Index, ReplayWithExplicitOrds) {
    Index idx;
    idx.put_doc("a", 0, slot(1, 0,  10));
    idx.put_doc("b", 1, slot(1, 10, 10));
    idx.put_doc("a", 2, slot(1, 20, 15));   // update a
    idx.remove("b", 3);                      // delete b

    EXPECT_EQ(idx.info().next_ord, 4u);      // 推到 max ord + 1
    EXPECT_EQ(idx.info().live_docs, 1u);     // 只剩 a

    auto a = idx.get("a");
    ASSERT_TRUE(a.has_value());
    EXPECT_EQ(a->loc.offset, 20u);           // a 的最新版本
    EXPECT_FALSE(idx.get("b").has_value());

    EXPECT_FALSE(idx.is_live(0));            // a 旧版本
    EXPECT_TRUE(idx.is_live(2));             // a 新版本
    EXPECT_FALSE(idx.is_live(1));            // b（已删）

    // 之后正常 alloc_ord 接着 next_ord 走。
    EXPECT_EQ(idx.alloc_ord(), 4u);
}

// ---- 分块数组测试（方案 B）----

TEST(Index, CrossChunkOps) {
    Index idx;
    constexpr auto N = bitcask::index::kChunkOrds;

    idx.put_doc("low",  0,     slot(1, 0,  10));
    idx.put_doc("high", N + 5, slot(2, 100, 20));

    EXPECT_TRUE(idx.is_live(0));
    EXPECT_TRUE(idx.is_live(N + 5));
    EXPECT_FALSE(idx.is_live(1));
    EXPECT_FALSE(idx.is_live(N));

    auto lo = idx.get("low");
    ASSERT_TRUE(lo.has_value());
    EXPECT_EQ(lo->loc.file_id, 1u);

    auto hi = idx.get("high");
    ASSERT_TRUE(hi.has_value());
    EXPECT_EQ(hi->loc.file_id, 2u);

    EXPECT_EQ(*idx.ord_to_ext(0), "low");
    EXPECT_EQ(*idx.ord_to_ext(N + 5), "high");
}

TEST(Index, ChunkBoundaryLastSlot) {
    Index idx;
    constexpr auto N = bitcask::index::kChunkOrds;

    idx.put_doc("last0",  N - 1, slot(1, 0, 10));
    idx.put_doc("first1", N,     slot(2, 0, 10));

    EXPECT_TRUE(idx.is_live(N - 1));
    EXPECT_TRUE(idx.is_live(N));
    EXPECT_EQ(*idx.ord_to_ext(N - 1), "last0");
    EXPECT_EQ(*idx.ord_to_ext(N), "first1");
}

TEST(Index, CompactChunksFreesDeadChunks) {
    Index idx;
    constexpr auto N = bitcask::index::kChunkOrds;

    idx.put_doc("a", 0,     slot(1, 0, 10));
    idx.put_doc("b", 1,     slot(1, 10, 10));
    idx.put_doc("c", N,     slot(1, 20, 10));
    idx.put_doc("d", N + 1, slot(1, 30, 10));

    EXPECT_EQ(idx.info().chunks_allocated, 2u);

    idx.remove("c", idx.alloc_ord());
    idx.remove("d", idx.alloc_ord());

    auto freed = idx.compact_chunks();
    EXPECT_EQ(freed, 1u);
    EXPECT_EQ(idx.info().chunks_freed, 1u);

    EXPECT_TRUE(idx.is_live(0));
    EXPECT_TRUE(idx.is_live(1));
    EXPECT_FALSE(idx.is_live(N));
    EXPECT_FALSE(idx.is_live(N + 1));
}

TEST(Index, CompactChunksPreservesLiveChunks) {
    Index idx;
    constexpr auto N = bitcask::index::kChunkOrds;

    idx.put_doc("a", 0,     slot(1, 0, 10));
    idx.put_doc("b", N,     slot(1, 10, 10));
    idx.put_doc("c", N + 1, slot(1, 20, 10));

    idx.remove("c", idx.alloc_ord());

    auto freed = idx.compact_chunks();
    EXPECT_EQ(freed, 0u);

    EXPECT_TRUE(idx.is_live(0));
    EXPECT_TRUE(idx.is_live(N));
}

TEST(Index, ForEachLiveAcrossChunks) {
    Index idx;
    constexpr auto N = bitcask::index::kChunkOrds;

    idx.put_doc("a", 0,     slot(1, 0, 10));
    idx.put_doc("b", N,     slot(1, 10, 10));
    idx.put_doc("c", N + 1, slot(1, 20, 10));

    std::vector<std::pair<std::uint64_t, std::string>> seen;
    idx.for_each_live([&](std::uint64_t ord, const std::string& ext,
                          const DocSlot&) {
        seen.emplace_back(ord, ext);
    });

    ASSERT_EQ(seen.size(), 3u);
    EXPECT_EQ(seen[0].first, 0u);
    EXPECT_EQ(seen[0].second, "a");
    EXPECT_EQ(seen[1].first, N);
    EXPECT_EQ(seen[1].second, "b");
    EXPECT_EQ(seen[2].first, N + 1);
    EXPECT_EQ(seen[2].second, "c");
}
