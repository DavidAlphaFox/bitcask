# Feature Status and API Reference

This document describes the current bitcask feature set, the complete API
surface, and operational characteristics. All operations go through the C++
NIF — there is no legacy mode.

## Overview

The C++23 NIF (`cask_cpp`) is the only available mode. `bitcask_legacy.erl`
has been deleted. All API calls route through `bitcask_cpp_nifs` →
`priv/bitcask_cpp.so`.

- **KV mode** (default): `open(Dir, [read_write])` — plain key/value storage
- **Index mode**: `open(Dir, [read_write, {analyzer, ...}])` — adds BM25
  full-text search; creates `bitcask.meta` with `mode=kIndex`

Both modes share the same on-disk format (typed records `kDoc`/`kTombstone`).

## API Reference

| Erlang API                    | C++ NIF            | Notes                                              |
|-------------------------------|--------------------|----------------------------------------------------|
| `bitcask:open/1,2`            | `cask_open/2`      | Returns resource ref                               |
| `bitcask:close/1`             | `cask_close/1`     | Releases write/merge lock                         |
| `bitcask:get/2`               | `cask_get/2`       |                                                    |
| `bitcask:put/3`               | `cask_put/3`       | `put(_, _, tombstone)`等价于`delete`               |
| `bitcask:delete/2`            | `cask_delete/2`    | Soft-delete (tombstone)                            |
| `bitcask:sync/1`              | `cask_sync/1`      | fsync active data file                             |
| `bitcask:search_text/2,3`     | `cask_search_text/3`| BM25 bag-of-words; index mode only               |
| `bitcask:search_phrase/2,3`   | `cask_search_phrase/3`| BM25 phrase; index mode only                     |
| `bitcask:fold/3,6`            | `cask_fold_start/3,4` + iterators | 3-step iterator (start/next/release)     |
| `bitcask:fold_keys/3,6`       | `cask_fold_start/3,4` + iterators | Returns `#bitcask_entry` records          |
| `bitcask:list_keys/1`         | via `cask_fold_*`   | Collects keys into a list                         |
| `bitcask:stream/1`            | via `cask_fold_*`  | Producer/consumer streaming iterator              |
| `bitcask:next/1`              | via `cask_fold_*`  | Pull next entry                                   |
| `bitcask:stop/1`              | via `cask_fold_*`  | Stop and release stream                           |
| `bitcask:with_stream/2`       | via `cask_fold_*`  | RAII wrapper                                      |
| `bitcask:merge/1,2,3`         | `cask_merge/2`     | Opens `merge_only` cask, merges, closes           |
| `bitcask:needs_merge/1,2`     | `cask_needs_merge/1`| Returns `{true, {Files, Expired}}` or `false`    |
| `bitcask:status/1`            | `cask_status/1`    | Returns `{KeyCount, Files}`                       |
| `bitcask:is_empty_estimate/1` | `cask_is_empty/1`  | O(1) estimate                                      |
| `bitcask:is_frozen/1`         | `cask_is_frozen/1` | Keydir frozen state                               |
| `bitcask:close_write_file/1`  | `cask_close_write_file/1` | Release write lock, keep handle usable        |

## Options

Options flow through `?CASK_PASSTHROUGH_OPTS` in `src/bitcask.erl`. Unrecognised
options are silently dropped.

### General

| Option                      | Default | Description                              |
|-----------------------------|---------|------------------------------------------|
| `read_write`                | `false` | Open with write permission               |
| `{expiry_secs, N}`          | `0`     | Records older than N seconds are filtered on get/fold; also triggers merge |
| `{max_file_size, B}`        | `2 GiB` | Active file rolls over at B bytes        |
| `{sync_strategy, none}`     | (default) | No auto-sync                           |
| `{sync_strategy, o_sync}`   | —       | O_SYNC every write                       |
| `{sync_strategy, {seconds, N}}` | —    | Caller-driven sync                       |
| `{tombstone_version, V}`    | `0`     | `0` = `bitcask_tombstone` (17 B); `2` = `bitcask_tombstone2` (22 B, supports concurrent control) |

### Merge Policy

| Option                      | Default | Description                              |
|-----------------------------|---------|------------------------------------------|
| `frag_merge_trigger`        | `60`    | Percent fragmentation to trigger merge   |
| `dead_bytes_merge_trigger`  | `512 MB`| Dead bytes to trigger merge              |
| `frag_threshold`            | `40`    | Per-file fragmentation threshold          |
| `dead_bytes_threshold`      | `128 MB`| Per-file dead bytes threshold            |
| `small_file_threshold`      | `10 MB` | Total size below which file is included   |
| `expiry_grace_time`         | —       | Grace period after expiry_secs            |
| `max_merge_size`           | —       | Maximum total size to merge in one pass  |

