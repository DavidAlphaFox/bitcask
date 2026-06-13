# ord 回收复用：可行性分析与方案

> 前置阅读：`vector-db-design-zh.md`（ord 模型）、`ord-density-analysis-zh.md`（gap 分析）、
> `concurrency-zh.md`（锁与不变量）、`recovery-snapshot-design-zh.md`（快照恢复流程）
> 状态：设计分析（含两条方案路径 + 结论建议）

## 1. 动机

Bitcask ord 采用「单调递增、永不复用」策略。高频删写交替（如 TTL cache 场景）下，
`Index` 的平坦数组（`slots_[ord]`、`live_[ord]`、`ord2ext_[ord]`、`doc_lens_[ord]`、
`meta_blobs_[ord]`）随 `next_ord_` 单调增长、永不收缩，死 slot 占据内存但无法回收。

本文分析 ord 回收复用的可行性，给出两条方案路径，并回答「是否值得做」。

## 2. ord 的三重角色

ord 在当前架构中同时扮演三个角色，每一重都假设 ord 永不复用：

| 角色 | 代表代码 | 假设 | 回收后后果 |
|------|----------|------|-----------|
| **数组下标** | `Index::live_[ord]`, `slots_[ord]` | ord → 固定内存偏移 | 新文档读到旧 slot 的 stale 数据 |
| **幂等水位** | `hnsw.cpp:575` `ord <= max_inserted_ord_ → reject`；`inverted.cpp:323` 同理 | ord 永远递增，小 ord = 已处理 | 回收 ord 被水位拦截 → **静默丢弃** |
| **唯一排序键** | `PostingList::items` 按 ord 严格升序无重复；`intersect.hpp` SIMD 求交 | ord 全局唯一且单调 | 旧死文档与新文档碰撞 → **搜索结果错误** |

## 3. ord 不可变不变量全表（20 处）

| # | 组件 | 不变量 | 文件:行 | 回收后破坏方式 |
|---|------|--------|---------|---------------|
| 1 | HNSW | `ord <= max_inserted_ord_` → 拒绝插入 | `hnsw.cpp:575-577` | 回收 ord ≤ 水位 → 向量被静默丢弃 |
| 2 | HNSW BCVS | ord 在快照中严格递增 | `hnsw.cpp:953-955` | 快照加载失败（整体拒绝） |
| 3 | HNSW | `NodeChunk::ords[slot]` = ord | `hnsw.cpp:610,962` | 并发读者看到 stale ord |
| 4 | Inverted | PostingList items 按 ord 升序无重复 | `inverted.hpp:96` | 回收 ord 与死 ord 碰撞 → 错误文档 |
| 5 | Inverted | `add_doc`: ord > max_indexed_ord_ | `inverted.cpp:323-324` | 回收 ord ≤ 水位 → postings 静默丢弃 |
| 6 | Inverted | `PostingList::find()` 按 ord 二分 | `inverted.cpp:28-37` | 返回死文档的 stale index |
| 7 | Inverted | `PostingBlock` base_ord/end_ord 范围 | `inverted.cpp:127-128` | WAND 块跳过误判 |
| 8 | Inverted WAL | WAL 条目存原始 ord | `inverted_wal.cpp:120` | 重放回收 ord 触发水位拦截 |
| 9 | Inverted load | max_indexed_ord_ 从最大 posting ord 重建 | `inverted.cpp:1965-1967` | 快照后回收 ord 被重放拒绝 |
| 10 | Index | 所有数组 `[ord]` | `index.hpp:133-145` | 回收 ord ≥ 数组长度 → 越界 |
| 11 | Index | `put_doc`: 旧 ord 软删，新 ord 占 slot | `index.cpp:69-84` | slot 未清 → stale 数据 |
| 12 | Index | `for_each_live`: 0..size 扫描 live_ | `index.hpp:121-122` | 回收 ord 重复出现 → 双重计数 |
| 13 | Index | `fill_is_live`/`fill_doc_lens` SIMD 假设 in-bounds | `index.cpp:165-184` | 慢路径处理越界；快路径静默出错 |
| 14 | KeyDir | `alloc_ord()` 返回下一个未用值（无回收机制） | `keydir.cpp:333-335` | 无回收机制存在 |
| 15 | KeyDir | `ord` 在 SingleEntry 中是属性，非索引 | `keydir.hpp:82-89` | 风险较低 |
| 16 | Merge | ord 通过 merge 保持不变（不重编号） | `merger.cpp:99-131` | 无影响 |
| 17 | Search | RRF 用 ord 作为去重键 | `search_layer.cpp:286-291` | 死+回收 ord 碰撞 → 错误融合分数 |
| 18 | 交集 | 输入必须严格升序无重复 | `intersect.hpp:11-12` | 回收 ord → 重复 → 错误交集结果 |
| 19 | LiveChecker | `is_live(ord)` / `doc_len(ord)` | `live_checker.hpp:23-24` | 回收 ord 有 stale slot → 返回错误值 |
| 20 | Format | "per-write, 永不复用"（格式头注释） | `format.hpp:25` | 磁盘格式契约违反 |

