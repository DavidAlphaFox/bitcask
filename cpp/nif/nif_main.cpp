// Entry point for the C++ NIF (priv/bitcask_cpp.so).
// Module name registered with ERL_NIF_INIT must match the Erlang module
// that calls erlang:load_nif/2 — here that's `bitcask_cpp_nifs`.

#include <erl_nif.h>

#include "atoms.hpp"
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

namespace {

ErlNifFunc kNifFuncs[] = {
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

    {"lock_acquire_int",   2, nif_lock_acquire,   0},
    {"lock_release_int",   1, nif_lock_release,   0},
    {"lock_readdata_int",  1, nif_lock_readdata,  0},
    {"lock_writedata_int", 2, nif_lock_writedata, 0},
};

int on_load(ErlNifEnv* env, void** /*priv_data*/, ERL_NIF_TERM /*load_info*/) {
    if (!register_resources(env)) return -1;
    atoms().init(env);
    return 0;
}

}  // namespace
}  // namespace bitcask::nif

ERL_NIF_INIT(bitcask_cpp_nifs,
             bitcask::nif::kNifFuncs,
             &bitcask::nif::on_load,
             nullptr, nullptr, nullptr)
