#include <gtest/gtest.h>
#include <bitcask/cask.hpp>
#include <bitcask/codec.hpp>
#include <filesystem>
#include <vector>

namespace {

using bitcask::Cask;
using bitcask::CaskOptions;
using bitcask::GetResult;
using bitcask::search::SearchLayerConfig;
using bitcask::search::SearchHit;
using bitcask::text::AnalyzerType;

class CaskDocValueTest : public ::testing::Test {
protected:
    void SetUp() override {
        namespace fs = std::filesystem;
        tmpdir_ = std::filesystem::temp_directory_path() / "bitcask_docvalue_test";
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
        std::filesystem::create_directories(tmpdir_, ec);
    }

    void TearDown() override {
        namespace fs = std::filesystem;
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
    }

    std::filesystem::path tmpdir_;
};

TEST_F(CaskDocValueTest, PutGetRoundTrip) {
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'k'}, std::byte{'e'}, std::byte{'y'}};
    std::vector<std::byte> val{std::byte{'v'}, std::byte{'a'}, std::byte{'l'}, std::byte{'u'}, std::byte{'e'}};

    auto pr = (*c)->put(key, val, /*tstamp*/ 1000);
    ASSERT_TRUE(pr);

    auto gr = (*c)->get(key);
    ASSERT_TRUE(gr);
    EXPECT_EQ(gr->value, val);
    EXPECT_EQ(gr->tstamp, 1000u);
    // alloc_ord 从 0 开始，第一次 put 的 ord = 0
    EXPECT_EQ(gr->ord, 0u);

    (*c)->close();
}

TEST_F(CaskDocValueTest, PutGetRoundTripMultipleKeys) {
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key1{std::byte{'a'}};
    std::vector<std::byte> val1{std::byte{1}};
    std::vector<std::byte> key2{std::byte{'b'}};
    std::vector<std::byte> val2{std::byte{2}, std::byte{3}};

    ASSERT_TRUE((*c)->put(key1, val1, 1000));
    ASSERT_TRUE((*c)->put(key2, val2, 1001));

    auto r1 = (*c)->get(key1);
    ASSERT_TRUE(r1);
    EXPECT_EQ(r1->value, val1);

    auto r2 = (*c)->get(key2);
    ASSERT_TRUE(r2);
    EXPECT_EQ(r2->value, val2);

    // ord 单调递增：key1 先写=0，key2 后写=1
    EXPECT_EQ(r1->ord, 0u);
    EXPECT_EQ(r2->ord, 1u);
    EXPECT_NE(r1->ord, r2->ord);

    (*c)->close();
}

TEST_F(CaskDocValueTest, OrdMonotonicallyIncreasing) {
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'k'}};
    std::vector<std::byte> val{std::byte{'v'}};
    // 用 -1 作为哨兵，因为第一次 ord = 0
    std::int64_t last_ord = -1;

    for (int i = 0; i < 5; ++i) {
        auto pr = (*c)->put(key, val, static_cast<std::uint32_t>(2000 + i));
        ASSERT_TRUE(pr);
        auto gr = (*c)->get(key);
        ASSERT_TRUE(gr);
        EXPECT_GT(static_cast<std::int64_t>(gr->ord), last_ord);
        last_ord = static_cast<std::int64_t>(gr->ord);
    }

    (*c)->close();
}

TEST_F(CaskDocValueTest, RemoveAndReinsert) {
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'k'}};
    std::vector<std::byte> val1{std::byte{'a'}};
    std::vector<std::byte> val2{std::byte{'b'}};

    ASSERT_TRUE((*c)->put(key, val1, 1000));
    auto r1 = (*c)->get(key);
    ASSERT_TRUE(r1);
    std::uint64_t ord1 = r1->ord;

    ASSERT_TRUE((*c)->remove(key, 2000));

    ASSERT_TRUE((*c)->put(key, val2, 3000));
    auto r2 = (*c)->get(key);
    ASSERT_TRUE(r2);
    EXPECT_EQ(r2->value, val2);
    EXPECT_GT(r2->ord, ord1);

    (*c)->close();
}

