#include "bitcask/inverted_wal.hpp"
#include "bitcask/codec.hpp"
#include "bitcask/inverted.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>

namespace bitcask::bm25 {

namespace {

constexpr std::uint8_t kWalEntryAddDoc    = 0x01;
constexpr std::uint8_t kWalEntryRemoveDoc = 0x02;

// O11 framing:每条 entry 落盘为 [PayloadLen:u32][Payload][CRC32:u32]。
// CRC 覆盖 Payload;replay 据此检测半条/损坏 entry,截断至上一完整条。
constexpr std::size_t kWalLenPrefix   = 4;
constexpr std::size_t kWalCrcSuffix   = 4;
// 单条 entry payload 上限(防御性:len 字段被垃圾数据撑爆时不至于巨额分配)。
constexpr std::uint32_t kWalMaxPayload = 64u << 20;  // 64 MiB

std::uint32_t crc_of(const std::uint8_t* p, std::size_t n) {
    return codec::crc32(
        std::span<const std::byte>(reinterpret_cast<const std::byte*>(p), n));
}

// 编码端:整条 entry 先 append 进缓冲,再一次 fwrite。
// 字节序/布局与旧的逐字段 fwrite 完全一致(小端内存表示直拷)。

void put_u8(std::vector<std::uint8_t>& b, std::uint8_t v) {
    b.push_back(v);
}

void put_u32(std::vector<std::uint8_t>& b, std::uint32_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 4);
}

void put_u64(std::vector<std::uint8_t>& b, std::uint64_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 8);
}

void put_bytes(std::vector<std::uint8_t>& b, const void* data, std::size_t size) {
    const auto* p = static_cast<const std::uint8_t*>(data);
    b.insert(b.end(), p, p + size);
}

}  // namespace

InvertedWal::InvertedWal(std::string_view path, std::size_t batch_size)
    : path_(path), batch_size_(batch_size) {
    file_ = std::fopen(path_.c_str(), "ab");
}

InvertedWal::~InvertedWal() {
    if (file_) {
        flush_batch();           // V6.2:析构前落盘剩余缓冲,避免数据丢失。
        std::fclose(file_);
    }
}

InvertedWal::InvertedWal(InvertedWal&& other) noexcept
    : path_(std::move(other.path_)), file_(other.file_),
      batch_buf_(std::move(other.batch_buf_)),
      batch_count_(other.batch_count_),
      batch_size_(other.batch_size_) {
    other.file_ = nullptr;
    other.batch_count_ = 0;
}

InvertedWal& InvertedWal::operator=(InvertedWal&& other) noexcept {
    if (this != &other) {
        if (file_) {
            flush_batch();
            std::fclose(file_);
        }
        path_ = std::move(other.path_);
        file_ = other.file_;
        batch_buf_ = std::move(other.batch_buf_);
        batch_count_ = other.batch_count_;
        batch_size_ = other.batch_size_;
        other.file_ = nullptr;
        other.batch_count_ = 0;
    }
    return *this;
}

void InvertedWal::append_add_doc(
    std::uint64_t ord,
    const WalTermPositions& term_data) {
    if (!file_) return;

    enc_buf_.clear();  // 复用容量:稳态零分配
    enc_buf_.resize(kWalLenPrefix);  // 长度前缀占位,payload 编完后回填
    put_u8(enc_buf_, kWalEntryAddDoc);
    put_u64(enc_buf_, ord);

    put_u32(enc_buf_, static_cast<std::uint32_t>(term_data.size()));

    for (auto& [term, data] : term_data) {
        auto& [tf, positions] = data;
        const std::uint32_t term_len = static_cast<std::uint32_t>(term.size());
        put_u32(enc_buf_, term_len);
        put_bytes(enc_buf_, term.data(), term_len);
        put_u32(enc_buf_, tf);

        put_u32(enc_buf_, static_cast<std::uint32_t>(positions.size()));
        put_bytes(enc_buf_, positions.data(), positions.size() * sizeof(std::uint32_t));
    }

    seal_and_write();
}

