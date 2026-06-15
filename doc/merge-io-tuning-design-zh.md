# P11 — merge I/O 顺序优化 设计

> 状态：2.1.1 承诺项（小项）。路线图见 [`../ROADMAP.md`](../ROADMAP.md)；merge 见
> [`merge-policy-zh.md`](merge-policy-zh.md)、[`merger.cpp`]。

## 1. 背景

merge 顺序**读旧文件**（`run_merge` fold 各输入文件）+ **写新文件**（`out_data`），
但读路径用 `pread`、写用 `pwrite`，**无 readahead / 缓存策略提示**。merge 是冷路径
但 I/O 量大（O(live data)），缺省策略下可能 readahead 不足 + 污染 page cache。

## 2. 方案

- **读侧**：对 merge 输入文件 `posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL)`
  （增大内核 readahead 窗口）+ 可选 `WILLNEED`（预取）。
- **写侧/收尾**：merge 完成后对已合并的旧输入文件可 `POSIX_FADV_DONTNEED`，避免大 merge
  把热数据挤出 page cache（cache pollution）。
- 可选：merge fold 用更大读缓冲（顺序读，大块更省 syscall）。
- 全部是**advisory**，失败/不支持平台静默忽略，不影响正确性。

## 3. 子任务
- **P11a**：merge 输入 open 后 `fadvise(SEQUENTIAL)`；fold 大缓冲。
- **P11b（可选）**：merge 收尾对旧输入 `DONTNEED`；评估是否值得（DONTNEED 用错会伤
  并发读者的命中——仅对**确定即将 unlink** 的输入用）。

## 4. 边界 / 风险
- `DONTNEED` 要谨慎：只对 merge 即将 unlink 的旧文件用；正在被 reader/fold 命中的页
  别丢（保守起见可只做 SEQUENTIAL，不做 DONTNEED）。
- 平台差异：fadvise 仅 POSIX；非 Linux 行为不同——能力探测 / 忽略。

## 5. 测试
- merge 正确性不变（fadvise 是 advisory，结果应完全一致——复用现有 merge 测试）。
- 性能为基准项（大库 merge 墙钟），非断言。
