// NIF 层内部共享辅助函数。
//
// 被拆分后的 nif_cask.cpp / nif_cask_iter.cpp / nif_cask_admin.cpp 共用，
// 放在 bitcask::nif::detail 命名空间下，不对外暴露。
//
// === 线程模型 ===
// 所有函数仅操作 caller 提供的 env / term / 局部变量，无共享可变状态。
// 可重入、线程安全、无锁——与 NIF 入口函数的线程安全要求一致。

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include <erl_nif.h>

#include "bitcask/cask.hpp"
#include "bitcask/collection.hpp"

namespace bitcask::nif {

struct CaskHandle;
struct CaskIterHandle;
struct CollectionHandle;

// 跨 .cpp 共享的内部辅助函数。
namespace detail {

// 模板化的资源句柄提取：从 NIF term 中取出指定类型的资源指针。
// T 是句柄类型（CaskHandle / CaskIterHandle / CollectionHandle），
// rt 是对应的 ErlNifResourceType* 全局变量。
template <typename T>
T* get_resource_handle(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifResourceType* rt) noexcept;

// 从 NIF term 取出 CaskHandle 指针；类型不对返回 nullptr。
CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 同上，额外验证 h->cask 非空（cask 未关闭）。
CaskHandle* checked_cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 从 NIF term 取出 CaskIterHandle 指针；类型不对返回 nullptr。
CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

CollectionHandle* collection_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 同 checked_cask_handle：额外验证 h->collection 非空（collection 未关闭）。
CollectionHandle* checked_collection_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 解析 [{Key, Value} | atom, ...] 形态的选项 proplist 到 CaskOptions。
// 不识别的键静默跳过，与 legacy 语义一致。
CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list);

// 解析 collection_open 的选项列表到 CollectionOptions。
// 支持的键：analyzer, dict_path, enable_stop_words, read_write。
CollectionOptions parse_collection_options(ErlNifEnv* env, ERL_NIF_TERM list);

// CaskFault → Erlang 错误 term。
// kNotFound / kAlreadyExists 返回裸 atom（legacy 契约），其余返回 {error, Tag}。
ERL_NIF_TERM fault_to_term(ErlNifEnv* env, const CaskFault& f) noexcept;

ERL_NIF_TERM collection_fault_to_term(ErlNifEnv* env, const CollectionFault& f) noexcept;

// fold_start / fold_start4 共用实现。
// 创建迭代器、启动快照、包装成 NIF 资源 term。
ERL_NIF_TERM fold_start_impl(ErlNifEnv* env, CaskHandle* h,
                              int maxage, int maxputs,
                              bool see_tombstones);

// vector<string> → Erlang string list。倒着 cons 保持原始顺序。
ERL_NIF_TERM make_string_list(ErlNifEnv* env,
                               const std::vector<std::string>& v);

// 把搜索结果（vector<TextHit>）转换为 Erlang 的 [{ExtId, Score}, ...] 列表。
// 倒着遍历保持结果原始顺序（BM25 分数从高到低）。
ERL_NIF_TERM make_search_hits(ErlNifEnv* env, const std::vector<TextHit>& hits);

}  // namespace detail
}  // namespace bitcask::nif
