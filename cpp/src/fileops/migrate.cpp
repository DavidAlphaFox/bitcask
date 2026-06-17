#include "bitcask/migrate.hpp"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <vector>

#include "bitcask/codec.hpp"
#include "bitcask/data_file.hpp"
#include "bitcask/format.hpp"
#include "bitcask/hint_file.hpp"

namespace bitcask::migrate {

namespace fs = std::filesystem;

namespace {

// 旧格式（v1）是大端——本工具是唯一仍需读大端的地方,故 BE 解码器自带,
// 不依赖 codec（codec 已 flag-day 切成小端）。
std::uint16_t be_u16(const std::byte* p) {
    return static_cast<std::uint16_t>(
        (static_cast<std::uint16_t>(p[0]) << 8) | static_cast<std::uint16_t>(p[1]));
}
std::uint32_t be_u32(const std::byte* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24) |
           (static_cast<std::uint32_t>(p[1]) << 16) |
           (static_cast<std::uint32_t>(p[2]) << 8)  |
            static_cast<std::uint32_t>(p[3]);
}
std::uint64_t be_u64(const std::byte* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | static_cast<std::uint64_t>(p[i]);
    return v;
}

std::expected<std::vector<std::byte>, std::string>
read_all(const fs::path& path) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return std::unexpected("cannot open " + path.string());
    std::fseek(f, 0, SEEK_END);
    const long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<std::byte> buf(sz > 0 ? static_cast<std::size_t>(sz) : 0);
    const bool ok =
        buf.empty() || std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!ok) return std::unexpected("short read " + path.string());
    return buf;
}

std::expected<void, std::string>
write_all(const fs::path& path, std::span<const std::byte> bytes) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return std::unexpected("cannot create " + path.string());
    const bool ok =
        bytes.empty() ||
        std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
    std::fclose(f);
    if (!ok) return std::unexpected("write failed " + path.string());
    return {};
}

// 一个 data 文件：逐 record 解大端头 → 小端重编码 + 重生成 hint。
std::expected<void, std::string>
migrate_data_file(const fs::path& src_data, const fs::path& dst_dir,
                  MigrateStats& st) {
    auto bytes = read_all(src_data);
    if (!bytes) return std::unexpected(bytes.error());

    const auto name = src_data.filename().string();
    const auto dst_data_path = (dst_dir / name).string();
    const auto dst_hint_path =
        fileops::mk_hint_filename(dst_data_path);

    // 小端写：DataFile/HintFile 内部用新（小端）codec,CRC/水位重算。
    auto dst_data = fileops::DataFile::open(
        dst_data_path, fileops::DataFile::Mode::kCreate, /*sync*/ false,
        /*mmap_enabled*/ false);
    if (!dst_data) return std::unexpected("create dst data " + dst_data_path);
    auto dst_hint = fileops::HintFile::open(
        dst_hint_path, fileops::HintFile::Mode::kCreate);
    if (!dst_hint) return std::unexpected("create dst hint " + dst_hint_path);

    const std::byte* base = bytes->data();
    const std::uint64_t total = bytes->size();
    std::uint64_t off = 0;
    while (off + format::kHeaderSize <= total) {
        const std::byte* p = base + off;
        const std::uint16_t key_sz = be_u16(p + format::kKeySzOffset);
        const std::uint32_t value_sz = be_u32(p + format::kValueSzOffset);
        const std::uint64_t rec_total =
            format::kHeaderSize + static_cast<std::uint64_t>(key_sz) + value_sz;
        if (off + rec_total > total) break;  // torn tail：尾部截断,停。

        // 旧 CRC 校验（大端存储,覆盖 Type..Value）。坏的跳过（与恢复同策略）。
        const std::uint32_t stored_crc = be_u32(p + format::kCrcOffset);
        const std::uint32_t calc_crc = codec::crc32(std::span<const std::byte>(
            p + 4, static_cast<std::size_t>(rec_total) - 4));
        if (stored_crc != calc_crc) {
            ++st.skipped_bad_crc;
            off += rec_total;
            continue;
        }

        const auto type = static_cast<format::RecordType>(p[format::kTypeOffset]);
        const std::uint32_t tstamp = be_u32(p + format::kTstampOffset);
        const std::uint64_t ord = be_u64(p + format::kOrdOffset);
        std::span<const std::byte> key(p + format::kHeaderSize, key_sz);
        std::span<const std::byte> value(p + format::kHeaderSize + key_sz,
                                         value_sz);
        const bool tomb = (type == format::RecordType::kTombstone);

        // 墓碑 v2 shadow file_id 是 4 字节大端值 → 重排成小端,与新格式一致。
        std::vector<std::byte> shadow_le;
        if (tomb && value_sz == 4) {
            const std::uint32_t fid = be_u32(value.data());
            shadow_le = {static_cast<std::byte>(fid & 0xFF),
                         static_cast<std::byte>((fid >> 8) & 0xFF),
                         static_cast<std::byte>((fid >> 16) & 0xFF),
                         static_cast<std::byte>((fid >> 24) & 0xFF)};
            value = std::span<const std::byte>(shadow_le);
        }

        auto w = dst_data->write(type, tstamp, ord, key, value);
        if (!w) return std::unexpected("write record to " + dst_data_path);
        auto h = dst_hint->write(tstamp, w->total_size, w->offset, tomb, key);
        if (!h) return std::unexpected("write hint to " + dst_hint_path);

        ++st.records;
        if (tomb) ++st.tombstones;
        off += rec_total;
    }
    if (auto r = dst_hint->finalize(); !r) {
        return std::unexpected("finalize hint " + dst_hint_path);
    }
    ++st.data_files;
    return {};
}

