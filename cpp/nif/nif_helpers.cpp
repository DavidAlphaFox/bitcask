// nif_helpers.hpp 的实现。拆分为独立编译单元，避免在 header 里暴露 parse_options
// 等较长的函数体。

#include "nif_helpers.hpp"

#include <cstring>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/analyzer.hpp"
#include "bitcask/search_layer.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
namespace detail {

// ---------------------------------------------------------------------------
// 资源句柄提取
// ---------------------------------------------------------------------------

template <typename T>
T* get_resource_handle(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifResourceType* rt) noexcept {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, rt, &obj)) return nullptr;
    return static_cast<T*>(obj);
}

template CaskHandle* get_resource_handle<CaskHandle>(ErlNifEnv*, ERL_NIF_TERM, ErlNifResourceType*) noexcept;
template CaskIterHandle* get_resource_handle<CaskIterHandle>(ErlNifEnv*, ERL_NIF_TERM, ErlNifResourceType*) noexcept;

CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    return get_resource_handle<CaskHandle>(env, term, g_cask_resource_type);
}

CaskHandle* checked_cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    auto* h = cask_handle(env, term);
    return (h && h->cask) ? h : nullptr;
}

CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    return get_resource_handle<CaskIterHandle>(env, term, g_cask_iter_resource_type);
}

// ---------------------------------------------------------------------------
// 选项解析
// ---------------------------------------------------------------------------

// ===========================================================================
// 选项解析（open/2 的 proplist 参数）
//
// 格式：[atom, {Key, Value}, ...]
// 不识别的键静默跳过，与 legacy 语义一致。
// ===========================================================================

static void parse_atom_option(ERL_NIF_TERM head, CaskOptions& o) {
    // 解析裸 atom 选项（read_write / merge_only）。
    if (head == atoms().read_write) {
        o.read_write = true;
    } else if (head == atoms().merge_only) {
        o.merge_only = true;
        o.read_write = true;
    }
}

static void parse_merge_option(ErlNifEnv* env, const ERL_NIF_TERM* tup,
                                merge::PolicyOptions& p) {
    // 解析合并策略相关选项 {frag_merge_trigger, Int} 等。
    if (tup[0] == atoms().frag_merge_trigger) {
        int v = 0;
        if (enif_get_int(env, tup[1], &v)) p.frag_merge_trigger = v;
    } else if (tup[0] == atoms().dead_bytes_merge_trigger) {
        ErlNifUInt64 v = 0;
        if (enif_get_uint64(env, tup[1], &v)) p.dead_bytes_merge_trigger = v;
    } else if (tup[0] == atoms().frag_threshold) {
        int v = 0;
        if (enif_get_int(env, tup[1], &v)) p.frag_threshold = v;
    } else if (tup[0] == atoms().dead_bytes_threshold) {
        ErlNifUInt64 v = 0;
        if (enif_get_uint64(env, tup[1], &v)) p.dead_bytes_threshold = v;
    } else if (tup[0] == atoms().small_file_threshold) {
        ErlNifUInt64 v = 0;
        if (enif_get_uint64(env, tup[1], &v)) p.small_file_threshold = v;
    } else if (tup[0] == atoms().expiry_grace_time) {
        int v = 0;
        if (enif_get_int(env, tup[1], &v) && v >= 0) {
            p.expiry_grace_time = static_cast<std::uint32_t>(v);
        }
    } else if (tup[0] == atoms().max_merge_size) {
        ErlNifUInt64 v = 0;
        if (enif_get_uint64(env, tup[1], &v)) p.max_merge_size = v;
    }
}

