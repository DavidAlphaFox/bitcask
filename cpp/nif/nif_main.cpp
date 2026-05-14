// priv/bitcask_cpp.so 入口。模块名必须与调用 erlang:load_nif/2
// 的 Erlang 模块（bitcask_cpp_nifs）一致。
//
// M6 之后只剩 cask_* 粗粒度 NIF；旧的 file_* / lock_* / keydir_*
// 细粒度入口随 legacy Erlang 端一并下线。
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
// 各 NIF 入口的可重入性 / 锁要求见对应的 nif_cask.cpp 函数注释。

#include <new>

#include <erl_nif.h>

#include "atoms.hpp"
#include "priv_data.hpp"
#include "resources.hpp"

namespace bitcask::nif {

ERL_NIF_TERM nif_cask_open         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_close        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_get          (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_put          (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_delete       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_sync         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_close_write_file(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_start   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_start4  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_iterator     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_iterator_next(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_iterator_release(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next_full(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_release (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_is_empty     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_is_frozen    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_status       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_needs_merge  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_merge        (ErlNifEnv*, int, const ERL_NIF_TERM[]);

namespace {

// 长耗时的 fold/merge/sync/open 必须挂到 dirty IO 调度器，
// 否则会卡住 BEAM 主调度线程。
ErlNifFunc kNifFuncs[] = {
    {"cask_open",          2, nif_cask_open,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_close",         1, nif_cask_close,       0},
    {"cask_get",           2, nif_cask_get,         0},
    {"cask_put",           3, nif_cask_put,         0},
    {"cask_delete",        2, nif_cask_delete,      0},
    {"cask_sync",          1, nif_cask_sync,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_close_write_file", 1, nif_cask_close_write_file,
        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_start",    3, nif_cask_fold_start,  0},
    {"cask_fold_start",    4, nif_cask_fold_start4, 0},
    {"cask_fold_next",     1, nif_cask_fold_next,   0},
    {"cask_fold_next_full",1, nif_cask_fold_next_full, 0},
    {"cask_fold_release",  1, nif_cask_fold_release,0},
    {"cask_iterator",         3, nif_cask_iterator,         0},
    {"cask_iterator_next",    1, nif_cask_iterator_next,    0},
    {"cask_iterator_release", 1, nif_cask_iterator_release, 0},
    {"cask_is_empty",      1, nif_cask_is_empty,    0},
    {"cask_is_frozen",     1, nif_cask_is_frozen,   0},
    {"cask_status",        1, nif_cask_status,      0},
    {"cask_needs_merge",   1, nif_cask_needs_merge, 0},
    {"cask_merge",         2, nif_cask_merge,       ERL_NIF_DIRTY_JOB_IO_BOUND},
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
