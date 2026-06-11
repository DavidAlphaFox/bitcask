#include <gtest/gtest.h>

#include "bitcask/analyzer.hpp"
#include "bitcask/text_utils.hpp"
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

// S9.8：min_token_length 过滤短拉丁词。
TEST(WhitespaceAnalyzer, MinTokenLengthFiltersShortLatin) {
    WhitespaceAnalyzer a(3);
    auto tfs = a.analyze("a of cat hello");
    EXPECT_EQ(tfs.find("a"), tfs.end());     // 1 codepoint → 过滤
    EXPECT_EQ(tfs.find("of"), tfs.end());    // 2 → 过滤
    EXPECT_NE(tfs.find("cat"), tfs.end());   // 3 → 保留
    EXPECT_NE(tfs.find("hello"), tfs.end()); // 5 → 保留
}

// S9.8：默认 min_token_length=1 不过滤（向后兼容）。
TEST(WhitespaceAnalyzer, DefaultKeepsShortTokens) {
    WhitespaceAnalyzer a;
    auto tfs = a.analyze("a of cat");
    EXPECT_NE(tfs.find("a"), tfs.end());
    EXPECT_NE(tfs.find("of"), tfs.end());
    EXPECT_NE(tfs.find("cat"), tfs.end());
}

// S9.8 关键：min_token_length 只作用于拉丁整词，CJK n-gram 不受影响。
// 否则 min>=2/3 会删光中文 bi-gram 索引。
TEST(NgramAnalyzer, MinTokenLengthDoesNotAffectCjkNgrams) {
    NgramAnalyzer a(2, 3, false, {}, 3);  // min_token_length=3
    auto tfs = a.analyze("北京 a of");
    EXPECT_NE(tfs.find("北京"), tfs.end());  // CJK bi-gram（2 codepoint）必须保留
    EXPECT_EQ(tfs.find("a"), tfs.end());     // 拉丁短词过滤
    EXPECT_EQ(tfs.find("of"), tfs.end());
}

// =========================================================================
// P2.5：nfkc_fold ASCII 快路径语义对拍
// =========================================================================

TEST(NfkcFold, AsciiFastPathEqualsLowercase) {
    using bitcask::text::detail::nfkc_fold;
    EXPECT_EQ(nfkc_fold("Hello, World! 123"), "hello, world! 123");
    EXPECT_EQ(nfkc_fold("ABCxyz"), "abcxyz");
    EXPECT_EQ(nfkc_fold("already lower"), "already lower");
    EXPECT_EQ(nfkc_fold(""), "");
    // 全部 ASCII 可打印字符：除 A-Z 外不变。
    std::string all;
    for (char c = 0x20; c < 0x7F; ++c) all.push_back(c);
    auto folded = nfkc_fold(all);
    ASSERT_EQ(folded.size(), all.size());
    for (std::size_t i = 0; i < all.size(); ++i) {
        char expect = (all[i] >= 'A' && all[i] <= 'Z')
                          ? static_cast<char>(all[i] - 'A' + 'a') : all[i];
        EXPECT_EQ(folded[i], expect) << "i=" << i;
    }
}

TEST(NfkcFold, NonAsciiPathUnchanged) {
    using bitcask::text::detail::nfkc_fold;
    // 全角 → 半角 + casefold（NFKC_Casefold 经典行为，走 utf8proc 路径）。
    EXPECT_EQ(nfkc_fold("ＨＥＬＬＯ"), "hello");
    EXPECT_EQ(nfkc_fold("Ｃａｆé"), "café");
    EXPECT_EQ(nfkc_fold("北京"), "北京");
    // 混合（含非 ASCII → 整串走 utf8proc，ASCII 部分行为一致）。
    EXPECT_EQ(nfkc_fold("Hello北京World"), "hello北京world");
}