TEST_F(CaskDocValueTest, MetaFileCreatedOnOpen) {
    namespace fs = std::filesystem;
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    EXPECT_TRUE(fs::exists(tmpdir_ / "bitcask.meta"));
    (*c)->close();
}

TEST_F(CaskDocValueTest, ModeMismatchKVVsSearch) {
    namespace fs = std::filesystem;
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);
    (*c)->close();

    CaskOptions search_opts;
    search_opts.read_write = true;
    search_opts.enable_search = true;
    auto c2 = Cask::open(tmpdir_.string(), search_opts);
    ASSERT_FALSE(c2);
    EXPECT_EQ(c2.error().kind, bitcask::CaskError::kModeMismatch);
}

TEST_F(CaskDocValueTest, ModeMismatchSearchVsKV) {
    namespace fs = std::filesystem;
    CaskOptions search_opts;
    search_opts.read_write = true;
    search_opts.enable_search = true;
    auto c = Cask::open(tmpdir_.string(), search_opts);
    ASSERT_TRUE(c);
    (*c)->close();

    CaskOptions opts;
    opts.read_write = true;
    auto c2 = Cask::open(tmpdir_.string(), opts);
    ASSERT_FALSE(c2);
    EXPECT_EQ(c2.error().kind, bitcask::CaskError::kModeMismatch);
}

TEST_F(CaskDocValueTest, DocValueEncodingVerified) {
    CaskOptions opts;
    opts.read_write = true;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'t'}, std::byte{'e'}, std::byte{'s'}, std::byte{'t'}};
    std::vector<std::byte> val{std::byte{'h'}, std::byte{'e'}, std::byte{'l'}, std::byte{'l'}, std::byte{'o'}};

    ASSERT_TRUE((*c)->put(key, val, 1000));
    (*c)->close();

    // 重新打开后 get 仍然能正确解码 DocValue
    auto c2 = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c2);

    auto gr = (*c2)->get(key);
    ASSERT_TRUE(gr);
    EXPECT_EQ(gr->value, val);
    // 恢复后 ord 保持不变（从 record header 读取）
    EXPECT_EQ(gr->ord, 0u);

    (*c2)->close();
}

TEST_F(CaskDocValueTest, SearchTextAfterPut) {
    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sl_cfg;
    sl_cfg.analyzer_config.type = AnalyzerType::Ngram;
    sl_cfg.analyzer_config.min_n = 2;
    sl_cfg.analyzer_config.max_n = 3;
    opts.search_config = sl_cfg;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);
    EXPECT_TRUE((*c)->has_search());

    std::vector<std::byte> key{std::byte{'k'}};
    std::vector<std::byte> val{std::byte{'h'}, std::byte{'e'}, std::byte{'l'}, std::byte{'l'}, std::byte{'o'}};

    ASSERT_TRUE((*c)->put(key, val, 1000));

    auto* search = (*c)->search();
    ASSERT_NE(search, nullptr);

    search->on_write("testkey", 0, "hello world", 1, 100, 50, 1000);

    auto r1 = search->search_text("hello", 10);
    ASSERT_TRUE(r1) << "search_text failed: " << r1.error();
    EXPECT_EQ(r1->size(), 1u);

    auto sr = (*c)->search_text("hello", /*k*/ 10);
    ASSERT_TRUE(sr);
    EXPECT_EQ(sr->hits.size(), 1u);
    EXPECT_EQ(sr->hits[0].ord, 0u);

    (*c)->close();
}

