// 粗粒度 cask_* NIF — v5.1.0 S35 引擎原子批 + S34 多键事务。
//
// 两个入口，同一条底层实现（Cask::put_batch_atomic）。批内 value 可以是
// binary 或 doc map（libbitcask 6.6.2 kPutDoc，与 put/3 同形）：
//
//   cask_put_batch_atomic(Ref, Ops)      裸原子批。批内允许同 key 多次
//                                        （依序 apply = 批内 LWW），允许空批。
//   cask_txn_commit(Ref, Ops, Sync)      TxnCask::commit。多一层校验
//                                        （非空 / key 非空 / key 互不重复 /
//                                        不占用 "_txn:" 保留前缀）与提交点
//                                        fsync 策略。
//   cask_txn_commit(Ref, Ops, Sync, Token)
//                                        同上，执行期间 pin 住提交令牌。
//   txn_commit_token(Pid, TxnId)         建令牌：析构时若仍 armed 发
//                                        {txn_committed, TxnId} 给 Pid。
//   txn_commit_token_disarm(Token)       撤销通知（正常提交完成后调）。
//
// 语义（doc/atomic-batch-design-zh.md）：崩溃/掉电后**整批要么全可见要么全
// 不可见**——盘上批头声明区间，恢复时区间不完整即整批截断。原子性与持久性
// 正交：没 fsync 就掉电仍可能整批丢失，但绝不半批。
//
// ⚠️ **首次调用把目录 bitcask.meta 懒升级为 v6**。v6 目录不能被早于 5.1.0 的
// 读端打开。从不调用这两个入口的目录停留在 v5，与旧读端双向互开。
//
// 事务不提供隔离性（I）——中间态对并发读者可见。libbitcask 8.0.0（S46）起
// 批内 op 可带前置条件（absent | {ord, N}，及只校验的 {check, K, Cond}）：全部
// 条件在引擎写锁内、落盘前对照批前状态判断，任一不成立 ⇒ 整批零副作用，返回
// {error, {conflict, OpIndex}}——读-改-写的调用方重读重试即可（乐观并发）。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。两个入口都是线程安全的
//（底层 write_mu_ 串行化），但都可能写很多字节 + fsync，故挂 dirty IO 调度。

#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "atoms.hpp"
#include "bitcask/cask.hpp"
#include "bitcask/txn.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

namespace {

// 解析出来的单条操作。key/value 的 span 借用 caller 的 ErlNifBinary——
// enif_inspect_binary 给出的指针在本次 NIF 调用返回前一直有效，而
// put_batch_atomic / commit 都是同步完成的，所以不需要拷贝。
//
// libbitcask 6.6.2：value 是 doc map（形态同 put/3）时走 kPutDoc——文档与它的
// 二级索引项可以同批落盘。DocInput 与它的向量缓冲放进 DocSlot，由 unique_ptr
// 持有（地址稳定），op 只借指针。
struct DocSlot {
    DocInput doc;
    std::vector<float> vec;   // doc.vector 指向这里
};

struct ParsedOp {
    enum class Kind : std::uint8_t { kPut, kRemove, kPutDoc, kCheck } kind = Kind::kPut;
    std::span<const std::byte> key;
    std::span<const std::byte> value;
    const DocInput* doc = nullptr;
    Cask::BatchOp::Expect expect = Cask::BatchOp::Expect::kNone;
    std::uint64_t expect_ord = 0;
};

// libbitcask 8.0.0（S46）的前置条件：absent | {ord, N}。别的形态 → false。
bool parse_cond(ErlNifEnv* env, ERL_NIF_TERM term, ParsedOp& op) {
    if (term == atoms().absent) {
        op.expect = Cask::BatchOp::Expect::kAbsent;
        return true;
    }
    int arity = 0;
    const ERL_NIF_TERM* tup = nullptr;
    ErlNifUInt64 n = 0;
    if (enif_get_tuple(env, term, &arity, &tup) && arity == 2 &&
        tup[0] == atoms().ord && enif_get_uint64(env, tup[1], &n)) {
        op.expect = Cask::BatchOp::Expect::kOrdEquals;
        op.expect_ord = n;
        return true;
    }
    return false;
}

// Ops 列表 → ParsedOp 向量。接受的形态：
//   {put, Key, Value}         写（Value 是 binary）
//   {put, Key, DocMap}        写结构化文档（text / meta / vector / fields，同 put/3）
//   {remove, Key}             删
//   {put, Key, Value | DocMap, Cond}
//   {remove, Key, Cond}       同上，带前置条件（libbitcask 8.0.0 S46）
//   {check, Key, Cond}        只校验 Cond、不写
//   Cond :: absent | {ord, N}
// 任何其它形态（元数不符 / 标签不认 / 元素不是 binary / Cond 不认）一律
// false → badarg。与 open/2 选项「不识别静默跳过」的宽松语义**刻意相反**：
// 批里悄悄丢一条操作（或丢一个条件）会让「原子」这个词失去意义。
bool parse_ops(ErlNifEnv* env, ERL_NIF_TERM list, std::vector<ParsedOp>& out,
               std::vector<std::unique_ptr<DocSlot>>& docs) {
    if (!enif_is_list(env, list)) return false;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup) || arity < 2) return false;

        ParsedOp op;
        ErlNifBinary key_bin{};
        const bool is_put = tup[0] == atoms().put && (arity == 3 || arity == 4);
        if (is_put && enif_is_map(env, tup[2])) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            auto slot = std::make_unique<DocSlot>();
            if (!parse_doc_map(env, tup[2], slot->doc, slot->vec)) return false;
            op.kind = ParsedOp::Kind::kPutDoc;
            op.key  = as_bytes(key_bin);
            op.doc  = &slot->doc;
            docs.push_back(std::move(slot));
            if (arity == 4 && !parse_cond(env, tup[3], op)) return false;
        } else if (is_put) {
            ErlNifBinary val_bin{};
            if (!ensure_binary(env, tup[1], key_bin) ||
                !ensure_binary(env, tup[2], val_bin)) {
                return false;
            }
            op.kind  = ParsedOp::Kind::kPut;
            op.key   = as_bytes(key_bin);
            op.value = as_bytes(val_bin);
            if (arity == 4 && !parse_cond(env, tup[3], op)) return false;
        } else if (tup[0] == atoms().remove && (arity == 2 || arity == 3)) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            op.kind = ParsedOp::Kind::kRemove;
            op.key  = as_bytes(key_bin);
            if (arity == 3 && !parse_cond(env, tup[2], op)) return false;
        } else if (tup[0] == atoms().check && arity == 3) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            op.kind = ParsedOp::Kind::kCheck;
            op.key  = as_bytes(key_bin);
            if (!parse_cond(env, tup[2], op)) return false;
        } else {
            return false;
        }
        out.push_back(op);
    }
    // 改进列表（`[{put,K,V} | rest]`）：enif_get_list_cell 会在尾巴不是列表时
    // 安静地停下，于是前缀被当成完整的批接受。同「不静默丢弃」的理由，这里
    // 要求尾巴必须是 []。
    return enif_is_empty_list(env, tail) != 0;
}

