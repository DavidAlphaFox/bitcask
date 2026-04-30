#include "atoms.hpp"

#include <erl_driver.h>  // erl_errno_id

namespace bitcask::nif {

namespace {
// 模块内单例。BEAM 加载 .so 时调用 on_load → atoms().init(env)
// 把所有 atom term 一次性建好；运行期间纯读，无锁。
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
    eof_whence        = eof;  // legacy 在 whence 位置也用 `eof` atom

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
    merge_only      = a("merge_only");
    max_file_size   = a("max_file_size");
    sync_strategy   = a("sync_strategy");
    none            = a("none");
    seconds         = a("seconds");
    expiry_secs     = a("expiry_secs");
    tombstone_version = a("tombstone_version");
    key_too_large   = a("key_too_large");
    value_too_large = a("value_too_large");
    read_only       = a("read_only");
    write_locked    = a("write_locked");
    bad_crc         = a("bad_crc");

    frag_merge_trigger       = a("frag_merge_trigger");
    dead_bytes_merge_trigger = a("dead_bytes_merge_trigger");
    frag_threshold           = a("frag_threshold");
    dead_bytes_threshold     = a("dead_bytes_threshold");
    small_file_threshold     = a("small_file_threshold");
    expiry_grace_time        = a("expiry_grace_time");
    max_merge_size           = a("max_merge_size");
}

Atoms& atoms() noexcept { return g_atoms; }

// errno → atom：直接借用 erts 内置的 erl_errno_id，结果跟 Erlang
// file:read_file_info 等接口看到的 atom 完全一致。
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
