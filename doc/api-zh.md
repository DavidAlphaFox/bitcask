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
| `{max_read_handles, N}` | read 句柄缓存上限（每句柄 = 1 fd + 1 sealed mmap） | `0` = 自动 | 自动档由 `RLIMIT_NOFILE` 推导并**夹在 `[64, 1024]`**（6.0.0）；`unlimited` = 显式不限 |
| `{keydir_cache_entries, N}` | **6.0.0**：keydir 磁盘驻留 Level B 的热点缓存条目预算 | `0` = 不限 = 全内存 | `> 0` 才 opt-in；见下 |

**`keydir_cache_entries` 详解。** `0`（默认）= 现状，keydir 全内存。`> 0` 时
keydir 降级为热点缓存（超预算分片内采样逐出），点查权威 = 缓存 → memdelta →
BCOK v2 run（内嵌 bloom + 块 LRU，冷 get ≤2 次 pread）；`fold`/`range` 在逐出态
经组合视图完整枚举。上游 1 亿 `doc:` key 实测：常驻 11 GB → **加载峰值 1.14 GB /
重开 0.80 GB（-90%）**，热 get/put/merge 零回归。

> ⚠️ 首次在未带 Level B 戳的目录上开启会**全量重建 OKI**（那一次 open 慢）；
> 此后 manifest 带戳，重开快。
> ⚠️ Level A（不设此项）的写者重开会**清戳**，再回 Level B 时重建自愈。
> ⚠️ `merge_only` 旁车与 Level B 目录**互斥**——open 直接拒绝（旁车的无挂钩搬迁
> 会静默腐蚀组合视图的位置权威）。
> 预算是软目标（fold 活跃期暂停逐出）。

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
| `{embedder, {Provider, Cfg}}` | open 内部经 `bitcask_embedder:new(Provider, Cfg)` 建 ctx，并自动用 embedder 的 `vector_dim` 作为集合维度；启用 `put`/查询的自动 embed。ctx **本句柄独占**。 | `Provider = openai \| anthropic \| {custom, Mod}`；`Cfg` 是 map。预建 ctx map 会被**拒绝**（`{error, {bad_embedder, _}}`）。在场时 `{vector_dim, N}` 由 embedder 接管。 |
| `{embedder, ServerRef}` | **有状态 provider（本地模型）走这条。** 一个 [`bitcask_embedder_server`](../src/bitcask_embedder_server.erl) 进程；行为同上，但 provider 状态归那个进程：**多 cask 共用一份**，生命周期跟着进程走（`terminate/2` 释放）。进程一般由 `bitcask_sup` 按 application env `{embedder, #{name, provider, config}}` 启动。⚠️ HTTP 档**不要**放进来（无状态、该并发，进程会把吞吐锁成一条链）。 | `ServerRef = pid() \| 注册名 \| {global,_} \| {via,M,N}`。进程未起 → `{error, {embedder_not_running, Ref}}`；运行中挂掉 → `put` 得 `{error, {embedder_not_running,_}}`，**不会**带走调用方。⚠️ env 配了却起不来 → 整个 application 起不来，`open` 返回 `{error, {bitcask_app_start_failed,_}}`（有意如此）。见 [`doc/local-embedding-zh.md`](local-embedding-zh.md)。 |
| `{vector_dim, N}` | 向量维度——仅手动向量路径（不配 embedder）需要 | `N > 0`；重开须与磁盘 meta 一致 |
| `{vector_metric, M}` | 距离/相似度度量——见下 | `cosine`（默认）\| `l2` \| `dot`；**创建时固定**（重开换度量 → `mode_mismatch`） |
| `{vector_engine, E}` | v4.0.0：向量引擎——`hnsw`（内存图，≤ 数 M 向量档）\| `ivfrq`（IVF-RaBitQ 磁盘档，10M-100M 推荐）\| `diskann`（Vamana 图，**实验性**） | 默认 `hnsw`；**建库时固定**并持久化进 `bitcask.meta`（重开不符 → `mode_mismatch`）；磁盘档引擎要求 `cosine`/`dot`（`l2` → `{error, _}`）；离线切换用 libbitcask 的 `vec_engine_migrate` 工具 |

