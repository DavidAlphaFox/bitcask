// Bitcask data file: append-only sequence of records on disk.
// Each record is encoded by bitcask::codec::encode_data_record (M0).
// I/O goes through bitcask::io::PosixFile (M1).
//
// Supported modes:
//   - kRead:        existing file, read-only
//   - kAppend:      existing file, append
//   - kCreate:      brand-new file (O_EXCL)
// Optional `kSync` adds O_SYNC for durability.

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/codec.hpp"
#include "bitcask/io.hpp"

namespace bitcask::fileops {

// Result of a data-file write: where the record landed and how big it is.
struct WriteResult {
    std::uint64_t offset;     // byte offset in the file
    std::uint32_t total_size; // bytes written (incl. 14B header)
};

// Read result: a fully decoded record at a given offset.
struct ReadRecord {
    std::uint32_t tstamp;
    std::uint32_t total_size;
    std::vector<std::byte> key;
    std::vector<std::byte> value;
};

enum class DataFileError {
    kIo,           // wraps an io::IoError
    kBadCrc,       // CRC mismatch on read or fold
    kShortRead,    // EOF mid-record
    kTooLarge,     // key/value exceeds format limits
};

struct DataFileFault {
    DataFileError kind;
    int errnum = 0;  // populated when kind == kIo
};

class DataFile {
public:
    enum class Mode { kRead, kAppend, kCreate };

    DataFile() = default;
    ~DataFile() = default;

    DataFile(const DataFile&) = delete;
    DataFile& operator=(const DataFile&) = delete;
    DataFile(DataFile&&) noexcept = default;
    DataFile& operator=(DataFile&&) noexcept = default;

    [[nodiscard]] static std::expected<DataFile, DataFileFault>
    open(std::string_view path, Mode mode, bool sync = false);

    // ---- Writing (only valid for Mode::kAppend or kCreate) ----

    // Append one record. The implementation pwrites at `current_offset_` then
    // advances; concurrent writers on the same DataFile are NOT supported.
    [[nodiscard]] std::expected<WriteResult, DataFileFault>
    write(std::uint32_t tstamp,
          std::span<const std::byte> key,
          std::span<const std::byte> value);

    // Truncate to the current write offset. Used by undo paths.
    [[nodiscard]] std::expected<void, DataFileFault> truncate_here();

    // fsync(2).
    [[nodiscard]] std::expected<void, DataFileFault> sync();

    // ---- Reading ----

    // Read a record at the given offset (size must be the recorded total_size,
    // i.e. 14 + key_sz + value_sz). Verifies CRC.
    [[nodiscard]] std::expected<ReadRecord, DataFileFault>
    read(std::uint64_t offset, std::uint32_t total_size);

    // Sequentially fold over every record in the file. Each call to fn
    // receives the decoded record. CRC errors stop the fold and propagate
    // unless `tolerate_crc_errors` is true (matches the legacy behaviour
    // that skips up to 20 corrupt records before bailing).
    //
    // If `out_last_valid_end` is non-null, on return it holds the file
    // offset just past the last successfully-decoded record. Caller can
    // compare to `size()` to detect a torn write at EOF and truncate.
    using FoldFn = std::function<void(const codec::DataRecordView& view,
                                       std::uint64_t offset,
                                       std::uint32_t total_size)>;
    [[nodiscard]] std::expected<void, DataFileFault>
    fold(FoldFn fn,
         bool tolerate_crc_errors = false,
         std::uint64_t* out_last_valid_end = nullptr);

    // Truncate the file to `new_size`. Used by recovery to chop off a
    // torn-write tail discovered by fold(). Caller must be in write/append
    // mode (Mode::kAppend or kCreate); the file's seek position is
    // restored to end-of-file after truncation so subsequent writes
    // continue cleanly.
    [[nodiscard]] std::expected<void, DataFileFault>
    truncate_to(std::uint64_t new_size);

    // ---- Introspection ----
    [[nodiscard]] std::string_view path() const noexcept { return path_; }
    [[nodiscard]] std::uint64_t    size() const noexcept { return current_offset_; }

    void close() noexcept { file_.close_quiet(); }

private:
    DataFile(io::PosixFile&& f, std::string p, std::uint64_t off, Mode m) noexcept
        : file_(std::move(f)), path_(std::move(p)),
          current_offset_(off), mode_(m) {}

    io::PosixFile  file_;
    std::string    path_;
    std::uint64_t  current_offset_ = 0;
    Mode           mode_           = Mode::kRead;
};

// ---------------------------------------------------------------------------
// Filename conventions: <dir>/<tstamp>.bitcask.data, .bitcask.hint
// ---------------------------------------------------------------------------
[[nodiscard]] std::string mk_data_filename(std::string_view dirname,
                                            std::uint64_t tstamp);
[[nodiscard]] std::string mk_hint_filename(std::string_view data_path);
[[nodiscard]] std::optional<std::uint64_t>
parse_data_tstamp(std::string_view filename) noexcept;

}  // namespace bitcask::fileops
