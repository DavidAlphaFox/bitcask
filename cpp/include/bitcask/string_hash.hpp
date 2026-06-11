// 透明 hash/equal（C++20 异构查找）：让 unordered_map<std::string, V>
// 支持用 string_view 直接 find，免去查找路径上的临时 string 拷贝。
// 使用方式：std::unordered_map<std::string, V, StringHash, std::equal_to<>>。
// 注意：insert/emplace 仍需 owned string（map 持有 key），透明只省查找。
#pragma once

#include <cstddef>
#include <functional>
#include <string_view>

namespace bitcask {

struct StringHash {
    using is_transparent = void;
    std::size_t operator()(std::string_view s) const noexcept {
        return std::hash<std::string_view>{}(s);
    }
};

}  // namespace bitcask
