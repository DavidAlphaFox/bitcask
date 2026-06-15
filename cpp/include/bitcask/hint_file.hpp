// bitcask hint file：data file 的并行索引。
//
// 每条 hint record 编码靠 codec::encode_hint_record。文件末尾有一条特殊的
// EOF sentinel record，里头存了整文件的 running CRC，给 has_valid_hintfile
// 用——hint 文件的完整性靠这个 trailer CRC 来验证（不像 data file 是
// 每条 record 自带 CRC）。
//
// 用途：keydir 重建加速。完整跑 fold(data_file) 重建 keydir 需要读全部
// value bytes；fold(hint_file) 只读 key + 元数据，省掉绝大部分 I/O。
//
// === 线程模型 ===
// 类似 DataFile：写路径 write()/finalize() 修改 running_crc_，必须单线程
// 串行；读路径 fold()/validate_trailer() 走 pread，可在不同 HintFile 对象
// 间并发。本类无内部锁，并发由上层保证。

#pragma once

#include <cstdint>
#include <expected>
#include <functional>
#include <span>
#include <string>
#include <string_view>

#include "bitcask/codec.hpp"
#include "bitcask/detail/file_fault.hpp"
#include "bitcask/io.hpp"

namespace bitcask::fileops {

class HintFile {
public:
    enum class Mode { kRead, kAppend, kCreate };

    HintFile() = default;
    ~HintFile() = default;

    HintFile(const HintFile&) = delete;
    HintFile& operator=(const HintFile&) = delete;
    HintFile(HintFile&&) noexcept = default;
    HintFile& operator=(HintFile&&) noexcept = default;

    // 线程安全: 是；不需任何锁。
    [[nodiscard]] static std::expected<HintFile, DataFileFault>
    open(std::string_view path, Mode mode, bool sync = false);

    // ---- 写入 ----

    // append 一条 hint record。同时更新 running_crc_。
    // 写入先进内存缓冲 pending_，攒到阈值（kFlushBytes）才一次 write(2)，把
    // 写路径的 per-put syscall 减半（hint 可重建：崩溃丢缓冲 → 下次 open
    // 无 trailer → validate_trailer 失败 → fold(data) 回退，安全语义不变）。
    // 线程安全: 否（修改 pending_/running_crc_ 与底层 fd 顺序写状态）；caller 串行化。
    [[nodiscard]] std::expected<void, DataFileFault>
    write(std::uint32_t tstamp, std::uint32_t total_sz,
          std::uint64_t offset, bool tombstone,
          std::span<const std::byte> key);

    // 写 EOF sentinel：含整文件 running CRC。
    // 不是「per-call 幂等」的——调两次会真写两条 sentinel；解析方碰到
    // 第一条就停下来，所以仍然能正常读，但文件多出几个无意义字节。
    // 正常使用是 close 前调一次。
    // 线程安全: 否（与 write() 共享 running_crc_）；caller 串行化。
    [[nodiscard]] std::expected<void, DataFileFault> finalize();

    // ---- 读取 ----

    // 遍历每条 hint record（不调 EOF sentinel 给 fn）。如果 trailer CRC
    // 不通过返回 kBadCrc——caller 应该退回 fold(data_file) 重建。
    using FoldFn = std::function<void(const codec::HintRecord& rec)>;
    // 线程安全: 是（pread + 顺序读 buf）；多读者可并发 fold 同一对象；
    // fn 自身的并发安全由 caller 负责。
    [[nodiscard]] std::expected<void, DataFileFault> fold(FoldFn fn);

    // 单独验 trailer CRC，不真正解析每条 record。给 has_valid_hintfile()
    // 用——快速判断 hint 文件能不能直接 fold。返回 false：sentinel 缺失
    // 或 CRC 不匹配。
    // 线程安全: 是（仅 pread + 局部 CRC 累加）。
    [[nodiscard]] std::expected<bool, DataFileFault> validate_trailer();

    // ---- 内省 ----
    [[nodiscard]] std::string_view path() const noexcept { return path_; }
    [[nodiscard]] std::uint32_t    running_crc() const noexcept { return running_crc_; }

    void close() noexcept { file_.close_quiet(); }

private:
    HintFile(io::PosixFile&& f, std::string p, std::uint32_t crc, Mode m) noexcept
        : file_(std::move(f)), path_(std::move(p)), running_crc_(crc), mode_(m) {}

    // 把 pending_ 的内容一次性 write 到 fd 并清空（pending 为空则 no-op）。
    [[nodiscard]] std::expected<void, DataFileFault> flush_pending();

    // 攒满多少字节就 flush 一次（hint 可重建，丢缓冲只触发 fold(data) 回退）。
    static constexpr std::size_t kFlushBytes = 64 * 1024;

    io::PosixFile file_;
    std::string   path_;
    std::uint32_t running_crc_ = 0;
    Mode          mode_        = Mode::kRead;
    std::vector<std::byte> pending_;  // 攒批写缓冲（write 追加，flush/finalize 落盘）
};

}  // namespace bitcask::fileops
