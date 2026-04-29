// NIF translation for keydir_*_int functions.
// Contracts mirror legacy c_src/bitcask_nifs.c:
//
//   keydir_new                       -> {ok, Ref}                         (anonymous)
//   keydir_new(Name)                 -> {ok, Ref} | {error, not_ready}
//   maybe_keydir_new(Name)           -> {ready, Ref} | {error, not_ready}
//   keydir_mark_ready(Ref)           -> ok
//   keydir_put_int(...10 args...)    -> ok | already_exists
//   keydir_get_int(Ref, K, Epoch)    -> #bitcask_entry{} | not_found
//   keydir_get_epoch(Ref)            -> uint64
//   keydir_remove(Ref, K, Tstamp)    -> ok                                (3-arg)
//   keydir_remove(...6 args...)      -> ok | already_exists               (CAS)
//   keydir_copy(Ref)                 -> {ok, NewRef}
//   keydir_itr_int(Ref, Ts, MaxAge,
//                  MaxPuts)          -> ok | out_of_date
//                                       | {error, iteration_in_process}
//   keydir_itr_next_int(Ref)         -> #bitcask_entry{} | not_found
//                                       | {error, iteration_not_started}
//   keydir_itr_release(Ref)          -> ok | {error, iteration_not_started}
//   keydir_info(Ref)                 -> {KCount,KBytes,FStats,IterInfo,Ep}
//   keydir_release(Ref)              -> ok
//   keydir_trim_fstats(Ref, IdList)  -> {ok, NonExistent}
//   increment_file_id(Ref)           -> {ok, Id}
//   increment_file_id(Ref, Cond)     -> {ok, Id}
//   update_fstats(...8 args...)      -> ok
//   set_pending_delete(Ref, FileId)  -> ok
//
// Offset is encoded as <<X:64/unsigned-native>> (8-byte binary), mirroring
// legacy. All other ints are plain enif_get_uint / enif_make_uint.

#include <cstring>
#include <string>

#include "atoms.hpp"
#include "bitcask/keydir.hpp"
#include "bitcask/keydir_registry.hpp"
#include "priv_data.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {

using keydir::AcquireResult;
using keydir::AcquireStatus;
using keydir::EntryProxy;
using keydir::FStatsEntry;
using keydir::KeyDir;
using keydir::KeyDirInfo;
using keydir::PutResult;
using keydir::StartIterResult;
using keydir::kMaxEpoch;

namespace {

// ---- Resource helpers -------------------------------------------------------

KeyDirHandle* keydir_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_keydir_resource_type, &obj)) return nullptr;
    return static_cast<KeyDirHandle*>(obj);
}

ERL_NIF_TERM make_keydir_resource(ErlNifEnv* env, KeyDirHandle&& src) {
    void* mem = enif_alloc_resource(g_keydir_resource_type, sizeof(KeyDirHandle));
    if (!mem) return 0;
    new (mem) KeyDirHandle(std::move(src));
    ERL_NIF_TERM term = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return term;
}

// ---- Term helpers -----------------------------------------------------------

// Build the 6-tuple #bitcask_entry{key,file_id,total_sz,offset(8B),tstamp}
ERL_NIF_TERM proxy_to_bitcask_entry(ErlNifEnv* env, const EntryProxy& p,
                                     ERL_NIF_TERM key_term) {
    return enif_make_tuple6(env,
        atoms().bitcask_entry,
        key_term,
        enif_make_uint(env, p.file_id),
        enif_make_uint(env, p.total_sz),
        make_uint64_bin(env, p.offset),
        enif_make_uint(env, p.tstamp));
}

