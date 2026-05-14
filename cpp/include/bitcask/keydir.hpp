// bitcask 内存索引（KeyDir）。
//
// KeyDir 是「key → (file_id, offset, total_sz, tstamp)」的全内存哈希表，
// 是 bitcask 整个架构的核心：put/delete 改 keydir + 追加 data file，
// get 走 keydir 拿 (file_id, offset) 直接 pread 一次磁盘。
//
// === 并发模型（M5.3 phase 1） ===
//
// 一把 std::shared_mutex 罩住所有状态。
//   - 读：get / get_epoch / info / biggest_file_id / iter::next / deep_copy /
//          conditional_remove 的探测阶段 / is_ready —— 都是 shared_lock。
//   - 写：put / remove / update_fstats / pending freeze / iter start+release
//          —— unique_lock。
// 实测在 4 reader 并发下相对 std::mutex 有 ~1.9× 吞吐，单线程无开销。
// 进一步的 per-key sharding（M6 候选）需要把 epoch_/pending_/fstats_ 切开，
// 暂未做。
//
// === fold（迭代）下的 sibling chain + pending hash ===
//
// keyfolders_ > 0（有 fold 在跑）时，put 命中已存在 key 时不能直接覆盖
// （会破坏迭代器看到的快照），而是把旧 SingleEntry 升级成 MultiEntry——
// 一条 newest-first 的 sibling 链。新 key 走单独的 pending_ map，迭代器
// 看不到。
// 最后一个 fold release 时：把 pending_ 合并回 entries_，把 MultiEntry
// 折叠回 SingleEntry。这种「写时复制 + 延迟合并」让 fold 看到的是稳定
// 快照，并发写还能继续——这是 bitcask 高并发读 / 一致性 fold 的核心机制。

#pragma once

#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

namespace bitcask::keydir {

// 跟 legacy bitcask_nifs.c 完全对齐的 sentinel 值，用于「无限」/ unset。
inline constexpr std::uint32_t kMaxTime    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxEpoch   = std::numeric_limits<std::uint64_t>::max();
inline constexpr std::uint32_t kMaxSize    = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint32_t kMaxFileId  = std::numeric_limits<std::uint32_t>::max();
inline constexpr std::uint64_t kMaxOffset  = std::numeric_limits<std::uint64_t>::max();

// 一个 key 的某次「写入快照」。epoch 是写入时分配的全局递增计数，用于
// fold 期间区分新 / 旧 revision；wall-clock tstamp 在 ms 级别用于过期判定。
struct SingleEntry {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
};

// 「sibling 链」：fold 期间被多次写过的同 key revision 列表。
// revisions[0] 是最新，往后越来越旧。fold release 时折回 SingleEntry。
struct MultiEntry {
    std::vector<SingleEntry> revisions;
};

// entries_ map 中存的实际类型；用 variant 避免每个 key 都背 vector 开销。
using Entry = std::variant<SingleEntry, MultiEntry>;

// 查询返回的「展开视图」。对应 legacy 的 bitcask_keydir_entry_proxy 结构。
// key 字段是 zero-copy view——指向 KeyDir 内部存储，仅在持锁期间有效；
// 调用方要保留必须自己 copy。
struct EntryProxy {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
    bool is_tombstone      = false;
    std::string_view key;
};

// 文件级统计：每个 file_id 一条。merge 触发判断 + status 都靠这个。
struct FStatsEntry {
    std::uint32_t file_id          = 0;
    std::uint64_t live_keys        = 0;  // 还活着的 key 数
    std::uint64_t total_keys       = 0;  // 历史写入的 key 数
    std::uint64_t live_bytes       = 0;
    std::uint64_t total_bytes      = 0;
    std::uint32_t oldest_tstamp    = 0;
    std::uint32_t newest_tstamp    = 0;
    std::uint64_t expiration_epoch = kMaxEpoch;  // pending delete 截止 epoch
};

enum class PutResult { kOk, kAlreadyExists };

enum class StartIterResult {
    kOk,                  // 迭代成功开始；caller 必须配套调 release()
    kAlreadyIterating,    // 这个 handle 已经在迭代了
    kOutOfDate,           // pending 已过期；caller 应重试或等待
};

struct IterInfo {
    std::uint64_t iter_generation = 0;  // 累计 fold 启动次数
    std::uint64_t keyfolders      = 0;  // 当前 fold 数
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

class KeyDir;

// 单个 fold 的迭代句柄。
//
// 同一个 KeyDir 可以同时挂多个 IterHandle（并发 fold）。每个 handle 在
// start 时通过 iter_epoch_ 锁定一个 keydir 快照——之后看到的所有 key
// revision 都不晚于这个 epoch。handle 持有指向 parent 的非拥有指针；
// parent 必须比 handle 活得久（实际通过 cask 的 owning shared_ptr<KeyDir> 保证）。
//
// === 线程模型 ===
//   - 单 handle 内：start / next / release 自行获取 parent_->mutex_，但
//     handle 自身字段（iterating_/iter_epoch_/keys_snapshot_/cursor_）
//     不受任何锁保护——caller 必须保证「不要在多线程同时调用同一个
//     IterHandle 的方法」。
//   - 多 handle 之间：parent 共享但每个 handle 独立；可并行 fold。
//   - 析构调 release()——若上层有别的线程仍在 next()，会出现数据竞争。
class IterHandle {
public:
    explicit IterHandle(KeyDir* parent) noexcept : parent_(parent) {}
    ~IterHandle() noexcept;

