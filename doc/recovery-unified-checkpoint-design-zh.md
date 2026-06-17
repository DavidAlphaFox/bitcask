# 恢复持久化统一:checkpoint 命名 + 单趟尾部回放(路线 A)

> 对应代码:`keydir.cpp`(save/load_snapshot)、`search_layer.cpp`
> (save/load_index_sidecar、save/load_vec_snapshot、load_snapshot)、
> `inverted.cpp`/`inverted_wal.cpp`(bm25 WAL)、`cask.cpp`
> (`load_recovery_snapshots`/`load_keydir_from_disk`/写入点)。
> 背景:本文取代并收敛 `recovery-snapshot-design-zh.md` 的命名与
> 多写者日志策略;不变量论证沿用其 §2,不重复。搜索快照的**单文件分段 +
> 逐段 CRC + 代际回退 + docmap 可选缓存**与姊妹引擎 `cellar`
> (`design-cellar-search.md`)**已全面收敛到路线 A**(对比见 §10):两引擎
> 都以 data 为唯一 WAL、砍搜索 WAL、`.prev` 用 data 尾巴追平,仅命名/magic 不同。

## 1. 问题

现状三个痛点,根因都是**持久化契约没有显式化在文件名/格式上**:

1. **命名混乱**:`.snap` 后缀同时盖在裸 checkpoint(keydir/index/hnsw,
   无 WAL)与 checkpoint+WAL(bm25)上;bm25 又不带 `bitcask.` 前缀,
   塞了 `_snapshot`+`.inv` 两层语义。读名字看不出耐久契约。
2. **IO 浪费(双重日志)**:一次搜索 put 把 value(text+vector)写进
   data 文件——data 文件**本身已是一条带 ord 的全量 WAL**——又把分析后
   的 term 追加进 bm25 WAL(`inverted.cpp:358`)。同一笔写记两遍。
3. **重用率 ≈ 0**:checkpoint 只在 close/merge 落盘,无周期性。崩溃后
   keydir/docmap/hnsw 三块必陈旧 → 成对门(`cask.cpp:881`)按**最弱环**
   判定 → 全量 fold。此时 bm25 WAL 被丢弃重建,**等于白记**。

## 2. 核心决策

- **data 文件是唯一 WAL。** 所有派生索引(keydir / docmap / bm25 / hnsw)
  统一为「周期性 checkpoint + open 时单趟 fold 尾部回放」。
- **砍掉 bm25 独立 WAL。** 其唯一收益是 replay 免重新分词;改为可选的
  「分析后 term 缓存」(§6),而非一条完整 WAL,消除双重日志。
- **搜索索引合并为单个分段自描述文件 `search.ckpt`**(借鉴 cellar 提案
  `design-cellar-search.md`):docmap / bm25 / hnsw 各为一个**段**,**逐段
  独立 CRC**、页脚目录定位;替代 P14a 的多文件(`search.docmap.ckpt` +
  `search.vec.ckpt` + `search.bm25.manifest` + `search.bm25.f{i}.seg`)。
  收益:文件数大降、损坏隔离到段(只重建坏的那种索引)、加新索引类型只
  登记 type 不新增文件、未脏的段拷贝前移省写放大。
- **保留上一代 `search.ckpt.prev`(代际回退)。** 最新 `search.ckpt` 整体
  位腐时回退上一代,再 fold data 尾巴追平——**回退的增量源是 data 文件
  (我们的 WAL),不依赖搜索 WAL**(论证见 §6.5)。在本架构里 `.prev` 是
  恢复**提速**项(把"最新损坏"从全库重建降到尾巴重放),非 durability 必需。
- **重用率靠 checkpoint 频率提升,不靠加 WAL。** 给 keydir/docmap/hnsw
  补 WAL 是反方向(更多文件+fsync,且 hnsw WAL ≈ 重新 insert,无收益)。
- **keydir 仍独立 `kv.keydir.ckpt`**(KV 层,非搜索)——纯 KV 库不产生
  `search.ckpt`,与 cellar 把 keydir/hint 与 search 分层一致。
