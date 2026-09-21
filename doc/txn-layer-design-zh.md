# 事务协调层设计（bitcask_txn）：2PL + 死锁检测 + 事务重启

> 状态：**P1 + P2（前缀锁）+ P3（分片 + victim 启发式）已实施**（2026-09-21，`src/bitcask_txn.erl` +
> `src/bitcask_txn_locker.erl` + `src/bitcask_txn_locker_sup.erl`，
> `test/bitcask_txn_tests.erl` 27 例），**随 6.5.1 发布**（2026-09-21）。实现与本稿的
> 偏差见 §11，前缀锁模型见 §12，分片与 victim 启发式见 §13。
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
   │     └── 本地: 写入 pdict 缓冲(同 Mnesia)                              │
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

- **缓冲用调用方进程字典（pdict），不用 per-txn ETS**（Mnesia
  `mnesia_tm` 同款）：单个命名键 `{?MODULE, TxnId} => #{Key => {put, Val}
  | delete}`，同事务内重复写天然 LWW（map 覆盖）。理由：① ETS 表是
  配额资源——默认每节点 1400 张（`+e` 可调），且 `ets:new/delete` 走
  全局表注册锁，per-txn 建表在高事务率下既耗配额又串行化创建；
  ② pdict 随进程死亡自动消失，崩溃安全与 ETS 所有权语义**等价**；
  ③ 单次访问更快。**代价**：放弃 `ordered_set` 的免费有序遍历——提交
  组装时对小缓冲 `lists:sort/1`（O(n log n)，n = 缓冲键数，通常
  < 100，可忽略）。
- ETS 只保留 locker 的三张常驻表（§4.1）：每节点 ETS 用量**恒定**，
  与事务并发度无关。分工原则：**共享状态归 ETS，事务私有状态归 pdict**。
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
src/bitcask_txn.erl          门面 + 重启循环 + pdict 写缓冲（~300 行）
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
| P2 ✅ | 前缀锁（事务内 range 扫描的幻读防护）、`status/0`。已落地（2026-09-21），模型见 §12 | graphdb `del_vertex_txn` / `out_edges_txn` |
| P3 ✅ | locker 分片（§13）+ victim 启发式（§13.7，环上最年轻、年龄跨重跑不变）已落地（2026-09-21）；环境式 API（Mnesia 习惯法）不做——显式 Tx 更清楚 | profiling：单 locker 26k txn/s 且不随并发增长 |
| 交汇 | **与引擎条件批（CAS/`expected_rev`）融合**：2PL 管跨 key 不变式，条件批管单 key 乐观并发，两者共享条件校验语义 | CouchDB 风格条件更新立项时 |
| 消费 ✅ | `graphdb` 事务式 API（`transaction/2,3` + `put_edge_txn` 族，deg/degi 计数入事务），消除"单写者语义下精确"的限制。已落地（2026-09-21），见 graph 设计 §12 第 6 条 | — |

## 10. 风险与开放问题

- **单 locker 吞吐**：理论瓶颈与 Mnesia 同档；若 hit，P3 分片方案
  （key 哈希 → N 个 locker；waits 边进共享 ETS，检测由请求方 locker
  做全局 DFS——检测一致性依赖边插入的原子性，设计需单独评审）。
- **不确定窗口**（§4.5）：kill 调用方场景；v1 文档化，必要时 v2 幂等键。
- **重启风暴**：对称死锁 + 无退避 = 活锁；抖动退避已入设计，预算耗尽
  有显式返回。
- **与 merge 的关系**：无。事务提交走常规写路径，merge 锁模型不变。

## 11. 实现对账（P1 落地时与设计稿的偏差）

