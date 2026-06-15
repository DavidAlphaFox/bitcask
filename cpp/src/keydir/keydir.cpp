#include "bitcask/keydir.hpp"
#include "bitcask/codec.hpp"

#include <cstdio>
#include <cstring>

#include <algorithm>
#include <cassert>
#include <shared_mutex>

// =============================================================================
// M6-S2 并发模型速记（详见 keydir.hpp 文件头 / doc/keydir-sharding-design-zh.md）
//
// 锁全序（屏障 v2，必须严格遵守）：
//     barrier_mu_ → gate_mu_ → meta_mu_ → 单个 shard(任意时刻 ≤1 把)
//     → fstats_grow_mu_
// 两处反向嵌套例外（无环论证见 keydir.hpp 文件头）：
//   ① 热路径持单个分片锁后嵌套 meta（shard→meta，S2 起的既有方向）；
//   ② iter release 阶段二屏障内 meta_shared→shard（见
//      apply_pending_to_entries_barrier 注释）。
//
// 核心不变量（探测顺序 entries→pending 的正确性依据）：
//     key ∈ 某分片 entries  ⟹  pending_ 不会有它的更新版本。
// 已存在 key 的新版本（put 覆写 / remove 墓碑）一律在分片内走 sibling
// 链，绝不进 pending；pending 只接「fold 期间出现的全新 key」。
//
// keyfolders_ 只在写者闸门屏障（BarrierGuard + meta unique）内修改；
// 写者在持自己分片锁（且闸门检查通过）后 relaxed 读即足够新——闸门
// 检查读到 inactive 的写者要么先于排干循环持有分片锁（排干在该分片
// 等它出清，keyfolders_ 修改整体在其后），要么经排干循环的 mutex
// 配对必见 active 退避；所以「读到 0 → 直写」的写一定整体先于屏障。
// =============================================================================

