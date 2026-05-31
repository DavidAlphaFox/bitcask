# bitcask Usage Guide

This guide covers the C++23 NIF (`cask_cpp`) — the only mode available.
All operations go through `bitcask_cpp_nifs` → `priv/bitcask_cpp.so`.

## Build & Shell

```bash
cd /path/to/bitcask
rebar3 compile        # produces priv/bitcask_cpp.so
rebar3 shell          # start a production-mode shell
```

## NIF Modes

There is **one mode only**: `cask_cpp` (coarse-grained C++ NIF).

```erlang
%% Production default — no option needed
R = bitcask:open("/tmp/db", [read_write]).

%% To force KV mode explicitly (default when no analyzer is set):
R = bitcask:open("/tmp/db", [read_write]).

%% To enable full-text search, add an analyzer:
R = bitcask:open("/tmp/db", [read_write, {analyzer, ngram}]).
```

No legacy fallback exists — `bitcask_legacy.erl` has been deleted.

## Basic Operations

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> bitcask:put(R, <<"k">>, <<"v">>).             ok
3> bitcask:get(R, <<"k">>).                       {ok,<<"v">>}
4> bitcask:list_keys(R).                          [<<"k">>]
5> bitcask:fold(R, fun(K,V,Acc) -> [{K,V}|Acc] end, []).
6> bitcask:delete(R, <<"k">>).                    ok
7> bitcask:close(R).                              ok
```

### Full-Text Search (Index Mode)

Open with an analyzer to enable BM25 search:

```erlang
%% Open with BM25 index — creates bitcask.meta with mode=kIndex
1> R = bitcask:open("/tmp/db", [read_write, {analyzer, ngram}]).

%% Put documents — accepts binary or #{text => binary(), meta => binary()}
2> bitcask:put(R, <<"doc1">>, <<"Beijing Chaoyang district">>).
3> bitcask:put(R, <<"doc2">>, <<"Shanghai Pudong area">>).
4> bitcask:put(R, <<"doc3">>, <<"Beijing Chaoyang is a district">>).

%% BM25 bag-of-words search
5> bitcask:search_text(R, <<"Beijing">>, 10).
{ok,[{<<"doc1">>,0.288},{<<"doc3">>,0.288}]}

%% BM25 phrase search (tokens must be adjacent)
6> bitcask:search_phrase(R, <<"Beijing Chaoyang">>, 10).
{ok,[{<<"doc1">>,0.287}]}

7> bitcask:close(R).
```

**Analyzer options:**

| Analyzer    | Description                                     |
|-------------|-------------------------------------------------|
| `ngram`     | Default; n-gram tokenization                     |
| `jieba`     | Chinese word segmentation (requires `{dict_path, Path}`) |
| `whitespace`| Simple space-separated tokenization             |

**Return format:** `[{Key :: binary(), Score :: float()}]`

**Mode constraint:** `search_text`/`search_phrase` require the Cask to be opened in index mode (bitcask.meta has `mode=kIndex`). KV mode returns `{error, no_index}`.

### Streaming Fold

Streaming iteration via a producer/consumer model:

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> [bitcask:put(R, K, <<"v">>) || K <- [<<"a">>,<<"b">>,<<"c">>]].

%% Open a stream
3> S = bitcask:stream(R).

%% Pull entries one at a time
4> bitcask:next(S).
{ok,<<"a">>,<<"v">>}
5> bitcask:next(S).
{ok,<<"b">>,<<"v">>}
6> bitcask:next(S).
{ok,<<"c">>,<<"v">>}
7> bitcask:next(S).
done

%% Stop the stream (also auto-cleaned on consumer crash)
8> bitcask:stop(S).

%% RAII wrapper — automatically stops stream on exit
9> bitcask:with_stream(R, fun(S) ->
    loop(S, []).
end).

loop(S, Acc) ->
    case bitcask:next(S) of
        done         -> Acc;
        {ok, K, V}  -> loop(S, [{K,V}|Acc]);
        {error, E}  -> {error, E}
    end.
```

Multiple streams can be open simultaneously on the same `Ref` — each holds an independent iterator.

## Crash Recovery

If a writer process crashes, the next `bitcask:open(D, [read_write])`
inspects the recorded PID in `bitcask.write.lock`. If that process is no
longer alive (`kill -0 PID` fails with `ESRCH`), the stale lock is unlinked
and the open succeeds. A live owner stays locked — the second open returns
`{error, write_locked}`.

