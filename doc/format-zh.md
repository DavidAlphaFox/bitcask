# Bitcask 存储格式

本文档是 C++ 实现读写的字节级规范。权威来源：

- 常量定义：`cpp/include/bitcask/format.hpp`
- 编解码：`cpp/src/fileops/codec.cpp`
- 文件抽象：`cpp/include/bitcask/data_file.hpp` / `hint_file.hpp`
- Meta 文件：`cpp/include/bitcask/meta_file.hpp`
- 字节级测试固件：`cpp/tests/codec_test.cpp`

所有多字节整数均为**小端**（LE-only 主机：x86/ARM64，原生零转换 + mmap 零拷贝
友好）。**flag-day 切换**：此前 record/hint/field.schema 为大端（对齐 legacy Erlang
`<<X:N>>`），切换后旧大端文件不可读（meta version 1→2，旧目录 open 时被干净拒绝），
不再与 legacy Erlang 字节互通。**迁移**：旧大端目录可用 `cpp/tools/migrate_le
<src> <dst>` 离线转换成小端（非破坏性；迁移 data/hint/meta/field.schema，ckpt/seg/wal
等可重建文件由新库首开自动重建）；详见 `cpp/include/bitcask/migrate.hpp`。
字段大小单位均为字节。

---

## 一、目录结构

一个 bitcask 实例就是一个普通目录：

```
<dir>/
├── bitcask.meta              # 二进制元数据（模式 + 向量配置）        §一
├── <tstamp1>.bitcask.data    # append-only data 文件                 §二
├── <tstamp1>.bitcask.hint    # 可选 sidecar 索引（与 data 一一对应）  §四
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── field.schema              # 字段名↔id 注册表（索引模式）          §五
├── bitcask.write.lock        # 写锁（live writer 持有）              §六
├── bitcask.merge.lock        # 合并锁（active merger 持有）          §六
│   # —— 以下为恢复 checkpoint / 索引文件（可 fold 重建，纯优化）——  §十
├── kv.keydir.ckpt            # keydir checkpoint（BCKS）
├── search.docmap.ckpt        # 搜索文档目录 checkpoint（BCIS）
├── search.vec.ckpt           # HNSW 向量图 checkpoint（BCVS）
├── search.bm25.manifest      # bm25 字段清单（文本）
├── search.bm25.f<i>.seg      # bm25 per-field 倒排段
└── search.bm25.f<i>.wal      # bm25 per-field 增量 WAL
```

> checkpoint/索引文件**全部可由 fold 数据文件重建**（纯优化），命名契约
> `{kv|search}.{组件}.{ckpt|seg|wal|manifest}`（P14a）；详见 §十与
> [`recovery-unified-checkpoint-design-zh.md`](recovery-unified-checkpoint-design-zh.md)。

`<tstampN>` 是 file id，一个全局单调递增的十进制整数（内部 uint32，
解析时按 uint64 安全处理）。`KeyDirRegistry` 跨 open/close 持久化
`biggest_file_id + 1`，确保未来的 open 不会复用 id——这是 keydir 不
会把老文件误认为新文件的保证。目录扫描按 tstamp 升序遍历。

### bitcask.meta（18 字节）

```
偏移   字段          字节数  说明
──────────────────────────────────────────────────────────
0      Magic         4       "BCME" (0x42434D45)
4      Version       1       2（v1=大端 legacy；v2=小端 flag-day 起，旧 v1 目录 open 时拒绝）
5      Mode          1       0 = KV 模式，1 = 索引模式（BM25 搜索）
6      VecMetric     1       0=kNone 1=kCosineNormalized 2=kL2 3=kDot（V3.1）
7      VecDim        2       向量维度 u16 小端；0 = 无向量（V3.1）
9      VecQuantized  1       0/1：向量落盘 int8 量化（P3b；旧文件全零=否）
10     VecInmemInt8  1       0/1：HNSW int8-only 内存模式（P5b；仅 kDot）
11     Reserved      7       全零；预留将来扩展
```

不变量：`(VecMetric==kNone) ⟺ (VecDim==0)`。VecMetric/Dim/Quantized/InmemInt8
创建即固定，重开必须与 open 选项一致，否则 `kModeMismatch`。
来源：`cpp/src/cask/meta_file.cpp`、`cpp/include/bitcask/meta_file.hpp`。

---

## 二、Data 文件格式（Data record）

append-only 的 record 序列，文件本身无 header，record 之间无 padding。

```
偏移   字段        字节数  说明
────────────────────────────────────────────
0      CRC32       4       覆盖 Type..Value（zlib 多项式，跟 erlang:crc32 一致）
4      Type        1       RecordType：0 = kDoc，1 = kTombstone
5      Tstamp      4       写入时刻的 Unix 秒
9      Ord         8       单调递增的写入序号（小端），永不复用
17     KeySz       2       key 字节数（≤ 65535）
19     ValueSz     4       value 字节数（≤ ~4 GiB）
23     Key         KeySz
23+KeySz Value     ValueSz
```

