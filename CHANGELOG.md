# 更新日志（中文）

English version: [`CHANGELOG_EN.md`](CHANGELOG_EN.md)。
格式大致遵循 [Keep a Changelog](https://keepachangelog.com/)。

## [5.1.0] — 2026-08-06

**本地嵌入后端（llama.cpp / ggml）+ 独立 embedder 进程。**

> 与此前每一个版本不同，本次**不涉及 libbitcask 升级**：submodule 仍为 v5.0.0，
> 无 ABI 变更、无盘上格式变更。不打开本后端时，构建产物与 5.0.0 **一字不差**
> ——不拉子模块、不加 CMake 开关、不多任何 target。

### 新增

- **本地嵌入后端**（`bitcask_embedder_llama` + `bitcask_llama_nifs`），在 BEAM
  进程内用 llama.cpp 直接算 embedding，不经 HTTP 端点。产物是**独立的第二个
  NIF** `priv/bitcask_llama.so` + 一组 vendored ggml/llama 共享库（含 14 个运行时
  按 CPU 微架构 `dlopen` 的变体）；核心 `bitcask_cpp.so` 不链接任何 ggml 符号。
  **默认不构建**，`BITCASK_WITH_LLAMA=1 rebar3 compile` 打开。
  新增 submodule `third_party/llama.cpp`（tag `b10257`）。
- **独立 embedder 进程** `bitcask_embedder_server`（gen_server）+
  `bitcask_embedder_proxy`（provider）。`open/2` 的 `{embedder, _}` 现在也接受
  进程引用（`pid()` / 注册名 / `{global,_}` / `{via,M,N}`）：**多个 cask 共用
  一份权重**，生命周期跟着进程走（`terminate/2` 释放）。可由 `bitcask_sup` 按
  新增的 application env `{embedder, #{name, provider, config}}` 启动；不配就
  不启动。
- **GPU 后端：CUDA（NVIDIA）+ Vulkan（AMD / Intel，也能跑 N 卡）**，各一个开关，
  语义一致：`BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN` = `AUTO`（默认，探测到
  SDK 就编入）| `ON`（硬要求）| `OFF`。两个可以同时开。
  ⚠️ Vulkan 的 AUTO 必须把 loader / `glslc` / SPIRV-Headers **三个**都确认到位再
  开——ggml-vulkan 里那两个 `find_package` 都是 `REQUIRED`，只探到一个就打开会
  **直接把构建炸掉**，而 AUTO 的意义是"没有就安静地不编"。
  CUDA 运行时（cudart/cublas/cublasLt）默认随包平铺进 `priv/`
  （`BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME`）——服务器产品，体积不是约束，换掉的是
  "目标机缺 libcublas → ggml 静默跳过后端 → 降级纯 CPU"这一整类不报错的故障。
  CUDA 架构覆盖 Maxwell..Blackwell，不收窄成 native。
- **运行期由 Erlang 自己决策用哪个后端**，不需要按机器改配置、也不需要脚本：
  `model_load` 新增 `backend => auto`（默认）`| cuda | vulkan | cpu`，`auto` 按
  **CUDA > Vulkan > CPU** 挑第一个**真的有 GPU** 的后端族；`n_gpu_layers` 默认
  也是 `auto`（有 GPU 就全卸载，没有就 0）。未知取值报 `{error,{bad_backend,_}}`
  而不是静默当成默认值。
  ⚠️ **只选一族是正确性要求，不是策略**：CUDA 与 Vulkan 同时编进包里时，两者会
  **各自枚举同一张物理卡**（一张 4090 = `CUDA0` + `Vulkan0`）。
  `llama_model_params.devices` 为 NULL 时"使用全部可用设备"，llama 会把同一张卡
  当成两张去切分模型层——不报错，只是显存重复占用 + 莫名其妙的慢或 OOM。
- **多卡：默认只用一张，走数据并行**。新增 `gpu_index`（默认 `0`）与
  `split_mode`（默认 `none`）。
  ⚠️ llama 的 `split_mode` 默认是 `LAYER`（把层切到所有卡上）。对嵌入模型那是个
  反优化：0.6B 权重一张卡装得下，切开只多出跨卡传输，还把 N 张卡的并行浪费在
  **一条串行**的请求路径上。嵌入要的是数据并行——按 `backend_info/0` 的设备表开
  N 个 embedder 进程、各绑一张卡。`gpu_index` 越界报 `{error,{bad_gpu_index,_}}`，
  不静默退回 CPU（那会让整池 worker 挤在 CPU 上没人发现）。
- **构建期 / 运行期分离诊断**：构建期事实（编没编 CUDA / Vulkan、toolkit 版本、
  架构列表）烧进 `.so` 由 `build_info/0` 自报；运行期事实由 `backend_info/0` 给
  （设备表带 `type` / `backend` / 显存）；`gpu_status/0` 把两者对到一起产出
  `ok` / `cpu_only_build` / `no_gpu_device` / `backend_not_initialized`。
  只看运行期的话，"0 个 GPU"分不清是包里没编 GPU 后端（要重新构建）还是机器没
  驱动（要装驱动）。回落原因也**按请求的那一族**判——包里编了 Vulkan 没编 CUDA
  而你要 `cuda` 时，说"有 GPU 后端但没设备"是错的。
- **构建期 SDK 探测脚本** `scripts/detect-llama-backends.sh`：CMake 只会说
  "没找到"，它说**缺哪个包**并给出建议的构建命令（自动带上探到的
  `-DBITCASK_LLAMA_CUDA=ON` / `-DBITCASK_LLAMA_VULKAN=ON`）。
  ⚠️ 只是构建期工具——运行期的决策在 Erlang 侧完成，部署机上既不会有这个仓库也
  不会有 cmake。
- **`bitcask_embedder_util`**：把 `truncate_utf8` / `strip_partial` /
  `validate_dims` / `validate_limits` / `l2_normalize` / `mrl_truncate` 收成一份。
  此前 openai 与 anthropic 各有一份**逐字重复**的拷贝。
- 文档 `doc/local-embedding-zh.md` / `doc/local-embedding-en.md`。

### 变更

- ⚠️ **`bitcask:open/2` 不再吞掉 `application:start(bitcask)` 的失败**，改为返回
  `{error, {bitcask_app_start_failed, Reason}}`。从前那句 `catch
  application:start(bitcask)` 把返回值直接丢掉：配了 embedder 但模型路径写错时，
  application 起不来而 `open` 照常返回一个句柄，之后所有 `put #{text=>...}` 都
  没有向量，症状要等到检索结果不对才浮现，而那时候库已经写脏了。**这是有意的
  行为变更**：配置了嵌入模型就说明业务要用它，静默降级比当场死掉危险得多。
  （application 本来就能起来的部署不受影响。）
- `rebar.config` 的 submodule 初始化改为**路径限定**到
  `third_party/libbitcask`。裸的 `--init --recursive` 会把新增的
  `third_party/llama.cpp`（约 200 MB）拉给每一个使用者，包括绝大多数从不打开
  本后端的人。
- `backend_info/0` 的 devices 增加 `type`（`cpu`/`gpu`/`accel`），顶层增加
  `gpu_count`。
- application env 增加 `{embedder, undefined}`（默认不启动 embedder 进程）。

### 修复

- `.gitignore` 的 `priv/*.so` 匹配不到带 SONAME 后缀的产物
  （`libggml-base.so.0.18.0` 这类），补 `priv/*.so.*`——否则构建产物会被误提交。

### 实测（8 vCPU 容器，`Qwen3-Embedding-0.6B-Q8_0`，`n_ctx=512`）

查询（5 token）**33–35 ms**、文档（276 token）≈ 890 ms、模型加载 542 ms、
自检（近义 − 无关）0.59。

> ⚠️ `n_threads` 默认值必须用 `erlang:system_info(logical_processors_available)`
> 而不是 `logical_processors`：后者报**宿主机**核数、不认 CPU 亲和性掩码。实测
> 环境上两者分别是 8 和 128，按后者算出 126 线程比最优**慢 20 倍**，且没有任何
> 报错。

### 回归

- `rebar3 eunit` **100/100**（其中 17 条本地嵌入 + 17 条 embedder 进程；NIF 未
  构建时相关用例优雅跳过），`rebar3 xref` 干净。
- **Vulkan 构建路径已实测**：开发机上有 Vulkan SDK（1.4.309），AUTO 探测到并
  编入，`priv/libggml-vulkan.so` 落地，运行期 `build_info` 自报
  `vulkan_built => true`。因为这台机器没有 GPU，`gpu_status/0` 给出的是
  `no_gpu_device` 而不是 `cpu_only_build`——**这正是构建期/运行期分离要区分的
  那两种情况，本次是用真实数据验证的，不是推理**。
- ⚠️ **CUDA 编译与真实 GPU 运行路径未实测**（开发机无 NVIDIA 驱动、无 toolkit，
  Vulkan 也只是编出来、没有卡可跑）：已验证的是两条 AUTO 探测分支、构建期宏注入
  与自报、无 GPU 时的诚实诊断、以及 `backend` / `gpu_index` / `split_mode` 的
  参数校验与错误路径。

---

## [5.0.0] — 2026-07-17

**升级到 libbitcask v5.0.0**：submodule 由 v4.1.0 升至 **v5.0.0**（64 位时间戳
flag-day：`tstamp` / `expiry_at` 全链路 `uint32_t` → `uint64_t`，Y2038 前瞻；
`SOVERSION` 4 → **5**，ABI + **盘上格式**双破坏）。本仓库版本同步对齐为 **5.0.0**。
NIF 已重新编译链接，eunit 64/64 通过，另做盘上格式逐字节验证与旧库门禁冒烟。

> 本次升级对 Erlang 调用方**无 API 变更**：`fold_keys` 等返回的 `tstamp` 本就是
> 任意精度整数，只是自此可承载 > 2^32（2106 年后）的秒值。`{expiry_secs, N}` /
> `{expiry_grace_time, N}` 选项上游仍为 u32（时长而非时刻），不受影响。

> ⚠️ **盘上格式不向后兼容**：`bitcask.meta` v3 → **v4** 门禁——v5.0.0 打开旧
> u32 纪元库（meta v1/v2/v3）时**干净拒开**（当前 NIF 映射为 `{error, unknown}`，
> 上游把门禁错误包成 `kIo`/errnum 0，详情字符串未透出）。旧库**不必重灌**：
> 上游统一迁移工具 `bitcask_migrate tstamp64 <src> <dst>` 提供非破坏性离线迁移
> （只读 src、只写 dst；`detect` 子命令可先探测纪元）。

> 上游已补 v4.1.0 tag，此前按 commit `66924e3` 固定的说明作废；本次起 submodule
> 恢复按 tag 引用（v5.0.0 = `aaac44c`）。

### 变更（继承自 libbitcask v5.0.0）

- **64 位时间戳全链路**：C/C++ API + 盘上 data record header（23B → **27B**）+
  DocValue（v3 → **v4**，ExpiryAt 段 u32 → u64）+ hint（`BCH3` → **`BCH4`**）+
  keydir 快照（BCKS v2 → **v3**）+ docmap sidecar 等全部 tstamp 载体同步扩宽。
- **修复 u32 求和 wrap**：`expiry_secs` 极大（如 `0xFFFFFFFF`）时
  `tstamp + expiry_secs` 在 u32 域回绕，导致**全库 key 误判过期**；现全部在
  u64 域运算。
- **`now_sec_default()` 返回 u64**：不再把 `tv_sec` 截断到 u32。

### NIF 适配（本仓库）

- `nif_cask_iter.cpp` ×2：迭代器返回 `tstamp` 由 `enif_make_uint`（32 位，u64
  传入会静默截断）改为 `enif_make_uint64`——`fold_keys` / `iterator_next` 的
  `#bitcask_entry.tstamp` 自此 2106 年后仍正确。其余触点为零：写路径均走默认
  tstamp（源码级无感），Erlang 侧整数无位宽。

### 回归

- `rebar3 compile`（链接 v5.0.0）+ `rebar3 eunit` **64/64**。
- 盘上格式逐字节抽查：data header 27B / tstamp u64 / DocValue Ver=4 /
  meta `BCME 04` / hint `BCH4` 全部为新纪元格式。
- 门禁冒烟：v4.1.0 写出的旧库以 v5.0.0 打开被干净拒绝，不会按新偏移读坏旧字节。

---

## [4.1.0] — 2026-07-15

**升级到 libbitcask v4.1.0**：submodule 由 v4.0.0 升至 **v4.1.0**（Phase 5/6 深度审计：
8 项修复 + 4 项重构）。`SOVERSION` 保持 **4**、ABI 未破坏、盘上格式不变；本仓库版本
同步对齐为 **4.1.0**。NIF 已重新编译链接，eunit 64/64 通过。

> 本次升级对 Erlang 调用方**无任何 API 变更**：无新增/废弃 `open/2` 选项，无行为变更。
> 收益全部来自 C++ 核心库的稳定性修复——调用方无需改动代码，重编即得。

> ⚠️ 上游 v4.1.0 只有 release commit、**未打 tag**，submodule 按 commit `66924e3`
> 固定（`git describe` = `v4.0.0-32-g66924e3`）。上游补 tag 后可改回 tag 引用。

### 修复（继承自 libbitcask v4.1.0）

以下均为 C++ 核心库内部修复，对应 Erlang 侧的可观测症状：

- **进程级永久挂死**（P6-MEM-1 + P6-DL-1）：`IndexPool::submit` 先递增 `in_flight`
  再入队，队列内部分配抛 `bad_alloc` 即泄漏计数 → `flush()` 谓词永假；叠加
  `unregister_lib` 的无超时 `flush()`，`close/1` 卸载路径可**永久挂死** VM 调度器。
  修复双向闭合：submit 补偿 `dec_in_flight` 后重抛（根因）+ 拆卸路径 flush 有界 30s
  （兜底）。
- **持久性——hnsw 原子写无 fsync**（P6-DUR-1）：`save` / `save_vec_payload` /
  `write_bcq8` 三处 rename 前无任何 sync，**崩溃后旧好文件已被覆盖成半截文件**
  （向量索引损坏 → 重开全量重建）。现补 `fflush` + `fdatasync` 且两个返回值都检查。
- **资源泄漏**：`RowChunks::ensure_slot` 槽泄漏（P6-MEM-2）、`MmapSegment::open`
  fd 泄漏（P6-MEM-3）、`OrdSkipGuard` 析构抛出触发 `std::terminate`（P5-MEM-1）。
- **checkpoint 水位不一致**：`last_ckpt_ord_` 三处漏更新（P5-MEM-2）。

### 内部（无 Erlang 侧可见影响）

- `file_util.hpp` 归并整读 ×6 + 原子写 ×9 站点，fsync 纪律 4 套收敛为 1 套（T21）。
- Analyzer 双出口归并 + 3 例对拍测试（T22）；死代码清理（T25、P5-DL-3）。
- 上游验收：ASan 644/644 + TSan 全量零告警。

---

## [4.0.0] — 2026-07-13

**升级到 libbitcask v4.0.0**：submodule 由 v3.1.0 升至 **v4.0.0**（S32 向量双引擎 +
S29-11-②④ AVX2 int8 内核 + 磁盘段 UB 审计；`SOVERSION` 3 → **4**，
`bitcask_options_t` 布局变更 ×2 = ABI 破坏，**源码级完全向后兼容**——NIF 重编即正确）。
NIF 已重新编译链接；本仓库版本同步对齐为 **4.0.0**。

> ⚠️ 升级本身对 Erlang 调用方**无破坏性 API 变更**：现有 `open/2` 选项与检索
> API 原样可用，未传新选项时行为不变（向量引擎默认仍为 HNSW）。

### 新增

- **`open/2` 选项 `{vector_engine, hnsw | ivfrq | diskann}`（向量模式）**：透传
  libbitcask v4.0.0 的向量双引擎（S32）。`hnsw`（默认，内存图，≤ 数 M 向量档）、
  `ivfrq`（IVF-RaBitQ 磁盘档，10M-100M 推荐，要求 cosine/dot 度量）、`diskann`
  （Vamana 图，**实验性**，真实语料验证前不建议生产）。建库一次性选定并持久化进
  `bitcask.meta`；重开不符 → `{error, mode_mismatch}`；运行期不可切换（离线工具
  `vec_engine_migrate` 只改 meta，首次 open 全量 fold 重建，可回滚）。
- **`open/2` 向量引擎调优选项**（`0` = 各自动默认，一般无需设置）：
  `{hnsw_m, N}` / `{hnsw_ef_construction, N}`（HNSW 图出度 / 建图 ef）、
  `{hnsw_build_nav_int8, B}`（S29-11-②：HNSW int8 混合精度建图导航，默认 `true`
  ——插入 +29%~75%、recall@10 零损失；`false` = 全 f32 回退闸）、
  `{vector_rebase_min_docs, N}`（S32-M1：向量 ckpt 崩溃恢复重放上界，全引擎，
  默认 262144）、`{vector_ivf_nlist, N}` / `{vector_ivf_nprobe, N}`（ivfrq 簇数 /
  查询探簇数）、`{vector_diskann_r, N}` / `{vector_diskann_l_build, N}`（diskann
  邻接容量 / 建图 beam 宽）。
- **`open/2` 选项 `{auto_checkpoint_min_docs, N}`（索引模式）**：透传
  `CaskOptions::auto_checkpoint_min_docs`（S14-1/S31.5）。自上次 checkpoint 的文档
  增量 ≥ N 即异步落 keydir 快照 + search ckpt，崩溃恢复重放窗口恒 ≤ N。默认
  65536；`0` = 关。
- **`search_vector` 的 `Ef` 参数按引擎解释**：HNSW = candidate list 大小；ivfrq =
  查询探簇数 nprobe；diskann = 查询 beam 宽。
- **`examples/` Wikipedia 检索库示例**：用真实 Wikipedia dump 构建「BM25 +
  向量 + 混合 RRF」检索库，`wiki_hnsw.escript` / `wiki_diskann.escript` 分别
  演示两种向量引擎（只差 `vector_engine` 一个选项，逻辑共享于
  `wiki_common.erl`）。数据提取方案移植自 wiser-cpp：SAX 流式解析（十几 GB
  dump 不进内存）+ wiki 标记两遍清洗 + key=标题/正文进 text/标题进 title
  字段；open 配 embedder 后 put 自动 embed 导语。embedding 端点经环境变量
  `WIKI_EMBED_URL`（必填）/ `WIKI_EMBED_MODEL` / `WIKI_EMBED_DIM` 配置，
  不写死在代码里。用法见 `examples/README.md`。

### 修正

- **`put` doc map 的 `fields` 文档更正（×3 处）**：NIF 实际要求 **map**
  （`#{字段名 => 文本}`，非 map → `badarg`），但 `bitcask.erl` 注释与中英
  API 文档均误写为 `[{Field, Text}]` proplist——该路径此前无测试/示例覆盖，
  首个真实调用方（examples）即踩中。三处文档已对齐实现。

### 变更

- **`third_party/libbitcask` 子模块**：v3.1.0 → **v4.0.0**（soname
  `libbitcask.so.3` → `libbitcask.so.4`；上游后续重打 v4.0.0 标签追加了一次
  文档同步，指针已跟进至 `e814e4d`，无代码/ABI 变更）。随库引入：IVF-RaBitQ-lite 引擎
  （100k/384d 查询 36.5µs、召回损失 ≤0.08pt）、DiskANN 引擎（实验性）、AVX2 int8
  点积内核（VNNI512→VNNI256→AVX2 分发，非 VNNI 机器全 int8 路径激活）、向量 ckpt
  崩溃恢复有界（最坏 ~4.2M 条 → ≤320K 条）、HNSW `.qc8` 码字 mmap 化 +
  `clone_live` payload 外溢（merge 重建堆峰值不再翻倍）、磁盘段结构边界校验修复
  （可信盘模式 OOB 读 UB）、IO 循环 EINTR 重试、`parallel_for` 异常安全。引擎细节见
  [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **NIF 内部**：`search_layer.hpp` 拆分随迁——`nif_options.cpp` / `nif_helpers.cpp`
  改 include `search_config.hpp`（libbitcask v4.0.0 已删除旧头）。
- **构建**：根 `CMakeLists.txt` 版本注释对齐 v4.0.0；`bitcask.app.src` `vsn`
  3.1.0 → 4.0.0。

## [3.1.0] — 2026-07-01

**升级到 libbitcask v3.1.0**：submodule 由 v3.0.0 升至 **v3.1.0**（S12 全库审计批次；
`SOVERSION` 保持 **3**、ABI 未破坏——向后兼容的功能新增）。NIF 已重新编译链接；
本仓库版本同步对齐为 **3.1.0**。

> ⚠️ **盘上格式前向不兼容**：libbitcask v3.1.0 把 `bitcask.meta` 升至 **v3**（加
> CRC32）。本版写出的库**不能被旧 3.0.0 打开**（旧读端只认 v2 → "unsupported meta
> version"）；**反向兼容**——本版能读旧库（v2 meta 兼容读、legacy field.schema 自动
> 原子升级为 FSCH v1）。升级请单向进行。

### 新增

- **`open/2` 选项 `{max_read_handles, unlimited}`**：透传 libbitcask v3.1.0 的
  `kUnlimitedReadHandles` 哨兵（显式不限、旧默认行为）。
- **`open/2` 选项 `{auto_compact_dead_ratio, R}`（索引模式）**：透传
  `SearchLayerConfig::auto_compact_dead_ratio`。`0.0`（默认）= 关；`R ∈ (0.0, 1.0]`
  = 开——reducer 线程内按 per-list 死占比自动 compaction，posting list 内存随 churn
  有界，不再依赖 merge 才回收（libbitcask S12-2）。仅索引模式（带 `{analyzer, _}`）
  生效。
- **错误原子 `closed`**：NIF 把 libbitcask 新增的 `CaskError::kClosed`（对已 close
  的 handle 发起调用，S12-5）映射为 `{error, closed}`，与通用 `{error, error}` 区分。

### 变更

- **`third_party/libbitcask` 子模块**：v3.0.0 → **v3.1.0**（`SOVERSION` 保持 3，
  soname `libbitcask.so.3` 不变；ABI 增量安全——新符号 + 枚举末尾加值）。随库引入：
  read 句柄默认上限（防 fd/mmap 无界）、reducer 线程内自动 compaction、field.schema
  加 FSCH v1 格式头 + CRC、`bitcask.meta` v2 → v3 加 CRC、C API 批量检索 ×3 +
  `parallel_scan` + `BITCASK_ERR_CLOSED`、`-Werror` 库构建护栏。引擎细节见
  [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **`{max_read_handles, N}` 语义变更（随 libbitcask v3.1.0）**：默认 `0` 由「不限」
  改为**按 `RLIMIT_NOFILE` 软上限自动推导**（约一半、下限 64）。小/中库行为不变；
  大库由 fd 耗尽 crash 改为 graceful 句柄淘汰。需旧「不限」行为改传 `unlimited`。
- **构建**：根 `CMakeLists.txt` 版本/格式注释对齐 v3.1.0；`bitcask.app.src`
  `vsn` 3.0.0 → 3.1.0。

## [3.0.0] — 2026-06-25

**升级到 libbitcask v3.0.0**：submodule 由 v1.1.0 升至 **v3.0.0**（libbitcask 自此
**三套版本号统一**——CHANGELOG = 库 `VERSION` = C API = `3.0.0`，`SOVERSION` 1 → 3）。
ABI 破坏性变更，NIF 已重新编译链接；本仓库版本同步对齐为 **3.0.0**。

> ⚠️ **破坏性 API 变更**：移除运行期 `bitcask:set_synonym_map/2`，同义词词典改为
> `open/2` 的 open-time 不可变选项 `{synonym_file, Path}`。调用方需迁移（详见下）。

### 变更（破坏性）

- **同义词词典：运行期 setter → open-time 不可变配置**（对齐 libbitcask v3.0.0：
  `Cask::set_synonym_map` / `bitcask_set_synonym_map` 已删除，新增
  `CaskOptions::synonym_map`）。
  - **移除** `bitcask:set_synonym_map/2`（及 NIF `cask_set_synonym_map/2`、atom
    `load_failed`）。
  - **新增** `open/2` 选项 `{synonym_file, Path}`：开库时一次性从文件加载，构造后
    **不可变** → 并发查询天然安全。`Path` 接受 string 或 binary（facade 自动转
    binary）；仅在索引模式（带 `{analyzer, _}`）生效；文件打不开则静默不展开
    （沿用「无效选项值静默跳过」语义，open 仍成功）。
  - **迁移**：`set_synonym_map(H, Path)` 运行期调用 → 改为 `open(Dir, [{analyzer,
    _}, {synonym_file, Path}, ...])`；运行期更换词典需重开库。

### 变更

- **`third_party/libbitcask` 子模块**：v1.1.0 → **v3.0.0**（`SOVERSION` 1 → 3，
  soname `libbitcask.so.1` → `libbitcask.so.3`；ABI 不兼容时链接器明确报错）。
  随库引入 v1.2.0 引擎能力：`Cask` handle 多线程安全（写路径内部串行化 +
  读/搜索并发 + `close()` fail-fast）、批量检索、异步索引 MapReduce 流水线、
  `parallel_scan` 全表并行扫描；meta 格式升至 v2（新增 `VecInmemInt8` 字节）。
  引擎细节见 [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **构建**：根 `CMakeLists.txt` 版本/ABI 注释对齐 v3.0.0；`bitcask.app.src`
  `vsn` 2.2.0 → 3.0.0。

### 文档

- README（中/英）移除函数表 `set_synonym_map/2` 行；`open/2` 文档新增
  `{synonym_file, Path}` 选项说明；ROADMAP 增 libbitcask v3.0.0 升级条目。

## [2.2.0] — 2026-06-22

**libcask 独立库拆分**（[ROADMAP §2.2.0](ROADMAP.md) 计划落地）：C++ 核心（24 源
文件 + 45 头文件）提取为独立的 `libbitcask`（`libbitcask.a` 静态 / `libbitcask.so`
动态），NIF 仅保留胶水层。本仓库 `cpp/` 只剩 9 个 NIF 绑定 TU，单一
`priv/bitcask_cpp.so` 链接静态 libbitcask（保留 LTO）。第三方依赖
（cppjieba / googletest / benchmark / oneTBB / utf8proc / limonp /
unordered_dense）改为 libbitcask submodule vendored，符号链接委托至
`third_party/libbitcask/third_party/*`。

里程碑 L1–L9 全部完成（详见 [`TASK.md` §L](TASK.md)）；libbitcask 同步迭代到
**v1.1.0**（独立 C API + BCSC `search.ckpt` 容器 + HNSW V7 `search.vec` 外存 +
InvVersion=6 FOR/VByte + 三梯队性能微优化 + 生产正确性 C1–C5 修复）。

### 新增

- **`third_party/libbitcask` 子模块**（v1.0.0 → v1.1.0）：完整 C++ 引擎 + 稳定 C
  ABI（38 个 `extern "C"` 函数，`SOVERSION=1`）。`cmake -S third_party/libbitcask
  -B build` 独立可构建，`find_package(Bitcask)` 安装支持。
- **C++ 核心 → 独立库**（L1–L9）：`bitcask_cask` / `bitcask_keydir` / `bitcask_hnsw` /
  `bitcask_search` 等 11 个 STATIC 聚合为 `bitcask_static`（ar 合并 `.a`）+
  `bitcask_shared`（`.so` + C wrapper）；符号导出策略（`-fvisibility=hidden` +
  `__attribute__((visibility("default")))`）。
- **libbitcask v1.1.0 同步引入**：
  - **统一分段搜索 checkpoint `search.ckpt`（BCSC 容器）**：docmap / bm25.default
    / bm25.fields / hnsw 各为一段、**逐段独立 CRC** + 页脚目录 + `.prev` 代际回退
    （取代 `search.docmap.ckpt` / `search.vec.ckpt` / `search.bm25.*` 多文件）。
  - **HNSW V7 / BVH2 v2 外存化**：全精度 f32 向量独立 `search.vec` 文件（`BCVP`，
    只读 mmap + 每 4 KB 页 CRC32）；`search.ckpt` HNSW 段（magic `BVH2`,
    version 2）内嵌 int8 量化码字，省去开库重量化 pass。
  - **倒排盘上格式 v6（`InvVersion=6`）**：ord 改用 FOR（Frame-of-Reference）
    块压缩（128/块），tf/dl 改用 VByte varint（不再支持 v1–v5 载入）。
  - **三梯队性能微优化**（均经实测验证为安全微优化）：HNSW rerank、WAND 结果排序、
    qcodes 条件分配、FStats 缓存行对齐（梯队一）；KeyDir 换
    `ankerl::unordered_dense` 稠密扁平表、HNSW 邻接 bump-slab arena（梯队二）；
    `thread_local` scratch/encode 缓冲复用、serialize 缓冲复用、hint `pread_into`、
    向量软件预取、`-march=native` 开关（梯队三）。
  - **CI**：GitHub Actions matrix（Release + ASan/UBSan/TSan）；崩溃恢复回归测试
    （`fork + SIGKILL` 写入中 + `MergeFailurePreservesKeyDirVisibility`）。
  - **生产正确性 C1–C5 修复**（详见变更段）。
- **NIF 适配（v1.1.0 API）**：
  - 新增 atom `load_failed`；`set_synonym_map/2` 文件打不开现返回 `{error, load_failed}`
    （v1.1.0 起 `load_from_file` 为 `[[nodiscard]] bool`；旧实现会静默装上空词典）。
  - 新增 facade `bitcask:index_errors/1`（[同步透出 v1.1.0 IndexPool 异常计数](src/bitcask.erl)）。
- **构建系统**：根 `CMakeLists.txt` `add_subdirectory(third_party/libbitcask)` 引入
  全部 C++ target；`cpp/CMakeLists.txt` 仅定义 NIF 绑定（链接 `bitcask_cask`）。
  第三方依赖符号链接委托循环覆盖 7 个 vendored 库。
- **索引状态可观测性**：异步索引 worker 异常计数（`IndexErrors`）透出到
  `bitcask:status/1` NIF 元组（facade 通过新 `index_errors/1` 单独读取）——
  非零即索引可能漂移、搜索结果可能陈旧。

### 变更

- **`cpp/` 目录结构**：移除所有 C++ 核心源文件与头文件，仅保留 `cpp/nif/`（9 个
  NIF TU：`nif_main.cpp` / `nif_cask.cpp` / `nif_cask_iter.cpp` /
  `nif_cask_admin.cpp` / `nif_cask_meta.cpp` / `nif_helpers.cpp` /
  `nif_options.cpp` / `atoms.cpp` / `resources.cpp`）。
- **`cpp/include/` → `third_party/libbitcask/include/`**：所有 C++ 公共头文件移入
  libbitcask 库；NIF 通过 `bitcask/...` include 路径访问（CMake 自动添加）。
- **`cpp/c_api/` → `third_party/libbitcask/c_api/`**：38 个 `extern "C"` C API
  函数及对应头文件整体迁移；`nm -D libbitcask.so` 仅暴露 C ABI 符号。
- **第三方依赖 vendoring**：utf8proc / cppjieba / limonp / googletest / benchmark /
  oneTBB / unordered_dense 全部以 libbitcask submodule 形式 vendored，本仓库
  `third_party/` 仅保留符号链接指向 `third_party/libbitcask/third_party/*`。
- **KeyDir 分片锁**：`shared_mutex` → `std::mutex`（消写者偏好停车）；fstats 改
  无锁发布路径。分片数演进至 256（同 2.1.1，但实现层落地于 libbitcask）。
- **`set_synonym_map/2` 错误行为**：从「静默装上空词典」改为「返回 `{error,
  load_failed}`」（v1.1.0 `load_from_file` API 收紧的连带适配）。
- **`status/1` NIF 返回元组**：从 4 元组 `{KeyCount, KeyBytes, Epoch, Files}`
  扩为 5 元组，新增 `IndexErrors` 字段（facade 不外露，新
  `bitcask:index_errors/1` 单独读取）。

### 修复（随 libbitcask v1.1.0 同步引入）

- **C1 — merge 失败时 keydir 完全未动**（延后 apply）：失败后数据立即可见、无需
  重启走恢复路径。
- **C2 — merger 全 9 条错误路径补 cleanup**：部分输出文件不残留。
- **C3 — IndexPool worker 整体 try/catch 吞异常**（best-effort 丢弃 +
  `index_errors` 计数）：异常不再杀 worker、`pending_` 必递减 → `flush()` 不挂、
  索引不静默漂移。
- **C4 — IndexPool 析构 UB 修复**：`start()` 从未调用时 `joinable()` guard 跳过
  join；`stop()` 幂等（CAS 短路）。
- **C5 — `Cask::close()`（`noexcept`）整体 try/catch**：所有可抛操作
  （`save_search_ckpt` / `write_keydir_snapshot` / 分配 / 取锁）纳入兜底；
  catch 后的资源释放中唯一可抛的 `registry release` 也单独 try → 彻底消除
  `noexcept` 函数抛出导致 `std::terminate` 的风险。
- merge 输出无条件 fsync（成功返回 = 新文件已落盘）。

### 不兼容的变化

**无**。2.2.0 是纯结构性提取 + 性能/正确性增量，盘上格式字节序（meta v2 /
小端）与 2.1.1 兼容；旧目录可直接 open。唯一对外可见的 API 行为变化：

- `set_synonym_map/2` 在同义词文件无法打开时**改为返回 `{error, load_failed}`**，
  旧版本会静默装上空词典——依赖静默行为的代码需适配。
- `bitcask_cpp_nifs:cask_status/1` 返回元组从 4 元组**扩为 5 元组**（新增
  `IndexErrors` 字段）。未直接调用此 NIF 的纯 facade 用户不受影响。

---

## [2.1.1] — 2026-06-17

2.1.0 引入 C++23 引擎后的第一轮**系统级优化**——聚焦向量库的内存/磁盘墙、
读路径零拷贝、恢复持久化统一、以及全盘字节序规范化。428 GoogleTests 全绿。

### 新增

- **P5 — HNSW int8-only 内存模式**（opt-in `{vector_inmem_int8, true}`）：丢掉
  常驻 f32 `vecs`，建图/查询/精排全走 int8（查询侧也量化、VNNI int8×int8）。向量
  内存 **−80%（~5×）**，1M 向量 dim=2560 从 12.81 GB → 2.57 GB；代价 recall@10 约
  −3%（合成簇 1.0→0.965）。与 P3 落盘 int8 正交可组合。默认仍 f32+int8（召回优先）。
- **P6 — sealed 文件 mmap 只读路径**：sealed（封口不可变）data 文件 mmap 零拷贝读
  ——免 pread syscall、直接用 OS page cache、不双缓存。active 文件永远 pread。merge
  unlink 旧文件延迟 munmap（`shared_ptr<DataFile>` 引用计数，在途读者续命）。32 位
  禁用。`GetResultView` 持映射引用锚定生命。
- **P8 — HNSW merge rebuild 门控**：按死节点比例门控全量重建（同 P2 范式），死占比
  < 阈值跳过（`is_live` 过滤兜底），≥ 阈值才全量重建——节省向量库 merge 的主要 CPU。
- **P9 — read 句柄 fd 预算 LRU**（`{max_read_handles, N}`）：只读文件句柄按 LRU /
  数量上限淘汰，解决大库 fd 撞 ulimit 问题（与 P6「mmap 后 close fd」互补）。0=不限。
- **P10 — search_hybrid 两路并行**：BM25 与 HNSW 两路搜索丢线程池并行执行，hybrid
  查询延迟近减半。
- **P11 — merge I/O 顺序优化**：merge 读旧/写新文件加 `posix_fadvise(SEQUENTIAL/
  WILLNEED)` + 大缓冲，降低 IO stall。
- **P13 — open 时按需后台 merge**（`{merge_on_open, off|background}`）：open
  （read_write）后按 `needs_merge` 门控**后台**触发 merge，收拢小文件，不阻塞 open。
- **P14 — 恢复持久化统一**：
  - **P14a** checkpoint 命名重构（`.snap→.ckpt`、bm25 `.inv→.seg`/`.inv.wal→.wal`），
    契约 `{kv|search}.{组件}.{ckpt|seg|wal|manifest}` 文档化。
  - **P14b/P14e** 单文件分段 `search.ckpt`（逐段 CRC + 页脚目录 + 段级脏位复用 + 代际
    `.prev` 回退）+ 单趟尾部回放（认 data 文件为唯一 WAL，消 4-way 配对门悬崖、重用率
    从 0 起来）。写放大 2→1、搜索多文件→1、崩溃后不再全量 fold。
- **P15 — 全盘字节序统一（小端）+ 迁移工具**：
  - 全盘统一小端（mmap 读无 bswap、`static_assert` 守护）。
  - `bitcask.meta` version 1→2，旧 v1 大端目录 open 干净拒绝（fail-loud）。
  - `migrate_le` 离线迁移工具（data 重编码 + hint 重生成 + meta + field.schema + shadow
    翻转）；中英文档 [`doc/migrate-le.md`](doc/migrate-le.md) /
    [`doc/migrate-le-en.md`](doc/migrate-le-en.md)。
- **libcask 独立库拆分可行性评估**：见
  [`doc/libcask-extraction-zh.md`](doc/libcask-extraction-zh.md)。

### 变更

- checkpoint 文件后缀全面变更：keydir `.snap→.ckpt`、bm25 `.inv→.seg`/
  `.inv.wal→.wal`、搜索多文件 → 单个 `search.ckpt`。
- 磁盘格式字节序从混合（record/hint 大端、向量/snapshot 小端）统一为**全盘小端**。
  `bitcask.meta` version 从 1 升到 2。

### 不兼容的变化

1. **磁盘格式字节序**：全盘统一小端（meta v2）。旧 v1（大端）目录**不被读取**——
   需用 [`migrate_le`](doc/migrate-le.md) 工具迁移或从新目录重建。
2. **checkpoint 文件命名**：`.snap`/`.inv`/`.inv.wal` 后缀废弃，统一为
   `.ckpt`/`.seg`/`.wal` + `search.ckpt`。旧名不再读（可重建，升级后首次 open 一次
   全量 fold、close 落新名）。

### 备选项目 gate 结论

- **P7（派生值 compute cache）❌ 不做**：dequant derive 仅 mmap 访问的 1-1.3×，缓存
  收益微乎其微；highlight 非热路径（仅 `search_text_highlight` 触发），收益面太窄。
- **P12（meta_blobs_ 有界）❌ 不做**：1M ords 访问 200-300 ns（`shared_lock` + vector
  copy）、内存 ~280 MB——当前规模可接受；按需读盘会在搜索热路径引入毫秒级 I/O
  （比当前慢 10000×）。>10M ords 时再评估。

---

## [2.1.0] — 2026-06-15

引擎的一次彻底 **C++23 重写**（单一 NIF，`priv/bitcask_cpp.so`），把 bitcask 从
纯键值存储升级为 **KV + BM25 全文检索 + HNSW 向量检索** 引擎，并做了大量
SIMD/AVX 加速。核心 Erlang KV 接口（`get`/`put`/`delete`/`fold`/`merge`…）保留；
与 legacy 2.0.x 的差异见 **不兼容的变化**。

API 参考：[`doc/api-zh.md`](doc/api-zh.md)。

### 概述
- C++23 NIF 引擎；带类型记录磁盘格式（`kDoc`/`kTombstone` + 逐次写入序号 +
  可选 DocValue：text / fields / vector / meta）。
- BM25 全文检索；HNSW 近似最近邻向量检索；RRF 混合检索融合两路。
- 可插拔 embedder 框架，写入与查询自动 embed。
- 大量 AVX/AVX-512/VNNI SIMD 加速，运行时按 CPU 派发 + 标量兜底（见下方专节）。

### 新增
- **BM25 全文检索**：`search_text` / `search_phrase` / `search_fields`
  （`field:term^boost`）/ `search_near`（slop）/ `search_fuzzy`（编辑距离）/
  `search_wildcard`（`*` `?`）。同义词（`set_synonym_map/2`）、Porter 词干化、
  片段高亮。
- **分词器**：whitespace、CJK n-gram、jieba（CutForSearch + CJK 回退）；NFKC
  归一化、可选停用词、可配 n-gram 上下界 / 最小词长 / 词干化。
- **搜索引擎内核**：Block-Max WAND 早终止、k-way leapfrog 交集、扁平数组评分、
  选择性查询缓存（`SearchCache`）、文档原文 LRU、倒排 WAL + 快照恢复。
- **HNSW 向量检索**（`search_vector`）：分层图 + 启发式选边，`cosine` / `l2` /
  `dot` 度量，int8 量化（粗筛 + f32 精排），BCVS 快照持久化，merge 物理清死节点。
- **RRF 混合检索**（`search_hybrid`）：以 `Σ 1/(60+rank)` 融合 BM25 与 HNSW；
  支持单路退化。
- **Embedder 框架**（`bitcask_embedder`）：`new/2` 上下文 API，
  `openai` / `anthropic` / `{custom, Mod}` provider；`put #{text => ...}` 自动
  embed；`search_hybrid(H, Text)` / `search_hybrid(H, Text, auto, …)` 与
  `search_vector(H, {text, _}, …)` 自动 embed 查询；`bitcask:embed/2` 门面。
  可配 `max_input_bytes` / `timeout_ms` / `connect_timeout_ms`。
  **MRL（Matryoshka）**：`dim`（原生）与 `vector_dim`（截断落库）——二者不一致时
  请求带 `dimensions`，并校验响应维度。
- **结构化元数据 + 过滤**：`encode_meta/1`；`eq`/`gte`/`lte`/`in` 条件 +
  `and`/`or` + 嵌套，作用于 `search_text/4`、`search_vector/5`、`search_hybrid/5`。
- **P3 — 向量落盘 int8 量化**（opt-in `{vector_quantized, true}`）：向量按 per-vector
  对称 int8 码字落盘（磁盘 `~4×` 小），写入 `bitcask.meta` 并重开校验一致；
  `get`/恢复透明 dequant。默认仍 f32——合成 dim=2560 实测 recall@10=0.987 /
  @100=0.995（@10 跌 ~1.3%），故 int8 作磁盘受限部署的 opt-in。设计+测量见
  `doc/vector-ondisk-quant-design-zh.md`。
- **P4 — 单写者组提交**（`{sync_strategy, {puts, N}}`）：每 N 次写对 active data
  file fsync 一次（close/roll/sync 收尾 force-flush），介于 `none` 与逐条
  `o_sync` 之间。无跨线程锁。
- **流式迭代**：`stream/1` + `next/1` + `stop/1` + `with_stream/2`，及
  `stream_fold/3,4`。
- **双语文档**：API 参考（`doc/api-zh.md` / `doc/api-en.md`）、并发/锁全序、磁盘
  格式、HNSW 设计、SIMD 内幕等。
- **构建/测试**：CMake + rebar3 双入口；ASan/UBSan/TSan 预设；400+ GoogleTests。

### 性能——AVX / SIMD 指令集优化
所有内核都做**运行时 CPU 特性派发**（`AVX-512F → AVX2 → 标量`，适用处含 NEON），
单一二进制到处可跑、自动用最宽指令集，并始终保留标量兜底。

- **HNSW 距离内核**：dot / L2 的 AVX-512（4× `__m512` 累加器）与 AVX2+FMA 实现；
  `pick_kernel` 构造时一次性选定 ISA。
- **int8 量化（VNNI）**：基于 `dpbusd` 的 int8 距离内核做粗筛，再 f32 精排——在
  AVX-512-VNNI CPU 上大幅提速且保召回。
- **倒排交集**：u64 SIMD 交集（AVX-512 / AVX2）+ Inoue 块过滤，配合 galloping /
  标量自适应派发（ord 可窄化时用 u32）；AVX2 原型实测约 3.46× 于标量。
- **BM25 评分**：SIMD `tf_norm`（AVX2 8 路 / AVX-512 16 路）+ 统一
  `score_bow_topk` 内核；查询向量归一化 SIMD（双精度 dot + float scale）。
- **存活位 gather**：`fill_is_live` / `fill_doc_lens` AVX2 gather，ords 有序快路径
  （recency 类查询占主导）。
- **CRC32**：PCLMULQDQ 硬件加速（SSE4.2 + CLMUL），zlib 兜底。
- **模糊匹配**：Myers 位并行编辑距离（约 11× 于 DP 基线）。

### 性能——持久化与写路径
- **P1 — Hint 写缓冲**：hint record 攒进 64 KiB 内存缓冲，按阈值 / 文件 roll /
  close 才落盘，取代每 put 一次 `write(2)`——写路径 syscall 约减半。hint 可重建，
  崩溃丢缓冲尾巴只回退 `fold(data)`（安全语义不变）。
- **P2 — merge 不重分词**：merge 后不再全量重建 BM25 索引（原会重读+重分词所有
  live 文档）。posting 以稳定 `ord` 为键，`merge` 已通过 `on_relocate` 重映射定位、
  死文档由 `is_live` 过滤，故 merge 改为按阈值 `compact`（清死 posting，不读盘、
  不跑 NLP）。

### 变更
- `bitcask:open/2` 改用 `{embedder, {Provider, Cfg}}` 配置 embedder，并自动从
  embedder 的 `vector_dim` 推出集合维度（无需单独写 `{vector_dim, N}`）。
- KeyDir 分片为 256 片 + 写者闸门屏障（取代 stop-the-world 全屏障）；任意瞬间至多
  持 1 把分片锁。
- 索引更新走异步单写者 `IndexPool` worker；读/搜索无锁，与之并发。
- 统一架构：`Cask` 与原 `Collection` 合并为单一引擎，由 `{analyzer, ...}` 选择；
  每目录 `bitcask.meta` 记录模式。

### 修复
- **崩溃**：jieba 分词器因自注册在独立 TU 被静态链接器丢弃 → `create(Jieba)`
  返回 null → 首次带 text 的 `put` 段错误。注册移入工厂 TU；analyzer 构造失败时
  `open` 干净拒绝。
- **并发 / 内存**（读路径 vs 异步 worker 加固）：`meta_blob` 改返回拷贝而非逃逸
  span（UAF）；搜索缓存 `last_used` 统一经 `atomic_ref`；`InvertedIndex::save`
  安全遍历并发表；`max_indexed_ord_` 原子化；`IndexPool` 消费者 try/catch（避免
  `flush` 挂起 / `std::terminate`）；HNSW `load` 释放残留 chunk；重建/加载快照时
  清理 `ord_field_lens_`。
- **`{sync_strategy, {seconds, N}}`** 文档有声明但 C++ NIF 从未实现（静默等同
  `none`）；以已实现的 `{sync_strategy, {puts, N}}` 取代（P4）。
- **`bitcask:open/2` 模式不一致 `case_clause` 崩溃**：NIF 把部分故障（如
  `mode_mismatch`）以裸 atom 返回，`open/2` 未处理——现归一为 `{error, Reason}`。

### 不兼容的变化
1. **磁盘格式**：新的带类型记录格式（`kDoc`/`kTombstone` + 逐次写入序号、可选
   DocValue）。本引擎**不读** legacy 2.0.x 数据文件——请用全新目录。
2. **`open/2` 返回值**：现在是 `{CaskRef, EmbedderCtx}`（二元组），不再是裸
   `reference()`。整体不透明地传给所有 `bitcask:*` 调用即可（仍可用）；对裸
   reference 做模式匹配的代码需适配。
3. **移除 legacy 迭代 API**：`iterator/3` + `iterator_next/1` +
   `iterator_release/1` → 改用 `stream/1`+`next/1`+`stop/1` / `with_stream/2`，或
   `fold/3,6` / `fold_keys/3,6`。
4. **移除 `collection_*` API**：合并进单一引擎；用 `{analyzer, _}` 启用索引模式。
   `keydir_copy` / `deep_copy` 不再导出。
5. **构建 / 运行时**：构建 NIF 需 C++23 工具链与 oneTBB；Erlang/OTP ≥ 22
   （OpenAI 兼容 embedder 用 OTP 27+ 的 `json` 模块）。引擎产物为单一
   `priv/bitcask_cpp.so`。

---

## [2.0.3] 及更早
legacy Erlang/C bitcask。见 `2.0.3` 标签之前的 git 历史。
