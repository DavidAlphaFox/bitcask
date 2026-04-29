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

    bitcask_entry         = a("bitcask_entry");
    not_found             = a("not_found");
    already_exists        = a("already_exists");
    not_ready             = a("not_ready");
    ready                 = a("ready");
    out_of_date           = a("out_of_date");
    iteration_in_process  = a("iteration_in_process");
    iteration_not_started = a("iteration_not_started");
    atom_true             = a("true");
    atom_false            = a("false");
    undefined             = a("undefined");

    done            = a("done");
    read_write      = a("read_write");
    max_file_size   = a("max_file_size");
    expiry_secs     = a("expiry_secs");
    key_too_large   = a("key_too_large");
    value_too_large = a("value_too_large");
    read_only       = a("read_only");
    write_locked    = a("write_locked");
    bad_crc         = a("bad_crc");
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
