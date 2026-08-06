# Bitcask 路线图（Roadmap）

English: [`ROADMAP_EN.md`](ROADMAP_EN.md)。详细子任务拆分与历史见 [`TASK.md`](TASK.md)。

状态图例：✅ 承诺（will do） · ⚠️ 备选（candidate，按 gate 决策）。

---

## 5.1.0 落地

### 本地嵌入后端（llama.cpp / ggml）✅

在 BEAM 进程内直接算 embedding，不经 HTTP 端点。产物是**独立的第二个 NIF**
`priv/bitcask_llama.so`，与核心 `bitcask_cpp.so` 互不依赖；**默认不构建**
（`BITCASK_WITH_LLAMA=1`），关掉时构建产物与 5.0.0 一字不差。新增 submodule
`third_party/llama.cpp`（tag `b10257`）。**本次不涉及 libbitcask 升级**，无 ABI
变更、无盘上格式变更。

定位是**另开一档**而不是替换 HTTP 端点：CPU 上跑得动的是 0.6B / 1024 维这一类，
换档 = 落库维度变了 = 全量重建索引。实测（8 vCPU、`Qwen3-Embedding-0.6B-Q8_0`、
`n_ctx=512`）查询 33–35 ms、文档（276 token）≈ 890 ms。

> ⚠️ **ggml 的 `GGML_ASSERT` 是 `abort()`**，在 BEAM 里等于整个 node 连同所有打开
> 的 cask 一起没。分成两个 `.so` 不能隔离这一点（同进程），只能把可预期的失败挡
> 在 llama 之前（路径 / 池化 / token 数）。真要进程级隔离只能上 port —— 那正是
> 现有的 HTTP 端点方案。不能接受这条就继续用 HTTP 档。

### 独立 embedder 进程 ✅

`bitcask_embedder_server`（gen_server）+ `bitcask_embedder_proxy`（provider）。
`open/2` 的 `{embedder, _}` 现在也接受进程引用。一次解决三件事：**权重只装一份**
（此前每 `open` 一次建一个 ctx）、**生命周期有主**（`bitcask:close/1` 不关
embedder，进程的 `terminate/2` 才关）、**串行本来就是要的**（`llama_context` 非
线程安全，gen_server 单进程语义就是这个约束）。

两档 embedder 就此分清：HTTP 档（`openai` / `anthropic`）无状态、请求该并发，
**不需要配置任何进程**；内置档有状态、必须串行，走进程。共享逻辑收进
`bitcask_embedder_util`（此前 openai / anthropic 各有一份逐字重复的拷贝）。

> ⚠️ 配了 embedder 却起不来（GGUF 路径写错、pooling 解析成 NONE …）会让整个
> bitcask application 起不来，**这是有意的**——静默降级成没有嵌入能力，要等到
> 检索结果不对才发现，那时候库已经写脏了。为此 `bitcask:open/2` 也不再吞掉
> `application:start` 的失败（返回 `{error, {bitcask_app_start_failed, _}}`）。

### GPU（NVIDIA CUDA / Vulkan）✅

服务器产品的取舍是**性能优先、体积不是约束**：CUDA 架构覆盖 Maxwell..Blackwell
不收窄成 native，CUDA 运行时随包平铺进 `priv/`——换掉的是"目标机缺 libcublas →
ggml 静默跳过 → 降级纯 CPU"这一整类不报错的故障。

**构建期探测 SDK，运行期探测显卡** —— 这两件事在**不同的机器**上发生（构建机常常
没有卡，部署机常常没有 SDK），所以分开做：

- **构建期**：`BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN` 各自 `AUTO|ON|OFF`
  （默认 AUTO，探到 SDK 就编入，两个可同时开）。构建期事实烧进 `.so`，由
  `build_info/0` 自报。⚠️ Vulkan 的 AUTO 必须 loader / `glslc` / SPIRV-Headers
  **三个**都确认再开——ggml-vulkan 那两个 `find_package` 都是 `REQUIRED`，只探到
  一个就打开会直接把构建炸掉。
- **运行期**：由 Erlang **自己**按 `backend => auto`（CUDA > Vulkan > CPU）挑第一个
  真的有 GPU 的后端族，`n_gpu_layers` 默认也是 auto。**不需要按机器改配置，也不
  需要脚本**——部署机上既没有这个仓库也没有 cmake。
- `gpu_status/0` 把两者对到一起：`ok` / `cpu_only_build`（要重新构建）/
  `no_gpu_device`（要装驱动）。只看运行期分不清这两种，而修法完全不同。

> ⚠️ **只选一族是正确性要求，不是策略。** CUDA 与 Vulkan 同时编进包里时两者各自
> 枚举同一张物理卡（一张 4090 = `CUDA0` + `Vulkan0`），`devices=NULL` 会让 llama
> 把它当成两张去切分模型层——不报错，只是显存重复占用 + 莫名其妙的慢或 OOM。

