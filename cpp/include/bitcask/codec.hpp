// bitcask data 文件 / hint 文件 record 的编解码。
//
// 纯函数：只在 caller 提供的 byte buffer 上做事，不做 I/O，不分配除
// caller 容器之外的内存。磁盘格式定义见 format.hpp。
//
// 错误用 std::expected 返回（kBufferTooShort / kBadCrc / 字段越界），
// 不抛异常——所有上层调用方需要在错误路径下做出选择（截断 / 拒绝整文件 /
// 跳过当前 record 等）。

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <vector>

namespace bitcask::codec {

enum class DecodeError {
    kBufferTooShort,     // 输入不够长，连 header 都读不全
    kBadCrc,             // CRC32 校验失败（数据损坏 / 写入到一半被 kill）
    kKeySizeOverflow,    // KeySz 字段读出来后跟 buffer 实际长度不符
    kValueSizeOverflow,  // ValueSz 同上
};

// 解码后的 data record 视图。key/value 是 zero-copy span，生命周期跟着
// 输入 buf 走——caller 持有 buf 的时候才能用 view。
struct DataRecordView {
    std::uint32_t crc;
    std::uint32_t tstamp;
    std::span<const std::byte> key;
    std::span<const std::byte> value;
    std::size_t total_size;  // kHeaderSize + key.size() + value.size()
};

// 解码后的 hint record。consumed 是消耗的字节数（== kHintRecordSize + key），
// caller 用它推进 buf 指针读下一条。
struct HintRecord {
    std::uint32_t tstamp;
    std::uint32_t total_sz;
    std::uint64_t offset;   // 63-bit；最高位被 tombstone 标志占用
    bool tombstone;
    std::span<const std::byte> key;
    std::size_t consumed;
};

// ---------------------------------------------------------------------------
// data 文件 record
// ---------------------------------------------------------------------------

// 编码一条 data record，append 到 out 末尾。返回写入字节数
// （== kHeaderSize + key.size() + value.size()）。
// CRC 在内部算好填到前 4 字节。
std::size_t encode_data_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value);

// 从 buf 头部读一条 data record。CRC 会校验；不通过返回 kBadCrc。
// 不修改 buf；caller 用 result.total_size 自己 advance。
[[nodiscard]] std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf);

// ---------------------------------------------------------------------------
// hint 文件 record
// ---------------------------------------------------------------------------

// 编码一条 hint record。caller 必须保证 offset <= kMaxOffsetV2
// （63-bit 上限）；超过的话 tombstone bit 会被覆盖污染。
std::size_t encode_hint_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::uint32_t total_sz,
                               std::uint64_t offset,
                               bool tombstone,
                               std::span<const std::byte> key);

// 编码 hint 文件末尾的 EOF sentinel。布局复用普通 record 但语义特殊：
//   Tstamp=0, KeySz=0, TotalSz=running_crc, Tomb=0, Offset=kMaxOffsetV2
// 解析方靠 (KeySz==0 && Offset==kMaxOffsetV2) 识别 sentinel；TotalSz
// 被借来放整文件的 running CRC，给 has_valid_hintfile 用。
std::size_t encode_hint_eof(std::vector<std::byte>& out, std::uint32_t running_crc);

// 从 buf 头部读一条 hint record。EOF sentinel 也作为 HintRecord 返回，
// 调用方用 is_hint_eof() 判断（key 为空 + offset==kMaxOffsetV2）。
[[nodiscard]] std::expected<HintRecord, DecodeError>
decode_hint_record(std::span<const std::byte> buf);

[[nodiscard]] bool is_hint_eof(const HintRecord& r) noexcept;

// ---------------------------------------------------------------------------
// CRC32 (zlib / IEEE 802.3 多项式，跟 erlang:crc32/1 一致)
// ---------------------------------------------------------------------------

// 一次性算一段。
[[nodiscard]] std::uint32_t crc32(std::span<const std::byte> data) noexcept;

// 流式：seed 是上一次的 CRC，data 是新增的字节。hint 文件 running CRC 用。
[[nodiscard]] std::uint32_t crc32_update(std::uint32_t seed,
                                         std::span<const std::byte> data) noexcept;

}  // namespace bitcask::codec
