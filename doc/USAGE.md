# bitcask 使用指南

本指南涵盖 C++23 NIF（`cask_cpp`）——唯一可用的模式。
所有操作通过 `bitcask_cpp_nifs` → `priv/bitcask_cpp.so` 进行。

## 构建与 Shell

```bash
cd /path/to/bitcask
rebar3 compile        # 生成 priv/bitcask_cpp.so
rebar3 shell          # 启动生产模式 shell
```

## NIF 模式

**仅有一种模式**：`cask_cpp`（粗粒度 C++ NIF）。

```erlang
%% 生产环境默认——无需选项
R = bitcask:open("/tmp/db", [read_write]).

%% 显式强制 KV 模式（未设置分析器时的默认值）：
R = bitcask:open("/tmp/db", [read_write]).

%% 启用全文检索，添加分析器：
R = bitcask:open("/tmp/db", [read_write, {analyzer, ngram}]).
```

不存在遗留回退——`bitcask_legacy.erl` 已被删除。

## 基本操作

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> bitcask:put(R, <<"k">>, <<"v">>).             ok
3> bitcask:get(R, <<"k">>).                       {ok,<<"v">>}
4> bitcask:list_keys(R).                          [<<"k">>]
5> bitcask:fold(R, fun(K,V,Acc) -> [{K,V}|Acc] end, []).
6> bitcask:delete(R, <<"k">>).                    ok
7> bitcask:close(R).                              ok
```

### 全文检索（索引模式）

使用分析器打开以启用 BM25 搜索：

```erlang
%% 使用 BM25 索引打开——创建 bitcask.meta 并设置 mode=kIndex
1> R = bitcask:open("/tmp/db", [read_write, {analyzer, ngram}]).

%% 写入文档——接受 binary 或 #{text => binary(), meta => binary()}
2> bitcask:put(R, <<"doc1">>, <<"Beijing Chaoyang district">>).
3> bitcask:put(R, <<"doc2">>, <<"Shanghai Pudong area">>).
4> bitcask:put(R, <<"doc3">>, <<"Beijing Chaoyang is a district">>).

%% BM25 词袋搜索（结果为 {Key, Ord, Score} 三元组，分数降序）
5> bitcask:search_text(R, <<"Beijing">>, 10).
{ok,[{<<"doc1">>,0,0.288},{<<"doc3">>,2,0.288}]}

%% BM25 短语搜索（词元必须相邻）
6> bitcask:search_phrase(R, <<"Beijing Chaoyang">>, 10).
{ok,[{<<"doc1">>,0,0.287}]}

