// 粗粒度 cask_* NIF 翻译层。
//
// 每个 nif_cask_* 函数都跟一条 Cask 方法 1:1 对应：
//   1. 校验 argv 的形态、把 binary/string/list 转成 C++ 类型；
//   2. 调用 Cask 方法；
//   3. 把 expected<T, CaskFault> 结果翻译成对应的 Erlang 元组。
//
// 选项以 proplist 形式传入，parse_options 把已知键解析成 CaskOptions，
// 未知键保持 legacy 的「静默忽略」语义（避免老调用方挂掉）。

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

// 从 NIF term 取出 CaskHandle 指针；类型不对返回 nullptr，调用方应回 badarg。
CaskHandle* cask_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_cask_resource_type, &obj)) return nullptr;
    return static_cast<CaskHandle*>(obj);
}

// 同上，针对 fold/3、fold/6 用的独立迭代器资源。
CaskIterHandle* cask_iter_handle(ErlNifEnv* env, ERL_NIF_TERM term) {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_cask_iter_resource_type, &obj)) return nullptr;
    return static_cast<CaskIterHandle*>(obj);
}

// 把 unique_ptr<Cask> 包成 Erlang NIF 资源 term。
// alloc 失败返回 0（调用方判断后回 allocation_error 元组）。
ERL_NIF_TERM make_cask_resource(ErlNifEnv* env, std::unique_ptr<Cask> c) {
    void* mem = enif_alloc_resource(g_cask_resource_type, sizeof(CaskHandle));
    if (!mem) return 0;
    new (mem) CaskHandle{std::move(c), nullptr};
    ERL_NIF_TERM r = enif_make_resource(env, mem);
    enif_release_resource(mem);  // 资源所有权交给 BEAM
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

// 解析 [{Key, Value} | atom, ...] 形态的选项 proplist 到 CaskOptions。
// 不识别的键直接跳过，跟 legacy 语义保持一致。
CaskOptions parse_options(ErlNifEnv* env, ERL_NIF_TERM list) {
    CaskOptions o;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        // 单 atom 形式：read_write、merge_only。
        if (enif_is_atom(env, head)) {
            if (head == atoms().read_write) o.read_write = true;
            else if (head == atoms().merge_only) {
                o.merge_only = true;
                o.read_write = true;  // merger 自己得写输出文件
            }
            continue;
        }
        // {Key, Value} 二元组形式。
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
        } else if (tup[0] == atoms().tombstone_version) {
            // 接受 0（默认）和 2（v2，墓碑里带影子 file_id）。
            // 其它值默认为 v0——保留 legacy 的容错语义。
            int v = 0;
            if (enif_get_int(env, tup[1], &v) && v == 2) {
                o.tombstone_version = 2;
            }
        } else if (tup[0] == atoms().sync_strategy) {
            // legacy 三选一：
            //   'none'        — 让 OS 决定；不做任何特殊处理
            //   'o_sync'      — open 时带 O_SYNC，每次 write 都直接落盘
            //   {seconds, N}  — 调用方负责定时调 bitcask:sync/1（cask 跟
            //                   legacy 一致，这个选项只是个语义占位）
            if (tup[1] == atoms().o_sync) {
                o.o_sync = true;
            }
            // 'none' 和 {seconds, _} 维持默认 o_sync = false。
        }
        // ---- merge 策略阈值 ----
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
    // CaskOptions::expiry_secs 同时也下推给 PolicyOptions::expiry_secs，
    // 保证 merge 触发判断和 get/iter 用同一个过期截止时间。
    if (o.expiry_secs > 0) o.policy.expiry_secs = o.expiry_secs;
    return o;
}

// CaskFault → Erlang {error, Reason} 元组。
// 部分错误 (NotFound / AlreadyExists) 历史上不带 {error, ...} 包裹，
// 直接返回单 atom——保留这个契约，调用方需要这么模式匹配。
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

// span<byte> → Erlang binary。空 span 也会分配一个 0 长 binary（有效 term）。
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

// cask_open(Dirname, Opts) -> {ok, CaskRef} | {error, Reason}
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

// cask_close(Ref) -> ok
//
// 不等 GC——立刻关闭底层 Cask 对象（释放 fd / 锁 / 删 keydir 引用）。
// Ref 之后再用就 badarg（因为 h->cask 已 reset）。
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
// get / put / delete / sync / close_write_file
// =============================================================================

