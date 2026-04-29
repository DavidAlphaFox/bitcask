#include "bitcask/keydir.hpp"

#include <algorithm>
#include <cassert>
#include <shared_mutex>

namespace bitcask::keydir {

// =============================================================================
// Helpers (no locking; assume the caller holds the keydir mutex)
// =============================================================================

namespace {

// Sibling-tombstone marker matches legacy is_sib_tombstone():
//   file_id == MAX_FILE_ID && total_sz == MAX_SIZE && offset == MAX_OFFSET.
SingleEntry make_sibling_tombstone(std::uint64_t epoch, std::uint32_t tstamp) noexcept {
    return SingleEntry{kMaxFileId, kMaxSize, kMaxOffset, epoch, tstamp};
}
[[nodiscard]] bool is_sibling_tombstone(const SingleEntry& s) noexcept {
    return s.file_id == kMaxFileId && s.total_sz == kMaxSize && s.offset == kMaxOffset;
}

// Pending-tombstone marker matches legacy is_pending_tombstone():
//   offset == MAX_OFFSET (file_id/total_sz are inherited from a real entry).
[[nodiscard]] bool is_pending_tombstone(const SingleEntry& s) noexcept {
    return s.offset == kMaxOffset;
}

// Convert a SingleEntry to EntryProxy.
[[nodiscard]] EntryProxy to_proxy(std::string_view key, const SingleEntry& s,
                                   bool tombstone) noexcept {
    return EntryProxy{
        .file_id      = s.file_id,
        .total_sz     = s.total_sz,
        .offset       = s.offset,
        .epoch        = s.epoch,
        .tstamp       = s.tstamp,
        .is_tombstone = tombstone,
        .key          = key,
    };
}

// Find the revision visible at `target_epoch`. Returns {found, revision,
// is_tombstone}. For a SingleEntry, simple epoch comparison. For MultiEntry,
// scan newest-first for the first revision whose epoch <= target_epoch.
struct EntryAt {
    bool found = false;
    SingleEntry rev{};
    bool is_tombstone = false;
};
[[nodiscard]] EntryAt entry_at_epoch(const Entry& e, std::uint64_t target_epoch) noexcept {
    EntryAt out;
    if (const auto* s = std::get_if<SingleEntry>(&e)) {
        if (target_epoch < s->epoch) return out;  // not yet existed
        out.found = true;
        out.rev = *s;
        out.is_tombstone = false;  // SingleEntry never holds a tombstone
        return out;
    }
    const auto& m = std::get<MultiEntry>(e);
    for (const auto& rev : m.revisions) {
        if (target_epoch >= rev.epoch) {
            out.found = true;
            out.rev = rev;
            out.is_tombstone = is_sibling_tombstone(rev);
            return out;
        }
    }
    return out;  // target_epoch precedes the chain
}

}  // namespace

// =============================================================================
// fstats
// =============================================================================

void KeyDir::update_fstats_locked(std::uint32_t file_id, std::uint32_t tstamp,
                                   std::uint64_t expiration_epoch,
                                   std::int32_t live_inc, std::int32_t total_inc,
                                   std::int32_t live_bytes_inc,
                                   std::int32_t total_bytes_inc,
                                   bool should_create) {
    auto it = fstats_.find(file_id);
    if (it == fstats_.end()) {
        if (!should_create) return;
        FStatsEntry e;
        e.file_id          = file_id;
        e.expiration_epoch = kMaxEpoch;
        it = fstats_.emplace(file_id, e).first;
    }
    auto& f = it->second;
    f.live_keys = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.live_keys) + live_inc);
    f.total_keys = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.total_keys) + total_inc);
    f.live_bytes = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.live_bytes) + live_bytes_inc);
    f.total_bytes = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.total_bytes) + total_bytes_inc);

    if (expiration_epoch < f.expiration_epoch) {
        f.expiration_epoch = expiration_epoch;
    }
    if ((tstamp != 0 && tstamp < f.oldest_tstamp) || f.oldest_tstamp == 0) {
        f.oldest_tstamp = tstamp;
    }
    if ((tstamp != 0 && tstamp > f.newest_tstamp) || f.newest_tstamp == 0) {
        f.newest_tstamp = tstamp;
    }
}

