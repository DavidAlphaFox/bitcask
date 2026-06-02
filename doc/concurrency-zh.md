# Bitcask 并发与共享语义

本文说明同时打开同一个 bitcask 目录时的行为，包含两个层面：

1. **跨 OS 进程**的隔离与冲突——靠文件锁
2. **同 BEAM 内**的共享与协调——靠 `KeyDirRegistry`

源码导航：

- 锁实现：`cpp/include/bitcask/file_lock.hpp` / `cpp/src/lock/file_lock.cpp`
- 注册表：`cpp/include/bitcask/keydir_registry.hpp` /
  `cpp/src/keydir/keydir_registry.cpp`
- open 路径：`cpp/src/cask/cask.cpp::Cask::open`

---

## 1. 三种 open 模式

| 选项 | 语义 | 拿什么锁 |
|---|---|---|
| `[]`                       | 只读                       | 不拿锁           |
| `[read_write]`             | 写者                       | `bitcask.write.lock` |
| `[merge_only, ...]`（内部用）| 合并器（不在常规 API 暴露）  | `bitcask.merge.lock` |

锁文件用 `O_CREAT|O_EXCL` 实现互斥（不是 POSIX flock 也不是 fcntl
锁），跨 OS 进程有效。详细语义见 [`format-zh.md` §5](format-zh.md)。

---

## 2. 同 BEAM 内：共享 KeyDir

**结论先行**：同一个 BEAM 进程里，多次 `bitcask:open(Dir, _)` 共享
**同一个**内存 KeyDir。第一个 open 付扫盘代价，后续全部 refcount + 直接
拿 `shared_ptr`。

### 代码路径

`Cask::open` 中关键片段：

```cpp
if (registry != nullptr) {                         // ← NIF 总是传 &priv->registry
    auto a = registry->acquire(cask->keydir_name_);
    cask->keydir_ = a.keydir;                      // ← 拿到 shared_ptr
    if (a.status == keydir::AcquireStatus::kCreated) {
        // ★ 只有第一个开它的人才进这条分支
        if (auto r = cask->load_keydir_from_disk(); !r) return std::unexpected(r.error());
        cask->keydir_->mark_ready();
    }
}
```

`KeyDirRegistry::acquire`：

```cpp
auto it = entries_.find(key);                      // key = dirname 字符串
if (it != entries_.end()) {
    if (!it->second.keydir->is_ready()) {
        return {kNotReady, nullptr};               // 别人正在初始化，等
    }
    it->second.refcount += 1;                      // ← 共享！只 +1 计数
    return {kReady, it->second.keydir};
}
auto kd = std::make_shared<KeyDir>();
entries_.emplace(key, Slot{kd, 1});
return {kCreated, kd};                             // ← 这个 caller 负责扫盘
```

### 三种 acquire 状态

| acquire 返回 | 触发条件                       | 该 caller 干什么                                     |
|---|---|---|
| `kCreated`  | name 在 registry 里不存在       | 必须 `load_keydir_from_disk` 扫盘建索引，然后 `mark_ready` |
| `kReady`    | name 已存在且就绪                | 直接拿 shared_ptr，refcount +1，不扫盘               |
| `kNotReady` | name 已存在但还在被别人初始化     | 50 ms 间隔轮询 40 次，最多等 2 秒                     |

> 关键：「第一个开的」是谁不重要——可能是 writer 也可能是 reader。
> 谁先到谁付扫盘成本，后到的全部白嫖。

### 行为示例

```erlang
%% T0：BEAM 启动后第一次 open
R1 = bitcask:open("/data/db", []).
%% → acquire 返回 kCreated
%% → load_keydir_from_disk 扫所有 .bitcask.data + hint
%% → mark_ready
%% → registry: {"/data/db" → {kd_ptr, refcount=1}}

%% T1：第二个 open（读或写都行）
W = bitcask:open("/data/db", [read_write]).
%% → acquire 返回 kReady
%% → 不扫盘，秒返回
%% → registry: {"/data/db" → {kd_ptr, refcount=2}}

%% T2：再来 N 个 reader
R2 = bitcask:open("/data/db", []).  %% refcount=3
R3 = bitcask:open("/data/db", []).  %% refcount=4

%% T3：W 写入
ok = bitcask:put(W, <<"k">>, <<"v">>).
%% → keydir_->put 拿 unique_lock，写到唯一的 KeyDir 实例
%% → 所有 reader 立刻可见

%% T4：R2 读
{ok, <<"v">>} = bitcask:get(R2, <<"k">>).  %% ✅ 看见 W 刚写的
```

四个 Ref 共享：

- 同一个 `shared_ptr<KeyDir>`
- 同一个 `entries_` 哈希表
- 同一个 `fstats_` 文件统计
- 同一把 `std::shared_mutex`

### 关闭与持久化

```erlang
bitcask:close(R1).  %% refcount 4 → 3，shared_ptr 还活着
bitcask:close(R2).  %% 3 → 2
bitcask:close(R3).  %% 2 → 1
bitcask:close(W).   %% 1 → 0
%% ★ 此时 KeyDir 才真正析构
%% ★ saved_biggest_file_id_ 记下 biggest_file_id + 1
```

