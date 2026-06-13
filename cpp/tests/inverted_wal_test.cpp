#include <gtest/gtest.h>
#include <filesystem>

#include "bitcask/inverted.hpp"
#include "bitcask/inverted_wal.hpp"
#include "bitcask/query.hpp"
#include "test_support.hpp"

using namespace bitcask::bm25;

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
// items 严格升序无重复 → bool_search 的 intersect_u64 不崩、结果正确。
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

    // bool_search 两个 MUST：触发 intersect_u64；修复前重复 ord 会让 AVX2
    // 越界写崩溃，且交集结果错。
    auto q = QueryNode::must_all(
        {QueryNode::must_term("alpha"), QueryNode::must_term("beta")});
    auto hits = idx2.bool_search(q, 100, checker);
    EXPECT_EQ(hits.size(), 50u);  // 全部 50 文档同时含 alpha+beta

    std::filesystem::remove(snap);
    std::filesystem::remove(wal);
}

// O11 framing:截尾注入——最后一条 entry 只落了一半(模拟崩溃),
// replay 应只回放完整条目,且把文件截断修复到上一完整 entry 末尾。
TEST(WalFraming, TruncatedTailDetectedAndRepaired) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_frame_trunc.wal";
    std::filesystem::remove(tmp);

    {
        InvertedWal wal(tmp.string());
        ASSERT_TRUE(wal.valid());
        TermPositions terms;
        terms.emplace("alpha", tp(1, {0}));
        wal.append_add_doc(0, terms);
        wal.append_add_doc(1, terms);
    }
    const auto full_size = std::filesystem::file_size(tmp);

    // 追加第三条后砍掉它的后 6 字节(CRC+部分 payload),制造半条 entry。
    {
        InvertedWal wal(tmp.string());
        TermPositions terms;
        terms.emplace("alpha", tp(1, {0}));
        wal.append_add_doc(2, terms);
    }
    std::filesystem::resize_file(tmp, std::filesystem::file_size(tmp) - 6);

    // 直接用 InvertedWal::replay——上层 InvertedIndex::replay_wal 在重放
    // 成功后会整体清空 WAL(既有语义),观察不到截断修复。
    InvertedIndex idx;
    InvertedWal wal(tmp.string());
    int count = wal.replay(idx);
    EXPECT_EQ(count, 2);                  // 半条不回放
    EXPECT_EQ(idx.live_doc_count(), 2u);
    // 截断修复:文件应回到前两条的精确末尾。
    EXPECT_EQ(std::filesystem::file_size(tmp), full_size);

    std::filesystem::remove(tmp);
}

// O11 framing:位翻转注入——CRC 必须拦住 payload 中部的字节腐坏。
TEST(WalFraming, BitflipDetectedByCrc) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_frame_flip.wal";
    std::filesystem::remove(tmp);

    {
        InvertedWal wal(tmp.string());
        TermPositions terms;
        terms.emplace("alpha", tp(1, {0}));
        wal.append_add_doc(0, terms);
        wal.append_add_doc(1, terms);
    }

    // 翻转第二条 entry payload 中间一个字节(跳过第一条:8B 头+4B len+payload+4B CRC)。
    {
        std::FILE* f = std::fopen(tmp.string().c_str(), "rb+");
        ASSERT_NE(f, nullptr);
        ASSERT_EQ(std::fseek(f, 8, SEEK_SET), 0);
        std::uint32_t len1 = 0;
        ASSERT_EQ(std::fread(&len1, 1, 4, f), 4u);
        const long second_payload_mid =
            static_cast<long>(8 + 4 + len1 + 4 + 4 + len1 / 2);
        ASSERT_EQ(std::fseek(f, second_payload_mid, SEEK_SET), 0);
        int ch = std::fgetc(f);
        ASSERT_NE(ch, EOF);
        ASSERT_EQ(std::fseek(f, second_payload_mid, SEEK_SET), 0);
        std::fputc(ch ^ 0xFF, f);
        std::fclose(f);
    }

    InvertedIndex idx;
    idx.enable_wal(tmp.string());
    int count = idx.replay_wal();
    EXPECT_EQ(count, 1);                  // 第二条被 CRC 拦下
    EXPECT_EQ(idx.live_doc_count(), 1u);

    std::filesystem::remove(tmp);
}

// V6.2.3:batch_size>1 时,entry 缓冲到 batch_buf_,满后一次 flush。
// 写 3 条 batch_size=2 → 第 2 条 flush,第 3 条在析构时 flush。
// 关闭后重开 replay 验证全部 3 条都在。
TEST(WalBatch, BufferFlushesOnThreshold) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_batch_flush.wal";
    std::filesystem::remove(tmp);

    {
        InvertedWal wal(tmp.string(), 2);  // batch_size=2
        ASSERT_TRUE(wal.valid());
        TermPositions terms;
        terms.emplace("alpha", tp(1, {0}));
        wal.append_add_doc(0, terms);
        wal.append_add_doc(1, terms);  // flush triggered (count=2)
        wal.append_add_doc(2, terms);  // buffered, flushed on destruct
    }

    InvertedIndex idx;
    InvertedWal wal(tmp.string());
    int count = wal.replay(idx);
    EXPECT_EQ(count, 3);
    EXPECT_EQ(idx.live_doc_count(), 3u);

    std::filesystem::remove(tmp);
}