```erlang
%% Process A:
1> R = bitcask:open("/tmp/db", [read_write]).
%% A crashes, write.lock left behind with A's PID.

%% Process B (or A restarted):
1> R = bitcask:open("/tmp/db", [read_write]).
#Ref<...>                       % succeeds — stale lock reclaimed
```

The same logic applies if the lock file is empty (writer crashed before
recording its PID).

## Merge: Compacting Fragmented Files

bitcask is append-only, so `put`/`delete` accumulate dead records. **Merge**
walks fragmented files, copies live records into a fresh file, and updates
the keydir.

### Concept

A file's fragmentation is `(1 - live_keys / total_keys) * 100`.

### Trigger Thresholds (any-of)

A merge runs only if at least one non-active file crosses **any** of these:

| Option                       | Default | Meaning |
|------------------------------|---------|---------|
| `frag_merge_trigger`         | `60`    | Percent fragmentation |
| `dead_bytes_merge_trigger`   | `512 MB`| Bytes of dead data |
| `expiry_secs` + `expiry_grace_time` | unset | All records older than `now - (expiry_secs + grace)` |

### Per-file Inclusion Thresholds (any-of)

Once the trigger fires, each file is checked against:

| Option                  | Default | Meaning |
|-------------------------|---------|---------|
| `frag_threshold`        | `40`    | Fragmentation percent |
| `dead_bytes_threshold`  | `128 MB`| Dead bytes |
| `small_file_threshold`  | `10 MB` | Total size below which file is included |
| (`expiry_secs`)         | unset   | Whole file expired |

### Configuring Thresholds

Three ways, in priority order:

```erlang
%% 1. open/2 options (single Cask)
bitcask:open(D, [read_write,
                 {max_file_size,        1024},
                 {frag_merge_trigger,   50},
                 {frag_threshold,       50},
                 {dead_bytes_threshold, 1024}]).

%% 2. application env (process-wide default)
application:set_env(bitcask, frag_merge_trigger, 50).
application:set_env(bitcask, frag_threshold,     50).

%% 3. C++ defaults (above table) when neither is set
```

The full pass-through list:
`max_file_size`, `expiry_secs`, `frag_merge_trigger`,
`dead_bytes_merge_trigger`, `frag_threshold`, `dead_bytes_threshold`,
`small_file_threshold`, `expiry_grace_time`, `max_merge_size`.

### Active Writer Is Excluded

`needs_merge/1` and `merge` **always skip the file currently being written**.
This matches legacy semantics — merging the active writer would race with
in-flight `put`s. Consequence: if everything fits in a single file (the
active writer), `needs_merge` returns `false` no matter how fragmented.

To force rollover for testing, lower `max_file_size`:

```erlang
bitcask:open(D, [read_write, {max_file_size, 1024}]).
```

### End-to-End Demo

```erlang
%% Step 1: open with small max_file_size to force rollover.
1> Dir = "/tmp/merge_demo".
2> R = bitcask:open(Dir, [read_write, {max_file_size, 1024}]).

%% Step 2: write the same key 100 times → 99 stale, 1 live.
3> [bitcask:put(R, <<"k">>, integer_to_binary(I)) || I <- lists:seq(1, 100)].

%% Step 3: inspect file count and fragmentation.
4> length(filelib:wildcard(filename:join(Dir, "*.bitcask.data"))).
%% e.g. 3 files

5> bitcask:status(R).
%% {1, [{"...1.bitcask.data", 99, ..., ...},  % 99% fragmented
%%      {"...2.bitcask.data", 99, ..., ...},
%%      {"...3.bitcask.data",  0, ..., ...}]} % active writer at 0%

%% Step 4: ask whether merge is needed.
6> bitcask:needs_merge(R).
%% {true, {[file_paths_to_merge], [expired_paths]}}

%% Step 5: trigger merge via the convenience wrapper
7> do_merge(R).
```

### Reading the `cask_merge` Result

```erlang
{ok, {Seen, Kept, Stale, Tombs}}
```

| Field   | Meaning |
|---------|---------|
| `Seen`  | Total records walked across all input files |
| `Kept`  | Records copied to the new merge file |
| `Stale` | Skipped: keydir points elsewhere (overwritten or deleted) |
| `Tombs` | Skipped: source record is a tombstone |

`Kept = 0, Stale > 0` is **normal** when the live versions all happen to
live in the active writer — merge correctly skips writing them again.

### Why `needs_merge` Sometimes Returns `false` After Heavy Writes

