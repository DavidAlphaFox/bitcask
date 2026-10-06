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
// 事务不提供隔离性（I）与 CAS——中间态对并发读者可见；键集重叠的并发 commit
// 无定序保证，需应用层自行串行化。
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
    enum class Kind : std::uint8_t { kPut, kRemove, kPutDoc } kind = Kind::kPut;
    std::span<const std::byte> key;
    std::span<const std::byte> value;
    const DocInput* doc = nullptr;
};

// Ops 列表 → ParsedOp 向量。接受三种形态：
//   {put, Key, Value}   写（Value 是 binary）
//   {put, Key, DocMap}  写结构化文档（text / meta / vector / fields，同 put/3）
//   {remove, Key}       删
// 任何其它形态（元数不符 / 标签不认 / 元素不是 binary）一律 false → badarg。
// 与 open/2 选项「不识别静默跳过」的宽松语义**刻意相反**：批里悄悄丢一条
// 操作会让「原子」这个词失去意义。
bool parse_ops(ErlNifEnv* env, ERL_NIF_TERM list, std::vector<ParsedOp>& out,
               std::vector<std::unique_ptr<DocSlot>>& docs) {
    if (!enif_is_list(env, list)) return false;
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        int arity = 0;
        const ERL_NIF_TERM* tup = nullptr;
        if (!enif_get_tuple(env, head, &arity, &tup)) return false;

        ParsedOp op;
        ErlNifBinary key_bin{};
        if (arity == 3 && tup[0] == atoms().put && enif_is_map(env, tup[2])) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            auto slot = std::make_unique<DocSlot>();
            if (!parse_doc_map(env, tup[2], slot->doc, slot->vec)) return false;
            op.kind = ParsedOp::Kind::kPutDoc;
            op.key  = as_bytes(key_bin);
            op.doc  = &slot->doc;
            docs.push_back(std::move(slot));
        } else if (arity == 3 && tup[0] == atoms().put) {
            ErlNifBinary val_bin{};
            if (!ensure_binary(env, tup[1], key_bin) ||
                !ensure_binary(env, tup[2], val_bin)) {
                return false;
            }
            op.kind  = ParsedOp::Kind::kPut;
            op.key   = as_bytes(key_bin);
            op.value = as_bytes(val_bin);
        } else if (arity == 2 && tup[0] == atoms().remove) {
            if (!ensure_binary(env, tup[1], key_bin)) return false;
            op.kind = ParsedOp::Kind::kRemove;
            op.key  = as_bytes(key_bin);
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
    auto h = lock_cask_checked(env, argv[0]);
    if (!h) return enif_make_badarg(env);

    std::vector<ParsedOp> parsed;
    std::vector<std::unique_ptr<DocSlot>> docs;
    if (!parse_ops(env, argv[1], parsed, docs)) return enif_make_badarg(env);
    if (parsed.empty()) return atoms().ok;   // 空批 = no-op，不碰 meta 纪元

    std::vector<Cask::BatchOp> ops;
    ops.reserve(parsed.size());
    for (const auto& p : parsed) {
        using T = Cask::BatchOp::Type;
        ops.push_back(Cask::BatchOp{
            p.kind == ParsedOp::Kind::kRemove   ? T::kRemove
            : p.kind == ParsedOp::Kind::kPutDoc ? T::kPutDoc
                                                : T::kPut,
            p.key, p.value, p.doc});
    }

    auto r = h->cask->put_batch_atomic(ops);
    if (!r) return fault_to_term(env, r.error());
    return atoms().ok;
}

// cask_txn_commit(Ref, Ops, SyncPolicy) -> ok | {error, Reason}
//   SyncPolicy :: sync_on_commit（默认，提交点显式 fsync）| no_sync
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
    for (const auto& p : parsed) {
        using T = TxnOp::Type;
        ops.push_back(TxnOp{
            p.kind == ParsedOp::Kind::kRemove   ? T::kRemove
            : p.kind == ParsedOp::Kind::kPutDoc ? T::kPutDoc
                                                : T::kPut,
            p.key, p.value, p.doc});
    }

    TxnCask txn(h->cask.get(), sync);
    auto r = txn.commit(ops);
    if (!r) return fault_to_term(env, r.error());
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
