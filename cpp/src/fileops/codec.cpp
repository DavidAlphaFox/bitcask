#include "bitcask/codec.hpp"

#include <bit>
#include <cassert>
#include <cstring>

#include <zlib.h>

#include "bitcask/format.hpp"

namespace bitcask::codec {

namespace {

// 大端 load/store 辅助。bitcask record 在磁盘上是大端存储——
// Erlang 的 <<X:N>> 默认就是大端，跟旧 NIF 互操作要保持一致。
constexpr void be_store_u16(std::byte* p, std::uint16_t v) noexcept {
    p[0] = static_cast<std::byte>((v >> 8) & 0xFF);
    p[1] = static_cast<std::byte>(v & 0xFF);
}
constexpr void be_store_u32(std::byte* p, std::uint32_t v) noexcept {
    p[0] = static_cast<std::byte>((v >> 24) & 0xFF);
    p[1] = static_cast<std::byte>((v >> 16) & 0xFF);
    p[2] = static_cast<std::byte>((v >> 8) & 0xFF);
    p[3] = static_cast<std::byte>(v & 0xFF);
}
constexpr void be_store_u64(std::byte* p, std::uint64_t v) noexcept {
    for (int i = 0; i < 8; ++i) {
        p[static_cast<std::size_t>(i)] =
            static_cast<std::byte>((v >> (56 - 8 * i)) & 0xFFu);
    }
}
constexpr std::uint16_t be_load_u16(const std::byte* p) noexcept {
    return static_cast<std::uint16_t>(
        (static_cast<std::uint16_t>(p[0]) << 8) |
         static_cast<std::uint16_t>(p[1]));
}
constexpr std::uint32_t be_load_u32(const std::byte* p) noexcept {
    return (static_cast<std::uint32_t>(p[0]) << 24) |
           (static_cast<std::uint32_t>(p[1]) << 16) |
           (static_cast<std::uint32_t>(p[2]) << 8)  |
            static_cast<std::uint32_t>(p[3]);
}
constexpr std::uint64_t be_load_u64(const std::byte* p) noexcept {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v = (v << 8) | static_cast<std::uint64_t>(p[static_cast<std::size_t>(i)]);
    }
    return v;
}

}  // namespace

// 一次性算 CRC——薄包装 zlib::crc32(0, ...)。
std::uint32_t crc32(std::span<const std::byte> data) noexcept {
    return crc32_update(0, data);
}

// 流式 CRC：seed 是上一段的结果，可以多段累计。hint 文件的 trailer CRC
// 就靠这个边写边累加。zlib 的 CRC32 有 incremental 性质——seed 起始值是
// 0，append 一段后的 CRC 跟「整段一次性算」结果一致。
std::uint32_t crc32_update(std::uint32_t seed,
                           std::span<const std::byte> data) noexcept {
    return static_cast<std::uint32_t>(
        ::crc32(static_cast<uLong>(seed),
                reinterpret_cast<const Bytef*>(data.data()),
                static_cast<uInt>(data.size())));
}

// ---------------------------------------------------------------------------
// data record 编解码
// ---------------------------------------------------------------------------

// 把一条 data record append 到 out 末尾。返回写入字节数。
// caller 用 assert 兜底大小限制——超出 uint16/uint32 字段范围是 caller bug。
std::size_t encode_data_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value) {
    assert(key.size() <= format::kMaxKeySize);
    assert(value.size() <= format::kMaxValueSize);

    // resize 一次性预留空间：避免 push_back 多次 realloc。
    const std::size_t total = format::kHeaderSize + key.size() + value.size();
    const std::size_t base = out.size();
    out.resize(base + total);
    std::byte* p = out.data() + base;

    // 布局: [CRC|Tstamp|KeySz|ValueSz|Key|Value]。
    // CRC 覆盖它自身之后的全部字节（即 Tstamp..Value）。
    be_store_u32(p + format::kTstampOffset, tstamp);
    be_store_u16(p + format::kKeySzOffset, static_cast<std::uint16_t>(key.size()));
    be_store_u32(p + format::kValueSzOffset, static_cast<std::uint32_t>(value.size()));
    if (!key.empty()) std::memcpy(p + format::kHeaderSize, key.data(), key.size());
    if (!value.empty()) std::memcpy(p + format::kHeaderSize + key.size(),
                                    value.data(), value.size());

    const std::span<const std::byte> covered{p + format::kTstampOffset,
                                              total - format::kTstampOffset};
    be_store_u32(p + format::kCrcOffset, crc32(covered));
    return total;
}

