# Inoue 块过滤 + SIMD 精确匹配（交集内核设计方案）

> 对应代码：`intersect.cpp` 的 `intersect_u32`/`intersect_u64`、
> `inverted.cpp` 的 `run_must_intersect`。
> 前置阅读：`doc/bool-search-intersection-zh.md`。

> **状态（2026-06-12 决策，见 §8.5）**：ord 恒为 u64，**u32 收窄路径已整体
> 移除**——commit 08fbc92 起 `bool_search` 统一走 `intersect_u64`，
> `narrow_ok` 门与 `intersect_u32` 内核已从代码中删除。本文中 u32 相关内容
> （§2.3 / §2.5 u32 内核、§2.7 u32 分发、§4.3 u32 触发条件、§5.3 的
> `narrow_ok` 代码段）**保留作历史参考，不再是现行设计**。

## 1. 设计动机

### 1.1 当前方案（Schlegel/Lemire 旋转法）的局限

当前 `intersect_u32` 的 AVX2 路径使用旋转法实现 8-lane 全对全比较：

- 每个块固定执行 7 次 `permutevar8x32` 旋转 + 8 次 `cmpeq` + 7 次 OR + LUT 压缩；
- **不重叠的块也照跑完全套 SIMD**——浪费在非匹配区域上的指令不可忽略；
- u64 扩展依赖「成对 u32 索引模拟 64 位 lane 移动」（见
  `doc/bool-search-intersection-zh.md` §7.1），引入 PairLut（512B）+
  `permutevar8x32` 配对索引，代码复杂且难推理。

### 1.2 Inoue 方法的核心思想

Inoue et al.（VLDB 2015, "Faster Set Intersection with SIMD Instructions
by Reducing Branch Mispredictions"）观察到：排序数组交集的瓶颈不是
比较本身，而是 `if (a[i] < b[j])` 三路分支的**预测失败**。

解法：将交集分为两个阶段——

1. **块过滤**（O(1)/块）：用两个标量比较判断两个块是否可能重叠；
   不重叠的块直接跳过，零元素比较。
2. **精确匹配**（仅重叠块）：在确认重叠的块内做交集。

对排序数组，块 max/min 就是首尾元素，**不需要 SIMD 归约**：
```cpp
if (a[i + BLOCK - 1] < b[j]) { i += BLOCK; continue; }  // a 整块 < b
if (b[j + BLOCK - 1] < a[i]) { j += BLOCK; continue; }  // b 整块 < a
// 否则：块重叠 → 精确匹配
```

**阶段 1 与元素大小（u32/u64）和 ISA（AVX2/AVX-512/NEON）完全无关。**

### 1.3 组合优势

将 Inoue 块过滤与 SIMD 精确匹配组合后：

| 问题 | 旋转法 | Inoue + SIMD |
|---|---|---|
| 非重叠块 | 照跑 SIMD（浪费） | **跳过，0 条 SIMD 指令** |
| u64 旋转 | `permutevar8x32` + paired u32（模拟） | **`permute4x64_epi64` + 立即数（原生 u64）** |
| u64 压缩 | PairLut 16 项 + `permutevar8x32`（模拟） | **`_mm256_extract_epi64` 条件提取（零 LUT）** |
| u32 AVX-512 | 未实现 | **`compressstoreu` 一条指令（零 LUT）** |
| 不对称查询 | galloping 处理 | 块过滤 + 精确匹配，更少分支预测失败 |

## 2. 架构设计

### 2.1 总体流程

```
输入：两个升序无重复的数组 a[], b[]
    │
    ├─ 悬殊形态（>32x）→ galloping（与现有逻辑共用，不随 ISA 变）
    │
    └─ 相近大小 → Inoue + SIMD 交集
         │
         ├─ 阶段 1：块过滤（标量 O(1)/块，与元素大小无关）
         │     a_max < b_min → 跳过 a 块
         │     b_max < a_min → 跳过 b 块
         │     否则 → 进入阶段 2
         │
         ├─ 阶段 2：精确匹配（按 ISA + 元素大小分派）
         │     u32 + AVX2   → 旋转法或广播法
         │     u32 + AVX-512→ 16-lane 旋转 + compressstoreu
         │     u64 + AVX2   → 原生 permute4x64 + extract
         │     u64 + AVX-512→ 原生 permutexvar + compressstoreu
         │     无 SIMD      → 标量双指针归并
         │
         └─ 尾部（不足一块）→ 标量归并
```

### 2.2 通用骨架

