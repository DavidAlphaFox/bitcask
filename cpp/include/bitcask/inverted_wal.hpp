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
    explicit InvertedWal(std::string_view path);
    ~InvertedWal();

    InvertedWal(const InvertedWal&) = delete;
    InvertedWal& operator=(const InvertedWal&) = delete;
    InvertedWal(InvertedWal&&) noexcept;
    InvertedWal& operator=(InvertedWal&&) noexcept;

    void append_add_doc(std::uint64_t ord, WalTermPositions term_data);
    void append_remove_doc(std::uint32_t doc_len,
                           const std::unordered_map<std::string, std::uint32_t>& term_freqs);

    int replay(InvertedIndex& target) const;
    bool truncate();
    bool valid() const { return file_ != nullptr; }

private:
    std::string path_;
    std::FILE* file_ = nullptr;
};

}  // namespace bitcask::bm25