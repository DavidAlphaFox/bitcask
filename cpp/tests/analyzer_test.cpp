#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/cjk_detect.hpp"
#include "bitcask/ngram_analyzer.hpp"
#include "bitcask/whitespace_analyzer.hpp"

using namespace bitcask::text;
using detail::is_cjk;

// ===========================================================================
// CJK Detection
// ===========================================================================

TEST(CjkDetect, BasicHan) {
    EXPECT_TRUE(is_cjk(U'中'));
    EXPECT_TRUE(is_cjk(U'文'));
    EXPECT_TRUE(is_cjk(U'京'));
}

TEST(CjkDetect, Hangul) {
    EXPECT_TRUE(is_cjk(U'한'));
    EXPECT_TRUE(is_cjk(U'국'));
}

TEST(CjkDetect, HiraganaKatakana) {
    EXPECT_TRUE(is_cjk(U'あ'));   // Hiragana
    EXPECT_TRUE(is_cjk(U'ア'));   // Katakana
}

TEST(CjkDetect, LatinNotCjk) {
    EXPECT_FALSE(is_cjk(U'A'));
    EXPECT_FALSE(is_cjk(U'z'));
    EXPECT_FALSE(is_cjk(U'0'));
}

TEST(CjkDetect, AsciiNotCjk) {
    EXPECT_FALSE(is_cjk(0x20));    // space
    EXPECT_FALSE(is_cjk(0x2E));    // '.'
}

// ===========================================================================
// AnalyzerFactory
// ===========================================================================

TEST(AnalyzerFactory, NgramDefault) {
    auto a = AnalyzerFactory::create(AnalyzerConfig{});
    ASSERT_NE(a, nullptr);
    EXPECT_EQ(a->type(), AnalyzerType::Ngram);
    auto* ng = dynamic_cast<NgramAnalyzer*>(a.get());
    ASSERT_NE(ng, nullptr);
    EXPECT_EQ(ng->min_n(), 2);
    EXPECT_EQ(ng->max_n(), 3);
}

TEST(AnalyzerFactory, Whitespace) {
    auto a = AnalyzerFactory::create(AnalyzerConfig{.type = AnalyzerType::Whitespace});
    ASSERT_NE(a, nullptr);
    EXPECT_EQ(a->type(), AnalyzerType::Whitespace);
}

TEST(AnalyzerFactory, InvalidConfigReturnsNull) {
    auto a = AnalyzerFactory::create(AnalyzerConfig{
        .type = AnalyzerType::Ngram, .min_n = 0, .max_n = 3});
    EXPECT_EQ(a, nullptr);

    a = AnalyzerFactory::create(AnalyzerConfig{
        .type = AnalyzerType::Ngram, .min_n = 5, .max_n = 2});
    EXPECT_EQ(a, nullptr);
}

// ===========================================================================
// NgramAnalyzer — CJK
// ===========================================================================

TEST(NgramAnalyzer, ChineseBigram) {
    NgramAnalyzer a(2, 2);
    auto tfs = a.analyze("北京市");

    // "北京市" (3 chars) → bigrams: "北京", "京市"
    EXPECT_EQ(tfs.size(), 2u);
    EXPECT_EQ(tfs.at("北京"), 1u);
    EXPECT_EQ(tfs.at("京市"), 1u);
}

TEST(NgramAnalyzer, ChineseBigramTrigram) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("北京市");

    // bigrams: "北京", "京市"  |  trigrams: "北京市"
    EXPECT_EQ(tfs.size(), 3u);
    EXPECT_EQ(tfs.at("北京"), 1u);
    EXPECT_EQ(tfs.at("京市"), 1u);
    EXPECT_EQ(tfs.at("北京市"), 1u);
}

TEST(NgramAnalyzer, ChineseRepeatedChar) {
    NgramAnalyzer a(2, 2);
    auto tfs = a.analyze("哈哈哈");

    // bigrams: "哈哈" x2
    EXPECT_EQ(tfs.at("哈哈"), 2u);
}

TEST(NgramAnalyzer, EmptyInput) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("");
    EXPECT_TRUE(tfs.empty());
}

TEST(NgramAnalyzer, SingleCjkChar) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("中");
    // 单个 CJK 字符无法生成 bigram（min_n=2）
    EXPECT_TRUE(tfs.empty());
}

TEST(NgramAnalyzer, CjkPunctAsSeparator) {
    NgramAnalyzer a(2, 2);
    auto tfs = a.analyze("你好，世界");

    // "，" (U+FF0C fullwidth comma) splits CJK run:
    // "你好" → bigram "你好"
    // "世界" → bigram "世界"
    EXPECT_EQ(tfs.size(), 2u);
    EXPECT_EQ(tfs.at("你好"), 1u);
    EXPECT_EQ(tfs.at("世界"), 1u);
}

// ===========================================================================
// NgramAnalyzer — Latin
// ===========================================================================

