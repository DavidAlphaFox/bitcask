# 事务协调层设计（bitcask_txn）：2PL + 死锁检测 + 事务重启

> 状态：设计稿（未实施）。落地版本：TBD（当前 6.5.0）。
> 前置阅读：`third_party/libbitcask/doc/multikey-txn-zh.md` §4（引擎事务边界：
> 只有 A+D，没有 I，也没有 CAS）、`doc/graph-layer-design-zh.md`。

## 1. 背景与动机

引擎原子批（`put_batch_atomic/2`、`txn_commit/2,3`）保证崩溃后的
all-or-nothing，但不提供隔离性：事务中间态对并发读者可见，键集重叠的并发
提交无定序保证，应用层 `get → 判定 → txn_commit` 之间存在丢失更新窗口。

这个缺口已经有真实消费者：`graphdb.erl` 头部明确记录——

> ⚠️ deg/degi 是读-判-写计数（引擎无 CAS）：并发对同一端点加边可能丢计数，
> 单写者语义（每图一个写进程 / 串行写）下精确。

即：**图层的度计数器、以及一切"读了再写"的应用逻辑，目前都依赖调用方自觉
串行化**。本设计在 Erlang 层补齐 Mnesia 三件套——悲观 2PL、死锁检测、
事务重启——把串行化的责任从每个调用方收拢到一处。

**关键约束：引擎零改动。** 提交原语复用 `bitcask:txn_commit/3`
（`sync_on_commit`），锁与检测全部在 BEAM 侧，纯 OTP（无新依赖，
`rebar.config` 现状满足）。

## 2. 目标与非目标

### 目标

| # | 目标 | 说明 |
|---|------|------|
| G1 | 可串行化隔离 | 并发事务的执行效果等价于某个串行顺序（2PL 的 2PL-定理保证） |
| G2 | 死锁不死锁 | wait-for 图检测，受害者自动中止并重跑，有重启预算 |
| G3 | 崩溃安全 | 提交走引擎原子批（A+D 现成）；协调进程/调用方死亡自动清锁 |
| G4 | 零引擎改动、零新依赖 | 纯 OTP：gen_server + ETS + monitor |

### 非目标（明确不做）

- **分布式**：单节点协调器。跨节点复制/全局事务属未来 Ra 路线
  （讨论结论：复制是上层协议，与存储引擎无关）。
- **快照点查 / MVCC 读视图**：引擎不暴露 per-key 版本（`get` 无 ord），
  悲观锁模型也不需要。`fold` 快照保留给分析类负载，与事务层无关。
- **引擎级 CAS / 条件批**：另一条演进线（CouchDB `_rev` 风格），
  与本草稿正交；两者在 P3 有交汇点（见 §9）。
- **嵌套事务、跨 cask 事务**：v1 一个事务绑定一个 cask handle。
- **范围锁（前缀锁）**：v1 只有点锁；事务内做 range 扫描属于 P2。

## 3. 总体架构

### 3.1 组件

| 模块 | 角色 | 说明 |
|------|------|------|
| `bitcask_txn` | 门面 | `transaction/2,3`、事务内 API（`read/write/delete/abort`）、重启循环 |
| `bitcask_txn_locker` | gen_server | 锁表 + 等待队列 + wait-for 边 + 检测 + monitor 清理；**单实例**（注册名 `bitcask_txn_locker`），作为 `bitcask_sup` 常驻 child（与 `bitcask_merge_worker` 同级） |
| ETS（locker 私有） | `locks` / `waits` / `txns` | 见 §4.1 |

调用方进程执行事务函数；锁获取走 `gen_server:call`；写只进 per-txn 缓冲；
提交时调用方自己执行 `bitcask:txn_commit/3`，随后通知 locker 放锁。

单 locker 是刻意的：锁操作与检测需要全局一致的串行点，且 Mnesia
（`mnesia_tm`/`mnesia_locker` 同为单点）证明该拓扑可支撑生产规模。
分片优化留 P3（§9）。

### 3.2 数据流

