# V3:HNSW 向量检索设计(定稿待实施)

> 前置阅读:`vector-db-design-zh.md`(可行性探索与总体定位)、
> `recovery-snapshot-design-zh.md`(A4 快照体系,本设计的持久化模板)、
> `keydir-sharding-design-zh.md` §6(锁序纪律)。
> 边界讨论结论(2026-06-12,与 owner 定稿):引擎**只收向量不算向量**。

## 1. 边界与配置(已定稿,不再讨论)

1. **向量进、近邻出**:embedding 由调用方提供(Erlang 层可选 `embedder`
   behaviour 接外部模型服务);C++ 引擎不含任何 ML runtime。依据:
   ① DocValue v3 vector 段已是 source of truth,merge/恢复不依赖模型;
   ② BM25 内置因分词廉价确定,embedding 是重推理,性质不同;
   ③ BEAM 进程不引入百 MB 级推理依赖(同 tbbmalloc 决策一脉)。
2. **维度:库内恒定、初始化显式配置**:
   ```cpp
   struct VectorConfig {
       std::uint16_t dim;       // 创建时指定;0 = 本集合无向量
       VectorMetric  metric;    // kCosineNormalized(默认)/ kL2 / kDot
   };
   ```
   写入 `bitcask.meta` 扩展节;重开校验,不符 → kModeMismatch;
   **显式配置,不做首写推断**(脏数据不应有定义集合 schema 的权力)。
   per-record 的 `[Dim:varint]` 保留作自描述 + 损坏哨兵,策略上必等于
   meta.dim。
3. **cosine 实现为「写入时归一化 + 内积」**:归一化是引擎内廉价数值
   操作;meta 记 `cosine_normalized`,查询向量同样入口归一化。
4. 多模型/多维度需求的出口:多字段向量(`field → HNSW 图`,沿 S8.6
   `fields_` 同构)——**V3 仅做默认字段单图**,接口留扩展位。

## 2. 数据结构与内存布局

### 2.1 向量驻留:ord 间接 + 平面数组

```cpp
// 内部节点 id:u32,插入序紧凑分配(≤1M 规模,u64 ord 的一半内存)。
std::vector<float>          vecs_;     // node_id * dim 平面寻址,SoA 纪律
std::vector<std::uint64_t>  id2ord_;   // node_id → ord(结果翻译)
// ord → node_id:tbb 或分片 map(删除标记/去重用,写路径低频查)
```

内存账(规模上限指导,非硬限):

| dim | 100k 向量 | 1M 向量 | 图(M=16,1M) |
|---|---|---|---|
| 384 | 0.15 GB | 1.5 GB | ~0.6 GB(邻接 u32) |
| 768 | 0.3 GB | 3.0 GB | 同上 |
| **2560**(qwen3-embedding,已确认部署目标) | **1.0 GB** | 10 GB | 同上 |

规模指导:384/768d 全内存 ≤1M 可行;**2560d 全内存适宜 ≤~300k
(≈3GB),百万级 2560d 必须等 V4 量化(int8 → 2.5GB/1M)**。

**部署目标实测(2026-06-12,192.168.186.1:8080,OpenAI 兼容
/v1/embeddings,model=qwen3-embedding)**:dim=2560,输入上限 32K token,
**输出已 L2 归一化(实测 norm=1.0)**——引擎写入侧归一化对其幂等,
保留不变(兜其它客户端/模型漂移);32K 上限的文本截断是 Erlang 层
embedder behaviour 的职责,引擎不感知。2560 = 8×320,AVX2 内核
整块覆盖无尾循环。

### 2.2 图结构

- 标准 HNSW:分层跳表式图;层数几何分布(mL = 1/ln(M));
  entry_point + max_level 全局两元组。
- 邻接存储:每节点每层一段 u32 数组,**L0 容量 2M、上层 M**
  (hnswlib 惯例);定长槽位 + count 字节,更新原地。
- 默认参数:**M=16,efConstruction=200**;efSearch 为查询参数
  (默认 max(k, 64)),不进 meta。

### 2.3 距离内核

运行时 dim + 编译期特化分发(同 intersect 内核的 cpu-dispatch 模式):
384/768/1024 三条 AVX2 特化 + 通用循环兜底;open 时按 meta.dim 选
函数指针,分发一次。f32 内积/L2;FMA 优先。

