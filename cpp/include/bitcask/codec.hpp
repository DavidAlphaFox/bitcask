// Encode/decode for bitcask data file and hint file records.
// Pure functions over byte buffers — no I/O, no allocation beyond the
// caller-provided output container. Format defined in format.hpp.

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace bitcask::codec {

enum class DecodeError {
    kBufferTooShort,
    kBadCrc,
    kKeySizeOverflow,
    kValueSizeOverflow,
};

struct DataRecordView {
    std::uint32_t crc;
    std::uint32_t tstamp;
    std::span<const std::byte> key;
    std::span<const std::byte> value;
    std::size_t total_size;  // kHeaderSize + key.size() + value.size()
};

struct HintRecord {
    std::uint32_t tstamp;
    std::uint32_t total_sz;
    std::uint64_t offset;   // 63-bit
    bool tombstone;
    std::span<const std::byte> key;
    std::size_t consumed;   // bytes read from input (kHintRecordSize + key.size())
};

// ---------------------------------------------------------------------------
// Data file record.
// ---------------------------------------------------------------------------

// Encodes a data record into `out` (appended). Returns total bytes written
// (== kHeaderSize + key.size() + value.size()).
std::size_t encode_data_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value);

// Decodes the next data record from the head of `buf`. CRC verified.
[[nodiscard]] std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf);

// ---------------------------------------------------------------------------
// Hint file record.
// ---------------------------------------------------------------------------

// Encodes a hint record into `out` (appended). Caller asserts
// offset <= kMaxOffsetV2. Returns total bytes written.
std::size_t encode_hint_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::uint32_t total_sz,
                               std::uint64_t offset,
                               bool tombstone,
                               std::span<const std::byte> key);

// Encodes the EOF sentinel record:
//   Tstamp=0, KeySz=0, TotalSz=running_crc, Tomb=0, Offset=kMaxOffsetV2
std::size_t encode_hint_eof(std::vector<std::byte>& out, std::uint32_t running_crc);

// Decodes the next hint record from the head of `buf`.
// Returns the EOF sentinel as a HintRecord with key.empty() and
// offset == kMaxOffsetV2.
[[nodiscard]] std::expected<HintRecord, DecodeError>
decode_hint_record(std::span<const std::byte> buf);

[[nodiscard]] bool is_hint_eof(const HintRecord& r) noexcept;

// ---------------------------------------------------------------------------
// CRC32 (zlib / IEEE 802.3 polynomial — same as erlang:crc32/1).
// ---------------------------------------------------------------------------
[[nodiscard]] std::uint32_t crc32(std::span<const std::byte> data) noexcept;
[[nodiscard]] std::uint32_t crc32_update(std::uint32_t seed,
                                         std::span<const std::byte> data) noexcept;

}  // namespace bitcask::codec
