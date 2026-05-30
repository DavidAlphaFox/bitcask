// nif_helpers.hpp 的实现。拆分为独立编译单元，避免在 header 里暴露 parse_options
// 等较长的函数体。

#include "nif_helpers.hpp"

#include <cstring>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/collection.hpp"
#include "bitcask/text/analyzer.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
namespace detail {

// ---------------------------------------------------------------------------
// 资源句柄提取
// ---------------------------------------------------------------------------

// 模板化的资源句柄提取实现。
template <typename T>
T* get_resource_handle(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifResourceType* rt) noexcept {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, rt, &obj)) return nullptr;
    return static_cast<T*>(obj);
}

// 显式实例化，避免链接错误。
template CaskHandle* get_resource_handle<CaskHandle>(ErlNifEnv*, ERL_NIF_TERM, ErlNifResourceType*) noexcept;
template CaskIterHandle* get_resource_handle<CaskIterHandle>(ErlNifEnv*, ERL_NIF_TERM, ErlNifResourceType*) noexcept;
template CollectionHandle* get_resource_handle<CollectionHandle>(ErlNifEnv*, ERL_NIF_TERM, ErlNifResourceType*) noexcept;

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

CollectionHandle* collection_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    return get_resource_handle<CollectionHandle>(env, term, g_collection_resource_type);
}

CollectionHandle* checked_collection_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    auto* h = collection_handle(env, term);
    return (h && h->collection) ? h : nullptr;
}

// ---------------------------------------------------------------------------
// 选项解析
// ---------------------------------------------------------------------------

// 处理单 atom 形式的选项：read_write | merge_only。
static void parse_atom_option(ERL_NIF_TERM head, CaskOptions& o) {
    if (head == atoms().read_write) {
        o.read_write = true;
    } else if (head == atoms().merge_only) {
        o.merge_only = true;
        o.read_write = true;  // merger 需要写输出文件
    }
}

// 处理 {Key, Value} 二元组形式的 merge 策略选项。
static void parse_merge_option(ErlNifEnv* env, const ERL_NIF_TERM* tup,
                                merge::PolicyOptions& p) {
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

// 处理 {Key, Value} 二元组形式的选项（文件/同步/cask 级别）。
// merge 策略选项委托给 parse_merge_option。
static void parse_tuple_option(ErlNifEnv* env, const ERL_NIF_TERM* tup,
                                CaskOptions& o) {
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
        // 接受 0（默认）和 2（v2，墓碑带影子 file_id）；其它值默认 v0。
        int v = 0;
        if (enif_get_int(env, tup[1], &v) && v == 2) {
            o.tombstone_version = 2;
        }
    } else if (tup[0] == atoms().sync_strategy) {
        // 'o_sync' → 每次 write 直接落盘；'none' 和 {seconds,_} 维持默认。
        if (tup[1] == atoms().o_sync) {
            o.o_sync = true;
        }
    } else {
        // 非以上键 → 尝试作为 merge 策略选项解析。
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
        parse_tuple_option(env, tup, o);
    }
    // expiry_secs 下推给 PolicyOptions，保证 merge 触发判断与 get/iter 用同一截止时间。
    if (o.expiry_secs > 0) o.policy.expiry_secs = o.expiry_secs;
    return o;
}

CollectionOptions parse_collection_options(ErlNifEnv* env, ERL_NIF_TERM list) {
    CollectionOptions o;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup) || arity != 2) continue;

        if (tup[0] == atoms().analyzer) {
            if (tup[1] == atoms().jieba) {
                o.analyzer_config.type = text::AnalyzerType::Jieba;
            } else if (tup[1] == atoms().ngram) {
                o.analyzer_config.type = text::AnalyzerType::Ngram;
            } else if (tup[1] == atoms().whitespace) {
                o.analyzer_config.type = text::AnalyzerType::Whitespace;
            }
        } else if (tup[0] == atoms().dict_path) {
            ErlNifBinary bin{};
            if (enif_inspect_binary(env, tup[1], &bin)) {
                o.analyzer_config.dict_path = std::string(
                    reinterpret_cast<const char*>(bin.data), bin.size);
            }
        } else if (tup[0] == atoms().enable_stop_words) {
            if (tup[1] == atoms().atom_true) {
                o.analyzer_config.enable_stop_words = true;
            }
        } else if (tup[0] == atoms().read_write) {
            if (tup[1] == atoms().atom_true) {
                o.read_write = true;
            }
        }
    }
    return o;
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
        case CaskError::kInvalidOption:
        default:                          tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
}

ERL_NIF_TERM collection_fault_to_term(ErlNifEnv* env, const CollectionFault& f) noexcept {
    ERL_NIF_TERM tag;
    switch (f.kind) {
        case CollectionError::kIo:             tag = errno_atom(env, f.errnum); break;
        case CollectionError::kBadCrc:         tag = atoms().bad_crc; break;
        case CollectionError::kNotFound:       return atoms().not_found;
        case CollectionError::kCorrupt:        tag = atoms().error; break;
        case CollectionError::kWriteLocked:    tag = atoms().write_locked; break;
        case CollectionError::kKeyTooLarge:    tag = atoms().key_too_large; break;
        case CollectionError::kValueTooLarge:  tag = atoms().value_too_large; break;
        default:                               tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
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
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
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
                               const std::vector<TextHit>& hits) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = hits.rbegin(); it != hits.rend(); ++it) {
        ErlNifBinary id_bin;
        if (!enif_alloc_binary(it->ext_id.size(), &id_bin)) continue;
        if (!it->ext_id.empty()) {
            std::memcpy(id_bin.data, it->ext_id.data(), it->ext_id.size());
        }
        ERL_NIF_TERM tuple = enif_make_tuple2(env,
            enif_make_binary(env, &id_bin),
            enif_make_double(env, static_cast<double>(it->score)));
        list = enif_make_list_cell(env, tuple, list);
    }
    return list;
}

}  // namespace detail
}  // namespace bitcask::nif