7> bitcask:close(R).
```

**分析器选项：**

| Analyzer    | 说明                                     |
|-------------|-------------------------------------------------|
| `ngram`     | 默认；n-gram 分词                     |
| `jieba`     | 中文分词（需要 `{dict_path, Path}`） |
| `whitespace`| 简单空格分词             |

**返回格式：** `{ok, [{Key :: binary(), Ord :: non_neg_integer(), Score :: float()}]}`（分数降序；`Ord` 为内部文档序号）

**模式约束：** `search_text`/`search_phrase` 要求 Cask 以索引模式打开（bitcask.meta 中 `mode=kIndex`）。KV 模式返回 `{error, no_index}`。

**其它文本检索方式**（同为索引模式、返回 `{ok, [{Key, Ord, Score}]}`）：

| 函数 | 方式 |
|------|------|
| `search_fields(R, Query[, K])` | 多字段，`field:term^boost` 加权 |
| `search_near(R, Query, Slop[, K])` | 近邻：按序且间隙 ≤ Slop（Slop=0 即短语） |
| `search_fuzzy(R, Query, MaxEdit[, K])` | 模糊：Levenshtein 编辑距离 ≤ MaxEdit |
| `search_wildcard(R, Pattern[, K])` | 通配符 `*` / `?` |

同义词（v3.0.0）：open 时加 `{synonym_file, Path}`（每行逗号分隔一组），查询自动展开。

自动 compaction（v3.1.0，索引模式）：open 时加 `{auto_compact_dead_ratio, R}`
（`R ∈ (0.0, 1.0]`，默认 `0.0`=关）——reducer 线程内按 per-list 死占比自动压实 posting
list，churn 下内存有界，不再依赖 merge 才回收。

### 向量 / 混合检索（向量模式）

向量检索需索引模式 + 向量配置（open 配 `{embedder, {Provider, Cfg}}`，或低层 `{vector_dim, N}` + 自带向量）。`search_vector` 是纯向量近邻，`search_hybrid` 是 BM25 + 向量 RRF 融合。两者 arity 都是缺省项逐级展开。

```erlang
%% open 配 embedder（put #{text=>...} 与查询都自动 embed）
1> H = bitcask:open("/tmp/vec", [read_write, {analyzer, whitespace},
1>     {embedder, {openai, #{url => "http://localhost:8080/v1/embeddings",
1>                           model => <<"qwen3-embedding">>, dim => 2560}}}]).
2> bitcask:put(H, <<"d1">>, #{text => <<"a rapid brown fox">>}).

%% 纯向量近邻：search_vector(H, Query[, K[, Ef[, Filter]]])
3> bitcask:search_vector(H, {text, <<"fast animal">>}).        % 默认 K=10、Ef=0
3> bitcask:search_vector(H, VecBin, 20, 128).                  % 显式向量 + 调大 Ef 提召回
3> bitcask:search_vector(H, {text, <<"fast">>}, 10, 0,
3>     #{op => eq, field => <<"category">>, value => <<"tech">>}). % + meta filter

%% 混合 RRF：search_hybrid(H, Text[, VecOrAuto[, K[, Filter]]])
4> bitcask:search_hybrid(H, <<"fast brown animal">>).          % 全自动：文本既做 BM25 又 embed
4> bitcask:search_hybrid(H, <<"fast">>, MyVecBin, 10).         % 文本走 BM25、向量显式给
4> bitcask:search_hybrid(H, <<"fast">>, <<>>, 10).             % 单路退化：只 BM25
4> bitcask:search_hybrid(H, <<>>, MyVecBin, 10).               % 单路退化：只向量
5> bitcask:close(H).
```

- `Query`/向量位接受 `VecBin`（f32 LE，`vector_dim*4` 字节）或文本自动 embed（`search_vector` 传 `{text, Bin}`、`search_hybrid` 向量位传 `auto`），需 open 配 embedder。
- `K` 默认 10；`Ef` 默认 `max(K,64)`（越大越准越慢）；`Filter` 为结构化 meta 过滤。
- 详尽参数/arity 展开表见 [`doc/api-zh.md`](api-zh.md) 向量/混合检索节。

**独立 embedder 进程** — `{embedder, _}` 也接受一个 `bitcask_embedder_server`
进程。provider 状态归那个进程：多个 cask 共用一份，生命周期跟着进程走。
有状态 provider（尤其是下面的本地模型）应当走这条：

```erlang
%% 挂进自己的 supervision tree
1> Spec = bitcask_embedder_server:child_spec(my_emb, {local, my_emb},
1>     #{provider => {custom, bitcask_embedder_llama},
1>       config   => #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
1>                     pooling => last,   % Qwen3-Embedding 要 last；BERT/BGE 要 cls
1>                     n_ctx   => 512}}). % 性能旋钮，不只是长度上限
2> H1 = bitcask:open("/tmp/v1", [read_write, {analyzer, whitespace}, {embedder, my_emb}]).
3> H2 = bitcask:open("/tmp/v2", [read_write, {analyzer, whitespace}, {embedder, my_emb}]).
```

⚠️ `bitcask:close/1` **不会**释放 embedder；`{embedder, {Provider, Cfg}}` 那条是
每 open 一次建一份 ctx（本地模型 = 每次装一份权重）。长跑服务用进程形态。

**本地嵌入（不经 HTTP 端点，可选）** — 需 `BITCASK_WITH_LLAMA=1 rebar3 compile`
构建。这是另开一档不是替换 HTTP：换档 = 落库维度变了 = 全量重建索引，且 ggml 的
`abort()` 会带走整个 node。取舍、实测数字与排错见
[`doc/local-embedding-zh.md`](local-embedding-zh.md)。

向量引擎（v4.0.0）：open 时加 `{vector_engine, hnsw | ivfrq | diskann}`——
`hnsw`（默认，内存图，≤ 数 M 向量）、`ivfrq`（IVF-RaBitQ 磁盘档，10M-100M 推荐，
要求 cosine/dot）、`diskann`（实验性）。建库一次性选定并持久化，重开不符 →
`{error, mode_mismatch}`；调优选项（`vector_ivf_nlist`/`vector_ivf_nprobe`、
`hnsw_m`/`hnsw_ef_construction`/`hnsw_build_nav_int8`、`vector_rebase_min_docs`
等）见 [`doc/api-zh.md`](api-zh.md)。

### 流式 Fold

通过生产者/消费者模型进行流式迭代：

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> [bitcask:put(R, K, <<"v">>) || K <- [<<"a">>,<<"b">>,<<"c">>]].

%% 打开流
3> S = bitcask:stream(R).

%% 逐条拉取条目
4> bitcask:next(S).
{ok,<<"a">>,<<"v">>}
5> bitcask:next(S).
{ok,<<"b">>,<<"v">>}
6> bitcask:next(S).
{ok,<<"c">>,<<"v">>}
7> bitcask:next(S).
done

%% 停止流（消费者崩溃时也会自动清理）
8> bitcask:stop(S).

%% RAII 封装——退出时自动停止流
9> bitcask:with_stream(R, fun(S) ->
    loop(S, []).
end).

loop(S, Acc) ->
    case bitcask:next(S) of
        done         -> Acc;
        {ok, K, V}  -> loop(S, [{K,V}|Acc]);
        {error, E}  -> {error, E}
    end.
```

