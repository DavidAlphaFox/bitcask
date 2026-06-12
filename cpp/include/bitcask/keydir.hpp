// bitcask 内存索引（KeyDir）。
//
// KeyDir 是「key → (file_id, offset, total_sz, tstamp)」的全内存哈希表，
// 是 bitcask 整个架构的核心：put/delete 改 keydir + 追加 data file，
// get 走 keydir 拿 (file_id, offset) 直接 pread 一次磁盘。
//
// === 并发模型（M6-S2:16 分片）===
//
// entries 按 key hash 低 4 位切成 16 个分片，每分片一把 shared_mutex；
// 全局标量（epoch_/key_count_/key_bytes_/biggest_file_id_/next_ord_/
// keyfolders_）全部 atomic（M6-S1/S2），fstats 走无锁发布路径（§设计
// doc/keydir-sharding-design-zh.md）。pending_/iter 协调状态由独立的
// meta_mu_ 保护（只在 fold 期间触碰，冷路径）。
//
// 锁全序（必须严格遵守）：
//     shards_[0..kShards)（按下标升序）→ meta_mu_ → fstats_grow_mu_
// 即：允许在持分片锁时嵌套获取 meta_mu_（get/put/remove 的 pending
// 分支就这么做），严禁反向（持 meta 再拿分片锁）。fold 的
// start/release/deep_copy/save_snapshot/load_snapshot 是全屏障：按下标
// 序拿全部 16 个分片锁再拿 meta_mu_。
//
//   - 热路径（无 fold）：get 单分片 shared，put/remove 单分片 unique，
//     至多一把锁 + relaxed 原子。
//   - fold 期间：写已存在 key 在分片内升 sibling 链；新 key 经
//     meta_mu_ 进 pending_。
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

#include "bitcask/string_hash.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <deque>
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
// ord 是写入时的全局单调递增序号，用于 tie-breaking 和有序遍历。
struct SingleEntry {
    std::uint32_t file_id  = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t offset   = 0;
    std::uint64_t epoch    = 0;
    std::uint32_t tstamp   = 0;
    std::uint64_t ord      = 0;  // 全局单调递增写序号
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
    std::uint64_t ord      = 0;  // 全局单调递增写序号
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
//   - 单 handle 内：start / release 自行对 parent 做全屏障（全部分片
//     unique + meta unique），next 只拿目标 key 的分片 shared；handle
//     自身字段（iterating_/iter_epoch_/keys_snapshot_/cursor_）
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
    // 锁: 内部对 parent_ 做全屏障（全部分片 unique + meta unique）。
    // caller 不要持有任何 keydir 锁。
    StartIterResult start(std::uint32_t now_sec, int maxage, int maxputs);

    // 取下一项。默认跳过墓碑（legacy fold 语义）；include_tombstones=true
    // 时墓碑也作为 EntryProxy 返回（is_tombstone=true 字段）——给 fold/6
    // 的 SeeTombstones 路径用。
    // 线程安全: 否（推进 cursor_）；同一 handle 不可并发调用。
    // 锁: 内部对目标 key 的分片取 shared_lock（读）。caller 不要持锁。
    std::optional<EntryProxy> next(bool include_tombstones = false);

    // 释放迭代；幂等。如果是最后一个 folder，触发 parent 把 pending_
    // 合并回 entries_ 并折叠 MultiEntry。
    // 线程安全: 否；幂等但同一 handle 上不可与 start/next 并发。
    // 锁: 内部对 parent_ 做全屏障（全部分片 unique + meta unique）。
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
// 所有 public 方法均「线程安全 / 可重入」，内部按需获取分片锁 /
// meta_mu_（锁序见文件头：shards 下标升序 → meta_mu_ → fstats_grow_mu_）。
// caller 永远不应该在外部预先持有 keydir 的任何锁。
// 把多次调用组合成原子操作不支持——例如「get 再 put」不是原子的，需要
// 上层自行控制；M5 阶段的 cask 利用「单 Erlang 进程一个 Cask」回避了
// 这个需求。
//
// 私有的 *_barrier 后缀方法要求 caller 已持全屏障（全部分片 unique +
// meta unique）；详见每个方法附近的注释。
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
    //   ord：写入的全局单调递增序号，用于 tie-breaking 和有序遍历。
    // 线程安全: 是。锁: key 分片 unique;fold 态新 key 嵌套 meta unique。
    // 可重入: 否（递归会死锁）。
    PutResult put(std::string_view key,
                  std::uint32_t file_id, std::uint32_t total_sz,
                  std::uint64_t offset, std::uint32_t tstamp,
                  std::uint32_t now_sec,
                  bool newest_put,
                  std::uint32_t old_file_id, std::uint64_t old_offset,
                  std::uint64_t ord = 0);

