#include "bitcask/keydir.hpp"
#include "bitcask/codec.hpp"

#include <cstdio>
#include <cstring>

#include <algorithm>
#include <cassert>
#include <shared_mutex>

namespace bitcask::keydir {

// =============================================================================
// 内部辅助函数（不做锁；caller 必须已持 keydir mutex）
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
void KeyDir::update_fstats_locked(std::uint32_t file_id, std::uint32_t tstamp,
                                   std::uint64_t expiration_epoch,
                                   std::int32_t live_inc, std::int32_t total_inc,
                                   std::int32_t live_bytes_inc,
                                   std::int32_t total_bytes_inc,
                                   bool should_create) {
    const std::size_t idx = file_id;
    const bool exists = idx < fstats_present_.size() && fstats_present_[idx];
    if (!exists) {
        if (!should_create) return;
        if (idx >= fstats_.size()) {
            fstats_.resize(idx + 1);
            fstats_present_.resize(idx + 1, 0);
        }
        FStatsEntry e;
        e.file_id          = file_id;
        e.expiration_epoch = kMaxEpoch;
        fstats_[idx]         = e;
        fstats_present_[idx] = 1;
    }
    auto& f = fstats_[idx];
    f.live_keys = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.live_keys) + live_inc);
    f.total_keys = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.total_keys) + total_inc);
    f.live_bytes = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.live_bytes) + live_bytes_inc);
    f.total_bytes = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(f.total_bytes) + total_bytes_inc);

    if (expiration_epoch < f.expiration_epoch) {
        f.expiration_epoch = expiration_epoch;
    }
    if ((tstamp != 0 && tstamp < f.oldest_tstamp) || f.oldest_tstamp == 0) {
        f.oldest_tstamp = tstamp;
    }
    if ((tstamp != 0 && tstamp > f.newest_tstamp) || f.newest_tstamp == 0) {
        f.newest_tstamp = tstamp;
    }
}

// 标记某 file_id「等迭代结束就可以删」。把当前 epoch_ 写到该 file 的
// expiration_epoch；后续 needs_merge 看到 expiration_epoch < newest fold
// epoch 就把这个文件标记为「safe to delete」。
void KeyDir::set_pending_delete(std::uint32_t file_id) {
    std::unique_lock lock(mutex_);
    update_fstats_locked(file_id, /*tstamp*/ 0,
                         /*expiration_epoch*/ epoch_,
                         0, 0, 0, 0, /*should_create*/ false);
}

