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

    // keydir atoms
    ERL_NIF_TERM bitcask_entry;
    ERL_NIF_TERM not_found;
    ERL_NIF_TERM already_exists;
    ERL_NIF_TERM not_ready;
    ERL_NIF_TERM ready;
    ERL_NIF_TERM out_of_date;
    ERL_NIF_TERM iteration_in_process;
    ERL_NIF_TERM iteration_not_started;
    ERL_NIF_TERM atom_true;
    ERL_NIF_TERM atom_false;
    ERL_NIF_TERM undefined;

    // cask_* atoms
    ERL_NIF_TERM done;
    ERL_NIF_TERM read_write;
    ERL_NIF_TERM max_file_size;
    ERL_NIF_TERM expiry_secs;
    ERL_NIF_TERM key_too_large;
    ERL_NIF_TERM value_too_large;
    ERL_NIF_TERM read_only;
    ERL_NIF_TERM write_locked;
    ERL_NIF_TERM bad_crc;

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
