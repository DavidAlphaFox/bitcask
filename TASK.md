# Bitcask 统一架构开发任务 (TASK.md)

在 bitcask 引擎之上构建**统一存储引擎**：将 Cask（纯 KV）和 Collection（KV + BM25 搜索）
统一为一个引擎，共享存储层和 merge。完整设计见 `doc/unified-architecture-plan-zh.md`。

## 约定

- 每个子任务**先 standalone 编译+跑测试**验证，再跑全量 `ctest`。
- 每步尽量配套单元测试；改磁盘格式必更新黄金 fixture。
- 所有注释使用中文，遵循项目现有头文件注释风格。
- 不考虑向后兼容性。

---

## 历史任务（已完成）

### ✅ V1 — typed-record 存储地基（ctest 79/79）

### ✅ V2 — BM25 原生倒排 + search_text（ctest 130/130）

### ✅ V2.8 — BM25 精度与健壮性优化

### ✅ V2.9 — NIF 接线

### ✅ V2.10 — Jieba 中文分词器集成（ctest 144/144）

### ✅ NIF 层重构 Phase 1-5

---

## 当前任务：统一架构（U0 - Unification）

### 设计目标

1. Cask 和 Collection 共享同一套存储和 merge
2. Collection 的索引建立在 Cask 之上
3. 配置索引能力时支持搜索，不配置时退化为 KV
4. 所有 value 使用 DocValue 格式（统一磁盘格式）
5. 所有模式分配真实 ord（统一标识）
6. 支持 KV → 索引的离线升级

---

### U1 — Phase 1：KeyDir 增加 ord 字段

**目标**：KeyDir 成为 ord 的唯一来源，为后续搜索层提供 `key → ord` 映射。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U1.1** | 数据结构加 ord | `keydir.hpp` | `SingleEntry` / `EntryProxy` 增加 `uint64_t ord = 0` | ✅ |
| **U1.2** | put 签名加 ord | `keydir.hpp` / `keydir.cpp` | `put()` 末尾加 `uint64_t ord = 0` 参数；实现中将 ord 存入 SingleEntry / MultiEntry | ✅ |
| **U1.3** | alloc_ord | `keydir.hpp` / `keydir.cpp` | 新增 `uint64_t alloc_ord()`（unique_lock, 返回 `next_ord_++`）；私有成员 `uint64_t next_ord_ = 0` | ✅ |
| **U1.4** | advance_ord | `keydir.hpp` / `keydir.cpp` | 新增 `void advance_ord(uint64_t ord)`（恢复用，推进 `next_ord_`） | ✅ |
| **U1.5** | get 填充 ord | `keydir.cpp` | `get()` / `find_at_epoch_locked()` 填充 `EntryProxy.ord` | ✅ |
| **U1.6** | deep_copy 含 ord | `keydir.cpp` | 拷贝 `next_ord_` | ✅ |
| **U1.7** | 单元测试 | `keydir_test.cpp` | alloc_ord 单调递增 / advance_ord 不冲突 / put+get 带 ord / MultiEntry 场景 | ✅ |
| **U1.8** | 回归验证 | 全量 | 144/144 现有测试通过（新增参数有默认值） | ✅ |

---

### U2 — Phase 2：Cask 适配 DocValue + ord + bitcask.meta

**目标**：Cask 的 put/get 使用 DocValue 格式，始终分配 ord，open 时检查/创建 bitcask.meta。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U2.1** | bitcask.meta 格式 | 新建 `meta_file.hpp` / `meta_file.cpp` | `MetaConfig` 结构 + `read_meta()` / `write_meta()` / `meta_exists()`；二进制格式 "BCME"+配置 | ✅ |
| **U2.2** | CaskOptions 扩展 | `cask.hpp` | 增加 `std::optional<SearchLayerConfig> search_config`（Phase 3 定义 SearchLayerConfig，此处 forward declare） | ✅ |
| **U2.3** | CaskError 新增 | `cask.hpp` | `kNoIndex` / `kModeMismatch` / `kAnalyzerMismatch` / `kCannotUpgrade` | ✅ |
| **U2.4** | open 模式检查 | `cask.cpp` | `Cask::open()` 读 bitcask.meta → 验证模式匹配 → 空目录创建 meta → 非空目录报错 | ✅ |
| **U2.5** | put 编码 DocValue | `cask.cpp` | `put()` 内部：`alloc_ord()` → `encode_doc_value{text=value}` → `write(kDoc, ts, ord, key, encoded)` → `keydir.put(..., ord)` | ✅ |
| **U2.6** | get 解码 DocValue | `cask.cpp` | `get()` 内部：pread → `decode_doc_value()` → KV 模式提取 text 段返回 binary；`GetResult` 增加 `ord` | ✅ |
| **U2.7** | remove 带 ord | `cask.cpp` | `remove()` 分配 ord → 写墓碑 → `keydir.remove()`；`keydir.put()` 调用传 ord | ✅ |
| **U2.8** | load_keydir_from_disk 改为始终 data fold | `cask.cpp` | 从 record header 读 ord（`view.ord`）→ `keydir.put(..., view.ord)` + `keydir.advance_ord(view.ord)` | ✅ |
| **U2.9** | CaskIter Entry+ord | `cask.hpp` / `cask.cpp` | `CaskIter::Entry` 增加 `uint64_t ord`；`next()` 从 `EntryProxy::ord` 取值 | ✅ |
| **U2.10** | NIF 适配 put/get 变更 | `nif_cask.cpp` | put 适配新签名（put 仍返回 ok）；get 适配 `GetResult+ord`（返回给 Erlang 时忽略 ord） | ✅ |
| **U2.11** | 回归测试 | 全量 | 所有 C++ 测试通过 + NIF 端到端验证 | ✅ |

---

### U3 — Phase 3：SearchLayer 模块

**目标**：创建独立的 SearchLayer 类，封装 Index + InvertedIndex + Analyzer。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U3.1** | SearchLayerConfig | `search_layer.hpp` | 配置结构：`AnalyzerConfig + Bm25Params` | ✅ |
| **U3.2** | SearchLayer 类 | `search_layer.hpp` / `search_layer.cpp` | 新建类：持有 `Index + unique_ptr<InvertedIndex> + unique_ptr<Analyzer>` | ✅ |
| **U3.3** | on_write | `search_layer.cpp` | 接收 (key, ord, text, loc, ts)：切词 → `index.put_doc()` → `inverted.add_doc()` | ✅ |
| **U3.4** | on_delete | `search_layer.cpp` | 接收 (key)：取旧 DocSlot → `inverted.remove_doc()` → `index.remove()` → 返回旧 ord | ✅ |
| **U3.5** | on_relocate | `search_layer.cpp` | 接收 (key, ord, new_loc)：`index.put_doc()` 更新 loc（ord 不变） | ✅ |
| **U3.6** | search_text/phrase | `search_layer.cpp` | 切词 → `inverted.search()` → ord→key 翻译 → 返回 `vector<SearchHit>` | ✅ |
| **U3.7** | recover_doc/tomb | `search_layer.cpp` | 恢复用：全量 analyze + add_doc | ✅ |
| **U3.8** | snapshot save/load | `search_layer.cpp` | 包装 `inverted_->save/load` | ✅ |
| **U3.9** | 单元测试 | `search_layer_test.cpp` | write → search → delete → search / on_relocate / recover 场景 | ✅ |
| **U3.10** | CMake 接线 | `CMakeLists.txt` | 新增 `bitcask_search` target + `search_layer.cpp` | ✅ |

---

### U4 — Phase 4：Cask 集成 SearchLayer + 统一 put/get

**目标**：Cask 持有 SearchLayer，搜索模式下 put 自动建索引，get 返回完整信息。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U4.1** | Cask 持有 SearchLayer | `cask.hpp` | `unique_ptr<SearchLayer> search_` + `has_search()` + `search()` | ✅ |
| **U4.2** | open 创建 SearchLayer | `cask.cpp` | `if (opts.search_config) search_ = make_unique<SearchLayer>(*opts.search_config)` | ✅ |
| **U4.3** | put 增加搜索通知 | `cask.cpp` | put 后通过 IndexPool 异步通知 `search_->on_write()` | ✅ |
| **U4.4** | put_doc 方法 | `cask.hpp` / `cask.cpp` | 新增 `put_doc(key, DocInput, tstamp)`：编码 DocValue（含 text+meta+vector）+ 搜索通知 | ✅ |
| **U4.5** | get 索引模式返回 map | `cask.hpp` / `cask.cpp` / `nif_cask.cpp` | `GetResult` 扩展含 meta；NIF 层索引模式返回 `#{text => ..., meta => ...}` | ✅ |
| **U4.6** | search_text/phrase | `cask.hpp` / `cask.cpp` | 新增 `search_text(query, k)` / `search_phrase(query, k)`：委托 SearchLayer | ✅ |
| **U4.7** | 恢复路径集成 SearchLayer | `cask.cpp` | fold 中 `decode_doc_value` → 提取 text → `search_->recover_doc()` | ✅ |
| **U4.8** | 端到端测试 | `cask_test.cpp` | KV put/get + 索引 put/get/search + 恢复 + 一写多读 | ✅ |

---

### U5 — Phase 5：Merge 支持 ord + SearchLayer

**目标**：merge 保留 ord，合并后通知 SearchLayer 更新定位。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U5.1** | run_merge 重载 | `merger.hpp` / `merger.cpp` | 新增 `SearchLayer* search` 参数（nullable） | ✅ |
| **U5.2** | ord 透传 | `merger.cpp` | 使用 `write(RecordType, ts, view.ord, key, value)` + `keydir.put(..., view.ord)` | ✅ |
| **U5.3** | on_relocate 通知 | `merger.cpp` | `if (search) search->on_relocate(key, ord, new_loc)` | ✅ |
| **U5.4** | Cask::merge 传参 | `cask.cpp` | `run_merge(files, dir, keydir, search_.get(), o_sync)` | ✅ |
| **U5.5** | 测试 | `merger_test.cpp` / `cask_test.cpp` | merge 后 search 结果不变 + merge 后 get 正确 | ✅ |

---

### U6 — Phase 6：统一 NIF + 删除 Collection + 升级命令

**目标**：统一 Erlang API，删除 Collection，合并 Registry，添加升级命令。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U6.1** | 统一 put NIF | `nif_cask.cpp` | `nif_cask_put`：binary → `Cask::put`；索引+map → `Cask::put_doc` | ✅ |
| **U6.2** | 统一 get NIF | `nif_cask.cpp` | `nif_cask_get`：KV → binary；索引 → `#{text => ..., meta => ...}` map | ✅ |
| **U6.3** | search NIF | `nif_cask.cpp` / `nif_main.cpp` | 新增 `cask_search_text/3` + `cask_search_phrase/3`；KV 模式返回 `{error, no_index}` | ✅ |
| **U6.4** | 选项解析扩展 | `nif_helpers.cpp` | `parse_options()` 识别 `{analyzer, ...}` / `{dict_path, ...}` / `{enable_stop_words, ...}` → 填充 `search_config` | ✅ |
| **U6.5** | 函数表更新 | `nif_main.cpp` | 删 collection_* 8 条；增 cask_search_text/cask_search_phrase | ✅ |
| **U6.6** | 统一 Registry | `keydir_registry.hpp` | Slot 增加 `shared_ptr<SearchLayer>`；删除 CollectionRegistry | ✅ |
| **U6.7** | 删除 Collection | 多文件 | 删 `collection.hpp/.cpp` / `collection_registry.hpp/.cpp` / CollectionHandle / collection_registry | ✅ |
| **U6.8** | Erlang facade 更新 | `bitcask.erl` / `bitcask_cpp_nifs.erl` | 统一 `put/3` + `get/2` + `search/2,3`；删除 `collection_*` 导出；新增 `upgrade/2` | ✅ |
| **U6.9** | 升级命令 | `cask.hpp` / `cask.cpp` + NIF | `Cask::upgrade(dirname, config)`：排他锁 → 扫描 → 重建 BM25 → 写 meta + snapshot | ✅ |
| **U6.10** | 全量回归测试 | 全量 | 所有 C++ 测试通过 + Erlang 集成测试通过（196/206，10 Jieba 词典 pre-existing） | ✅ |

---

## 并发架构（T1-T6）

### T1 — ✅ Phase 0：消除 Index::mutex_ 搜索瓶颈

| # | 目标 | 状态 |
|---|------|------|
| T1.1 | Posting 嵌入 doc_len | ✅ |
| T1.2 | 原子 bitmap 替换 live_ | ✅ |
| T1.3 | 评分循环消除锁 | ✅ |
| T1.4 | mutex_ → structure_mutex_ | ✅ |
| T1.5 | live_df 优化（skipped） | ✅ |
| T1.7 | 回归测试 168/182 | ✅ |

### T2 — ✅ Phase 1：引入 TBB + 线程池基础设施

| # | 目标 | 状态 |
|---|------|------|
| T2.1 | CMake 引入 TBB | ✅ |
| T2.2 | 线程池封装 (std::thread + concurrent_bounded_queue) | ✅ |
| T2.3 | 索引任务队列 + IndexTask | ✅ |
| T2.4 | Cask 持有线程池 | ✅ |
| T2.5 | NIF 生命周期 (TbbLifetime) | ✅ |
| T2.6 | 热升级安全 (RT_TAKEOVER) | ✅ |
| T2.7 | 单元测试 8/8 | ✅ |
| T2.8 | 回归测试 176/190 | ✅ |

### T3 — ✅ Phase 2：异步索引队列

| # | 目标 | 状态 |
|---|------|------|
| T3.1 | IndexTask 定义 | ✅ |
| T3.2 | put/put_doc/remove 路径异步化 | ✅ |
| T3.3 | Index Pool worker (std::thread) | ✅ |
| T3.4 | 背压 (bounded queue capacity) | ✅ |
| T3.5 | 有序性保证 (单消费者 FIFO) | ✅ |
| T3.6 | 一致性语义 (get 强一致, search flush) | ✅ |
| T3.8 | 回归测试 176/190 | ✅ |

### T4 — ✅ Phase 3：搜索 NIF 接口变更

| # | 目标 | 状态 |
|---|------|------|
| T4.1 | search NIF flag → ERL_NIF_DIRTY_JOB_CPU_BOUND | ✅ |
| T4.8 | 回归测试 176/190 | ✅ |

### T5 — ✅ Phase 4：InvertedIndex 扩 shard + TBB concurrent_hash_map

| # | 目标 | 状态 |
|---|------|------|
| T5.1 | kShardCount 16→64 | ✅ |
| T5.2 | std::unordered_map → tbb::concurrent_hash_map | ✅ |
| T5.3 | add_doc/search/search_phrase 适配 accessor | ✅ |
| T5.4 | save/load 移除 shared_mutex | ✅ |
| T5.5 | CMakeLists: bitcask_bm25 链接 TBB::tbb | ✅ |
| T5.7 | 回归测试 176/190 | ✅ |

### T6 — ✅ Phase 5：并行搜索 per-shard BM25 评分

