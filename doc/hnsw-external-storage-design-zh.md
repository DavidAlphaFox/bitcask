# V6.4.2: HNSW 外存预留点设计

> 前置阅读：`hnsw-design-zh.md`（V3 HNSW 基础设计）、`vector-db-design-zh.md`（向量引擎总体架构）
> 状态：设计中（不包含实现代码）

## 1. 动机

V3 HNSW 采用全内存架构，向量数据和图结构完全驻留 RAM。对于百万级（1M）向量，在 dim=384 场景下内存占用约 2.2GB，仍在典型服务器（64-128GB）承载范围内。但向千万级（10M）演进时，内存压力显著放大（约 22GB 仅向量数据，不含邻接表）。

本设计旨在：
1. 量化当前 HNSW 节点的内存占用，识别内存悬崖（cliff）位置
2. 明确外存接入点（integration points），为 V7+ 热冷分离做技术储备
3. 识别 shard-local epoch 作为增量持久化锚点

## 2. 内存分析

### 2.1 NodeChunk 内存布局

当前 HNSW 采用 NodeChunk 粒度管理节点，单个 chunk 包含 kChunkSize=64 个节点（见 `hnsw.hpp`）：

```cpp
struct NodeChunk {
    std::vector<float> vecs_;       // f32 × kChunkSize × dim
    std::vector<std::int8_t> qcodes_; // int8 × kChunkSize × dim（V4.2 量化副本）
    std::vector<float> qscales_;    // float × kChunkSize
    std::vector<std::int32_t> qsums_; // int32 × kChunkSize
    std::vector<std::uint64_t> ords_; // u64 × kChunkSize
    // adjacency: per-node 邻接表（每层独立存储）
};
```

### 2.2 单节点内存开销

以 dim=384（常见 embedding 维度）计算：

| 字段 | 大小 | 说明 |
|---|---|---|
| vecs_ | 384 × 4B = 1536B | 原始 f32 向量，检索热路径 |
| qcodes_ | 384 × 1B = 384B | V4.2 int8 量化副本 |
| qscales_ + qsums_ | 4B + 4B = 8B | 量化参数 |
| ords_ | 8B | ord 映射，结果翻译 |
| adjacency | ~320B | u32 × neighbors × levels（平均 5 层，每层约 5 邻居） |
| **合计** | **~2256B ≈ 2.2KB** | |

以 dim=768 计算：

| 字段 | 大小 |
|---|---|
| vecs_ | 768 × 4B = 3072B |
| qcodes_ | 768 × 1B = 768B |
| 其他字段 | 336B |
| adjacency | ~320B |
| **合计** | **~4496B ≈ 4.4KB** | |

### 2.3 规模推演

| 规模 | dim=384 | dim=768 | dim=2560 |
|---|---|---|---|
| 100k | ~220MB | ~440MB | ~1.4GB |
| 1M | ~2.2GB | ~4.4GB | ~14GB |
| 10M | ~22GB | ~44GB | ~140GB |

### 2.4 内存悬崖识别

1. **L3 Cache Cliff**：典型 L3 cache 32MB → 约 14k 向量（14k × 2.2KB = 31MB）超出缓存
   - 后续访问大幅依赖 RAM 延迟，QPS 峰值明显下降

2. **RAM Cliff**：取决于服务器配置
   - 64GB 服务器：~30M 向量（dim=384）可全内存
   - 128GB 服务器：~60M 向量可全内存

3. **邻接表占比较低**：单节点 2.2KB 中，邻接表仅占 320B（~14%），向量本身占主导

## 3. 外存接入点（Integration Points）

### 3.1 当前快照限制

BCVS 快照格式当前实现：所有节点序列化至单个文件，启动时全量加载至 RAM。无 mmap、无懒加载。

### 3.2 可外存化组件分析

| 组件 | 外存化可行性 | 热度 | 外存策略 |
|---|---|---|---|
| vecs_（原始 f32） | **高** | 中 | mmap 只读，图构建完成后不变 |
| qcodes_ + qscales_ + qsums_ | 低 | 高 | 检索热路径（V4.2 int8 乘累加），需常驻 RAM |
| ords_ | 低 | 高 | 结果翻译热路径，需常驻 RAM |
| adjacency | **高** | 中 | mmap 只读，随机访问邻接边 |

**关键观察**：
- 检索时仅使用 qcodes_（int8）计算距离，vecs_ 可作为冷数据外存化
- 邻接表访问模式为跳点式（search 遍历图），可容忍 mmap page fault

### 3.3 Shard-local Epoch 概念