### Index Mode (Full-Text Search)

| Option                      | Default | Description                              |
|-----------------------------|---------|------------------------------------------|
| `{analyzer, ngram\|jieba\|whitespace}` | `ngram` | Analyzer type; must be set to enable search |
| `{dict_path, binary()}`     | —       | Path to jieba dictionary (required for `jieba`) |
| `{enable_stop_words, boolean()}` | `false` | Enable stop word filtering               |

## Operational Notes

### Two-Lock Model

`bitcask:merge/1,2,3` acquires `bitcask.merge.lock` — **not**
`bitcask.write.lock`. A live writer keeps running concurrently. The merger
reads the writer's lock file to learn which file id is active and excludes it
from merge candidates. Two mergers on the same dir still serialize on
`merge.lock`.

### Stale Lock Reclamation

If a previous writer process died without releasing `bitcask.write.lock`,
opening the dir again succeeds: `Cask::open` reads the lock contents, checks
`kill(pid, 0)`, and unlinks the file if `ESRCH`. Empty/malformed lock files
are also treated as stale.

### Torn-Write Tail Recovery

Opening a dir as a writer after a mid-record crash will trim the tail of the
last data file back to the last successfully-decoded record. Read-only opens
leave the file alone. No more "skip-CRC-errors-forever-and-eat-disk" behaviour.

### Merge Deletes Old Files Inline

Cask's merge unlinks both the `.data` and `.hint` of merged-away files and
calls `keydir_->trim_fstats()` so the file-stats slate is clean. There is no
separate deferred delete process.

## What's Not Yet Implemented

See `TASK.md` for the full roadmap (U0–U6).

- **Unified Cask + Collection architecture**: planned; currently `Cask` and
  `Collection` are separate classes. U0–U6 will merge them.
- **HNSW vector search**: designed but not yet implemented.
- **`put_doc` / `upgrade`**: available in C++ (`Cask::put_doc`, `Cask::upgrade`);
  NIF exposure is partial.

## Rolling Out

1. Build with `rebar3 compile` — the C++ NIF is the only option.
2. Run your existing tests — the on-disk format is unchanged; existing data
   is readable as-is.
3. Watch `bitcask:status/1`, `bitcask:needs_merge/1`, and the
   `bitcask.write.lock` content.
4. To enable full-text search, open with `{analyzer, ngram}` (or `jieba` for
   Chinese with `{dict_path, Path}`).

## Common Errors

| Return                       | Cause                                   | Fix                                     |
|------------------------------|-----------------------------------------|----------------------------------------|
| `{error, write_locked}`      | Live writer holds the lock              | Close the prior cask, or pick another dir |
| `not_found`                  | Key never existed / deleted / expired   | Normal                                 |
| `{error, bad_crc}`           | Disk corruption on read                 | Restore from backup; merge skips these |
| `{error, key_too_large}`     | Key > 65 535 bytes                      | Format limit; not configurable          |
| `{error, value_too_large}`    | Value > 4 GiB                           | Format limit                            |
| `{error, no_index}`          | Search called on KV-mode Cask           | Reopen with `{analyzer, ...}`          |
| `{error, merge_locked}`      | Another merger already running          | Wait for it to finish                   |

## Expiry

Records older than `expiry_secs` seconds are invisible to `get`/`list_keys`/`fold`.
They are also candidates for expiry-triggered merge once past
`now - (expiry_secs + expiry_grace_time)`.

```erlang
1> R = bitcask:open(Dir, [read_write, {expiry_secs, 60}]).
2> bitcask:put(R, <<"k">>, <<"v">>).
3> timer:sleep(61000).
4> bitcask:get(R, <<"k">>).           not_found
```

## Crash Recovery

If a writer process crashes leaving `bitcask.write.lock`, the next
`open(Dir, [read_write])` checks whether the recorded PID is still alive.
If not (or the lock file is empty/malformed), the stale lock is unlinked and
the open succeeds.

```erlang
%% Process A writes, then crashes:
1> R = bitcask:open("/tmp/db", [read_write]).

%% Process B reopens — stale lock is reclaimed:
2> R2 = bitcask:open("/tmp/db", [read_write]).
#Ref<...>   % succeeds
```