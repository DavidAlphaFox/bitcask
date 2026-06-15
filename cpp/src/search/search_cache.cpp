#include "bitcask/search_cache.hpp"

#include <functional>

namespace bitcask::search {

CacheKey CacheKey::make(std::string_view query_type,
                        std::string_view query,
                        std::size_t k) {
    auto h = std::hash<std::string_view>{}(query_type);
    h ^= std::hash<std::string_view>{}(query) + 0x9e3779b9 + (h << 6) + (h >> 2);
    h ^= std::hash<std::size_t>{}(k) + 0x9e3779b9 + (h << 6) + (h >> 2);
    return CacheKey{h};
}

SearchCache::SearchCache(std::size_t max_entries)
    : max_entries_(max_entries) {
}

std::optional<std::vector<bm25::SearchResult>>
SearchCache::get(const CacheKey& key) const {
    std::shared_lock lock(mutex_);

    auto it = map_.find(key.hash);
    if (it == map_.end()) {
        return std::nullopt;
    }

    auto& node = *it->second;
    // LRU 触碰:共享锁下不能动链表,经 atomic_ref 记访问序号。
    std::atomic_ref<std::uint64_t>(node.last_used)
        .store(use_clock_.fetch_add(1, std::memory_order_relaxed) + 1,
               std::memory_order_relaxed);
    return node.results;  // 拷贝(锁内),杜绝指针逃逸后的 UAF
}

void SearchCache::put(const CacheKey& key, std::vector<bm25::SearchResult> results,
                      std::vector<std::string> terms) {
    if (max_entries_ == 0) return;

    std::unique_lock lock(mutex_);

    const std::uint64_t now =
        use_clock_.fetch_add(1, std::memory_order_relaxed) + 1;
    auto it = map_.find(key.hash);
    if (it != map_.end()) {
        it->second->results = std::move(results);
        it->second->terms = std::move(terms);
        // 经 atomic_ref 写:与 get 的 atomic_ref 访问保持同一对象全程原子。
        std::atomic_ref<std::uint64_t>(it->second->last_used)
            .store(now, std::memory_order_relaxed);
        return;
    }

    lru_list_.push_front(ListNode{key, std::move(results), std::move(terms), now});
    map_[key.hash] = lru_list_.begin();

    evict_if_needed();
}

void SearchCache::invalidate() {
    std::unique_lock lock(mutex_);
    lru_list_.clear();
    map_.clear();
}

void SearchCache::invalidate_terms(const std::vector<std::string>& changed_terms) {
    if (changed_terms.empty()) return;

    std::unique_lock lock(mutex_);
    if (map_.empty()) return;

    std::unordered_set<std::string_view> changed(changed_terms.begin(),
                                                 changed_terms.end());

    for (auto it = lru_list_.begin(); it != lru_list_.end();) {
        bool hit = false;
        for (const auto& t : it->terms) {
            if (changed.count(t)) { hit = true; break; }
        }
        if (hit) {
            map_.erase(it->key.hash);
            it = lru_list_.erase(it);
        } else {
            ++it;
        }
    }
}

std::size_t SearchCache::size() const {
    std::shared_lock lock(mutex_);
    return map_.size();
}

std::size_t SearchCache::max_entries() const {
    return max_entries_;
}

void SearchCache::evict_if_needed() {
    // 链表顺序不再承载 LRU 语义,按 last_used 计数找最旧者淘汰。
    // O(n) 扫描,n ≤ max_entries_(默认 256),仅在 put 溢出时发生。
    while (lru_list_.size() > max_entries_) {
        auto oldest = lru_list_.begin();
        auto lu = [](const ListNode& n) {
            return std::atomic_ref<std::uint64_t>(
                       const_cast<std::uint64_t&>(n.last_used))
                .load(std::memory_order_relaxed);
        };
        for (auto it = std::next(oldest); it != lru_list_.end(); ++it) {
            if (lu(*it) < lu(*oldest)) oldest = it;
        }
        map_.erase(oldest->key.hash);
        lru_list_.erase(oldest);
    }
}

}  // namespace bitcask::search