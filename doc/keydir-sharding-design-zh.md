# M6:KeyDir 分片设计(已实施)

> 动机数据:`BM_KeyDir_Mixed_MultiThreaded`(90% get + 10% put 覆写):
> 1t 23.6M ops/s → 8t **0.22M ops/s(-100×)**。M5.3 实测结论:锁类型
> 无解(临界区亚微秒,锁字 cache-line ping-pong 主导),唯一出路是
> 让不同 key 不共享锁字。障碍清单初版见 cpp-optimization-zh.md §8.2。

## 1. 结构

```cpp
static constexpr std::size_t kShards = 16;   // 2^n,hash 低位路由
struct Shard {
    mutable std::shared_mutex mu;
    std::unordered_map<std::string, Entry, StringHash, std::equal_to<>> entries;
    // 按 64B 对齐隔离,防伪共享
};
std::array<Shard, kShards> shards_;
mutable std::shared_mutex meta_mu_;          // pending_/iter 协调专用
```

shard = StringHash{}(key) & (kShards-1)。每 key 操作只触自己分片的锁字。

## 2. 全局状态的去锁化(热路径零全局锁)

| 状态 | 现状 | 分片后 | 备注 |
|---|---|---|---|
| epoch_ | 大锁内 ++ | `atomic<u64>` fetch_add | 全局逻辑钟保持全局,只是无锁 |
| next_ord_ | 已 atomic | 不变 | — |
| key_count_/key_bytes_ | 大锁内 | atomic | info() 读近似一致即可 |
| biggest_file_id_ | 大锁内 | atomic CAS-max | — |
| fstats_ | 大锁内更新 | **AtomicFStats + 无锁读路径** | 见 §3,不能换成第二把全局锁(M5.3 教训会原样复发) |
| pending_/iter 协调 | 大锁 | meta_mu_(仅 fold 期间触碰) | 冷路径 |

## 3. fstats:发布式无锁热路径

`std::deque<AtomicFStats>`(元素地址稳定)+ `atomic<size_t> fstats_size_`:

- 读/累加:`idx < fstats_size_.load(acquire)` ⟹ 槽位已构造完毕,
  直接对字段做 `fetch_add(relaxed)`;oldest/newest/expiration 用
  CAS-min/max 循环;
- 增长(新 file_id,罕见):`fstats_grow_mu_` 串行构造新槽,
  `fstats_size_.store(release)` 发布;
- trim/info:grow_mu_ + 逐槽原子读快照。

put 热路径自此**零锁字共享**(分片锁字 + 纯 relaxed 原子)。

## 4. fold(MVCC)协议:屏障 v2(写者闸门)

### 4.0 方案演进

初版方案 B(stop-the-world 全屏障)在屏障期间**同时持有全部分片锁 +
meta**(kShards=256 后即 257 把)。S5 把 kShards 推到 256 后撞上 TSan
死锁检测器的 **64 持锁硬上限**——compiler-rt
`sanitizer_deadlock_detector.h:67` 的
`CHECK_LT(dtls->getNumLocks(), kMaxLT)`,实测屏障类全量遍历操作
(save_snapshot / 全量 fold)在 `TSAN_OPTIONS=detect_deadlocks=1` 下
必崩(CHECK failed)。该方案废弃,重构为**写者闸门屏障**:任意瞬间至多
持 1 把分片锁,语义不变,且屏障期间读者照常并发(旧方案的全独占锁顺带
挡住了读者,是过强的副作用)。

### 4.1 屏障 v2 协议

新增成员:`atomic<bool> barrier_active_`、`barrier_mu_`(屏障间互斥,
跨整个屏障持有)、`gate_mu_`/`gate_cv_`(写者退避等待)。

- **BarrierGuard(RAII,keydir.cpp 内部)**:
  - ctor:`barrier_mu_.lock()` → gate_mu_ 内置 `barrier_active_=true`
    → **排干**:逐分片「加锁-放锁」,任意瞬间只持 1 把——保证在途写者
    出清(先于排干持分片锁的写者被排干循环等待;晚于排干拿锁的写者经
    mutex 配对必见 active,退避)。
  - dtor:gate_mu_ 内置 `barrier_active_=false` → `notify_all` →
    放 barrier_mu_。
- **写者侧**(put / remove;conditional_remove 的只读 peek **不**检查
  闸门,其写阶段调 remove() 自带检查):拿到分片锁后立即查
  `barrier_active_(acquire)`;active 则**先放分片锁**再到 gate_cv_
  等待,唤醒后重拿分片锁循环重查。
