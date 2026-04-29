#include "atoms.hpp"

#include <erl_driver.h>  // erl_errno_id

namespace bitcask::nif {

namespace {
Atoms g_atoms;
}

void Atoms::init(ErlNifEnv* env) noexcept {
    auto a = [env](const char* s) { return enif_make_atom(env, s); };
    ok                = a("ok");
    error             = a("error");
    eof               = a("eof");
    allocation_error  = a("allocation_error");
    lock_not_writable = a("lock_not_writable");
    fstat_error       = a("fstat_error");
    ftruncate_error   = a("ftruncate_error");
    pread_error       = a("pread_error");
    pwrite_error      = a("pwrite_error");
    create            = a("create");
    readonly          = a("readonly");
    o_sync            = a("o_sync");
    cur               = a("cur");
    bof               = a("bof");
    eof_whence        = eof;  // legacy uses the same `eof` atom for whence
}

Atoms& atoms() noexcept { return g_atoms; }

ERL_NIF_TERM errno_atom(ErlNifEnv* env, int errnum) noexcept {
    return enif_make_atom(env, ::erl_errno_id(errnum));
}

ERL_NIF_TERM errno_error_tuple(ErlNifEnv* env, int errnum) noexcept {
    return enif_make_tuple2(env, g_atoms.error, errno_atom(env, errnum));
}

ERL_NIF_TERM tagged_errno_error_tuple(ErlNifEnv* env,
                                      ERL_NIF_TERM tag,
                                      int errnum) noexcept {
    return enif_make_tuple2(
        env, g_atoms.error,
        enif_make_tuple2(env, tag, errno_atom(env, errnum)));
}

}  // namespace bitcask::nif
