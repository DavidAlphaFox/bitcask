// libbitcask 11.2.0（S60 / S61）能力接入（随 12.0.0 子模块一并接）：
//
//   cask_update_doc(Ref, Key, Patch)
//     Patch :: #{fields => #{Name :: binary() => Text :: binary() | delete},
//                meta   => #{Key :: binary() => Value | delete}}
//     两个键都可省；其它键 → badarg。Value 同 encode_meta（标量 + [binary()]），
//     但其它 atom 不当 null（只认 undefined），避免把拼错的 delete 静默写成 null。
//     → {ok, Lsn} | not_found（裸，fault_to_term 的 legacy 形态，门面归一）
//       | {error, conflict}（引擎重读重试 16 次仍冲突）| {error, _}。
//
//   cask_search_fields_highlight(Ref, Query, K, Filter, HlOpts)
//     Filter = undefined | filter term；HlOpts :: #{pre_tag, post_tag :: binary(),
//     fragment_size, max_fragments :: pos_integer()}（都可省，未知键 → badarg）。
//     → {ok, [{Key, Ord, Score, Fields, [{Field, [Snippet :: binary()]}]}]}
//     Fields / Field 同 search_fields_attributed（<<>> = 默认字段）；片段只列切出了
//     片段的字段，与 Fields 同序；读回版本 ≠ 命中版本的命中不给片段。
//
//   cask_search_text_highlight(Ref, Query, K, HlOpts)（上游 S13-D3 / S53）
//     HlOpts 同上，另收 cold => load | skip（缺省 load：原文 LRU 没有的「冷」命中从存储
//     读回正文再切；skip = 上游三参版行为，冷命中片段为空）。上游无 filter 参数。
//     → {ok, [{Key, Ord, Score, [Snippet :: binary()]}]}

#include <cstring>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/meta_filter.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

namespace {

std::span<const std::byte> bin_span(const ErlNifBinary& b) {
    return {reinterpret_cast<const std::byte*>(b.data), b.size};
}

std::string bin_string(const ErlNifBinary& b) {
    return {reinterpret_cast<const char*>(b.data), b.size};
}

ERL_NIF_TERM str_term(ErlNifEnv* env, const std::string& s) {
    return make_binary_checked(env, std::as_bytes(std::span<const char>(s.data(), s.size())));
}

// 遍历 map；fn(k, v) 返回 false ⇒ 整体 false。非 map ⇒ false。
template <class F>
bool for_each_pair(ErlNifEnv* env, ERL_NIF_TERM map, F&& fn) {
    if (!enif_is_map(env, map)) return false;
    ErlNifMapIterator it;
    if (!enif_map_iterator_create(env, map, &it, ERL_NIF_MAP_ITERATOR_FIRST)) return false;
    ERL_NIF_TERM k, v;
    bool ok = true;
    while (ok && enif_map_iterator_get_pair(env, &it, &k, &v)) {
        ok = fn(k, v);
        enif_map_iterator_next(env, &it);
    }
    enif_map_iterator_destroy(env, &it);
    return ok;
}

bool parse_patch(ErlNifEnv* env, ERL_NIF_TERM term, bitcask::DocPatch& p) {
    return for_each_pair(env, term, [&](ERL_NIF_TERM k, ERL_NIF_TERM v) {
        if (enif_is_identical(k, atoms().fields)) {
            return for_each_pair(env, v, [&](ERL_NIF_TERM fk, ERL_NIF_TERM fv) {
                ErlNifBinary name{};
                if (!enif_inspect_binary(env, fk, &name)) return false;
                if (enif_is_identical(fv, atoms().atom_delete)) {
                    p.remove_fields.push_back(bin_string(name));
                    return true;
                }
                ErlNifBinary text{};
                if (!enif_inspect_binary(env, fv, &text)) return false;
                p.set_fields.emplace_back(bin_string(name), bin_span(text));
                return true;
            });
        }
        if (enif_is_identical(k, atoms().meta)) {
            return for_each_pair(env, v, [&](ERL_NIF_TERM mk, ERL_NIF_TERM mv) {
                ErlNifBinary key{};
                if (!enif_inspect_binary(env, mk, &key)) return false;
                if (enif_is_identical(mv, atoms().atom_delete)) {
                    p.remove_meta.push_back(bin_string(key));
                    return true;
                }
                bitcask::meta::MetaEntry e;
                e.key = bin_string(key);
                if (!parse_meta_entry_value(env, mv, e.value, /*other_atoms_as_null=*/false)) {
                    return false;
                }
                p.set_meta.push_back(std::move(e));
                return true;
            });
        }
        return false;  // 未知键
    });
}

// cold != nullptr ⇒ 另收 cold => load | skip。
bool parse_hl_opts(ErlNifEnv* env, ERL_NIF_TERM term, bitcask::search::HighlightOptions& o,
                   bitcask::search::ColdText* cold = nullptr) {
    return for_each_pair(env, term, [&](ERL_NIF_TERM k, ERL_NIF_TERM v) {
        if (cold != nullptr && enif_is_identical(k, atoms().cold)) {
            if (enif_is_identical(v, atoms().load)) { *cold = bitcask::search::ColdText::kLoad; return true; }
            if (enif_is_identical(v, atoms().skip)) { *cold = bitcask::search::ColdText::kSkip; return true; }
            return false;
        }
        const bool pre = enif_is_identical(k, atoms().pre_tag);
        if (pre || enif_is_identical(k, atoms().post_tag)) {
            ErlNifBinary b{};
            if (!enif_inspect_binary(env, v, &b)) return false;
            (pre ? o.pre_tag : o.post_tag) = bin_string(b);
            return true;
        }
        const bool frag = enif_is_identical(k, atoms().fragment_size);
        if (frag || enif_is_identical(k, atoms().max_fragments)) {
            ErlNifUInt64 n = 0;
            if (!enif_get_uint64(env, v, &n) || n == 0 || n > (1U << 20)) return false;
            (frag ? o.fragment_size : o.max_fragments) = static_cast<std::size_t>(n);
            return true;
        }
        return false;
    });
}

// 片段列表 → [binary()]；0 = 分配失败。
ERL_NIF_TERM make_snippet_list(ErlNifEnv* env, const std::vector<bitcask::search::Snippet>& ss) {
    std::vector<ERL_NIF_TERM> out;
    out.reserve(ss.size());
    for (const auto& s : ss) {
        ERL_NIF_TERM t = str_term(env, s.text);
        if (!t) return 0;
        out.push_back(t);
    }
    return enif_make_list_from_array(env, out.data(), static_cast<unsigned>(out.size()));
}

// 0 = 分配失败。
ERL_NIF_TERM make_hl_hits(ErlNifEnv* env, const std::vector<bitcask::search::SearchFieldHitEx>& hits) {
    std::vector<ERL_NIF_TERM> out;
    out.reserve(hits.size());
    for (const auto& h : hits) {
        ERL_NIF_TERM key = str_term(env, h.key);
        if (!key) return 0;
        std::vector<ERL_NIF_TERM> fields;
        for (const auto& f : h.fields) {
            ERL_NIF_TERM t = str_term(env, f);
            if (!t) return 0;
            fields.push_back(t);
        }
        std::vector<ERL_NIF_TERM> groups;
        for (const auto& g : h.field_snippets) {
            ERL_NIF_TERM name = str_term(env, g.field);
            if (!name) return 0;
            ERL_NIF_TERM snips = make_snippet_list(env, g.snippets);
            if (!snips) return 0;
            groups.push_back(enif_make_tuple2(env, name, snips));
        }
        out.push_back(enif_make_tuple5(
            env, key, enif_make_uint64(env, h.ord), enif_make_double(env, h.score),
            enif_make_list_from_array(env, fields.data(), static_cast<unsigned>(fields.size())),
            enif_make_list_from_array(env, groups.data(), static_cast<unsigned>(groups.size()))));
    }
    return enif_make_list_from_array(env, out.data(), static_cast<unsigned>(out.size()));
}

}  // namespace

