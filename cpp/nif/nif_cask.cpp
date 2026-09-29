// 粗粒度 cask_* NIF — CRUD 操作：open / close / get / put / delete / sync / close_write_file。
// Phase 6 统一后：put 支持 binary（KV）和 map（search-doc）两种形态，
// 并新增 cask_search_text / cask_search_phrase 搜索 NIF。

#include <memory>
#include <string>
#include <vector>

#include "atoms.hpp"
#include "bitcask/meta_filter.hpp"
#include "nif_helpers.hpp"
#include "priv_data.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

ERL_NIF_TERM nif_cask_open(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    std::string dir;
    if (!get_latin1_string(env, argv[0], dir))     return enif_make_badarg(env);
    if (!enif_is_list(env, argv[1]))                return enif_make_badarg(env);

    CaskOptions opts = parse_options(env, argv[1]);
    auto* p = priv(env);
    auto c = Cask::open(dir, opts, &p->cask_registry);
    // 纪元门禁（meta v4 → v5 的 `bitcask_migrate hintord` 提示、v1/v2/v3 的
    // 「须重建」提示）与选项校验失败都只带消息——fault_to_term 会把消息带上
    //（6.7.0 起所有入口统一，见 nif_helpers.cpp）。
    if (!c) return fault_to_term(env, c.error());

    auto term = make_resource<CaskHandle>(env, g_cask_resource_type,
                                           std::move(*c));
    if (!term) return make_error(env, atoms().allocation_error);
    return make_ok(env, term);
}

