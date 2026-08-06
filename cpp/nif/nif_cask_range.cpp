// 粗粒度 cask_* NIF — v5.1.0 S33-5 的 OKI 有序 range 迭代器。
//
// 与 fold/iterator 两条链路的定位差别：
//   fold      = 全表 + **快照一致**（keydir 冻结），代价 O(全表)。
//   iterator  = 全表 + 单活跃槽位，legacy 契约。
//   range     = **[Lo, Hi) 区间 + O(range)**，一致性只到 per-key 弱一致
//               （与 parallel_scan 同档）——迭代期间的并发写可能部分可见。
//               需要快照语义的调用点应该继续用 fold。
//
// 权威来源是 OKI（有序 key 索引，派生缓存）。OKI 不可用时上游按成因拆两个码
//（6.1.0），这里原样翻译，**不合并**——两者的补救方式不同：
//   kNoIndex             本就不建（RO / merge_only 打开一个没有 OKI 的目录）
//                        → {error, no_index}，读写方式重开即建，或回退到
//                          fold + 前缀过滤。
//   kIndexRebuildFailed  试建而败（可写 open 撞 IO/环境问题）
//                        → {error, index_rebuild_failed}。⚠️ 这条意味着**库里
//                          有数据、只是索引没建起来**，当成「空库」是错的。
//
// 生命周期：资源 keep 住父 CaskHandle（见 resources.hpp 的
// CaskRangeIterHandle 注释），并在每次 next 前检查父 cask 是否已 close。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。单个迭代器**不可**跨进程并发使用
//（BEAM 侧不保证串行化，C++ 侧 CaskRangeIter 自身非线程安全）——契约与
// fold 迭代器一致：谁开的谁用。

#include <cstdint>
#include <memory>
#include <optional>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

namespace {

// range 选项 proplist → RangeOptions。
//   {lo, Binary}              区间下界（含），缺省/空 = 从头
//   {hi, Binary}              区间上界（不含），缺省/空 = 到尾
//   {prefetch, N}             N>1 才生效：一次归并 N 个 key 并发取值
//   {prefetch_threads, N}     0 = min(hardware_concurrency, 4)
//
// lo/hi 的 span 借用 caller 的 ErlNifBinary，只在本次 NIF 调用内有效——
// 这没问题：make_range_iter 里 lo 仅用于建游标时 seek，hi 被拷进迭代器
// 自己的 std::string。不识别的键静默跳过，与 open/2 的选项语义一致。
bool parse_range_options(ErlNifEnv* env, ERL_NIF_TERM list,
                         RangeOptions& out,
                         ErlNifBinary& lo_bin, ErlNifBinary& hi_bin) {
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup) || arity != 2) continue;
        const ERL_NIF_TERM key = tup[0];
        const ERL_NIF_TERM val = tup[1];
        if (key == atoms().lo) {
            if (!ensure_binary(env, val, lo_bin)) return false;
            out.lo = as_bytes(lo_bin);
        } else if (key == atoms().hi) {
            if (!ensure_binary(env, val, hi_bin)) return false;
            out.hi = as_bytes(hi_bin);
        } else if (key == atoms().prefetch) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, val, &v)) {
                out.prefetch = static_cast<std::size_t>(v);
            }
        } else if (key == atoms().prefetch_threads) {
            ErlNifUInt64 v = 0;
            if (enif_get_uint64(env, val, &v)) {
                out.prefetch_threads = static_cast<std::size_t>(v);
            }
        }
    }
    return true;
}

// 一条 Entry → {K, V, Tstamp, Ord}。分配失败返回 0（调用方转 allocation_error）。
ERL_NIF_TERM make_range_entry(ErlNifEnv* env, const CaskRangeIter::Entry& e) {
    ERL_NIF_TERM key_bin = make_binary_checked(env, e.key);
    ERL_NIF_TERM val_bin = make_binary_checked(env, e.value);
    if (!key_bin || !val_bin) return 0;
    return enif_make_tuple4(env, key_bin, val_bin,
                            enif_make_uint64(env, e.tstamp),
                            enif_make_uint64(env, e.ord));
}