ERL_NIF_TERM nif_cask_update_doc(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !enif_inspect_binary(env, argv[1], &key)) return enif_make_badarg(env);
    bitcask::DocPatch patch;
    if (!parse_patch(env, argv[2], patch)) return enif_make_badarg(env);
    auto r = h->cask->update_doc(bin_span(key), patch);
    if (!r) {
        if (r.error().kind == CaskError::kConditionFailed) {
            return enif_make_tuple2(env, atoms().error, atoms().conflict);
        }
        return fault_to_term(env, r.error());
    }
    return make_ok(env, enif_make_uint64(env, *r));
}

ERL_NIF_TERM nif_cask_search_fields_highlight(ErlNifEnv* env, int /*argc*/,
                                              const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary query{};
    if (!h || !enif_inspect_binary(env, argv[1], &query)) return enif_make_badarg(env);
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    std::unique_ptr<bitcask::meta::MetaFilter> filter;
    if (!enif_is_identical(argv[3], atoms().undefined)) {
        filter = parse_filter_term(env, argv[3]);
        if (!filter) return enif_make_badarg(env);
    }
    bitcask::search::HighlightOptions opts;
    if (!parse_hl_opts(env, argv[4], opts)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_fields_highlight(as_string_view(query), k, opts, filter.get());
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM hits = make_hl_hits(env, *r);
    if (!hits) return make_error(env, atoms().allocation_error);
    return make_ok(env, hits);
}

ERL_NIF_TERM nif_cask_search_text_highlight(ErlNifEnv* env, int /*argc*/,
                                            const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary query{};
    if (!h || !enif_inspect_binary(env, argv[1], &query)) return enif_make_badarg(env);
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    bitcask::search::HighlightOptions opts;
    auto cold = bitcask::search::ColdText::kLoad;
    if (!parse_hl_opts(env, argv[3], opts, &cold)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_text_highlight(as_string_view(query), k, opts, cold);
    if (!r) return fault_to_term(env, r.error());
    std::vector<ERL_NIF_TERM> out;
    out.reserve(r->hits.size());
    for (const auto& hit : r->hits) {
        ERL_NIF_TERM key = str_term(env, hit.key);
        ERL_NIF_TERM snips = key ? make_snippet_list(env, hit.highlights) : 0;
        if (!snips) return make_error(env, atoms().allocation_error);
        out.push_back(enif_make_tuple4(env, key, enif_make_uint64(env, hit.ord),
                                       enif_make_double(env, hit.score), snips));
    }
    return make_ok(env, enif_make_list_from_array(env, out.data(),
                                                  static_cast<unsigned>(out.size())));
}

}  // namespace bitcask::nif