| # | 目标 | 状态 |
|---|------|------|
| T6.1 | search() 改用 tbb::parallel_reduce | ✅ |
| T6.2 | 线程本地 ScoreMap 无锁累加 | ✅ |
| T6.3 | join 合并 + 单线程 top-k | ✅ |
| T6.4 | search_phrase 保持串行（位置依赖） | ✅ |
| T6.7 | 回归测试 176/190 | ✅ |

---

## BM25 搜索引擎完善（S1-S8）

> 基于 Lucene/Elasticsearch/Tantivy 行业基准审计，补齐 BM25 实现的关键缺失。

### S1 — P0：修正 IDF 公式为 Lucene 标准

**目标**：当前 IDF 使用简化公式 `log((N+1)/(df+1))`，偏离 Robertson-Sparck Jones 标准，对高频/低频词区分度不足。修正为 Lucene 标准公式。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S1.1** | search() IDF 修正 | `inverted.cpp` | `log((N+1)/(df+1))` → `log(1 + (N - df + 0.5) / (df + 0.5))`（Lucene 标准，避免负 IDF） | ✅ |
| **S1.2** | search_phrase() IDF 修正 | `inverted.cpp` | 同 S1.1，phrase 搜索的 IDF 也要统一 | ✅ |
| **S1.3** | df 参数语义确认 | `inverted.cpp` | 确认传入 IDF 的 df 使用 `live_df`（非 `items.size()`），当前已正确 | ✅ |
| **S1.4** | 回归测试 | 全量 | 相关性排序结果可能变化，需验证测试通过 | ✅ |

---

### S2 — P1：Merge 时重建倒排索引（清理死 posting）

**目标**：当前删除文档的 posting 永不物理删除，内存无限增长。Merge 只调用 `on_relocate()` 更新存储位置，不清理死 posting。需在 merge 时重建紧凑倒排索引。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S2.1** | SearchLayer::rebuild_index | `search_layer.hpp/.cpp` | 新增方法：遍历 Index 中所有 live DocSlot → 清空 InvertedIndex → 逐文档重新 add_doc | ✅ |
| **S2.2** | Merge 后触发 rebuild | `cask.cpp` / `merger.cpp` | merge 完成后调用 `search_->rebuild_index()` 重建紧凑索引 | ✅ |
| **S2.3** | rebuild 期间搜索可用性 | `search_layer.cpp` | rebuild 期间旧索引仍可查询（写新索引到新 InvertedIndex，原子 swap） | ✅ |
| **S2.4** | rebuild 后持久化 | `cask.cpp` | rebuild 完成后 save snapshot 覆盖旧文件 | ✅ |
| **S2.5** | 测试 | `search_layer_test.cpp` / `cask_docvalue_test.cpp` | put→delete→merge→search 验证死 posting 清理 | ✅ |

---

### S3 — P2：布尔查询支持（AND/OR/NOT）

**目标**：当前只有 bag-of-words（所有查询词 OR 关系）。支持布尔组合查询。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S3.1** | QueryAST 数据结构 | 新建 `query.hpp` | `enum Op { MUST, SHOULD, MUST_NOT }`；`struct QueryNode { Op op; string term; vector<QueryNode> children; }` | ✅ |
| **S3.2** | 查询解析器 | 新建 `query_parser.hpp/.cpp` | 解析简单查询语法：`+hello +world`（MUST）、`hello world`（SHOULD）、`-test`（MUST_NOT） | ✅ |
| **S3.3** | bool_search 实现 | `inverted.cpp` | MUST：所有 term posting 取交集；SHOULD：并集评分；MUST_NOT：排除 | ✅ |
| **S3.4** | Cask/SearchLayer 接口扩展 | `cask.hpp` / `search_layer.hpp` | `search_text(query, k, filter)` 或 `search_bool(query_ast, k)` | ✅ |
| **S3.5** | NIF 接口扩展 | `nif_cask.cpp` | Erlang 侧传入查询语法字符串或 AST map | ⬜ |
| **S3.6** | 测试 | `inverted_test.cpp` | AND/OR/NOT 各场景 + 组合查询 | ✅ |

---

### S4 — P3：Posting 压缩（VByte gap encoding）

**目标**：当前 posting 是 `vector<Posting>` 无压缩，内存占用高。对 ord 做差值编码 + VByte 压缩。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S4.1** | VByte 编解码器 | 新建 `vbyte.hpp` | `vbyte_encode/gap_encode` 和 `vbyte_decode/gap_decode` 内联函数 | ✅ |
| **S4.2** | PostingList 存储改造 | `inverted.hpp` | PostingList 使用压缩存储：`vector<uint8_t> compressed_ords` + `vector<uint8_t> compressed_tfs` + 解压缓存 | ✅ |
| **S4.3** | add_doc 写入压缩 | `inverted.cpp` | 新 posting 追加时做 gap + VByte 编码 | ✅ |
| **S4.4** | search 解压迭代 | `inverted.cpp` | 搜索时流式解压 posting list（不全文解压到内存） | ✅ |
| **S4.5** | save/load 兼容 | `inverted.cpp` | 持久化格式写入压缩后的字节，加载时直接读入 | ✅ |
| **S4.6** | 压缩率 + 性能基准测试 | `inverted_test.cpp` | 对比压缩前后内存占用和搜索延迟 | ✅ |

---

### S5 — P4：Block-Max WAND 早终止

**目标**：当前 DAAT 遍历所有匹配 posting。对 top-k 查询，实现 Block-Max WAND 跳过不可能进入 top-k 的文档块。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S5.1** | Posting 分块 | `inverted.hpp` | PostingList 按 128 个 posting 分 block，每 block 存储 `max_tf` 和 ord 范围 | ✅ |
| **S5.2** | Block-Max 元数据维护 | `inverted.cpp` | finalize() 时计算 block metadata（base_ord, end_ord, max_tf, start_idx, count） | ✅ |
| **S5.3** | Block-Max WAND 算法 | `inverted.cpp` | search_wand()：cursor 排序 → pivot 选择 → block upper bound 检查 → 早终止 | ✅ |
| **S5.4** | search 集成 WAND | `inverted.cpp` | `search()` posting 总量 ≥ 1024 时走 WAND，否则 DAAT fallback | ✅ |
| **S5.5** | 正确性验证 | `inverted_test.cpp` | 4 测试：基础/大数据集/单词/块元数据，WAND=DAAT 精确 top-k | ✅ |
| **S5.6** | save/load v3 | `inverted.cpp` | 版本 3 持久化 block metadata，向后兼容 v1/v2 | ✅ |

---

### S6 — P5：查询结果缓存

**目标**：热门查询重复执行全量评分。引入 LRU 缓存，相同查询+参数直接返回缓存结果。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S6.1** | 缓存数据结构 | `search_cache.hpp/.cpp` | CacheKey=hash(type+query+k)，LRU 链表+unordered_map，mutex 线程安全 | ✅ |
| **S6.2** | 缓存失效策略 | `search_layer.cpp` | on_write/on_delete/recover_doc/rebuild_index 时 cache_.invalidate() | ✅ |
| **S6.3** | search 缓存集成 | `search_layer.cpp` | search_text/search_phrase/bool_search 先查缓存 → miss 执行搜索 → 写入缓存 | ✅ |
| **S6.4** | 缓存大小限制 | `search_layer.hpp` | SearchLayerConfig.cache_max_entries（默认 256），0 禁用缓存 | ✅ |
| **S6.5** | 测试 | `search_layer_test.cpp` | 5 测试：命中/失效/淘汰/短语/禁用 | ✅ |

---

### S7 — P6：高亮/摘要生成

**目标**：搜索结果返回匹配片段（snippet），支持前后标签高亮。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **S7.1** | 位置偏移存储 | `analyzer.hpp` | 新增 `TokenInfo{position, start_byte, end_byte}` + `analyze_with_offsets()` 虚方法，WhitespaceAnalyzer 实现真实偏移 | ✅ |
| **S7.2** | 片段切分 | 新建 `highlighter.hpp/.cpp` | 固定窗口滑动 + 覆盖 query term 数评分 + top-N 非重叠片段选取 | ✅ |
| **S7.3** | 高亮标签插入 | `highlighter.cpp` | 在匹配 token 的 byte offset 处插入可配置 pre/post tag（默认 `<em>`/`</em>`） | ✅ |
| **S7.4** | API 扩展 | `search_layer.hpp` | `SearchHitEx{key, ord, score, highlights}` + `search_text_highlight(query, k, opts)` | ✅ |
| **S7.5** | 文本存储 | `search_layer.cpp` | `doc_texts_` map（ord → 原始文本），on_write/recover_doc 写入，on_delete/rebuild_index 清理 | ✅ |
| **S7.6** | 测试 | `highlighter_test.cpp` | 6 测试：英文高亮/多词/无匹配/片段大小/多片段/集成测试 | ✅ |

---

### S8 — 锦上添花（非关键，按需实现）

| # | 目标 | 改动范围 | 关键内容 | 优先级 |
|---|------|---------|---------|--------|
 | **S8.1** | 词干提取（Stemming） ✅ | `porter_stemmer.hpp` `stemming_analyzer.hpp` `analyzer.hpp/.cpp` `nif/atoms` `bitcask.erl` | Header-only Porter stemmer（5 步经典算法，~300 行）+ StemmingAnalyzer 装饰器（wrap 任意 Analyzer，替换 terms 为 stems）。`AnalyzerConfig.enable_stemming = true` 开启，工厂自动 wrap。NIF 侧加 `enable_stemming` atom + 透传。新增 19 测试（12 stemmer + 7 analyzer）。✅ ctest 264/264 + eunit 38/38 | 低 |
| **S8.2** | 同义词扩展 ✅ | `synonym_map.hpp` `search_layer.hpp/.cpp` `cask.hpp/.cpp` `nif/nif_cask` `bitcask.erl` | `SynonymMap` 类：`add_group`/`expand`/`expand_terms`/`load_from_file`（逗号分隔，一行一组）。查询时扩展（search_text/search_fields），索引不扩展；phrase/near 不扩展。NIF：`cask_set_synonym_map(Ref, FilePath)` 从文件加载。Erlang facade：`set_synonym_map/2`。新增 11 测试。✅ ctest 306/306 + eunit 38/38 | 低 |
| **S8.3** | 模糊搜索（Fuzzy） ✅ | `fuzzy_matcher.hpp` `inverted.hpp/.cpp` `search_layer.hpp/.cpp` `cask.hpp/.cpp` `nif/nif_cask` `bitcask.erl` | Header-only `levenshtein_distance`（DP，O(n*m)）+ `InvertedIndex::search_fuzzy`（遍历所有 shard terms，距离 ≤ max_edit 的 posting lists 做 DAAT BM25）。NIF：`cask_search_fuzzy(Ref, Query, MaxEdit, K)`。Erlang：`search_fuzzy/3,4`。新增 13 测试。✅ ctest 306/306 + eunit 38/38 | 低 |
| **S8.4** | 通配符搜索 ✅ | `wildcard_matcher.hpp` `inverted.hpp/.cpp` `search_layer.hpp/.cpp` `cask.hpp/.cpp` `nif/nif_cask` `bitcask.erl` | Header-only `wildcard_match`（迭代两指针，支持 `*`/`?`）+ `InvertedIndex::search_wildcard`（遍历 shard terms 匹配 pattern，DAAT BM25）。NIF：`cask_search_wildcard(Ref, Pattern, K)`。Erlang：`search_wildcard/2,3`。新增 15 测试。✅ ctest 306/306 + eunit 38/38 | 低 |
| **S8.5** | 查询时 k1/b 调节 ✅ | `inverted.hpp/.cpp` `search_layer.hpp/.cpp` | InvertedIndex 4 个查询函数 + SearchLayer search_text/phrase/bool_search 加可选 `const Bm25Params*`，nullptr=用默认。WAND 上界估算用同组参数（剪枝正确）。override 查询绕过缓存（避免与默认结果互污染）。范围到 C++ SearchLayer 层（Cask/NIF 未扩散）。新增测试 `QueryTimeBm25ParamsOverride`（b=0 vs b=0.75 分数不同）。✅ ctest 218/218 | 低 |
| **S8.6** | 多字段索引 + 权重 ✅ | codec / search_layer / query_parser / cask / nif / bitcask.erl | 四阶段完成：①DocValue v2 加 fields 段（空 fields 写 v1 字节不变，向后兼容）②SearchLayer `inverted_`→`map<field,InvertedIndex>`，per-field 统计隔离 + manifest 多文件快照 + R3 doc_len 辅助表 ③QueryNode 加 field/boost，parse_query 解析 `field:term^boost`（R5 防 http:// 误判）④DocInput/IndexTask/put_doc/NIF parse_doc_map（enif_map_iterator）/cask_search_fields 全打通。端到端实测：Erlang `put_doc(#{title=>,body=>})` + `search_fields("title:apple")` 字段路由正确。✅ ctest 234/234 + eunit 38/38。计划见 plans/tranquil-watching-sutton.md | 低 |
| **S8.7** | 近邻搜索 NEAR/slop ✅ | inverted / search_layer / cask / nif / bitcask.erl | search_phrase 重构为 `search_phrase_impl(slop)`，phrase=slop0；search_near 用有序 slop 匹配（term 按序、相邻间隙≤slop，lower_bound 在 (prev,prev+1+slop] 找）。SearchLayer 用 analyze_with_positions 按 position 还原查询词序（map 无序不可靠）。全链路打通：`cask_search_near/4` NIF + facade。实测 Erlang `search_near("quick fox",0)` 空、`slop1` 命中（隔 brown）。新增 2 单测 + 端到端。✅ ctest 236/236 + eunit 38/38 | 低 |
| **S8.8** | 评分解释 explain() API ✅ | `inverted.hpp/.cpp` `search_layer.hpp/.cpp` | 新增 `TermScore`/`ScoreExplanation` 结构 + `InvertedIndex::explain(terms, ord, ...)`（用与 search 完全相同的 idf/tf_norm 公式逐 term 给分项）+ `SearchLayer::explain(query, key)`（key→ord→inverted::explain，key 不存在返回 nullopt）。新增测试 `ExplainMatchesSearchScore`（total 与 search score EXPECT_NEAR 一致）+ `ExplainMissingKey`。✅ ctest 220/220 | 低 |
| **S8.9** | 增量索引持久化 ✅ | `inverted_wal.hpp/.cpp` `inverted.hpp/.cpp` `search_layer.hpp/.cpp` | append-only WAL：`InvertedWal` 类（`append_add_doc`/`append_remove_doc`/`truncate`/`replay`）。`InvertedIndex::enable_wal`/`disable_wal`/`replay_wal`（replay 时临时移出 WAL 避免递归写入）。`SearchLayer::save_snapshot` 后 truncate WAL，`load_snapshot` 后 replay WAL。新增 7 测试（6 单元 + 1 集成）。✅ ctest 306/306 + eunit 38/38 | 低 |
| **S8.10** | BM25+ 变体（δ 参数）✅ | `inverted.hpp/.cpp` | `Bm25Params` 加 `delta`（默认 0=标准 BM25）。所有评分路径（search/wand/phrase/bool/explain）贡献从 `idf·tf_norm` 改为 `idf·(tf_norm+δ)`；WAND 块上界 `block_upper_bound` 也加 δ（与实际评分一致，避免剪枝漏结果）。缓解长文档过度惩罚（Lv&Zhai 2011）。新增测试 `Bm25PlusDeltaBoostsScore`（δ=1 分数更高 + explain 一致）。✅ ctest 221/221 | 低 |

