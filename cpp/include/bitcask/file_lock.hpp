// 文件式咨询锁，用于 bitcask 的 write / merge / create 串行化。
//
// 注意：不是 POSIX flock 也不是 fcntl 锁，bitcask 只依赖
// O_CREAT|O_EXCL 的原子性 + release 时 unlink 来达到「同时只有一个持有者」
// 的语义。所以：
//
//   - 跨进程是安全的（O_EXCL 在内核层是原子的）
//   - 持有进程崩溃后锁文件留在磁盘上，需要 stale-lock reclaim
//     （cask 在 open 时会做：检查锁文件里的 pid 是否还活着，死了就接管）
//   - NFS 上不可靠（O_EXCL 在 NFS 上有历史 bug，本来 bitcask 也不该跑
//     在网络盘上）

#pragma once

#include <cstddef>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/io.hpp"  // IoError

namespace bitcask::lock {

// fd + filename 的所有者；移动语义、析构 release。
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

    // 读锁：O_RDONLY 打开已存在的锁文件——只是为了能读到当前持有者
    //       写进去的元数据（pid、active file 路径），不阻止别人写。
    // 写锁：O_CREAT | O_EXCL | O_RDWR | O_SYNC, mode 0600；EEXIST 表示
    //       已经有别人持有。stale 检查由调用方在拿到 EEXIST 后自己做。
    [[nodiscard]] static std::expected<FileLock, io::IoError>
    acquire(std::string_view filename, bool is_write_lock) noexcept;

    // 释放锁：close fd；如果是 write lock 还会 unlink 锁文件。
    // 错误吞掉——legacy 行为；这一步出错也没有恢复路径。
    void release_quiet() noexcept;

    // 把锁文件全部读出来。失败时 ReadError 区分 fstat / pread / 内存分配。
    enum class ReadErrorKind { kFstat, kPread, kAlloc };
    struct ReadError { ReadErrorKind kind; int errnum = 0; };
    [[nodiscard]] std::expected<std::vector<std::byte>, ReadError>
    read_data() noexcept;

    // truncate 到 0 然后 pwrite(offset=0, data)。仅写锁可用——读锁会返回
    // kNotWritable。给 cask 写「我是当前 writer，pid=N，active=...」用。
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
