# C++ 代码优化分析报告

> 基于对 `cpp/` 目录下全部 22 个 `.cpp` + 37 个 `.hpp` 源文件的深度审阅。
> 覆盖 I/O 层、内存管理、并发模型、数据结构、搜索算法五大维度。

---

## 一、I/O 层（最高优先级）

### 1.1 `PosixFile::pread()` 每次调用分配堆内存

**文件**: `cpp/src/io/posix_file.cpp:70`

```cpp
ReadResult PosixFile::pread(std::uint64_t offset, std::size_t count) noexcept {
    std::vector<std::byte> buf(count);  // <--- 每次读都 malloc
    const ssize_t n = ::pread(fd_, buf.data(), count, ...);
```

**影响**: `get` 热路径（`keydir 查 → pread → CRC 校验 → 返回`）每次都要分配/释放堆内存。小 key 读取（~100B header + key）也会触发 allocator。

**优化建议**: 提供 `pread_into(span<byte> buf)` 重载，让调用方提供缓冲区。在 `DataFile::read` 和 `fold` 中复用 thread-local 或预分配的 buffer。

### 1.2 `DataFile::write()` 每次写入分配临时 vector

**文件**: `cpp/src/fileops/data_file.cpp:73-75`

```cpp
std::vector<std::byte> buf;
buf.reserve(format::kHeaderSize + key.size() + value.size());
const std::size_t total = codec::encode_data_record(buf, type, tstamp, ord, key, value);
auto w = file_.pwrite(off, buf);  // <--- buf 是临时分配
```

**影响**: 每次 `put` 至少 2 次堆分配（data write + hint write），merge 路径更频繁。

**优化建议**: 让 `encode_data_record` 支持直接写入 `pwrite`，或使用栈上的 `std::array<byte, N>` 作为小缓冲区（大部分 record < 4KB）。

### 1.3 `DataFile::fold()` 每条记录两次 `pread` = 两次堆分配

**文件**: `cpp/src/fileops/data_file.cpp:166-192`

```cpp
// 第一次 pread: 只读 14B header 拿 key_sz/value_sz
auto hr = file_.pread(offset, format::kHeaderSize);   // <--- malloc #1
// ... 解析大小 ...
// 第二次 pread: 读整条 record
auto br = file_.pread(offset, rec_total);              // <--- malloc #2
```

**影响**: 扫盘重建 keydir 时（`load_keydir_from_disk`）每条记录 2 次 malloc + 2 次 syscall。

**优化建议**: 使用 `io_uring` 批量提交，或至少将 header + 小 value 的读取合并为一次 pread（判断 `rec_total <= 阈值` 时一次读完）。

### 1.4 `HintFile::write()` 也有临时 vector 分配

**文件**: `cpp/src/fileops/hint_file.cpp:50-51`

```cpp
std::vector<std::byte> buf;
buf.reserve(format::kHintRecordSize + key.size());
```

hint record 固定大小（18B + key），完全可以用栈缓冲区。

### 1.5 `InvertedWAL` 逐字节 `fwrite` + 每次写入 `fflush`

**文件**: `cpp/src/bm25/inverted_wal.cpp:15,89,93,98`

```cpp
bool write_u8(std::FILE* f, std::uint8_t v) {
    return std::fwrite(&v, 1, 1, f) == 1;  // <--- 逐字节写入
}
// ...
for (auto pos : positions) {
    if (!write_u32(file_, pos)) return;  // <--- 每个 position 一次 fwrite
}
// ...
std::fflush(file_);  // <--- 每次 append_add_doc 结尾强制 flush
```

**影响**: WAL 写入 I/O 开销极大——频繁的小写 + 每次强制 fflush。

**优化建议**: 将整个 WAL entry 编码到缓冲区后一次性 `fwrite`，去掉中间的 `fflush`（或只在 `sync` 时 flush）。

---

## 二、内存管理（高优先级）

### 2.1 `Index` 使用 `std::vector<bool>` — 经典性能陷阱

**文件**: `cpp/include/bitcask/index.hpp:123`

```cpp
std::vector<bool> live_;  // 下标 = ord（Roaring 留待优化）
```

`vector<bool>` 是 bit-packed 的，每次 `live_[ord]` 访问需要位操作，比 `vector<char>` 慢 ~3-8x。而且它的内存地址不稳定，`fill_is_live` 里的顺序访问对 cache 不友好。

**优化建议**: 改为 `std::vector<uint8_t>` 或 `std::vector<char>`。注释里已经提到 Roaring bitmap，但即使不做 Roaming，简单的 byte 数组已经好很多。

### 2.2 `Posting::positions` 每条 posting 独立堆分配

**文件**: `cpp/include/bitcask/inverted.hpp:68`

