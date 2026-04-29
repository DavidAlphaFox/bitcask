// M0 codec golden test: locks the on-disk byte layout of bitcask data
// records and hint records so subsequent C++ rewrites cannot drift.

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/codec.hpp"
#include "bitcask/format.hpp"

using namespace bitcask;
using namespace bitcask::format;

namespace {

std::span<const std::byte> as_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

std::vector<std::byte> hex_to_bytes(std::string_view hex) {
    std::vector<std::byte> out;
    out.reserve(hex.size() / 2);
    auto nyb = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return 10 + c - 'a';
        if (c >= 'A' && c <= 'F') return 10 + c - 'A';
        return -1;
    };
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<std::byte>(
            (nyb(hex[i]) << 4) | nyb(hex[i + 1])));
    }
    return out;
}

std::string bytes_to_hex(std::span<const std::byte> b) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.resize(b.size() * 2);
    for (std::size_t i = 0; i < b.size(); ++i) {
        const auto v = static_cast<std::uint8_t>(b[i]);
        out[2 * i + 0] = kHex[v >> 4];
        out[2 * i + 1] = kHex[v & 0xF];
    }
    return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// CRC32: must match erlang:crc32/1 (zlib / IEEE 802.3).
// Reference vectors generated with: erl -eval 'io:format("~.16B~n",[erlang:crc32(<<"...">>)])'
// ---------------------------------------------------------------------------
TEST(Crc32, KnownVectors) {
    // erlang:crc32(<<>>) = 0
    EXPECT_EQ(codec::crc32({}), 0u);
    // erlang:crc32(<<"123456789">>) = 16#CBF43926
    EXPECT_EQ(codec::crc32(as_bytes("123456789")), 0xCBF43926u);
    // erlang:crc32(<<"hello">>)     = 16#3610A686
    EXPECT_EQ(codec::crc32(as_bytes("hello")), 0x3610A686u);
}

// ---------------------------------------------------------------------------
// Data record golden: byte-by-byte layout for known input.
// ---------------------------------------------------------------------------
TEST(DataRecord, GoldenLayout) {
    const std::uint32_t tstamp = 0x12345678;
    const std::string_view key = "k";
    const std::string_view val = "vv";

    std::vector<std::byte> out;
    const std::size_t n = codec::encode_data_record(out, tstamp,
                                                    as_bytes(key),
                                                    as_bytes(val));
    ASSERT_EQ(n, kHeaderSize + key.size() + val.size());
    ASSERT_EQ(out.size(), n);

    // Hand-checked layout:
    //   crc32 over [Tstamp(4) KeySz(2) ValueSz(4) Key(1) Value(2)]
    //   bytes after CRC:
    //     12 34 56 78  00 01  00 00 00 02  6b  76 76
    static constexpr std::array<std::byte, 10 + 1 + 2> covered = {
        std::byte{0x12}, std::byte{0x34}, std::byte{0x56}, std::byte{0x78},
        std::byte{0x00}, std::byte{0x01},
        std::byte{0x00}, std::byte{0x00}, std::byte{0x00}, std::byte{0x02},
        std::byte{'k'},
        std::byte{'v'}, std::byte{'v'},
    };
    const std::uint32_t expected_crc = codec::crc32(covered);

    EXPECT_EQ(out[0], static_cast<std::byte>((expected_crc >> 24) & 0xFF));
    EXPECT_EQ(out[1], static_cast<std::byte>((expected_crc >> 16) & 0xFF));
    EXPECT_EQ(out[2], static_cast<std::byte>((expected_crc >> 8) & 0xFF));
    EXPECT_EQ(out[3], static_cast<std::byte>(expected_crc & 0xFF));

    // Bytes 4..end must equal the covered region.
    for (std::size_t i = 0; i < covered.size(); ++i) {
        EXPECT_EQ(out[4 + i], covered[i]) << "mismatch at byte " << (4 + i);
    }
}

// Cross-validated against a live `erl` run (Tstamp=0x12345678, Key="k",
// Value="vv") -> bytes `5bb76cce 12345678 0001 00000002 6b 7676`.
// Pinning the exact hex (including CRC) makes any silent format drift fail.
TEST(DataRecord, GoldenFromErlang) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, 0x12345678,
                              as_bytes("k"), as_bytes("vv"));
    EXPECT_EQ(bytes_to_hex(out),
              "5bb76cce123456780001000000026b7676");
}

