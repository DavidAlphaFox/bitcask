// DocValue meta 段的「结构化 KV」二进制格式编解码（V5 metadata filter, §1）。
//
// DocValue v3 的 meta 段此前是一个不透明二进制 blob，引擎无法在不解码的情况下
// 解析或过滤。V5 起约定一个紧凑的「key-sorted KV 列表」结构，让 HNSW 过滤
// 搜索等热路径可以只读单字段（meta_lookup 二分查找）而无需全量 decode。
//
// 格式：
//   [Ver:u8=1][NumEntries:varint]
//     对每个 entry（key 升序）：
//       [KeyLen:varint][KeyBytes: UTF-8]
//       [ValueType:u8]   (0=null, 1=bool, 2=int64, 3=float64, 4=string)
//       [ValueData]:
//         null: 0 字节
//         bool: 1 字节（0=false, 1=true）
//         int64: 8 字节小端
//         float64: 8 字节小端（IEEE 754）
//         string: [Len:varint][Bytes]
//
// === 不变式 / 性能契约 ===
// - keys 必须按字典序升序排列，由 encode_meta 校验（assert），被 meta_lookup
//   用作二分查找的 key——这是 hot path 上「O(log n) 跳读」的前提。
// - 没有重复 key，由 caller 保证（encode_meta 也 assert）。
// - Type tag 同时是 fixed-size 类型（null/bool/int64/float64）的长度指示；
//   只有 string 需要额外的长度前缀。
//
// === 线程模型 ===
// 所有函数均为纯函数：只读 / append 到 caller 提供的 buffer，不分配除 caller
// 容器之外的内存。线程安全、可重入、无锁。
// - meta_lookup 是热路径（HNSW 每个被访问节点调用一次），必须尽量紧凑。

#pragma once

#include <algorithm>
#include <bit>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace bitcask::meta {

// meta 二进制格式的 value type tag——直接落盘 u8，禁止重排/重用。
enum class MetaType : std::uint8_t {
    Null    = 0,
    Bool    = 1,
    Int64   = 2,
    Float64 = 3,
    String  = 4,
};

// MetaValue 用 std::variant 表达；std::monostate 对应 Null（默认构造即 Null）。
// String 持 owned 数据——decode_meta 会分配、caller 拿到后长期持有 OK。
using MetaValue = std::variant<
    std::monostate,
    bool,
    std::int64_t,
    double,
    std::string>;

// 单条 KV。encode_meta 要求 entries 已按 key 升序、无重复——调用方责任。
struct MetaEntry {
    std::string key;
    MetaValue   value;
};

// 格式版本号。改格式必须 bump 这个字节。
inline constexpr std::uint8_t kMetaFormatVersion = 1;

namespace detail {

// VByte 变长整数：低 7 位数据 + 最高位 1=终止字节。与 codec.cpp 同算法。
inline void vbyte_append(std::vector<std::byte>& out, std::uint64_t val) {
    while (val >= 128) {
        out.push_back(static_cast<std::byte>(val & 0x7Fu));
        val >>= 7;
    }
    out.push_back(static_cast<std::byte>(val | 0x80u));
}

// VByte 解码：返回 {value, new_pos}；越界或非法编码返回 {0, buf.size()}。
inline std::pair<std::uint64_t, std::size_t>
vbyte_read(std::span<const std::byte> buf, std::size_t pos) {
    std::uint64_t result = 0;
    std::uint64_t shift  = 0;
    while (true) {
        if (pos >= buf.size()) return {0, buf.size()};
        const auto b = static_cast<std::uint8_t>(buf[pos++]);
        result |= static_cast<std::uint64_t>(b & 0x7Fu) << shift;
        if (b & 0x80u) break;
        shift += 7;
        if (shift >= 64) return {0, buf.size()};
    }
    return {result, pos};
}

// 把 VByte 写入 [p, p+n)，返回写入字节数。供 encode_meta 直接顺序写，
// 不再触发 vector 的 push_back realloc。
inline std::size_t vbyte_store(std::byte* p, std::uint64_t val) noexcept {
    std::size_t off = 0;
    while (val >= 128) {
        p[off++] = static_cast<std::byte>(val & 0x7Fu);
        val >>= 7;
    }
    p[off++] = static_cast<std::byte>(val | 0x80u);
    return off;
}

// 一条 entry 在 encode 时的 worst-case 字节数：含 KeyLen:varint(<=9) +
// KeyBytes + ValueType:u8 + ValueData(fixed-size 或 String 的 varint+bytes)。
inline std::size_t entry_payload_size(const MetaEntry& e) noexcept {
    std::size_t key_part = 9 + e.key.size();
    switch (e.value.index()) {
        case 0: return key_part + 1;
        case 1: return key_part + 1 + 1;
        case 2: return key_part + 1 + 8;
        case 3: return key_part + 1 + 8;
        case 4: {
            const auto& s = std::get<std::string>(e.value);
            return key_part + 1 + 9 + s.size();
        }
        default: return key_part + 1;
    }
}

}  // namespace detail