If you write `N` keys and overwrite each once (`put k v1; put k v2`), each
file ends up with roughly half stale records → ~50% fragmentation per
file. The default `frag_merge_trigger` is `60%`, so no trigger fires —
which is **legacy behaviour**, not a bug.

To force the trigger:
- write the same key many more times (high frag), **or**
- pass `{frag_merge_trigger, 50}` to `open`/app env.

### Convenience wrapper

```erlang
do_merge(R) ->
    case bitcask:needs_merge(R) of
        false                     -> nothing_to_merge;
        {true, {Files, _Expired}} -> bitcask_cpp_nifs:cask_merge(R, Files)
    end.
```

After a successful `cask_merge`, the input `.data` + `.hint` files are
unlinked and their `fstats` entries trimmed from the keydir, so disk
usage drops immediately and `bitcask:status/1` reflects the new state.

### Known Limitations

| Limitation | Workaround |
|------------|------------|
| `search_text`/`search_phrase` only available in index mode (bitcask.meta with `mode=kIndex`) | Open with `{analyzer, ...}` to enable |
| Collection class is separate from Cask | Unification planned (see TASK.md U0-U6) |
| No tombstone-v2 reverse marker on source files | Single-process workloads only; multi-process readers not supported |

## Expiry

```erlang
%% Records older than 60 seconds are invisible to get/list_keys/fold.
1> R = bitcask:open(Dir, [read_write, {expiry_secs, 60}]).
2> bitcask:put(R, <<"k">>, <<"v">>).
3> timer:sleep(61000).
4> bitcask:get(R, <<"k">>).                       not_found
```

`expiry_secs` also feeds the merge trigger via `expiry_grace_time` —
once a whole file is past `now - (expiry_secs + grace)`, it gets queued
for merge so storage can be reclaimed.

## Direct cask_* NIF (Bypass facade)

The `bitcask` facade is the supported user API. If you need the raw NIF for
microbenchmarks or testing:

```erlang
{ok, R} = bitcask_cpp_nifs:cask_open(Dir, [read_write]).
ok      = bitcask_cpp_nifs:cask_put(R, K, V).
{ok, V} = bitcask_cpp_nifs:cask_get(R, K).

%% Fold via three-step iterator.
{ok, IR}        = bitcask_cpp_nifs:cask_fold_start(R, -1, -1).
{ok, K, V}      = bitcask_cpp_nifs:cask_fold_next(IR).        % or `done`
ok              = bitcask_cpp_nifs:cask_fold_release(IR).

%% Search (index mode only)
{ok, [{K,S}]}   = bitcask_cpp_nifs:cask_search_text(R, <<"query">>, 10).
{ok, [{K,S}]}   = bitcask_cpp_nifs:cask_search_phrase(R, <<"query">>, 10).

ok = bitcask_cpp_nifs:cask_close(R).
```

### Available cask_* NIFs

| NIF | Description |
|-----|-------------|
| `cask_open/2` | Open a cask |
| `cask_close/1` | Close and release resources |
| `cask_get/2` | Read a key |
| `cask_put/3` | Write a key/value |
| `cask_delete/2` | Soft-delete a key |
| `cask_sync/1` | fsync active data file |
| `cask_close_write_file/1` | Release write lock, keep handle usable |
| `cask_search_text/3` | BM25 bag-of-words search (index mode only) |
| `cask_search_phrase/3` | BM25 phrase search (index mode only) |
| `cask_fold_start/3,4` | Begin iteration |
| `cask_fold_next/1` | Next entry (K, V) |
| `cask_fold_next_full/1` | Next entry (K, V, FileId, Offset, Sz, Tstamp, IsTomb) |
| `cask_fold_release/1` | Release iterator |
| `cask_is_empty/1` | O(1) empty estimate |
| `cask_is_frozen/1` | Keydir frozen state |
| `cask_status/1` | `{KeyCount, Files}` |
| `cask_needs_merge/1` | `{true, {Files, Expired}}` or `false` |
| `cask_merge/2` | Run merge on specified files |

## Common Errors

| Return | Cause | Fix |
|--------|-------|-----|
| `{error, write_locked}` | Live writer holds the lock | Close the prior cask, or pick another dir |
| `not_found`             | Key never existed / deleted / expired | Normal |
| `{error, bad_crc}`      | Disk corruption on read | Restore from backup; merge will skip these |
| `{error, key_too_large}` | Key > 65 535 bytes | Format limit; not configurable |
| `{error, value_too_large}` | Value > 4 GiB | Format limit |
| `{error, no_index}`     | Search called on KV-mode Cask | Reopen with `{analyzer, ...}` |