```cpp
struct Posting {
    std::uint64_t ord;
    std::uint32_t tf;
    std::vector<std::uint32_t> positions;  // <--- 每个 posting 独立的堆分配
};
```

对于短文档，大多数 term 只出现 1-3 次，`vector<uint32_t>` 的 overhead（24B 控制块 + 堆分配）远大于实际数据。

**优化建议**: 使用 inline vector / small buffer optimization（如 `std::array<uint32_t, 2>` + overflow 指针），或使用 flat array + offset 的 SoA 布局。

### 2.3 `put` 路径的字符串拷贝

**文件**: `cpp/src/cask/cask.cpp:932-944`

```cpp
submit_index_task(IndexTask{
    IndexOp::Add,
    std::string(bytes_to_view(key)),          // <--- 拷贝 key
    ord,
    std::string(reinterpret_cast<const char*>  // <--- 拷贝 value
               (value.data()), value.size()),
    ...
});
```

每次 `put` 至少 2 次字符串分配用于异步索引任务。

**优化建议**: 使用 `shared_ptr` 或 `string_view + lifetime token` 来共享 buffer，避免拷贝。

### 2.4 `score_bow_topk` 中间 `unordered_map` 累加分数

**文件**: `cpp/src/bm25/inverted.cpp:94`

```cpp
using ScoreMap = std::unordered_map<std::uint64_t, float>;
ScoreMap scores = tbb::parallel_reduce(
    ..., ScoreMap{},
    [&](const auto& range, ScoreMap local) {
        // ... 每个线程维护一个 unordered_map ...
    },
    [](ScoreMap a, const ScoreMap& b) {
        for (auto& [doc, score] : b) { a[doc] += score; }  // <--- reduce 阶段也是 O(n) hash 操作
    });
```

**影响**: 查询热路径上，每次 BM25 搜索分配多个 `unordered_map`，reducer 阶段合并也是 O(n) hash 操作。

**优化建议**: 对于 top-k（k 通常 10-100），可以用 `flat_hash_map` 或直接维护一个分数数组 + 堆，避免 hash map 的 overhead。

### 2.5 `DataFile::read()` 不必要的 key/value 拷贝

**文件**: `cpp/src/fileops/data_file.cpp:144-145`

```cpp
out.key.assign(rec->key.begin(), rec->key.end());    // <--- 拷贝 key
out.value.assign(rec->value.begin(), rec->value.end()); // <--- 拷贝 value
```

而 `decode_data_record` 已经返回 zero-copy `span`。可以让 `ReadRecord` 直接持有 `span` + buffer ownership。

### 2.6 `fstats_` 使用 `unordered_map<uint32_t, FStatsEntry>`

**文件**: `cpp/include/bitcask/keydir.hpp:328`

文件 ID 通常是连续的小整数，`flat_vector` 或直接 `vector<FStatsEntry>` 按 file_id 下标访问会更快。

---

## 三、并发与锁（中高优先级）

### 3.1 `KeyDir` 单一 `shared_mutex` 全局竞争

**文件**: `cpp/src/keydir/keydir.cpp`

所有操作（get/put/remove/alloc_ord/update_fstats）走同一把 `shared_mutex`。注释里已经提到 sharding 是 M6 候选。

```cpp
// 读路径
std::shared_lock lock(mutex_);   // get (line 194)
// 写路径
std::unique_lock lock(mutex_);   // put (line 252), remove (line 433)
// 甚至连递增计数器都独占
std::unique_lock lock(mutex_);   // alloc_ord (line 220)
```

**优化建议**:
- **短期**: `alloc_ord` / `advance_ord` 改为 `std::atomic<uint64_t>`，去掉锁。
- **中期**: per-shard `shared_mutex`（按 key hash 分片），类似 InvertedIndex 的 64-shard 模型。

### 3.2 `SearchCache` 使用 `std::mutex` 而非 `shared_mutex`

**文件**: `cpp/src/search/search_cache.cpp:21,37`

```cpp
std::lock_guard<std::mutex> lock(mutex_);  // get 也独占！
```

读缓存是查询热路径，使用 `shared_mutex` 允许多读者并发。

**优化建议**: 改为 `std::shared_mutex`，`get()` 用 `shared_lock`，`put()/invalidate()` 用 `unique_lock`。

### 3.3 `Cask::read_file()` 每次都锁 `read_cache_mu_`

**文件**: `cpp/src/cask/cask.cpp:780-798`

```cpp
fileops::DataFile* Cask::read_file(std::uint32_t file_id) {
    std::scoped_lock lk(read_cache_mu_);  // <--- 每次读都独占锁
    auto it = read_files_.find(file_id);
    ...
}
```

