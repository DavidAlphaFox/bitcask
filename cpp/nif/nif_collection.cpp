#include <string>

#include "atoms.hpp"
#include "nif_helpers.hpp"
#include "priv_data.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

ERL_NIF_TERM nif_collection_open(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    std::string dir;
    if (!get_latin1_string(env, argv[0], dir)) return enif_make_badarg(env);

    CollectionOptions opts;
    if (argc >= 2 && enif_is_list(env, argv[1])) {
        opts = parse_collection_options(env, argv[1]);
    }

    auto* p = priv(env);
    auto c = Collection::open(dir, opts, &p->collection_registry);
    if (!c) return collection_fault_to_term(env, c.error());

    auto term = make_resource<CollectionHandle>(env, g_collection_resource_type,
                                                 std::move(*c));
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

ERL_NIF_TERM nif_collection_close(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = collection_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->collection) {
        h->collection->close();
        h->collection.reset();
    }
    return atoms().ok;
}

ERL_NIF_TERM nif_collection_put(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    ErlNifBinary key_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &key_bin)) {
        return enif_make_badarg(env);
    }

    DocInput doc;
    ERL_NIF_TERM val_term = argv[2];

    if (enif_is_binary(env, val_term)) {
        ErlNifBinary vb{};
        if (!enif_inspect_binary(env, val_term, &vb)) return enif_make_badarg(env);
        doc.text = as_string_view(vb);
    } else if (enif_is_map(env, val_term)) {
        ERL_NIF_TERM text_key = enif_make_atom(env, "text");
        ERL_NIF_TERM text_val;
        if (enif_get_map_value(env, val_term, text_key, &text_val)) {
            ErlNifBinary tb{};
            if (enif_inspect_binary(env, text_val, &tb)) {
                doc.text = as_string_view(tb);
            }
        }
    } else {
        return enif_make_badarg(env);
    }

    auto ext_id = as_string_view(key_bin);
    auto r = h->collection->upsert(ext_id, doc);
    if (!r) return collection_fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_collection_get(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    ErlNifBinary key_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &key_bin)) {
        return enif_make_badarg(env);
    }
    auto ext_id = as_string_view(key_bin);
    auto r = h->collection->get(ext_id);
    if (!r) return collection_fault_to_term(env, r.error());

    ERL_NIF_TERM result;
    if (r->has_text) {
        ErlNifBinary tb;
        if (!enif_alloc_binary(r->text.size(), &tb)) {
            return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
        }
        if (!r->text.empty()) std::memcpy(tb.data, r->text.data(), r->text.size());
        result = enif_make_tuple2(env, enif_make_atom(env, "text"), enif_make_binary(env, &tb));
    } else {
        result = enif_make_atom(env, "undefined");
    }
    return enif_make_tuple2(env, atoms().ok, result);
}

ERL_NIF_TERM nif_collection_delete(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    ErlNifBinary key_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &key_bin)) {
        return enif_make_badarg(env);
    }
    auto ext_id = as_string_view(key_bin);
    auto r = h->collection->remove(ext_id);
    if (!r) return collection_fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_collection_sync(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto r = h->collection->sync();
    if (!r) return collection_fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_collection_search_text(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }
    auto query = as_string_view(query_bin);

    int k = 10;
    if (enif_is_number(env, argv[2])) {
        enif_get_int(env, argv[2], &k);
        if (k <= 0) k = 10;
    }

    auto r = h->collection->search_text(query, static_cast<std::size_t>(k));
    if (!r) return collection_fault_to_term(env, r.error());

    return enif_make_tuple2(env, atoms().ok, make_search_hits(env, *r));
}

ERL_NIF_TERM nif_collection_search_phrase(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_collection_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }
    auto query = as_string_view(query_bin);

    int k = 10;
    if (enif_is_number(env, argv[2])) {
        enif_get_int(env, argv[2], &k);
        if (k <= 0) k = 10;
    }

    auto r = h->collection->search_phrase(query, static_cast<std::size_t>(k));
    if (!r) return collection_fault_to_term(env, r.error());

    return enif_make_tuple2(env, atoms().ok, make_search_hits(env, *r));
}

}  // namespace bitcask::nif
