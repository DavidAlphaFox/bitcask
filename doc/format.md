# Bitcask On-Disk Format

This is the byte-level spec the C++ implementation produces and consumes.
It is byte-for-byte compatible with the legacy C NIF / Erlang `bitcask_fileops`
so a directory written by either implementation is readable by the other.
Ground truth lives in:

- Constants:  `cpp/include/bitcask/format.hpp`
- Encoder/decoder:  `cpp/src/fileops/codec.cpp`
- File abstractions:  `cpp/include/bitcask/data_file.hpp` / `hint_file.hpp`
- Byte-level fixtures:  `cpp/tests/codec_test.cpp`

All multi-byte integers are big-endian. All sizes are bytes.

---

## 1. Directory layout

A bitcask instance is a single flat directory:

```
<dir>/
├── <tstamp1>.bitcask.data        # append-only data file
├── <tstamp1>.bitcask.hint        # optional sidecar index (one per data file)
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── bitcask.write.lock            # held by the live writer (exclusive)
└── bitcask.merge.lock            # held by the active merger (exclusive)
```

`<tstampN>` is the file id, a monotonically-increasing decimal integer
(internally `uint32`, parsed as `uint64` for safety). `KeyDirRegistry`
persists `biggest_file_id + 1` across open/close so a future opener never
reuses an id — this is what keeps the keydir from confusing an old file
with a new one. Directory scans walk files in ascending tstamp order.

---

## 2. Data record

A data file is a tight sequence of records — no file header, no padding
between records.

```
offset  field      size  notes
─────────────────────────────────────────────
0       CRC32      4     covers Tstamp..Value (zlib polynomial,
                         identical to erlang:crc32)
4       Tstamp     4     unix seconds at write time
8       KeySz      2     key bytes (≤ 65535)
10      ValueSz    4     value bytes (≤ ~4 GiB)
14      Key        KeySz
14+KeySz Value     ValueSz
```

Total record size = `14 + KeySz + ValueSz`.  Header is a fixed 14 bytes.

| Field      | Width | Meaning                                            |
|------------|-------|----------------------------------------------------|
| `crc`      |   4 B | CRC-32 (zlib) over `tstamp..value`                 |
| `tstamp`   |   4 B | Unix seconds at write time                         |
| `key_sz`   |   2 B | Bytes of `key`; max 65535                          |
| `value_sz` |   4 B | Bytes of `value`; max `kMaxValueSize`              |
| `key`      |   var | Raw bytes; allowed to contain NUL                  |
| `value`    |   var | Raw bytes; tombstones are ordinary records (§3)    |

Notes:

- **CRC is at the front** for streaming verification but only covers what
  comes after it.
- **Big-endian** matches Erlang's default `<<X:N>>` bit syntax — required
  for byte-compatibility with the legacy NIF.
- A read whose `total_size` would exceed
  `kMaxValueSize + 14 + kMaxKeySize` is rejected as `kTooLarge`.

---

## 3. Tombstones (encoded as record VALUE)

A delete is a regular data record whose **value** is a tombstone marker.
Three formats coexist:

| Version | Value bytes                                        | Size | Status            |
|---------|----------------------------------------------------|------|-------------------|
| v0      | `"bitcask_tombstone"`                              | 17 B | legacy default    |
| v1      | `"bitcask_tombstone1"` + `FileId32` (BE)           | 22 B | recognized only   |
| v2      | `"bitcask_tombstone2"` + `FileId32` (BE)           | 22 B | current cask default |

Recognition is prefix-only: any value whose first 17 bytes match
`"bitcask_tombstone"` is treated as a delete (see
`format::is_tombstone_value`).

The `FileId32` in v1/v2 is the **shadow file id** — the id of the data
file that holds the record being deleted. The merger uses it to decide
when both the original record and its tombstone can be reclaimed
together: only after the shadowed file is itself eligible for merging.
This avoids races where a concurrent put writes a fresh value for the
same key between the original and the tombstone.

