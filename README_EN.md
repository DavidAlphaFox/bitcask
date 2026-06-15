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
1> R = bitcask:open("/tmp/db", [read_write]).
#Ref<0.1234.5678.90>
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
#Ref<0.9876.5432.10>
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

**HNSW vector search** — vector search requires index mode; open with
`{analyzer, ...}` + `{vector_dim, N}` (optional `{vector_metric, cosine|l2|dot}`,
default `cosine`). Vectors are f32 little-endian binaries
(`<< <<X:32/float-little>> || X <- Floats >>`):

```erlang
1> R = bitcask:open("/tmp/vec", [read_write,
1>     {analyzer, whitespace}, {vector_dim, 4}]).
2> Vec = << <<X:32/float-little>> || X <- [1.0, 0.0, 0.0, 0.0] >>.
3> bitcask:put(R, <<"d1">>, #{text => <<"hello">>, vector => Vec}).
ok
4> Q = << <<X:32/float-little>> || X <- [0.9, 0.1, 0.0, 0.0] >>.
5> bitcask:search_vector(R, Q).          % top-K nearest neighbors (cosine similarity)
{ok,[{<<"d1">>,0,0.99388}]}
6> bitcask:close(R).
ok
```

**Hybrid search (BM25 + Vector RRF)** — combines text and vector relevance:

```erlang
1> bitcask:search_hybrid(R, <<"hello">>, Q).   % RRF fusion, k=10
{ok,[...]}
```

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
| `search_vector/2,3,4,5`, `search_hybrid/3,4,5` | HNSW vector nearest-neighbor / RRF hybrid (BM25+vector); `/5` takes a trailing meta filter |
| `set_synonym_map/2` | Load a synonym dictionary |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | Utilities |

## Documentation

| File | What it covers |
|------|----------------|
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