| 设计稿 | 实现 | 为什么 |
|--------|------|--------|
| `LockId :: binary()`（用户 key） | `LockId = {CaskRef, Key}` | 单 locker 服务全部 cask；不带 ref 会让两个库的同名 key 假冲突。零成本 |
| `waits` 边表（第三张 ETS） | **不存边**，从锁表按需推导：等待者 W 等 (a) 与它冲突的 holder，(b) 队列里排它前面且冲突的请求者；`txns` 记 `waiting => LockId` | 推导式的图永远与锁表一致，没有"边表漏删"这一类 bug；DFS 每步多一次 O(队列长) 扫描，可忽略 |
| `Holders :: #{TxnId => N}` 重入计数 | `#{TxnId => read \| write}` | 严格 2PL 事务结束才放锁，重入不需要计数；只需记模式（read 升 write 只升不降） |
| 授予时补做死锁检测 | 只在**入队**时检 | 授予不造环（被授予者不再等任何人），删边（释放/死亡/中止）也不造环；入队是唯一会加边的时刻 |
| `status/0` 列在 P2 | P1 就有：`#{txns, waiting, locks, deadlocks_total}`，直读 protected ETS 不过 locker | 测试要靠它断言"锁清零"；`deadlocks_total` 替代设计里的 `restarts_total`（locker 只看得见死锁，看不见重跑） |
| `{timeout, Ms}` 语义未定 | **整个 transaction 调用的总预算**（跨重跑），deadline 注册时算好；等锁中过点由兜底计时器（`min(lock_wait_timeout, 剩余)`）叫醒 | 超时是调用方的预算，重跑不应把预算刷新 |
| `index_fun` 额外 op 只并批 | 额外 op 的 key 在提交前**补写锁**（仍属增长段，可能死锁 → 照常重跑）；与缓冲 key 重合 → `{aborted, {index_conflict, K}}` | 不锁的话两个事务的索引写会互相覆盖，"同批原子"只保住了崩溃安全没保住隔离 |
| 提交固定 `sync_on_commit` | 加 `{sync, sync_on_commit \| no_sync}` 选项，默认不变 | 测试/批量装载不必每次 fsync |
| `lock_wait_timeout` 只是默认值 | 也是 `transaction/3` 选项 | 测试要短超时；生产也可能按负载调 |
| `{aborted, {Class, Reason}}` 形态未定 | 与 Mnesia 对齐：`{aborted, {throw, V}}` / `{aborted, {Reason, Stack}}` | — |
| `read/2` 只有读锁 | 加 `read/3`，`Lock = write` 直接拿写锁再读（Mnesia `wlock_read`） | 读-改-写模式两个事务都先读锁再升级 = 确定死锁，能跑对但白白重跑；graphdb 计数器全走它 |
| `txns` 记录里放 `locks => [LockId]` | 持有锁单独一张 bag 表 `bitcask_txn_held` | ETS insert 整条拷贝，列表放记录里每拿一把新锁拷一遍已持有的——大事务 O(n²)。实测 100 边/事务从 12.8k → 25.6k edges/s |
| 每个 read/write 一次 `gen_server:call` | 门面在 pdict 记已持有锁，重入（读后写、RMW）不再过 locker | 2PL 到事务结束才放锁，本地缓存永远准确；put_edge_txn 每边省 2~3 次往返 |
| `handle(Tx)` 未列 | 加 `handle/1` | graphdb 计数键缺失时的按需扫描要句柄（不上锁，文档已声明） |

实测（`concurrent_transfers_conserve_test_` 放大到 8 进程 × 400 次，10 账户，
`no_sync`）：3200 个高冲突事务 ~170ms（≈19k txn/s，含死锁重跑），总额守恒，
锁表清零。

## 12. P2 前缀锁（已实施）

### 12.1 语义

- `LockId = {CaskRef, Bin, point | prefix}`。前缀锁罩住以 `Bin` 开头的**全部
  key——现有的和将来的**，所以持前缀读锁扫描不会有幻读。
- 两把锁**重叠**当且仅当一方的 Bin 是另一方的前缀（点锁视为等长前缀；两把
  点锁只在相等时重叠）。重叠 + 模式冲突（非 read/read）= 互斥。
- 门面：`lock_prefix(Tx, Prefix, read|write)`；`prefix_range(Tx, Prefix[, Opts])`
  = 前缀锁（默认 read，`{lock, write}` 给扫了就删的场景）+ `bitcask:range`
  `[Prefix, succ(Prefix))` + 合并本事务缓冲（读自己的写），按 key 升序返回。
- 持有覆盖锁后对其下 key 的 read/write/delete **免费**：门面本地判定覆盖，
  不过 locker；即使过了 locker，`covered/3` 也直接 ok、不建记录。

### 12.2 锁表模型（一张表，不用意向锁）

DB 教科书做法是层级锁 + IS/IX 意向锁。这里 key 空间是扁平的字节串、层级
由前缀关系隐含，用不着意向锁：

