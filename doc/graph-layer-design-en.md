# Graph Storage Layer (KV per-key: k = vertex, OKI range traversal)

中文版：[graph-layer-design-zh.md](graph-layer-design-zh.md)。This document defines the
graph storage scheme built on libbitcask as the sole storage engine with Erlang as the
execution layer.

Status: 📐 Design. **This document supersedes the 2.2.1 "whole graph as one CSR value"
scheme**: its core constraint (hash keydir → no prefix scans, range degrades to
O(all keys)) was invalidated by the OKI ordered-range capability shipped in 6.0.0.
The original CSR on-disk format is not discarded — it is demoted to the OLAP
materialized-cache layer of this design (§7). Implementation status: **P1–P5 landed**
(`src/graphdb.erl`, `src/graphdb_analytics.erl`, `test/graphdb_tests.erl`,
`test/graphdb_analytics_tests.erl`, `test/graphdb_bench`).

---

## 1. Positioning and one-sentence model

```
n  <vid>  → vertex payload (DocValue: props + optional text / vector)
e  ...    → out-edge (source-side view)
ei ...    → reverse navigation key (dst-side view, empty value)
```

**One vertex = one KV pair; one edge = two KV pairs.** libbitcask serves as both the
persistence layer and the adjacency index: fetching neighbors is one O(degree) prefix
range; random vertex/edge access is O(1) keydir + a single `pread`. Traversal hops
through the graph in BEAM memory — there is no "whole graph materialization" step on
the hot path.

The reference point is still Neo4j's property graph + index-free adjacency, on a
different medium:

| | Neo4j | Whole-graph CSR (old scheme) | This scheme |
|---|---|---|---|
| Adjacency | on-disk doubly-linked lists | in-memory CSR array slices | **on-disk key-ordered adjacency + prefix range** |
| Neighbor fetch | O(degree) pointer chasing (disk) | O(degree) array slice (memory) | O(degree) one seek + merge + pread |
| Random point lookup | on-disk record | requires whole graph in memory | **O(1) keydir, native** |
| Per-graph size cap | unbounded on disk | ≤ 4 GiB (`kMaxValueSize`) + whole graph in RAM | **unbounded; memory holds only hot data** |
| Writes | online random writes | overlay + whole-graph checkpoint | **online random writes, durable per write** |
| Consistency | read committed | whole-graph snapshot | per-hop per-key consistent (§6.5) |

Positioning: **graph OLTP** (online traversal, point lookups, property search,
small-to-medium fan-out multi-hop). Whole-graph iterative analytics (PageRank /
connected components) is uneconomical hop-by-hop — use the §7 materialized cache.
The two tiers complement each other; they are not either/or.

---

## 2. Why the old constraint died

The only argument against the per-key model in the 2.2.1 scheme: *the keydir is a hash
table (unordered) with no efficient prefix/range scan; flattening the graph into
per-vertex / per-edge keys degrades neighbor lookup to O(total edges)*. The OKI
(ordered key index, see libbitcask `doc/ordered-key-index-design-zh.md`) shipped in
6.0.0 invalidates this point by point:

- **`range/3` iterates [Lo, Hi) in lexicographic order at O(range) cost** — upstream
  measured 8.0 ms → 0.53 ms at 1/256 selectivity; prefix scans are syntactic sugar
  (`Lo = prefix`, `Hi = lexicographic successor of prefix`).
- **Zero index-building cost**: the put path appends to the OKI memdelta (write-path
  budget ≤ 3%); above a threshold it flushes to immutable runs; missing/corrupt files
  are rebuilt from a fold (derived-cache semantics). **Write an edge key and the
  adjacency index exists** — there is no "build the graph index" step.
- **Atomic batches close the dual-write gap**: `put_batch_atomic` (S35 engine atomic
  batches) is all-or-nothing across crashes. TAO writes reverse edges across shards
  non-atomically (hanging associations + async repair) and NebulaGraph reserves a
  placeholder byte for TOSS — this problem has an engine-level answer here.
