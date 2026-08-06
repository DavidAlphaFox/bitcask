# Changelog (English)

中文版见 [`CHANGELOG.md`](CHANGELOG.md)。
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [6.1.0] — 2026-08-06

**Upgrade libbitcask 6.0.0 → 6.1.0**: "OKI unavailable" is now split into two
error codes by cause. Submodule `3480d0f` → `056127b` (tag `6.1.0`). This repo's
version is aligned to **6.1.0**.

> **Purely additive, no migration.** Upstream **appended** the new enumerator to
> the end of `CaskError`, leaving existing values untouched — so the C API's
> numeric mapping does not shift and the ABI is intact (`SOVERSION` stays `6`).
> No on-disk format change.

### Changed

- **"Index unavailable" from `range/2,3` and `range_fold/5` is now two distinct
  errors**, because the remedies are entirely different:

  | Return | Cause | What to do |
  |--------|-------|-----------|
  | `{error, no_index}` | The index **was never built for this handle**: a read-only / `merge_only` open of a directory with no OKI | Reopen `read_write` and it builds automatically; or fall back to `fold` + prefix filtering |
  | `{error, index_rebuild_failed}` (**new**) | A writable open **attempted a rebuild and it failed** (IO / environment problem; details in the log) | Fix the environment, then reopen to retry |

  ⚠️ The crucial difference is that `index_rebuild_failed` means **the data is
  there and only the index is missing**. Under 6.0.0 both collapsed into
  `no_index`; treating that as "no index, fall back to a full scan" was correct,
  but gave callers no way to know the environment was actually broken and worth
  alerting on.
- The new code is emitted as a proper `{error, index_rebuild_failed}` tuple from
  the NIF, **not** following `no_index`'s bare-atom legacy shape — a brand-new
  code carries no historical baggage, so there is no reason to propagate that
  wart. After facade normalization both are `{error, Reason}`, so callers can
  branch on them in a single `case`.

### Verified

- `rebar3 eunit` **158/158** (adds `range_rebuild_failed_test_`), xref and
  dialyzer clean.
- The new code was **actually triggered**, not just mapped from the enum by
  inspection: build a directory with its OKI deleted and a **directory** placed
  at the `kv.oki.manifest` path (the manifest is the OKI's only commit point, so
  the atomic-write rename onto a directory always fails) → the writable open's rebuild
  fails → `range` returns `{error, index_rebuild_failed}` while `get` keeps
  working (the OKI is only a derived cache).

---

## [6.0.0] — 2026-08-06

**Upgrade libbitcask v5.0.0 → 6.0.0** (spanning two upstream releases: 5.1.0 and
6.0.0), and expose all three capabilities they added to the Erlang side:
**ordered range queries**, **crash-atomic batches**, and **multi-key
transactions**. The `third_party/libbitcask` submodule advances from `aaac44c`
to `3480d0f` (tag `6.0.0`). This repo's version is aligned to **6.0.0**.

> ### ⚠️ Read this first: existing directories need one offline migration
>
> Upstream 5.1.0 introduced the **hint-embedded-ord flag day**: `bitcask.meta`
> v4 → **v5**. **Every directory written by this repo's 5.x line is cleanly
> refused when opened with 6.0.0** — old bytes are never silently reinterpreted
> under the new semantics. The migration is **non-destructive**: data files are
> hard-linked (zero byte changes), only hints + meta are regenerated, and it is
> idempotent and re-runnable:
>
> ```sh
> _build/cmake/libbitcask-build/bitcask_migrate hintord <old-dir> <new-dir>
> _build/cmake/libbitcask-build/bitcask_migrate detect  <dir>   # confirm the era first
> ```
>
> On refusal `bitcask:open/2` now **hands the migration command straight back**
> (see the error-detail passthrough under Changed) — you no longer need to read
> the docs first to get unstuck.
>
> The reverse does not hold: **directories written by 6.0.0 cannot be opened by
> older versions**. Upgrade in one direction only.

> ### Version semantics
>
> Upstream 6.0.0 is an **ABI break** (`CaskOptions` / `bitcask_options_t` gain a
> `keydir_cache_entries` field → struct layout change, `SOVERSION` 5 → **6**).
> This repo depends on it at the **source level** (submodule +
> `add_subdirectory`), so a rebuild is all it takes — there is no stale `.so.5`
> to link against. On-disk: the meta epoch does not move (v5; directories that
> use atomic batches lazily upgrade to v6), and the new BCOK v2 / BCOM v2-v3 /
> BCKS v4 formats are all **derived-cache evolutions** — older versions discard
> and rebuild them, so no migration is involved.

### Added

- **Ordered range queries** (upstream S33-5, the OKI ordered-key index):
  - `bitcask:range/2,3` — returns the `{Key, Value}` pairs in `[Lo, Hi)` in key
    lexicographic order. `Lo` is inclusive, `Hi` exclusive; either bound may be
    `undefined` for unbounded.
  - `bitcask:range_fold/5` — streaming variant; the callback is
    `fun(Key, Value, Tstamp, Ord, Acc) -> Acc'`.
  - Costs **O(range)** rather than filtering over the whole table (upstream
    measured 100k keys at 1/256 selectivity: 8.0 ms → **0.53 ms**).
  - Options `{prefetch, N}` (N>1 fetches values concurrently in batches; this
    changes *when* values are read, **never the output order or contents**) and
    `{prefetch_threads, N}` (0 = `min(online cores, 4)`). It pays off for large
    windows over cold values and loses to thread-creation cost on small ones,
    hence off by default.
  - ⚠️ Consistency is **per-key weak** (same tier as `parallel_scan`) — writes
    concurrent with the iteration may be partially visible. This is **not**
    `fold/3`'s snapshot semantics; keep using `fold` when you need a snapshot.
  - No OKI for the directory (read-only open of a never-written database, or a
    failed rebuild) → `{error, no_index}`; callers should fall back to `fold`
    plus prefix filtering.
- **Crash-atomic batches**, `bitcask:put_batch_atomic/2` (upstream S35):
  `Ops :: [{put, Key, Value} | {remove, Key}]`. After a crash or power loss the
  batch is **either entirely visible or entirely invisible** (the on-disk batch
  header declares the extent; an incomplete extent truncates the whole batch at
  recovery). The same key may appear multiple times (applied in order =
  intra-batch LWW); an empty batch is a no-op.
  ⚠️ Atomicity and durability are **orthogonal**: without an fsync, power loss
  can still lose the entire batch — but never half of one.
- **Multi-key transactions**, `bitcask:txn_commit/2,3` (upstream S34): a
  validation layer over the atomic batch — non-empty batch, non-empty keys, no
  duplicate keys, and no use of the reserved `"_txn:"` prefix. Violating any of
  these returns `{error, {invalid_option, Msg}}` with **zero side effects**.
  The third argument is the commit-point fsync policy: `sync_on_commit`
  (default) or `no_sync`.
  ⚠️ **No isolation (I) and no CAS**: intermediate transaction state is visible
  to concurrent readers, and concurrent commits with overlapping key sets have
  no ordering guarantee — serialize those in your application. Disjoint key sets
  are safe to commit concurrently.
  ⚠️ The first call to either entry point **lazily upgrades the directory's
  `bitcask.meta` to v6**, after which readers older than upstream 5.1.0 cannot
  open it. Directories that never call them stay at v5.
- **`{keydir_cache_entries, N}` open option** (upstream S36-4, disk-resident
  keydir Level B): `0` (default) = unlimited = today's fully in-memory
  behaviour; `>0` opts in to a hot-cache entry budget. The keydir degrades to a
  cache, and point lookups resolve through cache → memdelta → BCOK v2 run
  (embedded bloom + block LRU, cold get ≤2 preads). Upstream measured 100M
  `doc:` keys: 11 GB resident → **1.14 GB peak while loading / 0.80 GB on
  reopen (-90%)**, with no regression on hot get/put/merge.
  ⚠️ Enabling it for the first time on a directory without the Level B stamp
  triggers a **full OKI rebuild** (one slow open); `merge_only` sidecars and
  Level B directories are **mutually exclusive** (open is refused outright).
- `test/bitcask_range_txn_tests.erl` (19 cases) covering the boundary semantics,
  error translation, and resource lifetimes of all three.

### Changed

