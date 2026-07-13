// nif_helpers.hpp 的实现：资源句柄提取、DocInput 解析、错误翻译、搜索骨架
// run_search、迭代器创建、Erlang term 构造等跨 .cpp 共用的辅助。
// （选项解析 parse_options 已拆到 nif_options.cpp。）

#include "nif_helpers.hpp"

#include <cstring>
#include <variant>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/meta_filter.hpp"
#include "bitcask/search_config.hpp"
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
    // 方案 C：4 个顶层 key，类型严格，零碰撞可能。
    //   text   — binary，主文本（search_text 搜这个）
    //   fields — map<binary, binary>，命名字段（search_fields 搜这些）
    //   vector — binary，f32 LE 向量
    //   meta   — binary，opaque 元数据
    // 未知顶层 key → false（badarg），防止旧式扁平字段被静默丢弃。

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
    // 命名字段：#{<<"title">> => <<"...">>, ...}，key/value 均为 binary。
    // span 指向 NIF binary（put_doc 同步编码完才返回，生命周期安全）。
    ERL_NIF_TERM fields_val;
    if (enif_get_map_value(env, map_term, atoms().fields, &fields_val)) {
        if (!enif_is_map(env, fields_val)) {
            return false;
        }
        ErlNifMapIterator fiter;
        if (enif_map_iterator_create(env, fields_val, &fiter,
                                      ERL_NIF_MAP_ITERATOR_FIRST)) {
            ERL_NIF_TERM fk, fv;
            while (enif_map_iterator_get_pair(env, &fiter, &fk, &fv)) {
                ErlNifBinary key_b{}, val_b{};
                if (!enif_inspect_binary(env, fk, &key_b) ||
                    !enif_inspect_binary(env, fv, &val_b)) {
                    enif_map_iterator_destroy(env, &fiter);
                    return false;
                }
                std::string name(reinterpret_cast<const char*>(key_b.data),
                                  key_b.size);
                doc.fields.push_back({std::move(name), as_bytes(val_b)});
                enif_map_iterator_next(env, &fiter);
            }
            enif_map_iterator_destroy(env, &fiter);
        }
    }
    // 拒绝未知顶层 key — 只有 text/fields/vector/meta 合法。
    ErlNifMapIterator iter;
    if (enif_map_iterator_create(env, map_term, &iter,
                                  ERL_NIF_MAP_ITERATOR_FIRST)) {
        ERL_NIF_TERM k, v;
        while (enif_map_iterator_get_pair(env, &iter, &k, &v)) {
            if (!enif_is_identical(k, atoms().text) &&
                !enif_is_identical(k, atoms().meta) &&
                !enif_is_identical(k, atoms().vector) &&
                !enif_is_identical(k, atoms().fields)) {
                enif_map_iterator_destroy(env, &iter);
                return false;
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
        case CaskError::kClosed:         return atoms().closed;
        case CaskError::kAnalyzerMismatch:
        case CaskError::kInvalidOption:
        default:                          tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
}

// ---------------------------------------------------------------------------
// V5:MetaFilter 解析
// ---------------------------------------------------------------------------

namespace {

// Erlang term → MetaValue。
// 支持 int(int64) / float(double) / binary(string) / true|false(bool) / undefined(monostate)。
// 其他形态返回 false。
bool parse_meta_value(ErlNifEnv* env, ERL_NIF_TERM term,
                      bitcask::meta::MetaValue& out) {
    if (enif_is_identical(term, atoms().undefined)) {
        out = std::monostate{};
        return true;
    }
    if (enif_is_identical(term, atoms().atom_true)) {
        out = true;
        return true;
    }
    if (enif_is_identical(term, atoms().atom_false)) {
        out = false;
        return true;
    }
    // 整数走 int64:enif_get_int64 在溢出时返回 false;大数用例罕见。
    ErlNifSInt64 iv = 0;
    if (enif_get_int64(env, term, &iv)) {
        out = static_cast<std::int64_t>(iv);
        return true;
    }
    double dv = 0.0;
    if (enif_get_double(env, term, &dv)) {
        out = dv;
        return true;
    }
    ErlNifBinary bv{};
    if (enif_inspect_binary(env, term, &bv)) {
        out = std::string(reinterpret_cast<const char*>(bv.data), bv.size);
        return true;
    }
    return false;
}

// op atom → MetaOp。不识别返回 false。
bool parse_meta_op(ErlNifEnv* /*env*/, ERL_NIF_TERM term,
                   bitcask::meta::MetaOp& out) {
    if (enif_is_identical(term, atoms().eq))     { out = bitcask::meta::MetaOp::Eq;     return true; }
    if (enif_is_identical(term, atoms().neq))    { out = bitcask::meta::MetaOp::Neq;    return true; }
    if (enif_is_identical(term, atoms().gt))     { out = bitcask::meta::MetaOp::Gt;     return true; }
    if (enif_is_identical(term, atoms().gte))    { out = bitcask::meta::MetaOp::Gte;    return true; }
    if (enif_is_identical(term, atoms().lt))     { out = bitcask::meta::MetaOp::Lt;     return true; }
    if (enif_is_identical(term, atoms().lte))    { out = bitcask::meta::MetaOp::Lte;    return true; }
    if (enif_is_identical(term, atoms().in_op))  { out = bitcask::meta::MetaOp::In;     return true; }
    if (enif_is_identical(term, atoms().exists)) { out = bitcask::meta::MetaOp::Exists; return true; }
    return false;
}

// 解析单条 condition map → MetaCondition。失败返回 nullptr。
// key 必填;op 必填;value/values 按 op 类型决定;In 必带 values 列表。
std::unique_ptr<bitcask::meta::MetaCondition>
parse_condition_map(ErlNifEnv* env, ERL_NIF_TERM map) {
    using bitcask::meta::MetaCondition;
    using bitcask::meta::MetaOp;
    using bitcask::meta::MetaValue;

    ERL_NIF_TERM key_term;
    if (!enif_get_map_value(env, map, atoms().key, &key_term)) return nullptr;
    ErlNifBinary kb{};
    if (!enif_inspect_binary(env, key_term, &kb)) return nullptr;
    std::string key(reinterpret_cast<const char*>(kb.data), kb.size);

    ERL_NIF_TERM op_term;
    if (!enif_get_map_value(env, map, atoms().op, &op_term)) return nullptr;
    MetaOp op{};
    if (!parse_meta_op(env, op_term, op)) return nullptr;

    auto cond = std::make_unique<MetaCondition>();
    cond->key = std::move(key);
    cond->op = op;

    if (op == MetaOp::In) {
        ERL_NIF_TERM values_term;
        if (!enif_get_map_value(env, map, atoms().values, &values_term)) return nullptr;
        if (!enif_is_list(env, values_term)) return nullptr;
        ERL_NIF_TERM head, tail = values_term;
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            MetaValue v;
            if (!parse_meta_value(env, head, v)) return nullptr;
            cond->values.push_back(std::move(v));
        }
        if (cond->values.empty()) return nullptr;
    } else if (op == MetaOp::Exists) {
        // value field intentionally ignored
    } else {
        ERL_NIF_TERM value_term;
        if (!enif_get_map_value(env, map, atoms().value, &value_term)) return nullptr;
        if (!parse_meta_value(env, value_term, cond->value)) return nullptr;
    }

    return cond;
}

// 解析一个 MetaFilter map(含 logic/conditions/children 三个字段)。
// conditions/children 都可缺省,缺省视为空;children 递归走本函数。
// 任一子项解析失败返回 nullptr。
std::unique_ptr<bitcask::meta::MetaFilter>
parse_filter_map(ErlNifEnv* env, ERL_NIF_TERM map) {
    using bitcask::meta::MetaFilter;

    auto filter = std::make_unique<MetaFilter>();

    ERL_NIF_TERM logic_term;
    if (enif_get_map_value(env, map, atoms().logic, &logic_term)) {
        if (enif_is_identical(logic_term, atoms().and_op)) {
            filter->logic = MetaFilter::Logic::And;
        } else if (enif_is_identical(logic_term, atoms().or_op)) {
            filter->logic = MetaFilter::Logic::Or;
        } else {
            return nullptr;
        }
    }
    // logic 缺省默认 And——与 list 形态行为一致。

    ERL_NIF_TERM cond_term;
    if (enif_get_map_value(env, map, atoms().conditions, &cond_term)) {
        if (!enif_is_list(env, cond_term)) return nullptr;
        ERL_NIF_TERM head, tail = cond_term;
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            if (!enif_is_map(env, head)) return nullptr;
            auto c = parse_condition_map(env, head);
            if (!c) return nullptr;
            filter->conditions.push_back(std::move(*c));
        }
    }

    ERL_NIF_TERM children_term;
    if (enif_get_map_value(env, map, atoms().children, &children_term)) {
        if (!enif_is_list(env, children_term)) return nullptr;
        ERL_NIF_TERM head, tail = children_term;
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            if (!enif_is_map(env, head)) return nullptr;
            auto child = parse_filter_map(env, head);
            if (!child) return nullptr;
            filter->children.push_back(std::move(child));
        }
    }

    return filter;
}

}  // namespace

