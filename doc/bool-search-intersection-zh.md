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

## 7. 备选实现路径（已评审、按需启动）

> 现状（P4.5 后）：u32 窄化快路径（AVX2/galloping/标量三路）+ u64
> `set_intersection` 标量回退，两者共用单一骨架（`run_must_intersect<T>`
> 模板 lambda），u64 回退由 `BoolSearchMustU64Fallback` 测试覆盖（用
> ord>2^32 的大值强制走回退，非 43 亿文档）。以下是评审过但**有意未做**
> 的扩展路径，各自记录触发条件——条件不满足前不实现。

### 7.1 u64 AVX2 内核（成对 permutevar8x32 模拟 64 位变量 shuffle）

**触发条件**：单索引累计写入超 2^32（ord 突破 32 位），u64 回退从
「影子路径」变成热路径时。

AVX2 做 u64 shuffle 交集的障碍只有一个：`_mm256_permutevar8x32_epi32`
是 32 位 lane 的变量索引 shuffle，64 位变量版（`permutexvar_epi64`）
是 AVX-512 才有。**解法：把每个 u64 视为两个相邻 u32 lane（lo,hi），
用成对索引的 permutevar8x32 模拟 64 位 lane 移动**：

- 256-bit 寄存器 = 4 个 u64 = 8 个 u32 lane（成对）；
- 旋转 4 个 u64 lane 一位 ⟺ permutevar8x32 索引 `{2,3,4,5,6,7,0,1}`
  （每对 u32 整体平移），4 个旋转变体即覆盖全对全；
- 相等比较直接用 `_mm256_cmpeq_epi64`（AVX2 原生有），
  `movemask_pd` 取 4-bit 命中掩码；
- 压缩存储同样用成对索引 LUT（16 项 × 8 个 u32 索引）+
  permutevar8x32。

成本评估：4 lane × 4 旋转（对比 u32 路径 8 lane × 8 旋转），内存流量
2 倍。块推进、守卫（cnt+8 越界防护的 u64 版为 cnt+4）与 §4③ 完全同构。

**已原型实证（2026-06，i9-13900H/AVX2），原型收录于
`cpp/bench/intersect_u64_proto_bench.cpp`**（opt-in bench 目标，
`--benchmark_filter=IntersectU64Proto`）：

- 对拍 2354 组全过——覆盖 4/8 块边界尺寸 × 跨 2^32 边界/高位大值的
  值域 × 对抗性「低 32 位相同、高 32 位不同」模式（验证 cmpeq_epi64
  是真 64 位比较）+ 自交全命中；ASan+UBSan 干净。
- 库内基准：2M×2M u64（~62 万交集）SIMD 6.8ms vs 标量归并 25.2ms =
  **~3.5-3.7x**——优于纸面预估（~2x），因为标量归并的瓶颈是数据相关
  分支的预测失败而非带宽，SIMD 全程无分支把这部分整个消掉。
- 防腐烂：bench 文件内置缩减版自检对拍（含对抗性模式），每次运行先
  跑，失败即 `SkipWithError` 显式报红——原型代码烂掉时不会静默输出
  假数字。运行时 `__builtin_cpu_supports` 分发，不动 `-march` 基线。

集成时只需把 P4.5 骨架（run_must_intersect）u64 侧的 lambda 从
set_intersection 换成 intersect_u64，并复刻 u32 侧的三路分发与守卫/
对拍测试（接线步骤详见原型文件头注释）。

### 7.2 AVX-512 后端

**触发条件**：部署目标明确为带 AVX-512 的服务器（Xeon/EPYC）。

u32 16 lane；u64 有原生 `permutexvar_epi64`（§7.1 的模拟不再需要）+
`_mm512_cmpeq_epu64_mask` 直接出 mask + `compressstoreu` 免 LUT——
实现反而比 AVX2 简洁。注意：消费级 Intel（12 代后）无 AVX-512，本机
（i9-13900H）**无法验证**；部分微架构有降频代价，需实测。

### 7.3 NEON 后端（aarch64）

**触发条件**：ARM 成为真实部署目标（Apple Silicon / Graviton /
移动端）——当前 ARM 上交集走纯标量。

128-bit = 4 个 u32 lane（AVX2 一半），shuffle 用 `vqtbl1q_u8` 字节表
查重写内核；mask 提取无 movemask 等价物，用 `vshrn` 窄移位惯用法。
**前置**：必须先有 ARM 验证环境（真机 CI 或 qemu + ASan）——SIMD
边界错误（参见 P3.1 的 AVX2 越界写教训）没有 sanitizer 实测兜底
不可合入。

### 7.4 SSE4.1 中间档

**评审结论：不做**。「有 SSE4.1 但无 AVX2」的机器（2013 年前）在
现实部署面占比可忽略，标量回退已保证正确性。

### 分发扩展点

`intersect_u32`（intersect.cpp）的运行时分发即扩展点：新后端 =
新增一个 `__attribute__((target(...)))` 内核 + 一个
`__builtin_cpu_supports` 分支（ARM 侧改用编译期 `#ifdef __aarch64__`）。
悬殊形态的 galloping 路由对所有后端共用，不随 ISA 变。

另注：BM25 **评分循环**的向量化是另一套机制（编译器自动向量化，受
`-march` 基线限制在 SSE2 宽度）——若要让评分吃上 AVX2，用
`target_clones` 函数多版本而非动 `-march`，见 TASK.md P2 节的 ISA
分发策略。评分是全查询热路径，其收益面大于本文的 bool-only 交集。
