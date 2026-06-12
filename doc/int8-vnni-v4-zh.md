# V4 预研:int8 量化 + AVX-VNNI 距离内核

记录 V4 把距离内核从 f32/AVX2 切到 int8/VNNI 的动机、收益账与本机硬件约束。
背景:V3 距离内核见 [hnsw-design-zh.md](hnsw-design-zh.md) §2.3(f32 内积/L2,
AVX2 FMA,每迭代 8 元素);"插入残差"与 2560d 规模账的根治均指向本方案。

## 1. vpdpbusd 指令

AVX-VNNI(Vector Neural Network Instructions)的核心指令是
`vpdpbusd`(**P**acked **D**ot **P**roduct of **B**ytes,
**U**nsigned×**S**igned to **D**oubleword),一条指令完成:

```
对 256-bit 寄存器的每个 32-bit 槽位:
  acc += a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3]   (a 为 u8,b 为 s8)
```

一个 256-bit ymm 装 32 个 int8,所以一条 `vpdpbusd` = 32 次乘法 + 32 次加法 +
累加,乘积自动扩宽到 int32 累加器,int8 相乘不会溢出。VNNI 之前要
`vpmaddubsw` + `vpmaddwd` + `vpaddd` 三条指令才能凑出同样效果。

对比 V3 内核:f32 + AVX2 FMA 一个 ymm 装 8 个 float,每迭代 8 维;
int8 + VNNI 每迭代 32 维——单指令吞吐 4×。2560 维内积从 320 次迭代降到 80 次。

## 2. 为什么"两个瓶颈一起解"

HNSW 搜索的真实瓶颈往往不是算力而是内存:图遍历访问邻居向量是随机访存,
cache 命中率极低,基本每个候选都要从 DRAM 拉一遍。2560 维下:

- **f32**:每向量 10,240 B(10 KB)——单次查询碰几百个候选就是几 MB 的随机
  DRAM 流量,带宽打满;
- **int8**:每向量 2,560 B——内存流量 4×↓,同样带宽多塞 4 倍候选,
  单向量更容易整体落进 L2。

int8 量化同时拿到两份收益:访存量降 4×(治 DRAM 瓶颈)+ 计算吞吐升 4×
(VNNI 治算力瓶颈)。两者是乘性配合:光提算力,内核更快地空等内存;
光降访存,标量 int8 计算又成新瓶颈。VNNI 让计算速度跟上变小的数据。

与"插入残差"、2560d 规模账的关系:插入成本(建图时每点大量距离计算)和
2560 维内存账,根因都是单次距离计算又贵又费带宽。V3 框架内只能预取/批量化
治标;V4 把数据变小 4×、计算变快 4×,从根上改常数项。

## 3. 本机硬件约束(i9-13900H,Raptor Lake)

`/proc/cpuinfo` 有 `avx_vnni` 标志——VEX 编码的 AVX-VNNI,`vpdpbusd`
可在 ymm 上用,本方案成立。

**没有** `avx512_vnni`:12/13 代因 E-core 不支持 AVX-512,整个 AVX-512
家族(含 512-bit VNNI)被熔断。上限 256-bit,做不到一条指令 64 个 int8。

实现注意:

- 编译:`-mavxvnni`(GCC/Clang 均支持);
- intrinsic:`_mm256_dpbusd_avx_epi32`——带 `_avx` 后缀的才是 VEX 版;
  不带后缀的 `_mm256_dpbusd_epi32` 是 AVX512-VNNI 的 EVEX 版,本机非法指令;
- 运行时检测:CPUID leaf 7 subleaf 1 的 AVX-VNNI 位,与 AVX-512 检测路径
  不同,cpu-dispatch 时勿混。

## 4. 量化方案要点

- `vpdpbusd` 是 unsigned×signed:两边都是 signed int8 时,常见做法是给
  一边 +128 偏移转 u8,再用补偿项修正(`Σ(a+128)·b = Σa·b + 128·Σb`,
  `Σb` 可对每个向量预计算);
- 量化本身有损(per-vector scale 对称量化,召回率小幅下降);通用解法是
  int8 粗筛 + 对 top 候选用原始 f32 重排(rerank),精度基本无损;
- embedder 输出已归一化(qwen3-embedding,2560d),数值范围稳定,
  per-vector scale 量化误差可控。
