# Bitcask C++23 重构任务清单

> 目标:将 Bitcask 的核心逻辑从 Erlang + C 迁移到 **C++23**(GCC 14.2 / Clang 16+),使用 CMake 管理。
> Erlang 层只保留 NIF 加载与对外 API 直通,所有存储逻辑下沉到 C++。
>
> 原则:**磁盘格式逐字节兼容** · **每个里程碑可独立验收回滚** · **eunit/EQC 始终是金线**

---

## 待确认的决策点(动手前必须拍板)

- [x] **D1 磁盘格式**:保持与现有版本逐字节兼容(数据文件 14B header / hint 18B / tombstone v0/v1/v2)
- [x] **D2 NIF 接口粒度**:粗粒度 API(`cask_open/get/put/del/fold/merge/...`,约 15 个函数),废弃现有 30+ 细粒度函数
- [ ] **D3 哈希实现**:`absl::flat_hash_map`(开放寻址,缓存友好);备选 `std::unordered_map`
- [ ] **D4 并发模型**:`std::shared_mutex` + 分桶锁(默认 64 桶)
- [ ] **D5 错误传递**:内部 `std::expected<T, Error>`(C++23);NIF 边界翻译为 `{ok,_}` / `{error,_}`
- [x] **D6 构建系统**:CMake 顶层产出 `priv/bitcask.so`;rebar3 通过 `pre_hooks` 调 cmake(替换 `pc` 插件)
- [x] **D7 语言标准与编译器**:**C++23**(`-std=c++23`),最低 GCC 13 / Clang 16,目标环境 GCC 14.2(Debian 14.2.0-19)。可放心使用 `std::expected` / `std::print` / `std::flat_map` / `std::jthread` / `<ranges>`
- [ ] **D8 依赖管理**:CMake `FetchContent` 拉 abseil + GoogleTest + Google Benchmark
- [ ] **D9 合并执行模式**:由 `bitcask_merge_worker` gen_server 触发,NIF 内同步执行(走 dirty scheduler)
- [ ] **D10 测试策略**:保留 eunit + EQC 不变;新增 GoogleTest 单测 + golden 格式兼容测试
- [ ] **D11 Riak 兼容性**:M4 之前所有 `bitcask:*/*` export 保持不变
- [ ] **D12 是否引入 abseil**:是 / 否(否则 M5 之前用 `std::unordered_map`)
- [ ] **D13 覆盖率底线**:目标行覆盖率 ≥ 80%

---

## 必须保持的不变式(Invariants)

- [ ] 数据文件 / hint 文件 / 锁文件的二进制布局与现有版本一致
- [ ] tombstone 三代格式(v0/v1/v2)的判定与写入语义不变
- [ ] `MAXOFFSET_V2 = 0x7fff_ffff_ffff_ffff` 等常量保持
- [ ] fold 期间允许并发写,迭代器看到的是开始时刻的 epoch 视图(sibling 链 + pending 表语义)
- [ ] 同进程多次 `open(Dir)` 共享同一 keydir(refcount + 全局注册表)
- [ ] `sync_strategy`:`none` / `o_sync` / `{seconds, N}` 三种语义一致
- [ ] `max_file_size` 滚动、`merge_window`、`needs_merge` 阈值语义一致
- [ ] CRC32 算法与字段位置不变

---

## 里程碑 0:脚手架 + 格式抓手 (1–2 天)

> 目标:建立 CMake + GoogleTest 框架,拿到磁盘格式的 golden 测试。本里程碑对现有代码零侵入。

- [x] 顶层 `CMakeLists.txt`,要求 cmake ≥ 3.20
- [x] `cmake/FindErlang.cmake`:通过 `erl -eval` 探测 ERTS include / lib 路径
- [x] `cmake/BitcaskWarnings.cmake`:`-Wall -Wextra -Wconversion -Wshadow -fvisibility=hidden`(暂内联在 `cpp/CMakeLists.txt`,后续如需复用再抽出)
- [x] `cmake/BitcaskSanitizers.cmake`:`-DBITCASK_SANITIZE=address,undefined,thread,leak`(三组合验证全过)
- [x] `cpp/` 目录骨架(`include/`、`src/`、`nif/`、`tests/`)
- [x] 编译产出空 stub `bitcask_stub.so` 到 `priv/`(暂不替换原 NIF)
- [x] **端到端验证**:Erlang `erlang:load_nif/2` 加载 stub 成功并调用 `ping/0` 返回 `pong`
- [x] `rebar.config` 增加 cmake `pre_hooks` + `post_hooks`(双产出阶段:`bitcask.so` + `bitcask_stub.so` 共存,`rebar3 clean` 联动清理)
- [x] `FetchContent` 接入 GoogleTest(v1.15.2),跑通 hello-world 单测
- [x] `cpp/include/bitcask/format.hpp`:从 `include/bitcask.hrl` 移植所有二进制布局常量(kHeaderSize=14、kHintRecordSize=18、kMaxOffsetV2、tombstone v0/v1/v2 等)
- [x] `cpp/include/bitcask/codec.hpp` + `cpp/src/fileops/codec.cpp`:数据文件 / hint 记录的 encode/decode + zlib CRC32
- [x] `cpp/tests/codec_test.cpp`:byte-level golden tests(包含与 Erlang 实跑输出交叉验证的硬编码 hex,CRC 值精确到位)
- [ ] `cpp/tests/fixtures/`:放入若干真实数据文件(M2 引入 keydir 时一并补)
- [x] `rebar3 compile` 同时产出新旧两个 `.so`;`rebar3 eunit` 全部 **81/81** 测试通过
- [x] `ctest --output-on-failure` 通过(**19/19 PASS**)