namespace bitcask::keydir {

// =============================================================================
// 内部辅助函数（不做锁；caller 必须已持对应分片 / meta 锁）
// =============================================================================

namespace {

// sibling-tombstone：fold 期间删除已存在 key 时，往 sibling 链头部插入的
// 「墓碑 revision」。三个 sentinel 字段同时取 MAX 是 legacy is_sib_tombstone
// 的判别约定，沿用以保证跨实现互通。
SingleEntry make_sibling_tombstone(std::uint64_t epoch, std::uint32_t tstamp) noexcept {
    return SingleEntry{kMaxFileId, kMaxSize, kMaxOffset, epoch, tstamp, 0};
}
[[nodiscard]] bool is_sibling_tombstone(const SingleEntry& s) noexcept {
    return s.file_id == kMaxFileId && s.total_sz == kMaxSize && s.offset == kMaxOffset;
}

// pending-tombstone：写入 pending_ map 的墓碑标记。只用 offset==MAX 一个
// 字段判别——legacy is_pending_tombstone 行为；file_id/total_sz 是从真实
// entry 继承过来的，merge 后会被覆盖。
[[nodiscard]] bool is_pending_tombstone(const SingleEntry& s) noexcept {
    return s.offset == kMaxOffset;
}

// SingleEntry → EntryProxy 的字段拷贝。tombstone 标志由 caller 显式传，
// 因为 SingleEntry 自身不知道自己在 sibling 链里是不是墓碑。
[[nodiscard]] EntryProxy to_proxy(std::string_view key, const SingleEntry& s,
                                   bool tombstone) noexcept {
    return EntryProxy{
        .file_id      = s.file_id,
        .total_sz     = s.total_sz,
        .offset       = s.offset,
        .epoch        = s.epoch,
        .tstamp       = s.tstamp,
        .ord          = s.ord,
        .is_tombstone = tombstone,
        .key          = key,
    };
}

// 找出 target_epoch 时能看到的 revision。
//   SingleEntry：epoch 比较一下就完事；
//   MultiEntry ：链是 newest-first 排序的，从头往后扫，第一个 epoch
//                <= target_epoch 的就是那一刻的可见 revision。
// 返回 {是否找到, revision 值, 是否墓碑}。
struct EntryAt {
    bool found = false;
    SingleEntry rev{};
    bool is_tombstone = false;
};
[[nodiscard]] EntryAt entry_at_epoch(const Entry& e, std::uint64_t target_epoch) noexcept {
    EntryAt out;
    if (const auto* s = std::get_if<SingleEntry>(&e)) {
        if (target_epoch < s->epoch) return out;  // 那一刻还没写入
        out.found = true;
        out.rev = *s;
        out.is_tombstone = false;  // SingleEntry 从不直接表示墓碑
        return out;
    }
    const auto& m = std::get<MultiEntry>(e);
    for (const auto& rev : m.revisions) {
        if (target_epoch >= rev.epoch) {
            out.found = true;
            out.rev = rev;
            out.is_tombstone = is_sibling_tombstone(rev);
            return out;
        }
    }
    return out;  // target_epoch 早于链中最早的 revision
}

}  // namespace

// =============================================================================
// 屏障 v2:写者闸门（RAII;替代旧 lock_all_shards/lock_all_shards_shared）。
//
// 旧方案在屏障期间同时持有全部 kShards+1=257 把锁,撞 TSan 死锁检测器
// 的 64 持锁硬上限(compiler-rt sanitizer_deadlock_detector.h:67 CHECK,
// 实测 KeyDir.DeepCopyPreservesOrd 在 TSAN_OPTIONS=detect_deadlocks=1
// 下崩溃),故废弃。本方案任意瞬间至多持 1 把分片锁。
//
// 协议:
//   ctor: barrier_mu_(屏障间互斥) → gate_mu_ 内置 barrier_active_=true
//         → 排干:逐分片「加锁-放锁」。在途写者两种结局:
//           a) 先于排干持有分片锁(闸门检查读到 inactive)——排干循环在
//              该分片阻塞,等写者整段临界区(含嵌套 meta unique)出清;
//           b) 晚于排干拿到分片锁——经该分片 mutex 的 unlock/lock 配对
//              必见 barrier_active_=true,放分片锁到 gate_cv_ 退避。
//         排干完成 ⟹ 屏障内不再有写者,也不存在 meta unique 持有/
//         等待者(其余 unique 使用者 start/release/save/load 被
//         barrier_mu_ 串行)。
//   dtor: gate_mu_ 内置 barrier_active_=false → notify_all 唤醒退避
//         写者 → 放 barrier_mu_。退避写者经 gate_mu_ 的 HB 必见屏障内
//         的全部修改(keyfolders_/pending_/entries)。
//
// 屏障期间**读者(get/next/conditional_remove peek/info)照常并发**:
//   - 屏障持有者对各分片 entries 的无锁遍历(save/iter start)
//     与读者的持锁 find 是读-读并发,天然安全;写者出清由排干循环的
//     mutex 配对保证 happens-before。
//   - 唯一的屏障内写路径是 iter release 的阶段二/折叠,均按分片锁协议
//     持锁写,对读者安全(见 apply_pending_to_entries_barrier)。
// =============================================================================

class BarrierGuard {
    KeyDir& kd;

public:
    explicit BarrierGuard(const KeyDir& k) : kd(const_cast<KeyDir&>(k)) {
        kd.barrier_mu_.lock();
        {
            std::lock_guard<std::mutex> g(kd.gate_mu_);
            kd.barrier_active_.store(true, std::memory_order_release);
        }
        // 排干:逐分片 加锁-放锁,任意瞬间只持 1 把——保证在途写者出清。
        for (auto& sh : kd.shards_) {
            sh.mu.lock();
            sh.mu.unlock();
        }
    }
    ~BarrierGuard() {
        {
            std::lock_guard<std::mutex> g(kd.gate_mu_);
            kd.barrier_active_.store(false, std::memory_order_release);
        }
        kd.gate_cv_.notify_all();
        kd.barrier_mu_.unlock();
    }
    BarrierGuard(const BarrierGuard&) = delete;
    BarrierGuard& operator=(const BarrierGuard&) = delete;
    BarrierGuard(BarrierGuard&&) = delete;
    BarrierGuard& operator=(BarrierGuard&&) = delete;
};

// =============================================================================
// 文件级统计 (fstats)
//
// 每个 file_id 一条 FStatsEntry，记录该 data file 的 live/total key 数和
// 字节数。put / remove 的时候增量更新，merge 触发判断和 status() 都靠它。
// expiration_epoch 用 set_pending_delete() 设：标记「等所有 < 这个 epoch
// 的 fold 都收掉之后这个文件就可以删了」——避免迭代器中途被釜底抽薪。
// =============================================================================

// 增量更新某个 file_id 的 fstats 计数。计数字段全是无符号但 caller
// 经常传负数（put 的 +live、remove 的 -live），所以这里走 int64 中转，
// 让 wrap-around 在签名整数语义下完成——这是 legacy 一直在做的把戏，
// 不要改成 saturating，否则会跟 legacy 字节级对账失败。
//
// should_create=false 时如果 file_id 不存在直接 return：set_pending_delete
// 路径要这个语义——只对已知 file_id 标记 expiration_epoch，不为不存在的
// file 凭空建一条 fstats。
void KeyDir::update_fstats(std::uint32_t file_id, std::uint32_t tstamp,
                           std::uint64_t expiration_epoch,
                           std::int32_t live_inc, std::int32_t total_inc,
                           std::int32_t live_bytes_inc,
                           std::int32_t total_bytes_inc,
                           bool should_create) {
    // M6-S1 无锁化:槽位发布 + relaxed 原子累加(wrap-around 语义经
    // int64 二补数保留,与 legacy 字节级对账一致)。锁序:fstats_grow_mu_
    // 是全序最末一把,caller 持分片锁/meta 时调用均合法。
    const std::size_t idx = file_id;
    if (idx >= fstats_size_.load(std::memory_order_acquire)) {
        if (!should_create) return;
        std::lock_guard<std::mutex> g(fstats_grow_mu_);
        while (fstats_.size() <= idx) fstats_.emplace_back();
        fstats_size_.store(fstats_.size(), std::memory_order_release);
    }
    auto& f = fstats_[idx];
    if (!f.present.load(std::memory_order_relaxed)) {
        if (!should_create) return;
        f.present.store(1, std::memory_order_relaxed);
    }
    auto add = [](std::atomic<std::uint64_t>& a, std::int32_t inc) {
        a.fetch_add(static_cast<std::uint64_t>(static_cast<std::int64_t>(inc)),
                    std::memory_order_relaxed);
    };
    add(f.live_keys, live_inc);
    add(f.total_keys, total_inc);
    add(f.live_bytes, live_bytes_inc);
    add(f.total_bytes, total_bytes_inc);

    // CAS-min:expiration_epoch 只向更早推。
    std::uint64_t cur = f.expiration_epoch.load(std::memory_order_relaxed);
    while (expiration_epoch < cur &&
           !f.expiration_epoch.compare_exchange_weak(
               cur, expiration_epoch, std::memory_order_relaxed)) {
    }
    if (tstamp != 0) {
        std::uint32_t o = f.oldest_tstamp.load(std::memory_order_relaxed);
        while ((o == 0 || tstamp < o) &&
               !f.oldest_tstamp.compare_exchange_weak(
                   o, tstamp, std::memory_order_relaxed)) {
        }
        std::uint32_t n = f.newest_tstamp.load(std::memory_order_relaxed);
        while ((n == 0 || tstamp > n) &&
               !f.newest_tstamp.compare_exchange_weak(
                   n, tstamp, std::memory_order_relaxed)) {
        }
    }
}

// 标记某 file_id「等迭代结束就可以删」。把当前 epoch_ 写到该 file 的
// expiration_epoch；后续 needs_merge 看到 expiration_epoch < newest fold
// epoch 就把这个文件标记为「safe to delete」。
// S2:完全无锁（fstats 原子路径 + epoch_ 原子读）。
void KeyDir::set_pending_delete(std::uint32_t file_id) {
    update_fstats(file_id, /*tstamp*/ 0,
                  /*expiration_epoch*/ epoch_.load(std::memory_order_relaxed),
                  0, 0, 0, 0, /*should_create*/ false);
}

// 一次性删一组 file_id 的 fstats（merge 完成后调用，回收旧统计）。
// 返回找不到的 id 数——caller 用它做日志 / 测试断言；正常路径下应该是 0。
// S2:只拿 fstats_grow_mu_（与槽位增长串行;锁全序最末,独立持有合法）。
std::uint32_t KeyDir::trim_fstats(std::span<const std::uint32_t> ids) {
    std::lock_guard<std::mutex> lock(fstats_grow_mu_);
    std::uint32_t missing = 0;
    const std::size_t n = fstats_size_.load(std::memory_order_acquire);
    for (auto id : ids) {
        if (id < n && fstats_[id].present.exchange(0, std::memory_order_relaxed)) {
            auto& f = fstats_[id];  // 清零槽位,防陈旧数据被误读
            f.live_keys.store(0, std::memory_order_relaxed);
            f.total_keys.store(0, std::memory_order_relaxed);
            f.live_bytes.store(0, std::memory_order_relaxed);
            f.total_bytes.store(0, std::memory_order_relaxed);
            f.oldest_tstamp.store(0, std::memory_order_relaxed);
            f.newest_tstamp.store(0, std::memory_order_relaxed);
            f.expiration_epoch.store(kMaxEpoch, std::memory_order_relaxed);
        } else {
            ++missing;
        }
    }
    return missing;
}

// =============================================================================
// put / get / remove
//
// 这是 keydir 的核心。put 的逻辑分支最多：
//   - 没在跑 fold (keyfolders_ == 0)：直接覆盖本分片 entries[key]，最简单
//   - 在跑 fold，且新 key 还不在 entries 里：写到 pending_（meta unique），
//     迭代器看不到
//   - 在跑 fold，且 key 已经在 entries 里：把旧 SingleEntry 升级成
//     MultiEntry，把新 revision 插到链头——迭代器仍然看到自己 epoch 的
//     那个 revision，新写入对它不可见。全程只持本分片锁。
// merge 路径走 newest_put=false 的「条件 put」：如果当前 entry 的
// (file_id, offset) 跟 caller 期望的不一致（说明 race 中被覆盖了），
// 返回 kAlreadyExists 让 merge 跳过。
// =============================================================================

// 在指定 epoch（默认 kMaxEpoch = 最新）查 key 的可见 revision。
//
// 查找顺序（S2 起,与旧实现的 pending→entries 相反,这是有意的）：
//   1. 本分片 entries（权威：已存在 key 的新版本走 sibling 链,不进 pending）
//   2. miss 且 fold 态时,**保持分片锁不放**,嵌套 meta shared 查 pending_。
//      保持分片锁是为了堵 release 合并窗口的 TOCTOU：若先放分片锁再查
//      pending,merge(pending→entries) 可能恰好在两次查找之间完成,两边
//      都 miss。屏障 v2 下论证更新:release 阶段二把某 key 应用进
//      entries 必须拿该 key 的分片锁(被本读者持有,无法插入两次查找
//      之间),且清 pending 表(阶段三)排在阶段二全部应用完成之后——
//      「先应用后清表」⟹ 持本分片锁期间该分片 key 要么已在 entries
//      命中,要么仍留在 pending 可见,无丢失窗口。
// 正确性依据：key ∈ entries ⟹ pending 不会有它的更新版本（见文件头
// 不变量）。墓碑视作「不存在」（kNotFound）。
// epoch 比较语义保留：pending entry 的 epoch <= target_epoch 才可见——
// 确保 fold 期间不会被 fold 启动后才插入的 key 干扰。
std::optional<EntryProxy> KeyDir::get(std::string_view key,
                                       std::uint64_t target_epoch) const {
    const Shard& sh = shards_[shard_for(key)];
    std::unique_lock slock(sh.mu);

    auto it = sh.entries.find(key);
    if (it != sh.entries.end()) {
        auto found = entry_at_epoch(it->second, target_epoch);
        if (!found.found || found.is_tombstone) return std::nullopt;
        return to_proxy(it->first, found.rev, /*tombstone*/ false);
    }

    // entries miss → 只有 fold 态才需要查
    // pending。锁序:分片 → meta,嵌套合法。
    if (keyfolders_.load(std::memory_order_relaxed) > 0 ||
        has_pending_.load(std::memory_order_relaxed)) {
        std::shared_lock mlock(meta_mu_);
        if (pending_.has_value()) {
            auto p = pending_->find(key);
            if (p != pending_->end() && target_epoch >= p->second.epoch) {
                const SingleEntry& s = p->second;
                if (is_pending_tombstone(s)) return std::nullopt;
                return to_proxy(p->first, s, /*tombstone*/ false);
            }
        }
    }
    return std::nullopt;
}

std::uint64_t KeyDir::get_epoch() const {
    return epoch_.load(std::memory_order_acquire);
}

std::uint64_t KeyDir::alloc_ord() {
    return next_ord_.fetch_add(1, std::memory_order_relaxed);
}

void KeyDir::advance_ord(std::uint64_t ord) {
    // CAS max:只向前推,与并发 alloc_ord 兼容。
    std::uint64_t cur = next_ord_.load(std::memory_order_relaxed);
    while (cur < ord + 1 &&
           !next_ord_.compare_exchange_weak(cur, ord + 1,
                                            std::memory_order_relaxed)) {
    }
}

// keydir 写入主入口。
//
// 大致控制流：
//   1. 先把当前 key 的「最新可见状态」找出来：本分片 entries 优先；
//      miss 且 fold 态时嵌套 meta unique 查 pending_（锁序分片→meta）
//   2. 三种情况分支处理：
//      (A) key 不存在 / 已是墓碑
//      (B) key 存在，无 fold 在跑：直接覆盖（分片内）
//      (C) key 存在，fold 在跑（keyfolders_ > 0）：升级 SingleEntry →
//          MultiEntry，把新 revision 插到链头（分片内完成,不触 meta）
//   3. 在中间合适的位置 fetch_add epoch_（分片锁内,保证「entry.epoch <
//      iter epoch ⟺ 屏障前完成」判据）
//   4. 最后维护 fstats 计数（live ++、total ++、bytes 变化）
//
// 条件 put（old_file_id != 0）来自 merge 路径：只有当前 entry 仍指向
// (old_file_id, old_offset) 才允许覆盖；不匹配返回 kAlreadyExists 让
// merger 跳过——避免跟并发 put 抢同一个 key。
PutResult KeyDir::put(std::string_view key,
                       std::uint32_t file_id, std::uint32_t total_sz,
                       std::uint64_t offset, std::uint32_t tstamp,
                       std::uint32_t now_sec,
                       bool newest_put,
                       std::uint32_t old_file_id, std::uint64_t old_offset,
                       std::uint64_t ord) {
    PutCtx ctx;
    if (auto r = put_probe(ctx, key, old_file_id); r != PutResult::kOk) return r;

    // 全局 epoch 计数器递增，作为本次写入的时间戳。分片锁内完成。
    ctx.this_epoch = epoch_.fetch_add(1, std::memory_order_relaxed) + 1;
    ctx.now_sec = now_sec;

    if (!ctx.found || ctx.current_is_tombstone) {
        return put_insert(ctx, key, file_id, total_sz, offset, tstamp,
                          newest_put, old_file_id, ord);
    }
    return put_overwrite(ctx, key, file_id, total_sz, offset, tstamp,
                         newest_put, old_file_id, old_offset, ord);
}

// ---- put 阶段 1：探测当前状态 ----
// 获取分片锁 → 屏障闸门 → 探测 entries_ 和 pending_。
// 返回 kAlreadyExists 表示条件 put 快速失败（key 不存在/墓碑 且 old_file_id != 0）。
PutResult KeyDir::put_probe(PutCtx& ctx, std::string_view key,
                             std::uint32_t old_file_id) {
    Shard& sh = shards_[shard_for(key)];
    ctx.slock = std::unique_lock<std::mutex>(sh.mu);
    ctx.shard = &sh;

    // 屏障闸门(v2):屏障期间写者退避。★ 等待前必须放分片锁——否则排干
    // 循环与我们互等。被唤醒后重新拿分片锁再查(循环兜住虚假唤醒与
    // 连续屏障)。读路径不检查闸门(屏障期间读者照常并发)。
    while (barrier_active_.load(std::memory_order_acquire)) {
        ctx.slock.unlock();
        {
            std::unique_lock<std::mutex> g(gate_mu_);
            gate_cv_.wait(g, [&] {
                return !barrier_active_.load(std::memory_order_acquire);
            });
        }
        ctx.slock.lock();
    }

    // keyfolders_ 只在屏障内变;闸门检查通过且持分片锁后 relaxed 读即
    // 足够新(论证见文件头)。
    ctx.fold_active = keyfolders_.load(std::memory_order_relaxed) > 0;

    // entries 优先（S2 不变量:key ∈ entries ⟹ pending 无其更新版本）。
    // pending 分支才需要的 meta 锁;持有期横跨本函数余下部分。
    auto it = sh.entries.find(key);
    if (it != sh.entries.end()) {
        auto at = entry_at_epoch(it->second, kMaxEpoch);
        if (at.found) {
            ctx.entries_entry = &it->second;
            ctx.current_is_tombstone = at.is_tombstone;
            ctx.current_proxy = to_proxy(it->first, at.rev, at.is_tombstone);
            ctx.found = true;
        }
    }
    if (!ctx.found && (ctx.fold_active ||
                       has_pending_.load(std::memory_order_relaxed))) {
        ctx.mlock = std::unique_lock<std::shared_mutex>(meta_mu_);  // 锁序:分片 → meta
        if (pending_.has_value()) {
            auto p = pending_->find(key);
            if (p != pending_->end() && kMaxEpoch >= p->second.epoch) {
                ctx.pending_entry = &p->second;
                ctx.current_is_tombstone = is_pending_tombstone(*ctx.pending_entry);
                ctx.current_proxy = to_proxy(p->first, *ctx.pending_entry, ctx.current_is_tombstone);
                ctx.found = true;
            }
        }
    }

    // 条件 put 但 key 不存在 / 已是墓碑：CAS 不可能成功——快速失败。
    if ((!ctx.found || ctx.current_is_tombstone) && old_file_id != 0) {
        return PutResult::kAlreadyExists;
    }
    return PutResult::kOk;
}

// ---- put 分支 (A)：key 不存在或当前是墓碑 ----
PutResult KeyDir::put_insert(PutCtx& ctx, std::string_view key,
                              std::uint32_t file_id, std::uint32_t total_sz,
                              std::uint64_t offset, std::uint32_t tstamp,
                              bool newest_put, std::uint32_t old_file_id,
                              std::uint64_t ord) {
    Shard& sh = *ctx.shard;

    // merge race 检查：newest_put 路径上如果 file_id < biggest_file_id_，
    // 说明并发 merger 已经把 file_id 推到更大的值，这次 put 是「向后」
    // 写入，必须拒绝（caller 拿到 kAlreadyExists 后会 roll_active 切到
    // 更大的 file_id 重试）。
    if ((newest_put &&
         file_id < biggest_file_id_.load(std::memory_order_relaxed)) ||
        old_file_id != 0) {
        return PutResult::kAlreadyExists;
    }

    SingleEntry s{file_id, total_sz, offset, ctx.this_epoch, tstamp, ord};

    if (ctx.pending_entry != nullptr) {
        // 之前在 pending 里是墓碑——直接覆盖成活的 entry（mlock 已持）。
        *ctx.pending_entry = s;
    } else if (ctx.entries_entry != nullptr) {
        // 在 entries_ 里是墓碑（必定是 sibling 链），插一条新 revision
        // 放到链头标记它复活了。
        // 注:旧实现这里优先查 pending_.has_value() 分流;S2 改为优先
        // 升链——维持 entries/pending 不相交不变量（entries 已有的 key
        // 绝不进 pending）。
        if (auto* multi = std::get_if<MultiEntry>(ctx.entries_entry)) {
            multi->revisions.insert(multi->revisions.begin(), s);
        } else {
            // 理论不可达——SingleEntry 不存墓碑标记。
            *ctx.entries_entry = s;
        }
    } else if (ctx.mlock.owns_lock()) {
        // fold 态新 key——分流到 pending（meta unique 已持）。
        // legacy 这里靠 kh_put_will_resize 判断是否真的要分流（rehash
        // 才会破坏迭代器），我们简化为「fold 期间一律分流」——正确性
        // 等价，pending 表略大一点点。
        if (!pending_.has_value()) {
            pending_.emplace();
            pending_start_epoch_ = ctx.this_epoch;
            pending_start_time_  = ctx.now_sec;
            pending_updated_     = 0;
            has_pending_.store(true, std::memory_order_relaxed);
        }
        pending_->insert_or_assign(std::string(key), s);
        pending_updated_ += 1;
    } else {
        // 最常见路径：没 fold、key 全新——直接进本分片 entries。
        sh.entries.insert_or_assign(std::string(key), Entry{s});
    }

    key_count_.fetch_add(1, std::memory_order_relaxed);
    key_bytes_.fetch_add(key.size(), std::memory_order_relaxed);
    if (ctx.fold_active) iter_mutation_.store(true, std::memory_order_relaxed);

    const auto sz_i32 = static_cast<std::int32_t>(total_sz);
    update_fstats(file_id, tstamp, kMaxEpoch,
                  1, 1, sz_i32, sz_i32, /*should_create*/ true);
    // CAS-max:并发 put 跨分片推进 biggest_file_id_。
    std::uint32_t big = biggest_file_id_.load(std::memory_order_relaxed);
    while (file_id > big &&
           !biggest_file_id_.compare_exchange_weak(
               big, file_id, std::memory_order_relaxed)) {
    }
    return PutResult::kOk;
}

// ---- put 分支 (B)/(C)：key 当前是活的，可能要覆盖 ----
PutResult KeyDir::put_overwrite(PutCtx& ctx, std::string_view key,
                                 std::uint32_t file_id, std::uint32_t total_sz,
                                 std::uint64_t offset, std::uint32_t tstamp,
                                 bool newest_put,
                                 std::uint32_t old_file_id, std::uint64_t old_offset,
                                 std::uint64_t ord) {
    const SingleEntry cur = SingleEntry{
        ctx.current_proxy.file_id, ctx.current_proxy.total_sz,
        ctx.current_proxy.offset, ctx.current_proxy.epoch,
        ctx.current_proxy.tstamp, ctx.current_proxy.ord};

    // 条件 put 校验：必须正好替换我们期望的 (file_id, offset)，否则失败。
    // newest_put=true 时即使 (old_file_id, old_offset) 不匹配，只要 file_id
    // 自身相同也允许（写入同一个文件的更新位置）。
    if (old_file_id != 0 &&
        (newest_put || file_id != cur.file_id) &&
        !(old_file_id == cur.file_id && old_offset == cur.offset)) {
        return PutResult::kAlreadyExists;
    }

    // 「新 entry 比旧的更新吗？」三套判断（legacy 原样保留）：
    //   - newest_put 模式：file_id >= biggest_file_id_ 即可（写入路径）
    //   - 普通模式：tstamp 严格大、file_id 大、或同 file_id 但 offset 大
    // 任一满足就接受新 entry，否则当作 stale 拒绝（CAS race 兜底）。
    const bool accept =
        (newest_put &&
         file_id >= biggest_file_id_.load(std::memory_order_relaxed)) ||
        (!newest_put && cur.tstamp < tstamp) ||
        (!newest_put && (cur.file_id < file_id ||
                          (cur.file_id == file_id && cur.offset < offset)));

    if (!accept) {
        if (!is_ready_.load(std::memory_order_relaxed)) {
            update_fstats(file_id, tstamp, kMaxEpoch,
                          0, 1, 0,
                          static_cast<std::int32_t>(total_sz),
                          /*should_create*/ true);
        }
        return PutResult::kAlreadyExists;
    }

    // fstats accounting.
    const auto sz_i32     = static_cast<std::int32_t>(total_sz);
    const auto cur_sz_i32 = static_cast<std::int32_t>(cur.total_sz);
    if (cur.file_id != file_id) {
        update_fstats(cur.file_id, /*tstamp*/ 0, kMaxEpoch,
                      -1, 0, -cur_sz_i32, 0, /*should_create*/ false);
        update_fstats(file_id, tstamp, kMaxEpoch,
                      1, 1, sz_i32, sz_i32, /*should_create*/ true);
    } else {
        update_fstats(file_id, tstamp, kMaxEpoch,
                      0, 1, sz_i32 - cur_sz_i32, sz_i32,
                      /*should_create*/ true);
    }
    if (ctx.fold_active) iter_mutation_.store(true, std::memory_order_relaxed);

    SingleEntry next{file_id, total_sz, offset, ctx.this_epoch, tstamp, ord};

    if (ctx.pending_entry != nullptr) {
        // 已经在 pending 里——直接覆盖（pending 自身就是 fold 不可见的；
        // mlock 已持）。
        *ctx.pending_entry = next;
    } else {
        assert(ctx.entries_entry != nullptr);
        if (ctx.fold_active) {
            // fold 在跑——把旧 revision 留在链里给迭代器看，新 revision
            // 插到链头。SingleEntry 自动升级成 MultiEntry。全程分片内。
            if (auto* multi = std::get_if<MultiEntry>(ctx.entries_entry)) {
                multi->revisions.insert(multi->revisions.begin(), next);
            } else {
                MultiEntry promoted;
                promoted.revisions.reserve(2);
                promoted.revisions.push_back(next);
                promoted.revisions.push_back(*std::get_if<SingleEntry>(ctx.entries_entry));
                *ctx.entries_entry = std::move(promoted);
            }
        } else {
            // 没 fold 干扰——直接覆盖（如果之前是 MultiEntry 也会被折回 SingleEntry）。
            *ctx.entries_entry = next;
        }
    }

    std::uint32_t big = biggest_file_id_.load(std::memory_order_relaxed);
    while (file_id > big &&
           !biggest_file_id_.compare_exchange_weak(
               big, file_id, std::memory_order_relaxed)) {
    }
    return PutResult::kOk;
}

// 无条件 delete。返回 true 表示原本有这条 key（fstats 已减了一次 live）；
// false 表示 key 不在 keydir 里，调用方一般也不需要管这个返回值。
//
// 存放路径（S2）：
//   - entries 命中 + 无 fold：直接 erase；
//   - entries 命中 + fold 态：升级 sibling 链插墓碑（分片内完成）。
//     注:旧实现在 pending 已冻结时对 entries 命中写 pending 墓碑;S2 改为
//     统一升链,维持 entries/pending 不相交不变量（get 的 entries 优先
//     探测顺序依赖它）。语义对迭代器等价（旧 revision 都保留）,且修复了
//     旧实现「freeze 复用的后启 fold 看不到 remove」的不一致。
//   - entries miss + pending 命中：pending 内原地改墓碑（meta unique）。
bool KeyDir::remove(std::string_view key, std::uint32_t remove_time) {
    Shard& sh = shards_[shard_for(key)];
    std::unique_lock slock(sh.mu);

    // 屏障闸门(v2):同 put——等待前必须放分片锁,唤醒后重拿再查。
    while (barrier_active_.load(std::memory_order_acquire)) {
        slock.unlock();
        {
            std::unique_lock<std::mutex> g(gate_mu_);
            gate_cv_.wait(g, [&] {
                return !barrier_active_.load(std::memory_order_acquire);
            });
        }
        slock.lock();
    }

    // 与旧实现一致:无论命中与否都消耗一个 epoch（epoch 洞无害）。
    const std::uint64_t this_epoch =
        epoch_.fetch_add(1, std::memory_order_relaxed) + 1;
    const bool fold_active = keyfolders_.load(std::memory_order_relaxed) > 0;

    auto it = sh.entries.find(key);
    if (it != sh.entries.end()) {
        auto at = entry_at_epoch(it->second, kMaxEpoch);
        if (!at.found || at.is_tombstone) return false;  // 已是墓碑/不可见
        const SingleEntry cur = at.rev;

        update_fstats(cur.file_id, cur.tstamp, kMaxEpoch,
                      -1, 0, -static_cast<std::int32_t>(cur.total_sz), 0,
                      /*should_create*/ false);
        assert(key_count_.load(std::memory_order_relaxed) > 0 &&
               "remove found a live entry but key_count_ is 0");
        key_count_.fetch_sub(1, std::memory_order_relaxed);
        key_bytes_.fetch_sub(key.size(), std::memory_order_relaxed);

        if (fold_active) {
            iter_mutation_.store(true, std::memory_order_relaxed);
            // 升 sibling 链插墓碑,旧 revision 留给迭代器。
            SingleEntry t = make_sibling_tombstone(this_epoch, remove_time);
            if (auto* multi = std::get_if<MultiEntry>(&it->second)) {
                multi->revisions.insert(multi->revisions.begin(), t);
            } else {
                MultiEntry promoted;
                promoted.revisions.reserve(2);
                promoted.revisions.push_back(t);
                promoted.revisions.push_back(*std::get_if<SingleEntry>(&it->second));
                it->second = std::move(promoted);
            }
        } else {
            // 没 fold 干扰——直接从本分片 entries 抹掉。
            sh.entries.erase(it);
        }
        return true;
    }

    // entries miss → pending（仅 fold 态）。
    // 保持分片锁不放,嵌套 meta unique（锁序分片→meta;堵 merge TOCTOU）。
    if (fold_active || has_pending_.load(std::memory_order_relaxed)) {
        std::unique_lock mlock(meta_mu_);
        if (pending_.has_value()) {
            auto p = pending_->find(key);
            if (p != pending_->end()) {
                if (is_pending_tombstone(p->second)) {
                    return false;  // 已是 pending 墓碑
                }
                const SingleEntry cur = p->second;
                update_fstats(cur.file_id, cur.tstamp, kMaxEpoch,
                              -1, 0, -static_cast<std::int32_t>(cur.total_sz), 0,
                              /*should_create*/ false);
                assert(key_count_.load(std::memory_order_relaxed) > 0 &&
                       "remove found a live entry but key_count_ is 0");
                key_count_.fetch_sub(1, std::memory_order_relaxed);
                key_bytes_.fetch_sub(key.size(), std::memory_order_relaxed);
                if (fold_active) {
                    iter_mutation_.store(true, std::memory_order_relaxed);
                }
                // pending 里有 live entry——原地改成 pending 墓碑（offset=MAX）。
                p->second.offset = kMaxOffset;
                p->second.tstamp = remove_time;
                p->second.epoch  = this_epoch;
                return true;
            }
        }
    }
    return false;
}

// CAS-style remove：只有当前 entry 的 (tstamp, file_id, offset) 完全
// 匹配才真的删；否则返回 kAlreadyExists 让 caller（一般是 merge / 内部
// 清理）跳过。key 不存在视为「已经删了」——返回 kOk。
//
// 实现：先用分片锁快速 peek 比对，匹配再释放并调 remove()。
// 屏障闸门(v2):只读 peek 阶段**不**检查闸门(读不受限,屏障期间照常
// 并发);写阶段走 remove(),其内部自带闸门检查。
PutResult KeyDir::conditional_remove(std::string_view key,
                                      std::uint32_t tstamp,
                                      std::uint32_t file_id,
                                      std::uint64_t offset,
                                      std::uint32_t remove_time) {
    {
        // 探测阶段：只读。探测顺序与 get/remove 一致:entries 优先,miss
        // 再嵌套 meta shared 查 pending（锁序分片→meta）。
        const Shard& sh = shards_[shard_for(key)];
        std::unique_lock slock(sh.mu);
        SingleEntry cur{};
        bool found = false;
        auto it = sh.entries.find(key);
        if (it != sh.entries.end()) {
            auto at = entry_at_epoch(it->second, kMaxEpoch);
            if (at.found && !at.is_tombstone) {
                cur = at.rev; found = true;
            }
        }
        if (!found && (keyfolders_.load(std::memory_order_relaxed) > 0 ||
                       has_pending_.load(std::memory_order_relaxed))) {
            std::shared_lock mlock(meta_mu_);
            if (pending_.has_value()) {
                auto p = pending_->find(key);
                if (p != pending_->end()) {
                    if (is_pending_tombstone(p->second)) {
                        return PutResult::kOk;  // 已删,not-found is success
                    }
                    cur = p->second; found = true;
                }
            }
        }
        if (!found) return PutResult::kOk;  // legacy: not-found is success
        if (cur.tstamp != tstamp || cur.file_id != file_id || cur.offset != offset) {
            return PutResult::kAlreadyExists;
        }
    }
    // TOCTOU 窗口：peek 释放锁到 remove() 重新加锁之间，entry 可能被并发
    // 写者覆盖或删除。安全性：remove() 内部重新检查 key 状态——不存在或已
    // 是墓碑则返回 false（幂等），存在则直接删除。CAS「精确删除特定版本」
    // 不保证，但 merge 语义容忍（跳过已被覆盖的条目即可）。
    // 详见 doc/concurrency-zh.md §5 conditional_remove TOCTOU 分析。
    return remove(key, remove_time) ? PutResult::kOk : PutResult::kOk;
}

// =============================================================================
// 迭代器（IterHandle 实现放在同一个 TU；析构会调 release()）
//
// start() / release() 是写者闸门屏障（BarrierGuard）冷路径：写者出清、
// 读者照常并发。start 屏障内纯读 + meta unique；release 的合并是唯一
// 屏障内写路径,按三阶段执行（见 release 注释;设计 §4 屏障 v2）。
// =============================================================================

IterHandle::~IterHandle() noexcept {
    if (iterating_) {
        try { release(); } catch (...) { /* nothrow contract */ }
    }
}

// 启动迭代。语义比较微妙：
//   1. 如果已经有别的 fold 在跑（pending_ 已建立），并且我们要求的
//      maxage/maxputs 限制 pending 还能容忍——直接复用已存在的
//      freeze（共享同一份 pending），iter_epoch_ 取最新 epoch。
//   2. pending 太老（age > maxage 或 updated > maxputs）——返回
//      kOutOfDate，让 caller 等待 pending 排空再重试。
//   3. 通过的话拍一个 keys snapshot：按分片下标序枚举所有 entries 的
//      key，copy 进 keys_snapshot_。next() 后续从这个 snapshot 走，对
//      rehash 完全免疫。
StartIterResult IterHandle::start(std::uint32_t now_sec,
                                   int maxage, int maxputs) {
    if (iterating_) return StartIterResult::kAlreadyIterating;
    // 屏障 v2:写者出清,读者照常并发。屏障内全是纯读 + meta 状态修改:
    // freeze 判定/keyfolders_++/pending 初始化在 meta unique 下做（此刻
    // 不持任何分片锁,锁序 barrier→gate→meta 无环）。
    BarrierGuard barrier(*parent_);
    std::unique_lock mlock(parent_->meta_mu_);

    // pending freeze 复用判断：现存 pending 是否仍然「足够新」给本次 fold 用。
    auto can_use_existing_freeze = [&]() -> bool {
        if (!parent_->pending_.has_value() || (maxage < 0 && maxputs < 0)) {
            return true;  // 无 pending 或两个限制都禁用——必然能用
        }
        if (now_sec == 0 || now_sec < parent_->pending_start_time_) {
            return false;  // 时钟漂移或 caller 强制要求最新 freeze
        }
        const std::uint64_t age = now_sec - parent_->pending_start_time_;
        return ((maxage < 0 || age <= static_cast<std::uint64_t>(maxage)) &&
                (maxputs < 0 || parent_->pending_updated_ <=
                                  static_cast<std::uint64_t>(maxputs)));
    };

    if (!can_use_existing_freeze()) {
        return StartIterResult::kOutOfDate;
    }

    iterating_ = true;
    iter_epoch_ = parent_->epoch_.fetch_add(1, std::memory_order_relaxed) + 1;
    parent_->newest_folder_epoch_ = iter_epoch_;
    // keyfolders_ 只在屏障内修改（此处与 release 阶段一）。
    parent_->keyfolders_.fetch_add(1, std::memory_order_relaxed);

    // 拍 key snapshot——O(n) 一次性开销，跨分片归并（按分片下标序拼接），
    // 之后对 entries 的 rehash 免疫。屏障内写者已出清,遍历各分片
    // entries **不需要分片锁**（并发的 get/next 只读,unordered_map
    // 并发只读安全;写者出清的 HB 由排干循环的 mutex 配对保证）。
    keys_snapshot_.clear();
    std::size_t total = 0;
    for (const auto& sh : parent_->shards_) total += sh.entries.size();
    keys_snapshot_.reserve(total);
    for (const auto& sh : parent_->shards_) {
        for (const auto& [k, _] : sh.entries) {
            keys_snapshot_.push_back(k);
        }
    }
    cursor_ = 0;
    return StartIterResult::kOk;
}

// 取下一项。对 cursor 指向的 key:其分片 shared → 查 entries →
// entry_at_epoch。cursor_ 是 per-handle 状态（不共享）;keys_snapshot_
// 全部来自 entries,所以这里不需要触碰 pending_（fold 期间 entries 的
// key 集只增不减——remove 走 sibling 墓碑,不 erase）。
// snapshot 期间被折叠 erase 的 key（不可能在 fold 中,防御）直接跳过。
std::optional<EntryProxy> IterHandle::next(bool include_tombstones) {
    if (!iterating_) return std::nullopt;

    while (cursor_ < keys_snapshot_.size()) {
        const std::string& k = keys_snapshot_[cursor_++];
        const auto& sh = parent_->shards_[KeyDir::shard_for(k)];
        std::unique_lock lock(sh.mu);
        auto it = sh.entries.find(k);
        if (it == sh.entries.end()) continue;  // 拍快照后被删了

        auto at = entry_at_epoch(it->second, iter_epoch_);
        if (!at.found) continue;
        if (at.is_tombstone && !include_tombstones) continue;
        return to_proxy(it->first, at.rev, /*tombstone*/ at.is_tombstone);
    }
    return std::nullopt;
}

// 结束迭代。最后一个 folder release 时触发 pending → entries 合并 +
// MultiEntry 折叠。这两步是 fold 期间「写时复制」的反向收尾。
//
// 屏障 v2 三阶段（写者已出清,唯一并发者是读者,逐阶段保证读者视角
// 无缝）:
//   阶段一[meta unique]  keyfolders_--;非最后一个 folder 直接返回;
//                        是最后一个 → 继续（**不在此清 pending**）。
//   阶段二[meta shared]  遍历 pending_ 每条,嵌套拿该 key 分片锁应用进
//                        entries（apply_pending_to_entries_barrier）。
//   阶段三[meta unique,不持分片锁]  pending_.reset()/has_pending_=false。
//   「先应用(阶段二)后清表(阶段三)」⟹ 读者在窗口内要么 entries 命中
//   （探测顺序 entries 优先）要么 pending 命中,无丢失窗口。
//   之后 MultiEntry 折叠:逐分片「lock → 折叠 → unlock」（读者按分片锁
//   协议安全;此刻 keyfolders_==0,无迭代器再看老 revision）。
void IterHandle::release() {
    if (!iterating_) return;
    BarrierGuard barrier(*parent_);
    iterating_ = false;
    iter_epoch_ = kMaxEpoch;
    keys_snapshot_.clear();
    cursor_ = 0;

    // 阶段一[meta unique]:keyfolders_--。
    {
        std::unique_lock mlock(parent_->meta_mu_);
        if (parent_->keyfolders_.fetch_sub(1, std::memory_order_relaxed) != 1) {
            return;  // 还有别的 folder——屏障由 RAII 释放。
        }
    }

    // 阶段二[meta shared]:pending → entries 应用（嵌套分片锁）。
    parent_->apply_pending_to_entries_barrier();

    // 阶段三[meta unique,不持任何分片锁]:清 pending 表 + iter 协调状态。
    {
        std::unique_lock mlock(parent_->meta_mu_);
        if (parent_->pending_.has_value()) {
            parent_->pending_.reset();
            parent_->has_pending_.store(false, std::memory_order_relaxed);
            parent_->pending_start_epoch_ = 0;
            parent_->pending_start_time_  = 0;
            parent_->pending_updated_     = 0;
        }
        parent_->iter_generation_ += 1;
        parent_->iter_mutation_.store(false, std::memory_order_relaxed);
    }

    // MultiEntry 折叠（逐分片持锁）。
    parent_->collapse_multi_entries_barrier();
}

// release 阶段二:把 fold 期间累积的 pending 表逐条应用进各分片 entries。
// 前置条件:caller 持 BarrierGuard（写者已出清）且 keyfolders_ 已归零。
//
// ⚠ 锁序例外（仅屏障内合法）:本函数在 meta **shared** 持有期间逐 key
// 嵌套该 key 的分片锁——这是 meta→shard 方向,与常规锁序（热路径
// shard→meta）相反。无环论证:
//   - 写者(put/remove,meta unique 的全部使用者)已被闸门出清:任何越过
//     闸门的写者必在排干循环前就持有分片锁,并在排干完成前整体结束
//     （含其嵌套 meta unique 段）;其余 meta unique 使用者
//     （start/release 阶段一三/save/load）被 barrier_mu_ 串行,
//     不与本阶段并发——屏障内不存在 meta unique 持有者或等待者。
//   - 唯一并发者是读者(get/conditional_remove peek),其 shard→meta
//     嵌套对 meta 只拿 **shared**;本阶段同样只拿 shared。shared-shared
//     相容且无 unique 排队者,双方的 meta 获取都不可能阻塞——无法构成
//     「持 shard 等 meta / 持 meta 等 shard」的环。
void KeyDir::apply_pending_to_entries_barrier() {
    std::shared_lock mlock(meta_mu_);
    if (!pending_.has_value()) return;

    // pending 墓碑的语义（与旧 merge_pending_and_collapse_barrier 逐字
    // 一致）：
    //   - entries 里没这个 key：什么都不做（fold 期间出现又消失的临时 key）
    //   - entries 里有：直接 erase，相当于完成最终 delete
    //     （S2 不变量下 pending∩entries=∅,该分支理论不可达,保留防御）
    // pending 活 entry 直接覆盖进 entries（unconditional——fold 期间
    // 这个 key 在 entries 里的旧 revision 已经没用了）。
    for (auto& [k, p_entry] : *pending_) {
        Shard& sh = shards_[shard_for(k)];
        std::lock_guard<std::mutex> sg(sh.mu);  // 嵌套:meta_shared → shard
        auto it = sh.entries.find(k);
        const bool is_tomb = is_pending_tombstone(p_entry);

        if (it == sh.entries.end()) {
            if (is_tomb) {
                // 临时墓碑——丢弃即可。
            } else {
                sh.entries.emplace(k, Entry{p_entry});
            }
        } else {
            if (is_tomb) {
                sh.entries.erase(it);
            } else {
                it->second = Entry{p_entry};
            }
        }
    }
}

// release 收尾:遍历所有分片,把 MultiEntry 折回 SingleEntry。
// 链头是最新 revision；如果链头本身是 sibling 墓碑，整个 entry 都消失。
// 前置条件:caller 持 BarrierGuard 且 keyfolders_==0、pending_ 已清。
// 逐分片「lock → 折叠该分片全部链 → unlock」,任意瞬间只持 1 把分片锁;
// 并发读者按分片锁协议安全（折叠前后单 key 可见值不变:链头即最新）。
void KeyDir::collapse_multi_entries_barrier() {
    for (auto& sh : shards_) {
        std::lock_guard<std::mutex> sg(sh.mu);
        for (auto it = sh.entries.begin(); it != sh.entries.end(); ) {
            if (auto* m = std::get_if<MultiEntry>(&it->second)) {
                if (m->revisions.empty() || is_sibling_tombstone(m->revisions.front())) {
                    it = sh.entries.erase(it);
                    continue;
                }
                // 关键：必须先把 front 拷出来再覆盖回 variant！直接
                // it->second = m->revisions.front() 会在赋值过程中析构 m，
                // m->revisions.front() 引用的内存就被释放——经典悬垂引用。
                const SingleEntry winner = m->revisions.front();
                it->second = winner;
            }
            ++it;
        }
    }
}

// =============================================================================
// 杂项：is_ready / file_id 计数器 / info
// =============================================================================

void KeyDir::mark_ready() {
    is_ready_.store(true, std::memory_order_release);
}

bool KeyDir::is_ready() const {
    return is_ready_.load(std::memory_order_acquire);
}

std::uint32_t KeyDir::biggest_file_id() const {
    return biggest_file_id_.load(std::memory_order_relaxed);
}

// 给新 active file / 新 merge 输出文件分配下一个 file_id。
// 单调递增是 keydir 的核心不变量——put 的 staleness 判断依赖它。
std::uint32_t KeyDir::increment_file_id() {
    return biggest_file_id_.fetch_add(1, std::memory_order_relaxed) + 1;
}

// 把计数器至少推到 conditional_id（不小于）。给两种场景：
//   1. registry 重新 acquire 时从 saved_biggest_file_id_ 恢复；
//   2. open 扫盘后发现磁盘上 max(file_id) 大于内存计数器（异常恢复），
//      需要追上来。
std::uint32_t KeyDir::increment_file_id_at_least(std::uint32_t conditional_id) {
    // CAS-max:与并发 put/increment_file_id 兼容。
    std::uint32_t cur = biggest_file_id_.load(std::memory_order_relaxed);
    while (conditional_id > cur &&
           !biggest_file_id_.compare_exchange_weak(
               cur, conditional_id, std::memory_order_relaxed)) {
    }
    return std::max(cur, conditional_id);
}

KeyDirInfo KeyDir::info() const {
    KeyDirInfo r;
    // 计数器都是 atomic,近似一致读即可（设计 §2）。
    r.key_count = key_count_.load(std::memory_order_relaxed);
    r.key_bytes = key_bytes_.load(std::memory_order_relaxed);
    r.epoch     = epoch_.load(std::memory_order_relaxed);
    {
        // iter 协调状态归 meta_mu_（独立持有合法,锁序末段）。
        std::shared_lock mlock(meta_mu_);
        r.iter_info.iter_generation = iter_generation_;
        r.iter_info.keyfolders      = keyfolders_.load(std::memory_order_relaxed);
        r.iter_info.frozen          = pending_.has_value();
        r.iter_info.pending_start_epoch =
            pending_.has_value() ? std::optional<std::uint64_t>(pending_start_epoch_)
                                   : std::nullopt;
    }
    const std::size_t fn = fstats_size_.load(std::memory_order_acquire);
    r.fstats.reserve(fn);
    for (std::size_t i = 0; i < fn; ++i) {
        const auto& f = fstats_[i];
        if (!f.present.load(std::memory_order_relaxed)) continue;
        FStatsEntry e;
        e.file_id          = static_cast<std::uint32_t>(i);
        e.live_keys        = f.live_keys.load(std::memory_order_relaxed);
        e.total_keys       = f.total_keys.load(std::memory_order_relaxed);
        e.live_bytes       = f.live_bytes.load(std::memory_order_relaxed);
        e.total_bytes      = f.total_bytes.load(std::memory_order_relaxed);
        e.oldest_tstamp    = f.oldest_tstamp.load(std::memory_order_relaxed);
        e.newest_tstamp    = f.newest_tstamp.load(std::memory_order_relaxed);
        e.expiration_epoch = f.expiration_epoch.load(std::memory_order_relaxed);
        r.fstats.push_back(e);
    }
    return r;
}

// ============================================================================
// A4:keydir 段快照(设计 doc/recovery-snapshot-design-zh.md)
// 格式:[magic "BCKS"][ver=1][payload][crc32(payload)],LE,tmp+rename。
// 磁盘格式无分片概念（重分片自由）,S2 只改内存侧的读写路径。
// ============================================================================

namespace {

constexpr std::uint32_t kSnapMagic   = 0x42434B53;  // "BCKS"
constexpr std::uint32_t kSnapVersion = 1;

void snap_put32(std::vector<std::uint8_t>& b, std::uint32_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 4);
}
void snap_put64(std::vector<std::uint8_t>& b, std::uint64_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 8);
}

