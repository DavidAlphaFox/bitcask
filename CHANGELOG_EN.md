# Changelog (English)

中文版见 [`CHANGELOG.md`](CHANGELOG.md)。
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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