- **`bitcask:open/2` errors now carry their reason.** libbitcask has two classes
  of failure that are message-only, with no errno and no dedicated enum —
  `kIo(errnum == 0)` and `kInvalidOption`. They used to collapse to
  `{error, unknown}` and `{error, error}`, losing everything. They are now
  `{error, {io_error | invalid_option, DetailBinary}}`.
  This is what makes the migration path above self-serving: opening a v4-era
  directory now yields ``{error, {io_error, <<"read meta failed: ord-less-hint
  era format (meta v4); run `bitcask_migrate hintord <src> <dst>` to migrate
  ...">>}}``.
  **Every other failure shape is unchanged** — in particular
  `{error, write_locked}` stays a bare atom, which `merge/3`'s `merge_locked`
  mapping matches exactly.
- Inherited from upstream B4: **merge input files are now retired and deleted
  lazily** instead of being unlinked on the spot. The visible change is that
  **disk space freed by a merge is released one beat later** (at the next merge
  start / `checkpoint()` entry / `close()`). In exchange, in-flight readers
  holding an older keydir snapshot no longer hit a spurious-ENOENT window.
  Retired files left behind by a crash are ordinary data files; recovery and
  subsequent merges absorb them.
- Inherited upstream fix: once group commit became the primary put path, the
  **memdelta threshold flush lost its trigger** — a pure-KV write-heavy workload
  (no checkpoint to piggyback on) grew memdelta without bound (upstream measured
  790 MB at 10M puts). Also fixes the pre-existing exposure where `close()`
  performed no fsync at all under `sync_every_n=0`.
- Inherited upstream B1 closure: **checkpoints could outrun un-fsynced data** —
  keydir snapshots, ckpt-chain watermarks, and OKI runs are now all filtered by
  "reference ≤ durable". The dangling entries that survived a power loss while
  their data evaporated (get reporting IO/CRC) are gone.
- Inherited upstream S33-6: the automatic tier of `{max_read_handles, 0}` is now
  **clamped to [64, 1024]**. It previously took half of `RLIMIT_NOFILE`, and
  under containers/systemd that limit is routinely 5×10^5+, where "half" is no
  limit at all.

### Removed

- Nothing. Upstream removed TxnCask's plan-B intent replay
  (`recover` / `pending_txns`), which this repo never exposed — the Erlang side
  is unaffected.

### Verified

- `rebar3 compile` (linked against 6.0.0) + `rebar3 eunit` **157/157**
  (19 new cases).
- **The migration path was exercised end to end** (against a synthetic but valid
  meta v4 directory — version byte changed *and* the meta CRC recomputed):
  `open/2` refuses cleanly and hands back the verbatim `bitcask_migrate hintord`
  command → `bitcask_migrate detect` identifies the era and names the next step →
  `hintord` migrates successfully (112 records) → the migrated directory opens
  normally with `get` / `range` data intact.
- Lifetime smoke test: using a range iterator after `cask_close` yields
  `{error, closed}` (the NIF keeps the parent resource alive and checks it on
  every call) rather than a segfault.

---

## [5.1.0] — 2026-08-06

**Local embedding backend (llama.cpp / ggml) + a standalone embedder process.**

> Unlike every release before it, this one involves **no libbitcask upgrade**: the
> submodule stays at v5.0.0, no ABI change, no on-disk format change. With the
> backend switched off the build output is **byte-for-byte** what 5.0.0 produced —
> no submodule fetch, no CMake flag, no extra target.

### Added

- **Local embedding backend** (`bitcask_embedder_llama` + `bitcask_llama_nifs`):
  computes embeddings in-process via llama.cpp, with no HTTP endpoint. The
  artifact is a **second, independent NIF**, `priv/bitcask_llama.so`, plus a set
  of vendored ggml/llama shared libraries (including 14 variants `dlopen`ed at
  runtime by CPU microarchitecture); the core `bitcask_cpp.so` links no ggml
  symbols. **Not built by default** — enable with `BITCASK_WITH_LLAMA=1 rebar3
  compile`. Adds the `third_party/llama.cpp` submodule (tag `b10257`).
- **Standalone embedder process**: `bitcask_embedder_server` (gen_server) +
  `bitcask_embedder_proxy` (provider). `{embedder, _}` at `open/2` now also
  accepts a process reference (`pid()` / registered name / `{global,_}` /
  `{via,M,N}`): **all casks share one copy of the weights** and the lifecycle
  follows the process (released in `terminate/2`). It can be started by
  `bitcask_sup` from the new application env `{embedder, #{name, provider,
  config}}`; no config, no process.
- **GPU backends: CUDA (NVIDIA) and Vulkan (AMD / Intel, and NVIDIA too)**, one
  switch each with identical semantics: `BITCASK_LLAMA_CUDA` /
  `BITCASK_LLAMA_VULKAN` = `AUTO` (default — compiled in whenever the SDK is
  detected) | `ON` (hard requirement) | `OFF`. Both can be on at once.
  ⚠️ Vulkan's AUTO has to confirm **all three** of loader / `glslc` /
  SPIRV-Headers before enabling anything — ggml-vulkan declares both of its
  `find_package` calls `REQUIRED`, so enabling on a partial match **fails the
  build outright**, and the whole point of AUTO is "quietly don't compile it".
  The CUDA runtime (cudart/cublas/cublasLt) is flattened into `priv/` by default
  (`BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME`) — this is a server-side product, size is
  not a constraint, and it removes the silent "target is missing libcublas →
  ggml skips the backend → degrades to CPU" class of failure. CUDA architecture
  coverage spans Maxwell..Blackwell rather than narrowing to native.
- **Run time picks the backend in Erlang itself**, with no per-machine
  configuration and no script: `model_load` gains `backend => auto` (default)
  `| cuda | vulkan | cpu`, where `auto` walks **CUDA > Vulkan > CPU** and takes
  the first family that actually has a GPU; `n_gpu_layers` also defaults to
  `auto` (offload everything if there is a GPU, else 0). An unknown value returns
  `{error, {bad_backend, _}}` rather than silently falling back to the default.
  ⚠️ **Picking exactly one family is a correctness requirement, not a policy**:
  with CUDA and Vulkan both compiled in, each backend **enumerates the same
  physical card** (one 4090 = `CUDA0` + `Vulkan0`). With
  `llama_model_params.devices` left NULL ("use all available devices") llama
  splits the model's layers across what it thinks are two cards — no error, just
  double-booked VRAM and mysterious slowness or OOM.
- **Multiple GPUs: one card by default, data parallelism**. Adds `gpu_index`
  (default `0`) and `split_mode` (default `none`).
  ⚠️ llama's `split_mode` defaults to `LAYER` (split layers across every card).
  For an embedding model that is a pessimization: 0.6B of weights fits on one
  card, so splitting only adds cross-GPU transfers, and it spends N cards' worth
  of parallelism on **one serial** request path. Embedding wants data
  parallelism — size a pool of embedder processes from `backend_info/0`'s device
  list, one bound per card. An out-of-range `gpu_index` returns
  `{error, {bad_gpu_index, _}}` instead of silently falling back to CPU (which
  would pile the whole pool onto the CPU with nobody noticing).
- **Batch embedding entry point** `bitcask_embedder:embed_batch/2` (an
  **optional** `bitcask_embedder` callback `embed_batch/2`; when a provider does
  not implement it the framework falls back to sequential `embed/2` with an
  identical result shape, so callers never need to know). The llama backend
  implements it natively: one decode feeds several sequences and pooling produces
  one vector each; `model_load` gains `batch_size` (default 1).
  ⚠️ Results are **per item**, `[{ok,Vec} | {error,Reason}]`, in input order — one
  bad document should not waste the other 63, and failing the whole batch forces
  the caller to drop it or fall back to one-at-a-time retries.
  ⚠️ **`n_ctx` must be multiplied by `batch_size`**: llama's `n_ctx` is a budget
  shared across sequences (`n_ctx_seq = n_ctx / n_seq_max`), so without that,
  enabling batching would **silently shrink each text's usable length by a factor
  of batch_size** and texts that used to fit would start returning
  `too_many_tokens` while the configured `n_ctx` never changed. The cost is that
  memory/VRAM grows linearly with `batch_size`.
  ⚠️ Any number of texts may be passed; the C++ side **chunks automatically**
  against the sequence-count and total-token limits — without chunking
  `llama_decode` rejects the whole block with a negative value that does not say
  the count was the problem.
  With a pool, a batch is **split and dispatched concurrently** across the workers
  (K cards each running one batched decode) and reassembled in the original order.
  **`batch_size` defaults to 1 (off)**: the measured gain grows as texts get
  shorter (7.0x short, 2.9x medium), but other fully-loaded processes were running
  on the measurement box, and oversubscription inflates exactly the overhead
  batching amortizes — expect noticeably less on a quiet machine, and there is no
  trustworthy data for the long-text case. Measure on your own hardware first.
- **Native batching for the HTTP tier**: `embed_batch/2` on `openai` /
  `anthropic` sends one request carrying an array, with a new `max_batch`
  (default 64) to chunk on (endpoints cap both array length and total tokens, and
  exceeding either fails the **whole request**).
  ⚠️ **Responses are placed by the `index` field, not zipped in return order** —
  every object carries `index`, and "data is in input order" is only how common
  implementations behave, not a protocol guarantee. Zipping by order **attaches
  vectors to the wrong documents**: no error, correct dimensions, and retrieval
  quietly wrong from then on with no way to notice. If the indices are not a
  permutation of `0..N-1` the whole batch errors rather than guessing.
  ⚠️ Empty strings are filtered client-side and never sent — an OpenAI-compatible
  endpoint 400s the entire request on an empty array element, wasting the other
  63 texts in the batch.
- **The HTTP tier's request/parse moved into `bitcask_embedder_util`**: openai and
  anthropic previously had **identical** request bodies, timeout handling and
  response parsing (only the auth header differed); there is now one copy. The
  parsing is a **pure exported function**, and the new
  `test/bitcask_embedder_util_tests.erl` adds 14 network-free unit tests — that
  path previously had only a manual, skipped-by-default case needing a live
  endpoint, i.e. it was effectively untested.
- **`instances => auto`**: the provider probes which cards to use — those **ggml
  enumerates and that can fit the model** (the latter reuses the pre-load coarse
  check, which incidentally skips cards someone else is already filling).
  If none qualify → it degenerates to **one instance with no card bound** (pure
  CPU) rather than erroring: `auto` means "use whatever is there", so it must
  still work on a GPU-less machine.
  ⚠️ It does **not** try to guess which cards it should take: which GPUs a process
  can see is already an operator-side standard (`GGML_CUDA_DEVICES` /
  `CUDA_VISIBLE_DEVICES` / `GGML_VK_VISIBLE_DEVICES` / container device
  passthrough), and we do not invent a second mechanism.
  ⚠️ **The failure policy is deliberately asymmetric**: an explicit card list means
  **all must start** (writing a card number is a statement of intent, so failing
  to start means the config disagrees with reality); `auto` is **best effort** —
  a failing instance is skipped with a warning, and only zero started is a
  failure.
  ⚠️ Best effort has to come with saying so — the new
  `bitcask_embedder_pool:status/1` reports `requested` / `started` / `missing`.
  With 1 of 8 cards up the workload gets one eighth of the throughput while
  everything looks fine; this function is the only clue in that situation.
  When a provider does not implement `auto_instances/1` (the HTTP tier has no
  notion of cards) `auto` is **rejected outright** rather than quietly degrading
  to a single instance.
- **`per_gpu => K`** (default 1): K contexts on the same card. ⚠️ A context serves
  one forward at a time, so several do add concurrency, but they contend for the
  same SMs — the gain is **not necessarily linear** — while VRAM grows with the
  copy count. **No measured data, so it is an explicit option and never a
  default.**
- **Multi-GPU data-parallel pool** `bitcask_embedder_pool`: N embedder processes,
  **all layers on one card, one instance per card**, N requests genuinely
  concurrent. The application env gains `instances => [0,1,2,3]` (or card groups
  `[[0,1],[2,3]]` when a model does not fit on one card).
  ⚠️ **This is not splitting layers across cards**: llama's `split_mode` defaults
  to `LAYER`, which is a pessimization for embedding models — 0.6B fits on one
  card, splitting only adds cross-GPU transfers, and **a single `llama_context`
  serves one forward at a time**, so N cards would still be working on 1 request.
  ⚠️ **No coordinator on the hot path**: the pool is a **supervisor** and forwards
  no `embed`. Workers register under stable names and the caller (the proxy)
  **talks to a worker directly**, zero hops; routing through a process that
  `gen_server:call`s the workers would make that process the new serialization
  point. Dispatch picks the shortest message queue (workers are serial, so queue
  length is the work owed).
  ⚠️ The same card in two instances is rejected (a config error; `per_gpu` is the
  explicit way to ask for replication).
  ⚠️ **Startup is sequential** (N model loads; 542 ms measured for 0.6B).
  Deliberately not parallel or lazy — that would let a worker's startup failure
  bypass the supervisor's start-time check, and the "a configured embedder that
  fails to start kills the application" policy depends on synchronous start-time
  failure.
- **`split_mode` promoted to an explicit config option** (`none` | `layer` |
  `row`) and `gpu_index` now accepts a **card group** (`[0,1]`). A group larger
  than one card switches `split_mode` to `layer` by default; ⚠️ `split_mode =>
  none` with several cards is self-contradictory and is rejected outright rather
  than quietly using only the first card.
- **Coarse pre-check for "does not fit"**: before loading, the GGUF file size is
  compared against the group's total free VRAM, and an obvious mismatch returns
  `{error, {model_too_large, _}}` listing the three ways out (partial offload via
  `n_gpu_layers => N`, across cards via `instances => [[0,1]]`, or a smaller
  quantization).
  ⚠️ Coarse only — **never used to pick `n_gpu_layers` automatically**, since
  llama's real footprint also includes the compute buffer and KV cache and
  guessing low means silently offloading too few layers. Without this check,
  "does not fit" shows up as llama OOM → fallback retries `ngl=0` → **the whole
  model goes back to CPU**, throwing away the 90% of layers that would have fitted.
- **Build-time / run-time split diagnostics**: the build-time facts (was CUDA /
  Vulkan compiled in, toolkit version, architecture list) are baked into the
  `.so` and reported by `build_info/0`; the run-time facts come from
  `backend_info/0` (device list carrying `type` / `backend` / VRAM); and
  `gpu_status/0` reconciles the two into `ok` / `cpu_only_build` /
  `no_gpu_device` / `backend_not_initialized`. Looking only at run time, "0 GPUs"
  cannot distinguish "no GPU backend in the package" (rebuild) from "no driver on
  this machine" (install one). The fallback reason is also judged **against the
  family you asked for** — with Vulkan but not CUDA in the package, answering a
  `cuda` request with "has a GPU backend but no device" would be wrong.
- **Build-time SDK probe** `scripts/detect-llama-backends.sh`: CMake only says
  "not found"; the script says **which package is missing** and prints the build
  command to use (pre-filled with whichever of
  `-DBITCASK_LLAMA_CUDA=ON` / `-DBITCASK_LLAMA_VULKAN=ON` it detected).
  ⚠️ A build-time tool only — the run-time decision happens in Erlang, and a
  deployment box has neither this repository nor cmake.
- **`bitcask_embedder_util`**: collects `truncate_utf8` / `strip_partial` /
  `validate_dims` / `validate_limits` / `l2_normalize` / `mrl_truncate` into one
  place. openai and anthropic previously carried **verbatim duplicate** copies.
- Documentation: `doc/local-embedding-en.md` / `doc/local-embedding-zh.md`.

### Changed

- ⚠️ **`bitcask:open/2` no longer swallows an `application:start(bitcask)`
  failure**; it returns `{error, {bitcask_app_start_failed, Reason}}` instead.
  The old `catch application:start(bitcask)` discarded the return value outright:
  with an embedder configured but a bad model path, the application would fail to
  start while `open` still handed back a handle, after which every
  `put #{text=>...}` carried no vector — a symptom that only surfaces once the
  search results are wrong, by which point the store is dirty. **This behaviour
  change is deliberate**: configuring an embedding model means the workload needs
  it, and silently degrading is far more dangerous than dying. (Deployments whose
  application starts normally are unaffected.)
- `rebar.config`'s submodule init is now **path-scoped** to
  `third_party/libbitcask`. A bare `--init --recursive` would drag the new
  `third_party/llama.cpp` (~200 MB) onto every user of this library, including
  the vast majority who never enable the backend.
- `backend_info/0` devices gain a `type` (`cpu`/`gpu`/`accel`); the top level
  gains `gpu_count`.
- Application env gains `{embedder, undefined}` (no embedder process by default).
- `rebar.config` gains `{dialyzer, [{plt_extra_apps, [inets]}]}`, silencing the
  "Unknown function `httpc:request/4`" warnings.
  ⚠️ `plt_extra_apps` rather than adding `inets` to `applications`: inets is only
  used by the HTTP-tier embedder, and since the vast majority of deployments
  configure no embedder at all it should not become a start-up dependency of
  bitcask (it is pulled in by `application:ensure_all_started/1` when needed).
  This entry only makes dialyzer aware of it; **the runtime dependencies are
  unchanged**.

### Fixed

- `.gitignore`'s `priv/*.so` does not match SONAME-suffixed artifacts
  (`libggml-base.so.0.18.0` and friends); added `priv/*.so.*` so build output is
  not accidentally committed.

### Measured (8 vCPU container, `Qwen3-Embedding-0.6B-Q8_0`, `n_ctx=512`)

Query (5 tokens) **33–35 ms**, document (276 tokens) ≈ 890 ms, model load 542 ms,
self-check margin (near-synonym − unrelated) 0.59.

> ⚠️ The `n_threads` default must come from
> `erlang:system_info(logical_processors_available)`, not `logical_processors`:
> the latter reports the **host's** core count and ignores the CPU affinity mask.
> On the measurement box the two read 8 and 128 — deriving 126 threads from the
> latter is **20× slower** than optimal, with no error anywhere.

### Regression

- `rebar3 eunit` **138/138** (25 local-embedding cases + 39 embedder
  process/pool/batch cases + 14 network-free HTTP parsing unit tests; the
  model-dependent ones skip gracefully when the NIF is not built), `rebar3 xref`
  clean, `rebar3 dialyzer` **zero warnings**.
- **The Vulkan build path was exercised for real**: the development box has a
  Vulkan SDK (1.4.309), AUTO detected it and compiled it in,
  `priv/libggml-vulkan.so` was produced, and `build_info` reports
  `vulkan_built => true` at run time. Since that machine has no GPU,
  `gpu_status/0` returns `no_gpu_device` rather than `cpu_only_build` — **exactly
  the distinction the build/run-time split exists to make, demonstrated with real
  data rather than reasoning**.
- ⚠️ **The CUDA compile and any real GPU runtime path were not exercised** (the
  development box has no NVIDIA driver and no toolkit, and the Vulkan backend was
  only compiled, never run against a card). What was verified: both AUTO
  detection branches, build-time macro injection and self-report, honest
  diagnostics when no GPU is present, and the validation/error paths for
  `backend` / `gpu_index` / `split_mode`.

---

## [5.0.0] — 2026-07-17

**Upgrade to libbitcask v5.0.0**: the submodule advances from v4.1.0 to **v5.0.0**
(64-bit timestamp flag-day: `tstamp` / `expiry_at` widen from `uint32_t` to
`uint64_t` end to end, for Y2038 readiness; `SOVERSION` 4 → **5**, breaking both
the ABI and the **on-disk format**). This repo's version is aligned to **5.0.0**
in lockstep. The NIF has been recompiled and relinked; eunit 64/64 passes, plus a
byte-level on-disk format verification and an old-database gate smoke test.

> This upgrade carries **no API change for Erlang callers**: the `tstamp` returned
> by `fold_keys` and friends was always an arbitrary-precision integer — it can now
> simply carry second values > 2^32 (past year 2106). The `{expiry_secs, N}` /
> `{expiry_grace_time, N}` options remain u32 upstream (durations, not instants)
> and are unaffected.

> ⚠️ **The on-disk format is not backward compatible**: `bitcask.meta` v3 → **v4**
> gate — v5.0.0 **cleanly refuses** to open old u32-era databases (meta v1/v2/v3);
> the NIF currently surfaces this as `{error, unknown}` (upstream wraps the gate
> error as `kIo`/errnum 0, dropping the detail string). Old databases need **no
> re-ingest**: upstream's unified migration tool `bitcask_migrate tstamp64 <src>
> <dst>` performs a non-destructive offline migration (reads src only, writes dst
> only; the `detect` subcommand probes the era first).

> Upstream has retro-tagged v4.1.0, so the previous pin-by-commit (`66924e3`) note
> is obsolete; from this release on the submodule is referenced by tag again
> (v5.0.0 = `aaac44c`).

### Changed (inherited from libbitcask v5.0.0)

- **64-bit timestamps end to end**: C/C++ API + on-disk data record header (23B →
  **27B**) + DocValue (v3 → **v4**, ExpiryAt segment u32 → u64) + hint (`BCH3` →
  **`BCH4`**) + keydir snapshot (BCKS v2 → **v3**) + docmap sidecar — every tstamp
  carrier widened in lockstep.
- **u32 wraparound fix**: with a huge `expiry_secs` (e.g. `0xFFFFFFFF`),
  `tstamp + expiry_secs` wrapped in the u32 domain, **misjudging every key in the
  database as expired**; all expiry arithmetic now runs in the u64 domain.
- **`now_sec_default()` returns u64**: `tv_sec` is no longer truncated to u32.

### NIF adaptation (this repo)

- `nif_cask_iter.cpp` ×2: iterator `tstamp` returns switch from `enif_make_uint`
  (32-bit — a u64 argument would truncate silently) to `enif_make_uint64`, so
  `#bitcask_entry.tstamp` from `fold_keys` / `iterator_next` stays correct past
  2106. No other touch points: all write paths use the default tstamp
  (source-level no-op), and Erlang integers have no fixed width.

### Regression

- `rebar3 compile` (linked against v5.0.0) + `rebar3 eunit` **64/64**.
- Byte-level on-disk spot check: data header 27B / tstamp u64 / DocValue Ver=4 /
  meta `BCME 04` / hint `BCH4` — all in the new era format.
- Gate smoke test: a database written by v4.1.0 is cleanly rejected when opened
  with v5.0.0 — old bytes are never silently misread at the new offsets.

---

## [4.1.0] — 2026-07-15

**Upgrade to libbitcask v4.1.0**: the submodule advances from v4.0.0 to **v4.1.0**
(Phase 5/6 deep audit: 8 fixes + 4 refactors). `SOVERSION` stays **4**, the ABI is
unbroken, and the on-disk format is unchanged; this repo's version is aligned to
**4.1.0** in lockstep. The NIF has been recompiled and relinked; eunit 64/64 passes.

> This upgrade carries **no API change whatsoever for Erlang callers**: no added or
> deprecated `open/2` options, no behavioral change. The entire benefit comes from
> stability fixes in the C++ core — callers need no code changes, just a rebuild.

> ⚠️ Upstream v4.1.0 exists only as a release commit and is **not tagged**, so the
> submodule is pinned by commit `66924e3` (`git describe` = `v4.0.0-32-g66924e3`).
> This can revert to a tag reference once upstream pushes one.

### Fixed (inherited from libbitcask v4.1.0)

All of the following are internal C++ core fixes; the symptoms they map to on the
Erlang side:

- **Process-wide permanent hang** (P6-MEM-1 + P6-DL-1): `IndexPool::submit`
  incremented `in_flight` before enqueuing, so a `bad_alloc` from the queue's
  internal allocation leaked the count and left `flush()`'s predicate forever false.
  Combined with the untimed `flush()` in `unregister_lib`, the `close/1` teardown
  path could **hang a VM scheduler forever**. Closed from both ends: `submit` now
  compensates with `dec_in_flight` before rethrowing (root cause), and the teardown
  `flush` is bounded at 30s (backstop).
- **Durability — hnsw atomic writes had no fsync** (P6-DUR-1): `save`,
  `save_vec_payload`, and `write_bcq8` performed no sync before `rename`, so **a
  crash left the previously-good file already overwritten by a truncated one**
  (corrupt vector index → full rebuild on reopen). Now `fflush` + `fdatasync`, with
  both return values checked.
- **Resource leaks**: slot leak in `RowChunks::ensure_slot` (P6-MEM-2), fd leak in
  `MmapSegment::open` (P6-MEM-3), and `std::terminate` when `OrdSkipGuard`'s
  destructor threw (P5-MEM-1).
- **Inconsistent checkpoint watermark**: three missing `last_ckpt_ord_` updates
  (P5-MEM-2).

### Internal (no Erlang-visible impact)

- `file_util.hpp` consolidates 6 whole-file-read and 9 atomic-write sites; fsync
  discipline converges from 4 variants to 1 (T21).
- Analyzer dual-exit consolidation plus 3 differential tests (T22); dead-code
  removal (T25, P5-DL-3).
- Upstream acceptance: ASan 644/644, TSan clean across the full suite.

---

## [4.0.0] — 2026-07-13

**Upgrade to libbitcask v4.0.0**: the submodule advances from v3.1.0 to **v4.0.0**
(S32 vector dual-engine + S29-11-②④ AVX2 int8 kernels + disk-segment UB audit;
`SOVERSION` 3 → **4** — two `bitcask_options_t` layout changes make this an ABI
break, while staying **fully source-compatible**: recompiling the NIF is all it
takes). The NIF has been recompiled and relinked, and this repo's version is
aligned to **4.0.0** in lockstep.

> ⚠️ The upgrade itself carries **no breaking API change for Erlang callers**:
> every existing `open/2` option and search API works as before, and behavior is
> unchanged when the new options are not passed (the vector engine still
> defaults to HNSW).

### Added

- **`open/2` option `{vector_engine, hnsw | ivfrq | diskann}` (vector mode)**:
  passes through libbitcask v4.0.0's vector dual-engine (S32). `hnsw` (default,
  in-memory graph, up to a few M vectors), `ivfrq` (IVF-RaBitQ disk tier,
  recommended for 10M-100M, requires cosine/dot metric), `diskann` (Vamana
  graph, **experimental** — not recommended for production until validated on
  real corpora). Picked once at creation and persisted in `bitcask.meta`;
  reopening with a different engine → `{error, mode_mismatch}`; no runtime
  switching (the offline `vec_engine_migrate` tool rewrites only the meta; the
  next open rebuilds via a full fold, and the switch is reversible).
- **`open/2` vector-engine tuning options** (`0` = engine-specific auto
  default, normally not needed): `{hnsw_m, N}` / `{hnsw_ef_construction, N}`
  (HNSW graph degree / build ef), `{hnsw_build_nav_int8, B}` (S29-11-②: HNSW
  int8 mixed-precision build navigation, default `true` — insert +29%~75% with
  zero recall@10 loss; `false` = full-f32 fallback gate),
  `{vector_rebase_min_docs, N}` (S32-M1: vector checkpoint crash-recovery
  replay bound, all engines, default 262144), `{vector_ivf_nlist, N}` /
  `{vector_ivf_nprobe, N}` (ivfrq cluster count / query probe count),
  `{vector_diskann_r, N}` / `{vector_diskann_l_build, N}` (diskann adjacency
  capacity / build beam width).
- **`open/2` option `{auto_checkpoint_min_docs, N}` (index mode)**: passes
  through `CaskOptions::auto_checkpoint_min_docs` (S14-1/S31.5). Once the doc
  delta since the last checkpoint reaches N, a keydir snapshot + search ckpt
  are persisted asynchronously, bounding the crash-recovery replay window to
  ≤ N. Default 65536; `0` = off.
- **`search_vector`'s `Ef` parameter is interpreted per engine**: HNSW =
  candidate list size; ivfrq = query probe count (nprobe); diskann = query
  beam width.
- **`examples/` Wikipedia search-database examples**: build a "BM25 + vector +
  hybrid RRF" search database from a real Wikipedia dump.
  `wiki_hnsw.escript` / `wiki_diskann.escript` demonstrate the two vector
  engines (they differ only in the `vector_engine` option; all logic is shared
  in `wiki_common.erl`). The data-extraction scheme is ported from wiser-cpp:
  streaming SAX parsing (a dump of tens of GB never enters memory), two-pass
  wiki-markup stripping, and the key=title / body→text / title→field
  convention; with an embedder configured at open, `put` auto-embeds the
  article lead. The embedding endpoint is configured via environment
  variables — `WIKI_EMBED_URL` (required) / `WIKI_EMBED_MODEL` /
  `WIKI_EMBED_DIM` — never hard-coded. See `examples/README.md`.

### Fixed

- **`put` doc-map `fields` documentation corrected (×3 places)**: the NIF
  actually requires a **map** (`#{FieldName => Text}`; a non-map → `badarg`),
  but the `bitcask.erl` comment and both API docs described it as a
  `[{Field, Text}]` proplist. The path had no test or example coverage, so the
  first real caller (the examples) hit it immediately. All three places now
  match the implementation.

### Changed

- **`third_party/libbitcask` submodule**: v3.1.0 → **v4.0.0** (soname
  `libbitcask.so.3` → `libbitcask.so.4`; upstream later re-tagged v4.0.0 with
  one extra docs-sync commit — the pointer now tracks `e814e4d`, no code/ABI
  change). Ships with the library: the
  IVF-RaBitQ-lite engine (100k/384d queries at 36.5µs, recall loss ≤0.08pt),
  the DiskANN engine (experimental), AVX2 int8 dot-product kernels
  (VNNI512→VNNI256→AVX2 dispatch; full int8 path now active on non-VNNI
  machines), bounded vector-checkpoint crash recovery (worst case ~4.2M →
  ≤320K entries), HNSW `.qc8` codeword mmap + `clone_live` payload spill
  (merge rebuilds no longer double peak heap), disk-segment bounds-check fixes
  (OOB-read UB in trusted-disk mode), EINTR retry in IO loops, and
  exception-safe `parallel_for`. Engine details in the
  [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md).
- **NIF internals**: followed the `search_layer.hpp` split —
  `nif_options.cpp` / `nif_helpers.cpp` now include `search_config.hpp`
  (libbitcask v4.0.0 removed the old header).
- **Build**: root `CMakeLists.txt` version notes aligned to v4.0.0;
  `bitcask.app.src` `vsn` 3.1.0 → 4.0.0.

## [3.1.0] — 2026-07-01

**Upgrade to libbitcask v3.1.0**: the submodule advances from v3.0.0 to **v3.1.0**
(the S12 whole-library audit batch; `SOVERSION` stays **3**, ABI unbroken—a
backward-compatible feature addition). The NIF has been recompiled and relinked, and
this repo's version is aligned to **3.1.0** in lockstep.

> ⚠️ **On-disk format is forward-incompatible**: libbitcask v3.1.0 bumps `bitcask.meta`
> to **v3** (adds CRC32). Databases written by this version **cannot be opened by the old
> 3.0.0** (old readers only accept v2 → "unsupported meta version"). It **is**
> backward-compatible—this version reads old databases (v2 meta compat-read, legacy
> field.schema auto-upgraded to FSCH v1 in place). Upgrade one-way only.

### Added

- **`open/2` option `{max_read_handles, unlimited}`**: passes through libbitcask
  v3.1.0's `kUnlimitedReadHandles` sentinel (explicit no-limit, the old default).
- **`open/2` option `{auto_compact_dead_ratio, R}` (index mode)**: passes through
  `SearchLayerConfig::auto_compact_dead_ratio`. `0.0` (default) = off; `R ∈ (0.0, 1.0]`
  = on—automatic compaction inside the reducer thread by per-list dead ratio, bounding
  posting-list memory under churn without waiting for merge (libbitcask S12-2). Effective
  in index mode only (with `{analyzer, _}`).
- **Error atom `closed`**: the NIF maps libbitcask's new `CaskError::kClosed` (a call on
  an already-closed handle, S12-5) to `{error, closed}`, distinct from generic
  `{error, error}`.

