#include "bitcask/cask.hpp"

#include <signal.h>     // ::kill for stale-lock detection
#include <unistd.h>     // ::getpid, ::unlink

#include <chrono>
#include <cstring>
#include <filesystem>
#include <thread>

#include "bitcask/format.hpp"
#include "bitcask/merger.hpp"
#include "bitcask/scanner.hpp"

namespace bitcask {

namespace {
namespace fs = std::filesystem;

CaskFault io_fault(int errnum, std::string detail = {}) {
    return CaskFault{CaskError::kIo, errnum, std::move(detail)};
}
CaskFault err(CaskError k, std::string detail = {}) {
    return CaskFault{k, 0, std::move(detail)};
}

std::uint32_t now_sec_default() {
    return static_cast<std::uint32_t>(
        std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch()).count());
}

std::span<const std::byte> str_to_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

std::string_view bytes_to_view(std::span<const std::byte> b) {
    return {reinterpret_cast<const char*>(b.data()), b.size()};
}

// Returns true iff the OS process `pid` is still running. Mirrors legacy
// bitcask_lockops:os_pid_exists/1, which uses `kill -0 <pid>`. We do the
// equivalent via kill(pid, 0): returns 0 if the signal could be delivered;
// -1 + ESRCH if the process is gone; -1 + EPERM if it exists but we
// cannot signal (treated as "alive" — conservative).
[[nodiscard]] bool process_alive(int pid) noexcept {
    if (pid <= 0) return false;
    if (::kill(pid, 0) == 0) return true;
    return errno != ESRCH;
}

// Lock-file payload format (legacy + ours):
//   "<pid> <active_data_file_path>\n"
//   or just "<pid>\n" if the active path hasn't been recorded yet.
// We extract the active file's tstamp/file_id from the path's basename,
// using fileops::parse_data_tstamp. Returns 0 if no path is present or
// it cannot be parsed.
[[nodiscard]] std::uint32_t
parse_active_file_id_from_lock(std::span<const std::byte> bytes) noexcept {
    // Skip leading PID digits.
    std::size_t i = 0;
    while (i < bytes.size() && static_cast<char>(bytes[i]) >= '0' &&
                                static_cast<char>(bytes[i]) <= '9') {
        ++i;
    }
    if (i == bytes.size() || static_cast<char>(bytes[i]) != ' ') return 0;
    ++i;  // skip the space

    // Take the rest up to newline as the path.
    std::size_t end = i;
    while (end < bytes.size() && static_cast<char>(bytes[end]) != '\n') ++end;
    std::string path(reinterpret_cast<const char*>(bytes.data() + i), end - i);
    if (path.empty()) return 0;

    auto t = fileops::parse_data_tstamp(path);
    if (!t) return 0;
    return static_cast<std::uint32_t>(*t);
}

// Parse the leading positive integer from `bytes` (the lock-file payload
// is "<pid> <activefile>\n" — we only care about the pid).
[[nodiscard]] int parse_leading_pid(std::span<const std::byte> bytes) noexcept {
    int pid = 0;
    bool any_digit = false;
    for (auto byte : bytes) {
        char c = static_cast<char>(byte);
        if (c >= '0' && c <= '9') {
            pid = pid * 10 + (c - '0');
            any_digit = true;
            if (pid > (1 << 30)) return -1;  // overflow guard
        } else {
            break;
        }
    }
    return any_digit ? pid : -1;
}

// Try to remove an existing lock file if its recorded PID is no longer
// alive. Returns true iff we successfully unlinked it (caller may then
// retry the O_EXCL acquire). Mirrors legacy bitcask_lockops:delete_stale_lock.
//
// Race window: between us reading the PID and us unlinking, another
// process could have written a fresh lock — we'd then incorrectly remove
// theirs. Legacy carries the same race; the practical exposure is tiny
// (post-crash recovery only).
[[nodiscard]] bool try_remove_stale_lock(const std::string& path) noexcept {
    auto rl = lock::FileLock::acquire(path, /*write*/ false);
    if (!rl) return false;  // file vanished or unreadable; the retry will surface the right error

    auto data = rl->read_data();
    bool dead = false;
    if (data) {
        const int pid = parse_leading_pid(
            std::span<const std::byte>(data->data(), data->size()));
        // pid == -1 means "no parseable PID" (e.g. legacy hadn't written
        // it yet, or the writer crashed mid-write). Treat as stale.
        if (pid == -1 || !process_alive(pid)) {
            dead = true;
        }
    } else {
        dead = true;  // can't read content; treat as stale
    }
    rl->release_quiet();  // closes fd; read locks don't unlink
    if (!dead) return false;
    return ::unlink(path.c_str()) == 0;
}

// Acquire bitcask.write.lock with stale-lock reclaim. Writes the bare PID
// line; the active-file path is appended later by ensure_active_writer
// once the file id is known. Used by both Cask::open and the
// close_write_file → next-put reacquire path.
[[nodiscard]] std::expected<lock::FileLock, CaskFault>
acquire_writer_lock(const std::string& dirname) {
    const auto lock_path = (fs::path(dirname) / "bitcask.write.lock").string();
    auto fl = lock::FileLock::acquire(lock_path, /*write*/ true);
    if (!fl && fl.error().errnum == EEXIST) {
        if (try_remove_stale_lock(lock_path)) {
            fl = lock::FileLock::acquire(lock_path, /*write*/ true);
        }
    }
    if (!fl) {
        if (fl.error().errnum == EEXIST) {
            return std::unexpected(err(CaskError::kWriteLocked, lock_path));
        }
        return std::unexpected(io_fault(fl.error().errnum, lock_path));
    }
    const std::string pid_line = std::to_string(::getpid()) + "\n";
    auto pid_bytes = std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(pid_line.data()),
        pid_line.size());
    (void)fl->write_data(pid_bytes);
    return std::move(*fl);
}

}  // namespace

