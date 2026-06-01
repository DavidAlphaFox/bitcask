#include <gtest/gtest.h>
#include <filesystem>

#include "bitcask/inverted.hpp"
#include "bitcask/inverted_wal.hpp"

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