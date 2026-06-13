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
        // legacy 公式：trunc((1 - live/total) * 100)。
        // 这里走整数算术避免浮点误差：100 - live*100/total。
        const std::uint64_t live_pct =
            (f.live_keys * 100ULL) / std::max<std::uint64_t>(1, f.total_keys);
        s.fragmented = static_cast<int>(100ULL - live_pct);
    } else {
        s.fragmented = 0;
    }
    return s;
}

namespace {

// 算两个截止 tstamp：newest_tstamp 严格小于截止值的文件就被视为「整个文件
// 都过期了」。0 表示禁用过期判断。
// legacy 区分两个值：
//   - threshold_cutoff (= now - expiry_secs)：per-file 入选判断用
//   - trigger_cutoff   (= now - expiry_secs - grace)：trigger 判断用
//                                                    （多减一个 grace 期，
//                                                     防止刚到 expiry 边界就
//                                                     频繁触发整次 merge）
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

// 单文件是否「触发整次 merge」。任一规则成立即可。
bool any_trigger_fires(const FileStatus& f,
                       const PolicyOptions& opts,
                       std::uint32_t trigger_cutoff) {
    if (f.fragmented   >= opts.frag_merge_trigger)        return true;
    if (f.dead_bytes   >= opts.dead_bytes_merge_trigger)  return true;
    // 过期触发（legacy: `oldest_tstamp > 0` 确保不是空文件）。
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
                std::uint32_t now_sec,
                int dead_doc_rate) {
    Decision d;
    if (summary.empty()) return d;

    const auto cuts = expiry_cutoffs(opts, now_sec);

    // 第一阶段：trigger 判断。任一文件命中任一 trigger 就进入候选选择。
    // 一个都没命中就直接返回 needs_merge=false——本次连扫候选都不扫。
    bool any = std::any_of(summary.begin(), summary.end(),
        [&](const FileStatus& f) {
            return any_trigger_fires(f, opts, cuts.trigger_cutoff);
        });
    // V4:索引删除率触发(全局信号)。纯函数契约不变,信号作为 int 入参
    // 由 caller 算好后传进来——此函数仍不依赖 Index/KeyDir。
    if (!any && opts.deletion_rate_trigger > 0 &&
        dead_doc_rate >= opts.deletion_rate_trigger) {
        any = true;
    }
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
    // V4:删除率触发但无文件通过 per-file 阈值→全部非活跃文件入选。
    // 否则触发信号成立了但没文件可并,等于空转。
    if (d.files.empty() && opts.deletion_rate_trigger > 0 &&
        dead_doc_rate >= opts.deletion_rate_trigger) {
        d.files = summary;
        d.needs_merge = true;
    }
    return d;
}

std::vector<FileStatus>
cap_size(const std::vector<FileStatus>& files,
         const std::vector<std::uint64_t>& sizes,
         std::uint64_t max_merge_size) {
    if (max_merge_size == 0) return files;        // 0 = 无上限
    if (files.size() != sizes.size()) return files; // caller 传错——跳过 cap

    std::vector<FileStatus> out;
    out.reserve(files.size());
    std::uint64_t acc = 0;
    for (std::size_t i = 0; i < files.size(); ++i) {
        // legacy 严格语义：超过 cap 立即停止，且不包含撑爆 cap 的那个。
        // （包含的话 cap 形同虚设。）
        if (acc + sizes[i] > max_merge_size) break;
        out.push_back(files[i]);
        acc += sizes[i];
    }
    return out;
}

}  // namespace bitcask::merge
