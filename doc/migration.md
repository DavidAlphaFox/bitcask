# 特性状态与 API 参考

本文档描述了 bitcask 的当前特性集、完整 API 接口和操作特性。所有操作都通过 C++ NIF —— 不存在传统模式。

## 概述

C++23 NIF（`cask_cpp`）是唯一可用的模式。`bitcask_legacy.erl` 已被删除。所有 API 调用都路由到 `bitcask_cpp_nifs` → `priv/bitcask_cpp.so`。

- **KV 模式**（默认）：`open(Dir, [read_write])` — 纯键/值存储
- **索引模式**：`open(Dir, [read_write, {analyzer, ...}])` — 添加 BM25 全文检索；创建 `bitcask.meta` 文件并设置 `mode=kIndex`

两种模式共享相同的磁盘格式（带类型记录 `kDoc`/`kTombstone`）。

## API 参考

| Erlang API                    | C++ NIF            | 备注                                              |
|-------------------------------|--------------------|----------------------------------------------------|
| `bitcask:open/1,2`            | `cask_open/2`      | 返回资源引用                               |
| `bitcask:close/1`             | `cask_close/1`     | 释放写/合并锁                         |
| `bitcask:get/2`               | `cask_get/2`       |                                                    |
| `bitcask:put/3`               | `cask_put/3`       | `put(_, _, tombstone)`等价于`delete`               |
| `bitcask:delete/2`            | `cask_delete/2`    | 软删除（墓碑）                            |
| `bitcask:sync/1`              | `cask_sync/1`      | fsync 活动数据文件                             |
| `bitcask:search_text/2,3`     | `cask_search_text/3`| BM25 词袋模型；仅限索引模式               |
| `bitcask:search_phrase/2,3`   | `cask_search_phrase/3`| BM25 短语；仅限索引模式                     |
| `bitcask:fold/3,6`            | `cask_fold_start/3,4` + iterators | 三步迭代器（start/next/release）     |
| `bitcask:fold_keys/3,6`       | `cask_fold_start/3,4` + iterators | 返回 `#bitcask_entry` 记录          |
| `bitcask:list_keys/1`         | via `cask_fold_*`   | 收集键到列表                         |
| `bitcask:stream/1`            | via `cask_fold_*`  | 生产者/消费者流式迭代器              |
| `bitcask:next/1`              | via `cask_fold_*`  | 拉取下一条记录                                   |
| `bitcask:stop/1`              | via `cask_fold_*`  | 停止并释放流                           |
| `bitcask:with_stream/2`       | via `cask_fold_*`  | RAII 包装器                                      |
| `bitcask:merge/1,2,3`         | `cask_merge/2`     | 以 `merge_only` 模式打开 cask、合并、关闭           |
| `bitcask:needs_merge/1,2`     | `cask_needs_merge/1`| 返回 `{true, {Files, Expired}}` 或 `false`    |
| `bitcask:status/1`            | `cask_status/1`    | 返回 `{KeyCount, Files}`                       |
| `bitcask:is_empty_estimate/1` | `cask_is_empty/1`  | O(1) 估算                                      |
| `bitcask:is_frozen/1`         | `cask_is_frozen/1` | Keydir 冻结状态                               |
| `bitcask:close_write_file/1`  | `cask_close_write_file/1` | 释放写锁，保持句柄可用        |

## 选项

选项通过 `src/bitcask.erl` 中的 `?CASK_PASSTHROUGH_OPTS` 传递。无法识别的选项会被静默丢弃。

### 通用选项

| 选项                      | 默认值 | 描述                              |
|-----------------------------|---------|------------------------------------------|
| `read_write`                | `false` | 以写权限打开               |
| `{expiry_secs, N}`          | `0`     | get/fold 时过滤超过 N 秒的记录；同时触发合并 |
| `{max_file_size, B}`        | `2 GiB` | 活动文件在 B 字节处轮换        |
| `{sync_strategy, none}`     | (默认) | 无自动同步                           |
| `{sync_strategy, o_sync}`   | —       | 每次写入使用 O_SYNC                       |
| `{sync_strategy, {seconds, N}}` | —    | 调用者驱动同步                       |
| `{tombstone_version, V}`    | `0`     | `0` = `bitcask_tombstone`（17 B）；`2` = `bitcask_tombstone2`（22 B，支持并发控制） |

### 合并策略

| 选项                      | 默认值 | 描述                              |
|-----------------------------|---------|------------------------------------------|
| `frag_merge_trigger`        | `60`    | 触发合并的碎片化百分比   |
| `dead_bytes_merge_trigger`  | `512 MB`| 触发合并的死字节数              |
| `frag_threshold`            | `40`    | 单文件碎片化阈值          |
| `dead_bytes_threshold`      | `128 MB`| 单文件死字节阈值            |
| `small_file_threshold`      | `10 MB` | 文件总大小低于此值时包含   |
| `expiry_grace_time`         | —       | expiry_secs 之后的宽限期            |
| `max_merge_size`           | —       | 单次合并的最大总大小  |

