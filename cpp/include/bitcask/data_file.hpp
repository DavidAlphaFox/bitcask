// bitcask data file 抽象：磁盘上 append-only 的 record 序列。
//
//   - record 编码靠 codec::encode_data_record（见 format.hpp 的格式定义）
//   - I/O 走 PosixFile（io.hpp）
//
// 三种打开模式：
//   - kRead   ：已存在的文件，只读
//   - kAppend ：已存在的文件，追加（current_offset_ 初始化为文件尾）
//   - kCreate ：全新文件（O_EXCL，文件已存在会失败）
//
// 可选 `sync=true`：在底层 PosixFile 加 O_SYNC，每次 write 都同步落盘。
// 跟 kCreate 配合使用就是 cask 的 sync_strategy=o_sync 模式。
//
// === 线程模型 ===
// 类内部不持有互斥量，分两类方法看待并发：
//   - 读路径 read() / fold()：用 PosixFile::pread，OS 层 thread-safe。
//     允许多线程在同一 DataFile 对象上并发调用（典型场景：cask 多读者
//     并发 get 同一个文件）。
//   - 写路径 write() / truncate_here() / truncate_to() / sync()：
//     更新 current_offset_ 状态，不可并发；caller 必须保证同一对象写操作
//     串行（在 cask 里靠「单 Erlang 进程持有 active DataFile」保证）。
//   - 跨对象：完全独立、线程安全。
//   - 构造 / 析构 / open / close：单线程，由所有者控制。
// 本类不提供内部锁——并发约束由 cask 层（read_cache_mu_ + 单写者模型）维护。

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
#include "bitcask/detail/file_fault.hpp"
#include "bitcask/io.hpp"

namespace bitcask::fileops {

// write() 的结果：record 落在文件的哪个偏移、占了多少字节。
// keydir 拿这两个值建索引（offset 给 get 用，total_size 给 read 用）。
struct WriteResult {
    std::uint64_t offset;     // 文件内字节偏移
    std::uint32_t total_size; // 实际写入的字节数（含 14 字节 header）
};

// read() 的结果：解码完整的一条 record。key/value 是 owned vector
// （不是 view），因为底层的 pread buffer 离开 read() 就析构了。
struct ReadRecord {
    format::RecordType type;
    std::uint32_t tstamp;
    std::uint64_t ord;
    std::uint32_t total_size;
    std::vector<std::byte> key;
    std::vector<std::byte> value;
};

class DataFile {
public:
    enum class Mode { kRead, kAppend, kCreate };

    DataFile() = default;
    // P6:析构 munmap(若已映射);移动转移映射所有权并把源置空,避免
    // 默认 move 拷贝裸指针 → 双 munmap。定义在 .cpp。
    ~DataFile();

    DataFile(const DataFile&) = delete;
    DataFile& operator=(const DataFile&) = delete;
    DataFile(DataFile&&) noexcept;
    DataFile& operator=(DataFile&&) noexcept;

    // 线程安全: 是（每次调用产出新对象）；不需任何锁。
    // P6:mmap_enabled 且 Mode::kRead 且 64 位 → 整文件 mmap 只读(零拷贝),
    // 映射成功后 close(fd)。失败/active/32 位/禁用 → 走 pread。
    [[nodiscard]] static std::expected<DataFile, DataFileFault>
    open(std::string_view path, Mode mode, bool sync = false,
         bool mmap_enabled = true);

    // ---- 写入（仅 Mode::kAppend / kCreate 有效；kRead 调用是逻辑 bug）----

    // append 一条 record。内部先 pwrite 到 current_offset_ 然后推进；
    // 不支持同一 DataFile 对象的并发写入——concurrency 在更上层（cask）控制。
    // 线程安全: 否（修改 current_offset_）；caller 串行化对同一对象的写。
    [[nodiscard]] std::expected<WriteResult, DataFileFault>
    write(format::RecordType type,
          std::uint32_t tstamp,
          std::uint64_t ord,
          std::span<const std::byte> key,
          std::span<const std::byte> value);

    // 截断到当前 write offset。给 undo / 部分写恢复用
    // （比 truncate_to(current_offset_) 更明确意图）。
    // 线程安全: 否（依赖 current_offset_ + ftruncate）；与 write() 互斥串行。
    [[nodiscard]] std::expected<void, DataFileFault> truncate_here();

    // fsync(2)。
    // 线程安全: 是（仅触发 fsync 系统调用）；可在多线程并发，但通常配合
    // 写路径同步使用 → 实际由 caller 单线程触发。
    [[nodiscard]] std::expected<void, DataFileFault> sync();