- **读者(get/next/conditional_remove peek/info)不受闸门限制**,屏障
  期间照常并发——这是与旧方案的关键语义差异,逐调用方保证读者视角
  无缝(见 4.2)。
- **写路径 fold 感知不变**:闸门检查通过后读 `keyfolders_(relaxed)`。
  =0 → 直写;>0 → sibling 升链(分片锁内)/新 key 走 pending_
  (meta unique)。时序论证更新:闸门读到 inactive 的写者要么先于排干
  循环持有分片锁(排干在该分片等它出清,屏障内的 keyfolders_ 修改
  整体在其后),要么经排干循环的 mutex 配对必见 active 退避——
  「读到 0 → 直写」的写仍一定整体先于屏障。

### 4.2 各屏障调用方(读者无缝论证)

1. **save_snapshot / iter start(keys_snapshot 构建)**:
   屏障内全是**纯读**,写者已出清 → 遍历各分片 entries **不需要任何
   分片锁**(unordered_map 并发只读安全;与读者的持锁 find 是读-读
   并发)。meta 状态读取(save 的 keyfolders_ 检查、start 的 freeze
   判定/keyfolders_++/pending 初始化)在屏障内拿 meta unique 做——
   此刻不持任何分片锁,锁序 barrier→gate→meta 无环。
2. **iter release 的合并(写操作!)三阶段**——唯一精细处:
   - 阶段一[meta unique]:keyfolders_--;非最后一个 folder → 直接
     返回;是最后一个 → 继续(**不在此清 pending**);
   - 阶段二[meta **shared** 持有期间]:遍历 pending_ 每条,**嵌套拿该
     key 分片锁**应用进 entries,放分片锁。这是 meta→shard 方向,与
     常规锁序相反——**仅屏障内合法**:写者已被闸门出清(meta unique
     使用者不存在),唯一并发者是读者,读者对 meta 只拿 shared
     (shared-shared 相容,无 unique 排队者,无法构成环);
   - 阶段三[meta unique,不持分片锁]:pending_.reset()、
     has_pending_=false。**先应用后清表** ⟹ 读者在窗口内要么 entries
     命中(探测顺序 entries 优先)要么 pending 命中,无丢失窗口;
   - 之后 MultiEntry 折叠:逐分片「lock → 折叠该分片全部链 → unlock」
     (读者按分片锁协议安全;折叠前后单 key 可见值不变:链头即最新)。
3. **load_snapshot**:open 期单线程,用 BarrierGuard 统一即可,内部
   逻辑不变(直填分片)。

## 5. 其余操作

- get:meta shared(仅当 frozen,先查 pending)→ shard shared。
- conditional_remove(merge CAS):shard unique,逻辑不变。
- save_snapshot(A4):写者闸门屏障(§4 屏障 v2;冷路径/
  静止点);info 仅 meta shared。
- load_snapshot(A4):open 期单线程,entries 按 hash 分发进各分片;
  BCKS 格式不变(磁盘上无分片概念,重分片自由)。

## 6. 锁序与不变量(评审清单;屏障 v2 更新)

1. 全序:**barrier_mu_ → gate_mu_ → meta_mu_ → 单个 shard(任意时刻
   ≤1 把)→ fstats_grow_mu_**。任何路径任意时刻至多持 1 把分片锁
   (旧"全部分片锁"屏障因 TSan 64 持锁上限废弃,见 §4.0)。
2. 与全序相反的两处嵌套(均有无环论证,见 keydir.hpp 文件头):
   - 热路径 get/put/remove 持单个分片锁后嵌套 meta(shard→meta,
     S2 起的既有方向,堵 release 合并窗口 TOCTOU);
   - **屏障内例外**:iter release 阶段二在 meta shared 持有期间嵌套
     分片锁(meta→shard)。合法性:屏障内写者已出清、无 meta unique
     持有/等待者,读者与阶段二对 meta 均只拿 shared——无环。
3. 热路径(get/put/remove 非 fold 态)至多 1 把锁(自己分片)+
   写者一次 barrier_active_ 原子读(闸门检查)。
4. keyfolders_ 只在屏障(BarrierGuard + meta unique)内修改;写者
   闸门检查通过且持分片锁后 relaxed 读即足够新(§4.1 时序论证)。
