# Bitcask 统一架构开发任务 (TASK.md)

在 bitcask 引擎之上构建**统一存储引擎**：将 Cask（纯 KV）和 Collection（KV + BM25 搜索）
统一为一个引擎，共享存储层和 merge。完整设计见 `doc/unified-architecture-plan-zh.md`。

## 约定

- 每个子任务**先 standalone 编译+跑测试**验证，再跑全量 `ctest`。
- 每步尽量配套单元测试；改磁盘格式必更新黄金 fixture。
- 所有注释使用中文，遵循项目现有头文件注释风格。
- 不考虑向后兼容性。

---

## 当前任务：统一架构（U0 - Unification）

> 所有阶段性任务已完成，详见历史记录。

---

## 并发架构（T1-T6）

> 所有阶段性任务已完成，详见历史记录。

---

## BM25 搜索引擎完善（S1-S13）

> 所有阶段性任务已完成，详见历史记录。

---

## 性能优化（O1-O13）

> 所有阶段性任务已完成，详见历史记录。

---

## V2 检索加速（K1/B1/B2/A1/C1）

> 所有阶段性任务已完成，详见历史记录。

---

## A4 — keydir 快照 + 搜索快照

> 所有阶段性任务已完成，详见历史记录。

---

## M6 — KeyDir 分片

> 所有阶段性任务已完成，详见历史记录。

---

## V3 — HNSW 向量检索

> 已完成，功能分散在 S 系列迭代中落地。

---

## V4 — 单域 merge

> 已完成，详见历史记录。

---

## V5 — 混合检索 + metadata filter

> 已完成，详见历史记录。

---

## V6 — 性能与规模化

> 已完成，详见历史记录。

---

## V7 — 文件持久化优化（P 系列）

> P1-P6 已完成，P7/P12 gate 不通过（收益不足），全部路线图任务收尾。

---

## 2.1.1 路线图

### P5 — HNSW int8-only 内存模式（向量内存墙的主要杠杆）

> 背景：dot 模式下 HNSW 内存里是 f32 `vecs` + int8 `qcodes` **两份**（int8 为 VNNI
> 提速、反而 +25% 内存）。P3 落盘 int8 只省磁盘、不动内存。真正省**内存**要丢常驻
> f32，建图/精排都用 int8。实测见 `doc/vector-ondisk-quant-design-zh.md §7`。
>
> **实测收益（合成簇 dim=2560，`hnsw_test::Int8OnlyMemoryAndRecall`）**：向量内存
> **−80%（~5×）**，1M 向量 12.81 GB → 2.57 GB；代价 **recall@10 约 −3%**
> （f32 1.0 → int8-only 0.9675）。opt-in，真实语料 gate。

| # | 内容 | ROI/风险 | 状态 |
|---|------|---------|------|
| P5a | HNSW int8-only 配置：按 flag 不分配/保留常驻 f32 `vecs`，NodeChunk 裁掉 vecs；距离 + 「精排」都走 int8（查询侧也量化，用 VNNI int8×int8）。 | 中高 / 中 | ✅ |
| P5b | open 选项 `{vector_inmem_int8, true}` 接线 + meta 持久化 + 重开一致校验（同 P3b）；与 P3 落盘 int8 正交可组合（盘+内存都省）。`get` 仍可经盘 f32 / dequant 返回。 | 中 / 中 | ✅ |
| P5c | 真实 qwen3 语料召回 gate（复用 `Int8OnlyRecallAndMemory` harness）；定 opt-in 默认 + 文档；recall 跌幅可接受才推荐给内存受限/大规模部署。 | 中 / 低 | ✅ |

**依赖/关联**：建在 P3（int8 量化方案 + codec）与 V6.4.2 外存预留点之上；harness 复用
P3c。**红线**：默认仍 f32+int8（召回优先）；int8-only 是内存受限/大规模的 opt-in。

### P6 — sealed 文件 mmap 只读路径（取代原 value LRU 方案）

> 目标：对 **sealed（封口不可变）data 文件**做 mmap 只读——**零拷贝 + 免 pread
> syscall**，且直接用 OS page cache、**不双缓存**（优于 value LRU）。**active 文件
> 永远 pread**（append 增长对 mmap 不友好：映射定长、SIGBUS-past-EOF、重映射移址；
> 分析见对话记录）。range 模型同 LevelDB SSTable：不可变文件 + 引用计数延迟删除 +
> mmap_limit + pread 兜底。DocValue decode 近零成本，故不需缓解码值（原 value LRU 已弃）。

