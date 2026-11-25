# Graph storage layout 2: the chunk directory as a B+ tree over KV

> 2026-11-25 (TASK G17). 中文：[graph-layout-2-zh.md](graph-layout-2-zh.md).
> Only the differences from layout 1 ([graph-adjacency-pack-design-en.md](graph-adjacency-pack-design-en.md)) are described. The design and the
> benchmarks were first done on the keelson side (the Clojure clj-bitcask; keelson `designs/graph-layout-2.md`, `tasks/D-51.md`); this library
> implements the same on-disk value format. **Key encodings still differ** (binary here, fixed-width hex text in keelson; see §8).

## 1. Why

In layout 1 every new edge rewrites one KV at each end, and the rewrite grows with that end's degree: the whole head while it is ≤ 4 KiB;
after chunking, one chunk **plus the whole chunk directory in the head** (16 B per chunk); once the directory is capped at ~1024 entries the
chunks themselves grow (`group bytes / 1024`). Measured here (§7): an account with 300k followers writes ~22 KiB per new in-edge, ~56 KiB at
3M; and the head is coupled to the directory, so the big account following one more person also rewrites its in-edge directory.

Target workload: a social network — follows written one at a time, continuously, with heavy reads; also stores that are bulk-loaded and then
read. Constraints: no more records per edge (LSN consumption), key count not proportional to edge count, no libbitcask changes.

## 2. In one sentence

**Each group of edges (vertex × direction × edge type) is a B+ tree over the KV store: chunks are leaves, directory nodes are inner nodes,
and the head only records the chunk count and the tree height.** Compared with layout 1 only two things change: past a threshold the chunk
directory moves out of the head into its own keys (family `d`); and chunks are capped by entry count (default 512) instead of growing with
the group.

Adding an edge = rewrite one chunk (same key) + rewrite a small head; directory nodes are only written when a chunk splits or empties. Write
volume no longer depends on degree.

