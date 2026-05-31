# Bitcask — A Log-Structured Hash Table for Fast Key/Value Data with BM25 Full-Text Search

[![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

Bitcask is a log-structured hash table for fast key/value data, written in C++23
with an Erlang NIF interface. On-disk format uses typed records (`kDoc`/`kTombstone`)
with per-write ordinal numbers and optional DocValue encoding (text + vector + metadata).

The implementation is a single C++23 NIF (`cpp/`) with a thin Erlang facade (`src/bitcask.erl`).
All operations go through `bitcask_cpp_nifs` → `priv/bitcask_cpp.so`.

## Build

### rebar3 (Erlang + C++ NIF)

```sh
rebar3 compile        # builds priv/bitcask_cpp.so
rebar3 as test eunit  # 90+ Erlang tests
rebar3 do xref, dialyzer
```

Erlang ≥ 22.0 required.

### CMake (C++ tests + benchmarks)

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure   # ~167 GoogleTests
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

## Quick example

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> bitcask:put(R, <<"k">>, <<"hello">>).
ok
3> bitcask:get(R, <<"k">>).
{ok, <<"hello">>}
4> bitcask:close(R).
ok
```

**BM25 full-text search** (open with an analyzer to enable):

```erlang
1> R = bitcask:open("/tmp/db", [read_write, {analyzer, whitespace}]).
2> bitcask:put(R, <<"d1">>, <<"hello world">>).
3> bitcask:put(R, <<"d2">>, <<"hello bitcask">>).
4> bitcask:search_text(R, <<"hello">>, 10).
{ok,[{<<"d1">>,14.2},{<<"d2">>,14.2}]}
5> bitcask:close(R).
```

## API highlights

| Function | Description |
|----------|-------------|
| `open/1,2` | Open a cask (KV mode or search mode via `{analyzer, ...}`) |
| `get/2`, `put/3`, `delete/2`, `sync/1` | Core KV operations |
| `fold/3,6`, `fold_keys/3,6`, `list_keys/1` | Iteration |
| `stream/1`, `next/1`, `stop/1`, `with_stream/2` | Streaming iteration |
| `merge/1,2,3`, `needs_merge/1,2`, `status/1` | Merge management |
| `search_text/2,3`, `search_phrase/2,3` | BM25 full-text search |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | Utilities |

## Documentation

| File | What it covers |
|------|----------------|
| `doc/USAGE.md` | Tutorial: opening, merging, configuring, searching |
| `doc/format.md` | On-disk byte-level spec (typed records, DocValue, hints, locks) |
| `doc/cpp-arch.md` | C++ module layout, locking, build entry points |
| `doc/migration.md` | Feature status and API reference |
| `doc/format-zh.md` | 磁盘格式（中文） |
| `doc/concurrency-zh.md` | 并发与共享语义 |
| `doc/put-flow-zh.md` | put(K,V) 完整调用链 |
| `doc/collection-fulltext-zh.md` | Collection 全文索引使用与内部机制 |
| `doc/vector-db-design-zh.md` | 向量库设计方案 |
| `doc/vector-graph-db-zh.md` | 向量库/图库可行性分析 |
| `doc/unified-architecture-plan-zh.md` | 统一架构计划 |
| `TASK.md` | Project roadmap (V1–V2.10 done, U0–U6 planned) |

## Project status

- **C++ NIF** covers all core KV operations (`get`/`put`/`delete`/`sync`/`fold`/`merge`)
- **BM25 full-text search** is operational (`search_text`/`search_phrase`)
- **Jieba Chinese analyzer** integrated
- **Typed record format** (`kDoc`/`kTombstone` with per-write ordinal) is the default
- **Unified architecture** (merging Cask + Collection) is planned — see `TASK.md` (U0–U6)

## License

Apache 2.0; see `LICENSE`.