可以在同一个 `Ref` 上同时打开多个流——每个流持有独立的迭代器。

## 崩溃恢复

如果写入进程崩溃，下一次 `bitcask:open(D, [read_write])`
会检查 `bitcask.write.lock` 中记录的 PID。如果该进程已不再存活（`kill -0 PID` 返回 `ESRCH`），
旧的锁会被删除，打开操作成功。存活的拥有者保持锁定——第二次打开返回
`{error, write_locked}`。

```erlang
%% 进程 A：
1> R = bitcask:open("/tmp/db", [read_write]).
%% A 崩溃，write.lock 中留下 A 的 PID。

%% 进程 B（或 A 重启后）：
1> R = bitcask:open("/tmp/db", [read_write]).
#Ref<...>                       % 成功——回收了过期锁
```

如果锁文件为空（写入者在记录 PID 前崩溃），同样适用此逻辑。

## 合并：压缩碎片化文件

bitcask 采用仅追加模式，因此 `put`/`delete` 会累积死记录。**合并**
遍历碎片化文件，将活跃记录复制到新文件，并更新
keydir。

### 概念

文件的碎片度为 `(1 - live_keys / total_keys) * 100`。

### 触发阈值（满足任一）

仅当至少一个非活动文件超过以下**任一**阈值时，合并才会运行：

| Option                       | Default | 含义 |
|------------------------------|---------|---------|
| `frag_merge_trigger`         | `60`    | 碎片化百分比 |
| `dead_bytes_merge_trigger`   | `512 MB`| 死数据字节数 |
| `expiry_secs` + `expiry_grace_time` | 未设置 | 所有早于 `now - (expiry_secs + grace)` 的记录 |

### 单文件包含阈值（满足任一）

触发器触发后，每个文件会根据以下条件检查：

| Option                  | Default | 含义 |
|-------------------------|---------|---------|
| `frag_threshold`        | `40`    | 碎片化百分比 |
| `dead_bytes_threshold`  | `128 MB`| 死字节数 |
| `small_file_threshold`  | `10 MB` | 总大小低于此值的文件会被包含 |
| (`expiry_secs`)         | 未设置   | 整个文件已过期 |

### 配置阈值

三种方式，按优先级顺序：

