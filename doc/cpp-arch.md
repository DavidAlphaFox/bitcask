# C++ 架构

本文档介绍了 `cpp/` 目录下的 C++ 代码库，并说明各层之间如何协同工作。请结合 `doc/format-zh.md`（磁盘格式规范）一起阅读。

## 模块布局

```
cpp/
├── include/bitcask/         # 公共头文件（API 接口）
│   ├── format.hpp           # 磁盘格式常量（带类型记录：kDoc/kTombstone + ord）
│   ├── codec.hpp            # 数据/提示记录编解码（23B 数据头，18B 提示）
│   ├── io.hpp               # PosixFile + IoError
│   ├── data_file.hpp        # DataFile：追加/读取/折叠带类型记录
│   ├── hint_file.hpp        # HintFile：写入/验证提示记录
│   ├── scanner.hpp          # scan_dir：列出 .bitcask.data 文件
│   ├── keydir.hpp           # KeyDir：内存键目录 + 迭代器（MVCC 兄弟链）
│   ├── keydir_registry.hpp  # KeyDirRegistry：命名 keydir 缓存（引用计数共享）
│   ├── merge_policy.hpp     # decide() 规则 + 每文件阈值
│   ├── merger.hpp           # Merger：合并执行（重写活跃记录）
│   ├── cask.hpp             # Cask：终端用户 KV+search 门面（open/get/put/delete/search/merge）
│   ├── meta_file.hpp        # bitcask.meta：模式持久化（KV vs Index）
│   ├── field_schema.hpp     # FieldSchema：字段名↔id 追加注册表（DocValue v3 字段）
│   ├── index.hpp            # Index：内存文档侧表（ext2ord/slots/ord2ext/live）
│   ├── inverted.hpp         # InvertedIndex：BM25 倒排索引（分片锁）
│   ├── search_layer.hpp     # SearchLayer：Index + InvertedIndex + Analyzer 包装器
│   ├── analyzer.hpp         # text::Analyzer 抽象基类 + 工厂 + AnalyzerConfig
│   ├── ngram_analyzer.hpp   # NgramAnalyzer：CJK 二/三元词 + Latin 空白分词
│   ├── jieba_analyzer.hpp   # JiebaAnalyzer：中文分词（cppjieba）
│   ├── whitespace_analyzer.hpp # WhitespaceAnalyzer：纯空白分词
│   ├── cjk_detect.hpp       # CJK 字符检测工具
│   ├── text_utils.hpp      # NFKC 标准化 + 文本工具
│   └── file_lock.hpp       # FileLock：建议锁（O_CREAT|O_EXCL）
├── src/
│   ├── fileops/             # codec.cpp, data_file.cpp, hint_file.cpp, scanner.cpp
│   ├── io/                  # posix_file.cpp
│   ├── keydir/              # keydir.cpp, keydir_registry.cpp, index.cpp
│   ├── lock/                # file_lock.cpp
│   ├── merge/               # merger.cpp, merge_policy.cpp
│   ├── cask/                # cask.cpp, meta_file.cpp
│   ├── search/              # search_layer.cpp
│   ├── bm25/                # inverted.cpp
│   └── text/                # analyzer.cpp, jieba_analyzer.cpp
├── nif/                     # erl_nif 胶水 → bitcask_cpp.so
│   ├── nif_main.cpp         # ErlNifFunc 表 + on_load（28 个 NIF 入口）
│   ├── nif_cask.cpp         # cask_* 函数（open/close/get/put/delete/sync/search/merge）
│   ├── nif_cask_iter.cpp    # cask_fold_* + cask_iterator_*（fold/iterator NIF）
│   ├── nif_cask_admin.cpp   # cask_status / cask_needs_merge / cask_is_empty / cask_is_frozen
│   ├── nif_helpers.cpp/hpp  # 资源句柄 / DocInput 解析 / 错误翻译 / run_search 骨架 / term 构造
│   ├── nif_options.cpp      # open/2 选项解析（parse_options，单一职责）
│   ├── atoms.cpp/hpp        # 缓存的 ERL_NIF_TERM 原子
│   ├── resources.cpp/hpp    # ErlNifResourceType 注册
│   ├── term_conv.hpp        # Erlang term ↔ C++ 转换辅助
│   └── priv_data.hpp        # 每个 NIF 实例的状态（registry + 资源类型）
├── tests/                   # GoogleTest 单元 + 集成测试（15 个测试文件，约 167 个测试）
└── bench/                   # Google Benchmark（cask_bench, keydir_bench）
```