// V6.2.3:模拟批量模式崩溃——写入 5 条(batch_size=3),前 3 条已 flush,
// 后 2 条在 batch_buf_ 中尚未写出。模拟崩溃:直接 close FILE 而不 flush_batch。
// replay 只应回放已 flush 的 3 条。
TEST(CrashRecoveryBatched, BufferedEntriesLostOnCrash) {
    auto tmp = std::filesystem::temp_directory_path() / "wal_crash_batch.wal";
    std::filesystem::remove(tmp);

    // Phase 1: write 5 docs with batch_size=3 in a scope. The destructor
    // will flush the buffer (2 remaining entries) on scope exit, so the
    // post-destructor file would be 228 bytes. To simulate the crash, we
    // chop the file back to 140 bytes (header + 3 entries) using resize_file,
    // which is what the OS would leave behind if the process died before
    // destructor's flush_batch ran.
    {
        InvertedWal wal(tmp.string(), 3);
        ASSERT_TRUE(wal.valid());
        TermPositions terms;
        terms.emplace("alpha", tp(1, {0}));
        wal.append_add_doc(0, terms);
        wal.append_add_doc(1, terms);
        wal.append_add_doc(2, terms);  // flush at count=3
        // After 3 entries: file on disk has [8B WAL header] + 3 entries;
        // nothing buffered.
        // Entry layout (one term "alpha" + tp(1,{0}), V6.3.3 VByte format):
        //   [4B len][1B type][8B ord][4B term_count=1]
        //   [4B term_len=5][5B "alpha"]
        //   [4B tf_vbyte_len=1][1B tf_vbyte(0x81)]          // tf=1 → 1 byte
        //   [4B pos_count=1][4B pos_csize=1][1B pos_vbyte(0x80)]  // pos=0 → 1 byte
        //   [4B crc] = 44B total.
        //   8B header + 3 entries = 140 bytes.
        EXPECT_EQ(std::filesystem::file_size(tmp), 140u);
        wal.append_add_doc(3, terms);  // buffered
        wal.append_add_doc(4, terms);  // buffered
        // With 2 buffered, file size is still 140 (buffer not yet flushed).
        EXPECT_EQ(std::filesystem::file_size(tmp), 140u);
    }
    // After scope: destructor flushed the 2 buffered entries → 228 bytes.
    EXPECT_EQ(std::filesystem::file_size(tmp), 228u);

    // Simulate crash: chop the file to 140 bytes (header + 3 entries only).
    // This emulates the OS file state when the process died before the
    // destructor's flush_batch ran.
    std::filesystem::resize_file(tmp, 140u);

    // Replay: should get exactly 3 entries (ords 0,1,2).
    InvertedIndex idx;
    InvertedWal wal(tmp.string());
    int count = wal.replay(idx);
    EXPECT_EQ(count, 3);
    EXPECT_EQ(idx.live_doc_count(), 3u);
    EXPECT_EQ(idx.df("alpha"), 3u);

    std::filesystem::remove(tmp);
}

// V6.2.3:同样的内容用 batch_size=1 和 batch_size=4 写,replay 结果一致。
TEST(WalBatch, BatchAndImmediateProduceSameReplay) {
    auto tmp1 = std::filesystem::temp_directory_path() / "wal_immediate.wal";
    auto tmp2 = std::filesystem::temp_directory_path() / "wal_batched.wal";
    std::filesystem::remove(tmp1);
    std::filesystem::remove(tmp2);

    TermPositions terms;
    terms.emplace("alpha", tp(1, {0}));
    terms.emplace("beta", tp(1, {1}));

    for (int i = 0; i < 10; ++i) {
        {
            InvertedWal wal(tmp1.string(), 1);
            wal.append_add_doc(static_cast<std::uint64_t>(i), terms);
        }
        {
            InvertedWal wal(tmp2.string(), 4);
            wal.append_add_doc(static_cast<std::uint64_t>(i), terms);
        }
    }

    InvertedIndex idx1, idx2;
    InvertedWal wal1(tmp1.string());
    InvertedWal wal2(tmp2.string());
    int c1 = wal1.replay(idx1);
    int c2 = wal2.replay(idx2);
    EXPECT_EQ(c1, 10);
    EXPECT_EQ(c2, 10);
    EXPECT_EQ(idx1.live_doc_count(), idx2.live_doc_count());
    EXPECT_EQ(idx1.df("alpha"), idx2.df("alpha"));

    std::filesystem::remove(tmp1);
    std::filesystem::remove(tmp2);
}
