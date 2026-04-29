#include "bitcask/cask.hpp"

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

}  // namespace

// =============================================================================
// CaskIter
// =============================================================================

CaskIter::~CaskIter() noexcept { release(); }

std::expected<void, CaskFault>
CaskIter::start(int maxage, int maxputs, std::uint32_t now_sec) {
    if (iter_ && iter_->is_iterating()) return {};
    iter_ = parent_->keydir_->make_iter();
    auto r = iter_->start(now_sec, maxage, maxputs);
    if (r != keydir::StartIterResult::kOk) {
        return std::unexpected(err(CaskError::kIo, "iter start failed"));
    }
    return {};
}

std::expected<std::optional<CaskIter::Entry>, CaskFault> CaskIter::next() {
    if (!iter_ || !iter_->is_iterating()) return std::optional<Entry>{};

    auto proxy = iter_->next();
    if (!proxy) return std::optional<Entry>{};

    // Fetch value from the data file pointed to by the proxy.
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
    Entry e;
    e.key    = std::move(rec->key);
    e.value  = std::move(rec->value);
    e.tstamp = rec->tstamp;
    return std::optional<Entry>{std::move(e)};
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

    // Acquire write lock if read-write. The lock file holds the writer's
    // PID so other processes can detect us; legacy uses bitcask.write.lock.
    if (opts.read_write) {
        const auto lock_path = fs::path(cask->dirname_) / "bitcask.write.lock";
        auto fl = lock::FileLock::acquire(lock_path.string(), /*write*/ true);
        if (!fl) {
            // EEXIST means somebody else holds it.
            if (fl.error().errnum == EEXIST) {
                return std::unexpected(err(CaskError::kWriteLocked,
                                            lock_path.string()));
            }
            return std::unexpected(io_fault(fl.error().errnum,
                                             lock_path.string()));
        }
        cask->write_lock_ = std::move(*fl);
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

        // Fallback: fold the data file. Skip tombstones.
        auto df = fileops::DataFile::open(e.data_path,
                                           fileops::DataFile::Mode::kRead);
        if (!df) {
            return std::unexpected(io_fault(df.error().errnum, e.data_path));
        }
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
            }, /*tolerate_crc_errors*/ true);
        if (!fr) {
            return std::unexpected(err(CaskError::kBadCrc, e.data_path));
        }
    }
    return {};
}

// ---- Active writer management -----------------------------------------------
std::expected<void, CaskFault> Cask::ensure_active_writer() {
    if (active_data_) return {};
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));

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
    return {};
}

std::expected<void, CaskFault>
Cask::roll_active_if_needed(std::size_t about_to_write) {
    if (!active_data_) return ensure_active_writer();
    if (active_data_->size() + about_to_write <= opts_.max_file_size) return {};

    // Finalize current.
    if (auto r = active_hint_->finalize(); !r) {
        return std::unexpected(io_fault(r.error().errnum,
                                         std::string(active_hint_->path())));
    }
    active_data_.reset();
    active_hint_.reset();
    return ensure_active_writer();
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
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (key.size()   > format::kMaxKeySize)   return std::unexpected(err(CaskError::kKeyTooLarge));
    if (value.size() > format::kMaxValueSize) return std::unexpected(err(CaskError::kValueTooLarge));

    if (tstamp == 0) tstamp = now_sec_default();
    const std::size_t about = format::kHeaderSize + key.size() + value.size();
    if (auto r = roll_active_if_needed(about); !r) return std::unexpected(r.error());

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
        return std::unexpected(err(CaskError::kAlreadyExists));
    }
    return {};
}

std::expected<void, CaskFault>
Cask::remove(std::span<const std::byte> key, std::uint32_t tstamp) {
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (tstamp == 0) tstamp = now_sec_default();

    // Append a tombstone v0 record so a future scan rebuilds the same state.
    const std::string tomb(format::kTombstoneV0);
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

Cask::NeedsMerge Cask::needs_merge(std::uint32_t now_sec) {
    auto info = keydir_->info();
    std::vector<merge::FileStatus> summary;
    summary.reserve(info.fstats.size());
    for (const auto& f : info.fstats) {
        if (f.file_id == active_file_id_) continue;  // skip active writer
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
    // Drop any cached read handle for the merged-away files; they'll be
    // unlinked by the caller (or M3.5's merge_delete).
    {
        std::scoped_lock lk(read_cache_mu_);
        for (const auto& path : files) {
            if (auto t = fileops::parse_data_tstamp(path)) {
                read_files_.erase(static_cast<std::uint32_t>(*t));
            }
        }
    }
    return *r;
}

}  // namespace bitcask