## 分层结构

```
┌────────────────────────────────────────────────────────────┐
│  Erlang 门面 (src/bitcask.erl)                           │
│  bitcask:put/get/delete/search_text/merge/... → NIF 调用  │
└────────────────────────────┬───────────────────────────────┘
                              │ NIF (bitcask_cpp_nifs)
┌────────────────────────────▼───────────────────────────────┐
│  cpp/nif/  (薄胶水，管理 Erlang 生命周期 + atoms)       │
└────────────────────────────┬───────────────────────────────┘
                              │
┌────────────────────────────▼───────────────────────────────┐
│  Cask (KV + search 门面)                                  │
│  ├─ KeyDir（内存哈希索引 + MVCC 迭代器）                   │
│  ├─ DataFile 缓存（为 pread 保留打开的 fd）                │
│  ├─ HintFile（活跃写入器）                                │
│  ├─ SearchLayer（可选，仅索引模式）                        │
│  │   ├─ Index（ext2ord/slots/ord2ext/live 侧表）         │
│  │   ├─ InvertedIndex（BM25 倒排列表）                      │
│  │   └─ Analyzer（ngram/jieba/whitespace）                │
│  └─ MetaConfig（bitcask.meta 模式持久化）                  │
└────────────────────────────┬───────────────────────────────┘
                              │
┌────────────────────────────▼───────────────────────────────┐
│  fileops (codec, data_file, hint_file, scanner)            │
│  io (PosixFile, FileLock)                                  │
│  merge (Merger, PolicyOptions)                             │
│  text (Analyzer, NgramAnalyzer, JiebaAnalyzer)             │
└────────────────────────────────────────────────────────────┘
```

整个代码树使用 C++23，不依赖 Boost、abseil 或第三方运行时依赖库（在 NIF .so 中）。GoogleTest 和 Google Benchmark 通过 `FetchContent` 拉取，仅在 `BUILD_TESTING` / `BITCASK_BUILD_BENCHMARKS` 开启时编译。

## 磁盘文件清单

一个 bitcask 实例是一个扁平目录，包含以下文件。详细的字节级规范请参阅 `doc/format-zh.md`。

```
<dir>/
├── bitcask.meta                # 二进制元数据（模式标记，18 B）
├── <tstamp1>.bitcask.data      # 追加数据文件（可以有多个）
├── <tstamp1>.bitcask.hint      # 数据文件的附带给定索引（每个数据文件一个，可选）
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── field.schema                # 字段名→id 注册表（仅索引模式）
├── bitcask.write.lock          # 由活跃写入器持有（独占）
├── bitcask.merge.lock          # 由活跃合并器持有（独占）
├── bitcask.keydir.snap         # keydir 段快照（A4，可选）
├── bitcask.index.snap          # index 侧表快照（A4，可选）
├── <base>.f<N>.inv.snap        # 每字段倒排索引快照（索引模式，可选）
└── <base>.f<N>.inv.wal         # 每字段倒排索引 WAL（索引模式，可选）
```

### 文件详解