- **后缀编码契约**:`.ckpt`=可重建 checkpoint(分段或单块),`.prev`=上一代,
  `.wal`=日志(仅 data/hint)。所有派生文件可删,删后 fold 重建。

## 3. 文件总览与 `search.ckpt` 分段格式

### 3.1 目标文件布局

```
N.bitcask.data / .hint   数据日志(唯一 WAL)+ key→位置 加速(不变)
bitcask.meta             目录配置(不变,meta v2 小端)
field.schema             字段注册表(不变)
kv.keydir.ckpt           KV keydir checkpoint(BCKS,单块,独立)
search.ckpt        ← 新  搜索索引快照(分段:docmap/bm25/hnsw,逐段 CRC)
search.ckpt.prev   ← 新  上一代搜索快照(代际回退)
```

`.prev` 只对 `search.ckpt` 设(搜索段重建最贵、最值得回退提速);keydir
重建便宜,不设 `.prev`。无 `*.wal`(路线 A)。

> **取代关系(P14a → P14e)**:P14a 已落地的多文件搜索命名
> (`search.docmap.ckpt` / `search.vec.ckpt` / `search.bm25.manifest` /
> `search.bm25.f{i}.seg`)是**过渡态**,被本节单文件 `search.ckpt` 收编。
> 旧名不再读(可 fold 重建,flag-day,见 §8 P14e)。`kv.keydir.ckpt`
> 保留(它不是搜索段)。

### 3.2 `search.ckpt` 格式(自描述、分段、逐段 CRC,全小端)

```
== 头部 (16 B) ==
[0..3]   magic     "BCSC"   4 ASCII
[4..7]   version   u32 = 1
[8..15]  watermark u64      本快照覆盖到的 next_ord 上界(成对门/回放用)

== 段载荷区 ==
各段 payload 顺序拼接(无内联段头;位置/校验由页脚目录给出)。
段 payload 沿用现有内部序列化(InvertedIndex / HnswIndex / DocIndex),
仅由"独立文件"变为"文件内的段"——字节级不变(跨引擎一致性保留)。

== 页脚 ==
directory(dirLen 字节):
  sectionCount u32
  每段: type u16 | flags u16 | offset u64 | len u64 | crc32 u32  (crc 覆盖该段 payload)
footerCrc u32     CRC 覆盖 directory 字节
dirLen    u32     directory 字节长度
trailer   "BCSC"  4 ASCII
```

**定位页脚(从文件尾倒走)**:`[EOF-4..]`=trailer;`[EOF-8..EOF-4]`=dirLen;
`[EOF-12..EOF-8]`=footerCrc;directory=`[EOF-12-dirLen .. EOF-12]`,按 footerCrc 校验。
页脚最后写(tmp+rename 原子)——**页脚存在且 footerCrc 通过 = 文件结构完整**。

### 3.3 段类型(type,与姊妹引擎 cellar 对齐)

| type | 名称 | 必需性 | payload |
|---|---|---|---|
| 1 | `docmap` | **可选加速** | `ord → key/loc/live/doc_len`(原 BCIS sidecar 内容) |
| 2 | `bm25.default` | 必需 | 默认域 `InvertedIndex` |
| 3 | `bm25.fields` | 有字段时 | `u32 fieldCount; [name; InvertedIndex]×` |
| 4 | `hnsw` | 有向量时 | `HnswIndex` 图(原 BCVS;int8-only 盘上仍 f32) |
| 5 | `meta` | **可选加速** | `u32 count; [ord; blob]×`(过滤搜索免按 ord 读 data;缺失则按需读) |
| 6 | `terms` | **可选加速** | `ord → 分析后 term`(回放/重建免重分词;缺失则 fold 原文重分词) |

新增索引类型只登记新 type,**不新增文件**。

**type 1/5/6 是纯加速缓存(可删、不参与正确性)**:
- `docmap`(type 1):在 → 直接载入 `docs/_docs`;**不在 → 从 `keydir(ord→key) ⋈
  bm25 postings(ord→doc_len) + fold 尾巴` 现场推导**——bitcask 的 v5 impacts 已在
  posting 持久化 per-doc `doc_len`(`inverted.hpp:88`,`doc_len=Σtf`),`live` 由
  keydir(ord==keydir[key].ord)定,纯向量/空文本文档(无 postings)由 keydir 覆盖、
  dl=0。两条路结果等价。**故 docmap 不再是真相、不与 keydir 抢权威**(化解
  keydir/docmap 重复 + loc 分叉,见 §6.6)。
