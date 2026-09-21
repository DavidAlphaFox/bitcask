# 图存储层设计（KV per-key：k = 顶点，OKI range 遍历）

English: 暂缺。本文档定义「以 libbitcask 为单一存储、Erlang 为执行层」的图存储方案。

状态：**P1–P5 已落地**（2026-09：`src/graphdb.erl` + `src/graphdb_analytics.erl` +
测试 + `test/graphdb_bench` 基准）。**本文档覆盖 2.2.1 规划的「CSR 整图一个 value」
方案**：旧方案的核心约束（keydir 无序、前缀扫描退化 O(全部 key)）已被 6.0.0 的
OKI 有序 range 推翻。原 CSR 盘上格式不被丢弃——降级为本方案 §7 的全图分析物化缓存层。
英文版：[graph-layer-design-en.md](graph-layer-design-en.md)。

---

## 1. 定位与一句话模型

```
n  <vid>  → 顶点内容（DocValue：属性 + 可选 text / vector）
e  ...    → 出边（src 视角）
ei ...    → 反向导航键（dst 视角，值可空）
```

**一个顶点一行 KV，一条边两个 KV。** libbitcask 既是持久化层也是邻接索引：取邻居 =
一次 O(出度) 的前缀 range；顶点 / 边随机访问 = O(1) keydir + 单 `pread`。遍历在 BEAM
内逐跳展开，热路径上没有「整图物化」步骤。

参照系仍是 Neo4j 属性图 + index-free adjacency，介质不同：

| | Neo4j | CSR 整图（旧方案） | 本方案 |
|---|---|---|---|
| 邻接表示 | 盘上双向链表 | 内存 CSR 数组切片 | **盘上按 key 序邻接 + 前缀 range** |
| 取邻居 | O(degree) 指针追踪（盘） | O(degree) 数组切片（内存） | O(degree) 一次 seek + 归并 + pread |
| 随机点查 | 盘上记录 | 需整图驻留内存 | **O(1) keydir，天然支持** |
| 单图规模上限 | 盘上无界 | ≤ 4 GiB（`kMaxValueSize`）且整图进内存 | **无界，内存只放热数据** |
| 写 | 在线随机写 | overlay + 整图批量检查点 | **在线随机写，每写即持久** |
| 一致性 | 读已提交 | 整图快照 | 逐跳 per-key 一致（§6.5） |

适配定位：**图 OLTP**（在线遍历、点查、属性检索、中小扇出多跳）。全图迭代分析
（PageRank / 连通分量）逐跳 KV 不经济，走 §7 物化缓存——两层互补，不是二选一。

---

## 2. 为什么旧约束失效了

旧方案（2.2.1 版）否决 per-key 模型的唯一论据：*keydir 是哈希表（无序），没有高效
前缀 / 范围扫描，摊平成逐顶点 / 逐边一个 key 会退化成 O(总边数)*。6.0.0 落地的
OKI（有序 key 索引，见 libbitcask `doc/ordered-key-index-design-zh.md`）逐条推翻：

- **`range/3` 按 [Lo, Hi) 字典序遍历，代价 O(range)**——上游实测 1/256 选择性
  8.0 ms → 0.53 ms；前缀扫描是它的语法糖（`Lo = prefix`，`Hi = prefix 的字典序后继`）。
- **OKI 零构建成本**：put 路径挂钩 memdelta（回归预算 ≤ 3%），超阈值 flush 成不可变
  run；文件损坏 / 缺失由 fold 全量重建（派生缓存语义）。**边 key 写进去，邻接索引
  自动就有了**——不存在「建图索引」这个动作。
- **原子批补齐双向边一致性**：`put_batch_atomic`（S35 引擎原子批）崩溃 / 掉电后
  all-or-nothing。TAO 的反向边跨 shard 写不原子（悬挂边 + 异步修复）、NebulaGraph
  为 TOSS 预留 placeholder 字节——这一问题在本库有引擎级答案。
- 代价只剩两条，且都可声明、可补救：**per-key 弱一致**（与 `parallel_scan` 同档，
  非 fold 快照）与 **OKI 不可用时 range 拒答**（6.1.0 起按成因拆
  `{error, no_index}` / `{error, index_rebuild_failed}`，可回退 fold + 前缀过滤）。

---

## 3. Key 布局（盘上契约）

### 3.1 家族表

