// 搜索结果 LRU 缓存。
//
// 缓存 key = hash(查询类型 + 查询字符串 + k)，
// 缓存 value = vector<SearchResult>（ord + score，不含 key 翻译）。
// 失效（S9.2）：写/删一篇文档时，只失效「查询词与该文档词集有交集」的条目
// （invalidate_terms）；拿不到文档词集时降级为整缓存失效（invalidate）。
// 注意：BM25 全局统计（N/avgdl/IDF）会随任意增删漂移，故选择性失效是
// near-real-time 近似——文档的出现/消失精确，已缓存条目的 score 绝对值
// 可能轻微陈旧。
// 线程安全：shared_mutex——get 共享锁并发,写/失效独占。LRU 触碰经
// per-node 访问计数(atomic_ref)完成,get 不再修改链表;淘汰时按计数
// 找最旧(序仍是精确 LRU,只是不靠链表顺序表达)。
#pragma once

#include <atomic>
#include <cstdint>
#include <list>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "bitcask/inverted.hpp"  // SearchResult

namespace bitcask::search {

// 缓存 key：查询类型（text/phrase/bool）+ 查询字符串 + k 的哈希。
struct CacheKey {
    std::uint64_t hash;

    static CacheKey make(std::string_view query_type,
                         std::string_view query,
                         std::size_t k);
};

// 缓存条目。
struct CacheEntry {
    std::vector<bm25::SearchResult> results;
};

class SearchCache {
public:
    explicit SearchCache(std::size_t max_entries = 256);

    // 查询缓存。命中返回结果拷贝(nullopt = 未命中)。
    // 返回拷贝而非内部指针:旧接口的指针在解锁后可能被并发 put/evict
    // 释放(UAF 窗口);k 通常 ≤100,拷贝可忽略。
    // 线程安全(共享锁,多读者并发)。
    [[nodiscard]] std::optional<std::vector<bm25::SearchResult>>
    get(const CacheKey& key) const;

    // 写入缓存。如果已满则淘汰 LRU 条目。
    // terms：该查询命中的查询词集合，供 invalidate_terms 做交集判定。
    // 线程安全。
    void put(const CacheKey& key, std::vector<bm25::SearchResult> results,
             std::vector<std::string> terms);

    // 整缓存失效（拿不到变更文档词集时的降级路径）。
    // 线程安全。
    void invalidate();

    // 选择性失效：移除「查询词与 changed_terms 有交集」的缓存条目（S9.2）。
    // changed_terms 为被写入/删除文档的词集。
    // 线程安全。
    void invalidate_terms(const std::vector<std::string>& changed_terms);

    // 调试统计。
    [[nodiscard]] std::size_t size() const;
    [[nodiscard]] std::size_t max_entries() const;

private:
    std::size_t max_entries_;

    // 条目链表(节点地址稳定;顺序无语义,LRU 由 last_used 计数表达)。
    struct ListNode {
        CacheKey key;
        std::vector<bm25::SearchResult> results;
        std::vector<std::string> terms;   // 该查询的词集（用于 invalidate_terms 交集判定）
        // 访问序号。所有读写一律经 atomic_ref（get 共享锁下并发更新）——
        // 混用 atomic_ref 与普通访问同一对象是 UB,即便锁已排斥并发重叠。
        std::uint64_t last_used = 0;
    };
    mutable std::list<ListNode> lru_list_;

    // key → list iterator
    mutable std::unordered_map<std::uint64_t, std::list<ListNode>::iterator> map_;

    // 读写锁:get 共享,put/invalidate 独占。
    mutable std::shared_mutex mutex_;
    // 全局访问时钟(LRU 序号源)。
    mutable std::atomic<std::uint64_t> use_clock_{0};

    void evict_if_needed();
};

}  // namespace bitcask::search