- `terms`(type 6)取代旧 bm25 WAL 的"免重分词"价值,但与"WAL=耐久日志"语义分离(§6)。

**不再设 `coverage` 段**:完整性由 watermark + fold 兜底(§4);存活 ord 集已由
docmap(含 live)或 keydir 推导覆盖,无需单列。

## 4. 恢复模型:分段载入 + 单趟尾部回放

open 流程(取代 `load_recovery_snapshots` + `load_keydir_from_disk` 双轨):

1. **载 keydir**:`kv.keydir.ckpt`(单块,CRC 校验)。失败 → keydir 视为空,
   其水位 = 0。
2. **载 search.ckpt(分段)**:
   - 读页脚 footerCrc:**结构完整**才继续;结构损坏(页脚缺失/footerCrc
     失败,tmp+rename 已基本杜绝)→ **回退 `search.ckpt.prev`**(同样校验);
     都不行 → 整个 search 视为空(水位 0,全量重建兜底)。
   - 遍历目录**逐段校验 CRC**:CRC 通过 → 载入该段(docmap/bm25/hnsw);
     **CRC 失败 → 仅标记该 type「待重建」,其余段照常载入**(损坏隔离)。
3. **重建 `docs/_docs`(ord→doc)**:
   - `docmap` 段在且 CRC 通过 → **直接载入**(key/loc/live/doc_len,免推导)。
   - 否则 → 从 **keydir(ord→key) ⋈ bm25 postings(ord→doc_len)** 现场推导;
     纯向量/空文本文档由 keydir 覆盖、dl=0;未覆盖的 ord 由第 4 步 fold 补全。
     (docmap 是纯加速缓存,缺失不影响正确性——见 §3.3、§6.6。)
4. **水位模型(简化:单 ord watermark + keydir 字节水位 + 保存序不变量)**:
   - `kv.keydir.ckpt` 带 **per-file 字节水位**(fold 的 `start_offset` 驱动,不变)。
   - `search.ckpt` 头部只带**单个 ord watermark** = 保存时 `next_ord`(它覆盖的
     搜索 ord 上界);**不需要** per-file 字节水位。
   - **保存序不变量**:`keydir_covered ≤ search_covered`——close 端两者同点(相等)、
     merge 端 keydir 水位在 flush 前捕获(≤ 搜索覆盖)。现存代码已维持(§5)。
   - **fold 下界**:`fold_start(fid) = (search.ckpt 健康且全段 CRC 通过) ?
     keydir_wm(fid) : 0`。因不变量 `keydir_covered ≤ search_covered`,从
     keydir_wm 起 fold 给出的 `[keydir_covered, end)` **必覆盖搜索所需的
     `[search_covered, end)`**——搜索各索引按自身 ord 水位**自门**丢弃
     `[keydir_covered, search_covered)` 的重叠。
5. **单趟 fold**:对每个 data 文件从 `fold_start(fid)` fold 到尾,**一个回调**
   同时喂 `keydir.put/remove` + `DocIndex.put_doc` + `bm25.add_doc/remove`
   + `hnsw.insert`(沿用现 fold 回调结构;不再走「有 search_layer 跳过 hint」特判)。
   - **自门**:bm25/hnsw/docmap 均 ord 水位幂等(add_doc 丢 ord≤floor、insert 丢
     ord≤水位、put_doc 覆盖),keydir put 覆盖——故重喂恒安全,无需逐索引显式门。
   - **段级重建**:某搜索段 CRC 坏/缺(第 2 步)→ 内存为空、需 `[0,end)`;此时
     `fold_start` 取 **0**(健康段已载入,fold 中靠自门跳过其重应用,**只有坏段
     真正重建** → bm25 坏只重分词、hnsw 坏只重插)。即 I/O 不省但 CPU 只付坏段。
