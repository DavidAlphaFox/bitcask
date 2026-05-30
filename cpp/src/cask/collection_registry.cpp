#include "bitcask/collection_registry.hpp"

namespace bitcask {

CollectionAcquireResult CollectionRegistry::acquire(std::string_view name) {
    std::lock_guard lk(mutex_);
    std::string key(name);
    auto it = entries_.find(key);
    if (it != entries_.end()) {
        auto& slot = it->second;
        if (!slot.data->is_ready()) {
            return {CollectionAcquireStatus::kNotReady, nullptr};
        }
        ++slot.refcount;
        return {CollectionAcquireStatus::kReady, slot.data};
    }
    auto data = std::make_shared<CollectionSharedData>();
    auto& slot = entries_[key];
    slot.data = data;
    slot.refcount = 1;
    return {CollectionAcquireStatus::kCreated, data};
}

CollectionAcquireResult CollectionRegistry::query(std::string_view name) const {
    std::lock_guard lk(mutex_);
    auto it = entries_.find(std::string(name));
    if (it == entries_.end() || !it->second.data->is_ready()) {
        return {CollectionAcquireStatus::kNotReady, nullptr};
    }
    return {CollectionAcquireStatus::kReady, it->second.data};
}

void CollectionRegistry::release(std::string_view name) {
    std::lock_guard lk(mutex_);
    auto it = entries_.find(std::string(name));
    if (it == entries_.end()) return;
    --it->second.refcount;
    if (it->second.refcount == 0) {
        entries_.erase(it);
    }
}

std::size_t CollectionRegistry::size() const noexcept {
    std::lock_guard lk(mutex_);
    return entries_.size();
}

}  // namespace bitcask
