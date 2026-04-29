#include "bitcask/data_file.hpp"

#include <sys/stat.h>

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <optional>
#include <utility>

#include "bitcask/format.hpp"

namespace bitcask::fileops {

namespace {
constexpr int kCrcSkipLimit = 20;  // legacy: bail after this many CRC errors

DataFileFault io_fault(const io::IoError& e) noexcept {
    return DataFileFault{DataFileError::kIo, e.errnum};
}
}  // namespace

std::expected<DataFile, DataFileFault>
DataFile::open(std::string_view path, Mode mode, bool sync) {
    using io::OpenFlag;
    OpenFlag flags = OpenFlag::kNone;
    switch (mode) {
        case Mode::kRead:   flags = OpenFlag::kReadOnly; break;
        case Mode::kAppend: flags = OpenFlag::kNone; break;       // O_RDWR|O_APPEND default
        case Mode::kCreate: flags = OpenFlag::kCreate; break;     // O_EXCL
    }
    if (sync && mode != Mode::kRead) flags = flags | OpenFlag::kOSync;

    auto f = io::PosixFile::open(path, flags);
    if (!f) return std::unexpected(io_fault(f.error()));

    // Discover existing size for both kRead (used by fold) and kAppend
    // (used by write to position correctly even though O_APPEND ignores it).
    std::uint64_t initial_off = 0;
    if (mode != Mode::kCreate) {
        auto end = f->seek(0, SEEK_END);
        if (!end) return std::unexpected(io_fault(end.error()));
        initial_off = *end;
    }
    return DataFile(std::move(*f), std::string(path), initial_off, mode);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

std::expected<WriteResult, DataFileFault>
DataFile::write(std::uint32_t tstamp,
                std::span<const std::byte> key,
                std::span<const std::byte> value) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    if (key.size()   > format::kMaxKeySize)   return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    if (value.size() > format::kMaxValueSize) return std::unexpected(DataFileFault{DataFileError::kTooLarge});

    std::vector<std::byte> buf;
    buf.reserve(format::kHeaderSize + key.size() + value.size());
    const std::size_t total = codec::encode_data_record(buf, tstamp, key, value);

    const std::uint64_t off = current_offset_;
    auto w = file_.pwrite(off, buf);
    if (!w) return std::unexpected(io_fault(w.error()));
    current_offset_ += total;
    return WriteResult{off, static_cast<std::uint32_t>(total)};
}

std::expected<void, DataFileFault> DataFile::truncate_here() {
    auto s = file_.seek(static_cast<std::int64_t>(current_offset_), SEEK_SET);
    if (!s) return std::unexpected(io_fault(s.error()));
    auto t = file_.truncate_here();
    if (!t) return std::unexpected(io_fault(t.error()));
    return {};
}

std::expected<void, DataFileFault> DataFile::sync() {
    auto s = file_.sync();
    if (!s) return std::unexpected(io_fault(s.error()));
    return {};
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

std::expected<ReadRecord, DataFileFault>
DataFile::read(std::uint64_t offset, std::uint32_t total_size) {
    auto r = file_.pread(offset, total_size);
    if (!r) return std::unexpected(io_fault(r.error()));

    if (std::holds_alternative<io::ReadEof>(*r)) {
        return std::unexpected(DataFileFault{DataFileError::kShortRead});
    }
    auto& ok = std::get<io::ReadOk>(*r);
    if (ok.data.size() < total_size) {
        return std::unexpected(DataFileFault{DataFileError::kShortRead});
    }
    auto rec = codec::decode_data_record(ok.data);
    if (!rec) {
        // codec::DecodeError → DataFileFault
        switch (rec.error()) {
            case codec::DecodeError::kBadCrc:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
            case codec::DecodeError::kBufferTooShort:
                return std::unexpected(DataFileFault{DataFileError::kShortRead});
            default:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
        }
    }
    ReadRecord out;
    out.tstamp     = rec->tstamp;
    if (rec->total_size > format::kMaxValueSize + format::kHeaderSize + format::kMaxKeySize) {
        return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    }
    out.total_size = static_cast<std::uint32_t>(rec->total_size);
    out.key.assign(rec->key.begin(), rec->key.end());
    out.value.assign(rec->value.begin(), rec->value.end());
    return out;
}

std::expected<void, DataFileFault>
DataFile::fold(FoldFn fn, bool tolerate_crc_errors,
                std::uint64_t* out_last_valid_end) {
    if (out_last_valid_end) *out_last_valid_end = 0;
    // Snapshot file size; rewind to BOF.
    auto eof = file_.seek(0, SEEK_END);
    if (!eof) return std::unexpected(io_fault(eof.error()));
    const std::uint64_t total = *eof;
    if (auto r = file_.seek_bof(); !r) return std::unexpected(io_fault(r.error()));

    std::uint64_t offset = 0;
    int crc_errors = 0;

    // Read header first to learn the record's exact size, then read the body.
    while (offset + format::kHeaderSize <= total) {
        auto hr = file_.pread(offset, format::kHeaderSize);
        if (!hr) return std::unexpected(io_fault(hr.error()));
        if (std::holds_alternative<io::ReadEof>(*hr)) break;
        auto& hdr = std::get<io::ReadOk>(*hr);
        if (hdr.data.size() < format::kHeaderSize) break;

        // Parse just the sizes without verifying CRC yet.
        std::uint16_t key_sz;
        std::uint32_t value_sz;
        std::memcpy(&key_sz,  hdr.data.data() + format::kKeySzOffset,  sizeof(key_sz));
        std::memcpy(&value_sz, hdr.data.data() + format::kValueSzOffset, sizeof(value_sz));
        // Convert from BE on disk.
        key_sz   = static_cast<std::uint16_t>(((key_sz & 0xFF) << 8) | (key_sz >> 8));
        value_sz = ((value_sz & 0xFFu) << 24) | ((value_sz & 0xFF00u) << 8) |
                   ((value_sz & 0xFF0000u) >> 8) | (value_sz >> 24);

        const std::uint32_t rec_total =
            static_cast<std::uint32_t>(format::kHeaderSize) +
            static_cast<std::uint32_t>(key_sz) + value_sz;

        if (offset + rec_total > total) break;  // truncated tail

        auto br = file_.pread(offset, rec_total);
        if (!br) return std::unexpected(io_fault(br.error()));
        if (std::holds_alternative<io::ReadEof>(*br)) break;
        auto& body = std::get<io::ReadOk>(*br);

        auto rec = codec::decode_data_record(body.data);
        if (!rec) {
            if (rec.error() == codec::DecodeError::kBadCrc && tolerate_crc_errors) {
                if (++crc_errors > kCrcSkipLimit) {
                    return std::unexpected(DataFileFault{DataFileError::kBadCrc});
                }
                offset += rec_total;
                continue;
            }
            switch (rec.error()) {
                case codec::DecodeError::kBadCrc:
                    return std::unexpected(DataFileFault{DataFileError::kBadCrc});
                default:
                    return std::unexpected(DataFileFault{DataFileError::kShortRead});
            }
        }
        fn(*rec, offset, rec_total);
        offset += rec_total;
        if (out_last_valid_end) *out_last_valid_end = offset;
    }
    return {};
}

std::expected<void, DataFileFault>
DataFile::truncate_to(std::uint64_t new_size) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    auto s = file_.seek(static_cast<std::int64_t>(new_size), SEEK_SET);
    if (!s) return std::unexpected(io_fault(s.error()));
    auto t = file_.truncate_here();
    if (!t) return std::unexpected(io_fault(t.error()));
    // Move back to end-of-file so the next pwrite at current_offset_ is
    // contiguous. (current_offset_ is set by the caller, e.g. recovery.)
    auto e = file_.seek(0, SEEK_END);
    if (!e) return std::unexpected(io_fault(e.error()));
    current_offset_ = *e;
    return {};
}

// ---------------------------------------------------------------------------
// Filename helpers
// ---------------------------------------------------------------------------

std::string mk_data_filename(std::string_view dirname, std::uint64_t tstamp) {
    std::filesystem::path p(dirname);
    p /= (std::to_string(tstamp) + ".bitcask.data");
    return p.string();
}

std::string mk_hint_filename(std::string_view data_path) {
    // Replace ".data" suffix with ".hint", matching legacy hintfile_name.
    constexpr std::string_view kData = ".data";
    constexpr std::string_view kHint = ".hint";
    std::string out(data_path);
    if (out.size() >= kData.size() &&
        out.compare(out.size() - kData.size(), kData.size(), kData) == 0) {
        out.replace(out.size() - kData.size(), kData.size(), kHint);
    } else {
        out.append(kHint);
    }
    return out;
}

std::optional<std::uint64_t>
parse_data_tstamp(std::string_view filename) noexcept {
    // Strip directory.
    auto slash = filename.find_last_of('/');
    std::string_view base =
        (slash == std::string_view::npos) ? filename : filename.substr(slash + 1);

    constexpr std::string_view kSuffix = ".bitcask.data";
    if (base.size() <= kSuffix.size()) return std::nullopt;
    if (base.compare(base.size() - kSuffix.size(), kSuffix.size(), kSuffix) != 0) {
        return std::nullopt;
    }
    base = base.substr(0, base.size() - kSuffix.size());

    if (base.empty()) return std::nullopt;
    std::uint64_t tstamp = 0;
    for (char c : base) {
        if (c < '0' || c > '9') return std::nullopt;
        tstamp = tstamp * 10 + static_cast<std::uint64_t>(c - '0');
    }
    return tstamp;
}

}  // namespace bitcask::fileops