| # | 内容 | ROI/风险 | 状态 |
|---|------|---------|------|
| P6a | `DataFile` sealed mmap 模式：sealed 文件首次读时 `mmap(PROT_READ, MAP_SHARED)` 整文件，`read(off,sz)` 返回**指向映射的 span**（零拷贝、无 syscall）；active / 未映射 / 超额 → 回退 pread。**mmap 后可 close fd**（映射仍有效）→ 顺带缓解 read_files_ 的 fd 累积（大库撞 ulimit）。 | 高 / 中 | ✅ |
| **P6b merge 生命周期（重点）** | **释放**：merge unlink 旧文件时**不立即 munmap**——从 read_files_ erase 缓存的 `shared_ptr<DataFile>`，但在途读者仍持 shared_ptr → DataFile 存活 → 映射存活；**munmap 延迟到引用计数归零**（`~DataFile`）。Linux 上 unlinked-but-mapped 文件仍可读（inode 由映射续命，类似 open fd），在途读安全。**再次 mmap**：merge 产出的新 sealed 文件 + active roll 成 sealed 后，下次经 `read_file` 懒加载时按 sealed mmap 路径建立映射。 | 高 / 高 | ✅ |
| P6c | `GetResultView` 适配：mmap 命中时持 `shared_ptr<DataFile>`（映射引用）+ span 指向映射，保证 view 生命内映射不撤（现版持 owned ReadRecord/pread 拷贝）。mmap_limit（文件数/字节）+ pread 兜底；**32 位禁用 mmap**（地址空间，同 LevelDB）。 | 中 / 中 | ✅ |
| P6-gate | 量化 get 延迟：mmap 命中 vs 纯 pread vs OS page-cache 命中；ulimit/地址空间影响；小库（≤几文件）可全映射、大库走 limit+pread。 | — | ✅ |

**关键不变量**：只 mmap sealed（不可变）文件——merge 只 unlink、**绝不原地 truncate** sealed
文件，故无 SIGBUS-on-truncate；torn-tail 也不存在（sealed 已 finalize）。**生命周期靠
现有 `shared_ptr<DataFile>` 引用计数扩展到映射区**（= LevelDB Version refcount 的等价），
不引入新锁模型。
**已移除**：原 P6 value LRU + 统一 LRU 基件——mmap 覆盖其主要收益（省 syscall+拷贝）
且无双缓存；DocValue decode 近零、缓解码值无意义。（DocTextLru/SearchCache 保留现状。）

### P7 — 派生值 compute cache ❌ gate 不通过

> **Gate 结论（2026-06，`gate_bench.cpp`）**：highlight derive（nfkc_fold +
> analyze_with_offsets）= **11 μs/doc**，是 mmap 读（251 ns）的 44×——数字上值得缓存。
> 但 highlight **非热路径**（仅 `search_text_highlight` 触发，DocTextLru miss 时降级
> 为无片段不阻塞），收益面太窄。dequant derive = **52-325 ns**，仅 mmap 的 1-1.3×，
> 缓存收益微乎其微。**不做通用 compute cache**；若未来 highlight 成瓶颈，直接在
> DocTextLru 中加缓 offsets 即可（一行改动，无需框架）。

| # | 内容 | ROI/风险 | 状态 |
|---|------|---------|------|
| P7-gate | 量化 derive 成本 vs mmap：highlight=11μs(44×)、dequant=52-325ns(1-1.3×)。 | — | ❌ 不通过 |
| P7a | compute cache 框架 | 中 / 中 | ❌ 取消 |
| P7b | highlight offsets / dequant 缓存 | 中 / 中 | ❌ 取消 |

### P8–P13 — 增量优化

| # | 内容 | ROI/风险 | 状态 |
|---|------|---------|------|
| **P8 HNSW merge rebuild 门控**（= P2 for HNSW）| merge 现**无条件全量 `rebuild_hnsw`**（重插所有 live 向量，O(n log n)，向量库 merge 大头）；但查询已 `is_live` 过滤死节点（`search_layer.cpp:225/232`）→ 重建**纯物理压实、正确性不依赖**。改为**按死节点比例门控**：死占比 < 阈值跳过重建（is_live 兜底），≥阈值才全量重建。与 P2 同范式。详见 `doc/hnsw-merge-gate-design-zh.md`。 | 高 / 低 | ✅ |
| **P9 read_files_ fd 预算 LRU** | `read_files_` 每文件常驻 fd、无淘汰（`cask.cpp:1072`）→ 大库撞 ulimit。只读句柄按 LRU/数量上限淘汰（与 P6「mmap 后 close fd」互补）。详见 `doc/read-handle-lru-design-zh.md`。 | 中 / 低 | ✅ |
| **P10 search_hybrid 两路并行** | `search_text`→`search_vector` 现串行（`search_layer.cpp:263/270`）+ RRF；两路独立 → 丢线程池并行，hybrid 延迟近减半。注意 filter/缓存共享并发安全。详见 `doc/hybrid-parallel-design-zh.md`。 | 中 / 中 | ✅ |
| **P11 merge I/O 顺序优化** | merge 顺序读旧写新、无 readahead 提示。加 `posix_fadvise(SEQUENTIAL/WILLNEED)` + 大缓冲，降 IO stall（顺带 active 写也可 fadvise）。详见 `doc/merge-io-tuning-design-zh.md`。 | 中低 / 低 | ✅ |
| **P12 meta_blobs_ 内存按需/有界** | `Index::meta_blobs_` 每 ord 全量常驻；改有界 LRU 或按需读盘。**Gate 结论（2026-06，`gate_bench.cpp`）**：访问延迟 200-300 ns @ 1M ords（shared_lock + vector copy），内存 ~280 MB @ 1M×256B——当前规模可接受。按需读盘会在搜索热路径引入毫秒级 I/O（比当前慢 10000×）。❌ **不做**，>10M ords 时再评估。详见 `doc/meta-blob-residency-design-zh.md`。 | 中 / 中 | ❌ gate 不通过 |
| **P13 open 时按需后台 merge**（小文件收拢）| 每个写会话首次写建**新** active 文件（file_id 单调不回退、不重开旧文件——by design）→ 多次 open-写-close 累积小文件。**方案 A（承诺）**：open 后按 `needs_merge`（复用 `small_file_threshold` 等）门控、**后台**触发 merge（不阻塞 open），收成少数 sealed + 新 active；复用现有的 merge 全套 + `{merge_on_open, off|background}` 选项。否决无条件/同步 merge-on-open（O(data) 启动）。**方案 B（备选）**：复用上一个未满 sealed 文件续写（需 un-seal、破坏 sealed 不可变/与 P6 冲突）。**校正**：合并不提速单 get（keydir O(1)），收益在 open/fd/mmap/死空间。详见 `doc/open-merge-design-zh.md`。 | 中 / 中 | ✅（方案 A） |