| 文件 | 数量 | 生命周期 | 用途 |
|------|-------|----------|---------|
| `bitcask.meta` | 1 | 持久化 | 魔术数 `BCME` + 版本 + 模式（0=KV，1=Index/search）。来源：`meta_file.hpp`。 |
| `<tstamp>.bitcask.data` | 多个 | 持久化，旧文件由 merge 删除 | 核心数据。记录序列：`CRC(4)+Type(1)+Tstamp(4)+Ord(8)+KeySz(2)+ValueSz(4)+Key+Value`（23 B 头）。追加方式，无文件级头。`<tstamp>` = 单调递增的 uint32 文件 id，永不重用。 |
| `<tstamp>.bitcask.hint` | 0..N | 持久化，与数据文件 1:1 配对 | 附带给定索引：键 + 偏移 + 总大小（无值）。加速打开时的 keydir 重建 —— 只读取键，不读取值。以 18 B 哨兵结束，其 `TotalSz` 字段携带整个文件的 CRC32。如果 CRC 校验失败，则忽略 hint 并从数据文件重建 keydir。 |
| `field.schema` | 0 或 1 | 持久化 | 仅索引模式。追加式字段名→id 注册表。每个条目：`[NameLen:u16 BE][name]`，id = 出现顺序（从 0 开始）。DocValue v3 存储字段 id 而不是内联名称。 |
| `bitcask.write.lock` | 0 或 1 | 运行时（以 RW 模式打开时创建，关闭时删除） | 通过 `O_CREAT|O_EXCL` 独占写锁。内容：`<pid> <active_data_file_path>\n`。合并器读取此文件以了解活跃写入器的活动文件并将其从合并候选中排除。过时锁通过 `kill(pid, 0)` 探测自动回收。 |
| `bitcask.merge.lock` | 0 或 1 | 运行时（合并期间持有） | 独占合并锁。**有意独立**于 write.lock —— 写入器和合并器并发运行，互不竞争。 |
| `bitcask.keydir.snap` | 0 或 1 | 持久化 | KeyDir 段快照（A4 特性）。通过避免完整数据文件扫描来加速打开。 |
| `bitcask.index.snap` | 0 或 1 | 持久化 | Index 侧表快照（A4 特性）。与 keydir.snap 配对。 |
| `<base>.f<N>.inv.snap` | 0..N | 持久化 | 每字段倒排索引完整快照（仅索引模式）。`<N>` = 字段 id（0=default）。由 `InvertedIndex::save()` 写入，打开时加载。 |
| `<base>.f<N>.inv.wal` | 0..N | 持久化 | 每字段倒排索引 WAL（仅索引模式）。自上次快照以来的 add_doc/remove_doc 追加日志。快照保存后截断。 |

### 操作如何接触文件

| 操作 | 接触的文件 |
|-----------|---------------|
| `put(K,V)` | 追加记录到活跃 `.data` + 追加 hint 到活跃 `.hint` + 更新内存 keydir。索引模式：同时异步提交 IndexTask → `add_doc` → `.inv.wal` 追加 |
| `get(K)` | 查找内存 keydir → 从一个 `.data` 文件 `pread(file_id, offset)` |
| `delete(K)` | 追加墓碑记录（`type=kTombstone`）到活跃 `.data` + 墓碑 hint |
| `open` | 读取 `bitcask.meta` → 扫描所有 `.data` 文件（优先使用 `.hint` 加速，回退到完整数据扫描）→ 重建内存 keydir。索引模式：加载 `.inv.snap` + 回放 `.inv.wal` |
| `merge` | 获取 `merge.lock` → 读取 `write.lock` 获取活跃文件 id → 选择高碎片化候选 → 复制活跃记录到新的 `.data`+`.hint` 对 → CAS 更新 keydir → 删除旧文件 |
| `close` | 释放 `write.lock`（删除） |

### 关键设计要点

- **文件 id 永不重用**：`KeyDirRegistry` 在打开/关闭之间持久化 `biggest_file_id + 1`。
- **追加方式**：每个 put/delete 追加一个新记录；旧版本成为死字节。
- **两个独立锁**：写入器持有 `write.lock`，合并器持有 `merge.lock` —— 它们从不互相阻塞。
- **提示是可选/防御性的**：损坏或缺失的提示只会触发较慢的数据文件完整扫描重建。正确性从不依赖于提示。

## 双持久化：数据文件 vs 倒排 WAL

Bitcask 有**两条独立的持久化路径**，服务不同的目的。在接触写入路径之前，理解这种区别至关重要。

### 路径 1：数据文件（追加日志）—— KV 权威

每个 `put(K,V)` 向活跃 `.data` 文件追加一个带类型记录。这就是权威的 KV 存储。在 `open` 时，扫描所有 `.data` 文件（优先通过 `.hint` 附带文件）并重建内存 KeyDir。KV 数据不需要单独的 WAL —— 追加日志本身就是 WAL。

### 路径 2：倒排 WAL + 快照 —— BM25 索引恢复

BM25 倒排索引（倒排列表、词词典、位置）是 `InvertedIndex` 内部的复杂内存结构。每次重启从头重建需要重读所有数据文件并重新分析所有文本 —— 大规模下代价高昂（例如 200K 文档约需 2–5 秒）。

为了避免完整重建，索引使用**快照 + WAL** 模式：

