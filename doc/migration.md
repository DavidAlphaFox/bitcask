# Migration Guide: legacy → cask_cpp

This is the practical guide for moving an existing bitcask deployment off
the legacy C NIF onto the C++ rewrite. Read `doc/cpp-arch.md` for the
implementation map and `doc/format.md` for the on-disk spec — neither
changes byte-level, so existing data is readable as-is.

## TL;DR

```erlang
%% Before (or with -DTEST):
R = bitcask:open(Dir, [read_write]).

%% After:
R = bitcask:open(Dir, [read_write, {nifs, cask_cpp}]).
```

Or set the default once:

```erlang
application:set_env(bitcask, default_nif_mode, cask_cpp).
```

The compiled-in default is `cask_cpp` in production builds and `legacy`
under `-DTEST`. The latter exists so the 80+ legacy white-box eunit
tests keep running unchanged; new tests opt into cask via
`{nifs, cask_cpp}` explicitly.

## What changes for the caller

| API                              | Behaviour under `cask_cpp`                              |
|----------------------------------|---------------------------------------------------------|
| `open/1,2`                       | Returns the cask resource handle as `Ref`               |
| `close/1`                        | Closes the cask, releases write/merge lock              |
| `get/2`, `put/3`, `delete/2`     | Round-trip through the C++ NIF                          |
| `sync/1`                         | `fsync(2)` on the active data file                       |
| `list_keys/1`                    | Walks `cask_fold_*` internally                          |
| `fold/3`, `fold_keys/3`          | Walks `cask_fold_*` internally; `fold_keys` callbacks see real `#bitcask_entry` fields |
| `merge/1,2,3`                    | Opens a `merge_only` cask, runs the merge, closes        |
| `needs_merge/1,2`                | Routes to `cask_needs_merge`                             |
| `status/1`                       | Returns `{KeyCount, Files}` (matches legacy 2-tuple)     |
| `is_empty_estimate/1`            | Routes to `cask_is_empty`                                |
| `is_frozen/1`                    | Surfaces the keydir's iter-frozen state (M5.2 task 5)    |

## What's not (yet) implemented in cask_cpp

These three legacy APIs **fall through to `bitcask_legacy:`** even when
`{nifs, cask_cpp}` is selected:

- `iterator/3, iterator_next/1, iterator_release/1`
- `fold/6, fold_keys/6` (the variants taking `MaxAge`, `MaxPut`,
  `SeeTombstones`)
- `close_write_file/1` (legacy test helper; cask manages active writer
  internally so it's a no-op)

Plus four utility helpers that delegate:

- `get_opt/2`, `is_tombstone/1`, `has_pending_delete_bit/1`,
  `get_filestate/2`

These exist mostly because `bitcask_fileops` and `bitcask_merge_delete`
are still legacy modules. M6 will collapse them.

## Options that flow through to the cask

The Erlang option list passes through `?CASK_PASSTHROUGH_OPTS` in
`src/bitcask.erl`. Recognised opts:

```erlang
{expiry_secs, N}          % records older than N seconds are filtered
{max_file_size, B}        % active file rolls over at B bytes (default 2 GB)
{sync_strategy, none}     % no auto-sync (default)
{sync_strategy, o_sync}   % O_SYNC every write
{sync_strategy, {seconds, N}}  % accepted; caller-driven (matches legacy)
{tombstone_version, 2}    % write v2 tombstones (default v0)
%% merge policy ----------------------------------------------------
{frag_merge_trigger, Pct}        % default 60
{dead_bytes_merge_trigger, B}    % default 512 MiB
{frag_threshold, Pct}            % default 40
{dead_bytes_threshold, B}        % default 128 MiB
{small_file_threshold, B}        % default 10 MiB
{expiry_grace_time, S}
{max_merge_size, B}
```

Anything else is silently dropped (legacy did the same).

## Operational changes

### Two-lock model

`bitcask_merge_worker` (cask path) acquires `bitcask.merge.lock`, **not**
`bitcask.write.lock`. A live writer keeps running. The merger reads the
writer's lock file to learn which file id is active and excludes it from
merge candidates. Two mergers on the same dir still serialize on
`merge.lock` (good).

### Stale lock reclamation

If a previous writer process died without releasing `bitcask.write.lock`,
opening the dir again now succeeds: `Cask::open` reads the lock contents,
checks `kill(pid, 0)`, and unlinks the file if `ESRCH`. Empty/malformed
lock files are also treated as stale.

### Torn-write tail recovery

Opening a dir as a writer after a mid-record crash will trim the tail of
the last data file back to the last successfully-decoded record. Read-only
opens leave the file alone. No more "skip-CRC-errors-forever-and-eat-disk"
behaviour.

### Merge actually deletes old files

Cask's merge unlinks both the `.data` and `.hint` of files it merged away
and calls `keydir_->trim_fstats()` so the file-stats slate is clean. The
legacy implementation deferred this to a separate `bitcask_merge_delete`
gen_server; cask does it inline.

## Cross-mode compatibility

A directory written by `legacy` can be reopened under `cask_cpp` and vice
versa. The on-disk format is byte-identical — the only thing that changes
is which code path interprets the bytes. Verified via the
`cross_mode_*` tests in `test/bitcask_cpp_cask_gap_tests.erl`.

## Rolling out

1. Build with cask_cpp as default (`default_nif_mode_compiled() =
   cask_cpp` is the production build). Run your existing eunit suite —
   it still uses `legacy` because of `-DTEST`.
2. Add a per-feature opt-in in your application code: pass
   `{nifs, cask_cpp}` for the bitcasks you want to migrate first.
3. Watch `bitcask:status/1`, `bitcask:needs_merge/1`, and the
   `bitcask.write.lock` content evolve — the lock now contains
   `<pid> <active_data_path>\n` instead of just `<pid>`.
4. After a soak period, flip the runtime default:
   `application:set_env(bitcask, default_nif_mode, cask_cpp)`.
5. Once you're confident, drop the option entirely and rely on the
   compiled-in default.

## Rollback

Just pass `{nifs, legacy}` (or set the app env to `legacy`) and reopen.
The data files are unchanged, so the legacy code reads them without
issue. Hint files written by cask validate under legacy too.

## When NOT to migrate yet

- You depend on `iterator/3` or the `fold/6` variants — they fall through
  to legacy today but you'd be running mixed paths.
- You need `key_transform` — wontfix in cask_cpp; rare in production.
- You depend on `tombstone_version=1` — cask reads v1 but doesn't write
  it (only v0 default and v2 opt-in).
- You rely on `bitcask_merge_delete`'s deferred unlink behaviour for some
  external coordination.

For all other cases, `cask_cpp` is the recommended default.
