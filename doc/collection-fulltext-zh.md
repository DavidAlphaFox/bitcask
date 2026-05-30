# Collection 全文索引：使用指南与内部机制

本文描述 Bitcask Collection 的 BM25 全文检索功能——从 Erlang 层 API 到 C++ 底层索引构建的完整链路。

---

## 1. 概述

Collection 是 Bitcask 在 KV 存储基础上扩展的文档集合，支持：

- **结构化文档存储**：每个文档可包含 text（文本）、vector（向量）、meta（元数据）
- **BM25 全文检索**：对 text 字段自动构建倒排索引，支持 `search_text`（词袋查询）和 `search_phrase`（短语查询）
- **可配置分词**：通过抽象工厂模式支持 n-gram / jieba / whitespace 三种分词方案
- **停用词过滤**：可选启用，过滤中英文常见无意义词

---

## 2. Erlang API

### 2.1 打开 Collection

```erlang
%% 默认 n-gram 分词
{ok, Ref} = bitcask:collection_open("/tmp/db").

%% 使用 jieba 中文分词 + 停用词过滤
{ok, Ref} = bitcask:collection_open("/tmp/db", [
    {analyzer, jieba},
    {dict_path, <<"/path/to/cppjieba/dict">>},
    {enable_stop_words, true}
]).

%% 使用空白切分（调试 / 纯英文场景）
{ok, Ref} = bitcask:collection_open("/tmp/db", [
    {analyzer, whitespace}
]).
```

**配置选项：**

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `{analyzer, Atom}` | `ngram \| jieba \| whitespace` | `ngram` | 分词器类型，open 后不可更改 |
| `{dict_path, Binary}` | binary() | 空（内嵌 `priv/dict/`） | jieba 词典目录，仅 jieba 模式生效 |
| `{enable_stop_words, Boolean}` | `true \| false` | `false` | 是否启用停用词过滤 |

### 2.2 写入文档

```erlang
%% 写入纯文本文档
bitcask:collection_put(Ref, <<"doc1">>, <<"北京市朝阳区">>).

%% 写入多条
bitcask:collection_put(Ref, <<"doc2">>, <<"上海浦东新区">>),
bitcask:collection_put(Ref, <<"doc3">>, <<"北京人在上海">>).
```

`put` 时自动触发分词和索引构建，无需手动操作。

### 2.3 文本搜索

```erlang
%% BM25 词袋查询，返回 top-K 结果
{ok, Hits} = bitcask:search_text(Ref, <<"北京">>, 10).
%% Hits = [{<<"doc3">>, 0.288}, {<<"doc1">>, 0.288}]

%% 短语查询（要求词项位置相邻）
{ok, Hits2} = bitcask:search_phrase(Ref, <<"北京 上海">>, 10).
```

**返回格式：** `[{Key :: binary(), Score :: float()}]`，按 BM25 分数降序排列。

### 2.4 读取文档

```erlang
{ok, Doc} = bitcask:collection_get(Ref, <<"doc1">>).
%% Doc = #{text => <<"北京市朝阳区">>}
```

### 2.5 删除文档

```erlang
bitcask:collection_delete(Ref, <<"doc2">>).
```

删除后，该文档在搜索结果中自动消失（通过 `live_checker` 过滤已删除文档）。

### 2.6 持久化与关闭

```erlang
%% 将倒排索引快照写入磁盘
bitcask:collection_sync(Ref).

%% 关闭 Collection（内部会 sync）
bitcask:collection_close(Ref).
```

### 2.7 完整示例

```erlang
%% 1. 打开 jieba 分词的 Collection
{ok, Ref} = bitcask:collection_open("/tmp/mydb", [
    {analyzer, jieba},
    {dict_path, <<"/opt/cppjieba/dict">>},
    {enable_stop_words, true}
]),

%% 2. 写入文档
bitcask:collection_put(Ref, <<"d1">>, <<"北京市朝阳区">>),
bitcask:collection_put(Ref, <<"d2">>, <<"上海浦东新区">>),
bitcask:collection_put(Ref, <<"d3">>, <<"北京人在上海">>),

%% 3. 搜索
{ok, Results} = bitcask:search_text(Ref, <<"北京">>, 10).
%% → [{<<"d3">>, 0.288}, {<<"d1">>, 0.288}]

%% 4. 短语搜索
{ok, Results2} = bitcask:search_phrase(Ref, <<"北京 上海">>, 10).

%% 5. 删除后搜索
bitcask:collection_delete(Ref, <<"d1">>),
{ok, Results3} = bitcask:search_text(Ref, <<"北京">>, 10).
%% → [{<<"d3">>, 0.288}]

%% 6. 持久化并关闭
bitcask:collection_sync(Ref),
bitcask:collection_close(Ref).
```