---

## 2.1.1 落地进度（2026-06）

### P14 — 统一检查点

> 设计：`doc/recovery-unified-checkpoint-design-zh.md`（采纳 cellar 文件结构）。

#### P14a — 恢复 checkpoint 命名重构 ✅

`.snap→.ckpt`、bm25 `bm25_snapshot.inv→search.bm25`、段 `.f{i}.inv→.f{i}.seg`、
WAL `.f{i}.inv.wal→.f{i}.wal`；常量 `kKeydirSnapName`/`kIndexSidecarName`/
`kHnswSnapName`/新增 `kBm25SnapBase`；`search_layer` 段/WAL 后缀同步。**纯重命名、
零格式/逻辑变更**；旧名不再读（可重建，flag-day）。契约 `{kv|search}.{组件}.{ckpt|seg|wal|manifest}`。

#### P14e+P14b — 单文件分段 search.ckpt + 单趟尾部回放（合并）

- **S1** ✅ `SearchCheckpoint` 分段容器（`search_checkpoint.hpp`：头部 watermark +
  逐段 CRC + 页脚目录 + 结构完整性）；5 个测试（round-trip/单段损坏隔离/页脚损坏拒绝/
  截断/空段）。
- **S2** ✅ 三序列化器 → 字节缓冲：`HnswIndex`/`InvertedIndex`/`DocIndex(sidecar)`
  各加 `serialize`/`deserialize`，`save`/`load` 包一层（盘字节逐字不变，原生小端）；
  `deserialize` 带界游标。新测 `InvertedIndex.SerializeDeserializeRoundtrip`。
- **S3** ✅ 接 save：SearchLayer 产 {docmap,bm25.default,bm25.fields,hnsw} 段 → 写
  `search.ckpt` + `.prev` rename；替换 cask 多文件搜索保存（`close()`/`merge()` 统一调
  `save_search_ckpt`）。顺带修 `IndexPool::stop()` 竞态——`close()` 先 `flush()` 再
  `stop()`，防 worker 在 flag-set 与 Sentinel 之间空转退出、漏 drain。
- **S4** ✅ 接 recovery（P14b 核心）：载 search.ckpt（逐段 CRC）→ `.prev` 回退 →
  `search_ok = loaded && all_segments_ok` 单水位判定 → `fold_start` 判定 + 单趟自门
  fold；4-way 配对门删除。
- **S5** ✅ 段级脏位细化：统一每写全段（segment count 少、写量小），不引入增量脏位
  追踪——简化优先。
- **S6** ✅ 删旧多文件方法（`save_snapshot`/`load_snapshot`/`save_vec_snapshot` 等
  8 个）+ 死 WAL 重启用码 + `snapshot_path_` 成员；常量 3→1（`kSearchCkptName`）。
  回归测试：CRC 段损坏检测 + `.prev` 代际回退。428/428 全绿。

### P15 — 字节序统一（全盘小端）+ 大端目录迁移 ✅

- **P15a** 全盘 LE：`codec` `be_*→le_*`(record+hint)、`data_file`/`hint_file` 手写
  字节序读点、`field.schema` NameLen、墓碑 v2 shadow、`format.hpp`/`format-zh.md`
  注释；golden 测试翻 LE（**修复 hint fold 在 LE 下漏读 key_sz 的真 bug**）。
