#pragma once

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <utf8proc.h>

namespace bitcask::text::detail {

struct Utf8ProcDeleter {
    void operator()(void* p) const noexcept { std::free(p); }
};
using Utf8ProcBuf = std::unique_ptr<uint8_t[], Utf8ProcDeleter>;

[[nodiscard]] inline std::string nfkc_fold(std::string_view input) {
    if (input.empty()) return {};

    // P2.5 ASCII 快路径：纯 ASCII 输入的 NFKC_Casefold 数学上等价于逐字节
    // tolower——ASCII 区是 NFKC 稳定的（无分解/组合）、casefold 即小写化、
    // 无 default-ignorable 字符。实测 1KB 拉丁文本 utf8proc 路径 ~12us，
    // 本路径亚微秒（且循环可被自动向量化）。语义对拍见 analyzer_test。
    bool ascii = true;
    for (unsigned char c : input) {
        if (c >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        std::string out(input);
        for (auto& c : out) {
            if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        }
        return out;
    }

    // 非 ASCII：utf8proc_map 接受显式长度（utf8proc_NFKC_Casefold 即
    // 它加 NULLTERM 的包装）——免去此前「输入拷贝求 null 终止」与
    // 「输出 strlen」两次全串遍历。选项与 NFKC_Casefold 完全一致。
    // 行为差异仅在含内嵌 \0 的输入：旧版在 \0 截断，本版处理全长（更正确）。
    utf8proc_uint8_t* out = nullptr;
    auto n = utf8proc_map(
        reinterpret_cast<const utf8proc_uint8_t*>(input.data()),
        static_cast<utf8proc_ssize_t>(input.size()), &out,
        static_cast<utf8proc_option_t>(UTF8PROC_STABLE | UTF8PROC_COMPOSE |
                                       UTF8PROC_COMPAT | UTF8PROC_CASEFOLD |
                                       UTF8PROC_IGNORE));
    if (n < 0 || out == nullptr) return {};
    Utf8ProcBuf guard(out);
    return std::string(reinterpret_cast<const char*>(out),
                       static_cast<std::size_t>(n));
}

[[nodiscard]] inline std::pair<char32_t, std::size_t> decode_one(
    std::string_view sv) noexcept {
    if (sv.empty()) return {0, 0};

    auto* ptr = reinterpret_cast<const utf8proc_uint8_t*>(sv.data());
    auto len = static_cast<utf8proc_ssize_t>(sv.size());

    utf8proc_int32_t cp = 0;
    auto consumed = utf8proc_iterate(ptr, len, &cp);
    if (consumed < 0 || cp < 0) return {0xFFFD, 1};
    return {static_cast<char32_t>(cp), static_cast<std::size_t>(consumed)};
}

struct CpInfo {
    char32_t    cp;
    std::size_t byte_off;
    std::size_t byte_len;
};

[[nodiscard]] inline std::vector<CpInfo> to_codepoints(std::string_view text) {
    std::vector<CpInfo> cps;
    cps.reserve(text.size() / 2);
    std::size_t off = 0;
    while (off < text.size()) {
        // P2.5：ASCII 免 utf8proc_iterate 库调用（每码点一次函数调用 +
        // 分支判定，对拉丁/混合文本是纯开销）。
        const auto b = static_cast<unsigned char>(text[off]);
        if (b < 0x80) {
            cps.push_back({static_cast<char32_t>(b), off, 1});
            ++off;
            continue;
        }
        auto [cp, consumed] = decode_one(text.substr(off));
        if (consumed == 0) break;
        cps.push_back({cp, off, consumed});
        off += consumed;
    }
    return cps;
}

[[nodiscard]] inline bool is_cjk_punct(char32_t cp) noexcept {
    if (cp >= 0x3000 && cp <= 0x303F) return true;
    if (cp >= 0xFE30 && cp <= 0xFE4F) return true;
    if (cp >= 0xFF01 && cp <= 0xFF0F) return true;
    if (cp >= 0xFF1A && cp <= 0xFF20) return true;
    if (cp >= 0xFF3B && cp <= 0xFF40) return true;
    if (cp >= 0xFF5B && cp <= 0xFF60) return true;
    return false;
}

}  // namespace bitcask::text::detail
