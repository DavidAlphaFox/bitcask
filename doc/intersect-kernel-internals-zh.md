# 交集内核内幕：旋转法原理与输出段微优化

> 对应代码：`intersect.cpp`（`intersect_u64` 全部内核）。
> 前置阅读：`doc/inoue-simd-intersection-zh.md`（块过滤设计与评审）。
>
> 本文三部分：旋转法（Schlegel/Lemire）的深度原理介绍；
> 两项输出段微优化的收益分析——①预分配 + 裸指针游标（待实施），
> ②压缩段「条件分支 vs PairLut」实测对比（待实施，依赖①）。

## 1. 旋转法（Schlegel/Lemire, ADMS 2011）深度介绍

### 1.1 要解决的问题：标量归并的分支预测失败

两个升序块各 B 个元素求交。标量归并：

```cpp
if (a[i] < b[j]) ++i; else if (b[j] < a[i]) ++j; else { 输出; ++i; ++j; }
```

瓶颈不是比较（1 周期），而是**三路分支无法预测**——元素交错顺序由
数据决定，本质随机。随机数据下约每 2 个元素错预测一次，每次
~15-20 周期，真实成本 **~8-10 周期/元素**，其中 ~90% 是 mispredict
罚款。所有 SIMD 交集方法的共同出发点：**用固定指令序列换掉
数据相关分支**。

### 1.2 核心想法：旋转实现全对全比较

不知道两块元素如何对位，就把 B×B 所有配对全比一遍——换来零分支、
固定指令数、完美流水线。做法：va 固定，vb **循环旋转** B-1 次，
每轮做 lane 对 lane 相等比较。B=4：

```
        lane:    0      1      2      3
rot 0:  a0:b0  a1:b1  a2:b2  a3:b3   ← 主对角线
rot 1:  a0:b1  a1:b2  a2:b3  a3:b0
rot 2:  a0:b2  a1:b3  a2:b0  a3:b1
rot 3:  a0:b3  a1:b0  a2:b1  a3:b2
```

4 轮旋转把 16 个配对按**对角线**切成 4 份，每对恰比较一次。
4 轮掩码 OR 起来，lane i = 「a[i] 是否出现在 b 块中」。

对应代码（intersect.cpp:72-84）：

```cpp
cmp01 = cmpeq(va, vb)                              // rot 0
      | cmpeq(va, permute4x64(vb, 0x39));          // rot 1: lanes 1,2,3,0
cmp23 = cmpeq(va, permute4x64(vb, 0x4E))           // rot 2: lanes 2,3,0,1
      | cmpeq(va, permute4x64(vb, 0x93));          // rot 3: lanes 3,0,1,2
cmp   = cmp01 | cmp23;
mask  = movemask_pd(cmp);                          // 4-bit 命中掩码
```

要点：

- **旋转模式是编译期常量** → 用 `permute4x64` 立即数形式
  （0x39/0x4E/0x93 即 `_MM_SHUFFLE` 编码的三种循环移位），
  不需从内存加载索引向量——u64 内核比旧 paired-u32 模拟干净的原因。
- **cmp01 与 cmp23 两条链无数据依赖** → 乱序核并行发射，
  比较延迟互相隐藏。固定指令序列的第二重收益：无 mispredict 之外
  还有高 ILP。
- **正确性依赖「升序 + 无重复」**：每个 a[i] 在 b 块至多命中一次，
  OR 累积不混淆。前提由 PostingList 不变量保证。

### 1.3 块间推进

比较两块最大值（intersect.cpp:106-109）：

```cpp
if (amax <= bmax) i += B;    // 相等时两边都推进
if (bmax <= amax) j += B;
```

不丢匹配的证明：若仅 a 推进（amax < bmax），a 块所有元素 ≤ amax，
小于 b 块剩余未匹配区间，丢弃的 a 元素不可能再匹配。相等时双推进同理。
这两个分支数据相关，但每 B 个元素付一次，被摊薄。

### 1.4 压缩输出

mask 标出命中 lane，还要把命中元素**紧凑**写出。这是旋转法第三段，
各实现差异最大处：

| 宽度 | mask 取值数 | 经典做法 |
|---|---|---|
| u32 × 8 lane（AVX2） | 256 | 256 项 LUT（8KB）+ `permutevar8x32` + store |
| u64 × 4 lane（AVX2） | 16 | 16 项 PairLut（512B）+ paired `permutevar8x32`；或当前代码的 4 × 条件 push_back（intersect.cpp:86-89） |
| AVX-512 | — | `vpcompress` 一条指令，LUT 消失（intersect.cpp:146 已用） |

压缩段选型见 §3。

### 1.5 成本账与谱系

**u64 AVX2 每块（4 元素）**：2 load + 3 permute + 4 cmpeq + 3 or +
1 movemask ≈ 13 条 SIMD 指令覆盖 16 配对、推进 ≥4 元素，
约 3 条指令/元素，全程无数据相关分支（压缩段除外）。对比标量
~8-10 周期/元素。**旋转法不是比较得更快，而是从不猜错。**

谱系：Schlegel et al. 2011 用 SSE4.2 `pcmpestrm` 做 u16 全对全；
Lemire/Boytsov/Kurz 2016 推广到 u32 shuffle + galloping 混合。

