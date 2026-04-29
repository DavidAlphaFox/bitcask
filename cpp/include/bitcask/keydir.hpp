// Bitcask in-memory key directory.
//
// M2.1 scope (this file's current state):
//   - Single-mutex semantics (no shared_mutex sharding yet — that's M5)
//   - Single-revision entries (no sibling chain / pending table — that's M2.2)
//   - put / get / remove with optimistic concurrency hooks
//   - epoch counter + biggest_file_id tracking
//   - fstats per-file statistics (matching legacy update_fstats contract)
//   - deep copy + info snapshot
//
// Public types and method signatures are designed so M2.2 (multi-revision +
// pending) can be added without breaking callers.

#pragma once

#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bitcask::keydir {

// Sentinel values copied from legacy bitcask_nifs.c. Some are interpreted as
// "tombstone" markers in the entry struct and we cannot change them without
// breaking on-disk and in-memory protocol.
inline constexpr std::uint32_t kMaxTime    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxEpoch   = std::numeric_limits<std::uint64_t>::max();
inline constexpr std::uint32_t kMaxSize    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint32_t kMaxFileId  = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxOffset  = std::numeric_limits<std::uint64_t>::max();

// What the keydir hash stores per key. M2.1 is single-revision; M2.2 will
// generalize this into std::variant<Entry, MultiEntry>.
struct Entry {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
};

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

class KeyDir {
public:
    KeyDir() = default;
    ~KeyDir() = default;

    KeyDir(const KeyDir&) = delete;
    KeyDir& operator=(const KeyDir&) = delete;

    // ---- Mutations ----
    // put() implements the legacy keydir_put_int contract:
    //   - new key (or known tombstone): insert and return kOk; or kAlreadyExists
    //     if `old_file_id != 0` (caller wanted CAS) or merge race detected.
    //   - existing key:
    //       * if `old_file_id != 0` and (file_id, offset) doesn't match current,
    //         and we cannot prove it's an in-place rewrite: kAlreadyExists.
    //       * if newer than current per the same staleness rules legacy uses:
    //         update and return kOk.
    //       * else: kAlreadyExists.
    PutResult put(std::string_view key,
                  std::uint32_t file_id, std::uint32_t total_sz,
                  std::uint64_t offset, std::uint32_t tstamp,
                  std::uint32_t now_sec,
                  bool newest_put,
                  std::uint32_t old_file_id, std::uint64_t old_offset);

    // remove() = legacy keydir_remove (3-arg form): unconditional.
    // Returns true if a key was actually removed.
    bool remove(std::string_view key, std::uint32_t remove_time);

    // conditional_remove() = legacy keydir_remove_int (6-arg form): poor-man's
    // CAS. Removes only if (tstamp, file_id, offset) match the current value.
    // Returns kOk on remove or already-not-present, kAlreadyExists on mismatch.
    PutResult conditional_remove(std::string_view key,
                                 std::uint32_t tstamp,
                                 std::uint32_t file_id,
                                 std::uint64_t offset,
                                 std::uint32_t remove_time);

    // ---- Lookups ----
    // Returns the value at the requested epoch; M2.1 only stores the latest
    // version, so passing an older epoch may return std::nullopt where the
    // legacy could return a snapshot. M2.2 fixes this.
    std::optional<EntryProxy> get(std::string_view key,
                                   std::uint64_t epoch = kMaxEpoch) const;

    [[nodiscard]] std::uint64_t get_epoch() const;

    // ---- Housekeeping ----
    void mark_ready();
    [[nodiscard]] bool is_ready() const;

    [[nodiscard]] std::uint32_t biggest_file_id() const;

    // increment_file_id() bumps and returns the new biggest_file_id.
    std::uint32_t increment_file_id();
    // increment_file_id_at_least: advance only if `conditional_id` is greater.
    // Returns the resulting biggest_file_id either way.
    std::uint32_t increment_file_id_at_least(std::uint32_t conditional_id);

    // ---- File stats ----
    void update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                       std::uint64_t expiration_epoch,
                       std::int32_t live_inc, std::int32_t total_inc,
                       std::int32_t live_bytes_inc,
                       std::int32_t total_bytes_inc,
                       bool should_create);
    void set_pending_delete(std::uint32_t file_id);
    // Returns the count of file ids that did NOT exist in fstats.
    std::uint32_t trim_fstats(std::span<const std::uint32_t> file_ids);

    // ---- Snapshot ----
    [[nodiscard]] KeyDirInfo info() const;
    [[nodiscard]] std::shared_ptr<KeyDir> deep_copy() const;

private:
    // All members guarded by mutex_.
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Entry> entries_;
    std::unordered_map<std::uint32_t, FStatsEntry> fstats_;

    std::uint64_t key_count_       = 0;
    std::uint64_t key_bytes_       = 0;
    std::uint64_t epoch_           = 0;
    std::uint32_t biggest_file_id_ = 0;
    bool is_ready_                 = false;

    // M2.2 will introduce: pending_ (separate hash), keyfolders_,
    // iter_mutation_, iter_generation_, sibling chains, pending_awaken queue.
    // Stubs included now so info()'s shape is forward-compatible.
    std::uint64_t iter_generation_ = 0;
    std::uint64_t keyfolders_      = 0;

    void update_fstats_locked(std::uint32_t file_id, std::uint32_t tstamp,
                              std::uint64_t expiration_epoch,
                              std::int32_t live_inc, std::int32_t total_inc,
                              std::int32_t live_bytes_inc,
                              std::int32_t total_bytes_inc,
                              bool should_create);
};

}  // namespace bitcask::keydir