struct SnapCursor {
    const std::uint8_t* p;
    const std::uint8_t* end;
    bool fail = false;
    bool need(std::size_t n) {
        if (static_cast<std::size_t>(end - p) < n) { fail = true; return false; }
        return true;
    }
    std::uint16_t u16() { std::uint16_t v = 0; if (need(2)) { std::memcpy(&v, p, 2); p += 2; } return v; }
    std::uint32_t u32() { std::uint32_t v = 0; if (need(4)) { std::memcpy(&v, p, 4); p += 4; } return v; }
    std::uint64_t u64() { std::uint64_t v = 0; if (need(8)) { std::memcpy(&v, p, 8); p += 8; } return v; }
    bool bytes(void* dst, std::size_t n) {
        if (!need(n)) return false;
        std::memcpy(dst, p, n);
        p += n;
        return true;
    }
};

}  // namespace

bool KeyDir::save_snapshot(
    std::string_view path,
    const std::vector<std::pair<std::uint32_t, std::uint64_t>>& watermarks) const {
    // 写者闸门屏障:写者静止点;keyfolders_==0 检查保持「活跃 fold 拒绝」
    // 语义（start/release 同走屏障,被 barrier_mu_ 串行,无法并发进行）。
    // 屏障内全是纯读,遍历各分片 entries 不需要分片锁;meta 状态读取
    // （keyfolders_ 检查）在屏障内拿 meta unique 做（此刻不持任何分片
    // 锁,锁序 barrier→gate→meta 无环）。
    BarrierGuard barrier(*this);
    std::unique_lock mlock(meta_mu_);
    if (keyfolders_.load(std::memory_order_relaxed) != 0) {
        return false;  // 活跃 fold:MultiEntry 可能存在,放弃
    }

    std::size_t entries_total = 0;
    for (const auto& sh : shards_) entries_total += sh.entries.size();

    std::vector<std::uint8_t> buf;
    buf.reserve(64 + entries_total * 56);
    snap_put32(buf, kSnapMagic);
    snap_put32(buf, kSnapVersion);
    const std::size_t payload_begin = buf.size();

    snap_put64(buf, next_ord_.load(std::memory_order_relaxed));
    snap_put64(buf, epoch_.load(std::memory_order_relaxed));
    snap_put32(buf, biggest_file_id_.load(std::memory_order_relaxed));
    snap_put64(buf, key_count_.load(std::memory_order_relaxed));
    snap_put64(buf, key_bytes_.load(std::memory_order_relaxed));

    const std::size_t fsz = fstats_size_.load(std::memory_order_acquire);
    std::uint32_t fstats_n = 0;
    for (std::size_t i = 0; i < fsz; ++i) {
        if (fstats_[i].present.load(std::memory_order_relaxed)) ++fstats_n;
    }
    snap_put32(buf, fstats_n);
    for (std::size_t i = 0; i < fsz; ++i) {
        const auto& f = fstats_[i];
        if (!f.present.load(std::memory_order_relaxed)) continue;
        snap_put32(buf, static_cast<std::uint32_t>(i));
        snap_put64(buf, f.live_keys.load(std::memory_order_relaxed));
        snap_put64(buf, f.total_keys.load(std::memory_order_relaxed));
        snap_put64(buf, f.live_bytes.load(std::memory_order_relaxed));
        snap_put64(buf, f.total_bytes.load(std::memory_order_relaxed));
        snap_put32(buf, f.oldest_tstamp.load(std::memory_order_relaxed));
        snap_put32(buf, f.newest_tstamp.load(std::memory_order_relaxed));
        snap_put64(buf, f.expiration_epoch.load(std::memory_order_relaxed));
    }

    snap_put32(buf, static_cast<std::uint32_t>(watermarks.size()));
    for (auto& [fid, off] : watermarks) {
        snap_put32(buf, fid);
        snap_put64(buf, off);
    }

    snap_put64(buf, entries_total);
    for (const auto& shard : shards_) {
        for (auto& [key, entry] : shard.entries) {
            const auto* se = std::get_if<SingleEntry>(&entry);
            if (se == nullptr) return false;  // 防御:不应出现(keyfolders_==0)
            if (key.size() > 0xFFFF) return false;
            const auto klen = static_cast<std::uint16_t>(key.size());
            const auto* kp = reinterpret_cast<const std::uint8_t*>(&klen);
            buf.insert(buf.end(), kp, kp + 2);
            const auto* kd = reinterpret_cast<const std::uint8_t*>(key.data());
            buf.insert(buf.end(), kd, kd + key.size());
            snap_put32(buf, se->file_id);
            snap_put32(buf, se->total_sz);
            snap_put64(buf, se->offset);
            snap_put64(buf, se->epoch);
            snap_put32(buf, se->tstamp);
            snap_put64(buf, se->ord);
        }
    }

    const std::uint32_t crc = codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + payload_begin),
        buf.size() - payload_begin));
    snap_put32(buf, crc);

    const std::string final_path(path);
    const std::string tmp_path = final_path + ".tmp";
    std::FILE* f = std::fopen(tmp_path.c_str(), "wb");
    if (!f) return false;
    const bool wrote =
        std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!wrote) {
        std::remove(tmp_path.c_str());
        return false;
    }
    if (std::rename(tmp_path.c_str(), final_path.c_str()) != 0) {
        std::remove(tmp_path.c_str());
        return false;
    }
    return true;
}