**局限**：全对全是「块内」无分支，但**每块照付全套 13 条指令，
哪怕两块毫无交集**。低重叠率下大部分 SIMD 工作花在空块上——
这正是 Inoue 块过滤（intersect.cpp:101-102 两次标量区间比较）
要在它前面挡掉的开销。互补关系：**Inoue 管「这块要不要算」，
旋转法管「要算的块怎么算到最快」**。

## 2. 微优化①：预分配 min(na,nb) 上界 + 裸指针游标

### 2.1 push_back 在热循环里的真实成本

当前四处逐元素写出：标量归并（intersect.cpp:29）、galloping（:54）、
AVX2 内核（:86-89）、AVX-512 每重叠块一次 `resize`（:144-145）。
每次 `push_back` 编译后：

```
载入 size、capacity → 比较 → 分支（满？）
  ├─ 不满：写元素、size+1 写回内存
  └─ 满：扩容（分配+搬运+释放）
```

三个隐藏成本：

1. 每元素一次「容量检查 + 分支」，即使从不扩容也付；
2. size 字段内存读改写形成跨迭代 store-load 依赖链，限制乱序吞吐；
3. 编译器无法把写出位置保持在寄存器（`out` 成员可能被任何调用改）。

### 2.2 改法

交集结果天然上界 `min(na, nb)`：

```cpp
out.resize(std::min(na, nb) + kSlack);   // 一次给足（kSlack = B，见 2.3）
uint64_t* cur = out.data();              // 游标常驻寄存器
... *cur++ = v;  或  store + cur += popcount(mask);
out.resize(cur - out.data());            // 一次截断
```

写出变成「一条 store + 寄存器自增」。一次性 resize 的零填充是
一趟顺序写，远比每元素一次分支便宜。

**受益最大是 AVX-512 路径**：当前每重叠块 `out.resize(old + cnt)`
（函数调用 + 分支只为腾位置），改后整段变成：

```cpp
_mm512_mask_compressstoreu_epi64(cur, cmp, va);
cur += std::popcount(cmp);    // mask==0 早退分支也可删
```

每块固定两条指令，完全无分支。标量/galloping 省 per-element 检查，
SIMD 省 per-block resize——**对所有路径纯收益**。

### 2.3 实现细节

无条件 SIMD store 写满整个向量宽度（哪怕只 2 个命中），预分配须
多留 `kSlack = B` 余量；多写部分被后续写出覆盖或最终截断丢弃。

## 3. 微优化②：压缩段「4×条件分支 vs PairLut 无分支」实测

### 3.1 当前实现的分支形态依赖

intersect.cpp:86-89 每重叠块 4 个数据相关分支：

- **mask 几乎恒 0**（稀疏交集）或**恒满**（自交）：预测近乎全对，
  成本 ≈ 0，此写法很快；
- **mask 随机**（中等密度，每 lane ~50% 命中）：每分支 ~50% 错预测
  × ~15-20 周期，最坏 ~70 周期/块——旋转比较部分才 ~10 周期。
  **压缩段成为内核主要开销**，且破坏了旋转法的块内无分支设计。

### 3.2 PairLut 无分支替代

AVX2 无 64-bit lane 变量置换 → 把 4 个 u64 lane 视作 8 个 u32 lane，
用 `permutevar8x32` 以成对索引搬移。16 项表（4-bit mask 全取值），
每项 8 个 u32 索引：

```cpp
// 例: mask = 0b0101（lane0、lane2 命中）
// 表项 = {0,1, 4,5, _,_, _,_}
const __m256i perm = _mm256_load_si256(&kPairLut[mask]);
const __m256i packed = _mm256_permutevar8x32_epi32(va, perm);
_mm256_storeu_si256(cur, packed);       // 无条件写 32B
cur += std::popcount(mask);
```

固定 3 条指令 + 1 次 L1 表加载（整表 512B 常驻 L1），零分支，
对 mask 形态不敏感。

### 3.3 为什么实测而非直接换

两实现各有必胜区：分支版赢「可预测 mask」（省表加载 + permute），
无分支版赢「随机 mask」。基准须覆盖三点：

1. 每 lane 50% 命中率（分支版最坏情况，对抗构造）；
2. 稀疏交集（mask ≈ 0，分支版最好情况）；
3. 全命中 / 自交（mask 恒满）。

综合赢者上位——把 inoue 文档 §2.4 的「零 LUT 更优」从断言变成
有数据的结论。

### 3.4 依赖关系

无分支版需「无条件写 32B + 游标前进」，**前提是 §2 的预分配缓冲
就位**（push_back 接口下做不了无条件 store）。实施顺序：①先 ②后。

## 4. 总结：三段无分支化的全景

| 内核段 | 无分支手段 | 状态 |
|---|---|---|
| 块内比较 | 旋转法全对全（§1） | 已落地 |
| 压缩 | PairLut 或 vpcompress（§3） | AVX-512 已落地；AVX2 待实测选型 |
| 写出 | 预分配 + 裸指针游标（§2） | 待实施 |

三件做完，整条内核从头到尾才真正没有数据相关分支。

## 5. 参考

- Schlegel, Willhalm, Lehner: "Fast Sorted-Set Intersection using
  SIMD Instructions", ADMS 2011.
- Lemire, Boytsov, Kurz: "SIMD Compression and the Intersection of
  Sorted Integers", Software: Practice & Experience 2016.
- Inoue, Ohara, Taura: "Faster Set Intersection with SIMD Instructions
  by Reducing Branch Mispredictions", VLDB 2015.