5. epoch 分配(fetch_add)在分片锁内完成,保证"entry.epoch < iter
   epoch ⟺ 屏障前完成"的可见性判据不变。

## 7. 实施阶段(各自可验证)

| 步 | 内容 | 验证 |
|---|---|---|
| S1 | 全局标量原子化(epoch/key_count/key_bytes/biggest_file_id)+ fstats §3 | 全量测试 + Mixed 基准(写路径仍大锁,预期小improve) |
| S2 | entries_ 切 16 分片,get/put/remove/conditional_remove 改分片锁(fold 仍走全屏障粗化:start 即屏障) | 全量 + TSan(全插桩门禁)+ Mixed 基准主验收 |
| S3 | iter next() 细化为 meta+shard 两段锁 | fold 并发测试 + TSan |
| S4 | A4 快照路径接分片(save 屏障/load 分发) | A4 三测试 + eunit |
| S5 | 基准定稿:Mixed 1/2/4/8t 进 baseline.json;目标 8t ≥ 1t 的 4×(>90M ops/s 量级),至少不再倒缩 | — |

**验收红线**:`BM_KeyDir_Mixed_MultiThreaded/8t` 不再低于 1t;
`BM_KeyDir_Get_MultiThreaded/4t` 摆脱负扩展。TSan 全插桩 357+ 全绿。

## 8. before 基线(2026-06-12,本机)

| 线程 | Mixed ops/s | Get-only ops/s |
|---|---|---|
| 1 | 23.6M | 27.3M |
| 2 | 2.9M | 7.2M |
| 4 | 0.70M | 4.0M |
| 8 | 0.22M | 3.0M |

## 9. S2 实测(2026-06-12,本机,repetitions=3 mean)

before = S1 完成态(标量已原子、fstats 已无锁,entries 仍全局锁)实测;
after = S2(16 分片)落地后。

| 负载 | before(S1) | after(S2) | 倍率 |
|---|---|---|---|
| Mixed 1t | 22.2M | 21.2M | 0.96× |
| Mixed 2t | 2.66M | 11.5M | 4.3× |
| Mixed 4t | 1.06M | 2.66M | 2.5× |
| Mixed 8t | 0.227M | 1.22M | 5.4× |
| Get 1t | 27.9M | 26.8M | 0.96× |
| Get 2t | 7.46M | 20.4M | 2.7× |
| Get 4t | 3.17M | 15.2M | 4.8× |
| Get 8t | 2.44M | 13.2M | 5.4× |
| Put_Overwrite 1t | 16.9M | 17.4M | 1.03× |

门禁:plain/ASan/TSan(全插桩)ctest 357/357,eunit 44/44。

实施偏差(相对 §4/§5 草案,均已写入代码注释):

1. **锁序反转为 shards→meta**(草案 §6 写 meta→shards)。get/put/remove
   在持分片锁后嵌套拿 meta 查 pending——持分片锁不放堵死 release 合并
   窗口的 TOCTOU;全屏障也改为先分片后 meta,全库一致。
2. **探测顺序 entries→pending**(legacy 是 pending→entries),配套新不变量
   「key ∈ entries ⟹ pending 无其更新版本」:已存在 key 的 put 覆写 /
   remove 墓碑一律在分片内升 sibling 链,pending 只收 fold 期全新 key。
   由此 remove 在 frozen 态对 entries 命中 key 不再写 pending 墓碑
   (顺带修复旧实现「freeze 复用的后启 fold 看不到 remove」的不一致;
   代价:此类 remove 不再计入 pending_updated_/maxputs)。
3. **next() 已直接是单分片锁**(keys_snapshot 全来自 entries,fold 期间
   entries 键集只增不减,无需触 meta/pending)——S3 的主体随 S2 落地。
4. **A4 save/load 已接分片**(save 全分片 shared 屏障,load 按 shard_for
   分发,BCKS 磁盘格式不变)——S4 主体随 S2 落地。
5. iter_mutation_ 是写-only 诊断位,做成 atomic<bool> 而非挂 meta_mu_,
   避免 sibling 升链热分支为它单独抢 meta。
6. 新增 has_pending_ 原子镜像:release 收尾窗口里 keyfolders_ 可能已归零
   但 pending_ 仍在应用中,写路径不能只看 keyfolders_。
