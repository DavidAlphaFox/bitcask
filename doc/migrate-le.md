# 大端 → 小端目录迁移（`migrate_le`）

English: [`migrate-le-en.md`](migrate-le-en.md)

把**旧的大端（big-endian）bitcask 目录**离线迁移成**新的小端（little-endian）
格式**的工具。

## 1. 背景：为什么需要迁移

bitcask 做过一次字节序 **flag-day**：盘上所有多字节整数从大端切到小端
（LE-only 主机原生零转换 + mmap 零拷贝友好；详见
[`format-zh.md` 字节序说明](format-zh.md)）。切换后：

- `bitcask.meta` 的 version 从 `1`（大端纪元）升到 `2`（小端）。
- 新代码打开旧大端目录时**当场拒绝**（不会静默把大端读成小端而损坏）：

  ```
  incompatible legacy big-endian format (meta v1);
  little-endian flag-day requires rebuild — re-ingest data
  ```

要把旧目录用起来,二选一:**① 从源头重灌数据(rebuild)**,或 **② 用本工具
离线迁移**(无源头数据 / 想保留现有库时)。

## 2. 构建

随 CMake 构建产出可执行 `migrate_le`：

```bash
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j --target migrate_le
# 产物：_build/cmake/cpp/migrate_le
```

## 3. 用法

```bash
migrate_le <src_dir> <dst_dir>
```

- **非破坏性**:只读 `src_dir`、只写 `dst_dir`(`dst_dir` 不存在会创建)。
- 迁移完成后,用新代码打开 `dst_dir`;确认无误再删除旧 `src_dir`。

示例：

```bash
$ _build/cmake/cpp/migrate_le ~/db/wiki ~/db/wiki.le
migrated /home/me/db/wiki -> /home/me/db/wiki.le
  data files     : 2
  records        : 12000 (tombstones 134)
  skipped badcrc : 0
  meta migrated  : yes
  field.schema   : yes
```

`skipped badcrc > 0` 会额外打印 WARNING——表示源目录有损坏 record 被跳过
(源数据本身的问题,非迁移引入)。

## 4. 迁移了什么 / 跳过了什么

| 文件 | 处理 |
|---|---|
| `<id>.bitcask.data` | 逐 record 解**大端**头 → 用小端 codec 重编码（CRC 重算） |
| `<id>.bitcask.hint` | 从迁移后的 data **重新生成**（trailer CRC 一致） |
| `bitcask.meta` | version `1→2`，`VecDim` u16 大端→小端，其余字段照搬 |
| `field.schema` | 每条 `NameLen` u16 大端→小端 |
| 墓碑 v2 shadow file_id | 4 字节大端值 → 重排成小端 |
| `kv.keydir.ckpt` / `search.*`（ckpt/seg/wal）/ 锁 | **不迁移**——可由 fold 重建,新库首开自动重建 |

> 可重建的 checkpoint / 索引文件**故意不迁移**:它们是派生缓存,新库第一次
> open 时从迁移后的 data 文件 fold 重建即可(见
> [`recovery-unified-checkpoint-design-zh.md`](recovery-unified-checkpoint-design-zh.md)）。

## 5. 验证迁移结果

```bash
# 用新代码打开 dst：能正常 open 且读到数据即成功（meta 已是 v2）。
# 例如经 rebar3 shell：
#   {ok, R} = bitcask:open("/home/me/db/wiki.le", [read_write]),
#   bitcask:get(R, <<"some-key">>).
```

`migrate_le` 已内置 round-trip 测试覆盖（`MigrateBEtoLE.RoundTrip`：构造大端
固件 → 迁移 → 小端读路径逐 record / hint / meta / shadow 校验）。

## 6. 注意事项

- **仅支持小端主机**(x86-64 / ARM64),与引擎本体一致。
- `migrate_le` 是引擎内**唯一仍读大端**的地方;它自带大端解码器,写侧复用
  小端 `DataFile`/`HintFile`,保证产物与新写入字节结构一致。
- 已是 v2(小端)的目录再迁移会**干净报错**(`src meta already v2`),不会
  重复迁移。
- 实现:[`cpp/include/bitcask/migrate.hpp`](../cpp/include/bitcask/migrate.hpp)
  (`migrate_be_to_le`) + `cpp/src/fileops/migrate.cpp` + CLI
  `cpp/tools/migrate_le.cpp`。