```cpp
// 通用 Inoue 块过滤骨架，T ∈ {uint32_t, uint64_t}
template <typename T, std::size_t BLOCK, typename ExactMatch>
void intersect_inoue(const T* a, std::size_t na,
                     const T* b, std::size_t nb,
                     std::vector<T>& out,
                     ExactMatch&& exact_match) {
    std::size_t i = 0, j = 0;

    while (i + BLOCK <= na && j + BLOCK <= nb) {
        // 阶段 1：块过滤（标量，O(1)，适用于任何元素大小）
        const T a_max = a[i + BLOCK - 1];
        const T b_max = b[j + BLOCK - 1];

        if (a_max < b[j])       { i += BLOCK; continue; }
        if (b_max < a[i])       { j += BLOCK; continue; }

        // 阶段 2：块重叠 → 精确匹配（委托给 ISA 最优内核）
        exact_match(a + i, b + j, out);

        // 块推进（与现有旋转法相同语义）
        if (a_max <= b_max) i += BLOCK;
        if (b_max <= a_max) j += BLOCK;
    }

    // 尾部（不足一块）标量归并
    scalar_intersect(a + i, na - i, b + j, nb - j, out);
}
```

**前置条件**（同现有 `intersect_u32`）：两输入严格升序、无重复——由
`PostingList` 不变量保证。

### 2.3 u32 AVX2 精确匹配内核

```cpp
__attribute__((target("avx2")))
void exact_match_u32_avx2(const std::uint32_t* a, const std::uint32_t* b,
                           std::vector<std::uint32_t>& out) {
    // 加载 8 个 u32
    const __m256i va = _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(a));
    const __m256i vb = _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(b));

    // 8-lane 全对全比较（复用现有旋转逻辑）
    __m256i cmp = _mm256_cmpeq_epi32(va, vb);
    for (int r = 1; r < 8; ++r) {
        const __m256i ridx = _mm256_load_si256(
            reinterpret_cast<const __m256i*>(kRot[r]));
        const __m256i vbr = _mm256_permutevar8x32_epi32(vb, ridx);
        cmp = _mm256_or_si256(cmp, _mm256_cmpeq_epi32(va, vbr));
    }
    const unsigned mask = static_cast<unsigned>(
        _mm256_movemask_ps(_mm256_castsi256_ps(cmp)));

    // LUT 压缩存储（复用现有 CompressLut）
    if (mask == 0) return;
    const __m256i perm = _mm256_load_si256(
        reinterpret_cast<const __m256i*>(lut.idx[mask].data()));
    const __m256i packed = _mm256_permutevar8x32_epi32(va, perm);
    // 写出命中元素（守卫逻辑同现有 intersect_avx2）
    // ...
}
```

**说明**：u32 AVX2 精确匹配复用现有旋转+LUT 逻辑，代码与当前 `intersect_avx2`
的内核循环体完全一致。区别仅在于它只在「重叠块」上执行，而非每个块都执行。

### 2.4 u64 AVX2 精确匹配内核（原生 u64 操作）

```cpp
__attribute__((target("avx2")))
void exact_match_u64_avx2(const std::uint64_t* a, const std::uint64_t* b,
                           std::vector<std::uint64_t>& out) {
    const __m256i va = _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(a));
    const __m256i vb = _mm256_loadu_si256(reinterpret_cast<const __m256i_u*>(b));

    // 旋转：原生 u64 lane 置换（立即数，非变量索引）
    //   4 个旋转变体覆盖 4×4 = 16 对全对全比较
    __m256i cmp = _mm256_or_si256(
        _mm256_or_si256(
            _mm256_cmpeq_epi64(va, vb),
            _mm256_cmpeq_epi64(va,
                _mm256_permute4x64_epi64(vb, 0x1B))   // rot 1: _MM_SHUFFLE(0,3,2,1)
        ),
        _mm256_or_si256(
            _mm256_cmpeq_epi64(va,
                _mm256_permute4x64_epi64(vb, 0x4E)),   // rot 2: _MM_SHUFFLE(1,0,3,2)
            _mm256_cmpeq_epi64(va,
                _mm256_permute4x64_epi64(vb, 0x93))    // rot 3: _MM_SHUFFLE(2,1,0,3)
        )
    );
    const unsigned mask = static_cast<unsigned>(
        _mm256_movemask_pd(_mm256_castsi256_pd(cmp)));  // 4-bit 命中掩码

    // 压缩：标量条件提取（零 LUT）
    if (mask & 1) out.push_back(a[0]);
    if (mask & 2) out.push_back(a[1]);
    if (mask & 4) out.push_back(a[2]);
    if (mask & 8) out.push_back(a[3]);
}
```

**关键设计选择**：

| 操作 | 选用的指令 | 理由 |
|---|---|---|
| 旋转 | `_mm256_permute4x64_epi64`（`vpermq`） | 原生 u64 lane 置换，立即数索引。旋转 pattern 是编译期常量，不需要变量索引 |
| 比较 | `_mm256_cmpeq_epi64` | AVX2 原生真 64 位比较 |
| 掩码提取 | `_mm256_movemask_pd` | 4-bit 掩码（4 个 u64 lane） |
| 压缩存储 | `_mm256_extract_epi64` × 4 | 4 lane 条件提取，比 LUT + `permutevar8x32` 简单且无需成对 u32 模拟 |