    IterHandle(const IterHandle&) = delete;
    IterHandle& operator=(const IterHandle&) = delete;
    IterHandle(IterHandle&&) = delete;
    IterHandle& operator=(IterHandle&&) = delete;

    // 开始迭代。
    //   now_sec  — 当前 wall-clock 秒，用于 freshness 判断
    //   maxage   — 允许 frozen pending 表的最大年龄（秒），负数禁用该限制
    //   maxputs  — freeze 后允许的最大写入次数，负数禁用
    // 线程安全: 否（修改 handle 自身字段）；同一 handle 不可并发调用。
    // 锁: 内部对 parent_->mutex_ 取 unique_lock（写）。caller 不要持有 mutex_。
    StartIterResult start(std::uint32_t now_sec, int maxage, int maxputs);

    // 取下一项。默认跳过墓碑（legacy fold 语义）；include_tombstones=true
    // 时墓碑也作为 EntryProxy 返回（is_tombstone=true 字段）——给 fold/6
    // 的 SeeTombstones 路径用。
    // 线程安全: 否（推进 cursor_）；同一 handle 不可并发调用。
    // 锁: 内部对 parent_->mutex_ 取 shared_lock（读）。caller 不要持有 mutex_。
    std::optional<EntryProxy> next(bool include_tombstones = false);

    // 释放迭代；幂等。如果是最后一个 folder，触发 parent 把 pending_
    // 合并回 entries_ 并折叠 MultiEntry。
    // 线程安全: 否；幂等但同一 handle 上不可与 start/next 并发。
    // 锁: 内部对 parent_->mutex_ 取 unique_lock（写）。caller 不要持有 mutex_。
    void release();

    [[nodiscard]] bool is_iterating() const noexcept { return iterating_; }
    [[nodiscard]] std::uint64_t epoch() const noexcept { return iter_epoch_; }

private:
    friend class KeyDir;
    KeyDir* parent_;
    bool iterating_           = false;
    std::uint64_t iter_epoch_ = kMaxEpoch;

    // 迭代位置用 key copy 来表示，比 legacy 的 bucket index 多一点拷贝
    // 开销，但对 rehash 完全免疫。pin unordered_map 迭代器要求严格控
    // 制 load factor——M5 不愿意多花精力在那里。
    std::vector<std::string> keys_snapshot_;
    std::size_t cursor_ = 0;
};

// === KeyDir 类的线程模型（统一）===
// 所有 public 方法均「线程安全 / 可重入」，内部根据读 / 写自动获取
// shared_lock 或 unique_lock。caller 永远不应该在外部预先持有 mutex_。
// 把多次调用组合成原子操作不支持——例如「get 再 put」不是原子的，需要
// 上层自行控制；M5 阶段的 cask 利用「单 Erlang 进程一个 Cask」回避了
// 这个需求。
//
// 私有的 *_locked 后缀方法要求 caller 已持 unique_lock(mutex_)；
// 详见每个方法附近的注释。
class KeyDir {
public:
    KeyDir() = default;
    ~KeyDir() = default;

