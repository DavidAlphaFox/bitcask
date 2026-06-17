#include "bitcask/data_file.hpp"

#include <sys/mman.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <optional>
#include <utility>

#include "bitcask/format.hpp"

namespace bitcask::fileops {

namespace {
// fold(tolerate_crc_errors=true) 模式下，连续遇到 CRC 错的 record 上限。
// legacy 是 20 条——超过就认定文件损坏程度太重，放弃恢复整个文件。
constexpr int kCrcSkipLimit = 20;
}  // namespace

std::expected<DataFile, DataFileFault>
DataFile::open(std::string_view path, Mode mode, bool sync, bool mmap_enabled) {
    using io::OpenFlag;
    OpenFlag flags = OpenFlag::kNone;
    switch (mode) {
        case Mode::kRead:   flags = OpenFlag::kReadOnly; break;
        case Mode::kAppend: flags = OpenFlag::kNone; break;       // O_RDWR|O_APPEND default
        case Mode::kCreate: flags = OpenFlag::kCreate; break;     // O_EXCL
    }
    if (sync && mode != Mode::kRead) flags = flags | OpenFlag::kOSync;

    auto f = io::PosixFile::open(path, flags);
    if (!f) return std::unexpected(io_fault(f.error()));

    // 同时给 kRead（fold 要用 size 划界）和 kAppend（write 用 pwrite，
    // 不依赖 O_APPEND 的内核语义，要自己跟踪偏移）记录起始偏移。
    std::uint64_t initial_off = 0;
    if (mode != Mode::kCreate) {
        auto end = f->seek(0, SEEK_END);
        if (!end) return std::unexpected(io_fault(end.error()));
        initial_off = *end;
    }
    DataFile df(std::move(*f), std::string(path), initial_off, mode);

    // P6:sealed 只读文件整文件 mmap(PROT_READ, MAP_SHARED)。只对 kRead
    // (sealed 不可变,无 torn-tail/SIGBUS)、64 位(地址空间)、非空文件。
    // read_mmap 直读映射(get 热路径零拷贝);read()/fold() 仍走 pread——
    // 故 **fd 保留不关**(关 fd 会让迭代器/恢复在 mmapped 句柄上的 pread 失效)。
    // fd 预算的回收(close + munmap)交给 P9(read_files_ LRU)。失败 → 纯 pread。
    // mmap_enabled=false(纯 fold 的恢复/merge/迭代器 pin)跳过,避免无谓映射。
    if (mode == Mode::kRead && mmap_enabled && sizeof(void*) >= 8 &&
        initial_off > 0) {
        void* base = ::mmap(nullptr, static_cast<std::size_t>(initial_off),
                            PROT_READ, MAP_SHARED, df.file_.fd(), 0);
        if (base != MAP_FAILED) {
            df.map_base_ = static_cast<const std::byte*>(base);
            df.map_size_ = static_cast<std::size_t>(initial_off);
        }
    }
    return df;
}

DataFile::~DataFile() {
    if (map_base_ != nullptr) {
        ::munmap(const_cast<std::byte*>(map_base_), map_size_);
        map_base_ = nullptr;
    }
}

DataFile::DataFile(DataFile&& o) noexcept
    : file_(std::move(o.file_)), path_(std::move(o.path_)),
      current_offset_(o.current_offset_), mode_(o.mode_),
      write_buf_(std::move(o.write_buf_)),
      map_base_(o.map_base_), map_size_(o.map_size_) {
    o.map_base_ = nullptr;
    o.map_size_ = 0;
}

DataFile& DataFile::operator=(DataFile&& o) noexcept {
    if (this != &o) {
        if (map_base_ != nullptr) {
            ::munmap(const_cast<std::byte*>(map_base_), map_size_);
        }
        file_           = std::move(o.file_);
        path_           = std::move(o.path_);
        current_offset_ = o.current_offset_;
        mode_           = o.mode_;
        write_buf_      = std::move(o.write_buf_);
        map_base_       = o.map_base_;
        map_size_       = o.map_size_;
        o.map_base_     = nullptr;
        o.map_size_     = 0;
    }
    return *this;
}

std::expected<codec::DataRecordView, DataFileFault>
DataFile::read_mmap(std::uint64_t offset, std::uint32_t total_size) const {
    if (map_base_ == nullptr) {
        return std::unexpected(DataFileFault{DataFileError::kIo});
    }
    if (offset > map_size_ || total_size > map_size_ - offset) {
        return std::unexpected(DataFileFault{DataFileError::kShortRead});
    }
    auto rec = codec::decode_data_record(
        std::span<const std::byte>(map_base_ + offset, total_size));
    if (!rec) {
        switch (rec.error()) {
            case codec::DecodeError::kBadCrc:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
            case codec::DecodeError::kBufferTooShort:
                return std::unexpected(DataFileFault{DataFileError::kShortRead});
            default:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
        }
    }
    return *rec;
}

// ---------------------------------------------------------------------------
// 写入
// ---------------------------------------------------------------------------

// append 一条 record 到当前 offset。流程：
//   1. 校验权限 + 字段大小
//   2. 在内存里 encode 整条 record
//   3. pwrite 到 current_offset_，并把 current_offset_ 向前推
// 注意是 pwrite 不是 write——即使打开时带了 O_APPEND，我们也要明确指定
// offset 来支持「自己追踪写入位置」的语义（下一步 truncate_to 会用到）。
std::expected<WriteResult, DataFileFault>
DataFile::write(format::RecordType type,
                std::uint32_t tstamp,
                std::uint64_t ord,
                std::span<const std::byte> key,
                std::span<const std::byte> value) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    if (key.size()   > format::kMaxKeySize)   return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    if (value.size() > format::kMaxValueSize) return std::unexpected(DataFileFault{DataFileError::kTooLarge});