## 4. 方案 A：seq + merge-gated ord 回收

### 4.1 核心思路

引入独立单调递增的 `seq`（写入序列号）承担幂等水位职责，解耦 `ord` 使其可回收。

- **seq**：全局单调递增、永不回收，用于 HNSW/Inverted 的幂等水位
- **ord**：可回收的数组下标，仅用于 Index 层的数组索引
- **回收窗口**：ord 在 delete 时进入 `pending_free_`，在下次 merge compaction 完成后
  升级为 `available_free_`，此后 `alloc_ord()` 优先从 free list 分配

### 4.2 致命问题：PostingList 升序不变量

> **Oracle 架构审查发现的关键漏洞。**

`PostingList::add_doc` 的实现是 `pl.items.push_back({ord, tf, ...})` —— **纯追加**，
依赖 ord 永远递增。merge-gated 回收后：

```
Merge N 完成后:
  "cat" posting list = [ord=1, ord=7, ord=10]     ← rebuild_index 只保留活文档
  available_free_ = [2, 4, 5, 6, 8, 9]            ← 回收的 ord

新文档到来 → alloc_ord() 返回 ord=2 (回收)
  add_doc(ord=2, {"cat": ...})
    pl.items.push_back({ord=2, ...})
    → "cat" posting list = [1, 7, 10, 2]           ← 不升序！
```

连锁破坏 5 个下游消费者：

| 消费方 | 后果 |
|--------|------|
| `PostingList::find()` 二分查找 | 返回错误位置 |
| WAND `PostingBlock` 块跳过 | base_ord/end_ord 范围假设失效 |
| `note_appended()` / `seal_full_blocks()` | 块边界乱序 |
| `intersect_u64` SIMD 求交 | 前置条件直接违反 |
| `fill_is_live` AVX2 快速路径 | `ords.back() < bound` 优化静默出错 |

### 4.3 修复：PostingList 改为按 seq 存储

PostingList 必须存储 **seq**（全局单调，追加合法）而非 ord。连锁反应：

- `Posting.ord` → `Posting.seq`
- 搜索结果返回 seq → 需要 `seq2ord_[seq]` 转换才能访问 `live_[]` / `ord2ext_[]`
- `fill_is_live(seqs)` 需要批量 seq→ord 转换后再查 `live_[]`
- `compact_flags` 的 live 数组按 ord 索引 → 需要 seq→ord 映射
- 17 个 `snapshot_flat` + `fill_is_live` 调用点全部需要改造

### 4.4 安全的组件

以下组件在 merge-gated 回收下是安全的：

| 组件 | 安全原因 |
|------|----------|
| **HNSW** | 已有独立内部 node id（u32 插入序号），ord 只是元数据。merge 重建后无死节点，recycled ord 不会碰撞 |
| **WAL replay** | seq 水位正确拒绝旧条目：`seq=100 ≤ max_indexed_seq_=200 → 拒绝` |
| **`for_each_live`** | 扫描 `0..size()` 检查 `live_[ord]`，回收 slot 被重用不影响迭代语义 |
| **并发搜索** | merge 期间 `IndexPool::flush()` 保证无并发写，HNSW 指针通过 `atomic<shared_ptr>` 原子交换 |

