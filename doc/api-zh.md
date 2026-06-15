# Bitcask API 参考（中文）

English version: [`api-en.md`](api-en.md)。

除特别说明外，公开函数都在 `bitcask` 模块；embedder 辅助函数在
`bitcask_embedder` 模块。

## 句柄模型与模式

`bitcask:open/2` 返回的是**句柄** `{CaskRef, EmbedderCtx}`（二元组），不是裸
reference。后续所有调用都传整个元组。未配 embedder 时 `EmbedderCtx = undefined`。

三种模式，由 open 选项决定：

| 模式 | 启用方式 | 能力 |
|------|---------|------|
| KV | （默认） | `get`/`put`/`delete`/`sync`/`fold`/`merge` |
| 索引（BM25） | `{analyzer, _}` | + `search_text`/`phrase`/`fields`/`near`/`fuzzy`/`wildcard` |
| 向量 | `{embedder, _}` 或 `{vector_dim, N}`（同时需索引模式） | + `search_vector`/`search_hybrid`/`embed` |

---

## 生命周期

### `open(Dir) -> Handle | {error, Reason}` · `open(Dir, Opts) -> Handle | {error, Reason}`
在目录 `Dir` 打开（或创建）一个 cask。返回 `{CaskRef, EmbedderCtx}`。常见错误：
`write_locked`、`enoent`、`mode_mismatch`（选项与磁盘 meta 不符）、
`{bad_embedder, _}`、`{bad_opt, _}`。

**open 选项**（其余键静默忽略）：

*核心*

| 选项 | 含义 | 默认 | 限制 |
|------|------|------|------|
| `read_write` | 拿写锁、开放写 | 只读 | 每目录单写者（跨 OS 进程） |
| `{expiry_secs, N}` | N 秒前的 entry 视为过期 | 无 | 整数秒 |
| `{max_file_size, N}` | 超过 N 字节切下一个 active 文件 | 2 GiB | 字节 |
| `{sync_strategy, S}` | `none` \| `o_sync` \| `{seconds, N}` | `none` | — |
| `{tombstone_version, V}` | 墓碑编码版本 | `2` | `1` \| `2` |

*合并阈值*（供 `needs_merge`/`merge`）：`frag_merge_trigger`、
`dead_bytes_merge_trigger`、`frag_threshold`、`dead_bytes_threshold`、
`small_file_threshold`、`max_merge_size`、`expiry_grace_time`。

*索引模式（BM25）*

| 选项 | 含义 | 限制 |
|------|------|------|
| `{analyzer, Type}` | `ngram` \| `whitespace` \| `jieba` | 启用搜索必填 |
| `{dict_path, Path}` | jieba 词典目录 | `jieba` 必填（默认回退 `priv/dict`） |
| `{enable_stop_words, true}` | 停用词过滤 | — |
| `{min_n, N}` / `{max_n, N}` | n-gram 上下界（ngram） | `1 =< min_n =< max_n` |
| `{min_token_length, N}` | 丢弃过短拉丁词 | `N >= 1` |
| `{enable_stemming, true}` | Porter 词干化包装 | — |

*向量模式*

| 选项 | 含义 | 限制 |
|------|------|------|
| `{embedder, {Provider, Cfg}}` | **推荐。** open 内部经 `bitcask_embedder:new(Provider, Cfg)` 建 ctx，并自动用 embedder 的 `vector_dim` 作为集合维度；启用 `put`/查询的自动 embed。 | `Provider = openai \| anthropic \| {custom, Mod}`；`Cfg` 是 map。预建 ctx map 会被**拒绝**（`{error, {bad_embedder, _}}`）。在场时 `{vector_dim, N}` 由 embedder 接管。 |
| `{vector_dim, N}` | 向量维度——仅手动向量路径（不配 embedder）需要 | `N > 0`；重开须与磁盘 meta 一致 |
| `{vector_metric, M}` | `cosine` \| `l2` \| `dot` | 默认 `cosine`；cosine 拒绝零向量 |

### `close(Handle) -> ok`
刷盘、释放写锁、keydir 引用计数减一。之后句柄不可再用。

### `close_write_file(Handle) -> ok`
finalize 当前 active 文件并释放 `bitcask.write.lock`，但句柄仍可用（下次
`put`/`delete` 会重新拿锁、新建文件）。

### `sync(Handle) -> ok`
`fsync` 当前 active 文件。`{sync_strategy, o_sync}` 下退化为 no-op。

---

## 单 key 读写

### `get(Handle, Key) -> {ok, Value} | not_found | {error, Reason}`
`Key`/`Value` 为 binary。过期或被墓碑覆盖的 entry 读作 `not_found`。

### `put(Handle, Key, Value) -> ok | {error, Reason}`
`Value` 形态：

