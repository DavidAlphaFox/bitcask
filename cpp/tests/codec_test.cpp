// codec golden test: locks the on-disk byte layout of bitcask typed-record
// data records, kDoc value packing, and hint records so subsequent changes
// cannot silently drift. See doc/vector-db-design-zh.md §2.

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
// ---------------------------------------------------------------------------
TEST(Crc32, KnownVectors) {
    EXPECT_EQ(codec::crc32({}), 0u);
    EXPECT_EQ(codec::crc32(as_bytes("123456789")), 0xCBF43926u);
    EXPECT_EQ(codec::crc32(as_bytes("hello")), 0x3610A686u);
}

// ---------------------------------------------------------------------------
// Data record golden: byte-by-byte layout for known input.
//   [CRC(4)] [Type(1)] [Tstamp(4)] [Ord(8)] [KeySz(2)] [ValueSz(4)] [Key][Value]
//   CRC covers Type..Value.
// ---------------------------------------------------------------------------
TEST(DataRecord, GoldenLayout) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, RecordType::kDoc, /*tstamp*/ 0x12345678,
                              /*ord*/ 1, as_bytes("k"), as_bytes("vv"));
    ASSERT_EQ(out.size(), kHeaderSize + 1 + 2);

    // Covered region (everything after the 4-byte CRC):
    //   Type:    00
    //   Tstamp:  12 34 56 78
    //   Ord:     00 00 00 00 00 00 00 01
    //   KeySz:   00 01
    //   ValueSz: 00 00 00 02
    //   Key:     6b
    //   Value:   76 76
    auto covered = hex_to_bytes("00" "12345678" "0000000000000001"
                                "0001" "00000002" "6b" "7676");
    const std::uint32_t expected_crc = codec::crc32(covered);

    EXPECT_EQ(out[0], static_cast<std::byte>((expected_crc >> 24) & 0xFF));
    EXPECT_EQ(out[1], static_cast<std::byte>((expected_crc >> 16) & 0xFF));
    EXPECT_EQ(out[2], static_cast<std::byte>((expected_crc >> 8) & 0xFF));
    EXPECT_EQ(out[3], static_cast<std::byte>(expected_crc & 0xFF));
    for (std::size_t i = 0; i < covered.size(); ++i) {
        EXPECT_EQ(out[4 + i], covered[i]) << "mismatch at byte " << (4 + i);
    }
}

// Full pinned hex (incl. CRC) — any silent format drift fails here.
TEST(DataRecord, GoldenHex) {
    std::vector<std::byte> doc;
    codec::encode_data_record(doc, RecordType::kDoc, 0x12345678, 1,
                              as_bytes("k"), as_bytes("vv"));
    EXPECT_EQ(bytes_to_hex(doc),
              "a391d9e0001234567800000000000000010001000000026b7676");

    std::vector<std::byte> tomb;
    codec::encode_data_record(tomb, RecordType::kTombstone, 7, 9,
                              as_bytes("k"), {});
    EXPECT_EQ(bytes_to_hex(tomb),
              "993828e0010000000700000000000000090001000000006b");
}

TEST(DataRecord, RoundTrip) {
    std::vector<std::byte> out;
    const std::string key = "the-key";
    const std::string val(257, 'x');  // crosses the > 255 byte boundary
    codec::encode_data_record(out, RecordType::kDoc, 42, 0xABCDEF0123,
                              as_bytes(key), as_bytes(val));

    auto rec = codec::decode_data_record(out);
    ASSERT_TRUE(rec.has_value()) << "decode failed";
    EXPECT_EQ(rec->type, RecordType::kDoc);
    EXPECT_EQ(rec->tstamp, 42u);
    EXPECT_EQ(rec->ord, 0xABCDEF0123ull);
    EXPECT_EQ(rec->total_size, out.size());
    EXPECT_EQ(rec->key.size(), key.size());
    EXPECT_EQ(rec->value.size(), val.size());
    EXPECT_EQ(0, std::memcmp(rec->key.data(), key.data(), key.size()));
    EXPECT_EQ(0, std::memcmp(rec->value.data(), val.data(), val.size()));
}

TEST(DataRecord, TombstoneRoundTrip) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, RecordType::kTombstone, 7, 9,
                              as_bytes("k"), {});
    auto rec = codec::decode_data_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_EQ(rec->type, RecordType::kTombstone);
    EXPECT_EQ(rec->ord, 9u);
    EXPECT_TRUE(rec->value.empty());
}

TEST(DataRecord, EmptyKeyAndValue) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, RecordType::kDoc, 7, 0, {}, {});
    EXPECT_EQ(out.size(), kHeaderSize);

    auto rec = codec::decode_data_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_EQ(rec->tstamp, 7u);
    EXPECT_TRUE(rec->key.empty());
    EXPECT_TRUE(rec->value.empty());
}

