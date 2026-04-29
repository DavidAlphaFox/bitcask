#include "bitcask/io.hpp"

#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstring>
#include <utility>

namespace bitcask::io {

namespace {

int translate_open_flags(OpenFlag in) noexcept {
    // Legacy bitcask_nifs.c::get_file_open_flags rules:
    //   default     = O_RDWR | O_APPEND | O_CREAT
    //   'create'    = O_CREAT | O_EXCL | O_RDWR | O_APPEND   (overrides default)
    //   'readonly'  = O_RDONLY                               (overrides default)
    //   'o_sync'    = OR-in O_SYNC
    int flags = O_RDWR | O_APPEND | O_CREAT;
    if (has_flag(in, OpenFlag::kCreate)) {
        flags = O_CREAT | O_EXCL | O_RDWR | O_APPEND;
    }
    if (has_flag(in, OpenFlag::kReadOnly)) {
        flags = O_RDONLY;
    }
    if (has_flag(in, OpenFlag::kOSync)) {
        flags |= O_SYNC;
    }
    return flags;
}

}  // namespace

std::expected<PosixFile, IoError>
PosixFile::open(std::string_view path, OpenFlag flags) noexcept {
    // open(2) needs a NUL-terminated path. Caller passes std::string_view that
    // may not be terminated (NIF copies into a fixed buffer first), so we copy.
    std::string p(path);
    const int fd = ::open(p.c_str(), translate_open_flags(flags), S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return std::unexpected(IoError{errno});
    }
    return PosixFile{fd};
}

void PosixFile::close_quiet() noexcept {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

std::expected<void, IoError> PosixFile::sync() noexcept {
    if (::fsync(fd_) == -1) return std::unexpected(IoError{errno});
    return {};
}

ReadResult PosixFile::pread(std::uint64_t offset, std::size_t count) noexcept {
    std::vector<std::byte> buf(count);
    const ssize_t n = ::pread(fd_, buf.data(), count, static_cast<off_t>(offset));
    if (n > 0) {
        if (static_cast<std::size_t>(n) < count) buf.resize(static_cast<std::size_t>(n));
        return ReadOk{std::move(buf)};
    }
    if (n == 0) return ReadEof{};
    return std::unexpected(IoError{errno});
}

std::expected<void, IoError>
PosixFile::pwrite(std::uint64_t offset, std::span<const std::byte> data) noexcept {
    const std::byte* buf = data.data();
    std::size_t remaining = data.size();
    off_t off = static_cast<off_t>(offset);
    while (remaining > 0) {
        const ssize_t w = ::pwrite(fd_, buf, remaining, off);
        if (w <= 0) return std::unexpected(IoError{errno});
        buf += w;
        off += w;
        remaining -= static_cast<std::size_t>(w);
    }
    return {};
}

ReadResult PosixFile::read(std::size_t count) noexcept {
    std::vector<std::byte> buf(count);
    const ssize_t n = ::read(fd_, buf.data(), count);
    if (n > 0) {
        if (static_cast<std::size_t>(n) < count) buf.resize(static_cast<std::size_t>(n));
        return ReadOk{std::move(buf)};
    }
    if (n == 0) return ReadEof{};
    return std::unexpected(IoError{errno});
}

std::expected<void, IoError>
PosixFile::write(std::span<const std::byte> data) noexcept {
    const std::byte* buf = data.data();
    std::size_t remaining = data.size();
    while (remaining > 0) {
        const ssize_t w = ::write(fd_, buf, remaining);
        if (w <= 0) return std::unexpected(IoError{errno});
        buf += w;
        remaining -= static_cast<std::size_t>(w);
    }
    return {};
}

std::expected<std::uint64_t, IoError>
PosixFile::seek(std::int64_t offset, int whence) noexcept {
    const off_t r = ::lseek(fd_, static_cast<off_t>(offset), whence);
    if (r == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    return static_cast<std::uint64_t>(r);
}

std::expected<void, IoError> PosixFile::seek_bof() noexcept {
    const off_t r = ::lseek(fd_, 0, SEEK_SET);
    if (r == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    return {};
}

std::expected<void, IoError> PosixFile::truncate_here() noexcept {
    const off_t cur = ::lseek(fd_, 0, SEEK_CUR);
    if (cur == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    if (::ftruncate(fd_, cur) == -1) return std::unexpected(IoError{errno});
    return {};
}

}  // namespace bitcask::io
