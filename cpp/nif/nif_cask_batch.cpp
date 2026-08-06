// 粗粒度 cask_* NIF — v5.1.0 S35 引擎原子批 + S34 多键事务。
//
// 两个入口，同一条底层实现（Cask::put_batch_atomic）：
//
//   cask_put_batch_atomic(Ref, Ops)      裸原子批。批内允许同 key 多次
//                                        （依序 apply = 批内 LWW），允许空批。
//   cask_txn_commit(Ref, Ops, Sync)      TxnCask::commit。多一层校验
//                                        （非空 / key 非空 / key 互不重复 /
//                                        不占用 "_txn:" 保留前缀）与提交点
//                                        fsync 策略。
//
// 语义（doc/atomic-batch-design-zh.md）：崩溃/掉电后**整批要么全可见要么全
// 不可见**——盘上批头声明区间，恢复时区间不完整即整批截断。原子性与持久性
// 正交：没 fsync 就掉电仍可能整批丢失，但绝不半批。
//
// ⚠️ **首次调用把目录 bitcask.meta 懒升级为 v6**。v6 目录不能被早于 5.1.0 的
// 读端打开。从不调用这两个入口的目录停留在 v5，与旧读端双向互开。
//
// 事务不提供隔离性（I）与 CAS——中间态对并发读者可见；键集重叠的并发 commit
// 无定序保证，需应用层自行串行化。
//
// 线程模型见 nif_main.cpp 顶部的统一说明。两个入口都是线程安全的
//（底层 write_mu_ 串行化），但都可能写很多字节 + fsync，故挂 dirty IO 调度。

#include <cstdint>
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
struct ParsedOp {
    bool remove = false;
    std::span<const std::byte> key;
    std::span<const std::byte> value;
};

// Ops 列表 → ParsedOp 向量。接受两种形态：
//   {put, Key, Value}   写
//   {remove, Key}       删
// 任何其它形态（元数不符 / 标签不认 / 元素不是 binary）一律 false → badarg。
// 与 open/2 选项「不识别静默跳过」的宽松语义**刻意相反**：批里悄悄丢一条
// 操作会让「原子」这个词失去意义。
bool parse_ops(ErlNifEnv* env, ERL_NIF_TERM list, std::vector<ParsedOp>& out) {
    if (!enif_is_list(env, list)) return false;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup)) return false;

        ParsedOp op;
        ErlNifBinary key_bin{};
        if (arity == 3 && tup[0] == atoms().put) {
            ErlNifBinary val_bin{};
            if (!ensure_binary(env, tup[1], key_bin) ||
                !ensure_binary(env, tup[2], val_bin)) {
                return false;
            }
            op.remove = false;
            op.key    = as_bytes(key_bin);
            op.value  = as_bytes(val_bin);
        } else if (arity == 2 && tup[0] == atoms().remove) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            op.remove = true;
            op.key    = as_bytes(key_bin);
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

}  // namespace

// =============================================================================
// 原子批 / 事务
// =============================================================================

// cask_put_batch_atomic(Ref, Ops) -> ok | {error, Reason}
ERL_NIF_TERM nif_cask_put_batch_atomic(ErlNifEnv* env, int /*argc*/,
                                        const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);

    std::vector<ParsedOp> parsed;
    if (!parse_ops(env, argv[1], parsed)) return enif_make_badarg(env);
    if (parsed.empty()) return atoms().ok;   // 空批 = no-op，不碰 meta 纪元

    std::vector<Cask::BatchOp> ops;
    ops.reserve(parsed.size());
    for (const auto& p : parsed) {
        ops.push_back(Cask::BatchOp{
            p.remove ? Cask::BatchOp::Type::kRemove : Cask::BatchOp::Type::kPut,
            p.key, p.value});
    }

    auto r = h->cask->put_batch_atomic(ops);
    if (!r) return fault_to_term_detailed(env, r.error());
    return atoms().ok;
}

// cask_txn_commit(Ref, Ops, SyncPolicy) -> ok | {error, Reason}
//   SyncPolicy :: sync_on_commit（默认，提交点显式 fsync）| no_sync
//
// 校验失败（空批 / 空 key / 重复 key / "_txn:" 前缀）由 TxnCask 判定，
// 返回 kInvalidOption + 具体消息，经 fault_to_term_detailed 变成
// {error, {invalid_option, <<"...">>}}——调用方能直接看到是哪一条规则。
ERL_NIF_TERM nif_cask_txn_commit(ErlNifEnv* env, int /*argc*/,
                                  const ERL_NIF_TERM argv[]) {
    auto* h = checked_cask_handle(env, argv[0]);
    if (!h) return enif_make_badarg(env);

    TxnSyncPolicy sync = TxnSyncPolicy::kSyncOnCommit;
    if (argv[2] == atoms().no_sync) {
        sync = TxnSyncPolicy::kNone;
    } else if (argv[2] != atoms().sync_on_commit) {
        return enif_make_badarg(env);
    }

    std::vector<ParsedOp> parsed;
    if (!parse_ops(env, argv[1], parsed)) return enif_make_badarg(env);

    std::vector<TxnOp> ops;
    ops.reserve(parsed.size());
    for (const auto& p : parsed) {
        ops.push_back(TxnOp{
            p.remove ? TxnOp::Type::kRemove : TxnOp::Type::kPut,
            p.key, p.value});
    }

    TxnCask txn(h->cask.get(), sync);
    auto r = txn.commit(ops);
    if (!r) return fault_to_term_detailed(env, r.error());
    return atoms().ok;
}

}  // namespace bitcask::nif
