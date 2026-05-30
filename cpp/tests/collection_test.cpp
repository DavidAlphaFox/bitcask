// End-to-end tests for Collection (upsert/get/remove + recovery). V1.

#include <unistd.h>

#include <filesystem>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/collection.hpp"

using bitcask::Collection;
using bitcask::CollectionError;
using bitcask::CollectionOptions;
using bitcask::DocInput;
using bitcask::TextHit;

namespace fs = std::filesystem;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_coll_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string str() const { return path_.string(); }
private:
    fs::path path_;
};

DocInput text_doc(std::string_view t) {
    DocInput d;
    d.text = t;
    return d;
}

}  // namespace

TEST(Collection, UpsertGetTextAndVector) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    std::vector<float> vec = {1.0f, 2.0f, 3.0f};
    DocInput in;
    in.text = "美联储宣布降息";
    in.vector = std::span<const float>(vec);
    ASSERT_TRUE((*c)->upsert("news-1", in));

    auto got = (*c)->get("news-1");
    ASSERT_TRUE(got);
    EXPECT_TRUE(got->has_text);
    EXPECT_EQ(got->text, "美联储宣布降息");
    ASSERT_TRUE(got->has_vector);
    ASSERT_EQ(got->vector.size(), 3u);
    EXPECT_FLOAT_EQ(got->vector[0], 1.0f);
    EXPECT_FLOAT_EQ(got->vector[2], 3.0f);
    EXPECT_FALSE(got->has_meta);
}

TEST(Collection, GetMissingIsNotFound) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);
    auto got = (*c)->get("nope");
    ASSERT_FALSE(got);
    EXPECT_EQ(got.error().kind, CollectionError::kNotFound);
}

TEST(Collection, UpdateReturnsLatest) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->upsert("k", text_doc("v1")));
    ASSERT_TRUE((*c)->upsert("k", text_doc("v2")));
    auto got = (*c)->get("k");
    ASSERT_TRUE(got);
    EXPECT_EQ(got->text, "v2");
    EXPECT_EQ((*c)->info().live_docs, 1u);
}

TEST(Collection, RemoveThenNotFound) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);
    ASSERT_TRUE((*c)->upsert("k", text_doc("v")));
    auto removed = (*c)->remove("k");
    ASSERT_TRUE(removed);
    EXPECT_TRUE(*removed);
    EXPECT_FALSE((*c)->get("k").has_value());

    auto removed2 = (*c)->remove("k");
    ASSERT_TRUE(removed2);
    EXPECT_FALSE(*removed2);  // 删不存在返回 false
}

TEST(Collection, WriteLockHeldRejectsSecondOpen) {
    TempDir td;
    auto c1 = Collection::open(td.str(), {});
    ASSERT_TRUE(c1);
    auto c2 = Collection::open(td.str(), {});
    ASSERT_FALSE(c2);
    EXPECT_EQ(c2.error().kind, CollectionError::kWriteLocked);
}

TEST(Collection, ReopenRecoversState) {
    TempDir td;
    {
        auto c = Collection::open(td.str(), {});
        ASSERT_TRUE(c);
        std::vector<float> v = {0.5f, 0.25f};
        DocInput a; a.text = "alpha"; a.vector = std::span<const float>(v);
        ASSERT_TRUE((*c)->upsert("a", a));
        ASSERT_TRUE((*c)->upsert("b", text_doc("bravo")));
        ASSERT_TRUE((*c)->upsert("a", text_doc("alpha-v2")));  // update
        ASSERT_TRUE((*c)->upsert("c", text_doc("charlie")));
        ASSERT_TRUE((*c)->remove("b"));                         // delete
        ASSERT_TRUE((*c)->sync());
        (*c)->close();
    }

    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);
    // a: latest version after update
    auto a = (*c)->get("a");
    ASSERT_TRUE(a);
    EXPECT_EQ(a->text, "alpha-v2");
    EXPECT_FALSE(a->has_vector);   // v2 had no vector
    // b: deleted
    EXPECT_FALSE((*c)->get("b").has_value());
    // c: present
    auto cc = (*c)->get("c");
    ASSERT_TRUE(cc);
    EXPECT_EQ(cc->text, "charlie");

    EXPECT_EQ((*c)->info().live_docs, 2u);  // a, c
}

