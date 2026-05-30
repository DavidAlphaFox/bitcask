// 粗粒度 cask_* NIF — 迭代操作：fold 系列 + iterator 系列。
//
// 两条迭代链路：
//   fold 系列：独立 IterRef 资源，可多个并发（每个 fold/3 / fold/6 一个）。
//   iterator 系列：迭代状态挂在 CaskHandle 上，同 cask 同时只允许一个。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

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
    auto r = ih->iter->next();
    if (!r) return fault_to_term(env, r.error());
    if (!r->has_value()) return atoms().done;
    ERL_NIF_TERM key_bin = make_binary_from_bytes(env, (*r)->key, 0);
    ERL_NIF_TERM val_bin = make_binary_from_bytes(env, (*r)->value, 0);
    if (!key_bin || !val_bin)
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple3(env, atoms().ok, key_bin, val_bin);
}

// 完整版：{ok, K, V, FileId, Offset, TotalSz, Tstamp, IsTomb}。
// IsTomb 标志让 SeeTombstones=true 的调用方能区分活/死 entry。
ERL_NIF_TERM nif_cask_fold_next_full(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih || !ih->iter) return enif_make_badarg(env);
    auto r = ih->iter->next();
    if (!r) return fault_to_term(env, r.error());
    if (!r->has_value()) return atoms().done;
    const auto& e = **r;
    ERL_NIF_TERM key_bin = make_binary_from_bytes(env, e.key, 0);
    ERL_NIF_TERM val_bin = make_binary_from_bytes(env, e.value, 0);
    if (!key_bin || !val_bin)
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    ERL_NIF_TERM tup[8] = {
        atoms().ok,
        key_bin,
        val_bin,
        enif_make_uint(env, e.file_id),
        enif_make_uint64(env, e.offset),
        enif_make_uint(env, e.total_sz),
        enif_make_uint(env, e.tstamp),
        e.is_tombstone ? atoms().atom_true : atoms().atom_false,
    };
    return enif_make_tuple_from_array(env, tup, 8);
}

// fold 资源 release。idempotent。
ERL_NIF_TERM nif_cask_fold_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih) return enif_make_badarg(env);
    if (ih->iter) {
        ih->iter->release();
        ih->iter.reset();
    }
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
        return enif_make_tuple2(env, atoms().error, atoms().iteration_not_started);
    }
    auto r = h->iter->next();
    if (!r) return fault_to_term(env, r.error());
    // EOI 用 not_found——legacy iterator_next 也是这个 atom（不是 done）。
    if (!r->has_value()) return atoms().not_found;
    const auto& e = **r;
    ERL_NIF_TERM key_bin = make_binary_from_bytes(env, e.key, 0);
    ERL_NIF_TERM val_bin = make_binary_from_bytes(env, e.value, 0);
    if (!key_bin || !val_bin)
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    ERL_NIF_TERM tup[7] = {
        atoms().ok,
        key_bin,
        val_bin,
        enif_make_uint(env, e.file_id),
        enif_make_uint64(env, e.offset),
        enif_make_uint(env, e.total_sz),
        enif_make_uint(env, e.tstamp),
    };
    return enif_make_tuple_from_array(env, tup, 7);
}

ERL_NIF_TERM nif_cask_iterator_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->iter) {
        h->iter->release();
        h->iter.reset();
    }
    return atoms().ok;
}

}  // namespace bitcask::nif
