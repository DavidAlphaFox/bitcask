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
    if (!h || !h->cask) return enif_make_badarg(env);

    ErlNifBinary key{};
    if (!enif_inspect_binary(env, argv[1], &key)) return enif_make_badarg(env);

    if (enif_is_binary(env, argv[2])) {
        ErlNifBinary value{};
        if (!enif_inspect_binary(env, argv[2], &value)) return enif_make_badarg(env);
        auto r = h->cask->put(as_bytes(key), as_bytes(value));
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    } else if (enif_is_map(env, argv[2])) {
        DocInput doc;
        ERL_NIF_TERM text_key = enif_make_atom(env, "text");
        ERL_NIF_TERM text_val;
        if (enif_get_map_value(env, argv[2], text_key, &text_val)) {
            ErlNifBinary tb{};
            if (enif_inspect_binary(env, text_val, &tb)) {
                doc.text = as_bytes(tb);
            }
        }
        ERL_NIF_TERM meta_key = enif_make_atom(env, "meta");
        ERL_NIF_TERM meta_val;
        if (enif_get_map_value(env, argv[2], meta_key, &meta_val)) {
            ErlNifBinary mb{};
            if (enif_inspect_binary(env, meta_val, &mb)) {
                doc.meta = as_bytes(mb);
            }
        }
        auto r = h->cask->put_doc(as_bytes(key), doc);
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    }
    return enif_make_badarg(env);
}

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

ERL_NIF_TERM nif_cask_search_text(ErlNifEnv* env, int,
                                    const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }

    int k = 10;
    if (enif_is_number(env, argv[2])) {
        enif_get_int(env, argv[2], &k);
        if (k <= 0) k = 10;
    }

    if (!h->cask->has_search()) return enif_make_tuple2(env, atoms().error, atoms().no_index);

    auto r = h->cask->search_text(
        std::string_view(reinterpret_cast<const char*>(query_bin.data), query_bin.size),
        static_cast<std::size_t>(k));
    if (!r) return fault_to_term(env, r.error());

    return enif_make_tuple2(env, atoms().ok, make_search_hits(env, r->hits));
}

ERL_NIF_TERM nif_cask_search_phrase(ErlNifEnv* env, int,
                                     const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }

    int k = 10;
    if (enif_is_number(env, argv[2])) {
        enif_get_int(env, argv[2], &k);
        if (k <= 0) k = 10;
    }

    if (!h->cask->has_search()) return enif_make_tuple2(env, atoms().error, atoms().no_index);

    auto r = h->cask->search_phrase(
        std::string_view(reinterpret_cast<const char*>(query_bin.data), query_bin.size),
        static_cast<std::size_t>(k));
    if (!r) return fault_to_term(env, r.error());

    return enif_make_tuple2(env, atoms().ok, make_search_hits(env, r->hits));
}

}  // namespace bitcask::nif