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
                               format::RecordType type,
                               std::uint32_t tstamp,
                               std::uint64_t ord,
                               std::span<const std::byte> key,
                               std::span<const std::byte> value) {
    assert(key.size() <= format::kMaxKeySize);
    assert(value.size() <= format::kMaxValueSize);

    // resize 一次性预留空间：避免 push_back 多次 realloc。
    const std::size_t total = format::kHeaderSize + key.size() + value.size();
    const std::size_t base = out.size();
    out.resize(base + total);
    std::byte* p = out.data() + base;

    // 布局: [CRC|Type|Tstamp|Ord|KeySz|ValueSz|Key|Value]。
    // CRC 覆盖它自身之后的全部字节（即 Type..Value）。
    p[format::kTypeOffset] = static_cast<std::byte>(type);
    be_store_u32(p + format::kTstampOffset, tstamp);
    be_store_u64(p + format::kOrdOffset, ord);
    be_store_u16(p + format::kKeySzOffset, static_cast<std::uint16_t>(key.size()));
    be_store_u32(p + format::kValueSzOffset, static_cast<std::uint32_t>(value.size()));
    if (!key.empty()) std::memcpy(p + format::kHeaderSize, key.data(), key.size());
    if (!value.empty()) std::memcpy(p + format::kHeaderSize + key.size(),
                                    value.data(), value.size());

    const std::span<const std::byte> covered{p + format::kTypeOffset,
                                              total - format::kTypeOffset};
    be_store_u32(p + format::kCrcOffset, crc32(covered));
    return total;
}

// 从 buf 头部解一条 data record，校验 CRC 后返回 view（zero-copy）。
// 不修改 buf；caller 负责用 result.total_size 推进自己的指针。
std::expected<DataRecordView, DecodeError>
decode_data_record(std::span<const std::byte> buf) {
    // 第一道关：连固定 header 都读不全 → kBufferTooShort
    if (buf.size() < format::kHeaderSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint32_t crc      = be_load_u32(buf.data() + format::kCrcOffset);
    const auto          type     = static_cast<format::RecordType>(
                                       buf.data()[format::kTypeOffset]);
    const std::uint32_t tstamp   = be_load_u32(buf.data() + format::kTstampOffset);
    const std::uint64_t ord      = be_load_u64(buf.data() + format::kOrdOffset);
    const std::uint16_t key_sz   = be_load_u16(buf.data() + format::kKeySzOffset);
    const std::uint32_t value_sz = be_load_u32(buf.data() + format::kValueSzOffset);

    // 第二道关：header 说有 N 字节 body 但 buf 不够长 → kBufferTooShort
    const std::size_t total = format::kHeaderSize + key_sz + value_sz;
    if (buf.size() < total) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }

    const std::span<const std::byte> covered{
        buf.data() + format::kTypeOffset, total - format::kTypeOffset};
    if (crc32(covered) != crc) {
        return std::unexpected(DecodeError::kBadCrc);
    }

    return DataRecordView{
        .crc = crc,
        .type = type,
        .tstamp = tstamp,
        .ord = ord,
        .key = buf.subspan(format::kHeaderSize, key_sz),
        .value = buf.subspan(format::kHeaderSize + key_sz, value_sz),
        .total_size = total,
    };
}

// ---------------------------------------------------------------------------
// kDoc value 打包/解包（§2.4）
// ---------------------------------------------------------------------------

// 向量 f32 数组固定小端存储。V1 只目标 LE 主机（x86/ARM64），此处直接 memcpy；
// BE 主机会在这里编译失败而非静默写出错误字节序。
static_assert(std::endian::native == std::endian::little,
              "kDoc value 的 f32 向量按小端存储，当前仅支持小端主机");