    // ---- 读取 ----

    // 在 offset 处读一条 record，size 必须等于当时写入时记录的 total_size
    // （即 14 + key_sz + value_sz）。CRC 会校验；不通过返回 kBadCrc。
    // 线程安全: 是（pread 不动 fd offset）；多读者并发 OK，且与并发的
    // write()/truncate_*() 仅在「读到刚被改写的偏移段」时不一致——cask 通过
    // 「读只读老文件」「写仅写 active」的拓扑避免该情况。
    [[nodiscard]] std::expected<ReadRecord, DataFileFault>
    read(std::uint64_t offset, std::uint32_t total_size);

    // P6:sealed mmap 命中时的零拷贝读。返回的 DataRecordView 的 key/value
    // span **指向映射内存**——调用方必须在 view 生命期内持有本 DataFile 的
    // shared_ptr 锚定映射(析构即 munmap → span 悬垂)。仅 mmapped() 为真时
    // 有效;CRC 不通过 → kBadCrc,越界 → kShortRead。
    // 线程安全: 是(只读映射 + 纯解码,不碰 fd/offset)。
    [[nodiscard]] bool mmapped() const noexcept {
        return map_base_ != nullptr;
    }
    [[nodiscard]] std::expected<codec::DataRecordView, DataFileFault>
    read_mmap(std::uint64_t offset, std::uint32_t total_size) const;

    // 顺序遍历整个文件的所有 record。fn 收到解码后的 view + 偏移 + 大小。
    //
    // CRC 错误默认会停下并 propagate；tolerate_crc_errors=true 时会继续
    // 跳到下一个看似合法的 record（mirror legacy 「最多跳过 20 条损坏
    // record 之后就放弃」的恢复策略；见 cpp/src/fileops/data_file.cpp）。
    //
    // out_last_valid_end 非空时回填最后一条成功解码 record 的「末尾偏移」；
    // caller 拿它跟 size() 比较，不一致就说明文件尾有 torn write，可以
    // truncate_to(out_last_valid_end) 修掉。
    using FoldFn = std::function<void(const codec::DataRecordView& view,
                                       std::uint64_t offset,
                                       std::uint32_t total_size)>;
    // 线程安全: 是（pread + 一次性 stream 读取，不修改 current_offset_ 状态）；
    // 多线程可并发 fold 同一对象，但 fn 自身需自带线程安全（caller 责任）。
    [[nodiscard]] std::expected<void, DataFileFault>
    fold(FoldFn fn,
         bool tolerate_crc_errors = false,
         std::uint64_t* out_last_valid_end = nullptr,
         std::uint64_t start_offset = 0);  // A4:从该偏移起扫(快照尾部回放)

    // 截断到 new_size。给 fold 发现 torn write 后做尾部修复用。
    // caller 必须处于 write/append 模式；截断后内部 seek 到末尾，
    // 后续 write 可以无缝继续。
    // 线程安全: 否（修改 current_offset_ + ftruncate）；与 write 互斥串行。
    [[nodiscard]] std::expected<void, DataFileFault>
    truncate_to(std::uint64_t new_size);

    // ---- 内省 ----
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
    std::vector<std::byte> write_buf_;  // write() 复用的编码缓冲;容量跨调用保留
    // P6:sealed mmap。map_base_ != nullptr 表示整文件已 mmap(PROT_READ,
    // MAP_SHARED);此时 fd 已关闭,read_mmap 直读映射。~DataFile munmap。
    const std::byte* map_base_ = nullptr;
    std::size_t      map_size_ = 0;
};

// ---------------------------------------------------------------------------
// 文件名约定：<dir>/<tstamp>.bitcask.data 与 <dir>/<tstamp>.bitcask.hint
// tstamp 是文件创建时刻的 monotonic counter（不是 wall clock，避免
// 跨进程冲突；keydir_registry 全局递增）。
// 以下都是纯字符串处理函数：线程安全、可重入、无锁。
// ---------------------------------------------------------------------------
[[nodiscard]] std::string mk_data_filename(std::string_view dirname,
                                            std::uint64_t tstamp);
[[nodiscard]] std::string mk_hint_filename(std::string_view data_path);

// 从 "<tstamp>.bitcask.data" 解析出 tstamp；不匹配返回 nullopt。
[[nodiscard]] std::optional<std::uint64_t>
parse_data_tstamp(std::string_view filename) noexcept;

}  // namespace bitcask::fileops
