# Bitcask — A Log-Structured Hash Table for Fast Key/Value Data with BM25 Full-Text Search & HNSW Vector Retrieval

[中文](README.md) | [![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

Bitcask is a log-structured hash table for fast key/value data, written in C++23
with an Erlang NIF interface. On-disk format uses typed records (`kDoc`/`kTombstone`)
with per-write ordinal numbers and optional DocValue encoding (text + vector + metadata).

Features include BM25 full-text search, HNSW approximate nearest-neighbor vector
retrieval, and RRF hybrid search that fuses both ranking signals.

The implementation is a single C++23 NIF (`cpp/`) with a thin Erlang facade (`src/bitcask.erl`).
All operations go through `bitcask_cpp_nifs` → `priv/bitcask_cpp.so`.

## Build

### rebar3 (Erlang + C++ NIF)

```sh
rebar3 compile        # builds priv/bitcask_cpp.so
rebar3 eunit          # Erlang/NIF tests (eunit)
rebar3 do xref, dialyzer
```

Erlang ≥ 22.0 required.

### CMake (C++ tests + benchmarks)

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure   # 400+ GoogleTests
```

Sanitizers (one at a time — ASan and TSan are mutually exclusive):

```sh
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON
```

Benchmarks (release only):

```sh
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench
```

## Quick start (`rebar3 shell`)

Build the NIF and drop into an Erlang shell with the app on the path:

```sh
rebar3 shell        # runs `rebar3 compile` first, then starts the REPL
```

**Key/value mode** — plain binary values:

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).   % returns {CaskRef, EmbedderCtx}
{#Ref<0.1234.5678.90>,undefined}
2> bitcask:put(R, <<"k">>, <<"hello">>).
ok
3> bitcask:get(R, <<"k">>).
{ok,<<"hello">>}
4> bitcask:close(R).
ok
```

**BM25 full-text search** — open with `{analyzer, ...}` to enable. Each `put`
indexes the value; results are `{ok, [{Key, Ord, Score}, ...]}` sorted by score:

```erlang
%% analyzer: whitespace (English) | ngram (CJK n-gram) | jieba (Chinese segmentation)
1> R = bitcask:open("/tmp/idx", [read_write, {analyzer, whitespace}]).
{#Ref<0.9876.5432.10>,undefined}
2> bitcask:put(R, <<"d1">>, <<"the quick brown fox">>).
ok
3> bitcask:put(R, <<"d2">>, <<"a lazy brown dog">>).
ok
4> bitcask:search_text(R, <<"brown">>).               % both match
{ok,[{<<"d2">>,1,0.18232},{<<"d1">>,0,0.18232}]}
5> bitcask:search_phrase(R, <<"quick brown">>).       % only d1 has them adjacent
{ok,[{<<"d1">>,0,0.69315}]}
6> bitcask:search_fuzzy(R, <<"quikc">>, 2).           % typo, edit distance ≤ 2
{ok,[{<<"d1">>,0,0.69315}]}
7> bitcask:search_wildcard(R, <<"fox*">>).            % prefix wildcard
{ok,[{<<"d1">>,0,0.69315}]}
8> bitcask:close(R).
ok
```

> Calling any `search_*` on a cask opened **without** an analyzer returns
> `{error, no_index}`.

**HNSW vector search** — requires index mode (`{analyzer, ...}`). **Recommended
flow: pass the embedder as `{Provider, Cfg}` at open time; open builds the ctx
internally and auto-sets the collection dimension to the embedder's `vector_dim`
— no external `new`, no separate `{vector_dim, N}`.** Then `put #{text => ...}`
and queries auto-embed. `open` returns a `{CaskRef, EmbedderCtx}` tuple; pass it
as the handle:

```erlang
%% 1) Configure the embedder directly at open (Provider = openai|anthropic|{custom,Mod}).
%%    OpenAI-compatible endpoint, e.g. llama.cpp server / vLLM.
1> H = bitcask:open("/tmp/vec", [read_write, {analyzer, whitespace},
1>     {embedder, {openai, #{
1>         url => "http://localhost:8080/v1/embeddings",
1>         model => <<"qwen3-embedding">>,
1>         dim => 2560,                    % model's native dimension
1>         vector_dim => 1024,             % optional MRL truncation (<=dim; default=dim)
1>         max_input_bytes => 32768,       % optional (default 32768)
1>         timeout_ms => 30000,            % optional (default 30000)
1>         connect_timeout_ms => 5000}}]). % optional (default 5000)
{#Ref<0.1.2.3>, #{module => bitcask_embedder_openai, dim => 2560,
                  vector_dim => 1024, config => #{...}}}
%% 2) put with just text → auto-embed on write
2> bitcask:put(H, <<"d1">>, #{text => <<"the quick brown fox">>}).
ok
%% 3) hybrid: omit the vector / pass auto → the handle's embedder embeds the query text
3> bitcask:search_hybrid(H, <<"fast brown animal">>).
{ok,[{<<"d1">>,0,0.0328}]}
%% 4) pure vector: pass {text, _} as the query → auto-embed (score is cosine sim, illustrative)
4> bitcask:search_vector(H, {text, <<"fast brown animal">>}).
{ok,[{<<"d1">>,0,0.83}]}
%% 5) use the embed/2 facade when you need the raw vector
5> {ok, Q} = bitcask:embed(H, <<"fast brown animal">>).
6> bitcask:close(H).
ok
```

> **MRL (Matryoshka)**: `dim` is always the model's native dimension; `vector_dim`
> is the MRL-truncated stored/query dimension (≤ dim, default = dim). When they
> differ, the embed request automatically carries `dimensions => vector_dim` so the
> server truncates + renormalizes per MRL (endpoint must support it).
>
> **Low-level path (no embedder)**: omit `embedder`, pass `{vector_dim, N}` instead;
> `put` with `#{text => T, vector => V}` carrying your own f32 little-endian vector
> (`V = << <<X:32/float-little>> || X <- Floats >>`), and pass a vector binary as the
> query. E.g. `vector_dim=4`, doc `[1,0,0,0]`, query `[0.9,0.1,0,0]` →
> `search_vector(H, V)` returns `{ok,[{<<"d1">>,0,0.99388}]}` (cosine = 0.9/√0.82).

## API highlights

| Function | Description |
|----------|-------------|
| `open/1,2` | Open a cask (KV mode or search mode via `{analyzer, ...}`) |
| `get/2`, `put/3`, `delete/2`, `sync/1` | Core KV operations |
| `fold/3,6`, `fold_keys/3,6`, `list_keys/1` | Iteration |
| `stream/1`, `next/1`, `stop/1`, `with_stream/2` | Streaming iteration |
| `merge/1,2,3`, `needs_merge/1,2`, `status/1` | Merge management |
| `search_text/2,3`, `search_phrase/2,3`, `search_fields/2,3` | BM25 search (full-text / phrase / `field:term^boost`) |
| `search_near/3,4`, `search_fuzzy/3,4`, `search_wildcard/2,3` | Proximity / fuzzy (edit-distance) / wildcard search |
| `search_vector/2,3,4,5`, `search_hybrid/2,3,4,5` | HNSW vector NN / RRF hybrid (BM25+vector); pass `{text,_}` (vector) or `auto` (hybrid) to auto-embed the query; `/5` takes a trailing meta filter |
| `embed/2` | Encode text to a vector via the handle's embedder (`{ok, Vec}`/`{error, no_embedder}`) |
| `set_synonym_map/2` | Load a synonym dictionary |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | Utilities |

## Documentation

| File | What it covers |
|------|----------------|
| `doc/api-en.md` / `doc/api-zh.md` | **API reference**: capabilities, parameter meaning & constraints, return values (EN/中) |
| `doc/USAGE.md` | Tutorial: opening, merging, configuring, searching |
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
| `TASK.md` | Project roadmap |

## Project status

- **C++ NIF** covers all core KV operations (`get`/`put`/`delete`/`sync`/`fold`/`merge`)
- **BM25 full-text search** — text / phrase / fields / proximity / fuzzy / wildcard, plus synonyms and snippet highlighting
- **HNSW vector retrieval** — approximate nearest-neighbor search with configurable metric (cosine / L2 / dot), per-node locking for concurrent reads, BCVS snapshot persistence, and merge rebuild for dead-node eviction
- **RRF hybrid search** — fuses BM25 and HNSW via Reciprocal Rank Fusion (`score = Σ 1/(60+rank)`)
- **Embedder behaviour** — `bitcask_embedder` callback with OpenAI-compatible reference implementation
- **Jieba Chinese analyzer** integrated (whitespace / n-gram / jieba)
- **Typed record format** (`kDoc`/`kTombstone` with per-write ordinal) is the default
- **Unified architecture** — Cask and Collection are merged into a single engine; KV vs. index mode selected via `{analyzer, ...}` option
- **Concurrency hardening** (2026-06 audit) — search read path is safe against the async index worker: `meta_blob`/search-cache copy under lock without escaping pointers, inverted-index snapshot uses safe iteration, cross-thread scalars are atomic, IndexPool consumer is exception-safe; see [`doc/concurrency-zh.md` §6](doc/concurrency-zh.md)

## License

Apache 2.0; see `LICENSE`.