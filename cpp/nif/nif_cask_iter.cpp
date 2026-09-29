// 粗粒度 cask_* NIF — 迭代操作：fold 系列。
//
// 每个 fold / stream 一个独立 IterRef 资源，可多个并发。legacy iterator 系列
//（迭代状态挂在 CaskHandle 上、同 cask 只允许一个）6.7.0 删除：没有调用者，
// 那个槽位还是两个进程可并发改写的无同步字段。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。

#include <cstdint>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <vector>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

namespace {

// 释放迭代器资源（通用逻辑）。idempotent。
static void release_iter(std::unique_ptr<CaskIter>& iter) {
    if (iter) {
        iter->release();
        iter.reset();
    }
}

// iter->next() 的标量字段。以前这里整个拷贝一份 CaskIter::Entry（key/value
// 两个 vector）——而 key/value 早已拷成 binary term 了，fold_next 拿到后又把
// 拷贝丢掉：每条记录白付一次堆分配 + 整个 value 的 memcpy。
struct EntryMeta {
    std::uint32_t file_id = 0;
    std::uint64_t offset = 0;
    std::uint32_t total_sz = 0;
    std::uint64_t tstamp = 0;
    bool is_tombstone = false;
};

static EntryMeta meta_of(const CaskIter::Entry& e) noexcept {
    return {e.file_id, e.offset, e.total_sz, e.tstamp, e.is_tombstone};
}

// 迭代器 next 的公共逻辑：调用 iter->next()，处理错误和 EOI，
// 成功时构造 key/value 二进制 term。
// 返回 nullopt 表示错误或 EOI（调用方应直接返回 out_term）；
// 返回 EntryMeta 表示成功（key_bin/val_bin 已填充）。
static std::optional<EntryMeta> iter_next_common(
    ErlNifEnv* env,
    CaskIter* iter,
    ERL_NIF_TERM& out_term,   // 错误/EOI 时的输出 term
    ERL_NIF_TERM& key_bin,
    ERL_NIF_TERM& val_bin)
{
    auto r = iter->next();
    if (!r) {
        out_term = fault_to_term(env, r.error());
        return std::nullopt;
    }
    if (!r->has_value()) {
        out_term = atoms().done;
        return std::nullopt;
    }
    const auto& e = **r;
    key_bin = make_binary_checked(env, e.key);
    val_bin = make_binary_checked(env, e.value);
    if (!key_bin || !val_bin) {
        out_term = make_error(env, atoms().allocation_error);
        return std::nullopt;
    }
    return meta_of(e);
}

// 取 fold 迭代器句柄并锁住父 cask（shared）：期间 cask_close 进不来；父已
// close → {error, closed}（以前这里是 UAF：close 已经 delete 了 Cask）。
struct IterLock {
    CaskIterHandle* ih = nullptr;
    std::shared_lock<std::shared_mutex> lk;
};
static IterLock lock_iter(ErlNifEnv* env, ERL_NIF_TERM term, ERL_NIF_TERM& out_err) {
    auto* ih = cask_iter_handle(env, term);
    if (!ih || !ih->iter || !ih->owner) {
        out_err = enif_make_badarg(env);
        return {};
    }
    IterLock l{ih, std::shared_lock<std::shared_mutex>(ih->owner->mu)};
    if (ih->owner->closed.load(std::memory_order_acquire)) {
        out_err = make_error(env, atoms().closed);
        return {};
    }
    return l;
}

}  // namespace

// =============================================================================
// fold 系列
// =============================================================================

// 3 参版本：墓碑被 NIF 内部过滤（fold/3 + list_keys 的 legacy 行为）。
ERL_NIF_TERM nif_cask_fold_start(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    return fold_start_impl(env, h, maxage, maxputs, /*see_tombstones=*/false);
}

// 4 参版本：透传 SeeTombstones。给 bitcask:fold/6 / fold_keys/6 用。
ERL_NIF_TERM nif_cask_fold_start4(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    return fold_start_impl(env, h, maxage, maxputs, argv[3] == atoms().atom_true);
}

// 精简版：{ok, K, V} | done | {error, _}。fold/3 / list_keys 用。
ERL_NIF_TERM nif_cask_fold_next(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto il = lock_iter(env, argv[0], err);
    auto* ih = il.ih;
    if (!ih) return err;
    ERL_NIF_TERM out, key_bin, val_bin;
    auto e = iter_next_common(env, ih->iter.get(), out, key_bin, val_bin);
    if (!e) return out;
    return enif_make_tuple3(env, atoms().ok, key_bin, val_bin);
}