*向量引擎调优*（v4.0.0；`0` = 各自动默认，一般无需设置）：
`{hnsw_m, N}`、`{hnsw_ef_construction, N}`（HNSW 图出度 / 建图 ef）；
`{hnsw_build_nav_int8, B}`（HNSW int8 混合精度建图导航，默认 `true`，插入
+29%~75%、recall@10 零损失；`false` = 全 f32 回退闸）；
`{vector_rebase_min_docs, N}`（向量 ckpt 崩溃恢复重放上界，全引擎，默认
262144）；`{vector_ivf_nlist, N}`、`{vector_ivf_nprobe, N}`（ivfrq 簇数 /
查询探簇数，`0` = 自动；`search_vector` 的 `Ef` 参数非 0 时按 nprobe 解释）；
`{vector_diskann_r, N}`、`{vector_diskann_l_build, N}`（diskann 邻接容量 /
建图 beam 宽；查询 beam 宽走 `Ef` 参数）。

**`vector_metric` 详解。** 决定 HNSW 如何比较向量。三种度量返回的 `Score` 都统一为
**越大 = 越相似/越近**（结果按 `Score` 降序）：

| 度量 | 计算的是 | 返回的 `Score` | 说明 / 限制 |
|------|---------|---------------|------------|
| `cosine`（默认） | 余弦相似度 | 余弦相似度 ∈ `[-1, 1]`（1 = 方向完全一致） | 入库**与**查询向量都由引擎做 L2 归一化（重写幂等），忽略模长。**零向量被拒绝**（`{error, _}`，无方向）。内部实现为归一化后的 `dot`。 |
| `dot` | 原始内积 | 内积值（无界） | **不归一化**——模长影响分数。适合向量已归一化、或模长本身有意义的场景。 |
| `l2` | 平方欧氏距离 | **负**的平方距离（`=< 0`；越近越趋于 0） | 取负以统一「越大越好」的排序。 |

选型建议：多数文本 embedding 模型（含 qwen3-embedding，输出已 L2 归一化）→ 用
`cosine`（或 `dot`，归一化输入下等价）。只有当你要的是绝对几何距离时才用 `l2`。
度量在首次 open 写入集合 meta，之后不可更改。

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
- **doc map**（索引模式）—— `#{text => binary(), fields => #{Field => Text},
  vector => binary(), meta => binary()}`，所有键可选：
  - `text` —— 分词进默认 BM25 字段。
  - `fields` —— `#{字段名::binary() => 文本::binary()}` map，多字段索引；同时并入
    默认字段，使 `search_text` 也能命中。非 map（如 proplist）→ `badarg`。
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

## 有序范围查询（6.0.0）

按 key 字典序遍历 `[Lo, Hi)`，代价 **O(range)**，不是 O(全表) 过滤。底座是 OKI
有序 key 索引。

> ⚠️ **不是快照。** 一致性是 per-key 弱一致（与 `parallel_scan` 同档）——迭代期间
> 的并发写可能部分可见。需要快照请用 `fold`。

| 函数 | 说明 |
|------|------|
| `range(Handle, {Lo, Hi}) -> [{Key, Value}] \| {error,_}` | `Lo` 含、`Hi` 不含；任一端可为 `undefined` = 无界 |
| `range(Handle, {Lo, Hi}, Opts)` | 同上，带调优选项 |
| `range_fold(Handle, {Lo, Hi}, Opts, Fun, Acc0)` | `Fun(K, V, Tstamp, Ord, Acc) -> Acc'`；流式，不在内存里堆全量结果 |

`Opts`：

