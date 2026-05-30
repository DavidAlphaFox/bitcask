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

namespace bitcask::nif {

struct CaskHandle;
struct CaskIterHandle;

// 跨 .cpp 共享的内部辅助函数。
namespace detail {

// 从 NIF term 取出 CaskHandle 指针；类型不对返回 nullptr。
CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 同上，额外验证 h->cask 非空（cask 未关闭）。
CaskHandle* checked_cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 从 NIF term 取出 CaskIterHandle 指针；类型不对返回 nullptr。
CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 解析 [{Key, Value} | atom, ...] 形态的选项 proplist 到 CaskOptions。
// 不识别的键静默跳过，与 legacy 语义一致。
CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list);

// CaskFault → Erlang 错误 term。
// kNotFound / kAlreadyExists 返回裸 atom（legacy 契约），其余返回 {error, Tag}。
ERL_NIF_TERM fault_to_term(ErlNifEnv* env, const CaskFault& f) noexcept;

// fold_start / fold_start4 共用实现。
// 创建迭代器、启动快照、包装成 NIF 资源 term。
ERL_NIF_TERM fold_start_impl(ErlNifEnv* env, CaskHandle* h,
                              int maxage, int maxputs,
                              bool see_tombstones);

// vector<string> → Erlang string list。倒着 cons 保持原始顺序。
ERL_NIF_TERM make_string_list(ErlNifEnv* env,
                               const std::vector<std::string>& v);

}  // namespace detail
}  // namespace bitcask::nif