```
调用进程                                locker                      cask
   │ transaction(H, Fun)                   │                         │
   │── register(TxnId, Pid) ─────────────>│  monitor(Pid)           │
   │── Fun(Tx) 执行中:                     │                         │
   │   read(Tx,K) ── acquire(r) ─────────>│  授予/入等待队列          │
   │     └── 本地: 缓冲命中? 缓冲 : get ──────────────────────────>│
   │   write(Tx,K,V) ─ acquire(w) ───────>│  授予/入等待队列+检测     │
   │     └── 本地: 写入 per-txn ETS 缓冲                              │
   │── commit(Tx) ───────────────────────>│  校验( deadline / 状态)  │
   │── bitcask:txn_commit(H, Ops, sync) ──────────────────────────>│
   │── release_all(TxnId) ───────────────>│  放锁 + 唤醒等待者+检测   │
   │ {atomic, Fun 返回值}                                            │
```

## 4. 核心机制

### 4.1 锁表结构（locker 私有 ETS）

```erlang
%% locks: {LockId, Mode, Holders, Queue}
%%   LockId  :: binary()                      (v1 点锁 = 用户 key)
%%   Mode    :: read | write                  (授予模式:队列非空恒为 write)
%%   Holders :: #{TxnId => N}                 (N = 重入计数, 同一事务多次读锁)
%%   Queue   :: [{TxnId, read|write}]         (FIFO; 纯读段可合并授予)
%%
%% waits: {WaiterTxnId, BlockerTxnId}         (wait-for 边, set)
%%
%% txns: {TxnId, #{pid => Pid, deadline => Ms|infinity,
%%                 locks => [LockId], restarts => N}}
```

### 4.2 加锁算法（locker handle_call 内串行执行）

1. 查 `locks[LockId]`；
2. **可授予**：空闲；或请求 read 且无 write holder 且无 write 等待者
   （读合并）；或请求 write 且唯一 holder 是自己（读锁升级）→ 授予，
   回复 `{grant, Mode}`；
3. **不可授予**：请求者入队尾；对**当前冲突 holder 及队列中排在前面的
   冲突请求者**各插一条 `waits` 边；然后从请求者出发沿 `waits` 做
   DFS——**到达自己 ⟹ 死锁**；
4. 死锁：victim = 请求者本身（它是最新边，中止它必破环；启发式选 victim
   留 P3）。删除其 waits 边、出队、回复 `{error, deadlock}`；
5. 无环：回复 `{wait, LockId}`，请求者阻塞（`gen_server:call` 挂起）。

等待者获得授予的时机：任一 holder 释放锁后，从队首扫描可合并授予段
（连续 read 或队首单个 write），每授予一人补一次死锁检测（其等待边
转持有，可能为它身后的等待者制造死锁——同样由检测兜住）。

**writer 防饿死**：新 read 请求若队列里已有 write 等待者，必须排到
队尾（不准插纯读段前面）。

### 4.3 兼容矩阵

| 已授予 \ 请求 | read | write |
|--------------|------|-------|
| read(s)      | ✅ 合并授予 | ⏳ 等待（自己唯一 holder 时升级） |
| write        | ⏳ 等待 | ⏳ 等待 |

重入：同一事务对同一 key 多次 read → Holders 计数 +1；write 后 read →
按 write 持有计。全部锁在事务结束一次性释放（两阶段的"收缩段"）。

### 4.4 写缓冲与读路径

- 每事务一张 `ets`（`set`），caller 进程私有：`Key -> {put, Val} | delete`；
  同事务内重复写天然 LWW。
- `read(Tx, K)`：缓冲命中 → 按标记返回；否则 `bitcask:get/2`。
  **读自己的写**（read-your-writes）由此保证。
- 缓冲只进不出，直到 commit 组装 ops：按 key 升序（确定性序）展开为
  `[{put,K,V} | {remove,K}]`。
- 二级索引维护：门面接受 `{index_fun, fun(Key, Op) -> [ExtraOp]}`
  选项（如 graphdb 的 deg/degi 增量），ExtraOp 并入**同一条**
  `txn_commit` 批——主数据与索引一起原子提交（引擎 C 能力的用法，
  见 multikey-txn §4 的 C 行）。

### 4.5 提交协议

```
commit(Tx):
  1. locker: 状态/deadline 校验 → {commit_ok}          (仍持有全部锁)
  2. Ops = index_fun 展开 + 缓冲展开
  3. case bitcask:txn_commit(Handle, Ops, sync_on_commit) of
       ok        -> locker:release_all(TxnId); {atomic, Fun结果}
       {error,R} -> locker:release_all(TxnId); {aborted, {commit_failed,R}}
     end
```

- 提交期间锁不放（2PL 纪律）：引擎 `write_mu_` 串行提交期间，其他事务
  在这些 key 上等待——正确性优先，吞吐影响见 §8。
