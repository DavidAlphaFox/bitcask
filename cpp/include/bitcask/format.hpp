// bitcask 磁盘格式常量（向量库 typed record）。
//
// 这里的所有数字、字段顺序都是「磁盘契约」的一部分，改一处就是
// binary-incompatible 变更，必须同步更新黄金测试
// （cpp/tests/codec_test.cpp、data_file_test.cpp 里有跟二进制 fixture 的
// 字节级比对）。设计见 doc/vector-db-design-zh.md §2。
//
// === 线程模型 ===
// 全部为 inline constexpr 常量 + enum。
//   - 可重入 / 线程安全：是（无可变状态）。
//   - 锁要求：无。

#pragma once

#include <cstddef>
#include <cstdint>

namespace bitcask::format {

// ---------------------------------------------------------------------------
// 数据文件 record 布局（向量库 typed record，V1）：
//   [0..3]   CRC32       (覆盖 Type..Value 区段，即 [4..] 全部)
//   [4]      Type        u8   (RecordType：kDoc / kTombstone)
//   [5..8]   Tstamp      u32 大端
//   [9..16]  Ord         u64 大端 (引擎单调分配的写入序号，per-write，永不复用)
//   [17..18] KeySz       u16 大端 (key == ext_id)
//   [19..22] ValueSz     u32 大端 (kDoc 时是打包 value；kTombstone 时通常为 0)
//   [23..]   Key | Value
// 总长 = kHeaderSize + KeySz + ValueSz
//
// 设计依据见 doc/vector-db-design-zh.md §2.2。CRC 覆盖范围从 Type 开始
// （含 ord），而非 legacy 的 Tstamp 起。
// ---------------------------------------------------------------------------
inline constexpr std::size_t kHeaderSize = 23;  // 4 + 1 + 4 + 8 + 2 + 4
inline constexpr std::size_t kCrcOffset = 0;
inline constexpr std::size_t kTypeOffset = 4;
inline constexpr std::size_t kTstampOffset = 5;
inline constexpr std::size_t kOrdOffset = 9;
inline constexpr std::size_t kKeySzOffset = 17;
inline constexpr std::size_t kValueSzOffset = 19;

inline constexpr std::uint16_t kMaxKeySize = 0xFFFF;          // 16-bit 字段上限
inline constexpr std::uint32_t kMaxValueSize = 0xFFFF'FFFFu;  // 32-bit 字段上限

// record 类型（Type 字段，u8）。墓碑不再靠 value 魔法串识别，而是一等 record 类型。
enum class RecordType : std::uint8_t {
    kDoc       = 0,  // 一条文档：value 是 §2.4 打包的 {vector,text,meta}
    kTombstone = 1,  // 删除标记：value 通常为空，target 由 Key=ext_id + Ord 确定
};

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
// kDoc value 打包布局（写在 kDoc record 的 VALUE 段）。设计见 §2.4：
//   [0]      Ver         u8   (布局版本号，当前 = kDocValueVersion)
//   [1]      Flags       u8   (见下方 kFlag* 位)
//   [可选] vector 段：  [Dim:u32 大端][ f32×Dim 小端  或  量化码字 ]
//   [可选] text   段：  [Len:u32 大端][ utf8 字节 ]
//   [可选] meta   段：  [Len:u32 大端][ 序列化字节(msgpack/CBOR) ]
//   [可选] fields 段（v2，S8.6）：[FieldCount:u16 大端] ×
//          { [NameLen:u16 大端][name utf8][ValLen:u32 大端][value utf8] }
// 各段按 vector→text→meta→fields 定序出现，由 Flags 决定是否存在（向量段放
// 最前，便于 HNSW 重建按 Dim O(1) 切片）。
//
// 字节序：长度类整数(Dim/Len)大端，沿用本文件契约；向量 f32 数组固定小端
// （x86/ARM64 原生零转换，见 §2.4）。
//
// 版本兼容（S8.6）：encode 仅当存在 fields 段时写 Ver=2，否则写 Ver=1，字节
// 与旧实现完全一致；decode 接受 Ver∈{1,2}（范围式兼容，参考 inverted 的 S9.27）。
// ---------------------------------------------------------------------------
inline constexpr std::uint8_t kDocValueVersion       = 1;  // 默认（无 fields 段）
inline constexpr std::uint8_t kDocValueVersionFields = 2;  // 含 fields 段（S8.6）
inline constexpr std::size_t  kDocValueHeaderSize = 2;  // Ver + Flags
inline constexpr std::size_t  kSectionLenSize     = 4;  // 各段 Dim/Len 字段宽度
inline constexpr std::size_t  kFieldCountSize     = 2;  // fields 段 FieldCount 宽度
inline constexpr std::size_t  kFieldNameLenSize   = 2;  // 字段名长度宽度

inline constexpr std::uint8_t kFlagHasVector    = 0x01;
inline constexpr std::uint8_t kFlagHasText      = 0x02;
inline constexpr std::uint8_t kFlagHasMeta      = 0x04;
inline constexpr std::uint8_t kFlagVecQuantized = 0x08;
inline constexpr std::uint8_t kFlagHasFields    = 0x10;  // fields 段存在（S8.6）

// ---------------------------------------------------------------------------
// hint 文件的 CRC chunk 大小（解析时做合理性边界检查）。
// hint 末尾 EOF sentinel 的 TotalSz 字段实际放的是 running CRC，参见
// codec.cpp::encode_hint_eof / decode_hint_record。
// ---------------------------------------------------------------------------
inline constexpr std::size_t kChunkSize = 65535;
inline constexpr std::size_t kMinChunkSize = 1024;
inline constexpr std::size_t kMaxChunkSize = 134217728;

}  // namespace bitcask::format