// 把 Erlang term 翻译成 MetaFilter。
//   简单列表 [CondMap, ...] →  And{conditions};
//   map #{key, op, value/values}  → 单条 condition,包成 And{conditions};
//   map #{logic, conditions, children} → 递归嵌套;logic/conditions/children 均可缺省。
// 失败/形态错 → nullptr(caller 转 badarg)。
std::unique_ptr<bitcask::meta::MetaFilter>
parse_filter_term(ErlNifEnv* env, ERL_NIF_TERM term) {
    if (enif_is_list(env, term)) {
        auto f = std::make_unique<bitcask::meta::MetaFilter>();
        ERL_NIF_TERM head, tail = term;
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            if (!enif_is_map(env, head)) return nullptr;
            auto c = parse_condition_map(env, head);
            if (!c) return nullptr;
            f->conditions.push_back(std::move(*c));
        }
        return f;
    }
    if (enif_is_map(env, term)) {
        // 歧义消解:map 里有 key / op → 单条 condition;否则 → 嵌套 filter。
        // 用 map iterator 比 enif_get_map_value 配 nullptr 输出更安全。
        bool has_cond_field = false;
        ErlNifMapIterator iter;
        if (enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
            ERL_NIF_TERM k, v;
            while (enif_map_iterator_get_pair(env, &iter, &k, &v)) {
                if (enif_is_identical(k, atoms().key) ||
                    enif_is_identical(k, atoms().op)) {
                    has_cond_field = true;
                    break;
                }
                enif_map_iterator_next(env, &iter);
            }
            enif_map_iterator_destroy(env, &iter);
        }
        if (has_cond_field) {
            auto c = parse_condition_map(env, term);
            if (!c) return nullptr;
            auto f = std::make_unique<bitcask::meta::MetaFilter>();
            f->conditions.push_back(std::move(*c));
            return f;
        }
        return parse_filter_map(env, term);
    }
    return nullptr;
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