- **binary()** —— 原始 KV 值。
- **doc map**（索引模式）—— `#{text => binary(), fields => [{Field, Text}],
  vector => binary(), meta => binary()}`，所有键可选：
  - `text` —— 分词进默认 BM25 字段。
  - `fields` —— `{字段名::binary(), 文本::binary()}` 列表，多字段索引；同时并入
    默认字段，使 `search_text` 也能命中。
  - `vector` —— f32 小端二进制，长度 `vector_dim * 4` 字节。
  - `meta` —— 由 `encode_meta/1` 产出的结构化元数据 blob（供 filter）。
- **`tombstone`** —— 历史别名，等价 `delete`。

**自动 embed：** 若 open 配了 embedder 且 doc 有 `text` 无 `vector`，`put` 会调
embedder 生成并写入向量；显式传 `vector` 则跳过。

限制：`vector` 字节数非 4 的倍数 → `badarg`；维度不符 → `{error, _}`；`cosine`
下零向量 → `{error, _}`。

### `delete(Handle, Key) -> ok`
写墓碑。空间在下次 merge 回收。

---

## 迭代

迭代是 keydir **快照**——看不到 fold 开始之后的写入。

| 函数 | 回调 / 说明 |
|------|------------|
| `list_keys(Handle) -> [Key] \| {error,_}` | 活跃 key，顺序未定义 |
| `fold(Handle, Fun, Acc0)` | `Fun(K, V, Acc) -> Acc'` |
| `fold(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombs)` | `SeeTombs` 时墓碑以 `Fun({tombstone, K}, V, Acc)` 上交 |
| `fold_keys(Handle, Fun, Acc0)` | `Fun(#bitcask_entry{}, Acc) -> Acc'` |
| `fold_keys(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombs)` | 墓碑为 `{tombstone, #bitcask_entry{}}` |
| `stream_fold(Handle, Fun, Acc0)` / `/4`（批大小） | 内部分批的 fold |
| `stream(Handle) -> S` · `next(S) -> {ok,K,V} \| done \| {error,_}` · `stop(S) -> ok` · `with_stream(Handle, F)` | producer 进程流式；同句柄可并发多个 |

`MaxAge` 单位**微秒**（`-1`/负数 = 不限）。`MaxPut` 限制 fold 期间允许的写入次数
（`-1` = 不限）。

---

## 维护

### `merge(Dir)` · `merge(Dir, Opts)` · `merge(Dir, Opts, Which)`
在 `Dir` 临时开 `read_write` cask，跑一次 merge 后关闭。用 `bitcask.merge.lock`
（不阻塞在写的 writer）。已有别的 merger 持锁 → `{error, {merge_locked, _, Dir}}`。
若你已持有 writer 句柄，直接 `bitcask_cpp_nifs:cask_merge(Ref, Files)` 更高效。

### `needs_merge(Handle) -> false | {true, {Files, Expired}}` · `/2`
是否需要 merge；返回值可直接喂给 `merge/3`。

### `status(Handle) -> {KeyCount, FilesInfo}`
### `is_frozen(Handle) -> boolean()`
有 fold 快照在跑时为 true。
### `is_empty_estimate(Handle) -> boolean()`
O(1) 估算；写过任何 key 后恒 `false`。

---

## BM25 全文搜索（索引模式）

全部返回 `{ok, [{Key, Ord, Score}]}`（分数降序）；KV 模式下返回 `{error, no_index}`。
`Ord` 是内部文档序号。`K` = 返回条数（默认 `10`；`K =< 0` 回落到 `10`）。

| 函数 | 额外参数 |
|------|---------|
| `search_text(H, Query[, K[, Filter]])` | 词袋 |
| `search_phrase(H, Query[, K])` | 精确相邻短语 |
| `search_fields(H, Query[, K])` | `field:term^boost` 语法；无字段限定词 = 默认字段 |
| `search_near(H, Query, Slop[, K])` | 词按序出现且间隙 `=< Slop`；`Slop=0` 即短语 |
| `search_fuzzy(H, Query, MaxEdit[, K])` | Levenshtein 编辑距离 `=< MaxEdit`（通常 1–2） |
| `search_wildcard(H, Pattern[, K])` | `*` 与 `?` 通配 |

`Filter`（`search_text/4`）是 meta filter——见下。

---

## 向量 / 混合检索

`VecBin` 是长度 `vector_dim * 4` 的 f32 小端二进制。

### `embed(Handle, Text) -> {ok, VecBin} | {error, Reason}`
用句柄配置的 embedder 把 `Text` 编码成向量。未配 → `{error, no_embedder}`。

### `search_vector(H, Query[, K[, Ef[, Filter]]])`
`Query` 为 `VecBin` 或 `{text, Bin}`（用句柄自动 embed）。
- `K` —— top-K（默认 10）。
- `Ef` —— HNSW 搜索宽度 / candidate list 大小（`0` = 引擎默认 `max(K, 64)`；越大越准越慢）。
- `Filter` —— meta filter。

返回 `{ok, [{Key, Ord, Score}]}`（Score = 该度量下的相似度）。