**多卡：默认只用一张，走数据并行。** llama 的 `split_mode` 默认是 `LAYER`（把层切
到所有卡上）。对嵌入模型那是反优化：0.6B 权重一张卡装得下，切开只多出跨卡传输，
还把 N 张卡的并行浪费在**一条串行**的请求路径上（一个 `llama_context` 同时只服务
一次前向）。嵌入要的是数据并行——按 `backend_info/0` 的设备表开 N 个 embedder 进程、
各绑一张卡（`gpu_index`），正好对上"一句柄 = 一 context = 串行"的结构。真需要模型
并行（大模型单卡装不下）才配 `split_mode => layer`。

**多卡：一卡跑全部 layer，N 个 instance（数据并行）。** `bitcask_embedder_pool`
按 application env 的 `instances => [0,1,2,3]` 起 N 个 embedder 进程，各绑一张卡。
llama 的 `split_mode` 默认 `LAYER`（把层切到所有卡上）对嵌入模型是反优化：0.6B
一张卡装得下，切开只多出跨卡传输，而且**一个 `llama_context` 同时只服务一次前向**
——切完之后 N 张卡仍然只在处理 1 个请求。数据并行才是要的：N 个请求真并发，单卡
显存占用仍是一份权重。

> ⚠️ **协调者不在热路径上。** 池是个 **supervisor**，不转发任何 `embed`：worker
> 用稳定注册名注册（重启后名字不变，缓存不失效），调用方直接打 worker，中间零跳。
> 让一个进程去 `gen_server:call` worker 的话，它自己就成了新的串行点，N 个 worker
> 等于白开。
>
> ⚠️ **只接受显式卡（组）列表，不提供 `auto`**：共享机器上别的租户也在用 GPU。
> `[[0,1],[2,3]]` 表示卡组（单卡装不下时），组内多于一张自动 `split_mode => layer`。
>
> ⚠️ **启动串行**（N 次模型加载）。故意没做并行/懒加载——那样 worker 的启动失败会
> 绕过 supervisor 的启动期检查，而"配了却起不来就让 application 死"正是靠它成立的。

**单卡装不下的三条出路**：部分卸载（`n_gpu_layers => N`，首选）/ 跨卡
（`instances => [[0,1]]`，拿并发换容量）/ 换量化档。加载前有一次**粗检**，明显
装不下时报 `{error, {model_too_large, _}}` 并列出出路——但绝不用它自动决定
`n_gpu_layers`（算错就是静默少卸载几层）。不做这一步的话，装不下的表现是 llama
OOM → 回落 → **整体退回纯 CPU**。

**批量 embed** `embed_batch/2` ✅：llama 后端一次 decode 喂多条序列，逐条返回结果。
`bitcask_embedder` 的可选回调，provider 没实现就退化成逐条，调用方无感。池化时一批
会拆开并行打到各 worker。⚠️ `n_ctx` 必须乘上 `batch_size`（llama 的 n_ctx 是所有
序列共享的总预算），否则一开批量就把每条文本的可用长度悄悄缩小 N 倍。
**默认不开**：实测短文本 7.0x / 中文本 2.9x，但测量时机器有外部满载进程，安静机器
上倍数会小得多，长文本档无可信数据——开之前在自己的硬件上量。

构建期 SDK 探测脚本 `scripts/detect-llama-backends.sh`：CMake 只会说"没找到"，它说
**缺哪个包**并给出带上探到的开关的构建命令。

> **Vulkan 构建路径已实测**：开发机上有 Vulkan SDK（1.4.309），AUTO 探到并编入，
> `priv/libggml-vulkan.so` 落地。因为这台机器没有 GPU，`gpu_status/0` 给的是
> `no_gpu_device` 而不是 `cpu_only_build`——**这正是构建期/运行期分离要区分的那两
> 种情况，本次是用真实数据验证的**。
>
> ⚠️ **CUDA 编译与真实 GPU 运行路径仍未实测**（开发机无驱动无 toolkit，Vulkan 也
> 只是编出来、没有卡可跑）。已验证：两条 AUTO 探测分支、构建期宏注入与自报、无
> GPU 时的诚实诊断、`backend`/`gpu_index`/`split_mode` 的校验与错误路径。

### 后续候选 ⚠️

- **`bitcask_embedder` 加可选 `close/1` 回调**（按 gate）：让 `bitcask:close/1`
  能自动释放 `{Provider, Cfg}` 那条路建的 ctx。当前用进程形态规避，动核心 API
  的收益不明显。
- **`instances => auto`**（按 gate）：现在必须写明用哪几张卡。按机器上的卡数自动
  开池需要先决定"一个库该不该默认占满整机的 GPU"，以及池内某个 worker 起不来时
  是否放宽"整个 application 死"那条策略。两个都是策略问题，不是实现问题。
- **批量的可信定标**（按 gate）：现有数字是在有外部负载的机器上测的，比值被放大，
  长文本档没有可信结论。安静机器上重测一遍才能给出该不该默认开的建议。