TEST(NgramAnalyzer, LatinWhitespace) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("hello world");

    EXPECT_EQ(tfs.at("hello"), 1u);
    EXPECT_EQ(tfs.at("world"), 1u);
}

TEST(NgramAnalyzer, CaseFold) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("Hello WORLD");

    EXPECT_EQ(tfs.at("hello"), 1u);
    EXPECT_EQ(tfs.at("world"), 1u);
}

TEST(NgramAnalyzer, LatinRepeated) {
    NgramAnalyzer a(2, 3);
    auto tfs = a.analyze("foo foo bar");

    EXPECT_EQ(tfs.at("foo"), 2u);
    EXPECT_EQ(tfs.at("bar"), 1u);
}

// ===========================================================================
// NgramAnalyzer — Mixed CJK + Latin
// ===========================================================================

TEST(NgramAnalyzer, MixedText) {
    NgramAnalyzer a(2, 2);
    auto tfs = a.analyze("北京hello上海");

    // CJK run "北京" → "北京", CJK run "上海" → "上海"
    // Latin "hello" → "hello"
    EXPECT_EQ(tfs.at("北京"), 1u);
    EXPECT_EQ(tfs.at("hello"), 1u);
    EXPECT_EQ(tfs.at("上海"), 1u);
}

// ===========================================================================
// WhitespaceAnalyzer
// ===========================================================================

TEST(WhitespaceAnalyzer, Basic) {
    WhitespaceAnalyzer a;
    auto tfs = a.analyze("hello world foo");

    EXPECT_EQ(tfs.at("hello"), 1u);
    EXPECT_EQ(tfs.at("world"), 1u);
    EXPECT_EQ(tfs.at("foo"), 1u);
}

TEST(WhitespaceAnalyzer, CaseFold) {
    WhitespaceAnalyzer a;
    auto tfs = a.analyze("Hello WORLD");

    EXPECT_EQ(tfs.at("hello"), 1u);
    EXPECT_EQ(tfs.at("world"), 1u);
}

TEST(WhitespaceAnalyzer, Empty) {
    WhitespaceAnalyzer a;
    auto tfs = a.analyze("");
    EXPECT_TRUE(tfs.empty());
}

TEST(WhitespaceAnalyzer, CjkNotSegmented) {
    WhitespaceAnalyzer a;
    auto tfs = a.analyze("北京市");

    EXPECT_EQ(tfs.size(), 1u);
    EXPECT_EQ(tfs.at("北京市"), 1u);
}

// ===========================================================================
// Stop Words
// ===========================================================================

TEST(NgramAnalyzer, StopWordsDisabledByDefault) {
    NgramAnalyzer a(2, 3, false, {});
    auto tfs = a.analyze("this is a test");
    EXPECT_NE(tfs.find("this"), tfs.end());
    EXPECT_NE(tfs.find("is"), tfs.end());
}

TEST(NgramAnalyzer, StopWordsEnabledFiltersEnglish) {
    NgramAnalyzer a(2, 3, true, {});
    auto tfs = a.analyze("this is a test of the system");

    EXPECT_EQ(tfs.find("this"), tfs.end());
    EXPECT_EQ(tfs.find("is"), tfs.end());
    EXPECT_EQ(tfs.find("a"), tfs.end());
    EXPECT_EQ(tfs.find("of"), tfs.end());
    EXPECT_EQ(tfs.find("the"), tfs.end());

    EXPECT_NE(tfs.find("test"), tfs.end());
    EXPECT_NE(tfs.find("system"), tfs.end());
}

TEST(NgramAnalyzer, StopWordsFiltersChinese) {
    NgramAnalyzer a(2, 3, true, {});
    auto tfs = a.analyze("我是一个北京人");

    EXPECT_EQ(tfs.find("我"), tfs.end());
    EXPECT_EQ(tfs.find("是"), tfs.end());

    EXPECT_NE(tfs.find("北京"), tfs.end());
}

TEST(NgramAnalyzer, StopWordsCustomList) {
    NgramAnalyzer a(2, 3, true, {"bad", "term"});
    auto tfs = a.analyze("this bad term is good");

    EXPECT_EQ(tfs.find("bad"), tfs.end());
    EXPECT_EQ(tfs.find("term"), tfs.end());
    EXPECT_NE(tfs.find("this"), tfs.end());
    EXPECT_NE(tfs.find("good"), tfs.end());
}

TEST(AnalyzerFactory, StopWordsThroughConfig) {
    auto a = AnalyzerFactory::create(AnalyzerConfig{
        .type = AnalyzerType::Ngram,
        .min_n = 2,
        .max_n = 3,
        .enable_stop_words = true,
    });
    ASSERT_TRUE(a);

    auto tfs = a->analyze("the cat is on the mat");
    EXPECT_EQ(tfs.find("the"), tfs.end());
    EXPECT_EQ(tfs.find("is"), tfs.end());
    EXPECT_EQ(tfs.find("on"), tfs.end());
    EXPECT_NE(tfs.find("cat"), tfs.end());
    EXPECT_NE(tfs.find("mat"), tfs.end());
}
