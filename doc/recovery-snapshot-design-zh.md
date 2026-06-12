# A4:keydir 段快照 + 尾部回放(open 加速)

> 对应代码:`keydir.cpp` 的 `save_snapshot/load_snapshot`、
> `data_file.cpp` 的 `fold(start_offset)`、`cask.cpp` 的写入/加载点。
> 背景:`doc/cpp-optimization-zh.md` §8.3 L4;`vector-db-design-zh.md`
> 的「扩展 hint + 段文件 + 回放尾巴」方向。

## 1. 问题与方案

open 重建 keydir 目前要 fold 全部 data(或 hint)文件,O(全库)。
方案:在**写者静止点**(close、merge 末尾)把 keydir 内存态整体落盘,
附带**per-file 字节水位**;open 时加载快照,再只 fold 各文件水位之后
的尾巴。快照是**纯优化**:任何校验失败 → 丢弃,走原全量 fold。

## 2. 关键不变量与论证

1. **水位先于 dump 捕获**:水位 ≤ 快照覆盖点 ⟹ 尾部回放区间与快照
   有重叠,重放是重 put/重 remove——keydir fold 语义本就幂等
   (全量 fold 同样反复覆盖),方向安全。
2. **快照 = keydir 精确状态**:覆盖区内的墓碑已体现为"键不存在",
   无需重放;水位后的墓碑由尾部 fold 正常执行。
3. **崩溃于 merge unlink 与快照写之间**(快照偏旧):快照里指向已
   unlink 文件的 entry,其 key 必然被 merge 输出文件(不在水位表 →
   从 0 全量 fold)以同 ord 重 put 覆盖;与现状「old+merge 文件并存
   崩溃」同一恢复语义。
4. **活跃 fold(MultiEntry 存在)时拒绝快照**:save 返回 false,
   本次放弃——快照点都在写者静止处,正常不会撞上。

## 3. 格式(bitcask.keydir.snap,LE,tmp+rename 原子写)

```
[magic "BCKS"][ver=1]
payload:
  next_ord u64 | epoch u64 | biggest_file_id u32 | key_count u64 | key_bytes u64
  fstats_n u32 × {file_id,live_keys,total_keys,live_bytes,total_bytes,
                  oldest,newest,expiration}
  wm_n u32 × {file_id u32, covered_offset u64}
  entry_n u64 × {klen u16, key, file_id u32, total_sz u32,
                 offset u64, epoch u64, tstamp u32, ord u64}
[crc32(payload)]
```
O11 同款防御:长度/CRC 校验失败、截断、版本不识 → load 返回 nullopt
并清空状态,调用方全量 fold。

## 4. 阶段划分(诚实边界)

- **Phase 1(本次)**:仅 **KV 路径**(无 search_layer)启用快照快路径。
- **Phase 2(待做)**:search 路径——open 现状**从不加载** bm25 快照
  (只在 merge 时保存),search 恢复完全依赖全量 data fold 的
  recover_doc。启用前缀跳过必须先:① open 接通
  `search_->load_snapshot` + WAL 重放;② keydir 快照与 bm25 快照在
  同一静止点成对落盘,加载时校验成对性(否则跳过的前缀文档在搜索侧
  丢失)。add_doc 的 ord 水位幂等已为重放重叠区兜底。

## 5. 写入点与触发

- `Cask::close()`:close_write_file 之后(写者静止),best-effort;
- `Cask::merge()` 末尾:trim_fstats 之后(水位取 unlink 后的现存文件);
- 水位 = scan_dir 各 data 文件当前字节大小(pwrite 无缓冲,fs size 精确)。

## 6. 验收

- 等价性:快照路径 reopen 与删快照全量 fold reopen,键集/值/删除一致;
- 陈旧快照尾部回放:会话 2 的写/删在用会话 1 快照恢复后可见;
- 损坏注入:截断/位翻转 → 回退全量 fold,数据完好;
- 基准:BM_Cask_Open 快照 vs 全量 fold(20k 记录)。
