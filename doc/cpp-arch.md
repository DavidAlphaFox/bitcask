# C++ Architecture

This document maps the C++ codebase under `cpp/` and explains how the
layers fit together. Pair this with `doc/format.md` (on-disk spec).

## Module layout

```
cpp/
├── include/bitcask/         # public headers (the API surface)
│   ├── format.hpp           # on-disk format constants (typed records: kDoc/kTombstone + ord)
│   ├── codec.hpp            # data/hint record encode/decode (23B data header, 18B hint)
│   ├── io.hpp               # PosixFile + IoError
│   ├── data_file.hpp        # DataFile: append/read/fold typed records
│   ├── hint_file.hpp        # HintFile: write/validate hint records
│   ├── scanner.hpp          # scan_dir: list .bitcask.data files
│   ├── keydir.hpp           # KeyDir: in-memory key directory + iterator (MVCC sibling chain)
│   ├── keydir_registry.hpp  # KeyDirRegistry: named-keydir cache (refcount sharing)
│   ├── merge_policy.hpp     # decide() rule + per-file thresholds
│   ├── merger.hpp           # Merger: merge execution (rewrites live records)
│   ├── cask.hpp             # Cask: end-user KV+search facade (open/get/put/delete/search/merge)
│   ├── meta_file.hpp        # bitcask.meta: mode persistence (KV vs Index)
│   ├── field_schema.hpp     # FieldSchema: 字段名↔id append-only 注册表（DocValue v3 fields）
│   ├── collection.hpp       # Collection: standalone document + BM25 search facade
│   ├── collection_registry.hpp # CollectionRegistry: named-collection cache
│   ├── index.hpp            # Index: in-memory document side tables (ext2ord/slots/ord2ext/live)
│   ├── inverted.hpp         # InvertedIndex: BM25 inverted index (sharded locks)
│   ├── search_layer.hpp     # SearchLayer: Index + InvertedIndex + Analyzer wrapper
│   ├── analyzer.hpp         # text::Analyzer abstract base + factory + AnalyzerConfig
│   ├── ngram_analyzer.hpp   # NgramAnalyzer: CJK bi/tri-gram + Latin whitespace
│   ├── jieba_analyzer.hpp   # JiebaAnalyzer: Chinese segmentation (cppjieba)
│   ├── whitespace_analyzer.hpp # WhitespaceAnalyzer: pure whitespace tokenization
│   ├── cjk_detect.hpp       # CJK character detection utilities
│   ├── text_utils.hpp      # NFKC normalization + text utilities
│   └── file_lock.hpp       # FileLock: advisory lock (O_CREAT|O_EXCL)
├── src/
│   ├── fileops/             # codec.cpp, data_file.cpp, hint_file.cpp, scanner.cpp
│   ├── io/                  # posix_file.cpp
│   ├── keydir/              # keydir.cpp, keydir_registry.cpp, index.cpp
│   ├── lock/                # file_lock.cpp
│   ├── merge/               # merger.cpp, merge_policy.cpp
│   ├── cask/                # cask.cpp, meta_file.cpp, collection.cpp, collection_registry.cpp
│   ├── search/              # search_layer.cpp
│   ├── bm25/                # inverted.cpp
│   └── text/                # analyzer.cpp, jieba_analyzer.cpp
├── nif/                     # erl_nif glue → bitcask_cpp.so
│   ├── nif_main.cpp         # ErlNifFunc table + on_load (28 NIF 入口)
│   ├── nif_cask.cpp         # cask_* functions (open/close/get/put/delete/sync/search/merge)
│   ├── nif_cask_iter.cpp    # cask_fold_* + cask_iterator_* (fold/iterator NIFs)
│   ├── nif_cask_admin.cpp   # cask_status / cask_needs_merge / cask_is_empty / cask_is_frozen
│   ├── nif_helpers.cpp/hpp  # 资源句柄 / DocInput 解析 / 错误翻译 / run_search 骨架 / term 构造
│   ├── nif_options.cpp      # open/2 选项解析（parse_options，单一职责）
│   ├── atoms.cpp/hpp        # cached ERL_NIF_TERM atoms
│   ├── resources.cpp/hpp    # ErlNifResourceType registration
│   ├── term_conv.hpp        # Erlang term ↔ C++ conversion helpers
│   └── priv_data.hpp        # per-NIF-instance state (registry + resource types)
├── tests/                   # GoogleTest unit + integration (15 test files, ~167 tests)
└── bench/                   # Google Benchmark (cask_bench, keydir_bench)
```

## Layering