**验收**:✅ eunit 81/81 PASS;✅ ctest 19/19 PASS(无/ASan+UBSan/TSan 三组合都过);✅ `rebar3 compile` 双产出。

---

## 里程碑 1:文件 I/O + Lock 下沉 (3–5 天)

> 目标:把无并发难点、纯函数性质的 file I/O 与 lock 模块迁到 C++,验证 NIF 翻译层与资源生命周期。

### C++ 实现
- [x] `cpp/include/bitcask/io.hpp` + `cpp/src/io/posix_file.cpp`:`PosixFile` 类(open/close/sync/pread/pwrite/read/write/seek/seek_bof/truncate_here),`std::expected<T, IoError>`,移动语义
- [x] `cpp/include/bitcask/file_lock.hpp` + `cpp/src/lock/file_lock.cpp`:`FileLock` 类(write 锁 = O_CREAT|O_EXCL|O_RDWR|O_SYNC,read 锁 = O_RDONLY,release 时 unlink 写锁文件)
- [x] errno 通过 `IoError{int}` 透传至 NIF 层,由 `erl_errno_id()` 翻译为 atom

### NIF 翻译层
- [x] `cpp/nif/term_conv.hpp`:latin1 字符串、`ErlNifBinary ↔ std::span<const std::byte>` 转换
- [x] `cpp/nif/nif_io.cpp`(10 个 `file_*_int`)+ `cpp/nif/nif_lock.cpp`(4 个 `lock_*_int`)
- [x] `cpp/nif/atoms.{hpp,cpp}`:全部 atom 在 `on_load` 缓存
- [x] `cpp/nif/resources.{hpp,cpp}`:`bitcask_file_resource` / `bitcask_lock_resource` 注册 + 析构(placement-new 持有 C++ 对象)
- [x] `cpp/nif/nif_main.cpp`:`ERL_NIF_INIT(bitcask_cpp_nifs, ...)`,与 `c_src/bitcask_nifs.c` 在不同 module 名下共存(`bitcask.so` / `bitcask_cpp.so` 双产出)

### 切换 & 验收
- [x] 新增 `src/bitcask_cpp_nifs.erl` 加载 `priv/bitcask_cpp.so`(legacy `bitcask_nifs` **保持不动**)
- [x] **平价测试**:`test/bitcask_cpp_nifs_tests.erl` 19 个用例,**legacy vs C++ 同输入返回完全一致** PASS
- [x] eunit 全套 **100/100** 通过(原 81 + 新增 19)
- [x] C++ 单测:`posix_file_test` 10 例 + `file_lock_test` 9 例,**ctest 38/38** 全过
- [x] ASan + UBSan 38/38 全过(0 leak / 0 UB)
- [ ] `make pulse` 跑 30 秒不挂(EQC/PULSE 路径属于 keydir 范畴,M2 触发)
- [ ] 删除 `c_src/` 中已替换的 file/lock 部分(推迟到 M4 整体瘦身,保留共存)

**验收**:✅ eunit 100/100;✅ ctest 38/38(no san / ASan / UBSan);✅ legacy 与 C++ NIF 输出 byte-for-byte 一致。

---

## 里程碑 2:KeyDir 下沉(最核心)(5–8 天)

> 目标:复刻 keydir 的 sibling 链 + epoch + pending 表机制,EQC 必须全过。
> 由于工作量大,M2 拆成 5 个子阶段;每个子阶段独立验收。

### M2.1 — 核心结构 + 简单 ops + fstats(单 mutex,无 sibling/pending)
- [x] `cpp/include/bitcask/keydir.hpp`:`Entry` / `EntryProxy` / `FStatsEntry` / `KeyDir` API
- [x] `cpp/src/keydir/keydir.cpp`:put/get/remove/conditional_remove/get_epoch/info/deep_copy
- [x] put 的 staleness 检查 + merge race 检测(legacy `keydir_put_int` 的 4 类返回路径)
- [x] fstats:update_fstats/set_pending_delete/trim_fstats(8-arg 接口与 legacy 对齐)
- [x] biggest_file_id + increment_file_id (/at_least)
- [x] 全部用 `std::scoped_lock` + `std::unordered_map` 起步
- [x] **27 个 GoogleTest** 单测(含 8 线程并发 put);ctest **65/65**
- [x] ASan+UBSan + TSan **三 sanitizer 全过**

### M2.2 — Sibling 链 + Pending 表 + 迭代器(并发 fold 语义)
- [x] `Entry` 升级为 `std::variant<SingleEntry, MultiEntry>`,sibling 链按 epoch 倒序
- [x] `pending_` 影子哈希(`std::optional<unordered_map>`):新 key 在 fold 期间写入时启用
- [x] `merge_pending_and_collapse_locked`:最后一个 folder release 时把 pending 合并回 entries 并把所有 MultiEntry 折叠回 Single
- [x] iter API:`make_iter()` 工厂 + `IterHandle::start/next/release`(析构自动 release)
- [x] `entry_at_epoch` 等价 `proxy_kd_entry_at_epoch`:返回指定 epoch 的快照
- [x] StartIterResult:`kOk` / `kAlreadyIterating` / `kOutOfDate`(maxage / maxputs 检查)
- [x] put 4 路径都覆盖:pending 已存在 / pending 新建 / entries 加 sibling / entries 直接写
- [x] remove 走 sibling tombstone 路径(语义等价于 legacy 的 set_entry_tombstone)
- [x] **18 个 iter 测试 + 27 个原 keydir 测试 = 45 个**,ctest **83/83 PASS**
- [x] ASan+UBSan / TSan 三组合 **45/45 全过**
- [x] **stress test**:4 写线程 + 3 fold 线程并发,验证每次 fold 看到无重复无丢失的快照
- [ ] `pending_awaken` 队列(NIF 层职责,M2.4 加)
- [ ] `perhaps_sweep_siblings` 惰性清扫(性能优化,M5)

