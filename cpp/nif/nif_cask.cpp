// NIF translation for the coarse-grained cask_* API. Each function maps
// 1:1 to a Cask method; opts come in as a proplist.

#include <cstring>
#include <string>
#include <vector>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "priv_data.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {

namespace {

CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_cask_resource_type, &obj)) return nullptr;
    return static_cast<CaskHandle*>(obj);
}

CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_cask_iter_resource_type, &obj)) return nullptr;
    return static_cast<CaskIterHandle*>(obj);
}

ERL_NIF_TERM make_cask_resource(ErlNifEnv* env, std::unique_ptr<Cask> c) {
    void* mem = enif_alloc_resource(g_cask_resource_type, sizeof(CaskHandle));
    if (!mem) return 0;
    new (mem) CaskHandle{std::move(c)};
    ERL_NIF_TERM r = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return r;
}

ERL_NIF_TERM make_iter_resource(ErlNifEnv* env, std::unique_ptr<CaskIter> it) {
    void* mem = enif_alloc_resource(g_cask_iter_resource_type, sizeof(CaskIterHandle));
    if (!mem) return 0;
    new (mem) CaskIterHandle{std::move(it)};
    ERL_NIF_TERM r = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return r;
}

// Parse a {Key, Value} proplist into CaskOptions. Unknown keys are ignored.
CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list) {
    CaskOptions o;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        // Atom-only option (e.g. read_write, merge_only).
        if (enif_is_atom(env, head)) {
            if (head == atoms().read_write) o.read_write = true;
            else if (head == atoms().merge_only) {
                o.merge_only = true;
                o.read_write = true;  // merger needs to write its output file
            }
            continue;
        }
        // Tuple {Key, Value}.
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup) || arity != 2) continue;
        if (tup[0] == atoms().read_write) {
            o.read_write = (tup[1] == atoms().atom_true);
        } else if (tup[0] == atoms().max_file_size) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, tup[1], &v)) o.max_file_size = v;
        } else if (tup[0] == atoms().expiry_secs) {
            int v = 0;
            if (enif_get_int(env, tup[1], &v) && v > 0) {
                o.expiry_secs = static_cast<std::uint32_t>(v);
            }
        }
        // ---- merge policy options ----
        else if (tup[0] == atoms().frag_merge_trigger) {
            int v = 0;
            if (enif_get_int(env, tup[1], &v)) o.policy.frag_merge_trigger = v;
        } else if (tup[0] == atoms().dead_bytes_merge_trigger) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, tup[1], &v)) o.policy.dead_bytes_merge_trigger = v;
        } else if (tup[0] == atoms().frag_threshold) {
            int v = 0;
            if (enif_get_int(env, tup[1], &v)) o.policy.frag_threshold = v;
        } else if (tup[0] == atoms().dead_bytes_threshold) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, tup[1], &v)) o.policy.dead_bytes_threshold = v;
        } else if (tup[0] == atoms().small_file_threshold) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, tup[1], &v)) o.policy.small_file_threshold = v;
        } else if (tup[0] == atoms().expiry_grace_time) {
            int v = 0;
            if (enif_get_int(env, tup[1], &v) && v >= 0) {
                o.policy.expiry_grace_time = static_cast<std::uint32_t>(v);
            }
        } else if (tup[0] == atoms().max_merge_size) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, tup[1], &v)) o.policy.max_merge_size = v;
        }
    }
    // expiry_secs in CaskOptions also drives PolicyOptions::expiry_secs so
    // the merge trigger sees the same cutoff.
    if (o.expiry_secs > 0) o.policy.expiry_secs = o.expiry_secs;
    return o;
}

ERL_NIF_TERM fault_to_term(ErlNifEnv* env, const CaskFault& f) {
    ERL_NIF_TERM tag;
    switch (f.kind) {
        case CaskError::kIo:             tag = errno_atom(env, f.errnum); break;
        case CaskError::kBadCrc:         tag = atoms().bad_crc; break;
        case CaskError::kNotFound:       return atoms().not_found;
        case CaskError::kKeyTooLarge:    tag = atoms().key_too_large; break;
        case CaskError::kValueTooLarge:  tag = atoms().value_too_large; break;
        case CaskError::kAlreadyExists:  return atoms().already_exists;
        case CaskError::kReadOnly:       tag = atoms().read_only; break;
        case CaskError::kWriteLocked:    tag = atoms().write_locked; break;
        case CaskError::kInvalidOption:
        default:                          tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
}

ERL_NIF_TERM bytes_to_binary(ErlNifEnv* env, std::span<const std::byte> b) {
    ErlNifBinary bin;
    enif_alloc_binary(b.size(), &bin);
    if (!b.empty()) std::memcpy(bin.data, b.data(), b.size());
    return enif_make_binary(env, &bin);
}

}  // namespace

