# Bitcask Roadmap

中文：[`ROADMAP.md`](ROADMAP.md)。Detailed sub-task breakdown & history in [`TASK.md`](TASK.md).

Legend: ✅ committed (will do) · ⚠️ candidate (gated by measurement).

---

## 2.1.1 plan

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