**落地记录**:实现取「运行时 n 通用内核」而非 per-dim 特化(32 宽主循环
对 384/2560 均整除,特化无利可图)。V3.2 初版单累加器;**V3.8 改 4 路
独立累加器**(单链 FMA 延迟 ~4cyc 卡在 1 FMA/4cyc,4 路顶到 2 加载/cyc
的访存口上限,内核余量 ~4×)+ **候选向量软件预取**(copy_neighbors 后
预取遍先把未访问邻居向量首 256B 拉向 L1,大图冷 DRAM 取数与距离计算
重叠)。实测(384d,median of 3):查询 100k/ef64 483→322µs(−33%)、
插入 100k 936→1221/s(+30%)。本机(i9-13900H 混合核)无 AVX-512;
AVX-VNNI 留给 V4 int8(vpdpbusd,32 元素/迭代 + 内存流量 4×↓)。

## 3. 并发模型

沿生产既定形态:**单写者(IndexPool worker)+ 多读者(查询线程)**,
多写者不支持(与 SearchLayer 约束一致)。

- **per-node 自旋小锁**(节点邻接更新粒度):写者插入时锁住被改邻接表
  的节点;读者遍历某节点邻居前短暂取同一把锁拷出邻居数组(≤2M 个
  u32,栈上)。锁数组与节点同长,1 字节自旋足够(临界区 ~百 ns)。
- entry_point/max_level:atomic 双字段(版本化或合并进一个 u64,
  避免撕裂);层提升是罕见事件。
- vecs_/id2ord_ 增长:仅写者 push;读者按 `count_` atomic
  发布水位访问(M6-S1 fstats 同款「发布式」手法);predistribute
  reserve 或分段 deque 保地址稳定——**定稿用分段定长 chunk
  (如 64K 节点/段)**,地址稳定且无 realloc。
- 删除:**软删**。LiveChecker 同源(Index.live_):搜索遍历照常路过
  死节点(保持图连通性/导航质量),仅结果集过滤;merge 重建时物理清除。
  这是 hnswlib/Lucene 的标准做法,死点比例高时靠 merge 收敛。
- TSan 全插桩门禁是验收前提(M6 已铺好);并发回归测试比照
  SearchConcurrentWithSingleWriter 形态(N 读者 × 1 写者插入同图)。

### V3.3 实测/偏差(2026-06-12 落地记录)

实现按上述协议落地(`hnsw.hpp/.cpp`),与设计稿的差异与澄清逐条:

1. **「读者可达邻居 id < 其 load 的 count」需要读侧显式定界**。设计稿
   的发布序论证只对"邻居发布先于边发布"成立;但读者的 count 快照可能
   **早于**反向边的追加——旧快照读者沿新追加的反向边可见 `id ≥ 本地
   count`。故读侧(greedy/search_layer)对邻居 id 增加 `nid >= n` 跳过
   (n = 本次 search 开头的 count 快照),visited 数组按 n 定界即安全。
   语义无损:该节点对此读者尚未发布,跳过等价于"晚一拍可见"。
2. **entry 快照顺序**:search 先 load entry_meta_(acquire)再 load
   count_(acquire)。entry 的发布 happens-after 其 count 发布,该序保证
   entry id 必 < 本地 count(反序则可能拿到越界 entry)。
3. **visited 实现取「thread_local + 全局实例 id」**(任务书留的自由度):
   每线程一份 {marks, epoch, owner};owner 用全局自增实例 id 而非 this
   指针(指针 delete/new 复用会让陈旧 marks 与新实例 epoch 假性匹配)。
   owner 切换整组清零;同实例 epoch 自增免清零,回绕清一次。多实例被同
   线程交替查询时退化为每次清零,正确性不受影响(单集合单图常态零开销)。
4. **写者插入时自身可见边界取 n_bound = id**(排除自己):反向边在低层
   先行发布后,写者自己更低层的 search_layer 可能经它走回新节点,把自己
   选成自己的邻居;以 id 为界一并剪掉。
5. **超容收缩在持锁状态下做距离计算**(微秒级临界区,设计稿"~百 ns"仅
   对追加/拷贝成立)。读者只在 copy_neighbors 短暂争同一把锁,实测
   (20k×16d,1 写 4 读,TSan 插桩)无可观测停顿;锁外预选/arena 留 V3.x。
6. **单写者用 writer_active_ 原子守卫 + debug assert 声明**(成员无条件
   存在,避免 NDEBUG 不一致的布局分歧);多写者仍不支持。