    write_buf_.clear();  // 复用容量:稳态零分配(encode 是 append 语义)
    const std::size_t total =
        codec::encode_data_record(write_buf_, type, tstamp, ord, key, value);

    const std::uint64_t off = current_offset_;
    auto w = file_.pwrite(off, write_buf_);
    if (!w) return std::unexpected(io_fault(w.error()));
    current_offset_ += total;
    return WriteResult{off, static_cast<std::uint32_t>(total)};
}

// 截到当前写入位置：先 lseek 到 current_offset_，再 ftruncate 到那里。
// 用于 undo——caller 想撤销最近一次 write 的话，可以记下 write 前的
// current_offset_，写完发现不对就 truncate_to(那个旧值)。
std::expected<void, DataFileFault> DataFile::truncate_here() {
    auto s = file_.seek(static_cast<std::int64_t>(current_offset_), SEEK_SET);
    if (!s) return std::unexpected(io_fault(s.error()));
    auto t = file_.truncate_here();
    if (!t) return std::unexpected(io_fault(t.error()));
    return {};
}

// fsync 包装。cask 的 sync_strategy=o_sync 模式下不会调到这里
//（已经在 write 时直接落盘）；none 模式下由调用方在合适时机主动调。
std::expected<void, DataFileFault> DataFile::sync() {
    auto s = file_.sync();
    if (!s) return std::unexpected(io_fault(s.error()));
    return {};
}

// ---------------------------------------------------------------------------
// 读取
// ---------------------------------------------------------------------------

