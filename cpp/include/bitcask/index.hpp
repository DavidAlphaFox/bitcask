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
// 在外部预先持锁。组合操作（如 get 后 put）非原子。*_locked 后缀的
// 私有方法要求 caller 已持 unique_lock。

#pragma once

#include "bitcask/live_checker.hpp"
#include "bitcask/string_hash.hpp"

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

// 透明 hash 已提到 bitcask/string_hash.hpp 与 KeyDir 共用。
using bitcask::StringHash;

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
    std::uint32_t doc_len = 0;   // BM25 token 数（V2 由 analyzer 填）
    std::uint64_t ord     = 0;   // 该文档的 ord（仅 get() 返回时填充；slots_ 内存的副本不依赖此值）
};

struct IndexInfo {
    std::uint64_t live_docs  = 0;   // 当前存活文档数（= ext2ord_.size()）
    std::uint64_t total_ords = 0;   // 历史分配 ord 数（含已死）
    std::uint64_t next_ord   = 0;
};

class Index : public bm25::LiveChecker {
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

    // V5:存储 ord 的 meta blob(结构化 KV 二进制,可为空)。与 put_doc
    // 在同一 unique_lock 下调用——保证 meta 与定位/live 同写入原子点,
    // 后续读路径不必额外同步。blob 由 Index 内部拷贝(caller 可立即
    // 释放源缓冲)。线程安全:unique_lock。
    void set_meta(std::uint64_t ord, std::span<const std::byte> blob);

    // ---- 读 ----
    // 取 ext_id 当前存活文档的定位；不存在/已删返回 nullopt。
    // 线程安全：shared_lock。
    [[nodiscard]] std::optional<DocSlot> get(std::string_view ext_id) const;

    // ord → ext_id（检索结果翻译用；V1 主要给调试/恢复）。越界返回 nullopt。
    [[nodiscard]] std::optional<std::string> ord_to_ext(std::uint64_t ord) const;

    // 某 ord 是否存活。越界返回 false。线程安全：shared_lock。
    // 同时实现 LiveChecker::is_live。
    [[nodiscard]] bool is_live(std::uint64_t ord) const override;

    // LiveChecker::doc_len — 返回 ord 对应文档的 token 数，越界返回 0。
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t ord) const override;

    // V5:取 ord 的原始 meta blob(结构化 KV 二进制)。越界或空 → 空 span,
    // 让上层 filter 直接判 false 跳过(无 meta = 不通过过滤)。
    // 线程安全:shared_lock;返回的 span 指向 Index 内部存储,生命周期止于
    // 下一次 set_meta(同 ord)——caller 不得跨 set_meta 持留此 span。
    [[nodiscard]] std::span<const std::byte> meta_blob(std::uint64_t ord) const;

    // P2.1 批量版本：一次 shared_lock 完成整个数组（逐 posting 版本每条
    // posting 一次锁 + 一次虚调用，热词查询 = 数十万次锁操作且阻断评分
    // 循环的自动向量化）。
    void fill_is_live(std::span<const std::uint64_t> ords,
                      std::span<char> out) const override;
    void fill_doc_lens(std::span<const std::uint64_t> ords,
                       std::span<std::uint32_t> out) const override;

    // ---- 内省 ----
    [[nodiscard]] IndexInfo info() const;

    // 遍历所有 live 文档，对每个调用 fn(ord, ext_id, slot)。
    // 线程安全：持 shared_lock。
    template <typename Fn>
    void for_each_live(Fn&& fn) const {
        std::shared_lock lk(mutex_);
        for (std::uint64_t ord = 0; ord < slots_.size(); ++ord) {
            if (live_[ord]) {
                fn(ord, ord2ext_[ord], slots_[ord]);
            }
        }
    }

private:
    mutable std::shared_mutex mutex_;

    std::unordered_map<std::string, std::uint64_t,
                       StringHash, std::equal_to<>> ext2ord_;  // ext_id → 最新 ord
    std::vector<DocSlot>     slots_;                          // 下标 = ord
    std::vector<std::string> ord2ext_;                        // 下标 = ord
    std::vector<std::uint8_t> live_;                          // 下标 = ord;0/1。非 vector<bool>:
                                                              // 避免 bit-pack 的位操作与代理引用开销
    // P2.4：doc_len 的 SoA 读优化副本（下标 = ord）。slots_[ord].doc_len 仍是
    // API 返回值的来源（get/for_each_live 语义不变），但 BM25 评分的
    // fill_doc_lens 稀疏 gather 改读本数组：DocSlot 32B/项 → 每条 cache line
    // 只有 4B 有用；u32 紧凑数组 = 16 项/line。与 slots_ 同一 unique_lock
    // 下写入，不会发散。
    std::vector<std::uint32_t> doc_lens_;
    // V5:per-ord 原始 meta blob(结构化 KV 二进制,可为空)。与 slots_/doc_lens_
    // 同一 unique_lock 下写入,读路径按 ord 下标直取——零拷贝 span。
    std::vector<std::vector<std::byte>> meta_blobs_;
    std::uint64_t next_ord_  = 0;
    std::uint64_t live_docs_ = 0;

    // 把 ord 下标的数组按需扩到能容纳 ord。caller 持 unique_lock。
    void ensure_capacity_locked(std::uint64_t ord);
};

}  // namespace bitcask::index