| 选项 | 默认 | 说明 |
|------|------|------|
| `{prefetch, N}` | `0`（关） | `N > 1` 时一次归并 N 个 key 并发取值。**只改取值时机，输出序与内容不变。** 大窗口 + 冷值收益明显；小窗口反被线程创建成本吃掉 |
| `{prefetch_threads, N}` | `0` | `0` = `min(在线核数, 4)`；批内 key 数不足时按 key 数收窄 |
| `{want_meta, true}` | 关 | `V` 改为 `#{text => Bin, meta => Bin \| undefined}`，形态与 `get` 在索引模式下的返回一致。meta 和 text 出自同一次读 |
| `{filter, F}` | 无 | meta filter（形态同 `search_text/4`），在 C++ 侧逐条判断，不通过的条目不返回；没有 meta 的条目一律不通过 |

前缀扫描的惯用写法是把上界设成前缀的**下一个字节**：
`range(H, {<<"user:">>, <<"user;">>})`。

**OKI 不可用时按成因分两个错误码**（6.1.0 起）——补救方式不同，所以刻意分开：

| 返回 | 成因 | 怎么办 |
|------|------|--------|
| `{error, no_index}` | 索引在**本句柄上本就不建**：只读 / `merge_only` 打开一个从未建过 OKI 的目录 | 以 `read_write` 重开即自动建；或回落到 `fold` + 前缀过滤 |
| `{error, index_rebuild_failed}` | 可写 open 时 OKI **试建而败**（IO / 环境问题，细节在 log 里） | 先修环境再重开重试。**不要**当成「没数据」——库是有数据的 |

> **只读打开有数据的库，range 是正常的**——RW 会话已把 OKI 落盘，RO 直接读，
> 不需要（也无权）重建。会报 `no_index` 的是**从未写过的目录**。
>
> ⚠️ 两者都**没有**被压成空结果 `[]`：那会让「一个有数据的库因为索引坏了而
> 静静地返回空」无法察觉。尤其 `index_rebuild_failed` 意味着数据在、索引不在，
> 把它当空结果是实打实的数据丢失假象。
>
> ⚠️ OKI 只是派生缓存——这两种情况下 `get` / `put` / `fold` 全部照常，
> **只有 range 不可用**。

---

## 原子批与多键事务（6.0.0）

`Ops :: [{put, Key, Value} | {remove, Key}]`。`Key` 是 `binary()`；`Value` 是 `binary()`，
或者 doc map（与 `put/3` 同形：`text` / `meta` / `vector` / `fields`；随 libbitcask 6.6.2 支持）。
写 doc map 时，文档和它的二级索引项可以同批落盘。
- 配了 embedder 时，批里「有 `text`、没有 `vector`」的文档会自动 embed，和 `put_docs/2` 一样只调一次 `embed_batch`；embed 失败则整批不写。
- 向量维度不对时整批拒绝，没有任何副作用。
- KV 模式下 doc map 只保留 text，与 `put/3` 一致。

形态不认（标签错、元数错、key 不是 binary、value 既不是 binary 也不是 map）一律报 `badarg`——**绝不静默丢弃**，
批里悄悄少一条会让「原子」失去意义。

崩溃/掉电后**整批要么全生效要么全不生效**（盘上批头声明区间，恢复时区间不完整
即整批截断）。

> ⚠️ 原子性与持久性**正交**：没 fsync 就掉电仍可能整批丢失，但绝不半批。
> ⚠️ **不提供隔离性（I）与 CAS**：中间态对并发读者可见；键集重叠的并发提交无
> 定序保证，需应用层串行化。键集不相交则并发安全。
> ⚠️ **首次调用把目录 `bitcask.meta` 懒升级为 v6**，此后不能被早于上游 5.1.0 的
> 读端打开。从不调用的目录停留在 v5。

| 函数 | 说明 |
|------|------|
| `put_batch_atomic(Handle, Ops) -> ok \| {error,_}` | 裸批。允许批内同 key 多次（依序 apply = 批内 LWW）；空批是 no-op |
| `txn_commit(Handle, Ops) -> ok \| {error,_}` | 等价 `txn_commit(H, Ops, sync_on_commit)` |
| `txn_commit(Handle, Ops, Sync)` | `Sync :: sync_on_commit \| no_sync` |