    // 无条件删除。返回 true 表示原本有这条 key。
    // 线程安全: 是。锁: key 分片 unique;fold 态按需嵌套 meta unique。
    bool remove(std::string_view key, std::uint32_t remove_time);

    // 条件删除（CAS）：只有 (tstamp, file_id, offset) 匹配当前 entry
    // 才删。给 merge 跟 cask put 路径之间的 race 防护用。
    // 线程安全: 是。锁: 探测阶段分片 shared，匹配后 release 并调 remove()
    // 取分片 unique；这两阶段之间存在「探测后状态变化」的窗口（caller
    // 拿到 kOk 时不保证当前已不存在），但对 merge 的语义足够。
    PutResult conditional_remove(std::string_view key,
                                 std::uint32_t tstamp,
                                 std::uint32_t file_id,
                                 std::uint64_t offset,
                                 std::uint32_t remove_time);

    // ---- 查询 ----

    // 默认拿最新 revision；epoch != kMaxEpoch 时拿在那个 epoch 之前的
    // 最新 revision（fold 的 snapshot 语义就靠这个）。
    // 线程安全: 是。锁: key 分片 shared;miss 且 fold 态时嵌套 meta shared。
    // 注意: 返回的 EntryProxy.key 是 zero-copy view，仅在持锁期间有效——
    // 本接口返回时锁已释放，所以 key 已不可信赖；
    // caller 拿到值字段足够（key 字段当前调用方都已自带）。
    std::optional<EntryProxy> get(std::string_view key,
                                   std::uint64_t epoch = kMaxEpoch) const;

    // 线程安全: 是。无锁（atomic 读）。
    [[nodiscard]] std::uint64_t get_epoch() const;

    // 分配一个新的全局 ord 值（单调递增）。
    // 线程安全: 是。无锁（atomic fetch_add）。
    [[nodiscard]] std::uint64_t alloc_ord();

    // 把 next_ord_ 至少推到 ord + 1（用于 merge 后恢复 ord 状态）。
    // 线程安全: 是。无锁（atomic CAS-max）。
    void advance_ord(std::uint64_t ord);

    // ---- 迭代器工厂 ----
    // 线程安全: 是（仅构造一个 IterHandle 对象，未触碰共享状态）。
    [[nodiscard]] std::unique_ptr<IterHandle> make_iter() {
        return std::make_unique<IterHandle>(this);
    }

    // ---- 杂项 ----

    // 标记 keydir 为「就绪」——之前 acquire 同名 keydir 的线程会被解阻塞。
    // 线程安全: 是。无锁（atomic 写）。
    void mark_ready();
    // 线程安全: 是。无锁（atomic 读）。
    [[nodiscard]] bool is_ready() const;

    // 线程安全: 是。无锁（atomic 读）。
    [[nodiscard]] std::uint32_t biggest_file_id() const;
    // 线程安全: 是。无锁（atomic fetch_add）。
    std::uint32_t increment_file_id();
    // 把计数器至少推到 conditional_id；用于 registry 重新 acquire 时的恢复。
    // 线程安全: 是。无锁（atomic CAS-max）。
    std::uint32_t increment_file_id_at_least(std::uint32_t conditional_id);

    // A4-P2:当前 next_ord(成对性门比较用;原子读,无锁)。
    [[nodiscard]] std::uint64_t peek_next_ord() const {
        return next_ord_.load(std::memory_order_relaxed);
    }

    // ---- A4:keydir 段快照(open 加速;设计 doc/recovery-snapshot-design-zh.md)----
    // dump 当前内存态 + 调用方给的 per-file 字节水位。有活跃 fold
    // (MultiEntry 可能存在)时拒绝并返回 false(快照是纯优化)。
    // 线程安全: 是(全部分片 shared + meta shared;只应在写者静止点调用)。
    [[nodiscard]] bool save_snapshot(
        std::string_view path,
        const std::vector<std::pair<std::uint32_t, std::uint64_t>>& watermarks) const;
    // 校验 magic/ver/CRC 并整体重建内存态,返回水位表;任何不一致返回
    // nullopt 且清空状态(调用方走全量 fold)。仅限全新 KeyDir(open 路径)。
    [[nodiscard]] std::optional<
        std::vector<std::pair<std::uint32_t, std::uint64_t>>>
    load_snapshot(std::string_view path);