template <typename OpT>
OpT to_engine_op(const ParsedOp& p) {
    using T = typename OpT::Type;
    OpT op{};
    op.type = p.kind == ParsedOp::Kind::kRemove   ? T::kRemove
            : p.kind == ParsedOp::Kind::kPutDoc   ? T::kPutDoc
            : p.kind == ParsedOp::Kind::kCheck    ? T::kCheck
                                                  : T::kPut;
    op.key = p.key;
    op.value = p.value;
    op.doc = p.doc;
    op.expect = p.expect;
    op.expect_ord = p.expect_ord;
    return op;
}

// 批执行失败 → Erlang 错误项。条件不成立时用 outcome 里的 op 下标拼
// {error, {conflict, OpIndex}}（OpIndex 从 1 起，对应调用方 Ops 列表里的
// 位置，同 lists:nth/2）；其它故障照常 fault_to_term。
ERL_NIF_TERM batch_error(ErlNifEnv* env, const CaskFault& f,
                         const Cask::BatchOutcome& outcome) {
    if (f.kind == CaskError::kConditionFailed &&
        outcome.failed_op != Cask::BatchOutcome::kNoFailedOp) {
        return enif_make_tuple2(
            env, atoms().error,
            enif_make_tuple2(env, atoms().conflict,
                             enif_make_uint64(env, outcome.failed_op + 1)));
    }
    return fault_to_term(env, f);
}

ERL_NIF_TERM ords_list(ErlNifEnv* env, const std::vector<std::uint64_t>& ords) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = ords.rbegin(); it != ords.rend(); ++it) {
        list = enif_make_list_cell(env, enif_make_uint64(env, *it), list);
    }
    return list;
}

}  // namespace

// =============================================================================
// 原子批 / 事务
// =============================================================================

