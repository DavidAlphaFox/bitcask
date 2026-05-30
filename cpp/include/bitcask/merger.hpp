// Bitcask merger：把若干 fragmented data file 合并成一个新 data file
// （+ hint），然后 CAS 更新 keydir 指向新位置。
//
// M3.3 的精简范围（M3.4+ 在 cask.cpp 里包了完整功能）：
//   - 输出单个 data file，不超过 max_file_size 也不切分
//     （M3.4 在 cask 层补上 rollover）
//   - 不处理跟并发写入的 race（legacy 用 v2 墓碑写回源文件标记，这里
//     也由 cask 层在 merge 后置 stage 完成）
//   - 不拿锁——caller 必须已经持有 merge.lock
//   - 源文件里的墓碑 record 直接 SKIP（简化模型）
//
// 即使简化掉这些，run_merge 依然提供：
//   1. 去重：只有 keydir 仍然指向 (file_id, offset) 的 key 才被复制——
//      被覆盖 / 删除过的死 record 自然丢弃；
//   2. 同步生成 hint 文件，加速下次 open 的 keydir 重建；
//   3. 用 keydir->put(..., old_file_id, old_offset) 做 CAS 更新——
//      避免跟其它 writer 抢同一个 key。
//
// === 线程模型 ===
//   - run_merge 自身不取任何锁；caller 必须在外部串行（典型做法：通过
//     bitcask.merge.lock 文件锁保证同时仅一次 merge 在跑）。
//   - 期间会反复调用 keydir 的 put/get/conditional_remove——这些方法
//     自己内部加锁，并发写者可继续运行。
//   - 同一进程内并发调用 run_merge（同一目录）= 数据腐败风险；caller 责任。

#pragma once

#include <cstdint>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/keydir.hpp"

namespace bitcask::search { class SearchLayer; }

namespace bitcask::merge {

enum class MergeError {
    kInputOpenFailed,
    kOutputOpenFailed,
    kInputReadFailed,
    kOutputWriteFailed,
    kFinalizeFailed,
};

struct MergeFault {
    MergeError kind;
    int errnum = 0;
    std::string detail;  // 可选：路径 / 上下文，给日志用
};

struct MergeStats {
    std::string   output_data_path;
    std::string   output_hint_path;
    std::uint32_t output_file_id = 0;
    std::uint64_t records_seen   = 0;   // 输入文件总扫过的 record 数
    std::uint64_t records_kept   = 0;   // 实际复制到输出的
    std::uint64_t records_stale  = 0;   // 跳过：keydir 已指向别处
    std::uint64_t records_tombs  = 0;   // 跳过：源 record 是墓碑
    std::uint64_t bytes_written  = 0;
};

// 把 input_data_paths（必须都是 data file，不是 hint）合并到 output_dir
// 下一个新 data file + 新 hint。新文件的 file_id 通过
// keydir.increment_file_id() 分配，写在 MergeStats 里返回。
//
// sync_output=true 让输出文件以 O_SYNC 打开——cask 的 sync_strategy=o_sync
// 时使用，保证 merge 输出立刻落盘。
//
// 线程安全: 单调用本身（同一目录、同一 keydir）必须串行——caller 用
// merge.lock 文件锁仲裁；不同目录的 run_merge 互不冲突，可并发。
// 锁要求: 调用方需已持 bitcask.merge.lock（或同等仲裁），且 keydir 已就绪
// （is_ready() == true）。本函数内不取任何 mutex，但会通过 keydir 公共
// API 间接持锁。
// search_layer: 可选的 SearchLayer 指针。非空时，merge 复制活 record 后
// 会调用 on_relocate() 更新索引定位。空时跳过搜索通知（纯 KV merge）。
[[nodiscard]] std::expected<MergeStats, MergeFault>
run_merge(std::span<const std::string> input_data_paths,
          std::string_view output_dir,
          keydir::KeyDir& keydir,
          bool sync_output = false,
          search::SearchLayer* search_layer = nullptr);

}  // namespace bitcask::merge