// 完整版：{ok, K, V, FileId, Offset, TotalSz, Tstamp, IsTomb}。
// IsTomb 标志让 SeeTombstones=true 的调用方能区分活/死 entry。
ERL_NIF_TERM nif_cask_fold_next_full(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto il = lock_iter(env, argv[0], err);
    auto* ih = il.ih;
    if (!ih) return err;
    ERL_NIF_TERM out, key_bin, val_bin;
    auto e = iter_next_common(env, ih->iter.get(), out, key_bin, val_bin);
    if (!e) return out;
    ERL_NIF_TERM tup[8] = {
        atoms().ok,
        key_bin,
        val_bin,
        enif_make_uint(env, e->file_id),
        enif_make_uint64(env, e->offset),
        enif_make_uint(env, e->total_sz),
        enif_make_uint64(env, e->tstamp),
        e->is_tombstone ? atoms().atom_true : atoms().atom_false,
    };
    return enif_make_tuple_from_array(env, tup, 8);
}

// 批量版：{ok, [{K,V}, ...]} | done | {error, _}。
// argv[0] = IterRef, argv[1] = BatchSize (int, 1..1024)
ERL_NIF_TERM nif_cask_fold_next_batch(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto il = lock_iter(env, argv[0], err);
    auto* ih = il.ih;
    if (!ih) return err;
    int batch_size = 0;
    if (!enif_get_int(env, argv[1], &batch_size) || batch_size <= 0) {
        return enif_make_badarg(env);
    }
    if (batch_size > 1024) batch_size = 1024;  // cap

    auto r = ih->iter->next_batch(static_cast<std::size_t>(batch_size));
    if (!r) return fault_to_term(env, r.error());
    if (r->empty()) return atoms().done;

    // Build list [{K,V}, ...] in reverse order (enif_make_list_cell prepends)
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = r->rbegin(); it != r->rend(); ++it) {
        ERL_NIF_TERM key_bin = make_binary_checked(env, it->key);
        ERL_NIF_TERM val_bin = make_binary_checked(env, it->value);
        if (!key_bin || !val_bin) {
            return make_error(env, atoms().allocation_error);
        }
        ERL_NIF_TERM tup = enif_make_tuple2(env, key_bin, val_bin);
        list = enif_make_list_cell(env, tup, list);
    }
    return enif_make_tuple2(env, atoms().ok, list);
}

// 只要 key 的批量版：{ok, [{K, FileId, Offset, TotalSz, Tstamp, IsTomb}, ...]}
// | done | {error, _}。fold_keys/3,6 与 list_keys 用——它们根本不看 value，以前
// 走 next_full 每条都把 value 拷成 binary 再丢掉。
// ⚠️ 引擎的 CaskIter::next() 仍然 pread 了 value（Entry 里带着；不读 value 的
//    drain_live_keys 是 Cask::parallel_scan 的私有路径）——这里省的是跨界拷贝
//    与 BEAM 堆上的垃圾，不是磁盘读。
ERL_NIF_TERM nif_cask_fold_next_keys_batch(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto il = lock_iter(env, argv[0], err);
    auto* ih = il.ih;
    if (!ih) return err;
    int batch_size = 0;
    if (!enif_get_int(env, argv[1], &batch_size) || batch_size <= 0) {
        return enif_make_badarg(env);
    }
    if (batch_size > 1024) batch_size = 1024;  // cap

    auto r = ih->iter->next_batch(static_cast<std::size_t>(batch_size));
    if (!r) return fault_to_term(env, r.error());
    if (r->empty()) return atoms().done;

    std::vector<ERL_NIF_TERM> items;
    items.reserve(r->size());
    for (const auto& e : *r) {
        ERL_NIF_TERM key_bin = make_binary_checked(env, e.key);
        if (!key_bin) return make_error(env, atoms().allocation_error);
        ERL_NIF_TERM tup[6] = {
            key_bin,
            enif_make_uint(env, e.file_id),
            enif_make_uint64(env, e.offset),
            enif_make_uint(env, e.total_sz),
            enif_make_uint64(env, e.tstamp),
            e.is_tombstone ? atoms().atom_true : atoms().atom_false,
        };
        items.push_back(enif_make_tuple_from_array(env, tup, 6));
    }
    return enif_make_tuple2(env, atoms().ok,
                            enif_make_list_from_array(env, items.data(),
                                                      static_cast<unsigned>(items.size())));
}

// fold 资源 release。idempotent。
ERL_NIF_TERM nif_cask_fold_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih) return enif_make_badarg(env);
    // release 在 close 之后也合法（CaskIter pin 着 keydir，cask.hpp 契约 1），
    // 只需别与 close 并发：持父的 shared 锁。
    std::shared_lock<std::shared_mutex> lk(ih->owner->mu);
    release_iter(ih->iter);
    return atoms().ok;
}

}  // namespace bitcask::nif
