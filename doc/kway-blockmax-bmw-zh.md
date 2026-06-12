# k-way 交集 + 块级元数据 + Block-Max WAND（BM25 V2 检索加速路线）

> 对应代码：`inverted.cpp` 的 `run_must_intersect`（inverted.cpp:900，
> 当前为 pairwise 物化交集）、`intersect.hpp` 的 `intersect_u64`。
> 前置阅读：`doc/inoue-simd-intersection-zh.md`（尤其 §8 设计评审）。
>
> 本文解释三个递进的概念——k-way 交集、posting 块级元数据、
> Block-Max WAND——以及它们为什么应排在 AVX-512 内核之前。
> 状态：**设计路线说明，未实施**。

## 1. 背景与动机

当前 BM25 查询路径是「完整 must 交集 → 全部评分 → 排序取 top-k」。
两个问题：

1. **pairwise 物化交集**（inverted.cpp:900）：k 个 must 词做 k-1 轮
   两两交集，每轮分配中间 vector、完整重读上一轮结果。
2. **完整交集本身就是无用功**：top-k 查询要的是分数最高的 10 篇文档，
   却把全部命中文档都求了出来、评了分。工业引擎
   （Lucene/Elasticsearch）靠 WAND / Block-Max WAND / MaxScore
   在遍历阶段就跳过注定进不了 top-k 的文档，典型只触碰百分之几的
   posting——这是任何交集内核优化都给不出的量级。

`doc/inoue-simd-intersection-zh.md` §8.2.1 还指出：Inoue 块过滤是
**区间驱动**的跳跃（块 [min,max] 区间不相交才能跳），对均匀散布的
真实 doc ID 分布基本失效。本文的块级元数据提供的是**目标值驱动**与
**分数驱动**的跳跃，不依赖值域成簇假设。

## 2. 第一步：`run_must_intersect` k-way 化

### 2.1 现状（pairwise）

```
acc = list1
acc = intersect_u64(acc, list2)   // 物化新 vector，丢掉旧 acc
acc = intersect_u64(acc, list3)   // 再物化一个
...
```

k 个词 k-1 轮；第一轮中间结果可能很大（两个热词的交集），
后续每轮反复搬运它。

### 2.2 k-way（leapfrog）

k 个游标在 k 条列表上同时推进，一遍出结果、零中间物化：

```
candidate = 各游标当前值的最大者
把每个游标 advance 到 ≥ candidate 的位置
    ├─ 所有游标的值都等于 candidate → 命中，输出，candidate 推进
    └─ 某个游标跳过了 candidate → 以它的新值为新 candidate，继续
```

核心原语是 `advance(cursor, target)`——「跳到 ≥ target 的第一个
位置」。这个接口正好接住 §3 的块级元数据：advance 跳多远取决于
元数据的粒度。

改动范围：仅 `run_must_intersect` 局部（inverted.cpp:900），
posting 存储不动。独立收益：消除 k-1 次中间分配与搬运。

## 3. 第二步：posting 块级元数据（每 128 ord 存 max ord + max tf）

给每条 posting list 加一层骨架数组，每 128 个 ord 一个条目：

```
posting:  [ord0 ... ord127][ord128 ... ord255][ord256 ...]
骨架:     {max_ord: ord127, {max_ord: ord255,  {...
           max_tf: 9}        max_tf: 3}
```

两个字段各干一件事。

### 3.1 max_ord → skip 指针（目标值驱动的跳跃）

`advance(cursor, target)` 先在骨架上扫：`max_ord < target` 的块
**整块跳过**，定位到目标块后才进块内精确查找（SIMD 内核在这里上场）。
一跳 128 个元素，比 Inoue 块过滤的 4-16 元素粒度大一个数量级。

**与 Inoue 块过滤的本质区别**：

| | Inoue 块过滤 | skip 指针 |
|---|---|---|
| 跳跃条件 | 两块 [min,max] 区间不相交 | `max_ord < target` |
| 驱动方式 | 区间驱动 | 目标值驱动 |
| 均匀分布下 | 区间永远交叠 → 跳不动 | 照常跳，**与值域分布无关** |
| 典型受益形态 | 值域错开（如按时间分区） | 大小不对称（冷词 ∩ 热词） |

