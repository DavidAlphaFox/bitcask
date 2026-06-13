# 向量库设计：在 Bitcask 引擎上原生扩展（BM25 + Embedding）

本文是在当前 C++ Bitcask 引擎之上构建**混合检索向量库**的落地设计。
配合 `doc/cpp-arch.md`（实现地图）、`doc/format-zh.md`（磁盘格式）阅读。

> **定位**：不保留 legacy Bitcask 兼容，直接**扩展/改造核心数据结构**，把
> KV 引擎升级成一个**单域**的向量引擎。同时支持
> ① BM25 式 ngram 倒排（稀疏检索）② embedding 稠密检索（ANN）。

## 0. 已定决策（设计记录）

| 项 | 决策 | 理由 |
|---|---|---|
| 兼容性 | **放弃 legacy 兼容**，改核心 | 单域引擎消除双 GC/双恢复带来的耦合 |
| 稀疏索引 | BM25 倒排，**完全原生**融合进引擎 | posting 是 append 友好的，贴合 log+epoch+merge |
| ngram 分析 | **中文为主，字符级 bi/tri-gram** | 不依赖分词器，对中文/混合文本最稳 |
| 稠密索引 | HNSW，**单图常驻内存** + merge 整体重建 | ≤1M 召回最好/查询最简；自带细粒度锁并发，超百万再演进多段 |
| 规模 | **百万级以内** | 向量 + 索引全内存可行；接口预留量化/外存 |
| 接口 | `search_text` / `search_vector` / `search_hybrid`（RRF 默认） | 三者都要 |
| 恢复 | 扩展 hint + 段文件 + 回放尾巴，**原生单恢复路径** | 删除天然由墓碑扫描处理 |
| ord | 内部序号**单调、永不复用** | 避免软删 ord 复用导致 ABA |

## 1. 总体架构（单域引擎）

```
┌──────────────────────────────────────────────────────────┐
│ 查询层  search_text / search_vector / search_hybrid(RRF)   │
├──────────────────────────────────────────────────────────┤
│ Index（KeyDir 超集，单域）                                  │
│   ext2ord/slots/ord2ext │ 倒排(term→posting) │ HNSW 单图     │
│   doc_len/N/Σlen        │ 文档/向量统计                       │
├──────────────────────────────────────────────────────────┤
│ 存储层  data file（typed record，source of truth）          │
│   merge：单一 GC，重写存活+purge删除+重算df+重建HNSW图        │
│   恢复：扩展 hint + 段快照 + 回放 ord>watermark 的尾巴        │
└──────────────────────────────────────────────────────────┘
```

关键点：**只有一个 GC、一个恢复路径、一个 epoch 时钟。** 上一轮探索里
「跨域 GC 耦合 / 恢复漏删 / 双调度器」这些问题在单域下消失。

## 2. 数据模型与 record 格式扩展

### 2.1 原则：一条文档 = 一条 record

data 文件仍然沿用 Bitcask「**一条 record 一个 key、一次写一条**」的根本模型，
写入路径 / merge / 恢复的核心假设全部不变。**一次 `upsert` 只 append 一条
record**，文本和向量打包进同一个 value：

```
Key   = ext_id                       业务主键（调用方指定）
Value = 序列化的 {text, metadata, vector}
```

`get(ext_id)` 一次 pread 取回整条文档（含文本 + 向量）。倒排索引和 HNSW
**不**往 data 文件写任何额外 record——它们是内存派生结构，单独 flush 成段文件
（见 §3、§8）。

### 2.2 record 格式扩展

只对 `format.hpp` / `codec.hpp` 的 data record 做**一处**结构改动：在 `Tstamp`
后增加 `type`（区分文档 / 墓碑）与 `ord`（内部单调序号）两个字段
（binary-incompatible，前提是放弃 legacy 兼容）：

```
现状: [crc][tstamp][ksz][vsz][key][value]
扩展: [crc][type:u8][tstamp][ord:u64][ksz][vsz][key][value]
```