7. **接线过渡(V3.5 已撤销)**:HNSW 持久化在 V3.5 之前缺位,
   `load_keydir_from_disk` 曾对 vector_dim>0 的集合**强制全量 fold**。
   V3.5 落 BCVS 快照并入 covers 门(§5),该特判已删除——向量集合
   与 search 集合同走四块快照合取门。
8. **kMaxChunks=1024 定容目录**(上限 64M 节点,assert 越界);邻接块
   per-node `new u32[]`,arena 化留 V3.x(设计稿已注明)。

## 4. 写入与查询路径

```
put_doc(含 vector) → DocValue 编码(vector 段)→ data file(source of truth)
                  → IndexTask → worker:Index.put_doc + bm25 add_doc
                              + hnsw_.insert(ord, vec)     ← V3 新增
search_vector(qvec, k, efSearch?) → 归一化 → HNSW 搜索(live 过滤)
                                  → SearchHit{key, ord, score=相似度}
search_hybrid(query, qvec, k)     → BM25 top-K' ∥ HNSW top-K'
                                  → RRF(k=60)融合 → top-k
```

- RRF:`score = Σ 1/(60 + rank_i)`,K' = max(k×4, 64)(两路各取);
  无需分数归一化,与 vector-db-design 既定一致。
- 过滤式向量检索(bool 条件 + 向量)V3 不做,接口留
  `search_vector(qvec, k, filter_query?)` 形状,实现 V3.x 再议
  (预过滤/后过滤/图内过滤是独立课题)。

### V3.6 落地记录(2026-06-12,search_hybrid + NIF/Erlang 接口)

实现主体在 `SearchLayer::search_hybrid`(Cask 门面只做向量配置校验 +
flush),语义定稿如下:

1. **rank 从 1 起**;只在单路出现的文档照常累加该路项,不做缺路惩罚。
2. **确定性平局序**:RRF 分相等 → ord 小者在前(测试
   V36HybridRrfFusion 用「1/61+1/63 ≡ 1/63+1/61」的精确浮点平局锁死
   该行为,浮点加法可交换故两文档分逐位相等)。
3. **单路退化语义**:text 空 + vec 合法 → 等价纯向量(BM25 路空),
   反之亦然——结果序 = 单路原序,分数被 RRF 重打为 1/61, 1/62, …;
   **两路都空才报错**(kInvalidOption)。无向量配置的集合调 hybrid →
   kInvalidOption(即使纯文本退化也拒——hybrid 属向量集合 API);
   vec 维度不符 → kInvalidOption(经 search_vector 内核校验)。
4. 返回沿用 TextSearchResult,score = RRF 分(替换单路原始分)。
5. **NIF 跨界**:向量 = **f32 LE 二进制**(dim×4 字节 binary,与
   DocValue 存储一致),Erlang 侧 `<< <<X:32/float-little>> || X <- L >>`
   构造;`cask_put` 的 doc map 新增 `vector` 键(坏尺寸/非 binary →
   badarg,不落盘);新增 `cask_search_vector(Ref,VecBin,K,Ef)` /
   `cask_search_hybrid(Ref,TextBin,VecBin,K)`(dirty CPU 调度);open
   新增 `{vector_dim,N}` / `{vector_metric,cosine|l2|dot}` 选项。
6. **Erlang embedder**:`bitcask_embedder` behaviour
   (`embed(binary()) -> {ok, VecBin} | {error,_}`,可选 `dim/0`);
   参考实现 `bitcask_embedder_openai`(OpenAI 兼容 /v1/embeddings,
   httpc + OTP 27+ 内置 json;32K token 上限按 32768 字节保守截断 +
   UTF-8 尾部回退,粗糙但安全)。eunit 门禁用确定性 mock
   (test/bitcask_embedder_mock),真实端点用例默认 skip
   (BITCASK_EMBEDDER_LIVE=1 手动开)。

## 5. 持久化与恢复(A4 体系的第四块;V3.5 落地定稿)

> 实施记录(2026-06-12):本节由设计稿的"vec/hnsw 两文件"方案合并
> 定稿为**单文件完整图快照**——快照内容 = 向量 + 邻接 + entry。
> 理由:重插的距离计算才是开库慢的大头,只存向量再重插等于没省。

### 5.1 格式:`hnsw.snap`(BCVS v1,`HnswIndex::save/load`)

外壳与 BCKS/BCIS 同款:`[magic "BCVS"][ver u32=1][payload]
[crc32(payload)]`,tmp+rename 原子落盘。payload(LE):