> ⚠️ **"零 LUT"是用分支换的（见 §8.2.3）**：4 个 `if (mask & k) push_back`
> 是最内层循环里 4 个数据相关分支 + capacity 检查。PairLut（512B，常驻 L1）
> 的 lookup + permute + store 是无分支的。命中率中等（mask 难预测）时
> 条件提取可能反而更慢——"零 LUT 更优"需基准实测支撑，不能仅凭代码简洁判定。

**与 §7.1 原型（paired u32 `permutevar8x32`）的对比**：

| 维度 | §7.1 paired u32 原型 | 本方案（原生 u64） |
|---|---|---|
| 旋转实现 | `permutevar8x32` + paired 索引表 `kRot[4][8]` | `permute4x64` + 立即数 `0x1B/0x4E/0x93` |
| 压缩实现 | PairLut（16 项 × 8 u32 = 512B）+ `permutevar8x32` | 4 × `_mm256_extract_epi64`（零 LUT） |
| 旋转指令条数 | 3 × load + 3 × `permutevar8x32`（各 8 u32 操作） | 3 × `permute4x64`（各 4 u64 操作） |
| 代码复杂度 | 高（paired 索引 + u32/u64 混合操作） | 低（全程 u64 语义，无模拟层） |
| 非重叠块开销 | 全量 SIMD | **跳过（0 条 SIMD 指令）** |

### 2.5 u32 AVX-512 精确匹配内核

```cpp
__attribute__((target("avx512f,avx512bw")))
void exact_match_u32_avx512(const std::uint32_t* a, const std::uint32_t* b,
                              std::vector<std::uint32_t>& out) {
    const __m512i va = _mm512_loadu_si512(a);
    const __m512i vb = _mm512_loadu_si512(b);

    // 16-lane 全对全（16 个旋转）
    __mmask16 cmp = _mm512_cmpeq_epi32_mask(va, vb);
    for (int r = 1; r < 16; ++r) {
        const __m512i vbr = _mm512_permutexvar_epi32(kRot512[r], vb);
        cmp |= _mm512_cmpeq_epi32_mask(va, vbr);
    }

    // compressstoreu 一条指令搞定，零 LUT
    if (cmp == 0) return;
    const std::size_t cnt = static_cast<std::size_t>(std::popcount(cmp));
    const std::size_t old = out.size();
    out.resize(old + cnt);
    _mm512_mask_compressstoreu_epi32(out.data() + old, cmp, va);
}
```

**AVX-512 优势**：
- 16 lane（AVX2 的 2 倍）；
- `permutexvar_epi64` 原生变量索引 u64 置换——§7.1 的模拟不再需要；
- `compressstoreu` 直接按 mask 压缩存储——零 LUT。

**注意**：消费级 Intel 12 代后无 AVX-512，本机（i9-13900H）无法验证。
部署目标需明确为 Xeon/EPYC 服务器。部分微架构有降频代价，需实测。

**必须评估的对照项——AVX512-VP2INTERSECT**：`vp2intersectd`/`vp2intersectq`
一条指令完成两个向量的全对全相等比较（输出双侧 mask），正是上面 16 次
旋转循环要做的事。Intel 端 Tiger Lake 引入后被砍且为微码慢速实现，但
**AMD Zen 5 提供硬件快速实现**。若部署目标含 Zen 5（EPYC Turin），
VP2INTERSECT 内核应优先于 16-旋转方案；写 AVX-512 内核前先确认目标微架构。

### 2.6 u64 AVX-512 精确匹配内核

```cpp
__attribute__((target("avx512f")))
void exact_match_u64_avx512(const std::uint64_t* a, const std::uint64_t* b,
                              std::vector<std::uint64_t>& out) {
    const __m512i va = _mm512_loadu_si512(a);
    const __m512i vb = _mm512_loadu_si512(b);

    // 8-lane 全对全（8 个旋转）
    __mmask8 cmp = _mm512_cmpeq_epi64_mask(va, vb);
    for (int r = 1; r < 8; ++r) {
        const __m512i vbr = _mm512_permutexvar_epi64(kRot512_64[r], vb);
        cmp |= _mm512_cmpeq_epi64_mask(va, vbr);
    }

    if (cmp == 0) return;
    const std::size_t cnt = static_cast<std::size_t>(std::popcount(cmp));
    const std::size_t old = out.size();
    out.resize(old + cnt);
    _mm512_mask_compressstoreu_epi64(out.data() + old, cmp, va);
}
```

### 2.7 分发策略

