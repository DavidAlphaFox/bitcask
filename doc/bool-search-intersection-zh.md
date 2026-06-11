# 布尔查询与 posting 交集（bool_search 原理与优化记录）

> 对应代码：`inverted.cpp` 的 `bool_search`、`intersect.hpp/.cpp`、
> `query_parser.cpp`。优化任务见 TASK.md O4 / P2.2。

## 1. 布尔查询语义

布尔查询（S3 阶段引入）支持三种操作符，Erlang 侧查询串形如
`"+hello +world -spam"`，由 `query_parser` 解析为 QueryAST：

| 操作符 | 语义 | 集合含义 |
|---|---|---|
| `+term`（MUST） | 文档**必须**包含该词 | 候选集 = 各 MUST posting 的**交集** |
| `term`（SHOULD） | 包含则加分，不强制 | 只参与评分；MUST 非空时**不扩大**候选集 |
| `-term`（MUST_NOT） | 包含则排除 | 候选集减去其 posting 的**并集** |

倒排索引中每个词对应一个**按文档号（ord）升序、无重复**的 posting
数组（"哪些文档含这个词"）。AND 语义在数学上即：

```
candidates = posting(t1) ∩ posting(t2) ∩ … ∩ posting(tk)
```

`bool_search` 的交集代码就是这个翻译——把 MUST 语义落成有序数组的
集合交运算。

## 2. 完整查询流程

```
"+hello +world -spam"
   → query_parser 解析为 QueryAST（MUST / SHOULD / MUST_NOT 三组词）
   → 各词取 posting 扁平快照（P1），live 批量过滤（P2.1）
   → MUST 逐个求交集                ←—— 本文主题
   → 候选集剔除 MUST_NOT 命中的文档（排序数组 binary_search）
   → 候选集 BM25 评分（SHOULD 词只加分）
   → top-k 小顶堆返回
```

注意 SHOULD 的边界语义：MUST 非空时 SHOULD 不得追加候选——否则
「只含 should、不含 must」的文档会违反 MUST 语义混入结果
（代码中有对应注释与测试）。

## 3. 为什么交集是热点

热词 posting 可达 10⁴~10⁵ 条；两数组逐元素比较是 O(n+m)，多 MUST
词还要连续交多次。它是 bool 路径上除 BM25 评分外最大的计算块
（基准 BoolMustHot/100k：两个 10 万 posting 的 MUST 词）。

## 4. 三层优化（已落地）

### ① 交集顺序：最短优先（O4）

按 posting 数升序处理 MUST：最短 list 先进交集，accumulator 尽早
缩小，后续交集都在小集合上做；交集一旦为空提前退出。交集与顺序
无关，结果集语义不变。

### ② 查询内 u32 安全窄化（P2.2）

ord 是 u64（单调分配、永不复用，理论上可超 2^32）。全局改 u32 有
溢出风险；改为**查询内窄化**：fp.ords 升序 → O(1) 检查每个 MUST 词
的 `ords.back() ≤ 0xFFFFFFFF`（实际几乎恒真）→ 成立则全程在 u32 上
求交（内存流量减半、SIMD lane 数翻倍）；任一超界则回退原 u64 标量
路径，语义零变化。

窄化路径同时去掉了历史遗留的 `sort+unique`——`fp.ords` 本就升序
唯一、live 过滤保序，这两步一直是无效功。

### ③ 三路自适应交集内核（P2.2，`intersect_u32`）

| 输入形态 | 实现 | 理由 |
|---|---|---|
| 大小悬殊（>32x） | galloping（小数组驱动，指数探查+二分） | O(\|小\|·log\|大\|)，SIMD 对悬殊形态无益 |
| 相近大小 + AVX2 | shuffle 块交集：8 lane 全对全比较（`permutevar8x32` 8 个循环旋转）+ 256 项 LUT 压缩存储 | 一次比较 8 个元素 |
| 其余 | 标量双指针归并 | 基线正确实现 |

AVX2 经 `__builtin_cpu_supports("avx2")` **运行时分发**——不改
`-march` 基线（x86-64/SSE2），老机器自动走标量，无部署风险。

块推进正确性：每轮比较 a、b 各 8 元素的块，最大值较小的一侧整块
前进（相等双进）。已匹配的值不会重复发射：单数组内值唯一，且后续
块的元素严格大于已前进块的最大值。

### 前置条件

`intersect_u32` 要求两输入**严格升序无重复**——由 PostingList 不变量
保证（ord 单调分配、add_doc 不重复、live 过滤保序）。

## 5. 验证与收益

- 黑盒对拍：432 组随机（12×12 尺寸组合覆盖 8/16/64 块边界 × 3 档
  重叠密度）对照 `std::set_intersection`；悬殊双向（galloping）；
  全重叠/交错零重叠。见 `inverted_test.cpp` IntersectU32 系列。
- 基准（对齐构建，B1）：BoolMustHot/4096 183us → **148us（-19%）**；
  /100k 5620us → **4370us（-22%）**。

## 6. 术语澄清

「交集/求交」（intersection）指本文的集合运算；项目讨论中偶尔出现的
「正交」（orthogonal）是另一概念——指两个优化互不干扰可叠加（如
「长度差剪枝与 Myers 算法正交」），二者无关。