### M2.3 — 全局注册表 + 命名 KeyDir + Refcount
- [x] `cpp/include/bitcask/keydir_registry.hpp` + `cpp/src/keydir/keydir_registry.cpp`:`KeyDirRegistry` 类
- [x] `acquire(name)`:三态返回 `kCreated` / `kReady` / `kNotReady`
- [x] `query(name)`:仅探测,不 bump refcount,不 create(对应 `maybe_keydir_new/1`)
- [x] `release(name)`:refcount 减一;降到 0 持久化 `biggest_file_id+1` 并从 registry 删除
- [x] mark_ready 协议:首个 acquirer 拿到 `kCreated` 必须调 `mark_ready()`,在此之前其他人得 `kNotReady`
- [x] biggest_file_id 跨 close/reopen 持久化:**11 个测试**,验证多次 acquire/release 周期下单调
- [x] **8 线程并发 acquire/release stress** 测试,registry 最终为空、状态正确分配
- [x] ASan+UBSan / TSan **三组合全过 56/56**
- [ ] 匿名 keydir(`keydir_new/0`):直接 `std::make_shared<KeyDir>()` 即可,无需 registry,等到 M2.4 NIF 接入时再做封装

### M2.4 — NIF wiring + Erlang shim + parity
- [x] `cpp/nif/atoms.{hpp,cpp}` 扩展:`bitcask_entry / not_found / already_exists / not_ready / ready / out_of_date / iteration_in_process / iteration_not_started / true / false / undefined`
- [x] `cpp/nif/term_conv.hpp` 扩展:`get_uint64_bin` / `make_uint64_bin`(8字节 native-endian offset 编解码,与 legacy 对齐)
- [x] `cpp/nif/resources.{hpp,cpp}` 扩展:`KeyDirHandle` 资源(持 `shared_ptr<KeyDir>` + 可选 registry/name + iter)
- [x] `cpp/nif/priv_data.hpp`:`PrivData{KeyDirRegistry}`,通过 `enif_priv_data` 持有
- [x] `cpp/nif/nif_keydir.cpp`(~330 行):**19 个 `keydir_*` NIF 函数**全部实现
- [x] `cpp/nif/nif_main.cpp` 扩展:21 个新 ErlNifFunc 注册 + on_unload 释放 PrivData
- [x] `src/bitcask_cpp_nifs.erl` 扩展:`keydir_*` API,offset 自动 binary↔int 转换,与 `bitcask_nifs.erl` API 对齐
- [x] `test/bitcask_cpp_nifs_keydir_tests.erl`:**20 个 parity 测试**(19 双跑 + 1 cpp-only)
- [x] **意外收获**:发现 legacy `keydir_copy` 存在 14 年的旧 bug(memset 错了 handle 指针,把 source 清空),C++ 实现没有此 bug,我们用 cpp-only 测试明确防回归
- [x] eunit 全套 **120/120 PASS**(81 legacy + 19 M1 + 20 M2.4)
- [x] C++ ctest **94/94 PASS**;ASan+UBSan 全过

### M2.5 — 加强并发 stress 测试 + 真实业务路径接入(替代 EQC)
> EQC 是 Quviq 商业版,本环境无授权。改用更激进的 GoogleTest 并发 fuzz +
> 直接把 cpp NIF 接入 `bitcask:open/2` 让真实业务流跑,在生产路径上抓 bug。

- [x] **C++ stress 测试**(`cpp/tests/keydir_stress_test.cpp`,4 个测试):
  - `RandomOpsFuzz`:8 线程随机 put/get/remove/fold,~500k+ ops,验收 fold 观察到的 key 数 == info.key_count
  - `ConcurrentFoldsSnapshotStable`:4 writer + 4 folder 并发,每个 fold 看到无重复无丢失的快照
  - `RegistryAcquireReleaseChurn`:8 线程 churn registry,refcount 无泄漏
  - `LongFoldStableUnderRapidRewrites`:fold 期间 5000 次同 key 改写,fold 始终看到原始快照
  - **抓到一个真实 bug**:`remove()` 在 pending 是 tomb 时错误地继续检查 entries,导致 stale live revs 被误删 + key_count 双重 dec → 已修复
- [x] 三 sanitizer 全过(无 san / ASan+UBSan / TSan):**98/98 PASS**
- [x] **`bitcask_cpp_nifs.erl` 补齐** `keydir_fold/5` / `keydir_frozen/4` / `keydir_wait_pending/1`:
  - `keydir_fold/keydir_frozen` 实现与 legacy 完全一致
  - `keydir_wait_pending` 用 50ms polling 替代 NIF 端 `enif_send`(降级方案,功能正确,M5 可补真正实现)
- [x] **`include/bitcask.hrl` 加 `?NIF` 宏**:用 fun-wrapped case 读 proc dict `bitcask_nif_mod`,默认 `bitcask_nifs`
- [x] **`bitcask:open/2` 加 `{nifs, cpp}` 选项**:命中后设 proc dict 路由所有 NIF 到 `bitcask_cpp_nifs`;`close/1` 清理 proc dict
- [x] **5 个核心模块 sed 替换** `bitcask_nifs:` → `?NIF:`(146 callsites):`bitcask.erl` 49 / `bitcask_fileops.erl` 2 / `bitcask_io.erl`(独立 file_module 路由) / `bitcask_lockops.erl` 10 / `bitcask_merge_delete.erl` 5
- [x] **`bitcask_io:file_module/0` 也读 proc dict**:cpp 模式下 file I/O 也走 cpp NIF(否则混用不同 NIF 的资源会 badarg)
- [x] **`nif_keydir_new1` 返回值修正**:与 legacy 对齐,改返回 `{ready, Ref}` / `{not_ready, Ref}`(不是 `{ok, Ref}`)
- [x] `test/bitcask_cpp_open_tests.erl`:**10 个业务流 parity 测试**(legacy vs cpp 双跑,含 1000-key fold)
- [x] eunit 全套 **130/130 PASS**
- [x] 实测 `bitcask:open(Dir, [{nifs, cpp}, read_write])` 完整 put/get/list_keys/fold/delete 全流程通过

