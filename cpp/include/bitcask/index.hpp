// 向量库的内存索引侧表（Index）。
//
// Index 是 legacy KeyDir 的演化版（doc/vector-db-design-zh.md §3.1）：主映射
// 从「key → location」改为「ext_id → 最新 ord」+ 一组「ord 下标的数组」
// （slots / ord2ext / live）。ord 是引擎单调分配的 per-write 序号，永不复用，
// 所以 ord→X 用数组而非 hashmap（O(1) 下标、省内存）。
//
// V1 范围：只承载身份映射 + 文档定位 + 软删，不含 BM25 倒排 / HNSW / fold MVCC。
//
// === 线程模型 ===
// 所有 public 方法线程安全：读取 shared_lock、写入 unique_lock。caller 不应
// 在外部预先持锁。组合操作（如 get 后 put）非原子——V1 由 Collection「单写者」
// 保证。*_locked 后缀的私有方法要求 caller 已持 unique_lock。

#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bitcask::index {

// 透明 hash/equal：让 ext2ord_ 支持用 string_view 直接查找，免去临时 string 拷贝。
struct StringHash {
    using is_transparent = void;
    std::size_t operator()(std::string_view s) const noexcept {
        return std::hash<std::string_view>{}(s);
    }
};

// 一条文档在磁盘上的定位（pread 整条 kDoc 用）。
struct DocLoc {
    std::uint32_t file_id  = 0;
    std::uint64_t offset   = 0;
    std::uint32_t total_sz = 0;
};

// 按 ord 存的每文档元信息（slots[ord]）。
struct DocSlot {
    DocLoc        loc;
    std::uint32_t tstamp  = 0;
    std::uint32_t doc_len = 0;   // V1 恒 0；V2 切词时填
};

struct IndexInfo {
    std::uint64_t live_docs  = 0;   // 当前存活文档数（= ext2ord_.size()）
    std::uint64_t total_ords = 0;   // 历史分配 ord 数（含已死）
    std::uint64_t next_ord   = 0;
};

class Index {
public:
    Index() = default;
    Index(const Index&) = delete;
    Index& operator=(const Index&) = delete;

    // ---- ord 分配 ----
    // 拿下一个 ord（写 record header 前调用）。线程安全：unique_lock。
    std::uint64_t alloc_ord();

    // ---- 写 ----
    // 登记一条文档（append 落盘后调用）。若 ext_id 已存在 → update：旧 ord
    // 在 live 中清 0（软删），ext2ord 改指新 ord。内部把 next_ord 推到
    // max(next_ord, ord+1)，故恢复时按 ord 序回放亦走此方法。
    // 线程安全：unique_lock。
    void put_doc(std::string_view ext_id, std::uint64_t ord, const DocSlot& slot);

    // 删除：软删 ext_id 当前文档（清 live）、erase ext2ord。tomb_ord 是墓碑
    // record 自身的 ord（仅用于推进 next_ord）。返回原本是否存在。
    // 线程安全：unique_lock。
    bool remove(std::string_view ext_id, std::uint64_t tomb_ord);

    // ---- 读 ----
    // 取 ext_id 当前存活文档的定位；不存在/已删返回 nullopt。
    // 线程安全：shared_lock。
    [[nodiscard]] std::optional<DocSlot> get(std::string_view ext_id) const;

    // ord → ext_id（检索结果翻译用；V1 主要给调试/恢复）。越界返回 nullopt。
    [[nodiscard]] std::optional<std::string> ord_to_ext(std::uint64_t ord) const;

    // 某 ord 是否存活。越界返回 false。线程安全：shared_lock。
    [[nodiscard]] bool is_live(std::uint64_t ord) const;

    // ---- 内省 ----
    [[nodiscard]] IndexInfo info() const;

private:
    mutable std::shared_mutex mutex_;

    std::unordered_map<std::string, std::uint64_t,
                       StringHash, std::equal_to<>> ext2ord_;  // ext_id → 最新 ord
    std::vector<DocSlot>     slots_;                          // 下标 = ord
    std::vector<std::string> ord2ext_;                        // 下标 = ord
    std::vector<bool>        live_;                           // 下标 = ord（Roaring 留待优化）
    std::uint64_t next_ord_  = 0;
    std::uint64_t live_docs_ = 0;

    // 把 ord 下标的数组按需扩到能容纳 ord。caller 持 unique_lock。
    void ensure_capacity_locked(std::uint64_t ord);
};

}  // namespace bitcask::index
