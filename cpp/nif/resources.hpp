// Erlang NIF 资源类型注册：把 C++ 对象 placement-new 到 BEAM 分配的资源
// 缓冲区里，析构在资源 GC 回调里调用。
//
// M6 之后只剩 cask 自身和 cask 迭代器两种资源；旧的 file/lock/keydir
// 资源类型随细粒度 NIF 一并下线。
//
// === 线程模型 ===
//   - g_cask_resource_type / g_cask_iter_resource_type 仅在 on_load 阶段
//     被赋值，之后所有 NIF 入口仅读取——单写多读，race-free。
//   - register_resources：仅 on_load 调用一次，非线程安全。
//   - make_resource<T>：可重入、线程安全（enif_alloc_resource / make_resource
//     都是 BEAM 自身保证 thread-safe 的）。
//   - cask_resource_dtor / cask_iter_resource_dtor：由 BEAM 资源回收线程
//     调用，时机不可预测。必须线程安全且不可与持有该资源的 NIF 入口竞争
//     （BEAM 保证「最后一个 ref 释放后」才调 dtor，所以业务上是安全的）。

#pragma once

#include <atomic>
#include <memory>
#include <new>
#include <shared_mutex>
#include <utility>

#include <erl_nif.h>

#include "bitcask/cask.hpp"

namespace bitcask::nif {

extern ErlNifResourceType* g_cask_resource_type;
extern ErlNifResourceType* g_cask_iter_resource_type;
extern ErlNifResourceType* g_cask_range_iter_resource_type;
extern ErlNifResourceType* g_txn_token_resource_type;

// 包住 C++ Cask 对象的 NIF 资源。Cask 自己持有 KeyDir 和 active write/hint
// file，析构会顺序释放它们。
//
// `iter` 是给 legacy `iterator/3` API 用的「单 Ref 单活跃迭代器」槽位；
// fold/3 + fold/6 走另一条 CaskIterHandle 资源链路，跟这里互不影响。
//
// === 生命周期与并发（6.6.1）===
// cask.hpp 的两条契约：① `close()` 时刻不能有在途调用（并发是 UB）；
// ② CaskIter 持裸 `Cask*`，**必须先于 Cask 对象析构**。以前 cask_close 直接
// `cask.reset()` 删对象——普通调度器上的 get 能与 dirty 的 close 并发（违反
// ①），close 后仍活着的 fold 迭代器下一次 next 就是 UAF（违反 ②）。现在：
//   * `mu`：每个用到 cask 的 NIF 入口持 shared 锁（lock_cask_checked），
//     close 持 unique 锁——close 排在所有在途调用之后，在途调用也进不来。
//   * `closed`：close 只调 `Cask::close()`（释放 keydir / 文件），**不删对象**，
//     对象活到资源析构。close 后的入口按 `closed` 标志 fail-fast（badarg，
//     与以前 `cask` 为空时的行为一致）。
//   * 迭代器句柄 keep 住本资源（见 CaskIterHandle / CaskRangeIterHandle），
//     于是 Cask 对象一定晚于所有迭代器析构。
struct CaskHandle {
    std::unique_ptr<Cask> cask;
    std::unique_ptr<CaskIter> iter;
    mutable std::shared_mutex mu;
    std::atomic<bool> closed{false};

    explicit CaskHandle(std::unique_ptr<Cask> c) noexcept : cask(std::move(c)) {}
    CaskHandle(const CaskHandle&)            = delete;
    CaskHandle& operator=(const CaskHandle&) = delete;
};

// fold/3 + fold/6 用的独立迭代器资源；持有自己的 CaskIter。keep 住父
// CaskHandle（析构时 release）：CaskIter 的 `parent_` 是裸指针，父对象必须
// 活得比它久。next 时持父的 shared 锁并检查 `closed`——close 后的 next 返回
// {error, closed}，而不是读一个已经放掉 keydir 的 Cask。
struct CaskIterHandle {
    std::unique_ptr<CaskIter> iter;
    CaskHandle* owner = nullptr;   // keep 住的父资源，非拥有指针

    CaskIterHandle(std::unique_ptr<CaskIter> it, CaskHandle* o) noexcept
        : iter(std::move(it)), owner(o) {
        if (owner) enif_keep_resource(owner);
    }
    CaskIterHandle(const CaskIterHandle&)            = delete;
    CaskIterHandle& operator=(const CaskIterHandle&) = delete;
    ~CaskIterHandle() {
        iter.reset();  // 先放迭代器（它 pin 着 keydir），再放父资源
        if (owner) enif_release_resource(owner);
    }
};

// v5.1.0 S33-5：range 迭代器（OKI 有序范围查询）资源。
//
// 与 CaskIterHandle 的关键差别：CaskRangeIter **取值时回调父 Cask 的读路径**
// （不是 fold 快照自足），所以它的合法期不能超过父 Cask。这里显式把父
// CaskHandle 资源 keep 住（析构时 release），再逐次 next 前检查 `owner->cask`
// 是否已被 cask_close 置空——两道闸把「上层先丢 CaskRef / 先 close，再拿
// 迭代器 next」从段错误降级成 {error, closed}。
//
// keep/release 用 enif_keep_resource/enif_release_resource，配对严格：
// 构造成功即 keep 一次，dtor 里 release 一次。
struct CaskRangeIterHandle {
    std::unique_ptr<CaskRangeIter> iter;
    CaskHandle* owner = nullptr;   // keep 住的父资源，非拥有指针