TEST(HintRecord, GoldenFromErlang) {
    // erl: <<16#deadbeef:32, 2:16, 16#10:32, 0:1, 16#01020304:63, "ab">>
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 0xDEADBEEF, 0x10, 0x01020304ull, false,
                              as_bytes("ab"));
    EXPECT_EQ(bytes_to_hex(out),
              "deadbeef00020000001000000000010203046162");
}

TEST(DataRecord, RoundTrip) {
    std::vector<std::byte> out;
    const std::string key = "the-key";
    const std::string val(257, 'x');  // crosses the > 255 byte boundary
    codec::encode_data_record(out, 42, as_bytes(key), as_bytes(val));

    auto rec = codec::decode_data_record(out);
    ASSERT_TRUE(rec.has_value()) << "decode failed";
    EXPECT_EQ(rec->tstamp, 42u);
    EXPECT_EQ(rec->total_size, out.size());
    EXPECT_EQ(rec->key.size(), key.size());
    EXPECT_EQ(rec->value.size(), val.size());
    EXPECT_EQ(0, std::memcmp(rec->key.data(), key.data(), key.size()));
    EXPECT_EQ(0, std::memcmp(rec->value.data(), val.data(), val.size()));
}

TEST(DataRecord, EmptyKeyAndValue) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, 7, {}, {});
    EXPECT_EQ(out.size(), kHeaderSize);

    auto rec = codec::decode_data_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_EQ(rec->tstamp, 7u);
    EXPECT_TRUE(rec->key.empty());
    EXPECT_TRUE(rec->value.empty());
}

TEST(DataRecord, DetectsBadCrc) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, 1, as_bytes("k"), as_bytes("v"));
    // Flip a bit in the value.
    out.back() = static_cast<std::byte>(static_cast<std::uint8_t>(out.back()) ^ 0x01);
    auto rec = codec::decode_data_record(out);
    ASSERT_FALSE(rec.has_value());
    EXPECT_EQ(rec.error(), codec::DecodeError::kBadCrc);
}

TEST(DataRecord, ShortBufferBeforeHeader) {
    std::vector<std::byte> tiny(5);
    auto rec = codec::decode_data_record(tiny);
    ASSERT_FALSE(rec.has_value());
    EXPECT_EQ(rec.error(), codec::DecodeError::kBufferTooShort);
}

TEST(DataRecord, ShortBufferAfterHeader) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, 1, as_bytes("kkkk"), as_bytes("vvvvvv"));
    out.resize(out.size() - 3);  // truncate value
    auto rec = codec::decode_data_record(out);
    ASSERT_FALSE(rec.has_value());
    EXPECT_EQ(rec.error(), codec::DecodeError::kBufferTooShort);
}

// ---------------------------------------------------------------------------
// Hint record golden.
// ---------------------------------------------------------------------------
TEST(HintRecord, GoldenLayoutNonTombstone) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out,
                              /*tstamp*/ 0xDEADBEEF,
                              /*total_sz*/ 0x00000010,
                              /*offset*/   0x0000000001020304ull,
                              /*tombstone*/ false,
                              as_bytes("ab"));
    // Expected layout:
    //   Tstamp:   de ad be ef
    //   KeySz:    00 02
    //   TotalSz:  00 00 00 10
    //   Tomb|Off: 00 00 00 00 01 02 03 04   (tomb bit clear)
    //   Key:      'a' 'b'
    auto expected = hex_to_bytes("deadbeef" "0002" "00000010"
                                 "0000000001020304" "6162");
    ASSERT_EQ(out.size(), expected.size());
    EXPECT_EQ(bytes_to_hex(out), bytes_to_hex(expected));
}

TEST(HintRecord, GoldenLayoutTombstoneSetsHighBit) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 1, 22, /*offset*/ 0x10, /*tombstone*/ true,
                              as_bytes("k"));
    // First byte of packed offset must have the high bit set.
    EXPECT_EQ(static_cast<std::uint8_t>(out[10]) & 0x80u, 0x80u);
    // Decoding round-trips both flags.
    auto rec = codec::decode_hint_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_TRUE(rec->tombstone);
    EXPECT_EQ(rec->offset, 0x10u);
}

