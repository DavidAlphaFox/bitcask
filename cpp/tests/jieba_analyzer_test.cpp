#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/jieba_analyzer.hpp"
#include "bitcask/text_utils.hpp"

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

// 回归 S9.9：jieba 路径 analyze_with_offsets 此前把所有 byte offset 填成 0，
// 导致 jieba 分词的文档高亮永远生成不出片段。修复后应产出真实的、相对
// 归一化文本的字节区间，且区间切出的子串精确等于 term。
TEST(JiebaAnalyzer, OffsetsAreRealNotZero) {
    JiebaAnalyzer a(kDictDir);
    std::string text = "北京大学很有名";
    auto norm = detail::nfkc_fold(text);
    auto ttm = a.analyze_with_offsets(text);

    ASSERT_FALSE(ttm.empty());
    std::size_t checked = 0;
    for (auto& [term, infos] : ttm) {
        for (auto& info : infos) {
            // 修复后：CJK token 必有非零区间。
            ASSERT_GT(info.end_byte, info.start_byte) << "term=" << term;
            ASSERT_LE(info.end_byte, norm.size());
            // 区间切出的子串必须等于 term（offset 落在正确坐标系）。
            EXPECT_EQ(norm.substr(info.start_byte, info.end_byte - info.start_byte), term);
            ++checked;
        }
    }
    EXPECT_GT(checked, 0u);
}

// 回归 S9.26：jieba CutForSearch 会把空格也输出为词，不应进索引。
TEST(JiebaAnalyzer, SpaceNotIndexedAsToken) {
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("北京大学 hello world 上海");
    EXPECT_EQ(tfs.find(" "), tfs.end());        // 空格不应成为 term
    EXPECT_NE(tfs.find("hello"), tfs.end());    // 真实词保留
    EXPECT_NE(tfs.find("北京"), tfs.end());
}

TEST(JiebaAnalyzer, JapaneseFallbackNgram) {
    // jieba 词典不覆盖日文，应回退到 n-gram。
    JiebaAnalyzer a(kDictDir);
    auto tfs = a.analyze("東京タワー");

    // bi-gram 回退应产出"東京"等
    EXPECT_NE(tfs.find("東京"), tfs.end());
}
