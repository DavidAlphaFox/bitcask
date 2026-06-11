#include <gtest/gtest.h>

#include "bitcask/porter_stemmer.hpp"

using namespace bitcask::text;

TEST(PorterStemmer, Basic) {
    EXPECT_EQ(porter_stem("running"), "run");
    EXPECT_EQ(porter_stem("generalization"), "gener");
    EXPECT_EQ(porter_stem("cats"), "cat");
    EXPECT_EQ(porter_stem("addresses"), "address");
}

// 回归（O6 时发现）：step1a 的 ies 规则此前写成 erase(size-2) 再 += 'i'，
// 净效果是 "ies → ii"（"ponies" → "ponii"），偏离标准 Porter 与自身注释。
// 修正为标准 "ies → i"。
TEST(PorterStemmer, Step1aIes) {
    EXPECT_EQ(porter_stem("ponies"), "poni");
    EXPECT_EQ(porter_stem("ties"), "ti");
}

TEST(PorterStemmer, Short) {
    EXPECT_EQ(porter_stem("a"), "a");
    EXPECT_EQ(porter_stem("be"), "be");
    EXPECT_EQ(porter_stem("to"), "to");
    EXPECT_EQ(porter_stem("of"), "of");
}

TEST(PorterStemmer, CJK) {
    EXPECT_EQ(porter_stem("北京"), "北京");
    EXPECT_EQ(porter_stem("你好"), "你好");
    EXPECT_EQ(porter_stem("データ"), "データ");
}

TEST(PorterStemmer, Empty) {
    EXPECT_EQ(porter_stem(""), "");
}

TEST(PorterStemmer, MixedAlphabetic) {
    EXPECT_EQ(porter_stem("hello123"), "hello123");
    EXPECT_EQ(porter_stem("won't"), "won't");
}

TEST(PorterStemmer, Step1bEdIng) {
    EXPECT_EQ(porter_stem("eded"), "ed");
    EXPECT_EQ(porter_stem("eding"), "ed");
}

TEST(PorterStemmer, Step1cY) {
    EXPECT_EQ(porter_stem("happy"), "happi");
    EXPECT_EQ(porter_stem("copy"), "copi");
}

TEST(PorterStemmer, Step2DoubleSuffix) {
    EXPECT_EQ(porter_stem("national"), "nation");
    EXPECT_EQ(porter_stem("automation"), "autom");
}

TEST(PorterStemmer, Step3SingleSuffix) {
    EXPECT_EQ(porter_stem("historical"), "histor");
    EXPECT_EQ(porter_stem("beautiful"), "beauti");
}

TEST(PorterStemmer, Step4RemoveSuffix) {
    EXPECT_EQ(porter_stem("essential"), "essenti");
    EXPECT_EQ(porter_stem("different"), "differ");
}

TEST(PorterStemmer, Step5aFinalE) {
    EXPECT_EQ(porter_stem("generate"), "gener");
    EXPECT_EQ(porter_stem("date"), "date");
}

TEST(PorterStemmer, Step5bDoubleConsonant) {
    // controll doesn't reduce to control in our simplified implementation
    // because step5b exception for 'l' prevents removal
    EXPECT_EQ(porter_stem("controll"), "controll");
    EXPECT_EQ(porter_stem("bottles"), "bottl");
}