// Build the legacy 5-tuple keydir_info return value.
ERL_NIF_TERM build_info_tuple(ErlNifEnv* env, const KeyDirInfo& info) {
    // FStats list: [{file_id, live_keys, total_keys, live_bytes, total_bytes,
    //                oldest_tstamp, newest_tstamp, expiration_epoch}, ...]
    ERL_NIF_TERM fstats_list = enif_make_list(env, 0);
    for (const auto& f : info.fstats) {
        ERL_NIF_TERM e = enif_make_tuple8(env,
            enif_make_uint  (env, f.file_id),
            enif_make_ulong (env, f.live_keys),
            enif_make_ulong (env, f.total_keys),
            enif_make_ulong (env, f.live_bytes),
            enif_make_ulong (env, f.total_bytes),
            enif_make_uint  (env, f.oldest_tstamp),
            enif_make_uint  (env, f.newest_tstamp),
            enif_make_uint64(env, f.expiration_epoch));
        fstats_list = enif_make_list_cell(env, e, fstats_list);
    }
    // IterInfo: {iter_generation, keyfolders, frozen?, pending_start_epoch_or_undefined}
    ERL_NIF_TERM frozen      = info.iter_info.frozen ? atoms().atom_true : atoms().atom_false;
    ERL_NIF_TERM pending_se  = info.iter_info.pending_start_epoch.has_value()
                                 ? enif_make_uint64(env, *info.iter_info.pending_start_epoch)
                                 : atoms().undefined;
    ERL_NIF_TERM iter_info = enif_make_tuple4(env,
        enif_make_uint64(env, info.iter_info.iter_generation),
        enif_make_ulong (env, info.iter_info.keyfolders),
        frozen, pending_se);

    return enif_make_tuple5(env,
        enif_make_uint64(env, info.key_count),
        enif_make_uint64(env, info.key_bytes),
        fstats_list,
        iter_info,
        enif_make_uint64(env, info.epoch));
}

// View an ErlNifBinary as a string_view of bytes.
std::string_view bin_view(const ErlNifBinary& bin) noexcept {
    return {reinterpret_cast<const char*>(bin.data), bin.size};
}

}  // namespace

// =============================================================================
// keydir_new / maybe_keydir_new / mark_ready
// =============================================================================

ERL_NIF_TERM nif_keydir_new0(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM[] /*argv*/) {
    KeyDirHandle h;
    h.keydir = std::make_shared<KeyDir>();
    // Anonymous keydirs are immediately usable; legacy doesn't enforce
    // mark_ready for unnamed ones (their is_ready stays 0 but no checks gate
    // on it for keydir_new0). We mirror that — leave is_ready false.
    ERL_NIF_TERM ref = make_keydir_resource(env, std::move(h));
    if (!ref) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, ref);
}

ERL_NIF_TERM nif_keydir_new1(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string name;
    if (!get_latin1_string(env, argv[0], name)) return enif_make_badarg(env);

    auto* p = priv(env);
    AcquireResult r = p->registry.acquire(name);
    if (r.status == AcquireStatus::kNotReady) {
        return enif_make_tuple2(env, atoms().error, atoms().not_ready);
    }
    KeyDirHandle h;
    h.keydir   = r.keydir;
    h.registry = &p->registry;
    h.name     = name;
    ERL_NIF_TERM ref = make_keydir_resource(env, std::move(h));
    if (!ref) {
        // Roll back the refcount we just took.
        p->registry.release(name);
        return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    }
    return enif_make_tuple2(env, atoms().ok, ref);
}

ERL_NIF_TERM nif_maybe_keydir_new1(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    std::string name;
    if (!get_latin1_string(env, argv[0], name)) return enif_make_badarg(env);

    auto q = priv(env)->registry.query(name);
    if (q.status == AcquireStatus::kNotReady) {
        return enif_make_tuple2(env, atoms().error, atoms().not_ready);
    }
    // Exists and ready — go ahead and acquire properly.
    return nif_keydir_new1(env, argc, argv);
}

ERL_NIF_TERM nif_keydir_mark_ready(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    h->keydir->mark_ready();
    return atoms().ok;
}

// =============================================================================
// put / get / remove
// =============================================================================

