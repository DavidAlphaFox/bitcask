# Changelog (English)

中文版见 [`CHANGELOG.md`](CHANGELOG.md)。
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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