`txn_commit` 比 `put_batch_atomic` 多一层校验：批非空、key 非空、key 互不重复、
不占用 `"_txn:"` 保留前缀。违反任一条 → `{error, {invalid_option, Msg}}` 且
**零副作用**。`Sync` 取值非法 → `function_clause`（Erlang 层就挡掉）。

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
| `search_phrase(H, Query[, K[, Filter]])` | 精确相邻短语 |
| `search_fields(H, Query[, K[, Filter]])` | `field:term^boost` 语法；无字段限定词 = 默认字段 |
| `search_near(H, Query, Slop[, K[, Filter]])` | 词按序出现且间隙 `=< Slop`；`Slop=0` 即短语 |
| `search_fuzzy(H, Query, MaxEdit[, K[, Filter]])` | Levenshtein 编辑距离 `=< MaxEdit`（通常 1–2） |
| `search_wildcard(H, Pattern[, K[, Filter]])` | `*` 与 `?` 通配 |

`Filter` 是 meta filter（见下），`undefined` 表示不过滤。带 filter 时引擎会补取到 `K` 条：
返回少于 `K` 条，就说明满足条件的只有这么多。
同分命中按 (段次序, 段内写入序) 稳定排序：小 `K` 的结果是大 `K` 结果的前缀。
例外：`search_fields` 有多个字段或多个 boost 组时，结果是逐字段取 top-K 再求和的近似值，不保证这种前缀关系。

---

## 向量 / 混合检索

`VecBin` 是长度 `vector_dim * 4` 的 f32 小端二进制。

### `embed(Handle, Text) -> {ok, VecBin} | {error, Reason}`
用句柄配置的 embedder 把 `Text` 编码成向量。未配 → `{error, no_embedder}`。

### `search_vector(H, Query[, K[, Ef[, Filter]]])`
向量近邻检索（引擎由建库时的 `{vector_engine, E}` 决定，默认 HNSW）。四个
arity 是同一调用、缺省项逐级展开：

| Arity | 签名 | 等价于 |
|-------|------|--------|
| `/2` | `search_vector(H, Query)` | `/3`，`K=10` |
| `/3` | `search_vector(H, Query, K)` | `/4`，`Ef=0` |
| `/4` | `search_vector(H, Query, K, Ef)` | 调引擎（无 filter） |
| `/5` | `search_vector(H, Query, K, Ef, Filter)` | 调引擎（带 meta filter） |

参数：
- `Query` —— `VecBin`（f32 LE，`vector_dim*4` 字节）或 `{text, Bin}`（用句柄
  embedder 自动 embed；未配 embedder → `{error, no_embedder}`）。每个 arity 通用。
- `K` —— top-K（默认 10）。
- `Ef` —— 搜索宽度，按引擎解释：HNSW = candidate list 大小（`0` = 引擎默认
  `max(K, 64)`）；ivfrq = 查询探簇数 nprobe（`0` = 自动）；diskann = 查询 beam
  宽。越大越准越慢。
- `Filter` —— meta filter。

返回 `{ok, [{Key, Ord, Score}]}`（Score = 该度量下的相似度）。

```erlang
search_vector(H, VecBin).                 %% 默认 K=10、Ef 默认
search_vector(H, VecBin, 20).             %% 指定 K
search_vector(H, VecBin, 20, 128).        %% 调大 Ef 提召回
search_vector(H, {text, <<"机器学习">>}, 10, 0,
              #{key => <<"category">>, op => eq, value => <<"tech">>}). %% 文本自动 embed + 过滤
```

### `search_hybrid(H, Text[, VecOrAuto[, K[, Filter]]])`
对 BM25 文本路（基于 `Text`）与向量路做 RRF 融合（`1/(60+rank)`，平局 `ord` 小者
在前）。第 3 个参数选向量来源：
- 省略（`/2`）或传原子 **`auto`** → 用句柄 embedder 把 `Text` 编码成查询向量
  （一段文本驱动两路）。要同时传 `K`/`Filter` 必须用 `auto`。
- 传 **`VecBin`** → 显式查询向量。

四个 arity 缺省项逐级展开：

