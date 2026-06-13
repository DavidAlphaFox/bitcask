# SIMD 指令内幕:AVX2 madd vs VNNI dpbusd

记录 bitcask 量化距离内核用到的 SIMD 指令的底层运算逻辑。
背景见 [int8-vnni-v4-zh.md](int8-vnni-v4-zh.md);内核实现见
`cpp/include/bitcask/int8_kernels.hpp` 与 `cpp/src/vector/hnsw.cpp`。

## 1. `_mm256_madd_epi16`:相邻配对乘加

`VPACKSSDW`/`VPMADDWD`——取两个 `__m256i`(各 16 个 `int16`),相邻元素两两
分别相乘,再将每对乘积相加,输出 8 个 `int32`:

```
输入 a = [a0, a1, a2, a3, ..., a14, a15]   (16×int16)
输入 b = [b0, b1, b2, b3, ..., b14, b15]

结果   = [a0×b0 + a1×b1,      ← 第 0 对
          a2×b2 + a3×b3,      ← 第 1 对
          a4×b4 + a5×b5,
          a6×b6 + a7×b7,
          a8×b8 + a9×b9,
          a10×b10 + a11×b11,
          a12×b12 + a13×b13,
          a14×b14 + a15×b15]  ← 第 7 对
         (8×int32)
```

伪代码:

```cpp
for (int i = 0; i < 8; i++) {
    int32_t p0 = (int32_t)a[2*i]   * (int32_t)b[2*i];
    int32_t p1 = (int32_t)a[2*i+1] * (int32_t)b[2*i+1];
    result[i] = p0 + p1;
}
```

16 个 int16 输入 → 8 个 int32 输出。一条指令完成 16 次乘法 + 8 次加法。
要求输入是 int16;int8 没有对应的 madd 指令(因为 int8×int8=int16,需要二次
累加才能到 int32)。

## 2. 为什么 int8 点积在 AVX2 上麻烦

AVX2 没有 int8 直接乘加到 int32 的指令。要做 int8 点积必须:

```
步骤 1: int8 → int16    (_mm256_cvtepi8_epi16,每次只处理 16 个)
步骤 2: int16 × int16 → int32 相邻对乘加  (_mm256_madd_epi16)
步骤 3: int32 累加      (_mm256_add_epi32)

32 个 int8 的点积 ≈ 6 条指令 + 大量中间寄存器
```

类型链 `int8 → int16 → int32` 的逐级拆包是主要开销。

## 3. VNNI `vpdpbusd`:一步到位

`vpdpbusd`(Packed Dot Product of Bytes,Unsigned×Signed to Doubleword)一条
指令完成:

```
对 256-bit 寄存器的每个 32-bit 槽位:
  acc += a_u8[0]×b_s8[0] + a_u8[1]×b_s8[1] + a_u8[2]×b_s8[2] + a_u8[3]×b_s8[3]
  (a 为 unsigned byte, b 为 signed byte, 乘积累加到 int32)
```

32 个 int8 → **1 条指令**,无需中间类型提升。对比 AVX2 的 6 条指令,指令数
减少 ~6×,μops 从 ~10-12 降到 ~2,寄存器占用减半。

## 4. VNNI 指令家族

| 指令 | 操作 | 典型用途 |
|------|------|---------|
| `vpdpbusd` | u8 × s8 → i32 累加 | 对称量化向量点积 |
| `vpdpbssd` | s8 × s8 → i32 累加 | 有符号 int8 乘法 |
| `vpdpwssd` | s16 × s16 → i32 累加 | int16 量化(更高精度) |
| `vpdpbusds` | u8 × s8 → i32 累加(饱和) | 防溢出场景 |

## 5. VNNI 的偏置补偿技巧

`vpdpbusd` 要求第一个操作数是 **unsigned** int8,但我们的量化码是有符号的
(范围 [-127, 127])。处理方法:

```
query codes XOR 0x80 → 无符号(u8),  // -127→0, -1→127, 0→128, 1→129, 127→255
db codes 保持 s8                     // 不变

raw = Σ query_u8[i] × db_s8[i]
    = Σ (query[i] + 128) × db[i]    // XOR 0x80 等价于加 128(对 [-127,127] 范围)
    = Σ query[i]×db[i] + 128 × Σ db[i]

所以: Σ query[i]×db[i] = raw - 128 × sum_db
```

`sum_db` 在量化时预计算一次,每个 db 向量存一个 int32。运行时每个距离计算
只需一次减法修正。

## 6. AVX-VNNI(256-bit) vs AVX-512 VNNI(512-bit)

| 维度 | AVX-VNNI | AVX-512 VNNI |
|------|----------|--------------|
| 指令 | `_mm256_dpbusd_avx_epi32` | `_mm512_dpbusd_epi32` |
| 每指令处理 | 32 int8 | 64 int8 |
| 编码 | VEX(短) | EVEX(长) |
| 寄存器宽度 | 256-bit | 512-bit |

### 什么时候 AVX-VNNI 可能比 AVX-512 VNNI 快?

理论上 AVX-512 每指令处理 2× 数据,应该永远更快。但实际取决于 CPU 微架构:

| CPU | AVX-512 VNNI | AVX-VNNI | 胜者 |
|-----|-------------|----------|------|
| **Intel Skylake-SP** | 降频 300-500 MHz | 全速运行 | AVX-VNNI 可能更快 |
| **Intel Ice Lake / Sapphire Rapids** | 轻微降频 | 全速 | AVX-512 通常更快 |
| **AMD Zen 4** | 双泵 256-bit(无原生 512-bit ALU) | 原生 256-bit | 持平 |
| **AMD Zen 5** | 原生 512-bit 数据通路 | 原生 256-bit | **AVX-512 更快** |

关键因素:

1. **降频惩罚**: 某些 CPU 进入 AVX-512 模式会降频,连续使用时间 <1μs 时
   降频/恢复的开销可能抵消 2× 吞吐收益
2. **双泵实现**: AMD Zen 4 的 AVX-512 内部拆成两条 256-bit μop,与直接
   两条 AVX-VNNI 指令吞吐量相同,但后者调度更灵活
3. **混合代码**: 频繁在 int8(VNNI)和 f32(非 VNNI)之间切换时,AVX-512
   状态切换有额外开销;AVX-VNNI 与 AVX2 共享状态,无此问题

## 7. bitcask 中的使用方式

bitcask 在运行时根据 CPU 特性自动选择最优内核:

```
pick_int8_dot_kernel():
  avx512vnni 可用 → _mm512_dpbusd_epi32  (64 int8/iter)
  avxvnni 可用   → _mm256_dpbusd_avx_epi32 (32 int8/iter)
  都不可用       → nullptr, 回退 f32 路径
```

当前机器(Zen 5 / Ryzen 7 9700X)有原生 512-bit VNNI,运行时分发到
AVX-512 VNNI 路径,搜索 100k 向量 ef=64 耗时 72μs,比 V3.9 f32 路径的
376μs 快 5.2×。