- ⚠️ **不确定窗口**：调用方死于 `txn_commit` NIF 执行途中（被 kill），
  NIF 在 dirty scheduler 上跑完，批要么全成要么全不成，但调用方拿不到
  结果。重试前应用需自查（与 Mnesia `sync_transaction` 跨节点失败的
  语义同档）。v2 可考虑幂等键，v1 文档化。

### 4.6 死锁检测与重启

- **检测**：§4.2 步骤 3，阻塞即检，O(V+E) DFS，规模受单节点事务数限制，
  无后台扫描线程。
- **重启**：`transaction/3` 捕获 `{error, deadlock}` → 丢弃缓冲、
  重新注册新 TxnId → **原样重跑 Fun**。
  预算：`{retries, N}`（默认 10），耗尽返回
  `{aborted, {retry_limit, N}}`。每次重启加 1~10ms 随机抖动退避，
  打散重启风暴（双事务对称死锁时，无退避会活锁）。
- ⚠️ **无副作用纪律**（与 Mnesia 相同）：Fun 可能执行多次——禁止在
  Fun 内做 I/O、发消息、改进程字典等任何外部可见副作用。
- 调用方显式 `abort(Reason)` → `{aborted, Reason}`，**不重启**。

### 4.7 死亡与超时清理

- locker 在事务注册时 `erlang:monitor(process, Pid)`；收到 `DOWN` →
  删除该 txn 的全部持有/等待/边，重新评估其锁上的等待队列（级联授予 +
  级联检测）。
- `{timeout, Ms}`：注册时记 deadline；locker 在每次 grant/wake 路径上
  检查 → 过期即中止 `{aborted, timeout}`（**不计入**死锁重启预算——
  超时是调用方问题，重跑大概率再超时）。
- `{lock_wait_timeout, Ms}`（默认 5000）：单锁等待上限，纯兜底（正常
  路径检测必达），触发按死锁处理（中止 + 重启）。

### 4.8 与脏写的关系（契约声明）

`bitcask:put/3`、`graphdb:put_edge/4` 等直通 API 与事务锁**完全无
交互**——绕过锁的事务外写入，与事务并发时的行为未定义（等价 Mnesia
dirty op）。同一批 key 要么全走事务、要么全走直通，混用自担。
未来引擎级条件批（§9）落地后可作为热 key 的兜底校验。

## 5. API 设计

```erlang
%% ---- 门面 ----
-spec transaction(Handle, Fun) -> {atomic, term()} | {aborted, term()}.
-spec transaction(Handle, Fun, Opts) -> {atomic, term()} | {aborted, term()}.
%%   Handle :: bitcask:open/2 返回值（{Ref,_} 元组原样透传）
%%   Fun    :: fun((Tx) -> Result)
%%   Opts   :: [{retries, non_neg_integer() | infinity} |   %% 默认 10
%%              {timeout, pos_integer()}            |        %% 默认 infinity
%%              {index_fun, fun((Key, Op) -> [Op])}]          %% 默认 undefined

%% ---- 事务内（Tx 为 Fun 收到的不透明上下文）----
-spec read(Tx, Key) -> {ok, binary()} | not_found.
-spec write(Tx, Key, Val) -> ok.
-spec delete(Tx, Key) -> ok.
-spec abort(term()) -> no_return().        %% throw {bitcask_txn_abort, R}

%% ---- 可观测性（P2）----
%% status() -> #{txns => N, waiting => M, restarts_total => K, locks => L}
```

语义对账（与 Mnesia）：

| Mnesia | bitcask_txn |
|--------|-------------|
| `mnesia:transaction(F)` | `bitcask_txn:transaction(H, F)` |
| `mnesia:read({Tab,K})` | `bitcask_txn:read(Tx, K)` |
| `mnesia:write/3`（隐式上下文） | `bitcask_txn:write(Tx, K, V)`（显式 Tx） |
| `mnesia:abort/1` | `bitcask_txn:abort/1` |
| 死锁重启 | 死锁重启（`{retries,N}` 预算 + 抖动退避） |
| `mnesia:sync_transaction` | 默认即 sync（`sync_on_commit`） |
| dirty ops | `bitcask:*` 直通（绕过锁，见 §4.8） |
| 嵌套事务 | ❌ 检测到即 `{aborted, tx_nested}` |
| sticky lock | 不需要（单节点） |
| 表锁 | P2（前缀锁）；`match_object` 式全表锁暂以"业务前缀约定"替代 |

