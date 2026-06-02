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

// 以下 8 个搜索 NIF 都委托给 run_search 统一骨架（见 nif_helpers.hpp）：
// 各入口只负责解析自己的整型参数，再把「具体怎么搜」作为闭包传入。
// argv 约定：3 参版 = {ref, query, k}；4 参版 = {ref, query, extra, k}。

ERL_NIF_TERM nif_cask_search_text(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_positive_int(env, argv[2], 10));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_text(q, k); });
}

ERL_NIF_TERM nif_cask_search_phrase(ErlNifEnv* env, int /*argc*/,
                                     const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_positive_int(env, argv[2], 10));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_phrase(q, k); });
}

ERL_NIF_TERM nif_cask_bool_search(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_positive_int(env, argv[2], 10));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.bool_search(q, k); });
}

// S8.6：多字段搜索（field:term^boost）。
ERL_NIF_TERM nif_cask_search_fields(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_positive_int(env, argv[2], 10));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_fields(q, k); });
}

// S8.7：近邻搜索（4 参：ref, query, slop, k）。slop 非负，默认 0。
ERL_NIF_TERM nif_cask_search_near(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    const auto slop = static_cast<std::uint32_t>(get_nonneg_int(env, argv[2], 0));
    const auto k    = static_cast<std::size_t>(get_positive_int(env, argv[3], 10));
    return run_search(env, argv[0], argv[1],
        [slop, k](Cask& c, std::string_view q) { return c.search_near(q, slop, k); });
}

// S8.3：模糊搜索（ref, query, max_edit_distance, k）。距离非负，默认 1。
ERL_NIF_TERM nif_cask_search_fuzzy(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto max_edit = static_cast<std::uint32_t>(get_nonneg_int(env, argv[2], 1));
    const auto k        = static_cast<std::size_t>(get_positive_int(env, argv[3], 10));
    return run_search(env, argv[0], argv[1],
        [max_edit, k](Cask& c, std::string_view q) { return c.search_fuzzy(q, k, max_edit); });
}

// S8.4：通配符搜索（ref, pattern, k）。
ERL_NIF_TERM nif_cask_search_wildcard(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_positive_int(env, argv[2], 10));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view p) { return c.search_wildcard(p, k); });
}

// S8.2：设置同义词词典（ref, file_path）。
ERL_NIF_TERM nif_cask_set_synonym_map(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h || !h->cask->has_search()) return enif_make_badarg(env);
    ErlNifBinary path_bin{};
    if (!enif_inspect_binary(env, argv[1], &path_bin)) return enif_make_badarg(env);

    auto map = std::make_unique<text::SynonymMap>();
    map->load_from_file(std::string(as_string_view(path_bin)));
    h->cask->set_synonym_map(std::move(map));
    return atoms().ok;
}

}  // namespace bitcask::nif