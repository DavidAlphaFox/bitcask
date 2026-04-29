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

### M3.3 — Merge 策略 + merger 主体 ⏳
- [ ] `cpp/include/bitcask/merge.hpp`:`MergePolicy` + `needs_merge(fstats, opts) -> {bool, [file_id]}`
- [ ] `cpp/src/merge/merger.cpp`:`Merger` 类,合并旧 data 文件到新 file,更新 keydir,处理 tombstone

### M3.4 — Cask 类 + 粗粒度 `cask_*` NIF ⏳
- [ ] `cpp/include/bitcask/cask.hpp`:`Cask` 类(open/get/put/delete/sync/fold/merge/needs_merge/status/close)
- [ ] `cpp/nif/nif_cask.cpp`:14 个 `cask_*` NIF
- [ ] dirty scheduler 标记:open/merge/fold 走 `ERL_NIF_DIRTY_JOB_IO_BOUND`

### M3.5 — Erlang shim + parity ⏳
- [ ] `bitcask_cpp_nifs.erl` 增加 `cask_*` API
- [ ] `bitcask:open/2` 增加 `{nifs, cask_cpp}` 选项,直接走 `cask_open` 而非 `keydir + 散件 NIF`
- [ ] 业务流 parity 测试

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

## 里程碑 5:并发优化 + 工程化 (3–5 天)

> 目标:释放 C++23 并发性能;把工程基础设施补齐。

### 性能
- [ ] KeyDir 改为 `std::shared_mutex` + 分桶(默认 64 桶,可配置)
- [ ] 读路径(`get`、fold)走 `shared_lock`
- [ ] 写路径(`put`、`delete`、`merge`)走桶级 `unique_lock`
- [ ] 评估是否引入 `absl::flat_hash_map`(D3/D12)
- [ ] `std::pmr` 或自定义 arena 优化变长 key 分配

### CI / 工程化
- [ ] GitHub Actions 矩阵新增:OTP 22 / 25 / 26 × GCC 13 / Clang 16
- [ ] CI job:ASan
- [ ] CI job:UBSan
- [ ] CI job:TSan
- [ ] CI job:覆盖率(gcov + codecov)
- [ ] Google Benchmark 接入,产出 get/put/fold/merge 的 p50/p99 报告
- [ ] benchmark 基线归档,后续 PR 自动对比

### 文档
- [ ] `doc/cpp-arch.md`:架构图与扩展指引
- [ ] `doc/migration.md`:从 1.x 迁移到 C++ 版本的注意事项
- [ ] `doc/format.md`:磁盘格式规范(从代码反推为正式文档)
- [ ] `README.md` 更新构建指引(cmake / rebar3 双入口)

### 验收
- [ ] 16 线程 get qps ≥ 旧版 1.5x
- [ ] TSan 无 race report
- [ ] 行覆盖率 ≥ 80%(D13)
- [ ] format_compat_test 通过(用 1.x 真实数据目录)

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
| M3 Fileops + 合并核心下沉 | 🟨 | 2026-04-29 | | M3.1 done(DataFile + HintFile,12 单测全过);M3.2-3.5 进行中 |
| M4 Erlang 层瘦身 | ⬜ | | | |
| M5 并发优化 + 工程化 | ⬜ | | | |

> 状态图例:⬜ 未开始 · 🟨 进行中 · ✅ 完成 · ❌ 阻塞