// =============================================================================
// CaskIter
// =============================================================================

CaskIter::~CaskIter() noexcept { release(); }

std::expected<keydir::StartIterResult, CaskFault>
CaskIter::start(int maxage, int maxputs, std::uint32_t now_sec,
                bool see_tombstones) {
    if (iter_ && iter_->is_iterating()) {
        return std::unexpected(err(CaskError::kIo, "iter already started"));
    }
    iter_ = parent_->keydir_->make_iter();
    auto r = iter_->start(now_sec, maxage, maxputs);
    see_tombstones_ = see_tombstones;
    return r;  // kOk or kOutOfDate (kAlreadyIterating handled above)
}

std::expected<std::optional<CaskIter::Entry>, CaskFault> CaskIter::next() {
    if (!iter_ || !iter_->is_iterating()) return std::optional<Entry>{};

    const auto expiry = parent_->opts_.expiry_secs;
    const auto now = (expiry > 0) ? now_sec_default() : 0;

    // Skip expired entries. Tombstone behaviour depends on see_tombstones_:
    //   false (default) — skip tombstones entirely (legacy fold/3 behaviour)
    //   true  — surface them with is_tombstone=true; sibling tombstones
    //           don't have a real on-disk record so we synthesize a v0
    //           marker value so callers always see a non-empty value.
    while (true) {
        auto proxy = iter_->next(/*include_tombstones=*/ see_tombstones_);
        if (!proxy) return std::optional<Entry>{};

        if (expiry > 0 && proxy->tstamp + expiry <= now) {
            continue;  // expired; skip
        }

        // Sibling tombstones live entirely in the keydir (file_id sentinel,
        // no real record on disk). Skip the file read and synthesize.
        if (proxy->is_tombstone) {
            Entry e;
            e.key.assign(reinterpret_cast<const std::byte*>(proxy->key.data()),
                          reinterpret_cast<const std::byte*>(proxy->key.data()) +
                          proxy->key.size());
            const auto& tomb = bitcask::format::kTombstoneV0;
            e.value.assign(reinterpret_cast<const std::byte*>(tomb.data()),
                            reinterpret_cast<const std::byte*>(tomb.data()) +
                            tomb.size());
            e.tstamp       = proxy->tstamp;
            e.file_id      = proxy->file_id;
            e.offset       = proxy->offset;
            e.total_sz     = proxy->total_sz;
            e.is_tombstone = true;
            return std::optional<Entry>{std::move(e)};
        }

        auto* df = parent_->read_file(proxy->file_id);
        if (!df) {
            return std::unexpected(err(CaskError::kIo,
                "open read file_id=" + std::to_string(proxy->file_id)));
        }
        auto rec = df->read(proxy->offset, proxy->total_sz);
        if (!rec) {
            switch (rec.error().kind) {
                case fileops::DataFileError::kBadCrc:
                    return std::unexpected(err(CaskError::kBadCrc));
                case fileops::DataFileError::kIo:
                    return std::unexpected(io_fault(rec.error().errnum));
                default:
                    return std::unexpected(err(CaskError::kIo, "read"));
            }
        }
        // The on-disk record may itself encode a tombstone (key removed
        // since this iter's snapshot was taken AND we're at fold epoch
        // before the remove — or the record was already a tombstone in
        // the file the keydir points at).
        const bool value_is_tomb = bitcask::format::is_tombstone_value(
            std::string_view(reinterpret_cast<const char*>(rec->value.data()),
                              rec->value.size()));
        if (value_is_tomb && !see_tombstones_) continue;

        Entry e;
        e.key          = std::move(rec->key);
        e.value        = std::move(rec->value);
        e.tstamp       = rec->tstamp;
        e.file_id      = proxy->file_id;
        e.offset       = proxy->offset;
        e.total_sz     = proxy->total_sz;
        e.is_tombstone = value_is_tomb;
        return std::optional<Entry>{std::move(e)};
    }
}