void KeyDir::update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                            std::uint64_t expiration_epoch,
                            std::int32_t live_inc, std::int32_t total_inc,
                            std::int32_t live_bytes_inc,
                            std::int32_t total_bytes_inc,
                            bool should_create) {
    std::unique_lock lock(mutex_);
    update_fstats_locked(file_id, tstamp, expiration_epoch,
                         live_inc, total_inc, live_bytes_inc, total_bytes_inc,
                         should_create);
}

void KeyDir::set_pending_delete(std::uint32_t file_id) {
    std::unique_lock lock(mutex_);
    update_fstats_locked(file_id, /*tstamp*/ 0,
                         /*expiration_epoch*/ epoch_,
                         0, 0, 0, 0, /*should_create*/ false);
}

std::uint32_t KeyDir::trim_fstats(std::span<const std::uint32_t> ids) {
    std::unique_lock lock(mutex_);
    std::uint32_t missing = 0;
    for (auto id : ids) {
        if (fstats_.erase(id) == 0) ++missing;
    }
    return missing;
}

// =============================================================================
// put / get / remove
// =============================================================================

std::optional<EntryProxy> KeyDir::get(std::string_view key,
                                       std::uint64_t target_epoch) const {
    std::shared_lock lock(mutex_);

    // Pending hash first if it exists and pending entry's epoch is visible
    // at the requested epoch (legacy find_keydir_entry rule).
    if (pending_.has_value()) {
        auto p = pending_->find(std::string(key));
        if (p != pending_->end() && target_epoch >= p->second.epoch) {
            const SingleEntry& s = p->second;
            const bool tomb = is_pending_tombstone(s);
            if (tomb) return std::nullopt;
            return to_proxy(p->first, s, /*tombstone*/ false);
        }
    }

    auto it = entries_.find(std::string(key));
    if (it == entries_.end()) return std::nullopt;

    auto found = entry_at_epoch(it->second, target_epoch);
    if (!found.found || found.is_tombstone) return std::nullopt;
    return to_proxy(it->first, found.rev, /*tombstone*/ false);
}

std::uint64_t KeyDir::get_epoch() const {
    std::shared_lock lock(mutex_);
    return epoch_;
}