```
dim u16 | metric u8 | M u32 | ef_construction u32 | seed u64
count u32 | entry_meta u64 | max_inserted_ord u64
count 个节点(节点 id 即写出顺序 0..count-1,邻接 id 引用该编号):
  ord u64 | level u8 | vec f32×dim | (level+1) 层,每层: cnt u32 | cnt×u32 id
```

- save 遵守**读者协议**(entry→count acquire 快照、per-node 锁拷邻接、
  ≥ 快照水位的邻居滤掉),与并发写者共存安全;落盘水位取
  `ord_of(count-1)` 而非 max_inserted_ord_ 原子(防 mid-insert 时水位
  领先 count 发布,重开后错杀尾部回放)。静止点两者相等。
- load 仅 open 期单线程(空图直填,成员 atomic 用 relaxed,发布靠上层
  shared_ptr 换入点)。校验:CRC、config(dim/metric/M)一致、邻居/
  entry id < count、level/cnt 不超容、ord 严格递增、**邻居层数覆盖**
  (layer-l 表只允许 level ≥ l 的节点——否则 copy_neighbors 越块读,
  这是内存安全项不是洁癖)——任何违例**整体拒绝**(绝不半载),
  SearchLayer 弃新实例保现图,上层回退全量 fold。

### 5.2 covers 门(并入 A4 合取式)

close 保存顺序:bm25 → sidecar → **hnsw snap** → keydir snap(worker
已停,图静止)。open 时 `load_keydir_from_disk` 对 vector_dim>0 的
集合在既有三块门(bm25 floor ∧ sidecar covers ∧ keydir 快照)上**追加
第四项**:`hnsw_snap_ok ∧ hnsw_covers_next_ord ≥ keydir.next_ord`,
其中 `hnsw_covers_next_ord = 图水位 + 1`(空图 = 0)。

- 门过 → 尾部回放:fold 水位后的记录经 recover_doc 带向量重插,
  ord ≤ 图水位被 insert 幂等丢弃(同 add_doc 水位协议);
- 任何一块缺/损/覆盖不足 → 全量 fold。已成功载入的图保留无害
  (重放靠水位幂等收敛,与 bm25 快照同款);
- **保守性(有意为之)**:墓碑/无向量文档占用 ord 但不进图水位——
  尾部 ord 若被此类记录占用,门关闭走全量 fold。与 bm25 floor 门同向
  保守,安全方向;data file 即向量 WAL,无独立 WAL(与设计稿一致)。

### 5.3 merge 重建(物理清除死节点)

- `hnsw_` 改 `std::atomic<std::shared_ptr<HnswIndex>>`:读者
  (search_vector)与写路径每次操作开头 load 一次图快照指针;旧图被
  换出后由在途读者的引用计数续命。
- merge 末尾(search 模式且 vector_dim>0)向 IndexPool 提交
  `IndexOp::RebuildHnsw` 任务,**由 worker 执行**——单写者论证:
  worker 是 on_vector/recover-replay 之外唯一触图写者,重建(新图旁路
  构建 + store 换指针)与后续 put 任务在同一线程串行,无写写并发;
  重建期间查询走旧图(死节点照旧结果侧滤除,语义不变)。
- 重建 = 新建同 config 图,遍历旧图节点(0..count),跳过
  `!Index.live_(ord)`,重插活节点(vec 从旧图读),完毕换指针。
- hnsw 快照不在 merge 点落盘(重建异步未完,落了也是旧图):留待
  close 静止点。merge 后未 close 即崩 → 旧 hnsw.snap covers 不足,
  门关,全量 fold——纯优化损失,无正确性影响。
- on_relocate 对图为 no-op(图按 ord 键),与设计稿一致。

## 6. 实施阶段(各自可验证,沿 TASK 惯例)