- **HTTP 档的原生批量**（按 gate）：openai 的 `/v1/embeddings` 接受数组，接上就是
  一次请求多条。现在退化成逐条 HTTP。
- **多卡实测**（按 gate）：池的机制已用 mock provider 测透，但**多卡上的真实 GPU
  行为没跑过**（开发机无卡）。`gpu_index` 越界检查、卡组的 `mp.devices` 传递、
  `split_mode` 的实际效果都只验证了参数路径。
- **ROCm / SYCL 后端**（按 gate）：ggml 都有，与 Vulkan 同一个接法。要不要加取决于
  实际部署里有没有这类卡。

---

## 5.0.0 落地

### libbitcask 升级到 v5.0.0 ✅

submodule 由 v4.1.0 升至 **v5.0.0**（64 位时间戳 flag-day：`tstamp` / `expiry_at`
全链路 u32 → u64，Y2038 前瞻；`SOVERSION` 4 → **5**，ABI + **盘上格式**双破坏）。
本仓库版本同步对齐 5.0.0。

盘上格式全面换代：data record header 23B → 27B、DocValue v3 → v4、hint `BCH3` →
`BCH4`、keydir 快照 BCKS v2 → v3、`bitcask.meta` v3 → **v4**（门禁：旧 u32 纪元库
干净拒开，绝不按新偏移静默读坏旧字节）。随库修复极大 `expiry_secs` 下 u32 求和
回绕致全库 key 误判过期。NIF 适配仅 2 处（迭代器 `tstamp` 返回改
`enif_make_uint64`）；对 Erlang 调用方无 API 变更。

> ⚠️ 存量旧库迁移：上游统一迁移工具 `bitcask_migrate tstamp64 <src> <dst>`
> 非破坏性离线迁移（`detect` 子命令先探测纪元），无须重灌数据。

---

## 4.0.0 落地

### libbitcask 升级到 v4.0.0 ✅

submodule 由 v3.1.0 升至 **v4.0.0**（S32 向量双引擎 + S29-11-②④ AVX2 int8 内核 +
磁盘段 UB 审计；`SOVERSION` 3 → **4**，`bitcask_options_t` 布局变更 ×2 = ABI 破坏，
**源码级完全向后兼容**——NIF 重编即正确）。本仓库版本同步对齐 4.0.0。

新增 `open/2` 选项 `{vector_engine, hnsw | ivfrq | diskann}`（向量双引擎，建库时
选定并持久化进 `bitcask.meta`）、向量引擎调优选项（`hnsw_m` / `hnsw_ef_construction` /
`hnsw_build_nav_int8` / `vector_rebase_min_docs` / `vector_ivf_nlist` / `vector_ivf_nprobe` /
`vector_diskann_r` / `vector_diskann_l_build`）、`{auto_checkpoint_min_docs, N}`（崩溃恢复
重放窗口有界）。随库引入 IVF-RaBitQ-lite 引擎（100k/384d 查询 36.5µs、召回损失 ≤0.08pt）、
DiskANN 引擎（实验性）、AVX2 int8 点积内核（VNNI512→VNNI256→AVX2 分发，非 VNNI 机器全
int8 路径激活）、向量 ckpt 崩溃恢复有界（最坏 ~4.2M 条 → ≤320K 条）、HNSW `.qc8` 码字
mmap 化 + `clone_live` payload 外溢。`examples/` 增加 Wikipedia 检索库示例
（`wiki_hnsw` / `wiki_diskann` 双引擎对比）。

> ⚠️ ABI 破坏：soname `libbitcask.so.3` → `libbitcask.so.4`，下游须重新编译链接。
> 对 Erlang 调用方无破坏性 API 变更——未传新选项时行为不变（向量引擎默认仍 HNSW）。

---

## 3.1.0 落地

### libbitcask 升级到 v3.1.0 ✅

submodule 由 v3.0.0 升至 **v3.1.0**（S12 全库审计批次；`SOVERSION` 保持 **3**，
ABI 未破坏——向后兼容的功能新增）。本仓库版本同步对齐 3.1.0。

新增 `open/2` 选项 `{max_read_handles, unlimited}`（显式不限）、
`{auto_compact_dead_ratio, R}`（索引模式 reducer 线程内自动 compaction，posting list
内存随 churn 有界）、错误原子 `closed`（对已 close 的 handle 调用返回 `{error, closed}`）。
随库引入 read 句柄默认上限（`{max_read_handles, N}` 默认 `0` 由「不限」改为按
`RLIMIT_NOFILE` 自动推导）、`bitcask.meta` v2 → v3 加 CRC32、field.schema 加 FSCH v1
格式头 + CRC、C API 批量检索 ×3 + `parallel_scan` + `BITCASK_ERR_CLOSED`、`-Werror`
库构建护栏。

> ⚠️ 盘上格式前向不兼容：`bitcask.meta` 升至 v3（加 CRC32）。本版写出的库不能被
> 旧 3.0.0 打开；反向兼容——本版能读旧库（v2 meta 兼容读、legacy field.schema
> 自动升级为 FSCH v1）。升级请单向进行。

