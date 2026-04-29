// NIF translation for lock_*_int functions.
//   lock_acquire_int(Filename, IsWriteLock) -> {ok, Ref} | {error, ErrnoAtom}
//   lock_release_int(Ref)                   -> ok | badarg
//   lock_readdata_int(Ref)
//     -> {ok, Bin}
//      | {error, {fstat_error, ErrnoAtom}}
//      | {error, {pread_error, ErrnoAtom}}
//      | {error, allocation_error}
//   lock_writedata_int(Ref, Bin)
//     -> ok
//      | {error, lock_not_writable}
//      | {error, {ftruncate_error, ErrnoAtom}}
//      | {error, {pwrite_error, ErrnoAtom}}

#include "atoms.hpp"
#include "bitcask/file_lock.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {

namespace {

lock::FileLock* lock_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_lock_resource_type, &obj)) return nullptr;
    return static_cast<lock::FileLock*>(obj);
}

}  // namespace

ERL_NIF_TERM nif_lock_acquire(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string filename;
    int is_write_lock = 0;
    if (!get_latin1_string(env, argv[0], filename) ||
        !enif_get_int(env, argv[1], &is_write_lock)) {
        return enif_make_badarg(env);
    }
    auto fl = lock::FileLock::acquire(filename, is_write_lock != 0);
    if (!fl) return errno_error_tuple(env, fl.error().errnum);

    ERL_NIF_TERM ref = make_resource<lock::FileLock>(
        env, g_lock_resource_type, std::move(*fl));
    if (!ref) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, ref);
}

ERL_NIF_TERM nif_lock_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* lh = lock_handle(env, argv[0]);
    if (!lh) return enif_make_badarg(env);
    lh->release_quiet();
    return atoms().ok;
}

ERL_NIF_TERM nif_lock_readdata(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* lh = lock_handle(env, argv[0]);
    if (!lh) return enif_make_badarg(env);
    auto r = lh->read_data();
    if (!r) {
        const auto& e = r.error();
        switch (e.kind) {
        case lock::FileLock::ReadErrorKind::kFstat:
            return tagged_errno_error_tuple(env, atoms().fstat_error, e.errnum);
        case lock::FileLock::ReadErrorKind::kPread:
            return tagged_errno_error_tuple(env, atoms().pread_error, e.errnum);
        case lock::FileLock::ReadErrorKind::kAlloc:
            return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
        }
    }
    ErlNifBinary bin;
    if (!enif_alloc_binary(r->size(), &bin)) {
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    }
    if (!r->empty()) std::memcpy(bin.data, r->data(), r->size());
    return enif_make_tuple2(env, atoms().ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM nif_lock_writedata(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* lh = lock_handle(env, argv[0]);
    ErlNifBinary bin;
    if (!lh || !enif_inspect_binary(env, argv[1], &bin)) {
        return enif_make_badarg(env);
    }
    auto r = lh->write_data(as_bytes(bin));
    if (!r) {
        const auto& e = r.error();
        switch (e.kind) {
        case lock::FileLock::WriteErrorKind::kNotWritable:
            return enif_make_tuple2(env, atoms().error, atoms().lock_not_writable);
        case lock::FileLock::WriteErrorKind::kTruncate:
            return tagged_errno_error_tuple(env, atoms().ftruncate_error, e.errnum);
        case lock::FileLock::WriteErrorKind::kPwrite:
            return tagged_errno_error_tuple(env, atoms().pwrite_error, e.errnum);
        }
    }
    return atoms().ok;
}

}  // namespace bitcask::nif