---

## 3. 索引构建机制

### 3.1 写入路径

每次 `collection_put` 的完整处理链路：

```
Erlang: bitcask:collection_put(Ref, <<"d1">>, <<"北京天安门">>)
    │
    ▼
NIF: nif_collection.cpp :: nif_collection_put
    │  从 Ref 取出 CollectionHandle → 拿到 Collection*
    │  构造 Doc{.text = "北京天安门"}
    │
    ▼
C++: Collection::upsert("d1", doc)
    │
    ├─① 编码 + 写磁盘
    │   codec::encode_doc_value(val, parts)
    │   active_->write(kDoc, ts, ord, key_bytes, val_bytes)
    │   → append-only data file
    │
    ├─② 分词
    │   analyzer_->analyze_with_positions("北京天安门")
    │   │
    │   ├── NgramAnalyzer:
    │   │   NFKC 归一化 → CJK 检测 → bi-gram + tri-gram
    │   │   → {"北京":{1,[0]}, "京天":{1,[0]}, "天安":{1,[0]}, "安门":{1,[0]},
    │   │      "北京天":{1,[0]}, "京天安":{1,[0]}, "天安门":{1,[0]}}
    │   │
    │   ├── JiebaAnalyzer:
    │   │   jieba CutForSearch → 识别已知中文词汇
    │   │   未识别 CJK 字符段回退 n-gram
    │   │   → {"北京":{1,[0]}, "天安门":{1,[1]}}
    │   │
    │   └── WhitespaceAnalyzer:
    │       空白字符切分 → 去标点 → to_lower
    │       → {"北京天安门":{1,[0]}}
    │
    ├─③ 更新内存侧表
    │   index_.put_doc("d1", ord, DocSlot{location, timestamp, doc_len})
    │   → 内存 Hash 表：ext_id → ord + 磁盘位置 + 文档长度
    │
    └─④ 更新倒排索引
        inverted_->add_doc(ord, term_data)
        → 内存倒排索引：term → [{ord, tf, positions}]
```

### 3.2 倒排索引结构

```
InvertedIndex（16 分片锁，分片按 term hash 选择）
    │
    ├── shard[0]: term → PostingList
    ├── shard[1]: term → PostingList
    │   ...
    └── shard[15]: term → PostingList

PostingList = [{ord, tf, [pos0, pos1, ...]}]
    │
    ├── ord:  内部序号（uint64，单调递增）
    ├── tf:   词频（term 在文档中出现的次数）
    └── pos:  位置列表（用于短语查询的邻接判断）
```

### 3.3 BM25 评分

搜索时对每个匹配文档计算 BM25 分数：

```
score(D, Q) = Σ_{t ∈ Q} IDF(t) × (tf(t,D) × (k1 + 1)) / (tf(t,D) + k1 × (1 - b + b × |D| / avgdl))

其中：
- IDF(t) = ln((N - df(t) + 0.5) / (df(t) + 0.5) + 1)
- N = 活跃文档总数
- df(t) = 包含 term t 的活跃文档数（live_df，已删除文档不计入）
- tf(t,D) = term t 在文档 D 中的词频
- |D| = 文档 D 的长度（token 总数）
- avgdl = 所有活跃文档的平均长度
- k1 = 1.2, b = 0.75（默认值，尚无 Erlang 层配置接口）
```

### 3.4 查询路径

```
Erlang: bitcask:search_text(Ref, <<"北京">>, 10)
    │
    ▼
NIF → Collection::search("北京", k=10)
    │
    ├─① 分词查询文本
    │   analyzer_->analyze("北京") → {"北京": 1}
    │
    ├─② 倒排检索
    │   inverted_->search({"北京"}, k=10, live_checker)
    │   ├── 按 shard 锁取 "北京" 的 posting list
    │   ├── 遍历 posting，跳过 !is_live() 的（已删除）
    │   ├── 计算 live_df → IDF
    │   ├── 对每个 live posting 算 BM25 分数
    │   └── top-k 堆排序 → [{ord, score}]
    │
    └─③ 序号 → 外部 Key
        index_.ord_to_ext(ord) → ext_id
        返回 [{Key, Score}]
```

短语查询（`search_phrase`）在上述基础上额外要求：查询中的相邻词项在文档中的位置也必须相邻。

### 3.5 删除机制

删除是**逻辑删除**，不物理移除 posting：

