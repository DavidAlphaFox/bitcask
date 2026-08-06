# C++ 核心层与 BEAM 依赖边界分析

本文档分析 `cpp/` 目录下哪些模块依赖 BEAM/Erlang VM、哪些是纯 C++，
以及核心层脱离 BEAM 独立使用的可行性。

## 分层总览

```
┌──────────────────────────────────────────────────────────────┐
│  Erlang 层 (src/*.erl)                                       │
│  bitcask.erl / bitcask_cpp_nifs.erl / bitcask_merge_worker   │
│  bitcask_sup.erl / bitcask_app.erl / bitcask_stream.erl      │  ← 需要 BEAM VM
├──────────────────────────────────────────────────────────────┤
│  NIF 胶水层 (cpp/nif/)                                       │
│  nif_main.cpp / nif_cask.cpp / nif_cask_iter.cpp             │
│  nif_cask_admin.cpp / nif_helpers.* / nif_options.cpp        │  ← 唯一引用 erl_nif.h
│  atoms.* / resources.* / priv_data.hpp / term_conv.hpp       │
├──────────────────────────────────────────────────────────────┤
│  核心层 (cpp/src/ + cpp/include/bitcask/)                    │
│  cask/  keydir/  fileops/  io/  lock/                        │
│  merge/  search/  bm25/  text/                               │  ← 纯 C++23，零 BEAM 依赖
└──────────────────────────────────────────────────────────────┘
```

## 依赖方向验证

通过 `grep -r 'erl_nif\|enif_\|ErlNif' cpp/src/ cpp/include/` 确认：

**`cpp/src/` 和 `cpp/include/` 中零 BEAM 符号引用。** 所有 `erl_nif.h`、
`ErlNifEnv`、`enif_*` 调用全部被隔离在 `cpp/nif/` 的 13 个文件中。

## CMake 编译单元与依赖图

### 纯 C++ 库（不链接任何 BEAM 依赖）

下表对齐 libbitcask **6.0.0** 的 `CMakeLists.txt`。

| 库名                    | 源文件                    | 依赖                          | 说明 |
|-------------------------|--------------------------|-------------------------------|------|
| `bitcask_io`            | posix_file.cpp, file_lock.cpp | —                        | POSIX 文件 + advisory lock + `io::MappedFile` RAII |
| `bitcask_format`        | codec.cpp               | zlib                          | 数据记录编解码 |
| `bitcask_fileops`       | data_file.cpp, hint_file.cpp, **oki_run.cpp**, **oki_state.cpp**, scanner.cpp, migrate.cpp | format, io | DataFile + HintFile + **OKI 有序 key 索引**（5.1.0）+ 迁移 |
| `bitcask_keydir`        | keydir.cpp, keydir_registry.cpp | fileops, io            | keydir（6.0.0 起可降级为磁盘驻留热点缓存） |
| `bitcask_docmap`        | index.cpp, docmap_ckpt.cpp | text                       | 文档 side tables（`bitcask_index` 是兼容别名） |
| `bitcask_bm25`          | intersect.cpp, inverted.cpp, query_parser.cpp, segment_v2.cpp | format, io, TBB | BM25 倒排索引 |
| `bitcask_vector`        | hnsw.cpp, ivf_rq.cpp, diskann.cpp | format, io, TBB     | 向量三引擎 |
| `bitcask_text`          | analyzer.cpp, jieba_analyzer.cpp | utf8proc, cppjieba   | 分词器 |
| `bitcask_text_plugin`   | text_plugin.cpp, search_arena.cpp, search_cache.cpp, highlighter.cpp | docmap, bm25, text | 文本检索插件 |
| `bitcask_vector_plugin` | vector_plugin.cpp, ivf_plugin.cpp, diskann_plugin.cpp | vector, docmap | 向量检索插件 |
| `bitcask_hybrid`        | hybrid_searcher.cpp     | text_plugin, vector_plugin    | RRF 混合检索 |
| `bitcask_merge`         | merger.cpp, merge_policy.cpp | keydir, fileops, search  | 合并策略与执行 |
| `bitcask_cask`          | cask.cpp, cask_iter.cpp, **cask_range_iter.cpp**, cask_search.cpp, cask_recovery.cpp, **txn.cpp**, meta_file.cpp, legacy_ckpt.cpp | keydir, fileops, merge, search, TBB | KV+搜索统一门面 |

### BEAM 依赖库（仅一个）

