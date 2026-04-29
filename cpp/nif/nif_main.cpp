// Entry point for the C++ NIF (priv/bitcask_cpp.so).
// Module name registered with ERL_NIF_INIT must match the Erlang module
// that calls erlang:load_nif/2 — here that's `bitcask_cpp_nifs`.

#include <new>

#include <erl_nif.h>

#include "atoms.hpp"
#include "priv_data.hpp"
#include "resources.hpp"

namespace bitcask::nif {

// Forward declarations for the per-file NIF entry points.
ERL_NIF_TERM nif_file_open    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_close   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_sync    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_pread   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_pwrite  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_read    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_write   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_position(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_seekbof (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_file_truncate(ErlNifEnv*, int, const ERL_NIF_TERM[]);

ERL_NIF_TERM nif_lock_acquire  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_lock_release  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_lock_readdata (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_lock_writedata(ErlNifEnv*, int, const ERL_NIF_TERM[]);

ERL_NIF_TERM nif_keydir_new0       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_new1       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_maybe_keydir_new1 (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_mark_ready (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_put_int    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_get_int    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_get_epoch  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_remove     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_copy       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_itr_int    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_itr_next_int(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_itr_release(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_info       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_release    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_keydir_trim_fstats(ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_increment_file_id (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_update_fstats     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_set_pending_delete(ErlNifEnv*, int, const ERL_NIF_TERM[]);

ERL_NIF_TERM nif_cask_open         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_close        (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_get          (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_put          (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_delete       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_sync         (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_start   (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_next    (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_fold_release (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_is_empty     (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_status       (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_needs_merge  (ErlNifEnv*, int, const ERL_NIF_TERM[]);
ERL_NIF_TERM nif_cask_merge        (ErlNifEnv*, int, const ERL_NIF_TERM[]);

namespace {

ErlNifFunc kNifFuncs[] = {
    // file I/O (M1)
    {"file_open_int",      2, nif_file_open,     0},
    {"file_close_int",     1, nif_file_close,    0},
    {"file_sync_int",      1, nif_file_sync,     0},
    {"file_pread_int",     3, nif_file_pread,    0},
    {"file_pwrite_int",    3, nif_file_pwrite,   0},
    {"file_read_int",      2, nif_file_read,     0},
    {"file_write_int",     2, nif_file_write,    0},
    {"file_position_int",  2, nif_file_position, 0},
    {"file_seekbof_int",   1, nif_file_seekbof,  0},
    {"file_truncate_int",  1, nif_file_truncate, 0},

    // lock (M1)
    {"lock_acquire_int",   2, nif_lock_acquire,   0},
    {"lock_release_int",   1, nif_lock_release,   0},
    {"lock_readdata_int",  1, nif_lock_readdata,  0},
    {"lock_writedata_int", 2, nif_lock_writedata, 0},

    // keydir (M2.4)
    {"keydir_new",            0, nif_keydir_new0,        0},
    {"keydir_new",            1, nif_keydir_new1,        0},
    {"maybe_keydir_new",      1, nif_maybe_keydir_new1,  0},
    {"keydir_mark_ready",     1, nif_keydir_mark_ready,  0},
    {"keydir_put_int",       10, nif_keydir_put_int,     0},
    {"keydir_get_int",        3, nif_keydir_get_int,     0},
    {"keydir_get_epoch",      1, nif_keydir_get_epoch,   0},
    {"keydir_remove",         3, nif_keydir_remove,      0},
    {"keydir_remove_int",     6, nif_keydir_remove,      0},
    {"keydir_copy",           1, nif_keydir_copy,        0},
    {"keydir_itr_int",        4, nif_keydir_itr_int,     0},
    {"keydir_itr_next_int",   1, nif_keydir_itr_next_int,0},
    {"keydir_itr_release",    1, nif_keydir_itr_release, 0},
    {"keydir_info",           1, nif_keydir_info,        0},
    {"keydir_release",        1, nif_keydir_release,     0},
    {"keydir_trim_fstats",    2, nif_keydir_trim_fstats, 0},
    {"increment_file_id",     1, nif_increment_file_id,  0},
    {"increment_file_id",     2, nif_increment_file_id,  0},
    {"update_fstats",         8, nif_update_fstats,      0},
    {"set_pending_delete",    2, nif_set_pending_delete, 0},

    // Coarse-grained cask_* (M3.4).
    // Long-running ones go to dirty IO scheduler so the BEAM scheduler
    // isn't blocked while a fold or merge processes a large dir.
    {"cask_open",          2, nif_cask_open,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_close",         1, nif_cask_close,       0},
    {"cask_get",           2, nif_cask_get,         0},
    {"cask_put",           3, nif_cask_put,         0},
    {"cask_delete",        2, nif_cask_delete,      0},
    {"cask_sync",          1, nif_cask_sync,        ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cask_fold_start",    3, nif_cask_fold_start,  0},
    {"cask_fold_next",     1, nif_cask_fold_next,   0},
    {"cask_fold_release",  1, nif_cask_fold_release,0},
    {"cask_is_empty",      1, nif_cask_is_empty,    0},
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