### `search_hybrid(H, Text[, VecOrAuto[, K[, Filter]]])`
对 BM25 路（基于 `Text`）与向量路做 RRF 融合。第 3 个参数选向量来源：
- 省略（`/2`）或传原子 **`auto`** → 用句柄 embedder 把 `Text` 编码成查询向量
  （一段文本驱动两路）。要同时传 `K`/`Filter` 必须用 `auto`。
- 传 **`VecBin`** → 显式查询向量。

形态：`search_hybrid(H, Text)` · `(H, Text, VecBin)` · `(H, Text, auto|VecBin, K)`
· `(H, Text, auto|VecBin, K, Filter)`。任一路可空（`Text = <<>>` 或
`VecBin = <<>>`）做单路退化；两路都空 → `{error, _}`。每路内部取 `max(K*4, 64)`
个候选，融合后返回 top `K`。

---

## Meta 过滤

filter 只返回 `meta` 命中的文档。无 `meta` 的文档一律不通过。

**单条件：** `#{key => Key, op => Op, value => V}`，`Op` 为 `eq | gte | lte`；或
`#{key => Key, op => in, values => [V, ...]}`。`Key` 可为 binary 或 atom。

**组合：**
- **列表** = AND：`[Cond1, Cond2]`
- `#{logic => 'and' | 'or', conditions => [Cond, ...]}`
- 树形嵌套：`#{logic => ..., children => [子filter, ...]}`

形态非法（错误 `op`、`in` 缺 `values`、atom 当 binary 误用）→ `badarg`。

### `encode_meta(Entries) -> MetaBin`
把 map（或 proplist）编码成 `put` 用的 `meta` blob。值类型：`integer` → int64，
`float` → double，`binary` → string，`true`/`false` → bool，`undefined` → null。
结果作为 put doc map 的 `meta` 键。

---

## Embedder API（`bitcask_embedder`）

### `new(Provider, Cfg) -> {ok, Ctx} | {error, Reason}`
`Provider = openai | anthropic | {custom, Module}`。构建上下文。（用推荐的
`{embedder, {Provider, Cfg}}` open 选项时无需自己调——open 会调。）

### `embed(Ctx, Text) -> {ok, VecBin} | {error, Reason}`
### `dim(Ctx) -> pos_integer()` —— 模型**原生**维度
### `vector_dim(Ctx) -> pos_integer()` —— **落库/检索**维度（MRL 目标；默认 = `dim`）

**Provider 配置（`Cfg`）**——正整数类选项会校验，非法 → `{error, {bad_opt, Key}}`：

| 键 | 含义 | 默认 |
|----|------|------|
| `url` | 端点（OpenAI 兼容 `/v1/embeddings`） | 必填 |
| `model` | 模型名（binary） | 必填 |
| `dim` | 模型原生输出维度 | openai 2560 / anthropic 4096 |
| `vector_dim` | MRL 截断目标 = 落库/检索维度 | `= dim`；须 `=< dim` |
| `api_key` | bearer / x-api-key | 无 |
| `max_input_bytes` | embed 前输入字节级上限 | 32768 |
| `timeout_ms` | 请求总超时 | 30000 |
| `connect_timeout_ms` | 建连超时 | 5000 |

**MRL（Matryoshka）：** `dim` 永远是模型原生维度；`vector_dim` 是实际落库/检索的
截断维度。`vector_dim =/= dim` 时 embed 请求带 `dimensions => vector_dim`，由服务端
按 MRL 截断+重归一（端点需支持）；返回长度会被校验，不符报
`{error, {dim_mismatch, Got, Expect}}`。

---

## 返回值与错误（速查）

| 调用 | 成功 | 主要错误 |
|------|------|---------|
| `open` | `{Ref, Ctx}` | `write_locked`、`enoent`、`mode_mismatch`、`{bad_embedder,_}`、`{bad_opt,_}` |
| `get` | `{ok, V}` / `not_found` | `{error, _}` |
| `put` | `ok` | `badarg`（坏向量字节）、`{error, _}`（维度/零向量/embed） |
| `search_*` | `{ok, [{Key, Ord, Score}]}` | `{error, no_index}`、`{error, _}` |
| `embed` | `{ok, VecBin}` | `{error, no_embedder}`、`{error, {dim_mismatch,_,_}}`、`{error, {http_*,_}}` |
| `merge` | `ok` | `{error, {merge_locked, _, Dir}}` |

## 并发约束（速查）

- 每目录单写者（跨进程经 `bitcask.write.lock` 强制）。
- 读/搜索无锁，与单写者及异步索引 worker 并发。
- 句柄（`{Ref, Ctx}`）可在多读线程间共享；写由调用方串行化（单 Erlang 进程持写）。
  同一 BEAM 内对同一目录多次 `open` 共享同一内存 KeyDir。完整模型见
  [`concurrency-zh.md`](concurrency-zh.md)。