TEST(DataRecord, DetectsBadCrc) {
    std::vector<std::byte> out;
    codec::encode_data_record(out, RecordType::kDoc, 1, 1,
                              as_bytes("k"), as_bytes("v"));
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
    codec::encode_data_record(out, RecordType::kDoc, 1, 1,
                              as_bytes("kkkk"), as_bytes("vvvvvv"));
    out.resize(out.size() - 3);  // truncate value
    auto rec = codec::decode_data_record(out);
    ASSERT_FALSE(rec.has_value());
    EXPECT_EQ(rec.error(), codec::DecodeError::kBufferTooShort);
}

// ---------------------------------------------------------------------------
// kDoc value packing golden (§2.4).
//   [Ver(1)] [Flags(1)] [vector: Dim(4) f32×Dim(LE)] [text: Len(4) bytes] [meta...]
// ---------------------------------------------------------------------------
TEST(DocValue, GoldenHex) {
    // vector [1.0f, 2.0f], text "hi", no meta.
    float vec[2] = {1.0f, 2.0f};
    codec::DocValueParts parts;
    parts.vector = std::span<const float>(vec, 2);
    parts.text   = as_bytes("hi");

    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    // 03           ver = 3（varint 长度 + fieldId）
    // 03           flags = has_vector|has_text
    // 82           dim = 2（varint：末字节高位=终止标记，2|0x80=0x82）
    // 0000803f     1.0f little-endian
    // 00000040     2.0f little-endian
    // 82           text len = 2（varint）
    // 6869         "hi"
    EXPECT_EQ(bytes_to_hex(out), "0303820000803f00000040826869");
}

TEST(DocValue, RoundTripAllSections) {
    float vec[3] = {0.5f, -1.5f, 3.0f};
    const std::string text = "美联储宣布降息";
    const std::array<std::byte, 3> meta = {std::byte{1}, std::byte{2}, std::byte{3}};
    codec::DocValueParts parts;
    parts.vector = std::span<const float>(vec, 3);
    parts.text   = as_bytes(text);
    parts.meta   = std::span<const std::byte>(meta);

    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);

    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(v->ver, kDocValueVersion);
    ASSERT_TRUE(v->has_vector);
    EXPECT_EQ(v->dim, 3u);
    EXPECT_EQ(v->vector_raw.size(), 3u * sizeof(float));
    float back[3];
    std::memcpy(back, v->vector_raw.data(), sizeof(back));
    EXPECT_FLOAT_EQ(back[0], 0.5f);
    EXPECT_FLOAT_EQ(back[1], -1.5f);
    EXPECT_FLOAT_EQ(back[2], 3.0f);
    ASSERT_TRUE(v->has_text);
    EXPECT_EQ(0, std::memcmp(v->text.data(), text.data(), text.size()));
    ASSERT_TRUE(v->has_meta);
    EXPECT_EQ(v->meta.size(), 3u);
}

TEST(DocValue, VectorOnly) {
    float vec[1] = {42.0f};
    codec::DocValueParts parts;
    parts.vector = std::span<const float>(vec, 1);
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);

    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_TRUE(v->has_vector);
    EXPECT_FALSE(v->has_text);
    EXPECT_FALSE(v->has_meta);
    EXPECT_EQ(v->dim, 1u);
}

TEST(DocValue, TextOnly) {
    codec::DocValueParts parts;
    parts.text = as_bytes("plain doc");
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);

    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_FALSE(v->has_vector);
    EXPECT_TRUE(v->has_text);
    EXPECT_EQ(v->text.size(), 9u);
}

TEST(DocValue, RejectsUnsupportedVersion) {
    std::vector<std::byte> out;
    out.push_back(std::byte{0xFE});  // bogus ver
    out.push_back(std::byte{0x00});  // flags
    auto v = codec::decode_doc_value(out);
    ASSERT_FALSE(v.has_value());
    EXPECT_EQ(v.error(), codec::DecodeError::kUnsupportedVersion);
}

TEST(DocValue, DetectsTruncation) {
    float vec[4] = {1, 2, 3, 4};
    codec::DocValueParts parts;
    parts.vector = std::span<const float>(vec, 4);
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    out.resize(out.size() - 5);  // chop into the f32 payload
    auto v = codec::decode_doc_value(out);
    ASSERT_FALSE(v.has_value());
    EXPECT_EQ(v.error(), codec::DecodeError::kBufferTooShort);
}

// --- S8.6: DocValue v2 多字段段 ---

// 空 fields → 不设 has_fields 标记（v3 不再有 v1/v2 区分）。
TEST(DocValue, EmptyFieldsNoFlag) {
    codec::DocValueParts parts;
    parts.text = as_bytes("hello");
    // fields 默认空
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    EXPECT_EQ(static_cast<std::uint8_t>(out[0]), kDocValueVersion);  // Ver=3
    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_FALSE(v->has_fields);
}