static void parse_analyzer_option(ErlNifEnv* env, const ERL_NIF_TERM* tup,
                                  CaskOptions& o) {
    // 解析搜索/分词器选项 {analyzer, jieba|ngram|whitespace} 等。
    if (tup[0] == atoms().analyzer) {
        if (tup[1] == atoms().jieba) {
            o.search_config->analyzer_config.type = text::AnalyzerType::Jieba;
        } else if (tup[1] == atoms().ngram) {
            o.search_config->analyzer_config.type = text::AnalyzerType::Ngram;
        } else if (tup[1] == atoms().whitespace) {
            o.search_config->analyzer_config.type = text::AnalyzerType::Whitespace;
        }
    } else if (tup[0] == atoms().dict_path) {
        ErlNifBinary bin{};
        if (enif_inspect_binary(env, tup[1], &bin)) {
            o.search_config->analyzer_config.dict_path = std::string(
                reinterpret_cast<const char*>(bin.data), bin.size);
        }
    } else if (tup[0] == atoms().enable_stop_words) {
        if (tup[1] == atoms().atom_true) {
            o.search_config->analyzer_config.enable_stop_words = true;
        }
    }
}

static void parse_2tuple_option(ErlNifEnv* env, const ERL_NIF_TERM* tup,
                                CaskOptions& o) {
    // 解析二元组选项，分发到 merge/analyzer/general 处理器。
    if (tup[0] == atoms().read_write) {
        o.read_write = (tup[1] == atoms().atom_true);
    } else if (tup[0] == atoms().max_file_size) {
        ErlNifUInt64 v = 0;
        if (enif_get_uint64(env, tup[1], &v)) o.max_file_size = v;
    } else if (tup[0] == atoms().expiry_secs) {
        int v = 0;
        if (enif_get_int(env, tup[1], &v) && v > 0) {
            o.expiry_secs = static_cast<std::uint32_t>(v);
        }
    } else if (tup[0] == atoms().tombstone_version) {
        int v = 0;
        if (enif_get_int(env, tup[1], &v) && v == 2) {
            o.tombstone_version = 2;
        }
    } else if (tup[0] == atoms().sync_strategy) {
        if (tup[1] == atoms().o_sync) {
            o.o_sync = true;
        }
    } else if (tup[0] == atoms().analyzer || tup[0] == atoms().dict_path
               || tup[0] == atoms().enable_stop_words) {
        if (!o.search_config) o.search_config.emplace();
        parse_analyzer_option(env, tup, o);
    } else {
        parse_merge_option(env, tup, o.policy);
    }
}

CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list) {
    CaskOptions o;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        if (enif_is_atom(env, head)) {
            parse_atom_option(head, o);
            continue;
        }
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup) || arity != 2) continue;
        parse_2tuple_option(env, tup, o);
    }
    if (o.expiry_secs > 0) o.policy.expiry_secs = o.expiry_secs;
    if (o.search_config) o.enable_search = true;
    return o;
}

// ---------------------------------------------------------------------------
// DocInput 解析
// ---------------------------------------------------------------------------