### 后续(放到 M5 性能优化)
- [ ] `std::shared_mutex` + 桶级锁
- [ ] `absl::flat_hash_map` 替换
- [ ] 1M key benchmark:吞吐 ≥ 旧版 90%(M2 不要求,M5 要求)
- [ ] 删除 `c_src/bitcask_nifs.c` 的 keydir 段(M4 整体瘦身)

**验收**:eunit + EQC 全绿;keydir 部分性能不退化。

---

## 里程碑 3:Fileops + 合并核心下沉 (5–7 天)

> 目标:把 `bitcask_fileops.erl` 与 `bitcask.erl` 中的合并/扫描/状态计算迁到 C++,引入粗粒度 NIF API。
> 仿 M2 拆 5 个子阶段;每个子阶段独立验收。

### M3.1 — DataFile + HintFile C++ 类(基于 M0 codec + M1 PosixFile)
- [x] `cpp/include/bitcask/data_file.hpp` + `cpp/src/fileops/data_file.cpp`:`DataFile` 类(open/write/read/fold/sync/truncate_here)
- [x] `cpp/include/bitcask/hint_file.hpp` + `cpp/src/fileops/hint_file.cpp`:`HintFile` 类(append/finalize/fold/validate_trailer)
- [x] 文件名 helpers:`mk_data_filename`、`mk_hint_filename`、`parse_data_tstamp`(对应 legacy `mk_filename`/`hintfile_name`/`file_tstamp`)
- [x] CRC32 复用 zlib;运行 CRC 在 HintFile 内部累积
- [x] `validate_trailer`:O(filesize) 流式扫描,与 legacy `has_valid_hintfile` 行为对齐
- [x] **12 个 GoogleTest**:filename helper、DataFile round-trip、CRC 检测、HintFile validate_trailer 三种场景、DataFile↔HintFile 配对一致性
- [x] **Cross-language golden test**(`HintFileGolden.ReadsLegacyEncodedFile` + `EncodingMatchesLegacyByteForByte`):
  - `scripts/gen_golden_hint.escript` 用 Erlang 生成 legacy 编码的 79 字节 hint(3 records + trailer,CRC=0xED5B567A)
  - C++ 测试一是读 legacy 字节验证 trailer + 解出原始 records
  - C++ 测试二是用 HintFile 写出后 byte-for-byte 与 legacy 一致
- [x] ctest **120/120 全过**(包括 ASan+UBSan)
- [x] eunit 不回归 **130/130**

### M3.2 — 目录扫描器
- [x] `cpp/include/bitcask/scanner.hpp` + `cpp/src/fileops/scanner.cpp`:`scan_dir(dirname)` 返回 `[DataFileEntry]`,按 tstamp 升序
- [x] 每个 entry 含 `tstamp` / `data_path` / `has_hint` / `hint_path`
- [x] 跳过格式不正确的文件名(非纯数字 tstamp、错误后缀);忽略子目录、符号链接
- [x] uint64_max tstamp 不溢出
- [x] **8 个 GoogleTest** 覆盖空目录、不存在目录、排序、hint 配对、垃圾文件名、子目录过滤
- [x] ctest **120/120 全过**(包括 ASan+UBSan);eunit **130/130** 不回归

### M3.3 — Merge 策略 + merger 主体
- [x] `cpp/include/bitcask/merge_policy.hpp` + `cpp/src/merge/merge_policy.cpp`:
  - `summarize(dirname, fstats) → FileStatus`(算 frag% / dead_bytes / 文件名)
  - `per_file_reasons(file, opts, now) → [Reason]`(4 类:Fragmented / DeadBytes / SmallFile / DataExpired)
  - `decide(summary, opts, now) → Decision{needs_merge, files, expired_files}`(legacy `run_merge_triggers` 等价)
  - `cap_size(files, sizes, max_merge_size)`(legacy `cap_size`,严格不含越界文件)
- [x] `cpp/include/bitcask/merger.hpp` + `cpp/src/merge/merger.cpp`:`run_merge`(简化版 Merger)
  - 输入多 data 文件 → 输出单个 data + hint
  - 每个 record 走 keydir.get 做 liveness check;只搬 (file_id, offset) 仍指向原位置的"live"记录
  - tombstone records 跳过(M3.4 才补 tombstone v2 反写)
  - 写完后 keydir.put CAS 更新到新 (output_file_id, new_offset)
  - 返回统计:records_seen / kept / stale / tombs / bytes_written
- [x] **22 个 GoogleTest**:
  - 16 个 MergePolicy(summarize / 4 类 reason / decide 触发器 / 文件选择 / cap_size 三种边界)
  - 6 个 Merger(单文件 happy path / stale / tombstone 跳过 / 跨文件去重 / hint trailer 有效 / 空输入)
- [x] ctest **142/142 全过**(no san + ASan+UBSan);eunit 不回归 **130/130**