| Arity | 签名 | 等价于 |
|-------|------|--------|
| `/2` | `search_hybrid(H, Text)` | `/4`，向量位 `auto`、`K=10`（全自动） |
| `/3` | `search_hybrid(H, Text, VecBin)` | `/4`，`K=10`（显式向量） |
| `/4` | `search_hybrid(H, Text, auto\|VecBin, K)` | 调引擎（`auto` 先自动 embed） |
| `/5` | `search_hybrid(H, Text, auto\|VecBin, K, Filter)` | 调引擎 + meta filter |

任一路可空（`Text = <<>>` 或 `VecBin = <<>>`）做单路退化；两路都空 →
`{error, _}`。每路内部取 `max(K*4, 64)` 个候选，融合后返回 top `K`，结果为
`{ok, [{Key, Ord, RrfScore}]}`。

```erlang
search_hybrid(H, <<"机器学习入门">>).                %% 全自动：文本既做 BM25 又 embed
search_hybrid(H, <<"机器学习入门">>, auto, 20).      %% 自动 embed + 指定 K
search_hybrid(H, <<"机器学习">>, MyVecBin, 10).      %% 文本走 BM25、向量显式给
search_hybrid(H, <<"机器学习">>, auto, 10,
              #{key => <<"category">>, op => eq, value => <<"tech">>}). %% + 过滤
search_hybrid(H, <<"机器学习">>, <<>>, 10).          %% 单路退化：只 BM25
search_hybrid(H, <<>>, MyVecBin, 10).                %% 单路退化：只向量
```

> `search_vector` 是**纯向量**近邻（分数为向量相似度）；`search_hybrid` 是
> **BM25 + 向量两路 RRF 融合**（分数为融合 rank 分），兼顾关键词精确匹配与语义召回。

---

## Meta 过滤

filter 只返回 `meta` 命中的文档。没有 meta 的文档一律不通过（包括 `neq`）。传原子 `undefined` 表示不过滤。

**单条件：** `#{key => Key, op => Op, value => V}`，其中 `Op` 是 `eq | neq | gt | gte | lt | lte` 之一；
另有两种特殊形态：
- `#{key => Key, op => in, values => [V, ...]}`（列表不能为空）；
- `#{key => Key, op => exists}`（不需要 `value`）。

`Key` 必须是 binary，传 atom 会报 `badarg`。`V` 可以是 integer（int64）、float、binary、`true`/`false`，或者 `undefined`（表示 null）。传其它 atom 会报 `badarg`。

**组合：**
- **列表** = AND：`[Cond1, Cond2]`（列表元素只能是单条件）
- 单条件 map 本身也可以直接作为 filter 传入
- `#{logic => 'and' | 'or', conditions => [Cond, ...], children => [SubFilter, ...]}`。三个键都可以省略，`logic` 默认是 `'and'`。`children` 的元素必须是这种带 `logic` 的 map，不能是列表。

**求值语义**（`meta_filter.hpp`）：
- `eq`、`neq`、`in` 只在同类型之间判断相等，比如 `1` 不等于 `1.0`。
- 缺失的字段读作 null，所以 `{eq, undefined}` 能命中缺失字段。`in` 遇到缺失字段一律为假。
- `gt`、`gte`、`lt`、`lte` 只比较 integer 与 integer、float 与 float，其它组合一律为假。
- `exists` 表示字段存在且值不是 null。
- 不含任何条件、也不含子 filter 的 filter 恒为真（即使 `logic` 是 `'or'` 也一样）。

形态非法（未知 `op`、`in` 缺 `values` 或列表为空、atom 当 `Key`、不支持的值类型）→ `badarg`。

### `encode_meta(Entries) -> MetaBin`
把 map（或 proplist）编码成 `put` 用的 `meta` blob。值类型：`integer` → int64，
`float` → double，`binary` → string，`true`/`false` → bool，`undefined` → null。
结果作为 put doc map 的 `meta` 键。

### `decode_meta(MetaBin) -> map()`
`encode_meta/1` 的反方向：把 meta blob 解码成 `#{binary() => V}`，null 解回 `undefined`。
blob 非法会报 `badarg`。`get` 在没有 meta 时返回 `undefined`，由调用方自己判断。