// S8.6：put_doc 多字段 → search_fields 字段路由，端到端经 Cask（含异步 IndexTask）。
TEST_F(CaskDocValueTest, MultiFieldPutAndSearch) {
    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sl_cfg;
    sl_cfg.analyzer_config.type = AnalyzerType::Whitespace;
    opts.search_config = sl_cfg;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    auto bytes = [](std::string_view s) {
        return std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(s.data()), s.size());
    };

    // doc1: title="apple fruit", body="banana"
    bitcask::DocInput d1;
    d1.fields.push_back({"title", bytes("apple fruit")});
    d1.fields.push_back({"body", bytes("banana split")});
    ASSERT_TRUE((*c)->put_doc(bytes("doc1"), d1, 1000));

    // doc2: title="banana", body="apple"
    bitcask::DocInput d2;
    d2.fields.push_back({"title", bytes("banana bread")});
    d2.fields.push_back({"body", bytes("apple pie")});
    ASSERT_TRUE((*c)->put_doc(bytes("doc2"), d2, 1001));

    // title:apple 只命中 doc1（apple 在 doc1 title、doc2 body）。
    auto r = (*c)->search_fields("title:apple", 10);
    ASSERT_TRUE(r) << "search_fields failed";
    ASSERT_EQ(r->hits.size(), 1u);
    EXPECT_EQ(r->hits[0].ord, 0u);  // doc1 是第一个写入，ord=0

    // body:apple 只命中 doc2。
    auto r2 = (*c)->search_fields("body:apple", 10);
    ASSERT_TRUE(r2);
    ASSERT_EQ(r2->hits.size(), 1u);
    EXPECT_EQ(r2->hits[0].ord, 1u);

    (*c)->close();
}

TEST_F(CaskDocValueTest, SearchTextEmptyAfterRemove) {
    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig sl_cfg;
    sl_cfg.analyzer_config.type = AnalyzerType::Ngram;
    sl_cfg.analyzer_config.min_n = 2;
    sl_cfg.analyzer_config.max_n = 3;
    opts.search_config = sl_cfg;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'k'}};
    std::vector<std::byte> val{std::byte{'h'}, std::byte{'e'}, std::byte{'l'}, std::byte{'l'}, std::byte{'o'}};

    ASSERT_TRUE((*c)->put(key, val, 1000));
    ASSERT_TRUE((*c)->remove(key, 2000));

    auto sr = (*c)->search_text("hello", /*k*/ 10);
    ASSERT_TRUE(sr);
    EXPECT_EQ(sr->hits.size(), 0u);

    (*c)->close();
}

// === Merge + Search 集成测试 ===

class CaskMergeSearchTest : public ::testing::Test {
protected:
    void SetUp() override {
        tmpdir_ = std::filesystem::temp_directory_path() /
            ("bitcask_merge_search_" + std::string(::testing::UnitTest::GetInstance()->current_test_info()->name()));
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
        std::filesystem::create_directories(tmpdir_, ec);
    }

    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
    }

    std::filesystem::path tmpdir_;

    CaskOptions make_search_opts() {
        CaskOptions opts;
        opts.read_write = true;
        opts.enable_search = true;
        SearchLayerConfig sl_cfg;
        sl_cfg.analyzer_config.type = AnalyzerType::Ngram;
        sl_cfg.analyzer_config.min_n = 2;
        sl_cfg.analyzer_config.max_n = 3;
        opts.search_config = sl_cfg;
        return opts;
    }
};

TEST_F(CaskMergeSearchTest, SearchSurvivesMerge) {
    auto opts = make_search_opts();
    opts.max_file_size = 32;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key_a{std::byte{'a'}};
    std::vector<std::byte> val_hello{std::byte{'h'}, std::byte{'e'}, std::byte{'l'}, std::byte{'l'}, std::byte{'o'}};

    // max_file_size=32 且每条约 35 字节（23 header + 1 key + ~11 DocValue），
    // 每次 put 都会触发文件滚动
    ASSERT_TRUE((*c)->put(key_a, val_hello, 1000));

    auto sr = (*c)->search_text("hello", 10);
    ASSERT_TRUE(sr);
    ASSERT_EQ(sr->hits.size(), 1u);

    // 关闭后重新打开，恢复 SearchLayer
    (*c)->close();
    c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    sr = (*c)->search_text("hello", 10);
    ASSERT_TRUE(sr);
    ASSERT_EQ(sr->hits.size(), 1u);
    auto ord_before = sr->hits[0].ord;

    // 收集 data file 路径并显式传给 merge
    std::vector<std::string> files;
    for (const auto& entry : std::filesystem::directory_iterator(tmpdir_)) {
        auto name = entry.path().filename().string();
        if (name.ends_with(".bitcask.data")) {
            files.push_back(entry.path().string());
        }
    }
    ASSERT_GE(files.size(), 1u);

    auto mr = (*c)->merge(files, 3000);
    ASSERT_TRUE(mr) << "merge failed: " << mr.error().detail;
    EXPECT_GT(mr->records_kept, 0u);

    // merge 后搜索结果不变（ord 保留）
    auto sr2 = (*c)->search_text("hello", 10);
    ASSERT_TRUE(sr2);
    ASSERT_EQ(sr2->hits.size(), 1u);
    EXPECT_EQ(sr2->hits[0].ord, ord_before);

    // get 仍然正确
    auto gr = (*c)->get(key_a);
    ASSERT_TRUE(gr);
    EXPECT_EQ(gr->value, val_hello);

    (*c)->close();
}