| 步 | 内容 | 验证 |
|---|---|---|
| V3.1 | meta VectorConfig + DocValue vector 段读写打通(put_doc/get 透传) | 格式 round-trip 测试 + 黄金 fixture |
| V3.2 | HNSW 核心(单线程 insert/search,距离内核分发) | **召回对拍** vs 暴力 KNN:低维(32d/10k)recall@10 ≥ 0.95@ef64 / 0.99@ef256;高维纯随机(384d)按 ef=128/256 标定 ≥0.93/0.98——距离集中使其成为最坏形态,实测收敛曲线 0.824/0.960/0.996/1.000(ef 64..512)证实实现健康,真实 embedding 流形数据远易于此 |
| V3.3 | 并发化(per-node 锁 + 发布式增长)+ IndexPool 接线 | N 读 × 1 写并发测试;TSan 全插桩全绿 |
| V3.4 | 软删过滤 + LiveChecker 接入。**落地记录(2026-06-12)**:机制随 V3.3 已在位(`Index.live_` 位图即 LiveChecker;search_vector 注入 `is_live` 回调;HNSW 结果侧滤死),V3.4 为语义证明:覆写测试(旧向量不可达,key 仅经新向量出现一次)+ 死区导航测试(删掉查询近邻 150/300 形成死壳,k=10 仍凑满、零死文档泄入、与活集暴力真值重合 ≥9/10)。**已知边界**:结果侧过滤意味着 ef 候选内活者 < k 时返回不足 k——死文档占比高的邻域调用方需加大 ef;根治靠 merge 重建物理清除(V3.5) | 删除/覆写/死区三类可见性测试 ✅ |
| V3.5 | 持久化(BCVS 完整图快照 + covers 门并入 A4)+ merge 重建。**落地记录(2026-06-12)**:单文件 `hnsw.snap` 取代设计稿 vec/hnsw 两文件(§5 定稿);hnsw_ 改 atomic<shared_ptr>,merge 经 IndexPool 提交 RebuildHnsw 由 worker 重建换图(单写者保持);§3 偏差 7 特判撤销。**开库收益实测(10k×384d,tmpfs)**:快照 reopen 82ms vs 删 hnsw.snap 全量 fold 3770ms(≈46×,BM_Cask_Open_Vec{Snapshot,FullFold}) | A4 同款三件套(快照/全量等价 + 快照孤本可检索实证、陈旧尾部回放、位翻转回退)+ MergeRebuildEvictsDead(50→25 节点物理清死)+ ConcurrentSearchDuringRebuild;plain/TSan/ASan ctest 378/378(TSan 零报告);eunit 44/44 ✅ |
| V3.6 | search_hybrid RRF + NIF/Erlang 接口。**落地记录(2026-06-12)**:SearchLayer::search_hybrid(两路 K'=max(k×4,64),RRF k=60,rank 从 1 起;平局 → ord 小者;单路退化/双空报错语义见 §4 落地记录);NIF 跨界 f32 LE 二进制(put doc map `vector` 键 + cask_search_vector/4 + cask_search_hybrid/4 + open {vector_dim,N}/{vector_metric,M});bitcask_embedder behaviour + bitcask_embedder_openai 参考实现(httpc + OTP≥27 json,32K 字节级保守截断)。测试 +3(V36HybridRrfFusion 精确浮点平局 + SingleLeg + Errors)+ eunit +6(mock embedder 全链路,不打在线端点) | plain/TSan/ASan ctest 381/381(TSan 零报告)+ ldd 无 tsan + eunit 50/50 ✅ |
| V3.7 | 基准定稿(2026-06-12 实测,384d/M16/efC200,median of 3,hnsw_bench.cpp + BM_Cask_SearchHybrid,已入 baseline.json):**查询** 10k/ef64 145µs、10k/ef256 463µs、**100k/ef64 483µs ✅(红线 <1ms)**、100k/ef256 1.67ms;**hybrid 端到端 270µs**(1 万条语料,两路 K'=64+RRF);**插入** 10k 档 3.00k/s ✅、**100k 档 936/s ❌(红线 >2k/s 未达)**。归因:10k→100k 掉 3.2×,超 logN 预期——154MB 向量集远超 L3,增量插入的每次距离计算近乎全打 DRAM(内存受限),叠加图增大后 efC 候选搜索跳数上升;单写者单线程无并行摊薄。残差路线(不在 V3 范围):① efC 降档(200→128,牺牲少量召回换 ~1.5×)、② 邻接 arena 化 + 向量预取、③ V4 int8 量化(内存流量 4×↓,同时解 2560d 规模账)。注:插入走 IndexPool 异步,前台 put_doc 不被此速率阻塞(队列背压 10240 上限内);100k 全量构建 ~107s 为一次性成本,此后 BCVS 快照 82ms 级开库 | 查询红线 ✅;插入红线 10k ✅ / 100k ❌(如实记录,残差归因+路线见左) |

## 7. 明确不做(V3 边界)

- 进程内 embedding 推理(Erlang 层 behaviour 解决);
- 多字段多图(接口留位,V3.x);
- 量化(int8/PQ)与外存图(V4,DocValue 段已留版本位);
- 过滤式向量检索的图内实现(V3.x 课题);
- 多写者并发插入(全引擎统一约束)。
