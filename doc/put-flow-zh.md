# put(K, V) 完整调用链

从 Erlang 层一路到磁盘字节落定。每一步都标了源码位置，方便对照阅读。
本文描述的是 `bitcask:put/3` 的成功路径与关键 race 处理；磁盘格式细节
见 [`format-zh.md`](format-zh.md)。

---

## 第 0 层：Erlang facade

`src/bitcask.erl:120`

```erlang
put(Ref, Key, tombstone) -> bitcask_cpp_nifs:cask_delete(Ref, Key);
put(Ref, Key, Value)     -> bitcask_cpp_nifs:cask_put(Ref, Key, Value).
```

`bitcask:put/3` 直接下沉 NIF，不做 tombstone dispatch（tombstone 走
`bitcask:delete/2`）。

---

## 第 1 层：NIF 入口

`cpp/nif/nif_cask.cpp::nif_cask_put`

1. `enif_inspect_binary(env, argv[1], &key)` — 取 key binary（zero-copy view）
2. `enif_inspect_binary(env, argv[2], &value)` — 同上
3. `as_bytes()` 把 `ErlNifBinary` 包成 `std::span<const std::byte>`
4. 调 `h->cask->put(as_bytes(key), as_bytes(value))`
5. `expected<void, CaskFault>` → `ok` 或 `{error, Reason}` 元组

> 注：`cask_put` 在 `nif_main.cpp:120` 注册为**普通调度器**任务（不是
> dirty IO）——单次 put 是确定的小工作量，不需要让出 BEAM 主调度器。
> 长耗时的 `cask_open` / `cask_sync` / `cask_close_write_file` /
> `cask_merge` 才挂 `ERL_NIF_DIRTY_JOB_IO_BOUND`。

---

## 第 2 层：Cask::put — 写入编排

`cpp/src/cask/cask.cpp::Cask::put`

```
1. 权限校验
   - read_write == false 或 merge_only == true → kReadOnly
2. 大小校验
   - key.size() > 65535       → kKeyTooLarge
   - value.size() > 4 GiB     → kValueTooLarge
3. tstamp 默认值
   - tstamp == 0 时取当前 Unix 秒
4. ★ DocValue 编码
   - 用 codec::encode_doc_value 把 value 打包成 DocValue（text 段 = 原始 value）
   - encoded = [Ver=3][Flags][Len:varint][text bytes]
5. ★ 分配 ord
   - ord = keydir_->alloc_ord()（全局单调递增序号）
6. 估算本次 record 字节数
   - about = 23 + key.size() + encoded.size()     ← 23B header（新格式）
7. roll_active_if_needed(about)
   - 没 active writer → ensure_active_writer()
   - 写入会撑爆 max_file_size → roll_active()
8. ★ 关键 race 检查：active_file_id_ < keydir.biggest_file_id() → roll_active()
   - 并发 merger 抢先把 biggest_file_id 推过去了
   - 不主动 roll 的话第 11 步 keydir.put 会被 staleness 检查拒掉，put 静默丢失
9. active_data_->write(kDoc, tstamp, ord, key, encoded)  → 落 data record
10. active_hint_->write(tstamp, total_sz, offset, false, key)  → 落 hint record
11. keydir_->put(key, active_file_id_, total_sz, offset, tstamp,
                 0, /*newest_put=*/true, 0, 0, ord)
12. 如果 keydir 返回 kAlreadyExists（极少见的二段 race）→ roll + 重试一次
    二次仍失败 → 上报 kAlreadyExists
13. 如果开启了索引模式（search_ != nullptr）→ 调 search_->on_write(...)
    在 SearchLayer 里建立 text 索引
```

---

## 第 3 层：active writer 准备（首次写或切文件时）

`Cask::ensure_active_writer` (`cpp/src/cask/cask.cpp`)

```
1. 如果 active_data_ 已存在 → 直接返回
2. 如果 write_lock_ 空（之前 close_write_file 释放过）：
   - acquire_writer_lock(dirname)
     · O_CREAT|O_EXCL 创建 bitcask.write.lock
     · EEXIST → try_remove_stale_lock：
         读现有锁 → 解析 pid → kill(pid, 0) 探活
         死了 → unlink 重试
         活着 → 返回 kWriteLocked
3. active_file_id_ = keydir_->increment_file_id()  ← 单调递增分配
4. 创建 <file_id>.bitcask.data（O_CREAT|O_EXCL，o_sync 模式带 O_SYNC）
5. 创建 <file_id>.bitcask.hint（同上）
6. 把 "<pid> <active_data_path>\n" 写到 bitcask.write.lock
   → merger 读这个内容知道「不能合这个文件」
```