| type | 含义 | value 内容 |
|---|---|---|
| `kDoc` | 一条文档 | 序列化的 `{text, metadata, vector}`（BM25 / HNSW 重建源） |
| `kTombstone` | 删除 | target ext_id/ord；删除是 log 一等公民 |

> `type` 只用来区分 record 种类，**不**用于把文档拆成多条；向量不是单独 record。

### 2.3 ext_id 与 ord

- **ext_id**：调用方在 `upsert` 时指定的文档主键，任意字节（如 `"doc-12345"` /
  URL / UUID）；用户用它增删查。即 data record 的 `Key`。
- **ord**：引擎分配的紧凑整数（u64），供倒排 posting 和 HNSW 节点号使用
  （需要小而密的整数做 delta 压缩和图节点号，不能用任意字节串）。复用
  `keydir.hpp` 的 `increment_file_id` 同款思路，另起一个 ord 计数器，**永不复用**。

> **ord 是 per-write（每次写一个），不是 per-document（每文档一个）。**
> 引擎每 append 一条 record 就单调 ++ 分配一个新 ord——它本质是「第几次写」的
> 版本号。这一点对自洽很关键：
> - **更新**同一 `ext_id` ⇒ 写一条更大 ord 的新 record，**旧 ord 被软删**；
>   这正是 append-only 的「改=追加新版本 + 旧版本变垃圾」，旧 ord 下次 merge 清理。
> - **`ext_id → ord` 映射指向当前最新 ord**；`ord → ext_id` 把检索结果翻译回主键。
> - 因 ord 随写入单调递增，§8 恢复的「回放 `ord > W` 尾巴」恰好覆盖「上次快照
>   之后写的全部 record」，严格成立。

- 引擎维护 `ext_id → 最新 ord` 与 `ord → ext_id` 映射；两者皆为派生状态，恢复时
  扫 record（Key=ext_id、header 带 ord）即可重建。

### 2.4 kDoc value 打包布局

一条 `kDoc` 的 value 把 `{vector, text, metadata}` 打包进一个自描述、可按需切片、
可向前兼容的结构：

```
kDoc value:
┌──────┬───────┬──────────────┬──────────────┬──────────────┐
│ ver  │ flags │  vector 段    │   text 段     │   meta 段     │
│ u8   │ u8    │  (可选)       │  (可选)       │  (可选)       │
└──────┴───────┴──────────────┴──────────────┴──────────────┘

flags 位:  bit0=has_vector  bit1=has_text  bit2=has_meta  bit3=vec_quantized

vector 段 (has_vector):  [dim:varint][ f32×dim  或  量化码字 ]
text   段 (has_text):    [len:u32][ utf8 字节 ]
meta   段 (has_meta):    [len:u32][ 序列化字节 (msgpack/CBOR) ]
```

设计要点：

- **`ver`**：布局版本号，后续演进靠它兼容多版本，免不兼容大改。
- **`flags`**：文档可纯文本 / 纯向量 / 两者皆有，按位开关，缺段不占空间。
- **向量段放最前**：HNSW 重建只读 `2+4` 字节（ver/flags + dim）即可 memcpy 出向量，
  不碰文本/meta；BM25 重建按 dim 算出向量段长度跳过，直达 text。两条偏路径都
  O(1) 定位。
- **`dim` 冗余存一份**：collection 配置虽有 dim，record 自带 dim 使其自描述、
  对配置漂移/多 collection 鲁棒，仅多 4 字节。
- **metadata 用 msgpack/CBOR**：紧凑带类型；存储层视为不透明字节，查询层需要
  过滤时再解码（V1 的「查询后过滤」在该层做）。
- **`vec_quantized` 位**：为后续 scalar/PQ 量化预留（置位时向量段装码字而非裸
  f32，scheme 进 ver/header）；百万级先不用。

#### 字节序规则（x86 + ARM64 均零成本）

| 字段 | 字节序 | 理由 |
|---|---|---|
| header 整数（`dim`/`len`/`ord`/`tstamp`…） | **大端** | 沿用 `format.hpp` 既有契约 |
| 向量 `f32` 数组 | **固定小端** | x86/ARM64 都是 LE，原生零 byte-swap；格式仍良定义 |

