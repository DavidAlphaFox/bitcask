# 向量库实现任务 (TASK.md)

在 bitcask 引擎之上构建**混合检索向量库**（BM25 ngram + embedding ANN）。
完整设计见 `doc/vector-db-design-zh.md`。本文件只跟踪「接下来做什么」。

## 约定

- 每个子任务**先 standalone 编译+跑测试**验证，再跑全量 `ctest`。
- 每步尽量配套单元测试；改磁盘格式必更新黄金 fixture。
- 命名/分层沿用 V1：`bitcask::<子系统>` 命名空间，`cpp/include/bitcask/*.hpp` +
  `cpp/src/<子系统>/*.cpp` + `cpp/tests/*_test.cpp` + CMake target。

---

## ✅ V1 — typed-record 存储地基（已完成，ctest 79/79）

upsert/get/remove/update + 崩溃恢复 + 文件滚动；文本与向量存取，**尚不能检索**。
落点：`format`(type+ord)、`codec`(doc value 打包)、`data_file`、`index`(Index 侧表)、
`collection`(门面+恢复)。详见 git 工作区与 `doc/vector-db-design-zh.md` §2/§3.1/§5/§8。

---

## ▶ V2 — BM25 原生倒排 + `search_text`（进行中）

目标：文本可按 BM25 检索。设计依据 §3.2 / §3.4 / §6。

| # | 目标 | 新建/改动 | 关键内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| **V2.1** | analyzer | `analyzer.hpp`（抽象基类+工厂）、`ngram_analyzer.hpp`、`whitespace_analyzer.hpp`、`cjk_detect.hpp`、`src/text/analyzer.cpp`、utf8proc(FetchContent) | NFKC+casefold → CJK bi/tri-gram + 拉丁空白切分 → term→tf。抽象工厂模式：`AnalyzerFactory::create(config)` → `NgramAnalyzer`/`WhitespaceAnalyzer` | 22/22 测试通过（CJK/拉丁/混合/标点/工厂） | ✅ |
| **V2.2** | 倒排结构 | `inverted.hpp/.cpp`（新，`bitcask::bm25`） | `term → PostingList[(ord,tf)]`(按 ord 升序)；`add_doc(ord, terms)`/`remove_doc(ord)`；全局 `N`/`sum_doc_len`；按 term hash 分片锁(§4) | add/remove、posting 有序 | |
| **V2.3** | doc_len 回填 | `index.hpp/.cpp` | `put_doc` 增 `doc_len` 入参（或单独 setter），填 `slots[ord].doc_len`（V1 恒 0） | doc_len 持久于侧表 | |
| **V2.4** | BM25 评分 + 查询 | `inverted.cpp` | DAAT：query 切词 → 取 posting → 累加 `IDF·tf·(k1+1)/(tf+k1·(1−b+b·dl/avgdl))`，**跳过 `live=0`** → top-k 堆。`k1/b` 可配 | 已知语料打分/排序 | |
| **V2.5** | 接入 Collection | `collection.hpp/.cpp` | upsert：切词 → `inverted.add_doc` + 写 doc_len；remove：`inverted.remove_doc`（或靠 live 过滤）；新增 `search_text(query,k) → [{ext_id,score}]`（经 `ord→ext_id` 翻译） | 端到端 search_text | |
| **V2.6** | 恢复重建倒排 | `collection.cpp` `recover()` | 侧表重建后，遍历 live 文档读 value→切词→`add_doc`（V2 先全量重切词；**倒排段持久化留作后续**） | 重开后 search_text 一致 | |
| **V2.7** | 接线 | `CMakeLists.txt`、`tests/` | 新 target `bitcask_text`/`bitcask_bm25`；新增测试目标；全量 ctest 绿 | — | ✅ (bitcask_text) |

**不在 V2**：HNSW/向量检索、merge 时重算 df、Block-Max WAND、倒排段持久化
（恢复先全量重切词）。df 漂移：V2 查询过滤死点 + 接受漂移（merge 重算在 V4）。

---

## V3 — HNSW 单图 + `search_vector`（§3.3 / §6）

- V3.1 距离 kernel：cosine/L2/dot，AVX2(x64v3)/NEON(ARM)；LE f32。
- V3.2 HNSW 单图：节点=ord，邻居链；per-node 细粒度锁；`insert(ord, vec)`/`search(q, k, ef)`/`markDelete(ord)`。
- V3.3 内存向量数组（`dim×f32`，下标=ord）；从 `kDoc` value 加载。
- V3.4 接入 Collection：upsert 插图、remove markDelete、`search_vector(qvec,k,{ef})`。
- V3.5 恢复：遍历 live 文档读向量重插图（图快照 `hnsw/graph.ann` 持久化留作后续）。
- V3.6 接线 + 端到端测试（召回基本验证）。