- What remains is two honest, documented caveats: **per-key weak consistency** (same
  tier as `parallel_scan`, not a fold snapshot) and **range refusing to answer when
  OKI is unavailable** (split into `{error, no_index}` / `{error, index_rebuild_failed}`
  since 6.1.0; falls back to fold + prefix filtering).

---

## 3. Key layout (on-disk contract)

### 3.1 Families

| Family | key layout | value | purpose |
|---|---|---|---|
| `n` | `"n" + <vid:u64 BE>` | vertex DocValue | vertex payload; put_doc path → BM25 / vector for free |
| `e` | `"e" + <src:u64> <etype:u32> <dst:u64> <rank:u64>` | edge props (or empty) | out-edges (source view) |
| `ei` | `"ei" + <dst:u64> <etype:u32> <src:u64> <rank:u64>` | **empty** (navigation) | reverse traversal (dst view) |
| `et` | `"et" + <etype:u32> <src:u64> <dst:u64> <rank:u64>` | empty | optional: global listing by type ("all FOLLOWS edges") |
| `deg` / `degi` | `<tag> + <vid:u64> <etype:u32>` | u64 counter | optional: O(1) out/in-degree (same-batch maintained, P3) |
| `t` / `tn` | `"t" + <etype:u32>` / `"tn" + <len><name>` | name / id | etype intern table (§3.4) |

### 3.2 Encoding rules

1. **Family byte + fixed-width big-endian fields, zero delimiters**. All multi-byte
   integers big-endian: lexicographic order = numeric order, and prefix scans are
   exact per vertex (variable-length ids leak across ids: `e1+5` and `e10+5` share
   prefix `e1`; a `:` delimiter is injection-ambiguous for arbitrary binary vids).
   For arbitrary binary vids use the length-prefixed variant `<len:16 BE> <bytes>`.
2. **`rank` is a user-space discriminator, not the engine ord** (§11). Simple graphs
   (at most one edge per (src,etype,dst), TAO semantics) keep it at `0`; multi-edges /
   time series use µs timestamps (u64 µs wraps in ~586k years) or per-pair counters.
   **Do not reuse the engine ord as rank** — identity becomes unstable across
   re-ingestion.
3. **`etype` is interned to u32 at database creation**, mapping table stored in the
   same cask (`t` family). Registration is rare — either an open-time schema
   (aligned with this library's open-time immutable config philosophy, e.g.
   `{synonym_file, Path}`) or a single registration process (concurrent blind
   registration forks ids).
4. **Single key ≤ `kMaxKeySize` = 64 KiB** (`format.hpp:45`). With the fixed-width
   u64 layout an edge key is 29 bytes — no pressure; the length-prefixed variant
   should watch vid lengths.

### 3.3 Worked example

Vertex 42 (Alice), vertex 100 (Bob), `FOLLOWS` interned as etype 3:

```
vertex 42  key: 6E | 00 00 00 00 00 00 00 2A                       (9 B)
edge       key: 65 | …002A | 00 00 00 03 | …0064 | 00…00            (29 B, rank=0)
reverse    key: 65 69 | …0064 | 00 00 00 03 | …002A | 00…00          (30 B, empty value)
multi-edge …| …0064 | 00 00 01 8F A2 3B C1 90                        (rank = µs timestamp)
```

Ordering: vertex keys of vid 1,2,10 sort `…01 < …02 < …0A` (big-endian fixed width ⇒
lexicographic = numeric; variable-length decimal strings would sort `n1 < n10 < n2`).
Within the same (src,etype,dst), ascending rank = ascending time.

Concrete scan ranges:

```
all out-edges of 42:      {"e"+<<42:64>>,            "e"+<<43:64>>}          % 9 B prefix
FOLLOWS edges of 42:      {"e"+<<42:64, 3:32>>,      "e"+<<42:64, 4:32>>}    % 13 B prefix
point lookup (42,3,100):  get(full 29 B key)                                  % O(1)
```

`Hi = succ(Lo prefix)`: drop trailing `0xFF` bytes of the prefix and increment the
last remaining byte (all `0xFF` → unbounded).

### 3.4 Logical edge id

