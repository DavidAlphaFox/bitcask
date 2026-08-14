# Bitcask — A Log-Structured Hash Table for Fast Key/Value Data with BM25 Full-Text Search & Vector Retrieval

[中文](README.md) | [![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

📖 **API reference**: [English](doc/api-en.md) · [中文](doc/api-zh.md) · 📝 [Changelog](CHANGELOG_EN.md) · 🗺️ [Roadmap](ROADMAP_EN.md)

Bitcask is a log-structured hash table for fast key/value data, written in C++23
with an Erlang NIF interface. On-disk format uses typed records (`kDoc`/`kTombstone`)
with per-write ordinal numbers and optional DocValue encoding (text + vector + metadata).

Features include BM25 full-text search, approximate nearest-neighbor vector
retrieval (three selectable engines: `hnsw` in-memory graph / `ivfrq` disk tier /
`diskann` experimental), and RRF hybrid search that fuses both ranking signals.

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

Optional local embedding backend (llama.cpp), **off by default**:

```sh
BITCASK_WITH_LLAMA=1 rebar3 compile   # + priv/bitcask_llama.so and the vendored ggml/llama libs
```

Leaving it off keeps the build byte-for-byte as it was before that backend
existed: no submodule fetch, no CMake flag, no extra target. See
[doc/local-embedding-en.md](doc/local-embedding-en.md).

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

**Ordered range queries** (6.0.0) — walk `[Lo, Hi)` in key lexicographic order at
O(range) cost instead of filtering the whole table. Either bound may be
`undefined` for unbounded:

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> [bitcask:put(R, <<"user:", (integer_to_binary(N))/binary>>, <<"v">>)
    || N <- lists:seq(1, 3)].
3> bitcask:range(R, {<<"user:">>, <<"user;">>}).     % prefix scan: `;` is the byte after `:`
[{<<"user:1">>,<<"v">>},{<<"user:2">>,<<"v">>},{<<"user:3">>,<<"v">>}]
4> bitcask:range_fold(R, {<<"user:">>, undefined}, [{prefetch, 64}],
                      fun(K, _V, _T, _O, Acc) -> [K | Acc] end, []).
[<<"user:3">>,<<"user:2">>,<<"user:1">>]
```

> ⚠️ Ranges are **per-key weakly consistent** (writes concurrent with the
> iteration may be partially visible) — this is not `fold/3`'s snapshot
> semantics. Keep using `fold` when you need a snapshot.
> When the OKI is unavailable the cause is split across two codes: a read-only /
> `merge_only` open of a directory that never built one → `{error, no_index}`
> (reopen read-write and it builds); a writable open whose rebuild failed →
> `{error, index_rebuild_failed}` (IO/environment problem — **the data is there,
> only the index is missing**).

**Atomic batches and multi-key transactions** (6.0.0) — after a crash or power
loss, the batch either fully applies or does not apply at all:

```erlang
1> bitcask:put_batch_atomic(R, [{put, <<"a">>, <<"1">>},
                                {put, <<"b">>, <<"2">>},
                                {remove, <<"old">>}]).
ok
2> bitcask:txn_commit(R, [{put, <<"x">>, <<"1">>}, {put, <<"y">>, <<"2">>}]).
ok
3> bitcask:txn_commit(R, [{put, <<"d">>, <<"1">>}, {put, <<"d">>, <<"2">>}]).
{error,{invalid_option,<<"txn: duplicate key in ops">>}}      % zero side effects
```

> `txn_commit` adds validation on top of `put_batch_atomic` (non-empty, non-empty
> keys, no duplicates, no `_txn:` prefix); its optional third argument is
> `sync_on_commit` (default) or `no_sync`.
> ⚠️ Neither provides **isolation or CAS** — intermediate state is visible to
> concurrent readers, and concurrent commits with overlapping key sets must be
> serialized by the application. ⚠️ **The first call lazily upgrades the
> directory's meta to v6**, after which readers older than upstream 5.1.0 cannot
> open it.

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

> **Synonyms** (v3.0.0): pass `{synonym_file, Path}` at open (one comma-separated
> synonym group per line); queries expand automatically. It is an open-time immutable
> config (replacing the removed runtime `set_synonym_map/2`) — swapping dictionaries
> at runtime requires reopening the database.

**Vector search** — requires index mode (`{analyzer, ...}`); the engine defaults to
`hnsw`, add `{vector_engine, ivfrq | diskann}` at open for a disk tier (fixed at
creation, not switchable at runtime). **Recommended
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

> **Two tiers of embedder**: the HTTP tier (`openai` / `anthropic`) is stateless and
> wants concurrency — just write `{embedder, {openai, Cfg}}`, **no process to
> configure**. The built-in tier (the local model below) is stateful and must be
> serialized, so it runs in a `bitcask_embedder_server` process: configure
> `{embedder, #{name, provider, config}}` in the application env, `bitcask_sup`
> starts it, and casks refer to it as `{embedder, my_embedder}`. **All casks share
> one copy of the weights** and the lifecycle follows the process (`terminate/2`
> releases it — `bitcask:close/1` does **not**).
> ⚠️ If it is configured but fails to start (bad GGUF path, pooling resolving to
> NONE, …) the **whole bitcask application fails to start**, on purpose: silently
> degrading to "no embeddings" is far more dangerous than dying, since you would
> only notice once the search results are wrong and the store is already dirty.
> `bitcask:open/2` surfaces this as `{error, {bitcask_app_start_failed, _}}`.
> Logic shared by both tiers (input truncation, dimension validation, MRL) lives in
> `bitcask_embedder_util`.

> **Local embedding (optional, not built by default)**: `{custom,
> bitcask_embedder_llama}` computes embeddings in-process via llama.cpp, with no
> HTTP endpoint. Enable with `BITCASK_WITH_LLAMA=1 rebar3 compile`; it produces a
> **second, independent NIF** (`priv/bitcask_llama.so` plus a set of vendored
> ggml/llama shared libraries) and leaves the core `bitcask_cpp.so` untouched.
> ⚠️ This is **a different tier, not a replacement** for the HTTP endpoint: what
> runs on CPU is the 0.6B/1024-dim class, so switching tiers changes the stored
> dimension and means a full index rebuild — and ggml's `abort()` takes the whole
> node down with it. Trade-offs, measured numbers (35 ms per query; oversubscribing
> `n_threads` costs 20×) and troubleshooting are in
> [doc/local-embedding-en.md](doc/local-embedding-en.md).

> **GPU (NVIDIA CUDA / Vulkan)**: **build time probes the SDK, run time probes the
> GPU** — different machines, so they are done separately. Both build switches
> default to `AUTO` (`BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN`); at run time
> Erlang picks CUDA > Vulkan > CPU by itself (`backend => auto`), with **no
> per-machine configuration and no script**.
> ⚠️ On a multi-GPU box **only one card is used by default**: splitting an
> embedding model's layers across cards is a pessimization; what you want is data
> parallelism — N embedder processes each bound to a card (`gpu_index`).
> Previously: defaults to `AUTO` — compiled in whenever the build
> machine has a CUDA Toolkit (`BITCASK_LLAMA_CUDA=AUTO|ON|OFF`). Use `ON` for
> release builds; AUTO **silently** produces a CPU-only package on a machine
> without a toolkit. The CUDA runtime (cudart/cublas/cublasLt) is flattened into
> `priv/` by default — size is not a constraint, and it removes the whole "target
> is missing libcublas → ggml silently skips the backend → degrades to CPU" class
> of failure. Run `scripts/detect-llama-backends.sh` first to probe the
> environment and verify what the runtime actually enumerates (`--build` asks about
> the SDK, `--runtime` about the GPU; the two halves can run on different machines).
> The build-time answer is baked into the .so, and `bitcask_llama_nifs:gpu_status()`
> reconciles it with the runtime — looking only at run time, "0 GPUs" cannot
> distinguish "no CUDA in the package" (rebuild) from "no driver" (install one).

> **Vector dual-engine** (v4.0.0): pass `{vector_engine, hnsw | ivfrq | diskann}` at
> open to select the engine (default `hnsw`, in-memory graph, up to a few M vectors;
> `ivfrq` IVF disk tier, recommended for 10M-100M; `diskann` Vamana graph,
> experimental). Picked once at creation and persisted in `bitcask.meta`; reopening
> with a different engine → `{error, mode_mismatch}`; no runtime switching (the
> offline `vec_engine_migrate` tool rewrites only the meta; the next open rebuilds
> via a full fold, and the switch is reversible). Per-engine tuning options
> (`hnsw_m` / `hnsw_ef_construction` / `hnsw_build_nav_int8` / `vector_ivf_nlist` /
> `vector_ivf_nprobe` / `vector_diskann_r` / `vector_diskann_l_build`) use `0` for
> auto defaults.

## API highlights

| Function | Description |
|----------|-------------|
| `open/1,2` | Open a cask (KV mode or search mode via `{analyzer, ...}`) |
| `get/2`, `put/3`, `delete/2`, `sync/1` | Core KV operations |
| `fold/3,6`, `fold_keys/3,6`, `list_keys/1` | Iteration (**snapshot-consistent**, costs O(whole table)) |
| `range/2,3`, `range_fold/5` | Ordered range query over `[Lo, Hi)`, costs **O(range)**; per-key weak consistency (not a snapshot); `{prefetch, N}` fetches values concurrently |
| `put_batch_atomic/2`, `txn_commit/2,3` | Crash-atomic batch / multi-key transaction; `Ops :: [{put,K,V} \| {remove,K}]`; ⚠️ the first call lazily upgrades the directory's meta to v6 |
| `stream/1`, `next/1`, `stop/1`, `with_stream/2` | Streaming iteration |
| `merge/1,2,3`, `needs_merge/1,2`, `status/1` | Merge management |
| `search_text/2,3`, `search_phrase/2,3`, `search_fields/2,3` | BM25 search (full-text / phrase / `field:term^boost`) |
| `search_near/3,4`, `search_fuzzy/3,4`, `search_wildcard/2,3` | Proximity / fuzzy (edit-distance) / wildcard search |
| `search_vector/2,3,4,5`, `search_hybrid/2,3,4,5` | Vector NN (HNSW / IVF-RaBitQ / DiskANN — selected at `open` via `{vector_engine, ...}`) / RRF hybrid (BM25+vector); pass `{text,_}` (vector) or `auto` (hybrid) to auto-embed the query; `/5` takes a trailing meta filter |
| `embed/2` | Encode text to a vector via the handle's embedder (`{ok, Vec}`/`{error, no_embedder}`) |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | Utilities |

## Documentation

| File | What it covers |
|------|----------------|
| `doc/api-en.md` / `doc/api-zh.md` | **API reference**: capabilities, parameter meaning & constraints, return values (EN/中) |
| `doc/USAGE.md` | Tutorial: opening, merging, configuring, searching |
| `doc/local-embedding-en.md` / `doc/local-embedding-zh.md` | **Local embedding backend** (llama.cpp NIF): build, embedder process, the three silent-failure sources, measured numbers (EN/中) |
| `doc/format-zh.md` | 磁盘格式字节级规范（带类型记录、DocValue、提示文件、锁；字节序统一小端） |
| `doc/migrate-le.md` / `doc/migrate-le-en.md` | **Migration tool** `migrate_le`: offline-migrate an old big-endian (v1) dir to little-endian (v2) (中/EN) |
| `doc/cpp-arch.md` | C++ 模块布局、锁策略、构建入口 |
| `doc/migration.md` | 特性状态与 API 参考 |
| `doc/concurrency-zh.md` | 并发与共享语义 |
| `doc/put-flow-zh.md` | put(K,V) 完整调用链 |
| `doc/vector-db-design-zh.md` | 向量库设计方案（V1–V6 蓝图） |
| `doc/vector-search-extension-zh.md` | 向量搜索扩展：HNSW + RRF 混合检索 |
| `doc/hnsw-design-zh.md` | HNSW 向量索引设计（并发/持久化/RRF/实施表） |
| `doc/keydir-sharding-design-zh.md` | KeyDir 分片并发 + 屏障 v2 写者闸门 |
| `doc/unified-architecture-plan-zh.md` | 统一架构计划（已实施） |
| `doc/libcask-extraction-zh.md` | **libcask standalone extraction feasibility** (2.2.0 plan) |
| `ROADMAP_EN.md` / `ROADMAP.md` | **Roadmap**: 6.2.1 / 6.1.0 / 6.0.0 / 5.1.0 / 5.0.0 / 4.0.0 / 3.1.0 / 3.0.0 shipped + 2.1.1 shipped (P5–P15) + 2.2.0 plan (libcask extraction / V7+ vector optimization) (EN/中) |
| `TASK.md` | Detailed task breakdown & history |

## Project status

- **C++ NIF** covers all core KV operations (`get`/`put`/`delete`/`sync`/`fold`/`merge`)
- **BM25 full-text search** — text / phrase / fields / proximity / fuzzy / wildcard, plus synonyms and snippet highlighting
- **Vector retrieval (three engines)** — approximate nearest-neighbor search; the engine is chosen at open via `{vector_engine, hnsw | ivfrq | diskann}` and persisted into `bitcask.meta` (**fixed at creation**; reopening with a different engine → `{error, mode_mismatch}`): `hnsw` (default, in-memory graph, up to a few M vectors, cosine / L2 / dot, per-node locking for concurrent reads, BCVS snapshot persistence, merge rebuild for dead-node eviction), `ivfrq` (IVF-RaBitQ disk tier, recommended for 10M–100M), `diskann` (Vamana on-disk graph, **experimental**); disk-tier engines require cosine / dot
- **RRF hybrid search** — fuses the BM25 and vector legs via Reciprocal Rank Fusion (`score = Σ 1/(60+rank)`, each leg taking `K' = max(K×4, 64)`)
- **Embedder behaviour** — `bitcask_embedder` callback with OpenAI-compatible reference implementation
- **Jieba Chinese analyzer** integrated (whitespace / n-gram / jieba)
- **Typed record format** (`kDoc`/`kTombstone` with per-write ordinal) is the default
- **Unified architecture** — Cask and Collection are merged into a single engine; KV vs. index mode selected via `{analyzer, ...}` option
- **2.1.1 system optimizations** (2026-06) — HNSW int8-only memory mode (vector memory −80%), sealed-file mmap zero-copy reads, read-handle fd-budget LRU, unified `search.ckpt` recovery path, global little-endian unification + `migrate_le` tool ([docs](doc/migrate-le-en.md)), hybrid two-leg parallelism, merge I/O tuning, on-open background merge; see [`CHANGELOG_EN.md`](CHANGELOG_EN.md)
- **Concurrency hardening** (2026-06 audit) — search read path is safe against the async index worker: `meta_blob`/search-cache copy under lock without escaping pointers, inverted-index snapshot uses safe iteration, cross-thread scalars are atomic, IndexPool consumer is exception-safe; see [`doc/concurrency-zh.md` §6](doc/concurrency-zh.md)
- **3.0.0** (2026-06-25) — libbitcask v3.0.0 upgrade (ABI break, `SOVERSION` 1→3): synonym dictionary becomes the open-time immutable option `{synonym_file, Path}` (runtime `set_synonym_map/2` removed); ships with thread-safe `Cask` handle, `parallel_scan` full-table parallel scan, async-index MapReduce pipeline, batch retrieval
- **3.1.0** (2026-07-01) — libbitcask v3.1.0 upgrade (ABI unbroken): `{max_read_handles, unlimited}` / `{auto_compact_dead_ratio, R}` options, `closed` error atom; ships with default read-handle cap (auto-derived from `RLIMIT_NOFILE`), `bitcask.meta` v3 with CRC32, field.schema FSCH v1 header + CRC
- **4.0.0** (2026-07-13) — libbitcask v4.0.0 upgrade (ABI break, `SOVERSION` 3→4, source-compatible): `{vector_engine, hnsw|ivfrq|diskann}` vector dual-engine + tuning options, `{auto_checkpoint_min_docs, N}` bounded crash-recovery replay; ships with IVF-RaBitQ-lite engine, DiskANN engine (experimental), AVX2 int8 kernels, HNSW `.qc8` codeword mmap; `examples/` Wikipedia search-database example
- **4.1.0** (2026-07-15) — libbitcask v4.1.0 upgrade (ABI unbroken, `SOVERSION` stays 4, on-disk format unchanged): **no API change** for Erlang callers — just rebuild; ships with the Phase 5/6 deep audit — fixes a process-wide permanent hang on the `close/1` teardown path (`IndexPool` count leak + unbounded `flush` in `unregister_lib`), adds `fdatasync` before `rename` to hnsw's three atomic writes (previously a crash left a truncated file), closes `RowChunks`/`MmapSegment` resource leaks; `file_util` consolidation converges fsync discipline from 4 variants to 1
- **6.2.1** (2026-08-14, current) — libbitcask 6.1.0 → **6.2.1** upgrade (spanning upstream 6.2.0 and 6.2.1; zero changes to the C API and public C++ headers, `SOVERSION` stays 6, on-disk format untouched, no migration): **no API change** for Erlang callers — just rebuild. Ships with upstream's Windows port (native MSVC x64) and its I/O robustness work — **torn-tail coverage** (the write offset is anchored to the last complete record, so a half-written record at the tail is no longer treated as valid data after a crash or power loss), every raw POSIX call moved behind the `bitcask::io` seam, and SIMD dispatch moved to runtime CPU detection (moving a binary between machines no longer SIGILLs). Build side: with upstream's paths switched to `PROJECT_SOURCE_DIR`, this repo's `third_party/*` symlink workaround is deleted. ⚠️ The one externally visible behaviour change is a second line in `bitcask.write.lock` (a process instance token, always `0` on POSIX); both parsers read only the first line, so old and new lock files stay compatible in both directions
- **6.1.0** (2026-08-06) — libbitcask 6.0.0 → **6.1.0** upgrade (MINOR, purely additive: the new enumerator is appended at the end, ABI intact, `SOVERSION` stays 6, no on-disk format change and no migration): `range`'s "index unavailable" is split into two error codes by cause — `{error, no_index}` (the index was never built for this handle: a read-only / `merge_only` open of a directory with no OKI; reopen read-write and it builds) and the new `{error, index_rebuild_failed}` (a writable open attempted a rebuild and it failed — an IO/environment problem). ⚠️ The latter means **the data is there and only the index is missing** — worth alerting on rather than treating as an empty database
- **6.0.0** (2026-08-06) — libbitcask v5.0.0 → **6.0.0** upgrade (spanning upstream 5.1.0 and 6.0.0; ABI break, `SOVERSION` 5→6, but this repo depends on it at source level so a rebuild suffices): three new API surfaces — `range/2,3` + `range_fold/5` ordered range queries (O(range); upstream measured 15×), `put_batch_atomic/2` crash-atomic batches, `txn_commit/2,3` multi-key transactions; new `{keydir_cache_entries, N}` option (disk-resident keydir Level B; upstream measured -90% resident memory at 100M keys); `open/2` errors now carry detail (`{error, {io_error \| invalid_option, Msg}}`). ⚠️ **Existing directories must be migrated offline first**: upstream 5.1.0's hint-ord flag day moves `bitcask.meta` v4 → v5, so directories written by the 5.x line are cleanly refused — migrate non-destructively with `bitcask_migrate hintord <src> <dst>` (zero changes to data bytes)
- **5.1.0** (2026-08-06) — Local embedding backend (llama.cpp / ggml, **not built by default**) plus a standalone embedder process. **No libbitcask upgrade**, no ABI or on-disk format change, and with the backend off the output is byte-for-byte 5.0.0's: a second independent NIF `priv/bitcask_llama.so` (enable with `BITCASK_WITH_LLAMA=1`), `bitcask_embedder_server` so all casks share one copy of the weights with the lifecycle tied to the process, CUDA support (`BITCASK_LLAMA_CUDA=AUTO|ON|OFF`) with build-time/run-time split diagnostics (`build_info/0` / `backend_info/0` / `gpu_status/0`) and the `scripts/detect-llama-backends.sh` probe; ⚠️ `bitcask:open/2` no longer swallows an `application:start` failure (returns `{error, {bitcask_app_start_failed, _}}` — a deliberate behaviour change)
- **5.0.0** (2026-07-17) — libbitcask v5.0.0 upgrade (64-bit timestamp flag-day, breaking both ABI and **on-disk format**, `SOVERSION` 4→5): `tstamp`/`expiry_at` widen u32→u64 end to end (Y2038 readiness), fixing a u32 wraparound with huge `expiry_secs` that misjudged every key as expired; **no API change** for Erlang callers (`tstamp` was always an arbitrary-precision integer); the `bitcask.meta` v4 gate cleanly refuses old u32-era databases — migrate existing ones offline and non-destructively with upstream's `bitcask_migrate tstamp64`, no re-ingest needed

## License

Apache 2.0; see `LICENSE`.