```
open:
  load_snapshot()    → InvertedIndex::load(.inv.snap)
  enable_wal()       → 打开 .inv.wal 用于追加
  replay_wal()       → 回放自快照以来的增量 add_doc/remove_doc
                      → 成功回放后截断 WAL

运行时（每次 put）:
  put_doc(K, V)
    ├─ DataFile::write(kDoc)         ← 路径 1（KV 权威，追加）
    └─ submit_index_task(Add)        ← 异步到 IndexPool worker
         └─ SearchLayer::on_write()
              └─ InvertedIndex::add_doc(ord, terms)
                   └─ wal_->append_add_doc()  ← 路径 2（索引 WAL）

周期性保存:
  InvertedIndex::save(.inv.snap)    ← 完整状态到磁盘
  truncate_wal()                     ← 快照是权威的，WAL 清空

崩溃恢复:
  load_snapshot() + replay_wal()    → 索引当前到崩溃点
```

**为什么索引需要单独的 WAL？** 数据文件记录包含 DocValue 编码的文本 —— 分析器的原始输入。但倒排索引是一个*派生*结构（已分词、位置索引、词排序）。WAL 捕获*分析结果*（ord + 词位置），以便恢复跳过重新分析所有文本。没有 WAL，重启要么丢失自上次快照以来添加的索引条目（搜索结果陈旧），要么需要从数据文件完整重建。

**这反映了标准搜索引擎架构**：Elasticsearch 有 translog，Lucene 有段级 WAL —— 都服务于相同的目的，即在内存索引状态和周期性完整快照之间建立桥梁。

### WAL 批量刷新（V6.2）

`InvertedWal` 支持可配置的 `batch_size`（默认=1）：

- **batch_size=1**（默认）：每个 `append_add_doc` 立即执行 `fwrite + fflush`。最大持久性，最大 `fflush` 开销。
- **batch_size>1**：条目在内存中缓冲；达到阈值时单个 `fwrite + fflush` 刷新整个批次。析构函数刷新任何剩余缓冲区。

崩溃语义：未刷新的缓冲条目会丢失。这是安全的，因为数据文件（路径 1）是 KV 权威 —— 缺失的 WAL 条目意味着索引在下次快照保存之前不会有该文档，这与不运行 WAL 时的陈旧窗口相同。

WAL 帧格式：`[4B payload_len][payload][4B CRC32]`。CRC 仅覆盖 payload。`replay()` 验证每个条目并自动截断损坏的尾部（崩溃残留的半写入最后条目）。

## 并发模型

运行时存在三个锁层；在添加代码之前，了解你在哪一层下。

| 层            | 类型                  | 持有者               | 保护对象                        |
|------------------|-----------------------|-----------------------|---------------------------------|
| `bitcask.write.lock`  | flock(2) 文件锁 | 一个写入进程    | 活跃数据文件的尾部     |
| `bitcask.merge.lock`  | flock(2) 文件锁 | 一个合并进程    | 合并输出文件              |
| `KeyDir::mutex_`      | `std::shared_mutex` | 每个线程操作 | 内存 keydir 状态          |

两个 flock 文件是**独立的** —— 持有 `merge.lock` 的合并器不会阻塞持有 `write.lock` 的写入器，反之亦然。这是 M5.1 双锁模型。合并器读取 `write.lock` 的内容以了解活跃写入器正在追加到哪个文件 id，并将其从合并候选中排除。

> **注**：下一段描述的「整个 keydir 一个 `std::shared_mutex`」是 M5 的基线。
> M6 起 KeyDir 已分片为 256 个分片锁 + meta_mu_ + 写者闸门屏障；完整锁全序、
> 死锁防护与例外论证见 [`concurrency-zh.md` 锁全局序图](concurrency-zh.md) 与
> [`keydir-sharding-design-zh.md`](keydir-sharding-design-zh.md)。

`KeyDir::mutex_`（M5 基线）是整个 keydir 的一个 `std::shared_mutex`。读取（get / get_epoch / info / iter::next / biggest_file_id / is_ready / conditional_remove peek）采用 `std::shared_lock`。写入（put、remove、fstats 更新、待定冻结、iter 开始+释放）采用 `std::unique_lock`。M5.3 在 4 个并发读者下测量到约 1.9× 的 `std::mutex` 基线性能；M6 的分片实现突破了这一限制。

