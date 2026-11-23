# Graph Storage Layer v2: Two KVs per Vertex (Packed Adjacency + Conditional Writes)

中文版：[graph-adjacency-pack-design-zh.md](graph-adjacency-pack-design-zh.md).

Status: **Implemented** (2026-11-18, G1–G6, shipped in **8.0.0**; the repository now follows
8.1.0; implementation record in
§14). Supersedes the on-disk layout and write path of
[graph-layer-design-en.md](graph-layer-design-en.md) ("v1" below); v1's traversal
algorithms, OLAP materialization layer, etype registry and API shape are kept.

Depends on one engine capability: **conditional atomic batches** (checked against a key's
LSN). It was filed as downstream feedback (libbitcask
`feedbacks/2026-11-17-conditional-atomic-batch.md`) and shipped upstream in **8.0.0** (S46):
`Cask::BatchOp::expect` (`kAbsent` / `kOrdEquals`) + `expect_ord` + `kCheck`; a failed
condition returns `kConditionFailed`, and `BatchOutcome` reports the failing op index and
every op's LSN. This repository's submodule is now at 8.1.0 (`13322bd`); the NIF / facade shape
is in §5.3.

---

## 1. Motivation

v1 stores "three keys per edge":

| v1 family | Per edge | Notes |
|---|---|---|
| `e` src·etype·dst·rank | 1 key | Out-edge, value = edge properties |
| `ei` dst·etype·src·rank | 1 key | Reverse navigation, empty value |
| `et` etype·src·dst·rank | 1 key | List edges by type, empty value |
| `deg` / `degi` | 1 key per (vertex, etype) each | Rewritten on every edge add / delete |

Inserting one new edge writes 5 records and leaves 3 resident keys. libbitcask keeps every
key resident in memory in the keydir, and the OKI has a row per key too, so **key count ≈
3 × edges** directly drives memory and merge work. 50 million edges means 150 million keys.

v2's goal: **key count proportional to vertices, not to edges.**

## 2. The Model in One Line

```
n <vid>   → vertex content (unchanged: DocValue via put_doc, BM25 / vectors as before)
a <vid>   → the vertex's adjacency list (out section + in section + degrees), one value
```

**Two KVs per vertex.** A vertex whose adjacency list exceeds the threshold (a hub) splits
its large group into chunks, which are extra KVs (§4.3); real graphs are mostly power-law,
so the vast majority of vertices never trigger it.

Vertex content and adjacency are **not merged** into one KV: `n` goes through `put_doc`,
and every rewrite re-tokenizes / rebuilds vector index entries — adding an edge should not
pay that.

| | v1 | v2 |
|---|---|---|
| Key count | V + 3E + counter keys | 2V + hub chunks |
| Neighbors of a vertex | OKI prefix range + per-row lookup | **one point read, one pread** (hub: head + one point read per chunk in its directory) |
| Consistency within a hop | per-key weak | **atomic snapshot** (hub: optional check, §7.3) |
| Degree | extra counter keys, read-modify-write | in the adjacency head, updated atomically with edges |
| Insert one edge | append 5 small records | rewrite both endpoints' adjacency lists (each ≤ ~4 KiB) |
| Concurrent writes to one vertex | counts may drift | conditional write conflicts → retry, no lost edges |
| Single-edge lookup | O(1) keydir | read adjacency + search within the group |
| List all edges of a type | `et` prefix range | scan the `a` family and filter, or use materialization |

## 3. The Trade-off, Up Front

v2 trades "cheaper reads, less memory" for "more expensive writes":

- **Higher write amplification.** A v1 single-edge write logs about 300 B; a v2
  single-edge write rewrites two adjacency lists — about 2 × 1 KB on a simple graph with
  average degree 50, capped at about 2 × 4 KiB (the chunk threshold). The log is
  append-only, so garbage accumulates faster and merges run more often. The batch API
  (§6.4) aggregates per vertex so each vertex is written once per batch, which recovers
  part of the cost (measured in §14.3).
- **Every edge write is a read-modify-write** and needs concurrency protection. v2 uses
  engine conditional writes (§5) and retries on conflict. Many concurrent single-edge
  writes to a hot vertex retry repeatedly — such workloads should use the batch API or the
  transaction layer.