```
┌────────────────────────────────────────────────────────────┐
│  Erlang facade (src/bitcask.erl)                           │
│  bitcask:put/get/delete/search_text/merge/... → NIF call  │
└────────────────────────────┬───────────────────────────────┘
                             │ NIF (bitcask_cpp_nifs)
┌────────────────────────────▼───────────────────────────────┐
│  cpp/nif/  (thin glue, owns Erlang lifetime + atoms)       │
└────────────────────────────┬───────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────┐
│  Cask (KV + search facade)                                  │
│  ├─ KeyDir (in-memory hash index + MVCC iterator)           │
│  ├─ DataFile cache (open fds for pread)                     │
│  ├─ HintFile (active writer)                               │
│  ├─ SearchLayer (optional, index mode only)                 │
│  │   ├─ Index (ext2ord/slots/ord2ext/live side tables)     │
│  │   ├─ InvertedIndex (BM25 posting lists)                  │
│  │   └─ Analyzer (ngram/jieba/whitespace)                  │
│  └─ MetaConfig (bitcask.meta mode persistence)             │
└────────────────────────────┬───────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────┐
│  fileops (codec, data_file, hint_file, scanner)             │
│  io (PosixFile, FileLock)                                  │
│  merge (Merger, PolicyOptions)                             │
│  text (Analyzer, NgramAnalyzer, JiebaAnalyzer)             │
└────────────────────────────────────────────────────────────┘
```

The whole tree is C++23, no Boost, no abseil, no third-party runtime
dependencies in the NIF .so. GoogleTest and Google Benchmark are pulled
via `FetchContent` and only compiled when `BUILD_TESTING` /
`BITCASK_BUILD_BENCHMARKS` are on.

## On-disk file inventory

A bitcask instance is a single flat directory containing the following files.
Detailed byte-level spec lives in `doc/format.md` (English) / `doc/format-zh.md` (中文).

```
<dir>/
├── bitcask.meta                # binary metadata (mode marker, 18 B)
├── <tstamp1>.bitcask.data      # append-only data file (can be many)
├── <tstamp1>.bitcask.hint      # sidecar index for data file (one per data, optional)
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── field.schema                # field-name→id registry (index mode only)
├── bitcask.write.lock          # held by the live writer (exclusive)
├── bitcask.merge.lock          # held by the active merger (exclusive)
├── bitcask.keydir.snap         # keydir segment snapshot (A4, optional)
└── bitcask.index.snap          # index side-table snapshot (A4, optional)
```

### File-by-file

| File | Count | Lifetime | Purpose |
|------|-------|----------|---------|
| `bitcask.meta` | 1 | persistent | Magic `BCME` + version + mode (0=KV, 1=Index/search). Source: `meta_file.hpp`. |
| `<tstamp>.bitcask.data` | many | persistent, old files removed by merge | Core data. Sequence of records: `CRC(4)+Type(1)+Tstamp(4)+Ord(8)+KeySz(2)+ValueSz(4)+Key+Value` (23 B header). Append-only; no file-level header. `<tstamp>` = monotonically increasing uint32 file id, never reused. |
| `<tstamp>.bitcask.hint` | 0..N | persistent, paired 1:1 with data files | Sidecar index: key + offset + total_sz (no value). Speeds up keydir rebuild at open — only reads keys, not values. Terminated by an 18 B sentinel whose `TotalSz` field carries a whole-file CRC32. If the CRC check fails, the hint is ignored and the keydir is rebuilt from the data file instead. |
| `field.schema` | 0 or 1 | persistent | Index mode only. Append-only field-name→id registry. Each entry: `[NameLen:u16 BE][name]`, id = order of appearance (0-based). DocValue v3 stores field ids instead of inlining names. |
| `bitcask.write.lock` | 0 or 1 | runtime (created on open RW, unlinked on close) | Exclusive write lock via `O_CREAT|O_EXCL`. Content: `<pid> <active_data_file_path>\n`. Mergers read this to learn the live writer's active file and exclude it from merge candidates. Stale locks auto-reclaimed via `kill(pid, 0)` probe. |
| `bitcask.merge.lock` | 0 or 1 | runtime (held during merge) | Exclusive merge lock. **Deliberately independent** from write.lock — writer and merger run concurrently without contending. |
| `bitcask.keydir.snap` | 0 or 1 | persistent | KeyDir segment snapshot (A4 feature). Speeds up open by avoiding full data-file scan. |
| `bitcask.index.snap` | 0 or 1 | persistent | Index side-table snapshot (A4 feature). Paired with keydir.snap. |

### How operations touch the files

| Operation | Files touched |
|-----------|---------------|
| `put(K,V)` | Append record to active `.data` + append hint to active `.hint` + update in-memory keydir |
| `get(K)` | Lookup in-memory keydir → `pread(file_id, offset)` from one `.data` file |
| `delete(K)` | Append tombstone record (`type=kTombstone`) to active `.data` + tombstone hint |
| `open` | Read `bitcask.meta` → scan all `.data` files (prefer `.hint` for speed, fallback to full data scan) → rebuild in-memory keydir |
| `merge` | Acquire `merge.lock` → read `write.lock` for active file id → pick high-fragmentation candidates → copy live records to new `.data`+`.hint` pair → CAS-update keydir → unlink old files |
| `close` | Release `write.lock` (unlink) |

### Key design points

- **File ids never reused**: `KeyDirRegistry` persists `biggest_file_id + 1` across open/close.
- **Append-only**: every put/delete appends a new record; old versions become dead bytes.
- **Two independent locks**: writer holds `write.lock`, merger holds `merge.lock` — they never block each other.
- **Hints are optional/defensive**: a corrupt or missing hint just triggers a slower full-scan rebuild from the data file. Correctness never depends on hints.

