# WAL 批量 flush 设计（V6.2）

> 状态：已实施（V6.2.2–V6.2.4）。默认 batch_size=1（零风险），隔离微基准 2.1x 提速。

## 1. 问题

`InvertedWal` 每条 `append_add_doc` / `append_remove_doc` 调用都执行
`fwrite + fflush`。`fflush` 强制 OS buffer 刷到内核 page cache，单次约 1–3μs。
高写入场景（批量索引重建、大量 `put`）下，逐条 fflush 是吞吐瓶颈。

**目标**：缓冲 N 条 entry 到内存 batch_buf，一次 `fwrite` 写出全部，一次
`fflush` 刷盘。`batch_size` 可配，默认=1（等价当前行为）。

## 2. 设计

### 2.1 帧格式不变

现有 O11 framing `[4B len][payload][4B crc32]` 保持不变。批量模式下，
多条 framed entry 拼接在 `batch_buf_` 中，一次 `fwrite` 写出整块。
replay 侧逐条解析，不感知批量边界。

```
batch_buf_ layout (batch_size=3):
┌──────────────┬──────────────┬──────────────┐
│ entry 0 完整 │ entry 1 完整 │ entry 2 完整 │
│ [len][pl][crc]│ [len][pl][crc]│ [len][pl][crc]│
└──────────────┴──────────────┴──────────────┘
         ↕ 一次 fwrite + 一次 fflush
```

### 2.2 InvertedWal 新增字段

```cpp
class InvertedWal {
    // ... 现有字段 ...
    std::vector<std::uint8_t> batch_buf_;   // 批量缓冲（复用容量）
    std::size_t batch_count_ = 0;           // 当前 batch 已缓冲条数
    std::size_t batch_size_  = 1;           // 配置：每 batch 最多多少条
};
```

### 2.3 构造函数签名变更

```cpp
explicit InvertedWal(std::string_view path, std::size_t batch_size = 1);
```

`batch_size = 1`：每次 append 立即 `fwrite + fflush`（当前行为）。
`batch_size > 1`：缓冲到 batch_buf_，满后一次性 `fwrite + fflush`。

### 2.4 seal_and_write 改造

```cpp
void InvertedWal::seal_and_write() {
    // --- 封口（不变）---
    const auto payload_len = enc_buf_.size() - kWalLenPrefix;
    const auto len32 = static_cast<std::uint32_t>(payload_len);
    std::memcpy(enc_buf_.data(), &len32, kWalLenPrefix);
    const auto crc = crc_of(enc_buf_.data() + kWalLenPrefix, payload_len);
    put_u32(enc_buf_, crc);

    if (batch_size_ <= 1) {
        // 即时模式：逐条 fwrite + fflush（当前行为）
        std::fwrite(enc_buf_.data(), 1, enc_buf_.size(), file_);
        std::fflush(file_);
        return;
    }

    // 批量模式：追加到 batch_buf_
    batch_buf_.insert(batch_buf_.end(), enc_buf_.begin(), enc_buf_.end());
    ++batch_count_;
    if (batch_count_ >= batch_size_) {
        flush_batch();
    }
}

void InvertedWal::flush_batch() {
    if (batch_buf_.empty() || !file_) return;
    std::fwrite(batch_buf_.data(), 1, batch_buf_.size(), file_);
    std::fflush(file_);
    batch_buf_.clear();
    batch_count_ = 0;
}
```

### 2.5 析构函数

析构时必须 flush 剩余 batch，否则未刷盘的 entry 丢失：

```cpp
InvertedWal::~InvertedWal() {
    if (file_) {
        flush_batch();  // 刷残余
        std::fclose(file_);
    }
}
```

### 2.6 truncate() 改造

清空文件前先清 batch_buf_：

```cpp
bool InvertedWal::truncate() {
    batch_buf_.clear();
    batch_count_ = 0;
    // ... 现有 reopen "wb" 逻辑 ...
}
```

### 2.7 replay() 不变

replay 逐条读取 `[4B len][payload][4B crc]`，不感知写入时是否批量。
CRC 校验 + 截断至 last_good 的逻辑完全复用。

## 3. 崩溃窗口分析

| batch_size | 崩溃时丢失 | 说明 |
|------------|-----------|------|
| 1（当前） | 0 条 | 每条 fflush，崩溃不丢 |
| N > 1 | ≤ N-1 条 | 未 flush 的 batch_buf_ 内容丢失 |

**不变量保持**：已 `fflush` 的 entry 一定持久化。replay 的 CRC 校验会
自动截断半条 entry。batch 模式下丢失的是「缓冲中尚未写出的 entry」，
等价于这些 entry 从未 append 过——语义上与「put 尚未到达 WAL」一致。

**安全性**：batch_buf_ 中的 entry 尚未进入 WAL 持久化边界。崩溃恢复时
replay 看不到它们 → 对应文档不会出现在倒排索引中 → 与数据文件中的记录
一致（data file 写入和 WAL 写入是同一个 put 调用链，crash 前 data file
的 fwrite 也可能丢失）。因此 batch WAL 不降低系统级一致性。

## 4. 配置管道

```
CaskOptions
  └→ SearchLayerConfig
       └→ wal_batch_size (新增字段, 默认=1)
            └→ SearchLayer::enable_wal(path, batch_size)
                 └→ InvertedIndex::enable_wal(path, batch_size)
                      └→ InvertedWal(path, batch_size)
```

`batch_size=1` 时行为完全等价当前，零风险默认。

## 5. 子任务拆分

| # | 内容 | 依赖 |
|---|------|------|
| V6.2.1 | 设计文档（本文档） | — |
| V6.2.2 | InvertedWal 批量缓冲实现 + 配置管道 | V6.2.1 |
| V6.2.3 | CrashRecoveryBatched 测试 | V6.2.2 |
| V6.2.4 | 基准 BM_Put_WalBatch：batch_size=64 目标 > 2× throughput | V6.2.2 |

## 6. 不做的事

- **不做异步 flush 线程**——batch flush 仍同步（append 到 N 条后同步 flush），
  异步引入线程安全复杂度，归入 V7+
- **不做 WAL 跨线程 group-commit**——WAL 非线程安全，caller 串行化
- **不改 replay 逻辑**——帧格式不变，replay 完全复用