- 把磁盘格式定义为「f32 固定小端」（而非「平台原生」），契约确定。x86 与 AArch64
  （Linux/Apple Silicon/Graviton/Android 均 LE）上「固定 LE == 原生」→ memcpy 零转换；
  仅真正的大端主机（s390x 等，非目标）读时才 byte-swap，但格式始终良定义。
- **对齐无忧**：向量从 value memcpy 进对齐的内存数组后再算距离，value 内未对齐
  偏移不会被直接当 f32 解引用；memcpy 在 x86/ARM 上都安全处理未对齐。

## 3. 内存索引结构（KeyDir → Index 超集）

在 `keydir.hpp` 的 `KeyDir` 基础上扩展为 `Index`，复用其
registry refcount（`keydir_registry.hpp`）与恢复管线：

### 3.1 Index 容器（身份映射 + 文档元信息）

`ord` 是密集单调整数，故所有 `ord→X` 结构用**数组**而非 hashmap（O(1) 下标）：

```cpp
class Index {                          // 替代/扩展 KeyDir
  unordered_map<string,u64> ext2ord;   // ext_id → 最新 ord（点查/覆盖判断/删除）
  vector<DocSlot>           slots;      // 下标 = ord
  vector<string>            ord2ext;    // 下标 = ord，检索结果翻译回主键
  RoaringBitmap             live;       // 下标 = ord，软删标记（死点直到 merge 才清）
  u64                       next_ord;   // 单调分配器，永不复用

  struct DocSlot {                      // 定位 + BM25 元信息
    u32 file_id; u64 offset; u32 total_sz;  // pread 整条 kDoc
    u32 tstamp;
    u32 doc_len;                            // BM25 长度归一用的 token 数
  };
};
```

- `get(ext_id)`：`ext2ord` → `slots[ord]` → 一次 pread。
- `upsert`：分配新 ord、`ext2ord` 改指、老 ord 在 `live` 清 0（软删）。
- ord 永不复用 ⇒ `slots`/`ord2ext` 长度 = 历史总写入数，更新多了出现空洞 →
  **merge 时重编号（remap 老→新 ord）压实**（Lucene 段合并同款），重写 posting/HNSW
  里引用的 ord。

### 3.2 BM25 倒排（内存工作副本 + 段快照）

```cpp
// 词典→posting，按 term hash 分片上锁（§4）
unordered_map<string /*ngram*/, PostingList> inverted;
struct Posting     { u64 ord; u32 tf; };
struct PostingList { vector<Posting> items; };   // 按 ord 升序
u64 live_doc_count;   // = N
u64 sum_doc_len;      // avgdl = sum_doc_len / N
```

- **analyzer**：NFKC 归一 → CJK 走**字符 bi/tri-gram**、拉丁走空白切分+小写 →
  （可选停用词）。写与查用同一条链。
- **评分**：`score = Σ IDF(t)·tf·(k1+1)/(tf + k1·(1−b+b·|D|/avgdl))`，`k1/b` 可配。
- **查询**：切 query → 每 term 取 posting → DAAT 累加（跳过 `live=0` 的 ord）→ top-k 堆。
- **df / IDF 漂移**：posting 残留死点使 df 偏大。V1：查询过滤死点 + 接受轻微漂移，
  **`df/N/avgdl` 在 merge 重算**；要更准可维护删时递减的 `df_live`。
- **持久化**：`inverted` flush 成 `bm25/seg-*.inv`（term 字典 + delta-varint posting），
  **仅作恢复快照、不参与查询**——查询永远只打内存这一份。恢复 = 载快照 + 回放尾巴。
- 规模化（后续）：Block-Max WAND 加速 top-k。

> **内存预算**：1M 文档 × ~200 token ⇒ ~2 亿条 posting，未压缩 GB 级，是稀疏侧
> 主要开销。默认 **bigram**（term 少、posting 长、好压）比 trigram 省；内存 posting
> 建议分块压缩。