```
collection_delete("d1")
    │
    ├─① 写墓碑记录到 data file
    │   active_->write(kTombstone, ts, ord, key_bytes, {})
    │
    └─② 标记侧表中该 key 为删除
        index_.put_doc("d1", ord, DocSlot{..., deleted=true})

搜索时：
    inverted_->search(terms, k, live_checker)
    │
    └── 遍历 posting list 时，通过 live_checker.is_live(ord) 过滤
        已删除的 ord 不参与 BM25 计算
```

### 3.6 持久化与恢复

```
sync():
    ├── data file fsync（确保 append 数据落盘）
    └── inverted_->save("dir/bm25_snapshot.inv")
        将完整的倒排索引序列化到磁盘

恢复（collection_open）:
    ├── inverted_->load("bm25_snapshot.inv")   ← 有快照则直接加载
    │   成功 → 只需遍历 data file 重建侧表，跳过重分析
    │
    └── 无快照 → 全量重建
        遍历 data file 所有 record
        → 对每个 kDoc: 取 text → analyze_with_positions → add_doc
        → 重建完整倒排索引
```

---

## 4. 分词器详解

### 4.1 NgramAnalyzer（默认）

- 对 CJK 字符生成 bi-gram（2-gram）和 tri-gram（3-gram）
- 对拉丁字符按空白切分
- NFKC Unicode 归一化
- 适用场景：不依赖词典的通用分词，支持任意语言

```
输入: "北京天安门"
输出: "北京", "京天", "天安", "安门", "北京天", "京天安", "天安门"
```

### 4.2 JiebaAnalyzer

- 基于 cppjieba（`yanyiwu/cppjieba` v5.6.3，header-only）
- 使用 CutForSearch 模式：对长词进一步切分为子词，提升召回率
- CJK 回退：未被 jieba 识别的 CJK 字符段（日文假名等）自动回退 n-gram
- 可选停用词过滤
- 适用场景：中文为主的文本，需要精确分词

```
输入: "北京天安门"
输出: "北京", "天安门"
```

**词典配置：**

jieba 需要 5 个词典文件（位于 `dict_path` 目录下）：
- `jieba.dict.utf8`（核心词典）
- `hmm_model.utf8`（隐马尔可夫模型）
- `user.dict.utf8`（用户自定义词典）
- `idf.utf8`（IDF 权重表）
- `stop_words.utf8`（停用词表）

如果 `dict_path` 为空，默认使用内嵌的 `priv/dict/` 目录。

### 4.3 WhitespaceAnalyzer

- 纯空白字符切分
- 去除 ASCII 标点
- 转小写
- 适用场景：纯英文文本、调试

```
输入: "Hello, World! This is a test."
输出: "hello", "world", "this", "is", "a", "test"
```

---

## 5. 存储架构总览

```
┌─────────────── 写路径 ───────────────┐
│                                       │
│  text ──→ analyzer ──→ term_data      │
│                 │                      │
│                 ├──→ inverted index   │  (内存, term → posting list)
│                 │                      │
│  raw bytes ──→ data file (append)     │  (磁盘, 原始 value)
│                 │                      │
│  ext_id+ord ──→ index side table      │  (内存, key → ord + 磁盘位置 + doc_len)
│                                       │
└───────────────────────────────────────┘

┌─────────────── 读路径 ───────────────┐
│  get:    index 侧表 → 磁盘位置 → pread │
│  search: inverted → BM25 top-k        │
└───────────────────────────────────────┘

┌─────────────── 持久化 ───────────────┐
│  sync:  data file fsync               │
│         + bm25_snapshot.inv 写磁盘     │
│  恢复:  load 快照 → 直接加载           │
│         无快照 → 遍历 data file 重建   │
└───────────────────────────────────────┘
```

---

## 6. 相关源码

| 文件 | 说明 |
|------|------|
| `cpp/nif/nif_collection.cpp` | NIF 入口，选项解析 |
| `cpp/src/cask/collection.cpp` | Collection 核心逻辑（upsert/get/remove/search） |
| `cpp/include/bitcask/analyzer.hpp` | 分词器抽象基类 + 工厂 + 配置结构 |
| `cpp/src/text/analyzer.cpp` | NgramAnalyzer / WhitespaceAnalyzer 实现 + 工厂 |
| `cpp/src/text/jieba_analyzer.cpp` | JiebaAnalyzer 实现（pimpl 隐藏 cppjieba） |
| `cpp/include/bitcask/text_utils.hpp` | 共享文本工具（NFKC 归一化、CJK 检测等） |
| `cpp/include/bitcask/inverted.hpp` | 倒排索引接口 |
| `cpp/src/text/inverted.cpp` | 倒排索引实现（分片锁、BM25 评分、持久化） |
| `cpp/include/bitcask/collection.hpp` | Collection 类声明 + CollectionOptions |
| `src/bitcask.erl` | Erlang facade（collection_* API） |