| 库名          | 源文件                          | 链接                                   | 产物 |
|---------------|---------------------------------|----------------------------------------|------|
| `bitcask_cpp` | `cpp/nif/*.cpp`（10 个 TU）     | `bitcask_cask` + Erlang 头文件         | `priv/bitcask_cpp.so` |

NIF 侧的 10 个 TU：`nif_main`（导出表 + on_load）、`nif_cask`（单 key 读写）、
`nif_cask_iter`（fold / iterator）、`nif_cask_range`（**6.0.0**：OKI range 迭代
器）、`nif_cask_batch`（**6.0.0**：原子批 + 多键事务）、`nif_cask_admin`、
`nif_cask_meta`、`nif_helpers`、`nif_options`、`atoms` + `resources`。

NIF 库的编译是**条件性的**（`cpp/CMakeLists.txt` 第 280 行）：

```cmake
if(Erlang_INCLUDE_DIR)    # 只有找到 Erlang 头文件才编译 NIF .so
    add_library(bitcask_cpp SHARED ...)
endif()
```

这意味着不带 Erlang 也能完整编译所有核心库和测试。

## 核心层依赖图（无 BEAM）

```
                    ┌──────────────┐
                    │ bitcask_cask │  (统一门面)
                    └──────┬───────┘
               ┌───────────┼───────────┐
               v           v           v
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ keydir   │ │  merge   │ │  search  │
        └────┬─────┘ └────┬─────┘ └────┬─────┘
             v            v        ┌────┴─────┐
        ┌──────────┐ ┌──────────┐  v          v
        │ fileops  │ │          │ ┌─────┐ ┌──────┐
        └────┬─────┘ │ (同左侧) │ │index│ │ bm25 │
             v        │          │ └──┬──┘ └──┬───┘
        ┌──────────┐ │          │    v       v
        │    io    │ │          │ ┌──────────────┐
        └──────────┘ │          │ │    text      │
                     │          │ └──────┬───────┘
        ┌──────────┐ │          │        v
        │  format  │─┘          │ ┌──────────────┐
        └────┬─────┘            │ │ utf8proc     │
             v                  │ └──────────────┘
        ┌──────────┐            │ ┌──────────────┐
        │   zlib   │            └─│ cppjieba     │
        └──────────┘              └──────────────┘

外部依赖：zlib, TBB, utf8proc, cppjieba (全部非 BEAM)
```

## NIF 层的胶水职责

NIF 层不做任何业务逻辑，仅负责类型转换和生命周期管理：

| 职责              | 示例                                                    |
|-------------------|--------------------------------------------------------|
| 参数解析          | `enif_get_string` → `std::string`                       |
| 二进制转换        | `ErlNifBinary` → `std::span<const std::byte>`           |
| 资源生命周期      | `CaskHandle` 封装 `Cask`，由 BEAM GC 触发析构            |
| 返回值构造        | `std::expected` → `{ok, Term}` / `{error, Reason}`      |
| Atom 缓存         | 预缓存 `ok`、`undefined`、`error` 等 atom               |
| 调度器分派        | IO 密集 → dirty IO scheduler，CPU 密集 → dirty CPU     |

三种资源类型（`resources.hpp`）：

| 资源 | 持有 | 生命周期要点 |
|------|------|-------------|
| `CaskHandle` | `unique_ptr<Cask>` + legacy `iterator/3` 的单槽位 | GC 或显式 `cask_close` 释放 |
| `CaskIterHandle` | `unique_ptr<CaskIter>` | fold 快照自足，**不引用父 cask** |
| `CaskRangeIterHandle`（6.0.0） | `unique_ptr<CaskRangeIter>` + `enif_keep_resource` 住的父 `CaskHandle*` | `CaskRangeIter` 取值要**回调父 Cask 的读路径**，不像 fold 那样自足。故一是 keep 住父资源（上层丢掉 `CaskRef` 也不会被 GC 掉），二是每次 `next` 前检查 `owner->cask` 是否已被 `cask_close` 置空 → `{error, closed}`。两道闸把「先关后用」从段错误降级成普通错误返回 |

> ⚠️ NIF 里的悬垂指针不是异常而是**整个 BEAM node 的段错误**。任何持有指向另一
> 个资源内部对象的裸指针的新资源类型，都必须走 keep + 空检查这一对。

## 磁盘文件清单

一个 bitcask 实例是一个普通目录，包含以下文件：