| 家族 | key 布局 | 值 | 用途 |
|---|---|---|---|
| `n` | `"n" + <vid:u64 BE>` | 顶点 DocValue | 顶点内容；put_doc 路径 → BM25 / 向量免费生效 |
| `e` | `"e" + <src:u64> <etype:u32> <dst:u64> <rank:u64>` | 边属性（或空） | 出边（src 视角） |
| `ei` | `"ei" + <dst:u64> <etype:u32> <src:u64> <rank:u64>` | **空**（导航键） | 反向遍历（dst 视角） |
| `et` | `"et" + <etype:u32> <src:u64> <dst:u64>` | 空 | 可选：按类型全局列边（「所有 FOLLOWS 边」） |
| `deg` | `"deg" + <vid:u64> <etype:u32>` | u64 计数 | 可选：O(1) 度数（TAO 单独 counts 表同款） |
| `t` | `"t" + <etype:u32>` → 名字；`"tn" + <len><name>` → id | — | etype intern 映射表（§3.4） |

### 3.2 编码规则

1. **家族字节 + 定宽大端字段，零分隔符**。多字节整数一律 big-endian：字典序 = 数值序，
   前缀扫描精确到顶点（可变长 id 会串号：`e1+5` 与 `e10+5` 共享前缀 `e1`；分隔符
   `:` 对任意 binary vid 有注入歧义）。id 为任意 binary 时的变体：长度前缀
   `<len:16 BE> <bytes>`（自描述，代价是 2 字节 / 字段）。
2. **`rank` 是用户空间判别符，不是引擎 ord**（§11）。简单图（同 (src,etype,dst) 至多
   一条，TAO 语义）恒 `0`；重边 / 时间序用 µs 时间戳（u64 µs ~58 万年回绕）或
   per-pair 计数器。**不要拿引擎 ord 当 rank**——重灌 / 重放时身份不稳定。
3. **`etype` 建库时 intern 成 u32**，映射表存同 cask 的 `t` 家族。注册是低频操作，
   推荐两种做法之一：open-time schema（对齐本库「open-time 不可变配置」哲学，如
   `{synonym_file, Path}`），或经单一注册进程串行化（并发盲写会双 id 分叉）。
4. **单 key ≤ `kMaxKeySize` = 64 KiB**（`format.hpp:45`）。定宽 u64 布局下边 key
   恒 29 字节，无压力；长度前缀变体注意 vid 总长。

### 3.3 实例

顶点 42（Alice）、顶点 100（Bob）、`FOLLOWS` = etype 3：

```
顶点 42  key: 6E | 00 00 00 00 00 00 00 2A                       (9 B)
边       key: 65 | …002A | 00 00 00 03 | …0064 | 00…00            (29 B, rank=0)
反向键   key: 65 69 | …0064 | 00 00 00 03 | …002A | 00…00          (30 B, 值空)
重边     …| …0064 | 00 00 01 8F A2 3B C1 90                        (rank = µs 时间戳)
```

排序性质：vid 1,2,10 的顶点 key 排序 `…01 < …02 < …0A`（大端定宽 ⇒ 字典序 = 数值序；
不定长十进制串会排出 `n1 < n10 < n2`）。同 (src,etype,dst) 下 rank 升序即时间升序。

实际扫描区间：

```
顶点 42 全部出边:    {"e"+<<42:64>>,            "e"+<<43:64>>}          % 9 B 前缀
顶点 42 的 FOLLOWS:  {"e"+<<42:64, 3:32>>,      "e"+<<42:64, 4:32>>}    % 13 B 前缀
点查边 (42,3,100):   get(29 B 完整 key)                                  % O(1)
```

`Hi = succ(Lo 前缀)`：去掉前缀尾部连续 `0xFF` 字节、末字节 +1（全 `0xFF` 则无上界）。

### 3.4 边的逻辑 id

四元组 `(Src, Etype, Dst, Rank)`；应用需要不透明句柄时用去家族字节的 28 字节编码
`<<Src:64, Etype:32, Dst:64, Rank:64>>`。`e` / `ei` 互为镜像：从反向扫描结果交换
src/dst 段即可重算正向 key（对偶性白送，JanusGraph full-id 四元组的同构）。

---

## 4. 图命名空间（多图）

- **默认：一图一个 cask 目录**。零 key 开销、故障与合并天然按图隔离、写吞吐按图分片
  （对齐上游「更高写并发 ⇒ 按目录分片多个 `Cask` 实例」）。旧方案的「并行度在图之间」
  在此保留。
