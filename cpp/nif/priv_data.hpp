// NIF priv_data：每个 NIF 实例（即每个 .so 加载实例）独有的状态。
// BEAM 通过 enif_priv_data 管它的存活：on_load 里 new、on_unload 里 delete。
//
// 目前 priv_data 只放了 IndexRegistry —— 一个跨进程的目录级索引权威注册表，
// 让多个 Erlang 进程可以通过同一个目录名共享同一份 OKI 权威与索引池。
//
// === 线程模型 ===
//   - 对象构造 / 析构：仅 on_load / on_unload 单线程调用。
//   - registry 字段：IndexRegistry 自身线程安全（内部 mutex_）。
//   - priv(env)：只读 enif_priv_data 指针，可重入、线程安全、无锁。

#pragma once

#include "bitcask/index_registry.hpp"

namespace bitcask::nif {

struct PrivData {
    oki::IndexRegistry cask_registry;
};

inline PrivData* priv(ErlNifEnv* env) noexcept {
    return static_cast<PrivData*>(enif_priv_data(env));
}

}  // namespace bitcask::nif