```
intersect_u32(a, b, out)
    │
    ├─ |a|/|b| > 32x → intersect_galloping（共用，不随 ISA 变）
    │
    ├─ AVX-512 可用 → intersect_inoue<u32, 16>(..., exact_match_u32_avx512)
    │
    ├─ AVX2 可用 → intersect_inoue<u32, 8>(..., exact_match_u32_avx2)
    │
    └─ 否则 → intersect_scalar

intersect_u64(a, b, out)   ← 替代当前 set_intersection 标量回退
    │
    ├─ |a|/|b| > 32x → intersect_galloping_u64（共用 galloping 逻辑，改类型）
    │
    ├─ AVX-512 可用 → intersect_inoue<u64, 8>(..., exact_match_u64_avx512)
    │
    ├─ AVX2 可用 → intersect_inoue<u64, 4>(..., exact_match_u64_avx2)
    │
    └─ 否则 → intersect_scalar_u64
```

运行时分发通过 `__builtin_cpu_supports` 检测（与现有逻辑一致，
不改 `-march` 基线 x86-64/SSE2）。新后端 = 新增一个
`__attribute__((target(...)))` 内核 + 一个 `__builtin_cpu_supports` 分支。

## 3. 性能分析

### 3.1 各场景预测

下表以当前实测数据为基准（i9-13900H），`BLOCK` = SIMD lane 数。

| 场景 | 当前旋转法 | Inoue + SIMD | 说明 |
|---|---|---|---|
| 两热词 100K×100K（100% 重叠） | 4370μs | ~4400μs | 几乎无块可跳，退化为纯 SIMD 精确匹配，持平 |
| 两热词 100K×100K（10% 重叠） | ~4370μs | ~3500μs | 90% 块被阶段 1 跳过，SIMD 只处理 10% 重叠块 |
| 10K 冷词 × 100K 热词 | galloping | 相当或略优 | 两者都利用大小不对称 |
| u64 交集（任何形态） | 标量 `set_intersection` | **~3-4x** | 原生 u64 SIMD + 块过滤 |
| u64 交集（不对称） | 标量 | **>5x** | 块过滤跳过大部分块 + SIMD 精确匹配 |

> ⚠️ **关键前提（见 §8.2.1）**：上表"10% 重叠 → 90% 块被跳过"假设交集元素
> **在值域上成簇**。块过滤跳过的条件是两个块的 [min, max] **区间不相交**，
> 与元素重叠率无关。若 doc ID 均匀散布全值域（真实 posting list 的常态），
> 相近大小的两列表即使 0% 元素重叠，块区间也几乎必然互相覆盖——阶段 1
> 一个块都跳不掉，每块反而多付 2 次标量比较。该行预测必须用
> 均匀分布 + 成簇分布两种数据形态实测后才可作为决策依据。

### 3.2 旋转法 vs Inoue + SIMD 的指令开销对比

**以 u64 AVX2 为例，单块处理**：

| 操作 | 旋转法（§7.1 paired u32 原型） | Inoue + SIMD |
|---|---|---|
| 非重叠块 | 3×load ridx + 3×permutevar8x32 + 4×cmpeq + 3×or + 1×movemask + LUT lookup + permutevar8x32 + storeu | **2 条标量比较 → continue** |
| 重叠块 | 同上 | 3×permute4x64 + 4×cmpeq + 3×or + 1×movemask + 4×extract = 同阶，但指令更少且全是原生 u64 |

### 3.3 为什么块过滤对 u64 特别有效

u64 只有 4 lane（u32 的一半），SIMD 加速比本就有限。Inoue 的阶段 1 把
大量非重叠块用 O(1) 标量比较排除，只有少量重叠块进入 SIMD 精确匹配。
**即使精确匹配退化为标量归并，总工作量仍远小于全量 SIMD 旋转法**。

## 4. 与现有代码的集成

### 4.1 改动范围

| 文件 | 改动 |
|---|---|
| `intersect.hpp` | 新增 `intersect_u64()` 接口声明 |
| `intersect.cpp` | 新增 `intersect_inoue` 模板 + 各 ISA 精确匹配内核 + `intersect_u64` 三路分发 |
| `inverted.cpp` | `run_must_intersect` 的 u64 lambda 从 `set_intersection` 改调 `intersect_u64` |

**不需要改的文件**：
- `inverted.hpp`（PostingList / FlatPostings 不变）
- `index.hpp` / `index.cpp`（ord 分配不变）
- `merger`（ord 保留不变）
- `search_layer`（查询入口不变）

### 4.2 测试策略

1. **对拍测试**：复刻 `IntersectU32` 系列（432 组随机 × 12×12 尺寸组合 × 3 档
   重叠密度），新增 `IntersectU64` 系列对照 `std::set_intersection`。
2. **对抗性测试**：
   - 跨 2³² 边界的 u64 值域（同 §7.1 原型的 `base = 5'000'000'000ULL`）；
   - 「低 32 位相同、高 32 位不同」模式（验证 `cmpeq_epi64` 是真 64 位比较）；
   - 自交全命中（覆盖「双进」块推进路径）。
3. **BoolSearchMustU64Fallback**：现有测试已覆盖 ord>2³² 强制走 u64 回退，
   改调 `intersect_u64` 后仍应通过。
4. **Sanitizer**：ASan + UBSan（P3.1 越界写教训要求所有 SIMD 内核必须有
   sanitizer 实测兜底）。
