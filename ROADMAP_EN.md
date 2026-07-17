# Bitcask Roadmap

中文：[`ROADMAP.md`](ROADMAP.md)。Detailed sub-task breakdown & history in [`TASK.md`](TASK.md).

Legend: ✅ committed (will do) · ⚠️ candidate (gated by measurement).

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
