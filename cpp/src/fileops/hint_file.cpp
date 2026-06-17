#include "bitcask/hint_file.hpp"

#include <sys/stat.h>

#include <cstring>
#include <utility>

#include "bitcask/format.hpp"

namespace bitcask::fileops {

std::expected<HintFile, DataFileFault>
HintFile::open(std::string_view path, Mode mode, bool sync) {
    using io::OpenFlag;
    OpenFlag flags = OpenFlag::kNone;
    switch (mode) {
        case Mode::kRead:   flags = OpenFlag::kReadOnly; break;
        case Mode::kAppend: flags = OpenFlag::kNone; break;
        case Mode::kCreate: flags = OpenFlag::kCreate; break;
    }
    if (sync && mode != Mode::kRead) flags = flags | OpenFlag::kOSync;

    auto f = io::PosixFile::open(path, flags);
    if (!f) return std::unexpected(io_fault(f.error()));
    return HintFile(std::move(*f), std::string(path), 0, mode);
}

// ---------------------------------------------------------------------------
// 写入
// ---------------------------------------------------------------------------

// 把攒批缓冲一次性落盘（空缓冲 no-op）。
std::expected<void, DataFileFault> HintFile::flush_pending() {
    if (pending_.empty()) return {};
    auto w = file_.write(pending_);
    if (!w) return std::unexpected(io_fault(w.error()));
    pending_.clear();  // 复用容量
    return {};
}

// 追加一条 hint record（先进 pending_ 缓冲，攒满 kFlushBytes 才落盘）。同步把
// 刚编码的字节算进 running_crc_——finalize 用这个累计值生成 trailer，下次 open
// 验文件完整性。encode 是 append 语义，直接写进 pending_ 末尾免一次拷贝。
std::expected<void, DataFileFault>
HintFile::write(std::uint32_t tstamp, std::uint32_t total_sz,
                std::uint64_t offset, bool tombstone,
                std::span<const std::byte> key) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    if (offset > format::kMaxOffsetV2) {
        return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    }
    const std::size_t before = pending_.size();
    codec::encode_hint_record(pending_, tstamp, total_sz, offset, tombstone, key);
    running_crc_ = codec::crc32_update(
        running_crc_,
        std::span<const std::byte>(pending_.data() + before,
                                   pending_.size() - before));

    if (pending_.size() >= kFlushBytes) {
        if (auto r = flush_pending(); !r) return r;
    }
    return {};
}

// 写 EOF sentinel 并把 running_crc_ 嵌进去，连同缓冲里剩余 record 一次落盘。
// 这是 hint 文件的「封口」操作；没封口的 hint 文件下次 open 会被
// validate_trailer() 判失败，cask 会 fallback 到 fold(data) 重建——慢但可靠。
std::expected<void, DataFileFault> HintFile::finalize() {
    codec::encode_hint_eof(pending_, running_crc_);  // 追加 sentinel
    return flush_pending();                          // 缓冲 record + sentinel 一次写
}

// ---------------------------------------------------------------------------
// 读取
// ---------------------------------------------------------------------------

std::expected<void, DataFileFault> HintFile::fold(FoldFn fn) {
    auto end = file_.seek(0, SEEK_END);
    if (!end) return std::unexpected(io_fault(end.error()));
    const std::uint64_t total = *end;

    std::uint64_t offset = 0;

    // 在文件尾留出 sentinel record 的位置——遇到 EOF sentinel 就停下，
    // 不会把 sentinel 喂给 fn。
    // 缓冲整个 fold 循环复用(容量只增),每条 record 零分配。
    std::vector<std::byte> buf;
    while (offset + format::kHintRecordSize <= total) {
        // 先读 18 字节固定 header 拿 key_sz（offset 4..5, P:小端 u16）。
        // 直接 decode_hint_record(header_only) 会被 kBufferTooShort 拒掉，
        // 因为 decoder 要求 header + key 全部就位——所以分两次 pread。
        if (buf.size() < format::kHintRecordSize) {
            buf.resize(format::kHintRecordSize);
        }
        auto hn = file_.pread_into(
            offset, std::span(buf.data(), format::kHintRecordSize));
        if (!hn) return std::unexpected(io_fault(hn.error()));
        if (*hn < format::kHintRecordSize) break;  // 含 EOF

        const auto* p = buf.data();
        const std::uint16_t key_sz =
            static_cast<std::uint16_t>(
                static_cast<std::uint16_t>(p[4]) |
                (static_cast<std::uint16_t>(p[5]) << 8));
        const std::uint64_t rec_size =
            format::kHintRecordSize + static_cast<std::uint64_t>(key_sz);

        if (offset + rec_size > total) break;  // 文件尾被截断

        if (buf.size() < rec_size) buf.resize(rec_size);
        auto fn_ = file_.pread_into(
            offset, std::span(buf.data(), static_cast<std::size_t>(rec_size)));
        if (!fn_) return std::unexpected(io_fault(fn_.error()));
        if (*fn_ < rec_size) break;

        auto rec = codec::decode_hint_record(
            std::span<const std::byte>(buf.data(),
                                       static_cast<std::size_t>(rec_size)));
        if (!rec) return std::unexpected(DataFileFault{DataFileError::kShortRead});

        // 遇到 EOF sentinel 收工——不调 fn（它不是真正的 entry）。
        if (codec::is_hint_eof(*rec)) break;

        fn(*rec);
        offset += rec_size;
    }
    return {};
}

// 单独验 trailer CRC：先读末尾的 sentinel 拿到 expected_crc，再从头流式
// 算一遍前面所有字节的 CRC。两者一致才算 hint 文件健康，可以直接 fold；
// 否则 caller 应该 fall back 到 fold(data_file) 重建。
std::expected<bool, DataFileFault> HintFile::validate_trailer() {
    auto end = file_.seek(0, SEEK_END);
    if (!end) return std::unexpected(io_fault(end.error()));
    const std::uint64_t total = *end;
    if (total < format::kHintRecordSize) return false;

    // 1) 先读末尾的 sentinel record 拿 expected_crc。
    auto t = file_.pread(total - format::kHintRecordSize,
                         format::kHintRecordSize);
    if (!t) return std::unexpected(io_fault(t.error()));
    if (std::holds_alternative<io::ReadEof>(*t)) return false;
    auto& tb = std::get<io::ReadOk>(*t);
    auto trailer = codec::decode_hint_record(tb.data);
    if (!trailer) return false;
    if (!codec::is_hint_eof(*trailer)) return false;
    const std::uint32_t expected_crc = trailer->total_sz;

    // 2) 流式扫 trailer 之前的全部字节算 CRC，64 KiB 一块。
    if (auto s = file_.seek_bof(); !s) return std::unexpected(io_fault(s.error()));
    std::uint64_t remaining = total - format::kHintRecordSize;
    std::uint32_t crc = 0;
    constexpr std::size_t kChunk = 65536;
    while (remaining > 0) {
        const std::size_t n =
            static_cast<std::size_t>(std::min<std::uint64_t>(kChunk, remaining));
        auto r = file_.read(n);
        if (!r) return std::unexpected(io_fault(r.error()));
        if (std::holds_alternative<io::ReadEof>(*r)) break;
        auto& chunk = std::get<io::ReadOk>(*r);
        crc = codec::crc32_update(crc, chunk.data);
        remaining -= chunk.data.size();
        if (chunk.data.size() < n) break;
    }
    return crc == expected_crc;
}

}  // namespace bitcask::fileops