TEST(HintRecord, EofSentinel) {
    std::vector<std::byte> out;
    const std::uint32_t crc = 0xCAFEBABE;
    codec::encode_hint_eof(out, crc);
    ASSERT_EQ(out.size(), kHintRecordSize);

    auto rec = codec::decode_hint_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_TRUE(codec::is_hint_eof(*rec));
    EXPECT_EQ(rec->tstamp, 0u);
    EXPECT_EQ(rec->total_sz, crc);
    EXPECT_EQ(rec->offset, kMaxOffsetV2);
    EXPECT_FALSE(rec->tombstone);
    EXPECT_TRUE(rec->key.empty());
}

TEST(HintRecord, OffsetBoundaryMaxV2) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 1, 14, kMaxOffsetV2, /*tomb*/ false,
                              as_bytes("k"));
    auto rec = codec::decode_hint_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_EQ(rec->offset, kMaxOffsetV2);
    EXPECT_FALSE(rec->tombstone);
}

TEST(HintRecord, RoundTripStreamOfRecords) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 1, 100, 0,    false, as_bytes("a"));
    codec::encode_hint_record(out, 2, 200, 100,  true,  as_bytes("bb"));
    codec::encode_hint_record(out, 3, 300, 300,  false, as_bytes("ccc"));

    std::span<const std::byte> rest = out;
    auto r1 = codec::decode_hint_record(rest); ASSERT_TRUE(r1);
    rest = rest.subspan(r1->consumed);
    auto r2 = codec::decode_hint_record(rest); ASSERT_TRUE(r2);
    rest = rest.subspan(r2->consumed);
    auto r3 = codec::decode_hint_record(rest); ASSERT_TRUE(r3);
    rest = rest.subspan(r3->consumed);
    EXPECT_TRUE(rest.empty());

    EXPECT_EQ(r1->tstamp, 1u); EXPECT_EQ(r1->key.size(), 1u);
    EXPECT_EQ(r2->tstamp, 2u); EXPECT_EQ(r2->key.size(), 2u); EXPECT_TRUE(r2->tombstone);
    EXPECT_EQ(r3->tstamp, 3u); EXPECT_EQ(r3->key.size(), 3u);
}

// ---------------------------------------------------------------------------
// Tombstone value detection.
// ---------------------------------------------------------------------------
TEST(Tombstone, DetectsAllVersions) {
    EXPECT_TRUE(format::is_tombstone_value(format::kTombstoneV0));
    EXPECT_TRUE(format::is_tombstone_value(format::kTombstoneV1));
    EXPECT_TRUE(format::is_tombstone_value(format::kTombstoneV2));
    // V1/V2 with FileId tail
    EXPECT_TRUE(format::is_tombstone_value(
        std::string(format::kTombstoneV1) + std::string(4, '\0')));
    EXPECT_FALSE(format::is_tombstone_value("plain-value"));
    EXPECT_FALSE(format::is_tombstone_value(""));
    EXPECT_FALSE(format::is_tombstone_value("bitcask"));
}

TEST(Tombstone, SizeConstantsMatchHrl) {
    EXPECT_EQ(format::kTombstoneV0Size, 17u);
    EXPECT_EQ(format::kTombstoneV1Size, 22u);
    EXPECT_EQ(format::kTombstoneV2Size, 22u);
    EXPECT_EQ(format::kTombstoneV0.size(), format::kTombstoneV0Size);
    EXPECT_EQ(format::kTombstoneV1.size() + 4, format::kTombstoneV1Size);
    EXPECT_EQ(format::kTombstoneV2.size() + 4, format::kTombstoneV2Size);
}

TEST(Layout, ConstantsMatchHrl) {
    EXPECT_EQ(format::kHeaderSize, 14u);
    EXPECT_EQ(format::kHintRecordSize, 18u);
    EXPECT_EQ(format::kMaxOffsetV2, 0x7FFFFFFFFFFFFFFFull);
    EXPECT_EQ(format::kMaxKeySize, 0xFFFFu);
    EXPECT_EQ(format::kMaxValueSize, 0xFFFFFFFFu);
}
