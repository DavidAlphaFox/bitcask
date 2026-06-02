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

## 未来任务

### V3 — HNSW 单图 + search_vector（暂缓）

### V4 — 单域 merge

### V5 — 混合检索 + metadata filter

### V6 — 性能与规模化