6. **幂等收敛**:回放区每条都是重 put/重 insert,与全量 fold 同语义
   (`recovery-snapshot-design-zh.md §2.1`),方向安全。

**无成对门、无悬崖**:健康路径 `fold_start=keydir_wm`(跳 I/O、各索引自门);仅当
keydir.ckpt 缺失**或**某搜索段坏/缺(且 keydir 水位>0)才回退 `fold_start=0`——
后者 I/O 不省,但 CPU 只付"坏段重建",健康段自门跳过。**罕见损坏 ≠ 全库全量重建。**

## 5. 写入(snapshot)流程 + 周期 checkpoint

现仅 close(`cask.cpp:674`)/merge(`:1675/:1734`)。新增周期触发,把
`wm_min` 拉近尾部、限定崩溃后回放量。`search.ckpt` 单文件分段写流程:

```
1. drain 异步索引(IndexPool 静止);watermark = keydir.next_ord。
2. 逐段 type:
   - 该段自上次 checkpoint「脏」(有相应写入)→ 重新序列化 payload + 算 crc。
   - 否则【段级复用】→ 从旧 search.ckpt 按旧目录把该段原始字节拷贝前移
     (含旧 crc),不重序列化。
3. 写 temp:头部 + 各段 payload + 页脚目录(每段 offset/len/crc) + footerCrc
   + dirLen + trailer。fsync temp。
4.【代际】把现有 search.ckpt 重命名为 search.ckpt.prev(覆盖旧 .prev)。
5. rename(temp → search.ckpt)(原子)。
6. keydir.ckpt 单块照常 tmp+rename(独立)。
```

- **脏标记**:写路径维护 4 个 dirty bit(bm25 写 / 字段写 / 向量写 / docmap
  写),落快照后清零。无向量写的周期里 `hnsw` 段**零成本前移**——砍写放大。
- **触发**:写入字节/文档累计超阈值(`checkpoint_interval`),在 worker
  静止窗口执行。
- **静止性**:沿用「写者静止点才 dump」(`recovery-snapshot-design-zh.md §2.4`)。
- **顺序**:watermark **先于** payload 捕获(水位 ≤ 覆盖点 ⟹ 回放区与快照
  重叠,幂等安全);keydir.ckpt 与 search.ckpt 落盘顺序无关(回放取 wm_min)。

## 6. 删 bm25 WAL 的论证与替代

- **可删性**:bm25 增量已在 data 文件(text 段)持久化;fold 尾部经
  analyzer 重建倒排,与现 `recover_doc` 路径一致。WAL 非真相源。
- **唯一损失**:replay 免重新分词。量级 = 「两次 checkpoint 间新增文档」
  的 tokenization,被 §5 周期阈值限定有界。
- **替代(可选,profiling 驱动)**:若实测 tokenization 占回放主成本,
  引入 `search.bm25.f{i}.terms`——只缓存「ord → 分析后 term」,回放时
  命中则免分词,缺失则 fold 原文。它是**纯加速缓存**(可删、不参与门),
  与「WAL=耐久日志」语义分离,不恢复双重日志。
- **迁移**:`enable_wal/replay_wal/truncate_wal` 调用点摘除;`InvertedWal`
  保留为 terms-cache 的载体或整体下线(二期决定)。

## 6.5 代际回退(`.prev`)——增量源是 data 文件,不是搜索 WAL

`.prev` 是上一代 `search.ckpt`(覆盖较老 watermark)。最新 `search.ckpt`
**整体**位腐(footerCrc 失败)时回退它,再追平到当前:

```
最新 search.ckpt footerCrc 失败
  → 载 search.ckpt.prev(逐段 CRC 同样校验)
  → fold data 尾巴(从 .prev 的 per-file 水位起)补 [watermark_prev, now) 增量
  → 恢复到当前
```

**关键**:追平的增量来自 **data 文件尾巴(我们的 WAL)**,不需要搜索 WAL。
因此「砍搜索 WAL」与「保留 `.prev`」**互不冲突、各自独立**(cellar 更新版
已与此完全一致:同样砍搜索 WAL、`.prev` 用 data 尾巴追平)。

