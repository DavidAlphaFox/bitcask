// NIF priv_data：每个 NIF 实例（即每个 .so 加载实例）独有的状态。
// BEAM 通过 enif_priv_data 管它的存活：on_load 里 new、on_unload 里 delete。
//
// 目前 priv_data 只放了 KeyDirRegistry —— 一个跨进程的命名 keydir 注册表，
// 让多个 Erlang 进程可以通过同一个目录名共享同一份 in-memory keydir。
//
// === 线程模型 ===
//   - 对象构造 / 析构：仅 on_load / on_unload 单线程调用。
//   - registry 字段：KeyDirRegistry 自身线程安全（内部 mutex_）。
//   - priv(env)：只读 enif_priv_data 指针，可重入、线程安全、无锁。

#pragma once

#include "bitcask/keydir_registry.hpp"

namespace bitcask::nif {

struct PrivData {
    keydir::KeyDirRegistry registry;
};

// 从 NIF 环境拿到当前 NIF 实例的 PrivData 指针。
// 不可能为 null：on_load 失败的话整个 .so 加载就失败了。
inline PrivData* priv(ErlNifEnv* env) noexcept {
    return static_cast<PrivData*>(enif_priv_data(env));
}

}  // namespace bitcask::nif
