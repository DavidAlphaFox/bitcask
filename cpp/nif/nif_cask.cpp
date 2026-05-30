// 粗粒度 cask_* NIF — CRUD 操作：open / close / get / put / delete / sync / close_write_file。
//
// 每个 NIF 入口 1:1 对应一个 Cask 方法。调用链：
//   Erlang term → 参数校验 → Cask 方法 → expected<T,CaskFault> → Erlang term
//
// 线程模型见 nif_main.cpp 顶部的统一说明。

#include <string>
#include <vector>

#include "atoms.hpp"
#include "nif_helpers.hpp"
#include "priv_data.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

ERL_NIF_TERM nif_cask_open(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string dir;
    if (!get_latin1_string(env, argv[0], dir))     return enif_make_badarg(env);
    if (!enif_is_list(env, argv[1]))                return enif_make_badarg(env);

    CaskOptions opts = parse_options(env, argv[1]);
    auto* p = priv(env);
    auto c = Cask::open(dir, opts, &p->cask_registry);
    if (!c) return fault_to_term(env, c.error());

    auto term = make_resource<CaskHandle>(env, g_cask_resource_type,
                                           std::move(*c), nullptr);
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

ERL_NIF_TERM nif_cask_close(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->cask) {
        h->cask->close();
        h->cask.reset();
    }
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_get(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !enif_inspect_binary(env, argv[1], &key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->get(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM val_bin = make_binary_from_bytes(env, r->value, 0);
    if (!val_bin) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, val_bin);
}

ERL_NIF_TERM nif_cask_put(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{}, value{};
    if (!h || !h->cask ||
        !enif_inspect_binary(env, argv[1], &key) ||
        !enif_inspect_binary(env, argv[2], &value)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->put(as_bytes(key), as_bytes(value));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// 软删除：写一条墓碑 entry，空间在 merge 时回收。
ERL_NIF_TERM nif_cask_delete(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !enif_inspect_binary(env, argv[1], &key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->remove(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// fsync active data file。o_sync 模式下退化为 no-op。
ERL_NIF_TERM nif_cask_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto r = h->cask->sync();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// 写完 hint trailer、释放 write.lock；Ref 仍然可用。
// 如果有 stateful iterator 在跑，先收掉（迭代状态跟 file lifecycle 走）。
ERL_NIF_TERM nif_cask_close_write_file(ErlNifEnv* env, int /*argc*/,
                                         const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->iter && h->iter->is_iterating()) {
        h->iter->release();
        h->iter.reset();
    }
    auto r = h->cask->close_write_file();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

}  // namespace bitcask::nif
