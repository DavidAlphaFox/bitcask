# P7 — 派生值 compute cache（建在 mmap 之上）设计

> 状态：2.1.1 **备选**（依赖 P6，按 gate 决策）。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；
> 前置 mmap 见 [`sealed-mmap-read-design-zh.md`](sealed-mmap-read-design-zh.md)。

## 1. 背景：有 mmap 之后，LRU 改定位

P6 mmap 后，raw bytes 已是「指针直读 page cache，零拷贝无 syscall」——**raw 字节这层
不该再加缓存**（缓了是双缓存 + 跟内核抢 RAM，内核管 page cache 通常更好）。

所以 LRU 的位置变成 **compute cache**：只缓**从 raw bytes 派生、且 recompute 有真实
CPU 成本**的结果。省的是 **recompute、不是 I/O**。这正是 LevelDB 的分工——mmap/pread
取字节，**block LRU 缓解压后的块**（Snappy 解压贵）。

**纯 KV value**：DocValue decode 近零成本（变长前缀切段、返回 span）→ **不缓**。
（这也是原 value LRU 方案被否决的原因。）

## 2. 值得缓的派生结果（候选）

| 候选 | 派生成本 | 现状 |
|------|---------|------|
| highlight 的 **NFKC 归一 + `analyze_with_offsets`** | 高：每次高亮都重算（`search_layer.cpp:1069-1070`，即便 DocTextLru 原文命中也重跑分词） | DocTextLru 只缓**原文**；可缓「ord → 分词 offsets」 |
| int8→f32 **dequant 向量**（盘上 int8 + get 要返 f32 时） | 中：逐元素 ×scale | 无缓存 |
| raw KV value | ~0 | 不缓（mmap 足矣） |

## 3. 设计

### 3.1 数据结构
`ShardedLru<LogicalKey, std::shared_ptr<const Derived>>`：
- **按逻辑键缓**（key 或 ord）——内容跨 merge **稳定**（merge 只改文件定位、不改内容），
  缓存条目跨 merge 不失效；miss 时回 mmap 取原始字节再派生。
  （对比：按文件 offset 缓会随 merge 重定位而失效——所以必须按逻辑键。）
- **存 owned `shared_ptr<const Derived>`，绝不存指向 mmap 的 span**——与 munmap/merge
  生命周期**彻底解耦、无 UAF**（这条最关键：缓 mmap 指针会在 munmap 时悬垂）。
- **byte budget**（非条数；派生值变长）+ 分片 `shared_mutex`（命中共享、改写独占）。

### 3.2 读路径分层
```
get / highlight
  → LRU(派生) 命中? ─ 是 → 返回 owned 派生值（shared_ptr，零拷贝安全）
                    └ 否 → mmap 取 raw bytes（P6，无 syscall）
                           → decode / dequant / 分词   ← 派生
                           → LRU.put(owned) → 返回
```
mmap = L1（字节层，page-cache 背书）；P7 = L2（计算层，缓派生）。**互补不竞争**。

### 3.3 失效
- `put` / `delete`：按 key 失效（单写者，与 keydir 一起维护）。
- **merge：不失效**（内容不变、按逻辑键缓）。
- 过期：派生值带 tstamp 或命中后查 keydir 过期判定。

## 4. 与现有 DocTextLru / SearchCache 的关系
- **不**把三者合并成单一实例（用途/键/填充时机不同，naive 合并两头将就，见对话分析）。
- 可选：抽一个泛型 LRU 基件让三者**复用实现**（非复用实例）——但这是纯代码去重，
  与 P7 功能正交，按需做。
- DocTextLru 的升级路径：从「缓原文」升级为「缓分词 offsets」即落进 P7b 候选①。

## 5. gate（先做，再决定是否实现 P7b）
仅当 **derive 成本 ≫ mmap 访问** 才值得：量化「LRU 命中(返回派生) vs mmap+现场 derive」
的延迟差，显著才上。
- 纯 KV：derive≈0 → 不做。
- highlight 分词 / dequant 向量：derive 不小 → 候选。

## 6. 子任务
- **P7a**：compute cache 框架（逻辑键、owned shared_ptr、byte budget、shared_mutex、
  put/delete 失效、merge 不失效）。
- **P7b**：首批派生目标——① highlight 分词 offsets（DocTextLru 升级）；② dequant 向量。
- **P7-gate**：量化 derive vs mmap，显著才推进 P7b。

## 7. 风险
- 内存预算与 OS page cache 共用 RAM——派生缓存挤占 page cache 需权衡（byte budget 控）。
- 失效正确性（put/delete 漏失效 → 读到旧派生）——单写者下可控。
- 生命周期：只存 owned 派生值 → 与 mmap 解耦，无 UAF（设计已规避）。

## 8. 为何备选
依赖 P6 先落地；收益取决于 derive 成本（需 gate 量化）；raw value 永不缓。优先级低于
P5/P6（承诺项）。