5. **基准对比**：与当前旋转法在 BoolMustHot/4096 和 /100k 上对齐测量。
6. **分布形态矩阵（见 §8.2.1）**：基准必须覆盖
   {均匀散布, 成簇, 区段错开} × {0%, 10%, 100% 重叠} × {对称, 4x, 32x}。
   其中"均匀散布 + 相近大小"是真实 posting list 的常态，也是块过滤
   预期收益为零甚至为负的形态——该格子的结果决定 **u64 内核是否保留
   块过滤阶段**（跳过率 ≈ 0 时块过滤是每块 2 次标量比较的小额纯开销，
   保留或删除以实测定）。只测成簇形态会系统性高估收益。
7. **块跳过率计数器**：基准内核加编译期开关统计「阶段 1 跳过块数 / 总块数」，
   把"块过滤是否生效"从推测变成可观测指标。

### 4.3 触发条件

**u32 路径替换** —— **已作废（2026-06-12，见 §8.5）**：u32 收窄路径
整体移除，不存在"替换 u32 旋转法"的问题。原触发条件与「均匀散布格子
无回归」前置随之失效；分布矩阵实验（§4.2 第 6 条）降级为 u64 内核
调优实验（块过滤保留与否）。

**u64 路径** —— **已是唯一生产路径（08fbc92 落地）**：原触发条件
「累计写入超 2³² 使 u64 从影子路径变热路径」作废——u32 收窄移除后
`intersect_u64` 对所有查询生效。三路分发（galloping / AVX2 / 标量）
+ 对拍测试已就绪。

**AVX-512 内核**：
- 触发条件：部署目标明确为带 AVX-512 的服务器（同 §7.2）。
- 前置：AVX-512 验证环境。

## 5. Roaring 混合方案分析

### 5.1 设计概述

Roaring bitmap 按密度自适应选择存储方式（Lucene 5+ / Elasticsearch 标准）：

```
每 65536 元素一个 chunk：
  ≤ 4096 个元素 → ArrayContainer（排序 u16[] 数组，2B/元素）
  > 4096 个元素 → BitmapContainer（65536-bit bitset，8KB 固定）
  连续值        → RunContainer（(start, length) 对，RLE 编码）

交集按类型分派：
  Array ∩ Array   → galloping / merge
  Array ∩ Bitmap  → 遍历 array 查 bitmap（O(|array|)）
  Bitmap ∩ Bitmap → 位运算 AND（一条 SIMD 指令 / 256 bit）
```

### 5.2 u64 支持分析

CRoaring 提供两个 API：

| API | key 宽度 | 内部结构 | 交集性能 |
|---|---|---|---|
| `roaring_bitmap_t` | **u32** | 65536 × chunk（每 chunk 65536 值） | 基准 |
| `roaring64_bitmap_t` | **u64** | ART（高 48 bit 自适应基数树）+ 65536 × chunk（低 16 bit） | 约为 u32 版的 **50%** |

**Roaring64 的内部结构**：

```
u64 key = 0x0000_FFFF_0000_0042
              ├─────┤ ├──────────┤
              高48bit    低16bit
                │          │
                ▼          ▼
         ART 节点查找    标准 Roaring chunk
         （自适应基数    （ArrayContainer /
          基数树）        BitmapContainer /
                         RunContainer）

roaring64_bitmap_and(r1, r2):
    遍历两棵 ART 的共同前缀
        → 高 48 bit 相同的节点
            → 低 16 bit 对应的 Roaring chunk 做 AND
```

**Roaring64 的问题**：ART 遍历 + 间接寻址比 u32 Roaring 的直接数组索引慢。
CRoaring 自身基准显示 roaring64 大约为 roaring32 性能的 **50%**。

### 5.3 结论：u32 Roaring + Inoue u64 回退

> ⚠️ **历史参考**：本节写于 u32 收窄路径仍存在时。2026-06-12 决策后
> （§8.5）`narrow_ok` 已删除、u64 为唯一路径，下述 if/else 分发不再存在。
> 本节仍有效的结论只剩一条：**如引入 Roaring，用 u32 容器需先做 ord
> 分段重映射，且不用 Roaring64**（ART 开销使其不如原生 u64 SIMD）。

**Roaring 混合设计不需要 Roaring64。** 推荐组合：

```
run_must_intersect 骨架中的分发：

  if (narrow_ok) {
      // u32 热路径（几乎恒真）
      // 方案 A（渐进）：Inoue + AVX2（§2 的设计）
      // 方案 B（远期）：u32 Roaring AND
      intersect_u32(a, b, out);
  } else {
      // u64 回退（影子路径，需要 >43 亿写入才触发）
      // → Inoue + 原生 u64 SIMD（§2.4 的设计）
      intersect_u64(a, b, out);
  }
```

**理由**：