**优化建议**: 使用 `std::shared_mutex` + `shared_lock` 读缓存，`unique_lock` 仅在 lazy open 时。或使用 `folly::AtomicHashMap` / `tsl::hopscotch_map` 等并发友好容器。

---

## 四、数据结构与算法（中优先级）

### 4.1 `keydir::entries_` 使用 `std::unordered_map` — hash 碰撞 + cache 不友好

**文件**: `cpp/include/bitcask/keydir.hpp:317`

```cpp
std::unordered_map<std::string, Entry, StringHash, std::equal_to<>> entries_;
```

`std::unordered_map` 是链表哈希，cache 不友好。每次 `get` 需要跟随指针链。

**优化建议**: 替换为 `absl::flat_hash_map`、`tsl::hopscotch_map` 或 `robin_map`——都是 open addressing 实现，cache 命中率显著提升。

### 4.2 WAND 算法每轮重排序

**文件**: `cpp/src/bm25/inverted.cpp:484`

```cpp
while (true) {
    std::sort(order.begin(), order.end(), ...);  // <--- 每轮迭代都全量排序
    ...
}
```

**优化建议**: cursor 推进后只需增量调整顺序（类似于 insertion sort），而非每轮 `O(n log n)` 全排。或用 `std::priority_queue` 维护有序性。

### 4.3 `search_fields` 对每个 term 做独立搜索

**文件**: `cpp/src/search/search_layer.cpp:417-423`

```cpp
for (auto& [t, boost] : term_boosts) {
    for (auto& et : expanded) {
        auto res = inv->search({et}, k, index_, ...);  // <--- 每个 term 独立搜
    }
}
```

每个 term 调用一次 `search()`，而 `search` 内部每次都做 snapshot + BM25 评分 + top-k 堆。

**优化建议**: 批量化——对同一 field 的所有 terms 做一次 multi-term BM25 评分，避免重复的 snapshot/IDF 计算。

---

## 五、杂项优化（低优先级但值得做）

### 5.1 `now_sec_default()` 在每次 `get/put` 调用

**文件**: `cpp/src/cask/cask.cpp:27-31`

```cpp
std::uint32_t now_sec_default() {
    return static_cast<std::uint32_t>(
        std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch()).count());
}
```

`system_clock::now()` 涉及 syscall。可以缓存为每秒更新的 atomic。

### 5.2 `InvertedIndex::df()` 查询热路径上的字符串拷贝

**文件**: `cpp/src/bm25/inverted.cpp:1112,1119`

```cpp
if (!shard.inverted.find(acc, std::string(term))) return 0;  // <--- copy on every find
```

`df` 和 `df_live` 每次调用都将 `string_view` 转成 `string` 来查找。

**优化建议**: tbb `concurrent_hash_map` 的 `find` 接受 `string_view` 需要 transparent hasher，确认是否已启用或改用兼容接口。

---

## 六、总结：优先级排序

| # | 优化项 | 类别 | 预期收益 | 改动复杂度 |
|---|--------|------|----------|-----------|
| 1 | `pread` 缓冲区复用 | I/O | ⭐⭐⭐⭐⭐ | 中 |
| 2 | `alloc_ord` 改 atomic | 并发 | ⭐⭐⭐⭐ | 低 |
| 3 | `vector<bool>` → `vector<char>` | 内存 | ⭐⭐⭐⭐ | 低 |
| 4 | `unordered_map` → `flat_hash_map` | 数据结构 | ⭐⭐⭐⭐ | 中 |
| 5 | KeyDir 分片锁 | 并发 | ⭐⭐⭐⭐ | 高 |
| 6 | `DataFile::write` 栈缓冲区 | I/O | ⭐⭐⭐ | 低 |
| 7 | `SearchCache` → `shared_mutex` | 并发 | ⭐⭐⭐ | 低 |
| 8 | `read_file` → `shared_lock` | 并发 | ⭐⭐⭐ | 低 |
| 9 | WAL 批量写入 | I/O | ⭐⭐⭐ | 低 |
| 10 | `score_bow_topk` 减少 hash map | 算法 | ⭐⭐⭐ | 中 |
| 11 | Posting positions inline storage | 内存 | ⭐⭐⭐ | 中 |
| 12 | `search_fields` 批量 BM25 | 算法 | ⭐⭐⭐ | 中 |
| 13 | WAND 增量排序 | 算法 | ⭐⭐ | 中 |
| 14 | `now_sec_default` 缓存 | 杂项 | ⭐⭐ | 低 |
| 15 | `fold` 单次 pread 合并 | I/O | ⭐⭐ | 中 |

**推荐的实施顺序**: 先做 #2、#3（改动小、收益确定），然后做 #1（收益最大但改动面广），再推进 #4 和 #5（架构性改进）。