auto KeyDir::load_snapshot(std::string_view path)
    -> std::optional<std::vector<std::pair<std::uint32_t, std::uint64_t>>> {
    std::FILE* f = std::fopen(std::string(path).c_str(), "rb");
    if (!f) return std::nullopt;
    std::fseek(f, 0, SEEK_END);
    const long fsz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (fsz < 16) { std::fclose(f); return std::nullopt; }
    std::vector<std::uint8_t> buf(static_cast<std::size_t>(fsz));
    const bool rd = std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!rd) return std::nullopt;

    SnapCursor c{buf.data(), buf.data() + buf.size()};
    if (c.u32() != kSnapMagic || c.u32() != kSnapVersion) return std::nullopt;
    // CRC 覆盖 [8, size-4)。
    std::uint32_t stored_crc = 0;
    std::memcpy(&stored_crc, buf.data() + buf.size() - 4, 4);  // 未对齐安全
    const std::uint32_t crc = codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + 8), buf.size() - 12));
    if (crc != stored_crc) return std::nullopt;
    c.end -= 4;  // payload 不含尾部 CRC

    // open 期单线程,但仍走写者闸门屏障统一（防御 + TSan 友好）。
    // 内部逻辑不变:直填各分片 entries——写者已出清且 open 期无并发
    // 读者,无需分片锁。
    BarrierGuard barrier(*this);
    std::unique_lock mlock(meta_mu_);
    auto reset_all = [&] {
        for (auto& sh : shards_) sh.entries.clear();
        {
            std::lock_guard<std::mutex> g(fstats_grow_mu_);
            fstats_.clear();
            fstats_size_.store(0, std::memory_order_release);
        }
        key_count_.store(0, std::memory_order_relaxed);
        key_bytes_.store(0, std::memory_order_relaxed);
        epoch_.store(0, std::memory_order_relaxed);
        next_ord_.store(0, std::memory_order_relaxed);
        biggest_file_id_.store(0, std::memory_order_relaxed);
    };

    next_ord_.store(c.u64(), std::memory_order_relaxed);
    epoch_.store(c.u64(), std::memory_order_relaxed);
    biggest_file_id_.store(c.u32(), std::memory_order_relaxed);
    key_count_.store(c.u64(), std::memory_order_relaxed);
    key_bytes_.store(c.u64(), std::memory_order_relaxed);

    const std::uint32_t fstats_n = c.u32();
    if (c.fail || fstats_n > (1u << 24)) { reset_all(); return std::nullopt; }
    for (std::uint32_t i = 0; i < fstats_n; ++i) {
        FStatsEntry fe;
        fe.file_id          = c.u32();
        fe.live_keys        = c.u64();
        fe.total_keys       = c.u64();
        fe.live_bytes       = c.u64();
        fe.total_bytes      = c.u64();
        fe.oldest_tstamp    = c.u32();
        fe.newest_tstamp    = c.u32();
        fe.expiration_epoch = c.u64();
        if (c.fail || fe.file_id > (1u << 24)) { reset_all(); return std::nullopt; }
        {
            std::lock_guard<std::mutex> g(fstats_grow_mu_);
            while (fstats_.size() <= fe.file_id) fstats_.emplace_back();
            fstats_size_.store(fstats_.size(), std::memory_order_release);
        }
        auto& slot = fstats_[fe.file_id];
        slot.live_keys.store(fe.live_keys, std::memory_order_relaxed);
        slot.total_keys.store(fe.total_keys, std::memory_order_relaxed);
        slot.live_bytes.store(fe.live_bytes, std::memory_order_relaxed);
        slot.total_bytes.store(fe.total_bytes, std::memory_order_relaxed);
        slot.oldest_tstamp.store(fe.oldest_tstamp, std::memory_order_relaxed);
        slot.newest_tstamp.store(fe.newest_tstamp, std::memory_order_relaxed);
        slot.expiration_epoch.store(fe.expiration_epoch, std::memory_order_relaxed);
        slot.present.store(1, std::memory_order_relaxed);
    }

    const std::uint32_t wm_n = c.u32();
    if (c.fail || wm_n > (1u << 24)) { reset_all(); return std::nullopt; }
    std::vector<std::pair<std::uint32_t, std::uint64_t>> wms;
    wms.reserve(wm_n);
    for (std::uint32_t i = 0; i < wm_n; ++i) {
        const auto fid = c.u32();
        const auto off = c.u64();
        wms.emplace_back(fid, off);
    }

    const std::uint64_t entry_n = c.u64();
    if (c.fail || entry_n > (1ull << 40)) { reset_all(); return std::nullopt; }
    for (auto& sh : shards_) {
        sh.entries.reserve(static_cast<std::size_t>(entry_n) / kShards + 1);
    }
    for (std::uint64_t i = 0; i < entry_n; ++i) {
        const std::uint16_t klen = c.u16();
        std::string key(klen, '\0');
        if (!c.bytes(key.data(), klen)) { reset_all(); return std::nullopt; }
        SingleEntry se;
        se.file_id  = c.u32();
        se.total_sz = c.u32();
        se.offset   = c.u64();
        se.epoch    = c.u64();
        se.tstamp   = c.u32();
        se.ord      = c.u64();
        if (c.fail) { reset_all(); return std::nullopt; }
        // entries 按 shard_for 分发（磁盘格式无分片概念）。
        Shard& sh = shards_[shard_for(key)];
        sh.entries.emplace(std::move(key), se);
    }
    if (c.fail || c.p != c.end) { reset_all(); return std::nullopt; }
    return wms;
}

}  // namespace bitcask::keydir