std::expected<void, std::string>
migrate_meta(const fs::path& src_dir, const fs::path& dst_dir,
             MigrateStats& st) {
    const auto src_meta = src_dir / "bitcask.meta";
    if (!fs::exists(src_meta)) {
        return std::unexpected("no bitcask.meta in src (not a bitcask dir)");
    }
    auto bytes = read_all(src_meta);
    if (!bytes) return std::unexpected(bytes.error());
    if (bytes->size() < 18) return std::unexpected("meta too short");
    const std::byte* b = bytes->data();
    if (std::memcmp(b, "BCME", 4) != 0) return std::unexpected("bad meta magic");
    const auto ver = static_cast<std::uint8_t>(b[4]);
    if (ver == 2) {
        return std::unexpected("src meta already v2 (little-endian); "
                               "nothing to migrate");
    }
    if (ver != 1) return std::unexpected("unknown meta version");

    // v1 → v2：version 字节改 2,VecDim u16 大端→小端,其余单字节字段照搬。
    std::byte out[18] = {};
    std::memcpy(out, "BCME", 4);
    out[4] = static_cast<std::byte>(2);            // version 2
    out[5] = b[5];                                 // mode
    out[6] = b[6];                                 // vec metric
    const std::uint16_t dim = be_u16(b + 7);       // 旧大端 → 主机
    out[7] = static_cast<std::byte>(dim & 0xFF);   // 小端
    out[8] = static_cast<std::byte>((dim >> 8) & 0xFF);
    out[9] = b[9];                                 // vec quantized
    out[10] = b[10];                               // vec inmem_int8
    // out[11..17] 保留全零
    if (auto r = write_all(dst_dir / "bitcask.meta",
                           std::span<const std::byte>(out, 18)); !r) {
        return std::unexpected(r.error());
    }
    st.meta_migrated = true;
    return {};
}

std::expected<void, std::string>
migrate_field_schema(const fs::path& src_dir, const fs::path& dst_dir,
                     MigrateStats& st) {
    const auto src_fs = src_dir / "field.schema";
    if (!fs::exists(src_fs)) return {};  // 无字段表（纯 KV）→ 跳过。
    auto bytes = read_all(src_fs);
    if (!bytes) return std::unexpected(bytes.error());

    std::vector<std::byte> out;
    out.reserve(bytes->size());
    const std::byte* b = bytes->data();
    const std::size_t n = bytes->size();
    std::size_t pos = 0;
    while (pos + 2 <= n) {
        const std::uint16_t nlen = be_u16(b + pos);  // 旧大端
        pos += 2;
        if (pos + nlen > n) break;  // 截断,停。
        out.push_back(static_cast<std::byte>(nlen & 0xFF));         // 小端
        out.push_back(static_cast<std::byte>((nlen >> 8) & 0xFF));
        out.insert(out.end(), b + pos, b + pos + nlen);
        pos += nlen;
    }
    if (auto r = write_all(dst_dir / "field.schema", out); !r) {
        return std::unexpected(r.error());
    }
    st.field_schema_migrated = true;
    return {};
}

}  // namespace

std::expected<MigrateStats, std::string>
migrate_be_to_le(std::string_view src_dir, std::string_view dst_dir) {
    const fs::path src(src_dir);
    const fs::path dst(dst_dir);
    if (!fs::exists(src)) return std::unexpected("src dir does not exist");
    std::error_code ec;
    fs::create_directories(dst, ec);
    if (ec) return std::unexpected("cannot create dst dir: " + ec.message());

    MigrateStats st;
    // meta 先行（同时校验 src 确为 v1 大端目录）。
    if (auto r = migrate_meta(src, dst, st); !r) {
        return std::unexpected(r.error());
    }
    if (auto r = migrate_field_schema(src, dst, st); !r) {
        return std::unexpected(r.error());
    }
    // 逐 data 文件（hint 由其重生成）。ckpt/seg/wal/旧 hint/锁不迁移。
    for (const auto& de : fs::directory_iterator(src)) {
        const auto fname = de.path().filename().string();
        if (fileops::parse_data_tstamp(fname).has_value()) {
            if (auto r = migrate_data_file(de.path(), dst, st); !r) {
                return std::unexpected(r.error());
            }
        }
    }
    return st;
}

}  // namespace bitcask::migrate