- `bitcask_txn_locks` 改成 **ordered_set**，键 `{Ref, Bin, Kind}`。
- 请求 X 的**重叠记录集** `overlapping(X)`：
  1. X 自身；
  2. 罩住 X 的前缀记录——`bitcask_txn_plens` 记着现存前缀锁的**长度集合**
     `{Len, Count}`，只按这几个长度截 X.Bin 去查（典型应用 1~3 个长度）；
  3. X 是前缀时，它罩住的全部记录——从 `{Ref, Bin, 0}` 起 `ets:next` 顺序扫
     （数字 < 原子，所以同 Bin 的 point/prefix 都在其后），直到第二元不再以
     Bin 开头。
  没有前缀锁时 `plens` 为空，点锁路径只查自身一条——与纯点锁实现同价。
- 可授予 ⇔ `blockers(TxnId, Mode, Seq, overlapping(X)) =:= []`：
  - 重叠记录上与 Mode 冲突的其它 holder；
  - 若请求者不是任一重叠记录的 holder：重叠记录上**比它早到**（全局 seq 更小）
    且冲突的等待者。这就是 FIFO 公平 / 防写饿死的跨记录推广——前缀写等待者
    不会被源源不断的点锁请求饿死（`prefix_writer_fairness_test_`）。
  - "holder 不被等待者挡"是 P1"唯一 holder 升级越过队列"的推广：队列里的
    写在等它放锁，不让它过就是死锁。
- 唤醒 `wake_around(X)`：X 附近状态变了（holder 释放 / 等待者出队），把
  `overlapping(X)` 里的全部等待者按 seq 依次重判。重叠是对称的，所以释放
  点锁会重判罩住它的前缀等待者，释放前缀锁会重判其下所有点等待者。
- 死锁检测不变：`blockers_of(N)` 就是上面的 `blockers`，DFS 照旧。
  `prefix_covered_is_free_test_` 验证经前缀锁形成的环也能检出。
- `#txn.waiting` 语义不变（同一时刻最多等一把）。

### 12.3 graphdb 消费

`out_edges_txn` / `in_edges_txn`（前缀读锁 + 合并缓冲，etype/limit 同直通版）、
`degree_txn/2`、`del_vertex_txn`（`e<vid>` / `ei<vid>` 前缀**写**锁下级联：
三键删除、邻居计数逐条 RMW、自身 `deg<vid>`/`degi<vid>` 前缀扫清、顶点键，
一批提交）。`concurrent_insert_vs_del_vertex_test_`：8 个加边进程 vs 2 个
del_vertex_txn 进程随机交错（放大到 4800 + 300 次 × 3 轮），全图不变式
（每个 (vid, etype) 的 deg/degi == 实际 e/ei 键数；e/ei/et 三键两两配对）成立。

## 13. P3 locker 分片（已实施）

### 13.1 触发：profiling

locker-only 微基准（每事务 register + 6 把点写锁 + release_all）：单 locker
**~26k txn/s，P=1/4/8/16 一条平线**——每事务 ~8 次 `gen_server:call` 全串行在
一个进程上；引擎自己 P=8 能到 44–55k commit/s。锁管理器成了天花板，符合 §9 的
触发条件。

### 13.2 拓扑

- `bitcask_txn_locker_sup`（one_for_all）：1 个共享表持有者 + N 个分片
  gen_server，N = application env `{txn_locker_shards, N}`，默认 8。
  ⚠️ 不按 `schedulers_online` 推：容器里 BEAM 看到的是宿主核数（开发机 128）。
- 点锁按 `phash2({CaskRef, Key})` 落一个分片；**前缀锁在每个分片上各拿一份**
  （按分片序依次 acquire）——于是分片判点锁只看自己的表，分片之间没有锁语义
  上的交互，§12 的重叠模型原样搬进每个分片。
- 事务归属分片 `phash2(TxnId)`：register / monitor / DOWN / unregister 在那里。
- 共享表（public，tables 进程持有）：`txns`（waiting = `{Shard, LockId}`）、
  `held`（`{TxnId, Shard, LockId}` bag）、`stats`。每分片自有 `locks_I`
  （ordered_set）与 `plens_I`（protected，谁都能读——跨分片 DFS 用）。
- `check/1` 直读 `txns`，不再过任何进程。

### 13.3 跨分片死锁检测