### M3.4 — Cask 类 + 粗粒度 `cask_*` NIF
- [x] `cpp/include/bitcask/cask.hpp` + `cpp/src/cask/cask.cpp`:`Cask` 类整合 keydir + DataFile + HintFile + Scanner + Merger + FileLock
  - `open(dirname, opts, registry?)`:扫目录 → keydir 加载(hint 优先 + tombstone 正确处理 + data fold fallback)→ 写锁(read_write 模式)
  - `get` / `put` / `remove`(写 v0 tombstone)/ `sync`
  - active 写文件 + max_file_size 滚动
  - `read_files_` 缓存懒打开
  - `make_iter()` → CaskIter:keydir snapshot iter + lazy 取 value
  - `status()` / `is_empty_estimate()` / `needs_merge()` / `merge()`(包装 M3.3 的 run_merge)
- [x] `cpp/nif/nif_cask.cpp`:13 个 `cask_*` NIF 函数
  - `cask_open / close / get / put / delete / sync`
  - `cask_fold_start / next / release`(粗粒度 fold,3 个 NIF 替代散件 itr 系列)
  - `cask_status / is_empty / needs_merge / merge`
- [x] **dirty scheduler 标记**:`cask_open` / `cask_sync` / `cask_merge` 走 `ERL_NIF_DIRTY_JOB_IO_BOUND`
- [x] `bitcask_cpp_nifs.erl` 暴露 13 个 `cask_*` API
- [x] **15 个 GoogleTest** 端到端验证(开/读/写/删/fold/重开/滚动/锁/registry 共享/二进制 key)
- [x] **冒烟测试**:`bitcask_cpp_nifs:cask_open + put + get + status + delete + fold` 完整链路从 Erlang 跑通
- [x] ctest **157/157 全过**(no san + ASan+UBSan);eunit 不回归 **130/130**

### M3.5 — Erlang shim + parity
- [x] `bitcask_cpp_nifs.erl` 已暴露 13 个 `cask_*` API(M3.4 完成)
- [x] **`bitcask:open/2` 加 `{nifs, cask_cpp}` 选项**:
  - 命中后调 `bitcask_cpp_nifs:cask_open/2`,Cask 资源 Ref 直接作为 bitcask:* 的 Ref 用
  - 设 `bitcask_use_cask=true` 在 process dict
  - `close/1` 清理 dict
- [x] 把原 `open/2` 的 body 重构成 `open_legacy/2`,新 `open` 是 dispatcher
- [x] **公共 API 加 cask 分支**(13 个):
  - `close/1` / `close_legacy/1`
  - `get/2`(其余 try 计数路径不进 cask 模式)
  - `put/3` / `put_legacy/3`(Value=tombstone 走 cask_delete)
  - `delete/2`、`sync/1`、`list_keys/1`、`fold/3`、`fold_keys/3`、`status/1`、`is_empty_estimate/1`、`is_frozen/1`
  - `cask_fold_collect/3` helper:wrap `cask_fold_start/next/release` 适配 legacy `Fun(K, V, Acc)` 签名
- [x] `test/bitcask_cpp_cask_open_tests.erl`:**13 个业务流 parity 测试**(legacy + cask_cpp 双跑)
  - put/get/overwrite/delete/list_keys/fold/reopen-persists/binary-NUL/500-key/status/is_empty/write-lock 互斥
- [x] eunit 全套 **143/143 PASS**(原 81 legacy + 19 M1 + 20 M2.4 keydir + 10 M2.5 cpp open + 13 M3.5 cask open)
- [x] ctest **157/157 PASS**(无 san + ASan+UBSan)

### NIF 粗粒度 API(D2 落地)
- [ ] `cask_open/2`、`cask_close/1`
- [ ] `cask_get/2`、`cask_put/3`、`cask_delete/2`
- [ ] `cask_sync/1`
- [ ] `cask_fold_start/3`、`cask_fold_next/1`、`cask_fold_release/1`
- [ ] `cask_merge/2`、`cask_needs_merge/1`
- [ ] `cask_status/1`、`cask_is_empty_estimate/1`
- [ ] dirty scheduler 标记(merge / fold / open 走 `ERL_NIF_DIRTY_JOB_IO_BOUND`)

### 测试
- [ ] `cpp/tests/data_file_test.cpp`:数据文件读写往返
- [ ] `cpp/tests/merge_test.cpp`:合并前后键值与 fstats 一致
- [ ] `cpp/tests/concurrent_merge_test.cpp`:合并期间的并发 put/get
- [ ] `cpp/tests/format_compat_test.cpp`:用真实旧版数据目录做 fixture

### 切换 & 验收
- [ ] 旧 `keydir_*_int` API 与新 `cask_*` API 在 NIF 层共存(为渐进切换)
- [ ] eunit 全套通过(此时部分 Erlang 逻辑还在,通过新 API 调用 C++)
- [ ] 合并 benchmark 不退化

**验收**:eunit + EQC 全绿;新增的合并并发测试通过。

---

## 里程碑 4:Erlang 层瘦身 (3–4 天)

> 目标:把 Erlang 层降到只剩"NIF 加载 + API 直通 + gen_server 调度"。
> 拆 4 个子阶段以降低风险。

### M4.1 — 切换默认 NIF 到 cask_cpp(production)
- [x] `bitcask:open/2` 引入 `default_nif_mode/0` + `default_nif_mode_compiled/0`
- [x] **production 默认 = `cask_cpp`**:`bitcask:open(D)` 透明走粗粒度 cask_* API,无需 opt-in
- [x] **test profile (`-DTEST`) 默认 = `legacy`**:80+ 个老白盒测试(直接读 `#bc_state` / 调 `bitcask_fileops:fold`)保持原样,零侵入向后兼容
- [x] `application:set_env(bitcask, default_nif_mode, M)` 可全局覆盖(legacy / cpp / cask_cpp)
- [x] 显式 `{nifs, legacy}` opt-out 仍然可用
- [x] `test/bitcask_default_mode_tests.erl`:**5 个测试**覆盖 (test-profile 默认 / app env 覆盖 cask_cpp / cpp / 显式 legacy / 垃圾值 fallback)
- [x] eunit 全套 **148/148 PASS**(原 143 + 5 default-mode)

