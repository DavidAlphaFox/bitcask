# Bitcask 存储格式

本文档是 C++ 实现读写的字节级规范，跟 legacy C NIF 写出来的目录字节级
互通。权威来源：

- 常量定义：`cpp/include/bitcask/format.hpp`
- 编解码：`cpp/src/fileops/codec.cpp`
- 文件抽象：`cpp/include/bitcask/data_file.hpp` / `hint_file.hpp`

所有多字节整数都是**大端**存储，字段大小单位均为字节。

---

## 一、目录结构

一个 bitcask 实例就是一个普通目录：

```
<dir>/
├── <tstamp1>.bitcask.data   # data 文件（append-only 主存储）
├── <tstamp1>.bitcask.hint   # 对应 hint 文件（可选，加速重建）
├── <tstamp2>.bitcask.data
├── <tstamp2>.bitcask.hint
├── ...
├── bitcask.write.lock       # 写锁（writer 持有）
└── bitcask.merge.lock       # 合并锁（merger 持有）
```

`<tstamp>` 不是 wall-clock 时间戳，而是 keydir 全局单调递增的 file_id
（uint32 范围内使用）。`KeyDirRegistry::saved_biggest_file_id` 保证跨
open/close 永不复用 file_id——避免「老 file_id 被 keydir 当成新 entry」
的灾难。目录扫描按 tstamp 升序遍历。

---

## 二、data 文件格式

append-only 的 record 序列，文件本身没有 header，record 之间无 padding。

每条 record 大端编码：

```
偏移   字段       字节数   说明
─────────────────────────────────────────
0      CRC32      4       覆盖 Tstamp..Value（zlib 多项式，跟 erlang:crc32 一致）
4      Tstamp     4       wall-clock 秒
8      KeySz      2       key 字节数（最大 65535）
10     ValueSz    4       value 字节数（最大 ~4 GiB）
14     Key        KeySz
14+KeySz  Value   ValueSz
```

整条 record 长度 = `14 + KeySz + ValueSz`，header 固定 14 字节。

字段语义：

| 字段       | 宽度 | 含义                                            |
|------------|----|------------------------------------------------|
| `crc`      | 4 B  | CRC-32 (zlib) 覆盖 `tstamp..value`                |
| `tstamp`   | 4 B  | 写入时刻的 Unix 秒                                  |
| `key_sz`   | 2 B  | key 字节数，必须 ≤ 65535                            |
| `value_sz` | 4 B  | value 字节数                                       |
| `key`      | var  | 任意字节，允许包含 NUL                               |
| `value`    | var  | 任意字节；墓碑也走普通 record（见下）                  |

**关键点**：
- CRC 在最前面方便流式校验，但只覆盖它自身之后的字节
- 大端跟 Erlang `<<X:N>>` 默认行为一致，跟 legacy NIF 互通必要
- 删除不是物理操作——而是写一条 value 是「墓碑标记」的 record（见下文）

最大尺寸由 `format::kMaxKeySize` / `kMaxValueSize` 定义。`total_size`
超过 `kMaxValueSize + 14 + kMaxKeySize` 的读取会被拒为 `kTooLarge`。

---

## 三、墓碑值（写在 data record 的 VALUE 段）

删除 = 写一条 value 是墓碑前缀的 record。三种格式并存：

| 版本 | 内容                                              | 大小  | 用途                |
|----|----|----|----|
| v0 | `"bitcask_tombstone"`                            | 17 B | legacy 默认；最简    |
| v1 | `"bitcask_tombstone1"` + `FileId32` (BE)         | 22 B | 仅识别，不再写       |
| v2 | `"bitcask_tombstone2"` + `FileId32` (BE)         | 22 B | 当前 cask 默认       |

判别只看 17 字节前缀 `"bitcask_tombstone"`，对三种一视同仁
（`format::is_tombstone_value`）。

**v1/v2 的 shadow file_id 是关键**：merger 在合并某文件时遇到墓碑会
校验「shadow 指向的原 file_id 是否还存在」，仍存在才能放心丢掉对应
活 entry——避免 race 中误删并发 put 写下的新值。

C++ writer 默认写 v0；通过 `CaskOptions::tombstone_version = 2`
（Erlang opt：`{tombstone_version, 2}`）切换到 v2。读取方接受所有
三种版本。

---

## 四、hint 文件格式

data 文件的并行索引，**不带 value**，用于加速 open 时的 keydir 重建
（避免读全部 value 字节）。

每条 hint record：

```
偏移   字段              字节数   说明
─────────────────────────────────────────────
0      Tstamp           4       同 data record 的 tstamp
4      KeySz            2
6      TotalSz          4       data record 整条的字节数（含 14B header）
10     Tomb|Offset      8       最高位 = 墓碑标志，低 63 位 = data 文件内偏移
18     Key              KeySz
```

整条长度 = `18 + KeySz`，header 固定 18 字节。

**packed offset 字段**（位置 10..17 的 8 字节大端 uint64）：

```
位 63       位 62..0
[Tomb:1] [Offset:63]
```

- `Tomb=1` 表示这是墓碑 hint（对应的 data record 是一条 delete）
- `Offset` 上限 `0x7FFF_FFFF_FFFF_FFFF` (`kMaxOffsetV2`，约 8 EiB，远超
  任何实际 data 文件大小)

注意：墓碑标志在 **offset 字段的最高位**，**不是** tstamp 字段。

### EOF sentinel record