std::size_t encode_doc_value(std::vector<std::byte>& out, const DocValueParts& parts) {
    const std::size_t base = out.size();

    const bool has_fields = !parts.fields.empty();

    std::uint8_t flags = 0;
    if (parts.vector) flags |= format::kFlagHasVector;
    if (parts.text)   flags |= format::kFlagHasText;
    if (parts.meta)   flags |= format::kFlagHasMeta;
    if (has_fields)   flags |= format::kFlagHasFields;

    // 仅当存在 fields 段时升版本为 v2；否则写 v1，字节与旧实现完全一致（S8.6）。
    out.push_back(static_cast<std::byte>(
        has_fields ? format::kDocValueVersionFields : format::kDocValueVersion));
    out.push_back(static_cast<std::byte>(flags));

    // 追加一个「带 u32 大端长度前缀」的字节段。
    auto append_len = [&out](std::uint32_t n) {
        const std::size_t at = out.size();
        out.resize(at + format::kSectionLenSize);
        be_store_u32(out.data() + at, n);
    };

    if (parts.vector) {
        const auto& v = *parts.vector;
        assert(v.size() <= 0xFFFF'FFFFull);
        append_len(static_cast<std::uint32_t>(v.size()));  // Dim
        const std::size_t at = out.size();
        const std::size_t bytes = v.size() * sizeof(float);
        out.resize(at + bytes);
        if (bytes) std::memcpy(out.data() + at, v.data(), bytes);  // f32 LE
    }
    if (parts.text) {
        const auto& t = *parts.text;
        append_len(static_cast<std::uint32_t>(t.size()));
        const std::size_t at = out.size();
        out.resize(at + t.size());
        if (!t.empty()) std::memcpy(out.data() + at, t.data(), t.size());
    }
    if (parts.meta) {
        const auto& m = *parts.meta;
        append_len(static_cast<std::uint32_t>(m.size()));
        const std::size_t at = out.size();
        out.resize(at + m.size());
        if (!m.empty()) std::memcpy(out.data() + at, m.data(), m.size());
    }
    // fields 段（S8.6）：[FieldCount:u16 BE] × { [NameLen:u16][name][ValLen:u32][value] }
    if (has_fields) {
        assert(parts.fields.size() <= 0xFFFFu);
        const std::size_t fc_at = out.size();
        out.resize(fc_at + format::kFieldCountSize);
        be_store_u16(out.data() + fc_at,
                     static_cast<std::uint16_t>(parts.fields.size()));
        for (const auto& f : parts.fields) {
            assert(f.name.size() <= 0xFFFFu);
            const std::size_t n_at = out.size();
            out.resize(n_at + format::kFieldNameLenSize);
            be_store_u16(out.data() + n_at, static_cast<std::uint16_t>(f.name.size()));
            const std::size_t nb_at = out.size();
            out.resize(nb_at + f.name.size());
            if (!f.name.empty()) std::memcpy(out.data() + nb_at, f.name.data(), f.name.size());
            append_len(static_cast<std::uint32_t>(f.value.size()));
            const std::size_t vb_at = out.size();
            out.resize(vb_at + f.value.size());
            if (!f.value.empty()) std::memcpy(out.data() + vb_at, f.value.data(), f.value.size());
        }
    }
    return out.size() - base;
}

std::expected<DocValueView, DecodeError>
decode_doc_value(std::span<const std::byte> buf) {
    if (buf.size() < format::kDocValueHeaderSize) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    const std::uint8_t ver   = static_cast<std::uint8_t>(buf[0]);
    const std::uint8_t flags = static_cast<std::uint8_t>(buf[1]);
    // 范围式版本兼容（S8.6）：v1（无 fields）与 v2（含 fields 段）都接受。
    if (ver != format::kDocValueVersion && ver != format::kDocValueVersionFields) {
        return std::unexpected(DecodeError::kUnsupportedVersion);
    }

    DocValueView v{};
    v.ver           = ver;
    v.has_vector    = (flags & format::kFlagHasVector) != 0;
    v.has_text      = (flags & format::kFlagHasText) != 0;
    v.has_meta      = (flags & format::kFlagHasMeta) != 0;
    v.has_fields    = (flags & format::kFlagHasFields) != 0;
    v.vec_quantized = (flags & format::kFlagVecQuantized) != 0;

    std::size_t pos = format::kDocValueHeaderSize;

    // 读一个 [u32 大端字节长度][payload] 段（text/meta 用），推进 pos。
    auto read_bytes_section =
        [&buf, &pos](std::span<const std::byte>& out_span) -> bool {
        if (buf.size() < pos + format::kSectionLenSize) return false;
        const std::uint32_t len = be_load_u32(buf.data() + pos);
        pos += format::kSectionLenSize;
        if (buf.size() < pos + len) return false;
        out_span = buf.subspan(pos, len);
        pos += len;
        return true;
    };

    if (v.has_vector) {
        // vector 段：[Dim:u32 元素个数][f32×Dim 小端]。Dim 是元素数、非字节数。
        // 量化布局（vec_quantized）留待后续，V1 不写也不读。
        if (v.vec_quantized) {
            return std::unexpected(DecodeError::kUnsupportedVersion);
        }
        if (buf.size() < pos + format::kSectionLenSize) {
            return std::unexpected(DecodeError::kBufferTooShort);
        }
        const std::uint32_t dim = be_load_u32(buf.data() + pos);
        pos += format::kSectionLenSize;
        const std::size_t bytes = static_cast<std::size_t>(dim) * sizeof(float);
        if (buf.size() < pos + bytes) {
            return std::unexpected(DecodeError::kBufferTooShort);
        }
        v.dim = dim;
        v.vector_raw = buf.subspan(pos, bytes);
        pos += bytes;
    }
    if (v.has_text && !read_bytes_section(v.text)) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    if (v.has_meta && !read_bytes_section(v.meta)) {
        return std::unexpected(DecodeError::kBufferTooShort);
    }
    // fields 段（S8.6）：[FieldCount:u16] × { [NameLen:u16][name][ValLen:u32][value] }
    if (v.has_fields) {
        if (buf.size() < pos + format::kFieldCountSize) {
            return std::unexpected(DecodeError::kBufferTooShort);
        }
        const std::uint16_t fc = be_load_u16(buf.data() + pos);
        pos += format::kFieldCountSize;
        v.fields.reserve(fc);
        for (std::uint16_t i = 0; i < fc; ++i) {
            if (buf.size() < pos + format::kFieldNameLenSize) {
                return std::unexpected(DecodeError::kBufferTooShort);
            }
            const std::uint16_t nlen = be_load_u16(buf.data() + pos);
            pos += format::kFieldNameLenSize;
            if (buf.size() < pos + nlen) return std::unexpected(DecodeError::kBufferTooShort);
            DocField f;
            f.name = buf.subspan(pos, nlen);
            pos += nlen;
            if (!read_bytes_section(f.value)) {
                return std::unexpected(DecodeError::kBufferTooShort);
            }
            v.fields.push_back(f);
        }
    }
    return v;
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
