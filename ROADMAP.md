# Bitcask 路线图（Roadmap）

English: [`ROADMAP_EN.md`](ROADMAP_EN.md)。详细子任务拆分与历史见 [`TASK.md`](TASK.md)。

状态图例：✅ 承诺（will do） · ⚠️ 备选（candidate，按 gate 决策）。

---

## 2.1.1 规划

围绕**向量库的内存 / 磁盘瓶颈**与**读路径**的三项优化。

### P5 — HNSW int8-only 内存模式 ✅

> 详细设计：[`doc/hnsw-int8-only-design-zh.md`](doc/hnsw-int8-only-design-zh.md)

**问题**：dot 模式下 HNSW 内存里同时存 f32 `vecs` + int8 `qcodes`（int8 为 VNNI
提速、反而 +25% 内存）；P3 落盘 int8 只省磁盘、不动内存——向量库的真正墙是内存。

**方案**：丢掉常驻 f32，建图 / 精排都走 int8（查询侧也量化、用 VNNI int8×int8），
opt-in `{vector_inmem_int8, true}`，可与 P3 落盘 int8 组合（盘 + 内存都省）。

**实测收益**（合成簇 dim=2560，`hnsw_test::Int8OnlyMemoryAndRecall`）：向量内存
**−80%（~5×）**，1M 向量 12.81 GB → 2.57 GB；代价 **recall@10 约 −3%**（1.0 → 0.9675）。

**子任务**：P5a 配置 + NodeChunk 裁掉 vecs；P5b open/meta 接线 + 重开一致校验；
P5c 真实 qwen3 语料召回 gate 定默认。
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

**子阶段**：**P14a** 纯重命名 + 契约文档化（零格式/逻辑变更、旧名兼容读）；
**P14b** wm_min 单趟回放（替双轨 + 消门悬崖）；**P14c** 周期性 checkpoint（`checkpoint_interval`
+ worker 静止窗口）；**P14d** 摘 bm25 WAL（profiling 驱动决定是否留 `terms` 纯缓存）。
**收益**：命名契约清晰 · 写放大 2→1 · 稳态文件数减少（无 `.wal`）· 崩溃后不再全量 fold。

---

## 开发顺序（2.1.1，重拍）

> P 编号是**标识符不是顺序**。下列波次按**依赖 + 风险 + 收益**排，波内可并行，
> ⚠️ 备选项一律压到其依赖满足之后、波次末尾。

- **W0 清债（立即，零风险）**：**P14a** 纯重命名——独立可上线，当场消除命名混乱，不阻塞任何项。
- **W1 内存墙（独立 headline）**：**P5** HNSW int8-only（向量内存 −80%，已实测，无外部依赖）。
- **W2 读路径地基**：**P6** sealed mmap → **P9** read fd LRU（P6「mmap 后 close fd」的互补，紧随）。
- **W3 恢复核心**：**P14b** 单趟回放——fold sealed 文件时直接吃 W2 的 mmap；消门悬崖、抬重用率。
- **W4 merge**：**P8** HNSW merge 门控 + **P11** merge I/O（同 merge 主题、捆绑）→ **P13** open 后台 merge。
- **W5 周期 checkpoint + 去 WAL**：**P14c** 周期 checkpoint（触发点对齐 W4 的 merge/open-merge 时机）
  → **P14d** 摘 bm25 WAL（依赖 P14b 回放已验证）。
- **W6 查询（顺序无关，可浮动）**：**P10** search_hybrid 两路并行（独立，任意波次可插）。
- **W7 备选（gate 后置）**：**P7** 派生值 compute cache（依赖 P6）⚠️ · **P12** meta_blobs 有界（filter 热路径）⚠️。

**关键依赖边**：P7→P6 · P9↔P6 · P14b 受益于 P6 · P14c 对齐 P8/P13 的 merge 时机 · P14d 依赖 P14b。
**为何 P14 拆两段**：P14b（恢复模型）须先于 merge 改动，给 P8/P13 一个干净的回放语义；
P14c（周期 checkpoint）须**后于** P8/P13——它把 checkpoint 触发挂在 merge/open-merge 静止点上。

---

## 已落地（2.1.0，持久化优化 P1–P4）

- **P1** Hint 写缓冲（写路径 syscall 减半）
- **P2** merge 不重分词（compact 替代 rebuild_index）
- **P3** 向量落盘 int8 量化（opt-in `{vector_quantized}`，~4× 磁盘）
- **P4** 单写者组提交（`{sync_strategy,{puts,N}}`）

详见 [`CHANGELOG.md`](CHANGELOG.md)。
