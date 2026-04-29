// File-based advisory lock used by bitcask for write/merge/create
// serialization. NOT a POSIX flock or fcntl lock — bitcask only relies on
// O_CREAT|O_EXCL atomicity and unlink-on-release.

#pragma once

#include <cstddef>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/io.hpp"  // IoError

namespace bitcask::lock {

class FileLock {
public:
    FileLock() noexcept = default;
    FileLock(int fd, bool is_write_lock, std::string filename) noexcept
        : fd_(fd), is_write_lock_(is_write_lock),
          filename_(std::move(filename)) {}
    ~FileLock() noexcept { release_quiet(); }

    FileLock(const FileLock&) = delete;
    FileLock& operator=(const FileLock&) = delete;
    FileLock(FileLock&& o) noexcept
        : fd_(o.fd_), is_write_lock_(o.is_write_lock_),
          filename_(std::move(o.filename_)) { o.fd_ = -1; }
    FileLock& operator=(FileLock&& o) noexcept {
        if (this != &o) {
            release_quiet();
            fd_ = o.fd_; is_write_lock_ = o.is_write_lock_;
            filename_ = std::move(o.filename_); o.fd_ = -1;
        }
        return *this;
    }

    [[nodiscard]] bool is_open()       const noexcept { return fd_ >= 0; }
    [[nodiscard]] bool is_write_lock() const noexcept { return is_write_lock_; }
    [[nodiscard]] int  fd()            const noexcept { return fd_; }
    [[nodiscard]] const std::string& filename() const noexcept { return filename_; }

    // Read-locks open existing file with O_RDONLY.
    // Write-locks: O_CREAT | O_EXCL | O_RDWR | O_SYNC, mode 0600. EEXIST when
    // another writer holds the lock.
    [[nodiscard]] static std::expected<FileLock, io::IoError>
    acquire(std::string_view filename, bool is_write_lock) noexcept;

    // Releases lock: closes fd; if write-lock, also unlinks the file. Errors
    // are swallowed (matches legacy behavior — there is no recovery path).
    void release_quiet() noexcept;

    // Reads the entire lock file into a fresh buffer.
    // Failure modes:
    //   {fstat_error,  errno} | {pread_error, errno} | allocation_error.
    enum class ReadErrorKind { kFstat, kPread, kAlloc };
    struct ReadError { ReadErrorKind kind; int errnum = 0; };
    [[nodiscard]] std::expected<std::vector<std::byte>, ReadError>
    read_data() noexcept;

    // Truncates to 0 then pwrite at offset 0. Only valid for write-locks.
    enum class WriteErrorKind { kNotWritable, kTruncate, kPwrite };
    struct WriteError { WriteErrorKind kind; int errnum = 0; };
    [[nodiscard]] std::expected<void, WriteError>
    write_data(std::span<const std::byte> data) noexcept;

private:
    int  fd_ = -1;
    bool is_write_lock_ = false;
    std::string filename_;
};

}  // namespace bitcask::lock