- **The `et` index is gone.** `edges_by_type` becomes an O(V + E) scan. An optional index
  can be added if it turns out to be hot.

If the workload is "massive concurrent single-edge writes, few reads", v1 fits better. v2
targets read-heavy, bulk-loaded, memory-sensitive graphs — which is how this library is
mostly used today.

## 4. On-disk Contract

### 4.1 Key families

| Family | Key | Value |
|---|---|---|
| `n` | `<G> "n" <vid:64>` | Vertex content (unchanged) |
| `a` head | `<G> "a" <vid:64>` (13 B) | Adjacency head (§4.2) |
| `a` chunk | `<G> "a" <vid:64> <dir:8> <etype:32> <other:64> <rank:64>` (34 B) | One chunk of entries (§4.3); the (other, rank) in the key is the chunk's **lower bound** |
| `p` | `<G> "p" <src:64> <etype:32> <dst:64> <rank:64>` | Edge properties over the inline limit (§4.4) |
| `t` / `tn` | `<G> "t" …` / `<G> "tn" …` | etype registry (record bodies unchanged) |
| `g` | `<G> "g"` (5 B) | Graph metadata: `<<LayoutVer:8, …>>` = 1 |

`<G>` is the graph-layer namespace `<<16#01, "_g:">>` (4 B), so graph keys cannot collide
with application KV, full-text, or vector-index keys.

All multi-byte integers are fixed-width big-endian (as in v1: lexicographic order =
numeric order). `dir`: 0 = out, 1 = in. The head key is a prefix of all the vertex's chunk
keys, so a prefix range over `<G> "a" <vid>` returns exactly "head + all chunks", head
first.

### 4.2 Head value

```
Head   = <<Ver:8 = 1, NGroups:16, Group × NGroups>>
Group  = <<Dir:8, GFlags:8, Etype:32, Count:64, Body>>          %% sorted by (Dir, Etype)
GFlags : bit0 has_rank   some entry in the group has rank ≠ 0
         bit1 has_props  some entry in the group has properties
         bit2 chunked    the group is chunked
Body (inline)  = Entry × Count
Body (chunked) = <<NChunks:32, <<Other:64, Rank:64>> × NChunks>>  %% chunk lower bounds, ascending
```

Entries are sorted by `(other, rank)`; their width depends on the group flags:

```
Entry = <<Other:64>>                                  %% simple graph, no props: 8 B / neighbor
      | <<Other:64, Rank:64>>                         %% has_rank
      | <<Other:64, [Rank:64], PLen:16, Props/bytes>> %% has_props; PLen = 16#FFFF means props live in p
```

- Entries of groups without properties are fixed-width; Erlang decodes / searches them
  directly with binary matching, no NIF needed.
- **The in section stores no properties** (`has_props` is always 0 for `dir = 1` groups);
  properties are stored once, on the out side, just as v1's `ei` values were empty.
- `Count` is the degree: `degree(Vid, Etype)` is one head read, no separate counter keys.
- Group flags are maintained monotonically by writes and recomputed whenever a whole
  group is rewritten (chunking / unchunking / migration).

### 4.3 Chunking (hubs)

Parameters (open-time, recorded in `g`):

- `adj_inline_max`, default 4096 B: when the head value exceeds it, the largest inline
  group is converted to chunks;
- `adj_chunk_max`, default 4096 B: per-chunk value limit. Initial chunking fills chunks
  greedily by bytes; an existing chunk that overflows is split into ⌈bytes / limit⌉ (at
  least 2) roughly equal chunks (a generalization of splitting in half);
- Reclaim: once a chunked group's total size drops below `adj_inline_max / 4`, it goes
  back inline (hysteresis, to avoid flapping).

Chunking is **per group**: a vertex with a million in-edges and 100 out-edges chunks only
its in group; the out group stays in the head.

```
Chunk = <<Ver:8 = 1, GFlags:8, Count:32, Entry × Count>>
```