void CaskIter::release() noexcept {
    if (iter_) {
        iter_->release();
        iter_.reset();
    }
}

// =============================================================================
// Cask
// =============================================================================

Cask::~Cask() { close(); }

std::expected<std::unique_ptr<Cask>, CaskFault>
Cask::open(std::string_view dirname, const CaskOptions& opts,
            keydir::KeyDirRegistry* registry) {
    auto cask = std::make_unique<Cask>();
    cask->dirname_ = std::string(dirname);
    cask->opts_    = opts;

    // Create directory if it doesn't exist.
    std::error_code ec;
    fs::create_directories(cask->dirname_, ec);

    // Lock acquisition: writer takes bitcask.write.lock; merger takes
    // bitcask.merge.lock. Stale-lock detection (post-crash recovery) runs
    // for both. Merger additionally reads write.lock (if any) to learn the
    // live writer's active file id for needs_merge filtering.
    if (opts.read_write && !opts.merge_only) {
        // Plain writer: bitcask.write.lock with PID line + stale reclaim.
        auto fl = acquire_writer_lock(cask->dirname_);
        if (!fl) return std::unexpected(fl.error());
        cask->write_lock_ = std::move(*fl);
    } else if (opts.merge_only) {
        // Merger: bitcask.merge.lock (separate file from write.lock so the
        // live writer can keep running). Same stale-reclaim policy.
        const auto lock_path =
            (fs::path(cask->dirname_) / "bitcask.merge.lock").string();
        auto fl = lock::FileLock::acquire(lock_path, /*write*/ true);
        if (!fl && fl.error().errnum == EEXIST) {
            if (try_remove_stale_lock(lock_path)) {
                fl = lock::FileLock::acquire(lock_path, /*write*/ true);
            }
        }
        if (!fl) {
            if (fl.error().errnum == EEXIST) {
                return std::unexpected(err(CaskError::kWriteLocked, lock_path));
            }
            return std::unexpected(io_fault(fl.error().errnum, lock_path));
        }
        const std::string pid_line = std::to_string(::getpid()) + "\n";
        auto pid_bytes = std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(pid_line.data()),
            pid_line.size());
        (void)fl->write_data(pid_bytes);
        cask->write_lock_ = std::move(*fl);

        // For merger: snapshot the live writer's active file id from
        // write.lock so needs_merge can exclude it. Race window: writer
        // may roll over between us reading and merger picking files; that
        // race exists in legacy too (bitcask_lockops:read_activefile),
        // and the consequence is at most a missed merge of one freshly-
        // rolled file (next round picks it up).
        if (opts.merge_only) {
            const auto wlock_path =
                (fs::path(cask->dirname_) / "bitcask.write.lock").string();
            auto wl = lock::FileLock::acquire(wlock_path, /*write*/ false);
            if (wl) {
                if (auto data = wl->read_data()) {
                    cask->merger_writer_active_id_ =
                        parse_active_file_id_from_lock(
                            std::span<const std::byte>(data->data(), data->size()));
                }
                wl->release_quiet();
            }
            // If write.lock doesn't exist or can't be parsed, no active
            // writer is detected (id stays 0).
        }
    }

    // Acquire / build the keydir.
    if (registry != nullptr) {
        cask->registry_    = registry;
        cask->keydir_name_ = std::string(dirname);
        auto a = registry->acquire(cask->keydir_name_);
        if (a.status == keydir::AcquireStatus::kNotReady) {
            // Wait briefly for the originator to mark_ready.
            for (int i = 0; i < 40; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                a = registry->acquire(cask->keydir_name_);
                if (a.status != keydir::AcquireStatus::kNotReady) break;
            }
            if (a.status == keydir::AcquireStatus::kNotReady) {
                return std::unexpected(err(CaskError::kIo,
                    "keydir not_ready after wait"));
            }
        }
        cask->keydir_ = a.keydir;
        if (a.status == keydir::AcquireStatus::kCreated) {
            if (auto r = cask->load_keydir_from_disk(); !r) return std::unexpected(r.error());
            cask->keydir_->mark_ready();
        }
    } else {
        cask->keydir_ = std::make_shared<keydir::KeyDir>();
        if (auto r = cask->load_keydir_from_disk(); !r) return std::unexpected(r.error());
        cask->keydir_->mark_ready();
    }
    return cask;
}