下次任何 open 又会扫盘，但 `biggest_file_id` 从持久化值起步——保证
file_id 跨 open/close 永不回退。这是为了避免「老 file_id 被 keydir
当成新 entry」的灾难，见 `keydir_registry.cpp::release`。

### name 不规范化的小坑

`name` 是原样字符串比较，**没有 canonicalize**：

```erlang
bitcask:open("/data/db",  []).   %% slot key = "/data/db"
bitcask:open("/data/db/", []).   %% slot key = "/data/db/"  ← 不同！
```

会建两个独立的 KeyDir，两次扫盘，互相看不到对方的写入。跟 legacy
行为一致，调用方需要自己保证路径字符串规范化。

---

## 3. 跨 OS 进程：能开但语义弱

不同 OS 进程（比如两个 BEAM 实例，或 BEAM + 命令行工具）：

```
进程 A: bitcask:open(Dir, [read_write])  → 拿 bitcask.write.lock
进程 B: bitcask:open(Dir, [])            → ✅ 不拿锁，open 成功
进程 C: bitcask:open(Dir, [])            → ✅ 同上
```

- **拿锁**：write.lock 是 OS 级 `O_CREAT|O_EXCL`，跨进程 enforce「最多
  一个 writer」；只读 open 不拿锁，不冲突。
- **内存独立**：每个 OS 进程有独立的 `priv_data->registry`、独立的
  KeyDir。reader 进程在 open 时 `load_keydir_from_disk` 自己扫一遍，得
  到一个**快照**——之后 writer 进程的 put 这个 reader **看不见**。
- **reader 怎么看到新数据**：必须 close + reopen 重新扫盘。对大目录
  （百万 key 级别）每次几百 ms 到几秒，不实用。

跨进程「带快照」的只读 open 适合做：

- 离线备份 / 导出
- 一致性快照分析
- 命令行工具临时查询

不适合做「实时 read replica」——bitcask 不是为这个设计的。

---

## 4. 写写冲突的行为

第二个 writer 试图 open：

```erlang
W1 = bitcask:open(Dir, [read_write]).         %% ok，拿到锁
W2 = bitcask:open(Dir, [read_write]).         %% {error, write_locked}
```

返回 `{error, write_locked}`——来自 `O_CREAT|O_EXCL` 的 `EEXIST`，被
`Cask::open` 翻译成 `kWriteLocked`。

但**如果 W1 进程 crash 了**锁文件还在磁盘上：W2 open 时会读 lock 内容
拿到 W1 的 pid，调 `kill(pid, 0)` 探活，发现 `ESRCH` → unlink stale lock
→ 重试 acquire → 成功。这是 cask.cpp 里的 `try_remove_stale_lock`。

竞态窗口：从读 pid 到 unlink 之间另一个 writer 可能写了新锁，我们会
误删他的。legacy 也有同样的 race，实际暴露面极小，只发生在 crash
recovery 路径。

---

## 5. merger 是个特例

merger 用 `merge_only` 选项 open（内部由 `bitcask:merge/N` 触发，不是
对外 API），拿的是 `bitcask.merge.lock`（独立锁），**不阻塞 writer**：

```erlang
%% bitcask:merge/1 内部就这么干：
{ok, M} = bitcask_cpp_nifs:cask_open(Dir, [merge_only | Opts]),
%% 跟 W1 完全并行跑
```

所以稳态可以是：**1 writer + 1 merger + N readers** 同时活跃，互不
阻塞。这是 bitcask 跑生产负载的标准并发栈。

### merge 对读写的影响（正确性 vs 性能）

merge 设计成**对读写无阻塞**，靠的不是锁、而是 keydir 分片锁 + CAS + 文件
生命周期管理：

| 路径 | 影响 | 为什么安全 |
|------|------|-----------|
| **写** | 不阻塞 | merge 不抢 `write.lock`；并发改同一 key → merge 的 CAS（带 old_file_id/offset）失败、writer 赢，merge 拷贝沦为死字节下轮再清；writer 发现 `biggest_file_id` 被 merger 推进就 `roll_active` 到更大 id。无写丢失。 |
| **点 get** | 不阻塞 | merge「先写新文件 + CAS keydir、**最后**才 unlink 旧文件」；单次 `cask_get` NIF 从 keydir.get 到 pread 不让出线程，要读到被删文件得被 OS 抢占跨越整个 merge——实践可忽略。 |
| **fold** | 不阻塞（**S13** 修复） | 见下。 |

**fold 的文件句柄快照（S13）**：fold 跨越多次 `fold_next` NIF、墙钟时间长，
是真正可能撞上 merge unlink 的路径。keydir 的 epoch/frozen 只钉「key 修订快照」
（fold 看到稳定 key 集），**不钉 data file**（keydir 无文件级 refcount），且 merge
两侧都不 gate 在 frozen。所以 `CaskIter` 在 **start 时 pin 一份「目录下全部非
active data 文件」的只读句柄快照**：