1. **u32 窄化已覆盖 99.99%+ 的场景**——现有 `narrow_ok` 门（inverted.cpp:904-910）
   检查 `fp.ords.back() ≤ 0xFFFFFFFF`，需要累计写入超 43 亿条才失败。
2. **u32 Roaring 比 Roaring64 快约 2 倍**——对同一查询，u32 路径始终更快。
3. **u64 回退是影子路径**——用 Inoue + 原生 u64 SIMD（§2.4）比 Roaring64 更合适：
   - 不引入外部依赖（Roaring64 只在这一条路径上用，ROI 不够）
   - 原生 `permute4x64` + 块过滤比 ART 遍历 + Roaring chunk AND 快
   - 代码改动更小（只改 `intersect.cpp`，不需要改造 PostingList）

### 5.4 Roaring 引入的额外问题

即使只引入 u32 Roaring，也有以下工程成本：

| 问题 | 说明 |
|---|---|
| **tf/positions 丢失** | Roaring bitmap 只存 doc ID，不存 tf。需要混合存储：Roaring 存 ords + 并行数组存 tfs/positions。PostingList 内部表示需要完全重写 |
| **snapshot_flat 重写** | 当前拷贝 `vector<u64> ords + vector<u32> tfs`。Roaring 版需要拷贝 Roaring 容器或共享引用 |
| **save/load 格式变更** | 当前 VByte gap 编码（inverted.cpp:1272-1289）。需改成 Roaring 序列化格式（或维护两套） |
| **外部依赖** | CRoaring 是 header-only 或静态库，需引入构建系统 |
| **6 个模块受影响** | `PostingList`、`FlatPostings`、`intersect_u32`、`snapshot_flat`、`save/load`、`compact` 全要改 |

### 5.5 触发条件

**引入 u32 Roaring 替代排序数组**：
- 触发条件：存在高频 filter 查询（如 `status:active AND category:tech`），
  posting list 密度稳定超过 6.25%（4096/65536），且 Roaring AND 的加速可测量。
- 前置：PostingList 内部表示从 `vector<Posting>` 改为 Roaring + tfs[] 并行数组。

**不建议引入 Roaring64**：
- u32 窄化已覆盖几乎所有场景；
- Roaring64 的 ART 开销使其不如 Inoue + 原生 u64 SIMD；
- 如需处理 u64，使用 §2.4 的 Inoue + `permute4x64` 方案。

## 6. 与其他方案的对比

| 维度 | Schlegel/Lemire 旋转法（当前） | Inoue + SIMD（§2） | Galloping Only | Roaring u32 + Inoue u64（§5） |
|---|---|---|---|---|
| 代码复杂度 | 中（8KB LUT + 旋转 + 压缩） | **中低**（块过滤 + 精确匹配按需分派） | **低**（删 SIMD） | 高（PostList 重写 + CRoaring） |
| u64 支持 | paired u32 模拟 | **原生 u64 操作** | 标量 | Inoue 原生 u64（不用 Roaring64） |
| 非重叠块 | 全量 SIMD（浪费） | **跳过（O(1)）** | galloping 跳过 | Roaring AND / Inoue 跳过 |
| 对称热词 | ★★★★★（全量 SIMD） | ★★★★（退化为 SIMD） | ★★★（纯标量 -22%） | ★★★★ |
| 不对称查询 | ★★★（galloping） | ★★★★★（块过滤 + SIMD） | ★★★★（galloping） | ★★★★★ |
| 高频 filter 查询 | ★★★ | ★★★★ | ★★★ | ★★★★★（Bitmap AND 极快） |
| 跨平台 | x86-only | **通用骨架 + ISA 按需分派** | ★★★★★（纯标量） | 依赖 CRoaring |
| 依赖 | 无 | 无 | 无 | CRoaring |
| 改动范围 | 已实现 | 1-2 文件 | 删代码 | 6 文件（Roaring）+ 1-2 文件（Inoue u64） |

## 7. 术语与参考

- **块过滤 / Block filtering**：Inoue 方法的阶段 1，用 O(1) 比较判断两个块
  是否可能重叠。对排序数组只需 `a_max < b_min` / `b_max < a_min` 两个判断。
- **精确匹配 / Exact match**：Inoue 方法的阶段 2，在确认重叠的块内找出实际
  交集元素。可用旋转法、广播法、标量归并等任意策略。
- **`permute4x64_epi64`（`vpermq`）**：AVX2 原生 u64 lane 置换指令，
  使用**立即数**控制 shuffle pattern。区别于 `permutevar8x32_epi32`（`vpermd`）
  的**变量索引** u32 lane 置换。
- **Roaring bitmap**：密度自适应混合位图。按 65536 元素分 chunk，
  ≤4096 元素用排序数组，>4096 用 bitmap，连续值用 RLE。
  Lucene 5+ / Elasticsearch / Spark / Druid 标准方案。