void Cask::close() noexcept {
    // Finalize active writers.
    if (active_hint_) {
        (void)active_hint_->finalize();
        active_hint_.reset();
    }
    if (active_data_) {
        active_data_.reset();
    }
    {
        std::scoped_lock lk(read_cache_mu_);
        read_files_.clear();
    }
    if (registry_ && !keydir_name_.empty()) {
        registry_->release(keydir_name_);
        registry_ = nullptr;
        keydir_name_.clear();
    }
    keydir_.reset();
    if (write_lock_) {
        write_lock_->release_quiet();
        write_lock_.reset();
    }
}

// ---- Keydir build at open ---------------------------------------------------
std::expected<void, CaskFault> Cask::load_keydir_from_disk() {
    auto entries = fileops::scan_dir(dirname_);
    if (!entries) return std::unexpected(io_fault(entries.error().errnum, dirname_));

    for (const auto& e : *entries) {
        // Determine biggest_file_id seed.
        keydir_->increment_file_id_at_least(static_cast<std::uint32_t>(e.tstamp));

        // Prefer the hint file when present and CRC-valid.
        bool used_hint = false;
        if (e.has_hint) {
            auto hf = fileops::HintFile::open(e.hint_path,
                                                fileops::HintFile::Mode::kRead);
            if (hf) {
                auto v = hf->validate_trailer();
                if (v && *v) {
                    auto fr = hf->fold([&](const auto& rec) {
                        if (rec.tombstone) {
                            // Tombstone hints must flow through to the keydir
                            // so a key written in an earlier file gets erased.
                            keydir_->remove(bytes_to_view(rec.key), rec.tstamp);
                            return;
                        }
                        keydir_->put(bytes_to_view(rec.key),
                                     static_cast<std::uint32_t>(e.tstamp), rec.total_sz, rec.offset,
                                     rec.tstamp, /*now*/ 0,
                                     /*newest*/ false, 0, 0);
                    });
                    if (fr) used_hint = true;
                }
            }
        }
        if (used_hint) continue;

        // Fallback: fold the data file. Skip tombstones. Track the last
        // valid record end so we can chop off a torn-write tail (M5.1
        // task 4) — but only when this Cask is the writer.
        auto df = fileops::DataFile::open(e.data_path,
                                           fileops::DataFile::Mode::kRead);
        if (!df) {
            return std::unexpected(io_fault(df.error().errnum, e.data_path));
        }
        std::uint64_t last_valid_end = 0;
        auto fr = df->fold(
            [&](const codec::DataRecordView& view, std::uint64_t offset,
                std::uint32_t total_size) {
                std::string_view value_sv(
                    reinterpret_cast<const char*>(view.value.data()),
                    view.value.size());
                if (format::is_tombstone_value(value_sv)) {
                    keydir_->remove(bytes_to_view(view.key), view.tstamp);
                    return;
                }
                keydir_->put(bytes_to_view(view.key), static_cast<std::uint32_t>(e.tstamp),
                             total_size, offset, view.tstamp, /*now*/ 0,
                             /*newest*/ false, 0, 0);
            }, /*tolerate_crc_errors*/ true,
            /*out_last_valid_end*/ &last_valid_end);
        if (!fr) {
            return std::unexpected(err(CaskError::kBadCrc, e.data_path));
        }
        const std::uint64_t actual_size = df->size();
        df->close();

        // Torn-write recovery: if there are unparsable trailing bytes AND
        // we own write.lock (writer mode, not merge_only), reopen the file
        // in append mode and truncate to last_valid_end. A live writer's
        // mid-record crash leaves bytes that fold has already skipped;
        // trimming them frees disk and prevents bad fstats.
        if (opts_.read_write && !opts_.merge_only &&
            last_valid_end < actual_size) {
            auto wdf = fileops::DataFile::open(
                e.data_path, fileops::DataFile::Mode::kAppend);
            if (wdf) {
                (void)wdf->truncate_to(last_valid_end);  // best-effort
            }
        }
    }
    return {};
}

