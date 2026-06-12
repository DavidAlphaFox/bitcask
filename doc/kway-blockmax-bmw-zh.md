# k-way 交集 + 块级元数据 + Block-Max WAND（BM25 V2 检索加速路线）

> 对应代码：`inverted.cpp` 的 `run_must_intersect`（inverted.cpp:900，
> 当前为 pairwise 物化交集）、`intersect.hpp` 的 `intersect_u64`。
> 前置阅读：`doc/inoue-simd-intersection-zh.md`（尤其 §8 设计评审）。
>
> 本文解释三个递进的概念——k-way 交集、posting 块级元数据、
> Block-Max WAND——以及它们为什么应排在 AVX-512 内核之前。
> 状态：**§2(k-way)已落地(TASK.md K1,2026-06-12)**;块级元数据、
> BMW 未实施。
>
> K1 实测修正本文 §2 的预期:在尺寸升序 pairwise + SIMD/galloping
> 内核(经预分配/游标优化)之上,k-way 的去物化**没有可测时间收益**
> (BoolMustHot3@100k:1011 vs 1005μs);k==2 leapfrog 反而慢 10-13%,
> 故分发保留 k==2 SIMD pairwise、k≥3 走 leapfrog。落地价值=
> advance(target) 游标接口先行,块级元数据(§3)直接挂入。

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

## 6. B1 实施设计(2026-06-12 定稿,must-only 合取 BMW)

现状修正:v4 已具备 128-ord 块元数据(`PostingBlock{base_ord, end_ord,
max_tf, start_idx, count}`,FlatPostings 浅拷携带)与 WAND 基建——B1
不新增格式,直接消费现有块。

**适用门**:`should_terms` 与 `must_not_terms` 均空、`must_terms` 非空、
k>0 → 合取 BMW 路径;否则维持原路径(eager fill + 完整交集 + 全量评分)。

**核心决策**:

1. **idf 改基于 df(=列表长)而非 live_df**:live_df 需要 O(n) 全列表
   live 扫描,与 BMW 的亚线性目标矛盾。df 含未 merge 的死 posting,
   与 Lucene docFreq 语义一致(删除近实时近似,merge 后收敛)。
   **无删除时 live_df == df,与原路径分数位级一致**(等价性测试基础)。
   极端删除比下 idf 可为负——上界仍 admissible(ub<θ ⇒ 真实分<θ),
   剪枝正确性不破,记录为良性边角。
2. **live/doc_len 懒取**:按 128-ord 块粒度,首次触达才批量
   fill_is_live/fill_doc_lens(每块一次虚调用 + 一次锁)。未触达的块
   零成本——这是 10× 类收益的来源(原路径 eager 填全列表)。
3. **剪枝**:K1 leapfrog 对齐出候选 v 后,若堆已满:
   Σ_t upper_bound_from(块max_tf, idf_t) ≤ θ → 驱动游标跳到
   min_t(块end_ord)+1(整块跳过,不评分不查 live)。
4. **尾块**(未 seal,无块元数据):上界退化用列表级 max_tf,admissible。
5. **评分公式与原路径逐运算一致**(分数位级不变约定);跨词累加顺序
   为列表长升序(与原路径的词名序不同,k≥3 时浮点结合性可差最后
   1 ulp——测试用 FLOAT_EQ + 集合断言)。

**等价性测试策略**:无删除时,`+a +b` (BMW) vs `+a +b zzz_nonexistent`
(should 含不存在词 → 强制走原路径且分数不受影响)逐 ord/score 对比;
有删除时断言成员集(死文档排除、活文档齐全),不断言排序。

### 6.1 B1 实测结果与关键发现(落地后补записи)

| 基准(7 次中位) | K1 后 | B1 后 | Δ |
|---|---|---|---|
| BoolMustHot/4096(k=2) | 46.9μs | 49.1μs | +4.7%(SIMD pairwise → 懒填充 leapfrog) |
| BoolMustHot/100k | 1560μs | 1431μs | **-8%** |
| BoolMustHot3/100k | 1011μs | **695μs** | **-31%** |
| BoolMustSkewed/100k(新) | — | 1451μs | 剪枝未触发(见下) |

**收益来源全部是懒填充**(未触达块不付 live/doc_len 批量取数),
**块跳跃剪枝在所有被测形态下均未触发**。机制(canary 基准实证):

1. `upper_bound_from` 的 **dl=1 假设带来 ~25%/词的固有松弛**——
   近均匀语料里 θ ≈ 真实最高分 ≈ 上界/1.25,`Σub ≤ θ` 永假;
2. **BM25 长度归一天然压平 tf 钉子**:tf=50 的文档 doc_len 必然 ≥50,
   归一后其分数未必高于普通文档——"高 tf 块撑高 θ 后跳过低 tf 块"
   这个直觉故事在 dl 一致的数据上不成立;
3. 剪枝真正的生效域:**idf 差异大**(冷热词混合,θ 被冷词 idf 主导)
   或**上界更紧**。

**⇒ v5 块元数据的硬需求(取代 §3.2 的 max_tf 方案)**:每块存
**量化的块级最高分**(对块内每个 posting 用真实 tf+dl 算分取 max,
quantize 到 u8/u16),上界零松弛(仅量化误差)。BoolMustSkewed 基准
是该改动的验收标尺。B1 的剪枝骨架无需改动,只换 block_ub 的来源。

### 6.2 v5 落地结果(impacts:max_tf + min_dl,2026-06-12)

实际选型比 6.1 预想的"量化块最高分"更简:**块存 (max_tf, min_dl) 对**
(Lucene impacts 的单对简化)。块最高分依赖 idf/avgdl/params 等查询期
统计,预存会随统计漂移失去 admissibility;(max_tf, min_dl) 与统计
无关,查询期用当前统计算上界,天然 admissible。实现:`Posting` 增
`dl` 字段(索引时 Σtf,**恰落原 4B padding,内存零增量**),封块/
finalize/compact 都能精确重算 min_dl;快照 InvVersion=5(块 +4B),
v4 载入 min_dl=1 回退(等价旧行为)。

**新不变量**(已写入 LiveChecker 文档):查询期 doc_len(ord) 必须
== add_doc 时 Σtf(SearchLayer 同源天然成立)——若查询期 dl 更小,
上界不再 admissible。

| 基准(7 次中位) | B1 后(dl=1 上界) | v5(min_dl 上界) | 累计 vs K1 前 |
|---|---|---|---|
| BoolMustHot/4096 | 49.1μs | **7.63μs** | 44.3 → 7.63,**5.8×** |
| BoolMustHot/100k | 1431μs | **324μs** | 1481 → 324,**4.6×** |
| BoolMustSkewed/100k | 1451μs | **603μs** | -58% |
| BoolMustHot3/100k | 695μs | 674μs | 1011 → 674(基准 checker dl 与 Σtf 不一致,上界留有余隙——良性,admissible 方向) |

剪枝如预期触发:均匀形态 min_dl==实际 dl ⇒ ub==θ ⇒ 堆满后整块跳过。
压缩类改动(TF 量化、FOR)与本次解耦,另行排期(纯体积收益)。

## 7. 参考

- Broder et al.: "Efficient Query Evaluation using a Two-Level
  Retrieval Process", CIKM 2003（WAND）。
- Ding & Suel: "Faster Top-k Document Retrieval Using Block-Max
  Indexes", SIGIR 2011（Block-Max WAND）。
- Turtle & Flood: "Query Evaluation: Strategies and Optimizations",
  IPM 1995（MaxScore）。
- Lucene `WANDScorer` / `MaxScoreBulkScorer`——工业实现参考。
