# C++ Architecture

This document maps the C++ codebase under `cpp/` and explains how the
layers fit together. Pair this with `doc/format.md` (on-disk spec) and
`doc/migration.md` (how to move from the legacy NIF).

## Module layout

```
cpp/
├── include/bitcask/         # public headers (the API surface)
│   ├── format.hpp           # constants, sentinels, tombstones
│   ├── codec.hpp            # data/hint record encode/decode
│   ├── io.hpp               # PosixFile + IoError
│   ├── data_file.hpp        # DataFile: append/read/fold a single file
│   ├── hint_file.hpp        # HintFile: write/validate hint records
│   ├── scanner.hpp          # scan_dir: list .bitcask.data files
│   ├── keydir.hpp           # in-memory key directory + iterator
│   ├── keydir_registry.hpp  # named-keydir cache (legacy parity)
│   ├── merge_policy.hpp     # decide() rule + per-file thresholds
│   ├── merger.hpp           # run_merge: produces new files + GCs old
│   └── cask.hpp             # Cask: end-user facade tying it all together
├── src/                     # impls; one .cpp per header where appropriate
├── nif/                     # erl_nif glue → bitcask_cpp.so
│   ├── nif_main.cpp         # ErlNifFunc table + on_load
│   ├── nif_io.cpp           # legacy file_*_int / lock_*_int subset
│   ├── nif_keydir.cpp       # legacy keydir_*_int subset
│   ├── nif_cask.cpp         # coarse-grained cask_* (the cask_cpp dispatch)
│   ├── atoms.{hpp,cpp}      # cached ERL_NIF_TERM atoms
│   └── resources.{hpp,cpp}  # ErlNifResourceType registration
├── tests/                   # GoogleTest unit + stress tests
└── bench/                   # Google Benchmark micro-benchmarks (opt-in)
```

## Layering

```
┌────────────────────────────────────────────────────────────┐
│  Erlang facade (src/bitcask.erl)                           │
│  is_cask() dispatch → bitcask_cpp_nifs:* OR bitcask_legacy │
└────────────────────────────┬───────────────────────────────┘
                             │ NIF
┌────────────────────────────▼───────────────────────────────┐
│  cpp/nif/  (thin glue, owns Erlang lifetime + atoms)       │
└────────────────────────────┬───────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────┐
│  cask::Cask  (open/get/put/delete/sync/fold/merge/status)  │
│  ↓ holds                                                   │
│  ┌───────────────┬──────────────┬──────────────────────┐   │
│  │ keydir::KeyDir│ DataFile cache│ HintFile (active)   │   │
│  │ (in-memory)   │ (open fds)    │                      │   │
│  └───────────────┴──────────────┴──────────────────────┘   │
└────────────────────────────┬───────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────┐
│  fileops (codec, scanner, data_file, hint_file)            │
│  io (PosixFile, FileLock)                                  │
└────────────────────────────────────────────────────────────┘
```

The whole tree is C++23, no Boost, no abseil, no third-party runtime
dependencies in the NIF .so. GoogleTest and Google Benchmark are pulled
via `FetchContent` and only compiled when `BUILD_TESTING` /
`BITCASK_BUILD_BENCHMARKS` are on.

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

## NIF dispatch modes

The Erlang facade picks one of three modes at `bitcask:open` time:

| `{nifs, _}`     | Erlang module       | C++ surface used         |
|-----------------|---------------------|--------------------------|
| `legacy` (default in TEST) | `bitcask_legacy` + `bitcask_nifs` (legacy C) | none |
| `cpp`           | `bitcask_legacy` + `bitcask_cpp_nifs` (fine-grained C++) | keydir + file_* |
| `cask_cpp` (default in prod) | `bitcask_cpp_nifs` only         | full Cask facade |

`legacy` is the original implementation. `cpp` swaps the C NIF for the C++
NIF but keeps all Erlang business logic. `cask_cpp` pushes everything to
C++ and Erlang becomes a thin facade. Production = `cask_cpp`; existing
white-box eunit tests run under `legacy`.

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