    KeyDir(const KeyDir&) = delete;
    KeyDir& operator=(const KeyDir&) = delete;

    // ---- 写操作 ----

    // 写入或更新 key。
    //   newest_put：true 表示「无条件写」（put 流程）；
    //               false 表示「条件写」（用 old_file_id/old_offset 做 CAS，
    //               值不匹配返回 kAlreadyExists——给 merge 用）。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。可重入: 否（递归会死锁）。
    PutResult put(std::string_view key,
                  std::uint32_t file_id, std::uint32_t total_sz,
                  std::uint64_t offset, std::uint32_t tstamp,
                  std::uint32_t now_sec,
                  bool newest_put,
                  std::uint32_t old_file_id, std::uint64_t old_offset);

    // 无条件删除。返回 true 表示原本有这条 key。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    bool remove(std::string_view key, std::uint32_t remove_time);

    // 条件删除（CAS）：只有 (tstamp, file_id, offset) 匹配当前 entry
    // 才删。给 merge 跟 cask put 路径之间的 race 防护用。
    // 线程安全: 是。锁: 探测阶段 shared_lock，匹配后 release 并调 remove()
    // 取 unique_lock；这两阶段之间存在「探测后状态变化」的窗口（caller
    // 拿到 kOk 时不保证当前已不存在），但对 merge 的语义足够。
    PutResult conditional_remove(std::string_view key,
                                 std::uint32_t tstamp,
                                 std::uint32_t file_id,
                                 std::uint64_t offset,
                                 std::uint32_t remove_time);

    // ---- 查询 ----

    // 默认拿最新 revision；epoch != kMaxEpoch 时拿在那个 epoch 之前的
    // 最新 revision（fold 的 snapshot 语义就靠这个）。
    // 线程安全: 是。锁: 内部 shared_lock(mutex_)（多读者并发）。
    // 注意: 返回的 EntryProxy.key 是 zero-copy view，仅在 caller 释放
    // shared_lock 之后无效——本接口返回时锁已释放，所以 key 已不可信赖；
    // caller 拿到值字段足够（key 字段当前调用方都已自带）。
    std::optional<EntryProxy> get(std::string_view key,
                                   std::uint64_t epoch = kMaxEpoch) const;

    // 线程安全: 是。锁: 内部 shared_lock(mutex_)。
    [[nodiscard]] std::uint64_t get_epoch() const;

    // ---- 迭代器工厂 ----
    // 线程安全: 是（仅构造一个 IterHandle 对象，未触碰共享状态）。
    [[nodiscard]] std::unique_ptr<IterHandle> make_iter() {
        return std::make_unique<IterHandle>(this);
    }

    // ---- 杂项 ----

    // 标记 keydir 为「就绪」——之前 acquire 同名 keydir 的线程会被解阻塞。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    void mark_ready();
    // 线程安全: 是。锁: 内部 shared_lock(mutex_)。
    [[nodiscard]] bool is_ready() const;

    // 线程安全: 是。锁: 内部 shared_lock(mutex_)。
    [[nodiscard]] std::uint32_t biggest_file_id() const;
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    std::uint32_t increment_file_id();
    // 把计数器至少推到 conditional_id；用于 registry 重新 acquire 时的恢复。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    std::uint32_t increment_file_id_at_least(std::uint32_t conditional_id);

    // ---- 文件统计 ----

    // 增量更新某个 file_id 的 live/total 计数（put 调 +live+total，
    // remove 调 -live；merge 用 total_inc 调整历史值）。should_create=true
    // 时不存在则新建一条。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    void update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                       std::uint64_t expiration_epoch,
                       std::int32_t live_inc, std::int32_t total_inc,
                       std::int32_t live_bytes_inc,
                       std::int32_t total_bytes_inc,
                       bool should_create);
    // 标记某 file_id 为「等迭代结束就可删」。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    void set_pending_delete(std::uint32_t file_id);
    // 从 fstats 表里删一组 file_id（merge 完成后调）。返回实际删了几条。
    // 线程安全: 是。锁: 内部 unique_lock(mutex_)。
    std::uint32_t trim_fstats(std::span<const std::uint32_t> file_ids);

