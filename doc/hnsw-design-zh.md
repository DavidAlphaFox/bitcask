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
7. **接线过渡**:HNSW 持久化在 V3.5 之前缺位,`load_keydir_from_disk`
   对 vector_dim>0 的集合**强制全量 fold**(跳过 keydir 快照快路径;
   data file 即向量 WAL,bm25 快照仍先载、重放靠 add_doc 水位幂等收敛)。
   V3.5 落 vec/hnsw 快照并入 covers 门后撤销此特判。
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

## 5. 持久化与恢复(A4 体系的第四、五块)

两个新文件,**沿用 BCxS 框架(magic/ver/CRC/tmp+rename)**:

1. **`bitcask.vec`(BCVS v1)**:向量平面 dump——
   `header(dim/metric/count/covers_next_ord)` + `count × (ord u64 +
   f32×dim)`。**定长行**:将来可直接 mmap(V3 先整读入内存)。
2. **`bitcask.hnsw.snap`(BCHS v1)**:图结构——
   `header(M/efC/entry_point/max_level/count/covers_next_ord)` +
   每节点 `(ord, level, 各层邻居 u32[])`。**不含向量**(在 .vec 里,
   不重复)。

写入点与成对性:**完全复用 A4-P3 协议**——close/merge 末尾,在
bm25+sidecar 之后追加保存 vec+hnsw(同一静止点,同一 covers 标记
来源);open 时五块快照(keydir/bm25/sidecar/vec/hnsw)全过 CRC 且
covers 门统一判定(`min(各 covers) ≥ keydir.next_ord` 并入现有门),
才走尾部回放;任何一块缺/损 → 该子系统全量重建:
- 向量/图的全量重建 = fold data files 读 DocValue vector 段逐条
  insert(与 bm25 的 recover_doc 同一循环顺路完成,不另开扫描);
- **无独立向量 WAL**:data file 本身就是向量的 WAL(尾部回放覆盖
  崩溃窗口),与 bm25 需要 WAL(分词结果非持久)的处境不同。
- 水位幂等:hnsw_.insert 按 ord 与 max_inserted_ord 去重
  (同 add_doc 水位协议),重放重叠区安全。

merge:`rebuild_index` 扩展为同时重建图(doc_reader 已回传整条
DocValue,补给 vector 段);on_relocate 对图为 no-op(图按 ord 键)。

## 6. 实施阶段(各自可验证,沿 TASK 惯例)

| 步 | 内容 | 验证 |
|---|---|---|
| V3.1 | meta VectorConfig + DocValue vector 段读写打通(put_doc/get 透传) | 格式 round-trip 测试 + 黄金 fixture |
| V3.2 | HNSW 核心(单线程 insert/search,距离内核分发) | **召回对拍** vs 暴力 KNN:低维(32d/10k)recall@10 ≥ 0.95@ef64 / 0.99@ef256;高维纯随机(384d)按 ef=128/256 标定 ≥0.93/0.98——距离集中使其成为最坏形态,实测收敛曲线 0.824/0.960/0.996/1.000(ef 64..512)证实实现健康,真实 embedding 流形数据远易于此 |
| V3.3 | 并发化(per-node 锁 + 发布式增长)+ IndexPool 接线 | N 读 × 1 写并发测试;TSan 全插桩全绿 |
| V3.4 | 软删过滤 + LiveChecker 接入 | 删除可见性测试(删后不出现在结果) |
| V3.5 | 持久化(vec/hnsw 快照 + covers 门并入 A4)+ merge 重建 | A4 同款三件套:快照/全量等价、陈旧尾部回放、损坏回退;eunit |
| V3.6 | search_hybrid RRF + NIF/Erlang 接口 | 端到端 eunit;hybrid 排序确定性测试 |
| V3.7 | 基准定稿:BM_Hnsw_Insert/{10k,100k}、BM_Hnsw_Search/{10k,100k}×{ef64,ef256}、BM_Hybrid;入 baseline | 红线:100k/ef64 查询 < 1ms;插入 > 2k/s(384d,本机) |

## 7. 明确不做(V3 边界)

- 进程内 embedding 推理(Erlang 层 behaviour 解决);
- 多字段多图(接口留位,V3.x);
- 量化(int8/PQ)与外存图(V4,DocValue 段已留版本位);
- 过滤式向量检索的图内实现(V3.x 课题);
- 多写者并发插入(全引擎统一约束)。