---

## 3.0.0 落地

### libbitcask 升级到 v3.0.0 ✅

submodule 由 v1.1.0 升至 **v3.0.0**（libbitcask 三套版本号统一：CHANGELOG = 库
`VERSION` = C API = `3.0.0`，`SOVERSION` 1 → 3）。本仓库版本同步对齐 3.0.0。随库
引入的 v1.2.0 引擎能力对图工作负载尤为相关：**`Cask` handle 多线程安全**（同一句柄
可被多 actor 共享：写路径内部串行化、读/搜索并发、`close()` fail-fast）、
**`parallel_scan` 全表并行扫描**（analytics / export / reindex，正合并行整图加载）、
批量检索、异步索引 MapReduce 流水线；meta 格式升至 v2。

消费侧适配（破坏性）：**移除运行期 `bitcask:set_synonym_map/2`**，同义词词典改为
`open/2` 的 open-time 不可变选项 `{synonym_file, Path}`（对齐 libbitcask
`CaskOptions::synonym_map`：开库一次性加载、构造后不可变 → 并发查询天然安全）。
NIF 重新编译链接（ABI `SOVERSION` 1 → 3）。

> ⚠️ ABI 破坏：soname `libbitcask.so.1` → `libbitcask.so.3`，下游须重新编译链接。
> 盘上格式：KV data/hint（meta v2）兼容；同义词运行期更换需重开库。

---

## 2.2.1 规划

### libbitcask 升级到 v1.1.0 ✅

submodule 由 v1.0.0 升至 v1.1.0（当时 libbitcask 最高版本；现已升至 v3.0.0，见上节）。对图工作负载（读多、
整图加载密集）的收益：稠密扁平 keydir（`ankerl::unordered_dense`，海量 key 省内存）、
256 分片锁改 `std::mutex`（多图并行加载不互锁）、单 `pread` 取值（整图一次 syscall）、
fstats 无锁发布 + `thread_local` scratch 复用。

消费侧适配：`SynonymMap::load_from_file` 改 `[[nodiscard]] bool`（NIF 失败回 `{error,
load_failed}`）；`StatusInfo::index_errors` 经新 `bitcask:index_errors/1` 透出（异步索引
漂移计数）；根 CMake 补 `unordered_dense` 依赖软链。

> ⚠️ v1.1.0 改了盘上搜索格式（`search.ckpt` / 倒排 v6 / 外存向量），v1.0.0 建的索引
> 目录需重建；KV data/hint（meta v2）不变。

### 图处理层（libbitcask 存储 + Erlang 执行）✅

> 设计文档：[`doc/graph-layer-design-zh.md`](doc/graph-layer-design-zh.md)

以 libbitcask 为单一存储、Erlang 为执行层的简单图处理方案。核心约束：**一个图整体
序列化进一个 value**（CSR 格式），libbitcask 只做持久化与并发加载，遍历 / 计算在 BEAM
内存完成、热路径零 bitcask 访问。

- **CSR 盘上格式**：`xadj` 行偏移 + `adjncy` 邻居数组 + etype/vprops/eprops 侧表，全小端；
  BEAM 二进制零拷贝切片直接遍历。
- **执行模型**：owner gen_server 持有物化图（CSR + 写 overlay）；读 / 算纯内存，写进
  overlay、批量检查点折叠回写。
- **Erlang 特性**：并行度在「图之间」（N 图 = N actor）、崩溃隔离、单写多读对齐 bitcask、
  Pregel/BSP（顶点=进程、边=消息）、LRU 逐出 + MVCC 一致快照。
- **边界**：单图须整张进内存（`value_too_large` + LRU 封顶，超大图分区成多 value）；
  写放大在图粒度（靠批量检查点摊薄）。读多写少 / 批量构建场景最适配。

阶段：P1 CSR 编解码 + owner + CRUD → P2 内存遍历 → P3 overlay 压实 + LRU + MVCC →
P4 Pregel/BSP + 样例算法 → P5 入边转置 + 边属性 + 顶点向量混合检索。

---

## 2.2.0 规划

### libcask 独立库拆分 ✅

> 可行性评估：[`doc/libcask-extraction-zh.md`](doc/libcask-extraction-zh.md)

将 C++ 非 NIF 核心（`cpp/src/` + `cpp/include/`，24 源文件 + 45 头文件）独立为
`libcask.so` / `libcask.a`，当前 Erlang 项目仅保留 NIF 胶水层（`cpp/nif/`）依赖之。

现有架构已具备分离条件：
- C++ 核心零 `erl_nif.h` 依赖、零 `enif_*` 调用
- 构建系统已模块化（11 个 static library，`cpp/CMakeLists.txt` 支持独立构建）
- 耦合单向且极薄（NIF → C++，无反向调用；唯一桥接是 `CaskHandle { unique_ptr<Cask> }`）

