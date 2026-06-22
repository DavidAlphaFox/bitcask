# 图处理层设计（libbitcask 存储 + Erlang 执行）

English: 暂缺。本文档定义 2.2.1 规划中「以 libbitcask 为单一存储、Erlang 为执行层」
的简单图处理方案。

状态：📐 设计（2.2.1 规划）。

---

## 1. 定位与一句话模型

```
bitcask:  GraphId  ->  <整张图的 CSR 序列化二进制>
```

**一个图整体序列化进一个 value**，libbitcask 只负责这个 value 的持久化与并发加载；
所有遍历 / 计算在 BEAM 内存里完成，热路径零 bitcask 访问。

参照系是 Neo4j 的**属性图 + index-free adjacency**，但介质不同：

| | Neo4j | 本方案 |
|---|---|---|
| 邻接表示 | 盘上固定记录 + 物理指针 | **内存 CSR**（value 反序列化后） |
| 取邻居成本 | O(degree) 指针追踪（盘） | O(degree) 数组切片（内存） |
| 存储单元 | node/rel/property store 文件 | **一个 value = 一张图** |
| 适配规模 | 超大图、在线随机访问 | **有界图、读多写少 / 批量构建** |

代价是写放大落在「图」粒度（动一处→重建/回写整图），因此面向**有界规模 + 读多写少**
的「简单图处理」，而非超大图在线随机写。

---

## 2. 核心约束推导

bitcask 的 keydir 是**哈希表（无序）**，没有高效前缀 / 范围扫描（`fold_keys` 是
O(全部 key)）。因此**不能**把一张图摊平成「逐顶点 / 逐边一个 key」——取邻居会退化成
O(总边数)，恰好丢掉 index-free 特性。

把整张图收进**一个 value** 后：

1. 邻接在 value 内部，**取邻居不碰 bitcask**。
2. bitcask 退化为「快照 / 持久化层」：一次 `get` = 一次 `pread` = 整图入内存。
3. 真正的 index-free adjacency 落在 **BEAM 内存的 CSR** 上，指针级速度。

---

## 3. CSR 盘上格式（value 布局）

CSR（Compressed Sparse Row）= 用「行偏移数组 + 邻居数组」紧凑表示邻接：

- `xadj`（行偏移，长度 `|V|+1`）：`xadj[i]` = 顶点 i 邻居在 `adjncy` 的起点；
  `xadj[i+1] - xadj[i]` = 出度。
- `adjncy`（邻居数组，长度 `|E|`）：所有顶点的出邻居（内部稠密下标）顺序拼接。
- 顶点 i 的出邻居 = `adjncy[xadj[i] .. xadj[i+1]-1]`——一次切片，连续内存、cache 友好。

属性图需要在裸 CSR 上补三类侧表。**全小端**（对齐 libbitcask 盘上约定）：

```
┌─ header ────────────────────────────────────────────────┐
│ magic "GCSR" | version | flags | |V| u32 | |E| u32       │
├─ vid_table ─────────────────────────────────────────────┤
│ 内部稠密下标 [0,|V|) ↔ 外部 Vid(binary)：offsets + bytes  │
├─ 出边 CSR ──────────────────────────────────────────────┤
│ xadj   : (|V|+1) × u32       行偏移                       │
│ adjncy : |E| × u32           出邻居内部下标               │
│ etype  : |E| × u32           边类型 id（interned，与 adjncy 平行）│
├─ 入边 CSR（可选，flags 标记）──────────────────────────┤
│ xadj_in / adjncy_in          转置 CSR，支持反向 / 双向遍历│
├─ vprops ────────────────────────────────────────────────┤
│ 每顶点属性：offsets + DocValue v3 blob（复用现有编码）    │
├─ eprops（可选）─────────────────────────────────────────┤
│ 每边属性：与 adjncy 平行的 DocValue 侧表                  │
├─ intern 表 ─────────────────────────────────────────────┤
│ label↔id、edgetype↔id 字典                               │
└─────────────────────────────────────────────────────────┘
```

**BEAM 友好性**：Erlang 二进制连续、子二进制切片 O(1)（共享底层 refc binary，零拷贝）。
读 u32：`<<_:Off/binary, X:32/little, _/binary>>`；取邻居：
`binary:part(Adjncy, Xadj_i*4, (Xadj_i1-Xadj_i)*4)`。遍历直接在 value 二进制上跑，无需
先展开成 map。

---

## 4. Erlang 执行模型：物化 + owner 进程

```
load:    bitcask:get(GraphId) → CSR 二进制驻留进程 state
compute: 纯 BEAM 内存遍历 / 迭代（零 bitcask）
persist: 序列化 CSR → bitcask:put(GraphId, Bin)   ← 批量检查点，非每改即写
```

**一个 gen_server 进程持有一张物化图**——进程 state 就是这张图（CSR 二进制 + 写 overlay）。
这是 BEAM 最地道的「actor 拥有可变状态」，直接拿到：

