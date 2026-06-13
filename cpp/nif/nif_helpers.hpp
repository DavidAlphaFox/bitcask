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
#include <expected>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <erl_nif.h>

#include "bitcask/cask.hpp"
#include "bitcask/meta_filter.hpp"

namespace bitcask::nif {

struct CaskHandle;
struct CaskIterHandle;

// 跨 .cpp 共享的内部辅助函数。
namespace detail {

// 模板化的资源句柄提取：从 NIF term 中取出指定类型的资源指针。
// T 是句柄类型（CaskHandle / CaskIterHandle），
// rt 是对应的 ErlNifResourceType* 全局变量。
template <typename T>
T* get_resource_handle(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifResourceType* rt) noexcept;

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

// 从 Erlang map 中提取 DocInput（text 和可选 meta 字段）。
// map 必须包含 text 二进制字段，meta 二进制字段可选。
// V3.6:可选 vector 键 = f32 LE 二进制(dim×4 字节),解码进 caller 提供
// 的 vec_storage(DocInput.vector 是 span,需要外部存储),size%4 ≠ 0 或
// 非 binary → 返回 false(调用方 badarg)。其余形态错误沿旧语义静默跳过。
bool parse_doc_map(ErlNifEnv* env, ERL_NIF_TERM map_term, DocInput& doc,
                   std::vector<float>& vec_storage);

// 搜索 NIF 的统一骨架（Strategy 模式，用 std::function 承载策略）。
//
// 8 个搜索 NIF（text/phrase/fields/bool/near/fuzzy/wildcard）的前后处理完全相同：
//   取 handle → 校验 → 取 query binary → 校验 → has_search 检查 → 调用 → 错误翻译
//   / 构造 {ok, [{Key,Ord,Score}]}。
// 唯一不同的是「真正怎么搜」。把这步抽成一个闭包 invoke(Cask&, query)，由各 NIF
// 入口捕获自己的参数（k / slop / max_edit）后传入，从而把 5 份重复 impl 收敛为一处。
//
// invoke 返回 cask 层的搜索结果（含 hits）；本函数负责把它翻成 Erlang term。
using SearchInvoker =
    std::function<std::expected<TextSearchResult, CaskFault>(Cask&, std::string_view)>;
ERL_NIF_TERM run_search(ErlNifEnv* env, ERL_NIF_TERM ref_term,
                        ERL_NIF_TERM query_term, const SearchInvoker& invoke);

// fold_start / fold_start4 共用实现。
// 创建迭代器、启动快照、包装成 NIF 资源 term。
ERL_NIF_TERM fold_start_impl(ErlNifEnv* env, CaskHandle* h,
                              int maxage, int maxputs,
                              bool see_tombstones);

// V5:把 Erlang term 翻译成 MetaFilter。term 形态错/缺字段/类型不匹配
// 返回 nullptr(caller 转 badarg)。list-of-cond 形态等价 And{conditions};
// map 形态支持 logic + conditions + children 嵌套。
std::unique_ptr<bitcask::meta::MetaFilter>
parse_filter_term(ErlNifEnv* env, ERL_NIF_TERM term);

// vector<string> → Erlang string list。倒着 cons 保持原始顺序。
ERL_NIF_TERM make_string_list(ErlNifEnv* env,
                               const std::vector<std::string>& v);

// 把搜索结果（vector<SearchHit>）转换为 Erlang 的 [{Key, Ord, Score}, ...] 列表。
// 倒着遍历保持结果原始顺序（BM25 分数从高到低）。
ERL_NIF_TERM make_search_hits(ErlNifEnv* env, const std::vector<bitcask::search::SearchHit>& hits);

}  // namespace detail
}  // namespace bitcask::nif
