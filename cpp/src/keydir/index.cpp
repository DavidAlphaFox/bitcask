#include "bitcask/index.hpp"

#include <algorithm>

namespace bitcask::index {

void Index::ensure_capacity_locked(std::uint64_t ord) {
    // ord 是数组下标，需要 size >= ord+1。
    const std::size_t want = static_cast<std::size_t>(ord) + 1;
    if (slots_.size() < want) {
        slots_.resize(want);
        ord2ext_.resize(want);
        live_.resize(want, false);
    }
}

std::uint64_t Index::alloc_ord() {
    std::unique_lock lk(mutex_);
    return next_ord_++;
}

void Index::put_doc(std::string_view ext_id, std::uint64_t ord,
                    const DocSlot& slot) {
    std::unique_lock lk(mutex_);

    // 恢复路径用磁盘上的 ord 直接登记，需把分配器推到其后。
    next_ord_ = std::max(next_ord_, ord + 1);
    ensure_capacity_locked(ord);

    // update：ext_id 已存在 → 旧 ord 软删。
    if (auto it = ext2ord_.find(ext_id); it != ext2ord_.end()) {
        const std::uint64_t old_ord = it->second;
        if (old_ord < live_.size() && live_[old_ord]) {
            live_[old_ord] = false;  // 旧版本退出存活集；live_docs_ 不变（同一文档）
        }
        it->second = ord;
    } else {
        ext2ord_.emplace(std::string(ext_id), ord);
        ++live_docs_;
    }

    slots_[ord]   = slot;
    ord2ext_[ord].assign(ext_id);
    live_[ord]    = true;
}

bool Index::remove(std::string_view ext_id, std::uint64_t tomb_ord) {
    std::unique_lock lk(mutex_);

    next_ord_ = std::max(next_ord_, tomb_ord + 1);

    auto it = ext2ord_.find(ext_id);
    if (it == ext2ord_.end()) {
        return false;  // 本就不存在（重复删 / 删未知 key）
    }
    const std::uint64_t cur_ord = it->second;
    if (cur_ord < live_.size() && live_[cur_ord]) {
        live_[cur_ord] = false;
    }
    ext2ord_.erase(it);
    --live_docs_;
    return true;
}

std::optional<DocSlot> Index::get(std::string_view ext_id) const {
    std::shared_lock lk(mutex_);
    auto it = ext2ord_.find(ext_id);
    if (it == ext2ord_.end()) {
        return std::nullopt;
    }
    const std::uint64_t ord = it->second;
    // ext2ord 指向的 ord 必然存活（删除时已 erase），这里直接返回 slot。
    DocSlot s = slots_[ord];
    s.ord = ord;   // 让 caller（如 SearchLayer::on_delete）拿到 ord，无需另查
    return s;
}

std::optional<std::string> Index::ord_to_ext(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    if (ord >= ord2ext_.size()) {
        return std::nullopt;
    }
    return ord2ext_[ord];
}

bool Index::is_live(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    return ord < live_.size() && live_[ord];
}

std::uint32_t Index::doc_len(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    if (ord >= slots_.size()) return 0;
    return slots_[ord].doc_len;
}

IndexInfo Index::info() const {
    std::shared_lock lk(mutex_);
    return IndexInfo{
        .live_docs  = live_docs_,
        .total_ords = next_ord_,
        .next_ord   = next_ord_,
    };
}

}  // namespace bitcask::index
