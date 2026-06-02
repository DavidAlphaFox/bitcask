# Bitcask On-Disk Format

This is the byte-level spec the C++ implementation produces and consumes.
Ground truth lives in:

- Constants:  `cpp/include/bitcask/format.hpp`
- Encoder/decoder:  `cpp/src/fileops/codec.cpp`
- File abstractions:  `cpp/include/bitcask/data_file.hpp` / `hint_file.hpp`
- Meta file:  `cpp/include/bitcask/meta_file.hpp`
- Byte-level fixtures:  `cpp/tests/codec_test.cpp`

All multi-byte integers are big-endian (except f32 vector arrays which are
native little-endian).  All sizes are bytes.

---

## 1. Directory layout

A bitcask instance is a single flat directory:

```
<dir>/
├── bitcask.meta              # binary metadata (mode marker)
├── <tstamp1>.bitcask.data    # append-only data file
├── <tstamp1>.bitcask.hint    # optional sidecar index (one per data file)
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── bitcask.write.lock       # held by the live writer (exclusive)
└── bitcask.merge.lock        # held by the active merger (exclusive)
```

`<tstampN>` is the file id, a monotonically-increasing decimal integer
(internally `uint32`, parsed as `uint64` for safety).  `KeyDirRegistry`
persists `biggest_file_id + 1` across open/close so a future opener never
reuses an id — this is what keeps the keydir from confusing an old file
with a new one.  Directory scans walk files in ascending tstamp order.

### bitcask.meta (18 bytes)

```
offset  field     size  notes
────────────────────────────────────────────
0       Magic     4     "BCME" (0x42434D45)
4       Version   1     1
5       Mode      1     0 = KV mode, 1 = Index mode (BM25 search)
6       Reserved  12    zeros; for future use
```

Source: `cpp/include/bitcask/meta_file.hpp`.

---

## 2. Data record

A data file is a tight sequence of records — no file header, no padding
between records.

```
offset  field      size  notes
────────────────────────────────────────────
0       CRC32      4     covers Type..Value (zlib polynomial,
                         identical to erlang:crc32)
4       Type       1     RecordType: 0 = kDoc, 1 = kTombstone
5       Tstamp     4     unix seconds at write time
9       Ord        8     monotonically increasing per-write sequence number (big-endian)
17      KeySz      2     key bytes (≤ 65535)
19      ValueSz    4     value bytes (≤ ~4 GiB)
23      Key        KeySz
23+KeySz Value     ValueSz
```

Total record size = `23 + KeySz + ValueSz`.  Header is a fixed 23 bytes.

| Field      | Width | Meaning                                              |
|------------|-------|------------------------------------------------------|
| `crc`      |   4 B | CRC-32 (zlib) over `type..value`                     |
| `type`     |   1 B | RecordType: `kDoc = 0`, `kTombstone = 1`             |
| `tstamp`   |   4 B | Unix seconds at write time                           |
| `ord`      |   8 B | Monotonically increasing write sequence number; never reused |
| `key_sz`   |   2 B | Bytes of `key`; max 65535                             |
| `value_sz` |   4 B | Bytes of `value`; max `kMaxValueSize`               |
| `key`      |  var  | Raw bytes; allowed to contain NUL                   |
| `value`    |  var  | For kDoc: packed DocValue (§5); for kTombstone: usually empty |

### CRC coverage

CRC covers `Type..Value` (everything after the 4-byte CRC field).
This is different from some legacy formats that started coverage at
`Tstamp`.  The CRC field itself is not included in the checksum.

### RecordType enum

```cpp
enum class RecordType : std::uint8_t {
    kDoc       = 0,  // value is a packed DocValue (§5)
    kTombstone = 1,  // deletion marker; value usually empty
};
```

Tombstones are **not** detected by value magic prefixes — they are a
first-class record type.  The `tombstone_version` option in `CaskOptions`
is now moot for new writes.

---

## 3. Tombstones

A delete is a record with `type = kTombstone` (Type field = 1).  The value
is typically empty.  The Ord field gives the unique write sequence number
of this deletion; the key + Ord together identify which write this
tombstone supersedes.

The old mechanism — detecting tombstones by scanning for
`"bitcask_tombstone"` prefix in the value — is **no longer the primary
format**.  Reading code should accept both the new typed format and the
legacy value-magic format for backward compatibility with old files.

---

## 4. Hint record