### 3.3 HNSW 稠密索引（单图常驻内存）

**为什么是图遍历**：高维近邻没有可排序/可切分的结构（向量排不出线性序；
kd-tree 等树法在几百维下遭遇维度灾难、退化成近暴力）。唯一可行的是把「谁挨着谁」
做成**邻近图**（边 = 两向量接近），找最近邻退化成**从入口沿邻近边贪心走向 query**。
HNSW = 分层 + 小世界图：底层全节点短边（精修）、高层稀疏长边（远跳，类比社交网
「六度分隔」），让遍历既快（~O(log N) 跳）又准。代价就是连通可变图带来的删除需
路由中转、插入较贵、merge 整体重建（见 §11）。

百万级目标下采用**单图常驻内存**（非多段）——召回最好、查询最简：

- **一张 HNSW 图**常驻内存；节点 = ord，邻居链按 ord 存。
- **自带 per-node 细粒度锁**（hnswlib 式）支持并发 insert + search，**不挂 keydir 那把
  粗锁**——这就化解了「插入阻塞读」，无需靠分段回避。向量检索是近似/best-effort，
  **不需要 fold 的一致性快照**，故连通图不进 MVCC 也没问题。
- 向量数据常驻内存（`dim×f32` 数组，下标 = ord），距离 cosine / L2 / dot，
  AVX2（x64v3）/ NEON（ARM）加速。
- 距离计算的向量来自内存数组；**data 文件里的 `kDoc` value 是持久副本**，恢复时
  据此重建内存向量。
- **删除**：`markDelete` 软删，节点保留作路由中转、结果过滤；死点在 **merge 整体
  重建图**时物理清除。
- **持久化**：周期 flush 成**单个**快照段 `hnsw/graph.ann`（自包含向量副本），
  **仅供恢复**；恢复 = 载快照 + 回放尾巴增量插入。
- **规模化预留**：超百万再演进为多段 + buffer（接口/段格式预留，V1 不做）。

### 3.4 倒排索引 vs Index 侧表的分工

§3.1 的 Index 容器**本身不做检索**——它只是「按 ord 存每篇文档边角料」的一组
**侧表**。把「查询词 → 候选文档」连起来的是 §3.2 的**倒排索引**。两者分工：

```
倒排索引 (§3.2)          Index 侧表 (§3.1)
term → [(ord,tf)...]      ord → {doc_len, ext_id, live, location}
   ↑                          ↑
"查询词命中哪些 ord"      "给定 ord，O(1) 查它的信息"
```

**为什么 `ord→X` 用数组、`ext_id→ord` 用 hashmap**：ord 是密集连续整数（0,1,2…），
数组下标即 ord，O(1) 且省内存；ext_id 是任意字符串，只能哈希。

#### 一次 `search_text("降息", k)` 如何用到容器

```
1. analyzer 切词："降息" → ngram ["降息"]
2. 查倒排：inverted["降息"] → [(7,tf=1),(42,tf=2)]      # 仅产出候选 ord
3. 逐候选打分（用侧表取数据）：
     if live[ord]==0: continue                          # live[] 跳过已删
     dl  = slots[ord].doc_len                           # slots[] 取文档长度
     idf = log(N/df);  df = posting 长度
     score[ord] += idf * tf*(k1+1)/(tf + k1*(1-b+b*dl/avgdl))
     # N=live_doc_count, avgdl=sum_doc_len/N（容器全局统计）
4. top-k 堆选最高分的 ord
5. 翻译：ext_id = ord2ext[ord]                           # ord2ext[] 回主键
6.（可选）回显原文：slots[ord]→(file_id,offset)→pread kDoc
```

| 步骤 | 用到 | 作用 |
|---|---|---|
| 2 | 倒排索引(§3.2) | term → 候选 ord |
| 3 | `live[ord]` / `slots[ord].doc_len` / `live_doc_count`,`sum_doc_len` | 过滤死点 + BM25 打分 |
| 5 | `ord2ext[ord]` | ord → 返回给用户的 ext_id |
| 6 | `slots[ord]` location | pread 原文 |

