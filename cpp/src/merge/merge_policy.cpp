#include "bitcask/merge_policy.hpp"

#include <algorithm>

#include "bitcask/data_file.hpp"

namespace bitcask::merge {

FileStatus summarize(std::string_view dirname, const keydir::FStatsEntry& f) {
    FileStatus s;
    s.file_id          = f.file_id;
    s.filename         = fileops::mk_data_filename(dirname, f.file_id);
    s.dead_bytes       = (f.total_bytes >= f.live_bytes)
                           ? (f.total_bytes - f.live_bytes) : 0;
    s.total_bytes      = f.total_bytes;
    s.oldest_tstamp    = f.oldest_tstamp;
    s.newest_tstamp    = f.newest_tstamp;
    s.expiration_epoch = f.expiration_epoch;

    if (f.total_keys > 0) {
        // legacy: trunc((1 - live/total) * 100). Use uint math: 100 - live*100/total.
        const std::uint64_t live_pct =
            (f.live_keys * 100ULL) / std::max<std::uint64_t>(1, f.total_keys);
        s.fragmented = static_cast<int>(100ULL - live_pct);
    } else {
        s.fragmented = 0;
    }
    return s;
}

namespace {

// Return the cutoff: a file with newest_tstamp < cutoff is fully expired.
// A 0 cutoff disables expiry. The legacy code distinguishes
// `expiry_time` (used for the per-file threshold check) vs
// `expiry_grace_time = max(expiry_time - grace, 0)` (used for the per-keydir
// trigger). We compute both here.
struct ExpiryCutoffs {
    std::uint32_t threshold_cutoff = 0;
    std::uint32_t trigger_cutoff   = 0;
};
ExpiryCutoffs expiry_cutoffs(const PolicyOptions& opts, std::uint32_t now_sec) {
    ExpiryCutoffs out;
    if (opts.expiry_secs == 0 || now_sec == 0) return out;
    if (now_sec > opts.expiry_secs) {
        out.threshold_cutoff = now_sec - opts.expiry_secs;
    }
    const std::uint64_t grace_off =
        static_cast<std::uint64_t>(opts.expiry_secs) +
        static_cast<std::uint64_t>(opts.expiry_grace_time);
    if (now_sec > grace_off) {
        out.trigger_cutoff = static_cast<std::uint32_t>(now_sec - grace_off);
    }
    return out;
}

bool any_trigger_fires(const FileStatus& f,
                       const PolicyOptions& opts,
                       std::uint32_t trigger_cutoff) {
    if (f.fragmented   >= opts.frag_merge_trigger)        return true;
    if (f.dead_bytes   >= opts.dead_bytes_merge_trigger)  return true;
    // expired-data trigger (legacy: `oldest_tstamp > 0` ensures non-empty file)
    if (trigger_cutoff > 0 &&
        f.oldest_tstamp > 0 &&
        f.newest_tstamp < trigger_cutoff) {
        return true;
    }
    return false;
}

}  // namespace

std::vector<Reason>
per_file_reasons(const FileStatus& f, const PolicyOptions& opts,
                  std::uint32_t now_sec) {
    std::vector<Reason> out;
    if (f.fragmented >= opts.frag_threshold) {
        out.push_back({Reason::Kind::kFragmented,
                       static_cast<std::uint64_t>(f.fragmented), 0});
    }
    if (f.dead_bytes >= opts.dead_bytes_threshold) {
        out.push_back({Reason::Kind::kDeadBytes, f.dead_bytes, 0});
    }
    if (opts.small_file_threshold > 0 &&
        f.total_bytes < opts.small_file_threshold) {
        out.push_back({Reason::Kind::kSmallFile, f.total_bytes, 0});
    }
    const auto cuts = expiry_cutoffs(opts, now_sec);
    if (cuts.threshold_cutoff > 0 && f.newest_tstamp < cuts.threshold_cutoff) {
        out.push_back({Reason::Kind::kDataExpired,
                       f.newest_tstamp, cuts.threshold_cutoff});
    }
    return out;
}

Decision decide(const std::vector<FileStatus>& summary,
                const PolicyOptions& opts,
                std::uint32_t now_sec) {
    Decision d;
    if (summary.empty()) return d;

    const auto cuts = expiry_cutoffs(opts, now_sec);

    // Trigger phase: any one fired => proceed to file selection.
    bool any = std::any_of(summary.begin(), summary.end(),
        [&](const FileStatus& f) {
            return any_trigger_fires(f, opts, cuts.trigger_cutoff);
        });
    if (!any) return d;

    d.needs_merge = true;
    for (const auto& f : summary) {
        auto reasons = per_file_reasons(f, opts, now_sec);
        if (reasons.empty()) continue;
        d.files.push_back(f);
        if (std::any_of(reasons.begin(), reasons.end(),
                        [](const Reason& r) {
                            return r.kind == Reason::Kind::kDataExpired;
                        })) {
            d.expired_files.push_back(f);
        }
    }
    return d;
}

std::vector<FileStatus>
cap_size(const std::vector<FileStatus>& files,
         const std::vector<std::uint64_t>& sizes,
         std::uint64_t max_merge_size) {
    if (max_merge_size == 0) return files;  // 0 = unlimited
    if (files.size() != sizes.size()) return files;  // caller error: skip cap

    std::vector<FileStatus> out;
    out.reserve(files.size());
    std::uint64_t acc = 0;
    for (std::size_t i = 0; i < files.size(); ++i) {
        if (acc + sizes[i] > max_merge_size) break;  // legacy: STOP, exclude
        out.push_back(files[i]);
        acc += sizes[i];
    }
    return out;
}

}  // namespace bitcask::merge