### Changed

- **`third_party/libbitcask` submodule**: v3.0.0 → **v3.1.0** (`SOVERSION` stays 3,
  soname `libbitcask.so.3` unchanged; ABI-additive—new symbols + enum values appended).
  Brings: default read-handle cap (bounds fd/mmap), reducer-thread auto compaction,
  FSCH v1 header + CRC on field.schema, `bitcask.meta` v2 → v3 with CRC, C API batch
  search ×3 + `parallel_scan` + `BITCASK_ERR_CLOSED`, `-Werror` library-build guard. See
  the [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md) for engine details.
- **`{max_read_handles, N}` semantics change (with libbitcask v3.1.0)**: the default `0`
  changes from "unlimited" to **auto-derived from the `RLIMIT_NOFILE` soft limit** (about
  half, floor 64). Small/medium databases are unaffected; large databases move from
  fd-exhaustion crashes to graceful handle eviction. Pass `unlimited` for the old
  unbounded behavior.
- **Build**: root `CMakeLists.txt` version/format comments aligned to v3.1.0;
  `bitcask.app.src` `vsn` 3.0.0 → 3.1.0.

## [3.0.0] — 2026-06-25

**Upgrade to libbitcask v3.0.0**: the submodule advances from v1.1.0 to **v3.0.0**
(libbitcask now **unifies its three version numbers**—CHANGELOG = library `VERSION` =
C API = `3.0.0`, `SOVERSION` 1 → 3). This is an ABI-breaking change; the NIF has been
recompiled and relinked, and this repo's version is aligned to **3.0.0** in lockstep.