    // ---- 快照 ----

    // 线程安全: 是。锁: 内部 shared_lock(mutex_)。
    [[nodiscard]] KeyDirInfo info() const;
    // 全量深拷贝；给 keydir_copy NIF 用（虽然 M6 之后不再 export，但内部
    // 的 merge 有时会用浅快照走类似的路径）。
    // 线程安全: 是。锁: 内部 shared_lock(mutex_)。
    // 注意: 大对象，O(n) 拷贝；与并发写者共享 shared_lock 期间，写者会被阻塞。
    [[nodiscard]] std::shared_ptr<KeyDir> deep_copy() const;

private:
    friend class IterHandle;

    // 整个 keydir 的并发控制点。读操作 shared_lock、写操作 unique_lock。
    // 见文件头并发模型说明。
    mutable std::shared_mutex mutex_;

    // 主 hash。值是 variant；判别用 std::get_if<SingleEntry|MultiEntry>。
    std::unordered_map<std::string, Entry> entries_;

    // fold 期间「pending 表」：写时复制规则触发后，新 key 和「不在
    // entries_ 里的 key 之 tombstone」会落到这里。最后一个 release 时
    // merge 回 entries_。
    std::optional<std::unordered_map<std::string, SingleEntry>> pending_;
    std::uint64_t pending_start_epoch_ = 0;  // 第一个 fold 启动时的 epoch
    std::uint64_t pending_start_time_  = 0;  // 第一个 fold 启动时的 wall-clock
    std::uint64_t pending_updated_     = 0;  // pending 中累积的写入次数

    std::unordered_map<std::uint32_t, FStatsEntry> fstats_;

    std::uint64_t key_count_       = 0;
    std::uint64_t key_bytes_       = 0;
    std::uint64_t epoch_           = 0;
    std::uint32_t biggest_file_id_ = 0;
    bool is_ready_                 = false;

    // 迭代协调状态。
    std::uint64_t keyfolders_         = 0;  // 当前活跃 fold 数
    std::uint64_t iter_generation_    = 0;  // 单调 ++（fold 启动一次 +1）
    std::uint64_t newest_folder_epoch_ = 0;  // 最近启动的 folder 的 iter_epoch
    bool iter_mutation_               = false;

    // 持锁版本：caller 必须已经拿了 unique_lock(mutex_)。
    // 线程安全: 否（依赖外部锁）。锁要求: caller 已持 unique_lock(mutex_)。
    void update_fstats_locked(std::uint32_t file_id, std::uint32_t tstamp,
                              std::uint64_t expiration_epoch,
                              std::int32_t live_inc, std::int32_t total_inc,
                              std::int32_t live_bytes_inc,
                              std::int32_t total_bytes_inc,
                              bool should_create);

    // 把 pending_ 合并回 entries_、把 MultiEntry 折回 SingleEntry。
    // 前置条件：caller 持 mutex_ 且 keyfolders_ == 0。
    // 线程安全: 否（依赖外部锁）。锁要求: caller 已持 unique_lock(mutex_)。
    void merge_pending_and_collapse_locked();

    // 在指定 epoch 找 key 的可见 revision；填 out 并设 out_is_tombstone。
    // 返回 true 表示找到（可能是墓碑）。caller 必须持 mutex_。
    // 线程安全: 否（依赖外部锁）。锁要求: caller 已持 mutex_（shared 或 unique 均可）。
    bool find_at_epoch_locked(std::string_view key, std::uint64_t target_epoch,
                              EntryProxy& out, bool& out_is_tombstone) const;

    // 是否有 folder 锁定在 <= 给定 epoch。当前实现是保守的：只要
    // keyfolders_>0 就视为全部 epoch 都被 pin 住——M5 还没做更细粒度
    // 的 epoch tracking。M6 候选优化点。
    // 线程安全: 否（仅读 keyfolders_）。锁要求: caller 已持 mutex_。
    [[nodiscard]] bool fold_pinned_at_or_below_locked(std::uint64_t /*e*/) const noexcept {
        return keyfolders_ > 0;
    }
};

}  // namespace bitcask::keydir