// 一次性删一组 file_id 的 fstats（merge 完成后调用，回收旧统计）。
// 返回找不到的 id 数——caller 用它做日志 / 测试断言；正常路径下应该是 0。
std::uint32_t KeyDir::trim_fstats(std::span<const std::uint32_t> ids) {
    std::unique_lock lock(mutex_);
    std::uint32_t missing = 0;
    for (auto id : ids) {
        if (id < fstats_present_.size() && fstats_present_[id]) {
            fstats_present_[id] = 0;
            fstats_[id] = FStatsEntry{};  // 清零槽位,防陈旧数据被误读
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
//   - 没在跑 fold (keyfolders_ == 0)：直接覆盖 entries_[key]，最简单
//   - 在跑 fold，且新 key 还不在 entries_ 里：写到 pending_，迭代器看不到
//   - 在跑 fold，且 key 已经在 entries_ 里：把旧 SingleEntry 升级成
//     MultiEntry，把新 revision 插到链头——迭代器仍然看到自己 epoch 的
//     那个 revision，新写入对它不可见
// merge 路径走 newest_put=false 的「条件 put」：如果当前 entry 的
// (file_id, offset) 跟 caller 期望的不一致（说明 race 中被覆盖了），
// 返回 kAlreadyExists 让 merge 跳过。
// =============================================================================

// 在指定 epoch（默认 kMaxEpoch = 最新）查 key 的可见 revision。
//
// 查找顺序：
//   1. pending_ 表（fold 期间新写入的 key 都在这里）
//   2. entries_ 主表（可能是 SingleEntry 或 sibling 链 MultiEntry）
// 任一处找到就返回；墓碑视作「不存在」（kNotFound）。
//
// 对应 legacy 的 find_keydir_entry 规则；epoch 比较语义保留：
// pending entry 的 epoch <= target_epoch 才可见——确保 fold 期间不会
// 被 fold 启动后才插入的 key 干扰。
std::optional<EntryProxy> KeyDir::get(std::string_view key,
                                       std::uint64_t target_epoch) const {
    std::shared_lock lock(mutex_);

    if (pending_.has_value()) {
        auto p = pending_->find(key);
        if (p != pending_->end() && target_epoch >= p->second.epoch) {
            const SingleEntry& s = p->second;
            const bool tomb = is_pending_tombstone(s);
            if (tomb) return std::nullopt;
            return to_proxy(p->first, s, /*tombstone*/ false);
        }
    }

    auto it = entries_.find(key);
    if (it == entries_.end()) return std::nullopt;

    auto found = entry_at_epoch(it->second, target_epoch);
    if (!found.found || found.is_tombstone) return std::nullopt;
    return to_proxy(it->first, found.rev, /*tombstone*/ false);
}

std::uint64_t KeyDir::get_epoch() const {
    std::shared_lock lock(mutex_);
    return epoch_;
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
//   1. 先把当前 key 在 pending_ + entries_ 里的「最新可见状态」找出来
//   2. 三种情况分支处理：
//      (A) key 不存在 / 已是墓碑
//      (B) key 存在，无 fold 在跑：直接覆盖
//      (C) key 存在，fold 在跑（keyfolders_ > 0）：升级 SingleEntry →
//          MultiEntry，把新 revision 插到链头
//   3. 在中间合适的位置 +1 epoch；这是 keydir 的全局逻辑时钟，
//      用于 (a) 给新 entry 标记写入时刻，(b) iter 启动时拍快照
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
    std::unique_lock lock(mutex_);

    // ---- 阶段 1：探测当前状态 ----
    // pending 优先，entries 次之；epoch 用 kMaxEpoch 拿最新可见 revision。
    // 跟 legacy find_keydir_entry 的查找顺序保持一致。
    SingleEntry* pending_entry = nullptr;
    Entry* entries_entry = nullptr;
    EntryProxy current_proxy{};
    bool found = false;
    bool current_is_tombstone = false;

    if (pending_.has_value()) {
        auto p = pending_->find(key);
        if (p != pending_->end() && kMaxEpoch >= p->second.epoch) {
            pending_entry = &p->second;
            current_is_tombstone = is_pending_tombstone(*pending_entry);
            current_proxy = to_proxy(p->first, *pending_entry, current_is_tombstone);
            found = true;
        }
    }
    if (!found) {
        auto it = entries_.find(key);
        if (it != entries_.end()) {
            auto at = entry_at_epoch(it->second, kMaxEpoch);
            if (at.found) {
                entries_entry = &it->second;
                current_is_tombstone = at.is_tombstone;
                current_proxy = to_proxy(it->first, at.rev, at.is_tombstone);
                found = true;
            }
        }
    }

    // 条件 put 但 key 不存在 / 已是墓碑：CAS 不可能成功——快速失败。
    if ((!found || current_is_tombstone) && old_file_id != 0) {
        return PutResult::kAlreadyExists;
    }

    // 全局 epoch 计数器递增，作为本次写入的时间戳。
    epoch_ += 1;
    const std::uint64_t this_epoch = epoch_;

    // ---- 分支 (A)：key 不存在或当前是墓碑 ----
    if (!found || current_is_tombstone) {
        // merge race 检查：newest_put 路径上如果 file_id < biggest_file_id_，
        // 说明并发 merger 已经把 file_id 推到更大的值，这次 put 是「向后」
        // 写入，必须拒绝（caller 拿到 kAlreadyExists 后会 roll_active 切到
        // 更大的 file_id 重试）。
        if ((newest_put && file_id < biggest_file_id_) || old_file_id != 0) {
            return PutResult::kAlreadyExists;
        }

        SingleEntry s{file_id, total_sz, offset, this_epoch, tstamp, ord};

        if (pending_entry != nullptr) {
            // 之前在 pending 里是墓碑——直接覆盖成活的 entry。
            *pending_entry = s;
        } else if (pending_.has_value()) {
            // 已经 frozen 但这个 key 哪里都没——插入 pending。
            pending_->insert_or_assign(std::string(key), s);
            pending_updated_ += 1;
        } else if (entries_entry != nullptr) {
            // 在 entries_ 里是墓碑（必定是 sibling 链），插一条新 revision
            // 放到链头标记它复活了。
            if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
                multi->revisions.insert(multi->revisions.begin(), s);
            } else {
                // 理论不可达——SingleEntry 不存墓碑标记。
                *entries_entry = s;
            }
        } else if (keyfolders_ > 0) {
            // fold 期间第一次写入新 key——freeze 并把写入分流到 pending。
            // legacy 这里靠 kh_put_will_resize 判断是否真的要分流（rehash
            // 才会破坏迭代器），我们简化为「fold 期间一律分流」——正确性
            // 等价，pending 表略大一点点。
            pending_.emplace();
            pending_start_epoch_ = this_epoch;
            pending_start_time_  = now_sec;
            pending_updated_     = 0;
            pending_->insert_or_assign(std::string(key), s);
            pending_updated_ += 1;
        } else {
            // 最常见路径：没 fold、key 全新——直接进 entries_。
            entries_.insert_or_assign(std::string(key), Entry{s});
        }

        key_count_ += 1;
        key_bytes_ += key.size();
        if (keyfolders_ > 0) iter_mutation_ = true;

        const auto sz_i32 = static_cast<std::int32_t>(total_sz);
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             1, 1, sz_i32, sz_i32, /*should_create*/ true);
        if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
        return PutResult::kOk;
    }

    // ---- 分支 (B)/(C)：key 当前是活的，可能要覆盖 ----
    const SingleEntry cur = SingleEntry{
        current_proxy.file_id, current_proxy.total_sz,
        current_proxy.offset, current_proxy.epoch,
        current_proxy.tstamp, current_proxy.ord};

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
        (newest_put && file_id >= biggest_file_id_) ||
        (!newest_put && cur.tstamp < tstamp) ||
        (!newest_put && (cur.file_id < file_id ||
                          (cur.file_id == file_id && cur.offset < offset)));

    if (!accept) {
        if (!is_ready_) {
            update_fstats_locked(file_id, tstamp, kMaxEpoch,
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
        update_fstats_locked(cur.file_id, /*tstamp*/ 0, kMaxEpoch,
                             -1, 0, -cur_sz_i32, 0, /*should_create*/ false);
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             1, 1, sz_i32, sz_i32, /*should_create*/ true);
    } else {
        update_fstats_locked(file_id, tstamp, kMaxEpoch,
                             0, 1, sz_i32 - cur_sz_i32, sz_i32,
                             /*should_create*/ true);
    }
    if (keyfolders_ > 0) iter_mutation_ = true;

    SingleEntry next{file_id, total_sz, offset, this_epoch, tstamp, ord};

    if (pending_entry != nullptr) {
        // 已经在 pending 里——直接覆盖（pending 自身就是 fold 不可见的）。
        *pending_entry = next;
    } else {
        assert(entries_entry != nullptr);
        if (keyfolders_ > 0) {
            // fold 在跑——把旧 revision 留在链里给迭代器看，新 revision
            // 插到链头。SingleEntry 自动升级成 MultiEntry。
            if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
                multi->revisions.insert(multi->revisions.begin(), next);
            } else {
                MultiEntry promoted;
                promoted.revisions.reserve(2);
                promoted.revisions.push_back(next);
                promoted.revisions.push_back(*std::get_if<SingleEntry>(entries_entry));
                *entries_entry = std::move(promoted);
            }
        } else {
            // 没 fold 干扰——直接覆盖（如果之前是 MultiEntry 也会被折回 SingleEntry）。
            *entries_entry = next;
        }
    }

    if (file_id > biggest_file_id_) biggest_file_id_ = file_id;
    return PutResult::kOk;
}

// 无条件 delete。返回 true 表示原本有这条 key（fstats 已减了一次 live）；
// false 表示 key 不在 keydir 里，调用方一般也不需要管这个返回值。
//
// 跟 put 一样有三种存放路径：直接 erase / 升级 sibling 链 / 写 pending tomb。
bool KeyDir::remove(std::string_view key, std::uint32_t remove_time) {
    std::unique_lock lock(mutex_);

    epoch_ += 1;
    const std::uint64_t this_epoch = epoch_;

    SingleEntry* pending_entry = nullptr;
    Entry* entries_entry = nullptr;
    SingleEntry cur{};
    bool found = false;

    // 跟 legacy find_keydir_entry 完全一致：pending 永远 shadow entries。
    // 即使 pending 里的是墓碑也不再去查 entries——否则 fold 期间被覆盖到
    // entries 里的「旧 live revision」会被 remove 当成「活的」再减一次
    // key_count_，造成 double-decrement bug。
    if (pending_.has_value()) {
        auto p = pending_->find(key);
        if (p != pending_->end()) {
            if (is_pending_tombstone(p->second)) {
                return false;  // shadowed by pending tomb
            }
            pending_entry = &p->second;
            cur = p->second;
            found = true;
        }
    }
    if (!found) {
        auto it = entries_.find(key);
        if (it != entries_.end()) {
            auto at = entry_at_epoch(it->second, kMaxEpoch);
            if (at.found && !at.is_tombstone) {
                entries_entry = &it->second;
                cur = at.rev;
                found = true;
            }
        }
    }
    if (!found) return false;

    update_fstats_locked(cur.file_id, cur.tstamp, kMaxEpoch,
                         -1, 0, -static_cast<std::int32_t>(cur.total_sz), 0,
                         /*should_create*/ false);
    assert(key_count_ > 0 && "remove found a live entry but key_count_ is 0");
    key_count_ -= 1;
    key_bytes_ -= key.size();
    if (keyfolders_ > 0) iter_mutation_ = true;

    if (pending_entry != nullptr) {
        // pending 里有 live entry——原地改成 pending 墓碑（offset = MAX）。
        pending_entry->offset = kMaxOffset;
        pending_entry->tstamp = remove_time;
        pending_entry->epoch  = this_epoch;
    } else if (pending_.has_value()) {
        // 已 frozen 但 entry 只在 entries_ 里——分流写一条 pending 墓碑。
        SingleEntry t{cur.file_id, cur.total_sz, kMaxOffset, this_epoch, remove_time, 0};
        pending_->insert_or_assign(std::string(key), t);
        pending_updated_ += 1;
    } else if (keyfolders_ == 0) {
        // 没 fold 干扰——直接从 entries_ 抹掉。
        auto it = entries_.find(key);
        if (it != entries_.end()) entries_.erase(it);
    } else {
        // 有 fold 但还没建 pending——往 entries 里插一条 sibling 墓碑
        // （file_id/total_sz/offset 都是 MAX 的 sentinel revision），
        // 把 SingleEntry 升级成 MultiEntry。
        assert(entries_entry != nullptr);
        SingleEntry t = make_sibling_tombstone(this_epoch, remove_time);
        if (auto* multi = std::get_if<MultiEntry>(entries_entry)) {
            multi->revisions.insert(multi->revisions.begin(), t);
        } else {
            MultiEntry promoted;
            promoted.revisions.reserve(2);
            promoted.revisions.push_back(t);
            promoted.revisions.push_back(*std::get_if<SingleEntry>(entries_entry));
            *entries_entry = std::move(promoted);
        }
    }
    return true;
}

// CAS-style remove：只有当前 entry 的 (tstamp, file_id, offset) 完全
// 匹配才真的删；否则返回 kAlreadyExists 让 caller（一般是 merge / 内部
// 清理）跳过。key 不存在视为「已经删了」——返回 kOk。
//
// 实现：先用 shared_lock 快速 peek 比对，匹配再 release shared_lock 升级
// 成 unique_lock 真正调 remove。这样不匹配的常见路径无需独占锁。
PutResult KeyDir::conditional_remove(std::string_view key,
                                      std::uint32_t tstamp,
                                      std::uint32_t file_id,
                                      std::uint64_t offset,
                                      std::uint32_t remove_time) {
    {
        // 探测阶段：只读，避免没必要时占独占锁。
        // 用跟 remove() 完全一样的 shadow 规则：pending 优先，pending 里有
        // 墓碑就视为「key 已被 shadow 不存在」直接成功。
        std::shared_lock lock(mutex_);
        SingleEntry cur{};
        bool found = false;
        if (pending_.has_value()) {
            auto p = pending_->find(key);
            if (p != pending_->end()) {
                if (is_pending_tombstone(p->second)) {
                    return PutResult::kOk;  // shadowed; not-found is success
                }
                cur = p->second; found = true;
            }
        }
        if (!found) {
            auto it = entries_.find(key);
            if (it != entries_.end()) {
                auto at = entry_at_epoch(it->second, kMaxEpoch);
                if (at.found && !at.is_tombstone) {
                    cur = at.rev; found = true;
                }
            }
        }
        if (!found) return PutResult::kOk;  // legacy: not-found is success
        if (cur.tstamp != tstamp || cur.file_id != file_id || cur.offset != offset) {
            return PutResult::kAlreadyExists;
        }
    }
    // Match — fall through to the same logic as remove().
    return remove(key, remove_time) ? PutResult::kOk : PutResult::kOk;
}

// =============================================================================
// 迭代器（IterHandle 实现放在同一个 TU；析构会调 release()）
//
// start() 做的关键事：
//   1. 拿全部 entries_ 的 key 列表（snapshot）；
//   2. 记录当前 epoch 作为 iter_epoch_，next() 用它过滤 revision；
//   3. keyfolders_ ++；如果是第一个 folder，建立 pending_ map 接管新写入。
// release() 做反向：keyfolders_ --；如果归零就把 pending_ merge 回 entries_
// 并把全部 MultiEntry 折回 SingleEntry。
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
//   3. 通过的话拍一个 keys snapshot：枚举当前所有 entries_ 的 key，
//      copy 进 keys_snapshot_。next() 后续从这个 snapshot 走，对
//      rehash 完全免疫。
//
// 性能优化（key 直接 copy 一份）是 M5 之后的事——M5 阶段先求正确性。
StartIterResult IterHandle::start(std::uint32_t now_sec,
                                   int maxage, int maxputs) {
    if (iterating_) return StartIterResult::kAlreadyIterating;
    std::unique_lock lock(parent_->mutex_);

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

    parent_->epoch_ += 1;
    iterating_ = true;
    iter_epoch_ = parent_->epoch_;
    parent_->newest_folder_epoch_ = iter_epoch_;
    parent_->keyfolders_ += 1;

    // 拍 key snapshot——O(n) 一次性开销，之后对 entries_ 的 rehash 免疫。
    keys_snapshot_.clear();
    keys_snapshot_.reserve(parent_->entries_.size());
    for (const auto& [k, _] : parent_->entries_) {
        keys_snapshot_.push_back(k);
    }
    cursor_ = 0;
    return StartIterResult::kOk;
}

// 取下一项。读锁就够：cursor_ 是 per-handle 状态（不共享），entries_/
// pending_ 在这里只读不改。snapshot 期间被 erase 的 key 直接跳过。
std::optional<EntryProxy> IterHandle::next(bool include_tombstones) {
    if (!iterating_) return std::nullopt;
    std::shared_lock lock(parent_->mutex_);

    while (cursor_ < keys_snapshot_.size()) {
        const std::string& k = keys_snapshot_[cursor_++];
        auto it = parent_->entries_.find(k);
        if (it == parent_->entries_.end()) continue;  // 拍快照后被删了

        auto at = entry_at_epoch(it->second, iter_epoch_);
        if (!at.found) continue;
        if (at.is_tombstone && !include_tombstones) continue;
        return to_proxy(it->first, at.rev, /*tombstone*/ at.is_tombstone);
    }
    return std::nullopt;
}

// 结束迭代。最后一个 folder release 时触发 pending → entries 合并 +
// MultiEntry 折叠。这两步是 fold 期间「写时复制」的反向收尾。
void IterHandle::release() {
    if (!iterating_) return;
    std::unique_lock lock(parent_->mutex_);
    iterating_ = false;
    iter_epoch_ = kMaxEpoch;
    keys_snapshot_.clear();
    cursor_ = 0;

    parent_->keyfolders_ -= 1;
    if (parent_->keyfolders_ == 0) {
        parent_->merge_pending_and_collapse_locked();
        parent_->iter_generation_ += 1;
        parent_->iter_mutation_ = false;
    }
}

// 把 fold 期间累积的 pending 表 merge 回 entries_，并把所有 sibling 链
// 折回 SingleEntry。前置条件：caller 持 unique_lock(mutex_)，且 keyfolders_
// 已经归零（即不会再有迭代器看老 revision）。
void KeyDir::merge_pending_and_collapse_locked() {
    if (pending_.has_value()) {
        // 第 1 步：把 pending 里的 entry 合并回 entries_。
        // pending 墓碑的语义：
        //   - entries 里没这个 key：什么都不做（fold 期间出现又消失的临时 key）
        //   - entries 里有：直接 erase，相当于完成最终 delete
        // pending 活 entry 直接覆盖进 entries（unconditional——fold 期间
        // 这个 key 在 entries 里的旧 revision 已经没用了）。
        for (auto& [k, p_entry] : *pending_) {
            auto it = entries_.find(k);
            const bool is_tomb = is_pending_tombstone(p_entry);

            if (it == entries_.end()) {
                if (is_tomb) {
                    // 临时墓碑——丢弃即可。
                } else {
                    entries_.emplace(k, Entry{p_entry});
                }
            } else {
                if (is_tomb) {
                    entries_.erase(it);
                } else {
                    it->second = Entry{p_entry};
                }
            }
        }
        pending_.reset();
        pending_start_epoch_ = 0;
        pending_start_time_  = 0;
        pending_updated_     = 0;
    }

    // 第 2 步：把所有 MultiEntry 折回 SingleEntry。
    // 链头是最新 revision；如果链头本身是 sibling 墓碑，整个 entry 都消失。
    for (auto it = entries_.begin(); it != entries_.end(); ) {
        if (auto* m = std::get_if<MultiEntry>(&it->second)) {
            if (m->revisions.empty() || is_sibling_tombstone(m->revisions.front())) {
                it = entries_.erase(it);
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

// =============================================================================
// 杂项：is_ready / file_id 计数器 / info / deep_copy
// =============================================================================

void KeyDir::mark_ready() {
    std::unique_lock lock(mutex_);
    is_ready_ = true;
}

bool KeyDir::is_ready() const {
    std::shared_lock lock(mutex_);
    return is_ready_;
}

std::uint32_t KeyDir::biggest_file_id() const {
    std::shared_lock lock(mutex_);
    return biggest_file_id_;
}

// 给新 active file / 新 merge 输出文件分配下一个 file_id。
// 单调递增是 keydir 的核心不变量——put 的 staleness 判断依赖它。
std::uint32_t KeyDir::increment_file_id() {
    std::unique_lock lock(mutex_);
    biggest_file_id_ += 1;
    return biggest_file_id_;
}

// 把计数器至少推到 conditional_id（不小于）。给两种场景：
//   1. registry 重新 acquire 时从 saved_biggest_file_id_ 恢复；
//   2. open 扫盘后发现磁盘上 max(file_id) 大于内存计数器（异常恢复），
//      需要追上来。
std::uint32_t KeyDir::increment_file_id_at_least(std::uint32_t conditional_id) {
    std::unique_lock lock(mutex_);
    if (conditional_id > biggest_file_id_) biggest_file_id_ = conditional_id;
    return biggest_file_id_;
}

KeyDirInfo KeyDir::info() const {
    std::shared_lock lock(mutex_);
    KeyDirInfo r;
    r.key_count = key_count_;
    r.key_bytes = key_bytes_;
    r.epoch     = epoch_;
    r.iter_info.iter_generation = iter_generation_;
    r.iter_info.keyfolders      = keyfolders_;
    r.iter_info.frozen          = pending_.has_value();
    r.iter_info.pending_start_epoch =
        pending_.has_value() ? std::optional<std::uint64_t>(pending_start_epoch_)
                               : std::nullopt;
    r.fstats.reserve(fstats_.size());
    for (std::size_t i = 0; i < fstats_.size(); ++i) {
        if (fstats_present_[i]) r.fstats.push_back(fstats_[i]);
    }
    return r;
}

// 全量深拷贝。给 legacy keydir_copy NIF 用（M6 之后不再 export 给 Erlang，
// 但 cask 内部某些 merge 路径仍可能用类似的快照）。
// 拷贝出来的 keydir keyfolders_ 强制清零——副本是「干净的全新 keydir」，
// 不继承任何活跃 fold 状态，直接可以独立使用。
std::shared_ptr<KeyDir> KeyDir::deep_copy() const {
    auto copy = std::make_shared<KeyDir>();
    std::shared_lock lock(mutex_);
    copy->entries_         = entries_;
    copy->pending_         = pending_;
    copy->fstats_          = fstats_;
    copy->fstats_present_  = fstats_present_;
    copy->key_count_       = key_count_;
    copy->key_bytes_       = key_bytes_;
    copy->epoch_           = epoch_;
    copy->next_ord_.store(next_ord_.load(std::memory_order_relaxed),
                          std::memory_order_relaxed);
    copy->biggest_file_id_ = biggest_file_id_;
    copy->is_ready_        = is_ready_;
    copy->iter_generation_ = iter_generation_;
    copy->keyfolders_      = 0;  // 副本不继承 fold 状态
    copy->newest_folder_epoch_ = 0;
    copy->iter_mutation_   = false;
    copy->pending_start_epoch_ = pending_start_epoch_;
    copy->pending_start_time_  = pending_start_time_;
    copy->pending_updated_     = pending_updated_;
    return copy;
}


// ============================================================================
// A4:keydir 段快照(设计 doc/recovery-snapshot-design-zh.md)
// 格式:[magic "BCKS"][ver=1][payload][crc32(payload)],LE,tmp+rename。
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
    std::unique_lock lock(mutex_);
    if (keyfolders_ != 0) return false;  // 活跃 fold:MultiEntry 可能存在,放弃

    std::vector<std::uint8_t> buf;
    buf.reserve(64 + entries_.size() * 56);
    snap_put32(buf, kSnapMagic);
    snap_put32(buf, kSnapVersion);
    const std::size_t payload_begin = buf.size();

    snap_put64(buf, next_ord_.load(std::memory_order_relaxed));
    snap_put64(buf, epoch_);
    snap_put32(buf, biggest_file_id_);
    snap_put64(buf, key_count_);
    snap_put64(buf, key_bytes_);

    std::uint32_t fstats_n = 0;
    for (std::size_t i = 0; i < fstats_.size(); ++i) {
        if (fstats_present_[i]) ++fstats_n;
    }
    snap_put32(buf, fstats_n);
    for (std::size_t i = 0; i < fstats_.size(); ++i) {
        if (!fstats_present_[i]) continue;
        const auto& f = fstats_[i];
        snap_put32(buf, f.file_id);
        snap_put64(buf, f.live_keys);
        snap_put64(buf, f.total_keys);
        snap_put64(buf, f.live_bytes);
        snap_put64(buf, f.total_bytes);
        snap_put32(buf, f.oldest_tstamp);
        snap_put32(buf, f.newest_tstamp);
        snap_put64(buf, f.expiration_epoch);
    }

    snap_put32(buf, static_cast<std::uint32_t>(watermarks.size()));
    for (auto& [fid, off] : watermarks) {
        snap_put32(buf, fid);
        snap_put64(buf, off);
    }

    snap_put64(buf, entries_.size());
    for (auto& [key, entry] : entries_) {
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

    std::unique_lock lock(mutex_);
    auto reset_all = [&] {
        entries_.clear();
        fstats_.clear();
        fstats_present_.clear();
        key_count_ = 0;
        key_bytes_ = 0;
        epoch_ = 0;
        next_ord_.store(0, std::memory_order_relaxed);
        biggest_file_id_ = 0;
    };

    next_ord_.store(c.u64(), std::memory_order_relaxed);
    epoch_ = c.u64();
    biggest_file_id_ = c.u32();
    key_count_ = c.u64();
    key_bytes_ = c.u64();

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
        if (fe.file_id >= fstats_.size()) {
            fstats_.resize(fe.file_id + 1);
            fstats_present_.resize(fe.file_id + 1, 0);
        }
        fstats_[fe.file_id] = fe;
        fstats_present_[fe.file_id] = 1;
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
    entries_.reserve(static_cast<std::size_t>(entry_n));
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
        entries_.emplace(std::move(key), se);
    }
    if (c.fail || c.p != c.end) { reset_all(); return std::nullopt; }
    return wms;
}

}  // namespace bitcask::keydir