```erlang
%% 1. open/2 选项（单个 Cask）
bitcask:open(D, [read_write,
                  {max_file_size,        1024},
                  {frag_merge_trigger,   50},
                  {frag_threshold,       50},
                  {dead_bytes_threshold, 1024}]).

%% 2. application env（进程级默认值）
application:set_env(bitcask, frag_merge_trigger, 50).
application:set_env(bitcask, frag_threshold,     50).

%% 3. C++ 默认值（上表）——均未设置时使用
```

完整的透传选项列表：
`max_file_size`, `max_read_handles`, `expiry_secs`, `frag_merge_trigger`,
`dead_bytes_merge_trigger`, `frag_threshold`, `dead_bytes_threshold`,
`small_file_threshold`, `expiry_grace_time`, `max_merge_size`。

> `{max_read_handles, N | unlimited}`（v3.1.0）：read 句柄缓存上限。默认 `0` =
> 按 `RLIMIT_NOFILE` 自动推导（不再是「不限」）；`unlimited` = 显式不限。

### 活跃写入者被排除

`needs_merge/1` 和 `merge` **始终跳过当前正在写入的文件**。
这符合遗留语义——合并活跃写入者会与正在进行的 `put` 产生竞争。
后果：如果所有内容都适合单个文件（即活跃写入者），无论多碎片化，
`needs_merge` 都会返回 `false`。

要在测试中强制轮转，降低 `max_file_size`：

```erlang
bitcask:open(D, [read_write, {max_file_size, 1024}]).
```

### 端到端演示

```erlang
%% 步骤 1：使用较小的 max_file_size 打开以强制轮转。
1> Dir = "/tmp/merge_demo".
2> R = bitcask:open(Dir, [read_write, {max_file_size, 1024}]).

%% 步骤 2：写入同一个键 100 次 → 99 个过期，1 个活跃。
3> [bitcask:put(R, <<"k">>, integer_to_binary(I)) || I <- lists:seq(1, 100)].

%% 步骤 3：检查文件数量和碎片化。
4> length(filelib:wildcard(filename:join(Dir, "*.bitcask.data"))).
%% 例如：3 个文件

5> bitcask:status(R).
%% {1, [{"...1.bitcask.data", 99, ..., ...},  % 99% 碎片化
%%      {"...2.bitcask.data", 99, ..., ...},
%%      {"...3.bitcask.data",  0, ..., ...}]} % 活跃写入者为 0%

%% 步骤 4：询问是否需要合并。
6> bitcask:needs_merge(R).
%% {true, {[file_paths_to_merge], [expired_paths]}}

%% 步骤 5：通过便捷封装触发合并
7> do_merge(R).
```

### 读取 `cask_merge` 结果

```erlang
{ok, {Seen, Kept, Stale, Tombs}}
```

| 字段   | 含义 |
|---------|---------|
| `Seen`  | 遍历所有输入文件的总记录数 |
| `Kept`  | 复制到新合并文件的记录数 |
| `Stale` | 跳过：keydir 指向别处（被覆盖或已删除） |
| `Tombs` | 跳过：源记录是墓碑标记 |

`Kept = 0, Stale > 0` 是**正常情况**，当所有活跃版本恰好都位于活跃写入者中——合并正确地跳过了再次写入它们。

### 为什么大量写入后 `needs_merge` 有时返回 `false`

如果写入 `N` 个键并对每个键覆盖一次（`put k v1; put k v2`），每个文件最终大约有一半死记录 → 每个文件约 50% 碎片化。默认的 `frag_merge_trigger` 是 `60%`，因此不会触发——这是**遗留行为**，不是 bug。

要强制触发：
- 对同一个键写入更多次（高碎片化），**或**
- 向 `open`/app env 传递 `{frag_merge_trigger, 50}`。

### 便捷封装

```erlang
do_merge(R) ->
    case bitcask:needs_merge(R) of
        false                     -> nothing_to_merge;
        {true, {Files, _Expired}} -> bitcask_cpp_nifs:cask_merge(R, Files)
    end.
```

成功执行 `cask_merge` 后，输入的 `.data` + `.hint` 文件会被删除，
它们在 keydir 中的 `fstats` 条目也会被修剪，因此磁盘使用量立即下降，
`bitcask:status/1` 也会反映新状态。

