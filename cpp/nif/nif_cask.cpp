// 粗粒度 cask_* NIF — CRUD 操作：open / close / get / put / delete / sync / close_write_file。
// Phase 6 统一后：put 支持 binary（KV）和 map（search-doc）两种形态，
// 并新增 cask_search_text / cask_search_phrase 搜索 NIF。

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
    if (!term) return make_error(env, atoms().allocation_error);
    return make_ok(env, term);
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
    if (!h || !h->cask || !ensure_binary(env, argv[1], key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->get(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    if (h->cask->has_search()) {
        // 索引模式：返回 #{text => Binary, meta => Binary | undefined}
        ERL_NIF_TERM map = enif_make_new_map(env);
        ERL_NIF_TERM text_key = enif_make_atom(env, "text");
        ERL_NIF_TERM text_val = make_binary_checked(env, r->value);
        if (!text_val) return make_error(env, atoms().allocation_error);
        enif_make_map_put(env, map, text_key, text_val, &map);
        ERL_NIF_TERM meta_key = enif_make_atom(env, "meta");
        ERL_NIF_TERM meta_val = r->meta.empty() ? atoms().undefined
                                               : make_binary_checked(env, r->meta);
        if (!meta_val) return make_error(env, atoms().allocation_error);
        enif_make_map_put(env, map, meta_key, meta_val, &map);
        return make_ok(env, map);
    }
    // KV模式：返回纯 binary（行为不变）
    ERL_NIF_TERM val_bin = make_binary_checked(env, r->value);
    if (!val_bin) return make_error(env, atoms().allocation_error);
    return make_ok(env, val_bin);
}

ERL_NIF_TERM nif_cask_put(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);

    ErlNifBinary key{};
    if (!ensure_binary(env, argv[1], key)) return enif_make_badarg(env);

    if (enif_is_binary(env, argv[2])) {
        ErlNifBinary value{};
        if (!ensure_binary(env, argv[2], value)) return enif_make_badarg(env);
        auto r = h->cask->put(as_bytes(key), as_bytes(value));
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    }

    if (enif_is_map(env, argv[2])) {
        DocInput doc;
        parse_doc_map(env, argv[2], doc);
        auto r = h->cask->put_doc(as_bytes(key), doc);
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    }

    return enif_make_badarg(env);
}

ERL_NIF_TERM nif_cask_delete(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !ensure_binary(env, argv[1], key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->remove(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto r = h->cask->sync();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

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

ERL_NIF_TERM nif_cask_search_text(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    return search_impl(env, argc, argv, &Cask::search_text);
}

ERL_NIF_TERM nif_cask_search_phrase(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    return search_impl(env, argc, argv, &Cask::search_phrase);
}

ERL_NIF_TERM nif_cask_bool_search(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    return bool_search_impl(env, argc, argv);
}

// S8.6：多字段搜索（field:term^boost）。复用 search_impl（签名同 search_text）。
ERL_NIF_TERM nif_cask_search_fields(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    return search_impl(env, argc, argv, &Cask::search_fields);
}

}  // namespace bitcask::nif