void InvertedWal::append_remove_doc(
    std::uint32_t doc_len,
    const std::unordered_map<std::string, std::uint32_t>& term_freqs) {
    if (!file_) return;

    enc_buf_.clear();
    enc_buf_.resize(kWalLenPrefix);  // 长度前缀占位
    put_u8(enc_buf_, kWalEntryRemoveDoc);
    put_u32(enc_buf_, doc_len);

    put_u32(enc_buf_, static_cast<std::uint32_t>(term_freqs.size()));

    for (auto& [term, tf] : term_freqs) {
        const std::uint32_t term_len = static_cast<std::uint32_t>(term.size());
        put_u32(enc_buf_, term_len);
        put_bytes(enc_buf_, term.data(), term_len);
        put_u32(enc_buf_, tf);
    }

    seal_and_write();
}

// 封口并落盘:回填长度前缀、追加 payload CRC、一次 fwrite。
// 整条 entry 一次写出,entry 级原子性比逐字段写好;framing 让 replay
// 能区分「完整 entry」与「崩溃残留的半条」。
// V6.2：batch_size>1 时改走 batch_buf_ 累积，到阈值 flush_batch 整块落盘。
void InvertedWal::seal_and_write() {
    const std::size_t payload_len = enc_buf_.size() - kWalLenPrefix;
    const auto len32 = static_cast<std::uint32_t>(payload_len);
    std::memcpy(enc_buf_.data(), &len32, kWalLenPrefix);
    const std::uint32_t crc =
        crc_of(enc_buf_.data() + kWalLenPrefix, payload_len);
    put_u32(enc_buf_, crc);

    if (batch_size_ <= 1) {
        // 即时模式：逐条 fwrite + fflush（默认行为，与旧版完全一致）。
        if (std::fwrite(enc_buf_.data(), 1, enc_buf_.size(), file_) !=
            enc_buf_.size()) {
            return;
        }
        // fflush 保留:这是 WAL 对进程崩溃的持久化边界,去掉属于语义变更。
        std::fflush(file_);
        return;
    }

    // 批量模式：追加到 batch_buf_，满阈值时整块 flush。
    batch_buf_.insert(batch_buf_.end(), enc_buf_.begin(), enc_buf_.end());
    ++batch_count_;
    if (batch_count_ >= batch_size_) {
        flush_batch();
    }
}

// V6.2：把 batch_buf_ 一次性写盘+fflush 并清空。
// 三处共用：seal_and_write 阈值触发 / 析构 / truncate。
void InvertedWal::flush_batch() {
    if (batch_buf_.empty() || !file_) return;
    std::fwrite(batch_buf_.data(), 1, batch_buf_.size(), file_);
    std::fflush(file_);
    batch_buf_.clear();
    batch_count_ = 0;
}

namespace {

// payload 内存解析游标:全部读取带边界检查,越界置 fail 不崩。
struct Cursor {
    const std::uint8_t* p;
    const std::uint8_t* end;
    bool fail = false;

