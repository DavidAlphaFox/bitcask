// 搜索结果 LRU 缓存。
//
// 缓存 key = hash(查询类型 + 查询字符串 + k)，
// 缓存 value = vector<SearchResult>（ord + score，不含 key 翻译）。
// on_write/on_delete 时整缓存失效。
// 线程安全：mutex 保护（search 已在 dirty scheduler 上执行，竞争低）。
#pragma once

#include <cstdint>
#include <list>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
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
    // 线程安全。
    void put(const CacheKey& key, std::vector<bm25::SearchResult> results);

    // 整缓存失效（on_write/on_delete 时调用）。
    // 线程安全。
    void invalidate();

    // 调试统计。
    [[nodiscard]] std::size_t size() const;
    [[nodiscard]] std::size_t max_entries() const;

private:
    std::size_t max_entries_;

    // LRU 链表：front = 最近访问，back = 最久未访问。
    struct ListNode {
        CacheKey key;
        std::vector<bm25::SearchResult> results;
    };
    mutable std::list<ListNode> lru_list_;

    // key → list iterator
    mutable std::unordered_map<std::uint64_t, std::list<ListNode>::iterator> map_;

    // 互斥锁（搜索已在 dirty scheduler，竞争低）。
    mutable std::mutex mutex_;

    void evict_if_needed();
};

}  // namespace bitcask::search