// ---- Active writer management -----------------------------------------------
std::expected<void, CaskFault> Cask::ensure_active_writer() {
    if (active_data_) return {};
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (opts_.merge_only) {
        // A merger never opens its own active writer; merge::run_merge
        // creates its own output file via keydir->increment_file_id().
        return std::unexpected(err(CaskError::kReadOnly,
                                     "merge_only mode: no active writer"));
    }

    // Reacquire write_lock_ if a previous close_write_file() released it.
    // Stale-lock reclaim runs identically to open(), so a crashed peer is
    // handled the same way.
    if (!write_lock_) {
        auto fl = acquire_writer_lock(dirname_);
        if (!fl) return std::unexpected(fl.error());
        write_lock_ = std::move(*fl);
    }

    active_file_id_ = keydir_->increment_file_id();
    auto data_path = fileops::mk_data_filename(dirname_, active_file_id_);
    auto hint_path = fileops::mk_hint_filename(data_path);

    auto df = fileops::DataFile::open(data_path,
                                       fileops::DataFile::Mode::kCreate,
                                       opts_.o_sync);
    if (!df) return std::unexpected(io_fault(df.error().errnum, data_path));
    auto hf = fileops::HintFile::open(hint_path,
                                       fileops::HintFile::Mode::kCreate,
                                       opts_.o_sync);
    if (!hf) return std::unexpected(io_fault(hf.error().errnum, hint_path));
    active_data_ = std::make_unique<fileops::DataFile>(std::move(*df));
    active_hint_ = std::make_unique<fileops::HintFile>(std::move(*hf));

    // Record the new active file path in write.lock so concurrent mergers
    // (opened with merge_only=true) can read which file id we own. Format
    // matches legacy: "<pid> <active_data_path>\n".
    if (write_lock_) {
        const std::string line = std::to_string(::getpid()) + " " +
                                  data_path + "\n";
        auto bytes = std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(line.data()), line.size());
        (void)write_lock_->write_data(bytes);  // best-effort
    }
    return {};
}

std::expected<void, CaskFault>
Cask::roll_active_if_needed(std::size_t about_to_write) {
    if (!active_data_) return ensure_active_writer();
    if (active_data_->size() + about_to_write <= opts_.max_file_size) return {};
    return roll_active();
}

std::expected<void, CaskFault> Cask::roll_active() {
    if (active_hint_) {
        if (auto r = active_hint_->finalize(); !r) {
            return std::unexpected(io_fault(r.error().errnum,
                                             std::string(active_hint_->path())));
        }
    }
    active_data_.reset();
    active_hint_.reset();
    return ensure_active_writer();
}