- **备选：共享 cask + 图前缀**（vid 段前置 `<len:16><gid>`，或目录级定长 gid 字段），
  面向海量小图共享一份引擎实例的场景；代价是每 key 常数开销与 keydir 共享。MVP 不做。

---

## 5. 写路径

```
put_vertex(Vid, Doc)    → put_doc(n<vid>, Doc)            %% BM25/向量自动索引
put_edge(S,T,D,rank,P)  → put_batch_atomic([{put, e-key, P}, {put, ei-key, <<>>}])
del_edge(S,T,D,rank)    → put_batch_atomic([{remove, e-key}, {remove, ei-key}])
del_vertex(Vid)         → 先删全部 incident 边（双向 range 收集），再删顶点；分批原子
```

- **双向边原子性**：`e` / `ei` 同批 all-or-nothing，崩溃后反向键永不悬挂（§2）。
- **upsert 语义**：同 (src,etype,dst,rank) 再写即覆盖（put 天然语义）；multigraph 与
  否由应用通过 rank 约定表达，引擎不设第二种边类型。
- **持久性**：每次原子批返回即落盘（对比 CSR 方案：overlay 易失，检查点窗口内崩溃
  静默丢写）。本方案没有「图粒度检查点」这个概念。
- **写放大账**：每边 2 个 KV；`ei` 值留空（只做导航）使属性只存一份——NebulaGraph
  双存全量边属性、文档自承「存储放大明显」，此处刻意规避。反向需要属性时点查 `e` 键补。
- **度数**：启用 `deg` 家族时在**同一原子批**内 +1/−1（避免 assoc_count 热路径扫段）。

---

## 6. 读 / 遍历路径

### 6.1 原语

```erlang
succ(Bin) -> ...                                  %% 字典序后继（§3.2）
out_edges(R, Vid)      -> bitcask:range(R, {<<"e",  V64(Vid)>>,      succ(...)}, [{prefetch, N}])
out_edges(R, Vid, T)   -> bitcask:range(R, {<<"e",  V64(Vid), T32(T)>>, succ(...)}, ...)
in_edges(R, Vid)       -> bitcask:range(R, {<<"ei", V64(Vid)>>,      succ(...)}, ...)
edge(R, S, T, D)       -> bitcask:get(R, ekey(S, T, D, 0))            %% 点查
vertex(R, Vid)         -> bitcask:get(R, nkey(Vid))                   %% O(1) keydir
```

`range_fold` 批 256（NIF 上限 1024）；`prefetch` 复用 `parallel_scan` 线程池对窗口内
key 并发取值，吃 SSD 内部并行度——边值小、prefetch 主要在取下一跳顶点属性时兑现。

### 6.2 BFS / k-hop

```
frontier = [Start]
每层: frontier 逐顶点展开 —— 每个顶点一个 Erlang 进程，各自开各自的 range 迭代器
      （Cask 句柄多线程安全：读路径无锁 / shared_lock；唯一契约是单个迭代器单进程
        使用 —— 一进程一迭代器天然满足）
      结果按 vid 去重（map / ETS）→ 下一层 frontier
```

顶点属性批量取：下一层 frontier 的 `n` 键走逐个点查或 `parallel_scan`（key 集合已知时
它的前缀过滤正合适）。

### 6.3 双向最短路

`e` / `ei` 双家族让两个方向同是 O(度)：经典双向 BFS，每步展开较小的一侧 frontier，
在中间相遇即停。

### 6.4 hub（超大度数顶点）

`range` 无 LIMIT 参数，策略在调用层：

- `range_fold` 提前停（计数到位即 `done`）；
- 把 etype 下推进前缀收窄（§3.2 的谓词左到右规则）；
- 「最新 N 条」：rank 编码为补码使字典序 = 时间倒序，取前 N 即停
  （TAO assoc_list 按时间降序、缓存前缀命中的同款思路）。`RangeOptions::reverse`
  上游格式已预留、首版未实现，不依赖。

### 6.5 属性过滤遍历与一致性

- **属性过滤**：两阶段——`search_fields` / `search_text` 先出候选 vid 集，再与邻接
  求交；或逐跳在 Erlang 过滤。
- **一致性（诚实声明）**：每次 range 内部 per-key 一致（OKI 归并 + keydir 回查）；
  **跨跳弱一致**——遍历期间的并发写可能部分可见。需要全局快照的算法用 `fold`
  （快照语义，O(全表)）。此档位与主流在线图库的读已提交相当，文档言明即可。