- **Roaring64（`roaring64_bitmap_t`）**：CRoaring 的 u64 扩展。高 48 bit 用
  ART（自适应基数树），低 16 bit 用标准 Roaring chunk。性能约为 u32 版的 50%。
- **Inoue et al.**："Faster Set Intersection with SIMD Instructions by
  Reducing Branch Mispredictions", VLDB 2015.
- **Schlegel/Lemire**："Fast Sorted-Set Intersection using SIMD Instructions",
  ADMS 2011. 当前 `intersect_avx2` 所用方案。
- **4096 阈值**：Roaring bitmap 的 ArrayContainer → BitmapContainer 切换点。
  4096 个 u16 = 8KB = 一个 BitmapContainer（65536-bit bitset）的大小。

## 8. 设计评审：与工业界方案的差异与已知缺陷

> 2026-06 评审补充。本节记录该设计相对工业主流方案的定位偏差与
> 分析性缺陷，作为 §4.3 触发条件的决策背景。结论先行：
> **本设计在「flat 数组交集内核」局部题目内是干净的，但有局部最优嫌疑**——
> 核心收益假设（块过滤跳过率）对真实 doc ID 分布大概率不成立，
> 且若 V2 做 BM25 top-k，更高优先级的是 Block-Max 类结构而非交集内核。

### 8.1 与工业界主流的四点差异

| 维度 | 本设计 | 工业主流（Lucene/ES 系） | 差距影响 |
|---|---|---|---|
| 数据形态 | flat `vector<u64>` 全量驻留，8B/id | 128-doc 块压缩（FOR/PFor）+ skip 结构，~1-2 bit/id 有效 | 100K posting = 800KB，出 L2 后内核是**带宽瓶颈**，§3 的指令数对比可能不兑现 |
| 跳跃粒度 | 块过滤一次跳 4-16 元素；>32x 走 galloping | skip list / 块元数据一次跳 128~数千 | 4x~32x 中等不对称区间两边线性推进，正是 skip 结构最赚的区间 |
| 评分集成 | 完整 must 交集 → 再评分 | WAND / Block-Max WAND / MaxScore：分数上界跳文档，top-k 出来时大部分 posting 未被触碰 | 交集内核优化的环节会被 BMW 整体绕开；纯 filter 场景工业答案是 Roaring AND（§5 已分析） |
| doc ID 宽度 | ord 恒 u64，单一 u64 路径（决策见 §8.5） | segment 内 u32 局部 ID（Lucene 段上限 2³¹），分段消解 u64 需求 | 有意识的取舍：接受 2x 内存带宽 / 半数 SIMD lane，换单路径简单性；带宽代价的正解是将来块压缩，不是 u32 收窄 |

另一处工程差异：`run_must_intersect`（inverted.cpp:900）是 pairwise
物化交集——k 个 must 词产生 k-1 次中间 vector 分配 + move。工业实现用
k-way leapfrog 或迭代器 advance 链零物化。短交集上此开销可能盖过内核优化。

### 8.2 已知缺陷（按严重程度排序）

#### 8.2.1 块过滤的收益假设与真实分布不符（最严重）

块过滤跳过的条件是块 [min, max] **区间不相交**，§3.1 的预测表把
「元素重叠率」当成了「块区间不相交率」。两者只在交集元素值域成簇时近似：

```
成簇形态（块过滤有效）：
  a: [1..1000]            b: [900..1900]
  → a 的前 ~90% 块整块 < b[0]，阶段 1 直接跳过

均匀散布形态（块过滤失效，真实 posting 常态）：
  a: 1, 3, 5, 7, ...      b: 2, 4, 6, 8, ...
  → 0% 元素重叠，但每对块区间都互相覆盖
  → 阶段 1 一个块都跳不掉，每块多付 2 次标量比较 + 2 个分支
```

对相近大小、均匀分布的列表，块过滤阶段退化为纯开销。
**影响已降级（u32 收窄移除后）**：u64 内核的对照基线是标量
`set_intersection`，即使块跳过率为 0，SIMD 精确匹配部分仍稳赚——
本缺陷不再威胁路线成立性，只影响调优。处置：§4.2 第 6/7 条
（分布矩阵 + 跳过率计数器）决定 u64 内核**保留还是删除块过滤阶段**。

#### 8.2.2 引用的是 Inoue，实现的不是 Inoue

Inoue 2015 的核心贡献是**无分支 SIMD 低字节指纹过滤**消除
`if (a[i] < b[j])` 的预测失败；本文档 §2.2 的 max/min 标量块过滤
实质是经典 block-skipping merge，且重新引入了两个数据相关分支
（块很少被跳过时恒为 false、预测良好；跳过/不跳交替时会 mispredict）。
引用论文与实现物不一致——保留现名可以，但不应预期获得论文中
报告的 branch-miss 消除收益。

#### 8.2.3 u64 内核「零 LUT」的代价是 4 个内层分支

