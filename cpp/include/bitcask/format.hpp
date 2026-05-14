// bitcask 磁盘格式常量。
//
// 这里的所有数字、字段顺序、tombstone 字符串都是「磁盘契约」的一部分，
// 改一处就是 binary-incompatible 变更，必须同步更新 M0 黄金测试
// （cpp/tests/codec_test.cpp、data_file_test.cpp 里有跟二进制 fixture 的
// 字节级比对）。原 legacy 端 include/bitcask.hrl 已删，这里成了唯一来源。
//
// === 线程模型 ===
// 全部为 inline constexpr 常量 + 一个 constexpr 纯函数。
//   - 可重入 / 线程安全：是（无可变状态）。
//   - 锁要求：无。

#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace bitcask::format {

// ---------------------------------------------------------------------------
// 数据文件 record 布局：
//   [0..3]   CRC32       (覆盖 Tstamp..Value 区段)
//   [4..7]   Tstamp      u32 大端
//   [8..9]   KeySz       u16 大端
//   [10..13] ValueSz     u32 大端
//   [14..]   Key | Value
// 总长 = kHeaderSize + KeySz + ValueSz
// ---------------------------------------------------------------------------
inline constexpr std::size_t kHeaderSize = 14;  // 4 + 4 + 2 + 4
inline constexpr std::size_t kCrcOffset = 0;
inline constexpr std::size_t kTstampOffset = 4;
inline constexpr std::size_t kKeySzOffset = 8;
inline constexpr std::size_t kValueSzOffset = 10;

inline constexpr std::uint16_t kMaxKeySize = 0xFFFF;          // 16-bit 字段上限
inline constexpr std::uint32_t kMaxValueSize = 0xFFFF'FFFFu;  // 32-bit 字段上限

// ---------------------------------------------------------------------------
// hint 文件 record 布局（用于 keydir 重建加速；不带 value）：
//   [0..3]   Tstamp      u32 大端
//   [4..5]   KeySz       u16 大端
//   [6..9]   TotalSz     u32 大端 (对应 data file 里整条 record 的 total）
//   [10..17] (Tomb:1<<63) | (Offset:63)，整体 u64 大端
//   [18..]   Key (KeySz 字节)
// 总长 = kHintRecordSize + KeySz
//
// 最高位用于 v2 墓碑标记，其余 63 位是 data file 内偏移（最大 8 EiB）。
// ---------------------------------------------------------------------------
inline constexpr std::size_t kHintRecordSize = 18;  // 4 + 2 + 4 + 8
inline constexpr std::uint64_t kMaxOffsetV2 = 0x7FFF'FFFF'FFFF'FFFFull;
inline constexpr std::uint64_t kTombMaskV2 = 0x8000'0000'0000'0000ull;

// ---------------------------------------------------------------------------
// 墓碑 value（写在 data record 的 VALUE 段，不是单独的 record 类型）：
//   v0: "bitcask_tombstone"             (17 B)
//   v1: "bitcask_tombstone1" + FileId32 (22 B) — 不再生成，仅识别
//   v2: "bitcask_tombstone2" + FileId32 (22 B) — 当前默认
//
// v1/v2 在前缀后面跟 4 字节 file_id：用来区分「这条墓碑是为哪个 data file
// 的某条 entry 而写的」，merge 时校验影子 file_id 仍存活才回收原 entry。
// 详见 cpp/src/cask/cask.cpp 的 put_tombstone 与 merger 的 stale 判定。
// ---------------------------------------------------------------------------
inline constexpr std::string_view kTombstonePrefix = "bitcask_tombstone";
inline constexpr std::string_view kTombstoneV0 = "bitcask_tombstone";
inline constexpr std::string_view kTombstoneV1 = "bitcask_tombstone1";
inline constexpr std::string_view kTombstoneV2 = "bitcask_tombstone2";

inline constexpr std::size_t kTombstoneV0Size = 17;
inline constexpr std::size_t kTombstoneV1Size = 22;  // 18 + 4
inline constexpr std::size_t kTombstoneV2Size = 22;  // 18 + 4
inline constexpr std::size_t kMaxTombstoneSize = kTombstoneV2Size;

// 一条 record 的 value 是否是墓碑：只看 17 字节前缀，对 v0/v1/v2 一视同仁。
[[nodiscard]] constexpr bool is_tombstone_value(std::string_view v) noexcept {
    return v.size() >= kTombstonePrefix.size() &&
           v.substr(0, kTombstonePrefix.size()) == kTombstonePrefix;
}

// ---------------------------------------------------------------------------
// hint 文件的 CRC chunk 大小（解析时做合理性边界检查）。
// hint 末尾 EOF sentinel 的 TotalSz 字段实际放的是 running CRC，参见
// codec.cpp::encode_hint_eof / decode_hint_record。
// ---------------------------------------------------------------------------
inline constexpr std::size_t kChunkSize = 65535;
inline constexpr std::size_t kMinChunkSize = 1024;
inline constexpr std::size_t kMaxChunkSize = 134217728;

}  // namespace bitcask::format
