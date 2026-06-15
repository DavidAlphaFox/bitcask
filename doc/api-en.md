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
| `{embedder, {Provider, Cfg}}` | **Recommended.** open builds the ctx via `bitcask_embedder:new(Provider, Cfg)` and auto-derives the collection dimension from the embedder's `vector_dim`. Enables auto-embed on `put`/queries. | `Provider = openai \| anthropic \| {custom, Mod}`; `Cfg` is a map. Pre-built ctx maps are **rejected** (`{error, {bad_embedder, _}}`). When present, `{vector_dim, N}` is taken over by the embedder. |
| `{vector_dim, N}` | Vector dimension — manual-vector path only (no embedder) | `N > 0`; must match on-disk meta on reopen |
| `{vector_metric, M}` | Distance/similarity metric — see below | `cosine` (default) \| `l2` \| `dot`; **fixed at creation** (reopen with a different metric → `mode_mismatch`) |

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
- **doc map** (index mode) — `#{text => binary(), fields => [{Field, Text}],
  vector => binary(), meta => binary()}`. All keys optional:
  - `text` — analyzed into the default BM25 field.
  - `fields` — list of `{FieldName::binary(), Text::binary()}` for multi-field
    indexing; also merged into the default field so `search_text` still hits.
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
| `search_phrase(H, Query[, K])` | exact adjacent phrase |
| `search_fields(H, Query[, K])` | `field:term^boost` syntax; unscoped terms = default field |
| `search_near(H, Query, Slop[, K])` | terms in order within gap `=< Slop`; `Slop=0` = phrase |
| `search_fuzzy(H, Query, MaxEdit[, K])` | Levenshtein distance `=< MaxEdit` (typically 1–2) |
| `search_wildcard(H, Pattern[, K])` | `*` and `?` wildcards |

`Filter` (on `search_text/4`) is a meta filter — see below.

---

## Vector & hybrid search

`VecBin` is an f32 little-endian binary of length `vector_dim * 4`.

### `embed(Handle, Text) -> {ok, VecBin} | {error, Reason}`
Encode `Text` with the handle's configured embedder. `{error, no_embedder}` if
none was configured at open.

### `search_vector(H, Query[, K[, Ef[, Filter]]])`
`Query` is either a `VecBin` or `{text, Bin}` (auto-embedded via the handle).
- `K` — top-K (default 10).
- `Ef` — HNSW search width / candidate list size (`0` = engine default
  `max(K, 64)`; larger = more accurate, slower).
- `Filter` — meta filter.

Returns `{ok, [{Key, Ord, Score}]}` (Score = similarity under the metric).

### `search_hybrid(H, Text[, VecOrAuto[, K[, Filter]]])`
RRF fusion of a BM25 leg (over `Text`) and a vector leg. The 3rd argument selects
the vector source:
- omit it (`/2`) or pass the atom **`auto`** → embed `Text` via the handle's
  embedder (one text drives both legs). `auto` is required to also pass `K`/`Filter`.
- pass a **`VecBin`** → explicit query vector.

Forms: `search_hybrid(H, Text)` · `(H, Text, VecBin)` · `(H, Text, auto|VecBin, K)`
· `(H, Text, auto|VecBin, K, Filter)`. Either leg may be empty (`Text = <<>>` or
`VecBin = <<>>`) for single-leg; both empty → `{error, _}`. Each leg fetches
`max(K*4, 64)` candidates internally, then returns top `K` after fusion.

---

## Meta filters

A filter restricts results to documents whose `meta` matches. Documents with no
`meta` never pass a filter.

**Condition:** `#{key => Key, op => Op, value => V}` where `Op` is `eq | gte | lte`,
or `#{key => Key, op => in, values => [V, ...]}`. `Key` may be a binary or atom.

**Combinators:**
- a **list** of conditions = AND: `[Cond1, Cond2]`
- `#{logic => 'and' | 'or', conditions => [Cond, ...]}`
- nested trees via `#{logic => ..., children => [SubFilter, ...]}`

Malformed shapes (bad `op`, missing `values` for `in`, atom-as-binary misuse) →
`badarg`.

### `encode_meta(Entries) -> MetaBin`
Encode a map (or proplist) into the `meta` blob for `put`. Value types: `integer`
→ int64, `float` → double, `binary` → string, `true`/`false` → bool, `undefined`
→ null. Use the result as the `meta` key of a put doc map.

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