TEST(Collection, FileRollAcrossManyDocsSurvivesReopen) {
    TempDir td;
    CollectionOptions opts;
    opts.max_file_size = 256;  // force frequent rolls
    {
        auto c = Collection::open(td.str(), opts);
        ASSERT_TRUE(c);
        for (int i = 0; i < 50; ++i) {
            ASSERT_TRUE((*c)->upsert("key-" + std::to_string(i),
                                     text_doc("value-" + std::to_string(i))));
        }
        (*c)->close();
    }
    auto c = Collection::open(td.str(), opts);
    ASSERT_TRUE(c);
    for (int i = 0; i < 50; ++i) {
        auto g = (*c)->get("key-" + std::to_string(i));
        ASSERT_TRUE(g) << "missing key-" << i;
        EXPECT_EQ(g->text, "value-" + std::to_string(i));
    }
    EXPECT_EQ((*c)->info().live_docs, 50u);
}

// ===========================================================================
// search_text 端到端
// ===========================================================================

TEST(Collection, SearchTextChineseRanking) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->upsert("d1", text_doc("北京市朝阳区")));
    ASSERT_TRUE((*c)->upsert("d2", text_doc("上海浦东新区")));
    ASSERT_TRUE((*c)->upsert("d3", text_doc("北京人在上海")));

    auto result = (*c)->search_text("北京", 10);
    ASSERT_TRUE(result) << "search_text failed";
    auto& hits = *result;

    ASSERT_GE(hits.size(), 2u);

    std::vector<std::string> ids;
    for (auto& h : hits) ids.push_back(h.ext_id);
    EXPECT_NE(std::find(ids.begin(), ids.end(), "d1"), ids.end());
    EXPECT_NE(std::find(ids.begin(), ids.end(), "d3"), ids.end());
    EXPECT_EQ(std::find(ids.begin(), ids.end(), "d2"), ids.end());
}

TEST(Collection, SearchTextLatinCaseInsensitive) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->upsert("e1", text_doc("Hello World")));
    ASSERT_TRUE((*c)->upsert("e2", text_doc("Quick Fox")));
    ASSERT_TRUE((*c)->upsert("e3", text_doc("Hello Earth")));

    auto result = (*c)->search_text("hello", 10);
    ASSERT_TRUE(result);
    auto& hits = *result;

    ASSERT_GE(hits.size(), 2u);
    std::vector<std::string> ids;
    for (auto& h : hits) ids.push_back(h.ext_id);
    EXPECT_NE(std::find(ids.begin(), ids.end(), "e1"), ids.end());
    EXPECT_NE(std::find(ids.begin(), ids.end(), "e3"), ids.end());
}

TEST(Collection, SearchTextAfterDelete) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->upsert("keep", text_doc("北京天安门")));
    ASSERT_TRUE((*c)->upsert("del",  text_doc("北京故宫")));
    ASSERT_TRUE((*c)->remove("del"));

    auto result = (*c)->search_text("北京", 10);
    ASSERT_TRUE(result);
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).ext_id, "keep");
}

TEST(Collection, SearchTextSurvivesReopen) {
    TempDir td;
    {
        auto c = Collection::open(td.str(), {});
        ASSERT_TRUE(c);
        ASSERT_TRUE((*c)->upsert("a", text_doc("北京天安门广场")));
        ASSERT_TRUE((*c)->upsert("b", text_doc("上海外滩夜景")));
        ASSERT_TRUE((*c)->sync());
        (*c)->close();
    }

    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    auto result = (*c)->search_text("北京", 10);
    ASSERT_TRUE(result);
    ASSERT_EQ(result->size(), 1u);
    EXPECT_EQ(result->at(0).ext_id, "a");
}

TEST(Collection, SearchTextNoMatchReturnsEmpty) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->upsert("x", text_doc("上海浦东")));

    auto result = (*c)->search_text("不存在", 10);
    ASSERT_TRUE(result);
    EXPECT_TRUE(result->empty());
}

TEST(Collection, SearchTextEmptyQueryReturnsEmpty) {
    TempDir td;
    auto c = Collection::open(td.str(), {});
    ASSERT_TRUE(c);

    ASSERT_TRUE((*c)->upsert("x", text_doc("test")));
    auto result = (*c)->search_text("", 10);
    ASSERT_TRUE(result);
    EXPECT_TRUE(result->empty());
}