---

### S9 — 分词 / BM25 优化（代码审查产出，2026-06-01）

**背景**：对 analyzer + BM25 + 倒排索引子系统做了一次代码审查。下表均经实代码核实；
已排除两个误报——IDF 公式已是 Lucene 标准（`inverted.cpp:168` 等，无需改），
缓存 avgdl 收益可忽略（非热点）。

#### 已确认问题（按性价比排序）

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S9.1** | 修复高亮缓存删错 key | `search_layer.cpp:46` `index.hpp/.cpp` | `doc_texts_` 以 ord 为 key 存（:36），删除却用 `slot->doc_len`（:46）→ 内存泄漏 + 误删无关文档正文。修法：`DocSlot` 加 `ord` 字段、`Index::get()` 填充，`on_delete` 改用 `slot->ord`。✅ 已全量构建并跑 index(8) 测试通过（含 sanitizers） | 🔴 高 | ✅ |
| **S9.2** | 查询缓存选择性失效 | `search_cache.hpp/.cpp` `search_layer.cpp` | 改为按 term 选择性失效：缓存条目记录 query terms，`invalidate_terms(changed)` 只删与变更文档词集有交集者；on_delete 原文 miss 时降级整失效。属 near-real-time（score 绝对值可能轻微陈旧）。✅ 已全量构建并跑 search_layer(18) 测试通过（含 sanitizers） | 🟡 中 | ✅ |
| **S9.3** | 高亮正文不再全量常驻 | `search_layer.hpp/.cpp` | `doc_texts_` 改为带上限 LRU（`DocTextLru`，默认 1024 篇，配置 `doc_text_cache_max`）；高亮路径冷文档 miss 时降级为无片段 hit（不再整条丢弃，修了连带的结果缩水 bug）。✅ 已全量构建并跑 search_layer(18)+highlighter(6) 测试通过 | 🟡 中 | ✅ |

#### 顺带修的构建缺陷（本次联网构建时发现）

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S9.10** | utf8proc 仓库 URL 拼写修正 | `cpp/CMakeLists.txt:155` | `JulieStrings`（不存在，clone 报 could-not-read-Username）→ `JuliaStrings`（官方仓库） | 🔴 高 | ✅ |
| **S9.11** | cppjieba/limonp FetchContent 获取 | `cpp/CMakeLists.txt:165` | 原仅无条件指向空 `_deps/*-src`，CMake 不会获取；补 FetchContent_Declare（cppjieba v5.6.7 / limonp v1.0.2），保留 _deps-then-fetch 兼容 | 🔴 高 | ✅ |
| **S9.12** | thread_pool.hpp TBB 头路径过时 | `thread_pool.hpp:30-31` | `<tbb/concurrent_bounded_queue.h>` 在系统 oneTBB 已移除独立头（类已并入 `concurrent_queue.h`）；改用 `<oneapi/tbb/concurrent_queue.h>` + `<oneapi/tbb/global_control.h>`，与 inverted 一致 | 🟡 中 | ✅ |
| **S9.13** | NIF 引用了不存在的类型名 | `nif_cask_iter.cpp:32` | `CaskIterEntry` → `CaskIter::Entry`（嵌套类型，疑似重命名遗留）；NIF 层此前从未在本环境编译过故未暴露 | 🔴 高 | ✅ |
| **S9.14** | NIF 对 unique_ptr 用成员指针 | `nif_helpers.cpp:235` | `h->cask->*search_fn` 在 `unique_ptr<Cask>` 上用 `->*` 不合法；改 `((*h->cask).*search_fn)(...)` | 🔴 高 | ✅ |

| **S9.15** | Jieba 测试词典路径硬编码 | `jieba_analyzer_test.cpp:11` `cpp/CMakeLists.txt` `tests/CMakeLists.txt` | fixture 把词典目录写死成 `/tmp/bitcask-jieba-build3/...`（某次旧构建的绝对路径），换机器/构建目录必失败——这才是「10 Jieba pre-existing」的真因（词典其实在 cppjieba 源里）。修法：CMake 设 `BITCASK_JIEBA_DICT_DIR` 指向 `_deps/cppjieba-src/dict`，`target_compile_definitions` 注入测试，fixture 用宏（带相对路径回退） | 🔴 高 | ✅ |

| **S9.16** | jieba 词典进 priv + 运行时默认路径 | `cpp/CMakeLists.txt` `src/bitcask.erl` `.gitignore` | 此前注释称「dict_path 空=内嵌 priv/dict/」但①priv 无 dict ②代码无回退（空路径拼成 `/jieba.dict.utf8` 必失败）③契约实为「jieba 必填」。修法：CMake POST_BUILD 把 cppjieba 词典 copy 到 `priv/dict/`（仅 BITCASK_PRIV_DIR 定义时）；`bitcask.erl` 新增 `maybe_default_dict_path`：analyzer=jieba 且未传 dict_path 时用 `code:priv_dir(bitcask)/dict`（list_to_binary，匹配 NIF 的 enif_inspect_binary）；priv/dict 加入 .gitignore（构建产物）。已验证 priv/dict 5 文件齐全 + bitcask.erl 编译通过 | 🔴 高 | ✅ |

**全量构建结果**：`build_exit=0`，含 NIF 共享库 `priv/bitcask_cpp.so`（`cask_close` dirty-scheduler 改动也随之编译验证）。
ctest **206/206 全部通过**（含此前一贯失败的 10 个 Jieba 测试，经 S9.15 修复后全绿）。

| **S9.17** | 修复迭代器悬空指针 UB | `nif_cask_iter.cpp` | `iter_next_common` 原返回 `&e`（指向局部 `r` 内部，函数返回后析构 → 悬空），调用方读 `e->file_id` 等是 UB。改为返回 `std::optional<CaskIter::Entry>`（值拷贝，生命周期独立）；三个调用方 `auto* e` → `auto e`。✅ 全量构建 + ctest 206/206（含 sanitizers）通过 | 🔴 高 | ✅ |
| **S9.18** | C++ 注释与新行为对齐 | `analyzer.hpp:66` `jieba_analyzer.hpp:21` | 原注释称「dict_path 空=内嵌 priv/dict/」，实则无回退、空路径必失败。改为「必须有效，由 Erlang facade 默认填 priv/dict（S9.16）」，并说明空串会拼成 `/jieba.dict.utf8` 加载失败 | 🟡 中 | ✅ |
| **S9.4** | position 列 gap+VByte 压缩（仅磁盘） | `inverted.cpp` save/load | 核实后修正子分析：内存压缩会拖慢短语匹配（`binary_search` 需随机访问，VByte 变长不支持），故只压**磁盘 save/load**，内存仍 `vector<uint32_t>`、短语查询零影响。新增 `kInvVersion=4`：positions 落盘走 `gap_encode`/`gap_decode`（count+comp_size+字节流），v1/2/3 旧快照按原始 u32 读（load 分派 `ver==2\|\|3`→`ver>=2`、`ver==3`→`ver>=3`）。实测 positions 40000B→~10KB（约 75% 压缩），往返一致。✅ ctest 206/206。**S9.27 已补 v3 实跑验证**（并揭出版本检查漏 v3 的真 bug） | 🟡 中 | ✅ |
| **S9.5** | ~~搜索避免整体拷贝 PostingList~~ | `inverted.cpp` | **核实后判定不做**：`pl_copy` 是**有意设计**——`const_accessor` 持桶级读锁，拷贝后立即出作用域放锁，让查询不长期占桶锁、不阻塞并发 `add_doc`。改 `const&` 须让 accessor 活到查询结束 → 整个查询期间持多个桶读锁 → 牺牲读写并发度。子分析「纯收益」误判。另查 search/wand 路径无冗余 `decompress_ords`，无可省的二次拷贝。保留现状 | 🟡 中 | ❌不做 |

#### 待核实（子分析产出，未亲验，优先级低）

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S9.6** | bool_search 缓存 decompress_ords | `inverted.cpp` | 核实后修正子分析：`set_intersection` 对已排序序列本就是 O(n+m) 双指针、**不慢**（子分析误判「逐两比较」）。真正低效是同一 PostingList 在一次 bool_search 里被 `decompress_ords()` 解压 6 次（must_not/must/should×2/idf/评分各一次）。修法：给 `TermPostings` 加 `ords` 缓存，收集时解压一次，6 处复用。纯收益、不碰锁语义、不改算法/结果。✅ ctest 206/206（含 5 个 bool_search 用例）<br>**关联修复见 S9.6b** | 低 | ✅ |
| **S9.6b** | 修复 MUST+SHOULD 候选集语义 bug | `inverted.cpp` `inverted_test.cpp` | 实测确认 bug：`+hello world`（MUST hello + SHOULD world）会返回只含 world、不含 hello 的 doc2（违反 MUST 语义）。根因：must 非空时仍无条件把 should ords 追加进 candidates（原 592-600）。修法：删除该段——MUST 定候选集、SHOULD 只参与打分（评分循环遍历 all_tps 对候选内 ord 累加，加分不受影响）。顺带消除了 S9.6 记的「should 分支重复收集」。实测：修后 `+hello world`→{0,1}，且 doc0（含 world 加分 0.78）> doc1（0.52），打分仍正确。新增回归测试 `BoolSearchMustWithShouldBoost`。✅ ctest 207/207 | 🔴 高 | ✅ |
| **S9.7** | 短语匹配消除循环不变量重复 | `inverted.cpp` `inverted_test.cpp` | 核实后修正子分析：skip index 收益有限（binary_search 已 log）。真正低效是循环不变量重算：①`other_pl.find(posting_ord)`（O(log D) 二分）在**每个 start_pos** 内重复调用，但 idx 对固定 (doc,term) 不变 → 提到 start_pos 循环外，每 (doc,term) 只查一次，并缓存 pos_list 指针；any other term 不在本 doc → 提前跳过整 doc。②`live_df`（O(D)）原在每个匹配 doc 内重算 → 提到 doc 循环外只算一次。纯收益、零语义变化。新增回归测试 `PhraseSearchRepeatedInDoc`（phrase_tf>1）。✅ ctest 208/208 | 低 | ✅ |
| **S9.8** | 分词 `min_token_length`（C++ 层） | `analyzer.hpp` ngram/whitespace/jieba `analyzer_test.cpp` | 核实后关键设计：CJK 走 n-gram（bi/tri-gram 本就 2-3 字符），一刀切会删光中文索引，故**只过滤拉丁整词**（ngram emit_word / whitespace / jieba 非 CJK 词），按 codepoint 长度，CJK n-gram 不动。AnalyzerConfig 加 `min_token_length`，默认 1=不过滤（向后兼容）；工厂透传三个 analyzer；短词丢弃但 pos 仍递增（位置语义不变）。实测：ws min=3 过滤 a/of 留 cat/hello；ngram min=3 时「北京」bigram 保留、拉丁 a/of 过滤。新增 3 个测试。✅ ctest 213/213 | 低 | ✅ |
| **S9.21** | min_n/max_n/min_token_length 的 NIF 暴露 | `atoms.hpp/.cpp` `nif_helpers.cpp` `bitcask.erl` | 此前 NIF 只透传 analyzer type/dict_path/enable_stop_words。补：3 个 atom（atoms.hpp/.cpp）+ parse_analyzer_option 三个 int 分支（≥1 校验）+ parse_2tuple_option 分发条件 + bitcask.erl 的 CASK_PASSTHROUGH_OPTS。端到端实测（erl 起 BEAM）：`{analyzer,whitespace},{min_token_length,3}` 下搜 "cat"(len3)命中、"of"(len2)被过滤返回空 → atom 两侧拼写一致、整链路打通。✅ ctest 215/215 | 低 | ✅ |
| **S9.22** | 修复 cask_bool_search 缺 Erlang stub | `src/bitcask_cpp_nifs.erl` | 验证 S9.21 时发现**阻断性预存 bug**：C++ kNifFuncs 注册了 `cask_bool_search`，但 Erlang 模块未导出/声明对应占位函数 → `erlang:load_nif` 报 `bad_lib: Function not found bitcask_cpp_nifs:cask_bool_search/3` → **整个 NIF 无法加载**（任何用 NIF 的场景全挂）。应是 commit b7f6aa0/72783fa 加 C++ bool_search NIF 时漏同步 Erlang stub。修法：加 export `cask_bool_search/3` + nif_error 占位。修后 NIF 正常加载、端到端搜索可用 | 🔴 高 | ✅ |
| **S9.23** | 修复 fold/stream 返回未解码 doc 字节 | `cpp/src/cask/cask.cpp` `CaskIter::next` | 根因定位：`put` 把所有 value 统一编成 DocValue（version+flags+len+text，统一架构 V1）。`Cask::get` 会 `decode_doc_value` 取 text 段还原原始 value，但 **`CaskIter::next` 第 238 行直接 `e.value = std::move(rec->value)` 把磁盘 doc 编码原样上交**，没解码 → fold/stream/list_keys 拿到 `<<1,2,0,0,0,1,118>>` 而非 `<<"v">>`。读取路径不对称。修法：next 的非墓碑分支照 get 一样 decode 取 text 段（墓碑非 DocValue 编码，保持原始字节）。核实 merge 不走 next（用 scanner 的 view.value），不受影响。✅ rebar3 eunit 38/38（原 4 失败全过）+ ctest 215/215 | 🟡 中 | ✅ |
| **S9.9** | 修复 jieba 高亮 byte offset 未实现 | `jieba_analyzer.hpp/.cpp` `jieba_analyzer_test.cpp` | 核实后修正子分析：不是「二次归一化致 offset 错位」，而是 jieba 的 `analyze_with_offsets` 把所有 byte offset **填成 0**（原 257 行 `{p,0,0}`），导致 jieba 分词的文档高亮**永远生成不出片段**（highlighter 要求 end_byte>start_byte）。修法：抽出私有 `collect_tokens` 作为 positions/offsets 的单一数据源——jieba 词在归一化 cps 序列中朴素定位首次匹配填真实区间（CutForSearch 输出重叠子词/全词，顺序非单调，故每词独立从头查找，不用游标），n-gram 段直接取归一化坐标。停用词过滤统一用 remove_if。实测「北京大学很有名」5/5 token 区间精确（slice==term）。`analyze_with_positions` 输出经 10 个 jieba 测试确认未变（索引语义不破坏）。新增回归测试 `OffsetsAreRealNotZero`。✅ ctest 209/209 | 低 | ✅ |
| **S9.19** | 修复高亮 offset 坐标系全局不一致 | `search_layer.cpp` `search_layer_test.cpp` | 系统性 bug：三条 `analyze_with_offsets` 的 byte offset 都相对**归一化文本**，而 `highlight()` 原用**原文**切片 → 非规范文本（全角/组合字符）坐标系错位、切出 UTF-8 乱码。**实测复现**：`ＨＥＬＬＯ world`（全角，21B）查 `world`，原文 [6,11) 切出 `Ｌ\xef\xbf\xbd`，高亮成 `<em>Ｌ�</em>`。修法（按选定方案）：search_layer 在 `analyze_with_offsets`/`highlight` 前先 `nfkc_fold(doc_text)`，两者都基于归一化文本，坐标系一致（NFKC 幂等，二次归一化无害）。代价：高亮片段展示归一化后文本（全角→半角），但索引/匹配本就基于归一化形式，展示一致反而合理。实测修后高亮 `<em>world</em>` 无乱码。新增回归测试 `HighlightFullwidthText`。✅ ctest 210/210 | 🟡 中 | ✅ |
| **S9.20** | 修复高亮重复片段 | `highlighter.cpp` `highlighter_test.cpp` | 根因：`select_best_fragments` 在 const& 的 `sorted_ranges` 上循环 max_fragments(默认3) 次，每轮选同一最佳窗口、从不消费已覆盖 range → 产出 3 个完全相同片段。修法：用可变副本 `remaining_ranges`，每选定一个片段后 `remove_if` 掉落在该窗口 `[best_start,best_end)` 内的 range，下一轮在剩余里选；range 耗尽即停。实测：单次出现 → 1 片段（原 3 个相同）；远距两次出现 → 2 个不同片段。新增回归测试 `NoDuplicateFragmentsForSingleOccurrence` + `TwoFarApartOccurrencesGiveTwoFragments`。✅ ctest 215/215 | 低 | ✅ |
| **S9.24** | jieba 索引路径免 offset 定位（修 S9.9 回归） | `jieba_analyzer.hpp/.cpp` | S9.9 为填高亮 byte offset，让 `collect_tokens` 对每个 jieba 词做 O(cps长度) 朴素查找——但索引路径（`analyze_with_positions`）只需 term+position，不需 offset，却也付了此成本。修法：`collect_tokens(text, need_offsets)`；非 CJK 词在 `!need_offsets` 时跳过查找（has_cjk 词仍查，因 cjk_covered 标记是索引必需）。索引路径传 false、高亮传 true。实测：索引/高亮 term 集完全一致（混合文档 7 term），高亮路径拉丁词仍有 offset。✅ ctest 215/215 | 中 | ✅ |
| **S9.25** | is_cjk 收窄全角 ASCII 范围（防御） | `cjk_detect.hpp` | `is_cjk` 把 FF01–FF5E 整段判 CJK，含全角字母/数字（语义是 Latin，不该判 CJK），且注释自相矛盾。核实：因 `is_cjk` 只在 NFKC 后调用、全角已折半角，**当前不触发**（实测全角 Ａ→a 走 Latin，正确）。删除该行 + 修正注释，防未来未归一化路径踩雷。行为不变。✅ ctest 215/215 | 低 | ✅ |
| **S9.26** | 修复 jieba 把空格/标点当 token 入索引 | `jieba_analyzer.cpp` collect_tokens | 复审实测发现：`"北京大学 hello world 上海"` 索引出一个 `' '`（空格）term——jieba CutForSearch 把空格也输出为词，污染索引。修法：collect_tokens 加 `is_noise_word`（基于 utf8proc_category 判全空白 Z*/控制 Cc + 全标点 P*），纯噪声词跳过（pos 仍递增）。实测：修后 6 term（原 7，空格消失），真实词全保留。新增回归测试 `SpaceNotIndexedAsToken`。✅ ctest 216/216 | 低 | ✅ |
| **S9.27** | 修复 load 版本检查漏 v3 + 补 v3 兼容实跑验证 | `inverted.cpp` `inverted_test.cpp` | 验证 S9.4 兼容缺口时发现**真 bug**：load 入口检查 `ver != kInvVersion && ver != 2 && ver != 1`（kInvVersion=4）→ **拒绝 v3 快照**（虽然 load 体内有 ver>=3 分派逻辑，入口先挡掉）。S9.4 升 v4 时漏列 v3。修法：改范围检查 `ver < 1 || ver > kInvVersion`。验证：手工构造 v3 字节（positions 原始 u32 数组，comp=0 分支）实跑——修前 load 拒绝、修后 df=2/live=2 正确。新增回归测试 `LoadV3SnapshotBackwardCompat`。✅ ctest 217/217 | 🟡 中 | ✅ |
| **S9.28** | 修复 search_phrase 查询词序不可靠 | `search_layer.cpp` `search_layer_test.cpp` | 做 S8.7 时发现的预存隐患：`search_phrase` 遍历 `analyze(query)` 的 **unordered_map** 取 terms，**词序不保证**，且重复词被去重；而短语有序匹配依赖查询词序 → 多词短语可能漏召/错召。修法：改用 `analyze_with_positions` 按 position 排序还原词序（与 search_near 一致），重复词位也正确保留。新增回归测试 `PhraseOrderSensitive`（正序/逆序 3 词短语精确区分）。✅ ctest 237/237 | 🟡 中 | ✅ |
| **S9.29** | 修复多字段文档对普通搜索不可见（catch-all） | `search_layer.cpp` `search_layer_test.cpp` | **Erlang REPL 实测发现**的 S8.6 缺口：`put #{title=>,body=>}` 多字段文档能被 `search_fields("title:quick")` 搜到，但 `search_text/phrase/near`（只查默认字段）**完全搜不到**——`on_write_fields` 只写各字段索引、没填默认字段。修法（catch-all，类 Lucene _all）：on_write_fields 把非默认字段文本拼接后合并写入 `kDefaultField` 索引（若已有字段直接写默认字段则不重复）。字段限定查询不受影响。实测 Erlang：修后 search_text(quick) 命中两多字段文档、title:quick 仍只命中 1。新增回归测试 `MultiFieldVisibleToPlainSearch`。⚠️ 取舍：catch-all 拼接使短语可能跨原字段边界误匹配（全文搜索可接受）。✅ ctest 238/238 + eunit 38/38 | 🔴 高 | ✅ |