// 把一组 entries append 到 out 末尾。返回写入的字节数。
// 契约：entries 必须按 key 升序、无重复（assert 兜底，违反是 caller bug）。
// 线程安全：是（纯函数）；不需任何锁。
inline std::size_t encode_meta(std::vector<std::byte>& out,
                                std::span<const MetaEntry> entries) {
#ifndef NDEBUG
    for (std::size_t i = 1; i < entries.size(); ++i) {
        assert(entries[i - 1].key < entries[i].key &&
               "encode_meta: entries 必须按 key 升序排列");
    }
    for (std::size_t i = 1; i < entries.size(); ++i) {
        assert(entries[i - 1].key != entries[i].key &&
               "encode_meta: 不允许重复 key");
    }
#endif

    // 一次性 reserve worst-case 空间，避免 push_back 反复 realloc。
    std::size_t reserve = 1 + 9;  // Ver + NumEntries(varint 最坏 9)
    for (const auto& e : entries) reserve += detail::entry_payload_size(e);

    const std::size_t base = out.size();
    out.resize(base + reserve);
    std::byte* p = out.data() + base;
    std::size_t off = 0;

    p[off++] = static_cast<std::byte>(kMetaFormatVersion);
    off += detail::vbyte_store(p + off, entries.size());

    for (const auto& e : entries) {
        off += detail::vbyte_store(p + off, e.key.size());
        if (!e.key.empty()) {
            std::memcpy(p + off, e.key.data(), e.key.size());
            off += e.key.size();
        }
        switch (e.value.index()) {
            case 0: {
                p[off++] = static_cast<std::byte>(MetaType::Null);
                break;
            }
            case 1: {
                p[off++] = static_cast<std::byte>(MetaType::Bool);
                p[off++] = static_cast<std::byte>(
                    std::get<bool>(e.value) ? 1u : 0u);
                break;
            }
            case 2: {
                const std::int64_t v = std::get<std::int64_t>(e.value);
                std::uint64_t bits;
                std::memcpy(&bits, &v, sizeof(bits));
                p[off++] = static_cast<std::byte>(MetaType::Int64);
                for (std::size_t i = 0; i < 8; ++i) {
                    p[off++] = static_cast<std::byte>((bits >> (8 * i)) & 0xFFu);
                }
                break;
            }
            case 3: {
                const double v = std::get<double>(e.value);
                std::uint64_t bits;
                std::memcpy(&bits, &v, sizeof(bits));
                p[off++] = static_cast<std::byte>(MetaType::Float64);
                for (std::size_t i = 0; i < 8; ++i) {
                    p[off++] = static_cast<std::byte>((bits >> (8 * i)) & 0xFFu);
                }
                break;
            }
            case 4: {
                const auto& s = std::get<std::string>(e.value);
                p[off++] = static_cast<std::byte>(MetaType::String);
                off += detail::vbyte_store(p + off, s.size());
                if (!s.empty()) {
                    std::memcpy(p + off, s.data(), s.size());
                    off += s.size();
                }
                break;
            }
            default:
                assert(false && "encode_meta: 未知 MetaType，invariant 违反");
        }
    }

    out.resize(base + off);
    return off;
}