ERL_NIF_TERM nif_keydir_put_int(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    ErlNifBinary key{};
    std::uint32_t file_id, total_sz, tstamp, now_sec;
    int newest_put_int;
    std::uint32_t old_file_id;
    std::uint64_t offset, old_offset;
    if (!h || !h->keydir ||
        !enif_inspect_binary(env, argv[1], &key) ||
        !enif_get_uint   (env, argv[2], &file_id) ||
        !enif_get_uint   (env, argv[3], &total_sz) ||
        !get_uint64_bin  (env, argv[4], &offset) ||
        !enif_get_uint   (env, argv[5], &tstamp) ||
        !enif_get_uint   (env, argv[6], &now_sec) ||
        !enif_get_int    (env, argv[7], &newest_put_int) ||
        !enif_get_uint   (env, argv[8], &old_file_id) ||
        !get_uint64_bin  (env, argv[9], &old_offset)) {
        return enif_make_badarg(env);
    }

    auto r = h->keydir->put(bin_view(key), file_id, total_sz, offset, tstamp,
                            now_sec, newest_put_int != 0,
                            old_file_id, old_offset);
    return r == PutResult::kOk ? atoms().ok : atoms().already_exists;
}

ERL_NIF_TERM nif_keydir_get_int(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    ErlNifBinary key{};
    std::uint64_t epoch = kMaxEpoch;
    if (!h || !h->keydir ||
        !enif_inspect_binary(env, argv[1], &key) ||
        !enif_get_uint64(env, argv[2], &epoch)) {
        return enif_make_badarg(env);
    }
    auto v = h->keydir->get(bin_view(key), epoch);
    if (!v) return atoms().not_found;
    return proxy_to_bitcask_entry(env, *v, argv[1]);
}

ERL_NIF_TERM nif_keydir_get_epoch(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    return enif_make_uint64(env, h->keydir->get_epoch());
}

// keydir_remove (3 args, unconditional)
ERL_NIF_TERM nif_keydir_remove(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    ErlNifBinary key{};
    if (argc == 3) {
        std::uint32_t remove_time;
        if (!h || !h->keydir ||
            !enif_inspect_binary(env, argv[1], &key) ||
            !enif_get_uint(env, argv[2], &remove_time)) {
            return enif_make_badarg(env);
        }
        h->keydir->remove(bin_view(key), remove_time);
        return atoms().ok;
    }
    // Conditional 6-arg form.
    std::uint32_t tstamp, file_id, remove_time;
    std::uint64_t offset;
    if (!h || !h->keydir ||
        !enif_inspect_binary(env, argv[1], &key) ||
        !enif_get_uint(env, argv[2], &tstamp) ||
        !enif_get_uint(env, argv[3], &file_id) ||
        !get_uint64_bin(env, argv[4], &offset) ||
        !enif_get_uint(env, argv[5], &remove_time)) {
        return enif_make_badarg(env);
    }
    auto r = h->keydir->conditional_remove(bin_view(key), tstamp, file_id, offset, remove_time);
    return r == PutResult::kOk ? atoms().ok : atoms().already_exists;
}

// =============================================================================
// Iterator
// =============================================================================

ERL_NIF_TERM nif_keydir_itr_int(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    std::uint32_t ts; int maxage, maxputs;
    if (!h || !h->keydir ||
        !enif_get_uint(env, argv[1], &ts) ||
        !enif_get_int (env, argv[2], &maxage) ||
        !enif_get_int (env, argv[3], &maxputs)) {
        return enif_make_badarg(env);
    }
    if (h->iter && h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_in_process);
    }
    if (!h->iter) h->iter = h->keydir->make_iter();

    auto r = h->iter->start(ts, maxage, maxputs);
    if (r == StartIterResult::kOk) return atoms().ok;
    if (r == StartIterResult::kOutOfDate) return atoms().out_of_date;
    return enif_make_tuple2(env, atoms().error, atoms().iteration_in_process);
}