### 已知限制

| 限制 | 解决方案 |
|------------|------------|
| `search_text`/`search_phrase` 仅在索引模式下可用（bitcask.meta 中 `mode=kIndex`） | 使用 `{analyzer, ...}` 打开以启用 |
| 源文件上没有 tombstone-v2 反向标记 | 仅支持单进程工作负载；不支持多进程读取者 |

## 过期

```erlang
%% 早于 60 秒的记录对 get/list_keys/fold 不可见。
1> R = bitcask:open(Dir, [read_write, {expiry_secs, 60}]).
2> bitcask:put(R, <<"k">>, <<"v">>).
3> timer:sleep(61000).
4> bitcask:get(R, <<"k">>).                       not_found
```

`expiry_secs` 也通过 `expiry_grace_time` 传递给合并触发器——
一旦整个文件超过 `now - (expiry_secs + grace)`，它就会被排队进行合并，
从而可以回收存储空间。

## 直接使用 cask_* NIF（绕过门面）

`bitcask` 门面是受支持的用户 API。如果需要原始 NIF 用于微基准测试或测试：

```erlang
{ok, R} = bitcask_cpp_nifs:cask_open(Dir, [read_write]).
ok      = bitcask_cpp_nifs:cask_put(R, K, V).
{ok, V} = bitcask_cpp_nifs:cask_get(R, K).

%% 通过三步迭代器进行 Fold。
{ok, IR}        = bitcask_cpp_nifs:cask_fold_start(R, -1, -1).
{ok, K, V}      = bitcask_cpp_nifs:cask_fold_next(IR).        % 或 `done`
ok              = bitcask_cpp_nifs:cask_fold_release(IR).

%% 搜索（仅索引模式；结果为 {Key, Ord, Score} 三元组）
{ok, [{K,Ord,S}]} = bitcask_cpp_nifs:cask_search_text(R, <<"query">>, 10).
{ok, [{K,Ord,S}]} = bitcask_cpp_nifs:cask_search_phrase(R, <<"query">>, 10).

ok = bitcask_cpp_nifs:cask_close(R).
```

### 可用的 cask_* NIF

| NIF | 说明 |
|-----|-------------|
| `cask_open/2` | 打开 cask |
| `cask_close/1` | 关闭并释放资源 |
| `cask_get/2` | 读取键 |
| `cask_put/3` | 写入键/值 |
| `cask_delete/2` | 软删除键 |
| `cask_sync/1` | fsync 活动数据文件 |
| `cask_close_write_file/1` | 释放写入锁，保持句柄可用 |
| `cask_search_text/3` | BM25 词袋搜索（仅索引模式） |
| `cask_search_phrase/3` | BM25 短语搜索（仅索引模式） |
| `cask_fold_start/3,4` | 开始迭代 |
| `cask_fold_next/1` | 下一条目（K, V） |
| `cask_fold_next_full/1` | 下一条目（K, V, FileId, Offset, Sz, Tstamp, IsTomb） |
| `cask_fold_release/1` | 释放迭代器 |
| `cask_is_empty/1` | O(1) 空估计 |
| `cask_is_frozen/1` | Keydir 冻结状态 |
| `cask_status/1` | `{KeyCount, Files}` |
| `cask_needs_merge/1` | `{true, {Files, Expired}}` 或 `false` |
| `cask_merge/2` | 对指定文件运行合并 |

## 常见错误

| 返回 | 原因 | 修复 |
|--------|-------|-----|
| `{error, write_locked}` | 活跃写入者持有锁 | 关闭之前的 cask，或选择另一个目录 |
| `not_found`             | 键从未存在 / 已删除 / 已过期 | 正常 |
| `{error, bad_crc}`      | 读取时磁盘损坏 | 从备份恢复；合并会跳过这些 |
| `{error, key_too_large}` | 键 > 65 535 字节 | 格式限制；不可配置 |
| `{error, value_too_large}` | 值 > 4 GiB | 格式限制 |
| `{error, no_index}`     | 在 KV 模式 Cask 上调用搜索 | 使用 `{analyzer, ...}` 重新打开 |