The cask writer emits v0 by default. Set `CaskOptions::tombstone_version
= 2` (Erlang opt: `{tombstone_version, 2}`) to write v2. The reader
accepts all three.

---

## 4. Hint record

Each data file *may* have a sidecar hint file (`<tstamp>.bitcask.hint`).
Hints are an offline index used to rebuild the keydir at open time
without reading every value byte from the data file.

```
offset  field            size  notes
─────────────────────────────────────────────
0       Tstamp           4     same value as the data record's tstamp
4       KeySz            2
6       TotalSz          4     full size of the data record (incl. 14 B header)
10      Tomb|Offset      8     bit 63 = tombstone flag
                               bits 62..0 = data-file offset
18      Key              KeySz
```

Total record size = `18 + KeySz`.  Header is a fixed 18 bytes.

### Packed offset field (bytes 10..17, big-endian uint64)

```
bit 63       bits 62..0
[Tomb:1]    [Offset:63]
```

- `Tomb = 1` marks a hint for a delete (the corresponding data record
  has a tombstone value).
- `Offset` is capped at `kMaxOffsetV2 = 0x7FFF_FFFF_FFFF_FFFF` (~8 EiB,
  far above any practical data file size).

The tombstone flag lives **inside the offset field's high bit**, *not*
in the tstamp. This matches legacy `bitcask_fileops:hintfile_entry/5`
exactly:

```erlang
%% legacy 5-arg packing
<<Tstamp:32, KeySz:16, TotalSz:32, Tomb:1, Offset:63>>
```

### EOF sentinel (the trailer)

A hint file is terminated by one final record whose **layout is identical
to a normal hint record** but whose field values are repurposed:

```
field      value
────────────────────────────────────────
Tstamp     0
KeySz      0
TotalSz    running CRC32 of the whole file (trailer CRC)
Tomb       0
Offset     kMaxOffsetV2  (= 2^63 - 1)
(no key payload, since KeySz = 0)
```

The sentinel is exactly 18 bytes. Readers recognize it via
`(KeySz == 0 && Offset == kMaxOffsetV2)` — see `codec::is_hint_eof`.

Note that the **CRC is stored in the `TotalSz` field** of the sentinel
record, not in a separate trailer structure. This is also a faithful port
of the legacy encoder:

```erlang
%% legacy close_hintfile/1
hintfile_entry(<<>>, 0, 0, ?MAXOFFSET_V2, HintCRC).
%%               ↑   ↑  ↑       ↑          ↑
%%              Key  T  Tomb   Offset     TotalSz← borrowed for the CRC
```

`HintFile::validate_trailer()` reads the sentinel's `TotalSz`, then
streams every preceding byte to recompute the CRC. Mismatch → the hint
is treated as missing and the keydir is rebuilt from the data file.

---

## 5. Lock files

`bitcask.write.lock` and `bitcask.merge.lock` are advisory file locks.
They are **not** POSIX `flock` and **not** fcntl record locks — bitcask
relies entirely on `O_CREAT | O_EXCL` atomicity at acquire time and
`unlink` at release.

| File                    | Holder | Purpose                                                |
|-------------------------|--------|--------------------------------------------------------|
| `bitcask.write.lock`    | writer | At most one writer per directory                       |
| `bitcask.merge.lock`    | merger | At most one merger; **does not block the writer**      |

The two locks are deliberately split so a periodic merger can run
alongside the live writer — the merger holds `merge.lock`, the writer
holds `write.lock`, and they never contend.

### Lock-file contents

```
<pid> <active_data_file_path>\n
```

…or just `<pid>\n` if the lock was just acquired and the active file
hasn't been created yet.

Mergers (opened with `merge_only = true`) read `bitcask.write.lock` to
discover the live writer's current active file id. They then exclude
that id (and any newer id, defensively) from `needs_merge` candidates —
you must never merge a file that someone is still writing to.

### Stale-lock reclaim