PutResult KeyDir::put(std::string_view key,
                       std::uint32_t file_id, std::uint32_t total_sz,
                       std::uint64_t offset, std::uint32_t tstamp,
                       std::uint32_t now_sec,
                       bool newest_put,
                       std::uint32_t old_file_id, std::uint64_t old_offset) {
    std::unique_lock lock(mutex_);

    // Resolve current state of this key (consulting pending then entries),
    // mirroring legacy find_keydir_entry with epoch == kMaxEpoch.
    SingleEntry* pending_entry = nullptr;
    Entry* entries_entry = nullptr;
    EntryProxy current_proxy{};
    bool found = false;
    bool current_is_tombstone = false;

    if (pending_.has_value()) {
        auto p = pending_->find(std::string(key));
        if (p != pending_->end() && kMaxEpoch >= p->second.epoch) {
            pending_entry = &p->second;
            current_is_tombstone = is_pending_tombstone(*pending_entry);
            current_proxy = to_proxy(p->first, *pending_entry, current_is_tombstone);
            found = true;
        }
    }
    if (!found) {
        auto it = entries_.find(std::string(key));
        if (it != entries_.end()) {
            auto at = entry_at_epoch(it->second, kMaxEpoch);
            if (at.found) {
                entries_entry = &it->second;
                current_is_tombstone = at.is_tombstone;
                current_proxy = to_proxy(it->first, at.rev, at.is_tombstone);
                found = true;
            }
        }
    }

    // Conditional put on a missing/tombstoned key fails fast (legacy rule).
    if ((!found || current_is_tombstone) && old_file_id != 0) {
        return PutResult::kAlreadyExists;
    }

    epoch_ += 1;
    const std::uint64_t this_epoch = epoch_;

    // ---- Path 1: key absent or tombstoned ----
    if (!found || current_is_tombstone) {
        // Merge race detection (legacy).
        if ((newest_put && file_id < biggest_file_id_) || old_file_id != 0) {
            return PutResult::kAlreadyExists;
        }

        SingleEntry s{file_id, total_sz, offset, this_epoch, tstamp};

        if (pending_entry != nullptr) {
            // Updating an existing pending tombstone — promote back to live.
            *pending_entry = s;
        } else if (pending_.has_value()) {
            // Frozen, key not found anywhere — insert into pending.
            pending_->insert_or_assign(std::string(key), s);
            pending_updated_ += 1;
        } else if (entries_entry != nullptr) {
            // Existed in entries as a tombstone (sibling chain). Append a new
            // revision marking it live again.
            if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
                multi->revisions.insert(multi->revisions.begin(), s);
            } else {
                // Shouldn't happen — Single can't be a tombstone in our scheme.
                *entries_entry = s;
            }
        } else if (keyfolders_ > 0) {
            // First mutation during a fold — freeze and divert to pending.
            // (Legacy gates this on kh_put_will_resize; we always divert for
            // simplicity — correctness-equivalent, slightly less optimal.)
            pending_.emplace();
            pending_start_epoch_ = this_epoch;
            pending_start_time_  = now_sec;
            pending_updated_     = 0;
            pending_->insert_or_assign(std::string(key), s);
            pending_updated_ += 1;
        } else {
            entries_.insert_or_assign(std::string(key), Entry{s});
        }

        key_count_ += 1;
        key_bytes_ += key.size();
        if (keyfolders_ > 0) iter_mutation_ = true;

        const auto sz_i32 = static_cast<std::int32_t>(total_sz);
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             1, 1, sz_i32, sz_i32, /*should_create*/ true);
        if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
        return PutResult::kOk;
    }

    // ---- Path 2: key currently live ----
    const SingleEntry cur = SingleEntry{
        current_proxy.file_id, current_proxy.total_sz,
        current_proxy.offset, current_proxy.epoch,
        current_proxy.tstamp};

    // Conditional put: must replace the exact (file_id, offset) we expect.
    if (old_file_id != 0 &&
        (newest_put || file_id != cur.file_id) &&
        !(old_file_id == cur.file_id && old_offset == cur.offset)) {
        return PutResult::kAlreadyExists;
    }

    // Staleness check (legacy rules).
    const bool accept =
        (newest_put && file_id >= biggest_file_id_) ||
        (!newest_put && cur.tstamp < tstamp) ||
        (!newest_put && (cur.file_id < file_id ||
                          (cur.file_id == file_id && cur.offset < offset)));

    if (!accept) {
        if (!is_ready_) {
            update_fstats_locked(file_id, tstamp, kMaxEpoch,
                                 0, 1, 0,
                                 static_cast<std::int32_t>(total_sz),
                                 /*should_create*/ true);
        }
        return PutResult::kAlreadyExists;
    }

    // fstats accounting.
    const auto sz_i32     = static_cast<std::int32_t>(total_sz);
    const auto cur_sz_i32 = static_cast<std::int32_t>(cur.total_sz);
    if (cur.file_id != file_id) {
        update_fstats_locked(cur.file_id, /*tstamp*/ 0, kMaxEpoch,
                             -1, 0, -cur_sz_i32, 0, /*should_create*/ false);
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             1, 1, sz_i32, sz_i32, /*should_create*/ true);
    } else {
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             0, 1, sz_i32 - cur_sz_i32, sz_i32,
                             /*should_create*/ true);
    }
    if (keyfolders_ > 0) iter_mutation_ = true;

    SingleEntry next{file_id, total_sz, offset, this_epoch, tstamp};

    if (pending_entry != nullptr) {
        *pending_entry = next;
    } else {
        // entries_entry is non-null here.
        assert(entries_entry != nullptr);
        if (keyfolders_ > 0) {
            // Need to preserve old version for in-flight folds.
            if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
                multi->revisions.insert(multi->revisions.begin(), next);
            } else {
                MultiEntry promoted;
                promoted.revisions.reserve(2);
                promoted.revisions.push_back(next);
                promoted.revisions.push_back(*std::get_if<SingleEntry>(entries_entry));
                *entries_entry = std::move(promoted);
            }
        } else {
            // No folders: replace in place (collapse multi if any).
            *entries_entry = next;
        }
    }

    if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
    return PutResult::kOk;
}