冷词（1K）∩ 热词（100K）：冷词每出一个 target，热词平均要越过
~100 个 ord——骨架一跳 128 个正好命中这个量级。

**诚实的边界**：两个相近大小列表的对称交集，skip 也帮不上
（本来就得几乎全看）。救对称场景的是 §4 的 BMW——靠分数跳，不靠值跳。

### 3.2 max_tf → 块内分数上界（BMW 的入场券）

块内 max_tf 可推出该块任何文档的 BM25 贡献上界
（tf 单调；doc length 用块内最小值或预存量化上界）。
这是 §4 跳过整块的依据。

## 4. 第三步：WAND → Block-Max WAND（BMW）

### 4.1 WAND（Broder et al., CIKM 2003）

top-k 检索维护当前堆门槛 θ（第 k 名的分数）。每个词预存
**全局分数上界**（它对任何文档的最大可能贡献）。遍历时，
若某文档能拿到的上界之和 < θ，该文档不评分、不访问，
游标批量跳过。θ 随堆变满不断抬高，越跳越狠。

**弱点**：全局上界太松。一个词在某篇文档 tf=50，全局上界就被
这一个离群值撑大，整条 100K 列表都显得「有希望」，跳不动。

### 4.2 Block-Max WAND（Ding & Suel, SIGIR 2011）

上界不用全局的，用**当前块 max_tf 算出的局部上界**：

```
查询: "数据库" AND "优化"，θ = 8.5（当前第 10 名分数）
游标走到 ord ≈ 50000 附近：
  "数据库" 所在块 max_tf=2 → 块内上界 3.1
  "优化"   所在块 max_tf=1 → 块内上界 2.8
  3.1 + 2.8 = 5.9 < 8.5
  → 这 128 篇文档无论如何进不了 top-10
  → 两个游标直接跳到块尾，一篇都不评分
```

**这就是对称热词场景的解法**：两个 100K 热词在值域上没有任何跳跃
空间，但在分数上有——绝大多数块的局部上界够不到 θ，整块被跳过。
工业实测 top-k 查询典型只触碰百分之几的 posting。

### 4.3 MaxScore（同思路的替代算法）

按上界把词分为 essential / non-essential 两组：non-essential 列表
不参与游标推进，只在候选文档上做点查。实现比 BMW 简单，
工业上两者都在用（Lucene 8+ 默认 BMW 变体）。选型可后置，
两者依赖的块级元数据相同。

## 5. 实施顺序与依赖关系

```
k-way 化（§2）            → 提供 advance(target) 接口
    ↓
块级元数据（§3）          → 让 advance 跳得动（max_ord）
    ↓                       + 提供分数上界（max_tf）
BMW / MaxScore（§4）      → 按分数整块跳过，top-k 只触碰少量 posting
```

三步每步独立有收益（去物化 / 大粒度 skip / top-k 跳过），
且互为前提，投入不浪费。

**与 AVX-512 内核的优先级关系**（结论同
`doc/inoue-simd-intersection-zh.md` §8.3）：AVX-512 优化的是
「块内精确匹配」这最后一小段；BMW 落地后绝大多数块根本不进入
精确匹配——先做内核就是给一条 BMW 准备绕开的路铺豪华路面。
顺序应为：k-way → 块元数据 → BMW/MaxScore，AVX-512 等部署
微架构确定（含 VP2INTERSECT 评估）后再议。

**与块压缩的协同**（见 inoue 文档 §8.5）：块级元数据的 128-ord
分块与将来 FOR/PFor 块压缩天然同构——一份分块投入同时解决
skip 地基与 u64 flat posting 的带宽问题。

## 6. 参考

- Broder et al.: "Efficient Query Evaluation using a Two-Level
  Retrieval Process", CIKM 2003（WAND）。
- Ding & Suel: "Faster Top-k Document Retrieval Using Block-Max
  Indexes", SIGIR 2011（Block-Max WAND）。
- Turtle & Flood: "Query Evaluation: Strategies and Optimizations",
  IPM 1995（MaxScore）。
- Lucene `WANDScorer` / `MaxScoreBulkScorer`——工业实现参考。
