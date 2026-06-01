#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/jieba_analyzer.hpp"

using namespace bitcask::text;

namespace {

// cppjieba 词典目录：由 CMake 通过 BITCASK_JIEBA_DICT_DIR 注入真实路径
// （指向 _deps/cppjieba-src/dict）。未经 CMake 直接编译时回退到相对路径。
#ifndef BITCASK_JIEBA_DICT_DIR
#define BITCASK_JIEBA_DICT_DIR "_deps/cppjieba-src/dict"
#endif
const char* kDictDir = BITCASK_JIEBA_DICT_DIR;

}  // namespace

TEST(JiebaAnalyzer, ChineseSegmentation) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("我来到北京邮电大学");

    EXPECT_NE(tfs.find("北京"), tfs.end());
    EXPECT_NE(tfs.find("邮电"), tfs.end());
    EXPECT_NE(tfs.find("大学"), tfs.end());
    EXPECT_NE(tfs.find("北京邮电大学"), tfs.end());
}

TEST(JiebaAnalyzer, CutForSearchSplitsLongWords) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("他来自清华大学");

    EXPECT_NE(tfs.find("清华"), tfs.end());
    EXPECT_NE(tfs.find("大学"), tfs.end());
    EXPECT_NE(tfs.find("清华大学"), tfs.end());
}

TEST(JiebaAnalyzer, LatinPreserved) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("hello world");

    EXPECT_NE(tfs.find("hello"), tfs.end());
    EXPECT_NE(tfs.find("world"), tfs.end());
}

TEST(JiebaAnalyzer, EmptyInput) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("");
    EXPECT_TRUE(tfs.empty());
}

TEST(JiebaAnalyzer, PunctuationSkipped) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("你好，世界！");

    EXPECT_NE(tfs.find("你好"), tfs.end());
    EXPECT_NE(tfs.find("世界"), tfs.end());
}

TEST(JiebaAnalyzer, StopWordsEnabled) {
    JiebaAnalyzer a(kDictDir, 2, 3, true, {});
    auto tfs = a.analyze("这是一个测试");

    EXPECT_EQ(tfs.find("是"), tfs.end());
    EXPECT_NE(tfs.find("测试"), tfs.end());
}

TEST(JiebaAnalyzer, TypeIsJieba) {
    JiebaAnalyzer a(kDictDir);
    EXPECT_EQ(a.type(), AnalyzerType::Jieba);
}

TEST(JiebaAnalyzer, AnalyzeWithPositionsReturnsPositions) {
    JiebaAnalyzer a(kDictDir);
    auto tpm = a.analyze_with_positions("北京上海");

    EXPECT_NE(tpm.find("北京"), tpm.end());
    EXPECT_NE(tpm.find("上海"), tpm.end());

    auto& [tf_bj, pos_bj] = tpm.at("北京");
    EXPECT_GE(tf_bj, 1u);
    EXPECT_FALSE(pos_bj.empty());
}

TEST(AnalyzerFactory, CreateJieba) {
    auto a = AnalyzerFactory::create(AnalyzerConfig{
        .type = AnalyzerType::Jieba,
        .dict_path = kDictDir,
    });
    ASSERT_TRUE(a);
    EXPECT_EQ(a->type(), AnalyzerType::Jieba);

    auto tfs = a->analyze("南京市长江大桥");
    EXPECT_NE(tfs.find("南京"), tfs.end());
    EXPECT_NE(tfs.find("大桥"), tfs.end());
}

TEST(JiebaAnalyzer, JapaneseFallbackNgram) {
    // jieba 词典不覆盖日文，应回退到 n-gram。
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("東京タワー");

    // bi-gram 回退应产出"東京"等
    EXPECT_NE(tfs.find("東京"), tfs.end());
}