V6 已引入 shard 级 epoch（见 `keydir-sharding-design-zh.md`），每个 shard 维护独立的快照边界。

**定义**：shard-local epoch = 某个 shard 在某一时刻的 ord 快照边界，标记该 shard 内所有「存活」的 ords。

**作用**：
1. 增量外存持久化：按 epoch 分批外存化 NodeChunk，避免全量 dump
2. 热冷分离：近期 epoch 的节点驻留 RAM，历史 epoch 的节点落盘
3. Merge 协同：merge 重组 BCVS 后，冷节点可由 merge 工作线程触发 flush

### 3.4 外存化策略设计

#### V7+ 热冷分离提案

```
┌─────────────────────────────────────────────────────────┐
│ RAM（热区）                                              │
│  - 最近 N 个 epoch 的 NodeChunk（vecs_ + adj 都在内存）  │
│  - 所有 NodeChunk 的 qcodes_/qscales_/qsums_/ords_       │
├─────────────────────────────────────────────────────────┤
│ Disk（冷区）                                             │
│  - 历史 epoch 的 vecs_（mmap 只读）                      │
│  - 历史 epoch 的 adjacency（mmap 只读）                  │
└─────────────────────────────────────────────────────────┘
```

**访问路径**：
- 插入新节点：分配新 NodeChunk（热区，vecs_ 在 RAM）
- 检索：遍历图时，若邻居节点在冷区，触发 mmap page fault（首次访问代价，后续 cached）
- Merge：重建 BCVS 后，识别冷 epoch，批量 flush 至磁盘

#### BCVS v2 格式设想

当前 BCVS 单文件格式 → 拆分为：

| 文件 | 内容 | 加载策略 |
|---|---|---|
| bcvs.header | adjacency + qcodes_/qscales_/qsums_/ords_ | 全量加载 RAM |
| bcvs.payload | vecs_ 分片（按 epoch） | mmap 按需加载 |

**优势**：
- 启动时间大幅减少：仅加载 header（~30% 数据量）
- 检索 QPS 可控：冷节点首次访问触发 page fault，但内存压力可控

### 3.5 Merge 协同设计

Merge 是外存化的关键时机：

1. **BCVS 重建**：merge 输出新的 BCVS 文件，此时可识别「待外存化」的 epoch
2. **冷节点识别**：基于 shard-local epoch 标记，哪些 chunk 需 flush
3. **Flush 触发**：merge 后台线程异步写磁盘，更新元数据（epoch → 文件 offset 映射）

**元数据扩展**：
```cpp
struct ExternalStorageMeta {
    std::unordered_map<epoch_t, DiskRegion> epoch_regions;  // epoch → (file_id, offset, size)
    std::unordered_map<node_id_t, epoch_t> node_to_epoch;   // 节点所属 epoch
};
```

## 4. Cliff 实验计划（V6.4.2 验收）

### 4.1 L3 Cache Cliff

**目标**：验证 14k 向量处 QPS 峰值下降

**方法**：
1. 使用 dim=384，逐步增加向量规模：10k → 15k → 20k → 50k
2. 测量检索 QPS（单查询延迟 95 分位）
3. 观察 14k 处是否存在明显拐点

### 4.2 RAM Pressure Cliff

**目标**：验证 64GB 服务器上 ~30M 向量内存瓶颈

**方法**：
1. 使用 cgroup 限制内存至 64GB
2. 逐步加载向量：10M → 20M → 30M → 40M
3. 测量 OOM 触发点、swap 峰值、QPS 退化

### 4.3 外存接入点识别

**目标**：通过 perf 工具识别 HNSW 检索热点

**方法**：
1. 使用 perf record 对检索路径采样
2. 统计热点函数：vec 访问、qcodes 访问、adjacency 访问
3. 验证「qcodes 为热路径，vecs 为冷路径」假设

## 5. 总结

| 维度 | 结论 |
|---|---|
| 内存占用 | dim=384 单节点 2.2KB，1M 向量 2.2GB，10M 向量 22GB |
| Cliff 位置 | L3 cache 14k，RAM 取决于服务器配置（64GB → 30M） |
| 外存化可行性 | vecs_ + adjacency 可 mmap，qcodes_ + ords_ 需常驻 RAM |
| 接入点 | shard-local epoch 作为增量持久化边界 |
| V7+ 策略 | 热冷分离：近期 epoch 在 RAM，历史 epoch 在磁盘 |

**下一步**：
1. V6.4.2 完成实验验证，确认 cliff 位置
2. V7 实现 BCVS v2 格式 + mmap 支持
3. V7.5 实现热冷分离调度器