Each data file *may* have a sidecar hint file (`<tstamp>.bitcask.hint`).
Hints are an offline index used to rebuild the keydir at open time
without reading every value byte from the data file.

```
offset  field            size  notes
────────────────────────────────────────────
0       Tstamp           4     same value as the data record's tstamp
4       KeySz            2
6       TotalSz          4     full size of the data record (incl. 23 B header)
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
  has `type = kTombstone`).
- `Offset` is capped at `kMaxOffsetV2 = 0x7FFF_FFFF_FFFF_FFFF` (~8 EiB,
  far above any practical data file size).

The tombstone flag lives **inside the offset field's high bit**, *not*
in the tstamp.  This matches legacy `bitcask_fileops:hintfile_entry/5`
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
───────────────────────────────────────
Tstamp     0
KeySz      0
TotalSz    running CRC32 of the whole file (trailer CRC)
Tomb       0
Offset     kMaxOffsetV2  (= 2^63 - 1)
(no key payload, since KeySz = 0)
```

The sentinel is exactly 18 bytes.  Readers recognize it via
`(KeySz == 0 && Offset == kMaxOffsetV2)` — see `codec::is_hint_eof`.

Note that the **CRC is stored in the `TotalSz` field** of the sentinel
record, not in a separate trailer structure.  This is also a faithful
port of the legacy encoder:

```erlang
%% legacy close_hintfile/1
hintfile_entry(<<>>, 0, 0, ?MAXOFFSET_V2, HintCRC).
%%               ↑   ↑  ↑       ↑          ↑
%%              Key  T  Tomb   Offset     TotalSz← borrowed for the CRC
```

`HintFile::validate_trailer()` reads the sentinel's `TotalSz`, then
streams every preceding byte to recompute the CRC.  Mismatch → the hint
is treated as missing and the keydir is rebuilt from the data file.

---

## 5. DocValue format (kDoc value packing)

Records with `type = kDoc` store their value in DocValue format — a
packed binary structure containing optional vector, text, meta, and
fields sections.

> **Current version `Ver = 3` (S11)**: all lengths/counts are **VByte
> varints**; the fields section stores **field ids** (not inlined field
> names). No backward compatibility — `decode_doc_value` accepts `Ver == 3`
> only. Below, `varint` means VByte (see "VByte varints").

```
offset  field         size    notes
────────────────────────────────────────────
0       Ver           1       layout version, currently 3
1       Flags         1       bitmask (see below)
2       Vector section (optional, Flags&0x01)
         Dim          varint  number of f32 elements
         f32 array    Dim×4   little-endian f32 values
         [or quantized bytes if vec_quantized flag is set — future]
X       Text section  (optional, Flags&0x02)
         Len          varint  byte length
         bytes        Len     UTF-8 text
Y       Meta section  (optional, Flags&0x04)
         Len          varint  byte length
         bytes        Len     serialized (msgpack/CBOR)
Z       Fields section (optional, Flags&0x10; multi-field)
         FieldCount   varint  number of fields
         repeated FieldCount times:
           FieldId    varint  field id (assigned by field.schema registry)
           ValLen     varint  field value byte length
           Value      ValLen  field value UTF-8
```

### Flags byte (offset 1)

| Bit | Name             | Meaning                                      |
|-----|------------------|----------------------------------------------|
| 0   | `has_vector`     | Vector section present                       |
| 1   | `has_text`       | Text section present                         |
| 2   | `has_meta`       | Meta section present                         |
| 3   | `vec_quantized`  | Vector section contains quantized data (future) |
| 4   | `has_fields`     | Fields section present (multi-field)         |

Optional sections appear **in vector→text→meta→fields order** whenever
present.  The Flags byte determines which sections exist.

### VByte varints (S11, #2)

All lengths/counts (Dim, section Lens, FieldCount, FieldId) use VByte,
replacing the old fixed 4B/2B big-endian integers to save the fixed prefix
on small fields.

- Each byte holds 7 data bits; the **high bit is the terminator** (`1` = last
  byte). Note this is the *opposite* of LEB128's continuation bit, e.g.
  `varint(2) = 0x82` (`2 | 0x80`), not `0x02`.
- Algorithm in `vbyte.hpp`; codec-local `std::byte` helpers are
  `vbyte_append` / `vbyte_read`.

### Vector / Text / Meta sections

- Vector: `Dim` is the f32 element count (not byte count); payload is
  `Dim×4` little-endian f32 values, or quantized codewords (future;
  `vec_quantized = 1` currently errors).
