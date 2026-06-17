# Big-endian → little-endian directory migration (`migrate_le`)

中文：[`migrate-le.md`](migrate-le.md)

A tool that **offline-migrates an old big-endian bitcask directory** into the
new **little-endian** on-disk format.

## 1. Background: why migrate

bitcask went through a byte-order **flag-day**: all multi-byte integers on disk
switched from big-endian to little-endian (zero-conversion on LE-only hosts +
mmap zero-copy friendly; see the byte-order notes in
[`format-zh.md`](format-zh.md)). After the switch:

- `bitcask.meta`'s version went from `1` (big-endian era) to `2` (little-endian).
- Opening an old big-endian directory with new code **fails loudly** (it never
  silently reads big-endian bytes as little-endian and corrupts):

  ```
  incompatible legacy big-endian format (meta v1);
  little-endian flag-day requires rebuild — re-ingest data
  ```

To reuse an old directory, pick one: **① rebuild from the source of truth
(re-ingest)**, or **② migrate offline with this tool** (when you have no source
data / want to keep the existing store).

## 2. Build

`migrate_le` is built as part of the CMake build:

```bash
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j --target migrate_le
# output: _build/cmake/cpp/migrate_le
```

## 3. Usage

```bash
migrate_le <src_dir> <dst_dir>
```

- **Non-destructive**: `src_dir` is read-only, only `dst_dir` is written
  (created if absent).
- After migration, open `dst_dir` with the new code; delete the old `src_dir`
  only once verified.

Example:

```bash
$ _build/cmake/cpp/migrate_le ~/db/wiki ~/db/wiki.le
migrated /home/me/db/wiki -> /home/me/db/wiki.le
  data files     : 2
  records        : 12000 (tombstones 134)
  skipped badcrc : 0
  meta migrated  : yes
  field.schema   : yes
```

`skipped badcrc > 0` also prints a WARNING — it means corrupt records in the
**source** were skipped (a pre-existing source problem, not introduced by
migration).

## 4. What is migrated / skipped

| File | Handling |
|---|---|
| `<id>.bitcask.data` | each record's big-endian header decoded → re-encoded with the little-endian codec (CRC recomputed) |
| `<id>.bitcask.hint` | **regenerated** from the migrated data (trailer CRC consistent) |
| `bitcask.meta` | version `1→2`; `VecDim` u16 big→little; other fields copied |
| `field.schema` | each `NameLen` u16 big→little |
| tombstone v2 shadow file_id | 4-byte big-endian value re-ordered to little-endian |
| `kv.keydir.ckpt` / `search.*` (ckpt/seg/wal) / locks | **not migrated** — rebuildable; the new store reconstructs them on first open |

> The rebuildable checkpoint / index files are **intentionally not migrated**:
> they are derived caches, reconstructed by folding the migrated data files on
> the new store's first open (see
> [`recovery-unified-checkpoint-design-zh.md`](recovery-unified-checkpoint-design-zh.md)).

## 5. Verifying the result

```bash
# Open dst with the new code: a successful open + reads means success
# (meta is now v2). e.g. via rebar3 shell:
#   {ok, R} = bitcask:open("/home/me/db/wiki.le", [read_write]),
#   bitcask:get(R, <<"some-key">>).
```

`migrate_le` is covered by a round-trip test (`MigrateBEtoLE.RoundTrip`:
build big-endian fixtures → migrate → verify each record / hint / meta / shadow
via the little-endian read path).

## 6. Caveats

- **Little-endian hosts only** (x86-64 / ARM64), same as the engine itself.
- `migrate_le` is the **only** place in the engine that still reads big-endian;
  it carries its own big-endian decoder and reuses the little-endian
  `DataFile`/`HintFile` for writing, so output is byte-structurally identical to
  freshly written data.
- Migrating a directory that is already v2 (little-endian) **fails cleanly**
  (`src meta already v2`); it will not double-migrate.
- Implementation:
  [`cpp/include/bitcask/migrate.hpp`](../cpp/include/bitcask/migrate.hpp)
  (`migrate_be_to_le`) + `cpp/src/fileops/migrate.cpp` + CLI
  `cpp/tools/migrate_le.cpp`.
