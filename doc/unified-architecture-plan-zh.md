# Bitcask 统一架构：详细实施计划

> **状态**：U1–U6 全部完成。Cask 和 Collection 已统一为单一引擎，Collection 类已删除。
> 搜索能力通过 `{analyzer, ...}` 选项启用，KV 与索引模式共享同一存储层和 merge。
>
> **核心原则**：
> 1. 不考虑向后兼容性
> 2. **Value 格式统一**：所有 value（KV 和索引模式）都使用 DocValue 编码
> 3. **ord 统一分配**：所有模式都分配真实 ord
> 4. **允许升级**：KV → 索引升级只需重建索引（离线）
> 5. **模式标记**：`bitcask.meta` 二进制文件持久化模式信息
>
> 完整设计讨论见本文件。开发任务跟踪见 `TASK.md`。

---

## 0. 术语与缩写

| 术语 | 含义 |
|------|------|
| **ord** | 引擎单调分配的写入序号，per-write，永不复用。磁盘 record header [9..16] |
| **KeyDir** | `key → (file_id, offset, total_sz, epoch, tstamp, ord)` 内存哈希表 |
| **SearchLayer** | 可选的搜索层：Index + InvertedIndex + Analyzer，挂在 Cask 内部 |
| **DocValue** | 统一的 value 编码格式：`[Ver=3][Flags][段1][段2]...`，长度用 varint（见 format.hpp / format-zh.md §五） |
| **bitcask.meta** | 目录级模式标记文件，索引模式创建，KV 模式不存在 |
| **CAS** | Compare-And-Swap，merge 用 `(old_file_id, old_offset)` 条件更新 KeyDir |

---

## 1. 核心设计决策

### 1.1 Value 格式统一

所有 value 都使用 DocValue 格式存储（当前 Ver=3：长度/计数用 VByte varint，
fields 段存 field id；详见 format-zh.md §五）：

```
KV 模式 put(Ref, <<"k">>, <<"hello">>):
  Value = DocValue{Ver=3, Flags=0x02(hasText), Len=5(varint), "hello"}
  开销 = 3 字节（Ver 1B + Flags 1B + Len 1B varint）

索引模式 put(Ref, <<"k">>, #{text => <<"hello">>, meta => <<"data">>}):
  Value = DocValue{Ver=3, Flags=0x06(hasText|hasMeta), Len=5, "hello", Len=4, "data"}（各 Len 为 varint）
```

### 1.2 ord 统一分配

所有模式都调用 `keydir_->alloc_ord()` 分配真实 ord。

### 1.3 模式标记 bitcask.meta

```
文件位置: <dirname>/bitcask.meta
二进制格式（~18 字节）:
  [Magic: 4B] "BCME"
  [Version: 1B] = 1
  [Mode: 1B] = 1 (index)
  [AnalyzerType: 1B] 0=ngram, 1=whitespace, 2=jieba
  [Bm25K1: 4B] float LE
  [Bm25B: 4B] float LE
  [Flags: 1B] bit0=enable_stop_words
  [DictPathLen: 2B] LE u16
  [DictPath: variable] utf8
```

- **文件不存在** → 纯 KV 模式
- **文件存在** → 索引模式

### 1.4 升级路径

KV → 索引升级（离线）：扫描 data files → 解码 DocValue → 重建 BM25 索引。

### 1.5 get() 语义

- **KV 模式**：返回 binary（从 DocValue 提取 text 段）
- **索引模式**：返回 map（完整解码 DocValue）

### 1.6 put() 统一 API

Erlang 层只有一个 `put/3`，NIF 层根据模式自动分发。

---

## 2. 依赖图

```
Phase 1: KeyDir + ord
    │
    ├── Phase 2: Cask 适配 DocValue + ord + bitcask.meta
    │
    ├── Phase 3: SearchLayer 模块
    │       │
    │       └── Phase 4: Cask 集成 SearchLayer + 统一 put/get
    │               │
    │               ├── Phase 5: Merge 支持 ord + SearchLayer
    │               │
    │               └── Phase 6: 统一 NIF + 删除 Collection + 升级命令
```

---

## 3. 各 Phase 概要

### Phase 1：KeyDir 增加 ord 字段