### 4.5 改动清单

| 步骤 | 改动 | 规模 | 风险 |
|------|------|------|------|
| 1 | KeyDir 加 `next_seq_` 原子，SingleEntry 加 seq 字段 | Quick | 低 |
| 2 | 数据文件记录格式加 seq（`format.hpp`） | Quick | 低 |
| 3 | HNSW 水位 → `max_inserted_seq_`，节点存 seq | Short | 低 |
| 4 | InvertedIndex 水位 → `max_indexed_seq_` | Short | 低 |
| 5 | WAL add_doc 条目加 seq 字段 | Short | 低 |
| 6 | **PostingList 改为按 seq 存储** | **Large** | **最高** |
| 7 | Index 加 `seq2ord_[]` 数组 | Short | 中 |
| 8 | 17 个 `fill_is_live` 调用点加 seq→ord 转换 | Large | 高 |
| 9 | `compact_flags` live 数组改为 seq 索引 | Medium | 中 |
| 10 | free list（pending_free_ / available_free_） | Short | 中 |
| 11 | merge 管线最后一步：pending → available | Short | 高 |
| 12 | 所有快照格式更新 | Short | 低 |

**步骤 6-9 是风险集中区**——直接改造搜索热路径。

### 4.6 与 generational index（slotmap）的对比

Generational index `gen_idx = (slot << 20) | generation`：
- slot = 可回收数组下标（等价 ord）
- generation = 每 slot 独立的单调代次

**关键区别**：slotmap 的 generation 是 **per-slot** 的（slot 回收时递增），
而 seq 是 **global** 的。这意味着 gen_idx **不是全局单调的**
（slot=2/gen=3 < slot=7/gen=1），PostingList 升序问题依然存在。

| 方面 | seq 方案 | slotmap |
|------|----------|---------|
| PostingList 排序 | 按 seq 存储（全局单调）✓ | gen_idx 非全局单调 → 仍有问题 |
| Live 检查 | `live_[ord]` 数组 | 比较 generation → 可省去 live_ 数组 |
| 水位比较 | 简单 u64 比较 | 需比较 (slot, gen) 对 |
| 内存 | seq 额外 8B/doc | generation 打包进同一 u64（0 额外） |
| 改造面 | 20 个不变量 | 20 个不变量 + ord 类型从 u64 改为打包 gen_idx |

**结论**：slotmap 对本代码基更差，因为 gen_idx 非全局单调，PostingList 问题无法解决。
seq 方案严格优于 slotmap。

## 5. 方案 B：分块数组（Tiered Arrays）

### 5.1 核心思路

> Oracle 推荐的简化方案。

真正的问题不是 ord 空间耗尽（uint64_t 每秒 100K 写 → 用 5800 万年），而是
**Index 数组无限增长、死 slot 占内存**。不需要回收 ord，只需要回收内存。

将 `Index` 的平坦 `vector<T>` 改为分块结构：

```cpp
static constexpr std::size_t kChunkOrds = 65536;  // 每 chunk 64K 个 ord

struct Chunk {
    std::array<DocSlot,     kChunkOrds> slots;
    std::array<uint8_t,     kChunkOrds> live;
    std::array<uint32_t,    kChunkOrds> doc_lens;
    uint32_t live_count = 0;     // == 0 时整个 chunk 可释放
};

std::vector<std::unique_ptr<Chunk>> chunks_;  // chunk N 覆盖 [N*64K, (N+1)*64K)
```

### 5.2 优势

- **ord 保持单调递增，永不回收** — 20 个不变量全部不动
- **内存回收**：merge 时扫描所有 chunk，`live_count == 0` 的 chunk 直接释放
- **O(1) 索引**：`chunk_idx = ord / 65536; slot_idx = ord % 65536;`
- **`for_each_live` 更快**：跳过全死 chunk
- **`fill_is_live` AVX2**：chunk 内连续，SIMD 路径不变
- **零不变量改动**：PostingList、WAL、HNSW、快照格式全部不动