---

## 7. 全图分析：物化 CSR 缓存（吸收旧方案）

逐跳 KV 对 BSP 类算法不经济（每 superstep O(V+E) 次 seek，比 C++ CSR 内核慢 1–2 个
数量级）。分层解决：

```
离线/低频:  parallel_scan 或 range_fold 流式扫 e: 家族
            → BEAM 内存物化 CSR（xadj/adjncy/etype；GCSR 编码可复用）
            → PageRank / 连通分量 / SSSP 在内存跑（BSP）
失效:       写多时丢弃重建（缓存语义，非真源）
```

旧 2.2.1 方案（CSR 整图 + owner 进程 + overlay 检查点）整体降级为本层的实现参考——
它暴露的三大问题（`value_too_large` 4 GiB 封顶、图粒度写放大、检查点持久性窗口）在
本方案存储层已不存在，物化层只是**可再生缓存**，丢失无碍正确性。

---

## 8. Erlang 执行模型（与旧方案的差异）

- **不再需要 owner 进程托管图状态**：Cask 句柄线程安全，任意 BEAM 进程并发读写同一
  句柄；BEAM 侧无大状态、无 LRU 逐出、无检查点协议——旧方案为「进程 = 状态容器」
  付出的全部配套（overlay、折叠、逐出写回）随之消失。
- **崩溃隔离**：存储层每写即持久；BEAM 进程无状态化后，进程崩溃只影响在途遍历，
  不丢数据。supervisor 只需管遍历协调者（可选）与 etype 注册进程（若非 open-time schema）。
- **写吞吐**：单 cask 写路径 `write_mu_` 串行（多写安全但不提速）；更高写吞吐按 §4
  分图 / 分目录。
- **读并行度**：跨进程（frontier 并行）+ 跨图（多 cask 实例）两个维度，满核。

---

## 9. API 草案

```erlang
%% 生命周期（一图一目录）
graphdb:open(Dir, Opts)      -> {ok, R, EmbedderCtx}.   %% 薄封装 bitcask:open
graphdb:close(R)             -> ok.

%% 写（每操作即持久；边走原子批双写）
graphdb:put_vertex(R, Vid, Doc).
graphdb:put_edge(R, Src, Etype, Dst, Opts).             %% Opts: rank（默认 0）、props
graphdb:del_edge(R, Src, Etype, Dst, Rank).
graphdb:del_vertex(R, Vid).                             %% 先清 incident 边

%% 读 / 遍历
graphdb:vertex(R, Vid).
graphdb:neighbors(R, Vid, Dir).                         %% Dir :: out | in | both
graphdb:edge(R, Src, Etype, Dst).
graphdb:out_edges(R, Vid, Opts).                        %% Opts: etype、limit、prefix
graphdb:in_edges(R, Vid, Opts).
graphdb:bfs(R, Start, #{depth := K, dir => out, visit => Fun}).
graphdb:k_hop(R, Start, K, Opts).
graphdb:shortest_path(R, Src, Dst).
graphdb:degree(R, Vid, Etype).                          %% deg 家族或按需计数

%% 事务式写（X1-5 已落地；bitcask_txn 之上，2PL + 死锁重跑，计数器精确）
graphdb:transaction(R, fun(Tx) ->
    ok = graphdb:put_edge_txn(Tx, Src, Etype, Dst, Opts),
    ok = graphdb:del_edge_txn(Tx, Src2, Etype, Dst2),
    graphdb:degree_txn(Tx, Src, Etype)
end, [{retries, 10}])                                   -> {atomic, R} | {aborted, Why}.
%% 另有 edge_txn / put_vertex_txn（Doc 只收 binary）/ get_vertex_txn；前缀锁版
%% out_edges_txn / in_edges_txn / degree_txn/2（扫描无幻读）、del_vertex_txn
%%（e<vid>/ei<vid> 前缀写锁下级联，一批提交）。
%% ⚠️ 同一图的边写要么全走事务、要么全走直通（直通绕过锁）。

%% 检索联动（复用引擎能力）
graphdb:search_vertex(R, Query).                        %% search_fields/search_text 直通
graphdb:search_vector(R, Q).                            %% 顶点向量近邻
graphdb:neighbors_filtered(R, Vid, Dir, Pred).          %% 邻接 × 属性过滤

%% OLAP（§7）
graphdb:materialize(R)      -> {ok, CsrRef}.
graphdb:pregel(CsrRef, ComputeFun, Opts).
```

