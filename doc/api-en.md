# Bitcask API Reference (English)

中文版见 [`api-zh.md`](api-zh.md)。

All public functions live in the `bitcask` module unless noted. The embedder
helpers live in `bitcask_embedder`.

## Handle model & modes

`bitcask:open/2` returns a **handle** `{CaskRef, EmbedderCtx}` (a 2-tuple), not a
bare reference. Pass the whole tuple to every other call. `EmbedderCtx` is
`undefined` when no embedder is configured.

Three modes, selected by open options:

| Mode | Enabled by | Capabilities |
|------|-----------|--------------|
| KV | (default) | `get`/`put`/`delete`/`sync`/`fold`/`merge` |
| Index (BM25) | `{analyzer, _}` | + `search_text`/`phrase`/`fields`/`near`/`fuzzy`/`wildcard` |
| Vector | `{embedder, _}` or `{vector_dim, N}` (also requires index mode) | + `search_vector`/`search_hybrid`/`embed` |

---

## Lifecycle

### `open(Dir) -> Handle | {error, Reason}` · `open(Dir, Opts) -> Handle | {error, Reason}`
Open (or create) a cask at directory `Dir`. Returns `{CaskRef, EmbedderCtx}`.
Common errors: `write_locked`, `enoent`, `mode_mismatch` (opts disagree with the
on-disk meta), `{bad_embedder, _}`, `{bad_opt, _}`.

**Open options** (anything else is silently ignored):

*Core*

| Option | Meaning | Default | Constraints |
|--------|---------|---------|-------------|
| `read_write` | Acquire writer lock; enable writes | read-only | one writer per dir (cross-OS-process) |
| `{expiry_secs, N}` | Entries older than N seconds are expired | none | integer seconds |
| `{max_file_size, N}` | Roll active data file past N bytes | 2 GiB | bytes |
| `{sync_strategy, S}` | `none` \| `o_sync` \| `{seconds, N}` | `none` | — |
| `{tombstone_version, V}` | Tombstone encoding | `2` | `1` \| `2` |
| `{max_read_handles, N}` | Read-handle cache cap (each handle = 1 fd + 1 sealed mmap) | `0` = automatic | The automatic tier derives from `RLIMIT_NOFILE` and is **clamped to `[64, 1024]`** (6.0.0); `unlimited` disables the cap explicitly |
| `{keydir_cache_entries, N}` | **6.0.0**: hot-cache entry budget for the disk-resident keydir (Level B) | `0` = unlimited = fully in memory | Opt-in only when `> 0`; see below |

**`keydir_cache_entries` in detail.** `0` (default) keeps today's behaviour: the
keydir lives entirely in memory. With `> 0`, the keydir degrades to a hot cache
(sampled eviction within over-budget shards), and point lookups resolve through
cache → memdelta → BCOK v2 run (embedded bloom + block LRU, cold get ≤2 preads);
`fold`/`range` enumerate completely through the combined view while evicting.
Upstream measured 100M `doc:` keys: 11 GB resident → **1.14 GB peak while loading
/ 0.80 GB on reopen (-90%)**, with no regression on hot get/put/merge.

