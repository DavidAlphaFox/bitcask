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
        // O_SYNC：保证 write_data 写进去的内容（pid / active file 路径等）
        // 立刻被其它进程的读锁看到——bitcask 用这个机制做 stale-lock 检查。
        flags = O_CREAT | O_EXCL | O_RDWR | O_SYNC;
    }
    std::string path(filename);
    const int fd = ::open(path.c_str(), flags, 0600);
    if (fd < 0) return std::unexpected(io::IoError{errno});
    return FileLock(fd, is_write_lock, std::move(path));
}

void FileLock::release_quiet() noexcept {
    if (fd_ >= 0) {
        // 必须先 unlink 后 close：让仍持有 fd 的 reader 还能从老 inode 读到
        // 一致的内容；如果反过来先 close 后 unlink，新建同名锁文件的进程
        // 可能会被旧 reader 读出 garbage。这是 legacy lock_release 里的
        // 既定顺序，照搬。
        if (is_write_lock_ && !filename_.empty()) {
            ::unlink(filename_.c_str());
        }
        ::close(fd_);
        fd_ = -1;
    }
}

// 把锁文件全部读到内存。两步：fstat 拿大小、pread 一次读完。
// 错误分三种是为了让上层精确判断（fstat 失败可能是 fd 已坏；alloc 失败
// 是 OOM；pread 失败是真正的 I/O 错误）。
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
        // legacy 这里不检测短读——锁文件本来就 < 一页，pread 不太可能短读，
        // 出现的话就当合法的「内容比 fstat 看到的小」处理（resize 截断）。
        if (n >= 0 && static_cast<std::size_t>(n) < buf.size()) {
            buf.resize(static_cast<std::size_t>(n));
        }
    }
    return buf;
}

// truncate 到 0 然后 pwrite(0, data)：等价于「覆盖整个文件」。
// 仅写锁可用——读锁返回 kNotWritable。给 cask 把「pid + active file 路径」
// 写到 write.lock 里用。
std::expected<void, FileLock::WriteError>
FileLock::write_data(std::span<const std::byte> data) noexcept {
    if (!is_write_lock_) {
        return std::unexpected(WriteError{WriteErrorKind::kNotWritable, 0});
    }
    if (::ftruncate(fd_, 0) == -1) {
        return std::unexpected(WriteError{WriteErrorKind::kTruncate, errno});
    }
    // legacy 是单次 pwrite——不循环。这里照搬，以便错误语义完全一致：
    // 部分写在 legacy 里也算成功，不重试。锁文件容量极小，这种简化没
    // 实际风险。
    if (!data.empty()) {
        if (::pwrite(fd_, data.data(), data.size(), 0) == -1) {
            return std::unexpected(WriteError{WriteErrorKind::kPwrite, errno});
        }
    }
    return {};
}

}  // namespace bitcask::lock
