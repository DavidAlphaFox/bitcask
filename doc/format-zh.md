# Bitcask 存储格式

本文档是 C++ 实现读写的字节级规范。权威来源：

- 常量定义：`cpp/include/bitcask/format.hpp`
- 编解码：`cpp/src/fileops/codec.cpp`
- 文件抽象：`cpp/include/bitcask/data_file.hpp` / `hint_file.hpp`
- Meta 文件：`cpp/include/bitcask/meta_file.hpp`
- 字节级测试固件：`cpp/tests/codec_test.cpp`

所有多字节整数均为**大端**（f32 向量数组除外，为小端）。字段大小单位均为字节。

---

## 一、目录结构

一个 bitcask 实例就是一个普通目录：

```
<dir>/
├── bitcask.meta              # 二进制元数据（模式标记）
├── <tstamp1>.bitcask.data    # append-only data 文件
├── <tstamp1>.bitcask.hint    # 可选 sidecar 索引（与 data 文件一一对应）
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── bitcask.write.lock        # 写锁（live writer 持有）
└── bitcask.merge.lock        # 合并锁（active merger 持有）
```

`<tstampN>` 是 file id，一个全局单调递增的十进制整数（内部 uint32，
解析时按 uint64 安全处理）。`KeyDirRegistry` 跨 open/close 持久化
`biggest_file_id + 1`，确保未来的 open 不会复用 id——这是 keydir 不
会把老文件误认为新文件的保证。目录扫描按 tstamp 升序遍历。

### bitcask.meta（18 字节）

```
偏移   字段       字节数  说明
────────────────────────────────────────────
0      Magic      4       "BCME" (0x42434D45)
4      Version    1       1
5      Mode       1       0 = KV 模式，1 = 索引模式（BM25 搜索）
6      Reserved   12      全零；预留将来扩展
```

来源：`cpp/include/bitcask/meta_file.hpp`。

---

## 二、Data 文件格式（Data record）

append-only 的 record 序列，文件本身无 header，record 之间无 padding。

```
偏移   字段        字节数  说明
────────────────────────────────────────────
0      CRC32       4       覆盖 Type..Value（zlib 多项式，跟 erlang:crc32 一致）
4      Type        1       RecordType：0 = kDoc，1 = kTombstone
5      Tstamp      4       写入时刻的 Unix 秒
9      Ord         8       单调递增的写入序号（大端），永不复用
17     KeySz       2       key 字节数（≤ 65535）
19     ValueSz     4       value 字节数（≤ ~4 GiB）
23     Key         KeySz
23+KeySz Value     ValueSz
```

整条 record 长度 = `23 + KeySz + ValueSz`，header 固定 23 字节。

| 字段       | 宽度  | 含义                                              |
|------------|-----|--------------------------------------------------|
| `crc`      |  4 B | CRC-32 (zlib) 覆盖 `type..value`                 |
| `type`     |  1 B | RecordType：`kDoc = 0`，`kTombstone = 1`         |
| `tstamp`   |  4 B | 写入时刻的 Unix 秒                                 |
| `ord`      |  8 B | 单调递增的写入序号；永不复用                        |
| `key_sz`   |  2 B | key 字节数，最大 65535                            |
| `value_sz` |  4 B | value 字节数，最大 `kMaxValueSize`                |
| `key`      | var  | 原始字节，允许包含 NUL                            |
| `value`    | var  | kDoc 时为打包的 DocValue（§5）；kTombstone 时通常为空 |

### CRC 覆盖范围

CRC 覆盖 `Type..Value`（即 4 字节 CRC 字段之后的所有内容）。
这与某些 legacy 格式从 `Tstamp` 开始计算不同。CRC 字段本身不参与校验和。

### RecordType 枚举

```cpp
enum class RecordType : std::uint8_t {
    kDoc       = 0,  // value 是打包的 DocValue（§5）
    kTombstone = 1,  // 删除标记；value 通常为空
};
```

墓碑是**一等公民的 record 类型**，不再靠 value 魔法前缀识别。
`CaskOptions` 中的 `tombstone_version` 选项对新写入已无意义。

---

## 三、墓碑（Tombstones）

删除操作产生的 record 的 `type = kTombstone`（Type 字段 = 1）。
value 通常为空。Ord 字段给出本次删除的唯一写入序号；key + Ord
共同确定这条墓碑超越的是哪一次写入。

