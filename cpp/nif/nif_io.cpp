// NIF translation for file_*_int functions. Contracts mirror legacy
// c_src/bitcask_nifs.c byte-for-byte:
//   file_open_int(Filename, Opts)        -> {ok, Ref} | {error, ErrnoAtom} | badarg
//   file_close_int(Ref)                  -> ok | badarg
//   file_sync_int(Ref)                   -> ok | {error, ErrnoAtom}
//   file_pread_int(Ref, Off, Sz)         -> {ok, Bin} | eof | {error, ErrnoAtom}
//                                         | {error, allocation_error}
//   file_pwrite_int(Ref, Off, Bytes)     -> ok | {error, ErrnoAtom}
//   file_read_int(Ref, Sz)               -> {ok, Bin} | eof | {error, ...}
//   file_write_int(Ref, Bytes)           -> ok | {error, ErrnoAtom}
//   file_position_int(Ref, Loc)          -> {ok, NewOfs} | {error, ErrnoAtom}
//   file_seekbof_int(Ref)                -> ok | {error, ErrnoAtom}
//   file_truncate_int(Ref)               -> ok | {error, ErrnoAtom}

#include <cstdio>  // SEEK_*
#include <cstring>
#include <variant>

#include "atoms.hpp"
#include "bitcask/io.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {

namespace {

io::PosixFile* file_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_file_resource_type, &obj)) return nullptr;
    return static_cast<io::PosixFile*>(obj);
}

io::OpenFlag parse_open_flags(ErlNifEnv* env, ERL_NIF_TERM list) {
    auto out = io::OpenFlag::kNone;
    ERL_NIF_TERM head, tail;
    while (enif_get_list_cell(env, list, &head, &tail)) {
        if      (head == atoms().create)   out = out | io::OpenFlag::kCreate;
        else if (head == atoms().readonly) out = out | io::OpenFlag::kReadOnly;
        else if (head == atoms().o_sync)   out = out | io::OpenFlag::kOSync;
        // Unknown atoms are silently ignored, matching legacy behavior.
        list = tail;
    }
    return out;
}

ERL_NIF_TERM read_result_to_term(ErlNifEnv* env, io::ReadResult&& r) {
    if (!r.has_value()) return errno_error_tuple(env, r.error().errnum);
    return std::visit(
        [&](auto&& v) -> ERL_NIF_TERM {
            using T = std::decay_t<decltype(v)>;
            if constexpr (std::is_same_v<T, io::ReadEof>) {
                return atoms().eof;
            } else {
                ErlNifBinary bin;
                if (!enif_alloc_binary(v.data.size(), &bin)) {
                    return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
                }
                if (!v.data.empty()) {
                    std::memcpy(bin.data, v.data.data(), v.data.size());
                }
                return enif_make_tuple2(env, atoms().ok,
                                        enif_make_binary(env, &bin));
            }
        },
        std::move(*r));
}

}  // namespace

ERL_NIF_TERM nif_file_open(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string filename;
    if (!get_latin1_string(env, argv[0], filename)) return enif_make_badarg(env);
    if (!enif_is_list(env, argv[1]))                return enif_make_badarg(env);

    auto flags = parse_open_flags(env, argv[1]);
    auto f = io::PosixFile::open(filename, flags);
    if (!f) return errno_error_tuple(env, f.error().errnum);

    ERL_NIF_TERM ref = make_resource<io::PosixFile>(
        env, g_file_resource_type, std::move(*f));
    if (!ref) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, ref);
}

ERL_NIF_TERM nif_file_close(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    if (!fh) return enif_make_badarg(env);
    fh->close_quiet();
    return atoms().ok;
}

ERL_NIF_TERM nif_file_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    if (!fh) return enif_make_badarg(env);
    auto r = fh->sync();
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return atoms().ok;
}

ERL_NIF_TERM nif_file_pread(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    unsigned long off = 0, count = 0;
    if (!fh ||
        !enif_get_ulong(env, argv[1], &off) ||
        !enif_get_ulong(env, argv[2], &count)) {
        return enif_make_badarg(env);
    }
    return read_result_to_term(env, fh->pread(off, count));
}

ERL_NIF_TERM nif_file_pwrite(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    unsigned long off = 0;
    ErlNifBinary bin;
    if (!fh ||
        !enif_get_ulong(env, argv[1], &off) ||
        !enif_inspect_iolist_as_binary(env, argv[2], &bin)) {
        return enif_make_badarg(env);
    }
    auto r = fh->pwrite(off, as_bytes(bin));
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return atoms().ok;
}

ERL_NIF_TERM nif_file_read(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    unsigned long count = 0;
    if (!fh || !enif_get_ulong(env, argv[1], &count)) {
        return enif_make_badarg(env);
    }
    return read_result_to_term(env, fh->read(count));
}

ERL_NIF_TERM nif_file_write(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    ErlNifBinary bin;
    if (!fh || !enif_inspect_iolist_as_binary(env, argv[1], &bin)) {
        return enif_make_badarg(env);
    }
    auto r = fh->write(as_bytes(bin));
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return atoms().ok;
}

namespace {
// Parse the `Loc` argument for file_position:
//   Offset (long)              -> SEEK_SET
//   {bof, Off} | {cur, Off} | {eof, Off}
bool parse_seek_loc(ErlNifEnv* env, ERL_NIF_TERM term,
                    long& out_off, int& out_whence) {
    if (enif_get_long(env, term, &out_off)) {
        out_whence = SEEK_SET;
        return true;
    }
    int arity = 0;
    const ERL_NIF_TERM* tup = nullptr;
    if (!enif_get_tuple(env, term, &arity, &tup) || arity != 2) return false;
    if (!enif_get_long(env, tup[1], &out_off)) return false;
    if      (tup[0] == atoms().bof)        out_whence = SEEK_SET;
    else if (tup[0] == atoms().cur)        out_whence = SEEK_CUR;
    else if (tup[0] == atoms().eof_whence) out_whence = SEEK_END;
    else return false;
    return true;
}
}  // namespace

ERL_NIF_TERM nif_file_position(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    long off = 0; int whence = 0;
    if (!fh || !parse_seek_loc(env, argv[1], off, whence)) {
        return enif_make_badarg(env);
    }
    auto r = fh->seek(off, whence);
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return enif_make_tuple2(env, atoms().ok, enif_make_ulong(env, *r));
}

ERL_NIF_TERM nif_file_seekbof(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    if (!fh) return enif_make_badarg(env);
    auto r = fh->seek_bof();
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return atoms().ok;
}

ERL_NIF_TERM nif_file_truncate(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* fh = file_handle(env, argv[0]);
    if (!fh) return enif_make_badarg(env);
    auto r = fh->truncate_here();
    if (!r) return errno_error_tuple(env, r.error().errnum);
    return atoms().ok;
}

}  // namespace bitcask::nif