### 5.3 局限

如果删除是均匀分布的（每个 chunk 都有几个活 ord），没有 chunk 能达到
`live_count == 0`，内存无法回收。适合突发性批量删除场景，不适合均匀 churn。

## 6. Compaction 时间线（物理清死流程）

```
 Delete 时间点: live_[ord] = false (软删除)，postings 和 HNSW 节点仍在
                    ↓
 Merge Phase 2.4: rebuild_index() — 全量 BM25 重建，只索引活文档 → 死 postings 物理消失
 Merge Phase 2.6: rebuild_hnsw()  — 全量图重建，跳过死节点 → 死节点物理消失
                    ↓
 Merge 完成: 此时回收的 ord 在所有索引中已无残留（方案 A 的 free list 升级时机）
```

**关键发现**：`SearchLayer::compact()`（在线压缩，S10.11）**不在 merge 管线中**。
Merge 使用 `rebuild_index()`（全量重建）。`compact()` 是独立的外部 API。

### WAL 字节级格式（回收方案需改动处）

```
File Header (8 bytes):
  [magic 0x57414C31 "WAL1"][version u32=1]

Per-Entry (O11 framing):
  [PayloadLen:u32][Payload][CRC32:u32]

kWalEntryAddDoc (0x01):
  [0x01:u8][ord:u64][term_count:u32]
  × term_count: { [term_len:u32][term][tf_vbyte_len:u32][tf_vbyte]
                  [pos_count:u32][pos_csize:u32][gap_encoded_positions] }

kWalEntryRemoveDoc (0x02):
  [0x02:u8][doc_len_vbyte_len:u32][doc_len_vbyte]
  [term_count:u32]
  × term_count: { [term_len:u32][term][tf_vbyte_len:u32][tf_vbyte] }
```

方案 A 需在 `kWalEntryAddDoc` 的 `ord:u64` 旁增加 `seq:u64`。

## 7. 方案对比

| 维度 | 方案 A（seq + 回收） | 方案 B（分块数组） |
|------|---------------------|-------------------|
| 改动文件 | ~15 | 3-4（index.hpp/cpp + search_layer.cpp） |
| 不变量改动 | 20 | 0 |
| PostingList 改造 | 需要（大工程） | 不需要 |
| WAL / 快照格式 | 破坏性变更 | 不变 |
| 工期 | 2-3 周 | 1-2 天 |
| 风险 | 高（搜索热路径） | 低（存储层隔离） |
| 内存回收效果 | 完美（无空洞） | 依赖块聚集性 |
| 部分-dead 块处理 | 无空洞 | 仍有内存浪费 |
| 适用场景 | 均匀 churn + 内存敏感 | 突发批量删除 |

## 8. 结论：这个设计有必要吗？

### 8.1 ord 空间耗尽？

**不需要。** ord 是 `uint64_t`。每秒 100K 写 → 584 万亿年才耗尽。
即使 32-bit ord 也够 12 天连续写入。ord 回收**不是**为了防止空间耗尽。

### 8.2 Index 数组内存增长？

**这是真正的痛点**，但量级取决于工作负载：

```
假设 1 亿文档（高 churn：90% 已删除）:
  slots_:      32B  × 100M = 3.2 GB
  live_:        1B  × 100M = 100 MB
  doc_lens_:    4B  × 100M = 400 MB
  ord2ext_:   ~50B  × 100M = 5.0 GB   (字符串平均 50 字节)
  meta_blobs_: ~200B × 100M = 20 GB   (如果存 meta)
  → 总计 ~29 GB，其中 90% 是死 slot 浪费的 ~26 GB
```

对于嵌入式设备或内存受限环境，这是真实问题。
对于服务器（256GB+ RAM），1 亿文档的浪费可以容忍。

### 8.3 方案 B 是否够用？

**对大多数场景够用。** 分块数组的优势是零风险、零不变量改动。
如果删除模式有聚集性（批量过期、TTL 窗口），大部分 chunk 能完全回收。