// text + 多字段 round-trip（#1）：fields 存 id，值正确、顺序保持。
TEST(DocValue, MultiFieldRoundTrip) {
    const std::string text = "default text";
    const std::string v1s = "BM25 ranking";
    const std::string v2s = "正文内容";
    codec::DocValueParts parts;
    parts.text = as_bytes(text);
    parts.fields.push_back({7, as_bytes(v1s)});   // id=7
    parts.fields.push_back({42, as_bytes(v2s)});  // id=42

    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);

    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(v->ver, kDocValueVersion);  // Ver=3
    ASSERT_TRUE(v->has_text);
    ASSERT_TRUE(v->has_fields);
    ASSERT_EQ(v->fields.size(), 2u);
    auto span_eq = [](std::span<const std::byte> s, const std::string& str) {
        return s.size() == str.size() && std::memcmp(s.data(), str.data(), str.size()) == 0;
    };
    EXPECT_EQ(v->fields[0].id, 7u);
    EXPECT_TRUE(span_eq(v->fields[0].value, v1s));
    EXPECT_EQ(v->fields[1].id, 42u);
    EXPECT_TRUE(span_eq(v->fields[1].value, v2s));
}

// 仅 fields、无 text。
TEST(DocValue, FieldsOnly) {
    const std::string val = "hi";
    codec::DocValueParts parts;
    parts.fields.push_back({3, as_bytes(val)});
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    EXPECT_FALSE(v->has_text);
    ASSERT_EQ(v->fields.size(), 1u);
    EXPECT_EQ(v->fields[0].id, 3u);
}

// 大 field id 走多字节 varint，round-trip 正确。
TEST(DocValue, FieldIdMultibyteVarint) {
    const std::string val = "x";
    codec::DocValueParts parts;
    parts.fields.push_back({300, as_bytes(val)});     // 300 → 2 字节 varint
    parts.fields.push_back({1000000, as_bytes(val)}); // 大 id
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    auto v = codec::decode_doc_value(out);
    ASSERT_TRUE(v.has_value());
    ASSERT_EQ(v->fields.size(), 2u);
    EXPECT_EQ(v->fields[0].id, 300u);
    EXPECT_EQ(v->fields[1].id, 1000000u);
}

// fields 段被截断 → kBufferTooShort，不崩。
TEST(DocValue, DetectsFieldsTruncation) {
    const std::string val = "some value here";
    codec::DocValueParts parts;
    parts.fields.push_back({1, as_bytes(val)});
    std::vector<std::byte> out;
    codec::encode_doc_value(out, parts);
    out.resize(out.size() - 3);  // 砍进字段 value
    auto v = codec::decode_doc_value(out);
    ASSERT_FALSE(v.has_value());
    EXPECT_EQ(v.error(), codec::DecodeError::kBufferTooShort);
}

// ---------------------------------------------------------------------------
// Hint record golden (format unchanged in V1).
// ---------------------------------------------------------------------------
TEST(HintRecord, GoldenLayoutNonTombstone) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 0xDEADBEEF, 0x00000010,
                              0x0000000001020304ull, false, as_bytes("ab"));
    auto expected = hex_to_bytes("deadbeef" "0002" "00000010"
                                 "0000000001020304" "6162");
    ASSERT_EQ(out.size(), expected.size());
    EXPECT_EQ(bytes_to_hex(out), bytes_to_hex(expected));
}

TEST(HintRecord, GoldenLayoutTombstoneSetsHighBit) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 1, 22, 0x10, true, as_bytes("k"));
    EXPECT_EQ(static_cast<std::uint8_t>(out[10]) & 0x80u, 0x80u);
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
    codec::encode_hint_record(out, 1, 14, kMaxOffsetV2, false, as_bytes("k"));
    auto rec = codec::decode_hint_record(out);
    ASSERT_TRUE(rec.has_value());
    EXPECT_EQ(rec->offset, kMaxOffsetV2);
    EXPECT_FALSE(rec->tombstone);
}

TEST(HintRecord, RoundTripStreamOfRecords) {
    std::vector<std::byte> out;
    codec::encode_hint_record(out, 1, 100, 0,   false, as_bytes("a"));
    codec::encode_hint_record(out, 2, 200, 100, true,  as_bytes("bb"));
    codec::encode_hint_record(out, 3, 300, 300, false, as_bytes("ccc"));

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
// Layout constants are part of the on-disk contract.
// ---------------------------------------------------------------------------
TEST(Layout, ConstantsLocked) {
    EXPECT_EQ(format::kHeaderSize, 23u);  // 4+1+4+8+2+4
    EXPECT_EQ(format::kCrcOffset, 0u);
    EXPECT_EQ(format::kTypeOffset, 4u);
    EXPECT_EQ(format::kTstampOffset, 5u);
    EXPECT_EQ(format::kOrdOffset, 9u);
    EXPECT_EQ(format::kKeySzOffset, 17u);
    EXPECT_EQ(format::kValueSzOffset, 19u);
    EXPECT_EQ(format::kHintRecordSize, 18u);
    EXPECT_EQ(format::kMaxOffsetV2, 0x7FFFFFFFFFFFFFFFull);
    EXPECT_EQ(format::kMaxKeySize, 0xFFFFu);
    EXPECT_EQ(format::kMaxValueSize, 0xFFFFFFFFu);
    EXPECT_EQ(static_cast<std::uint8_t>(format::RecordType::kDoc), 0u);
    EXPECT_EQ(static_cast<std::uint8_t>(format::RecordType::kTombstone), 1u);
}
