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

### file_id 分配：writer 与 merger 各写各的文件

merge 期间「正在写新文件」的有两方，但写的是**不同文件、不同句柄**，不共享：

- **writer** 的 `put` append 到自己的 active 文件（`active_data_`）。
- **merger** 的 `run_merge` 新建自己的输出文件（`out_data`，`kCreate`）。

file_id 由 keydir 的**单调计数器** `increment_file_id()` 统一分配（`biggest_file_id_ += 1`，
writer 的 `ensure_active_writer` 与 merger 共用它）。文件名里的 `<tstamp>` 字段存的就是
这个计数器值，**不是墙钟时间**。

典型时序（当前 biggest = N，writer active = N）：

```
① merger 开 run_merge → increment_file_id() → N+1，输出写到 N+1
② writer 下次 put 发现 active(N) < biggest(N+1)
   → roll_active → increment_file_id() → N+2，新 active = N+2
```

所以「merger 写 N+1、writer 写 N+2」在「merger 先分配」的时序下成立，且字面连号。
但**具体谁拿 N+1 取决于谁先调** `increment_file_id`；真正保证的不变量是：

> **writer 的 active file_id 永远被顶到 merger 输出之上。**

机制：writer 每次 put 前查 `biggest_file_id()`，发现被 merger 推进了就主动
`roll_active` 到 ≥ biggest（`cask.cpp` put 路径）。这条不变量是正确性的核心——keydir
用 **file_id 大小判 newest/staleness**：merger 搬的是旧数据快照（语义更旧，必须更小
id），writer 的新写必须更大 id，于是并发改同一 key 时 writer 的值（大 id）天然胜出，
merger 搬进 N+1 的那份被判 stale、沦为死字节下轮清。若 writer 误写进 ≤ merger 的 id，
keydir 会当 merge-race 拒掉（`kAlreadyExists`）→ 由主动 roll + put 后的 roll-retry 兜住，
不会 silent drop。

---

## 6. 索引模式（SearchLayer）的并发

索引模式（`open(Dir, [read_write, {analyzer, ...}])`）在 Cask 内部创建
一个 `SearchLayer` 实例（BM25 全文索引 + 可选 HNSW 向量索引），外加一个
**单 worker 线程的 `IndexPool`**（`cpp/include/bitcask/thread_pool.hpp`）。

### 写路径其实是异步单写者

索引的「单写者」**不是** `Cask::put` 的调用线程，而是 IndexPool 的那一个
worker 线程：

```
put/delete (调用方写线程)
   └─ submit_index_task → IndexPool 有界队列（capacity 10240，满则 push 阻塞做背压）
        └─ worker 线程串行执行 on_write / on_delete / on_vector
                                  / Index::set_meta / InvertedIndex::add_doc
```

所以所有索引结构的变更都在这一个 worker 线程上串行发生——写-写竞态天然
不存在。调用线程只负责入队。

### 读路径与 worker 并发

搜索（`search_text` / `search_vector` / `search_hybrid`）在**调用线程**上跑
（NIF，可能落在 dirty 调度器），与 worker 线程**并发**。`prepare_search`
先 `flush()` 排空在途任务再搜，但搜索进行中新来的 `put` 仍会让 worker
并发改索引。因此读路径必须对「与 worker 并发」鲁棒。

| 组件            | 线程安全？ | 并发要求                                      |
|---|---|---|
| KeyDir          | ✅ 是      | 分片锁串行写，并发读（见 §2、§下方锁全序图）   |
| SearchLayer    | ⚠️ 半     | 写经 IndexPool 单 worker 串行；读可与之并发    |
| InvertedIndex  | ✅ 是      | 内部分片锁 + tbb 桶锁 + CoW，搜索可并发        |
| Index（meta/live） | ✅ 是   | `shared_mutex`，读拷贝出值后再用              |
| SearchCache    | ✅ 是      | `shared_mutex`，读拷贝结果集后返回            |
| HnswIndex      | ✅ 是      | per-node 自旋锁 + `atomic<shared_ptr>` 快照   |

### 读路径安全不变量（2026-06 并发审计加固）

读路径与 worker 并发，下列不变量是正确性的关键——**违反任一条都是真实
的 use-after-free 或数据竞态**：