唯一不够的场景：**持续均匀 churn**（每个 64K 窗口都有少量活文档）。
此时方案 B 无效，需要方案 A 或在 chunk 内做局部 compaction。

### 8.4 建议

**当前阶段：不做。** 理由：

1. **问题尚未出现**：没有实际工作负载数据显示 Index 数组内存成为瓶颈
2. **方案 A 成本极高**：改造搜索热路径（PostingList → seq），引入 12+ 步变更，
   2-3 工期，风险集中在唯一的 BM25 搜索链路上
3. **方案 B 是更好的第一步**：如果未来出现内存问题，先上分块数组（1-2 天），
   零不变量风险。如果分块数组不够（均匀 churn），再评估方案 A
4. **过早优化**：当前 ord 模型简洁、正确、经过充分测试。
   引入 seq 增加了一层概念复杂度（ord + seq 双 ID 空间），维护成本永久上升

**触发条件**（满足任一可重新评估）：
- Index 数组内存占用在实际工作负载下超过可用内存的 20%
- 出现需要频繁全量 merge 来回收内存的运维痛点
- 嵌入式部署场景对内存有硬性限制

**当需要做时**：先走方案 B（分块数组），不够再走方案 A（seq + PostingList 改造）。
两条路径不互斥——方案 B 的分块基础设施可以与方案 A 的 seq 回收叠加。

## 9. ord 为什么是 per-write 分配（而非 per-key）？

### 9.1 写路径追踪

`Cask::put()` 每次调用都 `alloc_ord()` 分配新 ord（`cask.cpp:1266`）。
`Cask::remove()` 也分配新 ord 作为墓碑标识（`cask.cpp:1318`）。

```
put("foo", "cat dog")  → ord=0 → "cat" PL: [0], "dog" PL: [0]
put("foo", "cat fish") → ord=1 → "cat" PL: [0,1], "fish" PL: [1]
                         put_doc: live_[0]=false, live_[1]=true, ext2ord_["foo"]=1
put("foo", "dog bird") → ord=2 → "dog" PL: [0,2], "fish" PL: [1(dead)], "bird" PL: [2]
                         put_doc: live_[1]=false, live_[2]=true, ext2ord_["foo"]=2
delete("foo")           → ord=3 → 墓碑 record, live_[2]=false
```

同一 key 更新 3 次 + 删除 1 次 = **消耗 4 个 ord**。

### 9.2 三个硬约束

**约束 1：PostingList 是追加式有序数组**

`add_doc` 的实现是 `pl.items.push_back({ord, tf, ...})`（`inverted.cpp:340-355`）—— 纯尾部追加，
依赖 ord 永远递增来维持升序不变量。如果 ord 复用（同一 key 保持相同 ord）：

```
put("foo", "cat dog")   → ord=0 → add_doc(0, {"cat","dog"})    ← push_back
put("foo", "cat fish")  → 同 ord=0 → add_doc(0, {"cat","fish"})
  问题：水位检查 ord=0 ≤ max_indexed_ord_=0 → 直接拒绝，更新进不了索引
  即使绕过水位：需要在 "dog" PL 中删除 ord=0（O(n)），
  在 "fish" PL 中插入 ord=0（O(n)，因为 0 不是最大值）
```

**约束 2：HNSW 无法原地更新向量**

HNSW 节点存的是 ord 对应的向量。更新文档意味着向量改变，但 HNSW 不支持原地向量替换——
删旧节点会破坏图连通性（邻接断裂）。当前方案：旧节点标记死（`is_live(ord)` 过滤），
merge 时整体重建。

**约束 3：幂等水位依赖 ord 单调性**

HNSW（`hnsw.cpp:575`）和 InvertedIndex（`inverted.cpp:323`）都用水位 `ord <= max_X_ord_ → 拒绝`，
保证崩溃恢复时 WAL 重放不重复。同 ord 二次写入会被水位直接拦截。

### 9.3 ord = 搜索索引的文档版本标识

```
KV 层（KeyDir）：    key → file_loc, tstamp     ← 可以原地替换，tstamp 决定胜负
搜索层（Index）：    ord → postings, HNSW node  ← 无法原地更新，只能追加新版本 + 软删旧版本
```

