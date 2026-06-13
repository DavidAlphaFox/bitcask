// 决策：要不要 merge？要并哪些文件？
//
// 这是 legacy bitcask:run_merge_triggers/2 + summarize/2 的纯函数移植。
// 输入：原始 fstats 列表（每个 file_id 一条）+ 配置；输出：每个文件的
// 决策结果。caller 拿这个 Decision 喂给 Merger 真正干活。
//
// 决策分两层：
//   1. trigger（任一满足就触发整次 merge）：frag_merge_trigger /
//      dead_bytes_merge_trigger
//   2. per-file threshold（任一满足就把这个文件加入候选列表）：
//      frag_threshold / dead_bytes_threshold / small_file_threshold / 过期
//
// 这种「先门槛后选文件」的两段决策保持跟 legacy 一致——不要破坏，
// Riak 等下游有运维脚本依赖具体的触发行为。
//
// === 线程模型 ===
// 本模块所有函数均为纯函数（无内部状态，无 I/O）。
//   - 可重入 / 线程安全：是。多线程可并发对同一/不同输入并发调用。
//   - 锁要求：无。
//   - 注意：输入的 fstats 列表通常来自 KeyDir::info()，由 caller 取到
//     快照后传入；本模块不保证「正在被并发修改的容器」的访问安全——caller
//     的责任是先拿快照再算策略。

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "bitcask/keydir.hpp"  // 需要 FStatsEntry

namespace bitcask::merge {

// 可调参数。默认值跟 priv/bitcask.app.src 对齐——保持同步是应用层的事，
// 这里只消费传进来的值。
struct PolicyOptions {
    // ---- trigger（任一满足整体就要 merge）----
    int        frag_merge_trigger          = 60;   // 百分比
    std::uint64_t dead_bytes_merge_trigger = 512ULL * 1024ULL * 1024ULL;

    // ---- 索引删除率触发（V4 新增）----
    // 当 (total_ords - live_docs) / total_ords >= 此百分比时触发 merge。
    // 0 = 禁用。这是全局信号（非 per-file），由 Cask::needs_merge 从 Index 计算。
    int        deletion_rate_trigger       = 0;    // 百分比, 0 = 禁用

    // ---- per-file 阈值（任一满足该文件入选）----
    int        frag_threshold              = 40;
    std::uint64_t dead_bytes_threshold     = 128ULL * 1024ULL * 1024ULL;
    // small_file_threshold == 0 表示禁用该规则。legacy 用 atom `disabled`
    // 表示禁用，这里统一折成 0。
    std::uint64_t small_file_threshold     = 10ULL * 1024ULL * 1024ULL;

    // ---- 过期 ----
    // expiry_secs == 0 禁用；否则任何 record 的 tstamp < (now - expiry_secs)
    // 视为过期，整个文件可以被并掉。
    std::uint32_t expiry_secs              = 0;
    std::uint32_t expiry_grace_time        = 0;  // legacy: 防止持续写入文件被错误判过期

    // ---- 输出体积上限 ----
    std::uint64_t max_merge_size           = 0;  // 0 = 无上限
};

// 单个文件的汇总。等价于 legacy `#file_status{}` 记录。
struct FileStatus {
    std::uint32_t file_id;
    std::string   filename;
    int           fragmented;        // 0..100，碎片率百分比
    std::uint64_t dead_bytes;        // total_bytes - live_bytes
    std::uint64_t total_bytes;
    std::uint32_t oldest_tstamp;
    std::uint32_t newest_tstamp;
    std::uint64_t expiration_epoch;
};

// Policy::decide 的结果。
struct Decision {
    bool needs_merge = false;
    std::vector<FileStatus> files;          // 要并的候选，保持输入顺序
    std::vector<FileStatus> expired_files;  // 子集：因过期而入选
};

// 一个 per-file 触发原因。给日志 / 测试用。
struct Reason {
    enum class Kind {
        kFragmented,
        kDeadBytes,
        kSmallFile,
        kDataExpired,
    };
    Kind kind;
    std::uint64_t value = 0;          // kFragmented 是百分比，其它是字节
    std::uint64_t cutoff = 0;         // 仅 kDataExpired 用
};

// 把单条 fstats 转成 FileStatus。dirname 用于拼出 data file 路径。
// total_bytes==0 && total_keys==0 的 fstats（空文件统计）legacy 隐式过滤
// 掉了——这里也保持同样行为。
[[nodiscard]] FileStatus
summarize(std::string_view dirname, const keydir::FStatsEntry& f);

// 列出某文件命中了哪些 per-file 阈值；空列表表示该文件不参与 merge。
// Policy::decide 内部用；测试 + log_needs_merge 也调它。
[[nodiscard]] std::vector<Reason>
per_file_reasons(const FileStatus& f, const PolicyOptions& opts,
                 std::uint32_t now_sec);

// 完整决策。now_sec 是 wall-clock 秒（0 表示无视 expiry，单测可用）；
// summary 一般由 summarize() 在 fstats 上批量算出来——caller 通常先把
// 当前 active write file 排除掉再传进来（不能并自己正在写的文件）。
// dead_doc_rate 是 V4 新增的全局信号（百分比）：(total_ords - live_docs)
// / total_ords * 100,由 caller 从 Index 计算;deletion_rate_trigger==0
// 时此参数被忽略,旧行为完全保留。
[[nodiscard]] Decision
decide(const std::vector<FileStatus>& summary,
       const PolicyOptions& opts,
       std::uint32_t now_sec,
       int dead_doc_rate = 0);

// 应用 max_merge_size 上限：累加文件大小，超过上限就停（严格遵守 legacy
// 「下一个文件会撑爆，就不要它」的语义）。第一个文件无条件保留——这是
// legacy 的兜底行为（即使第一个就超过 cap）。
// sizes 是跟 files 平行的 on-disk 大小列表，由 caller 通过 stat 拿到。
[[nodiscard]] std::vector<FileStatus>
cap_size(const std::vector<FileStatus>& files,
         const std::vector<std::uint64_t>& sizes,
         std::uint64_t max_merge_size);

}  // namespace bitcask::merge