ERL_NIF_TERM nif_keydir_itr_next_int(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    if (!h->iter || !h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_not_started);
    }
    auto v = h->iter->next();
    if (!v) return atoms().not_found;

    // Build a binary copy of the key (returned key term must be standalone —
    // its lifetime is decoupled from the keydir lock).
    ErlNifBinary key_bin;
    if (!enif_alloc_binary(v->key.size(), &key_bin)) {
        return atoms().allocation_error;
    }
    if (!v->key.empty()) std::memcpy(key_bin.data, v->key.data(), v->key.size());
    ERL_NIF_TERM key_term = enif_make_binary(env, &key_bin);

    return proxy_to_bitcask_entry(env, *v, key_term);
}

ERL_NIF_TERM nif_keydir_itr_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    if (!h->iter || !h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_not_started);
    }
    h->iter->release();
    return atoms().ok;
}

// =============================================================================
// info / release / copy
// =============================================================================

ERL_NIF_TERM nif_keydir_info(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    return build_info_tuple(env, h->keydir->info());
}

ERL_NIF_TERM nif_keydir_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    h->release_quiet();
    return atoms().ok;
}

ERL_NIF_TERM nif_keydir_copy(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    KeyDirHandle copy;
    copy.keydir = h->keydir->deep_copy();
    // The deep copy is anonymous (no registry, no name) — matches legacy
    // keydir_copy which produces an unnamed/private replica.
    ERL_NIF_TERM ref = make_keydir_resource(env, std::move(copy));
    if (!ref) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, ref);
}

// =============================================================================
// fstats / file_id housekeeping
// =============================================================================

ERL_NIF_TERM nif_increment_file_id(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir) return enif_make_badarg(env);
    std::uint32_t id = 0;
    if (argc == 1) {
        id = h->keydir->increment_file_id();
    } else {
        std::uint32_t cond;
        if (!enif_get_uint(env, argv[1], &cond)) return enif_make_badarg(env);
        id = h->keydir->increment_file_id_at_least(cond);
    }
    return enif_make_tuple2(env, atoms().ok, enif_make_uint(env, id));
}

ERL_NIF_TERM nif_update_fstats(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    std::uint32_t file_id, tstamp;
    int live_inc, total_inc, live_b_inc, total_b_inc, should_create;
    if (!h || !h->keydir ||
        !enif_get_uint(env, argv[1], &file_id) ||
        !enif_get_uint(env, argv[2], &tstamp) ||
        !enif_get_int (env, argv[3], &live_inc) ||
        !enif_get_int (env, argv[4], &total_inc) ||
        !enif_get_int (env, argv[5], &live_b_inc) ||
        !enif_get_int (env, argv[6], &total_b_inc) ||
        !enif_get_int (env, argv[7], &should_create)) {
        return enif_make_badarg(env);
    }
    h->keydir->update_fstats(file_id, tstamp, kMaxEpoch,
                             live_inc, total_inc, live_b_inc, total_b_inc,
                             should_create != 0);
    return atoms().ok;
}

ERL_NIF_TERM nif_set_pending_delete(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    std::uint32_t file_id;
    if (!h || !h->keydir || !enif_get_uint(env, argv[1], &file_id)) {
        return enif_make_badarg(env);
    }
    h->keydir->set_pending_delete(file_id);
    return atoms().ok;
}

ERL_NIF_TERM nif_keydir_trim_fstats(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = keydir_handle(env, argv[0]);
    if (!h || !h->keydir || !enif_is_list(env, argv[1])) return enif_make_badarg(env);

    std::vector<std::uint32_t> ids;
    ERL_NIF_TERM head, tail = argv[1];
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        std::uint32_t v;
        if (!enif_get_uint(env, head, &v)) return enif_make_badarg(env);
        ids.push_back(v);
    }
    auto missing = h->keydir->trim_fstats(ids);
    return enif_make_tuple2(env, atoms().ok, enif_make_uint(env, missing));
}

}  // namespace bitcask::nif