1. **`Index::meta_blob` 锁内拷贝返回**，不返回指向内部存储的 `span`。否则
   搜索侧 filter 求值时，worker 的 `set_meta` 重分配该 vector → 悬垂读。
2. **`SearchCache::get` 锁内拷贝结果集返回**，不逃逸指针。命中条目被并发
   `put`/淘汰时不悬垂。
3. **`InvertedIndex::save` 用 key 快照 + `const_accessor` 安全遍历**，不裸
   遍历 `tbb::concurrent_hash_map`。merge 线程落快照与 worker 的 `add_doc`
   并发，裸遍历会撞懒 rehash 重访/漏访、裸读会撞 CoW 替换撕裂。
4. **跨线程标量一律原子**：`InvertedIndex::max_indexed_ord_`（worker 写、
   搜索读）用 `std::atomic`；`SearchCache::last_used` 全程经 `atomic_ref`
   访问（混用 atomic_ref 与普通访问同一对象是 UB）。
5. **IndexPool 消费者 `try/catch` 兜底**：索引回调抛异常不杀 worker、也不
   让搜索路径每次都走的 `flush()` 因 `pending_` 不归零而永久挂起；失败按
   best-effort 丢弃本次更新。

### merge 与索引重建

merge 在 dirty 调度器线程上跑，merge 末尾 `rebuild_index` + `save_snapshot`
与 worker、读路径并发。安全靠：先 `flush()` 排空 worker，再重建/落盘；落盘
遍历走上面不变量 3 的安全路径；HNSW 重建提交给 worker 执行（维持单写者），
`flush()` 等其完成后才拍快照（旧图被 in-flight reader 的 `shared_ptr` 续命）。

### 与 KV 层的关系

索引模式不改变 KeyDir 的共享语义——同一目录的多个 `bitcask:open` 仍共享
KeyDir；SearchLayer 作为 `Cask` 成员只在 `put/delete`（入队）与搜索路径上
被触碰，不影响 reader 对 KV 的并发读。

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

---

## 锁全局序图（2026 重构补全）

本文档 2026 年重构补全完整的锁层级体系，包括所有模块的互斥锁声明、全局锁序规则、死锁防护机制及关键竞态窗口分析。

### 1. 完整锁层级表

| 模块 | 锁名称 | 类型 | 声明位置 | 说明 |
|------|--------|------|----------|------|
| **KeyDir** | barrier_mu_ | std::mutex | cpp/include/bitcask/keydir.hpp:384 | 屏障间互斥，跨整个屏障持有 |
| **KeyDir** | gate_mu_ | std::mutex | cpp/include/bitcask/keydir.hpp:385 | 写者退避等待的 cv 配套锁 |
| **KeyDir** | gate_cv_ | std::condition_variable | cpp/include/bitcask/keydir.hpp:386 | 写者退避等待的条件变量 |
| **KeyDir** | meta_mu_ | std::shared_mutex | cpp/include/bitcask/keydir.hpp:368 | pending_/iter 协调状态专用（仅 fold 期间触碰） |
| **KeyDir** | shard[i].mu | std::mutex ×256 | cpp/include/bitcask/keydir.hpp:361 | 分片锁（kShards=256），任意时刻至多持 1 把 |
| **KeyDir** | fstats_grow_mu_ | std::mutex | cpp/include/bitcask/keydir.hpp:419 | 仅新 file_id 槽位构造（罕见） |
| **Cask** | read_cache_mu_ | std::shared_mutex | (未在 keydir 中) | 独立，不与 KeyDir 或 SearchLayer 锁嵌套 |
| **KeyDirRegistry** | mutex_ | std::mutex | (未在 keydir 中) | 独立 |
| **Index** | mutex_ | std::shared_mutex | (未在 keydir 中) | 独立 |
| **SearchLayer** | fields_mu_ | std::shared_mutex | (未在 keydir 中) | 独立 |
| **SearchCache** | mutex_ | std::shared_mutex | (未在 keydir 中) | 独立 |
| **DocTextLru** | mu_ | std::mutex | (未在 keydir 中) | 独立 |
| **InvertedIndex** | vocab_mtx_[i] | std::shared_mutex ×64 | (未在 keydir 中) | per-shard 按词汇哈希分桶 |
| **InvertedIndex** | tbb::concurrent_hash_map | bucket locks (内部) | (未在 keydir 中) | TBB 内部哈希表桶锁 |
| **HnswIndex** | atomic&lt;shared_ptr&gt; | std::atomic | (未在 keydir 中) | 内部，无外部锁嵌套 |
| **HnswIndex** | per-node spinlock | (内部) | (未在 keydir 中) | 内部，无外部锁嵌套 |
| **IndexPool** | queue_ + pending_ | tbb 有界队列 + atomic | thread_pool.hpp | 单 worker 串行消费；队列满时 push 阻塞做背压 |