    // ---- 文件统计 ----
    // (注:fstats 的增量更新只发生在 put/remove 内,经私有 update_fstats;
    //  S1 起内部无锁,曾有的带锁公开版零调用方,O13 核实后删除。)

    // 标记某 file_id 为「等迭代结束就可删」。
    // 线程安全: 是。无锁（fstats 原子路径）。
    void set_pending_delete(std::uint32_t file_id);
    // 从 fstats 表里删一组 file_id（merge 完成后调）。返回实际删了几条。
    // 线程安全: 是。锁: fstats_grow_mu_（与槽位增长串行）。
    std::uint32_t trim_fstats(std::span<const std::uint32_t> file_ids);

    // ---- 快照 ----

    // 线程安全: 是。锁: meta shared（iter 状态）;计数走 atomic,fstats 无锁。
    [[nodiscard]] KeyDirInfo info() const;
    // 全量深拷贝；给 keydir_copy NIF 用（虽然 M6 之后不再 export，但内部
    // 的 merge 有时会用浅快照走类似的路径）。
    // 线程安全: 是。锁: 全部分片 shared + meta shared。
    // 注意: 大对象，O(n) 拷贝；持 shared 锁期间写者会被阻塞。
    [[nodiscard]] std::shared_ptr<KeyDir> deep_copy() const;

private:
    friend class IterHandle;

    // === M6-S2:16 分片 ===
    // 锁全序（严格遵守,详见文件头）:
    //     shards_[0..kShards)（下标升序）→ meta_mu_ → fstats_grow_mu_
    // 允许持分片锁时嵌套拿 meta_mu_;严禁持 meta_mu_ 时再拿任何分片锁。
    static constexpr std::size_t kShards = 256;  // S5:16→64,降低分片碰撞与写者停车传染面
    struct alignas(64) Shard {
        // 分片锁。主 hash 的值是 variant;判别用 std::get_if<Single|Multi>。
        // 透明 hash:get/put/remove 热路径用 string_view 直接查,零拷贝(O1)。
        mutable std::mutex mu;  // S5 实验:rwlock→mutex(消写者偏好停车;短临界区)
        // map 头独占缓存行:find 路径读 map 头,别让它与锁字(每次加解锁
        // RMW)同行。
        alignas(64) std::unordered_map<std::string, Entry, StringHash, std::equal_to<>> entries;
    };
    mutable std::array<Shard, kShards> shards_;
    // pending_/iter 协调状态专用(仅 fold 期间触碰,冷路径)。
    mutable std::shared_mutex meta_mu_;

    // key → 分片下标(hash 低位路由;kShards 是 2^n)。
    [[nodiscard]] static std::size_t shard_for(std::string_view key) noexcept {
        return StringHash{}(key) & (kShards - 1);
    }

    // 按下标升序锁住全部分片(全屏障第一段;之后通常再拿 meta_mu_)。
    [[nodiscard]] std::array<std::unique_lock<std::mutex>, kShards>
    lock_all_shards() const;
    [[nodiscard]] std::array<std::unique_lock<std::mutex>, kShards>
    lock_all_shards_shared() const;

    // fold 期间「pending 表」：写时复制规则触发后，新 key 的写入和
    // 「fold 期间临时 key 的 tombstone」会落到这里。最后一个 release 时
    // merge 回各分片 entries。
    // 不变量(S2 起)：key ∈ 某分片 entries ⟹ key ∉ pending_——已存在
    // key 的新版本一律走分片内 sibling 链,绝不进 pending。get/put/remove
    // 的「entries 优先、miss 再查 pending」探测顺序依赖该不变量。
    // 锁要求：meta_mu_。
    std::optional<std::unordered_map<std::string, SingleEntry,
                                     StringHash, std::equal_to<>>> pending_;
    std::uint64_t pending_start_epoch_ = 0;  // 第一个 fold 启动时的 epoch(meta_mu_)
    std::uint64_t pending_start_time_  = 0;  // 第一个 fold 启动时的 wall-clock(meta_mu_)
    std::uint64_t pending_updated_     = 0;  // pending 中累积的写入次数(meta_mu_)

