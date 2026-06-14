# Merge 触发策略与 HNSW 死节点回收

> 前置阅读：`hnsw-lifecycle-zh.md`（HNSW 图生命周期）、`format-zh.md`（磁盘格式）
> 状态：已实现

## 1. 概述

bitcask 的 merge **不会自动触发**——没有后台定时器，没有写入量阈值自动启动。
调用方必须显式调用 `bitcask:needs_merge/1` 检查，再调 `bitcask:merge/1` 执行。

merge 是唯一物理回收 HNSW 死节点（已 delete 的文档向量）的时机。在此之前，
死节点通过搜索时的 `is_live` callback 软过滤。

## 2. Delete → HNSW：软删

### 2.1 delete 时发生了什么

```
bitcask:delete(Ref, Key)
  └→ Cask::remove(key)
       ├→ KeyDir: 写 tombstone entry（ord 分配不变）
       └→ IndexPool worker:
            ├→ SearchLayer::on_delete(key, ord)
            │    ├→ BM25 倒排索引：移除词项统计（立即）
            │    ├→ index_.remove(key, tomb_ord)：标记 ord 为死（立即）
            │    ├→ doc_texts_.erase(ord)：清 LRU 原文（立即）
            │    └→ cache_.invalidate()：失效搜索缓存（立即）
            └→ HNSW：❌ 什么都不做
```

向量节点留在 HNSW 图中，但对应的 ord 在 index 中被标记为死。

### 2.2 为什么不增量删除 HNSW 节点

HNSW 删除节点会导致邻接表悬空边——需要级联修复邻居连接，
复杂度 O(dead_count × M × ef_construction)。全量重建虽然 O(N log N)，
但只在 merge（低频批处理）时执行，且能重排图结构获得更优拓扑。

### 2.3 搜索时：live callback 过滤

```cpp
// search_layer.cpp:222-234
live = [this](std::uint64_t ord) -> bool {
    return index_.is_live(ord);  // 死 ord → false
};
hnsw->search(q, k, ef, &live);   // 死节点不入候选集
```

搜索结果正确，但死节点仍占用图空间和遍历时间。

## 3. Merge 触发条件：两段式决策

### 3.1 第一阶段：Trigger（任一满足就启动整次 merge）

| 条件 | 默认值 | 来源 | 含义 |
|------|--------|------|------|
| `frag_merge_trigger` | 60 (%) | `bitcask.app.src` | 某文件碎片率 ≥ 60% |
| `dead_bytes_merge_trigger` | 512 MB | `bitcask.app.src` | 某文件死字节 ≥ 512MB |
| `deletion_rate_trigger` | 0（禁用）| `PolicyOptions` | 全局删除率 ≥ N% |
| 过期文件 | `expiry_secs` 配置时 | `bitcask.app.src` | 文件全部 entry 过期 |

碎片率 = `(1 - live_keys / total_keys) × 100`，即被覆写/删除的 key 占比。
死字节 = `total_bytes - live_bytes`。

一个 trigger 都没命中 → `needs_merge` 返回 `false`，不 merge。

### 3.2 第二阶段：Per-file 阈值（Trigger 命中后挑文件）

| 条件 | 默认值 | 含义 |
|------|--------|------|
| `frag_threshold` | 40 (%) | 碎片率 ≥ 40% |
| `dead_bytes_threshold` | 128 MB | 死字节 ≥ 128MB |
| `small_file_threshold` | 10 MB | 文件 < 10MB |
| 过期 | `expiry_secs` 配置时 | 文件全部 entry 过期 |

任一满足，该文件入选合并候选列表。

### 3.3 `deletion_rate_trigger`（V4 新增）

专门为索引模式设计。当 `(total_ords - live_docs) / total_ords × 100 ≥ N` 时
触发 merge——即使 data file 的碎片率没到阈值。

```erlang
%% 配置示例：20% 文档被删就触发 merge
bitcask:open(Dir, [read_write, {analyzer, whitespace}, {deletion_rate_trigger, 20}]).
```

如果 trigger 成立但无文件通过 per-file 阈值，所有非活跃文件全部入选
（否则触发信号成立了但没文件可并）。

默认 `0` = 禁用，纯 KV 行为完全不变。

### 3.4 决策流程

```
needs_merge(Ref)
  └→ KeyDir::info() 拿 fstats 快照
  └→ merge_policy::decide(fstats, opts, now, dead_doc_rate)
       1. 任一文件命中 trigger？  ── No ──→ false
       2. 扫描所有文件，挑命中 per-file 阈值的
       3. 返回 {true, {Files, Expired}}
```

### 3.5 代码位置

- 策略纯函数：`cpp/src/merge/merge_policy.cpp` + `cpp/include/bitcask/merge_policy.hpp`
- 调用入口：`Cask::needs_merge()` in `cask.cpp`，从 Index 计算 `dead_doc_rate`
- 默认值：`priv/bitcask.app.src` env 段

## 4. Merge 执行：HNSW 物理清死

### 4.1 rebuild_hnsw()

merge 的 Phase 2 调用 `rebuild_hnsw()`（`search_layer.cpp:76-90`）：

```cpp
void SearchLayer::rebuild_hnsw() {
    auto fresh = std::make_shared<HnswIndex>(old->config());
    for (id = 0 .. old->size()-1) {
        ord = old->node_ord(id);
        if (!index_.is_live(ord)) continue;  // 死节点不插入新图
        fresh->insert(ord, old->node_vec(id));
    }
    hnsw_.store(std::move(fresh));  // 原子换入
}
```

- 新图只含活节点（零死节点）
- 重建期间并发查询走旧图（含死节点，语义同软删）
- 换入后旧图由在途读者 `shared_ptr` 续命（无锁回收）
- 重建后立即落盘 `hnsw.snap`

### 4.2 完整 merge 流程

```
bitcask:merge(Dir)
  └→ Cask::merge(files)
       Phase 1: 合并 data files（写新文件，KeyDir 更新定位）
       Phase 2: rebuild_index() + rebuild_hnsw()（物理清死）
                └→ save_vec_snapshot()（落盘 hnsw.snap）
       Phase 3: compact_index_chunks()（释放全死 chunk）
```

## 5. 对运维的建议

| 场景 | 建议 |
|------|------|
| 大量 delete 后向量搜索变慢 | 调 `bitcask:merge(Dir)`，重建 HNSW |
| 持续写入 + 偶尔删除 | 设 `deletion_rate_trigger` 为 10-20，轮询 `needs_merge` |
| 纯 KV（无向量/搜索） | 默认策略足够，碎片率和死字节驱动 |
| 低延迟要求 | 在低峰期手动 merge，避免影响在线查询 |

## 6. 相关文件索引

| 文件 | 内容 |
|------|------|
| `cpp/src/merge/merge_policy.cpp` | `decide()` — 两段式决策纯函数 |
| `cpp/include/bitcask/merge_policy.hpp` | `PolicyOptions` — 默认值 + 参数定义 |
| `cpp/src/search/search_layer.cpp:429-464` | `on_delete()` — BM25 清理（HNSW 不动） |
| `cpp/src/search/search_layer.cpp:222-234` | search_vector live callback |
| `cpp/src/search/search_layer.cpp:76-90` | `rebuild_hnsw()` — 物理清死 |
| `cpp/src/cask/cask.cpp` | `needs_merge()` + `merge()` 调用链 |
| `src/bitcask.app.src` | 默认阈值（frag_merge_trigger 等） |
| `doc/hnsw-lifecycle-zh.md` | HNSW 图完整生命周期（构建/持久化/恢复） |