std::expected<void, CaskFault> Cask::close_write_file() {
    if (!opts_.read_write) {
        return std::unexpected(err(CaskError::kReadOnly,
                                     "close_write_file: read-only cask"));
    }
    if (opts_.merge_only) {
        return std::unexpected(err(CaskError::kReadOnly,
                                     "close_write_file: merge_only handle"));
    }
    // Finalize the hint trailer before dropping the handles so a future
    // open of this dir doesn't have to re-fold the data file.
    if (active_hint_) {
        if (auto r = active_hint_->finalize(); !r) {
            return std::unexpected(io_fault(r.error().errnum,
                                             std::string(active_hint_->path())));
        }
    }
    active_data_.reset();
    active_hint_.reset();
    active_file_id_ = 0;
    if (write_lock_) {
        write_lock_->release_quiet();
        write_lock_.reset();
    }
    // The next put/delete reaches ensure_active_writer, which sees a
    // null write_lock_ and reacquires before creating the new active
    // file. No state to set here beyond the resets above.
    return {};
}

// ---- read_file cache --------------------------------------------------------
fileops::DataFile* Cask::read_file(std::uint32_t file_id) {
    std::scoped_lock lk(read_cache_mu_);
    auto it = read_files_.find(file_id);
    if (it != read_files_.end()) return it->second.get();

    // Active writer doubles as a read source for itself.
    if (active_data_ && file_id == active_file_id_) {
        return active_data_.get();
    }

    auto path = fileops::mk_data_filename(dirname_, file_id);
    auto df = fileops::DataFile::open(path, fileops::DataFile::Mode::kRead);
    if (!df) return nullptr;
    auto* raw = df.value().path().data();  // touch to suppress unused
    (void)raw;
    auto up = std::make_unique<fileops::DataFile>(std::move(*df));
    auto* p = up.get();
    read_files_.emplace(file_id, std::move(up));
    return p;
}

// ---- get / put / delete -----------------------------------------------------

std::expected<GetResult, CaskFault>
Cask::get(std::span<const std::byte> key) {
    auto entry = keydir_->get(bytes_to_view(key));
    if (!entry) return std::unexpected(err(CaskError::kNotFound));

    // Expiry filter: a record older than (now - expiry_secs) is invisible.
    // We don't actively remove it from the keydir here (that would need to
    // be a write op); merge will eventually GC it.
    if (opts_.expiry_secs > 0) {
        const auto now = now_sec_default();
        if (entry->tstamp + opts_.expiry_secs <= now) {
            return std::unexpected(err(CaskError::kNotFound));
        }
    }

    auto* df = read_file(entry->file_id);
    if (!df) return std::unexpected(err(CaskError::kIo,
        "open file_id=" + std::to_string(entry->file_id)));

    auto rec = df->read(entry->offset, entry->total_sz);
    if (!rec) {
        switch (rec.error().kind) {
            case fileops::DataFileError::kBadCrc:
                return std::unexpected(err(CaskError::kBadCrc));
            case fileops::DataFileError::kIo:
                return std::unexpected(io_fault(rec.error().errnum));
            default:
                return std::unexpected(err(CaskError::kIo));
        }
    }
    // Tombstone? legacy: a tombstone value is still "the latest write" but
    // semantically deleted. Our keydir_->get already filters keydir tombs;
    // here we additionally hide tombstone *values* (M3.4 simple tombstones).
    if (format::is_tombstone_value(bytes_to_view(rec->value))) {
        return std::unexpected(err(CaskError::kNotFound));
    }
    return GetResult{std::move(rec->value), rec->tstamp};
}