旧机制——通过扫描 value 中的 `"bitcask_tombstone"` 前缀来识别墓碑——
**不再是主要格式**。读取代码应同时兼容新的类型化格式和 legacy
value-magic 格式，以保持对旧文件的向后兼容。

---

## 四、Hint 文件格式（Hint record）

每个 data 文件*可以*有一个并行的 hint 文件（`<tstamp>.bitcask.hint`）。
Hint 是不含 value 的离线索引，用于在 open 时加速 keydir 重建
（无需读取全部 value 字节）。

```
偏移   字段              字节数  说明
────────────────────────────────────────────
0      Tstamp           4       同 data record 的 tstamp
4      KeySz            2
6      TotalSz          4       data record 整条字节数（含 23B header）
10     Tomb|Offset      8       最高位 = 墓碑标志，低 63 位 = data 文件内偏移
18     Key              KeySz
```

整条长度 = `18 + KeySz`，header 固定 18 字节。

### Packed offset 字段（位置 10..17 的 8 字节大端 uint64）

```
位 63       位 62..0
[Tomb:1] [Offset:63]
```

- `Tomb = 1` 表示这是墓碑 hint（对应的 data record 的 `type = kTombstone`）
- `Offset` 上限 `kMaxOffsetV2 = 0x7FFF_FFFF_FFFF_FFFF`（约 8 EiB，
  远超任何实际 data 文件大小）

注意：墓碑标志在 **offset 字段的最高位**，**不是** tstamp 字段。
这与 legacy `bitcask_fileops:hintfile_entry/5` 完全一致：

```erlang
%% legacy 5-arg packing
<<Tstamp:32, KeySz:16, TotalSz:32, Tomb:1, Offset:63>>
```

### EOF sentinel（文件末尾的封口 record）

hint 文件末尾必须有一条特殊 record 作为「封口」，**布局跟普通 hint
record 完全一致**，但字段值被重新定义：

```
字段      值
───────────────────────────────────────
Tstamp    0
KeySz     0
TotalSz   整文件 running CRC32（trailer CRC，借用此字段）
Tomb      0
Offset    kMaxOffsetV2 (= 2^63 - 1)
（因 KeySz=0，无 key payload）
```

整条 sentinel 长度固定 18 字节（KeySz=0 所以无 key payload）。

读取方靠 `(KeySz == 0 && Offset == kMaxOffsetV2)` 识别 sentinel
（`codec::is_hint_eof`）。

`HintFile::validate_trailer()` 读取 sentinel 的 `TotalSz`，然后流式
重算前面所有字节的 CRC 并比对——不通过则 fallback 到 `fold(data_file)`
全量重建 keydir。

---

## 五、DocValue 格式（kDoc value 打包）

`type = kDoc` 的 record 其 value 编码为 DocValue 格式——可选 vector、text、
meta、fields 四段的打包二进制结构。

> **统一编码**：纯 KV 模式 `put(key, binary)` 与索引模式 `put_doc` 写入的
> value **都编码为 DocValue**——KV 的 binary 放进 text 段。因此 `get` 返回的
> 是解码后的 text；fold/stream/list_keys 也必须解码取 text 段（见 §九）。

```
偏移   字段              字节数  说明
────────────────────────────────────────────
0      Ver               1       布局版本：1=无 fields 段；2=含 fields 段（S8.6）
1      Flags             1       位掩码（见下）
2      Vector 段（可选，Flags&0x01 时存在）
         Dim            4       f32 元素个数（大端）
         f32 数组        Dim×4   小端 f32 值
         [若 Flags&0x08 置位，则为量化码字——未来扩展；V1 不支持]
X      Text 段（可选，Flags&0x02 时存在）
         Len             4       字节长度（大端）
         字节数组         Len    UTF-8 文本
Y      Meta 段（可选，Flags&0x04 时存在）
         Len             4       字节长度（大端）
         字节数组         Len    序列化数据（msgpack/CBOR 等）
Z      Fields 段（可选，Flags&0x10 时存在；S8.6 多字段）
         FieldCount     2       字段数（大端 u16）
         重复 FieldCount 次：
           NameLen      2       字段名字节长度（大端 u16）
           Name         NameLen 字段名 UTF-8
           ValLen       4       字段值字节长度（大端 u32）
           Value        ValLen  字段值 UTF-8
```

