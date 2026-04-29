// Bitcask in-memory key directory.
//
// M2.1: single-mutex, single-revision basics                    (done)
// M2.2: sibling chain + pending hash + iterator semantics       (this file)
//
// Concurrency model:
//   - M5.3 phase 1: one std::shared_mutex protects everything. Reads
//     (get / get_epoch / info / biggest_file_id / iter::next / deep_copy /
//     conditional_remove peek / is_ready) take std::shared_lock; writes
//     (put / remove / fstats updates / pending freeze / iter start+release)
//     take std::unique_lock. ~1.9× throughput vs std::mutex at 4-reader
//     load, no single-thread cost. Per-key parallelism (bucket sharding)
//     requires breaking pending_/epoch_/fstats_ — deferred to M6.
//   - When `keyfolders > 0`, writes that would touch existing entries get
//     promoted from SingleEntry to MultiEntry (a sibling chain ordered
//     newest-first). New keys go to a separate `pending_` map. Iterators
//     read from `entries_` only and look up the revision at their start
//     epoch, so writes are invisible to in-flight folds.
//   - On the last fold's release, `pending_` is merged back into `entries_`
//     and all multi-revision entries are collapsed to single-revision.

#pragma once

#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

namespace bitcask::keydir {

// Sentinel values mirrored from legacy bitcask_nifs.c.
inline constexpr std::uint32_t kMaxTime    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxEpoch   = std::numeric_limits<std::uint64_t>::max();
inline constexpr std::uint32_t kMaxSize    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint32_t kMaxFileId  = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxOffset  = std::numeric_limits<std::uint64_t>::max();

// One concrete revision of a value's keydir entry.
struct SingleEntry {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
};

// Sibling chain: revisions[0] is newest; chain extends back in time.
// Created when a write hits an existing key during an active fold.
struct MultiEntry {
    std::vector<SingleEntry> revisions;  // newest-first
};

// Stored per-key inside KeyDir's entries_ map.
using Entry = std::variant<SingleEntry, MultiEntry>;

// Exploded view returned by lookups. The legacy code calls this
// bitcask_keydir_entry_proxy.
struct EntryProxy {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
    bool is_tombstone      = false;
    std::string_view key;  // borrows from KeyDir storage; valid while lock held
};

struct FStatsEntry {
    std::uint32_t file_id          = 0;
    std::uint64_t live_keys        = 0;
    std::uint64_t total_keys       = 0;
    std::uint64_t live_bytes       = 0;
    std::uint64_t total_bytes      = 0;
    std::uint32_t oldest_tstamp    = 0;
    std::uint32_t newest_tstamp    = 0;
    std::uint64_t expiration_epoch = kMaxEpoch;
};

enum class PutResult { kOk, kAlreadyExists };

enum class StartIterResult {
    kOk,                  // iteration started; caller must release()
    kAlreadyIterating,    // this handle already iterating
    kOutOfDate,           // pending too stale; caller may retry / wait
};

struct IterInfo {
    std::uint64_t iter_generation = 0;
    std::uint64_t keyfolders      = 0;
    bool frozen                   = false;
    std::optional<std::uint64_t> pending_start_epoch;
};

struct KeyDirInfo {
    std::uint64_t key_count = 0;
    std::uint64_t key_bytes = 0;
    std::uint64_t epoch     = 0;
    IterInfo iter_info;
    std::vector<FStatsEntry> fstats;
};

class KeyDir;

// Per-process iteration handle.
//
// One KeyDir may have many handles at once (concurrent folds). Each handle
// snapshots the keydir at start_iter time via the saved `iter_epoch_`. The
// handle holds a non-owning pointer to the parent KeyDir.
class IterHandle {
public:
    explicit IterHandle(KeyDir* parent) noexcept : parent_(parent) {}
    ~IterHandle() noexcept;

    IterHandle(const IterHandle&) = delete;
    IterHandle& operator=(const IterHandle&) = delete;
    IterHandle(IterHandle&&) = delete;
    IterHandle& operator=(IterHandle&&) = delete;

    // Begin iteration. `now_sec` is the current wall-clock time used for the
    // freshness check; `maxage` is the max allowed age of a frozen pending
    // table in seconds; `maxputs` is the max allowed updates since freeze.
    // Negative values disable the respective limit.
    StartIterResult start(std::uint32_t now_sec, int maxage, int maxputs);

    // Returns the next entry (skipping tombstones and not-yet-existing keys
    // at this handle's epoch). std::nullopt at end of iteration.
    std::optional<EntryProxy> next();

    // Releases iteration; idempotent. If this was the last folder, the parent
    // merges its pending table back into entries_.
    void release();

    [[nodiscard]] bool is_iterating() const noexcept { return iterating_; }
    [[nodiscard]] std::uint64_t epoch() const noexcept { return iter_epoch_; }

private:
    friend class KeyDir;
    KeyDir* parent_;
    bool iterating_           = false;
    std::uint64_t iter_epoch_ = kMaxEpoch;

