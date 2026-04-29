// Process-global registry of named KeyDir instances.
//
// Mirrors the legacy `bitcask_priv_data.global_keydirs` + `global_biggest_file_id`
// pair. Multiple acquirers of the same name share the underlying KeyDir via
// refcount; on full release the registry persists `biggest_file_id + 1` so a
// later re-acquire never reuses an old file id.
//
// Initialization protocol:
//   - First acquirer of a name receives status = kCreated and a fresh KeyDir
//     with is_ready() == false. They MUST call kd->mark_ready() once the
//     keydir is populated (typically after scanning data files at open time).
//   - Subsequent acquirers while is_ready() == false receive status = kNotReady
//     and a null pointer (legacy behaviour: they retry / wait).
//   - Once mark_ready() has run, subsequent acquirers receive status = kReady
//     and a shared pointer with the refcount bumped.

#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

#include "bitcask/keydir.hpp"

namespace bitcask::keydir {

enum class AcquireStatus {
    kCreated,    // fresh; caller is initialiser; must mark_ready() when done
    kReady,      // existed and ready; refcount incremented
    kNotReady,   // existed but not yet ready; caller should retry / wait
};

struct AcquireResult {
    AcquireStatus status;
    std::shared_ptr<KeyDir> keydir;  // null when status == kNotReady
};

class KeyDirRegistry {
public:
    KeyDirRegistry() = default;
    ~KeyDirRegistry() = default;

    KeyDirRegistry(const KeyDirRegistry&) = delete;
    KeyDirRegistry& operator=(const KeyDirRegistry&) = delete;

    // Get-or-create a named KeyDir.
    [[nodiscard]] AcquireResult acquire(std::string_view name);

    // Query without creating: returns kReady or kNotReady (the latter when
    // either the name does not exist OR exists but is not ready).
    [[nodiscard]] AcquireResult query(std::string_view name) const;

    // Release a previously-acquired keydir. Decrements refcount; if zero,
    // the entry is removed from the registry and `biggest_file_id + 1` is
    // saved so that a future acquirer of the same name starts at >= that id.
    // `name` must match the name used at acquire time.
    void release(std::string_view name);

    // Test / introspection helpers.
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] std::optional<std::uint32_t>
    saved_biggest_file_id(std::string_view name) const;

private:
    struct Slot {
        std::shared_ptr<KeyDir> keydir;
        std::uint32_t refcount = 0;
    };
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Slot> entries_;
    std::unordered_map<std::string, std::uint32_t> saved_biggest_file_id_;
};

}  // namespace bitcask::keydir
