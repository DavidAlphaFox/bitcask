// priv/bitcask_cpp.so 入口。模块名必须与调用 erlang:load_nif/2
// 的 Erlang 模块（bitcask_cpp_nifs）一致。
//
// M6 之后只剩 cask_* 粗粒度 NIF；旧的 file_* / lock_* / keydir_*
// 细粒度入口随 legacy Erlang 端一并下线。
//
// NIF 函数实现分布在三个文件中：
//   nif_cask.cpp       — CRUD：open / close / get / put / delete / sync / close_write_file
//   nif_cask_iter.cpp  — 迭代：fold_* 系列 + iterator_* 系列
//   nif_cask_admin.cpp — 管理：status / needs_merge / merge / is_empty / is_frozen
// 共用辅助函数在 nif_helpers.hpp / nif_helpers.cpp（detail 命名空间）。
//
// === 线程模型 ===
// BEAM 会从多个调度线程上并发调用 NIF：
//   - kNifFuncs 中 flag = ERL_NIF_DIRTY_JOB_IO_BOUND 的入口在 dirty IO
//     scheduler 上运行，避免阻塞主调度线程（用于 open/sync/merge 等长耗时
//     操作）；
//   - flag = 0 的入口在主调度线程跑，必须 <1ms 完成，不得 block。
//   - 资源回收（cask_resource_dtor / cask_iter_resource_dtor）由 BEAM 的
//     回收线程调用，时机不可预测——析构内不得拿任何 BEAM 锁。
// on_load 在加载时单线程执行；on_unload 在 .so 卸载时单线程执行。
// 各 NIF 入口的可重入性 / 锁要求见对应的实现文件注释。

#include <new>

#include <erl_nif.h>

#include "atoms.hpp"
#include "priv_data.hpp"
#include "resources.hpp"

namespace bitcask::nif {

ERL_NIF_TERM nif_collection_open        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_close       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_put         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_get         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_delete      (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_sync        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_search_text (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_collection_search_phrase(ErlNifEnv*, int, const ERL_NIF_TERM[]);

namespace {

ErlNifFunc kNifFuncs[] = {
    {"collection_open",         1, nif_collection_open,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"collection_open",         2, nif_collection_open,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"collection_close",        1, nif_collection_close,       0},
    {"collection_put",          3, nif_collection_put,         0},
    {"collection_get",          2, nif_collection_get,         0},
    {"collection_delete",       2, nif_collection_delete,      0},
    {"collection_sync",         1, nif_collection_sync,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"collection_search_text",  3, nif_collection_search_text, 0},
    {"collection_search_phrase",3, nif_collection_search_phrase,0},
};

int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM /*load_info*/) {
    if (!register_resources(env)) return -1;
    atoms().init(env);

    auto* p = new (std::nothrow) PrivData();
    if (!p) return -1;
    *priv_data = p;
    return 0;
}

void on_unload(ErlNifEnv* /*env*/, void* priv_data) {
    delete static_cast<PrivData*>(priv_data);
}

}  // namespace
}  // namespace bitcask::nif

ERL_NIF_INIT(bitcask_cpp_nifs,
             bitcask::nif::kNifFuncs,
             &bitcask::nif::on_load,
             nullptr, nullptr,
             &bitcask::nif::on_unload)