    // Iteration position is a key (string copy). Less efficient than legacy's
    // bucket index but immune to rehash, which simplifies reasoning. The
    // alternative — pinning unordered_map iterators — requires careful
    // load-factor management that is M5's job.
    std::vector<std::string> keys_snapshot_;
    std::size_t cursor_ = 0;
};

class KeyDir {
public:
    KeyDir() = default;
    ~KeyDir() = default;

    KeyDir(const KeyDir&) = delete;
    KeyDir& operator=(const KeyDir&) = delete;

    // ---- Mutations ----
    PutResult put(std::string_view key,
                  std::uint32_t file_id, std::uint32_t total_sz,
                  std::uint64_t offset, std::uint32_t tstamp,
                  std::uint32_t now_sec,
                  bool newest_put,
                  std::uint32_t old_file_id, std::uint64_t old_offset);

    bool remove(std::string_view key, std::uint32_t remove_time);

    PutResult conditional_remove(std::string_view key,
                                 std::uint32_t tstamp,
                                 std::uint32_t file_id,
                                 std::uint64_t offset,
                                 std::uint32_t remove_time);

    // ---- Lookups ----
    std::optional<EntryProxy> get(std::string_view key,
                                   std::uint64_t epoch = kMaxEpoch) const;

    [[nodiscard]] std::uint64_t get_epoch() const;

    // ---- Iterator factory ----
    [[nodiscard]] std::unique_ptr<IterHandle> make_iter() {
        return std::make_unique<IterHandle>(this);
    }

    // ---- Housekeeping ----
    void mark_ready();
    [[nodiscard]] bool is_ready() const;

    [[nodiscard]] std::uint32_t biggest_file_id() const;
    std::uint32_t increment_file_id();
    std::uint32_t increment_file_id_at_least(std::uint32_t conditional_id);

    // ---- File stats ----
    void update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                       std::uint64_t expiration_epoch,
                       std::int32_t live_inc, std::int32_t total_inc,
                       std::int32_t live_bytes_inc,
                       std::int32_t total_bytes_inc,
                       bool should_create);
    void set_pending_delete(std::uint32_t file_id);
    std::uint32_t trim_fstats(std::span<const std::uint32_t> file_ids);

    // ---- Snapshot ----
    [[nodiscard]] KeyDirInfo info() const;
    [[nodiscard]] std::shared_ptr<KeyDir> deep_copy() const;

private:
    friend class IterHandle;

    // M5.3 phase 1: shared_mutex lets concurrent readers run get/info/iter::next
    // in parallel. Writes (put / remove / fstats updates / pending freeze)
    // still serialize on a unique_lock. Bucket sharding (phase 2) requires
    // breaking up epoch_/pending_/fstats_ — deferred to M6.
    mutable std::shared_mutex mutex_;

    // Main hash. Values are variants — use std::get_if when introspecting.
    std::unordered_map<std::string, Entry> entries_;

    // Active during folds when the resize-or-clobber rule kicks in. New keys
    // and tombstones-of-not-in-entries land here. Merged back at last release.
    std::optional<std::unordered_map<std::string, SingleEntry>> pending_;
    std::uint64_t pending_start_epoch_ = 0;
    std::uint64_t pending_start_time_  = 0;
    std::uint64_t pending_updated_     = 0;

    std::unordered_map<std::uint32_t, FStatsEntry> fstats_;

    std::uint64_t key_count_       = 0;
    std::uint64_t key_bytes_       = 0;
    std::uint64_t epoch_           = 0;
    std::uint32_t biggest_file_id_ = 0;
    bool is_ready_                 = false;

    // Iterator coordination.
    std::uint64_t keyfolders_         = 0;
    std::uint64_t iter_generation_    = 0;
    std::uint64_t newest_folder_epoch_ = 0;
    bool iter_mutation_               = false;

    // Helpers expecting the lock held.
    void update_fstats_locked(std::uint32_t file_id, std::uint32_t tstamp,
                              std::uint64_t expiration_epoch,
                              std::int32_t live_inc, std::int32_t total_inc,
                              std::int32_t live_bytes_inc,
                              std::int32_t total_bytes_inc,
                              bool should_create);

    // Merge pending hash into entries and collapse sibling chains.
    // Caller must hold mutex_ AND have keyfolders_ == 0.
    void merge_pending_and_collapse_locked();

    // Returns true if `target_epoch` has a visible non-tombstone entry; fills
    // `out`. Caller holds mutex_.
    bool find_at_epoch_locked(std::string_view key, std::uint64_t target_epoch,
                              EntryProxy& out, bool& out_is_tombstone) const;

    // True if any folder is currently pinned at an epoch <= e.
    [[nodiscard]] bool fold_pinned_at_or_below_locked(std::uint64_t /*e*/) const noexcept {
        // Conservative: if any folder active, pin everything. Tighten in M5.
        return keyfolders_ > 0;
    }
};

}  // namespace bitcask::keydir
