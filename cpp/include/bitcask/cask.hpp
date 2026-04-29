// Bitcask facade: integrates keydir, data files, hint files, scanner and
// merger into one process-level handle. Built for the coarse-grained NIF
// exposure in M3.4 — one open/close/get/put/delete call instead of the
// 30+ fine-grained `keydir_*_int` / `file_*_int` calls the legacy uses.
//
// Threading: a Cask is owned by a single Erlang process that holds the
// resource ref. Underlying KeyDir may be shared across Casks of the same
// directory (KeyDirRegistry handles refcount). Concurrent writers to the
// same active file are NOT supported by this class — callers must
// serialize writes (the experimental flag uses one process per Cask).

#pragma once

#include <cstdint>
#include <expected>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "bitcask/data_file.hpp"
#include "bitcask/file_lock.hpp"
#include "bitcask/hint_file.hpp"
#include "bitcask/keydir.hpp"
#include "bitcask/keydir_registry.hpp"
#include "bitcask/merge_policy.hpp"
#include "bitcask/merger.hpp"

namespace bitcask {

// --- Configuration -----------------------------------------------------------
struct CaskOptions {
    bool          read_write       = false;
    std::uint64_t max_file_size    = 2ULL * 1024ULL * 1024ULL * 1024ULL;  // 2 GiB
    bool          o_sync           = false;
    bool          require_hint_crc = false;  // legacy default; M5 may flip true
    merge::PolicyOptions policy{};
};

// --- Errors ------------------------------------------------------------------
enum class CaskError {
    kIo,
    kBadCrc,
    kNotFound,            // get on missing key
    kKeyTooLarge,
    kValueTooLarge,
    kAlreadyExists,       // CAS race
    kReadOnly,            // write-op on a read-only cask
    kWriteLocked,         // another writer already holds the lock
    kInvalidOption,
};

struct CaskFault {
    CaskError kind;
    int errnum = 0;
    std::string detail;
};

struct GetResult {
    std::vector<std::byte> value;
    std::uint32_t tstamp;
};

struct StatusInfo {
    std::uint64_t key_count = 0;
    std::uint64_t key_bytes = 0;
    std::uint64_t epoch     = 0;
    std::vector<merge::FileStatus> files;
};

class Cask;

// --- Fold iterator -----------------------------------------------------------
// Walks every live (key, value) snapshot at the time of make_iter().
// Uses KeyDir::IterHandle for snapshot semantics + a lazy data-file fetch
// for each entry's value. Designed to be wrapped one-call-per-step by NIF.
class CaskIter {
public:
    explicit CaskIter(Cask* parent) noexcept : parent_(parent) {}
    ~CaskIter() noexcept;
    CaskIter(const CaskIter&) = delete;
    CaskIter& operator=(const CaskIter&) = delete;

    [[nodiscard]] std::expected<void, CaskFault>
    start(int maxage = -1, int maxputs = -1, std::uint32_t now_sec = 0);

    // Returns the next (key, value) pair, or std::nullopt at end. The
    // returned vectors own their storage.
    struct Entry {
        std::vector<std::byte> key;
        std::vector<std::byte> value;
        std::uint32_t tstamp;
    };
    [[nodiscard]] std::expected<std::optional<Entry>, CaskFault> next();

    void release() noexcept;
    [[nodiscard]] bool is_iterating() const noexcept { return iter_ != nullptr; }

private:
    Cask* parent_;
    std::unique_ptr<keydir::IterHandle> iter_;
};

// --- The Cask ----------------------------------------------------------------
class Cask {
public:
    Cask() = default;
    ~Cask();
    Cask(const Cask&) = delete;
    Cask& operator=(const Cask&) = delete;

    [[nodiscard]] static std::expected<std::unique_ptr<Cask>, CaskFault>
    open(std::string_view dirname, const CaskOptions& opts,
         keydir::KeyDirRegistry* registry = nullptr);

    void close() noexcept;

    [[nodiscard]] std::expected<GetResult, CaskFault>
    get(std::span<const std::byte> key);

    [[nodiscard]] std::expected<void, CaskFault>
    put(std::span<const std::byte> key,
        std::span<const std::byte> value,
        std::uint32_t tstamp = 0);

    [[nodiscard]] std::expected<void, CaskFault>
    remove(std::span<const std::byte> key, std::uint32_t tstamp = 0);

    [[nodiscard]] std::expected<void, CaskFault> sync();

    [[nodiscard]] StatusInfo status();
    [[nodiscard]] bool is_empty_estimate();

    // Returns (true, [files_to_merge]) or (false, {}) — wraps decide().
    struct NeedsMerge {
        bool needs;
        std::vector<std::string> files;
        std::vector<std::string> expired_files;
    };
    [[nodiscard]] NeedsMerge needs_merge(std::uint32_t now_sec = 0);

    // Run a merge on the listed files. If `files.empty()`, runs needs_merge
    // first. Caller is responsible for any external scheduling / locks.
    [[nodiscard]] std::expected<merge::MergeStats, CaskFault>
    merge(std::vector<std::string> files = {}, std::uint32_t now_sec = 0);

    [[nodiscard]] std::unique_ptr<CaskIter> make_iter() {
        return std::make_unique<CaskIter>(this);
    }

    [[nodiscard]] std::string_view dirname() const noexcept { return dirname_; }
    [[nodiscard]] keydir::KeyDir&  keydir()  noexcept { return *keydir_; }
    [[nodiscard]] const CaskOptions& options() const noexcept { return opts_; }

private:
    friend class CaskIter;

    std::string dirname_;
    CaskOptions opts_;

    // Keydir (possibly shared via registry).
    std::shared_ptr<keydir::KeyDir> keydir_;
    keydir::KeyDirRegistry* registry_ = nullptr;
    std::string keydir_name_;

    // Active write file. nullptr if read-only.
    std::unique_ptr<fileops::DataFile> active_data_;
    std::unique_ptr<fileops::HintFile> active_hint_;
    std::uint32_t active_file_id_ = 0;

    // Read-side cache of per-file_id DataFile handles. Opened lazily.
    std::mutex read_cache_mu_;
    std::unordered_map<std::uint32_t,
                        std::unique_ptr<fileops::DataFile>> read_files_;

    // Write lock (if read_write).
    std::optional<lock::FileLock> write_lock_;

    // Helpers.
    [[nodiscard]] std::expected<void, CaskFault> load_keydir_from_disk();
    [[nodiscard]] std::expected<void, CaskFault> ensure_active_writer();
    [[nodiscard]] std::expected<void, CaskFault> roll_active_if_needed(std::size_t about_to_write);
    [[nodiscard]] fileops::DataFile* read_file(std::uint32_t file_id);
};

}  // namespace bitcask