- **P15b** 护栏：`bitcask.meta` version `1→2`，旧 v1 大端目录 open 干净拒绝
  （`LegacyV1MetaRejectedCleanly`）。
- **P15c** 迁移工具 `migrate_le <src> <dst>`（非破坏；data 重编码+hint 重生成+meta+
  field.schema+shadow 翻转；ckpt/seg/wal 不迁移、首开重建）+ 中英文档
  (`doc/migrate-le.md` / `migrate-le-en.md`) + round-trip 测试。

---

## L — libbitcask 库提取（C API + CMake 独立构建）

> 目标：将 C++ 核心提取为 `libbitcask.a`（静态，C++ API）+ `libbitcask.so`（动态，C API wrapper），
> CMake 管理，`install()` 规则支持 `find_package(Bitcask)`。
> 现有 NIF `.so` 继续链接静态库，保持 LTO 跨 TU 内联优势。
>
> 设计文档：`doc/libcask-extraction-zh.md`（路径 B 落地，C API for ABI 稳定）。

| # | 内容 | ROI/风险 | 状态 |
|---|------|---------|------|
| **L1** | C API 头文件 `cpp/c_api/bitcask_c.h`：38 个 `extern "C"` 函数声明 + 全部 C 类型（opaque handle、slice、error、options、get_result、search_hit、iter_entry、status）。固定缓冲 `detail[512]`、动态 `char*` key。 | 高 / 低 | ✅ |
| **L2** | CMake 重构 `cpp/CMakeLists.txt`：11 个 STATIC 保留；聚合为 `bitcask_static`（`ar` 合并 `.a`）+ `bitcask_shared`（`.so` + C wrapper）。 | 高 / 中 | ✅ |
| **L3** | C wrapper 生命周期 + KV：`bitcask_open/close/get/put/delete/sync/close_write_file/options_init` + `get_result_free`。CaskOptions↔C struct 映射 + error 转换。 | 高 / 低 | ✅ |
| **L4** | C wrapper 搜索：9 个 `search_*`（text/phrase/bool/fields/near/fuzzy/wildcard/vector/hybrid）+ `set_synonym_map` + `search_result_free`。TextSearchResult↔C 转换。 | 高 / 低 | ✅ |
| **L5** | C wrapper 迭代：`iter_start/next/next_batch/release` + `iter_entry_free`。CaskIter::Entry↔C 转换。 | 中 / 低 | ✅ |
| **L6** | C wrapper 管理：`status/needs_merge/merge/is_empty/is_frozen` + `put_doc`。 | 中 / 低 | ✅ |
| **L7** | CMake target 集成：`bitcask_static` + `bitcask_shared`（PRIVATE link）+ 符号导出（`-fvisibility=hidden` + C API `__attribute__((visibility("default")))`）+ `install(TARGETS/EXPORT/DIRECTORY)` + `GNUInstallDirs`。 | 高 / 中 | ✅ |
| **L8** | C API 冒烟测试 `cpp/tests/c_api_test.c`：纯 C，直接链接 `libbitcask.so`，KV CRUD + status/needs_merge + 迭代基本路径。 | 高 / 低 | ✅ |
| **L9** | 回归验证：`ctest`（429/429）+ NIF 编译 + `nm -D libbitcask.so` 符号可见性检查。 | 高 / 低 | ✅ |

**依赖关系**：L1 → (L2, L3) → (L4, L5, L6) → L7 → (L8, L9)
**并行机会**：L4 / L5 / L6 可并行实现（独立函数组）

---

## M — libbitcask 升级 v1.1.0 → v3.0.0（API 破坏性迁移）

submodule 升至 v3.0.0（三套版本号统一，`SOVERSION` 1 → 3）；本仓库 `vsn` → 3.0.0。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **M1** | submodule pin v1.1.0 → v3.0.0 + 嵌套子模块同步（注意：rebar `pre_hook` 跑 `git submodule update --init --recursive`，父仓 gitlink 须先 `git add` 暂存，否则被回滚到旧 tag）。 | ✅ |
| **M2** | 同义词运行期 setter → open-time 选项：删 `nif_cask_set_synonym_map` + `nif_main` 声明/注册 + atom `load_failed`；`nif_options.cpp` 新增 `{synonym_file, Path}` 解析 → `CaskOptions::synonym_map`（搜索类键，自动开索引模式）。 | ✅ |
| **M3** | Erlang facade：删 `bitcask:set_synonym_map/2` + `bitcask_cpp_nifs:cask_set_synonym_map/2`；`open/2` 加 `synonym_file` 白名单 + `maybe_binarize_synonym_file/1`（string→binary）+ 选项文档。 | ✅ |
| **M4** | 回归：`rebar3 compile`（链接 v3.0.0 通过）+ `rebar3 eunit`（64/64）+ 同义词新选项端到端冒烟（带 `synonym_file` 搜 quick 命中 rapid 文档；对照组空）。 | ✅ |
| **M5** | 文档：CHANGELOG（中/英）[3.0.0] 条目 + ROADMAP（中/英）升级条目 + README 表删行 + graph-layer §8 + `CMakeLists.txt` 注释。 | ✅ |