---

## 第 4 层：磁盘字节布局

### `DataFile::write` (`cpp/src/fileops/data_file.cpp`)

`codec::encode_data_record` 在内存 buffer 里组装（23 B 固定 header）：

```
偏移   字段      值
───────────────────────────────────────
0      CRC32     算 Type..Value 的 zlib CRC，写到这里（4 B）
4      Type      u8：0=kDoc，1=kTombstone
5      Tstamp    大端 u32（4 B）
9      Ord       大端 u64（8 B）—— 单调递增的写入序号
17     KeySz     大端 u16（2 B）
19     ValueSz   大端 u32（4 B）
23     Key       原样字节
23+KS  Value     DocValue 打包字节（kDoc 时）：[Ver=3][Flags][可选段…]（段长 varint）
```

CRC 覆盖 `Type..Value`（即偏移 4 起的所有内容），不包含 CRC 字段本身。
这与 legacy 从 `Tstamp` 开始计算不同。

然后 **`file_.pwrite(current_offset_, buf)`**——注意是 pwrite 不是
write，文件虽然带 O_APPEND 打开，但这里显式追踪偏移，方便 torn-write
修复时 truncate。

写完 `current_offset_ += total`，返回 `{offset, total_size}` 给上层。

### DocValue 打包格式（kDoc value）

`codec::encode_doc_value` 将 value 编码为：

```
偏移   字段              字节数   说明
───────────────────────────────────────────
0      Ver               1        当前 = 3
1      Flags             1        bit0=has_vector bit1=has_text bit2=has_meta bit4=has_fields
       各段按 vector→text→meta→fields 顺序、由 Flags 决定存在；长度/计数全 varint：
         vector?  [Dim:varint][f32×Dim 小端]
         text?    [Len:varint][bytes]
         meta?    [Len:varint][bytes]
         fields?  [FieldCount:varint] ×{[FieldId:varint][ValLen:varint][value]}
```

普通 `put(K,V)` 写入时只有 text 段（原始 value 作为 UTF-8 文本）。完整布局与
field id（schema interning）见 `format-zh.md` §五。

### `HintFile::write` (`cpp/src/fileops/hint_file.cpp`)

`codec::encode_hint_record` 组装（18 B 固定 header）：

```
偏移   字段          值
─────────────────────────────────────
0      Tstamp        大端 u32
4      KeySz         大端 u16
6      TotalSz       data record 整条字节数（含 23 B header）
10     Tomb|Offset   大端 u64：(0 << 63) | offset      ← 普通 put，tomb=0
18     Key           原样字节
```

然后 `file_.write(buf)` 顺序追加，并
`running_crc_ = crc32_update(running_crc_, buf)`——为最终 close 时写
trailer 用。

---

## 第 5 层：内存索引更新

`KeyDir::put` (`cpp/src/keydir/keydir.cpp`)

```
1. unique_lock(mutex_)（写锁）
2. 探测 key 当前在 pending_ 还是 entries_ 中
3. epoch_++  ← 全局逻辑时钟，作为本次写入的版本号
4. 三大分支：
   (A) key 不存在 / 是墓碑：
       - merge race 检查：file_id < biggest_file_id_ → kAlreadyExists
       - 没 fold → entries_[key] = SingleEntry{..., ord}  ← 最常见路径
       - 在 fold → 走 pending 表
   (B)/(C) key 存在：
       - staleness 检查（newest_put=true 模式：file_id >= biggest_file_id_）
       - 没 fold → 直接覆盖
       - 在 fold → 升级为 sibling 链 MultiEntry，新 revision 插链头
5. 更新 fstats：
   - 新 file → 创建一条；live++、total++、live_bytes+=sz、total_bytes+=sz
   - 同 file 覆盖 → 旧 file live--、新 file live++
6. biggest_file_id_ = max(biggest_file_id_, file_id)
```

`ord` 参数在第 4 步写入 SingleEntry/MultiEntry，用于 tie-breaking
和 SearchLayer 的文档跟踪。

---

## 完整时序示意

```
Erlang 进程              NIF/C++                       磁盘
────────────────────────────────────────────────────────────
bitcask:put(R,K,V)
  └─→ cask_put NIF
        └─→ Cask::put
              ├─[校验 + DocValue 编码 + alloc_ord]
              ├─→ DataFile::write
              │     └─ pwrite(off, [CRC|Type|Tstamp|Ord|KS|VS|K|DocValue])
              │                                         ━━━━ <id>.bitcask.data
              ├─→ HintFile::write
              │     └─ write([Tstamp|KS|TSz|Off|K])     ━━━━ <id>.bitcask.hint
              ├─→ KeyDir::put
              │     └─ entries_[K] = {fid,off,tsz,ep,ts,ord}
              └─[可选]→ SearchLayer::on_write
                        └─ InvertedIndex::add_doc
        └─ return ok
  ←─ ok
```