### 索引模式（全文检索）

| 选项                      | 默认值 | 描述                              |
|-----------------------------|---------|------------------------------------------|
| `{analyzer, ngram\|jieba\|whitespace}` | `ngram` | 分析器类型；必须设置以启用搜索 |
| `{dict_path, binary()}`     | —       | jieba 字典路径（`jieba` 必需） |
| `{enable_stop_words, boolean()}` | `false` | 启用停用词过滤               |

## 操作说明

### 双锁模型

`bitcask:merge/1,2,3` 获取 `bitcask.merge.lock` —— **不** 是 `bitcask.write.lock`。活动的写入者继续并发运行。合并器读取写入者的锁文件以了解哪个文件 ID 是活动的，并将其从合并候选中排除。同一目录上的多个合并器仍然在 `merge.lock` 上串行化。

### 过期锁回收

如果之前的写入者进程在未释放 `bitcask.write.lock` 的情况下死亡，再次打开目录会成功：`Cask::open` 读取锁内容，检查 `kill(pid, 0)`，如果返回 `ESRCH` 则取消链接该文件。空格式错误的锁文件也被视为过期。

### 撕裂写入尾部恢复

在记录中间崩溃后以写入者身份打开目录，会将最后一个数据文件的尾部修剪到最后成功解码的记录。只读打开保持文件不变。不再有"永远跳过 CRC 错误并吃掉磁盘"的行为。

### 合并内联删除旧文件

Cask 的合并会取消链接已合并文件的 `.data` 和 `.hint` 文件，并调用 `keydir_->trim_fstats()`，使文件统计状态表保持干净。没有单独的延迟删除进程。

## 后续规划

完整的路线图见 `TASK.md`。

已完成的里程碑：统一架构（U0–U6）、BM25 倒排索引（S1–S10）、HNSW 向量检索（V3）、int8 量化 + VNNI（V4）、元数据过滤（V5）、热路径零拷贝（V6.1）、WAL 批量 flush（V6.2）。

待实现：V6.3 内存与格式体积优化（sorted vocab + TF/FOR 量化）、V6.4 格式预留、V6.5 通配符 trie/FST。

## 部署

1. 使用 `rebar3 compile` 构建 —— C++ NIF 是唯一选项。
2. 运行现有测试 —— 磁盘格式未改变；现有数据可原样读取。
3. 监控 `bitcask:status/1`、`bitcask:needs_merge/1` 和 `bitcask.write.lock` 内容。
4. 要启用全文检索，使用 `{analyzer, ngram}` 打开（对于中文使用 `{dict_path, Path}` 的 `jieba`）。

## 常见错误

| 返回值                       | 原因                                   | 修复方法                                     |
|------------------------------|-----------------------------------------|----------------------------------------|
| `{error, write_locked}`      | 活动写入者持有锁              | 关闭之前的 cask，或选择另一个目录 |
| `not_found`                  | 键从未存在 / 已删除 / 已过期   | 正常                                 |
| `{error, bad_crc}`           | 读取时磁盘损坏                 | 从备份恢复；合并会跳过这些 |
| `{error, key_too_large}`     | 键 > 65 535 字节                      | 格式限制；不可配置          |
| `{error, value_too_large}`    | 值 > 4 GiB                           | 格式限制                            |
| `{error, no_index}`          | 在 KV 模式 cask 上调用搜索           | 使用 `{analyzer, ...}` 重新打开          |
| `{error, merge_locked}`      | 另一个合并器已在运行          | 等待它完成                   |

## 过期

超过 `expiry_secs` 秒的记录对 `get`/`list_keys`/`fold` 不可见。一旦超过 `now - (expiry_secs + expiry_grace_time)`，它们也是过期触发合并的候选。

```erlang
1> R = bitcask:open(Dir, [read_write, {expiry_secs, 60}]).
2> bitcask:put(R, <<"k">>, <<"v">>).
3> timer:sleep(61000).
4> bitcask:get(R, <<"k">>).           not_found
```

## 崩溃恢复

如果写入者进程崩溃并留下 `bitcask.write.lock`，下一个 `open(Dir, [read_write])` 会检查记录的 PID 是否仍然存活。如果不存活（或锁文件为空/格式错误），过期的锁会被取消链接，打开操作会成功。

```erlang
%% 进程 A 写入，然后崩溃：
1> R = bitcask:open("/tmp/db", [read_write]).

%% 进程 B 重新打开 —— 过期锁被回收：
2> R2 = bitcask:open("/tmp/db", [read_write]).
#Ref<...>   % 成功
```