### 2. 锁层级 ASCII 图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        全局锁层级（2026 重构）                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  KeyDir 锁全序（严格遵守）：                                                │
│                                                                             │
│     barrier_mu_ ──→ gate_mu_ ──→ meta_mu_ ──→ 单个 shard ──→ fstats_grow_mu_ │
│        (mutex)         (mutex)     (shared)      (mutex)        (mutex)    │
│                                                                           │
│  注：任意时刻至多持 1 把分片锁（TSan 死锁检测器 64 持锁硬上限）             │
│                                                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  独立模块锁（不参与全局锁序）：                                            │
│                                                                             │
│     Cask::read_cache_mu_      (shared_mutex)                               │
│     KeyDirRegistry::mutex_    (mutex)                                      │
│     Index::mutex_             (shared_mutex)                               │
│     SearchLayer::fields_mu_   (shared_mutex)                               │
│     SearchCache::mutex_       (shared_mutex)                               │
│     DocTextLru::mu_           (mutex)                                      │
│     InvertedIndex::vocab_mtx_[i] (shared_mutex ×64)                        │
│     HnswIndex::atomic<shared_ptr> (atomic)                                 │
│     HnswIndex::per-node spinlock (内部)                                    │
│     IndexPool::queue_ (tbb 有界队列) + pending_ (atomic)                   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  异常路径（均有死锁防护）：                                                 │
│                                                                             │
│  ① 热路径：shard → meta（与全序一致）                                      │
│     - get/put/remove 在持分片锁后嵌套 meta shared/unique                   │
│     - cpp/src/keydir/keydir.cpp:316, 413, 652                              │
│                                                                             │
│  ② 屏障内：meta_shared → shard（反向，仅屏障内合法）                        │
│     - apply_pending_to_entries_barrier 持 meta shared 期间嵌套分片锁        │
│     - cpp/src/keydir/keydir.cpp:891-904                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3. 锁获取规则

#### 3.1 KeyDir 内部规则

**标准锁序（必须遵守）：**
```
barrier_mu_ → gate_mu_ → meta_mu_ → 单个 shard（≤1 把） → fstats_grow_mu_
```

**热路径规则（get/put/remove）：**
- 先拿单个分片锁（shard.mu）
- fold 态或 pending 存在时，嵌套获取 meta_mu_（shared/unique 视操作而定）
- 方向：shard → meta（与全序一致）
- 代码位置：
  - get: cpp/src/keydir/keydir.cpp:303-326
  - put: cpp/src/keydir/keydir.cpp:371-423
  - remove: cpp/src/keydir/keydir.cpp:596-677

**屏障操作规则（start/release/save_snapshot/load_snapshot）：**
- 通过 BarrierGuard RAII 类自动管理屏障生命周期
- 屏障期间写者被闸门出清，读者照常并发
- 屏障内不持分片锁遍历各分片 entries（读-读并发安全）
- 代码位置：cpp/src/keydir/keydir.cpp:138-166（BarrierGuard）

#### 3.2 跨模块规则

**无跨模块锁嵌套：**
- 任何模块在持有自己锁的同时，不获取其他模块的锁
- 模块间协作通过无锁原子变量或函数调用完成
- 示例：Cask::read_cache_mu_ 独立持有，不与 KeyDir 锁嵌套

**独立模块锁：**
- KeyDirRegistry::mutex_、Index::mutex_、SearchLayer::fields_mu_ 等均独立
- 这些锁各自保护不重叠的数据结构，无全局锁序要求

### 4. 文档化的例外情况

#### 例外 ①：热路径 shard→meta 嵌套

**场景：** get/put/remove 在持分片锁后嵌套 meta 锁

**代码位置：**
- cpp/src/keydir/keydir.cpp:316（get）
- cpp/src/keydir/keydir.cpp:413（put）
- cpp/src/keydir/keydir.cpp:652（remove）