> 一句话：**倒排索引负责「词 → 一堆 ord」；Index 容器负责「给定 ord，O(1) 查
> doc_len / 死活 / ext_id / 磁盘位置」。** 检索 = 倒排出候选 ord，再用这些 ord 下标
> 的数组取打分数据与最终 ext_id。

## 4. 并发与锁模型（必须分片）

现状是整个 KeyDir 一把 `shared_mutex`。HNSW 插入很贵（一次几百次距离计算），
**不能挂在同一把写锁下**，否则阻塞所有读。拆分如下：

| 子结构 | 锁 | 说明 |
|---|---|---|
| ext2ord / slots / ord2ext | `shared_mutex`（沿用） | 读多写少 |
| BM25 倒排 | 按 term 分片 `shared_mutex` | 写入只锁命中分片 |
| HNSW 单图 | **HNSW 自带 per-node 细粒度锁** | 并发 insert + search；不挂 keydir 粗锁 |
| 全局统计/epoch/fstats | 沿用 `keydir.hpp` 机制 | 切出独立锁（`keydir.hpp` 注释里的 M6 sharding 候选） |

fold 的 sibling-chain MVCC **只用于稀疏/key 维度**；HNSW 是近似检索、不需一致性
快照，靠自身细粒度锁并发，不进 epoch MVCC。

## 5. 写路径

### 5.1 提交点原则（贯穿全节）

> **append 到 data file = 提交点；所有索引状态都是「持久日志 + 墓碑」的确定性
> 函数，可由回放重建。**

两条由此而来的铁律：

1. **先持久 append，后更新索引**——绝不能反过来。否则索引可能引用一条没落盘的
   record，崩溃后检索会返回不存在的文档。
2. **一致性恒成立，持久性看 sync 策略**：索引是内存态，append 未 fsync 前崩溃，
   record 和索引更新（都在内存/OS buffer）一起丢，恢复从存活日志重建 → 索引始终
   与日志一致；「这条写入是否扛得住崩溃」才取决于 fsync（`o_sync`/显式 `sync`）。

### 5.2 `upsert(ext_id, {text?, vector?, metadata?})`

```
0. 查 ext2ord[ext_id]：命中 → 这是 update，记 old_ord；未命中 → insert。
1. 分配 ord = next_ord++（单调，永不复用）。
2. 编码 kDoc value（§2.4 打包 {vector,text,meta}），append 一条 record：
     header: type=kDoc, ord, tstamp, key=ext_id
   ── 这是提交点（复用 data_file.hpp append + CRC；超 max_file_size 则先滚文件）──
3. 更新 Index 侧表（按 ord 下标，按需 grow 数组）：
     slots[ord]   = {file_id, offset, total_sz, tstamp, doc_len}
     ord2ext[ord] = ext_id
     live.set(ord)
     ext2ord[ext_id] = ord            # 覆盖旧值
     fstats[file_id] += live/total bytes        # 复用 update_fstats
4. BM25：analyzer 切 text → 每个 ngram term 把 (ord,tf) 追加进 posting；
   doc_len = token 数（记进 slots[ord]）。
5. HNSW：把 vector 作为节点 ord 插入单图。
6. 若是 update，软删旧版本（见 5.3）。
```

注意 4/5 是**追加新 ord**，不去改旧 ord 的 posting/图节点——旧版本靠软删失效、
merge 时才物理清除（append-only 的「改 = 写新 + 旧变垃圾」）。

### 5.3 update 时的软删与计数（易错点）

update 不写墓碑（同 ext_id 的更大 ord 已隐含覆盖），但要正确处置 `old_ord`：