## Concurrency model

Three lock layers exist at runtime; understand which one you're under
before adding code.

| Layer            | Type                  | Held by               | Protects                        |
|------------------|-----------------------|-----------------------|---------------------------------|
| `bitcask.write.lock`  | flock(2) on file | one writer process    | the active data file's tail     |
| `bitcask.merge.lock`  | flock(2) on file | one merger process    | merge output files              |
| `KeyDir::mutex_`      | `std::shared_mutex` | every threaded op | in-memory keydir state          |

The two flock files are **independent** — a merger holding `merge.lock` does
not block a writer holding `write.lock`, and vice versa. This is the M5.1
two-lock model. The merger reads `write.lock`'s contents to learn which
file id the live writer is appending to and excludes it from merge candidates.

`KeyDir::mutex_` is one `std::shared_mutex` for the whole keydir. Reads
(get / get_epoch / info / iter::next / deep_copy / biggest_file_id /
is_ready / conditional_remove peek) take `std::shared_lock`. Writes (put,
remove, fstats updates, pending freeze, iter start+release) take
`std::unique_lock`. M5.3 measured ~1.9× the `std::mutex` baseline at 4
concurrent readers. Per-bucket sharding to push beyond that requires
breaking up `pending_` / `epoch_` / `fstats_` (all global by design) and
is deferred to M6.

**SearchLayer** is NOT thread-safe — single-writer model, same as Cask writes.

**InvertedIndex** uses sharded locks (16 shards by term hash) — different from
KeyDir's single `shared_mutex`.

## Iterator semantics (sibling chain + pending hash)

When at least one `IterHandle` is iterating (`keyfolders_ > 0`):

1. A new key goes into a separate `pending_` map. Reads consult `pending_`
   first, then `entries_`. The fold doesn't see `pending_`, so the
   snapshot stays stable.
2. An overwrite of an existing key promotes its entry from `SingleEntry`
   to `MultiEntry` — a sibling chain newest-first. `IterHandle::next`
   reads at the iterator's `iter_epoch_`, so it sees the revision that
   was current at fold-start, not subsequent overwrites.
3. A delete during a fold writes a sibling tombstone (sentinel value:
   `file_id == kMaxFileId, total_sz == kMaxSize, offset == kMaxOffset`).

When the last folder releases:

- `pending_` is merged back into `entries_`.
- All multi-revision entries collapse to single revisions.
- `iter_generation_` bumps; the `iter_mutation_` flag clears.

This is the bitcask-equivalent of MVCC for in-memory state — readers see a
consistent snapshot without copying the whole map at iter start.

## NIF dispatch

The Erlang facade (`src/bitcask.erl`) dispatches ALL operations to the C++ NIF
(`bitcask_cpp_nifs`). There is no legacy mode — `bitcask_legacy.erl` has been
deleted.

28 NIF functions are registered:

| Group | Functions |
|-------|-----------|
| Core KV | `cask_open/2`, `cask_close/1`, `cask_get/2`, `cask_put/3`, `cask_delete/2`, `cask_sync/1` |
| Search | `cask_search_text/3`, `cask_search_phrase/3` |
| Fold/Iter | `cask_fold_start/3,4`, `cask_fold_next/1`, `cask_fold_next_full/1`, `cask_fold_release/1` |
| Legacy iter compat | `cask_iterator/3`, `cask_iterator_next/1`, `cask_iterator_release/1` |
| Admin | `cask_is_empty/1`, `cask_is_frozen/1`, `cask_status/1`, `cask_needs_merge/1` |
| Merge | `cask_merge/2` |
| Other | `cask_close_write_file/1` |

## Build entry points

```
# C++ only (CMake): tests + bench, no Erlang side
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure

# Sanitizers (set one at a time; ASan and TSan are mutually exclusive)
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON

# Benchmarks (release only — sanitized perf numbers are meaningless)
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench

# Full build (cmake + rebar3): includes the .so, runs eunit
cmake --build _build/cmake -j     # produces priv/bitcask_cpp.so
rebar3 as test eunit --dir test
```

## Adding a new C++ feature

1. Land a header change in `cpp/include/bitcask/`. Keep the public API
   small — internal helpers go in anonymous namespaces in the .cpp.
2. Implement in the matching .cpp under `cpp/src/`. Use `std::expected`
   for fallible APIs (every layer in this codebase does).
3. Add unit tests under `cpp/tests/` (one .cpp per area). The tests/
   CMakeLists wires every test through `bitcask_sanitizers` so they run
   under ASan/UBSan/TSan in CI.
4. If the change touches the keydir or cask hot path, add a microbench
   in `cpp/bench/` and update `cpp/bench/baseline/baseline.json`.
5. If the change adds a new NIF, register it in `cpp/nif/nif_main.cpp`'s
   `kNifFuncs` array AND add the Erlang shim in
   `src/bitcask_cpp_nifs.erl`.
