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
#include <exception>
#include <expected>
#include <functional>
#include <new>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <vector>

#include <erl_nif.h>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/meta_filter.hpp"
#include "resources.hpp"

namespace bitcask::nif {

// 跨 .cpp 共享的内部辅助函数。
namespace detail {

// 模板化的资源句柄提取：从 NIF term 中取出指定类型的资源指针。
// T 是句柄类型（CaskHandle / CaskIterHandle），
// rt 是对应的 ErlNifResourceType* 全局变量。
template <typename T>
T* get_resource_handle(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifResourceType* rt) noexcept;

// 从 NIF term 取出 CaskHandle 指针；类型不对返回 nullptr。**不加锁**——只给
// cask_close（它要拿 unique 锁）和不碰 cask 的路径用。
CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 持有 CaskHandle::mu 的 shared 锁的句柄。NIF 入口用它代替裸指针：锁在
// 入口函数返回时释放，期间 cask_close 进不来（见 resources.hpp CaskHandle）。
// 空句柄（类型不对 / 已 close）转成 nullptr，`if (!h)` 照旧。
struct CaskLock {
    CaskHandle* h = nullptr;
    std::shared_lock<std::shared_mutex> lk;
    CaskHandle* operator->() const noexcept { return h; }
    operator CaskHandle*() const noexcept { return h; }
};

// 类型对 && 未 close → 锁住并返回；否则空句柄。**所有用 cask 的入口都走这个**。
CaskLock lock_cask_checked(ErlNifEnv* env, ERL_NIF_TERM term);

// 从 NIF term 取出 CaskIterHandle 指针；类型不对返回 nullptr。
CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// v5.1.0：从 NIF term 取出 CaskRangeIterHandle 指针；类型不对返回 nullptr。
CaskRangeIterHandle* cask_range_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept;

// 解析 [{Key, Value} | atom, ...] 形态的选项 proplist 到 CaskOptions。
// 不识别的键静默跳过，与 legacy 语义一致。
CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list);

// Erlang term → MetaValue：int(int64) / float(double) / binary(string) /
// true|false(bool) / undefined(null)。其它 atom：other_atoms_as_null 为真时也当
// null（cask_encode_meta 的宽松语义），否则返回 false（filter 表达式的严格语义）。
// 其余形态返回 false。⚠️ true/false 必须先于"其它 atom"判断——以前
// nif_cask_meta.cpp 里的一份拷贝把顺序弄反，布尔被编成 null。
bool parse_meta_value(ErlNifEnv* env, ERL_NIF_TERM term,
                      bitcask::meta::MetaValue& out,
                      bool other_atoms_as_null = false);

// CaskFault → Erlang 错误 term。
// kNotFound / kAlreadyExists 返回裸 atom（legacy 契约），其余返回 {error, Tag}。
ERL_NIF_TERM fault_to_term(ErlNifEnv* env, const CaskFault& f) noexcept;

// v6.0.0：带 detail 的 CaskFault → Erlang 错误 term。
//
// 动机：libbitcask 有两类**只有消息、没有 errno/专用枚举**的故障——
// `kIo(errnum == 0)` 与 `kInvalidOption`。它们经 fault_to_term 分别塌成
// `{error, unknown}` 与 `{error, error}`，信息全丢。5.1.0 的 meta v4→v5
// flag-day 正好走这条路：open 一个旧纪元目录，用户看到的应该是那句
// 「run `bitcask_migrate hintord <src> <dst>`」，而不是 `{error, unknown}`。
//
// 本函数只对这两类附加 detail，形态 `{error, {Tag, DetailBinary}}`；
// **其余全部原样委托 fault_to_term**（尤其 kWriteLocked 保持裸
// `{error, write_locked}` —— bitcask.erl 的 merge_locked 映射精确匹配它）。
ERL_NIF_TERM fault_to_term_detailed(ErlNifEnv* env, const CaskFault& f) noexcept;

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
// 分配失败返回 0（无效 term）——以前是 continue 悄悄丢掉那条 hit，调用方拿到
// 一个短了的列表却没有任何错误。
ERL_NIF_TERM make_search_hits(ErlNifEnv* env, const std::vector<bitcask::search::SearchHit>& hits);

// 异常屏障：C++ 异常穿过 NIF 边界就是 std::terminate——整个节点没了。上游
// 索引路径文档化了 bad_alloc（cask.hpp），本层也到处 std::vector / std::string，
// 调用方一个夸张的参数（大 k、大 prefetch）就能触发。函数表里每个入口都套
// 一层，enif_schedule_nif 转到 dirty 调度器的那份 impl 也要套：
//   bad_alloc      → {error, allocation_error}
//   std::exception → {error, {exception, What}}
//   其它           → {error, {exception, <<"unknown">>}}
// 参数校验用的 enif_make_badarg 是返回值不是异常，不受影响。
using NifFn = ERL_NIF_TERM (*)(ErlNifEnv*, int, const ERL_NIF_TERM[]);

ERL_NIF_TERM exception_term(ErlNifEnv* env, const char* what) noexcept;

template <NifFn F>
ERL_NIF_TERM guarded(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) noexcept {
    try {
        return F(env, argc, argv);
    } catch (const std::bad_alloc&) {
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    } catch (const std::exception& e) {
        return exception_term(env, e.what());
    } catch (...) {
        return exception_term(env, "unknown");
    }
}

}  // namespace detail
}  // namespace bitcask::nif