bool parse_doc_map(ErlNifEnv* env, ERL_NIF_TERM map_term, DocInput& doc) {
    ERL_NIF_TERM text_val;
    if (enif_get_map_value(env, map_term, enif_make_atom(env, "text"), &text_val)) {
        ErlNifBinary tb{};
        if (enif_inspect_binary(env, text_val, &tb)) {
            doc.text = as_bytes(tb);
        }
    }
    ERL_NIF_TERM meta_val;
    if (enif_get_map_value(env, map_term, enif_make_atom(env, "meta"), &meta_val)) {
        ErlNifBinary mb{};
        if (enif_inspect_binary(env, meta_val, &mb)) {
            doc.meta = as_bytes(mb);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// 错误翻译
// ---------------------------------------------------------------------------

ERL_NIF_TERM fault_to_term(ErlNifEnv* env, const CaskFault& f) noexcept {
    ERL_NIF_TERM tag;
    switch (f.kind) {
        case CaskError::kIo:             tag = errno_atom(env, f.errnum); break;
        case CaskError::kBadCrc:         tag = atoms().bad_crc; break;
        case CaskError::kNotFound:       return atoms().not_found;
        case CaskError::kKeyTooLarge:    tag = atoms().key_too_large; break;
        case CaskError::kValueTooLarge:  tag = atoms().value_too_large; break;
        case CaskError::kAlreadyExists:  return atoms().already_exists;
        case CaskError::kReadOnly:       tag = atoms().read_only; break;
        case CaskError::kWriteLocked:    tag = atoms().write_locked; break;
        case CaskError::kNoIndex:        return atoms().no_index;
        case CaskError::kModeMismatch:  return atoms().mode_mismatch;
        case CaskError::kAnalyzerMismatch:
        case CaskError::kInvalidOption:
        default:                          tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
}

// ---------------------------------------------------------------------------
// 搜索 NIF 共用实现
// ---------------------------------------------------------------------------

ERL_NIF_TERM search_impl(ErlNifEnv* env, int, const ERL_NIF_TERM argv[],
                          SearchFn search_fn) {
    auto* h = checked_cask_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }

    int k = get_int_with_default(env, argv[2], 10);
    if (k <= 0) k = 10;

    if (!h->cask->has_search()) {
        return make_error(env, atoms().no_index);
    }

    std::string_view query(
        reinterpret_cast<const char*>(query_bin.data), query_bin.size);
    auto r = ((*h->cask).*search_fn)(query, static_cast<std::size_t>(k));
    if (!r) return fault_to_term(env, r.error());

    return make_ok(env, make_search_hits(env, r->hits));
}

ERL_NIF_TERM bool_search_impl(ErlNifEnv* env, int, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, argv[1], &query_bin)) {
        return enif_make_badarg(env);
    }

    int k = get_int_with_default(env, argv[2], 10);
    if (k <= 0) k = 10;

    if (!h->cask->has_search()) {
        return make_error(env, atoms().no_index);
    }

    std::string_view query(
        reinterpret_cast<const char*>(query_bin.data), query_bin.size);
    auto r = h->cask->bool_search(query, static_cast<std::size_t>(k));
    if (!r) return fault_to_term(env, r.error());

    return make_ok(env, make_search_hits(env, r->hits));
}

// ---------------------------------------------------------------------------
// 迭代器创建
// ---------------------------------------------------------------------------

ERL_NIF_TERM fold_start_impl(ErlNifEnv* env, CaskHandle* h,
                              int maxage, int maxputs,
                              bool see_tombstones) {
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs, /*now_sec*/ 0, see_tombstones);
    if (!r) return fault_to_term(env, r.error());
    if (*r == keydir::StartIterResult::kOutOfDate) return atoms().out_of_date;
    auto term = make_resource<CaskIterHandle>(env, g_cask_iter_resource_type,
                                               std::move(it));
    if (!term) return make_error(env, atoms().allocation_error);
    return make_ok(env, term);
}

// ---------------------------------------------------------------------------
// Erlang term 构造
// ---------------------------------------------------------------------------

ERL_NIF_TERM make_string_list(ErlNifEnv* env,
                               const std::vector<std::string>& v) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = v.rbegin(); it != v.rend(); ++it) {
        list = enif_make_list_cell(env,
            enif_make_string(env, it->c_str(), ERL_NIF_LATIN1), list);
    }
    return list;
}

ERL_NIF_TERM make_search_hits(ErlNifEnv* env,
                               const std::vector<bitcask::search::SearchHit>& hits) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = hits.rbegin(); it != hits.rend(); ++it) {
        ErlNifBinary key_bin;
        if (!enif_alloc_binary(it->key.size(), &key_bin)) continue;
        if (!it->key.empty()) {
            std::memcpy(key_bin.data, it->key.data(), it->key.size());
        }
        ERL_NIF_TERM tuple = enif_make_tuple3(env,
            enif_make_binary(env, &key_bin),
            enif_make_uint64(env, it->ord),
            enif_make_double(env, it->score));
        list = enif_make_list_cell(env, tuple, list);
    }
    return list;
}

}  // namespace detail
}  // namespace bitcask::nif