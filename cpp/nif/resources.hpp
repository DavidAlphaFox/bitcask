// Erlang NIF 资源类型注册：把 C++ 对象 placement-new 到 BEAM 分配的资源
// 缓冲区里，析构在资源 GC 回调里调用。
//
// M6 之后只剩 cask 自身和 cask 迭代器两种资源；旧的 file/lock/keydir
// 资源类型随细粒度 NIF 一并下线。
//
// === 线程模型 ===
//   - g_cask_resource_type / g_cask_iter_resource_type 仅在 on_load 阶段
//     被赋值，之后所有 NIF 入口仅读取——单写多读，race-free。
//   - register_resources：仅 on_load 调用一次，非线程安全。
//   - make_resource<T>：可重入、线程安全（enif_alloc_resource / make_resource
//     都是 BEAM 自身保证 thread-safe 的）。
//   - cask_resource_dtor / cask_iter_resource_dtor：由 BEAM 资源回收线程
//     调用，时机不可预测。必须线程安全且不可与持有该资源的 NIF 入口竞争
//     （BEAM 保证「最后一个 ref 释放后」才调 dtor，所以业务上是安全的）。

#pragma once

#include <memory>
#include <new>
#include <utility>

#include <erl_nif.h>

#include "bitcask/cask.hpp"

namespace bitcask::nif {

extern ErlNifResourceType* g_cask_resource_type;
extern ErlNifResourceType* g_cask_iter_resource_type;

// 包住 C++ Cask 对象的 NIF 资源。Cask 自己持有 KeyDir 和 active write/hint
// file，析构会顺序释放它们。
//
// `iter` 是给 legacy `iterator/3` API 用的「单 Ref 单活跃迭代器」槽位；
// fold/3 + fold/6 走另一条 CaskIterHandle 资源链路，跟这里互不影响。
struct CaskHandle {
    std::unique_ptr<Cask> cask;
    std::unique_ptr<CaskIter> iter;
};

// fold/3 + fold/6 用的独立迭代器资源；持有自己的 CaskIter，析构时由 iter
// 对象自行收尾，不持有对父 cask 的引用（父 cask 的生命周期由 BEAM 管）。
struct CaskIterHandle {
    std::unique_ptr<CaskIter> iter;
};

// 注册全部资源类型；任一注册失败返回 false。
// 线程安全: 否；仅 on_load 单线程调用一次。
[[nodiscard]] bool register_resources(ErlNifEnv* env) noexcept;

// 在 BEAM 资源缓冲区里 placement-new 构造 T，然后返回对应的 Erlang term。
// 内部会立即 release 本地 ref，剩下的生命周期完全由 BEAM 管。
// 分配失败返回 0（且不会触发 badarg，由调用方决定怎么报错）。
// 线程安全: 是（BEAM 的 enif_alloc_resource / enif_make_resource 自身
// thread-safe；T 的构造函数自身需 thread-safe，由 caller 保证）。
template <typename T, typename... Args>
ERL_NIF_TERM make_resource(ErlNifEnv* env, ErlNifResourceType* rt, Args&&... args) {
    void* mem = enif_alloc_resource(rt, sizeof(T));
    if (!mem) return 0;
    new (mem) T(std::forward<Args>(args)...);
    ERL_NIF_TERM term = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return term;
}

// enif_open_resource_type 注册的析构回调。
// 线程安全: 是（BEAM 调用前保证无 ref，安全独占该对象）；
// 调用线程不可预测，禁止内部反向调任何 BEAM 锁或拿任何阻塞资源。
void cask_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_iter_resource_dtor(ErlNifEnv* env, void* obj) noexcept;

}  // namespace bitcask::nif
