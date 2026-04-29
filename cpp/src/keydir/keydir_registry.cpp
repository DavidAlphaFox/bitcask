#include "bitcask/keydir_registry.hpp"

#include <algorithm>

namespace bitcask::keydir {

AcquireResult KeyDirRegistry::acquire(std::string_view name) {
    std::scoped_lock lock(mutex_);
    const std::string key(name);

    auto it = entries_.find(key);
    if (it != entries_.end()) {
        // Existing slot: only hand out a ref if the keydir is ready.
        if (!it->second.keydir->is_ready()) {
            return AcquireResult{AcquireStatus::kNotReady, nullptr};
        }
        it->second.refcount += 1;
        return AcquireResult{AcquireStatus::kReady, it->second.keydir};
    }

    // Fresh slot. Pre-seed biggest_file_id from the saved value if any —
    // this is what guarantees file ids never regress across open/close.
    auto kd = std::make_shared<KeyDir>();
    auto saved_it = saved_biggest_file_id_.find(key);
    if (saved_it != saved_biggest_file_id_.end()) {
        kd->increment_file_id_at_least(saved_it->second);
    }
    Slot slot{kd, 1};
    entries_.emplace(key, std::move(slot));
    return AcquireResult{AcquireStatus::kCreated, kd};
}

AcquireResult KeyDirRegistry::query(std::string_view name) const {
    std::scoped_lock lock(mutex_);
    auto it = entries_.find(std::string(name));
    if (it == entries_.end() || !it->second.keydir->is_ready()) {
        return AcquireResult{AcquireStatus::kNotReady, nullptr};
    }
    // Note: `query` is a probe — does NOT bump refcount. Caller wanting a
    // usable handle must call acquire().
    return AcquireResult{AcquireStatus::kReady, it->second.keydir};
}

void KeyDirRegistry::release(std::string_view name) {
    std::scoped_lock lock(mutex_);
    auto it = entries_.find(std::string(name));
    if (it == entries_.end()) return;  // already released by another path

    if (--it->second.refcount > 0) return;

    // Last reference: persist biggest_file_id + 1 (legacy: ensures no reuse).
    const std::uint32_t bumped = it->second.keydir->biggest_file_id() + 1;
    auto& saved = saved_biggest_file_id_[std::string(name)];
    saved = std::max(saved, bumped);
    entries_.erase(it);
}

std::size_t KeyDirRegistry::size() const noexcept {
    std::scoped_lock lock(mutex_);
    return entries_.size();
}

std::optional<std::uint32_t>
KeyDirRegistry::saved_biggest_file_id(std::string_view name) const {
    std::scoped_lock lock(mutex_);
    auto it = saved_biggest_file_id_.find(std::string(name));
    if (it == saved_biggest_file_id_.end()) return std::nullopt;
    return it->second;
}

}  // namespace bitcask::keydir
