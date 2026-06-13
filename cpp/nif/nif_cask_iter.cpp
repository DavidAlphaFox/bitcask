// 粗粒度 cask_* NIF — 迭代操作：fold 系列 + iterator 系列。
//
// 两条迭代链路：
//   fold 系列：独立 IterRef 资源，可多个并发（每个 fold/3 / fold/6 一个）。
//   iterator 系列：迭代状态挂在 CaskHandle 上，同 cask 同时只允许一个。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。

#include <optional>

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

// 迭代器 next 的公共逻辑：调用 iter->next()，处理错误和 EOI，
// 成功时构造 key/value 二进制 term。
// 返回 nullopt 表示错误或 EOI（调用方应直接返回 out_term）；
// 返回 Entry（值）表示成功（key_bin/val_bin 已填充）。
//
// 注意：返回值是 Entry 的拷贝，不是指向 iter->next() 内部临时量的指针——
// 后者在本函数返回后即析构，会留下悬空引用。调用方读取 file_id/offset 等
// 标量字段时必须用这个拷贝。
static std::optional<CaskIter::Entry> iter_next_common(
    ErlNifEnv* env,
    CaskIter* iter,
    ERL_NIF_TERM eoi_term,    // EOI 时返回的 term（done 或 not_found）
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
        out_term = eoi_term;
        return std::nullopt;
    }
    const auto& e = **r;
    key_bin = make_binary_checked(env, e.key);
    val_bin = make_binary_checked(env, e.value);
    if (!key_bin || !val_bin) {
        out_term = make_error(env, atoms().allocation_error);
        return std::nullopt;
    }
    return e;  // 拷贝出 Entry，使其生命周期独立于局部 r
}

}  // namespace

// =============================================================================
// fold 系列
// =============================================================================

// 3 参版本：墓碑被 NIF 内部过滤（fold/3 + list_keys 的 legacy 行为）。
ERL_NIF_TERM nif_cask_fold_start(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
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
    auto* h = cask_handle(env, argv[0]);
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
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih || !ih->iter) return enif_make_badarg(env);
    ERL_NIF_TERM out, key_bin, val_bin;
    auto e = iter_next_common(env, ih->iter.get(), atoms().done, out, key_bin, val_bin);
    if (!e) return out;
    return enif_make_tuple3(env, atoms().ok, key_bin, val_bin);
}

// 完整版：{ok, K, V, FileId, Offset, TotalSz, Tstamp, IsTomb}。
// IsTomb 标志让 SeeTombstones=true 的调用方能区分活/死 entry。
ERL_NIF_TERM nif_cask_fold_next_full(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih || !ih->iter) return enif_make_badarg(env);
    ERL_NIF_TERM out, key_bin, val_bin;
    auto e = iter_next_common(env, ih->iter.get(), atoms().done, out, key_bin, val_bin);
    if (!e) return out;
    ERL_NIF_TERM tup[8] = {
        atoms().ok,
        key_bin,
        val_bin,
        enif_make_uint(env, e->file_id),
        enif_make_uint64(env, e->offset),
        enif_make_uint(env, e->total_sz),
        enif_make_uint(env, e->tstamp),
        e->is_tombstone ? atoms().atom_true : atoms().atom_false,
    };
    return enif_make_tuple_from_array(env, tup, 8);
}

// 批量版：{ok, [{K,V}, ...]} | done | {error, _}。
// argv[0] = IterRef, argv[1] = BatchSize (int, 1..1024)
ERL_NIF_TERM nif_cask_fold_next_batch(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    int batch_size = 0;
    if (!ih || !ih->iter || !enif_get_int(env, argv[1], &batch_size) || batch_size <= 0) {
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

// fold 资源 release。idempotent。
ERL_NIF_TERM nif_cask_fold_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih) return enif_make_badarg(env);
    release_iter(ih->iter);
    return atoms().ok;
}

// =============================================================================
// iterator 系列（状态化迭代器，挂在 CaskHandle 上）
//
// 同 cask 同时只能有一个状态化迭代器；尝试启动第二个返回
// {error, iteration_in_process}。这是 legacy iterator/3 的契约。
// =============================================================================

ERL_NIF_TERM nif_cask_iterator(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    if (h->iter && h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_in_process);
    }
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs, /*now_sec*/ 0,
                        /*see_tombstones*/ false);
    if (!r) return fault_to_term(env, r.error());
    if (*r == keydir::StartIterResult::kOutOfDate) {
        return atoms().out_of_date;
    }
    h->iter = std::move(it);
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_iterator_next(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    if (!h->iter || !h->iter->is_iterating()) {
        return make_error(env, atoms().iteration_not_started);
    }
    ERL_NIF_TERM out, key_bin, val_bin;
    auto e = iter_next_common(env, h->iter.get(), atoms().not_found, out, key_bin, val_bin);
    if (!e) return out;
    ERL_NIF_TERM tup[7] = {
        atoms().ok,
        key_bin,
        val_bin,
        enif_make_uint(env, e->file_id),
        enif_make_uint64(env, e->offset),
        enif_make_uint(env, e->total_sz),
        enif_make_uint(env, e->tstamp),
    };
    return enif_make_tuple_from_array(env, tup, 7);
}

ERL_NIF_TERM nif_cask_iterator_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    release_iter(h->iter);
    return atoms().ok;
}

}  // namespace bitcask::nif
