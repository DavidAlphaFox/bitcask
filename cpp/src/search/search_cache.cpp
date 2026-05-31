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

const std::vector<bm25::SearchResult>* SearchCache::get(const CacheKey& key) const {
    std::lock_guard<std::mutex> lock(mutex_);

    auto it = map_.find(key.hash);
    if (it == map_.end()) {
        return nullptr;
    }

    auto& node = *it->second;
    lru_list_.splice(lru_list_.begin(), lru_list_, it->second);
    return &node.results;
}

void SearchCache::put(const CacheKey& key, std::vector<bm25::SearchResult> results) {
    if (max_entries_ == 0) return;

    std::lock_guard<std::mutex> lock(mutex_);

    auto it = map_.find(key.hash);
    if (it != map_.end()) {
        it->second->results = std::move(results);
        lru_list_.splice(lru_list_.begin(), lru_list_, it->second);
        return;
    }

    lru_list_.push_front(ListNode{key, std::move(results)});
    map_[key.hash] = lru_list_.begin();

    evict_if_needed();
}

void SearchCache::invalidate() {
    std::lock_guard<std::mutex> lock(mutex_);
    lru_list_.clear();
    map_.clear();
}

std::size_t SearchCache::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return map_.size();
}

std::size_t SearchCache::max_entries() const {
    return max_entries_;
}

void SearchCache::evict_if_needed() {
    while (lru_list_.size() > max_entries_) {
        map_.erase(lru_list_.back().key.hash);
        lru_list_.pop_back();
    }
}

}  // namespace bitcask::search