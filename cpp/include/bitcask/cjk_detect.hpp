// CJK 统一汉字及关联书写系统的 Unicode 范围检测。
//
// 用于 NgramAnalyzer 判断一个 codepoint 是否属于 CJK 字符集，
// 进而决定走 n-gram 分词还是拉丁空白切分。
//
// 覆盖范围（按 Unicode 15.0）：
//   - CJK Unified Ideographs (Han)
//   - Hiragana / Katakana
//   - Hangul Syllables + Jamo
//   - CJK Compatibility Ideographs
//   - CJK Extensions A–G（含 Ext G/Supported Ideograph）
//   - 全角 ASCII / 全角标点
//   - CJK Strokes / Bopomofo
//
// 参考：https://unicode.org/charts/  各 block 边界。

#pragma once

#include <cstdint>

namespace bitcask::text::detail {

// 判断 codepoint 是否属于 CJK 相关书写系统。
// 返回 true 时该字符应走 n-gram 分词路径。
[[nodiscard]] inline bool is_cjk(char32_t cp) noexcept {
    // CJK Unified Ideographs (4E00–9FFF)
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
    // CJK Extension A (3400–4DBF)
    if (cp >= 0x3400 && cp <= 0x4DBF) return true;
    // CJK Extension B (20000–2A6DF)
    if (cp >= 0x20000 && cp <= 0x2A6DF) return true;
    // CJK Extension C (2A700–2B73F)
    if (cp >= 0x2A700 && cp <= 0x2B73F) return true;
    // CJK Extension D (2B740–2B81F)
    if (cp >= 0x2B740 && cp <= 0x2B81F) return true;
    // CJK Extension E (2B820–2CEAF)
    if (cp >= 0x2B820 && cp <= 0x2CEAF) return true;
    // CJK Extension F (2CEB0–2EBEF)
    if (cp >= 0x2CEB0 && cp <= 0x2EBEF) return true;
    // CJK Extension G (30000–3134F)
    if (cp >= 0x30000 && cp <= 0x3134F) return true;
    // CJK Compatibility Ideographs (F900–FAFF)
    if (cp >= 0xF900 && cp <= 0xFAFF) return true;
    // CJK Compatibility Supplement (2F800–2FA1F)
    if (cp >= 0x2F800 && cp <= 0x2FA1F) return true;

    // Hiragana (3040–309F)
    if (cp >= 0x3040 && cp <= 0x309F) return true;
    // Katakana (30A0–30FF)
    if (cp >= 0x30A0 && cp <= 0x30FF) return true;
    // Katakana Phonetic Extensions (31F0–31FF)
    if (cp >= 0x31F0 && cp <= 0x31FF) return true;
    // Halfwidth Katakana (FF65–FF9F)
    if (cp >= 0xFF65 && cp <= 0xFF9F) return true;

    // Hangul Syllables (AC00–D7AF)
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true;
    // Hangul Jamo (1100–11FF)
    if (cp >= 0x1100 && cp <= 0x11FF) return true;
    // Hangul Compatibility Jamo (3130–318F)
    if (cp >= 0x3130 && cp <= 0x318F) return true;
    // Hangul Jamo Extended-A (A960–A97F)
    if (cp >= 0xA960 && cp <= 0xA97F) return true;
    // Hangul Jamo Extended-B (D7B0–D7FF)
    if (cp >= 0xD7B0 && cp <= 0xD7FF) return true;

    // 全角 ASCII 变体（FF01–FF5E）不在此判 CJK：全角字母/数字语义上是 Latin，
    // 全角标点由 is_cjk_punct 处理。实际上输入到 is_cjk 前已经过 NFKC，全角已
    // 折成半角，此处拿不到 FF 段；保留说明以防未来有未归一化路径直接调 is_cjk。

    // CJK Symbols and Punctuation (3000–303F)
    if (cp >= 0x3000 && cp <= 0x303F) return true;
    // CJK Strokes (31C0–31EF)
    if (cp >= 0x31C0 && cp <= 0x31EF) return true;
    // Bopomofo (3100–312F)
    if (cp >= 0x3100 && cp <= 0x312F) return true;
    // Bopomofo Extended (31A0–31BF)
    if (cp >= 0x31A0 && cp <= 0x31BF) return true;

    return false;
}

}  // namespace bitcask::text::detail
