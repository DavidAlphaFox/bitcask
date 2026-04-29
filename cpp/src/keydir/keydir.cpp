#include "bitcask/keydir.hpp"

#include <algorithm>

namespace bitcask::keydir {

namespace {

// Legacy "pending tombstone" sentinel: an entry with offset == kMaxOffset
// inside the pending hash is treated as a delete. M2.1 has no pending hash,
// so the only place this matters is in conditional_remove's "look like a
// tombstone" detection.
[[nodiscard]] bool entry_is_tombstone(const Entry& e) noexcept {
    return e.offset == kMaxOffset;
}

[[nodiscard]] EntryProxy entry_to_proxy(const std::string& key,
                                         const Entry& e) noexcept {
    return EntryProxy{
        .file_id      = e.file_id,
        .total_sz     = e.total_sz,
        .offset       = e.offset,
        .epoch        = e.epoch,
        .tstamp       = e.tstamp,
        .is_tombstone = entry_is_tombstone(e),
        .key          = key,
    };
}

}  // namespace

// ---------------------------------------------------------------------------
// fstats
// ---------------------------------------------------------------------------

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
    // Increments are signed and may underflow uint64. Legacy uses uint64
    // arithmetic and accepts wraparound, so we do the same — Erlang side never
    // requests a negative net.
    f.live_keys   = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.live_keys) + live_inc);
    f.total_keys  = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.total_keys) + total_inc);
    f.live_bytes  = static_cast<std::uint64_t>(
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
    std::scoped_lock lock(mutex_);
    update_fstats_locked(file_id, tstamp, expiration_epoch,
                         live_inc, total_inc, live_bytes_inc, total_bytes_inc,
                         should_create);
}

void KeyDir::set_pending_delete(std::uint32_t file_id) {
    std::scoped_lock lock(mutex_);
    // Legacy: update_fstats(env, kd, file_id, 0, kd->epoch, 0,0,0,0, 0)
    update_fstats_locked(file_id, /*tstamp*/ 0,
                         /*expiration_epoch*/ epoch_,
                         0, 0, 0, 0, /*should_create*/ false);
}

std::uint32_t KeyDir::trim_fstats(std::span<const std::uint32_t> ids) {
    std::scoped_lock lock(mutex_);
    std::uint32_t missing = 0;
    for (auto id : ids) {
        if (fstats_.erase(id) == 0) ++missing;
    }
    return missing;
}

// ---------------------------------------------------------------------------
// put / get / remove
// ---------------------------------------------------------------------------

PutResult KeyDir::put(std::string_view key,
                       std::uint32_t file_id, std::uint32_t total_sz,
                       std::uint64_t offset, std::uint32_t tstamp,
                       std::uint32_t /*now_sec*/,
                       bool newest_put,
                       std::uint32_t old_file_id, std::uint64_t old_offset) {
    std::scoped_lock lock(mutex_);

    auto it = entries_.find(std::string(key));
    const bool found = (it != entries_.end()) && !entry_is_tombstone(it->second);

    // Conditional put on a missing/tombstoned key fails fast.
    if (!found && old_file_id != 0) {
        return PutResult::kAlreadyExists;
    }

    epoch_ += 1;
    const std::uint64_t this_epoch = epoch_;

    if (!found) {
        // Merge race detection (matches legacy):
        //   newest_put && file_id < biggest_file_id  -> the writer raced a merge
        //   old_file_id != 0                          -> caller meant to CAS but key vanished
        if ((newest_put && file_id < biggest_file_id_) || old_file_id != 0) {
            return PutResult::kAlreadyExists;
        }

        Entry e{
            .file_id  = file_id,
            .total_sz = total_sz,
            .offset   = offset,
            .epoch    = this_epoch,
            .tstamp   = tstamp,
        };
        entries_.insert_or_assign(std::string(key), e);
        key_count_ += 1;
        key_bytes_ += key.size();
        const auto sz_i32 = static_cast<std::int32_t>(total_sz);
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             /*live*/ 1, /*total*/ 1,
                             sz_i32, sz_i32, /*should_create*/ true);
        if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
        return PutResult::kOk;
    }

    // Found — the key currently has a non-tombstone entry.
    const Entry cur = it->second;

    // Conditional put: must replace the exact (file_id, offset) we expect.
    // The legacy carve-out for in-place merge rewrites is preserved verbatim.
    if (old_file_id != 0 &&
        (newest_put || file_id != cur.file_id) &&
        !(old_file_id == cur.file_id && old_offset == cur.offset)) {
        return PutResult::kAlreadyExists;
    }

    // Staleness check — only update if the new value is newer per legacy rules.
    const bool accept =
        (newest_put && file_id >= biggest_file_id_) ||
        (!newest_put && cur.tstamp < tstamp) ||
        (!newest_put && (cur.file_id < file_id ||
                          (cur.file_id == file_id && cur.offset < offset)));

    if (!accept) {
        // Even when rejecting, legacy bumps total stats while not ready.
        if (!is_ready_) {
            update_fstats_locked(file_id, tstamp, kMaxEpoch,
                                 0, 1, 0,
                                 static_cast<std::int32_t>(total_sz),
                                 /*should_create*/ true);
        }
        return PutResult::kAlreadyExists;
    }

    // fstats: subtract from old file, add to new (or merge if same file).
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

    Entry next{
        .file_id  = file_id,
        .total_sz = total_sz,
        .offset   = offset,
        .epoch    = this_epoch,
        .tstamp   = tstamp,
    };
    it->second = next;
    if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
    return PutResult::kOk;
}