    CaskRangeIterHandle(std::unique_ptr<CaskRangeIter> it, CaskHandle* o) noexcept
        : iter(std::move(it)), owner(o) {
        if (owner) enif_keep_resource(owner);
    }
    CaskRangeIterHandle(const CaskRangeIterHandle&)            = delete;
    CaskRangeIterHandle& operator=(const CaskRangeIterHandle&) = delete;
    ~CaskRangeIterHandle() {
        iter.reset();  // 先放迭代器（它 pin 着 keydir），再放父资源
        if (owner) enif_release_resource(owner);
    }
};

// bitcask_txn 的提交令牌：**析构即通知**。
//
// 调用方每次提交建一个（txn_commit_token/2），当参数传给 cask_txn_commit/4，
// NIF 执行期间再额外 keep 一份。于是析构（最后一个 ref 放掉）只可能发生在：
//   (a) NIF 已返回，且调用方已丢掉令牌；或
//   (b) 调用方在排进 dirty 队列后、NIF 真正开始前被 kill——NIF 永远不会跑，
//       进程退出清理时放掉令牌。
// 两种都是"这批不会再动盘"的时刻，析构时若仍 armed 就把
// {txn_committed, TxnId} 发给 pid。正常路径调用方提交完 disarm
// （txn_commit_token_disarm/1），析构不发。
// 只存两个标量，消息在析构回调的 env 里现构造（msg_env = NULL 走拷贝），
// 不用为每个令牌再分配 / 释放一个 ErlNifEnv。
// ⚠️ 为什么不在 NIF 返回前直接 enif_send：(b) 里 NIF 根本不执行，发不出来；
//    且调用方已死时用它的 env 发会被 ERTS 按文档丢弃（发送者不存活）。
//    析构回调的 callback env 发消息是文档内用法，两种情况都覆盖。
struct TxnTokenHandle {
    ErlNifPid pid{};
    ErlNifSInt64 txn_id = 0;
    std::atomic<bool> armed{true};

    TxnTokenHandle(const ErlNifPid& p, ErlNifSInt64 id) noexcept : pid(p), txn_id(id) {}
    TxnTokenHandle(const TxnTokenHandle&)            = delete;
    TxnTokenHandle& operator=(const TxnTokenHandle&) = delete;
    void fire(ErlNifEnv* caller_env) noexcept {
        if (!armed.load(std::memory_order_acquire)) return;
        ERL_NIF_TERM msg = enif_make_tuple2(caller_env,
                                            enif_make_atom(caller_env, "txn_committed"),
                                            enif_make_int64(caller_env, txn_id));
        enif_send(caller_env, &pid, nullptr, msg);
    }
};

// 注册全部资源类型；任一注册失败返回 false。
// 线程安全: 否；仅 on_load 单线程调用一次。
[[nodiscard]] bool register_resources(ErlNifEnv* env) noexcept;

// 在 BEAM 资源缓冲区里 placement-new 构造 T，然后返回对应的 Erlang term。
// 内部会立即 release 本地 ref，剩下的生命周期完全由 BEAM 管。
// 分配失败返回 0（且不会触发 badarg，由调用方决定怎么报错）。
// 线程安全: 是（BEAM 的 enif_alloc_resource / enif_make_resource 自身
// thread-safe；T 的构造函数自身需 thread-safe，由 caller 保证）。
template <typename T, typename... Args>
ERL_NIF_TERM make_resource(ErlNifEnv* env, ErlNifResourceType* rt, Args&&... args) {
    void* mem = enif_alloc_resource(rt, sizeof(T));
    if (!mem) return 0;
    new (mem) T(std::forward<Args>(args)...);
    ERL_NIF_TERM term = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return term;
}

// enif_open_resource_type 注册的析构回调。
// 线程安全: 是（BEAM 调用前保证无 ref，安全独占该对象）；
// 调用线程不可预测，禁止内部反向调任何 BEAM 锁或拿任何阻塞资源。
void cask_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_iter_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_range_iter_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void txn_token_resource_dtor(ErlNifEnv* env, void* obj) noexcept;

}  // namespace bitcask::nif