**路径 A（C++ API 直出，推荐）**：导出 C++ 类，NIF 层直接 include，改动最小，保留 LTO。
**路径 B（C API 封装）**：额外 `extern "C"` wrapper，ABI 稳定，支持跨语言绑定（Python/Rust）。

### V7+ 向量优化 ⚠️

> 行业对标分析：[`doc/vector-ondisk-quant-design-zh.md`](doc/vector-ondisk-quant-design-zh.md) §9-11

- **DiskANN 式大规模架构**：V3.5 BCVS 快照已给 46× 加载提速；100M+ 规模需
  DiskANN 式「外存图 + PQ 粗筛 + SSD 精排」分层架构。
- **Product Quantization (PQ)**：离线训练管线是独立项目；V6.4.1 已留 seam。
- **Vamana / robust prune**：DiskANN 建图算法（α 参数 + robust prune）研究储备，
  磁盘友好性分析详见 §11。
- **HNSW 外存 mmap**：100M+ 规模问题是另一类设计（图结构分页 mmap + SSD 友好布局）。

---

## 2.1.1 已落地

围绕**向量库的内存 / 磁盘瓶颈**、**读路径**与**恢复持久化**的一组优化（P5–P15）。

### P5 — HNSW int8-only 内存模式 ✅

> 详细设计：[`doc/hnsw-int8-only-design-zh.md`](doc/hnsw-int8-only-design-zh.md)

**问题**：dot 模式下 HNSW 内存里同时存 f32 `vecs` + int8 `qcodes`（int8 为 VNNI
提速、反而 +25% 内存）；P3 落盘 int8 只省磁盘、不动内存——向量库的真正墙是内存。

**方案**：丢掉常驻 f32，建图 / 精排都走 int8（查询侧也量化、用 VNNI int8×int8），
opt-in `{vector_inmem_int8, true}`，可与 P3 落盘 int8 组合（盘 + 内存都省）。

**实测收益**（合成簇 dim=2560，`hnsw_test::Int8OnlyMemoryAndRecall`）：向量内存
**−80%（~5×）**，1M 向量 12.81 GB → 2.57 GB；代价 **recall@10 约 −3%**（1.0 → 0.9675）。

**子任务**：**P5a** ✅ `HnswConfig.inmem_int8` + NodeChunk 裁 vecs + 建图/查询/收缩全 int8 +
query 量化 + BCVS save/load 适配（盘仍存 f32）+ 非 VNNI 标量 int8 兜底；真实模式测试
`VectorQuant.Int8OnlyRealModeRecallAndRoundtrip` recall@10=0.9725、save/load round-trip 一致，
411 测试通过。**P5b** ✅ open 接线 `{vector_inmem_int8}`（NIF + erl 透传）+ meta offset[10] 持久化 +
重开一致校验 + kL2 拒绝 + 与 P3 落盘 int8 正交可组合；3 个端到端测试（open/search/reopen、
kL2 拒绝、quantized 组合）。**P5c** ✅（部分）召回 gate `Int8OnlyRecallGate_Dim2560`（真实
inmem_int8 + query 量化，dim=2560 recall@10=**0.9650**、红线 0.90）+ 默认定为 opt-in（默认
f32+int8）+ 用户文档（`bitcask.erl` 选项注释）；**未完**：真实 qwen3 语料复测须部署侧做
（CI 无 embedding 端点，合成簇代理）。415 测试通过。
**红线**：默认仍 f32+int8（召回优先）；int8-only 面向内存受限 / 大规模 opt-in。

### P6 — sealed 文件 mmap 只读路径 ✅

> 详细设计：[`doc/sealed-mmap-read-design-zh.md`](doc/sealed-mmap-read-design-zh.md)

**目标**：对 sealed（封口不可变）data 文件 mmap 只读——**零拷贝 + 免 pread syscall**，
直接用 OS page cache、**不双缓存**。**active 文件永远 pread**（append 增长对 mmap 不友好：
映射定长、SIGBUS-past-EOF、重映射移址）。

**子任务**：
- **P6a** `DataFile` sealed mmap 模式：sealed 首读 mmap 整文件、`read` 返回映射 span；
  active / 超额回退 pread；mmap 后 close fd（顺带缓解 read_files_ 的 fd 累积撞 ulimit）。
- **P6b merge 生命周期（重点）**：unlink 旧文件时**不立即 munmap**——靠
  `shared_ptr<DataFile>` 引用计数**延迟 munmap**（在途读者续命，Linux 上 unlinked-but-mapped
  仍可读）；merge 新文件 / active roll 成 sealed 后，下次经 `read_file` 懒加载重新 mmap。
- **P6c** `GetResultView` 持映射引用 + `mmap_limit`（文件数 / 字节）+ pread 兜底 + 32 位禁用。

**范式**：LevelDB SSTable——不可变文件 + 引用计数延迟删除 + mmap 限额 + pread 兜底。
**不变量**：只 mmap sealed（merge 只 unlink、绝不原地 truncate → 无 SIGBUS-on-truncate）。