见 §2.4 警示框。`if (mask & k) push_back` × 4 + capacity 检查
vs 512B PairLut（常驻 L1）无分支 lookup+permute+store——
后者在 mask 难预测时可能更快。另外所有内核直接 `push_back`/`resize`
进 `vector`；应预分配 `min(na, nb)` 上界 + 裸指针游标写出，
循环结束后一次 `resize` 收尾。
**两项的收益分析、实测方案与依赖顺序详见
`doc/intersect-kernel-internals-zh.md` §2/§3。**

#### 8.2.4 AVX-512 方案未对照 VP2INTERSECT

见 §2.5 警示框。Zen 5 的 `vp2intersectq` 一条指令即完成 8-lane u64
全对全比较，16-旋转循环在该微架构上是错误选型。AVX-512 内核动工前
必须先确认部署微架构并对照评估。

#### 8.2.5 带宽瓶颈未纳入性能模型

§3 全部以指令条数论证，未考虑 100K×100K（u64 下 1.6MB 工作集）
已出 L2。带宽受限时减少 SIMD 指令几乎不改变吞吐——这同时削弱
旋转法和 Inoue 的差异，也意味着压缩（缩小工作集）比内核优化
对大 posting 更有效。基准须报告工作集大小与 L2/L3 边界的关系。

### 8.3 评审结论对路线的修正

1. ~~u32 路径替换降级为「待证伪」~~ **已作废**：u32 收窄路径整体移除
   （§8.5），不存在替换问题。分布矩阵实验降级为 u64 内核调优
   （块过滤阶段保留与否，预期仅区段错开形态——如按时间分区的
   ord 空间——有收益）。
2. **u64 路径为唯一热路径**：08fbc92 起 `intersect_u64` 即生产路径，
   不再是影子路径，内核投入的 ROI 直接成立；其收益不依赖块过滤假设
   （SIMD 精确匹配相对标量本身就赚）。
3. **若 V2 确做 BM25 top-k**：交集内核之后的优化预算应转向
   Block-Max 元数据（每块 max tf/score）+ MaxScore/BMW，
   以及 `run_must_intersect` 的 k-way 化（消除中间物化）。
   **详细路线说明见 `doc/kway-blockmax-bmw-zh.md`**
   （k-way → 块元数据 → BMW 的依赖链与各自收益）。
4. **AVX-512**：维持 §4.3 触发条件，新增前置——确认目标微架构后
   先评估 VP2INTERSECT 路线。

### 8.5 决策记录：放弃 u32 收窄，ord 恒为 u64（2026-06-12）

**决策**：ord 在类型语义上就是 64 位单调序号，查询路径不做 u32 收窄。
`narrow_ok` 门与 `intersect_u32` 内核自 08fbc92 起从代码中移除，
`bool_search` 统一走 `intersect_u64`。

**放弃 u32 收窄的理由**：

1. **查询时收窄有自身成本**：u64 → u32 需逐 posting 拷贝
   （读 8B/id + 写 4B/id），大 posting 上这趟带宽吃掉相当部分内核收益；
   若改为存储层原生 u32 则违背 ord=u64 的类型设计，且引入双格式
   （save/load、snapshot、merger 全要感知）。
2. **双路径维护成本**：两套内核族 × 两套对拍/对抗/sanitizer 测试矩阵
   + 收窄门自身的边界条件（恰好跨 2³² 的索引），换来的只是
   热路径上的常数加速。
3. **per-element 指令数两者同阶**：全对全旋转每块 B 次 permute+cmp
   覆盖 B² 对、推进 ≥B 个元素——per-element ALU 成本与 lane 宽度
   基本无关。u32 的真实优势主要是**内存占用/带宽减半**，不是指令吞吐。

**接受的代价**（诚实记录）：

- flat posting 8B/id，是 u32 的 2 倍内存与带宽；与工业压缩格式
  （~1-2 bit/id 有效）差距进一步放大。
- **该代价的正解是将来的块压缩（FOR/PFor + 块级元数据），不是
  u32 收窄**——压缩同时为 BMW/MaxScore 提供 skip 地基（§8.3 第 3 条），
  一份投入解两个问题。当前规模（100K×2 列表 = 1.6MB，在 L3 内）
  带宽尚不构成瓶颈，posting 规模显著增长时再触发压缩路线。

- Inoue, Ohara, Taura: "Faster Set Intersection with SIMD Instructions by
  Reducing Branch Mispredictions", VLDB 2015 —— 注意其过滤阶段为
  无分支 SIMD 字节指纹，非本设计的标量 max/min 块过滤。
- Ding & Suel: "Faster Top-k Document Retrieval Using Block-Max Indexes",
  SIGIR 2011（Block-Max WAND）。
- Broder et al.: "Efficient Query Evaluation using a Two-Level Retrieval
  Process", CIKM 2003（WAND）。
- AVX512-VP2INTERSECT：Intel ISA 扩展，Tiger Lake 引入后弃用；
  AMD Zen 5（EPYC Turin）提供硬件快速实现。