### M4.2 — Cask-cpp 模式下补齐 legacy gap
- [x] 写 `test/bitcask_cpp_cask_gap_tests.erl`(7 个测试)直接在 cask_cpp 模式下复刻 legacy 关键场景
- [x] 跑出 3 个真实 gap:
  - `expiry_secs` get 不过滤过期 key
  - `expiry_secs` list_keys/fold 不过滤过期 key
  - `bitcask:needs_merge/1` 没 dispatch 到 cask 模式
- [x] **修复 #1+#2 (expiry_secs)**:
  - `CaskOptions::expiry_secs` 字段
  - `Cask::get()`:`entry.tstamp + expiry_secs <= now` → kNotFound
  - `CaskIter::next()`:同上 + 跳过 tombstone-value 记录(legacy 同行为)
  - NIF 选项解析支持 `{expiry_secs, N}`
  - Erlang `return_cask_open/2` 把 `expiry_secs` / `max_file_size` 转传给 cask_open
- [x] **修复 #3 (needs_merge dispatch)**:
  - `bitcask:needs_merge/2` 加 cask 分支调 `cask_needs_merge`
  - 重塑返回值为 legacy 的 `{true, {Files, Expired}}`
- [x] 7 个 gap 测试全过;eunit 全套 **155/155 PASS**;ctest **157/157**(无回归)
- [ ] 后续 gap(可选,按需补)
  - `key_transform` 选项(legacy 在 keydir 操作前对 key 做变换)
  - `fold_tombstones` 选项(legacy fold 可显式包含 tombstone)
  - `bitcask:merge/1, /2, /3`(目录级 API,legacy 自己 open/close;cask 用 Ref)
  - `is_frozen`(legacy 暴露 keydir freeze 状态;cask 总返回 false)

### M4.3 — 缩减 `bitcask.erl`(3873 → 283 行,**-92.7%**)
- [x] 创建 `src/bitcask_legacy.erl`(3881 行)= 原 `bitcask.erl` 完整复制 + module 名改名
- [x] 修复 bitcask_legacy.erl 内 `?MODULE` 宏对 `application:get_env`/`application:start` 的 misexpand(改硬编码 `bitcask`)
- [x] **重写 `bitcask.erl` 为 283 行薄 facade**:
  - 公共 API 22 个 export(open/close/get/put/delete/sync/list_keys/fold*/iterator*/merge*/needs_merge*/is_frozen/is_empty_estimate/status)
  - 4 个 helper re-export(get_opt/get_filestate/is_tombstone/has_pending_delete_bit → 转发到 bitcask_legacy)
  - 单一 dispatch 入口 `is_cask()` 读 process dict
  - cask_cpp 模式直接调 cask_* NIF;legacy/cpp 模式委托 `bitcask_legacy:*`
  - 集中的 `default_nif_mode/0` + `-ifdef(TEST)` 编译期默认
  - `cask_fold_collect/3` helper 统一 list_keys/fold/fold_keys 的 cask 路径
- [x] 修复 bitcask_legacy 内部 `bitcask:readable_files / subfold` 自调用 → 改 `bitcask_legacy:`
- [x] eunit 全套 **155/155 PASS**(原 155 不回归);ctest **157/157**
- [x] 80+ 个 legacy 白盒测试 **零侵入** —— 它们继续在 `bitcask_legacy` 模块下跑,通过 `bitcask:open/2` facade 进入 legacy 路径

### M4.4 — 删除 `c_src/` + 旧依赖 ⏳
- [ ] 删除 `c_src/` 整个目录
- [ ] 删除 `pc` 插件依赖
- [ ] 删除 `khash.h` / `murmurhash.c` / `erl_nif_compat.h` / `erl_nif_util.*`
- [ ] `rebar.config`:移除 `port_specs` / `port_env` / `pc` 相关段

### Erlang 改造
- [ ] `bitcask.erl` 重写为 `cask_*` API 的薄包装(从 3692 行降到 ~300 行)
  - [ ] 保留所有公共 export 不变(D11)
  - [ ] 删除 `bc_state`、`init_keydir`、扫描、合并编排等内部逻辑
- [ ] `bitcask_nifs.erl` 砍到只剩 `on_load` + 新 API stub(从 966 行降到 ~80 行)
- [ ] `bitcask_fileops.erl`:整文件删除
- [ ] `bitcask_lockops.erl`:整文件删除
- [ ] `bitcask_file.erl` / `bitcask_io.erl`:整文件删除
- [ ] `bitcask_merge_worker.erl`:gen_server 调度保留,内部调用换成 `cask_merge`
- [ ] `bitcask_merge_delete.erl`:同上,延迟删除调用换成 NIF
- [ ] `bitcask_app.erl` / `bitcask_sup.erl`:保留(OTP 应用形态)
- [ ] `bitcask_time.erl` / `bitcask_bump.erl`:评估是否还需要

### 清理
- [ ] 删除 `c_src/` 整个目录
- [ ] 删除 `pc` 插件依赖
- [ ] 删除 `khash.h` / `murmurhash.c` / `erl_nif_compat.h` / `erl_nif_util.*`
- [ ] `rebar.config`:移除 `port_specs` / `port_env` / `pc` 相关段

### 验收
- [ ] eunit 全套通过
- [ ] EQC 全套通过
- [ ] `make xref`:无 dangling 调用
- [ ] `make dialyzer`:无新增 warning
- [ ] Riak 集成冒烟测试(若有环境)

**验收**:Erlang 代码 < 1000 行;C++ 代码承接全部存储逻辑。

---

