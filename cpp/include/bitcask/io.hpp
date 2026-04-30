// POSIX 文件 I/O 包装。纯 C++，不依赖 Erlang/OTP——这样可以直接喂给
// gtest，跟 NIF 层解耦。语义上跟 legacy bitcask_nifs.c 的 file_* 系列原语
// 一一对应，方便从 C 翻译过来不出现行为漂移。

#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace bitcask::io {

// open() 接受的 flag 位掩码。bitcask 自己的语义层，不直接对应 POSIX flag。
enum class OpenFlag : unsigned {
    kNone     = 0,
    // 默认（无 flag）：O_RDWR | O_APPEND | O_CREAT
    // kCreate：           O_CREAT | O_EXCL | O_RDWR | O_APPEND（强制新建）
    kCreate   = 1u << 0,
    kReadOnly = 1u << 1,  // 改用 O_RDONLY，跟 kCreate 互斥（caller 自己保证）
    kOSync    = 1u << 2,  // 在原 flag 上 OR 一个 O_SYNC
};
constexpr OpenFlag operator|(OpenFlag a, OpenFlag b) noexcept {
    return static_cast<OpenFlag>(static_cast<unsigned>(a) | static_cast<unsigned>(b));
}
constexpr bool has_flag(OpenFlag set, OpenFlag bit) noexcept {
    return (static_cast<unsigned>(set) & static_cast<unsigned>(bit)) != 0u;
}

// IoError 只带 errno；NIF 层用 erl_errno_id() 翻成 atom，跟 legacy 行为
// 完全对齐（业务上拿到的 {error, enoent}/{error, eio} 等都不变）。
struct IoError {
    int errnum = 0;
};

// pread / read 的结果：要么读到了字节（可能短读），要么 EOF，要么报错。
// EOF 单独走 ReadEof 是因为 NIF 那边返回的是 atom 'eof'（不是 {ok, <<>>}），
// 必须在类型层面就把这两种情况区分开，避免下游误把 0 字节当成「合法空读」。
struct ReadOk {
    std::vector<std::byte> data;
};
struct ReadEof {};
using ReadResult = std::expected<std::variant<ReadOk, ReadEof>, IoError>;

// fd 持有者：移动语义、析构 close、不可拷贝。
// 跟 std::unique_ptr 一样的所有权模型，但定制了 fd_=-1 sentinel。
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

    // 按 bitcask 风格的 flag 打开文件。flag 推导规则跟 legacy
    // get_file_open_flags() 1:1 对齐（见 OpenFlag 注释）。mode = 0600。
    [[nodiscard]] static std::expected<PosixFile, IoError>
    open(std::string_view path, OpenFlag flags) noexcept;

    // 关 fd；幂等。错误吞掉——legacy 也是这个行为，反正 close 失败没救。
    void close_quiet() noexcept;

    // fsync(fd_)。
    [[nodiscard]] std::expected<void, IoError> sync() noexcept;

    // pread 循环：完整读到、短读 (>0)、EOF (0)、或 errno。短读不会被
    // 误报成 EOF——返回的 data.size() 直接告诉调用方读到多少。
    [[nodiscard]] ReadResult pread(std::uint64_t offset, std::size_t count) noexcept;

    // pwrite 循环直到全部写完或出错。pwrite 部分写不退化成短写——会继续。
    [[nodiscard]] std::expected<void, IoError>
    pwrite(std::uint64_t offset, std::span<const std::byte> data) noexcept;

    // 顺序读写（用当前 fd offset，不指定 offset）。
    [[nodiscard]] ReadResult read(std::size_t count) noexcept;
    [[nodiscard]] std::expected<void, IoError>
    write(std::span<const std::byte> data) noexcept;

    // lseek。whence: SEEK_SET / SEEK_CUR / SEEK_END。
    [[nodiscard]] std::expected<std::uint64_t, IoError>
    seek(std::int64_t offset, int whence) noexcept;

    // 便捷：seek 到文件头。
    [[nodiscard]] std::expected<void, IoError> seek_bof() noexcept;

    // ftruncate 到当前 fd offset。跟 legacy file_truncate 一致：截掉
    // current offset 之后的所有内容（不是 truncate 到 0）。
    [[nodiscard]] std::expected<void, IoError> truncate_here() noexcept;

private:
    int fd_ = -1;
};

}  // namespace bitcask::io
