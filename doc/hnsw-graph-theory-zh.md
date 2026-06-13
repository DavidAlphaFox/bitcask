# HNSW 多层图原理：数据结构、搜索复杂度与量化必要性

> 前置阅读：`hnsw-design-zh.md`（V3 基础设计）、`hnsw-lifecycle-zh.md`（图生命周期）、`int8-vnni-v4-zh.md`（量化内核实现）
> 参考文献：Malkov & Yashunin, "Efficient and robust approximate nearest neighbor search using Hierarchical Navigable Small World graphs," [arXiv:1603.09320](https://arxiv.org/abs/1603.09320)
> 状态：已实现（理论梳理文档）

## 1. 数据结构

### 1.1 内存布局：一张图，分层索引

不是每层一张独立图，是**一张图、节点带层级标签、邻接表按层分区内嵌**。

#### NodeChunk（64 个节点/块）

`hnsw.hpp:131-149`，构造时定容，生命周期内地址稳定：

```
NodeChunk {
    float[]          vecs;       // kChunkSize × dim（f32 原始向量）
    int8_t[]         qcodes;     // kChunkSize × dim（int8 量化副本，检索用）
    float[]          qscales;    // kChunkSize（每向量一个 scale = max|v|）
    int32_t[]        qsums;      // kChunkSize（每向量一个 Σcodes，VNNI 偏置）
    uint64_t[]       ords;       // kChunkSize（ord 映射）
    uint8_t[]        levels;     // kChunkSize（节点最高层）
    uint32_t*[]      adj;        // kChunkSize（邻接块首指针，永不搬迁）
    atomic<u8>[]     locks;      // kChunkSize（per-node 自旋锁）
}
```

#### 邻接块：单次分配，按层分区

每个节点的邻接表是一次 `new uint32_t[slots]` 分配（`hnsw.cpp:616-618`），布局：

```
M=16, level=3 的节点邻接块（97 个 u32 slot）:

偏移 layer_off(0)=0:   [L0_count | id₁ id₂ ... id₃₂]   ← 容量 2M=32
偏移 layer_off(1)=33:  [L1_count | id₁ id₂ ... id₁₆]    ← 容量 M=16
偏移 layer_off(2)=50:  [L2_count | id₁ id₂ ... id₁₆]    ← 容量 M=16
偏移 layer_off(3)=67:  [L3_count | id₁ id₂ ... id₁₆]    ← 容量 M=16
偏移 84:               （无 L4，该节点不在更高层出现）
```

`layer_off(layer)` 计算（`hnsw.hpp:182-187`）：

```cpp
size_t layer_off(uint32_t layer) const {
    return layer == 0 ? 0
         : (1 + cfg_.M * 2) + (layer - 1) * (1 + cfg_.M);
}
```

L0 容量 = 2M（密图精筛），上层每层容量 = M（稀疏导航）。

`copy_neighbors(id, layer, out)` 加 per-node 自旋锁拷出指定层邻居列表（`hnsw.cpp:323-336`）。

### 1.2 层级分配

`hnsw.cpp:594-597`，标准 HNSW 指数衰减采样：

```cpp
double u = uniform_real_distribution<double>(0.0, 1.0)(rng_);
if (u < 1e-12) u = 1e-12;
auto level = static_cast<uint32_t>(-std::log(u) * inv_log_m_);
if (level > 31) level = 31;
```

其中 `inv_log_m_ = 1.0 / ln(M)`（`hnsw.cpp:311`）。M=16 时 `mL ≈ 0.36`：

| 层 | P(节点出现在此层) | 1M 向量时节点数 | 每节点邻居容量 |
|---|---|---|---|
| L0 | 100% | 1,000,000 | ≤ 2M = 32 |
| L1 | ~36% | ~360,000 | ≤ M = 16 |
| L2 | ~13% | ~130,000 | ≤ M = 16 |
| L3 | ~5% | ~50,000 | ≤ M = 16 |
| L4 | ~2% | ~18,000 | ≤ M = 16 |

最高层节点数 ≈ O(log N)。entry point 固定在最高层节点（`entry_meta_` 高 32 位 = max_level+1，低 32 位 = entry id）。

### 1.3 与跳表的类比

论文原文：

> "Hierarchical NSW algorithm can be seen as an extension of the probabilistic skip list structure with proximity graphs instead of the linked lists."

```
Layer 3 (最稀疏):   A ─────────────────────────────── Z
                     ↑                                  ↑
Layer 2:           A ──────── F ──────────────────── Z
                     ↑          ↑                       ↑
Layer 1:           A ── C ──── F ──── I ────────── Z
                     ↑   ↑      ↑        ↑            ↑
Layer 0 (最密):    A──B──C──D──E──F──G──H──I──J──...──Z
```

高层 = "高速公路"：每跳跨大距离，快速定位目标区域。低层 = "本地路"：小步精筛。

## 2. 搜索算法与复杂度

### 2.1 三阶段流程

`hnsw.cpp:709-771`：

```
search(query, k, ef):
  Phase 1: 上层贪心下降（layer max → 1）
    for l = max_level downto 1:
        cur = greedy_closest(cur, l)
        // 每层只看 M 条边，贪心走最近，不回头
        // 收敛条件：连续一轮无改进

  Phase 2: L0 束搜（beam search）
    results = search_layer(cur, ef, layer=0)
    // 双优先队列：cands(min-heap) + top(max-heap, ≤ef)
    // 收敛条件：下个候选比 top 中最差的还远 → break

  Phase 3: f32 精排
    partial_sort(results[0..k×3] by f32 distance)
    return top-k
```

### 2.2 greedy_closest — 上层贪心下降

`hnsw.cpp:338-362`：

```cpp
cur = start;
cur_d = dist_id(q, cur);
while (improved) {
    improved = false;
    cnt = copy_neighbors(cur, layer, scratch);
    for (nid in scratch[0..cnt]):
        prefetch_vec(vec_of(nid));      // 预取下批向量
    for (nid in scratch[0..cnt]):
        d = dist_id(q, nid);
        if (d < cur_d) { cur = nid; cur_d = d; improved = true; }
}
return cur;
```

纯贪心：每轮检查当前节点的全部邻居，走最近的一个。无法改进时停止。每层访问 M 个邻居 × 若干轮。

### 2.3 search_layer — L0 束搜

`hnsw.cpp:364-423`：

```cpp
// cands: min-heap（最近优先展开）
// top:   max-heap（保留 ef 个最近，便于踢最远）
cands.push({d0, entry});
top.push({d0, entry});

while (!cands.empty()) {
    [d, id] = cands.top();
    if (d > top.top().first && top.size() >= ef) break;   // 收敛
    cands.pop();
    cnt = copy_neighbors(id, layer, scratch);
    for (nid in scratch[0..cnt]):
        if (visited[nid] == epoch) continue;
        visited[nid] = epoch;
        nd = dist_id(q, nid);
        if (top.size() < ef || nd < top.top().first) {
            cands.push({nd, nid});
            top.push({nd, nid});
            if (top.size() > ef) top.pop();
        }
}
```

`ef`（beam width）控制精度与速度的权衡：ef 越大，候选越多，recall 越高，越慢。

### 2.4 Visited 集合：thread_local 版本化数组

`hnsw.cpp:271-283, 369-381`：

```cpp
struct VisitedTable {
    vector<uint32_t> marks;   // 按 node id 索引
    uint32_t epoch = 0;       // 每次 search 自增
    uint64_t owner = 0;       // HnswIndex 实例 id（防 ABA）
};
thread_local VisitedTable t_visited;
```

标记方式：`visited[nid] = epoch`，检查 `visited[nid] == epoch`。无需清零数组，epoch 回绕时才整体清。per-thread，无竞争。

### 2.5 为什么是 O(log N)

论文（[arXiv:1603.09320](https://arxiv.org/abs/1603.09320) Section 4.2）证明：

1. **每层搜索步数是常数，与 N 无关。** 因为层级采样是指数衰减：`P(node 在 layer l) = exp(-l × ln M)`。
2. 在 layer l 搜索时，邻居也在 layer l——这是图的稀疏骨架。贪心走 S 步仍未找到更近节点的概率 ≤ `exp(-S × mL)`。
3. 期望步数 `E[S] = 1 / (1 - exp(-mL))`——**常数**。
4. 层数 = O(log N)，每层常数步，总复杂度 = **O(log N)**。

### 2.6 实际访问量

| 阶段 | 访问节点数 | 数据来源 |
|---|---|---|
| 上层贪心下降 | ~250 | 论文实测 ([arXiv:2507.17647](https://arxiv.org/abs/2507.17647)) |
| L0 束搜 (ef=200) | ~5,770 | 同上 |
| f32 精排 | k×3 ≤ 30 | 代码 `hnsw.cpp:746` |

**1M 向量中只访问 ~6,000 个节点 = 0.6%。**

## 3. 为什么需要量化

### 3.1 瓶颈是内存，不是计算

HNSW 图遍历的本质是**指针追逐（pointer chasing）**：

```
dist_id(node_id)
  → chunks_[id >> 16].load()           // 随机 NodeChunk 地址
  → chunk->qcodes.data() + id × dim    // 随机偏移
  → 读取 dim 个值
```

邻居节点在内存中随机散布——图拓扑不保证空间局部性。CPU prefetcher 无法预测下一跳。

int8 点积（dim=384）计算量 ~50ns（VNNI），但 RAM miss 延迟 ~80-100ns。**CPU 在等内存，不是在做计算。**

### 3.2 量化对每跳的影响

| 维度 | f32 路径 | int8 路径 |
|---|---|---|
| 每节点读取 | dim×4B = 1536B | dim×1B = **384B** |
| 占用缓存行 | 24 行 | **6 行** |
| L3 (32MB) 可容纳 | ~14k 节点 | **~44k 节点** |
| L1 (48KB) 可容纳 | ~21 节点 | **~66 节点** |

int8 把 L3 cliff 从 14k 推到 44k——**3.1× 延迟收益**。

### 3.3 两阶段检索

int8 对称量化有精度损失（7bit 定点 vs 23bit 浮点）。只看 int8 距离，top-1 可能错排。解决方案：

```
Phase 1 (int8 粗筛): 图遍历，拿 ef 个候选     ← 追求速度
Phase 2 (f32 精排):  仅对 k×3 候选算 f32 距离  ← 追求精度
```

Phase 2 只算 ~30 个 f32 距离（~5μs），不影响整体延迟，但补偿量化误差。实测 recall@10 > 95%。

### 3.4 业界对比

FAISS (`IndexHNSWSQ`)、Elasticsearch（`dense_vector` 量化）、Qdrant 等均采用相同的两阶段量化模式。Elasticsearch 实测：int8 量化后 recall 退化 < 1%，QPS 提升 3-4×。

量化误差被 HNSW 本身的算法近似误差所主导——即使 f32 精确距离，HNSW 也只返回近似最近邻。int8 引入的额外误差在此背景下可忽略。

## 4. 相关文件索引

| 文件 | 内容 |
|---|---|
| `cpp/include/bitcask/hnsw.hpp:131-149` | NodeChunk 结构 |
| `cpp/include/bitcask/hnsw.hpp:178-187` | layer_off / layer_cap |
| `cpp/include/bitcask/hnsw.hpp:256-257` | entry_meta_ 编码 |
| `cpp/src/vector/hnsw.cpp:271-283` | VisitedTable 版本化数组 |
| `cpp/src/vector/hnsw.cpp:323-336` | copy_neighbors |
| `cpp/src/vector/hnsw.cpp:338-362` | greedy_closest（上层贪心下降） |
| `cpp/src/vector/hnsw.cpp:364-423` | search_layer（L0 束搜） |
| `cpp/src/vector/hnsw.cpp:427-461` | greedy_closest_int8（量化版） |
| `cpp/src/vector/hnsw.cpp:465-531` | search_layer_int8（量化版束搜） |
| `cpp/src/vector/hnsw.cpp:568-706` | insert（增量构建 + 层采样 + 连边） |
| `cpp/src/vector/hnsw.cpp:709-771` | search（三阶段调度） |
| `cpp/include/bitcask/int8_kernels.hpp:89-118` | quantize（f32 → int8） |
| `cpp/include/bitcask/int8_kernels.hpp:190-287` | VNNI dot product 内核 |
