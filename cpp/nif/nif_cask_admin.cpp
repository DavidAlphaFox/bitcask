// 粗粒度 cask_* NIF — 管理操作：status / needs_merge / merge / is_empty / is_frozen。
//
// 这组 NIF 都是只读查询（除 merge 外），不修改 cask 状态。
// merge 在 nif_main.cpp 的注册表里挂了 ERL_NIF_DIRTY_JOB_IO_BOUND，
// 跑大目录时不会卡住 BEAM 主调度器。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。

#include <string>
#include <vector>

#include "atoms.hpp"
#include "bitcask/thread_limits.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

// O(1) 估算：keydir 是否为空。写过任何 key 即使后来全删，估算仍然 false。
ERL_NIF_TERM nif_cask_is_empty(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    return h->cask->is_empty_estimate() ? atoms().atom_true : atoms().atom_false;
}

// keydir 是否被 fold/iterator pin 住（影响 pending 表合并时机）。
ERL_NIF_TERM nif_cask_is_frozen(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    return h->cask->is_frozen() ? atoms().atom_true : atoms().atom_false;
}

// status(Ref) -> {KeyCount, KeyBytes, Epoch, [{Filename,Frag,Dead,Total},...], IndexErrors}
// Erlang facade 只透出 KeyCount + Files；KeyBytes / Epoch / IndexErrors 给 NIF 直接调用方
// （IndexErrors 另由 facade index_errors/1 单独透出）。
// v1.1.0：新增 IndexErrors（s.index_errors）——异步索引 worker 吞异常计数，非零 = 索引可能陈旧。
ERL_NIF_TERM nif_cask_status(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto s = h->cask->status();
    ERL_NIF_TERM files = enif_make_list(env, 0);
    for (const auto& f : s.files) {
        ERL_NIF_TERM e = enif_make_tuple4(env,
            enif_make_string(env, f.filename.c_str(), ERL_NIF_LATIN1),
            enif_make_int(env, f.fragmented),
            enif_make_uint64(env, f.dead_bytes),
            enif_make_uint64(env, f.total_bytes));
        files = enif_make_list_cell(env, e, files);
    }
    return enif_make_tuple5(env,
        enif_make_uint64(env, s.key_count),
        enif_make_uint64(env, s.key_bytes),
        enif_make_uint64(env, s.epoch),
        files,
        enif_make_uint64(env, s.index_errors));
}

// needs_merge(Ref) -> false | {true, [LiveFile,...], [ExpiredFile,...]}
ERL_NIF_TERM nif_cask_needs_merge(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto n = h->cask->needs_merge();
    if (!n.needs) return atoms().atom_false;
    return enif_make_tuple3(env, atoms().atom_true,
                              make_string_list(env, n.files),
                              make_string_list(env, n.expired_files));
}

// merge(Ref, Files) -> {ok, {Seen, Kept, Stale, Tombs}} | {error, _}
ERL_NIF_TERM nif_cask_merge(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask || !enif_is_list(env, argv[1])) return enif_make_badarg(env);

    std::vector<std::string> files;
    if (!get_latin1_string_list(env, argv[1], files)) return enif_make_badarg(env);

    auto r = h->cask->merge(std::move(files));
    if (!r) return fault_to_term(env, r.error());
    return make_ok(env,
        enif_make_tuple4(env,
            enif_make_uint64(env, r->records_seen),
            enif_make_uint64(env, r->records_kept),
            enif_make_uint64(env, r->records_stale),
            enif_make_uint64(env, r->records_tombs)));
}

// libbitcask 6.6.0：进程级线程数上限（索引池 map worker 数 / Search 池槽数，
// 后者非 0 时兼作 TBB worker 上限 search_slots - 1）。0 = 缺省
// max(hardware_concurrency, 2)。「首个 search 库 open 定终身」：之后值不同 →
// {error, {thread_limits_frozen, {生效IW, 生效SS}}}，值相同 → ok（幂等）。
// 不碰 cask handle，纯进程级；内部加锁，可并发调用。
//
// set_thread_limits(IndexWorkers, SearchSlots) -> ok | {error, {thread_limits_frozen, {IW, SS}}}
ERL_NIF_TERM nif_set_thread_limits(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ErlNifUInt64 iw = 0, ss = 0;
    if (!enif_get_uint64(env, argv[0], &iw) || !enif_get_uint64(env, argv[1], &ss)) {
        return enif_make_badarg(env);
    }
    if (bitcask::set_thread_limits({static_cast<std::size_t>(iw),
                                    static_cast<std::size_t>(ss)})) {
        return atoms().ok;
    }
    const auto cur = bitcask::thread_limits();
    return enif_make_tuple2(env, atoms().error,
        enif_make_tuple2(env, atoms().thread_limits_frozen,
            enif_make_tuple2(env, enif_make_uint64(env, cur.index_workers),
                                  enif_make_uint64(env, cur.search_slots))));
}

// thread_limits() -> {IndexWorkers, SearchSlots}（登记原值，0 = 缺省未解析）。
ERL_NIF_TERM nif_thread_limits(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM /*argv*/[]) {
    const auto cur = bitcask::thread_limits();
    return enif_make_tuple2(env, enif_make_uint64(env, cur.index_workers),
                                 enif_make_uint64(env, cur.search_slots));
}

}  // namespace bitcask::nif