| 动作 | insert | update | 说明 |
|---|---|---|---|
| `live[old_ord]` | — | **clear（软删）** | 旧版本退出检索 |
| `ext2ord[ext_id]` | 设为 ord | 改指 ord | 始终指向最新 |
| HNSW `markDelete(old_ord)` | — | ✔ | 旧节点留作路由中转 |
| 旧 posting | — | 不动（靠 live 过滤） | merge 时 purge |
| `live_doc_count`(N) | **+1** | **+0** | 一个 ext_id 始终算一篇活文档 |
| `sum_doc_len` | +new_len | **−old_len +new_len** | old_len = slots[old_ord].doc_len |
| `fstats` 死字节 | — | 旧 record 的 total_sz 转死字节 | 驱动 merge |

`N+0` 这点最容易写错：更新同一文档**不该**让文档总数虚增——否则 IDF/avgdl 全偏。

### 5.4 `remove(ext_id)` 写路径

```
1. old_ord = ext2ord[ext_id]；不存在 → 返回 false。
2. append 一条 kTombstone record（key=ext_id, ord=next_ord++）= 提交点。
3. live.clear(old_ord)；ext2ord.erase(ext_id)；HNSW markDelete(old_ord)；
   N−1；sum_doc_len −= slots[old_ord].doc_len；fstats 旧 record 转死字节。
```

墓碑是 log 一等公民（§2.2），恢复回放时据它软删——**删旧文档天然被覆盖**（§8）。

### 5.5 并发与持久化

- **日志侧串行**：ord 分配 + active file append 要串行（单 writer / write.lock，
  沿用 cask 模型）——保证 ord 单调、append offset 无竞争。
- **索引侧**：BM25 倒排按 term 分片锁、HNSW 自带 per-node 锁（§4），可在写路径内
  并发推进；侧表数组的 grow 用写锁短暂保护。
- **延迟构成**：append 很便宜，**HNSW 插入是 upsert 延迟的主要来源**（一次插入要
  多次距离计算）。V1 同步插入；若要降尾延迟，可把 HNSW 插入排队异步化（代价是
  「写完到可被向量检索」有短暂滞后），留作后续优化。
- **sync**：复用 `cask` 的 `o_sync` / 显式 `sync()`；批量写后一次 sync 即可。

### 5.6 崩溃点分析（每个点崩了会怎样）

| 崩溃位置 | 后果 | 恢复 |
|---|---|---|
| 5.2 步骤 1 后、2 前（ord 已分配未 append） | 内存态丢失，磁盘无此 record | `next_ord` 恢复时 = 磁盘最大 ord +1，幽灵 ord 自动消失，无空洞 |
| 5.2 步骤 2 后、3–6 前（已 append 未更新索引） | 日志有、内存索引没跟上 | 回放 `ord > W` 重建索引（§8），record 自描述（带 ord/ext_id/type） |
| 5.2 步骤 5 中途（HNSW 插一半） | 内存图态丢失 | 同上，从快照 + 回放重新插入 |
| append 已写 OS buffer 未 fsync | record 与索引更新一起丢 | 二者皆失 → 一致；该写入「未持久」符合 sync 语义 |

## 6. 查询路径（三接口）

```
search_text(query, k)            // 仅 BM25
search_vector(qvec, k)           // 仅 ANN（HNSW 单图）
search_hybrid(query, qvec, k, {fusion=RRF, w_text, w_vec})
```

- `search_text`：query 走同一字符 ngram 分析链 → 取 posting → DAAT 累分 → top-k。
- `search_vector`：HNSW 单图查 top-k（跳过 markDelete 的 ord）→ `ord→ext_id` 翻译。
- `search_hybrid`：两路各出 top-k，**RRF 融合**
  `score(d) = Σ 1/(c + rank_i(d))`（默认 `c=60`），或归一化加权和；返回合并 top-k。
- metadata filter：附加属性索引层（初版可先做查询后过滤）。

## 7. 删除与回收（单域 merge）

- 删除 = 写 `kTombstone`（log 一等公民）+ 索引侧软删标记。
- **单一 merge**（扩展 `merger.hpp`）一次 pass 完成：
  1. 重写存活 data record（沿用现有 merge）；
  2. purge 倒排里已删 ord，重算 `df/N/avgdl`；
  3. 整体重建 HNSW 单图（丢弃软删节点）+ 重编号 ord；
  4. trim fstats。
