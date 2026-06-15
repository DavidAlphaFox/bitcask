# 向量落盘 int8 量化设计（P3 / V7）

> 状态：设计。实现是 follow-on，**gated on 召回测量**（见 §6）。
> 关联：持久化优化 P 系列（`TASK.md` V7）、`doc/int8-vnni-v4-zh.md`（内存侧 int8）、
> `doc/hnsw-design-zh.md`。

## 1. 动机

向量集合的 data file 体积被 f32 向量主导：2560 维 = 10 KB/doc。落盘 int8 把每条
向量压到 `4 + dim` 字节（2564B @ 2560 维）≈ **4× 磁盘 + 读 I/O 缩减**。BM25/KV
负载不受影响（仅 kDoc 的向量段变化）。

## 2. 现有 seam（已就位，无需新建）

DocValue v3 格式（`format.hpp`）已为量化预留：
- `kFlagVecQuantized = 0x08`：向量段是码字而非裸 f32。
- `kQuantizedMagic "QCOD" + kQuantizedVersion=1`：V6.4.1 写端可写 stub，**读端拒绝**
  （"需 V7+ codeword 支持"）。
- 向量段定序最前：`[Dim:varint][ f32×Dim 或 量化码字 ]`，便于 HNSW O(1) 切片。

P3 = 把「读端拒绝」换成真正的 int8 编解码。

## 3. 量化方案（复用内存侧，避免双实现）

直接复用 `bitcask::vec::int8`（`detail/int8_kernels.hpp`）的 per-vector 对称量化：
- `scale = max|v[i]|`，`codes[i] = round(v[i]/scale*127)` ∈ [-127,127]，
  重建 `v̂[i] = codes[i]*scale/127`。
- **落盘码字布局**（kFlagVecQuantized 置位时的向量段）：
  ```
  [Dim:varint][scale:f32 LE][int8 × Dim]
  ```
  大小 = varint(Dim) + 4 + Dim 字节。复用同一量化器 → 落盘 int8 可**直接喂给
  HNSW**（in-memory 也是 int8），免一次量化。

可选增强（后续）：affine（min/max 偏移）比对称略提精度；先用对称（与内存侧一致）。

## 4. 核心决策：f32 权威问题 ⚠️

f32 当前是三处的 source of truth，int8-only 落盘都会受影响：

| 用途 | int8-only 影响 |
|------|---------------|
| HNSW rerank（int8 粗筛 → f32 精排） | **精排失去 f32**：只能 int8 精排，召回略降（int8 cosine 误差 ~1e-3 量级，见 int8-vnni 文档） |
| 重嵌入 / 迁移 | 原始 f32 不可逆恢复（量化有损） |
| `get` 返回向量 | 返回 dequant 近似 f32（有损） |

**结论与推荐**：
- int8 落盘是**有损**的体积/精度权衡，不能默认开。
- 设计为 **opt-in**：新增 open 选项 `{vector_quantized, true}`（写入侧量化落盘）；
  默认仍 f32（零行为变化、零兼容风险）。
- `get` 对量化文档返回 dequant f32 并在文档注明有损。
- 是否把它设为某类部署的推荐，**取决于 §6 召回测量**。

不做「int8 + 同时存 f32」——那没有体积收益，违背 P3 目标。

## 5. 读写路径改动点

1. `codec::encode_doc_value`：`parts.vector` + `quantize=true` → 写 §3 码字 + 置
   `kFlagVecQuantized`。
2. `codec::decode_doc_value`：见 `kFlagVecQuantized` → 读 scale+codes，dequant 成
   f32 返回（保持上层 `DocValueView.vector` 为 f32 的现有契约），同时透出原始
   codes/scale 供 HNSW 直接接入（避免 dequant→requant 往返）。
3. HNSW 接入（`on_vector`）：量化集合下直接用 codes/scale 建图，省一次量化。
4. open 选项 `{vector_quantized, true}` → `CaskOptions.vector_quantized` →
   写入 meta（`bitcask.meta`），重开校验一致（不一致 → `mode_mismatch`，同
   `vector_dim`/`vector_metric`）。