## 6. 模块与工程布局

```
src/bitcask_txn.erl          门面 + 重启循环 + 缓冲 ETS 管理（~300 行）
src/bitcask_txn_locker.erl   gen_server：锁/等待/检测/监控（~400 行）
src/bitcask_sup.erl          加一个 ?CHILD(bitcask_txn_locker, worker)
test/bitcask_txn_tests.erl   eunit（meck 已在 test profile）
```

- locker 常驻（空载开销 ≈ 一张空 ETS），不做 embedder 式 env 门控——
  事务层是无状态正确性组件，"配了才起"反而让库文件与运行时状态对不上。
- 无公共 hrl：Tx 是不透明 term（tuple  tagged `bitcask_txn_ctx`），
  不跨进程传递的契约由文档声明（Fun 内在调用方进程执行）。

## 7. 测试策略

eunit（`rebar3 eunit`；并发用例用 spawn + 确定性同步，不引新框架）：

1. **锁矩阵**：兼容/升级/重入的纯函数单测；
2. **FIFO 公平 + 防写饿死**：多读者多写者交错，断言授予序；
3. **确定性死锁**：两进程交叉加锁（A:K1→K2，B:K2→K1）→ 恰好一个
   拿到 `{aborted, deadlock}` 后重启成功，另一个 `{atomic,_}`；
   不变式：K1+K2 上的计数守恒；
4. **重启预算**：构造环形等待死锁预算耗尽 → `{aborted,{retry_limit,_}}`；
5. **死亡清理**：T1 持锁被 kill → 等待中的 T2 解锁继续；
6. **缓冲语义**：read-your-writes、delete 遮蔽、同事务覆盖序；
7. **提交失败**：meck `bitcask:txn_commit` 返回 io_error → 锁释放 +
   `{aborted,{commit_failed,_}}`；
8. **真实 cask 集成**：temp dir 开库，多进程并发事务搬运计数器，
   断言最终值（mini-Jepsen 式守恒检查）；
9.（可选）复用 `bitcask_sup` 已有的 PULSE ifdef 基建做调度感知的
   死锁路径覆盖。

## 8. 性能预期与取舍

- 事务内每个 `read/write` = 1 次 `gen_server:call`（+ 引擎读 1 次
  NIF）。这是 Mnesia 同款税（`mnesia_tm`/`mnesia_locker` 每 op 过
  进程），事务内批量高频点操作时应按吞吐实测；
- 优化空间（均不进 P1）：无冲突读锁的 ETS 快路径（try 授予失败再降级
  locker）、锁批量获取管线、locker 按 key 哈希分片 + 全局 waits ETS；
- 提交路径无额外进程：提交 = 一次 NIF（引擎 `write_mu_` 已是全局
  串行点），locker 不挡提交。

## 9. 演进路线

| 阶段 | 内容 | 触发条件 |
|------|------|---------|
| P1 | 点锁 2PL + 缓冲 + 检测/重启 + eunit 全量 | 本设计 |
| P2 | 前缀/表锁（事务内 range 扫描的幻读防护）、`timeout` 指标、`status/0` | graphdb 遍历入事务的需求 |
| P3 | locker 分片、环境式 API（Mnesia 习惯法）、victim 启发式（最老事务优先） | 锁竞争 profiling 证明单点瓶颈 |
| 交汇 | **与引擎条件批（CAS/`expected_rev`）融合**：2PL 管跨 key 不变式，条件批管单 key 乐观并发，两者共享条件校验语义 | CouchDB 风格条件更新立项时 |
| 消费 | `graphdb` 新增事务式 API（`put_edge_txn` 族，deg/degi 计数入事务），消除"单写者语义下精确"的限制 | P1 落地后跟进 |

## 10. 风险与开放问题

- **单 locker 吞吐**：理论瓶颈与 Mnesia 同档；若 hit，P3 分片方案
  （key 哈希 → N 个 locker；waits 边进共享 ETS，检测由请求方 locker
  做全局 DFS——检测一致性依赖边插入的原子性，设计需单独评审）。
- **不确定窗口**（§4.5）：kill 调用方场景；v1 文档化，必要时 v2 幂等键。
- **重启风暴**：对称死锁 + 无退避 = 活锁；抖动退避已入设计，预算耗尽
  有显式返回。
- **与 merge 的关系**：无。事务提交走常规写路径，merge 锁模型不变。