如果只有 KV 没有 search_layer，理论上可以复用 ord。但一旦有倒排索引 + HNSW，
每次更新就必须是一个新 ord。**ord per-write 是搜索引擎的硬约束，不是设计缺陷。**

## 10. 倒排列表膨胀与 compaction 机制

### 10.1 死 posting 的生命周期

`InvertedIndex::remove_doc`（`inverted.cpp:361-373`）**只扣全局统计**（`live_doc_count_--`、
`sum_doc_len_ -= doc_len`），**不从 posting list 里删除 posting**：

```cpp
void InvertedIndex::remove_doc(uint32_t doc_len, const unordered_map<string,uint32_t>& term_freqs) {
    live_doc_count_.fetch_sub(1, ...);      // 只减计数
    sum_doc_len_.fetch_sub(doc_len, ...);   // 只减总长度
    if (wal_) wal_->append_remove_doc(...); // 写 WAL
    // ← 注意：没有遍历 posting list 删除死 ord 的 posting
}
```

死 posting 留在 `items[]` 中，经历：

```
add_doc(ord=0, "cat")   → "cat" PL: [Posting{ord=0, tf=1}]
put("foo") 更新 → ord=0 标死
  ↓ 查询时: snapshot_flat() 拷出所有 posting（含死）→ fill_is_live() 批量过滤 → 只对 live 评分
  ↓ compact(): dead_ratio ≥ 50% 时 compact_flags() 物理移除死 posting
  ↓ 或 merge 时 rebuild_index(): 全量重建，只索引活文档
```

### 10.2 查询时的死 posting 过滤

所有搜索路径使用**批量 `fill_is_live`** 而非逐 posting 检查（P2.1 优化）：

| 搜索路径 | fill_is_live 位置 | 过滤方式 |
|---------|-------------------|---------|
| score_bow_topk | `inverted.cpp:119` | `fill_is_live(fp.ords, live)` → 评分后 `if (live[i])` 筛选 |
| search_wand | `inverted.cpp:525` | `fill_is_live(tp.fp.ords, tp.live)` → pivot 检查 |
| search_phrase | `inverted.cpp:743` | `fill_is_live(first_ords, first_live)` → 候选检查 |
| bool_search BMW | `inverted.cpp:1036` | 块级惰性 fill，`ensure_block()` |
| bool_search must/should | `inverted.cpp:1156` | 每 term 批量 fill |

**设计选择**：死 posting 也参与 SIMD 评分（branchless），结果不用。注释（`inverted.cpp:131-132`）：
> "死点也算、结果不用，保持无分支"

这是刻意的性能权衡——无分支 SIMD 全量评分 + 后置过滤，比逐 posting 分支检查更快。

### 10.3 compaction 机制

| 机制 | 触发方式 | 清理效果 | 位置 |
|------|---------|---------|------|
| `compact()` | **仅手动 API，无自动触发** | dead_ratio ≥ 阈值时移除死 posting | `inverted.cpp:1541` |
| `rebuild_index()` | merge 时 | 全量重建，完全无死 posting | `search_layer.cpp:984` |
| 查询时过滤 | 每次 search | 不回收内存，只保证正确性 | 全搜索路径 |

`compact()` 默认阈值 0.5（50% 死率）。`compact_flags`（`inverted.hpp:182-198`）过滤死 posting、
保序、重建 WAND 块元数据。

**关键 gap：`compact()` 不在 merge 管线中，也没有后台线程自动触发。**
merge 用的是 `rebuild_index()`（全量重建）。如果用户不手动调 `compact()` 也不 merge，
posting list 会随写入无限膨胀。

### 10.4 `fill_is_live` 成本

`Index::fill_is_live`（`index.cpp:159-184`）—— 批量取 live 状态：

- **AVX2 快速路径**：`vpgatherdq` 一次 gather 4 个 ord，整列一次 `shared_lock`
- **慢路径**：逐 ord `live_arr[ords[i]]` 数组下标
- **每 ord 成本**：~2 cycles（无 SIMD），~0.5 cycles（AVX2 gather）
- **主要开销**：`shared_lock` 获取（每 term 每查询一次，非每 posting）