**状态 ✅（核心落地）**：**P6a** DataFile sealed mmap（`read_mmap` 零拷贝、`DataFile::open`
新增 `mmap_enabled`、自定义 move/dtor 管 munmap、32 位 `sizeof(void*)<8` 禁用、纯 fold 的
recovery/merge/迭代器 pin 传 `mmap_enabled=false`）；**P6b** merge unlink 延迟 munmap——
复用现有 `shared_ptr<DataFile>` 引用计数（无新锁），测试 `P6MmapViewSurvivesMergeUnlink`
持 view 跨 merge unlink 仍读、**ASAN(address+leak)全过**；**P6c** `GetResultView` 持映射
`shared_ptr` 锚定 + 32 位禁用 ✅。416 测试通过。
**偏差（诚实）**：① **不 close fd**——保留 fd 让 `read()`/`fold()` 的 pread 在 mmapped 句柄上
可用（迭代器/恢复要走）；fd/mmap 回收（驱逐时随句柄析构 close+munmap）**已由 P9 兜住**。
② `mmap_limit` 按映射**数**的上限**已由 P9 `max_read_handles` 实现**（每句柄 = 1 fd + 可能 1 映射）；
按**字节**的上限仍未做（备选）。

### P7 — 派生值 compute cache（建在 mmap 之上）⚠️ 备选

> 详细设计：[`doc/derived-compute-cache-design-zh.md`](doc/derived-compute-cache-design-zh.md)

**定位**：有 mmap 后 LRU **改定位**——只缓**派生 / 解码后、recompute 有真实 CPU 成本**
的结果，**不缓 raw bytes**（mmap + page cache 已最优、缓了是双缓存 + 跟内核抢 RAM）。
省的是 recompute、不是 I/O（同 LevelDB：mmap 取字节 / block LRU 缓解压块）。
纯 KV value decode 近零 → **不缓**。

**规则**：按**逻辑键（key/ord）**缓（跨 merge 内容稳定）；存 owned
`shared_ptr<const Derived>`（**绝不存 mmap span** → 与 munmap/merge 解耦、无 UAF）；
byte budget + shared_mutex；put/delete 按键失效、merge 不失效。
**首批目标**：① highlight 的 NFKC + 分词 offsets（现每次高亮重算）；
② int8→f32 dequant 向量。
**gate**：仅当 derive 成本 ≫ mmap 访问才上。**依赖 P6**。

### P8 — HNSW merge rebuild 阈值门控 ✅

> 详细设计：[`doc/hnsw-merge-gate-design-zh.md`](doc/hnsw-merge-gate-design-zh.md)

merge 现**无条件全量重建 HNSW 图**（重插所有 live 向量）；但查询已用 `is_live` 过滤死
节点 → 重建**纯物理压实、正确性不依赖**。改为**按死节点比例门控**：死占比 < 阈值跳过
重建，≥阈值才全量重建。与 **P2（BM25 不重分词）同范式**——向量库 merge 的主要 CPU 省下来。

### P9 — read_files_ fd 预算 LRU ✅

> 详细设计：[`doc/read-handle-lru-design-zh.md`](doc/read-handle-lru-design-zh.md)

`read_files_`（只读文件句柄）每文件常驻一个 fd、**无淘汰** → 大库读过多文件**撞 ulimit**。
改为按 LRU / 数量上限淘汰只读句柄（与 P6「mmap 后 close fd」互补）。

**状态 ✅（落地）**：`read_files_` 值改为 `ReadHandle{shared_ptr<DataFile> + atomic atime}`；
命中在共享锁下置 `atime`（近似 LRU，零锁升级）；miss 在独占锁下 `try_emplace` 后
`evict_read_handles_locked()`——超 `max_read_handles` 时淘汰 `atime` 最旧的**空闲
(use_count==1)** 句柄，**在途读者持 shared_ptr 续命**（fd/mmap 随最后引用析构才释放，同
O10/merge-unlink）。选项 `{max_read_handles, N}`（0=不限，NIF + erl 透传）。**一并兜住 P6
延后的 fd 回收 + mmap 数上限**：每个缓存句柄 = 1 fd（+ 可能 1 映射），cap 即同时限两者。
测试 `P9ReadHandleCapEvictsAndRereads`（>cap 文件后常驻 ≤ cap、淘汰后重读正确、cap=0 不限），
420 测试通过 + ASAN 全过。**偏差**：`mmap_limit` 按**字节**的上限未做（按句柄数的 cap 已足够
控两者；字节级留备选）。

### P10 — search_hybrid 两路并行 ✅

> 详细设计：[`doc/hybrid-parallel-design-zh.md`](doc/hybrid-parallel-design-zh.md)

`search_text` → `search_vector` 现**串行** + RRF 融合；两路相互独立 → 丢线程池**并行**，
hybrid 查询延迟近减半（注意 filter / 缓存共享的并发安全）。

### P11 — merge I/O 顺序优化 ✅