---

## M3 — libbitcask 升级 v3.0.0 → v3.1.0（ABI 兼容增量）

> submodule 升至 v3.1.0（S12 全库审计批次；`SOVERSION` 保持 3，ABI 未破坏）；
> 本仓库 `vsn` → 3.1.0。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **M3-1** | submodule pin v3.0.0 → v3.1.0 + 嵌套子模块同步。 | ✅ |
| **M3-2** | NIF 适配：`{max_read_handles, unlimited}` 选项透传 + `{auto_compact_dead_ratio, R}` 选项透传（索引模式）+ `CaskError::kClosed` → `{error, closed}` 错误原子映射。 | ✅ |
| **M3-3** | Erlang facade：`open/2` 选项白名单加 `max_read_handles`（含 `unlimited` 哨兵）/ `auto_compact_dead_ratio`；选项文档更新。 | ✅ |
| **M3-4** | 回归：`rebar3 compile`（链接 v3.1.0 通过）+ `rebar3 eunit` 全绿。 | ✅ |
| **M3-5** | 文档：CHANGELOG（中/英）[3.1.0] 条目 + ROADMAP（中/英）升级条目 + `CMakeLists.txt` / `bitcask.app.src` 版本对齐。 | ✅ |

---

## M4 — libbitcask 升级 v3.1.0 → v4.0.0（ABI 破坏，源码兼容）

> submodule 升至 v4.0.0（S32 向量双引擎 + S29-11-②④ AVX2 int8 内核 + 磁盘段 UB
> 审计；`SOVERSION` 3 → 4，`bitcask_options_t` 布局变更 ×2 = ABI 破坏，源码级完全
> 向后兼容——NIF 重编即正确）；本仓库 `vsn` → 4.0.0。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **M4-1** | submodule pin v3.1.0 → v4.0.0 + 嵌套子模块同步（指针跟进至 `e814e4d`）。 | ✅ |
| **M4-2** | NIF 适配：`nif_options.cpp` / `nif_helpers.cpp` 改 include `search_config.hpp`（libbitcask v4.0.0 已删除旧 `search_layer.hpp`）；`{vector_engine, hnsw\|ivfrq\|diskann}` + 向量引擎调优选项（`hnsw_m` / `hnsw_ef_construction` / `hnsw_build_nav_int8` / `vector_rebase_min_docs` / `vector_ivf_nlist` / `vector_ivf_nprobe` / `vector_diskann_r` / `vector_diskann_l_build`）透传 + `{auto_checkpoint_min_docs, N}` 透传。 | ✅ |
| **M4-3** | Erlang facade：`open/2` 选项白名单加 `vector_engine` / 各引擎调优参数 / `auto_checkpoint_min_docs`；选项文档更新。 | ✅ |
| **M4-4** | 回归：`rebar3 compile`（链接 v4.0.0 通过）+ `rebar3 eunit` 全绿。 | ✅ |
| **M4-5** | examples：Wikipedia 检索库示例（`wiki_hnsw.escript` / `wiki_diskann.escript` / `wiki_common.erl`，移植自 wiser-cpp，embedding 端点经环境变量配置）。 | ✅ |
| **M4-6** | 文档：CHANGELOG（中/英）[4.0.0] 条目 + ROADMAP（中/英）升级条目 + README（中/英）项目状态 / API 表 / 向量双引擎说明 + `CMakeLists.txt` / `bitcask.app.src` 版本对齐。 | ✅ |

---

## M5 — libbitcask 升级 v4.1.0 → v5.0.0（ABI + 盘上格式双破坏）

> submodule 升至 v5.0.0（64 位时间戳 flag-day：`tstamp` / `expiry_at` 全链路
> u32 → u64，Y2038 前瞻；`SOVERSION` 4 → 5；`bitcask.meta` v4 门禁拒开旧 u32
> 纪元库，存量库经上游 `bitcask_migrate tstamp64` 非破坏性离线迁移）；
> 本仓库 `vsn` → 5.0.0。上游已补 v4.1.0 tag，submodule 恢复按 tag 引用。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **M5-1** | submodule pin v4.1.0（`66924e3`）→ v5.0.0（`aaac44c`）+ 嵌套子模块同步。⚠️ 踩坑复现：`rebar.config` pre-hook 的 `git submodule update` 按父仓库 index 里的 gitlink 复位子模块——checkout 后必须先 `git add third_party/libbitcask` 再编译，且编译**之后**验证 `git describe`（详见 build_system 备忘）。 | ✅ |
| **M5-2** | NIF 适配：`nif_cask_iter.cpp` ×2 迭代器 `tstamp` 返回 `enif_make_uint` → `enif_make_uint64`（u32 版对 u64 实参静默截断）。其余触点为零：写路径均走默认 tstamp；`expiry_secs` / `expiry_grace_time` 上游仍 u32（时长非时刻）；Erlang 侧 tstamp 本就是任意精度整数。 | ✅ |
| **M5-3** | 回归：`rebar3 compile`（链接 v5.0.0 通过）+ `rebar3 eunit` 64/64 + 盘上格式逐字节抽查（data header 27B / DocValue v4 / meta `BCME 04` / hint `BCH4`）+ 旧库门禁冒烟（v4.1.0 库拒开；NIF 现映射 `{error, unknown}`——上游把门禁错误包成 `kIo`/errnum 0，可提 issue 争取独立错误码）。 | ✅ |
| **M5-4** | 文档：CHANGELOG（中/英）[5.0.0] 条目 + ROADMAP（中/英）升级条目 + README（中/英）发布条目 + `CMakeLists.txt` / `bitcask.app.src` 版本对齐。 | ✅ |