**索引层是异步单写者**：索引模式下 `put/delete` 把任务入队到 `IndexPool`
的有界队列（满则 push 阻塞做背压），由**单一 worker 线程**串行执行所有索引
变更（`on_write`/`on_delete`/`on_vector`/`set_meta`/`add_doc`）。搜索在调用
线程上跑，与 worker 并发——读路径靠「锁内拷贝、不逃逸指针、安全遍历 tbb 表、
跨线程标量原子、消费者异常兜底」等不变量保证安全，详见
[`concurrency-zh.md` §6](concurrency-zh.md)。

**SearchLayer** 自身非线程安全：写经 IndexPool 单 worker 串行，读可与之并发。

**InvertedIndex** 线程安全：内部按词哈希分片锁 + `tbb::concurrent_hash_map`
桶锁 + posting list 的 CoW —— 与 KeyDir 的分片锁是各自独立的体系。

## 迭代器语义（兄弟链 + 待定哈希）

当至少一个 `IterHandle` 正在迭代时（`keyfolders_ > 0`）：

1. 新键进入一个单独的 `pending_` 映射。读取首先查询 `pending_`，然后查询 `entries_`。fold 不会看到 `pending_`，因此快照保持稳定。
2. 覆盖现有键将其条目从 `SingleEntry` 提升为 `MultiEntry` —— 一个最新的兄弟链。`IterHandle::next` 在迭代器的 `iter_epoch_` 处读取，因此它看到的是 fold 开始时当前的版本，而不是后续的覆盖。
3. fold 期间的删除写入一个兄弟墓碑（哨兵值：`file_id == kMaxFileId, total_sz == kMaxSize, offset == kMaxOffset`）。

当最后一个 folder 释放时：

- `pending_` 合并回 `entries_`。
- 所有多版本条目折叠为单个版本。
- `iter_generation_` 递增；`iter_mutation_` 标志清除。

这是 bitcask 相当于内存状态的 MVCC —— 读者看到一致的快照，无需在迭代开始时复制整个映射。

## NIF 调度

Erlang 门面（`src/bitcask.erl`）将所有操作调度到 C++ NIF（`bitcask_cpp_nifs`）。没有遗留模式 —— `bitcask_legacy.erl` 已被删除。

注册了 28 个 NIF 函数：

| 组 | 函数 |
|-------|-----------|
| 核心 KV | `cask_open/2`, `cask_close/1`, `cask_get/2`, `cask_put/3`, `cask_delete/2`, `cask_sync/1` |
| 搜索 | `cask_search_text/3`, `cask_search_phrase/3` |
| Fold/Iter | `cask_fold_start/3,4`, `cask_fold_next/1`, `cask_fold_next_full/1`, `cask_fold_release/1` |
| 遗留迭代器兼容 | `cask_iterator/3`, `cask_iterator_next/1`, `cask_iterator_release/1` |
| 管理 | `cask_is_empty/1`, `cask_is_frozen/1`, `cask_status/1`, `cask_needs_merge/1` |
| 合并 | `cask_merge/2` |
| 其他 | `cask_close_write_file/1` |

## 构建入口

```
# 仅 C++（CMake）：测试 + 基准，无 Erlang 端
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure

# Sanitizers（一次设置一种；ASan 和 TSan 互斥）
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON

# 基准（仅 release —— sanitized 性能数字无意义）
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench

# 完整构建（cmake + rebar3）：包括 .so，运行 eunit
cmake --build _build/cmake -j     # 生成 priv/bitcask_cpp.so
rebar3 as test eunit --dir test
```

## 添加新的 C++ 特性

1. 在 `cpp/include/bitcask/` 中放置头文件更改。保持公共 API 小 —— 内部辅助函数放在 .cpp 的匿名命名空间中。
2. 在 `cpp/src/` 下的匹配 .cpp 中实现。对可能失败的 API 使用 `std::expected`（本代码库中的每个层都这样做）。
3. 在 `cpp/tests/` 下添加单元测试（每个区域一个 .cpp）。tests/ CMakeLists 将每个测试通过 `bitcask_sanitizers` 连接，以便它们在 CI 中在 ASan/UBSan/TSan 下运行。
4. 如果更改涉及 keydir 或 cask 热路径，在 `cpp/bench/` 中添加微基准并更新 `cpp/bench/baseline/baseline.json`。
5. 如果更改添加新的 NIF，在 `cpp/nif/nif_main.cpp` 的 `kNifFuncs` 数组中注册它并在 `src/bitcask_cpp_nifs.erl` 中添加 Erlang 包装。