Differences from a textbook B+ tree: nodes are located by key (child key = level + lower bound, no pointers stored); no in-place updates
(a new version under the same key, merge reclaims the old one); small groups have no tree (inline in the head, or the directory stays inline in
the head while there are ≤ `dir_inline_max` chunks — layout 1's shape); deletes only drop empty chunks / nodes, no merging of half-empty
ones; no sibling links between leaves; concurrency via "the head is the version" (conditional commit, whole-session retry on conflict);
crash safety via atomic batches (head, chunks, directory nodes in one batch).

## 3. On-disk contract (differences from layout 1)

### 3.1 Key families

| Family | Key | Value | Change |
|---|---|---|---|
| `a` head | `<1,"_g:"> a vid:64` (13 B) | adjacency head | one more group body form (§3.2) |
| `a` chunk | `<1,"_g:"> a vid:64 dir:8 etype:32 o:64 r:64` (34 B) | entries | unchanged |
| `d` dir node | `<1,"_g:"> d vid:64 dir:8 etype:32 level:8 o:64 r:64` (35 B) | child lower bounds (§3.3) | **new** |
| `g` | `<1,"_g:"> g` | graph parameters | version 2 (§3.5) |

A node's `(o, r)` is the lower bound of what it covers; the leftmost node of every level is `(0, 0)`. Levels start at 1: level-1 children
are chunks, level-k (k > 1) children are level k−1 nodes. A separate family keeps the `a vid` prefix range exactly "head + all chunks", so
code scanning family `a` (`graphdb_analytics`, `edges_by_type`, `check_invariants`) keeps parsing by length.

### 3.2 Head

```
Group  = <<Dir:8, GFlags:8, Etype:32, Count:64, Body>>                                   %% unchanged
GFlags : bit0 has_rank / bit1 has_props / bit2 chunked / bit3 external dir (requires chunked)  %% bit3 new
Body (chunked, external directory) = <<NChunks:32, Levels:8>>                              %% new; NChunks ≥ 1, Levels ≥ 1
```

`Count` (the degree) stays in the group header, so `degree` reads only the head. An externalized group takes 19 bytes in the head regardless
of degree. `NChunks` is recorded so that externalize / internalize decisions never need to read the tree.

### 3.3 Directory node

```
DirNode = <<1:8, Level:8, Count:16, <<O:64, R:64>> × Count>>   %% child lower bounds, strictly ascending; first = the node's own bound
```

Entry e belongs to the last child whose lower bound ≤ e, level by level — the same rule as the inline chunk directory. Nodes read from disk
are checked for length, level matching the key, and strictly ascending bounds.

### 3.4 Chunks and splitting

Chunk values are unchanged. **The cap is by entry count**: at most `chunk_entries` entries per chunk, with a byte safety cap `chunk_max`
(groups with large inline properties are cut by bytes even below the count). Initial chunking fills chunks to the cap; an oversized chunk is
cut into `max(2, ⌈entries / cap⌉, ⌈bytes / byte cap⌉)` roughly equal pieces (a slight overflow is a plain halving).

**Safety valve `chunk_count_max`**: once a group exceeds "count cap × entries per chunk × 0.7", the per-chunk entry cap grows with the group:
`effective cap = max(chunk_entries, ⌈Count / (chunk_count_max × 0.7)⌉)`. Default 65536 chunks — inactive below ~23M entries; 0 disables it.
Existing chunks are not re-cut when the cap changes; later splits and initial chunking use the new effective cap.

### 3.5 `g` and `graphdb:open/2` options

```
g (layout 1) = <<1:8, InlineMax:32, ChunkMax:32, PropsMax:16>>                                        %% 11 B
g (layout 2) = <<2:8, InlineMax:32, ChunkMax:32, PropsMax:16, ChunkEntries:32, ChunkCountMax:32,
                 DirInlineMax:16, DirNodeMax:16>>                                                     %% 23 B
```

| `open/2` option | Meaning | Layout 1 default | Layout 2 default |
|---|---|---|---|
| `adj_layout` | layout for a new store | — | **2** |
| `adj_inline_max` | head above this ⇒ chunk the largest inline group (bytes) | 4096 | 4096 |
| `adj_chunk_entries` | max entries per chunk (main cap) | — | 512 |
| `adj_chunk_max` | per-chunk byte cap (a safety cap in layout 2) | 4096 (relaxed for huge groups) | 65536 |
| `adj_chunk_count_max` | per-group chunk-count safety valve (0 = off) | — | 65536 |
| `props_inline_max` | properties above this go to family `p` | 128 | 128 |
| `adj_dir_inline_max` | more chunks than this ⇒ external directory | — | 16 |
| `adj_dir_node_max` | max entries per directory node | — | 256 (node ≤ 4 KiB) |

Parameters only take effect when the store is created; afterwards `g` wins. `graphdb:graph_config/1` returns `#{layout => 1 | 2, …}`.
Invalid options raise `{badarg, {Opt, V}}` before the store is opened. A group without rank / properties at 512 entries per chunk has exactly
layout 1's 4 KiB chunks, so ordinary vertices look the same as in layout 1.

### 3.6 Invariants

Layout 1's invariants hold, with #3 extended: with an inline directory, as in layout 1; with an external one, the set of level-1 child
bounds enumerated from the root equals the set of existing chunk keys, each node's bounds ascend and start with its own bound, and the chunk
count equals `NChunks` in the head; nothing under `d vid dir etype` is unreachable (no keys there unless the group is external).
`graphdb:check_invariants/1` scans family `d` and reports `missing_dir_node` / `bad_dir_node` / `dir_node_level` / `dir_node_bound` /
`dir_order` / `dir_chunk_count` / `orphan_dir_node`.

## 4. Write path (`graphdb_adj` write sessions)

- **Locate**: binary search in the head for an inline directory; for an external one, point-read the nodes from the root down (`xwalk`).
  Nodes are cached in the session by key; in direct mode their versions join the read set (the same `rconds` map as chunks).
- **Add / delete an entry**: rewrite the chunk and the head (Count ± 1), as in layout 1.
- **Finalize**: `normalize_chunked` (only this group's touched chunks: drop empty ones, split oversized ones; on an external directory remove /
  insert bounds one by one, split overflowing nodes upwards, grow a level on a root split, drop a level when the root has a single child) →
  `unchunk_small` (a group below `inline_max / 4` goes back inline, deleting its nodes too) → `xrebalance` (inline directory with more than
  `dir_inline_max` chunks ⇒ build the tree; external with fewer than `dir_inline_max / 2` ⇒ back inline, with hysteresis) →
  `chunk_oversized` → `xrebalance`.
- **Removing a bound**: a node that becomes empty is deleted and removed from its parent; removing a node's first entry renames the node to
  its new first entry (the parent follows, recursively) — no empty placeholder chunks. Chunk 0 (bound (0,0)) is never deleted, so the
  leftmost path is never renamed and the root is never emptied.
- **Group emptied**: all chunks and all directory nodes are deleted (so the last `del_vertex` batch needs no extra `d` prefix scan).
- **Ops**: head (conditional) + chunk deletes / puts + node deletes / puts + checks for chunks and nodes read but not written. Node deletes
  are only emitted for nodes present on disk when read (`ondisk`); created-then-deleted nodes write no tombstone. Chunks of an external
  directory are not in the head, so chunk deletes also consult `ondisk`.
- **Stale**: if a node is missing while walking the tree — only possible if someone changed the vertex after the head was read — the session
  is marked `stale`; commit returns `conflict` in direct mode (the facade backs off and retries) and takes `bitcask_txn`'s restart path inside
  transactions. Nothing is written on top of a stale tree.
- Records per edge: source head, target head, one target chunk — as in layout 1; a split adds one chunk and one level-1 node.

## 5. Read path

- `out_edges` / `in_edges` / `neighbors`: depth-first from the root; each level-1 node's bounds go to the per-chunk point reads; stops at
  `limit` (reading the first few entries only walks the leftmost path). Missing nodes count as empty (the same weak consistency as "listed
  but absent" chunks); with `consistent => true` the nodes read join the read set validated under the write lock.
- `edge` / lookups: head → point-read nodes level by level → one chunk.
- `degree`: the head only (no longer the whole chunk directory — much faster on big accounts, §7).
- Heights (512 entries per chunk, 256 per node, 70% full): inline directory up to ~5800 edges (16 chunks), 1 level up to ~90k, 2 levels up
  to ~24M; with the safety valve no group exceeds three levels.

## 6. Layout versions and old stores

- New stores write layout 2's `g`; `{adj_layout, 1}` still creates a layout 1 store (openable by older releases).
- New code reads and writes both: **a store whose `g` is version 1 is written with layout 1's rules**.
- `graphdb:upgrade_layout(Handle, Opts)` (explicit, one-way): rewrites `g` to version 2 (conditionally on its version), keeping the store's
  `inline_max` / `props_max`, taking layout 2's parameters from Opts; already layout 2 ⇒ no write, returns the current parameters. Data is not
  rewritten — **converted when touched**: a group whose directory exceeds `dir_inline_max` is externalized the next time it is written,
  oversized chunks are cut the next time they are written. Reads never depend on conversion being complete; layout 2 reads oversized layout 1
  chunks fine. After upgrading, older releases refuse to open the store (`{error, {graph_layout, 2}}`).
- `g` is read once per write session (not cached), so an upgrade takes effect on the same handle immediately.

## 7. Measurements (this implementation, `apps/bitcask/test/graph_layout2_bench`)

A big account is bulk-built with `put_edges` (even srcs → hub), then 2000 in-edges are added one at a time (random odd srcs, uniformly between
existing entries); default parameters per layout; host .13, 2026-11-25, one run. Bytes = growth of `*.data` during the single-edge phase / edges
(including the source end).

| In-degree | Layout | B written per edge | add µs | lookup µs | first 100 µs | in-degree µs | full read ms | shape |
|---|---|---|---|---|---|---|---|---|
| 3k | 1 | 2251 | 10.5 | 1.69 | 17.5 | 0.73 | 0.2 | 18 chunks |
| 3k | 2 | 2198 | 9.9 | 1.65 | 11.2 | 0.68 | 0.2 | 12 chunks |
| 30k | 1 | 4976 | 16.3 | 1.77 | 8.9 | 0.90 | 1.7 | 175 chunks |
| 30k | 2 | 2392 | 17.0 | 3.88 | 10.4 | 0.53 | 1.5 | 117 chunks, 1-level dir |
| 300k | 1 | 22089 | 49.6 | 3.57 | 21.2 | 2.79 | 42.5 | 1543 chunks |
| 300k | 2 | 4214 | 25.2 | 4.57 | 11.7 | 0.50 | 38.3 | 999 chunks, 2-level dir |
| 3M | 1 | 56837 | 53.5 | 7.02 | 15.8 | 5.41 | 629 | 2801 chunks |
| 3M | 2 | 4432 | 25.8 | 5.21 | 11.1 | 0.47 | 739 | 5978 chunks, 2-level dir |

- Writes on big accounts flatten at ~4.3 KiB per edge: 5.2× less at 300k, 12.8× less at 3M; adding an edge is twice as fast. Accounts with up
  to a few thousand followers are essentially unchanged.
- Lookups read one or two extra directory nodes: 1.8 → 3.9 µs at 30k, 3.6 → 4.6 µs at 300k, and faster at 3M (layout 1 reads a 45 KiB head).
  First-100 and in-degree are faster. A full read of 3M entries is 18% slower (more chunks, one point read each).
- The 4.2–4.4 KiB at 300k / 3M is above keelson's prototype (~3.1 KiB): bulk-built chunks are full (~510 entries), so the following single
  inserts split almost every chunk they first touch, writing one extra chunk and a 4 KiB level-1 node. At steady state (chunks ~70% full) it
  should fall back to ~3 KiB — an inference, not measured.
- The node read check (ascending bounds) first sliced a sub-binary per entry: 11.9 µs per lookup at 300k; a single-pass match brought it to
  4.6 µs (decoding a 256-entry node takes ~1.6 µs).

## 8. Open / not done

- **Key encoding differs from keelson**: binary here (head 13 B, chunk 34 B, node 35 B), fixed-width hex text in keelson / keel; the **values**
  are byte-identical but the stores are not interchangeable. Whether to unify is the owner's call (keelson design Q1).
- Delete-heavy workloads: half-empty chunks and sparse nodes are not merged; the tree only disappears when the chunk count drops below
  `dir_inline_max / 2` (a root with a single child does drop a level).
- Concurrent writes to one hot vertex are still serialized by "the head is the version"; the group-commit writer (keelson design §6.1 / Q9) is
  not implemented.
- `put_edges`' `batch_vids` default of 256 is unchanged (keelson design Q8: it dominates bulk-import write volume).
- Not measured: cold-disk reads, how fast merge reclaims old chunk versions.