---

## 结构化查询（`bitcask_query`）

```erlang
{ok, Rows} = bitcask_query:q(H, #{
    key    => {prefix, <<"doc:">>},            % | {range, Lo, Hi} | {eq, K}
    text   => {match, <<"分布式 存储">>},        % | {phrase,Q} | {fields,Q} | {near,Q,Slop}
                                               % | {fuzzy,Q,MaxEdit} | {wildcard,P}
    where  => [{<<"year">>, gte, 2024},
               {'or', [{<<"cat">>, in, [<<"db">>, <<"kv">>]}, {<<"hot">>, eq, true}]}],
    vector => VecBin,                          % | {text, Bin}；与 {match,_} 同给 = 混合检索
    limit  => 100,                             % 默认 infinity；page/2 里是每页条数
    select => [key, text, meta, score]         % 默认全要
}).
%% Row = #{key, text, meta => map() | undefined, score}，score 只在 text 驱动时有
```

**分页**：`bitcask_query:page(H, Query)` 和 `page(Cont)` 都返回 `{ok, Rows, Cont}`，没有下一页时 `Cont` 为 `done`；`page(done)` 返回 `{ok, [], done}`。`limit` 就是每页条数，必须给。
游标是不透明的 term，不占服务端资源，丢掉即可。每页会多取 1 条，用来判断还有没有下一页，所以条数正好整除时，最后一页是满的，并直接返回 `done`。

| 驱动 | 游标 | 翻页保证 |
|---|---|---|
| key（range） | 下一页起始 key | 不重不漏，按 key 升序（`range` 本身不是快照，翻页期间的写入可能出现在后面的页里） |
| 全文检索（`search_fields` 除外） | 已消费的引擎命中数 | 不重不漏（依赖 libbitcask 6.6.1 的同分前缀稳定）；每页按偏移重查，越往后越贵 |
| 向量 / 混合 / `search_fields` | 已返回过的 key 集合 | **不重复，但可能漏**：K 变了结果也会变（HNSW 近似、RRF 融合、多字段逐字段 top-K 求和），翻页时新挤进前排的命中不会再出现 |

**向量 / 混合**：
- `vector => VecBin`（f32 小端，长度为 `vector_dim * 4` 字节）或 `{text, Bin}`（用句柄的 embedder 编码；整个查询包括翻页只 embed 一次）。
- 只给 `vector` 时走 `search_vector`，可以带 `ef`（默认 0，表示由引擎决定）。
- 和 `text => {match, Q}` 同时给时走 `search_hybrid`（RRF 融合），这时不能带 `ef`；配其它全文检索类型会报 `{bad_query, {hybrid_needs_match, _}}`。
- `where` 照样下推；`score` 在向量检索时是相似度，在混合检索时是 RRF 分数。
- 向量检索带 filter 时，引擎本身就可能少返回结果（HNSW），这时返回不足 K 条也只能当作已经取完。

### 二级索引

按 meta 字段建索引，让只有 `where` 的查询不必扫全表，相当于 `mnesia:index_read`。

```erlang
ok = bitcask_query:create_index(H, <<"year">>),       % 回填存量；已存在则直接 ok
ok = bitcask_query:put(H, Key, #{text => T, meta => M}),   % 有索引时写入必须走这里
ok = bitcask_query:delete(H, Key),
[{<<"year">>, ready}] = bitcask_query:indexes(H),
{ok, #{driver := index}} = bitcask_query:explain(H, #{where => {<<"year">>, gte, 2024}}),
ok = bitcask_query:drop_index(H, <<"year">>).
```

- **何时使用**：查询里没有 `key`、`text`、`vector` 条件，且顶层 AND 里有某个已建索引字段上的
  `eq`、`in`、`gt`、`gte`、`lt`、`lte` 或 `exists` 条件时走索引。多个可选时按 eq > in > 大小比较 > exists 的顺序只选一个。
  `neq`、`{F, eq, undefined}`（命中缺失字段）、多分支 `or` 不走索引。`index => none` 可以强制不用索引。