// cask_get(Ref, Key) -> {ok, Value} | not_found | {error, Reason}
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

// cask_put(Ref, Key, Value) -> ok | {error, Reason}
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

// cask_delete(Ref, Key) -> ok | {error, Reason}
// 软删除：写一条墓碑 entry，空间在 merge 时回收。
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

// cask_sync(Ref) -> ok | {error, Reason}
// fsync active data file。o_sync 模式下退化为 no-op（写入时已落盘）。
ERL_NIF_TERM nif_cask_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    auto r = h->cask->sync();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// cask_close_write_file(Ref) -> ok | {error, Reason}
//
// 写完 hint trailer、释放 write.lock；Ref 仍然可用。
// 如果当前有 stateful iterator 在跑，先把它收掉——legacy 的 close+reopen
// 行为也是这样（迭代状态跟着 file lifecycle 走）。
ERL_NIF_TERM nif_cask_close_write_file(ErlNifEnv* env, int /*argc*/,
                                         const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    if (h->iter && h->iter->is_iterating()) {
        h->iter->release();
        h->iter.reset();
    }
    auto r = h->cask->close_write_file();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// =============================================================================
// fold 系列：独立 IterRef，可多个并发（每个 fold/3 / fold/6 一个）
// =============================================================================

// 3 参版本：墓碑被 NIF 内部过滤（fold/3 + list_keys 的 legacy 行为）。
ERL_NIF_TERM nif_cask_fold_start(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs, /*now_sec*/ 0,
                        /*see_tombstones*/ false);
    if (!r) return fault_to_term(env, r.error());
    if (*r == keydir::StartIterResult::kOutOfDate) return atoms().out_of_date;
    auto term = make_iter_resource(env, std::move(it));
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

// 4 参版本：把 SeeTombstones 透传下去。给 bitcask:fold/6 / fold_keys/6 用。
ERL_NIF_TERM nif_cask_fold_start4(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    const bool see_tombs = (argv[3] == atoms().atom_true);
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs, /*now_sec*/ 0, see_tombs);
    if (!r) return fault_to_term(env, r.error());
    if (*r == keydir::StartIterResult::kOutOfDate) return atoms().out_of_date;
    auto term = make_iter_resource(env, std::move(it));
    if (!term) return enif_make_tuple2(env, atoms().error, atoms().allocation_error);
    return enif_make_tuple2(env, atoms().ok, term);
}

// fold_next：精简版，只返回 {ok, K, V} 或 done / {error, _}。
// fold/3 / list_keys 用这个——不需要 file_id / offset 等元数据。
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

// fold_next_full：返回 {ok, K, V, FileId, Offset, TotalSz, Tstamp, IsTomb}。
// 8 元组里 IsTomb 标志让 SeeTombstones=true 的调用方能区分活/死 entry；
// fold_keys 用这个版本来重建带元数据的 #bitcask_entry。
ERL_NIF_TERM nif_cask_fold_next_full(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_iter_handle(env, argv[0]);
    if (!ih || !ih->iter) return enif_make_badarg(env);
    auto r = ih->iter->next();
    if (!r) return fault_to_term(env, r.error());
    if (!r->has_value()) return atoms().done;
    const auto& e = **r;
    ERL_NIF_TERM tup[8] = {
        atoms().ok,
        bytes_to_binary(env, e.key),
        bytes_to_binary(env, e.value),
        enif_make_uint(env, e.file_id),
        enif_make_uint64(env, e.offset),
        enif_make_uint(env, e.total_sz),
        enif_make_uint(env, e.tstamp),
        e.is_tombstone ? atoms().atom_true : atoms().atom_false,
    };
    return enif_make_tuple_from_array(env, tup, 8);
}

// =============================================================================
// 状态化迭代器（cask 端等价于 legacy 的 keydir_itr/itr_next/release）
//
// 跟 fold 的区别：迭代状态挂在 CaskHandle 上，调用方不用持单独的 IterRef。
// 同 cask 同时只能有一个状态化迭代器；尝试启动第二个会拿到
// {error, iteration_in_process}。这是 legacy iterator/3 的契约。
// =============================================================================

