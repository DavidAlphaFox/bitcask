# Bitcask Roadmap

中文：[`ROADMAP.md`](ROADMAP.md)。Detailed sub-task breakdown & history in [`TASK.md`](TASK.md).

Legend: ✅ committed (will do) · ⚠️ candidate (gated by measurement).

---

## 6.0.0 shipped

### libbitcask v5.0.0 → 6.0.0 upgrade ✅

One step across two upstream releases, **5.1.0 and 6.0.0**. It is an ABI break
(`CaskOptions` gains `keydir_cache_entries` → struct layout change, `SOVERSION`
5 → 6), but this repo depends on libbitcask at the source level (submodule +
`add_subdirectory`), so a rebuild is all it takes — there is no stale `.so.5` to
link against. Upstream's public API is **purely additive** with respect to
everything this repo already touched: the NIF compiled unchanged.

> ⚠️ **Existing directories must be migrated offline first.** Upstream 5.1.0's
> hint-embedded-ord flag day moves `bitcask.meta` v4 → **v5**, so directories
> written by this repo's 5.x line are **cleanly refused** by 6.0.0 (old bytes are
> never reinterpreted under the new semantics). The migration is
> non-destructive — data files are hard-linked with zero byte changes, only
> hints + meta are regenerated — and it is idempotent and re-runnable:
>
> ```sh
> _build/cmake/libbitcask-build/bitcask_migrate hintord <old-dir> <new-dir>
> ```
>
> The reverse does not hold: directories written by 6.0.0 cannot be opened by
> older versions. Upgrade in one direction only.

### Ordered range queries: `range/2,3` + `range_fold/5` ✅

Walks `[Lo, Hi)` in key lexicographic order at **O(range)** cost instead of
filtering the whole table (upstream measured 100k keys at 1/256 selectivity:
8.0 ms → **0.53 ms**). The foundation is upstream S33's OKI ordered-key index (a
derived cache — if it fails validation it is discarded and rebuilt wholesale).
`{prefetch, N}` fetches values concurrently in batches, changing *when* values
are read and **never the output order or contents**.

> ⚠️ Consistency is **per-key weak** (the same tier as `parallel_scan`), not
> `fold/3`'s snapshot semantics — writes concurrent with the iteration may be
> partially visible. That is the deliberate trade: you cannot have O(range) and a
> frozen keydir at once. Call sites that need a snapshot keep using `fold`.

### Crash-atomic batches and multi-key transactions: `put_batch_atomic/2` + `txn_commit/2,3` ✅

After a crash or power loss the batch **either fully applies or does not apply at
all** (the on-disk batch header declares the extent; an incomplete extent
truncates the whole batch at recovery), with no intent-log write amplification.
`txn_commit` layers validation on top (non-empty, non-empty keys, no duplicates,
no `_txn:` prefix); a violation returns `{error, {invalid_option, Msg}}` with
**zero side effects**.

> ⚠️ **You get A and D — not I, and no CAS.** Intermediate transaction state is
> visible to concurrent readers, and concurrent commits with overlapping key sets
> have no ordering guarantee; serialize those in your application. Do not treat
> this as a database transaction.
> ⚠️ **The first call lazily upgrades the directory's meta to v6**, after which
> readers older than upstream 5.1.0 cannot open it. Directories that never call
> it stay at v5 and remain mutually openable with older readers — this
> "upgrade only when used" design leaves deployments that don't need atomic
> batches completely unaffected.

### Disk-resident keydir: `{keydir_cache_entries, N}` ⚠️ (opt-in, off by default)

The keydir degrades to a hot cache; point lookups resolve through cache →
memdelta → BCOK v2 run (embedded bloom + block LRU, cold get ≤2 preads).
Upstream measured 100M `doc:` keys: 11 GB resident → **1.14 GB peak while
loading / 0.80 GB on reopen (-90%)**, with no regression on hot get/put/merge.