TEST_F(CaskMergeSearchTest, MergeWithMultipleKeysAndSearch) {
    auto opts = make_search_opts();
    opts.max_file_size = 256;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> k1{std::byte{'x'}};
    std::vector<std::byte> k2{std::byte{'y'}};
    std::vector<std::byte> v_cat{std::byte{'c'}, std::byte{'a'}, std::byte{'t'}};
    std::vector<std::byte> v_dog{std::byte{'d'}, std::byte{'o'}, std::byte{'g'}};

    ASSERT_TRUE((*c)->put(k1, v_cat, 1000));
    ASSERT_TRUE((*c)->put(k2, v_dog, 1001));

    // merge
    auto mr = (*c)->merge({}, 2000);
    ASSERT_TRUE(mr);

    // 搜索 "cat" 和 "dog" 都能找到
    auto sr_cat = (*c)->search_text("cat", 10);
    ASSERT_TRUE(sr_cat);
    EXPECT_EQ(sr_cat->hits.size(), 1u);

    auto sr_dog = (*c)->search_text("dog", 10);
    ASSERT_TRUE(sr_dog);
    EXPECT_EQ(sr_dog->hits.size(), 1u);

    // ord 保持不同
    EXPECT_NE(sr_cat->hits[0].ord, sr_dog->hits[0].ord);

    (*c)->close();
}

TEST_F(CaskMergeSearchTest, MergeEliminatesDeletedDocs) {
    auto opts = make_search_opts();
    opts.max_file_size = 256;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'z'}};
    std::vector<std::byte> val{std::byte{'w'}, std::byte{'o'}, std::byte{'r'}, std::byte{'l'}, std::byte{'d'}};

    ASSERT_TRUE((*c)->put(key, val, 1000));

    auto sr1 = (*c)->search_text("world", 10);
    ASSERT_TRUE(sr1);
    EXPECT_EQ(sr1->hits.size(), 1u);

    // 删除后搜索为空
    ASSERT_TRUE((*c)->remove(key, 2000));
    auto sr2 = (*c)->search_text("world", 10);
    ASSERT_TRUE(sr2);
    EXPECT_EQ(sr2->hits.size(), 0u);

    // merge 后搜索仍然为空（不恢复已删除的文档）
    auto mr = (*c)->merge({}, 3000);
    ASSERT_TRUE(mr);

    auto sr3 = (*c)->search_text("world", 10);
    ASSERT_TRUE(sr3);
    EXPECT_EQ(sr3->hits.size(), 0u);

    (*c)->close();
}