ERL_NIF_TERM nif_cask_iterator(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    int maxage, maxputs;
    if (!h || !h->cask ||
        !enif_get_int(env, argv[1], &maxage) ||
        !enif_get_int(env, argv[2], &maxputs)) {
        return enif_make_badarg(env);
    }
    if (h->iter && h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_in_process);
    }
    auto it = h->cask->make_iter();
    auto r = it->start(maxage, maxputs, /*now_sec*/ 0,
                        /*see_tombstones*/ false);
    if (!r) return fault_to_term(env, r.error());
    if (*r == keydir::StartIterResult::kOutOfDate) {
        return atoms().out_of_date;
    }
    h->iter = std::move(it);
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_iterator_next(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    if (!h->iter || !h->iter->is_iterating()) {
        return enif_make_tuple2(env, atoms().error, atoms().iteration_not_started);
    }
    auto r = h->iter->next();
    if (!r) return fault_to_term(env, r.error());
    // EOI 用 not_found——legacy iterator_next 也是这个 atom（不是 done）。
    if (!r->has_value()) return atoms().not_found;
    const auto& e = **r;
    // legacy 接收的形态是 #bitcask_entry 记录。Erlang facade 拿这 7 元组
    // 重建记录；字段顺序跟 cask_fold_next_full 一致只是少了 IsTomb——
    // iterator/3 永远 see_tombstones=false，墓碑不会出现。
    ERL_NIF_TERM tup[7] = {
        atoms().ok,
        bytes_to_binary(env, e.key),
        bytes_to_binary(env, e.value),
        enif_make_uint(env, e.file_id),
        enif_make_uint64(env, e.offset),
        enif_make_uint(env, e.total_sz),
        enif_make_uint(env, e.tstamp),
    };
    return enif_make_tuple_from_array(env, tup, 7);
}

ERL_NIF_TERM nif_cask_iterator_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    if (h->iter) {
        h->iter->release();
        h->iter.reset();
    }
    return atoms().ok;
}

// fold 资源的对应 release（fold/3 + fold/6 走的链路）。idempotent。
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
// status / needs_merge / merge / is_empty / is_frozen
// =============================================================================

// O(1) 估算：keydir 是否为空。写过任何 key 即使后来全删，估算仍然 false。
ERL_NIF_TERM nif_cask_is_empty(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    return h->cask->is_empty_estimate() ? atoms().atom_true : atoms().atom_false;
}

// keydir 是否处于 frozen 状态（fold/iterator 在跑、阻挡了快照回收）。
ERL_NIF_TERM nif_cask_is_frozen(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    return h->cask->is_frozen() ? atoms().atom_true : atoms().atom_false;
}

// status(Ref) -> {KeyCount, KeyBytes, Epoch, [{Filename,Frag,Dead,Total},...]}
// Erlang facade 只把 KeyCount + Files 透出（保持 legacy 2 元组形态）；
// KeyBytes 和 Epoch 给 NIF 直接调用方用。
ERL_NIF_TERM nif_cask_status(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
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
    return enif_make_tuple4(env,
        enif_make_uint64(env, s.key_count),
        enif_make_uint64(env, s.key_bytes),
        enif_make_uint64(env, s.epoch),
        files);
}

// needs_merge(Ref) -> false | {true, [LiveFile,...], [ExpiredFile,...]}
ERL_NIF_TERM nif_cask_needs_merge(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);
    auto n = h->cask->needs_merge();
    if (!n.needs) return atoms().atom_false;

    // vector<string> → Erlang 路径 list。倒着 cons 保持原始顺序。
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

// merge(Ref, Files) -> {ok, {Seen, Kept, Stale, Tombs}} | {error, _}
//
// 这个 NIF 在 nif_main.cpp 的注册表里挂了 ERL_NIF_DIRTY_JOB_IO_BOUND，
// 跑大目录时不会卡住 BEAM 主调度器。
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
    return enif_make_tuple2(env, atoms().ok,
        enif_make_tuple4(env,
            enif_make_uint64(env, r->records_seen),
            enif_make_uint64(env, r->records_kept),
            enif_make_uint64(env, r->records_stale),
            enif_make_uint64(env, r->records_tombs)));
}

}  // namespace bitcask::nif
