# Bitcask On-Disk Format

This is the byte-level spec the C++ implementation produces and consumes.
It is byte-for-byte compatible with the legacy C NIF (`c_src/bitcask_nifs.c`)
so a directory written by either implementation is readable by the other.
Ground truth lives in `cpp/include/bitcask/format.hpp` and the encoder/
decoder in `cpp/src/fileops/codec.cpp`.

All multi-byte integers are big-endian. All sizes are bytes.

## Directory layout

```
<dirname>/
├── <tstamp1>.bitcask.data        # append-only data file
├── <tstamp1>.bitcask.hint        # optional index file (one per data file)
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── bitcask.write.lock            # exclusive: held by the live writer
└── bitcask.merge.lock            # exclusive: held by the active merger
```

`<tstampN>` is a monotonically-increasing decimal `uint64`. Each tstamp is
both the file id and the sort key — directory scans pick the file order
ascending by tstamp.

## Data record

Every data file is a sequence of records, no padding between them, no
header on the file itself.

```
+---------+---------+---------+--------------+----------+----------+
|  CRC32  | tstamp  | key_sz  |  value_sz    |   key    |  value   |
| 4 bytes | 4 bytes | 2 bytes |  4 bytes     |  key_sz  | value_sz |
+---------+---------+---------+--------------+----------+----------+
\_________ 14-byte header _____________________/
\_________________ CRC32 covers everything past the CRC field _____/
```

Field semantics:

| Field      | Width | Meaning                                              |
|------------|-------|------------------------------------------------------|
| `crc`      |   4 B | CRC-32 (zlib-style) over `tstamp..value` bytes       |
| `tstamp`   |   4 B | Unix seconds at write time                           |
| `key_sz`   |   2 B | Bytes of `key` (must be ≤ 65535)                     |
| `value_sz` |   4 B | Bytes of `value`                                     |
| `key`      |   var | Raw bytes; allowed to contain NUL                    |
| `value`    |   var | Raw bytes; tombstones are ordinary records           |

Maximum sizes are defined by `format::kMaxKeySize` and `kMaxValueSize`.
A read whose `total_size` would exceed `kMaxValueSize + 14 + kMaxKeySize`
is rejected as `kTooLarge`.

## Tombstones

A delete is encoded as a regular data record whose **value** is a tombstone
marker. Three formats coexist:

| Version | Value bytes                                           | Size |
|---------|-------------------------------------------------------|------|
| v0      | `"bitcask_tombstone"`                                 | 17 B |
| v1      | `"bitcask_tombstone1"` + `FileId32` (BE)              | 22 B |
| v2      | `"bitcask_tombstone2"` + `FileId32` (BE)              | 22 B |

`FileId32` in v1/v2 is the file id of the record being shadowed —
it lets a future merger drop both the deleted record and its tombstone in
one pass once both files are eligible.

The C++ writer produces v0 by default. Set `CaskOptions::tombstone_version =
2` (Erlang opt: `{tombstone_version, 2}`) to write v2. The reader accepts
all three; any value whose first 17 bytes match `"bitcask_tombstone"` is
treated as a delete (`format::is_tombstone_value`).

## Hint file

Each data file *may* have a hint file alongside (`<tstamp>.bitcask.hint`).
Hints are an offline index: opening a directory rebuilds the keydir from
hints when present, falling back to a full data-file fold otherwise.

Hint records:

```
+---------+---------+----------+---------+----------+
| tstamp  | key_sz  | total_sz | offset  |   key    |
| 4 bytes | 2 bytes | 4 bytes  | 8 bytes |  key_sz  |
+---------+---------+----------+---------+----------+
```

A tombstone hint is encoded by setting the high bit of `tstamp` (legacy
convention). The C++ codec exposes this via `HintRecord::tombstone`.

The hint file is finalized with a CRC trailer:

```
+----------+--------------+--------+--------+
| CRC32    | total_count  |  ZER   |  EOF   |
| 4 bytes  | 4 bytes      | sentinel       |
+----------+--------------+----------------+
```

`validate_trailer()` returns true only when the CRC checks out and the
sentinel matches; otherwise the hint is treated as missing and the keydir
is rebuilt from data.

## Lock files

Both `bitcask.write.lock` and `bitcask.merge.lock` follow the same legacy
convention — flock-held files whose contents identify the current owner:

```
<pid> <active_data_path>\n
```

`pid` is the live process. `active_data_path` is the file id the writer is
currently appending to (used by mergers to skip the in-flight active file).
Empty contents indicate a writer that crashed before writing the line —
the next `Cask::open` treats the file as stale (PID 0, never matches a
living process) and reclaims it.

Stale-lock detection: on lock acquisition, if `kill(pid, 0) == ESRCH` the
lock is unlinked and re-acquired. This handles the "process crashed
without releasing flock" case.

## Recovery

`Cask::open` runs three recoveries before returning:

1. **Stale lock reclaim** — see above.
2. **Torn-write tail trim** — `DataFile::fold` returns the offset just past
   the last successfully-decoded record. If the file is longer than that
   AND the cask is the writer (`read_write && !merge_only`), the file is
   truncated back to that offset. This handles a writer that crashed
   mid-record, leaving unparsable trailing bytes.
3. **Hint validation** — if a hint exists but its trailer is invalid (CRC
   mismatch or missing sentinel), the hint is ignored and the keydir is
   rebuilt from data.

Read-only opens never modify the directory.