On `acquire`, if `O_CREAT|O_EXCL` returns `EEXIST` we open the lock
file, parse the leading PID, and probe `kill(pid, 0)`:

- `0`        → process is alive, lock is held legitimately → return `kWriteLocked`.
- `ESRCH`    → process is gone, lock is stale → `unlink` and retry.
- `EPERM`    → process exists but we can't signal it → conservatively
               treat as alive.

This handles the common "writer crashed without releasing its lock" case
(see `cpp/src/cask/cask.cpp::try_remove_stale_lock` and `process_alive`).

There is a tiny race window: between reading the PID and unlinking,
another process could write a fresh lock that we then incorrectly remove.
This race exists in legacy too; the practical exposure is limited to
post-crash recovery paths.

`O_EXCL` is unreliable on NFS, but bitcask isn't supposed to run on
network filesystems anyway.

---

## 6. Read / write summary

**put(K, V)**:
1. Encode a data record and `pwrite` it to the active data file.
2. Encode a hint record and append it to the active hint file.
3. Update the keydir: `K → (active_file_id, offset, total_size, tstamp)`.

**get(K)**:
1. Look up `(file_id, offset, total_size)` in the keydir.
2. `pread(offset, total_size)` from the corresponding data file.
3. Verify CRC; tombstone values surface as `not_found`.

**delete(K)**:
1. Encode a tombstone data record + a tombstone hint record.
2. Mark the keydir entry as a tombstone.

**open** (rebuild the keydir):
1. `scan_dir` lists `<tstamp>.bitcask.data` files in ascending tstamp order.
2. For each file:
   - Prefer `fold(hint_file)` after `validate_trailer()` — only reads
     keys + metadata, no values.
   - On hint missing or trailer-CRC mismatch, fall back to
     `fold(data_file)` — full scan.
3. Later writes naturally overwrite earlier ones because we walk in
   tstamp order.

**merge**:
1. Acquire `bitcask.merge.lock` (does not block the writer).
2. Read `bitcask.write.lock` to learn the live writer's active file id;
   exclude it (and anything newer) from candidates.
3. `needs_merge` filters by frag / dead-bytes / expiry thresholds.
4. `run_merge` walks every candidate; only records whose keydir entry
   still points at `(file_id, offset)` are copied to the output.
5. CAS-update the keydir to point at the new locations, then unlink the
   merged-away files.

---

## 7. Recovery on open

`Cask::open` runs three recoveries before returning:

1. **Stale-lock reclaim** — see §5.
2. **Torn-write tail trim** — `DataFile::fold` reports the offset just
   past the last successfully-decoded record via `out_last_valid_end`.
   If the file is longer than that AND this cask is the writer
   (`read_write && !merge_only`), the file is truncated back to that
   offset. This handles a writer that crashed mid-record, leaving
   unparsable trailing bytes. `merge_only` opens never truncate — they
   don't own `write.lock`, and a still-running writer might be appending
   beyond what we just observed.
3. **Hint validation** — if a hint exists but its trailer CRC is bad
   (or the sentinel is missing), the hint is ignored and the keydir is
   rebuilt from the data file.

Read-only opens never modify the directory.

---

## 8. Hard constraints (don't change these)

The following are wire-format guarantees with byte-level fixtures in
`cpp/tests/codec_test.cpp`. Changing any of them is a binary-compatibility
break:

- **Big-endian** encoding throughout (no platform-native shortcuts).
- Header sizes: data = **14 B**, hint = **18 B**.
- CRC polynomial = **zlib / IEEE 802.3** (so `erlang:crc32/1` matches).
- Tombstone prefix = **`"bitcask_tombstone"`** (17 B), recognized in
  data record values.
- Tombstone flag in hints lives in the **high bit of the packed
  offset field** (bytes 10..17, bit 63), capping `Offset` at 63 bits.

`cpp/include/bitcask/format.hpp` is the single source of truth for these
constants. The legacy `include/bitcask.hrl` definitions were removed in
M6 — there is no parallel definition to drift against.