> 详细设计：[`doc/merge-io-tuning-design-zh.md`](doc/merge-io-tuning-design-zh.md)

merge 顺序读旧文件 / 写新文件，无 readahead 提示。加 `posix_fadvise(SEQUENTIAL/WILLNEED)`
+ 大缓冲，降低 merge 的 IO stall（低成本）。

### P12 — meta_blobs_ 内存按需 / 有界 ⚠️ 备选

> 详细设计：[`doc/meta-blob-residency-design-zh.md`](doc/meta-blob-residency-design-zh.md)

`Index::meta_blobs_` 每 ord 一份 meta blob **全量常驻**（filter 求值用）；可改有界 LRU 或
按需读盘。**但 filter 在搜索热路径，按需读盘会拖慢 → 需 gate**，故备选。

### P13 — open 时按需后台 merge（小文件收拢）✅

> 详细设计：[`doc/open-merge-design-zh.md`](doc/open-merge-design-zh.md)

**根因**：每个 read_write 会话首次写都建一个**新** active 文件（file_id 单调、不回退、
不重开旧文件续写——by design）；多次「open-写-close」累积大量小文件。
**校正**：合并**不提速单次 get**（keydir O(1)）；真正收益是 **open 成本 / fd / mmap 友好 /
死空间回收**。
**方案 A（承诺）**：open（read_write）后按 `needs_merge`（复用 `small_file_threshold` 等
阈值）门控、**后台**触发 merge（merge_worker / dirty 调度器，**不阻塞 open**），收成少数
sealed + 新 active。复用现有 merge 全套，主要是触发接线 + `{merge_on_open, off|background}`
选项。**否决**无条件/同步 merge-on-open（O(data) 启动、毁掉快照快开）。
**方案 B（备选）**：open 复用上一个未满 sealed 文件续写——从源头止小文件，但需 un-seal、
破坏 sealed 不可变（与 P6 冲突）、invasive，故仅备选。

### P14 — 恢复持久化统一：checkpoint 命名 + 单趟尾部回放 ✅

> 详细设计：[`doc/recovery-unified-checkpoint-design-zh.md`](doc/recovery-unified-checkpoint-design-zh.md)

**三个痛点**：① `.snap` 后缀盖在裸 checkpoint（keydir/index/hnsw）与 checkpoint+WAL（bm25）
两种契约上，命名混乱；② **双重日志**——一次搜索 put 既写 data 文件（本身已是带 ord 的全量
WAL），又追加 bm25 WAL，写放大 2；③ **重用率 ≈ 0**——checkpoint 仅 close/merge 落盘，崩溃后
成对门按最弱环判定 → 全量 fold，bm25 WAL 形同白记。

**方案（路线 A）**：认 **data 文件为唯一 WAL**，所有派生索引统一「周期性 checkpoint + open 单趟
fold 尾部回放」。后缀编码契约（`.ckpt`/`.wal`/`.seg`/`.manifest`），`index→docmap` 去歧义。
回放下界取**各块水位最小值 wm_min**，一趟 fold 同时喂 keydir/docmap/bm25/hnsw——成对门从
「最弱环→全量 fold 悬崖」降为「从 wm_min 多读点尾巴」，这是重用率从 0 起来的机理。

**子阶段**：**P14a** ✅ 纯重命名 + 契约文档化（零格式/逻辑变更；旧名不再读——可重建，
升级后首次 open 一次全量 fold、close 落新名；410 测试通过）；
**P14b** wm_min 单趟回放（替双轨 + 消门悬崖）；**P14c** 周期性 checkpoint（`checkpoint_interval`
+ worker 静止窗口）；**P14d** 摘 bm25 WAL（profiling 驱动决定是否留 `terms` 纯缓存）；
**P14e** 搜索快照收编为单个分段 `search.ckpt`（逐段 CRC + 页脚目录 + 段级脏位复用 + docmap/meta/terms
可选加速缓存，缺失从 keydir⋈postings+fold 派生）+ 代际 `search.ckpt.prev`（与 cellar 全面收敛于路线 A；见设计文档 §10）。
**收益**：命名契约清晰 · 写放大 2→1 · 文件数大降（搜索多文件→1）· 损坏隔离到段 · 崩溃后不再全量 fold。

### P15 — 字节序统一（全盘小端）+ 大端目录迁移 ✅

> 详细设计：[`doc/format-zh.md`](doc/format-zh.md)（字节序说明 + §十 checkpoint 格式）、
> [`doc/migrate-le.md`](doc/migrate-le.md) / [`doc/migrate-le-en.md`](doc/migrate-le-en.md)（迁移工具）。
> 路线图外插入项（从字节序审计衍生），已落地。

**问题**：盘格式字节序**二分**——核心 record/hint/field.schema/墓碑 shadow 为**大端**（对齐
legacy Erlang `<<X:N>>`），而向量/各 snapshot/meta/bm25 为**小端**。大端字段每次从 mmap 读都要
bswap，与 P6 零拷贝方向相悖；且"靠 native memcpy 碰巧 LE"非显式规范。