TEST(ToCodepoints, AsciiFastPathOffsets) {
    using bitcask::text::detail::to_codepoints;
    auto cps = to_codepoints("a北b");
    ASSERT_EQ(cps.size(), 3u);
    EXPECT_EQ(cps[0].cp, U'a');
    EXPECT_EQ(cps[0].byte_off, 0u);
    EXPECT_EQ(cps[0].byte_len, 1u);
    EXPECT_EQ(cps[1].cp, U'北');
    EXPECT_EQ(cps[1].byte_off, 1u);
    EXPECT_EQ(cps[1].byte_len, 3u);
    EXPECT_EQ(cps[2].cp, U'b');
    EXPECT_EQ(cps[2].byte_off, 4u);
    EXPECT_EQ(cps[2].byte_len, 1u);
}

// =========================================================================
// P2.5b：CJK 恒等快路径
// =========================================================================

namespace {
// UTF-8 编码单码点（测试辅助）。
std::string encode_utf8(char32_t cp) {
    std::string s;
    if (cp < 0x80) {
        s.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        s.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        s.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        s.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        s.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
    return s;
}

// 旧实现等价的 utf8proc oracle（绕过快路径）。
std::string nfkc_oracle(std::string_view input) {
    if (input.empty()) return {};
    std::string owned(input);
    auto* out = utf8proc_NFKC_Casefold(
        reinterpret_cast<const utf8proc_uint8_t*>(owned.c_str()));
    if (out == nullptr) return {};
    std::string r(reinterpret_cast<const char*>(out),
                  std::strlen(reinterpret_cast<const char*>(out)));
    std::free(out);
    return r;
}
}  // namespace

// 表成员穷举验证：nfkc_casefold_inert 标记的每个码点，经 utf8proc
// NFKC_Casefold 后必须逐字节不变。表与 Unicode 数据不符即此测试红。
TEST(NfkcInert, TableOracleExhaustive) {
    using bitcask::text::detail::nfkc_casefold_inert;
    std::size_t checked = 0;
    for (char32_t cp = 0x80; cp <= 0xFFFF; ++cp) {
        if (!nfkc_casefold_inert(cp)) continue;
        auto u = encode_utf8(cp);
        ASSERT_EQ(nfkc_oracle(u), u) << "cp=U+" << std::hex << static_cast<int>(cp);
        ++checked;
    }
    EXPECT_GT(checked, 27000u);  // CJK 基本区+扩展 A+标点
}

// 黑盒对拍：从「表成员 ∪ 回退字符」混合字母表生成随机串，
// nfkc_fold（含快路径）必须与 utf8proc oracle 逐串一致。
TEST(NfkcInert, RandomizedAgainstOracle) {
    using bitcask::text::detail::nfkc_fold;
    const std::string alphabet[] = {
        "中", "文", "搜", "索", "引", "擎",          // 快路径成员
        "a", "B", "z", "9", " ", ",", ".",           // ASCII（含大写）
        "、", "。", "《", "》", "—",                  // 恒等标点
        "，", "！", "Ａ", "…", "é", "　",             // 回退触发（全角/分解/附标）
    };
    std::uint64_t seed = 23;
    auto next = [&seed] {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return seed >> 33;
    };
    for (int iter = 0; iter < 3000; ++iter) {
        std::string s;
        auto n = next() % 24;
        for (std::uint64_t i = 0; i < n; ++i) {
            s += alphabet[next() % (sizeof(alphabet) / sizeof(alphabet[0]))];
        }
        ASSERT_EQ(nfkc_fold(s), nfkc_oracle(s)) << "s=" << s;
    }
}

// 定向用例：目标语料形态命中快路径；全角标点正确回退折叠。
TEST(NfkcInert, TargetedCases) {
    using bitcask::text::detail::nfkc_fold;
    EXPECT_EQ(nfkc_fold("北京GPU加速测试, 性能提升."),
              "北京gpu加速测试, 性能提升.");
    EXPECT_EQ(nfkc_fold("中文iPhone测试"), "中文iphone测试");
    EXPECT_EQ(nfkc_fold("《标题》、正文。"), "《标题》、正文。");
    EXPECT_EQ(nfkc_fold("全角，逗号"), "全角,逗号");      // 回退路径折叠
    EXPECT_EQ(nfkc_fold("ＧＰＵ测试"), "gpu测试");        // 全角字母回退折叠
}