std::optional<EntryProxy> KeyDir::get(std::string_view key,
                                       std::uint64_t epoch) const {
    std::scoped_lock lock(mutex_);
    auto it = entries_.find(std::string(key));
    if (it == entries_.end()) return std::nullopt;
    if (entry_is_tombstone(it->second)) return std::nullopt;
    if (epoch < it->second.epoch) return std::nullopt;  // M2.2 will return snapshot
    return entry_to_proxy(it->first, it->second);
}

std::uint64_t KeyDir::get_epoch() const {
    std::scoped_lock lock(mutex_);
    return epoch_;
}

bool KeyDir::remove(std::string_view key, std::uint32_t /*remove_time*/) {
    std::scoped_lock lock(mutex_);
    epoch_ += 1;
    auto it = entries_.find(std::string(key));
    if (it == entries_.end() || entry_is_tombstone(it->second)) {
        return false;
    }
    const Entry e = it->second;
    update_fstats_locked(e.file_id, e.tstamp, kMaxEpoch,
                         -1, 0, -static_cast<std::int32_t>(e.total_sz), 0,
                         /*should_create*/ false);
    key_count_ -= 1;
    key_bytes_ -= it->first.size();
    entries_.erase(it);
    return true;
}

PutResult KeyDir::conditional_remove(std::string_view key,
                                      std::uint32_t tstamp,
                                      std::uint32_t file_id,
                                      std::uint64_t offset,
                                      std::uint32_t /*remove_time*/) {
    std::scoped_lock lock(mutex_);
    epoch_ += 1;
    auto it = entries_.find(std::string(key));
    if (it == entries_.end() || entry_is_tombstone(it->second)) {
        return PutResult::kOk;  // legacy: not-found is success
    }
    const Entry& cur = it->second;
    if (cur.tstamp != tstamp || cur.file_id != file_id || cur.offset != offset) {
        return PutResult::kAlreadyExists;
    }
    update_fstats_locked(cur.file_id, cur.tstamp, kMaxEpoch,
                         -1, 0, -static_cast<std::int32_t>(cur.total_sz), 0,
                         /*should_create*/ false);
    key_count_ -= 1;
    key_bytes_ -= it->first.size();
    entries_.erase(it);
    return PutResult::kOk;
}

// ---------------------------------------------------------------------------
// Housekeeping / introspection
// ---------------------------------------------------------------------------

void KeyDir::mark_ready() {
    std::scoped_lock lock(mutex_);
    is_ready_ = true;
}

bool KeyDir::is_ready() const {
    std::scoped_lock lock(mutex_);
    return is_ready_;
}

std::uint32_t KeyDir::biggest_file_id() const {
    std::scoped_lock lock(mutex_);
    return biggest_file_id_;
}

std::uint32_t KeyDir::increment_file_id() {
    std::scoped_lock lock(mutex_);
    biggest_file_id_ += 1;
    return biggest_file_id_;
}

std::uint32_t KeyDir::increment_file_id_at_least(std::uint32_t conditional_id) {
    std::scoped_lock lock(mutex_);
    if (conditional_id > biggest_file_id_) biggest_file_id_ = conditional_id;
    return biggest_file_id_;
}

KeyDirInfo KeyDir::info() const {
    std::scoped_lock lock(mutex_);
    KeyDirInfo r;
    r.key_count = key_count_;
    r.key_bytes = key_bytes_;
    r.epoch     = epoch_;
    r.iter_info.iter_generation     = iter_generation_;
    r.iter_info.keyfolders          = keyfolders_;
    r.iter_info.frozen              = false;  // M2.1: never frozen
    r.iter_info.pending_start_epoch = std::nullopt;
    r.fstats.reserve(fstats_.size());
    for (const auto& [_, f] : fstats_) r.fstats.push_back(f);
    return r;
}

std::shared_ptr<KeyDir> KeyDir::deep_copy() const {
    auto copy = std::make_shared<KeyDir>();
    std::scoped_lock lock(mutex_);
    // No need to lock copy — nobody else has it yet.
    copy->entries_         = entries_;
    copy->fstats_          = fstats_;
    copy->key_count_       = key_count_;
    copy->key_bytes_       = key_bytes_;
    copy->epoch_           = epoch_;
    copy->biggest_file_id_ = biggest_file_id_;
    copy->is_ready_        = is_ready_;
    copy->iter_generation_ = iter_generation_;
    copy->keyfolders_      = 0;  // copy is private; no folds carried over
    return copy;
}

}  // namespace bitcask::keydir
