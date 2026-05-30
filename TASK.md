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

## ✅ V2 — BM25 原生倒排 + `search_text`（已完成，ctest 130/130）

目标：文本可按 BM25 检索。设计依据 §3.2 / §3.4 / §6。

| # | 目标 | 新建/改动 | 关键内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| **V2.1** | analyzer | `analyzer.hpp`（抽象基类+工厂）、`ngram_analyzer.hpp`、`whitespace_analyzer.hpp`、`cjk_detect.hpp`、`src/text/analyzer.cpp`、utf8proc(FetchContent) | NFKC+casefold → CJK bi/tri-gram + 拉丁空白切分 → term→tf。抽象工厂模式：`AnalyzerFactory::create(config)` → `NgramAnalyzer`/`WhitespaceAnalyzer` | 22/22 测试通过（CJK/拉丁/混合/标点/工厂） | ✅ |
| **V2.2** | 倒排结构 | `inverted.hpp/.cpp`（新，`bitcask::bm25`） | `term → PostingList[(ord,tf)]`(按 ord 升序)；`add_doc/remove_doc`；全局 `N/sum_doc_len`；16 shard 分片锁(§4)；BM25 DAAT 评分 + top-k 堆 | 8/8 测试通过（add/search/remove/stats/df） | ✅ |
| **V2.3** | doc_len 回填 | `index.hpp/.cpp` | `DocSlot.doc_len` 由 V1 恒 0 改为 upsert 时 analyzer 填；Index 实现 `LiveChecker` 接口（`is_live` + `doc_len`） | 现有 Index 测试兼容 | ✅ |
| **V2.4** | BM25 评分 + 查询 | `inverted.cpp` | DAAT：query 切词 → 取 posting → `IDF·tf·(k1+1)/(tf+k1·(1-b+b·dl/avgdl))`，跳过 `live=0` → top-k 堆。`k1/b` 可配 | 包含在 V2.2 测试中 | ✅ |
| **V2.5** | 接入 Collection | `collection.hpp/.cpp` | upsert：切词 → `inverted.add_doc` + 写 doc_len；remove：`inverted.remove_doc`；新增 `search_text(query,k) → [{ext_id,score}]`；`CollectionOptions` 增加 `analyzer_config` + `bm25_params` | 现有 Collection 测试兼容 | ✅ |
| **V2.6** | 恢复重建倒排 | `collection.cpp` `recover()` | 侧表重建时同时解码 text → 切词 → `add_doc`（全量重切词） | ReopenRecoversState 测试兼容 | ✅ |
| **V2.7** | 接线 | `CMakeLists.txt`、`tests/` | `bitcask_text` + `bitcask_bm25` target；`bitcask_index` → link bitcask_text；`bitcask_collection` → link text+bm25 | — | ✅ |

**不在 V2**：HNSW/向量检索、merge 时重算 df、Block-Max WAND。
**V2.10 jieba 集成**：见下方 V2.10 子任务表。

### V2.8 — BM25 精度与健壮性优化（已完成）

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **V2.8.1** | 端到端 Collection 搜索测试 | `tests/collection_test.cpp` | 插入多文档（中文+拉丁混合）→ search_text 验证排序/召回/删除后过滤/重开恢复后一致 | ✅ |
| **V2.8.2** | 停用词过滤 | `analyzer.hpp`（AnalyzerConfig 加 stop_words）、`src/text/analyzer.cpp` | analyzer 切词后过滤停用词；内置中英文默认停用词表；可配置开关 | ✅ |
| **V2.8.3** | 短语查询（位置信息） | `Posting` 增加 position 列表、`search` 增加短语匹配模式 | analyzer 记录 term→positions；posting 存 `[(ord,tf,[pos...])]`；短语查询要求连续位置 | ✅ |
| **V2.8.4** | 倒排持久化快照 | `inverted.hpp/.cpp`（新增 save/load）、`collection.cpp` | `bm25_snapshot.inv` 二进制序列化；recover 优先加载快照跳过重分析；sync 写快照 | ✅ |
| **V2.8.5** | df 精确化 | `inverted.hpp/.cpp` | `df_live()` 只计 live 文档；`search()/search_phrase()` IDF 改用 live_df | ✅ |

### V2.9 — NIF 接线（已完成）

| # | 目标 | 改动范围 | 关键内容 | 状态 |
|---|------|---------|---------|------|
| **V2.9** | Erlang REPL 端到端可用 | `nif/nif_collection.cpp`、`nif_helpers.*`、`resources.*`、`nif_main.cpp`、`bitcask.erl`、`bitcask_cpp_nifs.erl`、`CMakeLists.txt` | CollectionHandle 资源类型 + 8 个 collection_* NIF 入口 + Erlang facade + CMake 重建 bitcask_cpp 目标；REPL 验证 `bitcask:search_text(Ref, <<"Beijing">>, 10)` → `[{<<"d3">>,0.288},{<<"d1">>,0.288}]` | ✅ |

### V2.10 — Jieba 中文分词器集成（已完成）

**目标**：集成 `cppjieba`（yanyiwu/cppjieba v5.6.3, MIT, header-only）作为新的 Analyzer 实现，
提供比字符级 n-gram 更精准的中文分词能力。默认使用 CutForSearch 模式（搜索引擎模式，长词进一步拆分提升召回率），
对 jieba 未覆盖的 CJK 文字（日韩等）回退到 n-gram 兜底。词典文件内嵌到 `priv/dict/` 目录。

