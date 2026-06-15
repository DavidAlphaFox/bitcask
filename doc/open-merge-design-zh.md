# P13 — open 时按需后台 merge（小文件收拢）设计

> 状态：2.1.1 承诺项（方案 A）。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；
> merge 策略见 [`merge-policy-zh.md`](merge-policy-zh.md)；并发/锁见
> [`concurrency-zh.md`](concurrency-zh.md)。

## 1. 背景与根因

每个 read_write 会话**首次写**时 `ensure_active_writer`（`cask.cpp:923`）调
`increment_file_id()`（`keydir.cpp:995` = `biggest_file_id_ + 1`）建一个**新** active
`<id>.bitcask.data` + `.hint`。file_id **单调、跨 open/close 永不回退**
（`saved_biggest_file_id_` 恢复）。

→ 有文件 1、2 的库，open 后首次写得到 **3 号新文件**，**不会重开 2 号续写**（2 号已
sealed/immutable，续写要 un-seal、且破坏 file_id 单调与 sealed 不可变前提）。

→ 结果：**多次「open-写一点-close」会累积大量小文件**（by design）。close 本身不建
文件、只封口当前 active；open 不写也不建（懒触发）。

## 2. 误区校正（收益在哪）

「合并小文件 → 提高读取效率」**部分是误区**：单次 `get` 走 keydir O(1) 拿
`(file_id, offset)` → **一次 pread**，与文件数**无关**（keydir 就是精确索引）。合并
**不会让单次 get 更快**。

文件多真正拖累的是：
- **open 成本**：`scan_dir` 列全部 + 逐文件 fold(hint) 重建 keydir（即便有快照+尾部回放）。
- **fd**：`read_files_` 每文件常驻 fd（见 P9，大库撞 ulimit）。
- **mmap 友好度**（P6）、**死空间**（跨会话覆盖留下的死记录）。

文档须如实写明：收益是 **open / fd / mmap / 死空间回收**，不是单 get 延迟。

## 3. 方案 A（承诺）：open 时按 `needs_merge` 门控、**后台**触发 merge

- open（read_write）后判 `needs_merge`（复用现有阈值 `small_file_threshold` /
  `frag_threshold` / `dead_bytes_threshold`）。命中才触发。
- **后台执行，不阻塞 open**：merge 走 dirty 调度器 / `bitcask_merge_worker`，open 立即
  返回。**绝不在 open 同步跑 merge**（见 §5）。
- 产物 = 你要的形态：少数 sealed（merge 输出）+ 下次写起一个**全新 active**。
- **复用**：`merge` + `needs_merge` + `bitcask_merge_worker` + `small_file_threshold`
  全部已存在——P13 主要是**触发接线 + 选项**，非新机制。
- 选项：`{merge_on_open, off | background}`（默认建议 `off`，由部署显式开；或对小文件
  场景默认 `background`）。

## 4. 方案 B（备选）：open 时复用上一个未满文件续写

从源头止住「每会话一个小文件」：不新建 active，重开上一个**未满 sealed 文件**续 append。
- 代价：要 **un-seal**（旧 hint trailer 失效需重写）、file_id 处理、与并发 merge 交互；
  且**破坏「sealed 不可变」**——而 P6 的 mmap 正依赖该不变量。
- 故 **invasive、风险高 → 备选**。仅当短会话小文件是压倒性痛点、且方案 A 的后台延迟不够
  及时才评估。

## 5. 否决：无条件 / 同步 merge-on-open
每次开库都 O(live data) 重写——**毁掉快照快开**（open 从 O(tail) 退化为 O(data)），
大库灾难。必须门控 + 后台。

## 6. 跨进程 / 锁
- merge 持 `bitcask.merge.lock`（独立锁，**不阻塞 writer**）；作为 writer open 时持
  `write.lock`，后台 merge 与之并发安全（既有 1 writer + 1 merger + N reader 模型）。
- 已有别的 merger 持 merge.lock → 本次跳过（`{error, {merge_locked, ...}}` 容忍）。

## 7. 子任务
- **P13a**：open（read_write）末尾按 `needs_merge` 判定的触发钩子。
- **P13b**：后台执行（merge_worker 接线 / 异步 dirty），open 非阻塞；`{merge_on_open, ...}` 选项 + NIF/facade 接线。
- **P13c**：`small_file_threshold` 缺省调优 + 文档（校正「读效率」表述为 open/fd/mmap/死空间）。

## 8. 风险
- **别同步**：同步 merge 阻塞启动——强制后台。
- 后台 merge 与正常读写抢 IO/CPU（既有 merge 代价，dirty 调度器隔离主调度）。
- 短命进程：open 即触发后台 merge 但进程很快退出 → merge 可能未跑完/被打断（merge
  是幂等可重入的写新删旧，无损；下次再触发）。
- 默认值选择：默认开会让所有部署在 open 时承担后台 merge——倾向**默认 off、显式开**。

## 9. 测试
- 制造小文件（多次 open-写-close）→ open 配 `background` → 后台 merge 后文件数收敛到
  少数 sealed + 新 active；keydir/搜索结果不变。
- needs_merge 不满足 → 不触发（open 不变慢）。
- 同步禁止：断言 open 不被 merge 阻塞（计时 / 不在 open 线程跑 merge）。
- merge_locked 并发：别的 merger 在跑 → open 跳过、不报错。