- **结果顺序**：按「索引值、再按主键」升序，和全表扫描的「按 key 升序」不同。分页照常可用，游标是下一个索引键。
- **存储**：索引和数据在同一个 cask 里，用保留前缀 `<<0,"bitcask_query:">>` 隔开。全表查询会跳过这些 key，
  `bitcask_query:put` 拒绝写这个前缀。在索引模式下，索引项是空 text 的文档，全文检索不会命中，实测也不影响 BM25 打分。
- **一致性**：每次 `bitcask_query:put/delete` 都是一个 `bitcask_txn` 事务。
  - 先锁住这个 key、读出旧 meta，再把「文档 + 新索引项 + 删旧索引项」放进同一个提交批（随 libbitcask 6.6.2 支持）。
  - 崩溃时整批要么全在、要么全不在；并发写同一个 key 由锁串行。
  - 提交用 `no_sync`，持久性与 `bitcask:put` 相同。
  - 读取时仍会回表核对：文档当前值必须就是索引项里的值，再判断整个 `where`。这一步挡的是绕过 `bitcask_query:put` 的写入；
    命中行本来就要 `get` 文档，所以几乎不增加开销。
- ⚠️ **索引字段的写入必须走 `bitcask_query:put/delete`**。直接用 `bitcask:put` 改了 meta 的话，新值查不到，
  旧值的过期项会被读时校验挡掉。修复方法是 `drop_index` 后再 `create_index`。
- 建索引时先登记为 `building`，这时写入就开始维护索引；回填完成后转为 `ready`，之后查询才会使用它。
  回填不加 key 锁，和并发写交错时可能多出过期项，会被读时校验挡掉，不会漏。

为什么不用 match spec：值是要分词的字符串，全文条件只能交给倒排索引（在 C++ 侧分词），
结构化条件只能写在 `meta` 上。规划器按下面的顺序选择从哪里驱动：

| 条件 | 驱动方式 | 结果顺序 |
|---|---|---|
| 有 `text` / `vector` | `search_*`（只有 `vector` 走 `search_vector`，和 `{match,_}` 同给走 `search_hybrid`），`where` 下推成引擎 meta filter；`key` 条件对命中做后过滤 | 分数降序 |
| 无 `text`，`key => {eq,K}` | `get` | — |
| 无 `text`，有 prefix 或 range | `range`，`where` 下推成 range 的 `filter`，meta 随条目一起带回 | key 升序 |
| 都没有 | 全表 `range`，同上；OKI 不可用（`no_index`）时回落到 `fold`，收齐后按 key 排序 | key 升序 |

`where` 的语义和引擎 MetaFilter 逐条一致。测试里把检索下推、range 下推、BEAM 侧求值三条路径互相对照：

- 没有 meta 的文档，过不了任何非空 `where`。
- `eq`、`neq`、`in` 只在同类型之间判断相等，比如 `1` 不等于 `1.0`。缺失的字段读作 `undefined`。
- `gt`、`gte`、`lt`、`lte` 只比较 integer 与 integer、float 与 float。
- `exists` 表示字段存在且值不是 null。

字段名可以是 binary 或 atom。

限制：

- 全文检索返回的命中只有 key，结果行里的 text 和 meta 要再 `get` 一次才能拿到。两次读之间如果文档被改写，返回的是新版本，可能已经不满足 `where`。
- 有 `key` 条件时，key 过滤在 BEAM 侧对命中做；命中不够 `limit` 时翻倍 K 重查。
- `range` 不是快照。只有在只读打开一个从未建过 OKI 的目录（`no_index`）时，才回落到 `fold`，此时逐行 `get` 后在 BEAM 侧求值 `where`。
- 依赖 libbitcask ≥ 6.6.1（带 filter 的检索补取到 K、同分命中前缀稳定）。
- text 驱动在 100 万（引擎 topK 上限）以内凑不够结果 → 返回 `{error, {too_many_hits, 1000000}}`，不会悄悄截断。
- 查询本身不合法 → 返回 `{error, {bad_query, _}}`。

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
