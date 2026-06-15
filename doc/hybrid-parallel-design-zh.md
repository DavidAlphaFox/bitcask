# P10 — search_hybrid 两路并行 设计

> 状态：2.1.1 承诺项。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；RRF/混合检索见
> [`vector-search-extension-zh.md`](vector-search-extension-zh.md)。

## 1. 背景

`SearchLayer::search_hybrid`（`search_layer.cpp:249`）现**串行**跑两路：
`search_text`（263）→ `search_vector`（270）→ 再 RRF 融合（275-302）。两路**相互独立**
（各自查倒排 / HNSW，互不依赖），串行 = 延迟相加。

## 2. 方案：两路并行 + join 后 RRF

- 两路丢线程并发执行（`std::async` / 一个只读用线程池），各自产出 ranked 结果，
  **join 后再 RRF**。hybrid 延迟 ≈ `max(text, vec)` 而非 `text + vec`，近**减半**。
- 单路退化（一路 query 空）维持现状（只跑非空那路），不并行。

## 3. 并发安全（关键：现有读路径已是并发安全的）

两路并发读的共享结构均已读安全：
- `fields_` / `InvertedIndex`：`fields_mu_` shared_lock + 内部分片锁 + tbb 桶锁 + CoW。
- `index_`（Index）：`shared_mutex`。
- `HnswIndex`：`atomic<shared_ptr>` 快照 + per-node 自旋；**`t_visited` 是 thread_local**
  → 两路在**不同线程**各持自己的 visited 表，天然不冲突。
- `SearchCache`（`cache_`）：`shared_mutex`（get/put 都安全）。
- `filter` const。

即「同一次 search 用两个线程」与「两个并发 search」对这些结构是同一种并发——**已支持**。
唯一要确认：两路不写同一 per-search 可变局部（各自局部 vector，天然隔离）。

## 4. 子任务
- **P10a**：两路并发执行（线程池 / async）+ join；RRF 在 join 后。
- **P10b**：线程来源——复用一个只读线程池（非 IndexPool，那是单写者）；小查询可设阈值
  跳过并行（线程开销 > 收益时退回串行）。

## 5. 边界 / 风险
- **线程开销 vs 收益**：k 很小 / 单路极快时，起线程不划算 → 阈值或对极小 k 退串行。
- 线程池大小：避免与其它读/写线程争用；只读池规模可配。
- 异常传播：一路出错，另一路结果如何处置——按现行单路错误语义（两路都空才错）扩展。

## 6. 测试
- **正确性**：并行结果 == 串行结果（同 RRF 序，含平局 ord 序）——锁死现有测试。
- 延迟：双路非平凡时并行 < 串行（基准）。
- 单路退化仍走单路、不起第二线程。
- 并发压力：多个并发 hybrid（每个内部又两路）下无竞态（TSan）。