// 解码整个 blob 到 entries。失败时返回错误字符串（截断 / 非法 varint /
// 未支持 Ver / 非法 Type tag 等）。成功时 entries 按 key 升序（格式不变式）。
// 线程安全：是（纯函数，只读 buf）；不需任何锁。
inline std::expected<std::vector<MetaEntry>, std::string>
decode_meta(std::span<const std::byte> buf) {
    if (buf.size() < 2) {
        return std::unexpected("meta: buffer too short for header");
    }
    if (static_cast<std::uint8_t>(buf[0]) != kMetaFormatVersion) {
        return std::unexpected("meta: unsupported version");
    }
    auto [n, pos] = detail::vbyte_read(buf, 1);

    std::vector<MetaEntry> out;
    out.reserve(static_cast<std::size_t>(n));

    for (std::uint64_t i = 0; i < n; ++i) {
        if (pos >= buf.size()) {
            return std::unexpected("meta: truncated at entry keylen");
        }
        auto [klen, p2] = detail::vbyte_read(buf, pos);
        pos = p2;
        if (klen > buf.size() - pos) {
            return std::unexpected("meta: truncated key bytes");
        }
        MetaEntry e;
        e.key.assign(reinterpret_cast<const char*>(buf.data() + pos),
                     static_cast<std::size_t>(klen));
        pos += static_cast<std::size_t>(klen);

        if (pos >= buf.size()) {
            return std::unexpected("meta: truncated at value type tag");
        }
        const auto tag = static_cast<MetaType>(
            static_cast<std::uint8_t>(buf[pos++]));

        switch (tag) {
            case MetaType::Null:
                e.value = std::monostate{};
                break;
            case MetaType::Bool:
                if (pos >= buf.size()) {
                    return std::unexpected("meta: truncated bool byte");
                }
                e.value = (static_cast<std::uint8_t>(buf[pos++]) != 0);
                break;
            case MetaType::Int64: {
                if (buf.size() - pos < 8) {
                    return std::unexpected("meta: truncated int64 bytes");
                }
                std::uint64_t bits = 0;
                for (std::size_t j = 0; j < 8; ++j) {
                    bits |= static_cast<std::uint64_t>(
                                static_cast<std::uint8_t>(buf[pos + j]))
                            << (8 * j);
                }
                pos += 8;
                std::int64_t v;
                std::memcpy(&v, &bits, sizeof(v));
                e.value = v;
                break;
            }
            case MetaType::Float64: {
                if (buf.size() - pos < 8) {
                    return std::unexpected("meta: truncated float64 bytes");
                }
                std::uint64_t bits = 0;
                for (std::size_t j = 0; j < 8; ++j) {
                    bits |= static_cast<std::uint64_t>(
                                static_cast<std::uint8_t>(buf[pos + j]))
                            << (8 * j);
                }
                pos += 8;
                double v;
                std::memcpy(&v, &bits, sizeof(v));
                e.value = v;
                break;
            }
            case MetaType::String: {
                if (pos >= buf.size()) {
                    return std::unexpected("meta: truncated string len");
                }
                auto [slen, p3] = detail::vbyte_read(buf, pos);
                pos = p3;
                if (slen > buf.size() - pos) {
                    return std::unexpected("meta: truncated string bytes");
                }
                e.value.emplace<std::string>(
                    reinterpret_cast<const char*>(buf.data() + pos),
                    static_cast<std::size_t>(slen));
                pos += static_cast<std::size_t>(slen);
                break;
            }
            default:
                return std::unexpected("meta: unknown value type tag");
        }
        out.push_back(std::move(e));
    }
    return out;
}