DFS 不变；`blockers_of(N)` 读 N 所等分片的表（无锁快照）。正确性论证：每个
分片都是**先写边（入队 + 写 `txns.waiting`）再检**。两个分片并发各加一条边
（A 在 s1 等 B 持有的锁，B 在 s2 等 A 持有的锁）：设 A 写完在 a1、检在 a2，
B 写完在 b1、检在 b2；a2 > b1 则 A 看见 B 的边，否则 b2 > b1 > a2 > a1 则 B 看见
A 的边——环至少被一方检出。过期快照最多造成**误报**（多重跑一次，安全），
不会漏报。兜底计时器仍在，且 `status()` 新增 `lock_wait_timeouts` 计数：
它不为零就说明检测漏了。`concurrent_insert_vs_del_vertex_test_` 断言该计数
在 4800 加边 + 300 删点随机交错（3 轮）后**不变**。

### 13.4 释放与清理

- 正常释放由**调用进程**驱动：按 `held` 分组向各分片 **cast** `{release, TxnId}`
  （同 `mnesia_locker` 的 `release_tid`：异步），再 call 归属分片 unregister。
  同步版每个触及的分片一次 call，多 key 事务里比拿锁还贵；异步的代价只是
  返回后锁还挂几十微秒（等待者稍晚放行、`status()` 短暂可见），严格 2PL
  不受影响。已提交的事务不在等任何人，误报环不会经过它。
- DOWN：归属分片向其它分片 cast `{drop, TxnId}`，各自出队/放锁。
  **分片之间只 cast 不 call**——两个分片互相 call 就是分布式死锁。
- 分片崩溃：one_for_all 全组重启、锁表清零；进行中的事务下一步 acquire 拿到
  `unknown_txn` → `{aborted, locker_restarted}`（`shard_crash_aborts_txn_test_`）。

### 13.5 语义变化

- 跨分片的 FIFO 公平只对前缀写**已到达**的分片成立：它在分片 s 上等时，
  分片 > s 上的点请求照常授予。每到一个分片它都会排进那里的队列、后来者
  挡不住它，所以有进展保证，只是不是全局先来先得。
- 前缀锁 = N 条记录（`status()` 的 `prefix_locks` 按记录数）。
- victim 见 §13.7（已不再固定是请求者）。

### 13.6 实测（8 vCPU、宿主有别的负载，比值为准）

| | shards=1 | shards=8 |
|---|---|---|
| locker-only P=1 | 27k txn/s | 21k（多了 phash2 / persistent_term / held 分组） |
| locker-only P=8 | 27k | 36–39k |
| locker-only P=16 | 26k（平线） | **50k**（仍在涨） |
| put_edge_txn 插入 P=1 | 15.4k edges/s | 15.8k（call 地板） |
| put_edge_txn 插入 P=8 | 22.1k | **28.3k**（+28%；再往上是引擎 commit 与 8 核共享） |

### 13.7 victim 启发式：环上最年轻，年龄跨重跑不变

- **问题**：受害者 = 请求者时，长事务（如 hub 顶点的 `del_vertex_txn`，锁拿得
  多、拿得久）每次去拿下一把锁都可能闭环、都被牺牲，被源源不断的短事务
  反复打断——没有进展保证。
- **策略**：DFS 改为返回环上的事务列表（带路径栈的 DFS），受害者 = 环上
  `age` 最大者（最年轻）。`age` 由门面在**一次 `transaction/3` 调用**开始时
  取一个单调整数，每次重跑 register 时原样传入——重跑换了 TxnId 但年龄不变
  （同 Mnesia 重启保 Tid）。于是环上最老的永远不会被牺牲，它最终必完成。
- **中止非请求者**：环上所有节点都在等（holder 不等则无出边，不可能在环上），
  所以受害者一定挂在某个分片的某把锁上：在本分片就地出队回复
  `{error, deadlock}`；在别的分片 cast `{abort_waiter, Victim, LockId}`，那边
  核对它**仍在等同一把锁**才动手（否则环已经因授予/超时/死亡解开）。请求者
  留在队里：受害者要么是它等的锁上的先到等待者（出队即唤醒它），要么持着
  它等的锁（重跑前 release_all 放掉，唤醒它）。
- `status()` 新增 `victims_other`（受害者不是请求者的次数）。压测（4800 加边
  + 300 删点随机交错）：131 次死锁中 85 次选了非请求者，`lock_wait_timeouts`
  仍为 0；`concurrent_transfers` 3200 事务 0.27–0.5s → 0.2s（重启风暴少了）。
- 测试：`younger_is_victim_across_shards_test_`（闭环者更老，受害者在别的
  分片上等，cast 路径）、`older_txn_never_restarts_test_`（门面：老事务闭环
  也一次过，年轻的重跑一次）。