> ⚠️ Enabling it for the first time on a directory without the Level B stamp
> triggers a **full OKI rebuild** (that one open is slow); afterwards the
> manifest carries the stamp and reopens are fast.
> ⚠️ A Level A writer (one that omits this option) **clears the stamp** on
> reopen; going back to Level B rebuilds and self-heals.
> ⚠️ `merge_only` sidecars and Level B directories are **mutually exclusive** —
> open is refused outright (a sidecar's unhooked relocations would silently
> corrupt the combined view's positional authority).
> The budget is a soft target (eviction pauses while a fold is active).

*Merge thresholds* (used by `needs_merge`/`merge`): `frag_merge_trigger`,
`dead_bytes_merge_trigger`, `frag_threshold`, `dead_bytes_threshold`,
`small_file_threshold`, `max_merge_size`, `expiry_grace_time`.

*Index mode (BM25)*

| Option | Meaning | Constraints |
|--------|---------|-------------|
| `{analyzer, Type}` | `ngram` \| `whitespace` \| `jieba` | required to enable search |
| `{dict_path, Path}` | jieba dictionary dir | required for `jieba` (auto-defaults to `priv/dict`) |
| `{enable_stop_words, true}` | stop-word filtering | — |
| `{min_n, N}` / `{max_n, N}` | n-gram bounds (ngram) | `1 =< min_n =< max_n` |
| `{min_token_length, N}` | drop short latin tokens | `N >= 1` |
| `{enable_stemming, true}` | Porter stemming wrapper | — |

*Vector mode*

| Option | Meaning | Constraints |
|--------|---------|-------------|
| `{embedder, {Provider, Cfg}}` | open builds the ctx via `bitcask_embedder:new(Provider, Cfg)` and auto-derives the collection dimension from the embedder's `vector_dim`. Enables auto-embed on `put`/queries. The ctx is **owned by this handle alone**. | `Provider = openai \| anthropic \| {custom, Mod}`; `Cfg` is a map. Pre-built ctx maps are **rejected** (`{error, {bad_embedder, _}}`). When present, `{vector_dim, N}` is taken over by the embedder. |
| `{embedder, ServerRef}` | **Use this for stateful providers (local models).** A [`bitcask_embedder_server`](../src/bitcask_embedder_server.erl) process. Same behaviour, but the provider state lives in that process: **shared across casks**, lifecycle tied to the process (released in `terminate/2`). Normally started by `bitcask_sup` from the application env `{embedder, #{name, provider, config}}`. ⚠️ Do **not** put HTTP providers here — they are stateless and want concurrency; the process serialises them into one chain. | `ServerRef = pid() \| registered name \| {global,_} \| {via,M,N}`. Not started → `{error, {embedder_not_running, Ref}}`; if it dies at runtime `put` gets `{error, {embedder_not_running,_}}` and the **caller is not killed**. ⚠️ Configured-but-failing → the whole application fails to start and `open` returns `{error, {bitcask_app_start_failed,_}}` (deliberate). See [`doc/local-embedding-en.md`](local-embedding-en.md). |
| `{vector_dim, N}` | Vector dimension — manual-vector path only (no embedder) | `N > 0`; must match on-disk meta on reopen |
| `{vector_metric, M}` | Distance/similarity metric — see below | `cosine` (default) \| `l2` \| `dot`; **fixed at creation** (reopen with a different metric → `mode_mismatch`) |
| `{vector_engine, E}` | v4.0.0: vector engine — `hnsw` (in-memory graph, up to a few M vectors) \| `ivfrq` (IVF-RaBitQ disk tier, recommended for 10M-100M) \| `diskann` (Vamana graph, **experimental**) | Default `hnsw`; **fixed at creation** and persisted in `bitcask.meta` (reopen with a different engine → `mode_mismatch`); disk-tier engines require `cosine`/`dot` (`l2` → `{error, _}`); offline switching via libbitcask's `vec_engine_migrate` tool |

*Vector engine tuning* (v4.0.0; `0` = engine-specific auto default, normally not needed):
`{hnsw_m, N}`, `{hnsw_ef_construction, N}` (HNSW graph degree / build ef);
`{hnsw_build_nav_int8, B}` (HNSW int8 mixed-precision build navigation, default
`true` — insert +29%~75% with zero recall@10 loss; `false` = full-f32 fallback
gate); `{vector_rebase_min_docs, N}` (vector checkpoint crash-recovery replay
bound, all engines, default 262144); `{vector_ivf_nlist, N}`,
`{vector_ivf_nprobe, N}` (ivfrq cluster count / query probe count, `0` = auto;
a non-zero `Ef` in `search_vector` is interpreted as nprobe);
`{vector_diskann_r, N}`, `{vector_diskann_l_build, N}` (diskann adjacency
capacity / build beam width; query beam width uses the `Ef` parameter).

**`vector_metric` in detail.** Picks how the HNSW index compares vectors. For all
three, the returned `Score` is ordered so that **higher = more similar/closer**
(results are sorted descending by `Score`):

| Metric | What it computes | `Score` returned | Notes / constraints |
|--------|------------------|------------------|---------------------|
| `cosine` (default) | cosine similarity | cosine similarity in `[-1, 1]` (1 = identical direction) | Stored **and** query vectors are L2-normalized by the engine (idempotent on re-write), so magnitude is ignored. A **zero vector is rejected** (`{error, _}`) since it has no direction. Implemented internally as `dot` over normalized vectors. |
| `dot` | raw inner product | the dot product (unbounded) | **No normalization** — vector magnitude affects the score. Use when your embeddings are already normalized or when magnitude is meaningful. |
| `l2` | squared Euclidean distance | **negative** squared distance (`=< 0`; closer ⇒ nearer 0) | Negated so the "higher is better" ordering holds uniformly. |

Guidance: most text-embedding models (incl. qwen3-embedding, which returns
L2-normalized vectors) → use `cosine` (or `dot`, equivalent on normalized inputs).
Use `l2` only when absolute geometric distance is what you want. The metric is
written into the collection meta at first open and cannot change afterwards.

### `close(Handle) -> ok`
Flush, release the writer lock, drop the keydir refcount. The handle is unusable
afterwards.

### `close_write_file(Handle) -> ok`
Finalize the active data file and release `bitcask.write.lock`, but keep the
handle usable (next `put`/`delete` re-acquires the lock and starts a new file).

### `sync(Handle) -> ok`
`fsync` the active data file. No-op under `{sync_strategy, o_sync}`.

---

## Key/value operations

### `get(Handle, Key) -> {ok, Value} | not_found | {error, Reason}`
`Key`/`Value` are binaries. Expired or tombstoned entries read as `not_found`.

### `put(Handle, Key, Value) -> ok | {error, Reason}`
`Value` forms:

- **binary()** — raw KV value.
- **doc map** (index mode) — `#{text => binary(), fields => #{Field => Text},
  vector => binary(), meta => binary()}`. All keys optional:
  - `text` — analyzed into the default BM25 field.
  - `fields` — map of `#{FieldName::binary() => Text::binary()}` for multi-field
    indexing; also merged into the default field so `search_text` still hits.
    A non-map (e.g. a proplist) → `badarg`.
  - `vector` — f32 little-endian binary, length `vector_dim * 4` bytes.
  - `meta` — structured metadata blob from `encode_meta/1` (for filters).
- **`tombstone`** — legacy alias for `delete`.

**Auto-embed:** if an embedder was configured at open and the doc has `text` but
no `vector`, `put` calls the embedder and stores the resulting vector. Passing an
explicit `vector` skips embedding.

Constraints: a `vector` whose byte size is not a multiple of 4 → `badarg`; wrong
dimension → `{error, _}`; under `cosine`, a zero vector → `{error, _}`.

### `delete(Handle, Key) -> ok`
Write a tombstone. Space is reclaimed at the next merge.

---

## Iteration

Iteration is a keydir **snapshot** — writes after the fold starts are not seen.

| Function | Callback / Notes |
|----------|------------------|
| `list_keys(Handle) -> [Key] \| {error,_}` | live keys, order undefined |
| `fold(Handle, Fun, Acc0)` | `Fun(K, V, Acc) -> Acc'` |
| `fold(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombs)` | tombstones surface as `Fun({tombstone, K}, V, Acc)` when `SeeTombs` |
| `fold_keys(Handle, Fun, Acc0)` | `Fun(#bitcask_entry{}, Acc) -> Acc'` |
| `fold_keys(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombs)` | tombstones as `{tombstone, #bitcask_entry{}}` |
| `stream_fold(Handle, Fun, Acc0)` / `/4` (batch size) | internally batched fold |
| `stream(Handle) -> S` · `next(S) -> {ok,K,V} \| done \| {error,_}` · `stop(S) -> ok` · `with_stream(Handle, F)` | producer-process streaming; multiple per handle |

`MaxAge` is in **microseconds** (`-1`/negative = unlimited). `MaxPut` caps writes
allowed during the fold (`-1` = unlimited).

---

## Ordered range queries (6.0.0)

Walks `[Lo, Hi)` in key lexicographic order at **O(range)** cost rather than
filtering the whole table. Backed by the OKI ordered-key index.

> ⚠️ **Not a snapshot.** Consistency is per-key weak (the same tier as
> `parallel_scan`) — writes concurrent with the iteration may be partially
> visible. Use `fold` when you need a snapshot.

| Function | Notes |
|----------|-------|
| `range(Handle, {Lo, Hi}) -> [{Key, Value}] \| {error,_}` | `Lo` inclusive, `Hi` exclusive; either may be `undefined` = unbounded |
| `range(Handle, {Lo, Hi}, Opts)` | as above, with tuning options |
| `range_fold(Handle, {Lo, Hi}, Opts, Fun, Acc0)` | `Fun(K, V, Tstamp, Ord, Acc) -> Acc'`; streaming, never materializes the full result |

`Opts`:

| Option | Default | Notes |
|--------|---------|-------|
| `{prefetch, N}` | `0` (off) | `N > 1` merges N keys at a time and fetches their values concurrently. **Changes only when values are read — never the output order or contents.** Pays off for large windows over cold values; loses to thread-creation cost on small ones |
| `{prefetch_threads, N}` | `0` | `0` = `min(online cores, 4)`; narrowed to the key count when a batch is smaller |
| `{want_meta, true}` | off | `V` becomes `#{text => Bin, meta => Bin \| undefined}`, the same shape `get` returns in index mode. The meta and text come from the same read |
| `{filter, F}` | none | meta filter (same shape as `search_text/4`). It is evaluated per entry in C++, and entries that fail are not returned. Entries with no meta never pass |

The idiomatic prefix scan sets the upper bound to the **byte after** the prefix:
`range(H, {<<"user:">>, <<"user;">>})`.

When the OKI is unavailable, the cause is reported as **one of two distinct
errors** (since 6.1.0) — they call for different remedies, hence the split:

| Return | Cause | What to do |
|--------|-------|-----------|
| `{error, no_index}` | The index **was never built for this handle**: a read-only or `merge_only` open of a directory that has no OKI | Reopen `read_write` and it builds automatically; or fall back to `fold` plus prefix filtering |
| `{error, index_rebuild_failed}` | A writable open **attempted a rebuild and it failed** (IO / environment problem; details are in the log) | Fix the environment and reopen to retry. Do **not** read this as "no data" — the data is there |

> **Read-only opens of a populated database work fine** — the read-write session
> already persisted the OKI, so a read-only handle just reads it and never needs
> (or is allowed) to rebuild. What returns `no_index` is a **never-written**
> directory.
>
> ⚠️ Neither is collapsed into an empty result `[]`: that would make "a populated
> database silently returns nothing because its index is broken" undetectable.
> This matters most for `index_rebuild_failed`, which means the data is present
> and only the index is missing — reporting it as an empty result would be a
> genuine phantom-data-loss.
>
> ⚠️ The OKI is only a derived cache — in both cases `get` / `put` / `fold` keep
> working normally; **only range is unavailable**.

---

## Atomic batches and multi-key transactions (6.0.0)

`Ops :: [{put, Key, Value} | {remove, Key}]`, with `Key`/`Value` both
`binary()`. Any unrecognized shape (wrong tag, wrong arity, non-binary) raises
`badarg` — entries are **never silently dropped**, since quietly losing one would
make "atomic" meaningless.

After a crash or power loss the batch **either fully applies or does not apply at
all** (the on-disk batch header declares the extent; an incomplete extent
truncates the whole batch at recovery).

> ⚠️ Atomicity and durability are **orthogonal**: without an fsync, power loss can
> still lose the entire batch — but never half of one.
> ⚠️ **No isolation (I) and no CAS**: intermediate state is visible to concurrent
> readers; concurrent commits with overlapping key sets have no ordering
> guarantee and must be serialized by the application. Disjoint key sets are safe.
> ⚠️ **The first call lazily upgrades the directory's `bitcask.meta` to v6**,
> after which readers older than upstream 5.1.0 cannot open it. Directories that
> never call it stay at v5.

| Function | Notes |
|----------|-------|
| `put_batch_atomic(Handle, Ops) -> ok \| {error,_}` | Raw batch. The same key may repeat (applied in order = intra-batch LWW); an empty batch is a no-op |
| `txn_commit(Handle, Ops) -> ok \| {error,_}` | Equivalent to `txn_commit(H, Ops, sync_on_commit)` |
| `txn_commit(Handle, Ops, Sync)` | `Sync :: sync_on_commit \| no_sync` |

`txn_commit` validates beyond `put_batch_atomic`: non-empty batch, non-empty
keys, no duplicate keys, and no use of the reserved `"_txn:"` prefix. A violation
returns `{error, {invalid_option, Msg}}` with **zero side effects**. An invalid
`Sync` raises `function_clause` (rejected in the Erlang layer).

---

## Maintenance

### `merge(Dir)` · `merge(Dir, Opts)` · `merge(Dir, Opts, Which)`
Open a temporary `read_write` cask on `Dir`, run one merge, close it. Uses
`bitcask.merge.lock` (does not block a live writer). `{error, {merge_locked, _, Dir}}`
if another merger holds it. If you already hold a writer handle, prefer
`bitcask_cpp_nifs:cask_merge(Ref, Files)` to avoid the temporary open.

### `needs_merge(Handle) -> false | {true, {Files, Expired}}` · `/2`
Whether a merge is warranted; the result feeds straight into `merge/3`.

### `status(Handle) -> {KeyCount, FilesInfo}`
### `is_frozen(Handle) -> boolean()`
True while a fold snapshot is active.
### `is_empty_estimate(Handle) -> boolean()`
O(1) estimate; once any key has been written it stays `false`.

---

## BM25 search (index mode)

All return `{ok, [{Key, Ord, Score}]}` (descending score), or `{error, no_index}`
in KV mode. `Ord` is the internal document ordinal. `K` = number of hits to
return (default `10`; `K =< 0` falls back to `10`).

| Function | Extra params |
|----------|--------------|
| `search_text(H, Query[, K[, Filter]])` | bag-of-words |
| `search_phrase(H, Query[, K[, Filter]])` | exact adjacent phrase |
| `search_fields(H, Query[, K[, Filter]])` | `field:term^boost` syntax; unscoped terms = default field |
| `search_near(H, Query, Slop[, K[, Filter]])` | terms in order within gap `=< Slop`; `Slop=0` = phrase |
| `search_fuzzy(H, Query, MaxEdit[, K[, Filter]])` | Levenshtein distance `=< MaxEdit` (typically 1–2) |
| `search_wildcard(H, Pattern[, K[, Filter]])` | `*` and `?` wildcards |

`Filter` is a meta filter (see below); `undefined` means no filter. With a filter, the engine
keeps fetching candidates until it has `K` hits, so fewer than `K` hits means that is all there
is. Equal-score hits are ordered stably by (segment order, write order within a segment), so a
smaller `K`'s result is a prefix of a larger `K`'s. The exception is `search_fields` with several
fields or boost groups: it approximates by taking each field's top-K and summing, so the prefix
property does not hold there.

---

## Vector & hybrid search

`VecBin` is an f32 little-endian binary of length `vector_dim * 4`.

### `embed(Handle, Text) -> {ok, VecBin} | {error, Reason}`
Encode `Text` with the handle's configured embedder. `{error, no_embedder}` if
none was configured at open.

### `search_vector(H, Query[, K[, Ef[, Filter]]])`
Vector nearest-neighbor search (the engine is the one picked at creation via
`{vector_engine, E}`, default HNSW). The four arities are one call with defaults
filled in progressively:

| Arity | Signature | Equivalent to |
|-------|-----------|---------------|
| `/2` | `search_vector(H, Query)` | `/3` with `K=10` |
| `/3` | `search_vector(H, Query, K)` | `/4` with `Ef=0` |
| `/4` | `search_vector(H, Query, K, Ef)` | calls the engine (no filter) |
| `/5` | `search_vector(H, Query, K, Ef, Filter)` | calls the engine (with meta filter) |

Parameters:
- `Query` — a `VecBin` (f32 LE, `vector_dim*4` bytes) or `{text, Bin}` (auto-embedded
  via the handle's embedder; `{error, no_embedder}` if none configured). Accepted by
  every arity.
- `K` — top-K (default 10).
- `Ef` — search width, interpreted per engine: HNSW = candidate list size
  (`0` = engine default `max(K, 64)`); ivfrq = query probe count nprobe
  (`0` = auto); diskann = query beam width. Larger = more accurate, slower.
- `Filter` — meta filter.

Returns `{ok, [{Key, Ord, Score}]}` (Score = similarity under the metric).

```erlang
search_vector(H, VecBin).                 %% default K=10, default Ef
search_vector(H, VecBin, 20).             %% set K
search_vector(H, VecBin, 20, 128).        %% raise Ef for higher recall
search_vector(H, {text, <<"machine learning">>}, 10, 0,
              #{key => <<"category">>, op => eq, value => <<"tech">>}). %% auto-embed + filter
```

### `search_hybrid(H, Text[, VecOrAuto[, K[, Filter]]])`
RRF fusion (`1/(60+rank)`, ties broken by smaller `ord`) of a BM25 leg (over `Text`)
and a vector leg. The 3rd argument selects the vector source:
- omit it (`/2`) or pass the atom **`auto`** → embed `Text` via the handle's
  embedder (one text drives both legs). `auto` is required to also pass `K`/`Filter`.
- pass a **`VecBin`** → explicit query vector.

The four arities fill defaults progressively:

| Arity | Signature | Equivalent to |
|-------|-----------|---------------|
| `/2` | `search_hybrid(H, Text)` | `/4` with vector slot `auto`, `K=10` (fully auto) |
| `/3` | `search_hybrid(H, Text, VecBin)` | `/4` with `K=10` (explicit vector) |
| `/4` | `search_hybrid(H, Text, auto\|VecBin, K)` | calls the engine (`auto` embeds first) |
| `/5` | `search_hybrid(H, Text, auto\|VecBin, K, Filter)` | engine + meta filter |

Either leg may be empty (`Text = <<>>` or `VecBin = <<>>`) for single-leg; both empty
→ `{error, _}`. Each leg fetches `max(K*4, 64)` candidates internally, then returns
top `K` after fusion as `{ok, [{Key, Ord, RrfScore}]}`.

```erlang
search_hybrid(H, <<"intro to machine learning">>).        %% fully auto: text drives BM25 + embed
search_hybrid(H, <<"intro to machine learning">>, auto, 20). %% auto-embed + set K
search_hybrid(H, <<"machine learning">>, MyVecBin, 10).   %% text → BM25, explicit vector
search_hybrid(H, <<"machine learning">>, auto, 10,
              #{key => <<"category">>, op => eq, value => <<"tech">>}). %% + filter
search_hybrid(H, <<"machine learning">>, <<>>, 10).       %% single-leg: BM25 only
search_hybrid(H, <<>>, MyVecBin, 10).                     %% single-leg: vector only
```

> `search_vector` is **pure vector** NN (score = vector similarity); `search_hybrid`
> is **BM25 + vector RRF fusion** (score = fused rank), balancing exact keyword
> matching with semantic recall.

---

## Meta filters

A filter restricts results to documents whose `meta` matches. Documents with no
`meta` never pass a filter (not even `neq`). Passing the atom `undefined` means no filter.

**Condition:** `#{key => Key, op => Op, value => V}`, where `Op` is one of
`eq | neq | gt | gte | lt | lte`. There are two other forms:
- `#{key => Key, op => in, values => [V, ...]}` (the list must not be empty);
- `#{key => Key, op => exists}` (no `value`).

`Key` must be a binary; an atom is `badarg`. `V` may be an integer (int64), a float, a
binary, `true`/`false`, or `undefined` (null). Any other atom is `badarg`.

**Combinators:**
- a **list** of conditions = AND: `[Cond1, Cond2]` (conditions only)
- a single condition map can also be passed as a filter on its own
- `#{logic => 'and' | 'or', conditions => [Cond, ...], children => [SubFilter, ...]}`. All three
  keys are optional, and `logic` defaults to `'and'`. Each element of `children` must be one of
  these `logic` maps, not a list.

**Semantics** (`meta_filter.hpp`):
- `eq`, `neq` and `in` compare only values of the same type: `1` is not equal to `1.0`.
- A missing field reads as null, so `{eq, undefined}` matches a missing field. `in` is always
  false for a missing field.
- `gt`, `gte`, `lt` and `lte` compare only integer with integer, or float with float. Any other
  pairing is false.
- `exists` means the field is present and not null.
- A filter with no conditions and no children is always true, even when `logic` is `'or'`.

Malformed shapes (unknown `op`, `in` with missing or empty `values`, an atom `Key`, an
unsupported value type) → `badarg`.

### `encode_meta(Entries) -> MetaBin`
Encode a map (or proplist) into the `meta` blob for `put`. Value types: `integer`
→ int64, `float` → double, `binary` → string, `true`/`false` → bool, `undefined`
→ null. Use the result as the `meta` key of a put doc map.

### `decode_meta(MetaBin) -> map()`
Inverse of `encode_meta/1`: decodes the blob into `#{binary() => V}`, with null as
`undefined`. An invalid blob → `badarg`. `get` returns `undefined` when a document has no meta.

---

## Structured queries (`bitcask_query`)

```erlang
{ok, Rows} = bitcask_query:q(H, #{
    key    => {prefix, <<"doc:">>},            % | {range, Lo, Hi} | {eq, K}
    text   => {match, <<"distributed storage">>}, % | {phrase,Q} | {fields,Q} | {near,Q,Slop}
                                               % | {fuzzy,Q,MaxEdit} | {wildcard,P}
    where  => [{<<"year">>, gte, 2024},
               {'or', [{<<"cat">>, in, [<<"db">>, <<"kv">>]}, {<<"hot">>, eq, true}]}],
    vector => VecBin,                          % | {text, Bin}; with {match,_} = hybrid
    limit  => 100,                             % default infinity; page size for page/2
    select => [key, text, meta, score]         % default: all
}).
%% Row = #{key, text, meta => map() | undefined, score}; score only when text-driven
```

**Paging**: `bitcask_query:page(H, Query)` and `page(Cont)` both return `{ok, Rows, Cont}`; `Cont` is
`done` when there is no next page, and `page(done)` returns `{ok, [], done}`. `limit` is the page
size and is required. The cursor is an opaque term that holds no server-side resources, so it can
simply be dropped. Each page fetches one extra row to tell whether another page follows, so when
the row count divides evenly the last page is full and returns `done` directly.

| Driver | Cursor | Paging guarantee |
|---|---|---|
| key (range) | next start key | no duplicates, no gaps, key ascending (`range` is not a snapshot, so writes made while paging may appear on later pages) |
| full text (except `search_fields`) | engine hits consumed | no duplicates, no gaps (relies on libbitcask 6.6.1's prefix-stable ties); each page requeries with an offset, so deep pages cost more |
| vector / hybrid / `search_fields` | set of keys already returned | **no duplicates, but hits can be missed**: results change with K (approximate HNSW, RRF fusion, per-field top-K summed), so a hit that moves up into an earlier page while paging is never shown |

**Vector / hybrid**:
- `vector => VecBin` (f32 little-endian, `vector_dim * 4` bytes) or `{text, Bin}` (encoded with the
  handle's embedder, once per query including all pages).
- `vector` alone runs `search_vector` and accepts `ef` (default 0 = engine default).
- `vector` together with `text => {match, Q}` runs `search_hybrid` (RRF fusion); `ef` is not
  allowed there, and any other text kind returns `{bad_query, {hybrid_needs_match, _}}`.
- `where` is still pushed down. `score` is the similarity for vector search and the RRF score for
  hybrid search.
- With a filter, vector search can itself return fewer hits than requested (HNSW), so fewer than K
  hits has to be treated as the end of the results.

### Secondary indexes

Index a meta field so that `where`-only queries no longer scan the whole table, like
`mnesia:index_read`.

```erlang
ok = bitcask_query:create_index(H, <<"year">>),       % backfills; ok if it already exists
ok = bitcask_query:put(H, Key, #{text => T, meta => M}),   % writes must go through here once indexed
ok = bitcask_query:delete(H, Key),
[{<<"year">>, ready}] = bitcask_query:indexes(H),
{ok, #{driver := index}} = bitcask_query:explain(H, #{where => {<<"year">>, gte, 2024}}),
ok = bitcask_query:drop_index(H, <<"year">>).
```

- **When it is used**: when the query has no `key`, `text` or `vector` condition and its top-level AND
  includes an `eq`, `in`, `gt`, `gte`, `lt`, `lte` or `exists` condition on an indexed field. If several qualify,
  exactly one is picked in the order eq > in > comparison > exists. `neq`, `{F, eq, undefined}` (which matches
  missing fields) and multi-branch `or` do not use an index. `index => none` forces a scan.
- **Order**: rows come back by (index value, primary key) ascending, not by key ascending as a full scan
  returns them. Paging works as usual; the cursor is the next index key.
- **Storage**: indexes live in the same cask as the data under the reserved prefix `<<0,"bitcask_query:">>`.
  Full scans skip those keys, and `bitcask_query:put` rejects keys with that prefix. In index mode the entries
  are empty-text documents: full-text search never hits them, and in our measurements they do not change BM25 scores.
- **Consistency** (⚠️ not atomic): libbitcask atomic batches cannot carry documents with meta, so a document
  and its index entries cannot be written in one batch (reported upstream).
  - Writes take the key's write lock, then add new entries, write the document, and remove old entries. A crash
    part-way can leave stale entries but never drops one.
  - Reads check every candidate against the document's current value before evaluating the full `where`, so
    stale entries never produce wrong or duplicate rows.
  - Cost: one extra `get` per hit, plus a lock and a read of the old value on every write.
- ⚠️ **Writes to indexed fields must go through `bitcask_query:put/delete`.** If a direct `bitcask:put` changes
  meta, the new value is not findable through the index, and the old value's stale entry is filtered out on read.
  Fix it with `drop_index` followed by `create_index`.
- `create_index` registers the index as `building` first, so writes start maintaining it; after the backfill it
  becomes `ready`, and only then do queries use it.

Why not match specs: values are analyzed strings, so text conditions can only be answered by
the inverted index (tokenized in C++), and structured conditions live in `meta`. The planner
picks the driver as follows:

| Conditions | Driver | Order |
|---|---|---|
| `text` / `vector` present | `search_*` (`vector` alone runs `search_vector`; with `{match,_}`, `search_hybrid`) with `where` pushed down as an engine meta filter; `key` post-filters the hits | score desc |
| no `text`, `key => {eq,K}` | `get` | — |
| no `text`, prefix / range | `range`, with `where` pushed down as its `filter` and meta returned with each entry | key asc |
| neither | full-table `range`, same as above; falls back to `fold` on `no_index`, sorted by key once collected | key asc |

`where` semantics match the engine MetaFilter exactly. The tests cross-check search pushdown, range pushdown and BEAM evaluation against each other.

- A document with no meta never passes a non-empty `where`.
- `eq`, `neq` and `in` compare only values of the same type: `1` is not equal to `1.0`. A missing field reads as `undefined`.
- `gt`, `gte`, `lt` and `lte` compare only integer with integer, or float with float.
- `exists` means the field is present and not null.

Field names may be binaries or atoms.

Limitations:

- Text hits carry only keys, so each row's text and meta come from a follow-up `get`. If a document is rewritten between the two reads, the row shows the newer version, which may no longer match `where`.
- When there is a `key` condition, keys are filtered in BEAM, and K is doubled and the search rerun until `limit` is filled.
- `range` is not a snapshot. The query falls back to `fold` only on `no_index` (a read-only open of a directory that never had an OKI); it then calls `get` per row and evaluates `where` in BEAM.
- Requires libbitcask ≥ 6.6.1, which keeps fetching until filtered searches return K hits and orders equal-score hits stably.
- A text-driven query that cannot fill its result within the 1,000,000 engine top-K cap returns `{error, {too_many_hits, 1000000}}` rather than silently truncating.
- An invalid query returns `{error, {bad_query, _}}`.

---

## Embedder API (`bitcask_embedder`)

### `new(Provider, Cfg) -> {ok, Ctx} | {error, Reason}`
`Provider = openai | anthropic | {custom, Module}`. Builds a context. (When using
the recommended `{embedder, {Provider, Cfg}}` open option, you don't call this
directly — open does.)

### `embed(Ctx, Text) -> {ok, VecBin} | {error, Reason}`
### `dim(Ctx) -> pos_integer()` — model's **native** dimension
### `vector_dim(Ctx) -> pos_integer()` — **stored/queried** dimension (MRL target; default = `dim`)

**Provider config (`Cfg`)** — all-positive-integer options validate, else
`{error, {bad_opt, Key}}`:

| Key | Meaning | Default |
|-----|---------|---------|
| `url` | endpoint (OpenAI-compatible `/v1/embeddings`) | required |
| `model` | model name (binary) | required |
| `dim` | model's native output dimension | openai 2560 / anthropic 4096 |
| `vector_dim` | MRL truncation target = stored/queried dim | `= dim`; must be `=< dim` |
| `api_key` | bearer / x-api-key | none |
| `max_input_bytes` | byte-level input cap before embedding | 32768 |
| `timeout_ms` | request total timeout | 30000 |
| `connect_timeout_ms` | connect timeout | 5000 |

**MRL (Matryoshka):** `dim` is always the model's native dimension; `vector_dim`
is the truncated dimension actually stored/queried. When `vector_dim =/= dim`, the
embed request carries `dimensions => vector_dim` so the server truncates +
renormalizes (the endpoint must support it); the returned length is validated and
a mismatch is reported as `{error, {dim_mismatch, Got, Expect}}`.

---

## Return values & errors (summary)

| Call | Success | Notable errors |
|------|---------|----------------|
| `open` | `{Ref, Ctx}` | `write_locked`, `enoent`, `mode_mismatch`, `{bad_embedder,_}`, `{bad_opt,_}` |
| `get` | `{ok, V}` / `not_found` | `{error, _}` |
| `put` | `ok` | `badarg` (bad vector bytes), `{error, _}` (dim/zero-vector/embed) |
| `search_*` | `{ok, [{Key, Ord, Score}]}` | `{error, no_index}`, `{error, _}` |
| `embed` | `{ok, VecBin}` | `{error, no_embedder}`, `{error, {dim_mismatch,_,_}}`, `{error, {http_*,_}}` |
| `merge` | `ok` | `{error, {merge_locked, _, Dir}}` |

## Concurrency constraints (quick reference)

- One writer per directory (enforced cross-process via `bitcask.write.lock`).
- Reads/searches are lock-free and run concurrently with the single writer and the
  async index worker.
- A handle (`{Ref, Ctx}`) may be shared across reader threads; writes are
  caller-serialized (one Erlang process owns the writer). Within one BEAM, multiple
  `open` of the same dir share one in-memory KeyDir. Full model: [`concurrency-zh.md`](concurrency-zh.md).