- **崩溃隔离**：一张图处理崩溃只死它自己的进程，store 与其它图不受影响。
- **单写者天然成立**：一图一 owner，写串行 → 正好对上 bitcask 单写多读，无需额外锁。
- **并行度在「图之间」**：N 张独立图 = N 个 actor，满核并行、零竞争（多租户 / 多子图）。

---

## 5. 写路径：CSR + delta overlay

CSR 是**读优化静态格式**，原地插边代价高。因此采用业界标准的 **CSR + delta** 模式：

- **读 / 计算**：直接在 CSR 二进制上做（切片、零拷贝）。
- **写**：累积到 owner 进程内的 **mutation overlay**（`#{加边, 删边, 改属性}` 的 map），
  读时 CSR 结果叠加 overlay。
- **检查点 / 压实**：定时或 overlay 超阈值时，**把 overlay 折叠进 CSR 重建**，一次性
  `bitcask:put` 回写——把「图粒度写放大」摊薄成批量，而不是每条边一次 `put`。

---

## 6. Erlang 特性映射

| Erlang 特性 | 落点 |
|---|---|
| 百万轻进程 | 并行度在「图之间」：N 图 = N actor，满核并行 |
| 进程 = 状态容器 | 一个 gen_server = 一张物化图（CSR + overlay） |
| 不可变 + MVCC | bitcask MVCC 迭代器保证 load 到一致快照；并发写新版本，老遍历看老快照 |
| 背压 / 内存治理 | 活跃图常驻、冷图 **LRU 逐出**、再访问懒加载；`value_too_large` 封顶单图规模 |
| 消息传递 | **Pregel/BSP**：顶点状态=map，边=消息，superstep=屏障，收敛后一次回写 |
| 热代码升级 | 遍历 / 计算算法在线热替换，不动已加载图数据 |
| 监督树 | 图引擎为 OTP app；owner / 加载池 / 检查点各受 supervisor 监管、自动重启 |

---

## 7. API 草案

```erlang
%% 图生命周期（owner 进程托管）
graphdb:open(GraphId)            -> {ok, G}.   %% 懒加载 value → CSR 驻留 → 起 owner
graphdb:checkpoint(G)            -> ok.        %% overlay 折叠进 CSR → bitcask:put
graphdb:close(G)                 -> ok.        %% 检查点 + 逐出

%% 写（owner 串行，进 overlay，延迟落盘）
graphdb:add_vertex(G, Vid, Props).
graphdb:add_edge(G, Src, Dst, EProps).
graphdb:del_edge(G, Src, Dst).

%% 读 / 算（纯内存，CSR ⊕ overlay）
graphdb:neighbors(G, Vid, Dir).               %% Dir :: out | in | both
graphdb:bfs(G, Start, Opts).
graphdb:k_hop(G, Start, K).
graphdb:shortest_path(G, Src, Dst).
graphdb:pregel(G, ComputeFun, Opts).          %% 整图 BSP，算完回写
```

---

## 8. libbitcask v1.1.0 收益

热路径是纯 BEAM，libbitcask 价值集中在 **load / checkpoint 吞吐**：

- **单 `pread` 取值** → 整图加载一次 syscall。
- **多读者 + 256 分片 keydir（`std::mutex`，消写者偏好停车）** → 多图**并行加载**不互锁。
- **稠密扁平 keydir（`ankerl::unordered_dense`）** → 海量 GraphId 时每 key 内存低。
- **merge 不阻塞 writer** → 频繁检查点产生的 dead bytes 后台回收。

---

## 9. 权衡与边界

- ✅ 热路径纯内存、Neo4j 级遍历速度、跨图满核并行、崩溃隔离。
- ⚠️ **单图须整张进内存** → `value_too_large` + LRU 封顶；超大图**分区成多 value**
  （`g:<Gid>:<part>`，跨区边记边界引用）——scale 路径，非 MVP。
- ⚠️ **图粒度写放大** → 必须靠 owner 进程**批量检查点**而非每改即写；读多写少 / 批量
  构建场景最舒服。
- ⚠️ **无全局边索引**（如「所有 `:ACTED_IN` 边」）→ 靠顶点属性 BM25 二级索引补，非原生。

---

## 10. 阶段拆分

1. **P1**：CSR 编解码（header / vid_table / xadj / adjncy / vprops）+ owner gen_server
   + load / checkpoint / CRUD（overlay）。
2. **P2**：内存遍历（neighbors / BFS / k-hop / shortest_path，CSR ⊕ overlay）。
3. **P3**：overlay 折叠压实 + LRU 逐出 + MVCC 一致快照读。
4. **P4**：Pregel/BSP 引擎 + 样例算法（PageRank、连通分量、SSSP）。
5. **P5**：入边转置 CSR + 边属性 eprops + 顶点向量混合检索（结构邻居 + 语义邻居）。
