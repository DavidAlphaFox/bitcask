// 搜索结果 LRU 缓存。
//
// 缓存 key = hash(查询类型 + 查询字符串 + k)，
// 缓存 value = vector<SearchResult>（ord + score，不含 key 翻译）。
// 失效（S9.2）：写/删一篇文档时，只失效「查询词与该文档词集有交集」的条目
// （invalidate_terms）；拿不到文档词集时降级为整缓存失效（invalidate）。
// 注意：BM25 全局统计（N/avgdl/IDF）会随任意增删漂移，故选择性失效是
// near-real-time 近似——文档的出现/消失精确，已缓存条目的 score 绝对值
// 可能轻微陈旧。
// 线程安全：mutex 保护（search 已在 dirty scheduler 上执行，竞争低）。
#pragma once

#include <cstdint>
#include <list>
#include <mutex>
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

    // 查询缓存。命中返回结果指针，未命中返回 nullptr。
    // 线程安全。
    [[nodiscard]] const std::vector<bm25::SearchResult>* get(const CacheKey& key) const;

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

    // LRU 链表：front = 最近访问，back = 最久未访问。
    struct ListNode {
        CacheKey key;
        std::vector<bm25::SearchResult> results;
        std::vector<std::string> terms;   // 该查询的词集（用于 invalidate_terms 交集判定）
    };
    mutable std::list<ListNode> lru_list_;

    // key → list iterator
    mutable std::unordered_map<std::uint64_t, std::list<ListNode>::iterator> map_;

    // 互斥锁（搜索已在 dirty scheduler，竞争低）。
    mutable std::mutex mutex_;

    void evict_if_needed();
};

}  // namespace bitcask::search