---

## M7 — 本地嵌入后端（llama.cpp）+ 独立 embedder 进程

> **不涉及 libbitcask 升级**（submodule 仍 v5.0.0，无 ABI / 盘上格式变更）。
> 新增 submodule `third_party/llama.cpp`（tag `b10257`）。默认不构建，
> `BITCASK_WITH_LLAMA=1` 打开；关掉时构建产物与 5.0.0 一字不差。
> 本仓库 `vsn` → 5.1.0。参考 `~/workspace/coxswain` 的同类 shim（那边是 Chez
> Scheme FFI，这边是 Erlang NIF）。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **M7-1** | vendor llama.cpp（tag `b10257`，浅克隆）+ CMake 接入：`BITCASK_WITH_LLAMA` 开关、`GGML_NATIVE=OFF` + `GGML_BACKEND_DL=ON` + `GGML_CPU_ALL_VARIANTS=ON` 三件套、`BUILD_SHARED_LIBS` 用后即收（目录作用域会继承，不收回去后面每个 add_subdirectory 都跟着变共享）、变体递归收集平铺进 `priv/` + `add_dependencies` 挂进构建图（`EXCLUDE_FROM_ALL` 下没人依赖 = 不构建，失败是静默的：0 个后端 → 降级）。 | ✅ |
| **M7-2** | NIF shim `cpp/llama/nif_llama.cpp`：model 资源（`llama_context` 非线程安全 → 每句柄一把互斥量）、`embed` 挂 `DIRTY_JOB_CPU_BOUND`、日志改道、加载期拒绝 pooling=NONE、零范数/空输入报错、**向量长度用 `n_embd_out` 不是 `n_embd`**（coxswain 那份用的是后者，带投影层的模型上是潜在 bug）。⚠️ 自己写出又改掉一处真 bug：错误路径上手工 `~ModelRes()` 后再 `enif_release_resource`，后者引用计数归零会**再调一次析构器**。 | ✅ |
| **M7-3** | Erlang 侧：`bitcask_llama_nifs`（低阶）+ `bitcask_embedder_llama`（provider）。⚠️ `on_load` 里 `load_nif` 失败**必须仍返回 ok**（记进 persistent_term）——返回非 ok 会让 BEAM 撤掉整个模块，之后连 `available/0` 自己都是 `undef`，探针不可用。冒烟时撞出来的。 | ✅ |
| **M7-4** | 性能定标。⚠️ `n_threads` 默认值必须用 `logical_processors_available` 而非 `logical_processors`：后者报宿主机核数、不认亲和性掩码（实测机器上 8 vs 128），按后者算出 126 线程比最优**慢 20 倍**且无任何报错。定标结果：查询 33–35 ms、文档（276 tok）≈ 890 ms、`n_ctx` 512→8192 查询 35→57 ms。 | ✅ |
| **M7-5** | 独立 embedder 进程：`bitcask_embedder_server`（gen_server，`terminate/2` 释放）+ `bitcask_embedder_proxy`（provider）+ `open/2` 的 `{embedder, ServerRef}`；由 `bitcask_sup` 按 app env 启动，配了起不来就让整个 application 死掉（静默降级更危险）。⚠️ 连带修 `bitcask:open/2` 吞掉 `application:start` 失败的问题——不修的话"死掉"是无声的。 | ✅ |
| **M7-6** | 两档 embedder 分清 + 共享逻辑收口：HTTP 档无状态不需要进程、内置档有状态必须串行；`bitcask_embedder_util` 收掉 openai / anthropic 两份**逐字重复**的 `truncate_utf8` / `strip_partial` / `validate_dims` / `validate_limits`（我一度又加了第三份）。 | ✅ |
| **M7-7** | GPU 构建期：`BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN` 各 `AUTO\|ON\|OFF`、`ggml-cuda` / `ggml-vulkan` target 缺失守卫、CUDA 运行时平铺进 `priv/`（`GGML_STATIC` 不能用——它加全局 `-static`，与必须开的 `BUILD_SHARED_LIBS=ON` 冲突）、架构覆盖 Maxwell..Blackwell 不收窄。⚠️ Vulkan 的 AUTO 必须 loader/glslc/SPIRV-Headers **三个都确认**再开：ggml-vulkan 那两个 `find_package` 都是 REQUIRED，只探到一个就打开会直接把构建炸掉，而 AUTO 的意义是"没有就安静地不编"。**Vulkan 构建路径已在本机实测通过**（SDK 1.4.309 → `priv/libggml-vulkan.so`）。 | ✅ |
| **M7-7b** | GPU 运行期：NIF 加回落（回落必须把**建上下文**也圈进去，最常见的显存不足倒在 compute buffer 上）+ 诚实上报。⚠️ 第一版上报在撒谎：纯 CPU 包上请求 `n_gpu_layers=999`，llama 不报错、默默不卸载，而我按请求值报 `effective=999`；改成按有没有 GPU 设备算。⚠️ 第二个撒谎：改写 `n_gpu_layers` 之后才记 `requested`，"请求 999"被报成"请求 0"（既有测试拦下的）。⚠️ 第三个：包里编了 Vulkan 没编 CUDA 而调用方要 `cuda` 时，给的是通用的"有 GPU 后端但没设备"——改成按**请求的那一族**判。 | ✅ |
| **M7-7c** | 运行期后端自决策：`backend => auto\|cuda\|vulkan\|cpu`（auto 按 CUDA > Vulkan > CPU）+ `n_gpu_layers => auto`。⚠️ **显式给 `mp.devices` 是正确性要求**：CUDA 与 Vulkan 同时编入时两者各自枚举同一张物理卡，`devices=NULL` 会让 llama 把它当两张去切分——不报错，只是显存重复占用 + 慢/OOM。 | ✅ |
| **M7-7d** | 多卡：默认单卡 + 数据并行。⚠️ 原实现是错的——把选中族的**全部** GPU 传给 `mp.devices`，而 `split_mode` 默认 `LAYER`，4 卡机器上会把 0.6B 模型切到 4 张卡（跨卡传输 + 把 4 卡并行浪费在一条串行路径上）。改成默认 `split_mode=NONE` + `gpu_index=0`；多卡按 `backend_info` 设备表开 N 个进程各绑一张卡。`gpu_index` 越界报错不静默退回 CPU。 | ✅ |
| **M7-8** | 构建期 / 运行期分离：构建期事实（编没编 CUDA / Vulkan、toolkit 版本、架构列表）烧进 `.so` 由 `build_info/0` 自报，运行期事实由 `backend_info/0` 给（设备表带 type / backend / 显存），`gpu_status/0` 对齐成 `ok` / `cpu_only_build` / `no_gpu_device`。只看运行期分不清"包里没编"和"机器没驱动"，而两者修法完全不同。**本机恰好给出了这个区分的真实样本**：包里编了 Vulkan、机器没有卡 → `no_gpu_device` 而非 `cpu_only_build`。 | ✅ |
| **M7-8b** | 探测脚本收敛成**纯构建期工具**（运行期决策已移到 Erlang 侧，部署机上既没这个仓库也没 cmake）。⚠️ 脚本自己有两个 bug：探测工程用 `LANGUAGES NONE` 导致 `find_package(Vulkan)` **假阴性**（真实构建是 CXX，找得到）——探测条件必须与真实构建同条件，否则答案不算数；以及 `set(...) ; if(...) ; endif()` 写成一行，`;` 在 CMake 里是列表分隔符不是语句分隔符，configure 直接失败而三项全判缺失。 | ✅ |
| **M7-7e** | 多卡数据并行池 `bitcask_embedder_pool`：N 个 worker 各绑一（组）卡，app env 的 `instances` 只收**显式卡（组）列表**（不做 auto——共享机器上别的租户也在用 GPU）。⚠️ **协调者不在热路径上**：池是 supervisor 不是 gen_server，worker 用稳定注册名（重启后名字不变、缓存不失效），proxy 直接打 worker 零跳；转发式实现会让协调者自己变成新的串行点。派发取消息队列最短者。⚠️ 启动串行（N 次模型加载）是故意的：并行/懒加载会让 worker 的启动失败绕过 supervisor 启动期检查，而"配了却起不来就让 application 死"正是靠它成立。 | ✅ |
| **M7-7f** | `split_mode` 提为显式配置项 + `gpu_index` 收卡组；组内多卡缺省 `layer`。⚠️ `split_mode=none` 配多卡当场拒绝（不默默只用第一张）。装不下加**提前粗检**（GGUF 大小 vs 组内可用显存）→ `{error,{model_too_large,_}}` 并列出三条出路；⚠️ 绝不用它自动决定 `n_gpu_layers`。不做粗检的话，装不下 = llama OOM → 回落 → **整体退回纯 CPU**，90% 本来装得下的层白白挪回去。 | ✅ |
| **M7-7g** | 池化过程中的三个错：① supervisor 的 `init/1` **没有** `{stop,Reason}`（那是 gen_server 的），用了被判 `{error,{bad_return,_}}`，真原因埋两层——校验挪到 `start_link`（本来就是纯函数）；② `supervisor:which_children` 返回**倒序**，要按 index 重排；③ 测试函数名 `_test_` 后缀是 generator，写成普通函数会被 eunit 判 "not a test" —— **静默不跑，比失败更糟**。 | ✅ |
| **M7-7h** | 批量 embed 入口：`bitcask_embedder:embed_batch/2`（**可选**回调，provider 没实现自动退化成逐条，调用方无感）+ llama 原生批量（一次 decode 喂多条序列）。⚠️ **`n_ctx` 必须乘 `batch_size`**：llama 的 n_ctx 是所有序列共享的总预算（`n_ctx_seq = n_ctx / n_seq_max`），不乘就把每条文本的可用长度**悄悄缩小 N 倍**。⚠️ 逐条结果而非整批成败——一条坏文档不该让另外 63 条白算。⚠️ C++ 侧按序列数与 token 总数**自动切块**，不切的话 llama_decode 拒绝整块并返回一个不解释原因的负值。**测试最关键的一条是"批量结果与逐条逐字节一致"**——seq_id/pos 填错不报错、维度也对，只是语义悄悄不对。**默认 batch_size=1 不开**：实测短文本 7.0x / 中文本 2.9x，但测量时机器有外部满载进程（load 9.8/8 核），超订放大了批量摊薄的那部分开销，长文本档无可信数据。 | ✅ |
| **M7-7i** | HTTP 档原生批量（openai / anthropic）：一次请求带数组 + `max_batch` 切块。⚠️ **按 `index` 字段归位，不按返回顺序 zip**——"data 与 input 同序"只是常见实现的行为不是协议保证，按顺序 zip 会**把向量配到别的文档上**（不报错、维度也对）。⚠️ 空串客户端挡掉，否则整个请求 400 废掉同批 63 条。顺带把两个 provider **完全重复**的请求/超时/解析收进 `bitcask_embedder_util`，解析做成纯函数并补 14 条不打网络的单测——此前只有一个默认跳过的手动用例（要真实端点），等于没测过。 | ✅ |
| **M7-9** | 回归：`rebar3 eunit` **132/132**（23 本地嵌入 + 31 embedder 进程/池/批量 + 14 HTTP 解析；NIF 未构建时优雅跳过 0.05s）+ `rebar3 xref` 干净 + `rebar3 dialyzer` **零警告**（`plt_extra_apps: [inets]`——用它而非把 inets 加进 `applications`，运行期依赖不变） + 端到端（`open` 配 embedder → `put` 自动 embed → `search_vector`/`search_hybrid`）。⚠️ **CUDA 编译与真实 GPU 运行路径未实测**（开发机无驱动无 toolkit；Vulkan 只是编出来、没有卡可跑）。池的机制已用 mock provider 测透（稳定名字、直接派发、忙闲换人、worker 被 kill 不拖垮整池、`open` 收池名、app env 端到端），但**多卡上的真实 GPU 行为没跑过**——有卡的机器上跑一遍才算真验证。 | ✅ |
| **M7-10** | 文档：`doc/local-embedding-zh.md` / `-en.md` + CHANGELOG（中/英）[5.1.0] + ROADMAP（中/英）5.1.0 落地 + README（中/英）发布条目 + `api-zh/en.md` 选项表 + `USAGE.md` + `bitcask.app.src` 版本对齐。 | ✅ |