- `merge_policy.hpp` 的 `decide()` 增加触发信号：**死字节率**（现有）∪
  **删除率**（倒排/HNSW 膨胀）。
- 因为单域，无跨域 pin、无回收顺序协调问题。

## 8. 持久化与恢复

恢复分两块、成本天差地别：**侧表（便宜，全量重建）** 与 **派生索引 BM25/HNSW
（昂贵，靠快照 + 回放避免从头重算）**。

### 8.1 持久化的三类产物

| 产物 | 文件 | 内容 | 作用 |
|---|---|---|---|
| **日志**（source of truth） | `*.bitcask.data` | `kDoc`（文本+向量）/ `kTombstone` typed record | 唯一真相，可重建一切 |
| **hint**（扩展） | `*.bitcask.hint` | per-record：`ext_id`(key) / `ord` / location / `total_sz` / `tstamp` / `type` / `doc_len` | **快重建侧表**，免读 data value |
| **索引快照** | `bm25/seg-*.inv`、`hnsw/graph.ann` | 倒排（term 字典+delta-varint posting）/ HNSW 图（节点 ord+邻居链+入口+参数，自含向量） | **免重切词/重插图**，仅恢复用、不参与查询 |
| **checkpoint 清单** | `index.ckpt` | `W`（快照覆盖到的 ord）+ 段文件名及各自 CRC + 全局统计（`N`/`sum_doc_len`/`next_ord`） | 锚定「索引快照到 W 为止一致」 |

> hint 在 data 文件 finalize（滚动）时写出，覆盖所有已封文件；扩展点是每条多带
> `ord`/`doc_len`/`type`，使侧表（`slots`/`ord2ext`/`ext2ord`/`live`/`doc_len`/统计）
> 能只读 hint 重建，无需读 value。

### 8.2 checkpoint 何时产生 + 原子性

- **搭 merge 产生**：merge 本就整体重建 HNSW 图、重算 BM25 统计（§7），完成后把
  刚重建好的结构序列化成段、写 `index.ckpt`，`W` = 本次覆盖的最大 ord。
  ⇒ **checkpoint 节奏 ≈ merge 节奏**，统一了 §7/§8。也可独立定时 flush。
- **原子性**：段文件先整体写完 + fsync，再用「写临时 `index.ckpt.tmp` → fsync →
  rename」原子替换清单。崩溃在 flush 中途 → 旧 `index.ckpt` 仍有效，半成品段文件
  因未被清单引用而被忽略/GC。

### 8.3 恢复算法（单路径）

```
A. 扫目录：data 文件（scanner）、hint、index.ckpt、bm25/hnsw 段。

B. 重建侧表（便宜，只读 hint + active 尾巴）：
   - 每个 data 文件有 hint → 读 hint；无 hint（未 finalize 的 active 文件）
     → 只扫 record header。
   - 填 slots / ord2ext / doc_len；ext2ord 取每个 ext_id 的最新 ord（后写胜）；
     被覆盖的旧 ord、墓碑命中的 ord → live 清 0。
   - next_ord = 全局最大 ord + 1；统计 N / sum_doc_len。

C. 重建派生索引（昂贵，快照 + 回放）：
   - 读 index.ckpt → W、段清单、CRC。校验并加载 bm25 段（→内存倒排）、
     hnsw 段（→内存图 + 向量数组）。
   - 回放 ord > W 的尾巴：仅对 live[ord]==1 的 kDoc 读 value → 切词入倒排、
     插 HNSW（见 8.4）；kTombstone 在 B 已软删，跳过。

D. mark_ready，开服。
```

### 8.4 回放只处理 live ord（优化 + 一致性）

- 尾巴里若某 ord 已被后续 update/delete 顶掉，B 阶段已把 `live[ord]=0`；C 回放
  **跳过死 ord**，不做无谓的切词/插图。
- 快照内（ord≤W）也可能含已死 ord（W 后被删）：加载后由 B 的 `live` 标记过滤，
  查询不返回、下次 merge purge。**删旧文档天然被墓碑扫描覆盖**（解决早先 #4）。

