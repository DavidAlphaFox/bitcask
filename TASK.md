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
| **U1.1** | 数据结构加 ord | `keydir.hpp` | `SingleEntry` / `EntryProxy` 增加 `uint64_t ord = 0` | ⬜ |
| **U1.2** | put 签名加 ord | `keydir.hpp` / `keydir.cpp` | `put()` 末尾加 `uint64_t ord = 0` 参数；实现中将 ord 存入 SingleEntry / MultiEntry | ⬜ |
| **U1.3** | alloc_ord | `keydir.hpp` / `keydir.cpp` | 新增 `uint64_t alloc_ord()`（unique_lock, 返回 `next_ord_++`）；私有成员 `uint64_t next_ord_ = 0` | ⬜ |
| **U1.4** | advance_ord | `keydir.hpp` / `keydir.cpp` | 新增 `void advance_ord(uint64_t ord)`（恢复用，推进 `next_ord_`） | ⬜ |
| **U1.5** | get 填充 ord | `keydir.cpp` | `get()` / `find_at_epoch_locked()` 填充 `EntryProxy.ord` | ⬜ |
| **U1.6** | deep_copy 含 ord | `keydir.cpp` | 拷贝 `next_ord_` | ⬜ |
| **U1.7** | 单元测试 | `keydir_test.cpp` | alloc_ord 单调递增 / advance_ord 不冲突 / put+get 带 ord / MultiEntry 场景 | ⬜ |
| **U1.8** | 回归验证 | 全量 | 144/144 现有测试通过（新增参数有默认值） | ⬜ |

---

### U2 — Phase 2：Cask 适配 DocValue + ord + bitcask.meta

**目标**：Cask 的 put/get 使用 DocValue 格式，始终分配 ord，open 时检查/创建 bitcask.meta。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U2.1** | bitcask.meta 格式 | 新建 `meta_file.hpp` / `meta_file.cpp` | `MetaConfig` 结构 + `read_meta()` / `write_meta()` / `meta_exists()`；二进制格式 "BCME"+配置 | ⬜ |
| **U2.2** | CaskOptions 扩展 | `cask.hpp` | 增加 `std::optional<SearchLayerConfig> search_config`（Phase 3 定义 SearchLayerConfig，此处 forward declare） | ⬜ |
| **U2.3** | CaskError 新增 | `cask.hpp` | `kNoIndex` / `kModeMismatch` / `kAnalyzerMismatch` / `kCannotUpgrade` | ⬜ |
| **U2.4** | open 模式检查 | `cask.cpp` | `Cask::open()` 读 bitcask.meta → 验证模式匹配 → 空目录创建 meta → 非空目录报错 | ⬜ |
| **U2.5** | put 编码 DocValue | `cask.cpp` | `put()` 内部：`alloc_ord()` → `encode_doc_value{text=value}` → `write(kDoc, ts, ord, key, encoded)` → `keydir.put(..., ord)` | ⬜ |
| **U2.6** | get 解码 DocValue | `cask.cpp` | `get()` 内部：pread → `decode_doc_value()` → KV 模式提取 text 段返回 binary；`GetResult` 增加 `ord` | ⬜ |
| **U2.7** | remove 带 ord | `cask.cpp` | `remove()` 分配 ord → 写墓碑 → `keydir.remove()`；`keydir.put()` 调用传 ord | ⬜ |
| **U2.8** | load_keydir_from_disk 改为始终 data fold | `cask.cpp` | 从 record header 读 ord（`view.ord`）→ `keydir.put(..., view.ord)` + `keydir.advance_ord(view.ord)` | ⬜ |
| **U2.9** | CaskIter Entry+ord | `cask.hpp` / `cask.cpp` | `CaskIter::Entry` 增加 `uint64_t ord`；`next()` 从 `EntryProxy::ord` 取值 | ⬜ |
| **U2.10** | NIF 适配 put/get 变更 | `nif_cask.cpp` | put 适配新签名（put 仍返回 ok）；get 适配 `GetResult+ord`（返回给 Erlang 时忽略 ord） | ⬜ |
| **U2.11** | 回归测试 | 全量 | 所有 C++ 测试通过 + NIF 端到端验证 | ⬜ |

---

### U3 — Phase 3：SearchLayer 模块

**目标**：创建独立的 SearchLayer 类，封装 Index + InvertedIndex + Analyzer。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U3.1** | SearchLayerConfig | `search_layer.hpp` | 配置结构：`AnalyzerConfig + Bm25Params` | ⬜ |
| **U3.2** | SearchLayer 类 | `search_layer.hpp` / `search_layer.cpp` | 新建类：持有 `Index + unique_ptr<InvertedIndex> + unique_ptr<Analyzer>` | ⬜ |
| **U3.3** | on_write | `search_layer.cpp` | 接收 (key, ord, text, loc, ts)：切词 → `index.put_doc()` → `inverted.add_doc()` | ⬜ |
| **U3.4** | on_delete | `search_layer.cpp` | 接收 (key)：取旧 DocSlot → `inverted.remove_doc()` → `index.remove()` → 返回旧 ord | ⬜ |
| **U3.5** | on_relocate | `search_layer.cpp` | 接收 (key, ord, new_loc)：`index.put_doc()` 更新 loc（ord 不变） | ⬜ |
| **U3.6** | search_text/phrase | `search_layer.cpp` | 切词 → `inverted.search()` → ord→key 翻译 → 返回 `vector<SearchHit>` | ⬜ |
| **U3.7** | recover_doc/tomb | `search_layer.cpp` | 恢复用：与 Collection::recover 逻辑相同 | ⬜ |
| **U3.8** | snapshot save/load | `search_layer.cpp` | 包装 `inverted_->save/load` | ⬜ |
| **U3.9** | 单元测试 | `search_layer_test.cpp` | write → search → delete → search / on_relocate / recover 场景 | ⬜ |
| **U3.10** | CMake 接线 | `CMakeLists.txt` | 新增 `bitcask_search` target + `search_layer.cpp` | ⬜ |