整条 record 长度 = `23 + KeySz + ValueSz`，header 固定 23 字节。

### 完整布局（两层嵌套）

一条 record 是**两层嵌套**：外层是 record 框架，`Value` 段在 `type = kDoc`
时本身又是一个打包的 **DocValue v3**（详见 §五）。统一架构下纯 KV 模式的
`put(key, binary)` 也走 DocValue——binary 放进 text 段。

```
┌─ data record ───────────────────────────────────────────────┐
│ CRC(4) Type(1) Tstamp(4) Ord(8) KeySz(2) ValueSz(4)  ← 头 23B │
│ Key (KeySz 字节)                                              │
│ Value (ValueSz 字节)                                          │
│   └─ kDoc 时 = DocValue v3 ─────────────────────────────┐    │
│      [Ver=3][Flags]                                      │    │
│        vector? [Dim:varint][f32×Dim 小端]      Flags&0x01│    │
│        text?   [Len:varint][bytes]             Flags&0x02│    │
│        meta?   [Len:varint][bytes]             Flags&0x04│    │
│        fields? [FieldCount:varint] ×           Flags&0x10│    │
│                  {[FieldId:varint][ValLen:varint][value]}│    │
│   ──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
   CRC 覆盖 Type..Value 全部字节（含内层 DocValue）。
```

**例 ① 纯 KV `put("user:1","hello")`**（binary 进 text 段）：

```
头(23B, KeySz=6 ValueSz=8) │ "user:1" │ 03 02 85 "hello"
                             key(6B)     Ver=3 Flags=has_text Len=5(0x85=5|0x80) "hello"
```
整条 = 23 + 6 + 8 = **37 字节**。

**例 ② 多字段 `put_doc(#{title=>"a", body=>"b"})`**（title→id0、body→id1）：

```
value: 03 10 │ 82 │ 80 81 "a" │ 81 81 "b"
       Ver=3 has_fields │ Count=2 │ id=0 ValLen=1 "a" │ id=1 ValLen=1 "b"
```
字段名 `title`/`body` **不在 record 里**，只在 `<dir>/field.schema` 注册表存一份。

**例 ③ 墓碑**：`Type=1`，`ValueSz=0`（Value 空），靠 Ord/key 标记删除。

> append-only：每次 put/update/delete 都追加一条新 record，同 key 旧版本成为
> 死字节，由 merge 按阈值回收（merge 逐字节复制 live record，不重编码 →
> DocValue 字节与 field id 原样保留）。

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

### Packed offset 字段（位置 10..17 的 8 字节小端 uint64）

```
位 63       位 62..0
[Tomb:1] [Offset:63]
```

- `Tomb = 1` 表示这是墓碑 hint（对应的 data record 的 `type = kTombstone`）
- `Offset` 上限 `kMaxOffsetV2 = 0x7FFF_FFFF_FFFF_FFFF`（约 8 EiB，
  远超任何实际 data 文件大小）

注意：墓碑标志在 **offset 字段的最高位（bit 63）**，**不是** tstamp 字段。
小端编码下 packed u64 的最高位落在**最后一字节**（位置 17）。逻辑布局对应
legacy 的 5 元组打包,但**字节序已由大端切为小端**(flag-day,不再字节级互通)：

```erlang
%% 逻辑打包（legacy 为大端；现为小端字节序）
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

> **当前版本 `Ver = 3`（S11）**：所有长度/计数改为 **VByte 变长**；fields 段
> 存 **字段 id**（而非内联字段名）。不考虑向后兼容，`decode_doc_value` 只接受
> `Ver == 3`。下表 `varint` 即 VByte 编码（见「VByte 变长」小节）。

```
偏移   字段              字节数  说明
────────────────────────────────────────────
0      Ver               1       布局版本，当前 = 3
1      Flags             1       位掩码（见下）
2      Vector 段（可选，Flags&0x01 时存在）
         Dim            varint  f32 元素个数
         f32 数组        Dim×4   小端 f32 值
         [若 Flags&0x08 置位，则为量化码字——未来扩展；当前不支持]
X      Text 段（可选，Flags&0x02 时存在）
         Len            varint  字节长度
         字节数组         Len    UTF-8 文本
Y      Meta 段（可选，Flags&0x04 时存在）
         Len            varint  字节长度
         字节数组         Len    序列化数据（msgpack/CBOR 等）
Z      Fields 段（可选，Flags&0x10 时存在；多字段）
         FieldCount     varint  字段数
         重复 FieldCount 次：
           FieldId      varint  字段 id（由 field.schema 注册表分配）
           ValLen       varint  字段值字节长度
           Value        ValLen  字段值 UTF-8