// 在 meta blob 中查找单个 key，不全量 decode。这是 hot path——
// HNSW 每访问一个节点过滤时调用一次。
//
// 实现策略：一次性线性扫一遍，建立「entry 起始 offset」表；然后在这个
// offset 表上二分定位 key。对每次调用是 O(n) 预扫 + O(log n) 二分，
// 整体开销远小于全量 decode（后者还要为每条 string 分配堆内存）。
//
// 未找到返回 std::monostate。线程安全：是（纯函数，只读 blob）；不需任何锁。
inline MetaValue meta_lookup(std::span<const std::byte> blob,
                             std::string_view key) {
    if (blob.size() < 2) return std::monostate{};
    if (static_cast<std::uint8_t>(blob[0]) != kMetaFormatVersion) {
        return std::monostate{};
    }
    auto [n, pos] = detail::vbyte_read(blob, 1);

    std::vector<std::size_t> offsets;
    offsets.reserve(static_cast<std::size_t>(n));

    auto read_varint = [&blob](std::size_t p, std::uint64_t& out) -> std::size_t {
        std::uint64_t v = 0;
        std::uint64_t shift = 0;
        std::size_t q = p;
        while (q < blob.size()) {
            const auto b = static_cast<std::uint8_t>(blob[q++]);
            v |= static_cast<std::uint64_t>(b & 0x7Fu) << shift;
            if (b & 0x80u) { out = v; return q; }
            shift += 7;
            if (shift >= 64) return blob.size();
        }
        return blob.size();
    };

    std::size_t cur = pos;
    for (std::uint64_t i = 0; i < n; ++i) {
        if (cur >= blob.size()) break;
        const std::size_t entry_start = cur;

        std::uint64_t kl = 0;
        std::size_t p = read_varint(cur, kl);
        if (p == blob.size() || kl > blob.size() - p) break;
        cur = p + static_cast<std::size_t>(kl);

        if (cur >= blob.size()) break;
        const auto tag = static_cast<MetaType>(
            static_cast<std::uint8_t>(blob[cur++]));
        switch (tag) {
            case MetaType::Null:   break;
            case MetaType::Bool:   if (cur < blob.size()) ++cur; break;
            case MetaType::Int64:
                if (blob.size() - cur >= 8) cur += 8; else cur = blob.size(); break;
            case MetaType::Float64:
                if (blob.size() - cur >= 8) cur += 8; else cur = blob.size(); break;
            case MetaType::String: {
                std::uint64_t sl = 0;
                std::size_t q = read_varint(cur, sl);
                if (q == blob.size() || sl > blob.size() - q) {
                    cur = blob.size();
                } else {
                    cur = q + static_cast<std::size_t>(sl);
                }
                break;
            }
            default: cur = blob.size(); break;
        }
        offsets.push_back(entry_start);
    }

    const std::size_t m = offsets.size();
    if (m == 0) return std::monostate{};

    std::size_t lo = 0, hi = m;
    while (lo < hi) {
        const std::size_t mid = lo + (hi - lo) / 2;
        std::uint64_t kl = 0;
        std::size_t p = read_varint(offsets[mid], kl);
        if (p == blob.size() || kl > blob.size() - p) {
            return std::monostate{};
        }
        const std::string_view ek(
            reinterpret_cast<const char*>(blob.data() + p),
            static_cast<std::size_t>(kl));
        const int cmp = ek.compare(key);
        if (cmp == 0) {
            p += static_cast<std::size_t>(kl);
            if (p >= blob.size()) return std::monostate{};
            const auto tag = static_cast<MetaType>(
                static_cast<std::uint8_t>(blob[p++]));
            switch (tag) {
                case MetaType::Null:
                    return std::monostate{};
                case MetaType::Bool:
                    if (p >= blob.size()) return std::monostate{};
                    return static_cast<std::uint8_t>(blob[p]) != 0;
                case MetaType::Int64:
                    if (blob.size() - p < 8) return std::monostate{};
                    {
                        std::uint64_t bits = 0;
                        for (std::size_t j = 0; j < 8; ++j) {
                            bits |= static_cast<std::uint64_t>(
                                        static_cast<std::uint8_t>(blob[p + j]))
                                    << (8 * j);
                        }
                        std::int64_t v;
                        std::memcpy(&v, &bits, sizeof(v));
                        return v;
                    }
                case MetaType::Float64:
                    if (blob.size() - p < 8) return std::monostate{};
                    {
                        std::uint64_t bits = 0;
                        for (std::size_t j = 0; j < 8; ++j) {
                            bits |= static_cast<std::uint64_t>(
                                        static_cast<std::uint8_t>(blob[p + j]))
                                    << (8 * j);
                        }
                        double v;
                        std::memcpy(&v, &bits, sizeof(v));
                        return v;
                    }
                case MetaType::String: {
                    std::uint64_t sl = 0;
                    std::size_t q = read_varint(p, sl);
                    if (q == blob.size() || sl > blob.size() - q) {
                        return std::monostate{};
                    }
                    return std::string(
                        reinterpret_cast<const char*>(blob.data() + q),
                        static_cast<std::size_t>(sl));
                }
                default:
                    return std::monostate{};
            }
        } else if (cmp < 0) {
            lo = mid + 1;
        } else {
            if (mid == 0) break;
            hi = mid;
        }
    }
    return std::monostate{};
}

}  // namespace bitcask::meta