---

### S10 — 分词 / BM25 / 倒排第二轮优化（代码审查产出，2026-06-02）

**背景**：S9 那轮已修掉大部分问题；本轮针对 `inverted.cpp` / `inverted.hpp` / `analyzer.cpp`
再做一次静态审查，下列均经实代码核实（给了 file:line），但未跑 benchmark/TSan 实证，
故实现时**每项先验证再标 ✅**。按性价比排序。

#### 🔴 正确性 / UB 类

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S10.1** | 统计字段读路径无锁 data race（UB） | `inverted.hpp/.cpp` | `search()`（`inverted.cpp:156-158`）裸读 `live_doc_count_`/`sum_doc_len_`，而 `add_doc`(:104)/`remove_doc`(:115) 在 `unique_lock(stats_mutex_)` 下写 → 并发查询+写=数据竞争 UB（`explain`/`search_wand`/`search_phrase_impl`/`bool_search`/fuzzy/wildcard 全部裸读）。修法：两字段改 `std::atomic<std::uint64_t>`，去掉 `stats_mutex_`，既消 race 又免锁。`avg_doc_len()` 等访问器一并简化。✅ 改 `std::atomic<std::uint64_t>` + `fetch_add`/`fetch_sub`/`load(relaxed)`，删掉 `stats_mutex_` 及全部 shared_lock/unique_lock；ctest 307/307。TSan 单独核实：`search()` 的 `parallel_reduce` 路径有一处**预存** TSan 报告（baseline stash 后同样 4 warning，与本项无关，疑似 TSan 看不见 TBB 调度器 happens-before 的误报） | 🔴 高 | ✅ |
| **S10.2** | fuzzy 同一词被重复计分 | `inverted.cpp` `fuzzy_test.cpp` | `search_fuzzy`(:904-912) 外层 `for query_term` 内层扫全词表，多个 query term 模糊命中同一 vocab term 时被 `push_back` 两次 → 同一 posting list 在 `parallel_reduce` 评分两遍、IDF 贡献翻倍。修法：翻转循环（vocab term 外层、query term 内层 + break），每 term 至多入 tps 一次。新增回归测试 `NoDoubleCountWhenTwoQueryTermsMatchSameTerm`（`{"helo"}` 与 `{"helo","hallo"}` 同命中 "hello"，分数 EXPECT_NEAR 一致）。✅ fuzzy 15/15 + ctest 307/307 | 🔴 高 | ✅ |

#### 🟡 性能（高收益）

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S10.3** | fuzzy 长度剪枝 + 可选并行扫描 | `inverted.cpp` | `search_fuzzy`(:904) 对全词表每 term 跑 O(n·m) levenshtein DP。最廉价剪枝：`abs(len(query)-len(term)) > max_edit` 时距离必 > max_edit，直接 skip（编辑距离 ≥ 长度差），省掉绝大多数 DP。可选：用 `tbb::parallel_for` 并行扫 shards（当前词匹配阶段串行，仅评分并行）。✅ 与 S10.2 同一循环重写中加入 `len_diff > max_edit_distance → continue` 前置剪枝（按字节长度）；并行扫描留待后续。fuzzy 15/15 + ctest 307/307 | 🟡 中 | ✅ |
| **S10.4** | wildcard 全词表扫描优化 | `inverted.cpp` | `search_wildcard`(:602) 串行扫全词表跑 `wildcard_match`。带字面前缀的 pattern 本可收窄，但 hash 分片无前缀局部性 → 至少先并行扫 shards | 🟡 中 | ✅ |
| | | | **实现**：词匹配阶段改 `tbb::parallel_reduce` over `[0,kShardCount)`，每 shard 至多被一个任务遍历（互不重叠），线程本地收集 + 合并；与既有「查询无锁读」模型一致（拷贝 plist 不持桶锁，同 search() 的 parallel_reduce 安全姿态）。前缀收窄因 hash 分片无局部性未做。新增回归 `ParallelScanCollectsAllMatches`（200 匹配词散布 64 shard + 50 干扰词 → 全收齐、无重、ord 连续）。✅ wildcard 18/18 + ctest 309/309 + eunit 38/38 | | |
| **S10.5** | WAND 每轮对含 vector 的结构体整体 sort | `inverted.cpp` | `search_wand`(:349) 每个 pivot 迭代 `std::sort(tps...)`，而 `TermPostings` 含 `pl_copy`(items/compressed_ords/blocks) + `ords` 四个 vector，按值 swap 在搬这些 vector，远超 O(t log t) 比较本身。修法：排序 `vector<int>` 索引/指针，`tps` 本体不动 | 🟡 中 | ✅ |
| | | | **实现**：引入 `std::vector<std::size_t> order`（0..n-1），每轮 `std::sort(order...)` 只搬 size_t；pivot 累加/skip 循环改走 `tps[order[i]]`，pivot_idx→pivot_pos（order 中位置）。**完整保留原比较器语义**（含「耗尽 term 排前面、由 continue 跳过」的细节）+ 评分/推进/耗尽检查等顺序无关循环不动。行为等价由 WAND 精确性对比测试（BlockMaxWand* + IncrementalBlocksOnLiveIndex 的 `EXPECT_FLOAT_EQ`）保证。✅ inverted 50/50 + ctest 308/308 + eunit 38/38 | | |
| **S10.6** | 增量写从不 finalize → WAND 块跳跃失效 | `inverted.cpp` `search_layer.cpp` | `finalize()` 只在 rebuild(`search_layer.cpp:541`) 调用，正常 `on_write→add_doc` 后 `finalized=false`/`blocks` 空 → `block_for_ord`(:38) 对在线索引恒返回 nullptr，WAND 退化无跳跃 DAAT；每查询 `decompress_ords` 走未压缩分支重拷一遍。修法：达阈值的 posting list 惰性/后台 finalize，或 add_doc 累积增量 finalize | 🟡 中 | ✅ |
| | | | **实现**：`PostingList::seal_full_blocks()`（攒满 kBlockSize 即封一整块，O(1) 摊还，靠 ord 单调递增）+ `note_appended()`（add_doc 每追加一条调用：失效过期压缩态、弹掉 finalize 留的部分尾块、再封满块）。不变量：增量阶段 blocks 仅含满块，部分尾块只由 finalize 产生；`finalize()` 加 `blocks.clear()` 保证幂等覆盖。在线索引（未 finalize）现 `block_for_ord` 返回非空 → WAND 真正块跳跃。`decompress_ords` 在 finalized=false 时退回 items 源，正确。**取舍**：`save_snapshot` 不 finalize（const），存盘仍丢 blocks（预存行为，load 后需重 finalize 才有块）。新增回归 `IncrementalBlocksOnLiveIndex`（在线 blocks 非空+全满块 / 与 finalize 后结果 EXPECT_FLOAT_EQ 一致 / finalize 后块数=ceil）。✅ inverted 50/50 + ctest 308/308 + eunit 38/38 | | |

#### 🟢 性能（中低，顺手）

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S10.7** | 每 posting 两次 is_live 虚调用 | `inverted.cpp` | `search`(:173-184)/`search_wildcard`(:626)/`search_fuzzy`(:930)：先一遍算 live_df 再一遍评分，`is_live`（虚函数+表查）调两次。合成单遍或先填 `vector<char> live` | 🟢 低 | ✅ |
| | | | **实现**：三处 `parallel_reduce` 体先填 `std::vector<char> live`（一遍 `is_live` 算 live_df 顺带缓存），评分循环改判 `live[i]`，每 posting 省一次虚调用。✅ inverted 50/50 + wildcard 17/17 + fuzzy 15/15 + ctest 308/308 | | |
| **S10.8** | WAND doc_len(pivot_ord) 内层重复取 | `inverted.cpp` | `search_wand`(:408) 同一 pivot_ord 的 `doc_len` 在遍历 term 的循环里每次重算，提到循环外取一次 | 🟢 低 | ✅ |
| | | | **实现**：WAND 评分段 `auto dl = doc_len(pivot_ord)` 提到 term 循环外（dl 只依赖 pivot_ord）。✅ WAND 精确性对比测试通过 + ctest 308/308 | | |
| **S10.9** | block_upper_bound 每次重扫 global_max_tf | `inverted.cpp/.hpp` | `block_upper_bound`(:56-61) 线性扫全 items 求最大 tf。可在 `finalize()` 时把全局 max_tf 存进 PostingList，查询直接读 | 🟢 低 | ✅ |
| | | | **实现**：`PostingList` 加 `std::uint32_t max_tf`，增量维护（`note_appended` 追加时 `max(max_tf, items.back().tf)`）+ `load` 后重算（落盘格式不含此派生量）；`block_upper_bound` 直接读缓存。pl_copy 拷贝时字段随之复制。✅ WAND 精确剪枝结果不变（IncrementalBlocksOnLiveIndex 的 live vs finalized `EXPECT_FLOAT_EQ` 一致）+ ctest 308/308 | | |

#### 📦 内存 / 规模化