### Flags 字节（偏移 1）

| 位   | 名称            | 含义                                      |
|-----|-----------------|------------------------------------------|
| 0   | `has_vector`    | Vector 段存在                             |
| 1   | `has_text`      | Text 段存在                               |
| 2   | `has_meta`      | Meta 段存在                               |
| 3   | `vec_quantized` | Vector 段含量化数据（未来扩展；V1 不支持） |
| 4   | `has_fields`    | Fields 段存在（S8.6 多字段）              |

四个可选段存在时**按 vector→text→meta→fields 顺序**排列，由 Flags 决定哪些存在。

### 版本兼容（S8.6）

- **编码**：`encode_doc_value` 仅当存在 fields 段时写 `Ver=2`；否则写 `Ver=1`，
  字节与旧实现完全一致（保证旧数据/旧测试字节级不变）。
- **解码**：`decode_doc_value` 接受 `Ver ∈ {1, 2}`（范围式兼容）。

### Vector 段

- `Dim`：f32 元素个数（不是字节数），大端 u32。
- Payload：要么是 `Dim × 4` 个小端 f32 值，要么是量化码字（未来扩展；
  V1 若 `vec_quantized = 1` 则报错）。

### Text 段

- `Len`：UTF-8 文本的字节长度，大端 u32。
- Payload：原始 UTF-8 字节。

### Meta 段

- `Len`：序列化元数据的字节长度，大端 u32。
- Payload：任意序列化字节（msgpack、CBOR 等）。

### Fields 段（S8.6 多字段）

- 用于 `put_doc(#{title=>..., body=>...})` 这类多字段文档。
- 每个字段是 `(NameLen, Name, ValLen, Value)`，字段名/值均为 UTF-8。
- **索引侧**：每个字段建立独立的 InvertedIndex（字段间 BM25 统计隔离），
  查询语法 `field:term^boost` 路由到对应字段。
- **catch-all（S9.29）**：写入多字段文档时，各字段文本另会拼接合并进**默认
  字段**索引，使无字段限定的 `search_text`/`search_phrase`/`search_near`
  （只查默认字段）也能命中多字段文档。取舍：拼接会模糊原字段边界，短语
  查询可能跨字段误匹配（全文搜索可接受；字段限定查询不受影响）。

来源：`cpp/include/bitcask/format.hpp` + `cpp/src/fileops/codec.cpp`
（`encode_doc_value` / `decode_doc_value`）。

---

## 六、锁文件

`bitcask.write.lock` 和 `bitcask.merge.lock` 是 advisory 文件锁。
**不是** POSIX `flock` 也**不是** fcntl 记录锁——bitcask 完全依赖
`O_CREAT | O_EXCL` 的 acquire 原子性 + release 时 `unlink` 实现互斥。

| 文件                    | 持有者  | 用途                                              |
|-------------------------|--------|--------------------------------------------------|
| `bitcask.write.lock`    | writer | 同目录同时最多一个 writer                         |
| `bitcask.merge.lock`    | merger | 同目录同时最多一个 merger；**不阻塞 writer**        |

两把锁故意分开设计，让周期性 merge 能跟 live writer 并行——merger 拿
`merge.lock`、writer 拿 `write.lock`，互不冲突。

### 锁文件内容格式

```
<pid> <active_data_file_path>\n
```

或者锁刚拿到、active 文件还没建好时只有：

```
<pid>\n
```

merger（在 `merge_only = true` 模式下 open）读 `bitcask.write.lock`
获取 live writer 的 active file id，然后将其（以及更新的任何文件）
从 `needs_merge` 候选中排除——绝对不能合并别人还在写的文件。

### Stale-lock 回收

`acquire` 时若 `O_CREAT|O_EXCL` 返回 `EEXIST`，则打开锁文件、解析
leading PID、`kill(pid, 0)` 探测原持有进程是否存活：

- `0`      → 进程活着，锁合法持有 → 返回 `kWriteLocked`
- `ESRCH`  → 进程已消失，锁已 stale → `unlink` 后重试
- `EPERM`  → 进程存在但无权发送信号 → 保守视为存活