> ⚠️ **Breaking API change**: the runtime `bitcask:set_synonym_map/2` is removed; the
> synonym dictionary becomes an open-time immutable `open/2` option,
> `{synonym_file, Path}`. Callers must migrate (see below).

### Changed (breaking)

- **Synonym dictionary: runtime setter → open-time immutable config** (mirrors
  libbitcask v3.0.0, which removed `Cask::set_synonym_map` /
  `bitcask_set_synonym_map` in favor of `CaskOptions::synonym_map`).
  - **Removed** `bitcask:set_synonym_map/2` (plus the `cask_set_synonym_map/2` NIF
    and the `load_failed` atom).
  - **Added** the `open/2` option `{synonym_file, Path}`: loaded once at open time,
    **immutable** thereafter → naturally concurrency-safe for queries. `Path` accepts
    a string or binary (the facade binarizes it); only effective in index mode (with
    `{analyzer, _}`); if the file can't be opened, expansion is silently skipped (per
    the existing "invalid option value silently skipped" semantics, open still
    succeeds).
  - **Migration**: replace the runtime `set_synonym_map(H, Path)` call with
    `open(Dir, [{analyzer, _}, {synonym_file, Path}, ...])`; changing dictionaries at
    runtime now requires reopening the database.

### Changed

- **`third_party/libbitcask` submodule**: v1.1.0 → **v3.0.0** (`SOVERSION` 1 → 3,
  soname `libbitcask.so.1` → `libbitcask.so.3`; the linker errors clearly on an
  incompatible ABI). Brings the v1.2.0 engine capabilities along: thread-safe `Cask`
  handle (internally serialized writes + concurrent reads/search + fail-fast
  `close()`), batch retrieval, the async-index MapReduce pipeline, and
  `parallel_scan` full-table parallel scan; on-disk meta format bumped to v2 (new
  `VecInmemInt8` byte). Engine details in
  [the libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md).
