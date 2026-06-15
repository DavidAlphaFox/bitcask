# P8 — HNSW merge rebuild 阈值门控 设计（= P2 for HNSW）

> 状态：2.1.1 承诺项。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；BM25 同范式见
> [`merge-policy-zh.md`](merge-policy-zh.md) 与 P2（TASK.md V7）。

## 1. 背景

merge 末尾**无条件全量重建 HNSW 图**：`cask.cpp:1699` 提交 `IndexTask{RebuildHnsw}`，
worker 执行 `search_->rebuild_hnsw()`（`search_layer.cpp:76`）——遍历所有 live 文档
（line 86 `if (!index_.is_live(ord)) continue;` 跳死）、重插进一张新图。代价
O(n log n) 距离计算，是**向量库 merge 的 CPU 大头**（P2 已把 BM25 那半做廉价）。

## 2. 关键事实：重建是「纯物理压实」，正确性不依赖它

HNSW 查询**已经用 `is_live` 过滤死节点**——search_vector 的 live callback
（`search_layer.cpp:225` `if (!index_.is_live(ord)) return false;`，无 filter 时 232）。
即**死节点不会进结果**，无论图里有没有它。所以 merge 的全量重建**纯粹是物理压实**
（把死节点踢出图、回收内存、缩短遍历），与 P2 发现「rebuild_index 只为清死 posting」
完全同构。

## 3. 方案：按死节点比例门控

- 计算**死节点比例** = (图内节点数 − live 节点数) / 图内节点数。
  - 图内节点数 = HNSW 已插入计数（`count_`）。
  - live 节点数 = `Index::live_docs`（`index.hpp:53`）。
  - 二者差 = 死节点（被 delete / 被新版本覆盖的 ord）。
- 门控：`dead_ratio < 阈值`（默认建议 0.2）→ **跳过** RebuildHnsw（死节点留图、查询
  is_live 兜底）；`≥阈值` → 全量重建（现行行为）。
- **HNSW 无法像 BM25 posting 那样原地 compact**（图连通性）——所以是「跳过 vs 全量」
  二选一，而非增量压实。但多数 merge 死比例不高 → 大量 merge 省掉整张图重建。

## 4. 子任务
- **P8a**：死比例计算（HNSW `count_` vs `Index::live_docs`）；阈值常量/配置。
- **P8b**：merge 路径（`cask.cpp` merge）门控 `RebuildHnsw` 的 submit；快照仍照常落
  （未重建则快照含死节点，load 后 is_live 兜底，下次达阈值再清）。

## 5. 并发 / 边界
- 门控只是「是否 submit RebuildHnsw」的判断，在 merge 线程做；不改 HNSW 并发协议。
- 跳过重建后：图含死节点 → 遍历略增开销 + 内存占用直到下次重建；BCVS 快照也含死节点
  （略大）。均由 is_live 保证正确。
- **死节点跨多次跳过累积** → 图膨胀。兜底：除比例外，可加「绝对死数」或「每 N 次 merge
  强制一次」上限，防长期不重建。

## 6. 风险
- 长期死节点累积（见上，加绝对/周期兜底）。
- 死比例计算口径要准（覆盖更新也算死——同 ord 新版本使旧 ord 死；以 Index live 为准）。

## 7. 测试
- 删大量 + merge：死比例 < 阈值 → 断言**未重建**（图节点数不变 / 计时），搜索结果仍正确
  （is_live 过滤）；死比例 ≥ 阈值 → 重建、死节点清出、节点数降到 live。
- 周期/绝对兜底触发（若实现）。