```

### Flags 字节（偏移 1）

| 位   | 名称            | 含义                                      |
|-----|-----------------|------------------------------------------|
| 0   | `has_vector`    | Vector 段存在                             |
| 1   | `has_text`      | Text 段存在                               |
| 2   | `has_meta`      | Meta 段存在                               |
| 3   | `vec_quantized` | Vector 段含量化数据（未来扩展；当前不支持） |
| 4   | `has_fields`    | Fields 段存在（多字段）                    |

四个可选段存在时**按 vector→text→meta→fields 顺序**排列，由 Flags 决定哪些存在。

### VByte 变长（S11，#2）

所有长度/计数（Dim、各段 Len、FieldCount、FieldId）用 VByte 编码，取代旧版固定
4B/2B 整数，省掉小字段的固定前缀开销。

- 每字节低 7 位为数据；**最高位 = 终止标记**（`1` 表示末字节）。
- ⚠️ 注意：终止位语义与 LEB128 的「续位」相反。例如 `varint(2) = 0x82`
  （`2 | 0x80`），不是 `0x02`——改黄金 fixture 时易错。
- 算法见 `vbyte.hpp`；codec 内对 `std::byte` 缓冲的实现为
  `vbyte_append` / `vbyte_read`。

### Vector / Text / Meta 段

- Vector：`Dim` 为 f32 元素个数（非字节数），payload 为 `Dim×4` 个小端 f32，
  或量化码字（未来扩展；`vec_quantized=1` 当前报错）。
- Text / Meta：`Len` 为 payload 字节长度，payload 为原始字节（Text 是 UTF-8，
  Meta 是任意序列化字节）。

### Fields 段 + 字段名注册表（S11，#1）

旧版每条 record **内联存字段名**（"title"/"body"...），append-only 下同 schema
的海量文档把字段名重复无数次。v3 改为存 **字段 id**，字段名只在注册表存一份。

- **注册表**：append-only 文件 `<dir>/field.schema`，每个新字段名追加一条
  `[NameLen:u16 小端][name]`，**id = 出现顺序**（0 基）。open 时顺序重放还原
  name↔id。实现见 `field_schema.hpp`（`FieldSchema::open/intern/name_of`），
  Cask 在 `open`/`upgrade` 时加载，`put_doc` 把字段名 `intern` 成 id 后编码。
- **codec 保持纯函数**：`DocField{id, value}`，名字↔id 映射只在 Cask 层；
  `decode_doc_value` 只还原 id。
- **只写不读**：当前 4 个 `decode_doc_value` 调用点都不读字段名（fields 段是为
  「将来从数据文件重建多字段索引」预留），故 id 化的读侧改动面≈0。
- **merge 安全**：merge 逐字节复制 value、不重编码，field id 跨 merge 不变
  （schema 与数据同目录持久）。

**索引侧**（与存储格式正交）：每个字段建独立 InvertedIndex（BM25 统计隔离），
查询 `field:term^boost` 路由到对应字段。**catch-all（S9.29）**：写多字段文档时
各字段文本另拼接进**默认字段**索引，使无字段限定的 `search_text`/`search_phrase`/
`search_near` 也能命中（取舍：拼接模糊原字段边界，短语可能跨字段误匹配；字段
限定查询不受影响）。

**收益**（3 字段 doc，名 title/body/author）：结构开销从 ~35B/record 降到
~7B/record，字段名全局只存一份；append-only + merge 双重放大。

来源：`cpp/include/bitcask/format.hpp` + `cpp/src/fileops/codec.cpp`
（`encode_doc_value` / `decode_doc_value`）+ `cpp/include/bitcask/field_schema.hpp`。

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

- **小端**编码贯穿全部多字节整数字段（LE-only 主机原生零转换 + mmap 零拷贝）。
  flag-day 前为大端（对齐 legacy Erlang）；切换后旧大端文件不可读、需重建。
- Header 长度：data record = **23 B**，hint record = **18 B**。
- CRC 多项式 = **zlib / IEEE 802.3**（使 `erlang:crc32/1` 结果一致）。
- CRC 覆盖 `Type..Value`（不是从 `Tstamp` 开始，这与某些 legacy 格式不同）。
- Record type：`kDoc = 0`，`kTombstone = 1`。
- Ord 字段：8 字节，小端，单调递增，永不复用。
- 墓碑标志在 hint packed offset 的**最高位**（字节 10..17，位 63），
  Offset 限于 63 位。
- DocValue：当前 Ver=3，Flags 在偏移 1 处，各段按 vector→text→meta→fields
  排序；所有长度/计数为 VByte 变长，fields 段存字段 id（见 §五）。解码只接受
  Ver==3（不向后兼容）。

所有这些常量集中在 `cpp/include/bitcask/format.hpp`，是本格式的唯一权威来源。

---

## 十、恢复 checkpoint 与索引文件

以下文件都是**派生缓存**：可由 fold 数据文件完全重建（`recover_doc` / keydir
重建），是**纯优化**——任何校验失败 → 丢弃 → 回退全量 fold，绝不影响正确性。
命名契约 `{kv|search}.{组件}.{ckpt|seg|wal|manifest}`（P14a）。详见
[`recovery-unified-checkpoint-design-zh.md`](recovery-unified-checkpoint-design-zh.md)。

**统一外壳**（除 manifest 与 bm25 段外）：`[Magic:u32 LE][Version:u32 LE]
[payload][CRC32(payload):u32 LE]`，`tmp + rename` 原子落盘。全部多字节整数小端。

### 10.1 kv.keydir.ckpt — keydir checkpoint（BCKS v1）

Magic `0x42434B53`（"BCKS"），Version 1。payload：

```
next_ord u64 | epoch u64 | biggest_file_id u32 | key_count u64 | key_bytes u64
fstats_n u32, 重复 fstats_n 次:
    file_idx u32 | live_keys u64 | total_keys u64 | live_bytes u64
    total_bytes u64 | oldest_tstamp u32 | newest_tstamp u32 | expiration_epoch u64