bool KeyDir::remove(std::string_view key, std::uint32_t remove_time) {
    std::unique_lock lock(mutex_);

    epoch_ += 1;
    const std::uint64_t this_epoch = epoch_;

    SingleEntry* pending_entry = nullptr;
    Entry* entries_entry = nullptr;
    SingleEntry cur{};
    bool found = false;

    // Mirror legacy find_keydir_entry: pending always shadows entries. If a
    // key is present in pending — even as a tombstone — entries is NOT
    // consulted. Otherwise stale live revisions left in entries (set during
    // fold-time updates) would be visible to remove() as "live", causing a
    // double-decrement of key_count_.
    if (pending_.has_value()) {
        auto p = pending_->find(std::string(key));
        if (p != pending_->end()) {
            if (is_pending_tombstone(p->second)) {
                return false;  // shadowed by pending tomb
            }
            pending_entry = &p->second;
            cur = p->second;
            found = true;
        }
    }
    if (!found) {
        auto it = entries_.find(std::string(key));
        if (it != entries_.end()) {
            auto at = entry_at_epoch(it->second, kMaxEpoch);
            if (at.found && !at.is_tombstone) {
                entries_entry = &it->second;
                cur = at.rev;
                found = true;
            }
        }
    }
    if (!found) return false;

    update_fstats_locked(cur.file_id, cur.tstamp, kMaxEpoch,
                         -1, 0, -static_cast<std::int32_t>(cur.total_sz), 0,
                         /*should_create*/ false);
    assert(key_count_ > 0 && "remove found a live entry but key_count_ is 0");
    key_count_ -= 1;
    key_bytes_ -= key.size();
    if (keyfolders_ > 0) iter_mutation_ = true;

    if (pending_entry != nullptr) {
        // Convert in-pending live entry to pending tombstone.
        pending_entry->offset = kMaxOffset;
        pending_entry->tstamp = remove_time;
        pending_entry->epoch  = this_epoch;
    } else if (pending_.has_value()) {
        // Frozen; entry only exists in entries — divert tombstone to pending.
        SingleEntry t{cur.file_id, cur.total_sz, kMaxOffset, this_epoch, remove_time};
        pending_->insert_or_assign(std::string(key), t);
        pending_updated_ += 1;
    } else if (keyfolders_ == 0) {
        // No folders: just erase.
        auto it = entries_.find(std::string(key));
        if (it != entries_.end()) entries_.erase(it);
    } else {
        // Folders active, no pending yet — append a sibling tombstone in entries.
        assert(entries_entry != nullptr);
        SingleEntry t = make_sibling_tombstone(this_epoch, remove_time);
        if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
            multi->revisions.insert(multi->revisions.begin(), t);
        } else {
            MultiEntry promoted;
            promoted.revisions.reserve(2);
            promoted.revisions.push_back(t);
            promoted.revisions.push_back(*std::get_if<SingleEntry>(entries_entry));
            *entries_entry = std::move(promoted);
        }
    }
    return true;
}

