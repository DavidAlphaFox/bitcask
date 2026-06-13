// 倒排索引 WAL（Write-Ahead Log，S8.9）。
//
// 以追加方式记录 add_doc/remove_doc 操作，在两次全量快照之间
// 减少磁盘 sync 开销。加载时先读快照、再重放 WAL。

#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bitcask::bm25 {

class InvertedIndex;

using WalTermPositions = std::unordered_map<std::string, std::pair<std::uint32_t, std::vector<std::uint32_t>>>;

// WAL 追加器（append-only）。
// 线程安全：非线程安全，由 caller 串行化（与 InvertedIndex 写路径一致）。
class InvertedWal {
public:
    // batch_size=1:即时模式,逐条 fwrite+fflush(原行为,默认)。
    // batch_size>1:批量模式,积攒到阈值后单次 fwrite+fflush。
    explicit InvertedWal(std::string_view path, std::size_t batch_size = 1);
    ~InvertedWal();

    InvertedWal(const InvertedWal&) = delete;
    InvertedWal& operator=(const InvertedWal&) = delete;
    InvertedWal(InvertedWal&&) noexcept;
    InvertedWal& operator=(InvertedWal&&) noexcept;

    void append_add_doc(std::uint64_t ord, const WalTermPositions& term_data);
    void append_remove_doc(std::uint32_t doc_len,
                           const std::unordered_map<std::string, std::uint32_t>& term_freqs);

    int replay(InvertedIndex& target) const;
    bool truncate();
    bool valid() const { return file_ != nullptr; }

private:
    // O11:回填长度前缀 + 追加 CRC + 一次 fwrite(entry framing 封口)。
    void seal_and_write();
    // V6.2:把 batch_buf_ 整块写盘并清空(析构/truncate/threshold 触发点共用)。
    void flush_batch();

    std::string path_;
    std::FILE* file_ = nullptr;
    std::vector<std::uint8_t> enc_buf_;      // append_* 复用的整条 entry 编码缓冲
    std::vector<std::uint8_t> batch_buf_;    // V6.2:批量模式缓冲的待写 entry 字节
    std::size_t               batch_count_ = 0;  // V6.2:当前 batch 已攒条目数
    std::size_t               batch_size_  = 1;  // V6.2:触发 flush 的阈值
};

}  // namespace bitcask::bm25