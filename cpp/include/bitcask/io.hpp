// POSIX file I/O wrapper. Pure C++, no Erlang/OTP dependency.
// Mirrors the behavior of the legacy bitcask_nifs.c file_* primitives so it
// can be plugged into the NIF layer without semantic drift.

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>  // SEEK_*
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace bitcask::io {

enum class OpenFlag : unsigned {
    kNone     = 0,
    // Default for write: O_RDWR | O_APPEND | O_CREAT
    // 'create' overrides defaults: O_CREAT | O_EXCL | O_RDWR | O_APPEND
    kCreate   = 1u << 0,
    kReadOnly = 1u << 1,
    kOSync    = 1u << 2,
};
constexpr OpenFlag operator|(OpenFlag a, OpenFlag b) noexcept {
    return static_cast<OpenFlag>(static_cast<unsigned>(a) | static_cast<unsigned>(b));
}
constexpr bool has_flag(OpenFlag set, OpenFlag bit) noexcept {
    return (static_cast<unsigned>(set) & static_cast<unsigned>(bit)) != 0u;
}

// IoError carries a POSIX errno value. The NIF layer converts it to an atom
// via erl_errno_id() to match legacy behavior 1:1.
struct IoError {
    int errnum = 0;
};

// Result of a read: either a fully or partially filled buffer, or EOF, or an
// error. EOF is distinguished because NIF returns the atom 'eof' (not a tuple).
struct ReadOk {
    std::vector<std::byte> data;  // size <= requested; 0 means EOF *only* when
                                  // wrapped in ReadEof — see ReadResult below
};
struct ReadEof {};
using ReadResult = std::expected<std::variant<ReadOk, ReadEof>, IoError>;

class PosixFile {
public:
    PosixFile() noexcept = default;
    explicit PosixFile(int fd) noexcept : fd_(fd) {}
    ~PosixFile() noexcept { close_quiet(); }

    PosixFile(const PosixFile&) = delete;
    PosixFile& operator=(const PosixFile&) = delete;
    PosixFile(PosixFile&& other) noexcept : fd_(other.fd_) { other.fd_ = -1; }
    PosixFile& operator=(PosixFile&& other) noexcept {
        if (this != &other) { close_quiet(); fd_ = other.fd_; other.fd_ = -1; }
        return *this;
    }

    [[nodiscard]] bool is_open() const noexcept { return fd_ >= 0; }
    [[nodiscard]] int  fd()      const noexcept { return fd_; }

    // Open a file with bitcask-flavored flags. Same flag rules as the legacy
    // get_file_open_flags(): default = O_RDWR|O_APPEND|O_CREAT; kCreate
    // upgrades to O_CREAT|O_EXCL|O_RDWR|O_APPEND; kReadOnly forces O_RDONLY;
    // kOSync ORs in O_SYNC. mode = S_IREAD | S_IWRITE.
    [[nodiscard]] static std::expected<PosixFile, IoError>
    open(std::string_view path, OpenFlag flags) noexcept;

    // Closes the fd; idempotent. Errors swallowed (matches legacy behavior).
    void close_quiet() noexcept;

    // fsync(fd_).
    [[nodiscard]] std::expected<void, IoError> sync() noexcept;

    // pread loop: returns full read, partial read (>0), EOF (0), or error.
    [[nodiscard]] ReadResult pread(std::uint64_t offset, std::size_t count) noexcept;

    // pwrite loop until all bytes are written or an error occurs.
    [[nodiscard]] std::expected<void, IoError>
    pwrite(std::uint64_t offset, std::span<const std::byte> data) noexcept;

    // Sequential read/write (uses current fd offset).
    [[nodiscard]] ReadResult read(std::size_t count) noexcept;
    [[nodiscard]] std::expected<void, IoError>
    write(std::span<const std::byte> data) noexcept;

    // lseek(fd_, off, whence). whence is one of SEEK_SET / SEEK_CUR / SEEK_END.
    [[nodiscard]] std::expected<std::uint64_t, IoError>
    seek(std::int64_t offset, int whence) noexcept;

    // Convenience: lseek to BOF.
    [[nodiscard]] std::expected<void, IoError> seek_bof() noexcept;

    // ftruncate to current offset (matches legacy file_truncate semantics).
    [[nodiscard]] std::expected<void, IoError> truncate_here() noexcept;

private:
    int fd_ = -1;
};

}  // namespace bitcask::io
