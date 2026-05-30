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

    auto* raw = reinterpret_cast<const utf8proc_uint8_t*>(input.data());
    auto* out = utf8proc_NFKC_Casefold(raw);
    if (out == nullptr) return {};

    Utf8ProcBuf guard(out);
    return std::string(reinterpret_cast<const char*>(out), std::strlen(reinterpret_cast<const char*>(out)));
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
