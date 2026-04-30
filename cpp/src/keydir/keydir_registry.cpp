#include "bitcask/keydir_registry.hpp"

#include <algorithm>

namespace bitcask::keydir {

AcquireResult KeyDirRegistry::acquire(std::string_view name) {
    std::scoped_lock lock(mutex_);
    const std::string key(name);

    auto it = entries_.find(key);
    if (it != entries_.end()) {
        // 已存在的 slot：只有 keydir 就绪了才递交引用，否则告诉调用方
        // 「在等初始化完成」。
        if (!it->second.keydir->is_ready()) {
            return AcquireResult{AcquireStatus::kNotReady, nullptr};
        }
        it->second.refcount += 1;
        return AcquireResult{AcquireStatus::kReady, it->second.keydir};
    }

    // 全新 slot：如果之前有同名 keydir 释放过，把保留的 biggest_file_id
    // 灌进新 KeyDir，保证 open/close 跨实例时 file_id 永远单调递增。
    // 这是为了避免「老 file_id 复用 → keydir 把旧 entry 误判为最新」的灾难。
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
    // 注意：query 只是探测——不动 refcount。想拿到「可用的、生命周期受
    // 注册表保护的」keydir handle 必须走 acquire()。
    return AcquireResult{AcquireStatus::kReady, it->second.keydir};
}

void KeyDirRegistry::release(std::string_view name) {
    std::scoped_lock lock(mutex_);
    auto it = entries_.find(std::string(name));
    if (it == entries_.end()) return;  // 别的路径已经 release 过了，幂等

    if (--it->second.refcount > 0) return;

    // 最后一个引用：把 biggest_file_id + 1 持久化下来。下一次 acquire
    // 同名 keydir 时会从这个值开始往上分配 file_id，永不复用旧 id。
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