```
<dir>/
├── bitcask.meta                # 元数据（模式标记，18 字节）
├── <tstamp1>.bitcask.data      # append-only 数据文件（可多个）
├── <tstamp1>.bitcask.hint      # data 的 sidecar 索引（与 data 一一对应，可选）
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── kv.oki.seg-<gen>            # OKI 有序 key 索引 run（5.1.0+，派生缓存，可多个）
├── kv.oki.manifest             # OKI run 集合与覆盖水位（OKI 的唯一 commit point）
├── field.schema                # 字段名→id 注册表（索引模式才有）
├── bitcask.write.lock          # 写锁（运行时临时）
├── bitcask.merge.lock          # 合并锁（运行时临时）
├── bitcask.keydir.snap         # keydir 快照（A4 特性，可选）
└── bitcask.index.snap          # 索引侧表快照（A4 特性，可选）
```

### 逐文件说明

| 文件 | 数量 | 生命周期 | 职责 |
|------|------|----------|------|
| `bitcask.meta` | 固定 1 个 | 持久 | 魔数 `BCME` + 版本 + 模式（0=纯 KV，1=索引/搜索模式）。来源：`meta_file.hpp`。 |
| `<tstamp>.bitcask.data` | 可多个 | 持久，旧文件由 merge 回收 | 核心数据。record 序列：`CRC(4)+Type(1)+Tstamp(8)+Ord(8)+KeySz(2)+ValueSz(4)+Key+Value`，固定头 **27B**（`Tstamp` 自 v5.0.0 的 64 位时间戳 flag-day 起为 u64，此前是 u32 / 头 23B）。无文件级 header，record 紧密排列。`<tstamp>` = 单调递增 uint32 file id，永不复用。 |
| `<tstamp>.bitcask.hint` | 0..N | 持久，与 data 1:1 配对 | sidecar 索引：只存 key+offset+total_sz+**ord**（不含 value），加速 open 时 keydir 重建。magic 自 5.1.0 起为 **`BCH5`**（内嵌 ord；此前 `BCH4` 不存 ord，hint 快路径恢复的条目 ord 恒 0，与 `fold(data)` 不等价——这正是 v4→v5 纪元门禁存在的原因）。末尾 sentinel 存整文件 CRC32；CRC 不通过则忽略 hint，从 data 全量重建。 |
| `kv.oki.seg-<gen>` | 0..N | **派生缓存**，校验不过即整体弃用重建 | OKI run（magic `BCOK`，5.1.0 起 v1、6.0.0 起可为 v2）：按 key 升序的不可变文件，~4 KiB 块 + 块内 key 前缀差分 + 稀疏块索引 + trailer CRC。v2 额外带全字段行 + 内嵌 bloom（约 10 bits/key），供 keydir 磁盘驻留档做冷查。run 数 > 8 时归并成一个。 |
| `kv.oki.manifest` | 0 或 1 | 派生缓存 | OKI 的**唯一 commit point**（magic `BCOM`，v1/v2/v3）：run 集合 + 覆盖水位，`atomic_write_bytes(fsync_dir=true)` 写入。v3 带 Level B 模式戳。缺失/损坏 → open 时全量重建兜底。 |
| `field.schema` | 0 或 1 | 持久 | 仅索引模式。append-only 字段名→id 注册表。每条 `[NameLen:u16 大端][name]`，id=出现顺序（0 基）。DocValue v3 存字段 id 不存名。 |
| `bitcask.write.lock` | 0 或 1 | 运行时（RW open 时创建，close 时 unlink） | 排他写锁，`O_CREAT|O_EXCL` 实现。内容：`<pid> <active_data_file_path>\n`。merger 读它获知 live writer 的 active file，排除出 merge 候选。进程 crash 后 stale-lock 通过 `kill(pid,0)` 自动回收。 |
| `bitcask.merge.lock` | 0 或 1 | 运行时（merge 期间持有） | 排他 merge 锁。**与 write.lock 独立**——writer 和 merger 可并行运行互不阻塞。 |
| `bitcask.keydir.snap` | 0 或 1 | 持久 | keydir 段快照（A4），加速 open 恢复。 |
| `bitcask.index.snap` | 0 或 1 | 持久 | 索引侧表快照（A4），与 keydir.snap 成对。 |

### 操作与文件的对应关系