| # | 目标 | 改动范围 | 关键内容 | 优先级 |
|---|------|---------|---------|--------|
| **V2.10.1** | 拉取 cppjieba 依赖 | `cpp/CMakeLists.txt` | FetchContent 拉取 `limonp` + `cppjieba`（header-only，匹配 utf8proc 模式）；`bitcask_text` link `cppjieba`；词典文件复制到 `priv/dict/` | 高 |
| **V2.10.2** | 枚举 + 配置扩展 | `analyzer.hpp` | `AnalyzerType` 增加 `Jieba`；`AnalyzerConfig` 增加 `dict_path`（词典目录，默认空=使用内嵌 `priv/dict/`） | 高 |
| **V2.10.3** | JiebaAnalyzer 实现 | 新建 `cpp/include/bitcask/jieba_analyzer.hpp`、`cpp/src/text/jieba_analyzer.cpp` | 继承 `Analyzer`，构造时初始化 `cppjieba::Jieba`；`analyze_with_positions()` 调用 `CutForSearch` 得到词列表，对每个词记录 {tf, positions}；对 jieba 未识别的 CJK 字符段回退到 n-gram 切分；`analyze()` 从 `analyze_with_positions()` 派生；停用词过滤复用现有逻辑 | 高 |
| **V2.10.4** | 工厂接线 | `analyzer.cpp` `AnalyzerFactory::create()` | 增加 `case AnalyzerType::Jieba:` 分支，构造 `JiebaAnalyzer`；传入 `dict_path` + 停用词配置 | 高 |
| **V2.10.5** | NIF 传递 dict_path | `nif_collection.cpp`、`bitcask.erl` | `collection_open/1,2` 选项解析增加 `{dict_path, binary}` 选项；NIF 层解析为 `AnalyzerConfig.dict_path` | 中 |
| **V2.10.6** | 单元测试 | 新建 `cpp/tests/jieba_analyzer_test.cpp` | 中文精确切分验证（"我来到北京邮电大学"→["北京","邮电","大学"...]）；CutForSearch 长词拆分验证；CJK 回退 n-gram 验证（日文/韩文）；停用词过滤；空输入/纯拉丁；`AnalyzerFactory::create(Jieba)` 端到端 | 高 |
| **V2.10.7** | 集成测试 | `cpp/tests/collection_test.cpp` | 使用 `AnalyzerConfig{.type=Jieba}` 打开 Collection → 插入中文文档 → search_text 验证 jieba 切词下的排序和召回；search_phrase 验证；删除后过滤；重开恢复 | 中 |

**设计决策**：
- 分词模式：CutForSearch（搜索引擎模式），长词会被进一步拆分，适合 BM25 全文检索场景
- 词典部署：内嵌到 `priv/dict/`（~5-6 MB），CMake 构建时自动复制；同时支持 `dict_path` 选项覆盖
- 混合策略：先 jieba CutForSearch 切词识别已知词，对剩余未识别 CJK 字符段回退到 bi/tri-gram n-gram 切分
- 词典文件：`jieba.dict.utf8`(~5MB) + `hmm_model.utf8`(~1MB) + `user.dict.utf8`(空) + `idf.utf8`(~1MB) + `stop_words.utf8`(~5KB)
- 库选择：`yanyiwu/cppjieba` v5.6.3（MIT, 2837★, header-only, 仅依赖 limonp）

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
当前 13 文件 ~1100 行（Phase 1-5 重构后净减 ~100 行）。

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

### P3 — Collection NIF 重构 + legacy atom 清理

| # | 改动 | 描述 | 状态 |
|---|------|------|------|
| N3.1 | 删除重复死文件 | 删除 `nif_collection_helpers.cpp` + `resources_collection.cpp`（未参与编译，内容与 `nif_helpers.cpp`/`resources.cpp` 完全重复） | ✅ |
| N3.2 | 模板化资源句柄提取 | `get_resource_handle<T>(env, term, rt)` 模板 + 显式实例化，`cask_handle`/`cask_iter_handle`/`collection_handle` 委托模板 | ✅ |
| N3.3 | `as_string_view()` 消除 reinterpret_cast | `term_conv.hpp` 新增 `as_string_view(const ErlNifBinary&)`；`nif_collection.cpp` 全部 7 处 `reinterpret_cast<const char*>` 替换 | ✅ |
| N3.4 | 提取 `parse_collection_options` | 从 `nif_collection_open` 53 行循环提取为独立函数；新增 6 个缓存 atom（analyzer/jieba/ngram/whitespace/dict_path/enable_stop_words）替代每次 `enif_make_atom` | ✅ |
| N3.5 | 提取 `make_search_hits` | `search_text`/`search_phrase` 共享的结果构建循环提取为 `detail::make_search_hits` | ✅ |
| N3.6 | `checked_collection_handle` | 与 `checked_cask_handle` 对称，统一 collection handle 检查（`nif_collection_close` 保留原始 `collection_handle` 以支持已关闭 collection） | ✅ |
| N3.7 | 清理 legacy atoms | 删除 16 个未引用的 legacy atom（eof/lock_not_writable/fstat_error/...） | ✅ |

---

## 遗留清理（M6 式，可独立排期）

- 物理删除不接构建的 legacy 引擎源码：`keydir.*`/`keydir_registry.*`/`merger.*`/
  `merge_policy.*`/`cask.*`，以及存档的 `cpp/nif/`（向量引擎将来需自己的 NIF）。
- `cpp/bench/`（cask_bench/keydir_bench）引用已弃符号，opt-in OFF；按需重做或删。