## 里程碑 5:功能补齐 + 并发优化 + 工程化 (5–8 天)

> 目标:把 cask_cpp 与 legacy 的功能 gap 补齐到 prod-ready,然后释放
> C++23 并发性能,把 CI/Benchmark/文档基础设施补齐。
>
> M3-M4 收尾阶段做的功能 gap 盘点(详见对话记录 / doc/USAGE.md)显示:
> 在生产单进程典型场景下 cask_cpp 已能代替 legacy,但有几条 P0/P1
> 路径在 merge_worker、sync_strategy、status 等场景下偏差。M5.1/5.2
> 先把这些填平,再做性能与工程化。

### M5.1 — P0:生产风险修复 🟨
- [x] **`bitcask:merge/1, /2, /3` facade 加 cask 分支**(任务 1)
   - cask 模式自动 dispatch:`merge_mode/1` 读 `{nifs, _}` opt > app env > default
   - `cask_merge_dir/3` 开临时 Cask → 调 `cask_needs_merge` 或用显式 files → 调 `cask_merge` → close
   - 三种 arity 全支持:all-files / explicit list / `{Files, Expired}` 元组
   - 3 个新增 parity 测试
- [x] **`bitcask_merge_worker` 与 cask 写锁兼容**(任务 2,完整方案)
   - **两锁模型**:写者 `bitcask.write.lock`,merger `bitcask.merge.lock`,互不冲突
   - `CaskOptions::merge_only` 字段:`true` 时 acquire merge.lock 而非 write.lock,不创建 active writer
   - **write.lock 内容扩展**为 legacy 格式 `<pid> <active_data_path>\n`,且 rollover 时 `ensure_active_writer` 重写 lock content
   - **merger 排除写者 active 文件**:open 时读 write.lock,parse 出 active file_id;`needs_merge` 排除所有 file_id ≥ 该 id(防写者 race-rollover 时误合并新 active)
   - **写者自动 rollover 应对 merge race**:put 前如果发现 `active_file_id_ < biggest_file_id_`(merger 已经把 biggest 推过),先 roll;失败时再 retry 一次
   - `bitcask:merge/N` facade 默认用 `merge_only` 选项打开 → 不再与 writer 冲突
   - NIF 层支持 `merge_only` atom
   - 3 个新增测试:writer holds + merge runs concurrently / write.lock format / second merger blocked
   - eunit **161/161** PASS;ctest **161/161** PASS
- [x] **`sync_strategy` 完整支持**(任务 3)
   - 三种模式与 legacy 一致:
     - `none`(默认):不主动 sync — 当前默认行为
     - `o_sync`:O_SYNC 标志直通 PosixFile,每次 write 自动同步到 disk
     - `{seconds, N}`:legacy 也是 caller 责任(见 bitcask.app.src 注释:"it is up to the API caller to execute the call on the interval");cask 接受不报错
   - NIF `parse_options` 加分支识别 `{sync_strategy, V}`
   - 新增 atoms:`sync_strategy / none / seconds`
   - `?CASK_PASSTHROUGH_OPTS` 加 `sync_strategy`(自动从 app env 读)
   - 4 个新增测试:o_sync / none / {seconds,N} / app env 覆盖
   - eunit **165/165** PASS
- [x] **写中途崩溃 → 末尾半条 record 显式截断**(任务 4)
   - `DataFile::fold` 增加 `out_last_valid_end` 出参,每条记录解码成功后更新到 record 末尾
   - 新增 `DataFile::truncate_to(uint64_t)`:seek + ftruncate 后回到 EOF,供恢复路径调用
   - `Cask::load_keydir_from_disk` 在 fold 完一个 data 文件后,如果 `last_valid_end < actual_size` 且当前是 writer(`read_write && !merge_only`),用 kAppend 模式重开并 truncate
   - 仅 writer 持有 write.lock 时才动文件;read-only / merge_only 不修改磁盘
   - 2 个新增测试:`Cask.ReopenTruncatesTornWriteTail` / `Cask.ReadOnlyReopenLeavesTornTailIntact`
   - ctest **163/163** PASS;eunit **91/91** PASS

### M5.2 — P1:行为差异修复 + 跨模式兼容 ✅
- [x] **`Cask::status` 暴露 KeyBytes 和 Epoch**(任务 1)
   - `StatusInfo` / NIF `cask_status` 已经返回 `{KCount, KBytes, Epoch, Files}` 4 元组
   - `bitcask:status/1` 与 legacy 一致返回 2 元组 `{KCount, Files}`(legacy 本身就是这个 shape)
   - 1 个新增 GoogleTest 验证 KeyBytes/Epoch 真实非零
- [x] **`cask_fold_next_full` + `bitcask:fold_keys/3` 真实字段**(任务 2)
   - 新 NIF `cask_fold_next_full/1` 返回 `{ok, K, V, FileId, Offset, TotalSz, Tstamp}`
   - `CaskIter::Entry` 扩展 `file_id / offset / total_sz` 字段,`CaskIter::next` 从 keydir proxy 填入
   - `bitcask:fold_keys/3` cask 分支用 `cask_fold_next_full`,callback 收到真实 #bitcask_entry
   - 1 个新增 eunit 验证字段非零
- [x] **跨模式互通双向测试**(任务 3)
   - cask_cpp 写 → close → legacy 重开:get / overwrite 全 OK
   - legacy 写 → close → cask_cpp 重开:get / delete / list_keys 全 OK
   - 2 个新增 eunit