    // file_id 是 keydir_registry 分配的小整数单调计数,直接用 vector 按
    // 下标存(替代 unordered_map:update_fstats 在 put/remove 热路径上)。
    // present 位独立存;trim 后槽位清空但数组不收缩。
    // M6-S1:fstats 无锁热路径(设计 keydir-sharding-design-zh.md §3)。
    // deque 元素地址稳定;槽位经 fstats_grow_mu_ 串行构造后,以
    // fstats_size_ release 发布——读者 idx < size(acquire) 即可直接对
    // 字段做 relaxed 原子累加,put 热路径零锁字共享(S2 起生效;S1 仍在
    // mutex_ 内调用,顺序平凡安全)。
    struct AtomicFStats {
        std::atomic<std::uint64_t> live_keys{0};
        std::atomic<std::uint64_t> total_keys{0};
        std::atomic<std::uint64_t> live_bytes{0};
        std::atomic<std::uint64_t> total_bytes{0};
        std::atomic<std::uint32_t> oldest_tstamp{0};
        std::atomic<std::uint32_t> newest_tstamp{0};
        std::atomic<std::uint64_t> expiration_epoch{kMaxEpoch};
        std::atomic<std::uint8_t>  present{0};
    };
    mutable std::mutex fstats_grow_mu_;   // 仅新 file_id 槽位构造(罕见)
    mutable std::deque<AtomicFStats> fstats_;
    std::atomic<std::size_t> fstats_size_{0};

    // M6-S1/S2:全局标量原子化。epoch_ 的跨线程可见性判据
    // (entry.epoch < iter_epoch)由「分片锁内 fetch_add + 屏障内读取」
    // 保证,见设计 §6.4。
    //
    // 缓存行分组（S2 实测关键）:
    //   写热行——每次 put/remove 都 RMW（epoch_/next_ord_;key_count_/
    //   key_bytes_ 在插入删除时）。没有热读者(info 是冷路径)。
    alignas(64) std::atomic<std::uint64_t> epoch_{0};
    std::atomic<std::uint64_t> key_count_{0};
    std::atomic<std::uint64_t> key_bytes_{0};
    // ord 分配器独立为 atomic:alloc_ord/advance_ord 不再抢全局锁
    // (put 热路径上每次写都要分配 ord)。
    std::atomic<std::uint64_t> next_ord_{0};

    //   读热行——get/put 热路径每次 relaxed 读、写入罕见。与上面的写热
    //   行隔离,否则每个 put 的 epoch_ RMW 都会把读者需要的行打飞
    //   (false sharing,Mixed 基准实测主要损耗源)。
    // keyfolders_:当前活跃 fold 数。只在全屏障(全部分片 unique + meta
    // unique)内修改;热路径在持自己分片锁后 relaxed 读即足够新——屏障
    // 无法在写者持分片锁期间完成,见设计 §4 时序论证。
    alignas(64) std::atomic<std::uint64_t> keyfolders_{0};
    // biggest_file_id_:put 接受判断每次读;CAS-max 推进仅 roll 时真写。
    std::atomic<std::uint32_t> biggest_file_id_{0};
    // pending_.has_value() 的无锁镜像:热路径在持分片锁后 relaxed 读,
    // 避免每次 get/put 都摸 meta_mu_。仅在持 meta_mu_ unique 时修改。
    // (单独存在的意义:deep_copy 出的副本可能 keyfolders_==0 但 pending_
    //  仍在——此时写路径仍须分流到 pending,不能只看 keyfolders_。)
    std::atomic<bool> has_pending_{false};
    std::atomic<bool> is_ready_{false};

    // 迭代协调冷状态(meta_mu_;独立行,避免污染上面两条热行)。
    alignas(64) std::uint64_t iter_generation_ = 0;  // 单调 ++(fold release 归零时 +1)
    std::uint64_t newest_folder_epoch_ = 0;  // 最近启动的 folder 的 iter_epoch
    // 写痕迹标志。当前没有读者(纯诊断位);做成 atomic 以免 sibling 升链
    // 热分支为了它单独去拿 meta_mu_(S2 设计偏差,见 keydir.cpp 注释)。
    std::atomic<bool> iter_mutation_{false};

    // fstats 增量更新。S1 起内部即无锁(增长走 fstats_grow_mu_),caller
    // 无需持有任何锁;锁序上 fstats_grow_mu_ 排最末,持分片锁/meta 时
    // 调用均合法。
    void update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                       std::uint64_t expiration_epoch,
                       std::int32_t live_inc, std::int32_t total_inc,
                       std::int32_t live_bytes_inc,
                       std::int32_t total_bytes_inc,
                       bool should_create);

    // 把 pending_ 合并回各分片 entries、把 MultiEntry 折回 SingleEntry。
    // 前置条件：caller 持全屏障(全部分片 unique + meta unique)且
    // keyfolders_ == 0。
    // 线程安全: 否（依赖外部锁）。
    void merge_pending_and_collapse_barrier();
};

}  // namespace bitcask::keydir
