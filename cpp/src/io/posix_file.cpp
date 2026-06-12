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

// 把 bitcask 的 OpenFlag 翻成 POSIX open(2) 的 flag 位。
// 规则跟 legacy bitcask_nifs.c::get_file_open_flags 完全一致：
//   默认       = O_RDWR | O_APPEND | O_CREAT
//   kCreate    = O_CREAT | O_EXCL | O_RDWR | O_APPEND   （覆盖默认）
//   kReadOnly  = O_RDONLY                               （覆盖默认）
//   kOSync     = 在以上基础上 OR 一个 O_SYNC
int translate_open_flags(OpenFlag in) noexcept {
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
    // open(2) 需要 NUL-terminated 字符串；caller 给的 string_view 可能不带
    // 末尾 NUL（NIF 那边先 copy 进固定缓冲区再传过来），所以这里再 copy 一份。
    std::string p(path);
    const int fd = ::open(p.c_str(), translate_open_flags(flags), S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return std::unexpected(IoError{errno});
    }
    return PosixFile{fd};
}

// 关 fd；幂等（多次调用安全）。close 错误吞掉——legacy 行为，反正
// close 失败没有合理的恢复路径。
void PosixFile::close_quiet() noexcept {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

// fsync(2)：确保 fd 的脏页落盘。bitcask 的 sync_strategy 控制何时调用。
std::expected<void, IoError> PosixFile::sync() noexcept {
    if (::fsync(fd_) == -1) return std::unexpected(IoError{errno});
    return {};
}

// pread：保留「短读不当 EOF」的语义。返回值三种：
//   ReadOk{data}  — 读到 data.size() 字节（可能 < count，是合法短读）
//   ReadEof       — 0 字节（真 EOF）
//   IoError       — errno（不重试 EINTR——caller 需要的话自己重试）
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

// pread 零分配版：读进 caller 缓冲区，返回读到的字节数（0 = EOF）。
std::expected<std::size_t, IoError>
PosixFile::pread_into(std::uint64_t offset, std::span<std::byte> buf) noexcept {
    const ssize_t n =
        ::pread(fd_, buf.data(), buf.size(), static_cast<off_t>(offset));
    if (n < 0) return std::unexpected(IoError{errno});
    return static_cast<std::size_t>(n);
}

// pwrite：循环写直到全部完成或出错。部分写不会被当作成功返回。
// 注意 w==0 也算错误（极少见，通常意味着 EAGAIN 在 non-blocking fd 上）。
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

// 顺序 read：用当前 fd 偏移。返回语义跟 pread 一致。
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

// 顺序 write：循环到全部写完。跟 pwrite 一致，部分写继续。
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

// lseek 包装。返回新偏移。whence: SEEK_SET/CUR/END。
std::expected<std::uint64_t, IoError>
PosixFile::seek(std::int64_t offset, int whence) noexcept {
    const off_t r = ::lseek(fd_, static_cast<off_t>(offset), whence);
    if (r == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    return static_cast<std::uint64_t>(r);
}

// 便捷：seek 到文件头。
std::expected<void, IoError> PosixFile::seek_bof() noexcept {
    const off_t r = ::lseek(fd_, 0, SEEK_SET);
    if (r == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    return {};
}

// ftruncate 到当前 offset：截断 offset 之后的所有内容。注意是「截到这里」
// 而不是「截到 0」——给 torn-write 修复用。
std::expected<void, IoError> PosixFile::truncate_here() noexcept {
    const off_t cur = ::lseek(fd_, 0, SEEK_CUR);
    if (cur == static_cast<off_t>(-1)) return std::unexpected(IoError{errno});
    if (::ftruncate(fd_, cur) == -1) return std::unexpected(IoError{errno});
    return {};
}

}  // namespace bitcask::io