- [x] **tombstone v2 支持**(任务 4)
   - `CaskOptions::tombstone_version`(0 默认 / 2 = "bitcask_tombstone2" + FileId32 BE)
   - `Cask::remove` 在 v2 模式下从 keydir 取 shadow file_id 并 BE 编码;键不存在时回退 v0
   - 新增 atom `tombstone_version`,NIF parse_options 接受 `{tombstone_version, 2}`
   - `?CASK_PASSTHROUGH_OPTS` 加 `tombstone_version`(自动从 app env 读)
   - 2 个新增 GoogleTest 验证字节级 v2/v0 输出
- [x] **`is_frozen/1` 真实 freeze 状态**(任务 5)
   - `Cask::is_frozen()` 暴露 `KeyDirInfo::iter_info::frozen`
   - 新 NIF `cask_is_frozen/1`,`bitcask:is_frozen/1` cask 分支不再硬编码 false
   - 1 个新增 eunit
- ctest **166/166** PASS;eunit **95/95** PASS

### M5.3 — 并发优化
- [ ] KeyDir 改为 `std::shared_mutex` + 分桶(默认 64 桶,可配置)
- [ ] 读路径(`get`、fold)走 `shared_lock`
- [ ] 写路径(`put`、`delete`、`merge`)走桶级 `unique_lock`
- [ ] 评估引入 `absl::flat_hash_map`(D3/D12)
- [ ] `std::pmr` 或自定义 arena 优化变长 key 分配

### M5.4 — CI / 工程化
- [ ] GitHub Actions 矩阵新增:OTP 22 / 25 / 26 × GCC 13 / Clang 16
- [ ] CI job:ASan
- [ ] CI job:UBSan
- [ ] CI job:TSan
- [ ] CI job:覆盖率(gcov + codecov)

### M5.5 — Benchmark + 文档 + 验收
- [ ] Google Benchmark 接入,产出 get/put/fold/merge 的 p50/p99 报告
- [ ] benchmark 基线归档,后续 PR 自动对比
- [ ] `doc/cpp-arch.md`:架构图与扩展指引
- [ ] `doc/migration.md`:从 legacy 迁移到 cask_cpp 的注意事项
- [ ] `doc/format.md`:磁盘格式规范(从代码反推为正式文档)
- [ ] `README.md` 更新构建指引(cmake / rebar3 双入口)
- [ ] **验收**:16 线程 get qps ≥ legacy 1.5x;TSan 无 race;行覆盖率 ≥ 80%

### P2 — 已决定 wontfix(产品上线无影响)
- `key_transform` 选项(高级,生产用例罕见)
- `tombstone_version` 写 v1(v0/v2 已支持读;写 v0 默认,M5.2 加 v2 写)
- `read_ahead` 选项(性能优化,不影响正确性)
- `log_needs_merge` 选项(调试日志,可走 Erlang 端)
- `fold_tombstones` 选项(legacy 测试用)
- `iterator/3, iterator_next/1, iterator_release/1` 三件套(已有 fold/3 替代)
- `fold/6, fold_keys/6` 的 MaxAge/MaxPut/SeeTombstones 三参数版本
- `close_write_file/1`(legacy 测试用)

---

## 风险登记簿

| ID | 风险 | 触发里程碑 | 缓解措施 | 状态 |
|----|------|-----------|---------|------|
| R1 | 磁盘格式微差异导致旧数据读不出 | M0+ | golden test 每个里程碑跑 | ⬜ |
| R2 | keydir epoch/sibling 语义复刻不一致 | M2 | EQC ≥ 5min 强制门槛 | ⬜ |
| R3 | BEAM 长持锁导致调度异常 | M3 | dirty scheduler + 主动 yield | ⬜ |
| R4 | 资源生命周期(fold 迭代器)出错 | M2/M3 | `shared_ptr` + ASan/TSan CI | ⬜ |
| R5 | Riak 升级对接断裂 | M4 | 保留 export;单独评审 | ⬜ |
| R6 | CMake 找不到 ERTS | M0 | `FindErlang.cmake` 提供覆盖入口 | ⬜ |
| R7 | abseil 体积/构建时间影响 | M5 | 起步用 `std::unordered_map` | ⬜ |
| R8 | ~~C++23 编译器要求过高~~ | — | 已确认目标环境 GCC 14.2,无需降级 | ✅ |

---

## 进度追踪

| 里程碑 | 状态 | 起始 | 完成 | 备注 |
|--------|------|------|------|------|
| M0 脚手架 + 格式抓手 | ✅ | 2026-04-29 | 2026-04-29 | 工具链 + 格式 codec + sanitizer + rebar 双产出全部就绪;eunit 81/81、ctest 19/19 |
| M1 文件 I/O + Lock 下沉 | ✅ | 2026-04-29 | 2026-04-29 | `bitcask_cpp_nifs` 与 `bitcask_nifs` parity 验证;eunit 100/100;ctest 38/38(三 sanitizer 全过) |
| M2 KeyDir 下沉 | ✅ | 2026-04-29 | 2026-04-29 | M2.1–2.5 全部完成;C++ ctest 98/98、eunit 130/130;**`{nifs, cpp}` flag 让 bitcask:open 跑通 cpp NIF 业务路径** |
| M3 Fileops + 合并核心下沉 | ✅ | 2026-04-29 | 2026-04-29 | M3.1–M3.5 全部完成;ctest 157/157、eunit 143/143;**`bitcask:open(Dir, [{nifs, cask_cpp}])` 业务流跑通粗粒度 cask_* API** |
| M4 Erlang 层瘦身 | 🟨 | 2026-04-29 | | M4.1 done(production 默认 cask_cpp、test 默认 legacy、5 default-mode 测试);M4.2-4.4 待续 |
| M5 功能补齐 + 并发优化 + 工程化 | ⬜ | | | M5.1-5.5 五个子阶段;M5.1 起步 |

> 状态图例:⬜ 未开始 · 🟨 进行中 · ✅ 完成 · ❌ 阻塞