---

### U4 — Phase 4：Cask 集成 SearchLayer + 统一 put/get

**目标**：Cask 持有 SearchLayer，搜索模式下 put 自动建索引，get 返回完整信息。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U4.1** | Cask 持有 SearchLayer | `cask.hpp` | `unique_ptr<SearchLayer> search_` + `has_search()` + `search()` | ⬜ |
| **U4.2** | open 创建 SearchLayer | `cask.cpp` | `if (opts.search_config) search_ = make_unique<SearchLayer>(*opts.search_config)` | ⬜ |
| **U4.3** | put 增加搜索通知 | `cask.cpp` | put 后 `search_->on_write(key, ord, text, loc, ts)` | ⬜ |
| **U4.4** | put_doc 方法 | `cask.hpp` / `cask.cpp` | 新增 `put_doc(key, DocInput, tstamp)`：编码 DocValue（含 text+meta+vector）+ 搜索通知 | ⬜ |
| **U4.5** | get 索引模式返回 map | `cask.hpp` / `cask.cpp` / `nif_cask.cpp` | `GetResult` 扩展含 DocValueView；NIF 层索引模式返回 `#{text => ..., meta => ...}` | ⬜ |
| **U4.6** | search_text/phrase | `cask.hpp` / `cask.cpp` | 新增 `search_text(query, k)` / `search_phrase(query, k)`：委托 SearchLayer | ⬜ |
| **U4.7** | 恢复路径集成 SearchLayer | `cask.cpp` | fold 中 `decode_doc_value` → 提取 text → `search_->recover_doc()` | ⬜ |
| **U4.8** | 端到端测试 | `cask_test.cpp` | KV put/get + 索引 put/get/search + 恢复 + 一写多读 | ⬜ |

---

### U5 — Phase 5：Merge 支持 ord + SearchLayer

**目标**：merge 保留 ord，合并后通知 SearchLayer 更新定位。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U5.1** | run_merge 重载 | `merger.hpp` / `merger.cpp` | 新增 `SearchLayer* search` 参数（nullable） | ⬜ |
| **U5.2** | ord 透传 | `merger.cpp` | 使用 `write(RecordType, ts, view.ord, key, value)` + `keydir.put(..., view.ord)` | ⬜ |
| **U5.3** | on_relocate 通知 | `merger.cpp` | `if (search) search->on_relocate(key, ord, new_loc)` | ⬜ |
| **U5.4** | Cask::merge 传参 | `cask.cpp` | `run_merge(files, dir, keydir, search_.get(), o_sync)` | ⬜ |
| **U5.5** | 测试 | `merger_test.cpp` / `cask_test.cpp` | merge 后 search 结果不变 + merge 后 get 正确 | ⬜ |

---

### U6 — Phase 6：统一 NIF + 删除 Collection + 升级命令

**目标**：统一 Erlang API，删除 Collection，合并 Registry，添加升级命令。

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **U6.1** | 统一 put NIF | `nif_cask.cpp` | `nif_cask_put`：binary → `Cask::put`；索引+map → `Cask::put_doc` | ⬜ |
| **U6.2** | 统一 get NIF | `nif_cask.cpp` | `nif_cask_get`：KV → binary；索引 → `#{text => ..., meta => ...}` map | ⬜ |
| **U6.3** | search NIF | `nif_cask.cpp` / `nif_main.cpp` | 新增 `cask_search_text/3` + `cask_search_phrase/3`；KV 模式返回 `{error, no_index}` | ⬜ |
| **U6.4** | 选项解析扩展 | `nif_helpers.cpp` | `parse_options()` 识别 `{analyzer, ...}` / `{dict_path, ...}` / `{enable_stop_words, ...}` → 填充 `search_config` | ⬜ |
| **U6.5** | 函数表更新 | `nif_main.cpp` | 删 collection_* 8 条；增 cask_search_text/cask_search_phrase | ⬜ |
| **U6.6** | 统一 Registry | `keydir_registry.hpp` | Slot 增加 `shared_ptr<SearchLayer>`；删除 CollectionRegistry | ⬜ |
| **U6.7** | 删除 Collection | 多文件 | 删 `collection.hpp/.cpp` / `collection_registry.hpp` / `nif_collection.cpp` / CollectionHandle / collection_registry | ⬜ |
| **U6.8** | Erlang facade 更新 | `bitcask.erl` / `bitcask_cpp_nifs.erl` | 统一 `put/3` + `get/2` + `search/2,3`；删除 `collection_*` 导出；新增 `upgrade/2` | ⬜ |
| **U6.9** | 升级命令 | `cask.hpp` / `cask.cpp` + NIF | `Cask::upgrade(dirname, config)`：排他锁 → 扫描 → 重建 BM25 → 写 meta + snapshot | ⬜ |
| **U6.10** | 全量回归测试 | 全量 | 所有 C++ 测试通过 + Erlang 集成测试通过 | ⬜ |

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

## 未来任务

### V3 — HNSW 单图 + search_vector（暂缓）

### V4 — 单域 merge

### V5 — 混合检索 + metadata filter

### V6 — 性能与规模化