TEST_F(CaskMergeSearchTest, MergeUpdatesOverwrittenKey) {
    auto opts = make_search_opts();
    opts.max_file_size = 256;

    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);

    std::vector<std::byte> key{std::byte{'m'}};
    std::vector<std::byte> val_old{std::byte{'o'}, std::byte{'l'}, std::byte{'d'}};
    std::vector<std::byte> val_new{std::byte{'n'}, std::byte{'e'}, std::byte{'w'}};

    ASSERT_TRUE((*c)->put(key, val_old, 1000));
    ASSERT_TRUE((*c)->put(key, val_new, 1001));

    // 搜索只找到 "new"
    auto sr = (*c)->search_text("new", 10);
    ASSERT_TRUE(sr);
    EXPECT_EQ(sr->hits.size(), 1u);

    // merge 后仍然只找到 "new"
    auto mr = (*c)->merge({}, 2000);
    ASSERT_TRUE(mr);

    auto sr2 = (*c)->search_text("new", 10);
    ASSERT_TRUE(sr2);
    EXPECT_EQ(sr2->hits.size(), 1u);

    // "old" 不应该找到
    auto sr_old = (*c)->search_text("old", 10);
    ASSERT_TRUE(sr_old);
    EXPECT_EQ(sr_old->hits.size(), 0u);

    (*c)->close();
}

class CaskUpgradeTest : public ::testing::Test {
protected:
    void SetUp() override {
        tmpdir_ = std::filesystem::temp_directory_path() /
                  ("cask_upgrade_test_" + std::to_string(::getpid()));
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
        std::filesystem::create_directories(tmpdir_, ec);
    }

    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(tmpdir_, ec);
    }

    std::filesystem::path tmpdir_;
};

TEST_F(CaskUpgradeTest, UpgradeKVToIndex) {
    auto bytes = [](std::string_view s) {
        return std::vector<std::byte>(
            reinterpret_cast<const std::byte*>(s.data()),
            reinterpret_cast<const std::byte*>(s.data()) + s.size());
    };

    {
        CaskOptions opts;
        opts.read_write = true;
        auto c = Cask::open(tmpdir_.string(), opts);
        ASSERT_TRUE(c);

        auto k1 = bytes("key1");
        auto v1 = bytes("hello world");
        auto r1 = (*c)->put(k1, v1);
        ASSERT_TRUE(r1);

        auto k2 = bytes("key2");
        auto v2 = bytes("hello again");
        auto r2 = (*c)->put(k2, v2);
        ASSERT_TRUE(r2);

        (*c)->close();
    }

    SearchLayerConfig search_cfg;
    search_cfg.analyzer_config.type = AnalyzerType::Ngram;
    search_cfg.analyzer_config.min_n = 2;
    search_cfg.analyzer_config.max_n = 3;
    auto upg = Cask::upgrade(tmpdir_.string(), search_cfg);
    ASSERT_TRUE(upg) << "upgrade failed";

    auto sr = (*upg)->search_text("hello", 10);
    ASSERT_TRUE(sr);
    EXPECT_EQ(sr->hits.size(), 2u);

    auto g1 = (*upg)->get(bytes("key1"));
    ASSERT_TRUE(g1);
    EXPECT_EQ(g1->value, bytes("hello world"));

    (*upg)->close();

    {
        CaskOptions opts;
        opts.read_write = true;
        opts.enable_search = true;
        opts.search_config = search_cfg;
        auto c = Cask::open(tmpdir_.string(), opts);
        ASSERT_TRUE(c);

        auto sr2 = (*c)->search_text("hello", 10);
        ASSERT_TRUE(sr2);
        EXPECT_EQ(sr2->hits.size(), 2u);

        (*c)->close();
    }
}

TEST_F(CaskUpgradeTest, UpgradeFailsOnNonexistentDir) {
    SearchLayerConfig search_cfg;
    search_cfg.analyzer_config.type = AnalyzerType::Ngram;
    auto upg = Cask::upgrade("/tmp/no_such_bitcask_dir_12345", search_cfg);
    EXPECT_FALSE(upg);
}

TEST_F(CaskUpgradeTest, UpgradeFailsOnAlreadyIndexMode) {
    auto bytes = [](std::string_view s) {
        return std::vector<std::byte>(
            reinterpret_cast<const std::byte*>(s.data()),
            reinterpret_cast<const std::byte*>(s.data()) + s.size());
    };

    CaskOptions opts;
    opts.read_write = true;
    opts.enable_search = true;
    SearchLayerConfig search_cfg;
    search_cfg.analyzer_config.type = AnalyzerType::Ngram;
    opts.search_config = search_cfg;
    auto c = Cask::open(tmpdir_.string(), opts);
    ASSERT_TRUE(c);
    (*c)->put(bytes("k"), bytes("v"));
    (*c)->close();

    auto upg = Cask::upgrade(tmpdir_.string(), search_cfg);
    EXPECT_FALSE(upg);
}