- `next()` 优先从 pin 的句柄 pread；merge 即便 unlink 了旧文件，已 open 的 fd
  让 inode 在 Linux 上存活，fold 照常读到。
- `release()` 时才关掉这些 fd——被 fold pin 住的旧文件，磁盘空间要等 fold 结束
  才真正回收。
- 代价：每个并发 fold 占用「文件数」量级的 fd（与 legacy riak bitcask 的
  readable_files 快照一致，fold 本就重）。

> 这一层修复前是个真实 bug：fold 走共享 `read_file` 缓存读 value，merge 无条件
> unlink，长 fold 会因旧文件消失而中途报 `{error,_}`。

**性能影响才是 merge 的真实代价**（不是阻塞）：

- merge 回读旧文件 + 写新文件，跟正常读写**抢磁盘 IO / CPU**。
- **索引模式下最重**：每次 merge 后**同步**全量 `rebuild_index`（回读所有 live
  文档、重新分词、建全新 InvertedIndex）+ `save_snapshot`。纯 KV 无此项。
- `cask_merge` 挂 `ERL_NIF_DIRTY_JOB_IO_BOUND`，在 dirty 调度器跑，**不卡 BEAM
  主调度线程**，其它进程的读写照常被调度。

---

## 6. 索引模式（SearchLayer）的并发

索引模式（`open(Dir, [read_write, {analyzer, ...}])`）在 Cask 内部创建
一个 `SearchLayer` 实例，用于 BM25 全文搜索。

### SearchLayer 线程模型

`SearchLayer` **不是线程安全的**：内部 `InvertedIndex` 使用 16 个分片
锁（按 term hash 分桶），但 `SearchLayer` 自身要求单写者模型。

这与 KV 层的并发模型**不冲突**：

| 组件            | 线程安全？ | 并发要求                                      |
|---|---|---|
| KeyDir          | ✅ 是      | `unique_lock` 串行写，shared_lock 并发读      |
| SearchLayer    | ❌ 否      | 单写者（由 `Cask::put` 在同一写线程里调用）     |
| InvertedIndex  | ✅ 是      | 内部 16 分片锁，搜索可并发                     |

### InvertedIndex 分片锁

`InvertedIndex` 内部按 term hash 分 16 个 shard（`std::mutex` 数组），
搜索时对命中的 shard 加 `shared_lock` 并发查。这让多个 `search_text`
调用可以并行——每个调用只锁自己命中的分片，不锁整个索引。

### 与 KV 层的关系

索引模式的 SearchLayer 不改变 KeyDir 的共享语义——同一个目录的多个
`bitcask:open` 仍共享 KeyDir；SearchLayer 作为 `Cask` 的成员只在
`put/delete` 路径上被调用，不影响 reader 的并发读。

---

## 7. 总结表

### 跨 OS 进程

| 角色            | 锁文件               | 数量上限      | 备注                     |
|---|---|---|---|
| writer          | `bitcask.write.lock` | 1 / 目录      | 跨进程 enforce            |
| merger          | `bitcask.merge.lock` | 1 / 目录      | 跟 writer 并行            |
| reader          | 无                   | ∞             | 各 BEAM 各快照，open 后不更新 |

### 同 BEAM 内（最常用）

| 角色   | 共享 KeyDir？ | 锁层并发    | 看到 live 数据？ |
|---|---|---|---|
| writer | ✅ shared    | 拿 unique_lock 串行写 | n/a |
| merger | ✅ shared    | 内部走自己的 NIF 分支 | ✅ |
| reader | ✅ shared    | 拿 shared_lock 并发读 | ✅ 立即可见 |

---

## 8. 部署模型推荐

**典型 Riak 风格部署**：一个 OS 节点一个 BEAM，BEAM 内一个 bitcask
实例服务无数 Erlang 进程的并发读写。配置上：

- writer 进程：`bitcask:open(Dir, [read_write])`，作为 owner 持有
- N 个 reader 进程：`bitcask:open(Dir, [])`
- 应用层用 `bitcask_merge_worker` 或 cron 触发周期 `bitcask:merge(Dir)`

运行期间：

- 全部 reader 看到的都是最新写入（KeyDir 共享 + shared_mutex）
- 单写者无并发写竞争
- merge 跟 writer 并行不阻塞（独立 merge.lock）
- BEAM 重启 → 第一个开的 process 付扫盘代价 → 之后全部 refcount

**不推荐的反模式**：

- 多个 BEAM 实例同时打开同一个 dir 都想做实时读——reader 看不到对方
  writer 的更新；如果非要这么做请用 RPC 或者把 bitcask 包成 gen_server
  做单点写入路由
- 在 NFS / 网络盘上跑——`O_EXCL` 在 NFS 上有历史 bug
- 频繁 open + close 同一个 dir——每次 open 可能触发扫盘（如果 refcount
  归零过），大目录代价高