ERL_NIF_TERM nif_cask_close(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto* h = cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    // unique 锁：等所有在途调用（shared 锁）退出，之后新调用按 closed 拒绝。
    // 只 close 不 reset——Cask 对象要活到资源析构，fold / range 迭代器持的是
    // 裸 parent 指针（resources.hpp）。close 幂等，重复调用是 no-op。
    std::unique_lock<std::shared_mutex> lk(h->mu);
    if (h->cask && !h->closed.load(std::memory_order_acquire)) {
        h->cask->close();
        h->closed.store(true, std::memory_order_release);
    }
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_get(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !ensure_binary(env, argv[1], key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->get(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    if (h->cask->has_search()) {
        // 索引模式：返回 #{text => Binary, meta => Binary | undefined}
        ERL_NIF_TERM map = enif_make_new_map(env);
        ERL_NIF_TERM text_val = make_binary_checked(env, r->value);
        if (!text_val) return make_error(env, atoms().allocation_error);
        enif_make_map_put(env, map, atoms().text, text_val, &map);
        ERL_NIF_TERM meta_val = r->meta.empty() ? atoms().undefined
                                               : make_binary_checked(env, r->meta);
        if (!meta_val) return make_error(env, atoms().allocation_error);
        enif_make_map_put(env, map, atoms().meta, meta_val, &map);
        return make_ok(env, map);
    }
    // KV模式：返回纯 binary（行为不变）
    ERL_NIF_TERM val_bin = make_binary_checked(env, r->value);
    if (!val_bin) return make_error(env, atoms().allocation_error);
    return make_ok(env, val_bin);
}

// put / delete 的调度：默认在普通调度器上跑（小值 + 无 sync 策略时一次 put
// 就是几微秒），但下面几种情况会把普通调度器卡住，先转到 dirty IO 再做：
//   * {sync_strategy, o_sync}：每条写 O_DSYNC；{puts, N}：每 N 条 fdatasync；
//   * value 是 map（put_doc 在调用线程上编码整个 doc + 索引）；
//   * value > 64 KiB（单次 write 已经不是"几微秒"）。
// 另外 put/remove 都要拿引擎的 write_mu_，而 dirty 上的 put_batch_atomic /
// txn_commit 会持着它做 fsync——普通调度器上等这把锁同样是卡。有 sync 策略时
// 连 delete 也转。impl 自己拿 CaskLock，先调度再锁没有问题。
namespace {

constexpr std::size_t kInlinePutMaxValue = 64 * 1024;

bool cask_has_sync_policy(const Cask& c) noexcept {
    const auto& o = c.options();
    return o.o_sync || o.sync_every_n > 0;
}

ERL_NIF_TERM nif_cask_put_impl(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_cask_delete_impl(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);

}  // namespace

ERL_NIF_TERM nif_cask_put(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    bool heavy = enif_is_map(env, argv[2]);
    if (!heavy) {
        ErlNifBinary value{};
        if (enif_inspect_binary(env, argv[2], &value) && value.size > kInlinePutMaxValue) {
            heavy = true;
        }
    }
    if (!heavy) {
        // 只为看一眼选项拿一下 shared 锁；impl 会再拿一次（不可重入但这里已放）。
        auto h = lock_cask_checked(env, argv[0]);
        if (!h) return enif_make_badarg(env);
        heavy = cask_has_sync_policy(*h->cask);
    }
    if (heavy) {
        return enif_schedule_nif(env, "cask_put", ERL_NIF_DIRTY_JOB_IO_BOUND,
                                 guarded<nif_cask_put_impl>, argc, argv);
    }
    return nif_cask_put_impl(env, argc, argv);
}

ERL_NIF_TERM nif_cask_delete(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    {
        auto h = lock_cask_checked(env, argv[0]);
        if (!h) return enif_make_badarg(env);
        if (cask_has_sync_policy(*h->cask)) {
            return enif_schedule_nif(env, "cask_delete", ERL_NIF_DIRTY_JOB_IO_BOUND,
                                     guarded<nif_cask_delete_impl>, argc, argv);
        }
    }
    return nif_cask_delete_impl(env, argc, argv);
}

namespace {

ERL_NIF_TERM nif_cask_put_impl(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    if (!h || !h->cask) return enif_make_badarg(env);

    ErlNifBinary key{};
    if (!ensure_binary(env, argv[1], key)) return enif_make_badarg(env);

    if (enif_is_binary(env, argv[2])) {
        ErlNifBinary value{};
        if (!ensure_binary(env, argv[2], value)) return enif_make_badarg(env);
        auto r = h->cask->put(as_bytes(key), as_bytes(value));
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    }

    if (enif_is_map(env, argv[2])) {
        DocInput doc;
        // V3.6:vector 键的 f32 解码缓冲(doc.vector 是 span,指向它);
        // 坏向量(非 binary / size%4≠0)→ badarg,不落盘。
        std::vector<float> vec_storage;
        if (!parse_doc_map(env, argv[2], doc, vec_storage)) {
            return enif_make_badarg(env);
        }
        auto r = h->cask->put_doc(as_bytes(key), doc);
        if (!r) return fault_to_term(env, r.error());
        return atoms().ok;
    }

    return enif_make_badarg(env);
}

ERL_NIF_TERM nif_cask_delete_impl(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary key{};
    if (!h || !h->cask || !ensure_binary(env, argv[1], key)) {
        return enif_make_badarg(env);
    }
    auto r = h->cask->remove(as_bytes(key));
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

}  // namespace

ERL_NIF_TERM nif_cask_sync(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto r = h->cask->sync();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

ERL_NIF_TERM nif_cask_close_write_file(ErlNifEnv* env, int /*argc*/,
                                         const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    if (!h) return enif_make_badarg(env);
    auto r = h->cask->close_write_file();
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// 以下 7 个搜索 NIF 都委托给 run_search 统一骨架（见 nif_helpers.hpp）：
// 各入口只负责解析自己的整型参数，再把「具体怎么搜」作为闭包传入。
// argv 约定：3 参版 = {ref, query, k}；4 参版 = {ref, query, extra, k}。

ERL_NIF_TERM nif_cask_search_text(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_text(q, k); });
}

ERL_NIF_TERM nif_cask_search_phrase(ErlNifEnv* env, int /*argc*/,
                                     const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_phrase(q, k); });
}


// S8.6：多字段搜索（field:term^boost）。
ERL_NIF_TERM nif_cask_search_fields(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view q) { return c.search_fields(q, k); });
}

// S8.7：近邻搜索（4 参：ref, query, slop, k）。slop 非负，默认 0。
ERL_NIF_TERM nif_cask_search_near(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    const auto slop = static_cast<std::uint32_t>(get_nonneg_int(env, argv[2], 0));
    const auto k    = static_cast<std::size_t>(get_topk(env, argv[3]));
    return run_search(env, argv[0], argv[1],
        [slop, k](Cask& c, std::string_view q) { return c.search_near(q, slop, k); });
}

// S8.3：模糊搜索（ref, query, max_edit_distance, k）。距离非负，默认 1。
ERL_NIF_TERM nif_cask_search_fuzzy(ErlNifEnv* env, int /*argc*/,
                                    const ERL_NIF_TERM argv[]) {
    const auto max_edit = static_cast<std::uint32_t>(get_nonneg_int(env, argv[2], 1));
    const auto k        = static_cast<std::size_t>(get_topk(env, argv[3]));
    return run_search(env, argv[0], argv[1],
        [max_edit, k](Cask& c, std::string_view q) { return c.search_fuzzy(q, k, max_edit); });
}

// S8.4：通配符搜索（ref, pattern, k）。
ERL_NIF_TERM nif_cask_search_wildcard(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    return run_search(env, argv[0], argv[1],
        [k](Cask& c, std::string_view p) { return c.search_wildcard(p, k); });
}

// V3.6:HNSW 向量检索（ref, vec_bin, k, ef）。vec_bin = f32 LE 二进制
// (dim×4 字节,与 put_doc 的 vector 键同格式);size%4≠0 → badarg;
// dim 与集合配置不符 / 无向量配置 → 经 fault_to_term({error, ...})。
// ef=0 → 引擎默认 max(k, 64)。
ERL_NIF_TERM nif_cask_search_vector(ErlNifEnv* env, int /*argc*/,
                                      const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary vec_bin{};
    if (!h || !ensure_binary(env, argv[1], vec_bin)) {
        return enif_make_badarg(env);
    }
    const auto k  = static_cast<std::size_t>(get_topk(env, argv[2]));
    const auto ef = static_cast<std::size_t>(std::min(get_nonneg_int(env, argv[3], 0), kMaxTopK));
    std::vector<float> query;
    if (!binary_to_f32vec(vec_bin, query)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_vector(query, k, ef);
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM hits = make_search_hits(env, r->hits);
    if (!hits) return make_error(env, atoms().allocation_error);
    return make_ok(env, hits);
}

// V3.6:RRF 混合检索（ref, text_bin, vec_bin, k）。vec_bin 可为 <<>>
// (纯文本退化),text_bin 可为 <<>>(纯向量退化);两者都空 →
// {error, ...}(经 Cask 的 kInvalidOption)。score = RRF 分。
ERL_NIF_TERM nif_cask_search_hybrid(ErlNifEnv* env, int /*argc*/,
                                      const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary text_bin{};
    ErlNifBinary vec_bin{};
    if (!h || !ensure_binary(env, argv[1], text_bin) ||
        !ensure_binary(env, argv[2], vec_bin)) {
        return enif_make_badarg(env);
    }
    const auto k = static_cast<std::size_t>(get_topk(env, argv[3]));
    std::vector<float> query;
    if (!binary_to_f32vec(vec_bin, query)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_hybrid(as_string_view(text_bin), query, k);
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM hits = make_search_hits(env, r->hits);
    if (!hits) return make_error(env, atoms().allocation_error);
    return make_ok(env, hits);
}

// V5:解析「可选 filter term」 — 形态为 undefined atom → 无 filter;
// 其它 term 走 parse_filter_term 翻译;解析失败 → badarg。
// 返回的 unique_ptr 在 NIF 同步生命周期内持有,filter.get() 借给 cask
// 搜索调用,本函数返回后即析构(与现有 3-arity 一样是同步调用)。
static std::unique_ptr<bitcask::meta::MetaFilter>
parse_optional_filter(ErlNifEnv* env, ERL_NIF_TERM term) {
    if (enif_is_identical(term, atoms().undefined)) {
        return nullptr;
    }
    return parse_filter_term(env, term);
}

ERL_NIF_TERM nif_cask_search_text_4(ErlNifEnv* env, int /*argc*/,
                                     const ERL_NIF_TERM argv[]) {
    const auto k = static_cast<std::size_t>(get_topk(env, argv[2]));
    auto filter = parse_optional_filter(env, argv[3]);
    if (argv[3] != atoms().undefined && !filter) return enif_make_badarg(env);
    return run_search(env, argv[0], argv[1],
        [k, &filter](Cask& c, std::string_view q) {
            return c.search_text(q, k, filter.get());
        });
}

ERL_NIF_TERM nif_cask_search_vector_5(ErlNifEnv* env, int /*argc*/,
                                       const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary vec_bin{};
    if (!h || !ensure_binary(env, argv[1], vec_bin)) {
        return enif_make_badarg(env);
    }
    const auto k  = static_cast<std::size_t>(get_topk(env, argv[2]));
    const auto ef = static_cast<std::size_t>(std::min(get_nonneg_int(env, argv[3], 0), kMaxTopK));
    auto filter = parse_optional_filter(env, argv[4]);
    if (argv[4] != atoms().undefined && !filter) return enif_make_badarg(env);
    std::vector<float> query;
    if (!binary_to_f32vec(vec_bin, query)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_vector(query, k, ef, filter.get());
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM hits = make_search_hits(env, r->hits);
    if (!hits) return make_error(env, atoms().allocation_error);
    return make_ok(env, hits);
}

ERL_NIF_TERM nif_cask_search_hybrid_5(ErlNifEnv* env, int /*argc*/,
                                       const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    ErlNifBinary text_bin{};
    ErlNifBinary vec_bin{};
    if (!h || !ensure_binary(env, argv[1], text_bin) ||
        !ensure_binary(env, argv[2], vec_bin)) {
        return enif_make_badarg(env);
    }
    const auto k = static_cast<std::size_t>(get_topk(env, argv[3]));
    auto filter = parse_optional_filter(env, argv[4]);
    if (argv[4] != atoms().undefined && !filter) return enif_make_badarg(env);
    std::vector<float> query;
    if (!binary_to_f32vec(vec_bin, query)) return enif_make_badarg(env);
    if (!h->cask->has_search()) return make_error(env, atoms().no_index);
    auto r = h->cask->search_hybrid(as_string_view(text_bin), query, k, filter.get());
    if (!r) return fault_to_term(env, r.error());
    ERL_NIF_TERM hits = make_search_hits(env, r->hits);
    if (!hits) return make_error(env, atoms().allocation_error);
    return make_ok(env, hits);
}

}  // namespace bitcask::nif