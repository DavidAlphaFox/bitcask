# P6 — sealed 文件 mmap 只读路径 设计

> 状态：2.1.1 承诺项。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；并发/句柄生命周期
> 见 [`concurrency-zh.md`](concurrency-zh.md)、[`merge-policy-zh.md`](merge-policy-zh.md)。

## 1. 背景与动机

现状：data 文件读路径是 `pread`（`posix_file.cpp`）；`read_files_` 按 file_id 缓**打开的
DataFile 句柄（fd）**，不缓 value、不 mmap（`cask.cpp:1045`）。`Cask::get` =
keydir 查 → `read_file` → `df->read` pread → `GetResultView`（span 借 pread 缓冲）。

`pread` 已享 OS page cache（热数据不打盘），但每次 get：① 一次 pread **syscall**；
② page cache → 用户态**一次拷贝**。**mmap sealed 文件**可同时消掉这两项：指针直读
page cache，**零拷贝 + 无 syscall**，且**不双缓存**（mmap 就是 page cache 的视图）。

## 2. 为何只 mmap sealed（不可变）文件

active（正在 append、尺寸在长）文件对 mmap 不友好：
- 映射长度 map 时固定 → append 超出映射区不可见；
- 预映射更大区间 → 访问超过当前文件大小的页 **SIGBUS**（除非 ftruncate 撑大，破坏
  「文件大小 == 数据长度」不变量）；
- 随增长重映射 → `mremap` 可能**移动虚拟地址**，使在途读者持有的指针悬垂。

bitcask 文件 **roll 后即 sealed/immutable**，故 mmap 只用于 sealed 文件，**active 永远
pread**，append 问题自然规避。

## 3. 设计

### 3.1 DataFile mmap 模式
- sealed 文件首次读时 `mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0)` 整文件。
- `read(off, sz)` 命中映射 → 返回**指向映射的 span**（零拷贝、无 syscall）；
  active / 未映射 / 超额 → 回退 `pread`（返回 owned 缓冲，现行行为）。
- **mmap 后可 `close(fd)`**：Linux 下 mmap 后关 fd，映射仍有效 → **顺带缓解 read_files_
  的 fd 累积**（大库读过多文件撞 ulimit，见 [`concurrency-zh.md`]）。
- `mmap_limit`（按映射文件数 / 总字节）+ pread 兜底：大库地址空间/映射数可控。
  **32 位禁用 mmap**（地址空间不足，同 LevelDB）。

### 3.2 merge 生命周期（核心）

难点：merge 写新文件后 **unlink 旧文件**，与「并发读者持映射指针」的生命周期。

- **释放（延迟 munmap）**：merge unlink 时**不立即 munmap**——只从 `read_files_`
  erase 该 file_id 的 `shared_ptr<DataFile>`（去掉缓存引用）。**在途读者仍持 shared_ptr
  → DataFile 存活 → 映射存活**；最后一个引用析构（`~DataFile`）时才 `munmap`。
  Linux 上 **unlinked-but-mapped 文件仍可读**（inode 由映射续命，类似 open fd 续命，
  与现行 S13 fold-pin 同理）。
- **再次 mmap**：merge 产出的新 sealed 文件、以及 active `roll_active` 成 sealed 后，
  下次经 `read_file`（lazy open）按 sealed mmap 路径建立新映射。
- 即生命周期 = **现有 `shared_ptr<DataFile>` 引用计数从「fd」扩展到「映射区」**
  （= LevelDB Version refcount 的等价），不引入新锁模型。

### 3.3 GetResultView 适配
现行 `GetResultView` 持 owned `ReadRecord`（pread 拷贝），span 借它。mmap 命中时：
- `GetResultView` 改持 `shared_ptr<DataFile>`（映射引用）+ span 指向映射；
- 保证 view 生命内映射不撤（即便期间 merge unlink）。
- 两个来源统一：cache shared_ptr（mmap）/ disk ReadRecord（pread），view 各持其一。

### 3.4 写路径不变
`pwrite` append 到 active（含 P4 组提交）。active 不 mmap。roll → sealed 后才有资格 mmap。

## 4. 关键不变量
- **只 mmap sealed 文件**；merge **只 unlink、绝不原地 truncate** sealed 文件 →
  无 SIGBUS-on-truncate。
- sealed 已 finalize → **无 torn-tail**（active 才有 torn-write，走 pread + 修复）。
- 映射指针**绝不跨 DataFile 生命**逃逸（GetResultView/读者持 shared_ptr 锚定）。

## 5. 范式对照（LevelDB）
| 关注点 | LevelDB | 本设计 |
|--------|---------|--------|
| 不可变读文件 | SSTable | sealed data 文件 |
| 读路径 | mmap(限额) + pread 兜底 | 同 |
| 删文件生命周期 | Version refcount 延迟删 | shared_ptr<DataFile> refcount 延迟 munmap |
| 32 位 | 禁 mmap | 同 |

## 6. 子任务
- **P6a**（已落地）：DataFile sealed mmap（`DataFile::open` 新增 `mmap_enabled`；kRead+64 位+
  非空 → 整文件 `mmap(PROT_READ,MAP_SHARED)`；`read_mmap` 返回指向映射的 `DataRecordView`
  零拷贝；自定义 move/dtor 管 `munmap`；纯 fold 的 recovery/merge/迭代器 pin 传
  `mmap_enabled=false`）。**偏差**：未 `close(fd)`——保留 fd 让 `read()`/`fold()` 的 pread
  在 mmapped 句柄上仍可用（迭代器 `next()`/恢复需要）；fd 回收归 P9。
- **P6b**（已落地）：merge unlink 延迟 munmap——直接复用现有 `shared_ptr<DataFile>` 引用计数
  （O10 UAF 修复同款），unlink + `read_files_` 淘汰后,在途读者/`GetResultView` 持 shared_ptr
  续命映射,最后引用析构才 munmap。新/roll-sealed 文件下次 `read_file` 懒加载重新 mmap。
- **P6c**（部分）：`GetResultView` 持 `map_holder_`(shared_ptr) 锚定映射 + value_bytes 解耦
  （owned/mmap 两源统一 derive）✅；32 位禁用 ✅。**未做**：`mmap_limit`（映射数/字节上限 +
  超额回退 pread）——与 P9 read-handle LRU 同款驱逐,合并到 P9。
- 测试：`P6MmapViewSurvivesMergeUnlink`（读中 merge unlink，view 仍读，ASAN address+leak 全过）；
  416 测试通过（get 全程经 mmap 零拷贝路径,等价性由既有 get/迭代器测试守护）。
- **P6-gate**：量化 get 延迟（mmap 命中 vs pread vs page-cache 命中）；ulimit/地址空间影响。**待测**。

## 7. 风险
- 生命周期正确性（映射指针悬垂）——靠 shared_ptr 锚定 + 单元测试（读中 merge unlink）。
- SIGBUS 源：仅外部 truncate 已映射文件——bitcask 不 truncate sealed，自身安全。
- 地址空间（32 位禁用）/ 映射数（mmap_limit）。

## 8. 测试
- mmap 读正确性（vs pread 同结果）。
- **读中 merge unlink**：一个读者持 GetResultView（映射 span），并发 merge unlink 该文件
  → 读者照常读、无 UAF/SIGBUS；引用释放后文件真正 munmap/回收。
- mmap_limit 超额回退 pread。
- close + reopen（sealed mmap 路径）。
- 32 位（或强制禁用 flag）走 pread。