TEST_F(CaskUpgradeTest, UpgradePreservesDeletes) {
    auto bytes = [](std::string_view s) {
        return std::vector<std::byte>(
            reinterpret_cast<const std::byte*>(s.data()),
            reinterpret_cast<const std::byte*>(s.data()) + s.size());
    };

    {
        CaskOptions opts;
        opts.read_write = true;
        auto c = Cask::open(tmpdir_.string(), opts);
        ASSERT_TRUE(c);

        (*c)->put(bytes("keep"), bytes("kept value"));
        (*c)->put(bytes("remove"), bytes("removed value"));
        (*c)->remove(bytes("remove"));
        (*c)->close();
    }

    SearchLayerConfig search_cfg;
    search_cfg.analyzer_config.type = AnalyzerType::Ngram;
    search_cfg.analyzer_config.min_n = 2;
    search_cfg.analyzer_config.max_n = 3;
    auto upg = Cask::upgrade(tmpdir_.string(), search_cfg);
    ASSERT_TRUE(upg);

    auto g_keep = (*upg)->get(bytes("keep"));
    ASSERT_TRUE(g_keep);

    auto g_rm = (*upg)->get(bytes("remove"));
    EXPECT_FALSE(g_rm);

    auto sr = (*upg)->search_text("kept", 10);
    ASSERT_TRUE(sr);
    EXPECT_EQ(sr->hits.size(), 1u);

    auto sr_rm = (*upg)->search_text("removed", 10);
    ASSERT_TRUE(sr_rm);
    EXPECT_EQ(sr_rm->hits.size(), 0u);

    (*upg)->close();
}

// --- #1: FieldSchema 注册表 ---

// intern 确定性：同名同 id、新名递增；name_of 反查。
TEST(FieldSchema, InternDeterministicAndReverseLookup) {
    namespace fs = std::filesystem;
    auto path = (fs::temp_directory_path() / "bitcask_fieldschema_a.schema").string();
    fs::remove(path);

    bitcask::FieldSchema s;
    ASSERT_TRUE(s.open(path));

    auto title = s.intern("title");
    auto body  = s.intern("body");
    EXPECT_EQ(title, 0u);
    EXPECT_EQ(body, 1u);
    EXPECT_EQ(s.intern("title"), title);  // 幂等
    EXPECT_EQ(s.intern("body"), body);
    EXPECT_EQ(s.size(), 2u);

    EXPECT_EQ(s.name_of(0u), std::optional<std::string>("title"));
    EXPECT_EQ(s.name_of(1u), std::optional<std::string>("body"));
    EXPECT_EQ(s.name_of(99u), std::nullopt);

    fs::remove(path);
}

// 持久化：重开后 name↔id 映射不变（append-only 重放）。
TEST(FieldSchema, PersistsAcrossReopen) {
    namespace fs = std::filesystem;
    auto path = (fs::temp_directory_path() / "bitcask_fieldschema_b.schema").string();
    fs::remove(path);

    {
        bitcask::FieldSchema s;
        ASSERT_TRUE(s.open(path));
        EXPECT_EQ(s.intern("alpha"), 0u);
        EXPECT_EQ(s.intern("beta"), 1u);
        EXPECT_EQ(s.intern("gamma"), 2u);
    }
    {
        bitcask::FieldSchema s2;
        ASSERT_TRUE(s2.open(path));
        EXPECT_EQ(s2.size(), 3u);
        EXPECT_EQ(s2.intern("alpha"), 0u);   // 旧名字 id 不变
        EXPECT_EQ(s2.intern("beta"), 1u);
        EXPECT_EQ(s2.intern("delta"), 3u);   // 新名字接着分配
        EXPECT_EQ(s2.name_of(2u), std::optional<std::string>("gamma"));
    }
    fs::remove(path);
}

}  // namespace