5. 配 embedder 时与 MRL 正交：先 MRL 截断到 `vector_dim`，再 int8 量化落盘。

## 6. 召回测量 gate（P3c ✅）

测量隔离量化误差对召回的影响：brute-force f32 余弦 top-k 为真值，对比
「dequant-int8 库（= 落盘 int8 读回）vs f32 query」的 top-k 重叠。复用 `vec::int8`
的同一量化方案。harness：`cpp/tests/hnsw_test.cpp::measure_quant_recall`（CI
回归红线 ≥ 0.95，可任意改 n/dim/k 复跑）。

**结果（2026-06，合成归一化高斯，dim=2560，n=2000，nq=30）：**

| 指标 | f32 真值 vs 落盘 int8 |
|------|----------------------|
| recall@10 | **0.9867**（跌 ~1.33%） |
| recall@100 | **0.9953**（跌 ~0.47%） |

**决策：int8 保持 opt-in，f32 仍为默认。** 理由：recall@10 跌幅 ~1.3% 略超
「< 1% 才设默认」的保守线；top-10 是最常见 UI 路径，召回敏感。4× 磁盘换 ~1.3%
recall@10 对磁盘受限部署是合理取舍，由部署方 `{vector_quantized, true}` 自选。

**真实语料再验证（设默认前必须）：** 上述为合成语料。真实 qwen3 嵌入有聚簇
结构，int8 召回可能更高或更低。要把 int8 设为某类部署默认前，应在真实语料上用
同一 harness 复测（端点见 [[embedding_endpoint]]）。当前结论：不设默认。

## 7. int8-only 内存模式实测（与 P3 落盘 int8 区分）

P3 落盘 int8 只省**磁盘**；HNSW 内存里仍是 **f32 vecs + int8 qcodes 两份**
（dot 模式），int8 在内存里是为 VNNI 提速、反而 +25% 内存。真正省**内存**要
int8-only 模式：丢掉常驻 f32 `vecs`、建图/精排都用 int8。代价是召回（无 f32 精排）。

实测（`hnsw_test::Int8OnlyMemoryAndRecall`，聚簇合成 dim=2560，n=3000，nc=50，ef=64；
建图+搜索分别在 f32 与 dequant-int8 上跑，真值用 f32 brute-force）：

| | f32 精排（现行 dot 模式） | int8-only |
|---|---|---|
| recall@10 | 1.0000（合成簇可分，饱和） | **0.9675**（Δ −3.25%） |
| 向量存储/向量（dim=2560） | 5·dim+8 = **12808 B** | dim+8 = **2568 B** |
| 1M 向量（仅向量存储） | **12.81 GB** | **2.57 GB** |

**结论：int8-only 省 ~80% 向量内存（~5×），代价 recall@10 约 −3% 量级。**
（邻接表两模式相同、未计入差值——计入后总占用比略小于 5×。）合成簇高度可分使
f32=1.0 饱和、只暴露 int8 的隔离代价；真实语料 f32 < 1，int8 delta 量级相近，
设默认/上线前需真实语料复测。这是向量库内存墙的主要杠杆——比 P3 的磁盘优化更
接近瓶颈，但属 V7+ 大改（去 f32 副本 + 查询侧量化 + 召回 gate），尚未实现。

## 7. fixtures / 兼容

- 项目不考虑向后兼容；但 opt-in 默认关 → 既有 f32 数据零影响。
- 新增 QCOD 码字的黄金 fixture（encode/decode round-trip + dequant 误差界）。
- decode 仍只接受 DocValue Ver==3；量化与否由 Flags 区分。

## 8. 分期

- P3a：codec int8 编解码 + round-trip 测试 + fixture（纯格式，不接 open）。
- P3b：open `{vector_quantized}` 接线 + meta 持久化 + HNSW 直接接入 codes。
- P3c：§6 召回测量 + 决定默认与文档。

> 本设计完成「start」；P3a-c 是后续实现，P3b 起改 DocValue 写出需先过 P3a fixture。