7. 热原子按缓存行分组:epoch_/next_ord_/key_count_/key_bytes_(写热行)
   与 keyfolders_/biggest_file_id_/has_pending_/is_ready_(读热行)隔离,
   Shard 内 map 头与锁字分行。

剩余瓶颈(S5 输入):Mixed 4t/8t real-time 远大于 CPU-time(4t 375ns vs
175ns),主因是 10% 写者拿分片 unique 引发 rwlock futex 停车 + epoch_/
fstats 槽位真共享 RMW。8t 仍低于 1t(1.22M vs 21M),§7 红线「8t ≥ 1t」
留给 S5:候选手段 = 分片数加大(16→64+)、读路径 seqlock/RCU 化、
fstats 槽位 per-shard 化。

## 10. S5 收敛实测(2026-06-12,本机,repetitions=3 median)

两级杠杆,按便宜优先逐级实测:

| 配置 | Mixed 1t | Mixed 4t | Mixed 8t | Get 1t | Get 8t |
|---|---|---|---|---|---|
| S2(16 分片,rwlock) | 21.2M | 2.7M | 1.26M | 26.8M | 13.2M |
| 64 分片,rwlock | 20.9M | 7.4M | 3.21M | 26.5M | 18.5M |
| 256 分片,rwlock | 22.3M | 11.6M | 5.54M | — | — |
| **256 分片,std::mutex(定稿)** | **24.8M** | **13.8M** | **8.34M** | **31.9M** | 17.1M |

定稿决策:**kShards=256 + 分片锁 std::mutex**。
- mutex 替换 rwlock 的依据:Mixed 4t real 369→73ns(写者偏好引发的
  读者 futex 停车几乎消除);单线程读反而 +20%(mutex 加解锁本身更便宜);
  代价是同分片并发读互斥——256 分片下碰撞率足够低,Get/8t 仅 -8%。
- 红线复盘(诚实):「8t ≥ 1t」聚合吞吐**未达成**(8.34M vs 24.8M)。
  达成的是:崩塌消除(0.22M → 8.34M,**37×**)、各档单调可用、单线程
  全面无回退。残余差距归因:① epoch_ 全局 RMW(每写一次,设计即全局
  逻辑钟);② 基准 10% 写全打同一 file_id 的 fstats 槽(真共享,与
  生产"单 active 文件"形态一致);③ 本机 P/E 混合核,8 线程含 E 核拉低
  聚合。进一步收敛(per-shard epoch 域 / fstats 写侧分片聚合)收益
  预估有限且复杂度高,**有意止步**——记录为 M6 关账状态。
- baseline.json 已刷新(cpp/bench/baseline/,含 Mixed 全档)。

## 11. 屏障 v2(写者闸门)实测(2026-06-12,本机)

动机回顾(§4.0):旧全屏障同时持 257 把锁,TSan 死锁检测器
(detect_deadlocks=1)64 持锁上限 CHECK 崩溃,屏障类全量遍历操作
必现。重构后任意瞬间 ≤1 把分片锁。

门禁结果(全部通过):

| 门禁 | 结果 |
|---|---|
| plain ctest | 371/371 |
| TSan `bitcask_keydir_test`(detect_deadlocks=1,原崩溃环境) | 8/8 通过,DeepCopyPreservesOrd OK(该测试已于 2026-06-15 随 deep_copy 删除) |
| TSan 全量 ctest(detect_deadlocks=1 已固化进 ENVIRONMENT) | 371/371 |
| ASan(address,undefined)全量 ctest | 371/371 |
| eunit(plain .so,ldd 0 tsan) | 44/44 |

基准回归(repetitions=3 median,vs cpp/bench/baseline/baseline.json,
门槛 ±10%):

| 负载 | baseline M/s | 屏障 v2 M/s | Δ |
|---|---|---|---|
| Mixed 1t | 23.71 | 24.30 | +2.5% |
| Mixed 2t | 17.39 | 17.42 | +0.1% |
| Mixed 4t | 13.29 | 13.43 | +1.1% |
| Mixed 8t | 7.68 | 8.19 | +6.6% |
| Get 1t | 31.76 | 31.79 | +0.1% |
| Get 8t | 17.04 | 17.21 | +1.0% |
| Put_Overwrite | 19.31 | 19.21 | -0.5% |

热路径新增成本仅为写者一次 `barrier_active_` relaxed-acquire 读
(分片锁内),实测在噪声内;Mixed 8t 的 +6.6% 视为运行间波动,不归功
于本改动。