// =============================================================================
// cask_open / cask_close
// =============================================================================

ERL_NIF_TERM nif_cask_open(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string dir;
    if (!get_latin1_string(env, argv[0], dir))     return enif_make_badarg(env);
    if (!enif_is_list(env, argv[1]))                return enif_make_badarg(env);

    CaskOptions opts = parse_options(env, argv[1]);
    auto* p = priv(env);
    auto c = Cask::open(dir, opts, &p->registry);
    if (!c) return fault_to_term(env, c.error());

    auto term = make_cask_resource(env, std::move(*c));
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

ERL_NIF_TERM nif_cask_close(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->cask) {
        h->cask->close();
        h->cask.reset();
    }
    return atoms().ok;
}

// =============================================================================
// get / put / delete / sync
// =============================================================================

ERL_NIF_TERM nif_cask_get(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !enif_inspect_binary(env, argv[1], &key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->get(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    return enif_make_tuple2(env, atoms().ok, bytes_to_binary(env, r->value));
}

ERL_NIF_TERM nif_cask_put(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{}, value{};
    if (!h || !h->cask ||
        !enif_inspect_binary(env, argv[1], &key) ||
        !enif_inspect_binary(env, argv[2], &value)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->put(as_bytes(key), as_bytes(value));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_delete(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !enif_inspect_binary(env, argv[1], &key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->remove(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    auto r = h->cask->sync();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// =============================================================================
// Iterator
// =============================================================================

ERL_NIF_TERM nif_cask_fold_start(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs);
    if (!r) return fault_to_term(env, r.error());
    auto term = make_iter_resource(env, std::move(it));
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

ERL_NIF_TERM nif_cask_fold_next(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih || !ih->iter) return enif_make_badarg(env);
    auto r = ih->iter->next();
    if (!r) return fault_to_term(env, r.error());
    if (!r->has_value()) return atoms().done;
    return enif_make_tuple3(env, atoms().ok,
                             bytes_to_binary(env, (*r)->key),
                             bytes_to_binary(env, (*r)->value));
}

ERL_NIF_TERM nif_cask_fold_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih) return enif_make_badarg(env);
    if (ih->iter) {
        ih->iter->release();
        ih->iter.reset();
    }
    return atoms().ok;
}

// =============================================================================
// status / needs_merge / merge / is_empty
// =============================================================================

ERL_NIF_TERM nif_cask_is_empty(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    return h->cask->is_empty_estimate() ? atoms().atom_true : atoms().atom_false;
}

ERL_NIF_TERM nif_cask_status(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    auto s = h->cask->status();
    // {KeyCount, KeyBytes, Epoch, [{Filename,Frag,Dead,Total},...]}
    ERL_NIF_TERM files = enif_make_list(env, 0);
    for (const auto& f : s.files) {
        ERL_NIF_TERM e = enif_make_tuple4(env,
            enif_make_string(env, f.filename.c_str(), ERL_NIF_LATIN1),
            enif_make_int(env, f.fragmented),
            enif_make_uint64(env, f.dead_bytes),
            enif_make_uint64(env, f.total_bytes));
        files = enif_make_list_cell(env, e, files);
    }
    return enif_make_tuple4(env,
        enif_make_uint64(env, s.key_count),
        enif_make_uint64(env, s.key_bytes),
        enif_make_uint64(env, s.epoch),
        files);
}

ERL_NIF_TERM nif_cask_needs_merge(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    auto n = h->cask->needs_merge();
    if (!n.needs) return atoms().atom_false;

    auto path_list = [&](const std::vector<std::string>& v) {
        ERL_NIF_TERM list = enif_make_list(env, 0);
        for (auto it = v.rbegin(); it != v.rend(); ++it) {
            list = enif_make_list_cell(env,
                enif_make_string(env, it->c_str(), ERL_NIF_LATIN1), list);
        }
        return list;
    };
    return enif_make_tuple3(env, atoms().atom_true,
                              path_list(n.files),
                              path_list(n.expired_files));
}

ERL_NIF_TERM nif_cask_merge(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask || !enif_is_list(env, argv[1])) return enif_make_badarg(env);

    std::vector<std::string> files;
    ERL_NIF_TERM head, tail = argv[1];
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        std::string s;
        if (!get_latin1_string(env, head, s)) return enif_make_badarg(env);
        files.push_back(std::move(s));
    }

    auto r = h->cask->merge(std::move(files));
    if (!r) return fault_to_term(env, r.error());
    // {ok, {SeenMany, Kept, Stale, Tombs}}
    return enif_make_tuple2(env, atoms().ok,
        enif_make_tuple4(env,
            enif_make_uint64(env, r->records_seen),
            enif_make_uint64(env, r->records_kept),
            enif_make_uint64(env, r->records_stale),
            enif_make_uint64(env, r->records_tombs)));
}

}  // namespace bitcask::nif