| # | 目标 | 改动范围 | 关键内容 | 优先级 | 状态 |
|---|------|---------|---------|--------|------|
| **S10.10** | positions 无条件常驻 | `inverted.hpp/.cpp` `search_layer` | `Posting`(:62-66) 恒带 `positions`，部署只用 search_text/从不 phrase/near 时纯开销。加 `SearchLayerConfig.index_positions` 开关，关闭时不存 positions（S9.4 已压磁盘侧，内存侧仍全量） | 🟢 低 | ✅ |
| | | | **实现**：`InvertedIndex` 加 `index_positions_`（构造参数，默认 true 向后兼容）+ getter；`add_doc` 在 false 时 push 空 positions。`SearchLayerConfig.index_positions` 透传到 4 个 InvertedIndex 构造点（field_index + rebuild 三处）。save/load 无需改（positions.size()=0 即可）。**取舍**：关闭后 search_phrase/search_near 失效（无位置可匹配→返回空），仅适合纯 search_text/bool/fuzzy/wildcard 部署，已写入配置注释。新增回归 `IndexPositionsDisabled`（搜索正常+positions 空+短语空）/`IndexPositionsEnabledByDefault`（默认存 positions+短语命中）。✅ inverted 52/52 + ctest 311/311 + eunit 38/38 | | |
| **S10.11** | remove 不删 posting，churn 下无界膨胀 | `inverted.cpp` | `remove_doc`(:112) 只减统计不删 posting 行（文档化 df-drift 取舍），高频改写库里死 ord 永留、每查询 live_df+评分都扫过。可加「死点占比超阈值触发该 list 压实」机制 | 🟢 低 | ✅ |
| | | | **实现**：`PostingList::compact(is_live)`（重建只留 live，重置 compressed_ords/finalized/blocks/max_tf + seal_full_blocks，保序）+ `InvertedIndex::compact(LiveChecker, threshold=0.5)`（快照 key→逐 key 持写 accessor，死点占比≥阈值才压实，与查询 const_accessor 互斥，返回压实数）+ `SearchLayer::compact(threshold)`（用 index_ 作 LiveChecker 压实各字段+失效缓存）。**关键性质**：分数无关（live_df/idf/avgdl 都只数 live，压实只是不再扫死点）；非查询热路径。`remove_doc` 拿不到 ord（只调统计），故压实必须靠外部 LiveChecker 显式触发，而非 remove 内联。**WAL 取舍**：压实是内存操作不写 WAL，replay 会重新累积（靠 save_snapshot 持久化压实态）。新增回归 `CompactRemovesDeadPostingsPreservesScores`（50%死→压实后 df 减半、结果集+分数 EXPECT_FLOAT_EQ 一致）/`CompactSkipsBelowThreshold`（1%死不动）。✅ inverted 54/54 + ctest 313/313 + eunit 38/38 | | |

---

### S11 — DocValue 磁盘格式优化（2026-06-02）

**背景**：审查多字段存储格式时发现两类冗余——①固定 4B 长度前缀对小字段浪费；
②每条 record 内联存字段名（append-only 下同 schema 百万文档重复百万次，merge 后再付一遍）。
统一升级 DocValue 到 **v3**（项目不考虑向后兼容，已更新黄金 fixture）。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **#2** | 变长长度前缀 | `format.hpp` `codec.cpp` `codec_test.cpp` | 所有长度/计数（Dim/text/meta/FieldCount/字段值长）从固定 4B/2B u32/u16 BE 改 VByte varint（算法同 `vbyte.hpp`，对 std::byte 缓冲操作）。小字段省 2–3B。黄金 fixture 重算（`0303820000803f...`，注意 VByte 末字节高位=终止标记，varint(2)=0x82）。✅ codec 26/26 | ✅ |
| **#1** | 字段名字典（schema interning） | 新建 `field_schema.hpp` `codec.{hpp,cpp}` `cask.{hpp,cpp}` `cask_docvalue_test.cpp` | DocValue 的 fields 段存 **FieldId(varint)** 而非内联字段名。新增 header-only `FieldSchema`：append-only `<dir>/field.schema`（每新字段追加 `[u16 名长][name]`，id=出现序），`intern`(并发安全, shared→unique 双检 + fwrite+fflush)/`name_of`/`open`(顺序重放)。Cask 持 `field_schema_`，open/upgrade 时加载，`put_doc` 把字段名 intern 成 id 写入。codec 保持纯函数（DocField 带 id，名字映射在 Cask 层）。**关键发现**：4 个 `decode_doc_value` 调用点无一读 `dv->fields[].name`（字段名是只写不读的预留），故读侧改动面≈0。merge 逐字节复制 value、不重编码 → field id 跨 merge 不变（schema 同目录持久）。新增 `FieldSchema.InternDeterministicAndReverseLookup`/`PersistsAcrossReopen` + codec `FieldIdMultibyteVarint`。✅ ctest 316/316 + eunit 38/38（多字段 NIF e2e 走真实 schema） | ✅ |

**收益示例**（3 字段 doc，名 title/body/author）：结构开销从 ~35B/record（2B fieldcount + 3×(2B 名长+名+4B 值长)）降到 ~7B/record（1B fieldcount + 3×(1B id + 1B 值长)），字段名全局只存一份。append-only + merge 双重放大。
**未做**（更大、需单独设计）：#3 value 压缩（zstd/LZ4，会破坏 decode 的 zero-copy span）、#4 向量量化（V3/HNSW）。

---

### S12 — NIF 层重构（2026-06-02）

**目标**：C++ 最佳实践 / 高内聚低耦合 / 函数抽象去重复 / 适当设计模式 / 完善中文注释。
NIF 层本已模块化（atoms/resources/term_conv/helpers/main/cask/iter/admin），本轮针对
残留重复与耦合做精修。**行为不变**（纯重构），eunit 38/38 + 端到端 5 类搜索实测通过。

| # | 目标 | 改动 | 关键内容 |
|---|------|------|---------|
| **S12.1** | 统一搜索骨架（Strategy） | `nif_helpers.{hpp,cpp}` `nif_cask.cpp` | 5 个 `*_search_impl`（search/bool/near/fuzzy/wildcard，~115 行）90% 是同一套样板（取 handle→查 query binary→has_search→调用→fault_to_term/make_ok）。抽成单个 `run_search(env, ref, query, SearchInvoker)`，`SearchInvoker = std::function<expected<TextSearchResult,CaskFault>(Cask&, string_view)>` 承载「具体怎么搜」的策略闭包。8 个搜索 NIF 入口变成 3-4 行薄 lambda 包装（k/slop/max_edit 由闭包捕获）。**设计取舍**：NIF glue 是函数式的，正确的「设计模式」是高阶函数/Strategy，强行套继承反而是 cargo-cult，故用 std::function（小捕获走 SBO 无堆分配） |
| **S12.2** | 选项解析拆出独立 TU | 新建 `nif_options.cpp` | `parse_options` + `parse_*_option`（~130 行）从 nif_helpers.cpp 移出，单一职责（高内聚）。声明仍在 nif_helpers.hpp，调用方不变。加 typed 提取小工具 `opt_int`/`opt_u64`/`opt_u32_min`（min 校验），消除每分支重复的 `enif_get_int + 范围检查 + 赋值` |
| **S12.3** | term_conv 清理 + 复用 | `term_conv.hpp` `nif_cask.cpp` `nif_options.cpp` | ① 删 dead `make_binary_from_bytes`（零调用、且是 `make_binary_checked` 的劣化重复）② 加 `get_positive_int`（k）/`get_nonneg_int`（slop/max_edit）替代散落的 `if(v<=0)v=10` ③ 多处手写 `reinterpret_cast<const char*>(bin.data)` 改用已有的 `as_string_view`（run_search/dict_path/set_synonym_map） |

**效果**：nif_helpers.cpp 424→185 行；5 份搜索样板→1 个 run_search；选项解析独立成 TU。
✅ `bitcask_cpp.so` 重建 + erl 实测 search_text/phrase/fuzzy/wildcard 结果正确。

| **S12.4** | run_search 边界 eunit 用例 | 新建 `test/bitcask_search_boundary_tests.erl` | 此前 eunit **完全没覆盖搜索**（搜索测试都在 C++ 侧），run_search 仅靠手动 erl 验证。补 6 个用例：① no_index（KV 模式 6 个搜索接口全返回 `{error,no_index}`）② k≤0 回落默认 10（k=0/-5 结果与 k=10 一致；near/fuzzy 4 参版也覆盖）③ 空 query / 无命中 → `{ok,[]}` ④ 正向回归（text/phrase/fuzzy/wildcard 各命中预期文档）。✅ eunit 38→**44/44** |

---

### S13 — 修复 fold 与并发 merge 的文件竞争（2026-06-02）

**背景**：审查 merge 对读写的影响时发现的**真实并发缺口**。keydir 有 epoch/frozen/
IterHandle 机制，但核实后确认它只钉「keydir 的 key 修订快照」（fold 的 MVCC），
**不钉 data file**（keydir 无任何文件级 refcount，grep 零结果）；且 merge 两侧都
**不 gate 在 frozen**（C++ `needs_merge` + Erlang `do_merge`/`cask_merge_run` 都只看
阈值/时间窗口）。

**Bug**：`CaskIter::next` 通过 `parent_->read_file`（共享 `read_files_` 缓存）读
value，而 `Cask::merge` 无条件 erase 缓存 fd + unlink 旧文件。于是一个长 fold 跨越
一次并发 merge 时，其 epoch 快照里某 key 解析出的旧 `(file_id, offset)` 指向已被
unlink 的文件 → `read_file` 重新 open 失败 → **fold 中途报 `{error,_}`**。legacy riak
bitcask 靠 fold 启动时 pin 一份 readable_files 句柄快照规避，本实现改走共享缓存后
丢了这层保护（`merger.hpp` 注释自承「M3.3 精简版不处理并发 race」）。

| # | 目标 | 改动 | 关键内容 |
|---|------|------|---------|
| **S13.1** | fold pin 文件句柄快照（方案1） | `cask.hpp` `cask.cpp` | `CaskIter` 加 `pinned_files_`（`map<file_id, unique_ptr<DataFile>>`）+ `pin_files()`。`start()` 在 `kOk` 后 `scan_dir` 打开**目录下全部 data 文件**的只读句柄并 pin（active 文件除外——merge 不合并它）；`next()` 优先用 pin 的句柄、未 pin 的退回 `read_file`；`release()` 清空 pin。**原理**：已 open 的 fd 让 inode 在 Linux 上存活，merge unlink 旧文件不影响 fold 后续 pread |

**正确性论证**：pin 放在 epoch 快照（`iter_->start`）之后是**充分**的，不存在可触发的时序
窗口。两个条件互斥：① fold 在 epoch E 解析到文件 F ⟹ merge 尚未把该 key 从 F 搬走，即其
CAS 晚于 epoch 快照；② F 在 `pin_files` 扫到前被 unlink。但 merge 的 unlink **严格在所有
CAS 之后、且隔着整个 run_merge 尾巴 +（索引模式的）全量重建**，这一大段不可能塞进
「epoch 快照 → pin_files 扫描」那条亚微秒缝隙 → 凡 fold 在 A 时指向的 F，B 时必然还在 →
必被 pin。更根本地：fold 看不到比自己 epoch 更新的文件，它能引用的文件都在快照前就已落盘、
故都会被 pin（merge 输出/新写入 epoch 更大，fold 不可见，且本次 fold 期间不会被 unlink，
走 `read_file` 回退）。
**取舍**：① 每个并发 fold pin 住全部非 active 文件的 fd（large DB 下 fd 数 = 文件数，与
legacy 一致，fold 本就重），被 pin 的旧文件磁盘空间延迟到 fold release 才回收。② 唯一边角是
**非时序**的：`pin_files` 若因 fd 耗尽/权限 open 失败，该文件不受保护（运维资源上限，非并发
race）。点 get 本就基本无害（unlink 是 merge 最后一步、单次 NIF 不让出线程）。
**验证**：新增 `FoldSurvivesConcurrentMergeUnlink`（小 max_file_size 滚多文件 → fold
中触发 merge unlink → 续读全部 20 key 正确）。**测试有牙**：临时把 `pin_files` 改 no-op
确认它在 unlink 后 fail，还原后通过。✅ ctest 316→**317/317** + eunit 44/44。

---

## 性能优化（O1-O9）✅

> 基于全库代码审计（存储核心 / 倒排索引 / 搜索文本层 / NIF+Erlang 层四路并行分析，
> 高影响发现已逐一对照源码核实）。原则：只做已确认真实存在、收益明确的优化；
> 不改对外语义；每项独立可验证。基线：ctest 317/317 + eunit 44/44。
> **结果**：ctest 317→**319/319**（+2 回归测试）+ eunit 44/44。过程中发现并修复
> 2 个正确性 bug（O3 的 load 回填缺失、O6 的 ies 规则偏差，见各节）；O7 与 O9
> 的队列部分经核实为审计误报，未改动（理由见各节）。

### O1 — KeyDir 透明 hash（消除热路径 string 临时构造）

**目标**：`keydir.cpp` 中 `entries_`/`pending_` 的每次 `find`/`insert_or_assign` 都做
`std::string(key)` 临时构造（13 处），每个 put/get/remove 至少一次多余堆分配。
`index.hpp` 已有支持异构查找的 `StringHash`，复用之。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O1.1** | entries_/pending_ 改透明 hash | `keydir.hpp` / `keydir.cpp` | `StringHash` 提到共享头 `string_hash.hpp`（index.hpp 同步复用）；9 处 `find(std::string(key))` 改零拷贝；4 处 insert_or_assign 保留（key 须 owned） | ✅ |
| **O1.2** | 回归 | 全量 | ctest 317/317 | ✅ |

### O2 — NIF get 热路径 atom 缓存

**目标**：`nif_cask.cpp` 索引模式 get 每次调用 `enif_make_atom(env, "text"/"meta")`，
走 BEAM 原子表查询。挪进 `atoms()` on_load 一次性初始化。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O2.1** | atoms 加 text/meta | `atoms.hpp/.cpp` / `nif_cask.cpp` / `nif_helpers.cpp` | `atoms().text/.meta`；get 构造 map 与 parse_doc_map 解析共 4 处改引用 | ✅ |
| **O2.2** | 回归 | eunit | 44/44 | ✅ |

### O3 — 倒排查询 ords 解压缓存统一

**目标（实施中升级）**：原计划做查询内解压缓存；实施时发现 `items[].ord` 在内存中
恒存在（finalize 不清 items），`compressed_ords` 只服务落盘格式——查询路径的
`decompress_ords()`（VByte 全量解码 + 物化 vector）是纯浪费，可直接读 `items[i].ord`。

**顺手发现并修复正确性 bug**：load 的 comp==1 分支只读入 compressed_ords，
不回填 `items[].ord`（resize 后全 0）。而 `find()`/`note_appended()`/`compact()`/
`df` 等内存路径都以 `items[].ord` 为事实来源——快照重载后对既有 term 增量
add_doc 触发 note_appended 使压缩失效，旧 posting 的 ord 全部读成 0，索引损坏。
触发链路：merge → rebuild（finalize+save）→ 重启 load → 写既有 term。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O3.0** | **load 回填 items[].ord（bug 修复）** | `inverted.cpp` load | comp==1 分支 gap_decode 后回填，个数自洽校验 | ✅ |
| **O3.1** | 查询路径免解压 | `inverted.cpp` / `inverted.hpp` | search/explain/phrase/wildcard/fuzzy 5 处热循环直接读 `items[i].ord`（免物化）；wand/bool_search 的游标 `tp.ords` 保留但 `decompress_ords()` 改为从 items 直拷（免 VByte 解码） | ✅ |
| **O3.2** | 回归 | `inverted_test` | 新增 `LoadFinalizedThenAddDocKeepsOldOrds`（load→explain→增量写→搜索）；**测试有牙**：临时禁用回填确认 FAILED，还原后通过。ctest 318/318 | ✅ |