wm_n u32, 重复 wm_n 次:  file_id u32 | covered_offset u64   ← per-file 字节水位
entry_n u64, 重复 entry_n 次:
    klen u16 | key[klen] | file_id u32 | total_sz u32 | offset u64
    | epoch u64 | tstamp u32 | ord u64
```

`covered_offset` 是尾部回放的水位：open 装载快照后只 fold 各文件该偏移之后的
尾巴。来源 `cpp/src/keydir/keydir.cpp`（`save_snapshot`/`load_snapshot`）。

### 10.2 search.docmap.ckpt — 搜索文档目录 checkpoint（BCIS v1）

Magic `0x42434953`（"BCIS"），Version 1。payload：

```
covers_next_ord u64                 ← 保存时 keydir.next_ord（成对性门用）
rows u64, 重复 rows 次（每活索引文档一行）:
    ord u64 | klen u16 | ext[klen] | file_id u32 | offset u64
    | total_sz u32 | tstamp u32 | doc_len u32
```

把 bm25/hnsw 吐出的 ord 翻译回 key / 物理位置 / live / doc_len。与 keydir.ckpt
字段大量重叠（见 recovery 设计），但按 ord 而非 key 索引。来源
`cpp/src/search/search_layer.cpp`（`save_index_sidecar`/`load_index_sidecar`）。

### 10.3 search.vec.ckpt — HNSW 向量图 checkpoint（BCVS v1）

Magic `0x42435653`（"BCVS"），Version 1。payload：

```
dim u16 | metric u8 | M u32 | ef_construction u32 | seed u64
count u32 | entry_meta u64 | max_inserted_ord u64
重复 count 次（节点 id = 写出顺序 0..count-1）:
    ord u64 | level u8 | vec[dim] f32 小端
    重复 (level+1) 层:  cnt u32 | cnt×(neighbor_id u32)
```

不变量：邻居/entry id `< count`、ord 严格递增、layer-l 表只含 level≥l 的节点。
**注意**：即便内存为 int8-only（P5），盘上仍存 f32（save 反量化、load 再量化）。
来源 `cpp/src/vector/hnsw.cpp`（`save`/`load`）。

### 10.4 search.bm25.* — bm25 倒排索引

多字段：一个 `manifest` + 每字段一个 `.seg`（+ 运行期 `.wal`）。

- **search.bm25.manifest**（文本）：第一行 = 字段数；其后每行一个字段名
  （可能含控制字符前缀，如默认字段 `\x01default`）。
- **search.bm25.f\<i\>.seg**：第 i 个字段的倒排段（`InvertedIndex::save`）。
  标量字段 u32/u64 **小端**（原生 `fwrite`），postings 用 VByte gap 压缩 +
  block-max 元数据。逐字节布局随检索特性（BMW / zero-copy posting）演进，
  以源码为准：`cpp/src/bm25/inverted.cpp` + `doc/posting-zero-copy-design-zh.md`、
  `doc/kway-blockmax-bmw-zh.md`。
- **search.bm25.f\<i\>.wal**：`[Magic "WAL1"=0x57414C31:u32][Version=1:u32]` +
  增量记录（`add_doc`/`remove_doc`，VByte 编码）。load 快照后若 WAL 存在则重放、
  随后 truncate。来源 `cpp/src/bm25/inverted_wal.cpp`。

> 字节序例外回顾：bm25 倒排**位流**为 MSB-first 位级打包（`inverted.cpp`），
> 作为字节序列与主机字节序无关；VByte（§五）同样字节序中立。其余所有多字节
> 整数字段一律小端（§九）。