---

## 10. 权衡与边界

- ✅ 单图无内存封顶、无 `value_too_large`；在线随机写、每写即持久；双向遍历同 O(度)；
  双向边引擎级原子；点查 O(1)；跨图满核并行；顶点属性检索 / 向量近邻零成本复用。
- ⚠️ **一跳成本比 CSR 数组切片慢 10–100×**（seek + 归并 + pread vs 内存切片）——
  OLTP 遍历可接受，全图迭代必须走 §7 物化层，两层定位不同。
- ⚠️ **每边 2 个 KV**（+ 可选 deg 计数），边写放大 ×2；`ei` 值留空缓解属性侧翻倍。
- ⚠️ **跨跳 per-key 弱一致**；全局快照只有 fold（O(全表)）。多跳事务不存在。
- ⚠️ **deg/degi 计数在直通 API 下只在单写者语义下精确**；并发写用 `*_txn`
  族（`doc/txn-layer-design-zh.md`），代价约 2–2.5× 单边写延迟（锁管理器
  往返），100 边/事务批量装载可收回大半。
- ⚠️ **hub 顶点**：无服务端 LIMIT，靠调用层提前停 / 前缀收窄；超级 hub（>10⁶ 度）
  应在建模层拆分。
- ⚠️ **key ≤ 64 KiB**；u64 vid 之外的 id 走长度前缀变体（+2 B/字段）。
- ⚠️ **etype intern 并发注册会分叉**：open-time schema 或单进程注册，二选一。
- ⚠️ OKI 不可用时 range 拒答（`no_index` / `index_rebuild_failed`），只读回退
  fold + 前缀过滤（O(全表)，功能等价、性能退化）。

---

## 11. ord 与 Rank（澄清）

引擎内部 `ord`（keydir `next_ord_`，u64 atomic，每 key 操作分配一个）与本设计的
边 `rank` 无关：rank 是用户空间判别符，零 ord 消耗。ord 耗尽在任何现实负载下不可达
（10⁵ ord/s 持续 ~580 万年；1 千万边/秒持续 ~2.9 万年——盘上 record 数先爆 15 个
数量级），上游 `ord-recycling-design-zh.md` 已把真正的相邻问题（Index per-ord 数组
增长）用 chunk 分块 + merge 释放解决。边 key 的 29 字节定宽布局使 hint / OKI run 的
vbyte 前缀差分压缩率高（`prefix:id` 形态正是 BCOK 的优化目标）。

---

## 12. 阶段拆分（P1–P5 已落地，2026-09）

1. **P1** ✅：key codec（n/e/ei 定宽大端 + 长度前缀变体）+ 顶点 / 边 CRUD（原子批双写）
   + out/in/点查 + del_vertex 级联；etype open-time schema。
2. **P2** ✅：BFS / k-hop / 双向最短路；hub 策略（limit / 前缀收窄）；visited 去重结构。
3. **P3**：`deg` / `et` 家族 + `search_*` 联动的属性过滤遍历 + 向量近邻联动。
4. **P4** ✅：CSR 物化缓存（`parallel_scan` → GCSR）+ PageRank / 连通分量 / SSSP。
5. **P5** ✅：基准（`test/graphdb_bench`：稳态一跳 ~0.02 ms/op、批量装载 ~94k edges/s
   @2k/8k 规模；⚠️ 未 flush memdelta 上查询 ~12ms/跳——装载型负载装载后建议
   checkpoint/reopen）+ 一致性语义测试（扫中插入/删除可见性不变量）+ EN 文档（本文英文版）。
6. **X1-5** ✅（2026-09-21）：事务式 API（`transaction/2,3` + `put_edge_txn` /
   `del_edge_txn` / `edge_txn` / `degree_txn` / `put_vertex_txn` / `get_vertex_txn`），
   建在 `bitcask_txn` 上；16 进程并发对同一 hub 加边计数精确（`test/graphdb_txn_tests.erl`）。
7. **X1-6** ✅（2026-09-21）：前缀锁版 `out_edges_txn` / `in_edges_txn` / `degree_txn/2`
   / `del_vertex_txn`（txn 设计 §12）；加边 vs 删点随机交错的全图不变式测试。