**方案（flag-day）**：全盘统一**小端**（LE-only 主机原生零转换 + mmap 零拷贝友好），不留读大端
路径；旧大端目录**干净拒绝**而非静默读坏；提供离线迁移工具。

**子任务**（均已落地，419 测试通过 + ASAN/Erlang 编译过）：
- **P15a** ✅ 全盘 LE:`codec` 的 `be_*→le_*`(record + hint)、`data_file`/`hint_file` 手写字节序读点、
  `field.schema` NameLen、墓碑 v2 shadow file_id、`format.hpp`/`format-zh.md` 规范注释;golden 测试翻 LE
  （含修复 hint fold 在 LE 下漏读 key_sz 的真 bug）。
- **P15b** ✅ 护栏:`bitcask.meta` version `1→2`,旧 v1(大端)目录 open 时干净报错"需重建"
  （`LegacyV1MetaRejectedCleanly`）。
- **P15c** ✅ 迁移工具 `migrate_le <src> <dst>`（非破坏性;data 重编码 + hint 重生成 + meta v1→2 +
  field.schema + shadow 翻转;ckpt/seg/wal 不迁移、首开重建）+ 中英文档 + round-trip 测试。

**收益**：字节序规范统一显式（`static_assert` 守护）· mmap 读无 bswap · 旧目录 fail-loud 不静默坏 ·
有迁移路径不丢数据。**红线**:旧大端数据须迁移或重建,新代码不读 v1。

---

## 开发顺序（2.1.1，重拍）

> P 编号是**标识符不是顺序**。下列波次按**依赖 + 风险 + 收益**排，波内可并行，
> ⚠️ 备选项一律压到其依赖满足之后、波次末尾。

- **W0 清债（立即，零风险）**：**P14a** 纯重命名——独立可上线，当场消除命名混乱，不阻塞任何项。
- **W0.5 字节序统一（跨切面，已落地）**：**P15** 全盘小端 + meta v2 护栏 + `migrate_le`。逻辑上应早于 W2
  （mmap 零拷贝要求盘序=主机序），本轮已随手完成；旧大端目录走迁移/重建。
- **W1 内存墙（独立 headline）**：**P5** HNSW int8-only（向量内存 −80%，已实测，无外部依赖）。
- **W2 读路径地基**：**P6** sealed mmap → **P9** read fd LRU（P6「mmap 后 close fd」的互补，紧随）。
- **W3 恢复核心**：**P14b** 单趟回放——fold sealed 文件时直接吃 W2 的 mmap；消门悬崖、抬重用率。
- **W4 merge**：**P8** HNSW merge 门控 + **P11** merge I/O（同 merge 主题、捆绑）→ **P13** open 后台 merge。
- **W5 周期 checkpoint + 去 WAL**：**P14c** 周期 checkpoint（触发点对齐 W4 的 merge/open-merge 时机）
  → **P14d** 摘 bm25 WAL（依赖 P14b 回放已验证）。
- **W5.5 搜索快照收口**：**P14e** 多文件搜索 checkpoint → 单个分段 `search.ckpt`（逐段 CRC + 页脚目录
  + 段级脏位复用）+ 代际 `search.ckpt.prev`。排在 W5 之后——它要在「P14b 分段载入语义 + P14c 写流程
  + P14d 无 WAL」都就位后做收口（脏位复用挂在 P14c 的写流程上、去 WAL 后段集才稳定）。
- **W6 查询（顺序无关，可浮动）**：**P10** search_hybrid 两路并行（独立，任意波次可插）。
- **W7 备选（gate 后置）**：**P7** 派生值 compute cache（依赖 P6）⚠️ · **P12** meta_blobs 有界（filter 热路径）⚠️。

**关键依赖边**：P7→P6 · P9↔P6 · P14b 受益于 P6 · P14c 对齐 P8/P13 的 merge 时机 · P14d 依赖 P14b ·
**P14e 依赖 P14b（分段载入）+ P14c（段级脏位复用写流程）+ P14d（去 WAL 后段集稳定）**。
**为何 P14 拆多段**：P14b（恢复模型）须先于 merge 改动，给 P8/P13 一个干净的回放语义；
P14c（周期 checkpoint）须**后于** P8/P13——它把 checkpoint 触发挂在 merge/open-merge 静止点上；
P14e（单文件收口）放最后——格式收编依赖前三者就位，且它会再做一次 flag-day（旧多文件名不再读，可重建）。

---

## 已落地（2.1.0，持久化优化 P1–P4）

- **P1** Hint 写缓冲（写路径 syscall 减半）
- **P2** merge 不重分词（compact 替代 rebuild_index）
- **P3** 向量落盘 int8 量化（opt-in `{vector_quantized}`，~4× 磁盘）
- **P4** 单写者组提交（`{sync_strategy,{puts,N}}`）

详见 [`CHANGELOG.md`](CHANGELOG.md)。