**注意**：merge 整体重建图在副本上做、原子换图（§11）；V3 暂无 merge，死点累积。

---

## V4 — 单域 merge（§7）

- V4.1 fstats 接回 Index（V1 已保留位）：put/remove 增量更新 live/total bytes。
- V4.2 merge_policy `decide()`：死字节率 ∪ 删除率触发。
- V4.3 merge pass：重写存活 data record + **ord 重编号(remap)** + purge 倒排死点 + 重算 `df/N/avgdl` + 整体重建 HNSW 图。
- V4.4 checkpoint：merge 后 flush `bm25/seg-*.inv` + `hnsw/graph.ann` + `index.ckpt`（§8.2）。
- V4.5 恢复走快照+回放尾巴（§8.3），替代 V2/V3 的全量重建。

---

## V5 — 混合检索 + metadata filter（§6）

- V5.1 `search_hybrid(query, qvec, k, {fusion, w...})`：两路 top-k → **RRF**(c=60) 融合。
- V5.2 metadata filter：先做「查询后过滤」（解 meta msgpack/CBOR 判定）。
- V5.3 CollectionOptions 暴露 dim/metric/ngram/bm25/hnsw 参数（§9 API 草案）。

---

## V6 — 性能与规模化

- V6.1 锁分片落地（§4：ext2ord/slots 分片、倒排 term 分片确认、HNSW 自带锁）。
- V6.2 Block-Max WAND 加速 BM25 top-k。
- V6.3 倒排 posting 内存分块压缩（§3.2 内存预算）；`live` 改 Roaring。
- V6.4 量化(scalar/PQ)、IVF、外存等超百万预留点的评估（接口已留）。

---

## NIF 层重构（cpp/nif/）

重构 C++ NIF 桥接层，目标：消除代码重复、修复安全缺陷、统一资源管理模式。
当前 8 文件 ~1025 行。

### P0 — 安全缺陷修复

| # | 改动 | 文件 | 状态 |
|---|------|------|------|
| N0.1 | `bytes_to_binary` 缺少 `enif_alloc_binary` 返回值检查（OOM 时 memcpy 空指针） | `nif_cask.cpp` | ✅ 由 N1.3 合并解决 |
| N0.2 | `make_uint64_bin` 缺少 `enif_alloc_binary` 返回值检查 | `term_conv.hpp` | ✅ |

### P1 — 消除代码重复

| # | 改动 | 描述 | 文件 | 状态 |
|---|------|------|------|------|
| N1.1 | 统一资源分配 | 删除 `make_cask_resource`/`make_iter_resource`，改用 `resources.hpp` 中已有的泛型 `make_resource<T>` 模板 | `nif_cask.cpp` | ✅ |
| N1.2 | 合并 fold_start / fold_start4 | 提取 `fold_start_impl` 内部函数，两个入口仅做参数解析 | `nif_cask.cpp` | ✅ |
| N1.3 | 合并 bytes_to_binary / make_binary_from_bytes | 删除 `bytes_to_binary`，统一用 `term_conv.hpp` 的 `make_binary_from_bytes`（同时修复 N0.1） | `nif_cask.cpp`, `term_conv.hpp` | ✅ |
| N1.4 | 提取 handle 验证辅助 | 对 6 个纯 handle 验证函数提取 `checked_cask_handle` 辅助 | `nif_cask.cpp` | ✅ |

### P2 — 模块拆分 + 函数长度控制

| # | 改动 | 状态 |
|---|------|------|
| N2.1 | 创建 `nif_helpers.hpp/cpp` — 共享辅助函数到 `detail` 命名空间 | ✅ |
| N2.2 | 拆分 `nif_cask.cpp` → CRUD + `nif_cask_iter.cpp`（迭代）+ `nif_cask_admin.cpp`（管理） | ✅ |
| N2.3 | 重构 `parse_options` → `parse_atom_option` + `parse_tuple_option` + `parse_merge_option` | ✅ |
| N2.4 | 更新 `nif_main.cpp` 文件分布注释 | ✅ |
| N2.5 | 清理 `atoms.hpp/cpp` — 标记 legacy atom（M6 后下线） | ✅ |
| N2.6 | `nif_cask_admin.cpp` 中 `needs_merge` 提取 `make_string_list` 到 `detail` 复用 | ✅ |

---

## 遗留清理（M6 式，可独立排期）

- 物理删除不接构建的 legacy 引擎源码：`keydir.*`/`keydir_registry.*`/`merger.*`/
  `merge_policy.*`/`cask.*`，以及存档的 `cpp/nif/`（向量引擎将来需自己的 NIF）。
- `cpp/bench/`（cask_bench/keydir_bench）引用已弃符号，opt-in OFF；按需重做或删。