---

## 明确排除（V7+ 或永久取消）

| 条目 | 决策 | 理由 |
|------|------|------|
| Product Quantization (PQ) codebook | ❌ V7+ | 离线训练管线是独立项目；V6.4.1 留 seam |
| HNSW 外存 mmap | ❌ V7+ | V3.5 BCVS 已给 46×；100M+ 规模问题是另一类设计 |
| ord 重编号 | ❌ 正式取消 | format "never reused" 约束正确；gap 测量结论正式取消 |
| wildcard trie/FST/DAWG | ❌ V7+ | 中缀全扫 141μs 已亚毫秒，suffix array/n-gram 收益用户无感知，工程 ROI 不足 |
| value 压缩 zstd/LZ4 | ❌ 永久取消 | P6 mmap 零拷贝读路径已全量落地，压缩破坏 mmap 直接映射，不可逆 |
| A4-P2 live gate re-open | ❌ 永久取消（被 P14e 取代） | P14e S4 统一 checkpoint + 自门模型已实现水位恢复；docmap 作为 search.ckpt 段持久化，4-way 配对门删除 |
| WAL group-commit 跨线程 | ❌ 永久取消（被 P14e 取代） | P14e S6 删除整个 WAL 系统，统一 checkpoint 替代增量 WAL 持久化，无 WAL 可优化 |
