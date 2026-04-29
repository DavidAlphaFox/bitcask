// Bitcask on-disk format constants.
// Mirrored 1:1 from include/bitcask.hrl. Any change here is a binary
// compatibility break and must be reviewed against M0 golden tests.

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace bitcask::format {

// ---------------------------------------------------------------------------
// Data file record:
//   [0..3]   CRC32       (covers Tstamp..Value)
//   [4..7]   Tstamp      u32 BE
//   [8..9]   KeySz       u16 BE
//   [10..13] ValueSz     u32 BE
//   [14..]   Key | Value
// total = kHeaderSize + KeySz + ValueSz
// ---------------------------------------------------------------------------
inline constexpr std::size_t kHeaderSize = 14;  // 4 + 4 + 2 + 4
inline constexpr std::size_t kCrcOffset = 0;
inline constexpr std::size_t kTstampOffset = 4;
inline constexpr std::size_t kKeySzOffset = 8;
inline constexpr std::size_t kValueSzOffset = 10;

inline constexpr std::uint16_t kMaxKeySize = 0xFFFF;
inline constexpr std::uint32_t kMaxValueSize = 0xFFFF'FFFFu;

// ---------------------------------------------------------------------------
// Hint file record:
//   [0..3]   Tstamp      u32 BE
//   [4..5]   KeySz       u16 BE
//   [6..9]   TotalSz     u32 BE
//   [10..17] (Tomb:1 << 63) | (Offset:63), packed as u64 BE
//   [18..]   Key (KeySz bytes)
// total = kHintRecordSize + KeySz
// ---------------------------------------------------------------------------
inline constexpr std::size_t kHintRecordSize = 18;  // 4 + 2 + 4 + 8
inline constexpr std::uint64_t kMaxOffsetV2 = 0x7FFF'FFFF'FFFF'FFFFull;
inline constexpr std::uint64_t kTombMaskV2 = 0x8000'0000'0000'0000ull;

// ---------------------------------------------------------------------------
// Tombstone values written as record VALUE (not the record itself).
//   v0: "bitcask_tombstone"             (17 B)
//   v1: "bitcask_tombstone1" + FileId32 (22 B)
//   v2: "bitcask_tombstone2" + FileId32 (22 B)
// ---------------------------------------------------------------------------
inline constexpr std::string_view kTombstonePrefix = "bitcask_tombstone";
inline constexpr std::string_view kTombstoneV0 = "bitcask_tombstone";
inline constexpr std::string_view kTombstoneV1 = "bitcask_tombstone1";
inline constexpr std::string_view kTombstoneV2 = "bitcask_tombstone2";

inline constexpr std::size_t kTombstoneV0Size = 17;
inline constexpr std::size_t kTombstoneV1Size = 22;  // 18 + 4
inline constexpr std::size_t kTombstoneV2Size = 22;  // 18 + 4
inline constexpr std::size_t kMaxTombstoneSize = kTombstoneV2Size;

[[nodiscard]] constexpr bool is_tombstone_value(std::string_view v) noexcept {
    return v.size() >= kTombstonePrefix.size() &&
           v.substr(0, kTombstonePrefix.size()) == kTombstonePrefix;
}

// ---------------------------------------------------------------------------
// Hint file CRC chunking (parser uses these as sanity bounds).
// ---------------------------------------------------------------------------
inline constexpr std::size_t kChunkSize = 65535;
inline constexpr std::size_t kMinChunkSize = 1024;
inline constexpr std::size_t kMaxChunkSize = 134217728;

}  // namespace bitcask::format