| 操作 | 涉及的文件 |
|------|-----------|
| `put(K,V)` | 追加 record 到 active `.data` + 追加 hint 到 active `.hint` + 更新内存 keydir（同时经 `KeyDir::put` 咽喉点挂钩记入 OKI memdelta） |
| `get(K)` | 查内存 keydir → `pread(file_id, offset)` 一次对应 `.data` 文件。keydir 磁盘驻留档（`keydir_cache_entries > 0`）下未命中缓存则再查 memdelta → OKI run，冷 get ≤2 次 pread |
| `delete(K)` | 追加墓碑 record（`type=kTombstone`）到 active `.data` + 墓碑 hint |
| `range(Lo,Hi)` | k 路归并 `kv.oki.seg-*` + memdelta（同 key max-ord 胜、墓碑抵消）→ **逐 key 回查 keydir**（活性权威）→ 走 get 路径取值 |
| `put_batch_atomic` / `txn_commit` | 一次写批头 + 成员 record 到 active `.data`；恢复时批区间不完整即整批截断。**首次调用把 `bitcask.meta` 懒升级为 v6** |
| `open` | 读 `bitcask.meta`（纪元门禁：v1/v2/v3 拒开须重建，**v4 拒开须 `bitcask_migrate hintord`**）→ 扫描所有 `.data`（优先读 `.hint` 加速，hint 坏了 fallback 全量扫 data）→ 重建内存 keydir → 校验 OKI 水位，缺口则全量重建 |
| `merge` | 获取 `merge.lock` → 读 `write.lock` 获取 active file id → 挑高碎片率候选 → 复制活 record 到新 `.data`+`.hint` 对 → CAS 更新 keydir → **输入文件「退休」入延迟删除队列**（6.0.0 B4：不再当场 unlink，留到下次 merge 开始 / `checkpoint()` 入口 / `close()` 才删——持旧快照的在途读者不再有 ENOENT 假失败窗口；代价是空间回收延后一拍） |
| `close` | 排空延迟删除队列 → 释放 `write.lock`（unlink） |

### 关键设计

- **file id 永不复用**：`KeyDirRegistry` 跨 open/close 持久化 `biggest_file_id + 1`
- **Append-only**：每次 put/delete 追加新 record，同 key 旧版本成为死字节
- **两把锁分离**：writer 拿 `write.lock`，merger 拿 `merge.lock`，互不阻塞
- **Hint 是加速手段**：坏了就 fallback 到全量扫 data，正确性不依赖 hint
- **OKI 同理是派生缓存**：`kv.oki.*` 校验不过就整体弃用重建，正确性不依赖它；
  活性权威始终是哈希 keydir（range 逐 key 回查就是这条不变量的体现）
- **纪元门禁 vs 派生缓存**：破坏性格式变更走 `bitcask.meta` 版本门禁**干净拒开**
  （绝不按新语义读旧字节），派生缓存的格式演进则靠「读不懂就重建」自愈——
  前者需要 `bitcask_migrate` 离线迁移，后者零操作

字节级详细规范见 `doc/format-zh.md`。

## 脱离 BEAM 独立使用的可行性

**结论：核心层已可独立使用，无需修改。**

现有证据：

1. **300+ GoogleTest 用例**直接链接核心层 static 库运行，不需要 BEAM
2. **CMake 独立构建**已在 CI 中使用（`cmake -S . -B _build/cmake`）
3. **Benchmark** 同样直接跑在核心层上（`_build/bench/cpp/bench/bitcask_bench`）
4. **零侵入**：`cpp/src/` 和 `cpp/include/` 中无任何 `#ifdef` 或条件编译守卫引用 BEAM

### 潜在的非 BEAM 使用场景

- Python 绑定（pybind11 / nanobind）
- 命令行工具（CLI get/put/search）
- 嵌入到其他语言运行时（Node.js N-API、Rust FFI）
- 独立的数据处理服务（gRPC / REST facade）

### 做独立库需要的最小工作

如果要把核心层抽为独立 CMake project，需要：

1. 复制 `cpp/include/` + `cpp/src/` 到独立仓库
2. 复制 `cpp/CMakeLists.txt` 中 `bitcask_io` 到 `bitcask_cask` 的 target 定义
3. 移除顶层 `find_package(Erlang REQUIRED)`
4. 保留 `find_package(ZLIB)`、`find_package(TBB)`、utf8proc、cppjieba 的 FetchContent

工作量很小，因为核心层从一开始就是独立编译的——NIF 只是链接时的一个可选 consumer。
