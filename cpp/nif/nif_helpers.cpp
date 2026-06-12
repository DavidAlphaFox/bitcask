// nif_helpers.hpp 的实现：资源句柄提取、DocInput 解析、错误翻译、搜索骨架
// run_search、迭代器创建、Erlang term 构造等跨 .cpp 共用的辅助。
// （选项解析 parse_options 已拆到 nif_options.cpp。）

#include "nif_helpers.hpp"

#include <cstring>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
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

// 注：open/2 的选项解析（parse_options 及其 parse_*_option 辅助）已拆到
// nif_options.cpp（单一职责），声明仍在 nif_helpers.hpp。

// ---------------------------------------------------------------------------
// DocInput 解析
// ---------------------------------------------------------------------------

bool parse_doc_map(ErlNifEnv* env, ERL_NIF_TERM map_term, DocInput& doc,
                   std::vector<float>& vec_storage) {
    ERL_NIF_TERM text_val;
    if (enif_get_map_value(env, map_term, atoms().text, &text_val)) {
        ErlNifBinary tb{};
        if (enif_inspect_binary(env, text_val, &tb)) {
            doc.text = as_bytes(tb);
        }
    }
    ERL_NIF_TERM meta_val;
    if (enif_get_map_value(env, map_term, atoms().meta, &meta_val)) {
        ErlNifBinary mb{};
        if (enif_inspect_binary(env, meta_val, &mb)) {
            doc.meta = as_bytes(mb);
        }
    }
    // V3.6:vector 键 = f32 LE 二进制。格式错误(非 binary / size%4≠0)
    // 必须显式拒绝——静默跳过会把带坏向量的 put 当无向量文档写入。
    ERL_NIF_TERM vec_val;
    if (enif_get_map_value(env, map_term, atoms().vector, &vec_val)) {
        ErlNifBinary vb{};
        if (!enif_inspect_binary(env, vec_val, &vb) ||
            !binary_to_f32vec(vb, vec_storage)) {
            return false;
        }
        doc.vector = vec_storage;
    }
    // S8.6 多字段：遍历 map，把 text/meta 之外的「atom 键 → binary 值」作为命名字段。
    // span 指向 NIF binary（put_doc 同步编码完才返回，生命周期安全）。
    ErlNifMapIterator iter;
    if (enif_map_iterator_create(env, map_term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        ERL_NIF_TERM k, v;
        while (enif_map_iterator_get_pair(env, &iter, &k, &v)) {
            char namebuf[256];
            int n = enif_get_atom(env, k, namebuf, sizeof(namebuf), ERL_NIF_LATIN1);
            if (n > 0) {
                std::string name(namebuf, static_cast<std::size_t>(n - 1));  // 去末尾 NUL
                if (name != "text" && name != "meta" && name != "vector") {
                    ErlNifBinary fb{};
                    if (enif_inspect_binary(env, v, &fb)) {
                        doc.fields.push_back({std::move(name), as_bytes(fb)});
                    }
                }
            }
            enif_map_iterator_next(env, &iter);
        }
        enif_map_iterator_destroy(env, &iter);
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
// 搜索 NIF 统一骨架（见 nif_helpers.hpp 的 run_search 说明）
// ---------------------------------------------------------------------------

ERL_NIF_TERM run_search(ErlNifEnv* env, ERL_NIF_TERM ref_term,
                        ERL_NIF_TERM query_term, const SearchInvoker& invoke) {
    // checked_cask_handle 已保证返回非空时 h->cask 也非空。
    auto* h = checked_cask_handle(env, ref_term);
    ErlNifBinary query_bin{};
    if (!h || !enif_inspect_binary(env, query_term, &query_bin)) {
        return enif_make_badarg(env);
    }
    if (!h->cask->has_search()) {
        return make_error(env, atoms().no_index);
    }
    // 策略闭包负责具体怎么搜；query span 生命周期与 query_bin 同步，调用同步完成。
    auto r = invoke(*h->cask, as_string_view(query_bin));
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