The tuple `(Src, Etype, Dst, Rank)`; applications wanting an opaque handle can use
the family-less 28-byte encoding `<<Src:64, Etype:32, Dst:64, Rank:64>>`. `e` / `ei`
are mirror images: swapping the src/dst fields of an in-edge scan result recomputes
the forward key (dual representation for free — isomorphic to JanusGraph's
`relation-outV-label-inV` full id).

---

## 4. Graph namespace (multiple graphs)

- **Default: one graph = one cask directory.** Zero key overhead, per-graph failure
  and merge isolation, write throughput sharded per graph (aligns with the upstream
  "higher write concurrency ⇒ shard across multiple `Cask` instances"). The old
  scheme's "parallelism across graphs" carries over.
- **Alternative: shared cask + graph prefix** (a `<len:16><gid>` prepended to the vid
  segment, or a directory-level fixed gid field), for many-tiny-graphs sharing one
  engine instance; costs a per-key constant overhead and a shared keydir. Not in MVP.

---

## 5. Write path

```
put_vertex(Vid, Doc)    → put_doc(n<vid>, Doc)            %% BM25/vector indexed automatically
put_edge(S,T,D,rank,P)  → put_batch_atomic([{put, e-key, P}, {put, ei-key, <<>>}])
del_edge(S,T,D,rank)    → put_batch_atomic([{remove, e-key}, {remove, ei-key}])
del_vertex(Vid)         → collect all incident edges (both directions via ranges),
                          batch-delete them, then delete the vertex; chunked atomic
```

- **Dual-key edge atomicity**: `e` / `ei` in one all-or-nothing batch — reverse keys
  never hang after a crash (§2).
- **Upsert semantics**: re-putting the same (src,etype,dst,rank) overwrites (plain
  put semantics); multigraph or not is expressed by the application via rank — the
  engine has no second edge type.
- **Durability**: every atomic batch is durable once it returns (contrast the CSR
  scheme: a volatile overlay loses writes silently within the checkpoint window).
  This scheme has no "graph-granularity checkpoint" concept at all.
- **Write amplification**: 2 KV pairs per edge; the `ei` value is kept empty
  (navigation only) so properties are stored once — NebulaGraph duplicates full edge
  properties on both sides and its docs admit "obvious storage amplification"; we
  deliberately avoid that. Reverse-side property needs are served by a point lookup
  of the `e` key.
- **Degrees**: when the `deg` family is enabled, ±1 lands **in the same atomic
  batch** (avoiding per-ask counting on hot paths; TAO keeps counts in a separate
  table for the same reason).

---

## 6. Read / traversal path

### 6.1 Primitives

```erlang
succ(Bin) -> ...                                  %% lexicographic successor (§3.2)
out_edges(R, Vid)      -> range(R, {"e"+V64(Vid), succ(...)}, [{prefetch, N}])
out_edges(R, Vid, T)   -> range(R, {"e"+V64(Vid)+T32(T), succ(...)}, ...)
in_edges(R, Vid)       -> range(R, {"ei"+V64(Vid), succ(...)}, ...)
edge(R, S, T, D)       -> get(ekey(S, T, D))             %% point lookup
vertex(R, Vid)         -> get(nkey(Vid))                  %% O(1) keydir
```

`range_fold` batches 256 per NIF round-trip (NIF cap 1024); `prefetch` reuses the
`parallel_scan` thread pool to fetch windowed values concurrently, saturating SSD
internal parallelism — edge values are small, so prefetch mainly pays off when
fetching next-hop vertex payloads.

### 6.2 BFS / k-hop

```
frontier = [Start]
per layer: expand each frontier vertex — one Erlang process per vertex, each opening
           its own range iterator (the Cask handle is thread-safe: lock-free /
           shared_lock reads; the only contract is one iterator per process, which
           one-process-per-iterator satisfies naturally)
           dedup by vid → next frontier
```

Bulk vertex-payload fetch: point-get the next frontier's `n` keys one by one, or via
`parallel_scan` (whose key-prefix filtering fits a known key set).

### 6.3 Bidirectional shortest path

The `e` / `ei` dual families make both directions O(degree): classic bidirectional
BFS, always expanding the smaller frontier, meeting in the middle.