- Text / Meta: `Len` is the payload byte length; payload is raw bytes
  (Text is UTF-8, Meta is arbitrary serialized bytes).

### Fields section + field-name registry (S11, #1)

The old format **inlined field names** ("title"/"body"...) in every record;
append-only, the same schema across many docs repeats names endlessly. v3
stores **field ids** instead, keeping each name once in a registry.

- **Registry**: append-only file `<dir>/field.schema`; each new field name
  appends `[NameLen:u16 BE][name]`, and **id = order of appearance** (0-based).
  Replayed sequentially on open to restore name↔id. See `field_schema.hpp`
  (`FieldSchema::open/intern/name_of`); Cask loads it on `open`/`upgrade`,
  and `put_doc` interns field names to ids before encoding.
- **Codec stays pure**: `DocField{id, value}`; the name↔id mapping lives in
  the Cask layer. `decode_doc_value` only recovers the id.
- **Write-only today**: none of the current `decode_doc_value` call sites read
  field names (the fields section is reserved for a future "rebuild the
  multi-field index from data files"), so the id switch has ~zero read-side
  blast radius.
- **Merge-safe**: merge copies the value verbatim (no re-encode), so field ids
  survive merge unchanged (the schema persists in the same directory).

Index side (orthogonal to storage): each field gets its own InvertedIndex
(isolated BM25 stats); `field:term^boost` routes to the right field. A
catch-all (S9.29) also merges field texts into the default-field index so
unqualified `search_text`/`search_phrase`/`search_near` still match.

Source: `cpp/include/bitcask/format.hpp` + `cpp/src/fileops/codec.cpp`
(`encode_doc_value` / `decode_doc_value`) + `cpp/include/bitcask/field_schema.hpp`.

---

## 6. Lock files

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
discover the live writer's current active file id.  They then exclude
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

## 7. Read / write summary

**put(K, V)**:
1. Encode a data record with `type = kDoc` and `pwrite` it to the active data file.
2. Encode a hint record and append it to the active hint file.
3. Update the keydir: `K → (active_file_id, offset, total_size, tstamp, ord)`.

**get(K)**:
1. Look up `(file_id, offset, total_size)` in the keydir.
2. `pread(offset, total_size)` from the corresponding data file.
3. Verify CRC; `type = kTombstone` surfaces as `not_found`.
4. For `kDoc` records, decode DocValue to recover vector/text/meta.

**delete(K)**:
1. Encode a tombstone data record (`type = kTombstone`) + a tombstone hint record.
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

## 8. Recovery on open

`Cask::open` runs three recoveries before returning:

1. **Stale-lock reclaim** — see §6.
2. **Torn-write tail trim** — `DataFile::fold` reports the offset just
   past the last successfully-decoded record via `out_last_valid_end`.
   If the file is longer than that AND this cask is the writer
   (`read_write && !merge_only`), the file is truncated back to that
   offset.  This handles a writer that crashed mid-record, leaving
   unparsable trailing bytes.  `merge_only` opens never truncate — they
   don't own `write.lock`, and a still-running writer might be appending
   beyond what we just observed.
3. **Hint validation** — if a hint exists but its trailer CRC is bad
   (or the sentinel is missing), the hint is ignored and the keydir is
   rebuilt from the data file.

Read-only opens never modify the directory.

---

## 9. Hard constraints (don't change these)

The following are wire-format guarantees with byte-level fixtures in
`cpp/tests/codec_test.cpp`.  Changing any of them is a binary-compatibility
break:

- **Big-endian** encoding throughout (no platform-native shortcuts).
  Exception: f32 vector arrays inside DocValue are native little-endian.
- Header sizes: data record = **23 B**, hint record = **18 B**.
- CRC polynomial = **zlib / IEEE 802.3** (so `erlang:crc32/1` matches).
- CRC covers `Type..Value` (not from `Tstamp` as in some legacy formats).
- Record type field: `kDoc = 0`, `kTombstone = 1`.
- Ord field: 8 bytes, big-endian, monotonically increasing, never reused.
- Tombstone flag in hints lives in the **high bit of the packed
  offset field** (bytes 10..17, bit 63), capping `Offset` at 63 bits.
- DocValue: Ver=3, Flags at offset 1, sections ordered vector→text→meta→fields;
  all lengths/counts are VByte varints; fields store field ids (see §5).

`cpp/include/bitcask/format.hpp` is the single source of truth for these
constants.