- **Build**: root `CMakeLists.txt` version/ABI comments aligned to v3.0.0;
  `bitcask.app.src` `vsn` 2.2.0 → 3.0.0.

### Docs

- README (zh/en): drop the `set_synonym_map/2` function-table row; `open/2` docs gain
  the `{synonym_file, Path}` option; ROADMAP gains the libbitcask v3.0.0 upgrade entry.

## [2.2.0] — 2026-06-22

**libcask extraction** (per [ROADMAP §2.2.0](ROADMAP_EN.md)): the C++ core (24 source
files + 45 headers) is extracted into a standalone `libbitcask` (`libbitcask.a` static
/ `libbitcask.so` shared); the NIF layer retains only the glue. This repo's `cpp/`
shrinks to 9 NIF binding translation units; the single `priv/bitcask_cpp.so` links
statically against libbitcask (preserving LTO). Third-party deps (cppjieba /
googletest / benchmark / oneTBB / utf8proc / limonp / unordered_dense) are vendored
via the libbitcask submodule, with symlinks delegating to
`third_party/libbitcask/third_party/*`.

Milestones L1–L9 are all complete (see [`TASK.md` §L](TASK.md)); libbitcask has
advanced to **v1.1.0** in lockstep (stable C ABI + BCSC `search.ckpt` container +
HNSW V7 `search.vec` off-heap + InvVersion=6 FOR/VByte + three-tier performance
micro-opts + production-correctness fixes C1–C5).

