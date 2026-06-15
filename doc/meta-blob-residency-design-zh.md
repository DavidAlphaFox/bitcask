# P12 — meta_blobs_ 内存按需 / 有界 设计

> 状态：2.1.1 **备选**（需 gate）。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；
> meta filter 见 [`api-zh.md`](api-zh.md)（Meta 过滤）。

## 1. 背景

`Index::meta_blobs_`（`index.hpp`，`std::vector<std::vector<std::byte>>`，下标 = ord）
为每个 ord 存一份 meta blob，**全量常驻内存**，供 search filter 求值时锁内拷出
（P1 修复后 `meta_blob` 返回拷贝）。meta 大、文档多的集合，这块常驻内存不小。

## 2. 方案（两条，均需 gate）

- **(a) 有界 LRU**：meta_blobs_ 改成 ord→blob 的有界 LRU（类似 `DocTextLru`）；超额淘汰，
  miss 时从 data file 解码 meta 段回填。
- **(b) 纯按需读盘**：不常驻，filter 求值时按 ord→定位读 data record、解 DocValue 取 meta
  段（复用 `decode_doc_value`）。

## 3. 为何备选：filter 在搜索热路径

filter 求值发生在**搜索结果过滤的热路径**（每个候选 ord 都要查 meta）。按需读盘会把
「锁内拷一份内存 blob」换成「一次 pread + decode」**每候选一次** → 显著拖慢 filter 查询。
所以：
- 只有 **meta 很大 + 内存吃紧 + filter 查询不密集** 时才划算；
- 必须 **gate**（按 meta 总量 / 是否启用 filter / 命中率），默认保持全量常驻。
- 若上 P6 sealed mmap，按需「读」可走 mmap（零拷贝）缓解一部分——但 decode 与每候选一次
  访问的开销仍在。

## 4. 子任务（若推进）
- P12a：测量 meta_blobs_ 常驻内存占比（按集合）；判是否值得。
- P12b：(a) 有界 LRU 或 (b) 按需读盘 + gate（`{meta_resident, full|lru|on_demand}`）。

## 5. 风险
- filter 延迟回退（按需读盘的核心代价）——必须 gate、默认 full。
- 与 P6/P7 协同：按需读可走 mmap；派生（解码后的 meta 结构）可进 P7 compute cache。

## 6. 测试
- 内存占比测量（full vs lru vs on_demand）。
- filter 查询延迟对比（确认 on_demand 的回退幅度，决定 gate 阈值）。
- 正确性：三种模式 filter 结果一致。