- `SingleEntry` / `EntryProxy` 增加 `uint64_t ord`
- `put()` 末尾加 ord 参数（默认 0）
- 新增 `alloc_ord()` / `advance_ord()`

### Phase 2：Cask 适配 DocValue + ord + bitcask.meta

- `put()` 编码 DocValue{text=value}，始终分配 ord
- `get()` 解码 DocValue，KV 模式提取 text
- 新建 `meta_file.hpp/.cpp`：bitcask.meta 读写
- `load_keydir_from_disk()` 始终走 data file fold（需要 ord + DocValue）
- `CaskOptions` 增加 `optional<SearchLayerConfig>`

### Phase 3：SearchLayer 模块

- 新建 `search_layer.hpp/.cpp`
- `on_write/on_delete/on_relocate/search_text/search_phrase`
- `recover_doc/recover_tomb`

### Phase 4：Cask 集成 SearchLayer

- Cask 持有 `unique_ptr<SearchLayer>`
- `put()` 搜索通知 / `put_doc()` 文档写入
- `get()` 索引模式返回完整 map
- `search_text/search_phrase`
- 恢复路径集成 SearchLayer

### Phase 5：Merge 支持

- `run_merge` 新增 `SearchLayer*` 参数
- 保留 ord + `on_relocate()` 更新定位

### Phase 6：统一 NIF + 清理

- 删除 collection_* NIF / Collection 类 / CollectionRegistry
- 统一 `put/3`：binary → put, map → put_doc
- 统一 `get/2`：KV → binary, 索引 → map
- 新增 `search_text/search_phrase` NIF
- 升级命令 `bitcask:upgrade/2`

---

## 4. Erlang API 最终形态

```erlang
%% 打开
bitcask:open(Dir, [read_write]).                          %% KV 模式
bitcask:open(Dir, [{analyzer, jieba}, read_write]).       %% 索引模式

%% 写入（统一 put）
bitcask:put(Ref, Key, <<"value">>).                        %% binary
bitcask:put(Ref, Key, #{text => <<"文本">>, meta => <<"数据">>}).  %% map（索引模式）

%% 读取
bitcask:get(Ref, Key).                                     %% KV → {ok, Binary}; 索引 → {ok, Map}

%% 搜索（仅索引模式）
bitcask:search(Ref, Query).                                %% → {ok, [...]} | {error, no_index}

%% 升级
bitcask:upgrade(Dir, [{analyzer, jieba}]).                 %% 离线 KV → 索引
```

---

## 5. 文件变更总览

### 新建

| 文件 | Phase |
|------|-------|
| `cpp/include/bitcask/meta_file.hpp` | 2 |
| `cpp/src/fileops/meta_file.cpp` | 2 |
| `cpp/include/bitcask/search_layer.hpp` | 3 |
| `cpp/src/search/search_layer.cpp` | 3 |

### 修改

| 文件 | Phase(s) |
|------|----------|
| `keydir.hpp` / `keydir.cpp` | 1 |
| `cask.hpp` / `cask.cpp` | 2, 4 |
| `merger.hpp` / `merger.cpp` | 5 |
| `keydir_registry.hpp` | 6 |
| `nif_cask.cpp` | 2, 6 |
| `nif_cask_iter.cpp` | 2 |
| `nif_main.cpp` / `nif_helpers.*` | 6 |
| `resources.hpp` / `priv_data.hpp` / `atoms.hpp` | 6 |
| `CMakeLists.txt` | 2, 3, 6 |

### 删除

| 文件 | Phase |
|------|-------|
| `collection.hpp` / `collection.cpp` / `collection_registry.hpp` / `nif_collection.cpp` | 6 |

---

## 6. 预估工期

| Phase | 预估 |
|-------|------|
| Phase 1: KeyDir + ord | 0.5-1 天 |
| Phase 2: DocValue + meta + ord | 1-2 天 |
| Phase 3: SearchLayer | 1-2 天 |
| Phase 4: Cask 集成 | 1-2 天 |
| Phase 5: Merge | 0.5-1 天 |
| Phase 6: NIF + 清理 + 升级 | 1-2 天 |
| **合计** | **5-10 天** |