### Added

- **`third_party/libbitcask` submodule** (v1.0.0 → v1.1.0): the complete C++ engine
  with a stable C ABI (38 `extern "C"` functions, `SOVERSION=1`). Standalone build
  via `cmake -S third_party/libbitcask -B build`; `find_package(Bitcask)` install
  support.
- **C++ core → standalone library** (L1–L9): 11 STATICs aggregated into
  `bitcask_static` (`ar`-merged `.a`) + `bitcask_shared` (`.so` + C wrapper);
  symbol-export policy (`-fvisibility=hidden` +
  `__attribute__((visibility("default")))`).
- **libbitcask v1.1.0 features synced**:
  - **Unified segmented search checkpoint `search.ckpt` (BCSC container)**: docmap
    / bm25.default / bm25.fields / hnsw each as one segment with **per-segment CRC**
    + footer directory + `.prev` generational fallback (replaces
    `search.docmap.ckpt` / `search.vec.ckpt` / `search.bm25.*` multi-file scheme).
  - **HNSW V7 / BVH2 v2 off-heap**: full-precision f32 vectors live in a dedicated
    `search.vec` file (`BCVP`, read-only mmap + 4 KB-page CRC32); the HNSW segment
    of `search.ckpt` (magic `BVH2`, version 2) embeds int8 quantized codes,
    eliminating the open-time requantization pass.
  - **Inverted-index on-disk format v6 (`InvVersion=6`)**: ords use FOR
    (Frame-of-Reference) block compression (128/block); tf/dl use VByte varint;
    formats v1–v5 are no longer readable.
  - **Three-tier performance micro-optimizations** (each measured-safe):
    HNSW rerank, WAND result sort, qcodes conditional allocation, FStats cache-line
    alignment (tier 1); KeyDir → `ankerl::unordered_dense` dense flat hash, HNSW
    adjacency bump-slab arena (tier 2); `thread_local` scratch/encode buffer reuse,
    serialize buffer reuse, hint `pread_into`, vector software prefetch,
    `-march=native` switch (tier 3).
  - **CI**: GitHub Actions matrix (Release + ASan/UBSan/TSan); crash-recovery
    regression tests (`fork + SIGKILL` mid-write +
    `MergeFailurePreservesKeyDirVisibility`).
  - **Production correctness fixes C1–C5** (see Changed section).
- **NIF adaptations (v1.1.0 API)**:
  - New atom `load_failed`; `set_synonym_map/2` returns `{error, load_failed}` on a
    failed file open (in v1.1.0 `load_from_file` is `[[nodiscard]] bool`; the prior
    implementation would silently install an empty dictionary).
  - New facade `bitcask:index_errors/1` (surfaces the v1.1.0 IndexPool exception
    counter from [`src/bitcask.erl`](src/bitcask.erl)).
- **Build system**: root `CMakeLists.txt` does
  `add_subdirectory(third_party/libbitcask)` to pull in all C++ targets;
  `cpp/CMakeLists.txt` now defines only the NIF binding (linking `bitcask_cask`).
  The third-party symlink loop covers 7 vendored libraries.
- **Index observability**: the async index worker's exception counter (`IndexErrors`)
  is surfaced in the `bitcask:status/1` NIF tuple (the facade does not expose it;
  read it via the new `bitcask:index_errors/1`). Non-zero ⇒ index may be drifting
  and search results may be stale.

### Changed

- **`cpp/` directory layout**: all C++ core sources and headers removed; only
  `cpp/nif/` remains (9 NIF TUs: `nif_main.cpp` / `nif_cask.cpp` /
  `nif_cask_iter.cpp` / `nif_cask_admin.cpp` / `nif_cask_meta.cpp` /
  `nif_helpers.cpp` / `nif_options.cpp` / `atoms.cpp` / `resources.cpp`).
- **`cpp/include/` → `third_party/libbitcask/include/`**: all C++ public headers
  move into the libbitcask library; the NIF accesses them via `bitcask/...`
  include paths (added by CMake automatically).
- **`cpp/c_api/` → `third_party/libbitcask/c_api/`**: the 38 `extern "C"` C API
  functions and their header move wholesale; `nm -D libbitcask.so` exposes only C
  ABI symbols.
- **Third-party vendoring**: utf8proc / cppjieba / limonp / googletest / benchmark
  / oneTBB / unordered_dense are all vendored as the libbitcask submodule; this
  repo's `third_party/` keeps only symlinks pointing to
  `third_party/libbitcask/third_party/*`.
- **KeyDir shard lock**: `shared_mutex` → `std::mutex` (kills writer-favor
  starvation); fstats switches to a lock-free publish path. Shard count advances
  to 256 (same as 2.1.1; implementation now lives in libbitcask).