// 取出可用的 range 迭代器句柄：资源类型对、迭代器未 release、父 cask 未 close。
// 三者任一不满足时通过 out_err 给出对应的错误 term 并返回 nullptr。
CaskRangeIterHandle* live_range_handle(ErlNifEnv* env, ERL_NIF_TERM term,
                                       ERL_NIF_TERM& out_err) {
    auto* ih = cask_range_iter_handle(env, term);
    if (!ih || !ih->iter) {
        out_err = enif_make_badarg(env);
        return nullptr;
    }
    if (!ih->owner || !ih->owner->cask) {
        out_err = make_error(env, atoms().closed);
        return nullptr;
    }
    return ih;
}

}  // namespace

// =============================================================================
// range 系列
// =============================================================================

// cask_range_start(Ref, Opts) -> {ok, IterRef} | {error, Reason}
ERL_NIF_TERM nif_cask_range_start(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h || !enif_is_list(env, argv[1])) return enif_make_badarg(env);

    RangeOptions opts;
    ErlNifBinary lo_bin{}, hi_bin{};
    if (!parse_range_options(env, argv[1], opts, lo_bin, hi_bin)) {
        return enif_make_badarg(env);
    }

    auto it = h->cask->make_range_iter(opts);
    if (!it) return fault_to_term_detailed(env, it.error());

    auto term = make_resource<CaskRangeIterHandle>(
        env, g_cask_range_iter_resource_type, std::move(*it), h);
    if (!term) return make_error(env, atoms().allocation_error);
    return make_ok(env, term);
}

// cask_range_next(IterRef) -> {ok, K, V, Tstamp, Ord} | done | {error, Reason}
ERL_NIF_TERM nif_cask_range_next(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto* ih = live_range_handle(env, argv[0], err);
    if (!ih) return err;

    auto r = ih->iter->next();
    if (!r) return fault_to_term_detailed(env, r.error());
    if (!r->has_value()) return atoms().done;

    const auto& e = **r;
    ERL_NIF_TERM key_bin = make_binary_checked(env, e.key);
    ERL_NIF_TERM val_bin = make_binary_checked(env, e.value);
    if (!key_bin || !val_bin) return make_error(env, atoms().allocation_error);
    ERL_NIF_TERM tup[5] = {
        atoms().ok, key_bin, val_bin,
        enif_make_uint64(env, e.tstamp),
        enif_make_uint64(env, e.ord),
    };
    return enif_make_tuple_from_array(env, tup, 5);
}

// cask_range_next_batch(IterRef, N) -> {ok, [{K,V,Tstamp,Ord}]} | done | {error,_}
//
// C++ 侧只有单条 next()，这里在 NIF 内循环——收益是把 N 次 BEAM ↔ NIF 往返
// 压成一次（与 cask_fold_next_batch 同款权衡）。上限 1024，与 fold 批一致：
// 再大就该担心单次 NIF 调用占用调度器时间片了。
// 语义细节：**批未满也可能是到尾**——只要返回的列表比 N 短，调用方就该停。
ERL_NIF_TERM nif_cask_range_next_batch(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM err;
    auto* ih = live_range_handle(env, argv[0], err);
    if (!ih) return err;
    int batch_size = 0;
    if (!enif_get_int(env, argv[1], &batch_size) || batch_size <= 0) {
        return enif_make_badarg(env);
    }
    if (batch_size > 1024) batch_size = 1024;

    std::vector<CaskRangeIter::Entry> out;
    out.reserve(static_cast<std::size_t>(batch_size));
    for (int i = 0; i < batch_size; ++i) {
        auto r = ih->iter->next();
        if (!r) return fault_to_term_detailed(env, r.error());
        if (!r->has_value()) break;
        out.push_back(std::move(**r));
    }
    if (out.empty()) return atoms().done;

    // 倒着 cons 以保持字典序（enif_make_list_cell 是 prepend）。
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = out.rbegin(); it != out.rend(); ++it) {
        ERL_NIF_TERM entry = make_range_entry(env, *it);
        if (!entry) return make_error(env, atoms().allocation_error);
        list = enif_make_list_cell(env, entry, list);
    }
    return enif_make_tuple2(env, atoms().ok, list);
}

// cask_range_release(IterRef) -> ok。idempotent；释放后父 cask 的 keep 仍由
// 资源析构负责（这里只提前放掉 keydir pin 与 run 游标持的 fd）。
ERL_NIF_TERM nif_cask_range_release(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* ih = cask_range_iter_handle(env, argv[0]);
    if (!ih) return enif_make_badarg(env);
    ih->iter.reset();
    return atoms().ok;
}

}  // namespace bitcask::nif
