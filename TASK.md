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