**锁获取顺序：**
```
shard.mu (unique/shared) → meta_mu_ (shared/unique)
```

**死锁防护：**
- 方向与全局锁序一致（shard 在 meta 之前）
- 任意时刻至多持 1 把分片锁
- 热路径是标准操作路径，无特殊限制

**正确性保证：**
- 持分片锁时 meta 获取不会阻塞（meta 锁获取无分片锁依赖）
- 全局锁序要求 barrier_mu_ → gate_mu_ → meta_mu_，热路径不涉及前两把锁

#### 例外 ②：屏障内 meta_shared→shard 反向嵌套

**场景：** apply_pending_to_entries_barrier 在持 meta shared 期间嵌套分片锁

**代码位置：**
- cpp/src/keydir/keydir.cpp:891-904

**锁获取顺序（反向）：**
```
meta_mu_ (shared) → shard.mu (unique)  [与全序相反！]
```

**死锁防护证明：**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  例外 ② 无死锁论证                                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  前提条件：                                                                  │
│  1. 本阶段仅在屏障内执行（BarrierGuard 已激活）                              │
│  2. keyfolders_ 已归零（最后一个 folder 的 release）                        │
│                                                                             │
│  屏障状态：                                                                  │
│  - 写者（put/remove）已被闸门出清                                           │
│    └─ 任何越过闸门的写者必在排干循环前就持有分片锁                          │
│    └─ 并在排干完成前整体结束（含其嵌套 meta unique 段）                      │
│  - 其他 meta unique 使用者（start/release 阶段一三/save/load）被 barrier_mu_  │
│    串行，不与本阶段并发                                                      │
│                                                                             │
│  并发者类型：                                                                │
│  - 唯一的并发者是读者（get/conditional_remove peek）                        │
│  - 读者路径：shard → meta（只拿 meta shared）                                │
│  - 本阶段路径：meta → shard（只拿 meta shared）                              │
│                                                                             │
│  无环论证：                                                                  │
│  ① 读者不持 meta unique，只持 meta shared                                   │
│  ② 本阶段不持 meta unique，只持 meta shared                                 │
│  ③ shared-shared 兼容，不会互相阻塞                                          │
│  ④ 屏障内无 meta unique 排队者                                              │
│  ⑤ 双方的 meta 获取都不可能阻塞                                              │
│                                                                             │
│  结论：无法构成「持 shard 等 meta / 持 meta 等 shard」的环 → 无死锁          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5. conditional_remove TOCTOU 分析

**实现模式：** 两阶段（peek + remove）

**代码位置：** cpp/src/keydir/keydir.cpp:688-727

#### 5.1 Peek 阶段（只读探测）

**锁获取顺序：**
```
shard.mu (unique, 瞬间) → meta_mu_ (shared, 瞬间)
```

**执行逻辑：**
1. 持分片锁，查 entries 是否命中
2. miss 且 fold 态时，嵌套 meta shared 查 pending
3. 比对 (tstamp, file_id, offset) 是否匹配
4. 匹配则返回 kOk，否则返回 kAlreadyExists
5. 释放所有锁

**特点：**
- 瞬间持有锁，立即释放
- 无写操作，不修改状态

#### 5.2 Write 阶段（实际删除）

**调用路径：** 返回 kOk 后调用 remove()

**锁获取顺序：**
```
shard.mu (unique) → (可选) meta_mu_ (unique)
```

**执行逻辑：**
1. 先拿分片锁
2. 检查屏障闸门（v2）：屏障期间写者退避
3. 查 entries 命中时：
   - 无 fold：直接 erase
   - fold 态：升级 sibling 链插墓碑
4. entries miss 且 pending 命中时：
   - 嵌套 meta unique
   - pending 内原地改墓碑

#### 5.3 竞态窗口分析

**窗口描述：** Peek 阶段释放锁到 Write 阶段开始之间的时间段

**可能的状态变化：**
1. 目标 key 被其他写者删除（变成墓碑）
2. 目标 key 被其他写者更新（file_id/offset 变化）
3. 目标 key 从 entries 移动到 pending（fold 合并）
4. fold 状态从活跃变为非活跃