    bool need(std::size_t n) {
        if (static_cast<std::size_t>(end - p) < n) {
            fail = true;
            return false;
        }
        return true;
    }
    std::uint8_t u8() {
        if (!need(1)) return 0;
        return *p++;
    }
    std::uint32_t u32() {
        if (!need(4)) return 0;
        std::uint32_t v;
        std::memcpy(&v, p, 4);
        p += 4;
        return v;
    }
    std::uint64_t u64() {
        if (!need(8)) return 0;
        std::uint64_t v;
        std::memcpy(&v, p, 8);
        p += 8;
        return v;
    }
    bool bytes(void* dst, std::size_t n) {
        if (!need(n)) return false;
        std::memcpy(dst, p, n);
        p += n;
        return true;
    }
};

// 解析一条 payload 并应用到 target。返回 false = payload 内部不自洽
// (CRC 已过却解析失败,理论上只有版本不匹配/写入 bug 才会发生)。
bool apply_entry(const std::uint8_t* data, std::size_t len,
                 InvertedIndex& target) {
    Cursor c{data, data + len};
    const std::uint8_t entry_type = c.u8();

    if (entry_type == kWalEntryAddDoc) {
        const auto ord = c.u64();
        const auto term_count = c.u32();
        if (c.fail || term_count > (1u << 20)) return false;

        WalTermPositions term_data;
        term_data.reserve(term_count);
        for (std::uint32_t i = 0; i < term_count; ++i) {
            const auto term_len = c.u32();
            if (c.fail || term_len > 65536) return false;
            std::string term(term_len, '\0');
            if (!c.bytes(term.data(), term_len)) return false;

            const auto tf = c.u32();
            const auto pos_count = c.u32();
            if (c.fail || pos_count > (1u << 24)) return false;
            std::vector<std::uint32_t> positions(pos_count);
            if (pos_count > 0 &&
                !c.bytes(positions.data(), pos_count * sizeof(std::uint32_t))) {
                return false;
            }
            term_data.emplace(std::move(term),
                              std::make_pair(tf, std::move(positions)));
        }
        if (c.fail) return false;
        target.add_doc(ord, term_data);  // 全部解析通过才应用(整条原子)
        return true;
    }

    if (entry_type == kWalEntryRemoveDoc) {
        const auto doc_len = c.u32();
        const auto term_count = c.u32();
        if (c.fail || term_count > (1u << 20)) return false;

        std::unordered_map<std::string, std::uint32_t> term_freqs;
        term_freqs.reserve(term_count);
        for (std::uint32_t i = 0; i < term_count; ++i) {
            const auto term_len = c.u32();
            if (c.fail || term_len > 65536) return false;
            std::string term(term_len, '\0');
            if (!c.bytes(term.data(), term_len)) return false;
            const auto tf = c.u32();
            if (c.fail) return false;
            term_freqs.emplace(std::move(term), tf);
        }
        target.remove_doc(doc_len, term_freqs);
        return true;
    }

    return false;  // 未知 entry 类型
}

}  // namespace

int InvertedWal::replay(InvertedIndex& target) const {
    if (!file_) return 0;

    std::FILE* input = std::fopen(path_.c_str(), "rb");
    if (!input) return -1;

    int count = 0;
    // 上一条完整 entry 的末尾偏移:检测到损坏/半条时把文件截断到这里,
    // 后续 append 不会接在垃圾后面。
    std::uint64_t last_good = 0;
    bool corrupted = false;
    std::vector<std::uint8_t> payload;

    while (true) {
        std::uint32_t len = 0;
        const std::size_t got = std::fread(&len, 1, kWalLenPrefix, input);
        if (got == 0) break;                       // 干净 EOF
        if (got < kWalLenPrefix || len == 0 || len > kWalMaxPayload) {
            corrupted = true;                      // 半个长度前缀 / 长度疯值
            break;
        }

        payload.resize(len + kWalCrcSuffix);
        if (std::fread(payload.data(), 1, payload.size(), input) !=
            payload.size()) {
            corrupted = true;                      // 半条 payload(崩溃残留)
            break;
        }
        std::uint32_t stored_crc = 0;
        std::memcpy(&stored_crc, payload.data() + len, kWalCrcSuffix);
        if (crc_of(payload.data(), len) != stored_crc) {
            corrupted = true;                      // 位腐/撕裂写
            break;
        }
        if (!apply_entry(payload.data(), len, target)) {
            corrupted = true;                      // CRC 过但内容不自洽
            break;
        }
        ++count;
        last_good += kWalLenPrefix + len + kWalCrcSuffix;
    }
    std::fclose(input);

    if (corrupted) {
        // 截断修复:丢掉损坏尾巴。失败不致命——下次 replay 仍会在同一
        // 位置停下,只是文件里留着垃圾。
        std::error_code ec;
        std::filesystem::resize_file(path_, last_good, ec);
    }
    return count;
}

bool InvertedWal::truncate() {
    if (!file_) return false;
    // V6.2:截断前丢弃尚未落盘的缓冲——wb 模式重开文件,旧缓冲写到新文件
    // 没意义(WAL 即将从快照起重新积攒)。
    batch_buf_.clear();
    batch_count_ = 0;
    std::fclose(file_);
    file_ = std::fopen(path_.c_str(), "wb");
    return file_ != nullptr;
}

}  // namespace bitcask::bm25