- **`set_synonym_map/2` error behavior**: changes from "silently install empty
  dictionary" to "return `{error, load_failed}`" (knock-on adaptation to v1.1.0's
  tightened `load_from_file` API).
- **`status/1` NIF return tuple**: 4-tuple `{KeyCount, KeyBytes, Epoch, Files}`
  expands to 5-tuple with a new `IndexErrors` field (facade does not expose it;
  read it via the new `bitcask:index_errors/1`).

### Fixed (synced from libbitcask v1.1.0)

- **C1 — merge failure leaves keydir completely untouched** (delayed apply):
  failed merges don't require a restart-and-recover — data is immediately visible.
- **C2 — all 9 merge error paths now clean up**: no partially-written output files
  left behind.
- **C3 — IndexPool worker wrapped in a single try/catch** (best-effort discard +
  `index_errors` counter): exceptions no longer kill the worker; `pending_` always
  decrements → `flush()` no longer hangs; the index no longer silently drifts.
- **C4 — IndexPool destructor UB fix**: when `start()` was never called the
  `joinable()` guard skips the join; `stop()` is idempotent (CAS short-circuit).
- **C5 — `Cask::close()` (noexcept) wrapped in a top-level try/catch**: every
  throwing op (`save_search_ckpt` / `write_keydir_snapshot` / allocation / lock
  acquisition) is covered; even the registry-release inside the catch (itself the
  only remaining throw site) is wrapped separately — eliminates the `std::terminate`
  risk from a `noexcept` function throwing.
- Merge output is unconditionally fsync'd (success-return ⇒ new files are durable).

### Breaking changes

**None.** 2.2.0 is a pure structural extraction + performance/correctness
increment; the on-disk format (meta v2 / little-endian) is compatible with 2.1.1
and old directories open directly. The only externally-visible API behavior
changes:

- `set_synonym_map/2` now returns `{error, load_failed}` on a failed synonym file
  open (the prior version would silently install an empty dictionary) — code that
  relied on the silent behavior must adapt.
- `bitcask_cpp_nifs:cask_status/1` returns a 5-tuple instead of a 4-tuple (new
  `IndexErrors` field). Pure-facade users that don't call the NIF directly are not
  affected.

---

## [2.1.1] — 2026-06-17

The first round of **system-level optimizations** after the 2.1.0 C++23 engine —
focused on the vector-DB memory/disk walls, zero-copy read path, unified recovery
persistence, and a global endianness normalization. 428 GoogleTests green.

### Added

- **P5 — HNSW int8-only memory mode** (opt-in `{vector_inmem_int8, true}`): drops the
  resident f32 `vecs`; graph traversal, rerank, and query all operate at int8 (query
  quantized, VNNI int8×int8). Vector memory **−80% (~5×)** — 1M vectors at dim=2560
  drops from 12.81 GB to 2.57 GB; cost is ~−3% recall@10 (synthetic 1.0→0.965).
  Composes orthogonally with P3 on-disk int8. Default stays f32+int8 (recall first).
- **P6 — sealed-file mmap read path**: sealed (immutable) data files are mmap'd for
  zero-copy reads — no pread syscall, backed by OS page cache, no double-caching. The
  active file always uses pread. Merge unlink defers munmap via `shared_ptr<DataFile>`
  refcount (in-flight readers keep the mapping alive). Disabled on 32-bit.
  `GetResultView` holds a mapping ref to anchor lifetime.
- **P8 — HNSW merge-rebuild threshold gating**: gates full graph rebuild on the
  dead-node ratio (same pattern as P2) — skip rebuild below a threshold (`is_live`
  filter covers correctness), full rebuild at/above — saves the main merge CPU for
  vector mode.