> Defaults to `0` (unlimited = today's fully in-memory behaviour). ⚠️ Enabling it
> for the first time on a directory without the Level B stamp triggers a **full
> OKI rebuild** (one slow open); `merge_only` sidecars and Level B directories
> are **mutually exclusive**.
> This repo only wired the option through and smoke-tested it — **the large-scale
> numbers above are upstream's**. Measure on your own data shape before turning
> it on in production.

### Error detail passthrough ✅

`bitcask:open/2` failures now carry their reason:
`{error, {io_error | invalid_option, DetailBinary}}`. Upstream's two
message-only failure classes (no errno, no dedicated enum) previously collapsed
to `{error, unknown}` and `{error, error}`, losing everything — and the epoch
gate's migration hint travels exactly that path. **Every other failure shape is
unchanged** (notably `{error, write_locked}`, still a bare atom).

---

## 5.1.0 shipped

### Local embedding backend (llama.cpp / ggml) ✅

Computes embeddings in-process, with no HTTP endpoint. The artifact is a
**second, independent NIF**, `priv/bitcask_llama.so`, with no coupling to the
core `bitcask_cpp.so`; **not built by default** (`BITCASK_WITH_LLAMA=1`), and
with it off the build output is byte-for-byte what 5.0.0 produced. Adds the
`third_party/llama.cpp` submodule (tag `b10257`). **No libbitcask upgrade is
involved**, no ABI change, no on-disk format change.

It is positioned as **a different tier**, not a replacement for the HTTP
endpoint: what runs on CPU is the 0.6B / 1024-dim class, so switching tiers
changes the stored dimension and means a full index rebuild. Measured (8 vCPU,
`Qwen3-Embedding-0.6B-Q8_0`, `n_ctx=512`): query 33–35 ms, document (276 tokens)
≈ 890 ms.

> ⚠️ **ggml's `GGML_ASSERT` calls `abort()`**, which inside the BEAM takes down
> the entire node along with every open cask. Splitting into two `.so`s cannot
> isolate that (same process); all that can be done is catching the predictable
> failures before llama sees them (path / pooling / token count). True process
> isolation means a port — which is exactly the existing HTTP endpoint. If that
> risk is unacceptable, stay on the HTTP tier.

### Standalone embedder process ✅

`bitcask_embedder_server` (gen_server) + `bitcask_embedder_proxy` (provider).
`{embedder, _}` at `open/2` now also accepts a process reference. Three problems,
one fix: **one copy of the weights** (previously one ctx per `open`), **the
lifecycle has an owner** (`bitcask:close/1` does not close the embedder; the
process's `terminate/2` does), and **serialization was required anyway**
(`llama_context` is not thread-safe, and a gen_server's single-process semantics
*are* that constraint).

This also draws the line between the two embedder tiers: the HTTP tier (`openai`
/ `anthropic`) is stateless and wants concurrency — **no process to configure**;
the built-in tier is stateful and must be serialized, so it runs in a process.
Shared logic moved into `bitcask_embedder_util` (openai and anthropic previously
carried verbatim duplicates).

> ⚠️ An embedder that is configured but fails to start (bad GGUF path, pooling
> resolving to NONE, …) fails the whole bitcask application, **deliberately** —
> silently degrading to no embedding capability is only noticed once the search
> results are wrong, by which point the store is dirty. For the same reason
> `bitcask:open/2` no longer swallows an `application:start` failure (it returns
> `{error, {bitcask_app_start_failed, _}}`).

### GPU (NVIDIA CUDA / Vulkan) ✅

The trade-off for a server-side product is **performance first, size is not a
constraint**: CUDA architecture coverage spans Maxwell..Blackwell rather than
narrowing to native, and the CUDA runtime is flattened into `priv/` alongside the
package — removing the silent "target is missing libcublas → ggml skips the
backend → degrades to CPU" class of failure.

**Build time probes the SDK, run time probes the GPU** — these happen on
**different machines** (the build box often has no card, the deployment box often
has no SDK), so they are done separately:

- **Build time**: `BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN`, each
  `AUTO|ON|OFF` (default AUTO — compiled in whenever the SDK is detected; both
  can be on). The build-time facts are baked into the `.so` and reported by
  `build_info/0`. ⚠️ Vulkan's AUTO must confirm **all three** of loader /
  `glslc` / SPIRV-Headers before enabling — ggml-vulkan declares both of its
  `find_package` calls `REQUIRED`, so a partial match fails the build outright.
- **Run time**: Erlang decides **by itself** via `backend => auto`
  (CUDA > Vulkan > CPU), taking the first family that actually has a GPU;
  `n_gpu_layers` also defaults to auto. **No per-machine configuration and no
  script** — a deployment box has neither this repository nor cmake.
- `gpu_status/0` reconciles the two: `ok` / `cpu_only_build` (rebuild) /
  `no_gpu_device` (install a driver). Run time alone cannot tell those apart, and
  they need completely different fixes.

> ⚠️ **Picking exactly one family is a correctness requirement, not a policy.**
> With CUDA and Vulkan both compiled in, each enumerates the same physical card
> (one 4090 = `CUDA0` + `Vulkan0`), and `devices=NULL` makes llama split the
> model's layers across what it thinks are two cards — no error, just
> double-booked VRAM and mysterious slowness or OOM.

**Multiple GPUs: one card by default, data parallelism.** llama's `split_mode`
defaults to `LAYER` (split layers across every card). For an embedding model that
is a pessimization: 0.6B of weights fits on one card, so splitting only adds
cross-GPU transfers, and it spends N cards' worth of parallelism on **one serial**
request path (a single `llama_context` serves one forward at a time). Embedding
wants data parallelism — size a pool of embedder processes from
`backend_info/0`'s device list, one bound per card (`gpu_index`), which maps
exactly onto "one handle = one context = serial". Model parallelism
(`split_mode => layer`) is only for a large model that does not fit on one card.

**Multiple GPUs: all layers on one card, N instances (data parallelism).**
`bitcask_embedder_pool` starts N embedder processes from the application env's
`instances => [0,1,2,3]`, one bound per card. llama's `split_mode` defaults to
`LAYER` (split layers across every card), which is a pessimization for embedding
models: 0.6B fits on one card, splitting only adds cross-GPU transfers, and **a
single `llama_context` serves one forward at a time** — after splitting, N cards
are still working on 1 request. Data parallelism is what you want: N requests
genuinely concurrent, and per-card VRAM is still one copy of the weights.

> ⚠️ **No coordinator on the hot path.** The pool is a **supervisor** and
> forwards no `embed`: workers register under stable names (unchanged across
> restarts, so caches stay valid) and callers talk to a worker directly, zero
> hops. Routing through a process that `gen_server:call`s the workers would make
> that process the new serialization point, rendering the N workers pointless.
>
> `instances` takes either an explicit list of cards (or groups) or `auto` (the
> provider probes for cards that are **enumerated and can fit the model**).
> `per_gpu => K` then runs K contexts per card (explicit option; no measured data,
> so never a default).
>
> ⚠️ **The failure policy is deliberately asymmetric**: an explicit list means all
> must start (naming a card is a statement of intent); `auto` is best effort —
> failures are skipped and only zero started is a failure. `status/1` reports
> requested / started / missing, because best effort has to come with saying so.
>
> ⚠️ `auto` does **not guess which cards to take**: visibility is controlled by
> `GGML_CUDA_DEVICES` / `CUDA_VISIBLE_DEVICES` / `GGML_VK_VISIBLE_DEVICES` /
> container passthrough, which is the operator-side standard. With no usable card
> it degenerates to one unbound CPU instance rather than erroring.
>
> ⚠️ **Startup is sequential** (N model loads). Deliberately not parallel or lazy
> — that would let a worker's startup failure bypass the supervisor's start-time
> check, which is exactly what the "configured but failing kills the application"
> policy rests on.

**Three ways out when it does not fit on one card**: partial offload
(`n_gpu_layers => N`, preferred), across cards (`instances => [[0,1]]`,
concurrency traded for capacity), or a smaller quantization. A **coarse
pre-check** before loading returns `{error, {model_too_large, _}}` with those
options when it clearly will not fit — but it is never used to pick
`n_gpu_layers` automatically (guessing low means silently offloading too few
layers). Without it, "does not fit" shows up as llama OOM → fallback → **the
whole model back on CPU**.

**Batch embedding** `embed_batch/2` ✅: the llama backend feeds several sequences
per decode and returns per-item results. It is an optional `bitcask_embedder`
callback, so providers without it fall back to sequential encoding transparently.
With a pool, a batch is split and dispatched concurrently across workers.
⚠️ `n_ctx` must be multiplied by `batch_size` (llama's `n_ctx` is shared across
sequences), or enabling batching silently shrinks each text's usable length N-fold.
The HTTP tier (openai / anthropic) implements native batching too: one request
carries an array, chunked by `max_batch`. ⚠️ Responses are **placed by the `index`
field, not zipped in return order** — zipping by order attaches vectors to the
wrong documents with no error and correct dimensions. The two HTTP providers'
formerly identical request/parse code moved into `bitcask_embedder_util`, with the
parsing exposed as a pure function and 14 network-free unit tests added (it
previously had only a manual, skipped-by-default case).

**Off by default**: measured 7.0x on short texts and 2.9x on medium ones, but the
measurement box had external load which inflates the ratio, and the long-text case
has no trustworthy data — measure on your own hardware before enabling.

The build-time SDK probe `scripts/detect-llama-backends.sh`: CMake only says "not
found"; the script says **which package is missing** and prints the build command
pre-filled with whichever switches it detected.

> **The Vulkan build path was exercised for real**: the development box has a
> Vulkan SDK (1.4.309), AUTO detected and compiled it in, and
> `priv/libggml-vulkan.so` was produced. Since that machine has no GPU,
> `gpu_status/0` returns `no_gpu_device` rather than `cpu_only_build` — **exactly
> the distinction the build/run-time split exists to make, demonstrated with real
> data**.
>
> ⚠️ **The CUDA compile and any real GPU runtime path remain unexercised** (no
> driver and no toolkit on the development box; the Vulkan backend was only
> compiled, never run against a card). Verified: both AUTO detection branches,
> build-time macro injection and self-report, honest diagnostics when no GPU is
> present, and the validation/error paths for `backend` / `gpu_index` /
> `split_mode`.

### Candidates ⚠️

- **Optional `close/1` callback on `bitcask_embedder`** (gated): would let
  `bitcask:close/1` release a ctx built via the `{Provider, Cfg}` path. Currently
  side-stepped by the process form, and touching the core API has no obvious
  payoff.
- **Trustworthy batch calibration** (gated): the current numbers were taken on a
  box with external load, which inflates the ratio, and the long-text case has no
  conclusion. A re-measure on a quiet machine is needed before recommending a
  default.
- **Real multi-GPU measurement** (gated): the pool mechanism is thoroughly tested
  with the mock provider, but **real GPU behaviour on a multi-card box has never
  been exercised** (no card on the development machine). The `gpu_index` range
  check, the card group's `mp.devices` plumbing and the actual effect of
  `split_mode` have only been verified along the parameter path.
- **ROCm / SYCL backends** (gated): ggml has both, wired the same way as Vulkan.
  Whether to add them depends on whether such cards show up in real deployments.

---

## 5.0.0 shipped

### libbitcask upgrade to v5.0.0 ✅

The submodule advances from v4.1.0 to **v5.0.0** (64-bit timestamp flag-day:
`tstamp` / `expiry_at` widen from u32 to u64 end to end, for Y2038 readiness;
`SOVERSION` 4 → **5**, breaking both the ABI and the **on-disk format**). This
repo aligns to 5.0.0 in lockstep.

The on-disk format turns over wholesale: data record header 23B → 27B, DocValue
v3 → v4, hint `BCH3` → `BCH4`, keydir snapshot BCKS v2 → v3, and `bitcask.meta`
v3 → **v4** (a gate that cleanly refuses old u32-era databases — old bytes are
never silently misread at the new offsets). The library also fixes a u32
wraparound where a huge `expiry_secs` misjudged every key in the database as
expired. NIF adaptation is 2 lines (iterator `tstamp` returns switch to
`enif_make_uint64`); no API change for Erlang callers.

> ⚠️ Migrating existing databases: upstream's unified migration tool
> `bitcask_migrate tstamp64 <src> <dst>` performs a non-destructive offline
> migration (probe the era first with the `detect` subcommand); no re-ingest
> needed.

---

## 4.0.0 shipped

### libbitcask upgrade to v4.0.0 ✅

The submodule advances from v3.1.0 to **v4.0.0** (S32 vector dual-engine +
S29-11-②④ AVX2 int8 kernels + disk-segment UB audit; `SOVERSION` 3 → **4** —
two `bitcask_options_t` layout changes make this an ABI break, while staying
**fully source-compatible**: recompiling the NIF is all it takes). This repo
aligns to 4.0.0 in lockstep.

New `open/2` option `{vector_engine, hnsw | ivfrq | diskann}` (vector dual-engine,
picked once at creation and persisted in `bitcask.meta`), vector-engine tuning
options (`hnsw_m` / `hnsw_ef_construction` / `hnsw_build_nav_int8` /
`vector_rebase_min_docs` / `vector_ivf_nlist` / `vector_ivf_nprobe` /
`vector_diskann_r` / `vector_diskann_l_build`), and
`{auto_checkpoint_min_docs, N}` (bounded crash-recovery replay window). The
library ships with the IVF-RaBitQ-lite engine (100k/384d queries at 36.5µs,
recall loss ≤0.08pt), the DiskANN engine (experimental), AVX2 int8 dot-product
kernels (VNNI512→VNNI256→AVX2 dispatch; full int8 path active on non-VNNI
machines), bounded vector-checkpoint crash recovery (worst case ~4.2M → ≤320K
entries), and HNSW `.qc8` codeword mmap + `clone_live` payload spill. The
`examples/` directory gains a Wikipedia search-database example (`wiki_hnsw` /
`wiki_diskann` dual-engine comparison).

> ⚠️ ABI break: soname `libbitcask.so.3` → `libbitcask.so.4`; downstream must
> recompile/relink. No breaking API change for Erlang callers — behavior is
> unchanged when the new options are not passed (vector engine still defaults
> to HNSW).

---

## 3.1.0 shipped

### libbitcask upgrade to v3.1.0 ✅

The submodule advances from v3.0.0 to **v3.1.0** (the S12 whole-library audit
batch; `SOVERSION` stays **3**, ABI unbroken — a backward-compatible feature
addition). This repo aligns to 3.1.0 in lockstep.

New `open/2` option `{max_read_handles, unlimited}` (explicit no-limit),
`{auto_compact_dead_ratio, R}` (index-mode auto compaction inside the reducer
thread, bounding posting-list memory under churn), and error atom `closed`
(calls on an already-closed handle return `{error, closed}`). The library
brings: default read-handle cap (`{max_read_handles, N}` default `0` changes
from "unlimited" to auto-derived from `RLIMIT_NOFILE`), `bitcask.meta` v2 → v3
with CRC32, field.schema FSCH v1 header + CRC, C API batch search ×3 +
`parallel_scan` + `BITCASK_ERR_CLOSED`, and a `-Werror` library-build guard.

> ⚠️ On-disk format is forward-incompatible: `bitcask.meta` bumps to v3 (adds
> CRC32). Databases written by this version cannot be opened by the old 3.0.0;
> backward-compatible — this version reads old databases (v2 meta compat-read,
> legacy field.schema auto-upgraded to FSCH v1). Upgrade one-way only.

---

## 3.0.0 shipped

### libbitcask upgrade to v3.0.0 ✅

The submodule advances from v1.1.0 to **v3.0.0** (libbitcask unifies its three version
numbers: CHANGELOG = library `VERSION` = C API = `3.0.0`, `SOVERSION` 1 → 3); this repo
aligns to 3.0.0 in lockstep. The v1.2.0 engine capabilities it brings are especially
relevant to graph workloads: a **thread-safe `Cask` handle** (one handle shared across
actors: internally serialized writes, concurrent reads/search, fail-fast `close()`),
**`parallel_scan`** full-table parallel scan (analytics / export / reindex — a fit for
parallel whole-graph loading), batch retrieval, and the async-index MapReduce pipeline;
on-disk meta bumped to v2.

Consumer-side adaptation (breaking): **the runtime `bitcask:set_synonym_map/2` is
removed**; the synonym dictionary becomes the open-time immutable `open/2` option
`{synonym_file, Path}` (mirrors libbitcask `CaskOptions::synonym_map`: loaded once at
open, immutable thereafter → naturally concurrency-safe for queries). The NIF is
recompiled/relinked (ABI `SOVERSION` 1 → 3).

> ⚠️ ABI break: soname `libbitcask.so.1` → `libbitcask.so.3`; downstream must
> recompile/relink. On-disk: KV data/hint (meta v2) compatible; swapping synonym
> dictionaries at runtime now requires reopening the database.

---

## 2.2.0 plan

### libcask standalone extraction ✅

> Feasibility assessment: [`doc/libcask-extraction-zh.md`](doc/libcask-extraction-zh.md)

Extract the C++ non-NIF core (`cpp/src/` + `cpp/include/`, 24 source files + 45 headers)
into a standalone `libcask.so` / `libcask.a`; the Erlang project retains only the NIF
glue layer (`cpp/nif/`) and depends on the library.

The architecture is already separation-ready:
- Zero `erl_nif.h` dependency and zero `enif_*` calls in the C++ core
- Build system already modularized (11 static libraries; `cpp/CMakeLists.txt` supports
  standalone builds)
- Coupling is one-directional and paper-thin (NIF → C++, no reverse calls; the sole
  bridge is `CaskHandle { unique_ptr<Cask> }`)

**Path A (C++ API direct, recommended)**: export C++ classes, NIF layer includes
directly, minimal changes, preserves LTO.
**Path B (C API wrapper)**: additional `extern "C"` wrapper, stable ABI, enables
cross-language bindings (Python/Rust).

### V7+ vector optimization ⚠️

> Industry analysis: [`doc/vector-ondisk-quant-design-zh.md`](doc/vector-ondisk-quant-design-zh.md) §9-11

- **DiskANN-style large-scale architecture**: V3.5 BCVS snapshot already delivers 46×
  load speedup; 100M+ scale needs DiskANN-style "external graph + PQ coarse filter +
  SSD rerank" layered architecture.
- **Product Quantization (PQ)**: offline training pipeline is a separate project;
  V6.4.1 left a seam.
- **Vamana / robust prune**: DiskANN graph-build algorithm (α parameter + robust prune)
  research reserve; disk-friendliness analysis in §11.
- **HNSW external-memory mmap**: 100M+ scale is a different class of design (paged graph
  mmap + SSD-friendly layout).

---

## 2.1.1 shipped

Three optimizations targeting the **vector-DB memory / disk walls** and the **read path**.

### P5 — HNSW int8-only memory mode ✅

> Design: [`doc/hnsw-int8-only-design-zh.md`](doc/hnsw-int8-only-design-zh.md)

**Problem**: in dot mode the HNSW keeps both f32 `vecs` and int8 `qcodes` resident
(int8 is for VNNI speed, costing +25% memory); P3's on-disk int8 only saves disk,
not memory — and memory is the real wall for a vector DB.

**Approach**: drop the resident f32, run graph traversal *and* rerank at int8
(query also quantized, VNNI int8×int8), opt-in `{vector_inmem_int8, true}`;
composes with P3 on-disk int8 (save both disk and memory).

**Measured** (synthetic clusters, dim=2560, `hnsw_test::Int8OnlyMemoryAndRecall`):
vector memory **−80% (~5×)**, 1M vectors 12.81 GB → 2.57 GB; cost **recall@10 ≈ −3%**
(1.0 → 0.9675).

**Sub-tasks**: P5a config + drop `vecs` from NodeChunk; P5b open/meta wiring +
reopen-consistency check; P5c real-corpus recall gate to set the default.
**Red line**: default stays f32+int8 (recall first); int8-only is an opt-in for
memory-constrained / large-scale deployments.

### P6 — sealed-file mmap read path ✅

> Design: [`doc/sealed-mmap-read-design-zh.md`](doc/sealed-mmap-read-design-zh.md)

**Goal**: mmap **sealed (immutable)** data files for reads — **zero-copy, no pread
syscall**, backed directly by the OS page cache, **no double-caching**. The **active
file always stays pread** (append-growth is mmap-hostile: fixed map length,
SIGBUS-past-EOF, remap address churn).

**Sub-tasks**:
- **P6a** `DataFile` sealed mmap mode: mmap the whole file on first read of a sealed
  file, `read` returns a span into the mapping; active / over-limit fall back to pread;
  close the fd after mmap (also relieves the read_files_ fd accumulation vs ulimit).
- **P6b lifetime across merge (the crux)**: on unlink, **do not munmap immediately** —
  defer munmap to refcount drop via `shared_ptr<DataFile>` (in-flight readers keep it
  alive; on Linux an unlinked-but-mapped file is still readable); re-mmap merge outputs
  / freshly-sealed (rolled) files lazily on the next `read_file`.
- **P6c** `GetResultView` holds the mapping ref + `mmap_limit` (file count / bytes) +
  pread fallback + disable on 32-bit.

**Model**: LevelDB SSTable — immutable files + refcounted deferred deletion + mmap
limit + pread fallback. **Invariant**: only sealed files are mmap'd (merge only
unlinks, never truncates in place → no SIGBUS-on-truncate).

### P7 — derived-value compute cache (on top of mmap) ⚠️ candidate

> Design: [`doc/derived-compute-cache-design-zh.md`](doc/derived-compute-cache-design-zh.md)

**Positioning**: with mmap, an LRU's role **changes** — it caches **derived / decoded
results that cost real CPU to recompute**, **not raw bytes** (mmap + page cache already
optimal; caching raw bytes double-caches and competes with the kernel for RAM). It
saves recompute, not I/O (same split as LevelDB: mmap fetches bytes, block LRU caches
decompressed blocks). Plain KV value decode is ~free → **not cached**.

**Rules**: key by **logical id (key/ord)** (content stable across merge); store owned
`shared_ptr<const Derived>` (**never an mmap span** → decoupled from munmap/merge, no
UAF); byte budget + shared_mutex; invalidate by key on put/delete, no invalidation on
merge.
**First targets**: ① highlight NFKC + tokenize offsets (currently recomputed per
highlight); ② int8→f32 dequantized vectors.
**Gate**: only when derive cost ≫ mmap access. **Depends on P6**.

### P8 — HNSW merge-rebuild threshold gating ✅

> Design: [`doc/hnsw-merge-gate-design-zh.md`](doc/hnsw-merge-gate-design-zh.md)

Merge currently **rebuilds the whole HNSW graph unconditionally** (re-inserts every live
vector); but queries already filter dead nodes via `is_live` → the rebuild is **pure
physical compaction, not needed for correctness**. Gate it on the **dead-node ratio**:
skip rebuild below a threshold, full rebuild at/above. **Same pattern as P2** (BM25 no
re-tokenize) — saves the main CPU cost of a vector-mode merge.

### P9 — read_files_ fd-budget LRU ✅

> Design: [`doc/read-handle-lru-design-zh.md`](doc/read-handle-lru-design-zh.md)

`read_files_` (read-only file handles) keeps one fd resident per file with **no eviction**
→ large stores hit the ulimit. Evict read handles by LRU / count cap (complements P6's
"close fd after mmap").

### P10 — search_hybrid two-leg parallelism ✅

> Design: [`doc/hybrid-parallel-design-zh.md`](doc/hybrid-parallel-design-zh.md)

`search_text` → `search_vector` currently run **serially** before RRF fusion; the two legs
are independent → run them on a thread pool in **parallel**, ~halving hybrid query latency
(mind filter / cache sharing concurrency).

### P11 — merge I/O sequential tuning ✅

> Design: [`doc/merge-io-tuning-design-zh.md`](doc/merge-io-tuning-design-zh.md)

Merge reads old files / writes new files sequentially with no readahead hint. Add
`posix_fadvise(SEQUENTIAL/WILLNEED)` + larger buffers to cut merge IO stalls (low cost).

### P12 — meta_blobs_ on-demand / bounded ⚠️ candidate

> Design: [`doc/meta-blob-residency-design-zh.md`](doc/meta-blob-residency-design-zh.md)

`Index::meta_blobs_` keeps every ord's meta blob **fully resident** (for filter eval);
could switch to a bounded LRU or on-demand disk read. **But filter is on the hot search
path, so on-demand reads would slow it → needs a gate**, hence candidate.

### P13 — on-open on-demand background merge (small-file consolidation) ✅

> Design: [`doc/open-merge-design-zh.md`](doc/open-merge-design-zh.md)

**Root cause**: every read_write session's first write creates a **new** active file
(file_id is monotonic, never reused, never reopens an old file for append — by design);
many "open-write-close" cycles accumulate many small files.
**Correction**: consolidation does **not** speed individual gets (keydir is O(1)); the real
wins are **open cost / fd / mmap-friendliness / dead-space reclaim**.
**Plan A (committed)**: after open (read_write), gate on `needs_merge` (reuse
`small_file_threshold` etc.) and trigger merge **in the background** (merge_worker / dirty
scheduler, **never blocking open**), collapsing to a few sealed files + a fresh active.
Reuses the whole existing merge stack — mostly trigger wiring + a
`{merge_on_open, off|background}` option. **Rejected**: unconditional/synchronous
merge-on-open (O(data) startup, defeats snapshot fast-open).
**Plan B (candidate)**: reopen the last non-full sealed file to append — stops small files
at the source, but needs un-sealing, breaks the sealed-immutable invariant (conflicts with
P6), and is invasive; candidate only.

---

## Shipped (2.1.0, persistence optimizations P1–P4)

- **P1** hint write buffering (halves write-path syscalls)
- **P2** merge without re-tokenization (compact instead of rebuild_index)
- **P3** on-disk int8 vector quantization (opt-in `{vector_quantized}`, ~4× disk)
- **P4** single-writer group commit (`{sync_strategy, {puts, N}}`)

See [`CHANGELOG_EN.md`](CHANGELOG_EN.md).
