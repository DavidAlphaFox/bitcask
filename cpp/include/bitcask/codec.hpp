// bitcask data 文件 / hint 文件 record 的编解码。
//
// 纯函数：只在 caller 提供的 byte buffer 上做事，不做 I/O，不分配除
// caller 容器之外的内存。磁盘格式定义见 format.hpp。
//
// 错误用 std::expected 返回（kBufferTooShort / kBadCrc / 字段越界），
// 不抛异常——所有上层调用方需要在错误路径下做出选择（截断 / 拒绝整文件 /
// 跳过当前 record 等）。
//
// === 线程模型 ===
// 本模块所有函数均为纯函数：
//   - 可重入 / 线程安全：是。多线程可在不同 buffer 上并发调用。
//   - 锁要求：无。caller 自行保证「同一 buffer 在不同线程被并发改写」
//     不会发生（标准 const-correct 约定即可）。
//   - 不抛异常、不分配额外堆内存（除 encode_* 往 caller 的 vector 里 push）。

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <vector>

#include "bitcask/format.hpp"  // RecordType + kDoc value 打包常量

namespace bitcask::codec {

enum class DecodeError {
    kBufferTooShort,      // 输入不够长，连 header 都读不全
    kBadCrc,              // CRC32 校验失败（数据损坏 / 写入到一半被 kill）
    kKeySizeOverflow,     // KeySz 字段读出来后跟 buffer 实际长度不符
    kValueSizeOverflow,   // ValueSz 同上
    kUnsupportedVersion,  // kDoc value 的 Ver 字段不被支持
};

// 解码后的 data record 视图。key/value 是 zero-copy span，生命周期跟着
// 输入 buf 走——caller 持有 buf 的时候才能用 view。
struct DataRecordView {
    std::uint32_t      crc;
    format::RecordType type;
    std::uint32_t      tstamp;
    std::uint64_t      ord;
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
// CRC 在内部算好填到前 4 字节（覆盖 Type..Value）。
// 线程安全: 是（纯函数，但写入 out 由 caller 串行保证）；不需任何锁。
std::size_t encode_data_record(std::vector<std::byte>& out,
                               format::RecordType type,
                               std::uint32_t tstamp,
                               std::uint64_t ord,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value);

// 从 buf 头部读一条 data record。CRC 会校验；不通过返回 kBadCrc。
// 不修改 buf；caller 用 result.total_size 自己 advance。
// 线程安全: 是（纯函数，只读 buf）；不需任何锁。
[[nodiscard]] std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf);

// ---------------------------------------------------------------------------
// kDoc value 打包/解包（§2.4）。仅用于 type==kDoc 的 record 的 VALUE 段。
// ---------------------------------------------------------------------------

// 命名字段（S8.6 多字段）。#1：磁盘上存 field id（schema interning），不再内联
// 字段名。encode 输入 / decode 输出都用 id；name ↔ id 由 Cask 的 field.schema 维护。
// value 是 zero-copy span（指进原 buffer）。
struct DocField {
    std::uint32_t              id = 0;
    std::span<const std::byte> value;
};

// encode 输入：三段皆可选（nullopt = 该段缺省，不写 flag）。vector 是 f32
// 向量（V1 不量化）。fields 非空时写 fields 段（DocField.id 已由 caller 经 schema 解析）。
struct DocValueParts {
    std::optional<std::span<const float>>      vector;
    std::optional<std::span<const std::byte>>  text;
    std::optional<std::span<const std::byte>>  meta;
    std::vector<DocField>                      fields;  // 空 = 不写 fields 段
    bool                                      vec_quantized = false;  // V6.4.1 stub
};

// 解码后的 kDoc value 视图。各段是 zero-copy span，生命周期跟着输入 buf。
// vector_raw 是原始字节（f32 小端，未量化时长度 == dim*4）；caller 在 LE 主机
// 上可直接 memcpy 成 float[]。
struct DocValueView {
    std::uint8_t ver;
    bool has_vector = false;
    bool has_text   = false;
    bool has_meta   = false;
    bool has_fields = false;                // S8.6
    bool vec_quantized = false;
    std::uint32_t dim = 0;                  // 向量元素数（has_vector 或 vec_quantized 有效）
    // vector_raw 语义随 vec_quantized 而变：
    //   未量化：f32 小端字节，长度 == dim*4，LE 主机可直接 memcpy 成 float[]。
    //   量化：  int8 codes 字节，长度 == dim；配合 vec_scale 用 doc_vector_f32() 还原。
    std::span<const std::byte> vector_raw;
    float vec_scale = 0.0f;                 // 仅 vec_quantized 有效（重建标度）
    std::span<const std::byte> text;
    std::span<const std::byte> meta;
    std::vector<DocField>      fields;      // 解出的字段（id + zero-copy value span）
};

// 把 {vector,text,meta} 打包成 kDoc value，append 到 out。返回写入字节数。
// 线程安全: 是（纯函数）；不需任何锁。
std::size_t encode_doc_value(std::vector<std::byte>& out, const DocValueParts& parts);

// 解包 kDoc value。Ver 不支持返回 kUnsupportedVersion；截断返回 kBufferTooShort。
// 线程安全: 是（纯函数，只读 buf）；不需任何锁。
[[nodiscard]] std::expected<DocValueView, DecodeError>
decode_doc_value(std::span<const std::byte> buf);

// 把 DocValueView 的向量段还原成 f32：未量化直接 memcpy，量化则 dequant
// （v̂ = code*scale/127）。无向量段 → 返回空。给 get / 非 int8 路径用；HNSW
// int8 路径直接吃 vector_raw(codes)+vec_scale，不走这里。纯函数。
[[nodiscard]] std::vector<float> doc_vector_f32(const DocValueView& v);

// ---------------------------------------------------------------------------
// hint 文件 record
// ---------------------------------------------------------------------------

// 编码一条 hint record。caller 必须保证 offset <= kMaxOffsetV2
// （63-bit 上限）；超过的话 tombstone bit 会被覆盖污染。
// 线程安全: 是（纯函数）；不需任何锁。
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
// 线程安全: 是（纯函数）；不需任何锁。
std::size_t encode_hint_eof(std::vector<std::byte>& out, std::uint32_t running_crc);

// 从 buf 头部读一条 hint record。EOF sentinel 也作为 HintRecord 返回，
// 调用方用 is_hint_eof() 判断（key 为空 + offset==kMaxOffsetV2）。
// 线程安全: 是（纯函数）；不需任何锁。
[[nodiscard]] std::expected<HintRecord, DecodeError>
decode_hint_record(std::span<const std::byte> buf);

// 线程安全: 是；不需任何锁。
[[nodiscard]] bool is_hint_eof(const HintRecord& r) noexcept;

// ---------------------------------------------------------------------------
// CRC32 (zlib / IEEE 802.3 多项式，跟 erlang:crc32/1 一致)
// 全部为纯函数，线程安全、可重入，不需任何锁。
// ---------------------------------------------------------------------------

// 一次性算一段。
[[nodiscard]] std::uint32_t crc32(std::span<const std::byte> data) noexcept;

// 流式：seed 是上一次的 CRC，data 是新增的字节。hint 文件 running CRC 用。
[[nodiscard]] std::uint32_t crc32_update(std::uint32_t seed,
                                         std::span<const std::byte> data) noexcept;

}  // namespace bitcask::codec