这处理了常见的"writer crash 后未释放锁"场景
（见 `cpp/src/cask/cask.cpp::try_remove_stale_lock` + `process_alive`）。

存在一个极小的 race 窗口：读取 PID 到 unlink 之间，另一个 writer 可能
写入了新锁而被我们误删。这个 race 在 legacy 中同样存在，实际影响面
仅限于 crash recovery 路径。

NFS 上 `O_EXCL` 不可靠，但 bitcask 也不该跑在网络文件系统上。

---

## 七、读写流程对照

**put(K, V)**：
1. 编码一条 `type = kDoc` 的 data record，`pwrite` 到 active data 文件末尾
2. 编码一条 hint record，append 到 active hint 文件
3. 更新 keydir：`K → (active_file_id, offset, total_size, tstamp, ord)`

**get(K)**：
1. 在 keydir 中查找 `(file_id, offset, total_size)`
2. 按 file_id 找到对应 data 文件 → `pread(offset, total_size)` 一次磁盘读
3. CRC 校验；`type = kTombstone` 当作 `not_found`
4. 对 `kDoc` record，解码 DocValue 还原 vector/text/meta

**delete(K)**：
1. 编码一条墓碑 data record（`type = kTombstone`）+ 一条墓碑 hint record
2. 在 keydir 中将 K 标记为墓碑

**open**（重建 keydir）：
1. `scan_dir` 列出所有 `<tstamp>.bitcask.data`，按 tstamp 升序
2. 对每个文件：
   - 优先 `fold(hint_file)` + `validate_trailer()`——只读 key + 元数据
   - hint 缺失或 trailer CRC 不通过 → fallback 到 `fold(data_file)` 全量扫
3. 后写入的 entry 自动覆盖前面的（因为按 tstamp 升序遍历）

**merge**：
1. 获取 `bitcask.merge.lock`（不影响 writer）
2. 读 `write.lock` 获取 live writer 的 active file id；将其及更新的文件排除
3. `needs_merge` 按 frag / dead_bytes / expiry 阈值挑候选
4. `run_merge`：扫候选文件，仅复制 keydir 仍指向 `(file_id, offset)` 的活 record
5. CAS 更新 keydir → unlink 被合并走的文件

---

## 八、Open 时的恢复路径

`Cask::open` 在返回前执行三个恢复步骤：

1. **Stale lock 回收**（见 §6）。
2. **Torn-write 尾部修剪**：`DataFile::fold` 通过 `out_last_valid_end`
   报告最后一条成功解码 record 末尾的偏移。若文件比该值长 **且**
   当前 cask 是 writer（`read_write && !merge_only`），则 `truncate_to`
   截掉无法解析的尾部字节——典型场景是 writer 写到一半 crash。
   `merge_only` 模式不会这么做：万一 live writer 还在文件后面追加，
   截断会切掉别人的数据。
3. **Hint 校验**：若 hint 存在但 trailer CRC 不通过（或 sentinel 缺失），
   忽略 hint，从 data 文件全量重建 keydir。

只读 open 永远不会修改目录。

---

## 九、磁盘契约的硬约束

以下为线格式（wire-format）保证，在 `cpp/tests/codec_test.cpp`
中有字节级测试固件。修改其中任何一项都破坏二进制兼容性：

- **大端**编码贯穿全部字段（无平台原生捷径）。
  例外：DocValue 内的 f32 向量数组为小端。
- Header 长度：data record = **23 B**，hint record = **18 B**。
- CRC 多项式 = **zlib / IEEE 802.3**（使 `erlang:crc32/1` 结果一致）。
- CRC 覆盖 `Type..Value`（不是从 `Tstamp` 开始，这与某些 legacy 格式不同）。
- Record type：`kDoc = 0`，`kTombstone = 1`。
- Ord 字段：8 字节，大端，单调递增，永不复用。
- 墓碑标志在 hint packed offset 的**最高位**（字节 10..17，位 63），
  Offset 限于 63 位。
- DocValue：Flags 在偏移 1 处，各段按 vector→text→meta→fields 排序；
  Ver=1（无 fields 段，字节同旧实现）或 Ver=2（含 fields 段，S8.6），
  解码接受 Ver∈{1,2}。

所有这些常量集中在 `cpp/include/bitcask/format.hpp`，是本格式的唯一权威来源。