### 6.4 Hub (very high degree) vertices

`range` has no server-side LIMIT; strategies live in the caller:

- stop early in `range_fold` (count reached);
- push etype into the prefix to narrow (§3.2 left-to-right predicate rule);
- "newest N": encode rank complemented so lexicographic = time-descending, take N
  and stop (same spirit as TAO's time-descending association lists).
  `RangeOptions::reverse` is format-reserved upstream but not implemented in v1 —
  do not rely on it.

### 6.5 Property-filtered traversal and consistency

- **Property filtering**: two-phase — `search_fields` / `search_text` produce a
  candidate vid set, intersect with adjacency; or filter per hop in Erlang.
- **Consistency (honest statement)**: each range is per-key consistent internally
  (OKI merge + keydir recheck); **across hops it is weakly consistent** — concurrent
  writes during a traversal may be partially visible. Global-snapshot algorithms use
  `fold` (snapshot semantics, O(all keys)). This tier matches the read-committed
  behavior of mainstream online graph stores; state it in the docs.

---

## 7. Whole-graph analytics: materialized CSR cache (absorbing the old scheme)

Hop-by-hop KV is uneconomical for BSP-class algorithms (each superstep costs
O(V+E) seeks — 1–2 orders of magnitude slower than a C++ CSR kernel). Solve by tiers:

```
offline / low frequency:  stream the e: family via parallel_scan or range_fold
                          → in-memory CSR (xadj/adjncy/etype; the GCSR encoding is reusable)
                          → PageRank / connected components / SSSP run in memory (BSP)
invalidation:             drop and rebuild when writes accumulate (cache semantics, not truth)
```

The old 2.2.1 scheme (whole-graph CSR + owner process + overlay checkpoints) is
demoted to the implementation reference of this layer — the three problems it
exposed (`value_too_large` 4 GiB cap, graph-granularity write amplification, the
checkpoint durability window) no longer exist in this scheme's storage layer, and
the materialized layer is a **regenerable cache** whose loss never harms correctness.

---

## 8. Erlang execution model (vs the old scheme)

- **No owner process is needed anymore**: the Cask handle is thread-safe and any
  number of BEAM processes read/write the same handle concurrently. The BEAM side
  holds no large state, no LRU eviction, no checkpoint protocol — the entire
  apparatus the old scheme built for "process = state container" (overlay, folding,
  eviction write-back) disappears.
- **Crash isolation**: the storage layer is durable per write; with stateless BEAM
  processes, a crash only affects in-flight traversals, never data. The supervisor
  only needs to own the (optional) traversal coordinator and the etype registration
  process (unless using an open-time schema).
- **Write throughput**: a single cask serializes writes through `write_mu_`
  (concurrent writes are safe but not faster); higher write throughput shards by
  §4 graph / directory.
- **Read parallelism**: two dimensions — across processes (parallel frontier) and
  across graphs (multiple cask instances) — saturating cores.

---

## 9. API sketch

```erlang
%% lifecycle (one graph = one directory)
graphdb:open(Dir, Opts)      -> {ok, R, EmbedderCtx}.   %% thin wrapper over bitcask:open
graphdb:close(R)             -> ok.

%% writes (durable per operation; edges dual-write in one atomic batch)
graphdb:put_vertex(R, Vid, Doc).
graphdb:put_edge(R, Src, Etype, Dst, Opts).             %% Opts: rank (default 0), props
graphdb:del_edge(R, Src, Etype, Dst, Rank).
graphdb:del_vertex(R, Vid).                             %% cascades incident edges

%% reads / traversal
graphdb:vertex(R, Vid).
graphdb:neighbors(R, Vid, Dir).                         %% Dir :: out | in | both
graphdb:edge(R, Src, Etype, Dst).
graphdb:out_edges(R, Vid, Opts).                        %% Opts: etype, limit, prefix
graphdb:in_edges(R, Vid, Opts).
graphdb:bfs(R, Start, #{depth := K, dir => out, visit => Fun}).
graphdb:k_hop(R, Start, K, Opts).
graphdb:shortest_path(R, Src, Dst).
graphdb:degree(R, Vid, Etype).                          %% counter, or count on demand

%% search integration (engine capabilities)
graphdb:search_vertex(R, Query).                        %% search_fields/search_text passthrough
graphdb:search_vector(R, Q).                            %% vertex vector ANN
graphdb:neighbors_filtered(R, Vid, Dir, Pred).          %% adjacency × property filter

%% OLAP (§7)
graphdb:materialize(R)      -> {ok, CsrRef}.
graphdb:pregel(CsrRef, ComputeFun, Opts).
```

---

## 10. Trade-offs and boundaries

- ✅ No per-graph memory cap, no `value_too_large`; online random writes, durable
  per write; both directions O(degree); engine-atomic dual-key edges; O(1) point
  lookups; cross-graph core saturation; vertex property search / vector ANN reuse
  at zero cost.
- ⚠️ **One hop is 10–100× slower than a CSR array slice** (seek + merge + pread vs
  memory slice) — acceptable for OLTP traversal; whole-graph iteration must go
  through the §7 materialized layer. Different tiers, different jobs.
- ⚠️ **2 KV pairs per edge** (+ optional deg counters); the empty-valued `ei` keeps
  the property-side duplication away.
- ⚠️ **Cross-hop per-key weak consistency**; the only global snapshot is fold
  (O(all keys)). No multi-hop transactions.
- ⚠️ **Hub vertices**: no server-side LIMIT — rely on caller-side early stop /
  prefix narrowing; super-hubs (>10⁶ degree) should be split at modeling time.
- ⚠️ **keys ≤ 64 KiB**; non-u64 ids go through the length-prefixed variant
  (+2 B per field).
- ⚠️ **etype intern registration forks under concurrency**: open-time schema or a
  single registration process — pick one.
- ⚠️ When OKI is unavailable, ranges refuse to answer (`no_index` /
  `index_rebuild_failed`); read-only fallback is fold + prefix filtering
  (equivalent, slower).
- ⚠️ **Unflushed OKI memdelta is query-expensive**: measured ~12 ms/one-hop right
  after a bulk load vs ~0.02 ms/op after close→reopen (memdelta flushed to sealed
  runs, 600×+). Load-then-query workloads should checkpoint/reopen after loading,
  or wait for automatic memdelta flush thresholds (`test/graphdb_bench`).

---

## 11. ord vs Rank (clarification)

The engine's internal `ord` (keydir `next_ord_`, u64 atomic, one allocation per key
operation) is unrelated to the edge `rank`: rank is a user-space discriminator that
consumes zero ords. ord exhaustion is unreachable under any real workload
(~5.8M years at 10⁵ ords/s sustained; ~29k years at 10M edges/s sustained —
on-disk record counts blow up fifteen orders of magnitude first), and upstream
`ord-recycling-design-zh.md` already solved the adjacent real problem (Index
per-ord array growth) with chunked slots freed on merge. Incidentally: the 29-byte
fixed-width edge keys compress well under the vbyte prefix-differential encodings of
hint v5 / OKI runs — `prefix:id` shapes are exactly what BCOK optimizes for.

---

## 12. Phases

1. **P1** ✅: key codec (n/e/ei fixed-width big-endian + length-prefixed variant) +
   vertex / edge CRUD (atomic dual-write) + out/in/point lookups + del_vertex
   cascade; etype open-time schema.
2. **P2** ✅: BFS / k-hop / bidirectional shortest path; hub strategies
   (limit / prefix narrowing); visited-dedup structures.
3. **P3** ✅: `deg` / `degi` / `et` families + `search_*`-integrated property
   filtering (`neighbors_where`) + counter-correct cascades.
4. **P4** ✅: CSR materialization cache (`materialize` → in-memory binary CSR,
   out + transpose) + PageRank / connected components / SSSP
   (`graphdb_analytics`).
5. **P5** ✅: one-hop latency + bulk-load throughput benchmarks
   (`test/graphdb_bench`; steady-state one-hop ~0.02 ms/op after flush,
   ~94k edges/s bulk load at 2k/8k scale), consistency-semantics tests
   (mid-scan insert/delete visibility invariants), EN documentation (this file).
