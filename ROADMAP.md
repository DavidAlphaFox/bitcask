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

---

## 已落地（2.1.0，持久化优化 P1–P4）

- **P1** Hint 写缓冲（写路径 syscall 减半）
- **P2** merge 不重分词（compact 替代 rebuild_index）
- **P3** 向量落盘 int8 量化（opt-in `{vector_quantized}`，~4× 磁盘）
- **P4** 单写者组提交（`{sync_strategy,{puts,N}}`）

详见 [`CHANGELOG.md`](CHANGELOG.md)。