The (other, rank) in a chunk key is the chunk's **lower bound**: chunk 0 is always (0, 0);
each later chunk's bound is its first entry at the time it was created (by chunking or a
split). Entry e belongs to the last chunk whose bound is ≤ e. Bounds change only on splits
and when a chunk is emptied — deleting a chunk's first entry needs no key rename, and an
entry smaller than everything always has a home (chunk 0). An emptied chunk (other than
chunk 0) has its key deleted and is removed from the directory; when the whole group
empties, chunk 0 goes too.

Locating an edge: find its chunk in the head's directory → point-read that chunk → search
within it. Writing an edge = rewrite the head (the degree changed; it is small) + rewrite
one chunk (≤ 4 KiB). Write cost does not grow with degree.

The directory lives in the head, 16 B per chunk. A 100k-degree group has about 200 chunks
and a 3 KiB directory; to keep directories around 1024 entries or fewer, the effective
chunk limit of a huge group is `max(adj_chunk_max, group bytes / 1024)`. Vertices with
degree above 10⁷ should still be split at the modeling level (same advice as v1, with the
bar an order of magnitude higher).

### 4.4 Edge properties

- Up to `props_inline_max` (default 128 B): inline in the out entry.
- Larger: written to a separate key in the `p` family, marked in the entry with
  `PLen = 16#FFFF`, in the same atomic batch as the adjacency. Only edges with large
  properties cost an extra KV.

### 4.5 Invariants

1. **Symmetry**: `(a, t, b, r)` is in `a`'s out group ⟺ it is in `b`'s in group. Every
   write changes both sides in the same atomic batch.
2. **The head is the version**: **any** change to a vertex's adjacency rewrites its head
   (the degree is in the head and necessarily changes). So "the LSN of the head key" is
   the version of the vertex's adjacency list, chunks included.
3. **Degree = entry count**: `Count` always equals the number of entries, updated in the
   same batch.
