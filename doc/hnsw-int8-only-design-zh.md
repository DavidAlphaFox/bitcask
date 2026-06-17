# P5 — HNSW int8-only 内存模式 设计

> 状态：2.1.1 承诺项。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；落盘 int8 见
> [`vector-ondisk-quant-design-zh.md`](vector-ondisk-quant-design-zh.md)（§7 实测）；
> int8 内核见 [`int8-vnni-v4-zh.md`](int8-vnni-v4-zh.md)。

## 1. 背景与动机

dot 模式下 HNSW 每个节点在内存里同时存两份向量（`NodeChunk`，`hnsw.hpp:138-151`）：
- `vecs`（f32，dim×4 B）——用于建图选边与 top-k 的 **f32 精排**；
- `qcodes`/`qscales`/`qsums`（int8 + 标量）——用于 VNNI **粗筛**提速。

int8 在内存里是**为速度**，反而 **+25% 内存**。P3 落盘 int8 只省磁盘、不动内存。
向量库的真正墙是内存（2560 维、1M 向量 ≈ 12.8 GB 常驻）。**P5 = 丢掉常驻 f32，
全程 int8**，把向量内存降到 ~1/5。

## 2. 目标 / 非目标

- 目标：opt-in `{vector_inmem_int8, true}`，HNSW 不保留 f32 `vecs`，建图 + 查询全
  走 int8；向量内存 −80%（实测 ~5×）。
- 非目标：不改默认（默认仍 f32+int8，召回优先）；不动 L2 度量（int8 路径仅 kDot/
  cosine，见 §6）；不要求与 P3 落盘 int8 同时开（正交，可单独）。

## 3. 内存账（精确）

| 模式 | 每向量字节（向量存储部分） | dim=2560 | 1M 向量 |
|------|--------------------------|----------|---------|
| 现行 f32+int8 | `5·dim + 8`（f32 4d + int8 d + scale4 + sum4） | 12808 B | 12.81 GB |
| **int8-only** | `dim + 8`（int8 d + scale4 + sum4） | 2568 B | 2.57 GB |

邻接表（adj）两模式相同、不计入差值；计入后总占用比略小于 5×。

## 4. 设计

### 4.1 NodeChunk 改造
- `HnswConfig` 增 `bool inmem_int8 = false`。
- `inmem_int8` 时 `NodeChunk` **不分配 `vecs`**（容量 0），只分配 `qcodes/qscales/qsums`。
- `vec_of(id)`（返回 f32 指针）在 int8-only 下不可用——所有读 f32 向量的路径必须改走
  `qcodes_of(id)` + scale。需审计 `vec_of` 的全部调用点（距离、选边、精排、save）。

### 4.2 距离与建图
- 现已有 int8 路径：`greedy_closest` int8 版（`hnsw.cpp:421`）、`search_layer` int8 版
  （459）、`dist_id_int8`。int8-only 下**建图（insert 的 greedy + select_neighbors）也走
  int8 距离**（现行 f32 建图、仅查询粗筛用 int8）。
- **取消 f32 精排**：现行 search 是 int8 粗筛 → f32 精排（`hnsw.cpp:724-748`）。int8-only
  无 f32，精排改为 **int8 精排**（或直接取粗筛序）。召回代价见 §6。
- **查询侧量化**：VNNI int8×int8 需 query 也量化——search 入口对 query 量化一次
  （per-search 一次，`vec::int8::quantize`），全程 int8 dot。

### 4.3 配置 / 接线 / 持久化
- `bitcask:open` 选项 `{vector_inmem_int8, true}` → NIF → `CaskOptions.vector_inmem_int8`
  → `meta` 持久化（`bitcask.meta` offset[10]，紧邻 P3 的 vec_quantized[9]；旧文件全零=否）
  → 重开一致校验（不符 → `mode_mismatch`，同 P3b）。
- `SearchLayerConfig`/`HnswConfig` 透传 `inmem_int8`。
- **与 P3 落盘 int8 正交可组合**：盘 int8 + 内存 int8 = 盘和内存都省。四种组合：
  盘{f32,int8} × 内存{f32+int8, int8-only}。
- **`get` 返回向量**：内存 int8-only 不影响 get——get 读**磁盘** record（盘上 f32 → 精确
  f32；盘上 int8 → P3 的 `doc_vector_f32` dequant）。即「内存表示」与「磁盘/返回表示」解耦。

### 4.4 快照（BCVS）
- BCVS 快照已持 int8（load 时写 qcodes）。int8-only 模式快照**只存 codes+scale**（不存 f32），
  load 直接建 int8-only 图。需 BCVS 版本位标记 inmem_int8 或由 meta 决定。

