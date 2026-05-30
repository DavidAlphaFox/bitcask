// 分词器工厂实现 + NgramAnalyzer / WhitespaceAnalyzer 实现。

#include "bitcask/analyzer.hpp"
#include "bitcask/cjk_detect.hpp"
#include "bitcask/ngram_analyzer.hpp"
#include "bitcask/whitespace_analyzer.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <utf8proc.h>

namespace bitcask::text {

// ===========================================================================
// 工厂
// ===========================================================================

auto AnalyzerFactory::create(const AnalyzerConfig& config)
    -> std::unique_ptr<Analyzer>
{
    switch (config.type) {
        case AnalyzerType::Ngram:
            if (config.min_n < 1 || config.max_n < config.min_n) {
                return nullptr;
            }
            return std::make_unique<NgramAnalyzer>(config.min_n, config.max_n);
        case AnalyzerType::Whitespace:
            return std::make_unique<WhitespaceAnalyzer>();
    }
    return nullptr;
}

// ===========================================================================
// 内部辅助（detail 命名空间）
// ===========================================================================

namespace detail {

struct Utf8ProcDeleter {
    void operator()(void* p) const noexcept { std::free(p); }
};
using Utf8ProcBuf = std::unique_ptr<uint8_t[], Utf8ProcDeleter>;

[[nodiscard]] std::string nfkc_fold(std::string_view input) {
    if (input.empty()) return {};

    auto* raw = reinterpret_cast<const utf8proc_uint8_t*>(input.data());
    auto* out = utf8proc_NFKC_Casefold(raw);
    if (out == nullptr) return {};

    Utf8ProcBuf guard(out);
    return std::string(reinterpret_cast<const char*>(out), std::strlen(reinterpret_cast<const char*>(out)));
}

// 从 UTF-8 字节流中解码下一个 codepoint。
// 返回 (codepoint, consumed_bytes)。遇到非法序列返回 (0xFFFD, 1)。
[[nodiscard]] std::pair<char32_t, std::size_t> decode_one(
    std::string_view sv) noexcept {
    if (sv.empty()) return {0, 0};

    auto* ptr = reinterpret_cast<const utf8proc_uint8_t*>(sv.data());
    auto len = static_cast<utf8proc_ssize_t>(sv.size());

    utf8proc_int32_t cp = 0;
    auto consumed = utf8proc_iterate(ptr, len, &cp);
    if (consumed < 0 || cp < 0) return {0xFFFD, 1};
    return {static_cast<char32_t>(cp), static_cast<std::size_t>(consumed)};
}

// 将归一化后的 UTF-8 文本拆成 codepoint 序列（用于 n-gram 滑窗）。
// 每个 codepoint 携带其在原始 UTF-8 中的字节偏移和字节长度，
// 便于后续按字节 slice 出 n-gram term。
struct CpInfo {
    char32_t    cp;
    std::size_t byte_off;   // 在归一化后字符串中的字节偏移
    std::size_t byte_len;   // 该 codepoint 的 UTF-8 字节长度
};

[[nodiscard]] std::vector<CpInfo> to_codepoints(std::string_view text) {
    std::vector<CpInfo> cps;
    cps.reserve(text.size() / 2);  // 粗估
    std::size_t off = 0;
    while (off < text.size()) {
        auto [cp, consumed] = decode_one(text.substr(off));
        if (consumed == 0) break;
        cps.push_back({cp, off, consumed});
        off += consumed;
    }
    return cps;
}

// 判断 codepoint 是否为 Unicode 空白（用于拉丁空白切分）。
[[nodiscard]] bool is_unicode_space(char32_t cp) noexcept {
    auto cat = utf8proc_category(static_cast<utf8proc_int32_t>(cp));
    if (cat == UTF8PROC_CATEGORY_ZS) return true;
    // 水平制表 / 换行 / 回车 / 垂直制表 / 换页
    if (cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0x0B || cp == 0x0C) {
        return true;
    }
    return false;
}

// 判断 codepoint 是否属于 CJK 标点（应在 n-gram 中跳过，作为分隔符）。
[[nodiscard]] bool is_cjk_punct(char32_t cp) noexcept {
    if (cp >= 0x3000 && cp <= 0x303F) return true;
    if (cp >= 0xFE30 && cp <= 0xFE4F) return true;
    if (cp >= 0xFF01 && cp <= 0xFF0F) return true;
    if (cp >= 0xFF1A && cp <= 0xFF20) return true;
    if (cp >= 0xFF3B && cp <= 0xFF40) return true;
    if (cp >= 0xFF5B && cp <= 0xFF60) return true;
    return false;
}

// ASCII 标点（NFKC 归一化后全角标点可能变成 ASCII 标点）。
[[nodiscard]] bool is_ascii_punct(char32_t cp) noexcept {
    // ASCII 控制字符 + 标点范围 (0x21–0x2F, 0x3A–0x40, 0x5B–0x60, 0x7B–0x7E)
    if (cp >= 0x21 && cp <= 0x2F) return true;
    if (cp >= 0x3A && cp <= 0x40) return true;
    if (cp >= 0x5B && cp <= 0x60) return true;
    if (cp >= 0x7B && cp <= 0x7E) return true;
    return false;
}

}  // namespace detail

// ===========================================================================
// NgramAnalyzer
// ===========================================================================

NgramAnalyzer::NgramAnalyzer(std::uint32_t min_n, std::uint32_t max_n)
    : min_n_(min_n), max_n_(max_n) {}

auto NgramAnalyzer::analyze(std::string_view text) const -> TermFreqMap {
    if (text.empty()) return {};

    // Step 1: NFKC 归一化 + case fold
    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    // Step 2: 解码为 codepoint 序列
    auto cps = detail::to_codepoints(normalized);
    if (cps.empty()) return {};

    TermFreqMap tfs;
    std::size_t i = 0;

    // 辅助 lambda：对一段连续 CJK 字符（无标点）生成 n-gram
    auto emit_ngrams = [&](std::size_t start, std::size_t end) {
        auto n = end - start;
        for (std::size_t gram = min_n_; gram <= max_n_; ++gram) {
            if (gram > n) break;
            for (std::size_t j = start; j + gram <= end; ++j) {
                auto& first_cp = cps[j];
                auto& last_cp = cps[j + gram - 1];
                auto term = std::string_view(
                    normalized.data() + first_cp.byte_off,
                    (last_cp.byte_off + last_cp.byte_len) - first_cp.byte_off);
                ++tfs[std::string(term)];
            }
        }
    };

    while (i < cps.size()) {
        if (detail::is_cjk(cps[i].cp) && !detail::is_cjk_punct(cps[i].cp)) {
            // 收集连续 CJK 非标点字符，遇到标点/非 CJK 时断开
            std::size_t run_start = i;
            while (i < cps.size() &&
                   detail::is_cjk(cps[i].cp) &&
                   !detail::is_cjk_punct(cps[i].cp)) {
                ++i;
            }
            emit_ngrams(run_start, i);
            // 如果当前位置是 CJK 标点，跳过它（外层 while 会重新进入 CJK 分支或退出）
            if (i < cps.size() && detail::is_cjk_punct(cps[i].cp)) {
                ++i;
            }
        } else if (detail::is_unicode_space(cps[i].cp)) {
            ++i;
        } else if (detail::is_cjk_punct(cps[i].cp) || detail::is_ascii_punct(cps[i].cp)) {
            ++i;
        } else {
            std::size_t word_start = i;
            while (i < cps.size() &&
                   !detail::is_cjk(cps[i].cp) &&
                   !detail::is_unicode_space(cps[i].cp) &&
                   !detail::is_cjk_punct(cps[i].cp) &&
                   !detail::is_ascii_punct(cps[i].cp)) {
                ++i;
            }
            auto& first = cps[word_start];
            auto& last = cps[i - 1];
            auto term = std::string_view(
                normalized.data() + first.byte_off,
                (last.byte_off + last.byte_len) - first.byte_off);
            if (!term.empty()) {
                ++tfs[std::string(term)];
            }
        }
    }

    return tfs;
}

// ===========================================================================
// WhitespaceAnalyzer
// ===========================================================================

auto WhitespaceAnalyzer::analyze(std::string_view text) const -> TermFreqMap {
    if (text.empty()) return {};

    auto normalized = detail::nfkc_fold(text);
    if (normalized.empty()) return {};

    auto cps = detail::to_codepoints(normalized);
    if (cps.empty()) return {};

    TermFreqMap tfs;
    std::size_t i = 0;

    while (i < cps.size()) {
        if (detail::is_unicode_space(cps[i].cp)) {
            ++i;
            continue;
        }
        // 收集连续非空白字符
        std::size_t word_start = i;
        while (i < cps.size() && !detail::is_unicode_space(cps[i].cp)) {
            ++i;
        }
        auto& first = cps[word_start];
        auto& last = cps[i - 1];
        auto term = std::string_view(
            normalized.data() + first.byte_off,
            (last.byte_off + last.byte_len) - first.byte_off);
        if (!term.empty()) {
            ++tfs[std::string(term)];
        }
    }

    return tfs;
}

}  // namespace bitcask::text