### O4 — bool_search MUST 求交按 df 升序

**目标**：`inverted.cpp` bool_search 多 MUST term 逐个 `set_intersection`，未按
posting list 长度排序。先按 df 升序排，最短 list 优先求交，早期大幅剪枝。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O4.1** | MUST terms 按 df 升序 | `inverted.cpp` | 用索引数组 must_order 按 items.size() 升序处理（must_tps 本体不重排，评分用）；交集为空提前 break | ✅ |
| **O4.2** | 回归 | `inverted_test` | bool 全用例通过，ctest 318/318 | ✅ |

### O5 — 多字段写入 catch-all 合并分词（去重复分词）

**目标**：`search_layer.cpp` on_write_fields 各字段已逐个 `analyze_with_positions`，
catch-all 又把拼接文本完整重新分词一遍（NFKC + jieba 重跑）。改为直接合并各字段
term_data（position 按字段偏移平移），多字段写入分词开销约减半。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O5.1** | catch-all 由各字段结果合并 | `search_layer.cpp` | 各字段 term_data 平移 ca_pos_base（字段最大 position+1）并入；字段内相对位置不变；跨字段间隔仅在「字段尾部有被丢短词」时与拼接版差极小 slop（边角语义，已注释记录） | ✅ |
| **O5.2** | 回归 | `search_layer_test` | 多字段 phrase/near/highlight 全用例通过 | ✅ |

### O6 — Porter stemmer 去临时分配

**目标**：`porter_stemmer.hpp` 规则匹配大量 `std::string(r.first)` / `w.substr()` /
`stem + suffix` 临时串，每词十几次分配。改 `string_view` 后缀 + offset 版 measure +
原地修改。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O6.1** | 规则表 string_view 化 | `porter_stemmer.hpp` | 谓词/measure 全部 string_view；前缀用 stem_of 视图；规则表 constexpr string_view；替换 resize+append，逐词零临时分配 | ✅ |
| **O6.0** | **ies 规则修正（bug 修复）** | `porter_stemmer.hpp` | 原 step1a `erase(size-2)+='i'` 净效果 "ies→ii"（"ponies"→"ponii"），偏离标准 Porter 与自身注释；修正为 "ies→i"。注意：已建索引中受影响词干会变（项目不考虑向后兼容） | ✅ |
| **O6.2** | 回归 | `porter_stemmer_test` | 黄金词表不变 + 新增 `Step1aIes` 锁定修正行为。ctest 319/319 | ✅ |

### O7 — search_cache 失效判定 O(1) 化

**核实后不做（审计误报）**：现实现已把 changed_terms 建成 `unordered_set`，
每个缓存条目只做 O(查询词数) 次哈希查找——并非嵌套线性扫描。条目的 terms
是查询词（通常 1~5 个），总成本 O(m + cache×查询词数)，已接近最优；剩余
可省的只有每次调用重建 changed set，收益可忽略，不值得为此维护反向索引。

| # | 目标 | 状态 |
|---|------|------|
| **O7** | 核实为误报，不改动 | ❌（有意不做） |

### O8 — SearchLayer::field_index 透明 hash

**目标**：`search_layer.cpp:23,32` 每次字段名查找 `std::string(field)` 拷贝。
同 O1 方案，map 加透明 hash。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O8.1** | 字段 map 透明 hash | `search_layer.hpp/.cpp` | fields_ 复用共享头 `StringHash`，两个 field_index 重载查找零拷贝 | ✅ |

### O9 — Erlang 层低垂果实（merge_worker 队列）

**目标**：`bitcask_merge_worker.erl` 队列与列表差的低效写法。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O9.1** | 有序列表差 | `bitcask_merge_worker.erl` | `Files0 -- Expired`（O(n·m)）改 `ordsets:subtract`（O(n+m)，两边已 usort） | ✅ |
| **O9.2** | `Q ++ [Args]` 不改 | — | 核实后不做：入队前必经 `lists:keyfind`（按 Dir 去重）本身就 O(n)，换 queue 模块无法保留 keyfind/keyreplace 语义且不改渐近复杂度 | ❌（有意不做） |
| **O9.3** | 回归 | eunit | 44/44 | ✅ |

**暂不做（记录在案）**：GetResult 零拷贝（API 变更牵动 NIF，归入 V6）；fold/stream 批量
拉接口（接口设计问题，归入 V6）；WAL 批量 flush（动崩溃恢复窗口语义，需单独评审）；
wildcard 词典剪枝（trie/后缀索引工程量大，归入 V6）；LTO（已随 P1 节的 B1 落地）。

---

## 性能优化第二轮（O10-O13 + 内存批次 ✅）

> 来源：`doc/cpp-optimization-zh.md` §七（验收基线）/ §八（三维度深审）。
> 三路并行审计 + 高影响发现逐条对照源码核实；两个审计 "CRITICAL" 为误报
> 已剔除（IndexPool lambda UAF / load() FILE* 泄漏，理由见 §8.1）。

### ✅ 内存优化批次（2026-06-12，两批）

第一批（P0-1..4 + P1-5..8）：live_ 去 vector<bool>；data/hint 写路径成员
复用缓冲；WAL 整条编码一次 fwrite（顺手消掉 add_doc→WAL 的整 map 深拷贝）；
交集内核预分配+裸指针游标；pread_into + fold/get 缓冲复用；score_bow_topk
去 hash map；IndexTask key/text 合并单分配；fstats_ 改 vector 下标。
第二批：bool_search 评分 per-candidate hash 播种 → 平行数组+双指针归并
（**20049 → 39 次分配/查询**）；alloc_ord/advance_ord atomic；SearchCache
shared_mutex+计数 LRU（顺手修返回内部指针的 UAF 窗口）；read_file 双检
共享锁；now_sec_default → CLOCK_REALTIME_COARSE。
验收数字（LD_PRELOAD malloc 计数，`scripts/alloc_audit/`）：put 4→2、
get 4→3、fold 2→0、intersect 17→1 次/操作。回归：ctest 340/340 +
ASan/UBSan 340/340 + TSan 失败集为 HEAD 严格子集（既有 libtbb 假阳性）
+ eunit 44/44。

### O10 — read_file 生命周期修复（UAF + ENOENT 窗口）

**目标**：`read_files_` 缓存改存 `shared_ptr<DataFile>`，`read_file()` 返回
shared_ptr（引用计数 pin 住在途读，merge erase 不再析构正在使用的对象）；
merge 清理把 unlink 收进 read_cache_mu_ 锁内（封死 ENOENT 假失败窗口）。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O10.1** | shared_ptr 缓存 | cask.hpp / cask.cpp | read_files_ 值类型、read_file 返回值、全部调用方 | ☐ |
| **O10.2** | unlink 进锁 | cask.cpp merge 尾部 | erase + unlink 同临界区（冷路径，可持锁做文件系统操作） | ☐ |
| **O10.3** | 回归 | 全量 | ctest + ASan/UBSan + eunit | ☐ |

### O11 — WAL entry framing（[len][payload][crc32]）

**目标**：WAL entry 加长度前缀 + CRC32，replay 可检测半条 entry、精确截断、
跳过损坏条目。这是将来"去 per-entry fflush"（WAL 决策选项 b）的前置。
不向后兼容（约定：不考虑兼容性），replay 直接按新格式。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **O11.1** | 写侧 framing | inverted_wal.cpp | enc_buf_ 前置 4B len 占位 + 末尾 crc32(payload)，一次 fwrite | ☐ |
| **O11.2** | replay 校验 | inverted_wal.cpp | len 越界/CRC 不符 → 截断至上一完整 entry,返回已回放数 | ☐ |
| **O11.3** | 损坏注入测试 | inverted_wal_test.cpp | 截尾/翻转字节两类注入，replay 不读坏数据 | ☐ |

### O12 — merge 后为产物生成 hint ❌（审计误报，核实后不做）

**核实结论**：merger.cpp 的重写循环**本来就逐条写 hint**（merger.cpp:108
`out_hint->write`）且结束时 `finalize()` 封 trailer CRC（merger.cpp:153）。
"merge 产物无 hint、open 被迫 fold(data)" 是布局审计的误报。无事可做。

### O13 — fstats 原子计数器化 ❌（前置核实后不做）

**核实结论**：所有 fstats 更新都经私有 `update_fstats_locked`，发生在
put/remove **已持有**的 unique_lock 内——原子化不会从写路径移除任何一次
锁获取，收益≈0；`info()` 的停顿被 entries 相关状态的同锁读主导，单独
原子化 fstats 救不动。真正的赢面仍是 M6 分片（见 doc §8.2 障碍清单）。
**顺手清理**：带锁公开版 `update_fstats` 零调用方，已删除（API 收窄）。

**记录在案（不实施）**：mutable_pl CoW 协议加断言——无法在运行时检查
"调用方持写 accessor"，类型封装收益/改动比不划算，维持注释约定（M3）；
CaskIter 析构竞态（M4）——API 滥用才触发，文档已警示。

---

## V2 检索加速:K1 — run_must_intersect k-way 化 ✅

> 路线:`doc/kway-blockmax-bmw-zh.md`(k-way → 块级元数据 → BMW)。
> K1 落地 leapfrog 游标骨架与 advance(target) 接口——这是块级元数据
> 与 BMW 的消费接口;**即期性能持平,价值在地基**(数据见下)。

| # | 内容 | 状态 |
|---|------|------|
| K1.1 | k-way leapfrog(最短列表驱动 + galloping advance + liveness 全检,语义与 pairwise 等价) | ✅ |
| K1.2 | 分发:k==1 过滤直拷;**k==2 保留 SIMD pairwise**(实测 leapfrog 慢 10-13%:44.3→50.3μs@4096);k≥3 leapfrog | ✅ |
| K1.3 | 测试:三词交集 / 删除排除 / 极不对称 / 4 词随机对拍(vs 暴力参考集) +4 | ✅ |
| K1.4 | 基准 BoolMustHot3(新增):k-way 1011μs vs pairwise 1005μs@100k(+0.6%,噪声内);31.2 vs 30.2μs@4096(+3%) | ✅ |
| K1.5 | 回归:ctest 346/346 + ASan 346/346 + TSan 失败集零新增 + eunit 44/44 | ✅ |

**诚实结论**:尺寸升序 pairwise + SIMD/galloping 内核在密集与不对称形态
都已经很强,k-way 仅靠去物化拿不到可测收益。保留 k≥3 leapfrog 的理由是
**游标接口先行**——下一步(块级元数据)直接挂进 advance(),不用再改写
交集骨架;若块元数据落地后仍无收益,k≥3 回退 pairwise 只需删一个分支。

**顺手修复**:CaskDocValueTest.SearchTextAfterPut 既有时序竞态(异步 put
索引 vs 同步 on_write 赛跑 ord 0 水位)——测试中补 flush_index() 定序。

---

## V2 检索加速:B1 — must-only 合取 Block-Max 路径 ✅

> 设计与实测:`doc/kway-blockmax-bmw-zh.md` §6/§6.1。building on K1 游标。

| # | 内容 | 状态 |
|---|------|------|
| B1.1 | must-only 门(should/must_not 空,k>0)→ 合取 BMW 路径:K1 leapfrog 对齐 + 堆满后块上界剪枝 + 整块跳跃 | ✅ |
| B1.2 | live/doc_len 懒取(128-ord 块粒度,触达才批量填)——收益主来源 | ✅ |
| B1.3 | idf 改基于 df(O(1);无删除时与原路径位级一致;删除期近似与 Lucene docFreq 同语义) | ✅ |
| B1.4 | 测试 +3:无删除逐分等价(vs 强制原路径)/ 删除成员集 / 深块高分不被误剪 | ✅ |
| B1.5 | 基准:BoolMustHot3/100k **1011→695μs(-31%)**;Hot/100k -8%;Hot/4096 +4.7%(SIMD→懒 leapfrog);新增 BoolMustSkewed canary | ✅ |
| B1.6 | 回归:ctest 349/349 + ASan + TSan 零新增 + eunit 44/44 | ✅ |

**关键发现(改变 v5 设计)**:块跳跃剪枝在全部被测形态未触发——
dl=1 上界有 ~25%/词固有松弛,且 BM25 长度归一压平 tf 钉子(tf=50 ⇒
dl≥50)。**v5 块元数据必须存量化块级最高分(真实 tf+dl),而非 max_tf**;
BoolMustSkewed 是 v5 的验收标尺。详见 kway 文档 §6.1。

---

## V2 检索加速:B2 — v5 块级 impacts(max_tf + min_dl)✅

> 设计修正与实测:`doc/kway-blockmax-bmw-zh.md` §6.2。比 §6.1 预想的
> "量化块最高分"更简且统计无关:块存 (max_tf, min_dl) 对,查询期按
> 当前 idf/avgdl 算上界,天然 admissible(预存分数会随统计漂移失效)。

| # | 内容 | 状态 |
|---|------|------|
| B2.1 | Posting 增 dl(索引时 Σtf,落原 4B padding 零内存增量);add_doc 先求和再追加 | ✅ |
| B2.2 | PostingBlock 增 min_dl;seal/finalize 精确重算(compact 后 dl 随 Posting 保留) | ✅ |
| B2.3 | 快照 InvVersion=5(块 +4B);v4 载入 min_dl=1 回退;load→save 幂等测试 | ✅ |
| B2.4 | upper_bound_from 增 min_dl 参(默认 1 = 旧行为);B1 block_ub 接入 | ✅ |
| B2.5 | LiveChecker 新不变量落档:doc_len == add_doc Σtf(测试 checker 全部对齐) | ✅ |
| B2.6 | 基准:**Hot/4096 49.1→7.63μs;Hot/100k 1431→324μs(vs K1 前累计 4.6×);Skewed -58%** | ✅ |
| B2.7 | 回归:ctest 350/350 + ASan + TSan 零新增 + eunit 44/44 | ✅ |

**剩余(解耦另排)**:TF 量化 + FOR 块压缩(纯体积收益,InvVersion=6
候选);WAND(bag-of-words)路径接入 min_dl 上界(当前仅 bool MUST 路径)。

---

## V2 检索加速:A1 — WAND 块跳跃修复 + C1 — TSan 体系修缮 ✅

### A1:WAND 块跳跃死代码修复 + v5 min_dl 接入

**根因**:原跳跃条件 `block_upper < threshold - heap.top() + 1e-6` 在
threshold == heap.top()(θ 更新同源)时恒 ≈1e-6——**块跳跃从未触发过**
(死代码)。修复:本词块上界 + 其余词列表上界之和 ≤ θ → 整块跳;
块上界接 v5 (max_tf, min_dl)。**不能加绝对 epsilon**:df≈N 时 idf~1e-4,
分数量级 ~1e-4,绝对容差 1e-6 = 巨大相对容差,会把真 top-k 块当
"平分"误跳(开发中实测踩中)——只认 <=(位级平分才跳,严格优于语义)。

