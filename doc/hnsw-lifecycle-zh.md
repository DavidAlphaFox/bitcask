# HNSW 图生命周期：构建、持久化与恢复

> 前置阅读：`hnsw-design-zh.md`（V3 HNSW 基础设计）、`int8-vnni-v4-zh.md`（V4.2 量化检索）
> 状态：已实现（文档化梳理）

## 1. 概述

HNSW 多层图经历三个阶段：**增量构建**（put 时逐节点插入）、**全量重建**（merge 时物理清死）、**快照持久化**（close/merge 后落盘）。本文档梳理完整生命周期。

## 2. 增量构建（put 路径）

### 2.1 调用链

```
Cask::put_doc(vec)          [cask.cpp]
  → SearchLayer::on_vector() [search_layer.cpp]
    → HnswIndex::insert()    [hnsw.cpp:568]
```

索引任务在 IndexPool worker 线程串行执行（单写者约束）。put 返回前不阻塞等图构建完成——向量先入 WAL，worker 线程异步消费。

### 2.2 insert() 内部流程

`hnsw.cpp:568-706`

```
insert(ord, vec):
  1. 水位幂等检查：ord <= max_inserted_ord_ → 拒绝（防重复）
  2. 分配 node id，按 id >> 16 定位 NodeChunk（64 个/块，地址稳定）
  3. 随机采样层数：
     u ~ Uniform(0, 1)
     level = floor(-ln(u) / ln(M))     // M=16 → mL≈0.36
     cap at 31
  4. 写入：vec f32 + int8 量化副本 + ord + level
  5. 分配邻接表空间：(1 + 2M) + level × (1 + M)
  6. 发布节点：count_.store(id+1, release)
  7. 首节点 → 设 entry_meta_，return
  8. 从 entry point 贪心下降到 level+1 层（仅导航，不连边）
  9. 逐层（min(level, max_level) → 0）：
     a. search_layer() 找 ef_construction 个候选
     b. select_neighbors()（HNSW Algorithm 4）选 M 条
        - 候选按到 query 距离排序
        - 仅保留比所有已选邻居更近于 query 的候选（多样性启发式）
     c. 双向连边；对方超容量(2M)则裁剪最远边
  10. level > max_level → 更新 entry_meta_（新 entry point）
```

### 2.3 层级分布

采样公式 `level = floor(-ln(U) / ln(M))` 实现指数衰减：

| 层 | M=16 时占比 | 角色 |
|---|---|---|
| L0 | 100% | 全量节点，密图精筛 |
| L1 | ~36% | 区域导航 |
| L2 | ~13% | 大区导航 |
| L3 | ~5% | 全局入口层 |
| L4+ | 递减 | 更稀疏 |

检索时从最高层逐层下降——上层稀疏图快速定位目标区域，下层密图精筛候选。

## 3. 全量重建（merge 路径）

### 3.1 触发条件

Merge 物理压缩 data files 后触发图重建。Merge pipeline 中图重建是 Phase 2 的一部分（`cask.cpp:1661-1665`）：

```
Phase 1: 重写活 record → 新 data files + CAS 更新 KeyDir
Phase 2:
  flush 索引队列
  rebuild BM25 倒排索引
  rebuild_hnsw()  ← 全量重建 HNSW 图
  save_vec_snapshot()  ← 重建后落盘
Phase 3: 清理旧文件
```

### 3.2 rebuild_hnsw() 实现

`search_layer.cpp:76-90`

```cpp
void SearchLayer::rebuild_hnsw() {
    auto fresh = std::make_shared<HnswIndex>(old->config());
    for (id = 0 .. old->size()-1) {
        ord = old->node_ord(id);
        if (!index_.is_live(ord)) continue;  // 物理清死
        fresh->insert(ord, old->node_vec(id));
    }
    hnsw_.store(std::move(fresh));  // 原子换入
}
```

**语义保证**：
- 重建期间并发查询走旧图（含死节点，语义同 V3.4 软删）
- 换入后旧图由在途读者 `shared_ptr` 续命（无锁回收）
- 新图保证零死节点（merge 承诺）

### 3.3 为什么不增量删除死节点

HNSW 图删除节点会导致邻接表悬空边——需要级联修复邻居连接，复杂度 O(dead_count × M × ef_construction)。全量重建虽然 O(N log N)，但只在 merge（低频批处理）时执行，且能重排图结构获得更优拓扑。

## 4. 持久化

### 4.1 格式：BCVS v1 单文件

文件名：`hnsw.snap`（`cask.cpp:24`，常量 `kHnswSnapName`）

