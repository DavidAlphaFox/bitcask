// Erlang NIF 资源类型注册：把 C++ 对象 placement-new 到 BEAM 分配的资源
// 缓冲区里，析构在资源 GC 回调里调用。
//
// M6 之后只剩 cask 自身和 cask 迭代器两种资源；旧的 file/lock/keydir
// 资源类型随细粒度 NIF 一并下线。

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
[[nodiscard]] bool register_resources(ErlNifEnv* env) noexcept;

// 在 BEAM 资源缓冲区里 placement-new 构造 T，然后返回对应的 Erlang term。
// 内部会立即 release 本地 ref，剩下的生命周期完全由 BEAM 管。
// 分配失败返回 0（且不会触发 badarg，由调用方决定怎么报错）。
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
void cask_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_iter_resource_dtor(ErlNifEnv* env, void* obj) noexcept;

}  // namespace bitcask::nif
