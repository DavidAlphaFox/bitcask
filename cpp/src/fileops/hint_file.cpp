#include "bitcask/hint_file.hpp"

#include <sys/stat.h>

#include <cstring>
#include <utility>

#include "bitcask/format.hpp"

namespace bitcask::fileops {

namespace {
DataFileFault io_fault(const io::IoError& e) noexcept {
    return DataFileFault{DataFileError::kIo, e.errnum};
}
}  // namespace

std::expected<HintFile, DataFileFault>
HintFile::open(std::string_view path, Mode mode, bool sync) {
    using io::OpenFlag;
    OpenFlag flags = OpenFlag::kNone;
    switch (mode) {
        case Mode::kRead:   flags = OpenFlag::kReadOnly; break;
        case Mode::kAppend: flags = OpenFlag::kNone; break;
        case Mode::kCreate: flags = OpenFlag::kCreate; break;
    }
    if (sync && mode != Mode::kRead) flags = flags | OpenFlag::kOSync;

    auto f = io::PosixFile::open(path, flags);
    if (!f) return std::unexpected(io_fault(f.error()));
    return HintFile(std::move(*f), std::string(path), 0, mode);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

std::expected<void, DataFileFault>
HintFile::write(std::uint32_t tstamp, std::uint32_t total_sz,
                std::uint64_t offset, bool tombstone,
                std::span<const std::byte> key) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    if (offset > format::kMaxOffsetV2) {
        return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    }
    std::vector<std::byte> buf;
    buf.reserve(format::kHintRecordSize + key.size());
    codec::encode_hint_record(buf, tstamp, total_sz, offset, tombstone, key);

    auto w = file_.write(buf);
    if (!w) return std::unexpected(io_fault(w.error()));

    running_crc_ = codec::crc32_update(running_crc_, buf);
    return {};
}

std::expected<void, DataFileFault> HintFile::finalize() {
    std::vector<std::byte> buf;
    buf.reserve(format::kHintRecordSize);
    codec::encode_hint_eof(buf, running_crc_);
    auto w = file_.write(buf);
    if (!w) return std::unexpected(io_fault(w.error()));
    return {};
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

std::expected<void, DataFileFault> HintFile::fold(FoldFn fn) {
    auto end = file_.seek(0, SEEK_END);
    if (!end) return std::unexpected(io_fault(end.error()));
    const std::uint64_t total = *end;

    std::uint64_t offset = 0;

    // Stop one sentinel-record short — the trailer is not a real entry.
    while (offset + format::kHintRecordSize <= total) {
        // First peek the 18-byte header to learn key_sz (offset 4..5, BE u16).
        // We can't decode_hint_record on just the header because the decoder
        // requires the full record (header + key) and would return
        // kBufferTooShort here.
        auto hdr = file_.pread(offset, format::kHintRecordSize);
        if (!hdr) return std::unexpected(io_fault(hdr.error()));
        if (std::holds_alternative<io::ReadEof>(*hdr)) break;
        auto& hb = std::get<io::ReadOk>(*hdr);
        if (hb.data.size() < format::kHintRecordSize) break;

        const auto* p = hb.data.data();
        const std::uint16_t key_sz =
            static_cast<std::uint16_t>(
                (static_cast<std::uint16_t>(p[4]) << 8) |
                 static_cast<std::uint16_t>(p[5]));
        const std::uint64_t rec_size =
            format::kHintRecordSize + static_cast<std::uint64_t>(key_sz);

        if (offset + rec_size > total) break;  // truncated tail

        auto full = file_.pread(offset, static_cast<std::size_t>(rec_size));
        if (!full) return std::unexpected(io_fault(full.error()));
        auto& fb = std::get<io::ReadOk>(*full);
        if (fb.data.size() < rec_size) break;

        auto rec = codec::decode_hint_record(fb.data);
        if (!rec) return std::unexpected(DataFileFault{DataFileError::kShortRead});

        // EOF sentinel ends iteration without invoking fn.
        if (codec::is_hint_eof(*rec)) break;

        fn(*rec);
        offset += rec_size;
    }
    return {};
}

std::expected<bool, DataFileFault> HintFile::validate_trailer() {
    auto end = file_.seek(0, SEEK_END);
    if (!end) return std::unexpected(io_fault(end.error()));
    const std::uint64_t total = *end;
    if (total < format::kHintRecordSize) return false;

    // Read trailer.
    auto t = file_.pread(total - format::kHintRecordSize,
                         format::kHintRecordSize);
    if (!t) return std::unexpected(io_fault(t.error()));
    if (std::holds_alternative<io::ReadEof>(*t)) return false;
    auto& tb = std::get<io::ReadOk>(*t);
    auto trailer = codec::decode_hint_record(tb.data);
    if (!trailer) return false;
    if (!codec::is_hint_eof(*trailer)) return false;
    const std::uint32_t expected_crc = trailer->total_sz;

    // Now stream all bytes BEFORE the trailer to compute the CRC.
    if (auto s = file_.seek_bof(); !s) return std::unexpected(io_fault(s.error()));
    std::uint64_t remaining = total - format::kHintRecordSize;
    std::uint32_t crc = 0;
    constexpr std::size_t kChunk = 65536;
    while (remaining > 0) {
        const std::size_t n =
            static_cast<std::size_t>(std::min<std::uint64_t>(kChunk, remaining));
        auto r = file_.read(n);
        if (!r) return std::unexpected(io_fault(r.error()));
        if (std::holds_alternative<io::ReadEof>(*r)) break;
        auto& chunk = std::get<io::ReadOk>(*r);
        crc = codec::crc32_update(crc, chunk.data);
        remaining -= chunk.data.size();
        if (chunk.data.size() < n) break;
    }
    return crc == expected_crc;
}

}  // namespace bitcask::fileops