// 在指定 offset 读 total_size 字节并 decode 一条 record。
//
// total_size 必须正好等于当时写入的字节数（keydir 存的就是这个值）；
// 短读或 EOF 都翻成 kShortRead——意味着 keydir 跟磁盘不一致（极端情况
// 下数据损坏或被截断）。CRC 不通过翻成 kBadCrc。
std::expected<ReadRecord, DataFileFault>
DataFile::read(std::uint64_t offset, std::uint32_t total_size) {
    // get 热路径:per-thread 复用读缓冲,稳态零分配。pread 线程安全,
    // 多线程可并发调 read(),故缓冲必须 thread_local 而非成员。
    static thread_local std::vector<std::byte> read_buf;
    // 防膨胀:一次超大 value 不让缓冲长期占住线程内存。
    constexpr std::size_t kReadBufRetain = 1u << 20;  // 1 MiB
    if (read_buf.size() < total_size) read_buf.resize(total_size);

    auto n = file_.pread_into(offset,
                              std::span(read_buf.data(), total_size));
    if (!n) return std::unexpected(io_fault(n.error()));
    if (*n < total_size) {  // 含 EOF(0 字节)
        return std::unexpected(DataFileFault{DataFileError::kShortRead});
    }
    auto rec = codec::decode_data_record(
        std::span<const std::byte>(read_buf.data(), total_size));
    if (!rec) {
        // codec::DecodeError → DataFileFault
        switch (rec.error()) {
            case codec::DecodeError::kBadCrc:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
            case codec::DecodeError::kBufferTooShort:
                return std::unexpected(DataFileFault{DataFileError::kShortRead});
            default:
                return std::unexpected(DataFileFault{DataFileError::kBadCrc});
        }
    }
    ReadRecord out;
    out.type       = rec->type;
    out.tstamp     = rec->tstamp;
    out.ord        = rec->ord;
    if (rec->total_size > format::kMaxValueSize + format::kHeaderSize + format::kMaxKeySize) {
        return std::unexpected(DataFileFault{DataFileError::kTooLarge});
    }
    out.total_size = static_cast<std::uint32_t>(rec->total_size);
    out.key.assign(rec->key.begin(), rec->key.end());
    out.value.assign(rec->value.begin(), rec->value.end());
    // key/value 已拷出,缓冲可以安全收缩(防超大 value 撑住线程内存)。
    if (read_buf.size() > kReadBufRetain) {
        read_buf.clear();
        read_buf.shrink_to_fit();
    }
    return out;
}

std::expected<void, DataFileFault>
DataFile::fold(FoldFn fn, bool tolerate_crc_errors,
                std::uint64_t* out_last_valid_end,
                std::uint64_t start_offset) {
    if (out_last_valid_end) *out_last_valid_end = start_offset;
    // 进入 fold 时拍个文件大小快照（防止 fold 期间被人 append），再 seek 回头。
    auto eof = file_.seek(0, SEEK_END);
    if (!eof) return std::unexpected(io_fault(eof.error()));
    const std::uint64_t total = *eof;
    if (auto r = file_.seek_bof(); !r) return std::unexpected(io_fault(r.error()));

    std::uint64_t offset = start_offset;
    int crc_errors = 0;

    // 先读 header（14 字节）拿 KeySz / ValueSz 算出整条 record 的大小，
    // 再一次 pread 把 body 读出来 decode。两次 pread 比一次大块读更省内存
    // —— 大 value（几 MB）下避免提前分配。
    // 缓冲整个 fold 循环复用(容量只增):扫盘重建从每条 2 次 malloc
    // 降到 0(摊销)。
    std::vector<std::byte> buf;
    while (offset + format::kHeaderSize <= total) {
        if (buf.size() < format::kHeaderSize) buf.resize(format::kHeaderSize);
        auto hn = file_.pread_into(
            offset, std::span(buf.data(), format::kHeaderSize));
        if (!hn) return std::unexpected(io_fault(hn.error()));
        if (*hn < format::kHeaderSize) break;  // 含 EOF(0 字节)

        // 只读出长度字段，CRC 等下读完整 record 再校验。盘格式为小端
        // (全引擎 LE-only 主机,见 codec 顶部 static_assert)→ 直接 memcpy,
        // 无需字节序转换(不 decode 整个 header,只取这两个长度字段)。
        std::uint16_t key_sz;
        std::uint32_t value_sz;
        std::memcpy(&key_sz,  buf.data() + format::kKeySzOffset,  sizeof(key_sz));
        std::memcpy(&value_sz, buf.data() + format::kValueSzOffset, sizeof(value_sz));

        const std::uint32_t rec_total =
            static_cast<std::uint32_t>(format::kHeaderSize) +
            static_cast<std::uint32_t>(key_sz) + value_sz;

        // 文件尾被 torn write 截断——header 说有 N 字节 body 但磁盘上没那么多。
        // 静默 break，out_last_valid_end 保持上一条 record 的末尾偏移；caller
        // 拿这个值跟 size() 比较，不一致就 truncate_to(out_last_valid_end)。
        if (offset + rec_total > total) break;

        if (buf.size() < rec_total) buf.resize(rec_total);
        auto bn = file_.pread_into(offset, std::span(buf.data(), rec_total));
        if (!bn) return std::unexpected(io_fault(bn.error()));
        if (*bn == 0) break;  // EOF

        // 短读(*bn < rec_total)交给 decode 判 kBufferTooShort,
        // 走与旧实现相同的错误路径。
        auto rec = codec::decode_data_record(
            std::span<const std::byte>(buf.data(), *bn));
        if (!rec) {
            if (rec.error() == codec::DecodeError::kBadCrc && tolerate_crc_errors) {
                if (++crc_errors > kCrcSkipLimit) {
                    return std::unexpected(DataFileFault{DataFileError::kBadCrc});
                }
                offset += rec_total;
                continue;
            }
            switch (rec.error()) {
                case codec::DecodeError::kBadCrc:
                    return std::unexpected(DataFileFault{DataFileError::kBadCrc});
                default:
                    return std::unexpected(DataFileFault{DataFileError::kShortRead});
            }
        }
        fn(*rec, offset, rec_total);
        offset += rec_total;
        if (out_last_valid_end) *out_last_valid_end = offset;
    }
    return {};
}