// cask_put_batch_atomic(Ref, Ops) -> ok | {error, Reason}
// cask_put_batch_atomic(Ref, Ops, Opts) -> ok | {ok, [Ord]} | {error, Reason}
//   Opts :: [return_ords]：成功时带回每个 op 落盘记录的 LSN（与 Ops 等长，
//   check op 为 0），可直接当下一轮 {ord, N} 条件用。
//   条件不成立 → {error, {conflict, OpIndex}}，整批零副作用。
ERL_NIF_TERM nif_cask_put_batch_atomic(ErlNifEnv* env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    auto h = lock_cask_checked(env, argv[0]);
    if (!h) return enif_make_badarg(env);

    bool want_ords = false;
    if (argc == 3) {
        ERL_NIF_TERM head, tail = argv[2];
        if (!enif_is_list(env, tail)) return enif_make_badarg(env);
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            if (head == atoms().return_ords) want_ords = true;
            else return enif_make_badarg(env);
        }
        if (!enif_is_empty_list(env, tail)) return enif_make_badarg(env);
    }

    std::vector<ParsedOp> parsed;
    std::vector<std::unique_ptr<DocSlot>> docs;
    if (!parse_ops(env, argv[1], parsed, docs)) return enif_make_badarg(env);
    if (parsed.empty()) {   // 空批 = no-op，不碰 meta 纪元
        return want_ords ? make_ok(env, enif_make_list(env, 0)) : atoms().ok;
    }

    std::vector<Cask::BatchOp> ops;
    ops.reserve(parsed.size());
    for (const auto& p : parsed) ops.push_back(to_engine_op<Cask::BatchOp>(p));

    Cask::BatchOutcome outcome;
    auto r = h->cask->put_batch_atomic(ops, 0, &outcome);
    if (!r) return batch_error(env, r.error(), outcome);
    return want_ords ? make_ok(env, ords_list(env, outcome.ords)) : atoms().ok;
}

// cask_txn_commit(Ref, Ops, SyncPolicy) -> ok | {error, Reason}
//   SyncPolicy :: sync_on_commit（默认，提交点显式 fsync）| no_sync
//   Ops 形态同 cask_put_batch_atomic（含前置条件与 check op）；但 TxnCask
//   要求 key 互不重复——check 的 key 不能再出现在别的 op 里，要校验的写
//   直接把条件挂在那条 put / remove 上。条件不成立 → {error, {conflict, I}}。
//
// 校验失败（空批 / 空 key / 重复 key / "_txn:" 前缀）由 TxnCask 判定，
// 返回 kInvalidOption + 具体消息，经 fault_to_term 变成
// {error, {invalid_option, <<"...">>}}——调用方能直接看到是哪一条规则。
//
// 4 元形态 cask_txn_commit(Ref, Ops, Sync, Token)：Token 是 txn_commit_token/2
// 建的提交令牌（见 resources.hpp TxnTokenHandle）。本 NIF 执行期间 keep 住它，
// 保证"析构即批不会再动盘"。
ERL_NIF_TERM nif_cask_txn_commit(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    TxnTokenHandle* token = nullptr;
    if (argc == 4 &&
        !enif_get_resource(env, argv[3], g_txn_token_resource_type,
                           reinterpret_cast<void**>(&token))) {
        return enif_make_badarg(env);
    }
    struct TokenPin {
        TxnTokenHandle* t;
        explicit TokenPin(TxnTokenHandle* x) noexcept : t(x) { if (t) enif_keep_resource(t); }
        ~TokenPin() { if (t) enif_release_resource(t); }
    } pin{token};

    auto h = lock_cask_checked(env, argv[0]);
    if (!h) return enif_make_badarg(env);

    TxnSyncPolicy sync = TxnSyncPolicy::kSyncOnCommit;
    if (argv[2] == atoms().no_sync) {
        sync = TxnSyncPolicy::kNone;
    } else if (argv[2] != atoms().sync_on_commit) {
        return enif_make_badarg(env);
    }

    std::vector<ParsedOp> parsed;
    std::vector<std::unique_ptr<DocSlot>> docs;
    if (!parse_ops(env, argv[1], parsed, docs)) return enif_make_badarg(env);

    std::vector<TxnOp> ops;
    ops.reserve(parsed.size());
    for (const auto& p : parsed) ops.push_back(to_engine_op<TxnOp>(p));

    TxnCask txn(h->cask.get(), sync);
    Cask::BatchOutcome outcome;
    auto r = txn.commit(ops, &outcome);
    if (!r) return batch_error(env, r.error(), outcome);
    return atoms().ok;
}

// txn_commit_token(Pid, TxnId) -> Token
ERL_NIF_TERM nif_txn_commit_token(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    ErlNifPid pid{};
    ErlNifSInt64 txn_id = 0;
    if (!enif_get_local_pid(env, argv[0], &pid) ||
        !enif_get_int64(env, argv[1], &txn_id)) {
        return enif_make_badarg(env);
    }
    ERL_NIF_TERM t = make_resource<TxnTokenHandle>(env, g_txn_token_resource_type,
                                                   pid, txn_id);
    return t ? t : enif_make_badarg(env);
}

// txn_commit_token_disarm(Token) -> ok
ERL_NIF_TERM nif_txn_commit_token_disarm(ErlNifEnv* env, int /*argc*/,
                                          const ERL_NIF_TERM argv[]) {
    TxnTokenHandle* token = nullptr;
    if (!enif_get_resource(env, argv[0], g_txn_token_resource_type,
                           reinterpret_cast<void**>(&token))) {
        return enif_make_badarg(env);
    }
    token->armed.store(false, std::memory_order_release);
    return atoms().ok;
}

}  // namespace bitcask::nif