### 8.5 校验与回退（兜底）

- 段或清单 CRC 校验失败 / `index.ckpt` 缺失损坏 → **回退到全量重建**：读所有
  live `kDoc` 的 value，切词 + 逐个插 HNSW。慢但永远正确。这是安全网。
- 即正确性只依赖日志 + hint；索引快照纯属加速，丢了不影响数据。

### 8.6 恢复成本与节奏旋钮

| 路径 | 成本 | 何时 |
|---|---|---|
| 侧表重建（B） | O(记录数)，顺序读 hint，快 | 总是 |
| 快照 + 回放（C） | 加载 O(索引大小) + 回放「上次 checkpoint 以来的写入」× HNSW 插入成本 | 正常 |
| 全量重建（8.5） | O(N × HNSW 插入)，1M 量级可能数分钟 | 仅快照损坏时 |

⇒ **checkpoint（merge）节奏是恢复时长的旋钮**：越勤，回放尾巴越短、恢复越快，
但 flush 开销越高。

```
<dir>/
├── *.bitcask.data            # typed record：kDoc（文本+向量）/ kTombstone
├── *.bitcask.hint            # 扩展：每条带 ord/doc_len/type，快重建侧表
├── index.ckpt                # checkpoint 清单：W + 段清单&CRC + 统计（原子替换）
├── bm25/seg-000001.inv       # 倒排快照段（仅恢复用）
└── hnsw/graph.ann            # HNSW 单图快照（自含向量，仅恢复用）
```

## 9. 公共 API 草案

```cpp
// 实际实现中，这些选项通过 CaskOptions.search_config (SearchLayerConfig) 传入：
//   vector_dim, vector_metric, analyzer, bm25_params, hnsw M/ef
struct CaskOptions {  // 概念示意，详见 cask.hpp
  std::uint32_t dim;                 // embedding 维度
  Metric        metric = Metric::Cosine;
  NgramOptions  ngram{ .min_n = 2, .max_n = 3, .analyzer = Analyzer::CharCJK };
  Bm25Params    bm25{ .k1 = 1.2f, .b = 0.75f };
  HnswParams    hnsw{ .M = 16, .ef_construction = 200 };
};

upsert(ext_id, {text?, vector?, metadata?}) -> ord
remove(ext_id) -> bool

search_text  (query, k)                       -> [{ext_id, score}]
search_vector(qvec, k, {ef})                  -> [{ext_id, dist}]
search_hybrid(query, qvec, k, {fusion, w...}) -> [{ext_id, score}]
```

## 10. 里程碑

| M | 内容 |
|---|---|
| V1 | record `type`+`ord` 字段；`kDoc`（打包文本+向量）/`kTombstone`；ord 分配；upsert/get/remove |
| V2 | BM25 原生：字符 ngram 倒排 + 评分 + `search_text`；倒排段持久化 + 恢复 |
| V3 | HNSW 单图 + `search_vector`；图快照 flush + 恢复 |
| V4 | 单域 merge：purge 删除 + 重算 df + HNSW 整体重建 + ord 重编号 + 触发策略 |
| V5 | `search_hybrid`（RRF）+ metadata filter（查询后过滤起步） |
| V6 | 锁分片落地；Block-Max WAND；量化/外存预留点评估 |

## 11. 已知风险 / 待定

- **锁分片**是改核心最大的工程风险（§4）；初版可先单锁跑通、再切分片。
- HNSW 单图的 **merge 整体重建**对 ≤1M 可接受，但是 stop-the-world 风险点——
  应在副本上重建、原子换图，避免阻塞在线查询；超百万再考虑多段增量。
- 删除率高时召回/排序在两次 merge 间漂移（死点累积）——靠删除率触发 merge 缓解。
- metadata filter 的高效实现（filter-while-search）留到属性索引成熟后。
- 量化（PQ/scalar）、IVF、外存：百万级用不上，接口预留，超规模再做。