DocValue 编码将原始 value 打包为 `[Ver=3][Flags][Len:varint][text bytes]`——
普通 put 只含 text 段。写入 record 的 type = kDoc，ord = alloc_ord()
返回的单调递增序号。

落盘顺序固定：**data → hint → keydir**。这是有意为之：

- 如果 data 写到一半 crash → 文件尾是损坏字节，下次 open 的
  `fold(data)` 会跳过、`out_last_valid_end` 报告位置、cask 自动 truncate 修复
- 如果 data 写完但 hint 没写完 → hint trailer CRC 校验失败，cask 忽略
  hint 退回 `fold(data)` 重建，data 是权威
- 如果 data + hint 都写完但 keydir 没更新（比如 cask 进程崩溃）→ 下次
  open 重建 keydir 时会扫到这条 record，自然恢复

---

## 持久性 / 可见性

| sync_strategy   | put 返回时…                                            |
|---|---|
| `none`（默认）  | 字节在 OS page cache，未必落盘；调用方自己择时 sync       |
| `o_sync`        | data + hint 都用 O_SYNC 打开，每次 write 写穿到磁盘       |
| `{seconds, N}`  | 跟 `none` 等价；语义占位，由调用方定时调 sync             |

读路径是单调可见的：`keydir.put` 拿 `unique_lock` 串行化所有写者，
put 返回后任何后续 `get(K)` 立刻能看到新值（即使 OS 还没刷盘——只要
进程不死就有效）。

---

## 失败模式

| 错误                        | 触发点                          | 含义                                       |
|---|---|---|
| `{error, read_only}`        | step 1                          | 没开 read_write，或 merge_only 句柄          |
| `{error, key_too_large}`    | step 2                          | key > 65535 字节                            |
| `{error, value_too_large}`  | step 2                          | value > 4 GiB                              |
| `{error, write_locked}`     | step 5 (ensure_active_writer)   | 别人持有 bitcask.write.lock 且活着            |
| `{error, enospc}` 等        | step 7/8                        | pwrite 失败                                 |
| `{error, already_exists}`   | step 10                         | 二段 race 重试仍失败（极罕见）                |

---

## 关键不变量

- **file_id 单调递增**：`KeyDir::increment_file_id()` 是唯一分配器，
  active_file_id_ 永远不小于历史任何已分配 id。配合 keydir 的 staleness
  检查防止「老 file_id 写入覆盖新值」。
- **ord 单调递增**：每次 `put` 调用 `keydir_->alloc_ord()` 获取全局单调
  递增序号，永不复用。用于 tie-breaking、有序遍历和 SearchLayer 文档跟踪。
- **DocValue 编码格式**：`type = kDoc` 的 value 必须是 `encode_doc_value`
  输出的打包格式（Ver + Flags + 可选段），否则 CRC 校验会失败。
- **data 在 hint 之前**：data 是权威，hint 只是加速重建的索引；
  hint 损坏可以从 data 重建，反之不行。
- **keydir 在最后更新**：keydir 是 put 成功的唯一可见性边界；任何在
  keydir 更新前 crash 的 put 都不会被后续 get 看到（虽然字节可能已经
  在磁盘上）。

源码导航：

- `src/bitcask.erl::put/3` — Erlang facade
- `cpp/nif/nif_cask.cpp::nif_cask_put` — NIF 翻译层
- `cpp/src/cask/cask.cpp::Cask::put` — 写入编排主体
- `cpp/src/cask/cask.cpp::ensure_active_writer` — 锁 + 文件准备
- `cpp/src/fileops/data_file.cpp::DataFile::write` — 落 data record
- `cpp/src/fileops/hint_file.cpp::HintFile::write` — 落 hint record
- `cpp/src/fileops/codec.cpp::encode_data_record` / `encode_doc_value` /
  `encode_hint_record` — 字节编码
- `cpp/src/keydir/keydir.cpp::KeyDir::put` — 内存索引更新
- `cpp/src/keydir/keydir.cpp::KeyDir::alloc_ord` — ord 分配
- `cpp/src/search/search_layer.cpp::SearchLayer::on_write` — 索引更新（索引模式）