std::expected<void, CaskFault>
Cask::put(std::span<const std::byte> key,
          std::span<const std::byte> value,
          std::uint32_t tstamp) {
    if (!opts_.read_write || opts_.merge_only) {
        return std::unexpected(err(CaskError::kReadOnly));
    }
    if (key.size()   > format::kMaxKeySize)   return std::unexpected(err(CaskError::kKeyTooLarge));
    if (value.size() > format::kMaxValueSize) return std::unexpected(err(CaskError::kValueTooLarge));

    if (tstamp == 0) tstamp = now_sec_default();
    const std::size_t about = format::kHeaderSize + key.size() + value.size();
    if (auto r = roll_active_if_needed(about); !r) return std::unexpected(r.error());

    // M5.1 task 2: a concurrent merger may have advanced biggest_file_id
    // past our active_file_id_. If we wrote anyway, the keydir's merge-race
    // detection would return kAlreadyExists and the put would be silently
    // dropped. Roll over proactively so our active_file_id_ stays ≥ biggest.
    if (active_data_ && active_file_id_ < keydir_->biggest_file_id()) {
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
    }

    auto w = active_data_->write(tstamp, key, value);
    if (!w) return std::unexpected(io_fault(w.error().errnum,
                                             std::string(active_data_->path())));
    auto h = active_hint_->write(tstamp, w->total_size, w->offset,
                                  /*tomb*/ false, key);
    if (!h) return std::unexpected(io_fault(h.error().errnum,
                                             std::string(active_hint_->path())));

    auto pr = keydir_->put(bytes_to_view(key), active_file_id_,
                            w->total_size, w->offset, tstamp,
                            /*now*/ 0, /*newest*/ true, 0, 0);
    if (pr == keydir::PutResult::kAlreadyExists) {
        // Lost a race with a concurrent merger between the rollover check
        // above and the keydir update. Roll once more and retry; on second
        // failure, surface the error to the caller.
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
        auto w2 = active_data_->write(tstamp, key, value);
        if (!w2) return std::unexpected(io_fault(w2.error().errnum));
        auto h2 = active_hint_->write(tstamp, w2->total_size, w2->offset,
                                        /*tomb*/ false, key);
        if (!h2) return std::unexpected(io_fault(h2.error().errnum));
        auto pr2 = keydir_->put(bytes_to_view(key), active_file_id_,
                                  w2->total_size, w2->offset, tstamp,
                                  0, true, 0, 0);
        if (pr2 == keydir::PutResult::kAlreadyExists) {
            return std::unexpected(err(CaskError::kAlreadyExists));
        }
    }
    return {};
}

std::expected<void, CaskFault>
Cask::remove(std::span<const std::byte> key, std::uint32_t tstamp) {
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (tstamp == 0) tstamp = now_sec_default();

    // Build the tombstone value. v0 = bare prefix; v2 = prefix + shadowed
    // file_id (BE uint32). The shadowed file_id comes from the current
    // keydir entry; if the key isn't there (already deleted), fall back
    // to v0 because there's nothing to point at.
    std::string tomb;
    if (opts_.tombstone_version == 2) {
        std::uint32_t shadow = 0;
        if (auto entry = keydir_->get(bytes_to_view(key))) {
            shadow = entry->file_id;
        }
        if (shadow != 0) {
            tomb.assign(format::kTombstoneV2);
            const std::uint8_t be[4] = {
                static_cast<std::uint8_t>((shadow >> 24) & 0xFF),
                static_cast<std::uint8_t>((shadow >> 16) & 0xFF),
                static_cast<std::uint8_t>((shadow >>  8) & 0xFF),
                static_cast<std::uint8_t>( shadow        & 0xFF),
            };
            tomb.append(reinterpret_cast<const char*>(be), 4);
        } else {
            tomb.assign(format::kTombstoneV0);
        }
    } else {
        tomb.assign(format::kTombstoneV0);
    }
    auto tomb_bytes = str_to_bytes(tomb);
    const std::size_t about =
        format::kHeaderSize + key.size() + tomb_bytes.size();
    if (auto r = roll_active_if_needed(about); !r) return std::unexpected(r.error());

    auto w = active_data_->write(tstamp, key, tomb_bytes);
    if (!w) return std::unexpected(io_fault(w.error().errnum));
    // Also append a tombstone hint so the index reflects deletion.
    auto h = active_hint_->write(tstamp, w->total_size, w->offset,
                                  /*tomb*/ true, key);
    if (!h) return std::unexpected(io_fault(h.error().errnum));
    keydir_->remove(bytes_to_view(key), tstamp);
    return {};
}