| 基准(中位) | 修复前 | 修复后 |
|---|---|---|
| SearchHotTerm/4096 | 51.5μs | **4.66μs(11×)** |
| SearchHotTerm/100k | 1716μs | **177μs(9.7×)** |
| SearchWhileIndexing 4r×1w | (P1 时代 2459μs) | **167μs** |

安全网测试:WandSkipTopKEqualsUnprunedPrefix(小 k 剪枝结果 ==
大 k 无剪枝前缀;(tf,dl) 与 d 双射构造唯一分数 + 同分位放宽断言——
首版随机 tf 大量同分曾误报"丢结果",实为并列层合法自由度)。

### C1:TSan 体系修缮(三层)+ 两个真竞态修复

**最大发现:所有库目标从未链接 bitcask_sanitizers——历来的
sanitizer 构建只插桩了测试 TU,库代码的数据竞争仅靠 memcpy/new
拦截器间接可见**(每条报告 #0 都是拦截器即此故)。修缮后 TSan
**首次 351/351 全绿**,且是全插桩条件下:

1. 全部 10 个库 target 链接 bitcask_sanitizers(普通构建空 INTERFACE 零影响);
2. TSan 构建 FetchContent 源码编译插桩版 oneTBB v2022(系统 libtbb 的
   fence 同步 TSan 不可见);TBB 调度器仍有 fence 残余 →
   cmake/tsan.supp(race:*tbb*)经测试 ENVIRONMENT 属性注入
   (动态 libtsan 不回调二进制内 __tsan_default_suppressions,实测零匹配);
3. IndexTaskQueue push/pop 加 __tsan_release/acquire 标注
   (任务 payload 经 tbb 队列移交的 HB 显式化,非 TSan 构建空操作)。

**降噪后立刻捕获两个生产真竞态(并修复)**:
- SearchLayer::fields_:IndexPool worker 首写新字段 emplace vs 查询
  线程 find——加 fields_mu_(shared_mutex,双检升级);
- DocTextLru:worker put vs 高亮查询 get——内置 mutex,get 改返回
  拷贝(顺带封掉返回内部指针的 UAF 窗口)。
- SearchLayer 头注释的线程模型声明("非线程安全")与生产形态不符,
  已修订为「单写者 + 多读者」并注明各成员的保护方式。

回归:plain/ASan/TSan 三树 351/351 + eunit 44/44;基准无回归
(SearchHotTerm/BoolMust 与 A1 后持平)。

---

## A4 — keydir 段快照 + 尾部回放(Phase 1,KV 路径)✅

> 设计:`doc/recovery-snapshot-design-zh.md`。close/merge 末尾把 keydir
> 内存态 + per-file 字节水位落盘(BCKS v1,CRC + tmp/rename);open 加载
> 快照后各文件只 fold 水位后的尾巴。快照是纯优化:任何校验失败回退
> 全量 fold。水位先于 dump 捕获(回放重叠区幂等,方向安全)。

| # | 内容 | 状态 |
|---|------|------|
| A4.1 | KeyDir::save_snapshot/load_snapshot(BCKS v1;活跃 fold 拒绝;load 失败清态回退) | ✅ |
| A4.2 | DataFile::fold 增 start_offset;load_keydir_from_disk 快照快路径(仅 KV;hint 分支让位) | ✅ |
| A4.3 | 写入点:close()(写者静止)+ merge 末尾(最紧凑态);best-effort | ✅ |
| A4.4 | 测试 +3:快照/全量 fold 等价、陈旧快照尾部回放(新增/覆写/墓碑)、损坏注入回退(位翻转+截断) | ✅ |
| A4.5 | 基准 BM_Cask_Open:**29.1ms → 2.58ms(11.3×,20k 记录;计时含 close 重写快照)** | ✅ |
| A4.6 | 回归:plain/ASan/TSan 354/354 + eunit 44/44(UBSan 抓到一处未对齐读,已修) | ✅ |

**Phase 2(待做,设计 §4)**:search 路径——open 现状从不加载 bm25 快照,
启用前缀跳过需先接通 search_->load_snapshot + WAL 链,并与 keydir 快照
成对落盘/校验。该结构同时是 V3 HNSW 持久化(快照+回放)的模板。

---

## A4-P2 — search 快照链(基建落地,门暂闭)◐

| # | 内容 | 状态 |
|---|------|------|
| P2.1 | close 成对保存 bm25 快照 + keydir 快照(同一写者静止点;WAL 随 save 截断) | ✅ |
| P2.2 | open 接通 search_->load_snapshot + per-field WAL 重放(此前从不加载) | ✅ |
| P2.3 | 成对性门:SearchLayer::indexed_ord_floor / KeyDir::peek_next_ord / InvertedIndex::max_indexed_ord 三个访问器 + 门逻辑 | ✅ |
| P2.4 | **门强制关闭**:实测 SearchSurvivesMerge 暴露 Index 侧表缺口(ext2ord/live/doc_lens 无持久化来源;doc_len 不在任何快照里)——跳过前缀 ⟹ live 全空 + v5 dl 不变量失守 | ⚠️ |
| P2.5 | 回归:plain/ASan/TSan 354/354 + eunit 44/44(search 全量 fold 语义不变,快照加载经 add_doc 水位幂等无害) | ✅ |

**Phase 3 解锁条件**:Index sidecar 快照(ext2ord/slots/doc_lens/live;
建议并入 keydir 快照的扩展节)。就位后把 cask.cpp 成对性门里的
`covered = false` 行删掉即生效——其余链路已通。

---

## 未来任务

### P1 — 查询路径 PostingList 零拷贝（Phase 1 ✅ + Phase 2-min ✅）

> 设计文档：`doc/posting-zero-copy-design-zh.md`。原状：6 个查询路径每词
> 深拷贝整个 PostingList（含逐 posting 的 positions 堆分配），查询侧最大单项开销。

**基准先行**：新增 `cpp/bench/inverted_bench.cpp`（bitcask_bench 目标，
`--benchmark_filter=Inverted`）：SearchHotTerm/{512,4096,100k}（标量 + WAND
两路径）、BoolMustHot、SearchWhileIndexing（4 reader × 1 writer）。

**Phase 1（方案 D：扁平快照）已落地**：

| # | 内容 | 状态 |
|---|------|------|
| P1.1 | `FlatPostings`（ords/tfs/blocks/max_tf）+ `PostingList::snapshot_flat()`；block_for_ord/block_upper_bound 提取共享实现 | ✅ |
| P1.2 | search/wand/bool/wildcard/fuzzy 5 路径改扁平快照（分配 N+1→2 次、拷贝 ~40B+positions→12B/posting）；phrase/near 保留深拷（需 positions，Phase 2 处理）；explain 本就持 accessor 短读不拷 | ✅ |
| P1.3 | 并发回归 `SearchConcurrentWithSingleWriter`（4 reader × 单写者同 term 追加，对齐 IndexPool 线程模型），TSan 下单测干净 | ✅ |
| P1.4 | 回归：ctest 320/320 + eunit 44/44 | ✅ |

**基准结果**（同机同配置 before/after）：

| benchmark | before | after | Δ |
|---|---|---|---|
| SearchHotTerm/512（标量） | 25.1us | 15.7us | **-38%** |
| SearchHotTerm/4096（WAND） | 208.5us | 57.6us | **-72%** |
| SearchHotTerm/100k（WAND） | 6090.6us | 1816.5us | **-70%** |
| BoolMustHot/100k | 14682.5us | 5730.1us | **-61%** |
| SearchWhileIndexing 4r×1w | 8761.4us | 2459.2us | **-72%** |

**已知事项**：TSan 全量跑 inverted_test 时 `BlockMaxWandBasic` 报 4 条
warning——已验证 **HEAD（P1 之前）同测试报同签名 race**：系统 libtbb 无
TSan 插桩，parallel_reduce 任务派发的 happens-before 边对 TSan 不可见的
既有假阳性类（修复方向：TSan 构建链接插桩版 TBB 或加 suppression，归
工程化任务）。完整 Phase 2 按设计文档判据暂不启动。

**Phase 2-min（phrase/near 零拷贝子集）已落地**：

| # | 内容 | 状态 |
|---|------|------|
| P2.1 | map 值改 `shared_ptr<PostingList>`（`PostingMap` 别名）；新增 `mutable_pl()` CoW 协议：写者持写 accessor 时 `use_count()==1` → 原地改（常态零开销，observe 后补 acquire fence 与读者 release 递减配对）；`>1`（有 phrase 读者持引用）→ 克隆替换，旧版本靠引用计数续命 | ✅ |
| P2.2 | phrase/near 改持 `shared_ptr<const PostingList>` 零拷贝读（原先深拷整列表含全部 positions）；add_doc/compact/finalize 全部经 `mutable_pl`（finalize 从迭代器裸改改为 key 快照 + 写 accessor 模式） | ✅ |
| P2.3 | **顺手发现并修复**：wildcard/fuzzy 在遍历 concurrent_hash_map 期间取值不安全——遍历中调 `find()` 触发懒 rehash 节点搬迁致迭代器**重复访问同一节点**（实测复现，曾使 S10.2 去重失效）。改为两阶段：遍历只收集 key，遍历结束后逐 key 经 const_accessor 取值（顺带消除了既有的「遍历中裸读 slot 值」hazard） | ✅ |
| P2.4 | 回归：`CowClonesWhenReaderHoldsReference`（CoW 协议确定性验证：持引用→克隆、释放后→原地）+ `PhraseSearchConcurrentWithSingleWriter`（4 phrase 读者 × 单写者同 term 追加），TSan 下两者干净（全量仍只有已知 TBB 假阳性类）。ctest 322/322 + eunit 44/44 | ✅ |

**Phase 2-min 基准**（同会话 before/after，5 次重复取中位）：
PhraseHotTerm/100k **12448us → 8459us（-32%）**、/4096 424us → 319us（-25%）。

**+10% 疑点的严格 A/B 归因（已解决）**：P1-only（73009b0）与 P1+P2min（HEAD）
两个 worktree、同一份 bench 源（消除 bench TU 布局差）、同会话交替 6 轮取中位：
SearchHotTerm/100k A=1849us / B=2035us（+10.0%，分布不重叠）——回退真实存在但
**不是算法成本**：① SnapshotOnly 微基准两侧完全相同（~115us，排除 shared_ptr
间接寻址）；② 两侧加 `-falign-functions=64 -falign-loops=64` 重编后差距塌缩到
+0.4%（A≈1830us / B≈1840us）——根因是 inverted.cpp 新增函数改变了 search_wand
热循环的**代码对齐/布局**（icache 伪影）；③ 对齐构建下 phrase 收益不变
（A 12.4ms / B 8.4ms，-32%，算法性收益）。
**启示**：该热循环对代码布局敏感（±10%），后续任何 inverted.cpp 改动的基准对比
都应在对齐构建下进行。

### B1 — Release 构建性能选项（✅ 已落地）

`cpp/CMakeLists.txt`：① `-falign-functions=64`（仅 Release，GNU/Clang）——
消除上述对齐伪影，基准可复现、性能对无关代码改动免疫；② LTO/IPO
（`BITCASK_LTO` 选项，默认 ON；`CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE`
只作用于 Release 配置，sanitizer 构建自动关闭——`BITCASK_SANITIZE` 非空即跳过，
Debug/tsan/asan 构建目录均不受影响，已验证 tsan 构建无 LTO 且测试通过）。

**收益**（对比落地前同会话基准，3 轮中位）：SearchHotTerm/4096
62us → **51.7us（-17%）**；/100k 2035us → **~1750us（-14%）**；
BoolMustHot/100k 5977us → **~5460us（-8%）**；PhraseHotTerm/100k
~8200us → **~7660us（-7%）**。其中对齐贡献约消除 +10% 伪影，LTO 贡献
额外 -5~12%（跨 TU 内联）。

**代价**：LTO 全量构建 ~55s（链接期代码生成）；rebar3 增量路径不受影响
（bitcask_cpp 无改动时仍是 no-op）。eunit 验证 BEAM 正常加载 LTO 的
NIF .so（44/44）；ctest 322/322。

### P2 — 查询路径 SIMD / 位并行优化（已评审，待实施）

> 评审结论（2026-06）：反汇编 LTO 后最终二进制，BM25 评分循环 packed float
> 指令数为 **0**——`-O3` 自动向量化被循环体内逐 posting 的 `is_live()`/
> `doc_len()` 虚调用结构性阻断。P1 后评分数据已是扁平 SoA 数组
> （fp.ords/fp.tfs），向量化条件具备，前置是去虚调用。
> ISA 现状：未设 -march，基线 x86-64（SSE2）；分发策略建议 GCC
> `target_clones` 函数多版本（零部署风险），仅在不够时上 intrinsics +
> 运行时 dispatch。所有基准对比必须在对齐构建（B1）下做。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **P2.1** | LiveChecker 批量接口 | `inverted.hpp` / `index.hpp/.cpp` / `inverted.cpp` / bench | ✅ 已落地：`fill_is_live`/`fill_doc_lens` 批量虚接口（默认回退逐条，外部实现者零改动；Index 覆写为**一次 shared_lock 扫整列**——此前每 posting 一锁，热词查询 ≈20 万次锁）。评分循环改两阶段（①纯数组浮点→自动向量化已确认（objdump 见 packed mulps/divps），公式逐运算一致分数位级不变；②标量 scatter）；wand 的 DAAT 每 pivot is_live/doc_len 改读批量数组（零锁零虚调用）；bool 五阶段 live 重扫合并为一次；phrase first-term live 批量。**生产形态基准**（新增 LockedScalar/LockedBatch 对照，模拟 Index 的每调用一锁）：SearchHotTerm/100k **5570us → 1900us（-66%）**，已逼近无锁 checker 水平（~1830us）。诚实记录：无锁 checker 下 +3~5%（dls 数组的额外内存流量在 checker 本身免费时无补偿；生产 checker 永远带锁，不受此影响）。ctest 322/322 + eunit 44/44 + TSan 并发用例干净 | ✅ |
| **P2.2** | bool_search 求交 SIMD 化 | 新 `intersect.hpp/.cpp` / `inverted.cpp` / `inverted_test.cpp` | ✅ 已落地（原理与设计记录：`doc/bool-search-intersection-zh.md`）：三路自适应交集库——悬殊（>32x）galloping、相近大小走 AVX2 shuffle 块交集（8 lane 全对全比较 + 256 项 LUT 压缩存储，运行时 `__builtin_cpu_supports` 分发，无 AVX2 退标量归并）。ord 窄化采用**查询内安全窄化**而非全局改 u32：fp.ords 升序 → O(1) 查 `back()≤0xFFFFFFFF`（几乎恒真），超界走原 u64 标量路径语义不变。窄化路径顺手去掉原先冗余的 sort/unique（fp.ords 已升序唯一、live 过滤保序）。黑盒对拍 432 组随机（块边界尺寸×重叠密度）+ 悬殊双向 + 全/零重叠。**基准**：BoolMustHot/4096 183us → **148us（-19%）**、/100k 5620us → **4370us（-22%）**。ctest 327/327 + eunit 44/44 + TSan 干净 | ✅ |
| **P2.3** | fuzzy 换 Myers 位并行 | 新 `myers.hpp` / `inverted.cpp` / `fuzzy_test.cpp` | ✅ 已落地：`MyersMatcher`（单字版，m≤64 恒满足分词产物；>64 退回经典 DP 保正确；k-bounded 提前终止；每查询词建一次 Peq 摊销全词典扫描）。原 levenshtein 还有**每次调用 2 个 vector 堆分配**，一并消除。保留 S10.3 长度差剪枝。黑盒对拍 5000 组随机串（k∈0..3）+ m=64/65 边界 + UTF-8 字节语义，全过。**基准**：新增 FuzzyVocabScan（20 万词表 d=2）27.8ms → **20.7ms（-26%）**；匹配内核本身 ~38ns/词 → ~3.5ns/词（**~11x**，符合理论）；端到端剩余成本由 concurrent_hash_map 20 万节点指针遍历主导（词典侧表/排序字典是下一个杠杆，与 wildcard trie 同属 V6 词典结构议题）。FuzzyHot 不变（评分主导，符合预期）。ctest 324/324 + eunit 44/44 | ✅ |
| **P2.4** | Index 侧表内存布局优化（评审后改向） | `index.hpp/.cpp` / `inverted.hpp/.cpp` / bench | ✅ 已落地。**改向理由**：原设想「查询路径读位图」的价值已被 P2.1 批量接口吃掉；重新聚焦为侧表布局。① **doc_len SoA**：`doc_lens_`（u32 紧凑数组）作为读优化副本与 `slots_` 同锁同写，`fill_doc_lens` 的稀疏 gather 从 DocSlot 32B/项（每 cache line 4B 有用）改读 16 项/line；get/for_each_live 的 API 语义不变。② **compact 批量化**：死点统计与压实共用一次 `fill_is_live`（此前各自逐 posting 一次带锁虚调用）；`PostingList` 加 `compact_flags`（下标对齐 flags），谓词版转调保兼容。**基准**：新增 SearchIndexChecker（真实 index::Index 当 checker，1M 文档侧表、热词 posting 步长 10 散布）2570us → **2180us（-15%）**。**明确不做**：`live_` 换字位图（留给 merge 相关维护工作一起）、Roaring（ord 空间过亿再说，归 V6）。ctest 327/327 + eunit 44/44 | ✅ |
| **P2.5** | 文本侧优化（索引路径） | `text_utils.hpp` / `wildcard_matcher.hpp` / `inverted.cpp` / 新 `analyzer_bench.cpp` | ✅ 已落地。**先 profile 后动手**：新建文本层基准量化得 nfkc_fold 占 analyze 的 56%（拉丁），to_codepoints 仅 8% → **simdutf 评审后不引**（解码非瓶颈，不为 <10% 的占比加依赖）。实际做的三件事：① **nfkc_fold ASCII 快路径**——纯 ASCII 的 NFKC_Casefold 数学等价于逐字节 tolower（NFKC 稳定区 + casefold=小写 + 无 ignorable），1KB 拉丁 11.8us → **0.55us（21x）**；② 非 ASCII 路径换 `utf8proc_map` 显式长度——消除「输入 null 终止拷贝」与「输出 strlen」两次冗余全串遍历（行为差异仅内嵌 \0：旧版截断、新版处理全长，更正确）；③ to_codepoints ASCII 内联免 utf8proc_iterate 库调用（-30%）+ wildcard 最长字面量 `find` 预过滤（必要性条件，20000 组随机对拍证明不拒真命中；本基准形态收益温和 ~10%，对 `*xyz` 类回溯重模式收益更大）。**端到端**：AnalyzeWhitespaceLatin 20.9us → **7.5us（-62%）**；CJK 路径不变（走原 utf8proc，符合预期）。ctest 332/332 + eunit 44/44 | ✅ |
| **P2.5b** | CJK 恒等快路径（nfkc_fold 推广） | `text_utils.hpp` / `analyzer_test.cpp` / `analyzer_bench.cpp` | ✅ 已落地。把 ASCII 快路径推广为「全部码点 ∈ NFKC_Casefold 恒等区段 ∪ ASCII」的统一判定：命中则输出 = 原串 + ASCII 字节 tolower（UTF-8 多字节序列字节恒 ≥0x80，按字节 tolower 安全），跳过整条 utf8proc 流水线。恒等表（CJK 基本区/扩展 A/、。《》「」【】等/——/弯引号）成员要求「恒等 ∧ 组合类 0 ∧ 不参与规范组合」——成员间无跨码点重组，逐码点判定即整串判定；**穷举验证**：表内每个码点经 utf8proc 断言不变（表错即测试红），另有 3000 组混合字母表随机串黑盒对拍 + 定向用例（全角标点/全角字母正确回退折叠）。**基准**：NfkcFold 中文+半角英文 7.2us → **1.37us（5x）**，对应 ngram 分词端到端 27.0 → **19.5us（-28%）**；全角逗号对照组不变（正确回退）；统一判定后拉丁 0.55→0.66us（判定变富的代价，仍为原始 11.8us 的 18x）。**边界记录**：含全角标点（，：！？）的中文正文整串回退——分段版（需 starter 边界安全处理）留作语料证明需要时的后续。ctest 335/335 + eunit 44/44 | ✅ |
| **P2.6** | 基准扩充 | `inverted_bench.cpp` | ✅ 随 P2.1 落地：FuzzyHot（热词 100k posting + 1024 冷词，基线 ~3000us 供 P2.3 对比）、SearchLockedScalar/Batch 生产形态对照 | ✅ |

**评审后明确不做**：snapshot_flat 的 SIMD AoS→SoA（内存带宽主导，且完整
Phase 2 零拷贝会让它整体消失）；phrase 位置匹配 SIMD（分支/二分主导，
收益边缘）；CRC32 加速（系统 zlib 1.3.1 braiding 标量已数 GB/s，KV 路径
够用；换 zlib-ng/crc32c 涉及依赖与格式，不值）。

**诚实预期**：P2.1 后标量 search 路径的 `local[ord] += score`（hash map
scatter）不可向量化，可能成为新瓶颈——profile 后再决定是否改两阶段累加；
WAND 路径无此问题。建议顺序：P2.1 → 基准 → P2.2 → P2.3。

### P3 — 高强度 code-review 修复（✅ 已落地）

> P1/P2 全系列落地后做了一轮 7 角度 high-effort review（3 correctness +
> 3 cleanup + 1 altitude），~30 候选去重验证。1 个崩溃级 + 2 个一行级遗留
> 已修，附带 2 个低风险加固。

| # | 问题 | 修复 | 状态 |
|---|------|------|------|
| **P3.1** | **崩溃级**：崩溃恢复时 save/truncate_wal 非原子窗口 → load+replay_wal 重放快照已含的 add_doc → PostingList.items 重复/乱序，违反 bool_search（P2.2 删 sort+unique 后新依赖）的「严格升序无重复」前置 → intersect_avx2 越界写堆（验证 agent fuzz 实复现 SIGSEGV/malloc abort，NIF 形态会带崩 BEAM） | **根因**：InvertedIndex 加 `max_indexed_ord_` 水位，add_doc 幂等丢弃 ord≤水位的整文档（修复被违反的不变量本身、正常路径 O(1) 一次比较、并修正 inverted.hpp 错误注释「同一 ord 不会出现两次」），load 末尾重建水位。**纵深防御**：intersect_avx2 每轮 storeu 前守卫 `cnt+8≤out.size()`，违约输入扩容不写穿堆。**测试有牙**：`AddDocIdempotent`/`CrashRecovery`（去水位即 FAIL）+ `DirtyDuplicateInputDoesNotOverflow`（ASan 下去守卫即确定性 SEGV） | ✅ |
| **P3.2** | bool_search 最终评分循环漏掉 P2.1 批量化——逐 posting 调 `doc_len`（生产 Index = 每次一把 shared_lock+虚调用），search/wand/wildcard/fuzzy 都已改、唯独此处遗留锁风暴 | TermPostings 加 `dls`，fill_live 对 must/should 同时 `fill_doc_lens`（must_not 只建排除集免取），评分循环读 `tp.dls[i]` | ✅ |
| **P3.3** | search() 路由 WAND 时双倍快照：入口先对全部 term snapshot_flat 只为数 total_postings、判定后整组丢弃，search_wand 重新 find+快照——浪费恰在 posting 最大（≥阈值）的查询上 | 路由判定改为 accessor 下读 `items.size()`（不快照），仅标量路径才 snapshot_flat | ✅ |
| **P3.4** | MyersMatcher 持 `string_view pattern_` 仅服务 m>64 回退，临时串构造会在最冷路径悬垂读 | 改持 owned `std::string`（回退路径冷、拷贝无代价，消除生命周期前提） | ✅ |

**复审驳回**：`save()` 裸读 shared_ptr 的并发指控——验证确认 save 仅在 merge 路径调用，前置 `rebuild_index` 已在调用线程同步换上线程私有新 index，save 遍历的对象从未被 worker 触碰；单 handle 所有权契约保证无并发写者。**未修（记录）**：wand 可见性窗口扩大（PLAUSIBLE，与系统既有最终一致语义同级，上层对 stale ord 安全）；cleanup 类（死状态 compressed_ords/finalized、三份重复评分块、u64 回退影子路径）攒独立 commit。**全量**：ctest 338/338（+3 回归）+ eunit 44/44 + ASan inverted/wal/fuzzy 干净 + TSan 并发用例干净。

### P4 — review cleanup 类（✅ 本批已落地）

> P3 修完崩溃级/遗留后，做 review 记录的 cleanup（reuse/simplification/altitude）。
> 本批挑收益高、风险可控的做，每项独立验证；format-risk 项留后续。

| # | 内容 | 状态 |
|---|------|------|
| **P4.1** | 删死代码：`PostingList::decompress_ords()`（O3 后零调用方）+ `compact(IsLive)` 模板（P2.4 后被 `compact_flags` 取代、零 lambda 调用方） | ✅ |
| **P4.2** | 三份逐字相同的「批量 live/doc_len + 两阶段评分 parallel_reduce + 小顶堆 top-k」（search 标量/wildcard/fuzzy 各一份 ~75 行）提取为单一 `score_bow_topk` kernel；三处简单 `TermPostings{term,fp}` 合并为共享 `ScoredTerm`。BM25 公式与「分数位级不变/无分支可向量化」不变量从此只一处——消除「改公式漏改低频路径致评分不一致」的抄写漂移风险（O3/O6 回归即此类事故）。inverted 核心净 **−132 行**（109+/241−）。ctest 338/338（评分各路径有分数断言护着）+ bench 无回归 + eunit 44/44 | ✅ |

| **P4.3** | 两阶段 tbb 词表扫描提取 `collect_term_keys`：「遍历 concurrent_hash_map 只收集 key（不可 find/裸读，懒 rehash 会致迭代器重访/CoW 撕裂）+ sort/unique 去重」这条**实测复现过的并发不变量**此前在 wildcard/fuzzy/finalize_all_postings/compact 4 处各带一段警告注释复制——收敛到单一 helper（谓词过滤版），调用方只剩「逐 key 经 accessor 取值/改值」。价值在不变量集中（下个加词表扫描功能的人照抄 helper 而非重踩 rehash bug），非行数。ctest 338/338 + ASan(inverted/fuzzy/wildcard) 干净 + TSan 并发用例干净 + bench 无回归 + eunit 44/44 | ✅ |

| **P4.4** | 删 `compressed_ords`/`finalized` 内存死状态：O3 后查询路径从不读压缩副本（items[].ord 恒为事实来源），二字段只服务 save 的格式决定却让维护者误以为是读路径事实来源。删两字段——`save()` 改为现场 `gap_encode(items.ords)`（与旧 finalize 写出的字节逐字节一致，磁盘格式不变）、`load()` 解码进局部缓冲回填 items[].ord 后丢弃、`finalize`/`note_appended`/`compact_flags` 去掉压缩维护。`note_appended` 的尾块弹出逻辑独立于 finalized 标志（已确认），不受影响。净 −23 行 + 永久省 1-2 字节/posting 内存。两个误导命名测试（FinalizeCompressesOrds/ReducesMemory，实际只断言 search/df 不变）改名为 FinalizePreservesSearchResults/KeepsDfStable。**验证**：SaveLoadRoundtrip（非 finalized→现在 comp=1 路径）+ SaveLoadWithFinalizedPostings + LoadV3SnapshotBackwardCompat（新 load 读旧 finalize 的 comp=1 字节，证字节一致）+ LoadFinalizedThenAddDocKeepsOldOrds（回填路径）全过；ctest 338/338（×3 稳定）+ ASan 干净 + eunit 44/44 | ✅ |

| **P4.5** | bool_search MUST 交集的 u64 影子路径——加测试 + 合并骨架。① **加测试** `BoolSearchMustU64Fallback`：用 ord>2^32 的大值（非 43 亿文档）强制窄化闸门拒绝、走 set_intersection 回退；**有牙验证**：临时清空 u64 交集结果，仅此测试 fail（其余 bool 测试走 u32 路径全过），证明它精确覆盖此前无测试的回退分支。② **合并骨架**：u32 窄化 / u64 回退两条逐字相同的「must_order 升序遍历 + live 过滤 + 空交集 break」循环用 C++23 模板 lambda（`run_must_intersect<T>`）合一,只在「intersect_u32 三路 SIMD vs set_intersection 标量」处分叉——改 MUST 语义不再需人工同步两份。u32 仍全程 u32（T=uint32_t），LTO 下模板内联,**bench 无回归**（BoolMustHot/4096 150us、/100k 4400us 持平 P2.2）。净 −5 行。ctest 339/339 + ASan(bool/intersect/concurrent/CrashRecovery) 干净 + eunit 44/44 | ✅ |

| **P4.6** | u64 AVX2 交集原型收录为附录：`cpp/bench/intersect_u64_proto_bench.cpp`（opt-in bench，含自检对拍 + 对抗性「低 32 位碰撞」模式，烂掉即 SkipWithError 报红）。成对 permutevar8x32 模拟 64 位变量 shuffle + 原生 cmpeq_epi64，库内实测 **~3.5-3.7x** 于标量归并；设计/触发条件/接线步骤见 `doc/bool-search-intersection-zh.md` §7.1。**未接线生产代码**——触发条件仍是 ord>2^32（u64 回退变热），届时按文件头注释接入即可 | ✅ |

**本批未做（记录，留后续独立 commit）**：测试侧 LCG/LiveChecker 桩重复（建共享测试头，纯测试维护性）；nfkc_casefold_inert 表改离线 Unicode 数据生成（引入构建期工具，altitude）。

### V3 — HNSW 单图 + search_vector（暂缓）

### V4 — 单域 merge

### V5 — 混合检索 + metadata filter

### V6 — 性能与规模化