PutResult KeyDir::conditional_remove(std::string_view key,
                                      std::uint32_t tstamp,
                                      std::uint32_t file_id,
                                      std::uint64_t offset,
                                      std::uint32_t remove_time) {
    {
        // Quick mismatch check before bumping the epoch.
        // Same shadow rule as remove(): pending always shadows entries.
        std::shared_lock lock(mutex_);
        SingleEntry cur{};
        bool found = false;
        if (pending_.has_value()) {
            auto p = pending_->find(std::string(key));
            if (p != pending_->end()) {
                if (is_pending_tombstone(p->second)) {
                    return PutResult::kOk;  // shadowed; not-found is success
                }
                cur = p->second; found = true;
            }
        }
        if (!found) {
            auto it = entries_.find(std::string(key));
            if (it != entries_.end()) {
                auto at = entry_at_epoch(it->second, kMaxEpoch);
                if (at.found && !at.is_tombstone) {
                    cur = at.rev; found = true;
                }
            }
        }
        if (!found) return PutResult::kOk;  // legacy: not-found is success
        if (cur.tstamp != tstamp || cur.file_id != file_id || cur.offset != offset) {
            return PutResult::kAlreadyExists;
        }
    }
    // Match — fall through to the same logic as remove().
    return remove(key, remove_time) ? PutResult::kOk : PutResult::kOk;
}

// =============================================================================
// Iterator (defined in same TU; IterHandle dtor calls release())
// =============================================================================

IterHandle::~IterHandle() noexcept {
    if (iterating_) {
        try { release(); } catch (...) { /* nothrow contract */ }
    }
}

StartIterResult IterHandle::start(std::uint32_t now_sec,
                                   int maxage, int maxputs) {
    if (iterating_) return StartIterResult::kAlreadyIterating;
    std::unique_lock lock(parent_->mutex_);

    auto can_use_existing_freeze = [&]() -> bool {
        if (!parent_->pending_.has_value() || (maxage < 0 && maxputs < 0)) {
            return true;
        }
        if (now_sec == 0 || now_sec < parent_->pending_start_time_) {
            return false;  // clock skew or forced wait
        }
        const std::uint64_t age = now_sec - parent_->pending_start_time_;
        return ((maxage < 0 || age <= static_cast<std::uint64_t>(maxage)) &&
                (maxputs < 0 || parent_->pending_updated_ <=
                                  static_cast<std::uint64_t>(maxputs)));
    };

    if (!can_use_existing_freeze()) {
        return StartIterResult::kOutOfDate;
    }

    parent_->epoch_ += 1;
    iterating_ = true;
    iter_epoch_ = parent_->epoch_;
    parent_->newest_folder_epoch_ = iter_epoch_;
    parent_->keyfolders_ += 1;

    // Snapshot keys. O(n) at start; immune to subsequent rehash. Performance
    // is M5's job — for now correctness wins.
    keys_snapshot_.clear();
    keys_snapshot_.reserve(parent_->entries_.size());
    for (const auto& [k, _] : parent_->entries_) {
        keys_snapshot_.push_back(k);
    }
    cursor_ = 0;
    return StartIterResult::kOk;
}

std::optional<EntryProxy> IterHandle::next(bool include_tombstones) {
    if (!iterating_) return std::nullopt;
    // Reader lock: cursor_ advances inside this handle (per-iter state, not
    // shared) and entries_/pending_ are only read here.
    std::shared_lock lock(parent_->mutex_);

    while (cursor_ < keys_snapshot_.size()) {
        const std::string& k = keys_snapshot_[cursor_++];
        auto it = parent_->entries_.find(k);
        if (it == parent_->entries_.end()) continue;  // erased between snapshots

        auto at = entry_at_epoch(it->second, iter_epoch_);
        if (!at.found) continue;
        if (at.is_tombstone && !include_tombstones) continue;
        return to_proxy(it->first, at.rev, /*tombstone*/ at.is_tombstone);
    }
    return std::nullopt;
}

void IterHandle::release() {
    if (!iterating_) return;
    std::unique_lock lock(parent_->mutex_);
    iterating_ = false;
    iter_epoch_ = kMaxEpoch;
    keys_snapshot_.clear();
    cursor_ = 0;

    parent_->keyfolders_ -= 1;
    if (parent_->keyfolders_ == 0) {
        parent_->merge_pending_and_collapse_locked();
        parent_->iter_generation_ += 1;
        parent_->iter_mutation_ = false;
    }
}

