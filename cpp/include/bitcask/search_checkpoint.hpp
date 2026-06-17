// P14e:搜索索引分段 checkpoint 容器(`search.ckpt`)。
//
// 自描述、分段、**每段独立 CRC**;页脚最后写(tmp+rename 原子)——页脚存在且
// footerCrc 通过 = 文件结构完整。布局/语义见
// doc/recovery-unified-checkpoint-design-zh.md §3.2 与 doc/format-zh.md §十。
// 全多字节小端。本类只管**容器**(头部 watermark + 段载荷 + 页脚目录 + 逐段
// CRC),段 payload 是不透明字节(由各索引序列化器产出/消费),与序列化解耦。
//
//   头部 (16B):  "BCSC" | version u32=1 | watermark u64(覆盖 next_ord 上界)
//   段载荷区:    各段 payload 顺序拼接(位置/校验由页脚给出)
//   页脚:        directory{ sectionCount u32; 每段[type u16|flags u16|
//                  offset u64|len u64|crc32 u32] } | footerCrc u32 |
//                  dirLen u32 | trailer "BCSC"

#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/codec.hpp"  // crc32

namespace bitcask::search {

// 段类型(与姊妹引擎 cellar 对齐)。
enum class CkptSectionType : std::uint16_t {
    kDocmap      = 1,  // 可选加速缓存:ord→key/loc/live/doc_len
    kBm25Default = 2,
    kBm25Fields  = 3,
    kHnsw        = 4,
    kMeta        = 5,  // 可选加速缓存
    kTerms       = 6,  // 可选加速缓存
};

// 写入用:caller 持有 payload 字节。
struct CkptSection {
    std::uint16_t type;
    std::uint16_t flags = 0;
    std::span<const std::byte> payload;
};

// 读取用:从文件载出的一段(payload owned;crc_ok 标记是否通过逐段校验)。
struct LoadedSection {
    std::uint16_t type;
    std::uint16_t flags;
    std::vector<std::byte> payload;
    bool crc_ok;
};

struct LoadedCheckpoint {
    std::uint64_t watermark = 0;
    std::vector<LoadedSection> sections;  // 结构内定位到的段(逐段带 crc_ok)
};

namespace detail {

constexpr char kCkptMagic[4] = {'B', 'C', 'S', 'C'};
constexpr std::uint32_t kCkptVersion = 1;
constexpr std::size_t kHeaderLen = 16;  // magic(4)+ver(4)+watermark(8)
constexpr std::size_t kTrailerLen = 12;  // footerCrc(4)+dirLen(4)+trailer(4)

inline void put_u16(std::vector<std::byte>& b, std::uint16_t v) {
    b.push_back(static_cast<std::byte>(v & 0xFF));
    b.push_back(static_cast<std::byte>((v >> 8) & 0xFF));
}
inline void put_u32(std::vector<std::byte>& b, std::uint32_t v) {
    for (int i = 0; i < 4; ++i)
        b.push_back(static_cast<std::byte>((v >> (8 * i)) & 0xFF));
}
inline void put_u64(std::vector<std::byte>& b, std::uint64_t v) {
    for (int i = 0; i < 8; ++i)
        b.push_back(static_cast<std::byte>((v >> (8 * i)) & 0xFF));
}
inline std::uint16_t get_u16(const std::byte* p) {
    return static_cast<std::uint16_t>(
        static_cast<std::uint16_t>(p[0]) |
        (static_cast<std::uint16_t>(p[1]) << 8));
}
inline std::uint32_t get_u32(const std::byte* p) {
    return static_cast<std::uint32_t>(p[0]) |
           (static_cast<std::uint32_t>(p[1]) << 8) |
           (static_cast<std::uint32_t>(p[2]) << 16) |
           (static_cast<std::uint32_t>(p[3]) << 24);
}
inline std::uint64_t get_u64(const std::byte* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i)
        v |= static_cast<std::uint64_t>(p[i]) << (8 * i);
    return v;
}

}  // namespace detail

