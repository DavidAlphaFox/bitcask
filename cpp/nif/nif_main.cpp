// priv/bitcask_cpp.so 入口。模块名必须与调用 erlang:load_nif/2
// 的 Erlang 模块（bitcask_cpp_nifs）一致。
//
// NIF 函数实现分布在三个文件中：
//   nif_cask.cpp       — CRUD：open / close / get / put / delete / sync / close_write_file + search
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

#include <cstring>
#include <exception>
#include <new>

#include <erl_nif.h>

#include "atoms.hpp"
#include "nif_helpers.hpp"
#include "priv_data.hpp"
#include "resources.hpp"

namespace bitcask::nif {
using detail::guarded;

// --- cask_* NIF 声明（KV 存储 + 搜索统一）---------------------------
ERL_NIF_TERM nif_cask_open              (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_close             (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_get               (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_put               (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_delete            (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_sync              (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_close_write_file  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_text       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_text_4     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_phrase     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_fields     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_near       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_fuzzy      (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_wildcard   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_vector     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_vector_5   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_hybrid     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_search_hybrid_5   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_encode_meta       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_decode_meta       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_start        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_start4       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next_full    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next_batch   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next_keys_batch(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_release      (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_is_empty          (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_is_frozen         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_status            (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_needs_merge       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_merge             (ErlNifEnv*, int, const ERL_NIF_TERM[]);
// v5.1.0 S33-5：OKI 有序 range 迭代器（nif_cask_range.cpp）
ERL_NIF_TERM nif_cask_range_start       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_range_next_batch  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_range_release     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
// v5.1.0 S34/S35：引擎原子批 + 多键事务（nif_cask_batch.cpp）
ERL_NIF_TERM nif_cask_put_batch_atomic  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_txn_commit        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_txn_commit_token       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_txn_commit_token_disarm(ErlNifEnv*, int, const ERL_NIF_TERM[]);
// libbitcask 6.6.0：进程级线程数上限（nif_cask_admin.cpp）
ERL_NIF_TERM nif_set_thread_limits      (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_thread_limits          (ErlNifEnv*, int, const ERL_NIF_TERM[]);

namespace {

// 函数注册表：Erlang 函数名 → C++ 实现（全部经 guarded<> 包一层，见
// nif_helpers.hpp）。
// flag=0 表示主调度线程执行（必须 <1ms）；
// flag=ERL_NIF_DIRTY_JOB_IO_BOUND 表示 dirty IO 调度器（允许长耗时）。
// cask_put / cask_delete 登记为 0，但入口会按 sync 策略 / 值大小自行
// enif_schedule_nif 到 dirty IO（nif_cask.cpp）。
ErlNifFunc kNifFuncs[] = {
    // --- cask_*：KV 存储 + 搜索（统一 API）---
    {"cask_open",              2, guarded<nif_cask_open>,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_close",             1, guarded<nif_cask_close>,            ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_get",               2, guarded<nif_cask_get>,              0},
    {"cask_put",               3, guarded<nif_cask_put>,              0},
    {"cask_delete",            2, guarded<nif_cask_delete>,           0},
    {"cask_sync",              1, guarded<nif_cask_sync>,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_close_write_file",  1, guarded<nif_cask_close_write_file>, ERL_NIF_DIRTY_JOB_IO_BOUND},
    // 搜索
    {"cask_search_text",       3, guarded<nif_cask_search_text>,     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_text",       4, guarded<nif_cask_search_text_4>,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_phrase",      3, guarded<nif_cask_search_phrase>,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_fields",      3, guarded<nif_cask_search_fields>,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_near",        4, guarded<nif_cask_search_near>,     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_fuzzy",       4, guarded<nif_cask_search_fuzzy>,    ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_wildcard",    3, guarded<nif_cask_search_wildcard>, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_vector",      4, guarded<nif_cask_search_vector>,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_vector",      5, guarded<nif_cask_search_vector_5>, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_hybrid",      4, guarded<nif_cask_search_hybrid>,   ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_search_hybrid",      5, guarded<nif_cask_search_hybrid_5>, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"cask_encode_meta",        1, guarded<nif_cask_encode_meta>,     0},
    {"cask_decode_meta",        1, guarded<nif_cask_decode_meta>,     0},
    // 迭代：fold 系列（独立 IterRef，可多个并发）
    // start 要 pin 住目录下全部 sealed data file（每个一次 open()）——
    // O(#files) 系统调用；批量 next 一次最多 1024 次 pread。两者都挂 dirty IO，
    // 单条 next / next_full 留在主调度线程（一次 pread，与 get 同档）。
    {"cask_fold_start",        3, guarded<nif_cask_fold_start>,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_start",        4, guarded<nif_cask_fold_start4>,      ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_next",         1, guarded<nif_cask_fold_next>,        0},
    {"cask_fold_next_full",    1, guarded<nif_cask_fold_next_full>,   0},
    {"cask_fold_next_batch",   2, guarded<nif_cask_fold_next_batch>,  ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_next_keys_batch", 2, guarded<nif_cask_fold_next_keys_batch>, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_release",      1, guarded<nif_cask_fold_release>,     0},
    // 管理
    {"cask_is_empty",          1, guarded<nif_cask_is_empty>,         0},
    {"cask_is_frozen",         1, guarded<nif_cask_is_frozen>,        0},
    {"cask_status",            1, guarded<nif_cask_status>,           0},
    {"cask_needs_merge",       1, guarded<nif_cask_needs_merge>,      0},
    {"cask_merge",             2, guarded<nif_cask_merge>,            ERL_NIF_DIRTY_JOB_IO_BOUND},

    // --- v5.1.0 range 迭代器 ---
    // start 要为每个 OKI run 建游标 + seek（每路一次 pread），next_batch 一次
    // 最多跑 1024 条取值——两者都可能远超 1ms，挂 dirty IO。没有单条 next：
    // prefetch > 1 时一次 next 可能触发 fill_prefetch（归并 N 个 key + 起线程），
    // 放在主调度线程上不对；6.7.0 连同它唯一的（测试）调用者一起删了。
    {"cask_range_start",       2, guarded<nif_cask_range_start>,      ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_range_next_batch",  2, guarded<nif_cask_range_next_batch>, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_range_release",     1, guarded<nif_cask_range_release>,    0},

    // --- v5.1.0 原子批 / 多键事务 ---
    // 批大小无上界 + 提交点可能 fsync，一律 dirty IO。
    {"cask_put_batch_atomic",  2, guarded<nif_cask_put_batch_atomic>, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_txn_commit",        3, guarded<nif_cask_txn_commit>,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_txn_commit",        4, guarded<nif_cask_txn_commit>,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    // 提交令牌：只分配 / 置位，主调度线程。
    {"txn_commit_token",       2, guarded<nif_txn_commit_token>,      0},
    {"txn_commit_token_disarm", 1, guarded<nif_txn_commit_token_disarm>, 0},

    // --- libbitcask 6.6.0 进程级线程上限 ---
    // 只动一把全局锁与两个整数，主调度线程即可。
    {"set_thread_limits",      2, guarded<nif_set_thread_limits>,     0},
    {"thread_limits",          0, guarded<nif_thread_limits>,         0},
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