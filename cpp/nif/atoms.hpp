// Cached atoms used across NIF translation files. Populated in on_load.

#pragma once

#include <erl_nif.h>

namespace bitcask::nif {

struct Atoms {
    ERL_NIF_TERM ok;
    ERL_NIF_TERM error;
    ERL_NIF_TERM eof;
    ERL_NIF_TERM allocation_error;
    ERL_NIF_TERM lock_not_writable;
    ERL_NIF_TERM fstat_error;
    ERL_NIF_TERM ftruncate_error;
    ERL_NIF_TERM pread_error;
    ERL_NIF_TERM pwrite_error;

    // file_open option atoms
    ERL_NIF_TERM create;
    ERL_NIF_TERM readonly;
    ERL_NIF_TERM o_sync;

    // file_position whence atoms
    ERL_NIF_TERM cur;
    ERL_NIF_TERM bof;
    ERL_NIF_TERM eof_whence;  // duplicate of `eof` but kept named for clarity

    void init(ErlNifEnv* env) noexcept;
};

// Returns the singleton atoms registered for this NIF instance.
Atoms& atoms() noexcept;

// Map errno -> atom via erts-supplied erl_errno_id().
ERL_NIF_TERM errno_atom(ErlNifEnv* env, int errnum) noexcept;

// {error, ErrnoAtom}
ERL_NIF_TERM errno_error_tuple(ErlNifEnv* env, int errnum) noexcept;

// {error, {Tag, ErrnoAtom}}
ERL_NIF_TERM tagged_errno_error_tuple(ErlNifEnv* env,
                                      ERL_NIF_TERM tag,
                                      int errnum) noexcept;

}  // namespace bitcask::nif