class SearchCheckpoint {
public:
    // 写 header + sections + footer,tmp+rename 原子落盘。成功返回 true。
    [[nodiscard]] static bool write(std::string_view path,
                                    std::uint64_t watermark,
                                    std::span<const CkptSection> sections) {
        using namespace detail;
        std::vector<std::byte> buf;
        // 头部。
        buf.insert(buf.end(),
                   reinterpret_cast<const std::byte*>(kCkptMagic),
                   reinterpret_cast<const std::byte*>(kCkptMagic) + 4);
        put_u32(buf, kCkptVersion);
        put_u64(buf, watermark);
        // 段载荷区(记录每段 offset/len/crc 供页脚)。
        struct DirEnt { std::uint16_t type, flags; std::uint64_t off, len;
                        std::uint32_t crc; };
        std::vector<DirEnt> dir;
        dir.reserve(sections.size());
        for (const auto& s : sections) {
            const std::uint64_t off = buf.size();
            buf.insert(buf.end(), s.payload.begin(), s.payload.end());
            const std::uint32_t crc = bitcask::codec::crc32(s.payload);
            dir.push_back({s.type, s.flags, off,
                           static_cast<std::uint64_t>(s.payload.size()), crc});
        }
        // 页脚目录。
        std::vector<std::byte> d;
        put_u32(d, static_cast<std::uint32_t>(dir.size()));
        for (const auto& e : dir) {
            put_u16(d, e.type);
            put_u16(d, e.flags);
            put_u64(d, e.off);
            put_u64(d, e.len);
            put_u32(d, e.crc);
        }
        const std::uint32_t footer_crc = bitcask::codec::crc32(
            std::span<const std::byte>(d.data(), d.size()));
        buf.insert(buf.end(), d.begin(), d.end());
        put_u32(buf, footer_crc);
        put_u32(buf, static_cast<std::uint32_t>(d.size()));
        buf.insert(buf.end(),
                   reinterpret_cast<const std::byte*>(kCkptMagic),
                   reinterpret_cast<const std::byte*>(kCkptMagic) + 4);

        const std::string fp(path);
        const std::string tmp = fp + ".tmp";
        std::FILE* f = std::fopen(tmp.c_str(), "wb");
        if (!f) return false;
        const bool wrote =
            std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
        std::fclose(f);
        if (!wrote || std::rename(tmp.c_str(), fp.c_str()) != 0) {
            std::remove(tmp.c_str());
            return false;
        }
        return true;
    }

    // 读 + 校验。结构损坏(页脚缺失/footerCrc 失败/越界)→ nullopt(调用方退
    // .prev 或全量重建)。结构完整 → 返回 watermark + 各段(逐段带 crc_ok)。
    [[nodiscard]] static std::optional<LoadedCheckpoint>
    read(std::string_view path) {
        using namespace detail;
        std::FILE* f = std::fopen(std::string(path).c_str(), "rb");
        if (!f) return std::nullopt;
        std::fseek(f, 0, SEEK_END);
        const long fsz = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        if (fsz < static_cast<long>(kHeaderLen + kTrailerLen)) {
            std::fclose(f);
            return std::nullopt;
        }
        std::vector<std::byte> buf(static_cast<std::size_t>(fsz));
        const bool rd = std::fread(buf.data(), 1, buf.size(), f) == buf.size();
        std::fclose(f);
        if (!rd) return std::nullopt;

        const std::byte* base = buf.data();
        const std::size_t n = buf.size();
        // 头部 magic/version。
        if (std::memcmp(base, kCkptMagic, 4) != 0) return std::nullopt;
        if (get_u32(base + 4) != kCkptVersion) return std::nullopt;
        // 页脚(从尾倒走)。
        if (std::memcmp(base + n - 4, kCkptMagic, 4) != 0) return std::nullopt;
        const std::uint32_t dir_len = get_u32(base + n - 8);
        const std::uint32_t footer_crc = get_u32(base + n - 12);
        // directory 区间 [dir_begin, dir_begin+dir_len) 必须落在 header 与
        // trailer 之间。
        if (static_cast<std::size_t>(dir_len) + kHeaderLen + kTrailerLen > n) {
            return std::nullopt;
        }
        const std::size_t dir_begin = n - kTrailerLen - dir_len;
        if (dir_begin < kHeaderLen) return std::nullopt;
        const std::byte* d = base + dir_begin;
        if (bitcask::codec::crc32(std::span<const std::byte>(d, dir_len)) !=
            footer_crc) {
            return std::nullopt;  // 结构损坏。
        }

        LoadedCheckpoint out;
        out.watermark = get_u64(base + 8);
        if (dir_len < 4) return std::nullopt;
        const std::uint32_t cnt = get_u32(d);
        std::size_t p = 4;
        constexpr std::size_t kEntLen = 2 + 2 + 8 + 8 + 4;  // 24
        for (std::uint32_t i = 0; i < cnt; ++i) {
            if (p + kEntLen > dir_len) return std::nullopt;
            const std::byte* e = d + p;
            LoadedSection ls;
            ls.type = get_u16(e);
            ls.flags = get_u16(e + 2);
            const std::uint64_t off = get_u64(e + 4);
            const std::uint64_t len = get_u64(e + 12);
            const std::uint32_t crc = get_u32(e + 20);
            p += kEntLen;
            // payload 区间必须落在 header 与 directory 之间。
            if (off < kHeaderLen || off > dir_begin ||
                len > dir_begin - off) {
                return std::nullopt;  // 目录越界 = 结构损坏。
            }
            ls.payload.assign(base + off, base + off + len);
            ls.crc_ok = bitcask::codec::crc32(
                std::span<const std::byte>(base + off, len)) == crc;
            out.sections.push_back(std::move(ls));
        }
        return out;
    }
};

}  // namespace bitcask::search