- **P9 — read-handle fd-budget LRU** (`{max_read_handles, N}`): evicts read-only file
  handles by LRU / count cap, solving the fd-vs-ulimit problem at scale (complements
  P6's "close fd after mmap"). 0 = unlimited.
- **P10 — search_hybrid two-leg parallelism**: BM25 and HNSW legs run in parallel on
  a thread pool, roughly halving hybrid query latency.
- **P11 — merge I/O sequential tuning**: adds `posix_fadvise(SEQUENTIAL/WILLNEED)` +
  larger buffers to sequential merge reads/writes, cutting IO stalls.
- **P13 — on-open on-demand background merge** (`{merge_on_open, off|background}`):
  after open (read_write), gates on `needs_merge` and triggers merge **in the
  background** (never blocks open), consolidating small files.
- **P14 — recovery persistence unification**:
  - **P14a** checkpoint naming refactor (`.snap→.ckpt`, bm25 `.inv→.seg`/
    `.inv.wal→.wal`); contract `{kv|search}.{component}.{ckpt|seg|wal|manifest}`
    documented.
  - **P14b/P14e** single-file segmented `search.ckpt` (per-segment CRC + footer
    directory + segment-level dirty-flag reuse + generational `.prev` fallback) +
    single-pass tail replay (data files are the sole WAL; eliminates the 4-way
    pairwise-gate cliff, lifts replay reuse from ~0). Write amplification 2→1,
    search files 5→1, no more full fold after crash.
- **P15 — global endianness unification (little-endian) + migration tool**:
  - Unified all on-disk formats to little-endian (mmap reads with zero bswap;
    `static_assert` guarded).
  - `bitcask.meta` version 1→2; legacy v1 (big-endian) dirs are cleanly rejected
    (fail-loud).
  - `migrate_le` offline migration tool (data re-encode + hint regenerate + meta +
    field.schema + shadow flip); bilingual docs
    [`doc/migrate-le-en.md`](doc/migrate-le-en.md) / [`doc/migrate-le.md`](doc/migrate-le.md).
- **libcask extraction feasibility assessment**: see
  [`doc/libcask-extraction-zh.md`](doc/libcask-extraction-zh.md).

### Changed

- Checkpoint file suffixes globally renamed: keydir `.snap→.ckpt`, bm25
  `.inv→.seg`/`.inv.wal→.wal`, search multi-file → single `search.ckpt`.
- On-disk endianness changed from mixed (record/hint big-endian, vectors/snapshots
  little-endian) to **uniform little-endian**. `bitcask.meta` version bumped 1→2.

### Breaking changes

1. **On-disk endianness**: unified little-endian (meta v2). Legacy v1 (big-endian)
   dirs are **not read** — use the [`migrate_le`](doc/migrate-le-en.md) tool or start
   from a fresh directory.
2. **Checkpoint file naming**: `.snap`/`.inv`/`.inv.wal` suffixes are retired,
   replaced by `.ckpt`/`.seg`/`.wal` + `search.ckpt`. Old names are no longer read
   (rebuildable; first open after upgrade does one full fold, close writes new names).

### Candidate gate results

- **P7 (derived-value compute cache) ❌ rejected**: dequant derive is only 1-1.3×
  mmap access — negligible cache benefit; highlight is not a hot path (only triggered
  by `search_text_highlight`), too narrow a win.
- **P12 (meta_blobs_ bounded) ❌ rejected**: at 1M ords, access is 200-300 ns
  (`shared_lock` + vector copy), memory ~280 MB — acceptable at current scale; on-demand
  disk reads would introduce millisecond-level I/O on the search hot path (10000× slower).
  Revisit at >10M ords.

---

## [2.1.0] — 2026-06-15

A ground-up **C++23 rewrite** of the engine (single NIF, `priv/bitcask_cpp.so`)
that turns bitcask from a pure key/value store into a **KV + BM25 full-text +
HNSW vector search** engine, with heavy SIMD/AVX acceleration. The core Erlang
KV API (`get`/`put`/`delete`/`fold`/`merge`/…) is preserved; see
**Breaking changes** for what differs from the legacy 2.0.x line.

API reference: [`doc/api-en.md`](doc/api-en.md).

### Highlights
- C++23 NIF engine; typed-record on-disk format (`kDoc`/`kTombstone` + per-write
  ordinal + optional DocValue: text / fields / vector / meta).
- BM25 full-text search; HNSW approximate-nearest-neighbor vector search; RRF
  hybrid search fusing both.
- Pluggable embedder framework with auto-embed on write and on query.
- Extensive AVX/AVX-512/VNNI SIMD acceleration with runtime CPU dispatch and
  scalar fallback (see the dedicated section below).

### Added
- **BM25 full-text search**: `search_text` / `search_phrase` / `search_fields`
  (`field:term^boost`) / `search_near` (slop) / `search_fuzzy` (Levenshtein) /
  `search_wildcard` (`*` `?`). Synonyms (`set_synonym_map/2`), Porter stemming,
  snippet highlighting.
- **Analyzers**: whitespace, CJK n-gram, and jieba (CutForSearch + CJK fallback);
  NFKC normalization, optional stop-words, configurable n-gram bounds / min token
  length / stemming.
- **Search engine internals**: Block-Max WAND early termination, k-way leapfrog
  intersection, flat-array scoring, selective query cache (`SearchCache`),
  document-text LRU, inverted-index WAL + snapshot recovery.
- **HNSW vector search** (`search_vector`): multi-layer graph with heuristic edge
  selection, `cosine` / `l2` / `dot` metrics, int8 quantization (coarse filter +
  f32 rerank), BCVS snapshot persistence, dead-node eviction on merge.
- **RRF hybrid search** (`search_hybrid`): fuses BM25 and HNSW via
  `Σ 1/(60+rank)`; single-leg degeneration supported.
- **Embedder framework** (`bitcask_embedder`): `new/2` context API with
  `openai` / `anthropic` / `{custom, Mod}` providers; `put #{text => ...}`
  auto-embeds; `search_hybrid(H, Text)` / `search_hybrid(H, Text, auto, …)` and
  `search_vector(H, {text, _}, …)` auto-embed the query; `bitcask:embed/2`
  facade. Configurable `max_input_bytes` / `timeout_ms` / `connect_timeout_ms`.
  **MRL (Matryoshka)** support: `dim` (native) vs `vector_dim` (truncated, stored)
  — when they differ the request carries `dimensions` and the response length is
  validated.
- **Structured metadata + filters**: `encode_meta/1`; `eq`/`gte`/`lte`/`in`
  conditions with `and`/`or` and nesting on `search_text/4`, `search_vector/5`,
  `search_hybrid/5`.
- **P3 — on-disk int8 vector quantization** (opt-in `{vector_quantized, true}`):
  stores vectors as per-vector symmetric int8 codewords (`~4×` smaller on disk),
  persisted in `bitcask.meta` and validated on reopen; `get`/recovery dequantize
  transparently. Default stays f32 — measured recall@10 = 0.987 / @100 = 0.995 on
  synthetic dim=2560 (~1.3% @10 drop), so int8 is opt-in for disk-constrained
  deployments. Design + measurement: `doc/vector-ondisk-quant-design-zh.md`.
- **P4 — single-writer group commit** (`{sync_strategy, {puts, N}}`): fsync the
  active data file once every N writes (close/roll/sync force-flush), a middle
  ground between `none` and per-record `o_sync`. No cross-thread lock.
- **Streaming iteration**: `stream/1` + `next/1` + `stop/1` + `with_stream/2`,
  and `stream_fold/3,4`.
- **Bilingual docs**: API reference (`doc/api-en.md` / `doc/api-zh.md`),
  concurrency/lock-order, format, HNSW design, SIMD internals, and more.
- **Build/test**: CMake + rebar3 dual entry; ASan/UBSan/TSan presets; 400+ GoogleTests.

### Performance — AVX / SIMD instruction-set optimization
All kernels use **runtime CPU feature dispatch** (`AVX-512F → AVX2 → scalar`,
plus NEON paths where applicable), so a single binary runs everywhere and uses
the widest available instruction set; a scalar fallback always exists.

- **HNSW distance kernels**: AVX-512 (4× `__m512` accumulators) and AVX2+FMA
  implementations of dot / L2; `pick_kernel` selects the ISA once at construction.
- **int8 quantization (VNNI)**: `dpbusd`-based int8 distance kernel for the coarse
  filter, then f32 rerank — large recall-preserving speedups on AVX-512-VNNI CPUs.
- **Posting-list intersection**: u64 SIMD intersection on AVX-512 / AVX2 with the
  Inoue block-filter, plus galloping / scalar adaptive dispatch (u32 narrowing
  where ords fit); an AVX2 prototype measured ~3.46× over scalar.
- **BM25 scoring**: SIMD `tf_norm` (AVX2 8-wide / AVX-512 16-wide) and a unified
  `score_bow_topk` kernel; query-vector normalization in SIMD (double-precision
  dot + float scale).
- **Liveness gather**: `fill_is_live` / `fill_doc_lens` AVX2 gather with a
  sorted-ords fast path (dominant for recency queries).
- **CRC32**: PCLMULQDQ hardware acceleration (SSE4.2 + CLMUL) with a zlib fallback.
- **Fuzzy matching**: Myers bit-parallel edit distance (~11× faster than the DP
  baseline).

### Performance — persistence & write path
- **P1 — hint write buffering**: hint records accumulate in a 64 KiB in-memory
  buffer and flush on threshold / file roll / close, instead of one `write(2)`
  per put — roughly halves write-path syscalls. Hint is rebuildable, so a crash
  that loses the buffered tail just falls back to `fold(data)` (unchanged safety).
- **P2 — merge without re-tokenization**: post-merge the BM25 index is no longer
  fully rebuilt (which re-read and re-analyzed every live document). Postings key
  on the stable `ord`; `merge` already remaps storage locations via `on_relocate`
  and dead docs are filtered by `is_live`, so merge now only runs a
  threshold-gated `compact` (drop dead postings, no disk read, no NLP).

### Changed
- `bitcask:open/2` now configures the embedder via `{embedder, {Provider, Cfg}}`
  and auto-derives the collection dimension from the embedder's `vector_dim`
  (no separate `{vector_dim, N}` needed).
- KeyDir sharded to 256 shards with a writer-gate barrier (replaces the
  stop-the-world full barrier); at most one shard lock held at a time.
- Index updates run on an async single-writer `IndexPool` worker; reads/searches
  are lock-free and concurrent with it.
- Unified architecture: `Cask` and the former `Collection` merged into one engine
  selected by `{analyzer, ...}`; per-directory `bitcask.meta` records the mode.

### Fixed
- **Crash**: jieba analyzer was dropped by the static linker (self-registration in
  a separate TU) → `create(Jieba)` returned null → first text `put` segfaulted.
  Registration moved into the factory TU; `open` now fails cleanly if the analyzer
  can't be built.
- **Concurrency / memory** (read-path-vs-async-worker hardening): `meta_blob`
  returns a copy instead of an escaping span (use-after-free); search-cache
  `last_used` accessed uniformly via `atomic_ref`; `InvertedIndex::save` iterates
  the concurrent map safely; `max_indexed_ord_` made atomic; `IndexPool` consumer
  wrapped in try/catch (no `flush` hang / `std::terminate`); HNSW `load` releases
  pre-existing chunks; `ord_field_lens_` cleared on rebuild/snapshot load.
- **`{sync_strategy, {seconds, N}}`** was documented but never implemented in the
  C++ NIF (silently behaved as `none`); replaced by the implemented
  `{sync_strategy, {puts, N}}` (P4).
- **`bitcask:open/2` `case_clause` crash** on mode-mismatch: the NIF returns some
  faults (e.g. `mode_mismatch`) as a bare atom, which `open/2` didn't handle —
  now normalized to `{error, Reason}`.

### Breaking changes
1. **On-disk format**: new typed-record format (`kDoc`/`kTombstone` + per-write
   ordinal, optional DocValue). Legacy 2.0.x data files are **not** read by this
   engine — start from a fresh directory.
2. **`open/2` return value**: now `{CaskRef, EmbedderCtx}` (a 2-tuple), not a bare
   `reference()`. Pass it opaquely to all `bitcask:*` calls (those still work);
   code that pattern-matched a bare reference must adapt.
3. **Legacy iteration API removed**: `iterator/3` + `iterator_next/1` +
   `iterator_release/1` → use `stream/1`+`next/1`+`stop/1` / `with_stream/2`, or
   `fold/3,6` / `fold_keys/3,6`.
4. **`collection_*` API removed**: folded into the single engine; enable index
   mode with `{analyzer, _}`. `keydir_copy` / `deep_copy` are no longer exported.
5. **Build / runtime**: requires a C++23 toolchain and oneTBB to build the NIF;
   Erlang/OTP ≥ 22 (the OpenAI-compatible embedder uses the OTP 27+ `json`
   module). The engine ships as a single `priv/bitcask_cpp.so`.

---

## [2.0.3] and earlier
Legacy Erlang/C bitcask. See the git history before tag `2.0.3`.
