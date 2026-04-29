#include "bitcask/codec.hpp"

#include <bit>
#include <cassert>
#include <cstring>

#include <zlib.h>

#include "bitcask/format.hpp"

namespace bitcask::codec {

namespace {

// Big-endian load/store helpers. Bitcask records are big-endian on disk
// (Erlang's default <<X:N>> bit syntax).
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

std::uint32_t crc32(std::span<const std::byte> data) noexcept {
    return crc32_update(0, data);
}

std::uint32_t crc32_update(std::uint32_t seed,
                           std::span<const std::byte> data) noexcept {
    return static_cast<std::uint32_t>(
        ::crc32(static_cast<uLong>(seed),
                reinterpret_cast<const Bytef*>(data.data()),
                static_cast<uInt>(data.size())));
}

// ---------------------------------------------------------------------------
// Data record
// ---------------------------------------------------------------------------

std::size_t encode_data_record(std::vector<std::byte>& out,
                               std::uint32_t tstamp,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value) {
    assert(key.size() <= format::kMaxKeySize);
    assert(value.size() <= format::kMaxValueSize);

    const std::size_t total = format::kHeaderSize + key.size() + value.size();
    const std::size_t base = out.size();
    out.resize(base + total);
    std::byte* p = out.data() + base;

    // Layout: [CRC|Tstamp|KeySz|ValueSz|Key|Value]. CRC covers everything
    // after itself.
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

std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf) {
    if (buf.size() < format::kHeaderSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint32_t crc      = be_load_u32(buf.data() + format::kCrcOffset);
    const std::uint32_t tstamp   = be_load_u32(buf.data() + format::kTstampOffset);
    const std::uint16_t key_sz   = be_load_u16(buf.data() + format::kKeySzOffset);
    const std::uint32_t value_sz = be_load_u32(buf.data() + format::kValueSzOffset);

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
// Hint record
// ---------------------------------------------------------------------------

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

    const std::uint64_t packed =
        (tombstone ? format::kTombMaskV2 : 0ull) | offset;
    be_store_u64(p + 10, packed);

    if (!key.empty()) std::memcpy(p + format::kHintRecordSize, key.data(), key.size());
    return total;
}

std::size_t encode_hint_eof(std::vector<std::byte>& out, std::uint32_t running_crc) {
    // Same layout as a normal hint record, but Tstamp=0, KeySz=0,
    // TotalSz carries the CRC, Tomb=0, Offset=kMaxOffsetV2, no key payload.
    return encode_hint_record(out,
                              /*tstamp*/ 0,
                              /*total_sz*/ running_crc,
                              /*offset*/ format::kMaxOffsetV2,
                              /*tombstone*/ false,
                              {});
}

std::expected<HintRecord, DecodeError>
decode_hint_record(std::span<const std::byte> buf) {
    if (buf.size() < format::kHintRecordSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint32_t tstamp   = be_load_u32(buf.data() + 0);
    const std::uint16_t key_sz   = be_load_u16(buf.data() + 4);
    const std::uint32_t total_sz = be_load_u32(buf.data() + 6);
    const std::uint64_t packed   = be_load_u64(buf.data() + 10);

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
