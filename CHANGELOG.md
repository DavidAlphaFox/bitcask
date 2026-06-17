# 更新日志（中文）

English version: [`CHANGELOG_EN.md`](CHANGELOG_EN.md)。
格式大致遵循 [Keep a Changelog](https://keepachangelog.com/)。

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