hint 文件末尾必须有一条特殊 record 作为「封口」，**布局跟普通 hint
record 完全一致**，但字段值特殊化：

```
Tstamp   = 0
KeySz    = 0
TotalSz  = 整文件 running CRC32（trailer CRC，借用此字段存）
Tomb     = 0
Offset   = kMaxOffsetV2 (= 2^63 - 1)
（无 key payload）
```

整条 sentinel 长度固定 18 字节（KeySz=0 所以无 key payload）。

读取方靠 `(KeySz == 0 && Offset == kMaxOffsetV2)` 识别 sentinel
（`codec::is_hint_eof`）。

`HintFile::validate_trailer()` 用 sentinel 里的 CRC 跟前面所有字节流式
重算的 CRC 比对——不通过就 fallback 到 `fold(data)` 重建 keydir。

---

## 五、锁文件

两个独立的 advisory 锁文件，用 `O_CREAT|O_EXCL` 原子性 + 释放时 `unlink`
实现互斥（不是 POSIX flock 也不是 fcntl 锁）：

| 文件 | 持有者 | 互斥关系 |
|----|----|----|
| `bitcask.write.lock` | 写者 | 同目录同时只允许一个 writer |
| `bitcask.merge.lock` | merger | 同目录同时只允许一个 merger；**不阻塞 writer** |

两把锁分开设计是为了让周期性 merge 跟主 writer 并行——merger 拿
`merge.lock`、writer 拿 `write.lock`，互不冲突。

### 锁文件内容格式

```
<pid> <active_data_file_path>\n
```

或者锁刚拿到、active 文件还没建好时只有：

```
<pid>\n
```

merger 在 open 时读 `write.lock`，把 live writer 的 active file_id 抠
出来，从 needs_merge 候选里排除——不能合并别人正在写的文件。

### Stale-lock 回收

crash recovery 路径上：acquire 拿到 `EEXIST` 时会读现有锁文件、
`kill(pid, 0)` 探测原持有进程是否还活着；死了就 `unlink` 接管。

代码：`cpp/src/cask/cask.cpp` 的 `try_remove_stale_lock` + `process_alive`。

竞态窗口：从读 pid 到 unlink 之间另一个 writer 可能写了新锁——我们会
误删他的。legacy 也有同样的 race，实际暴露面极小，只发生在 crash
recovery 路径。

NFS 上不可靠（`O_EXCL` 在 NFS 上有历史 bug），bitcask 本来也不该跑在
网络盘上。

---

## 六、读写流程对照

**put(K, V)**：
1. encode 一条 data record → pwrite 到 active data 文件末尾
2. encode 一条 hint record → write 到 active hint 文件
3. 更新 keydir：`K → (active_file_id, offset, total_size, tstamp)`

**get(K)**：
1. keydir 查到 `(file_id, offset, total_size)`
2. 按 file_id 找到对应 data 文件 → `pread(offset, total_size)` 一次磁盘
3. CRC 校验；是墓碑则当 not_found，否则返回 value

**delete(K)**：
1. encode 一条墓碑 data record + 一条 tombstone hint
2. keydir 把 K 标记为墓碑

**open**（重建 keydir）：
1. `scan_dir` 列出所有 `<tstamp>.bitcask.data`，按 tstamp 升序
2. 对每个文件：
   - 优先 `fold(hint_file)` + `validate_trailer()`——只读 key + 元数据
   - hint 缺失或 CRC 不通过 → fallback 到 `fold(data_file)` 全量扫
3. 后写入的 entry 自动覆盖前面的（因为按 tstamp 升序）
4. 三步恢复：stale-lock 回收、torn-write 尾部修剪、hint 校验

**merge**：
1. 拿 `merge.lock`（不影响 writer）
2. 读 `write.lock` 排除 live writer 的 active 文件
3. `needs_merge` 按 frag/dead_bytes/expiry 阈值挑候选
4. `run_merge`：扫候选文件，活的 record（keydir 仍指向它的）复制到新输出
5. CAS 更新 keydir → unlink 旧文件

---

## 七、open 时的恢复路径

`Cask::open` 在返回前会做三件恢复工作：

1. **Stale lock 回收**（如上）。
2. **Torn-write 尾部修剪**：`DataFile::fold` 会回填「最后一条成功解码
   record 的末尾偏移」到 `out_last_valid_end`。如果文件比这个值长 **且**
   当前 cask 是 writer (`read_write && !merge_only`)，就 `truncate_to`
   截掉无法解析的尾部字节——典型场景是 writer 写到一半 crash。
   merge_only 模式不能这么干：万一 live writer 还在文件后面追写，
   截断会切掉别人的数据。
3. **Hint 校验**：如果 hint 存在但 trailer CRC 不通过，忽略 hint，
   从 data 文件全量重建 keydir。

只读 open 永远不会修改目录。

---

## 八、磁盘契约的硬约束

这些数字改了就破坏向后兼容（M0 阶段在 `cpp/tests/codec_test.cpp`
有跟 legacy 字节级 fixture 的对账）：

- **大端**编码（不可能跨平台传输 native，所以这是永久契约）
- header 长度：data = 14 字节、hint = 18 字节
- CRC 多项式 = zlib（IEEE 802.3）
- 墓碑前缀 = `"bitcask_tombstone"`（17 字节）
- offset 最高位用作 tombstone bit（offset 限于 63 位）

源码中所有这些常量集中在 `cpp/include/bitcask/format.hpp`，是这套
格式的唯一权威来源（M6 之后 legacy `bitcask.hrl` 里的定义已删）。