## 11. 业界对比：主流搜索引擎如何处理文档更新

### 11.1 Lucene / Elasticsearch

Lucene 的 `updateDocument` 内部实现是 **delete + insert**：

```java
// Lucene IndexWriter
writer.updateDocument(new Term("id", "doc1"), updatedDoc);
// 内部执行：
//   1. deleteDocuments(new Term("id", "doc1"))  → 标记旧文档删除
//   2. addDocument(updatedDoc)                   → 插入新文档（新 doc ID）
```

- **每次更新获得新 doc ID**（segment 内递增），旧 doc 标记为 deleted
- **LiveDocs bitset**：Lucene 10.4 引入 `SparseLiveDocs`（≤1% 删除时用稀疏 bitset）
  和 `DenseLiveDocs`（>1% 删除时用传统 bitset），查询时 O(1) 过滤
- **segment merge**：合并时跳过 deleted 文档，物理回收。ES 默认 33% 删除率触发优先 merge

> 引用：[Lucene segment merging](https://dev.to/iprithv/lucene-segment-merging-when-and-why-the-index-rewrites-itself-1k78)
> "Lucene's immutable segment design means documents are never updated in place."

### 11.2 Tantivy（Rust）

与 Lucene 完全相同的模型：

> 引用：[Tantivy ARCHITECTURE.md](https://github.com/quickwit-oss/tantivy/blob/main/ARCHITECTURE.md)
> "On commit, tantivy will find all of the segments with documents matching this existing term
> and remove from alive bitset file... Like all segment files, this file is immutable."

### 11.3 Solr

Solr 对 `docValues="true"` 的数值字段支持**原地更新**（不重建倒排索引），
但条件极严苛：字段必须 `indexed="false"` + `stored="false"` + `docValues="true"` + 数值类型。
对倒排索引中的文本字段，仍然是 delete + insert。

> 引用：[Solr partial updates](https://solr.apache.org/guide/solr/latest/indexing-guide/partial-document-updates.html)

### 11.4 对比总结

| 引擎 | 文档 ID 是否稳定 | 原地更新 posting list | 死文档清理 |
|------|:---:|:---:|-----------|
| **Lucene** | 否（每次更新新 ID） | 否 | LiveDocs bitset + segment merge |
| **Elasticsearch** | 否（继承 Lucene） | 否 | bitset + merge |
| **Tantivy** | 否（每次更新新 ID） | 否 | alive bitset + merge |
| **Solr** | 否（仅 docValues 数值字段可原地） | 否 | bitset + merge |
| **bitcask** | 否（ord per-write） | 否 | `live_[]` bitmap + compact/rebuild |

**bitcask 的 ord-per-write 模型与 Lucene 完全一致——这就是业界标准做法。**
没有任何主流搜索引擎使用「保持 ID 不变 + 原地更新 posting list」的方案。

### 11.5 为什么不原地更新 posting list？

1. **有序数组原地删除 = O(n)**：需要从中间移除并移动元素
2. **HNSW 无法原地更新向量**：删节点破坏图连通性
3. **不可变数据结构 = 并发友好**：Lucene segment 和 bitcask PostingList（`shared_ptr` + CoW）
   都依赖不可变性实现 lock-free 读。原地修改需要阻塞所有读者
4. **幂等水位依赖单调 ID**：崩溃恢复时需要区分新旧版本

## 12. 如果要控制 posting list 膨胀

当前 gap：`compact()` 无自动触发。三种解决方案（**均不需要改 ord 模型**）：

| 方案 | 改动 | 效果 |
|------|------|------|
| **后台 compact 线程** | 定期扫描 dead ratio，超阈值自动 `compact()` | 低延迟回收，适合在线服务 |
| **merge 时加 compact 步** | 在 `rebuild_index` 前先 `compact()` | 减少全量重建频率 |
| **写路径触发** | `add_doc` 后检查所在 PL 的 dead ratio，超阈值异步 compact | 精准回收，但增加写延迟 |
