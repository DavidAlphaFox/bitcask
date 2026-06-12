# M6:KeyDir 分片设计(定稿,待实施)

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

## 4. fold(MVCC)协议:全屏障冷路径

方案 B 定稿——fold 是冷路径,用 stop-the-world 屏障换实现简单与
逐字保留现有 sibling/pending 语义:

- **iter start**:按下标序拿全部 shard unique + meta unique →
  置 keyfolders_/iter_generation_、build keys_snapshot_(跨分片归并)、
  freeze pending_ → 全部释放。屏障期间写者短暂排队(冷路径可接受)。
- **写路径感知**:put/remove 在**持有自己分片锁后**读
  `keyfolders_(atomic)`。=0 → 直写;>0 → 沿用现有 sibling 升链
  (分片锁内)/新 key 走 pending_(meta_mu_ unique)。
  时序论证:若 put 读到 0 而屏障紧随其后,该写的 epoch < iter epoch,
  对迭代器可见且一致——等价于"屏障前完成的写";屏障无法在 put 持
  分片锁期间完成(unique 等待)。
- **next()**:meta shared(查 pending)→ 该 key 分片 shared。两段不
  嵌套(先后获取、各自释放),锁序恒 meta→shard,无死锁环。
  pending→entries 迁移窗口的 TOCTOU:先查 pending 后查分片,release
  合并方向是 pending→entries,顺序保证不漏(miss pending ⟹ 已并入
  entries ⟹ 分片查得到)。
- **release**:同 start 的全屏障,在屏障内逐字复用现有
  merge_pending_and_collapse 逻辑(全独占下原实现语义不变)——
  障碍清单里"唯一要认真 MVCC 推演"的第 5 项就此消解。

## 5. 其余操作

- get:meta shared(仅当 frozen,先查 pending)→ shard shared。
- conditional_remove(merge CAS):shard unique,逻辑不变。
- deep_copy/info/save_snapshot(A4):全屏障(均为冷路径/静止点)。
- load_snapshot(A4):open 期单线程,entries 按 hash 分发进各分片;
  BCKS 格式不变(磁盘上无分片概念,重分片自由)。

## 6. 锁序与不变量(评审清单)

1. 全序:meta_mu_ → shards_[0..n)(下标升序)→ fstats_grow_mu_;
   任何路径禁止逆序持有。
2. 热路径(get/put/remove 非 fold 态)至多 1 把锁(自己分片)。
3. keyfolders_ 只在全屏障内修改;分片锁内读取即足够新。
4. epoch 分配(fetch_add)在分片锁内完成,保证"entry.epoch < iter
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
6. 新增 has_pending_ 原子镜像:deep_copy 副本可能 keyfolders_==0 但
   pending_ 仍在,写路径不能只看 keyfolders_。
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