// 截到指定大小（torn-write 修复用）：seek 到 new_size 然后 ftruncate。
// 跟 truncate_here 区别：caller 显式给目标大小，不依赖当前 current_offset_。
// 必须处于 write 模式——只读 cask 不该乱动磁盘。
std::expected<void, DataFileFault>
DataFile::truncate_to(std::uint64_t new_size) {
    if (mode_ == Mode::kRead) {
        return std::unexpected(DataFileFault{DataFileError::kIo, 0});
    }
    auto s = file_.seek(static_cast<std::int64_t>(new_size), SEEK_SET);
    if (!s) return std::unexpected(io_fault(s.error()));
    auto t = file_.truncate_here();
    if (!t) return std::unexpected(io_fault(t.error()));
    // 截断后 seek 到文件尾，让下一次 pwrite(current_offset_) 紧接着写。
    // current_offset_ 一般由 caller 主动设（恢复路径调用 truncate_to 时
    // 会把 current_offset_ 同步到 new_size）。
    auto e = file_.seek(0, SEEK_END);
    if (!e) return std::unexpected(io_fault(e.error()));
    current_offset_ = *e;
    return {};
}

// ---------------------------------------------------------------------------
// 文件名工具
// ---------------------------------------------------------------------------

std::string mk_data_filename(std::string_view dirname, std::uint64_t tstamp) {
    std::filesystem::path p(dirname);
    p /= (std::to_string(tstamp) + ".bitcask.data");
    return p.string();
}

std::string mk_hint_filename(std::string_view data_path) {
    // 把后缀 ".data" 换成 ".hint"，跟 legacy hintfile_name 完全一致；
    // 没有 ".data" 后缀就直接 append（兜底，正常路径不会走到）。
    constexpr std::string_view kData = ".data";
    constexpr std::string_view kHint = ".hint";
    std::string out(data_path);
    if (out.size() >= kData.size() &&
        out.compare(out.size() - kData.size(), kData.size(), kData) == 0) {
        out.replace(out.size() - kData.size(), kData.size(), kHint);
    } else {
        out.append(kHint);
    }
    return out;
}

std::optional<std::uint64_t>
parse_data_tstamp(std::string_view filename) noexcept {
    // 去掉目录前缀；没斜杠就当 basename 用。
    auto slash = filename.find_last_of('/');
    std::string_view base =
        (slash == std::string_view::npos) ? filename : filename.substr(slash + 1);

    constexpr std::string_view kSuffix = ".bitcask.data";
    if (base.size() <= kSuffix.size()) return std::nullopt;
    if (base.compare(base.size() - kSuffix.size(), kSuffix.size(), kSuffix) != 0) {
        return std::nullopt;
    }
    base = base.substr(0, base.size() - kSuffix.size());

    if (base.empty()) return std::nullopt;
    std::uint64_t tstamp = 0;
    for (char c : base) {
        if (c < '0' || c > '9') return std::nullopt;
        tstamp = tstamp * 10 + static_cast<std::uint64_t>(c - '0');
    }
    return tstamp;
}

}  // namespace bitcask::fileops