void KeyDir::merge_pending_and_collapse_locked() {
    if (pending_.has_value()) {
        for (auto& [k, p_entry] : *pending_) {
            auto it = entries_.find(k);
            const bool is_tomb = is_pending_tombstone(p_entry);

            if (it == entries_.end()) {
                if (is_tomb) {
                    // Tombstone for a key that never settled in entries; drop.
                } else {
                    entries_.emplace(k, Entry{p_entry});
                }
            } else {
                if (is_tomb) {
                    entries_.erase(it);
                } else {
                    it->second = Entry{p_entry};
                }
            }
        }
        pending_.reset();
        pending_start_epoch_ = 0;
        pending_start_time_  = 0;
        pending_updated_     = 0;
    }

    // Collapse all multi-revision entries to single.
    for (auto it = entries_.begin(); it != entries_.end(); ) {
        if (auto* m = std::get_if<MultiEntry>(&it->second)) {
            // The newest revision wins; drop the chain. If the newest is a
            // sibling tombstone, the entry itself is gone.
            if (m->revisions.empty() || is_sibling_tombstone(m->revisions.front())) {
                it = entries_.erase(it);
                continue;
            }
            // CRITICAL: copy the front revision into a local before assigning
            // back into the variant — the assignment destroys `m` first.
            const SingleEntry winner = m->revisions.front();
            it->second = winner;
        }
        ++it;
    }
}

// =============================================================================
// Housekeeping / introspection
// =============================================================================

void KeyDir::mark_ready() {
    std::unique_lock lock(mutex_);
    is_ready_ = true;
}

bool KeyDir::is_ready() const {
    std::shared_lock lock(mutex_);
    return is_ready_;
}

std::uint32_t KeyDir::biggest_file_id() const {
    std::shared_lock lock(mutex_);
    return biggest_file_id_;
}

std::uint32_t KeyDir::increment_file_id() {
    std::unique_lock lock(mutex_);
    biggest_file_id_ += 1;
    return biggest_file_id_;
}

std::uint32_t KeyDir::increment_file_id_at_least(std::uint32_t conditional_id) {
    std::unique_lock lock(mutex_);
    if (conditional_id > biggest_file_id_) biggest_file_id_ = conditional_id;
    return biggest_file_id_;
}

KeyDirInfo KeyDir::info() const {
    std::shared_lock lock(mutex_);
    KeyDirInfo r;
    r.key_count = key_count_;
    r.key_bytes = key_bytes_;
    r.epoch     = epoch_;
    r.iter_info.iter_generation = iter_generation_;
    r.iter_info.keyfolders      = keyfolders_;
    r.iter_info.frozen          = pending_.has_value();
    r.iter_info.pending_start_epoch =
        pending_.has_value() ? std::optional<std::uint64_t>(pending_start_epoch_)
                               : std::nullopt;
    r.fstats.reserve(fstats_.size());
    for (const auto& [_, f] : fstats_) r.fstats.push_back(f);
    return r;
}

std::shared_ptr<KeyDir> KeyDir::deep_copy() const {
    auto copy = std::make_shared<KeyDir>();
    std::shared_lock lock(mutex_);
    copy->entries_         = entries_;
    copy->pending_         = pending_;
    copy->fstats_          = fstats_;
    copy->key_count_       = key_count_;
    copy->key_bytes_       = key_bytes_;
    copy->epoch_           = epoch_;
    copy->biggest_file_id_ = biggest_file_id_;
    copy->is_ready_        = is_ready_;
    copy->iter_generation_ = iter_generation_;
    copy->keyfolders_      = 0;  // copies do not inherit folders
    copy->newest_folder_epoch_ = 0;
    copy->iter_mutation_   = false;
    copy->pending_start_epoch_ = pending_start_epoch_;
    copy->pending_start_time_  = pending_start_time_;
    copy->pending_updated_     = pending_updated_;
    return copy;
}

}  // namespace bitcask::keydir