- 在本架构里 `.prev` 是**纯恢复提速**:把"最新损坏"从全库重建降到尾巴重放;
  正确性始终由 data 文件兜底,非 durability 必需。
- 增量"保留"免费:data 记录在 merge 前一直在;merge 搬走的记录换新
  ord/位置后 fold 当前文件照样重放(成对门处理"不在水位表→从 0 fold",
  见 §7.3)。**无需"WAL 保留到最老代际"那种截断策略**。
- 段级 CRC(§3.2)与 `.prev` 互补:**单段坏**→ 当代按段重建(§4.2);
  **整文件结构坏**→ 回退 `.prev`。二者覆盖不同损坏粒度。

## 6.6 docmap 是纯缓存,不与 keydir 抢权威(去重)

docmap 每行 7 个字段与 keydir **6 个重合**(key/file_id/offset/total_sz/tstamp/ord),
唯一独有的是 `doc_len`。本设计(采纳 cellar 更新版)把 docmap 段做成**可选加速
缓存**,所有字段都有派生来源,故**不再独立持久化、不与 keydir 抢真相**:

- `ord→key`、`live`(ord==keydir[key].ord)← **keydir**。
- `doc_len` ← **bm25 postings**(bitcask v5 impacts 已存 per-doc dl,`doc_len=Σtf`)。
- 无 postings 的纯向量/空文本文档 ← **keydir** 覆盖,dl=0。

收益:① 消除 keydir/docmap 的字段重复与"两份 loc 因 merge 分叉"风险(单一真相
= keydir+bm25);② docmap 在 → 省一次 join+postings 扫描的载入加速;不在 → §4.3
现场推导,正确性不依赖它。这也是为什么 **keydir 不并进 `search.ckpt`**:它是 KV
层、纯 KV 库也有,docmap 反过来从它派生即可。

## 7. 关键不变量

1. **wm_min 安全**:回放下界取各块水位最小 ⟹ 任一块的尾巴都被覆盖;
   某块 checkpoint 缺失(水位=0)⟹ 该块从头重建,其余块多读尾巴无害
   (幂等)。
2. **崩溃任意点**:checkpoint 偏旧或部分写(tmp 未 rename)⟹ 对应块退回
   旧态/空态,wm_min 下移,fold 补齐。无「门失败 → 全量 fold」悬崖。
3. **merge unlink 竞争**:沿用 `recovery-snapshot-design-zh.md §2.3`——
   指向已 unlink 文件的 entry 被 merge 输出文件以同 ord 重 put 覆盖。
4. **ord 单调**:回放 `advance_ord(view.ord)` 重建 next_ord;checkpoint
   的 next_ord 仅作上界校验(`peek_next_ord`)。

## 8. 阶段划分(诚实边界)

> 路线图编号见 `ROADMAP.md` P14;子阶段 P14a–d 与本节一一对应
> (避免与 2.1.0 的 P1–P4 撞号)。开发顺序(与 P5–P13 交织)见 ROADMAP「开发顺序」。

- **P14a**(已落地):纯重命名 + 文件契约文档化。`.snap→.ckpt`、bm25
  base `bm25_snapshot.inv→search.bm25`、段 `.f{i}.inv→.f{i}.seg`、
  WAL `.f{i}.inv.wal→.f{i}.wal`;代码常量(`kKeydirSnapName` 等)与
  写/读路径同步;**无格式/逻辑变更**。
  迁移(不考虑可重建文件兼容,见原始约束):**旧名不再读**——升级后
  首次 open 因找不到新名 checkpoint 走一次全量 fold,close 落新名;
  旧名文件成孤儿(无害,可手删)。meta/field.schema/data/hint 不动。
  验证:`cpp/` 全量 410 测试通过。
- **P14b**:统一 wm_min 单趟回放,替换双轨 + 成对门悬崖。删除「有
  search_layer 跳过快路径」逻辑。