```
[magic "BCVS" = 0x42435653][version u32 = 1]
[dim u16][metric u8][M u32][ef_construction u32][seed u64]
[count u32]
[entry_meta u64]              // 高32位=max_level+1, 低32位=entry node id
[max_inserted_ord u64]
[count 个节点]:
  [ord u64][level u8][vec f32×dim]
  [(level+1) 层邻接表]: [cnt u32][cnt × u32 neighbor_id]
[crc32(payload)]
```

**写入**：`tmp + rename` 原子操作（`hnsw.cpp:859`）。读者协议：先 acquire count 和 entry_meta 快照，邻接 id >= count 或 >= 调用方水位的一律跳过（防读到半写状态）。

**注意**：qcodes（int8 量化副本）**不持久化**——load 时从 f32 原始向量重新量化。这保证 BCVS 文件与量化实现解耦（V4.2 之前的快照仍可加载）。

### 4.2 落盘时机

| 时机 | 调用 | 位置 | 说明 |
|---|---|---|---|
| `close()` | `save_vec_snapshot()` | `cask.cpp:617-619` | worker 已停 → 图静止，水位 = max_inserted_ord |
| `merge()` Phase 2 | `save_vec_snapshot()` | `cask.cpp:1664` | rebuild 后立即落盘，下次 open 走快照路径 |
| `put()` | ❌ 不落盘 | — | 只更新内存图，WAL 保证持久性 |

### 4.3 加载时机

| 时机 | 调用 | 位置 | 说明 |
|---|---|---|---|
| `open()` | `load_vec_snapshot()` | `cask.cpp:688-691` | 覆盖性 gate 通过时走快照路径 |
| `open()`（gate 失败） | 全量 fold + `on_vector()` | 回退路径 | 逐条遍历 data files 重建图 |

### 4.4 覆盖性 Gate

```cpp
hnsw_snap_ok = load_vec_snapshot(path);
// gate: max_inserted_ord + 1 >= keydir.next_ord
```

`search_layer.cpp:64-69`：`hnsw_covers_next_ord()` 返回 `max_inserted_ord + 1`（空图返回 0）。

Gate 不通过说明快照之后有新写入未入图——回退全量 fold + WAL replay 补齐增量。

### 4.5 Load 的整体拒绝语义

`hnsw.cpp:871-1038`：CRC 不匹配、config 不一致（dim/metric/M）、邻接 id 越界、层级覆盖不完整——**任一违规整图拒绝**，调用方弃 fresh 实例回退 fold。绝不半载示人。

## 5. 完整生命周期图

```
    put(vec)           put(vec)           put(vec)
      │                  │                  │
      ▼                  ▼                  ▼
  insert(内存)       insert(内存)       insert(内存)
      │                  │                  │
      ·                  ·                  ·
      ·                  ·                  ·
  ┌───┴──────────────────┴──────────────────┘
  │
  ├─ close() ──────────→ save_vec_snapshot() ──→ hnsw.snap
  │                                                  │
  │                                        (进程退出)
  │                                                  │
  ├─ open() ──────────→ load_vec_snapshot() ←── hnsw.snap
  │                       (gate 检查覆盖性)
  │                         ├ pass → 快照加载（秒级）
  │                         └ fail → 全量 fold（O(N log N)）
  │
  └─ merge() ──→ rebuild_hnsw() ──→ save_vec_snapshot() ──→ hnsw.snap
                   (物理清死)        (重建后落盘)
```

## 6. 相关文件索引

| 文件 | 内容 |
|---|---|
| `cpp/src/vector/hnsw.cpp:568-706` | `insert()` — 增量插入 + 层采样 + 连边 |
| `cpp/src/vector/hnsw.cpp:533-566` | `select_neighbors()` — HNSW Algorithm 4 |
| `cpp/src/vector/hnsw.cpp:773-869` | `save()` — BCVS v1 序列化 |
| `cpp/src/vector/hnsw.cpp:871-1038` | `load()` — BCVS v1 反序列化 + 校验 |
| `cpp/src/search/search_layer.cpp:49-53` | `save_vec_snapshot()` |
| `cpp/src/search/search_layer.cpp:55-62` | `load_vec_snapshot()` |
| `cpp/src/search/search_layer.cpp:76-90` | `rebuild_hnsw()` — 全量重建 |
| `cpp/src/cask/cask.cpp:24` | `kHnswSnapName = "hnsw.snap"` |
| `cpp/src/cask/cask.cpp:617-619` | `close()` 落盘 |
| `cpp/src/cask/cask.cpp:688-691` | `open()` 加载 + gate |
| `cpp/src/cask/cask.cpp:1661-1665` | `merge()` rebuild + 落盘 |
| `cpp/include/bitcask/hnsw.hpp:256` | `entry_meta_` 定义 |
