# Bitcask 路线图（Roadmap）

English: [`ROADMAP_EN.md`](ROADMAP_EN.md)。详细子任务拆分与历史见 [`TASK.md`](TASK.md)。

状态图例：✅ 承诺（will do） · ⚠️ 备选（candidate，按 gate 决策）。

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
