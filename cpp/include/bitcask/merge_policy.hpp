// Decide which data files (if any) should be merged.
//
// Pure-function port of bitcask:run_merge_triggers/2 + summarize/2 from the
// Erlang side. Inputs are raw fstats records (one per file_id) and an opts
// bag; output is a per-file decision that the caller then feeds to Merger.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "bitcask/keydir.hpp"  // for FStatsEntry

namespace bitcask::merge {

// Tunables. Defaults mirror priv/bitcask.app.src — keeping them in sync is
// the application layer's job; Policy::decide only consumes the values.
struct PolicyOptions {
    // ---- Triggers (any-of) — does the keydir need merging at all? ----
    int        frag_merge_trigger          = 60;   // percent
    std::uint64_t dead_bytes_merge_trigger = 512ULL * 1024ULL * 1024ULL;

    // ---- Per-file thresholds (any-of) — which files to include? ----
    int        frag_threshold              = 40;
    std::uint64_t dead_bytes_threshold     = 128ULL * 1024ULL * 1024ULL;
    // small_file_threshold == 0 disables the rule. Legacy uses the atom
    // `disabled`; we collapse that to 0.
    std::uint64_t small_file_threshold     = 10ULL * 1024ULL * 1024ULL;

    // ---- Expiry ----
    // expiry_secs == 0 disables; otherwise: any record older than
    // (now_sec - expiry_secs) is considered expired.
    std::uint32_t expiry_secs              = 0;
    std::uint32_t expiry_grace_time        = 0;  // legacy: avoid expiring continuous writes

    // ---- Output cap ----
    std::uint64_t max_merge_size           = 0;  // 0 = unlimited
};

// Per-file summary, equivalent to the `#file_status{}` record.
struct FileStatus {
    std::uint32_t file_id;
    std::string   filename;
    int           fragmented;        // 0..100, percent
    std::uint64_t dead_bytes;        // total_bytes - live_bytes
    std::uint64_t total_bytes;
    std::uint32_t oldest_tstamp;
    std::uint32_t newest_tstamp;
    std::uint64_t expiration_epoch;
};

// Result of Policy::decide.
struct Decision {
    bool needs_merge = false;
    std::vector<FileStatus> files;          // candidates, ordered as given
    std::vector<FileStatus> expired_files;  // subset that hit the expired rule
};

// One reason a per-file threshold fired. Useful for logging / tests.
struct Reason {
    enum class Kind {
        kFragmented,
        kDeadBytes,
        kSmallFile,
        kDataExpired,
    };
    Kind kind;
    std::uint64_t value = 0;          // % for kFragmented; bytes otherwise
    std::uint64_t cutoff = 0;         // for kDataExpired
};

// Convert one fstats record to a FileStatus. `dirname` is needed to
// reconstruct the data-file path. Returns std::nullopt for fstats with
// total_bytes == 0 AND total_keys == 0 (legacy filters these implicitly).
[[nodiscard]] FileStatus
summarize(std::string_view dirname, const keydir::FStatsEntry& f);

// Returns the list of reasons a file hit ANY per-file threshold; empty if
// the file should not be merged. Used by Policy::decide internally; exposed
// for tests + log_needs_merge formatting.
[[nodiscard]] std::vector<Reason>
per_file_reasons(const FileStatus& f, const PolicyOptions& opts,
                 std::uint32_t now_sec);

// The full decision. `now_sec` is wall-clock seconds (0 disables expiry
// path independent of opts.expiry_secs). `summary` is typically derived by
// summarize() over fstats — but the caller may filter out the active
// write file first.
[[nodiscard]] Decision
decide(const std::vector<FileStatus>& summary,
       const PolicyOptions& opts,
       std::uint32_t now_sec);

// Apply max_merge_size: keep accumulating files while their cumulative
// on-disk size stays within the cap; legacy semantics are "stop strictly
// when a file would exceed the cap, and do NOT include that file". As a
// special case the first file is always included (mirroring legacy's
// fallthrough when read_file_info fails — caller passes in `sizes` directly,
// so we don't have that fallthrough, but the legacy effectively keeps the
// first file in the unlimited path). `sizes` is a parallel vector of the
// on-disk file sizes (caller obtains via stat).
[[nodiscard]] std::vector<FileStatus>
cap_size(const std::vector<FileStatus>& files,
         const std::vector<std::uint64_t>& sizes,
         std::uint64_t max_merge_size);

}  // namespace bitcask::merge
