# 恢复持久化统一:checkpoint 命名 + 单趟尾部回放(路线 A)

> 对应代码:`keydir.cpp`(save/load_snapshot)、`search_layer.cpp`
> (save/load_index_sidecar、save/load_vec_snapshot、load_snapshot)、
> `inverted.cpp`/`inverted_wal.cpp`(bm25 WAL)、`cask.cpp`
> (`load_recovery_snapshots`/`load_keydir_from_disk`/写入点)。
> 背景:本文取代并收敛 `recovery-snapshot-design-zh.md` 的命名与
> 多写者日志策略;不变量论证沿用其 §2,不重复。

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
- **重用率靠 checkpoint 频率提升,不靠加 WAL。** 给 keydir/docmap/hnsw
  补 WAL 是反方向(更多文件+fsync,且 hnsw WAL ≈ 重新 insert,无收益)。
- **后缀编码契约**:`.ckpt`=可重建 checkpoint,`.wal`=日志,`.seg`=段,
  `.manifest`=清单。所有派生文件可删,删后 fold 重建。

## 3. 命名方案(`{kv|search}.{组件}.{ckpt|seg|wal|manifest}`)

| 现名 | 新名 | 角色 |
|---|---|---|
| `bitcask.keydir.snap` | `kv.keydir.ckpt` | KV 索引 checkpoint |
| `bitcask.index.snap` | `search.docmap.ckpt` | 搜索文档目录(ord↔key/loc/live/dl) |
| `hnsw.snap` | `search.vec.ckpt` | 向量图 checkpoint |
| `bm25_snapshot.inv.manifest` | `search.bm25.manifest` | 字段清单 |
| `bm25_snapshot.inv.f{i}.inv` | `search.bm25.f{i}.seg` | per-field 倒排段 |
| `bm25_snapshot.inv.f{i}.inv.wal` | **删除** | 见 §2/§6 |
| `N.bitcask.hint` | 保留 | legacy 工具依赖,不动 |
| `N.bitcask.data` | **保留** | legacy 格式,改名断 rebar/legacy 链 |
| `bitcask.meta` / `field.schema` | 保留 | 权威元数据,不可 fold 重建 |

> "index" → "docmap":原名歧义(keydir 也是 index),它实为搜索层的
> 文档目录。命名一眼读出「哪层·哪组件·什么契约」。

## 4. 恢复模型:单趟尾部回放

open 流程(取代 `load_recovery_snapshots` + `load_keydir_from_disk` 双轨):

1. **载 checkpoint**:`kv.keydir.ckpt` → keydir;`search.docmap.ckpt` →
   DocIndex;`search.bm25.*` → 倒排;`search.vec.ckpt` → 图。任一校验
   失败 → 该块视为空,其覆盖水位 = 0(退化为从头 fold,语义安全)。
2. **统一水位**:每块 checkpoint 携带 **per-file 字节水位**(覆盖到的
   data 文件偏移)。回放下界取**各块水位的最小值** `wm_min(fid)`——
   保证回放区对每个索引都是「尾巴」,无遗漏。
3. **单趟 fold**:对每个 data 文件,从 `wm_min(fid)` fold 到尾。**一个
   回调里同时**喂四个索引:`keydir.put/remove` + `DocIndex.put_doc` +
   `bm25.add_doc/remove` + `hnsw.insert`(沿用现 fold 回调
   `cask.cpp:783-818` 的结构,只是把下界从 per-keydir-wm 改为 wm_min,
   且不再走「有 search_layer 就跳过 hint」的特判——回放只认 data)。
4. **幂等收敛**:回放区每条都是重 put/重 insert,与全量 fold 同语义
   (`recovery-snapshot-design-zh.md §2.1`),方向安全。

成对门简化:不再要求四块**各自**覆盖 `next_ord`;改为「**回放从 wm_min
起,fold 必然把每块补齐到 next_ord**」。即门恒可过,代价是 fold 区间 =
`tail_from(wm_min)`。最弱环只影响**回放多读多少尾巴**,不再触发**全量
fold**——这正是重用率从 0 提升的关键。

## 5. 周期性 checkpoint

现仅 close(`cask.cpp:674`)/merge(`:1675/:1734`)。新增周期触发,把
`wm_min` 拉近尾部、限定崩溃后回放量:

- **触发**:写入字节数 / 文档数累计超阈值(配置 `checkpoint_interval`),
  在 IndexPool worker 静止窗口执行(避免与 fold/insert 抢写)。
- **静止性**:沿用现有「写者静止点才 dump」约束
  (`recovery-snapshot-design-zh.md §2.4`,活跃 fold 时 save 返回 false)。
- **原子性**:每文件 tmp+rename(现 keydir/docmap/bm25/hnsw 已是此模式)。
- **顺序**:水位**先于** dump 捕获(水位 ≤ 覆盖点 ⟹ 回放区与 checkpoint
  重叠,幂等安全);多块落盘顺序无关(回放取 wm_min,任意子集陈旧都安全)。
- **bm25 段**:周期 checkpoint 即重写 `search.bm25.f{i}.seg`,旧 WAL 概念
  消失(§6)。

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
- 各阶段独立可上线、独立验收;P14a 即可消除命名混乱。

## 9. 验收

- **等价性**:任意阶段后,「checkpoint 路径 reopen」与「删全部 .ckpt
  全量 fold reopen」键集/值/删除/检索结果一致(KV + bm25 + 向量三模)。
- **重用率**:崩溃注入(kill -9 于持续写入中)后 reopen,P2 起**不再
  全量 fold**,fold 区间 ≈ `tail_from(wm_min)`;P3 后该区间被周期阈值限定。
- **IO 下降**:P4 后单次搜索 put 的写放大从 2(data+WAL)降到 1;
  统计稳态文件数减少(无 `.wal`)。
- **损坏注入**:任一 .ckpt 截断/位翻转 → 该块退空、wm_min 下移、fold
  补齐,数据完好;无悬崖。
- **基准**:`BM_Cask_Open` 三模 × {clean close / crash} × {有无周期
  checkpoint},对照全量 fold。