4. The head's chunk directory = the chunk keys that exist; a chunk's entries always lie in
   [its bound, the next chunk's bound), updated in the same batch.

`graphdb:check_invariants/1` scans the `a` / `p` families and checks all four (plus "an
out entry marked ext ⟺ a p key exists"); tests and migration verification both use it.

## 5. Concurrency: LSN-conditional Writes

### 5.1 Principle

The engine assigns an LSN (`ord`) to every write, and `get` already returns it. v2 stores
no separate rev in the value and uses the LSN as the version:

```
1. Read the heads of vertices a and b, noting each LSN (absent if missing)
2. Compute the new values in memory
3. Commit one atomic batch with preconditions:
     "a's head LSN is still what I read" and "b's head LSN is still what I read"
4. Any condition fails → nothing is written, conflict returned → back to 1
```

~~By invariant 2, conditions on the two heads suffice: any chunk change also changes the
head's LSN. Chunk writes in the batch need no conditions of their own.~~

> **Correction (2026-11-20)**: that argument assumes a reader sees head and chunks from the same
> committed state, but libbitcask ≤ 12.0.0's atomic batch is **not all-or-nothing for concurrent
> readers**: its keys take effect one by one, in key byte order (a head key is a prefix of its chunk
> keys, so a vertex's head always lands before its chunks). A reader can see "new head + old / missing
> chunk", and a write-back guarded only by the head then succeeds and overwrites someone else's chunk.
> Upstream 12.0.1 (S63) now publishes a batch inside one critical section. This layer still keeps the
> rule as explicit defence: **conditions cover the whole read set** — modified heads, every chunk read
> (on its put / remove if modified, as a `check` if not, `absent` if it was missing), and the heads of
> vertices the session read but did not modify. Conditions are checked under the engine's write lock
> against the pre-batch state, so if anything read by the session changes before commit, the whole
> computation conflicts and retries — even if a caller bypasses the graph protocol and writes a chunk
> directly. Upstream report: libbitcask
> `feedbacks/2026-11-20-atomic-batch-no-read-isolation.md`.

The check must be atomic with the write under the engine's write lock, so only the engine
can provide it (§5.3).

### 5.2 Retry policy

- The direct API retries 8 times by default with jittered backoff; exhausted →
  `{error, conflict}`.
- Conflicts only happen when two writers change the same vertex at the same time. Writes
  to different vertices never interfere.
- On a hot vertex (many writers adding edges to one hub) only one writer wins per round.
  Such workloads should use the batch API (§6.4, aggregate per vertex and write once) or
  the transaction layer (§8, queue instead of retry).

### 5.3 What the engine provides

Summarized from the feedback file:

1. Each op in an atomic batch may carry a precondition: `none` / `key absent` / `key's
   current LSN == N`.
2. All conditions are checked under the write lock before anything hits disk; if any
   fails, the batch has zero side effects and returns a dedicated conflict error that
   identifies the op.
3. Contract: a key's LSN changes only when the key is written — merge relocation, reopen
   recovery and OKI rebuilds never change it.
4. Optional: on success, return the LSN assigned to each op, so writers can continue
   without re-reading.

The shape implemented on this side (NIF and Erlang facade):

```erlang
bitcask:get_with_ord(H, Key)            -> {ok, Value, Ord} | not_found | {error, _}.
bitcask:put_batch_atomic(H, Ops)        %% three more op shapes:
    {put,    Key, Value, Cond}          %% Value may also be a doc map
    {remove, Key, Cond}
    {check,  Key, Cond}                 %% validate only, write nothing
                                        %% Cond :: absent | {ord, N}
                                        -> ok | {error, {conflict, OpIndex}} | {error, _}.
bitcask:put_batch_atomic(H, Ops, [return_ords]) -> {ok, [Ord]} | ...   %% each op's LSN
bitcask:txn_commit(H, Ops[, Sync[, Token]])     %% accepts conditional ops too
```

`OpIndex` is 1-based, the position in `Ops` (mapped from the engine's
`BatchOutcome::failed_op`); when no index is available the fallback is
`{error, condition_failed}`. Unrecognized shapes raise `badarg`.

## 6. Write Path

### 6.1 put_edge(S, T, D, #{rank, props})

```
Read head(S), head(D) (with LSNs)
Edge exists → update properties only: rewrite only S's side (head or the chunk), condition only on head(S)
Edge missing →
    insert (D, rank, props) into S's out group, Count + 1
    insert (S, rank) into D's in group, Count + 1
    chunk / split if needed (same batch)
    atomic batch: [head(S) with condition, head(D) with condition, touched chunks, maybe a p key]
Self-loop (S = D): two groups change in one head; the batch has a single head
```

### 6.2 del_edge

Symmetric: remove one entry on each side, Count − 1, same batch; properties in the `p`
family are deleted in the same batch. A missing edge returns `ok` (idempotent, no write).

### 6.3 del_vertex(V)

```
Read head(V) and all its chunks; group the entries by neighbor (a neighbor may have several edges, in both directions)
Process neighbors in batches (≤ 64 neighbors per batch):
    in the batch: each neighbor's head (and chunks) drops every entry involving V, with conditions;
                  V's own head drops those neighbors, with a condition
    —— the graph satisfies the symmetry invariant after every batch, so a rerun after a mid-way failure converges
Last batch: delete head(V) (condition: LSN unchanged, so nobody added an edge to V meanwhile), V's remaining chunks,
            the related p keys, and n<V>
```

When the neighbors fit in one batch, the whole delete is a single atomic batch. v1's
"aggregate neighbor counter RMW" machinery disappears entirely.

### 6.4 Batch API (new)

```erlang
graphdb:put_edges(H, [{S, T, D} | {S, T, D, Opts}])  -> ok | {error, _}.
graphdb:del_edges(H, [{S, T, D} | {S, T, D, Rank}])  -> ok | {error, _}.
```

Aggregated per touched vertex: each vertex is read once, modified once, written once.
Edges are first **stably sorted by (src, etype, dst, rank)** (a src's edges land in the same batch and in adjacent
chunks, and repeated upserts of one edge still apply in the caller's order; `sort => false` turns it off), then
cut by vertex set (at most `batch_vids` heads per batch, default 256); each batch is
independently atomic and independently retried. Offline loads can raise `batch_vids`: with
the whole graph in one batch every head is written once; the cost is that the larger a
batch, the more expensive a full retry after a conflict with concurrent writers. Bulk
loaders and hot-vertex writes should use this path.

## 7. Read Path

### 7.1 Primitives

```
out_edges / in_edges / neighbors(V):
    get head(V)
    inline group  → decode entries directly
    chunked group → point-read each chunk listed in the head's directory (stop at limit; a prefix range before G10)
edge(S, T, D, R): get head(S) → search the group (chunked: one more chunk read) → if props live in p, one more read
degree(V, T): get head(V) → read Count
degree(V): get head(V) → sum the out groups' Counts (v1 was an O(out-degree) scan)
```

`limit` and `etype` filtering happen during decoding; on inline vertices they save no IO
(the whole value, ≤ 4 KiB, is already read), while on chunked vertices `etype` is pushed
into the range prefix and `limit` stops early.

### 7.2 Traversal

BFS / k-hop / bidirectional shortest path are unchanged; expanding a vertex goes from "one
range" to "one get". Frontier expansion no longer needs one iterator per vertex.

### 7.3 Consistency

- Inline vertex: one get yields an atomic snapshot of the vertex's adjacency.
- Chunked vertex: head and chunks are read separately. `#{consistent => true}` point-reads the
  head and each chunk in the directory with their versions, then validates the read set under the
  engine's write lock with a check-only atomic batch, rereading on failure (since 2026-11-20; comparing
  the head's LSN before and after could not catch a chunk written by someone bypassing the graph
  protocol, see the §5.1 correction). Since libbitcask 12.0.1 an in-flight batch is always wholly
  visible; the check still gives the consistent read an explicit version confirmation under the write
  lock. Read-only handles skip validation. Off by default, matching v1's weak consistency.
- Across hops it stays weakly consistent, as in v1.

## 8. Transaction Layer

`put_edge_txn` and friends stay, but get simpler:

- Locks are taken on the vertex's head key (point lock). By convention "holding the head's
  lock covers all its chunks", so **prefix locks are no longer needed** against phantoms;
  `out_edges_txn` takes a read lock on the head (chunks of chunked groups are read with
  point reads following the head's directory, through the transaction's own buffer, with
  no prefix lock).
- At commit, the head LSNs read become conditions in the commit batch. Direct and
  transactional writes **can therefore be mixed**: a direct writer slipping in makes the
  transaction conflict and re-run, instead of v1's undefined behavior. This is
  implemented as a general mechanism, `bitcask_txn:read_guarded/3`: it records the version
  while reading; at commit, written keys carry the condition on their put / remove and
  read-only keys become `{check, K, Cond}`; a conflict takes the same restart path and
  `{retries, N}` budget as a deadlock. The graph layer reads every head through it.
- All counter-related lock upgrades and aggregation logic are gone.

## 9. Other Affected Parts

- **`edges_by_type`**: scans the heads and chunks of the `a` family filtering by etype,
  O(V + E). The cost is documented; an optional per-etype index can come later if there
  is real demand (separate task).
- **OLAP materialization (`graphdb_analytics:materialize`)**: the data already is
  per-vertex sorted adjacency, so one scan of the `a` family builds both CSRs, much faster
  than parsing v1 edge by edge.
- **Property-filtered traversal, search integration**: unchanged (they act on the `n`
  family).
- **Pathological vid defense**: in v1, `ei` / `et` keys could fall into `e` scan ranges;
  v2's families have no such prefix containment (an `a` head being a prefix of its own
  chunks is by design). Parsing still validates lengths strictly.

## 10. Layout Version and Legacy Data

- The `g` key records the layout version. On open: `<G> "g"` present with version 1 → the
  current layout; no new `g` but an old unprefixed `g` is present → an interim layout
  without the global namespace, rejected with `{error, graph_layout_unprefixed_v2}`;
  no new `g` but an `e` / `ei` family present → the earlier per-edge layout, rejected with
  `{error, graph_layout_v1}`.
- There is no automatic migration and no `graphdb_migrate` tool. Callers must export old
  graph data and reload it; the fail-loud open checks only prevent treating an old graph
  directory as an empty new store.

## 11. Phases

| Phase | Content | Needs engine conditional writes | Status |
|---|---|---|---|
| G0 | File engine feedback; wait for the upstream interface | — | ✅ upstream 8.0.0 |
| G1 | Value codec (head / chunk / entry) + property tests; read path (neighbors, lookup, degree, traversal) | no | ✅ |
| G2 | Migration tool + verification; materialization reads the `a` family | no | ✅ |
| G3 | Write path (single edge, batch, delete vertex) | no | ✅ |
| G4 | Chunking: split, merge, back to inline, `consistent` reads | no | ✅ |
| G5 | NIF and facade use conditional writes; direct writes become "conditional write + retry"; transaction commits carry conditions; allow mixing direct / transactional writes | **yes** | ✅ |
| G6 | Benchmarks, docs, CHANGELOG | — | ✅ |

Upstream shipped before implementation started, so G3's planned interim scheme
("serialize through the transaction layer's head point locks") was never needed: direct
writes were conditional write + retry from day one.

## 12. Acceptance Criteria

Benchmarks extend `test/graphdb_bench` with the earlier per-edge layout as a reference:

| Metric | Expectation |
|---|---|
| Key count | ≈ 2V + chunks; two orders of magnitude fewer on an average-degree-50 graph |
| Resident memory after open | drops along with key count; record measured values |
| One-hop neighbor latency | no slower than v1 steady state (v1 ~0.02 ms/op) |
| Bulk-load throughput | no lower than v1 (v1 ~94k edges/s) |
| Single-edge write throughput | record measured value and ratio to v1 (expected to drop, §3) |
| Log bytes per edge | record measured value (expected to rise, §3) |
| Concurrent correctness | 16 processes adding / deleting edges on one vertex: no lost edges, degree = entries, both sides symmetric |
| Crash consistency | reopen after a kill at any point: symmetry invariant holds |

## 13. Open Items

1. ~~Default `adj_inline_max` / `adj_chunk_max`~~: 4 KiB (the three settings were within
   noise, §14.3).
2. ~~`edges_by_type` as a full scan~~: accepted.
3. `props_inline_max` defaults to 128 B (implemented as such).
4. ~~Version number~~: 8.0.0.
5. ~~Engine conditional writes~~: shipped upstream in 8.0.0 and integrated.

## 14. Implementation Record (2026-11-18)

### 14.1 Modules

| Module | Content |
|---|---|
| `graphdb_adj` (new) | Head / chunk / entry codec; read primitives (`entries` / `lookup` / `counts`); write sessions (`put_edge` / `del_edge` / `all_entries` / `commit`, a condition on every modified head); chunk maintenance (split, drop empty chunks, back to inline, chunk an oversized head). IO abstraction `{direct, H}` / `{txn, Tx, Lock}`, so direct and transactional paths share one implementation |
| `graphdb` | Facade: layout check at open (`g` key; parameters are read from `g` once per write session, no out-of-process cache), direct API + conflict retry, `put_edges` / `del_edges`, neighbor-batched `del_vertex`, `consistent` reads, transactional API, traversal (unchanged), etype registry (unchanged), `check_invariants/1` |
| `graphdb_analytics` | `materialize` scans the `a` family |
| `bitcask` / NIF | `get_with_ord/2`, conditional batch ops, `put_batch_atomic/3` (`return_ords`), `{error, {conflict, I}}` |
| `bitcask_txn` | `read_guarded/3` (version guards, §8) |

### 14.2 Deviations from the design

- The (other, rank) in a chunk key is the chunk's **lower bound** rather than "its first
  entry" (§4.3): deleting a chunk's first entry needs no rename.
- `degree/2,3` keeps v1's meaning (**out-degree**); `in_degree/2,3` is added. Both are an
  O(1) head read.
- `edges_by_type` returns properties (v1's `et` keys had none and always returned `<<>>`).
- `consistent` reads try up to 32 times with jittered backoff after hitting a write;
  exhausted → `{error, inconsistent_read}`.
- `del_vertex`'s last batch carries `{check, head, absent}` when the vertex had no
  adjacency at all, so a concurrent edge insert interleaved with the delete cannot leave a
  dangling edge.
- `put_edges` / `del_edges` stably sort by (src, etype, dst, rank) before cutting batches (≤ `batch_vids`,
  default 256; src only before G10). Unsorted random edges rarely repeat a vertex within a batch, so
  aggregation barely helps; sorted, each src head is written once per batch — about 2×
  throughput and half the bytes (§14.3).
- `graph_layout_v1`: opening is refused only when an old per-edge out-edge key **and** its
  paired `ei` reverse key both exist (checking at most the first 64 candidates), so a
  directory that merely holds an application key of 29 bytes starting with "e" is not
  misdetected. There is no migration tool.
- All graph keys carry the global `<<1,"_g:">>` namespace. If a directory contains only the
  unprefixed `g` configuration written by the interim 8.0.0 build, opening returns
  `{error, graph_layout_unprefixed_v2}` instead of silently creating a new prefixed graph
  beside the old data.
- Parameters are not cached: each write session reads `g` once (about 5–10% slower for
  low-degree single-edge writes), so handles leave nothing behind whether closed via
  `graphdb:close` or `bitcask:close`, and handles obtained without `graphdb:open` still
  write with the store's parameters.
- In transactions, chunked groups are read chunk by chunk from the head's directory with
  point reads, without prefix locks (§8).
- Chunks created and dropped within the same write session are not deleted on disk (only
  chunks that existed when read get a delete).
- `del_vertex/3`: `retries`, `batch_neighbors => N | infinity` (infinity = one atomic
  batch). Deleting the vertex key `n<V>` is unconditional: against a concurrent
  `put_vertex` the later write wins (same as `bitcask:delete`).
- Crash consistency has no dedicated kill test: every write is a single engine atomic
  batch, and the engine's crash atomicity (all or nothing per batch) is covered upstream.

### 14.3 Benchmarks (`test/graphdb_bench`, 8 vCPU, 2026-11-18)

10,000 vertices / 50,000 edges (power-law sources, average out-degree 5), three
thresholds:

| Metric | 1 KiB | 4 KiB | 16 KiB | v1 reference |
|---|---|---|---|---|
| Keys | 10021 | 10003 | 10000 | 169423 |
| Chunks | 21 | 3 | 0 | — |
| Load via put_edge (edges/s) | 71.4k | 77.4k | 69.1k | 44–88k¹ |
| Load via put_edges (edges/s) | 88.0k | 93.0k | 85.5k | — |
| One-hop out_edges (ms/op) | 0.003 | 0.002 | 0.003 | ~0.02² |
| One-hop after reopen (ms/op) | 0.005 | 0.004 | 0.004 | ~0.02² |
| Data bytes / edge (put_edges) | 254 | 261 | 263 | 326 |
| Data bytes / edge (put_edge) | 303 | 323 | 332 | 326 |
| materialize (ms) | 62 | 54 | 65 | — |

¹ The v1 reference loads the same edges the v1 way (one 5-record atomic batch per edge +
counter read-modify-write); three runs gave 44k / 44k / 88k, too noisy for more than an
order-of-magnitude reference. ² v1 figure from the 6.5.0 benchmark record.

2,000 vertices / 100,000 edges (average out-degree 50, 4 KiB) — where §3's "more
expensive writes" shows:

| Metric | v2 | v1 reference | Ratio |
|---|---|---|---|
| Keys | 2014 (13 chunks) | 293187 | 1 / 145 |
| Load via put_edge (edges/s) | 32.8k | 91.4k | 0.36× |
| Load via put_edges (edges/s) | 46.2k | — | 0.51× |
| Data bytes / edge (put_edge) | 1095 | 314 | 3.5× |
| Data bytes / edge (put_edges) | 941 | 314 | 3.0× |
| One-hop out_edges (ms/op) | 0.012 | ~0.02 | — |

Conclusions:
- Key count (= keydir / OKI resident memory) follows vertex count: 17× fewer on the
  low-degree graph, 145× fewer at degree 50.
- A one-hop read is one point read, 2–10× faster than v1's prefix range.
- Writes: at low degree, bytes per edge are on par with v1; at degree 50 each edge write
  rewrites two heads of about 0.5 KiB, so log bytes are about 3× and single-edge write
  throughput about 0.36×, and merges run more often. The batch API recovers part of it;
  the more often a vertex repeats within a batch, the larger the gain — see "Sorting by
  src" below.
- The three thresholds are within noise; the default stays 4 KiB.

**Sorting by src (added 2026-11-18)**: `put_edges` now stably sorts by src before cutting
batches. Same data, 4 KiB:

| Graph | Unsorted | Sorted (default, 256 vertices/batch) | Sorted + `batch_vids => 4096` | v1 reference |
|---|---|---|---|---|
| 10k vertices / 50k edges (degree 5): edges/s | 84.6k | 138.7k | 148.7k | 88.1k |
| Same: bytes / edge | 261 | 134 | 107 | 326 |
| 2000 vertices / 100k edges (degree 50): edges/s | 42.7k | 88.6k | 253.0k | 84.3k |
| Same: bytes / edge | 941 | 420 | 17 | 314 |

Sorted, each src head is written once per batch; the remaining amplification is on the dst
side (each batch writes each of its dsts once). Bulk load at degree 50 goes from 0.51× back
to **1.05×** of v1, so §12's "bulk load no lower than v1" is met; with the whole graph in
one batch (2000 vertices < 4096) every head is written once — 3× v1 and 17 B per edge.
Single-edge `put_edge` is unaffected (still about 0.36–0.46×).

**Hub paths (added 2026-11-23, TASK G10)**: one vertex with 20k / 200k out-edges, 4 KiB, before → after:

| Operation | degree 20k | degree 200k |
|---|---|---|
| `del_vertex` | 1.11 s → 0.12 s | 450 s → 2.1 s |
| `put_edges` load (shuffled dsts) | 0.30 s → 0.22 s | 15.3 s → 3.5 s |
| `out_edges(#{limit => 10})` | 230 µs → 13 µs | 1133 µs → 30 µs |
| `degree` | 32 µs → 5 µs | 345 µs → 18 µs |
| `edge` | 48 µs → 12 µs | 939 µs → 32 µs |
| `put_edge` | 106 µs → 67 µs | 752 µs → 255 µs |

Four changes: `del_vertex` reads only the chunks needed for one batch of neighbors per round (it used to read every chunk each
round, O(degree²)); chunked groups are read by point reads from the chunk directory (the prefix range moved chunks a batch at a
time, and the first range after every write made the engine re-sort its whole unflushed in-memory delta); loading a head no
longer builds a table of every chunk key; the `put_edges` sort key now includes dst. What remains is inherent to the design: every
edge write on a large hub rewrites the whole head (about 13 KiB of chunk directory at degree 200k).

**Read path and in-session structures (added 2026-11-23, TASK G11)**: reads select groups by direction and type directly on the
head / chunk binaries and decode results in one pass (no session state); the chunk directory stays binary inside a session,
is binary-searched, and is written back as is when unchanged; in-session entry lists are zippers, so ascending inserts within a
batch resume from the previous position. On the 200k-degree hub, "after" above → this round: `put_edges` load 3.5 s → 0.95 s,
`put_edge` 255 → 64 µs, `edge` 32 → 8.5 µs, `degree` 18 → 4.8 µs, `out_edges(#{limit => 10})` 30 → 11 µs; `neighbors`
102 → 9.0 ms, full `out_edges` 57 → 43 ms. One-hop reads on low-degree graphs change little (`out_edges` about 6%,
`neighbors(both)` 7.5 → 4.2 µs): the point read itself takes 2 µs. `del_vertex` is essentially unchanged.

**Single-edge writes (added 2026-11-23, TASK G12)**: fixed-width entry lists stay in their on-disk binary form inside a session;
a single insert / delete binary-searches the position, splices the binary and writes it back as is, instead of decoding and
re-encoding the whole chunk. On the 200k-degree hub `put_edge` 56 → 29 µs, `del_edge` 40 → 33 µs; between degree-50 vertices
29.6 → 20.5 µs; unchanged on degree-5 graphs (about 17 µs, of which reading the graph config, reading two heads and the atomic
batch take about 9 µs).