// 从 buf 头部解一条 data record，校验 CRC 后返回 view（zero-copy）。
// 不修改 buf；caller 负责用 result.total_size 推进自己的指针。
std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf) {
    // 第一道关：连固定 14 字节 header 都读不全 → kBufferTooShort
    if (buf.size() < format::kHeaderSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint32_t crc      = be_load_u32(buf.data() + format::kCrcOffset);
    const std::uint32_t tstamp   = be_load_u32(buf.data() + format::kTstampOffset);
    const std::uint16_t key_sz   = be_load_u16(buf.data() + format::kKeySzOffset);
    const std::uint32_t value_sz = be_load_u32(buf.data() + format::kValueSzOffset);

    // 第二道关：header 说有 N 字节 body 但 buf 不够长 → kBufferTooShort
    const std::size_t total = format::kHeaderSize + key_sz + value_sz;
    if (buf.size() < total) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }

    const std::span<const std::byte> covered{
        buf.data() + format::kTstampOffset, total - format::kTstampOffset};
    if (crc32(covered) != crc) {
        return std::unexpected(DecodeError::kBadCrc);
    }

    return DataRecordView{
        .crc = crc,
        .tstamp = tstamp,
        .key = buf.subspan(format::kHeaderSize, key_sz),
        .value = buf.subspan(format::kHeaderSize + key_sz, value_sz),
        .total_size = total,
    };
}

// ---------------------------------------------------------------------------
// hint record 编解码
// ---------------------------------------------------------------------------

// 编码一条 hint record。offset 必须 <= 2^63-1（最高位是 tombstone bit）。
// 这两个 assert 失败都是 caller bug——data file 的 offset 不可能超过 8 EiB，
// 但还是兜底校验，以防上层算 offset 时溢出。
std::size_t encode_hint_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::uint32_t total_sz,
                               std::uint64_t offset,
                               bool tombstone,
                               std::span<const std::byte> key) {
    assert(offset <= format::kMaxOffsetV2);
    assert(key.size() <= format::kMaxKeySize);

    const std::size_t total = format::kHintRecordSize + key.size();
    const std::size_t base = out.size();
    out.resize(base + total);
    std::byte* p = out.data() + base;

    be_store_u32(p + 0, tstamp);
    be_store_u16(p + 4, static_cast<std::uint16_t>(key.size()));
    be_store_u32(p + 6, total_sz);

    // 把 tombstone 标志压到 offset 的最高位——节省 1 字节，跟 legacy 完全
    // 一致的 wire format。读取时反向 mask。
    const std::uint64_t packed =
        (tombstone ? format::kTombMaskV2 : 0ull) | offset;
    be_store_u64(p + 10, packed);

    if (!key.empty()) std::memcpy(p + format::kHintRecordSize, key.data(), key.size());
    return total;
}

std::size_t encode_hint_eof(std::vector<std::byte>& out, std::uint32_t running_crc) {
    // 布局跟普通 hint record 一致，但语义被特殊化：
    //   Tstamp=0, KeySz=0, TotalSz 借用来放整文件 running CRC,
    //   Tomb=0, Offset=kMaxOffsetV2, 无 key payload。
    // 解码方靠 (KeySz==0 && Offset==kMaxOffsetV2) 识别 sentinel。
    return encode_hint_record(out,
                              /*tstamp*/ 0,
                              /*total_sz*/ running_crc,
                              /*offset*/ format::kMaxOffsetV2,
                              /*tombstone*/ false,
                              {});
}

// 从 buf 头部解一条 hint record；CRC 不在这里校验（hint 文件用 trailer
// CRC 一次性兜底，不是逐条 CRC）。EOF sentinel 也作为 HintRecord 返回——
// caller 用 is_hint_eof() 判断。
std::expected<HintRecord, DecodeError>
decode_hint_record(std::span<const std::byte> buf) {
    if (buf.size() < format::kHintRecordSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint32_t tstamp   = be_load_u32(buf.data() + 0);
    const std::uint16_t key_sz   = be_load_u16(buf.data() + 4);
    const std::uint32_t total_sz = be_load_u32(buf.data() + 6);
    const std::uint64_t packed   = be_load_u64(buf.data() + 10);

    // 反向解 packed：最高位 bit = tombstone，剩余 63 位 = offset。
    const bool tomb = (packed & format::kTombMaskV2) != 0;
    const std::uint64_t offset = packed & format::kMaxOffsetV2;

    if (buf.size() < format::kHintRecordSize + key_sz) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    return HintRecord{
        .tstamp = tstamp,
        .total_sz = total_sz,
        .offset = offset,
        .tombstone = tomb,
        .key = buf.subspan(format::kHintRecordSize, key_sz),
        .consumed = format::kHintRecordSize + key_sz,
    };
}

bool is_hint_eof(const HintRecord& r) noexcept {
    return r.tstamp == 0 && r.key.empty() && r.offset == format::kMaxOffsetV2;
}

}  // namespace bitcask::codec
