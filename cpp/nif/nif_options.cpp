// open/2 的 proplist 选项解析。从 nif_helpers.cpp 拆出，单一职责：把 Erlang 侧
// 传来的 `[atom | {Key, Value}, ...]` 解析成 C++ 的 CaskOptions。
//
// 分发结构：
//   裸 atom            → parse_atom_option   （read_write / merge_only）
//   {Key, Value} 二元组 → parse_2tuple_option → 再细分到 merge / analyzer 处理器
// 不识别的键静默跳过，与 legacy 语义一致。
//
// 线程模型：纯函数式，只读 caller 的 env/term，无共享可变状态；可重入、无锁。

#include "nif_helpers.hpp"

#include "atoms.hpp"
#include "bitcask/analyzer.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/search_layer.hpp"
#include "bitcask/synonym_map.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
namespace detail {
namespace {

// ---------------------------------------------------------------------------
// 选项值提取小工具：把「enif_get_* + 校验 + 赋值」收成一行，消除每个分支的重复。
// 校验通过才写入 *out；否则保持原值（即沿用默认）。
// ---------------------------------------------------------------------------

// 取 int 选项值（无下限）。
bool opt_int(ErlNifEnv* env, ERL_NIF_TERM t, int* out) noexcept {
    return enif_get_int(env, t, out) != 0;
}

// 取 uint64 选项值。
bool opt_u64(ErlNifEnv* env, ERL_NIF_TERM t, std::uint64_t* out) noexcept {
    ErlNifUInt64 v = 0;
    if (!enif_get_uint64(env, t, &v)) return false;
    *out = v;
    return true;
}

// 取 uint32 选项值，要求 ≥ min_val（如 min_n ≥ 1、expiry_grace_time ≥ 0）。
bool opt_u32_min(ErlNifEnv* env, ERL_NIF_TERM t, int min_val, std::uint32_t* out) noexcept {
    int v = 0;
    if (enif_get_int(env, t, &v) && v >= min_val) {
        *out = static_cast<std::uint32_t>(v);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 各类选项处理器
// ---------------------------------------------------------------------------

// 裸 atom 选项（read_write / merge_only）。
void parse_atom_option(ERL_NIF_TERM head, CaskOptions& o) {
    if (head == atoms().read_write) {
        o.read_write = true;
    } else if (head == atoms().merge_only) {
        o.merge_only = true;
        o.read_write = true;
    }
}

// 合并策略相关 {frag_merge_trigger, Int} 等。
void parse_merge_option(ErlNifEnv* env, const ERL_NIF_TERM* tup, merge::PolicyOptions& p) {
    const ERL_NIF_TERM key = tup[0];
    const ERL_NIF_TERM val = tup[1];
    if      (key == atoms().frag_merge_trigger)        opt_int(env, val, &p.frag_merge_trigger);
    else if (key == atoms().dead_bytes_merge_trigger)  opt_u64(env, val, &p.dead_bytes_merge_trigger);
    else if (key == atoms().frag_threshold)            opt_int(env, val, &p.frag_threshold);
    else if (key == atoms().dead_bytes_threshold)      opt_u64(env, val, &p.dead_bytes_threshold);
    else if (key == atoms().small_file_threshold)      opt_u64(env, val, &p.small_file_threshold);
    else if (key == atoms().expiry_grace_time)         opt_u32_min(env, val, 0, &p.expiry_grace_time);
    else if (key == atoms().max_merge_size)            opt_u64(env, val, &p.max_merge_size);
}

// 搜索/分词器相关 {analyzer, jieba|ngram|whitespace} 等。
void parse_analyzer_option(ErlNifEnv* env, const ERL_NIF_TERM* tup, CaskOptions& o) {
    const ERL_NIF_TERM key = tup[0];
    const ERL_NIF_TERM val = tup[1];
    auto& ac = o.search_config->analyzer_config;
    if (key == atoms().analyzer) {
        if      (val == atoms().jieba)      ac.type = text::AnalyzerType::Jieba;
        else if (val == atoms().ngram)      ac.type = text::AnalyzerType::Ngram;
        else if (val == atoms().whitespace) ac.type = text::AnalyzerType::Whitespace;
    } else if (key == atoms().dict_path) {
        ErlNifBinary bin{};
        if (enif_inspect_binary(env, val, &bin)) {
            ac.dict_path = std::string(as_string_view(bin));
        }
    } else if (key == atoms().enable_stop_words) {
        if (val == atoms().atom_true) ac.enable_stop_words = true;
    } else if (key == atoms().min_n) {
        opt_u32_min(env, val, 1, &ac.min_n);
    } else if (key == atoms().max_n) {
        opt_u32_min(env, val, 1, &ac.max_n);
    } else if (key == atoms().min_token_length) {
        opt_u32_min(env, val, 1, &ac.min_token_length);
    } else if (key == atoms().enable_stemming) {
        if (val == atoms().atom_true) ac.enable_stemming = true;
    } else if (key == atoms().synonym_file) {
        // v3.0.0：同义词词典改为 open-time 不可变配置（取代已删除的运行期
        // set_synonym_map）。从文件加载一次，构造后只读 → 并发查询安全。
        // 载入失败（路径打不开）→ 沿用「无效选项值静默跳过」语义：不装词典，
        // open 仍成功、查询不展开同义词（与其它选项的容错一致）。
        ErlNifBinary bin{};
        if (enif_inspect_binary(env, val, &bin)) {
            auto map = std::make_shared<text::SynonymMap>();
            if (map->load_from_file(std::string(as_string_view(bin)))) {
                o.synonym_map = std::move(map);
            }
        }
    }
}

// 判断某二元组键是否属于「分词器/搜索」类。
bool is_analyzer_key(ERL_NIF_TERM key) {
    return key == atoms().analyzer || key == atoms().dict_path
        || key == atoms().enable_stop_words
        || key == atoms().min_n || key == atoms().max_n
        || key == atoms().min_token_length || key == atoms().enable_stemming
        || key == atoms().synonym_file;
}

// 二元组选项总分发：general → merge → analyzer。
void parse_2tuple_option(ErlNifEnv* env, const ERL_NIF_TERM* tup, CaskOptions& o) {
    const ERL_NIF_TERM key = tup[0];
    const ERL_NIF_TERM val = tup[1];
    if (key == atoms().read_write) {
        o.read_write = (val == atoms().atom_true);
    } else if (key == atoms().max_file_size) {
        opt_u64(env, val, &o.max_file_size);
    } else if (key == atoms().max_read_handles) {
        // P9:read 句柄缓存上限(0=不限)。
        std::uint64_t n = 0;
        if (opt_u64(env, val, &n)) o.max_read_handles = static_cast<std::size_t>(n);
    } else if (key == atoms().expiry_secs) {
        opt_u32_min(env, val, 1, &o.expiry_secs);
    } else if (key == atoms().tombstone_version) {
        int v = 0;
        if (opt_int(env, val, &v) && v == 2) o.tombstone_version = 2;
    } else if (key == atoms().sync_strategy) {
        if (val == atoms().o_sync) {
            o.o_sync = true;
        } else {
            // P4:{sync_strategy, {puts, N}} —— 单写者组提交，每 N 次写 fsync。
            int arity = 0;
            const ERL_NIF_TERM* tup = nullptr;
            int n = 0;
            if (enif_get_tuple(env, val, &arity, &tup) && arity == 2 &&
                tup[0] == atoms().puts &&
                enif_get_int(env, tup[1], &n) && n > 0) {
                o.sync_every_n = static_cast<std::uint32_t>(n);
            }
        }
    } else if (key == atoms().vector_dim) {
        // V3.6:{vector_dim, N},N ∈ [1, 65535]。dim>0 要求索引模式
        // (Cask::open 校验 enable_search,不符 → kInvalidOption)。
        int v = 0;
        if (enif_get_int(env, val, &v) && v > 0 && v <= 0xFFFF) {
            o.vector_dim = static_cast<std::uint16_t>(v);
        }
    } else if (key == atoms().vector_quantized) {
        // P3b:{vector_quantized, true} —— 向量落盘 int8（仅 vector_dim>0 有效）。
        o.vector_quantized = (val == atoms().atom_true);
    } else if (key == atoms().vector_inmem_int8) {
        // P5b:{vector_inmem_int8, true} —— HNSW int8-only 内存（仅 kDot/cosine）。
        o.vector_inmem_int8 = (val == atoms().atom_true);
    } else if (key == atoms().vector_metric) {
        // V3.6:{vector_metric, cosine|l2|dot};默认 cosine(写入归一化)。
        if      (val == atoms().cosine) o.vector_metric = meta::VectorMetric::kCosineNormalized;
        else if (val == atoms().l2)     o.vector_metric = meta::VectorMetric::kL2;
        else if (val == atoms().dot)    o.vector_metric = meta::VectorMetric::kDot;
    } else if (is_analyzer_key(key)) {
        if (!o.search_config) o.search_config.emplace();
        parse_analyzer_option(env, tup, o);
    } else {
        parse_merge_option(env, tup, o.policy);
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// 入口：遍历 proplist，逐项分发。
// ---------------------------------------------------------------------------

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
    // 派生项：expiry_secs 同步给 merge policy；有 search_config 即开启搜索模式。
    if (o.expiry_secs > 0) o.policy.expiry_secs = o.expiry_secs;
    if (o.search_config) o.enable_search = true;
    return o;
}

}  // namespace detail
}  // namespace bitcask::nif