**安全性保证：**
- remove() 内部重新检查 key 的当前状态
- 若 key 不存在或已是墓碑，直接返回 false（not-found）
- 若 key 存在但状态不匹配，remove() 仍执行删除操作
- CAS 语义的「恰好删除特定版本」在两阶段间不保证
- 但对于 merge 语义足够（merge 跳过已被覆盖的条目即可）

**幂等性：**
- remove() 对同一 key 多次调用安全
- 已删除的 key 再次调用返回 false
- 活跃的 key 被正确删除

**代码证据：**
- cpp/src/keydir/keydir.cpp:618（remove 内部重新检查）
- cpp/src/keydir/keydir.cpp:726（conditional_remove 的返回值统一为 kOk）

### 6. 设计约束与历史原因

#### 6.1 TSan 死锁检测器限制

**问题：** 旧实现同时持有全部 kShards+1=257 把锁
- 撞 TSan 死锁检测器的 64 持锁硬上限
- 位置：compiler-rt sanitizer_deadlock_detector.h:67 CHECK
- 触发场景：屏障类全量遍历操作（save_snapshot / 全量 fold）在
  `TSAN_OPTIONS=detect_deadlocks=1` 下崩溃

**解决方案：** 屏障 v2 写者闸门机制
- BarrierGuard 任意瞬间至多持 1 把分片锁
- 排干循环逐分片加锁-放锁，写者被闸门出清
- 读者不受影响，照常并发

**代码证据：**
- cpp/src/keydir/keydir.cpp:109-136（BarrierGuard 注释）
- cpp/include/bitcask/keydir.hpp:15-19（锁全序注释）

#### 6.2 分片数量演进

**历史：** 16 → 64 → 256（S5 迭代）

**原因：**
- 降低分片碰撞概率
- 减少写者停车传染面
- 提升并发度

**当前值：** kShards = 256

**代码证据：**
- cpp/include/bitcask/keydir.hpp:357

#### 6.3 shared_mutex → mutex 切换（S5）

**切换：** 分片锁从 rwlock 改为 mutex

**原因：**
- 消除写者偏好停车问题
- 临界区足够短，mutex 性能更好
- 简化锁语义

**代码证据：**
- cpp/include/bitcask/keydir.hpp:361（Shard::mu 注释）

#### 6.4 pending/entries 探测顺序变更（S2）

**变更：** 从 pending→entries 改为 entries→pending

**原因：**
- 堵 release 合并窗口的 TOCTOU
- 维持 entries/pending 不相交不变量
- 保证「key ∈ entries ⟹ pending 无其更新版本」

**不变量：**
```
key ∈ 某分片 entries  ⟹  pending_ 不会有它的更新版本
```

**正确性依据：**
- get/remove 的探测顺序依赖该不变量
- release 的「先应用后清表」协议依赖该不变量

**代码证据：**
- cpp/src/keydir/keydir.cpp:286-296（get 查找顺序注释）
- cpp/src/keydir/keydir.cpp:390-423（put 探测逻辑）

### 7. 验证与测试

#### 7.1 编译时验证

**工具：** Clang Thread Safety Analysis（若启用）

**验证点：**
- 锁序标注（CAPABILITY/REQUIRES）
- 分片锁至多一把检查
- meta_mu_ 读写分离正确性

#### 7.2 运行时验证

**工具：**
- TSan（Thread Sanitizer）- 竞态检测
- Helgrind（Valgrind）- 死锁检测

**关键测试案例：**
- KeyDir.AllocOrdThreadSafety（并发分配 ord 无竞态；屏障 v2 正确性）
- 并发 fold 与 put/remove 互不阻塞
- 多 fold 并发场景（keyfolders_ > 1）

**测试命令：**
```bash
# ASan/UBSan
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake --build _build/asan -j
ctest --test-dir _build/asan --output-on-failure

# TSan
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON
cmake --build _build/tsan -j
ctest --test-dir _build/tsan --output-on-failure
```

#### 7.3 设计文档交叉引用

**相关设计文档：**
- doc/keydir-sharding-design-zh.md - 分片并发设计
- doc/put-flow-zh.md - put 完整调用链
- doc/unified-architecture-plan-zh.md - 统一架构计划

---

**文档版本：** 2026 重构补全版本（2026-06 并发审计加固：§6 索引读路径不变量）
**最后更新：** 2026-06-15
**维护者：** Bitcask C++ 团队
