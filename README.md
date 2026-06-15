# Bitcask — 日志结构哈希表，支持 BM25 全文检索与 HNSW 向量近邻搜索

[![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

[English](README_EN.md)

Bitcask 是一个日志结构（log-structured）的哈希表键值存储引擎，使用 C++23 实现，
通过 Erlang NIF 接口对外暴露。磁盘格式采用带类型记录（`kDoc`/`kTombstone`）与
逐次写入序号（ordinal），可选 DocValue 编码（text + vector + metadata）。

主要特性：BM25 全文检索、HNSW 近似最近邻向量搜索、RRF 混合检索（融合文本与向量
两路排序信号）。

实现为单一 C++23 NIF（`cpp/`）+ 薄 Erlang 门面（`src/bitcask.erl`），所有操作经由
`bitcask_cpp_nifs` → `priv/bitcask_cpp.so`。

## 构建

### rebar3（Erlang + C++ NIF）

```sh
rebar3 compile        # 编译 priv/bitcask_cpp.so
rebar3 eunit          # Erlang/NIF 测试 (eunit)
rebar3 do xref, dialyzer
```

要求 Erlang ≥ 22.0。

### CMake（C++ 测试 + 基准）

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure   # 400+ GoogleTests
```

Sanitizer（一次只能开一种——ASan 和 TSan 互斥）：

```sh
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON
```

基准（仅 Release）：

```sh
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench
```

## 快速上手（`rebar3 shell`）

编译 NIF 并进入 Erlang shell：

```sh
rebar3 shell        # 先编译，再启动 REPL
```

**键值模式** — 纯二进制值：

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).   % 返回 {CaskRef, EmbedderCtx}
{#Ref<0.1234.5678.90>,undefined}
2> bitcask:put(R, <<"k">>, <<"hello">>).
ok
3> bitcask:get(R, <<"k">>).
{ok,<<"hello">>}
4> bitcask:close(R).
ok
```

**BM25 全文检索** — 用 `{analyzer, ...}` 打开即可启用。每次 `put` 自动索引；
返回 `{ok, [{Key, Ord, Score}, ...]}`，按分数降序：

```erlang
%% 分析器: whitespace（英文） | ngram（CJK n-gram） | jieba（中文分词）
1> R = bitcask:open("/tmp/idx", [read_write, {analyzer, whitespace}]).
{#Ref<0.9876.5432.10>,undefined}
2> bitcask:put(R, <<"d1">>, <<"the quick brown fox">>).
ok
3> bitcask:put(R, <<"d2">>, <<"a lazy brown dog">>).
ok
4> bitcask:search_text(R, <<"brown">>).               % 两篇都命中
{ok,[{<<"d2">>,1,0.18232},{<<"d1">>,0,0.18232}]}
5> bitcask:search_phrase(R, <<"quick brown">>).       % 仅 d1 有相邻短语
{ok,[{<<"d1">>,0,0.69315}]}
6> bitcask:search_fuzzy(R, <<"quikc">>, 2).           % 拼写错误，编辑距离 ≤ 2
{ok,[{<<"d1">>,0,0.69315}]}
7> bitcask:search_wildcard(R, <<"fox*">>).            % 前缀通配符
{ok,[{<<"d1">>,0,0.69315}]}
8> bitcask:close(R).
ok
```

> 在**未指定分析器**的 cask 上调用任何 `search_*` 函数将返回 `{error, no_index}`。

**HNSW 向量搜索** — 向量搜索需索引模式（`{analyzer, ...}`）。**推荐流程：open
时把 embedder 作为 `{Provider, Cfg}` 传入，open 内部建 ctx 并自动把集合维度设为
embedder 的 `vector_dim`——无需外部 `new`、也无需单独写 `{vector_dim, N}`。** 之后
`put #{text => ...}` / 查询都自动 embed。`open` 返回 `{CaskRef, EmbedderCtx}`
元组，整体当 Handle 传给后续调用：

```erlang
%% 1) open 直接配 embedder（Provider = openai | anthropic | {custom,Mod}）。
%%    OpenAI 兼容端点，如 llama.cpp server / vLLM。
1> H = bitcask:open("/tmp/vec", [read_write, {analyzer, whitespace},
1>     {embedder, {openai, #{
1>         url => "http://localhost:8080/v1/embeddings",
1>         model => <<"qwen3-embedding">>,
1>         dim => 2560,                    % 模型原生维度
1>         vector_dim => 1024,             % 可选 MRL 截断维度（≤dim；缺省=dim）
1>         max_input_bytes => 32768,       % 可选（默认 32768）
1>         timeout_ms => 30000,            % 可选（默认 30000）
1>         connect_timeout_ms => 5000}}]). % 可选（默认 5000）
{#Ref<0.1.2.3>, #{module => bitcask_embedder_openai, dim => 2560,
                  vector_dim => 1024, config => #{...}}}
%% 2) put 只给 text → 自动 embed 入库
2> bitcask:put(H, <<"d1">>, #{text => <<"the quick brown fox">>}).
ok
%% 3) 混合检索：向量位省略 / 传 auto → 用句柄 embedder 自动 embed 查询文本
3> bitcask:search_hybrid(H, <<"fast brown animal">>).
{ok,[{<<"d1">>,0,0.0328}]}
%% 4) 纯向量检索：查询传 {text, _} → 自动 embed（分数为 cosine 相似度，示意）
4> bitcask:search_vector(H, {text, <<"fast brown animal">>}).
{ok,[{<<"d1">>,0,0.83}]}
%% 5) 需要原始向量时用 embed/2 门面
5> {ok, Q} = bitcask:embed(H, <<"fast brown animal">>).
6> bitcask:close(H).
ok
```

> **MRL（Matryoshka）**：`dim` 永远是模型原生维度；`vector_dim` 是 MRL 截断后的
> 落库/检索维度（≤ dim，缺省 = dim）。二者不一致时 embed 请求自动带
> `dimensions => vector_dim`，由服务端按 MRL 截断+重归一（端点需支持）。
>
> **低层路径（不用 embedder）**：open 省略 `embedder`、改写 `{vector_dim, N}`；`put`
> 用 `#{text => T, vector => V}` 自带 f32 小端序向量
> （`V = << <<X:32/float-little>> || X <- Floats >>`），查询传向量二进制。
> 例如 `vector_dim=4`、库里 `[1,0,0,0]`、查 `[0.9,0.1,0,0]` →
> `search_vector(H, V)` 返回 `{ok,[{<<"d1">>,0,0.99388}]}`（cosine = 0.9/√0.82）。

## API 概览

| 函数 | 说明 |
|------|------|
| `open/1,2` | 打开 cask（KV 模式或通过 `{analyzer, ...}` 启用索引模式） |
| `get/2`, `put/3`, `delete/2`, `sync/1` | 核心 KV 操作 |
| `fold/3,6`, `fold_keys/3,6`, `list_keys/1` | 迭代 |
| `stream/1`, `next/1`, `stop/1`, `with_stream/2` | 流式迭代 |
| `merge/1,2,3`, `needs_merge/1,2`, `status/1` | 合并管理 |
| `search_text/2,3`, `search_phrase/2,3`, `search_fields/2,3` | BM25 检索（全文 / 短语 / `field:term^boost`） |
| `search_near/3,4`, `search_fuzzy/3,4`, `search_wildcard/2,3` | 近邻 / 模糊（编辑距离）/ 通配符搜索 |
| `search_vector/2,3,4,5`, `search_hybrid/2,3,4,5` | HNSW 向量近邻 / RRF 混合检索（BM25 + 向量）；查询传 `{text,_}`（vector）或 `auto`（hybrid）自动 embed；`/5` 末参为 meta filter |
| `embed/2` | 用句柄 embedder 把文本编码成向量（`{ok, Vec}`/`{error, no_embedder}`） |
| `set_synonym_map/2` | 加载同义词词典 |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | 工具函数 |

## 文档

| 文件 | 内容 |
|------|------|
| `doc/api-zh.md` / `doc/api-en.md` | **API 参考**：能力、参数含义与限制、返回值（中/英） |
| `doc/USAGE.md` | 教程：打开、合并、配置、搜索 |
| `doc/format-zh.md` | 磁盘格式字节级规范（带类型记录、DocValue、提示文件、锁） |
| `doc/cpp-arch.md` | C++ 模块布局、锁策略、构建入口 |
| `doc/migration.md` | 特性状态与 API 参考 |
| `doc/concurrency-zh.md` | 并发与共享语义 |
| `doc/put-flow-zh.md` | put(K,V) 完整调用链 |
| `doc/vector-db-design-zh.md` | 向量库设计方案（V1–V6 蓝图） |
| `doc/vector-search-extension-zh.md` | 向量搜索扩展：HNSW + RRF 混合检索 |
| `doc/hnsw-design-zh.md` | HNSW 向量索引设计（并发/持久化/RRF/实施表） |
| `doc/keydir-sharding-design-zh.md` | KeyDir 分片并发 + 屏障 v2 写者闸门 |
| `doc/unified-architecture-plan-zh.md` | 统一架构计划（已实施） |
| `TASK.md` | 项目路线图 |

## 项目状态

- **C++ NIF** 覆盖全部核心 KV 操作（`get`/`put`/`delete`/`sync`/`fold`/`merge`）
- **BM25 全文检索** — 文本 / 短语 / 多字段 / 近邻 / 模糊 / 通配符，外加同义词与高亮
- **HNSW 向量检索** — 近似最近邻搜索，支持 cosine / L2 / dot 距离度量，per-node 锁实现并发读，BCVS 快照持久化，merge 重建物理清死
- **RRF 混合检索** — 经 Reciprocal Rank Fusion 融合 BM25 与 HNSW（`score = Σ 1/(60+rank)`）
- **Embedder behaviour** — `bitcask_embedder` 回调 + OpenAI 兼容参考实现
- **Jieba 中文分析器** 已集成（whitespace / ngram / jieba）
- **带类型记录格式**（`kDoc`/`kTombstone` + 逐次写入序号）为默认格式
- **统一架构** — Cask 与 Collection 已合并为单一引擎，按配置（`{analyzer, ...}`）启用 KV 或索引模式
- **并发加固**（2026-06 审计）— 索引读路径与异步索引 worker 并发安全：`meta_blob`/搜索缓存锁内拷贝不逃逸、倒排索引快照安全遍历、跨线程标量原子化、IndexPool 消费者异常兜底；详见 [`doc/concurrency-zh.md` §6](doc/concurrency-zh.md)

## 许可证

Apache 2.0；详见 `LICENSE`。