## 5. 并发
不变：建图仍 IndexPool worker 单写者；读 search 取 `atomic<shared_ptr<HnswIndex>>` 图快照
（V3.5）。int8-only 只改节点内存布局与距离实现，不改并发协议。

## 6. 召回 gate（设默认前必须）

模拟实测（合成簇 dim=2560，`hnsw_test::Int8OnlyMemoryAndRecall`，f32 query ×
dequant-int8 库）：f32 精排 recall@10=1.0 → int8-only **0.9675（−3.25%）**。

**P5c 真实模式 gate（已落地，`hnsw_test::Int8OnlyRecallGate_Dim2560`）**：真正
`inmem_int8` 建图 + 查询（**含 query 量化**，§4.2），合成簇 dim=2560、n=2000：
recall@10 ef64 = **0.9650（−3.5% vs f32）**——query 量化的额外误差仅 ~0.25pt,
比预期小。红线设 **0.90**(回归红线,低于即查实现/量化退化)。
- 度量限制：int8 路径仅 `kDot`（cosine 归一化也走 dot）；**L2 不支持 int8-only**，
  L2 集合开此选项报 `kInvalidOption`（已实现）。
- **默认策略（定）**：默认 **f32+int8**（recall 优先）；`{vector_inmem_int8,true}`
  opt-in,面向内存受限/大规模。
- **诚实边界**：合成簇 ≠ 真实 qwen3 语料——本仓库 CI 无 embedding 端点,用合成
  数据作代理;**推荐默认前仍须在部署侧(qwen3 endpoint)用真实语料复测**召回。

## 7. 子任务
- **P5a**（已落地）：`HnswConfig.inmem_int8`；NodeChunk `inmem_int8` 时 vecs 容量 0；
  insert 只落量化副本、建图全走 int8（`greedy_closest_int8`/`search_layer_int8`/
  新增 `select_neighbors_int8`/收缩用 `dist_id_int8_node`）；search 强制 int8 路径 +
  跳过 f32 精排（found 已按 int8 距离序）；`node_vec` 在 int8-only 下反量化到
  thread_local（供 merge `rebuild_hnsw`）；BCVS save 反量化写 f32、load 读 f32 再量化
  （盘格式仍 v1，盘上存 int8 留 P5b）；非 VNNI 机器加标量 `int8::dot_scalar_raw` 兜底。
  测试 `VectorQuant.Int8OnlyRealModeRecallAndRoundtrip`：真实模式 recall@10=0.9725、
  save/load round-trip 召回一致。
- **P5b**（已落地）：`CaskOptions.vector_inmem_int8` + NIF atom/解析 + erl 透传白名单；
  `MetaConfig.vector_inmem_int8` 持久化到 `bitcask.meta` offset[10]（旧文件全零=否）；
  `check_or_create_meta` 重开一致校验（不符 → kModeMismatch）+ kL2 拒绝（kInvalidOption）；
  meta → `SearchLayerConfig` → `HnswConfig.inmem_int8` 透传。BCVS 快照适配已在 P5a 完成
  （盘存 f32、load 量化）；盘上直接存 int8 的优化仍未做（可选，收益仅省一次 dequant 往返）。
  测试：`P5bInmemInt8OpenSearchAndReopen` / `P5bInmemInt8RejectsL2` /
  `P5bInmemInt8ComposesWithQuantized`。
- **P5c**（已落地，部分）：召回 gate `Int8OnlyRecallGate_Dim2560`（真实 inmem_int8 +
  query 量化，dim=2560 recall@10=0.9650，红线 0.90）；默认策略定为 opt-in（默认 f32+int8）；
  用户文档（`bitcask.erl` open 选项注释加 `{vector_inmem_int8,true}`）。
  **未完**：真实 qwen3 语料复测须在部署侧做（CI 无 embedding 端点，合成簇作代理）。

## 8. 风险
- query 量化误差（harness 未含）→ 真实召回可能略低于 0.9675。
- `vec_of` 调用点遗漏 → int8-only 下空指针/读 0 向量。审计需彻底（save/rebuild/get 路径）。
- L2 不支持 → 明确拒绝。
- 与 P3 组合的四象限需测全。

## 9. 测试
- 复用 `Int8OnlyMemoryAndRecall`（已落地）：recall delta + 内存账断言。
- 新增：open/meta 重开校验、与 P3 组合、BCVS int8-only 快照 round-trip、L2 拒绝。