- **P14c**:周期性 checkpoint(`checkpoint_interval` 配置 + worker 静止窗口)。
- **P14d**:摘除 bm25 WAL;按 profiling 决定是否引入 `terms` 缓存。
- **P14e**(新增,与 cellar 全面收敛):把 P14a 的多文件搜索 checkpoint 收编为
  单个分段 `search.ckpt`(§3.2:页脚目录 + 逐段 CRC + 段级脏位复用)+ 代际
  `search.ckpt.prev`(§6.5)。`kv.keydir.ckpt` 保留独立。恢复改为分段载入 +
  段级重建 + `.prev` 回退(§4)。**docmap/meta/terms 做成可选加速缓存**:
  docmap 缺失时从 `keydir⋈bm25 postings + fold` 派生 `docs/_docs`(§4.3、§6.6)——
  需给恢复路径加这条派生路。旧多文件名不再读(可 fold 重建,flag-day)。
- 各阶段独立可上线、独立验收;P14a 即可消除命名混乱,P14e 收口为单文件。

## 9. 验收

- **等价性**:任意阶段后,「checkpoint 路径 reopen」与「删全部 .ckpt
  全量 fold reopen」键集/值/删除/检索结果一致(KV + bm25 + 向量三模)。
- **重用率**:崩溃注入(kill -9 于持续写入中)后 reopen,P2 起**不再
  全量 fold**,fold 区间 ≈ `tail_from(wm_min)`;P3 后该区间被周期阈值限定。
- **IO 下降**:P4 后单次搜索 put 的写放大从 2(data+WAL)降到 1;
  统计稳态文件数减少(无 `.wal`)。
- **损坏注入(P14e 段级)**:翻转 `search.ckpt` **单段** payload 字节 → 仅该
  type 走重建、其余段正常载入(验证损坏隔离);翻转**页脚** → 回退 `.prev`
  + fold 尾巴追平;两者数据/检索结果均与全量 fold 等价。
- **代际回退**:会话2写入后 kill,损坏最新 `search.ckpt` → reopen 用 `.prev`
  + data 尾巴恢复,会话2 的写/删可见。
- **段级复用**:无向量写的周期落 checkpoint → `hnsw` 段字节与上代逐字节相同
  (未重序列化)。
- **基准**:`BM_Cask_Open` 三模 × {clean close / crash} × {有无周期
  checkpoint};写放大 / 稳态文件数对照。

## 10. 与 cellar 提案(`design-cellar-search.md`)对比——已全面收敛

cellar(JDK/.NET 姊妹引擎)更新版**已和本设计完全收敛到路线 A**:两引擎在
搜索持久化上一致——单文件分段 + 逐段 CRC + 页脚目录 + 段级脏位复用 + 代际
回退 + 周期 checkpoint,且**都以 data 文件为唯一 WAL、砍掉搜索 WAL、`.prev`
用 data 尾巴追平**。docmap/meta/terms 同为可选加速缓存,均无 `coverage` 段。

| 维度 | 本设计 | cellar(更新版) |
|---|---|---|
| 搜索快照 | `search.ckpt` 分段 + 逐段 CRC + 页脚目录 | `cellar.search`,**同** |
| 段编号 | 1 docmap·2 bm25.default·3 bm25.fields·4 hnsw·5 meta·6 terms | **同** |
| docmap/meta/terms | 可选加速缓存,缺失从 keydir⋈postings+fold 派生 | **同** |
| 搜索 WAL | **无**(data 即 WAL) | **无**,**同** |
| `.prev` 追平增量源 | data 尾巴 | data 尾巴,**同** |
| 完整性守卫 | watermark + fold(无 coverage 段) | **同** |
| keydir/hint | 与 search 分层(`kv.keydir.ckpt` 独立) | 与 search 分层,**同** |

**唯一差异 = 命名/magic**:本设计 `search.ckpt` / `BCSC`,cellar `cellar.search`
/ `CSCH`——**当前不互通**(搜索 checkpoint 是各自本地缓存,本就不要求跨引擎
互读;跨引擎互读的是 data/hint/meta/DocValue 等**真相源**)。段 payload 沿用
各自中立小端序列化;若未来要让 checkpoint 也跨引擎互读,再统一 magic/前缀/
段编号。
