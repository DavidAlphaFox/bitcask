#include "bitcask/file_lock.hpp"

#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <utility>

namespace bitcask::lock {

std::expected<FileLock, io::IoError>
FileLock::acquire(std::string_view filename, bool is_write_lock) noexcept {
    int flags = O_RDONLY;
    if (is_write_lock) {
        // O_SYNC ensures lock contents are immediately visible to readers.
        flags = O_CREAT | O_EXCL | O_RDWR | O_SYNC;
    }
    std::string path(filename);
    const int fd = ::open(path.c_str(), flags, 0600);
    if (fd < 0) return std::unexpected(io::IoError{errno});
    return FileLock(fd, is_write_lock, std::move(path));
}

void FileLock::release_quiet() noexcept {
    if (fd_ >= 0) {
        // Unlink BEFORE close to keep contents consistent for any reader that
        // currently holds the path open. (Legacy comment in lock_release.)
        if (is_write_lock_ && !filename_.empty()) {
            ::unlink(filename_.c_str());
        }
        ::close(fd_);
        fd_ = -1;
    }
}

std::expected<std::vector<std::byte>, FileLock::ReadError>
FileLock::read_data() noexcept {
    struct stat st{};
    if (::fstat(fd_, &st) != 0) {
        return std::unexpected(ReadError{ReadErrorKind::kFstat, errno});
    }
    std::vector<std::byte> buf;
    try {
        buf.resize(static_cast<std::size_t>(st.st_size));
    } catch (...) {
        return std::unexpected(ReadError{ReadErrorKind::kAlloc, 0});
    }
    if (st.st_size > 0) {
        const ssize_t n = ::pread(fd_, buf.data(), buf.size(), 0);
        if (n == -1) {
            return std::unexpected(ReadError{ReadErrorKind::kPread, errno});
        }
        // Legacy code does not detect short reads here; we mirror that.
        if (n >= 0 && static_cast<std::size_t>(n) < buf.size()) {
            buf.resize(static_cast<std::size_t>(n));
        }
    }
    return buf;
}

std::expected<void, FileLock::WriteError>
FileLock::write_data(std::span<const std::byte> data) noexcept {
    if (!is_write_lock_) {
        return std::unexpected(WriteError{WriteErrorKind::kNotWritable, 0});
    }
    if (::ftruncate(fd_, 0) == -1) {
        return std::unexpected(WriteError{WriteErrorKind::kTruncate, errno});
    }
    // Legacy single-shot pwrite; not a loop. We mirror that to keep error
    // semantics identical (a partial write returns success in legacy too).
    if (!data.empty()) {
        if (::pwrite(fd_, data.data(), data.size(), 0) == -1) {
            return std::unexpected(WriteError{WriteErrorKind::kPwrite, errno});
        }
    }
    return {};
}

}  // namespace bitcask::lock