std::expected<void, CaskFault> Cask::sync() {
    if (active_data_) {
        if (auto r = active_data_->sync(); !r) {
            return std::unexpected(io_fault(r.error().errnum));
        }
    }
    return {};
}

// ---- status / fold / merge wrappers ----------------------------------------

StatusInfo Cask::status() {
    StatusInfo s;
    auto info = keydir_->info();
    s.key_count = info.key_count;
    s.key_bytes = info.key_bytes;
    s.epoch     = info.epoch;
    s.files.reserve(info.fstats.size());
    for (const auto& f : info.fstats) {
        s.files.push_back(merge::summarize(dirname_, f));
    }
    return s;
}

bool Cask::is_empty_estimate() {
    return keydir_->info().key_count == 0;
}

bool Cask::is_frozen() {
    return keydir_->info().iter_info.frozen;
}

Cask::NeedsMerge Cask::needs_merge(std::uint32_t now_sec) {
    auto info = keydir_->info();
    // Pick the file id to exclude:
    //   - normal writer mode: our own active_file_id_
    //   - merge_only mode: the live writer's active id, snapshotted from
    //     write.lock at open time. If the writer rolled over after we
    //     read, files newer than our snapshot may be the new active —
    //     exclude EVERYTHING with file_id >= snapshot to be safe.
    const std::uint32_t exclude_id =
        opts_.merge_only ? merger_writer_active_id_ : active_file_id_;
    std::vector<merge::FileStatus> summary;
    summary.reserve(info.fstats.size());
    for (const auto& f : info.fstats) {
        if (opts_.merge_only) {
            // Defensive: exclude the snapshot active AND any file rolled
            // over since (file_id > snapshot).
            if (exclude_id != 0 && f.file_id >= exclude_id) continue;
        } else {
            if (f.file_id == active_file_id_) continue;  // skip own writer
        }
        summary.push_back(merge::summarize(dirname_, f));
    }
    auto d = merge::decide(summary, opts_.policy, now_sec);
    NeedsMerge n;
    n.needs = d.needs_merge;
    for (const auto& f : d.files)         n.files.push_back(f.filename);
    for (const auto& f : d.expired_files) n.expired_files.push_back(f.filename);
    return n;
}

std::expected<merge::MergeStats, CaskFault>
Cask::merge(std::vector<std::string> files, std::uint32_t now_sec) {
    if (files.empty()) {
        auto n = needs_merge(now_sec);
        if (!n.needs) {
            // No-op: return an empty MergeStats-like result.
            return merge::MergeStats{};
        }
        files = std::move(n.files);
    }
    auto r = merge::run_merge(files, dirname_, *keydir_, opts_.o_sync);
    if (!r) {
        return std::unexpected(err(CaskError::kIo, r.error().detail));
    }

    // Drop cached read handles for the merged-away files BEFORE unlink so
    // we close the fds first (matters on systems where unlink-then-close
    // leaves the file briefly visible via /proc/self/fd).
    {
        std::scoped_lock lk(read_cache_mu_);
        for (const auto& path : files) {
            if (auto t = fileops::parse_data_tstamp(path)) {
                read_files_.erase(static_cast<std::uint32_t>(*t));
            }
        }
    }

    // After run_merge, every live record from `files` has been CAS-rewritten
    // into the new merge file, and stale records were already pointing
    // elsewhere. So nothing in the keydir references these inputs anymore —
    // safe to unlink the .data + .hint pair and drop the fstats entry.
    //
    // Failures here are best-effort: the keydir is already consistent. A
    // residual file just wastes disk until the next process tries the same.
    std::vector<std::uint32_t> trimmed_ids;
    trimmed_ids.reserve(files.size());
    for (const auto& path : files) {
        std::error_code ec;
        std::filesystem::remove(path, ec);
        std::filesystem::remove(fileops::mk_hint_filename(path), ec);
        if (auto t = fileops::parse_data_tstamp(path)) {
            trimmed_ids.push_back(static_cast<std::uint32_t>(*t));
        }
    }
    if (!trimmed_ids.empty()) {
        (void)keydir_->trim_fstats(trimmed_ids);
    }
    return *r;
}

}  // namespace bitcask
