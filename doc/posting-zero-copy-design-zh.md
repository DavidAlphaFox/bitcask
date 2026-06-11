# 查询路径 PostingList 零拷贝设计（P1）

> 状态：Phase 1（方案 D）已实施——基准 -60~72%；Phase 2-min（phrase/near
> 持 shared_ptr + use_count CoW 协议）已实施——phrase -25~32%，详见 TASK.md
> P1 节。完整 Phase 2（published_count 前缀只读 + deque）按 §6 判据暂不启动。
>
> 实施备注（Phase 2-min 与 §4.2 的差异）：未做 deque/published_count，
> 而是用「写者持写 accessor 时 use_count()==1 → 原地改，>1 → 克隆替换」
> 的 CoW 协议保证读者持引用期间对象不被修改（裸 shared_ptr + 原地追加
> 是不安全的——vector 扩容搬迁会让读者悬空）。代价：仅当 phrase 查询与
> 同 term 写入重叠时发生整列表克隆，常态写零开销。另：实施中发现并修复
> 「遍历 concurrent_hash_map 期间调 find 触发懒 rehash 致迭代器重复访问
> 节点」的坑（wildcard/fuzzy 改两阶段收集，详见 TASK.md P2.3）。

## 1. 问题

`inverted.cpp` 的 6 个查询路径（search / search_wand / search_phrase_impl /
bool_search / search_fuzzy / search_wildcard）都通过

```cpp
tbb::concurrent_hash_map<...>::const_accessor acc;
shard.inverted.find(acc, term);
tp.pl_copy = acc->second;          // ← 整个 PostingList 深拷贝
```

把命中的 PostingList **整体深拷贝**后再释放 accessor。拷贝内容包括：

- `items`：每条 `Posting{ord(8B), tf(4B), positions(vector, 24B 头 + 独立堆块)}`
  —— **每条 posting 一次堆分配**；
- `compressed_ords` / `blocks` / `max_tf`（派生态，量小）。

热词 10 万 posting ≈ 4MB 拷贝 + 10 万次小分配，**每次查询、每个命中词**都付一遍。
这是当前查询路径上最大的单项开销，超过 O 系列已优化项的总和。

拷贝存在的原因（必须在新设计中继续满足）：

1. 尽早释放 concurrent_hash_map 的桶锁——评分（含 TBB parallel_reduce）耗时
   毫秒级，持 accessor 全程会饿死写线程、且跨任务持多个 accessor 有死锁风险；
2. 写线程（add_doc）可能在查询进行中追加同一 term 的 posting / 触发
   `note_appended()` 重整派生态——读者需要一份不被突变的视图。

## 2. 并发模型（设计输入）

| 角色 | 线程 | 对 PostingList 的操作 |
|---|---|---|
| 索引写者 | IndexPool 单 worker 线程（`thread_pool.hpp`，concurrency=1） | **追加型**：`items.push_back` + `note_appended()`（封满块、弹部分尾块、失效 compressed、更新 max_tf） |
| 搜索读者 | NIF dirty 线程，多个并发 | 只读（当前靠深拷贝隔离） |
| 维护 | merge / open 路径 | **替换型**：`compact()` 原地重写、`load()` 整表重建、`rebuild_index()` 换整个 InvertedIndex、`finalize_all_postings()` 重算派生态 |

关键不变量：
- ord 全局单调分配 → add_doc 的追加**必然落在 items 尾部**，已发布前缀的
  (ord, tf) 永不改写；positions 一旦入列也不再改。
- `SearchLayer` 单写者由 IndexPool 保证（concurrency-zh.md §6）；
  rebuild/load 与并发搜索的互斥由上层 merge 路径保证（本设计不放宽该前提，
  但替换机制刻意做成与之兼容的指针发布）。
- 例外突变：`note_appended()` 在「finalize 过的列表上首次追加」时会
  **弹掉部分尾块**（blocks.pop_back）——这是唯一会回退已发布派生态的操作，
  Phase 2 需要单独处理（见 §4.2）。

## 3. 方案对比

### 方案 A：`shared_ptr<const PostingList>` + 写时全量克隆（经典 COW）

读者 accessor 下拷 shared_ptr（O(1)）即走；任何突变都克隆整个列表再换指针。

- ✅ 读零拷贝；compact/load/finalize 本来就是整体替换，天然适配。
- ❌ **add_doc 每追加一条 posting 克隆全列表**：热词追加是常态负载，
  写放大 O(N)/条，写吞吐不可接受。
- 结论：仅保留其「替换型突变走指针发布」的机制（Phase 2 采用），
  不能用于追加路径。

### 方案 B：不可变分段 + mutable tail（Lucene segment 式）

posting 切成 immutable sealed segments，追加只进 tail；读者拷段指针数组。

- ✅ 读零拷贝、写 O(1) 摊还，理论终态。
- ❌ `find()` 二分、`compact`、`save/load`、WAND blocks 全部按段重写，
  磁盘格式与查询遍历逻辑同时动，一步到位风险过高。
- 结论：作为远期形态参考，不直接实施。

### 方案 C：读者持 accessor 全程（去拷贝、不去锁）

- ❌ 热词查询持桶锁毫秒级，单写线程在该桶饿死；parallel_reduce 内跨任务
  持多个 accessor，TBB 文档明确警告死锁。否决。

### 方案 D：扁平快照（消除逐 posting 堆分配，拷贝降到 12B/posting）

观察：6 条路径里 **5 条只需要 (ord, tf)**（search/wand/bool/fuzzy/wildcard），
只有 phrase/near 需要 positions。

accessor 下把 items 压成两个扁平数组：

```cpp
struct FlatPostings {
    std::vector<std::uint64_t> ords;   // 1 次分配
    std::vector<std::uint32_t> tfs;    // 1 次分配
    std::vector<PostingBlock>  blocks; // 量小（N/128）
    std::uint32_t              max_tf;
};
void PostingList::snapshot_flat(FlatPostings& out) const;  // 顺序紧循环
```

- ✅ 分配次数 N+1 → 2；拷贝量 ~40B+positions堆块 → 12B/posting；
  评分循环改读连续数组，cache 友好（wand 的 `tp.ords` 游标天然适配）。
- ✅ **不改并发模型、不改磁盘格式、不动写路径**——风险最低、可独立回归。
- ❌ 仍是 O(N) 带宽拷贝，不是零拷贝；phrase/near 维持现状（深拷，低频）。

## 4. 推荐：两阶段

### Phase 1 = 方案 D（先做，预计收益占八成）

改动面：
1. `inverted.hpp` 加 `FlatPostings` + `PostingList::snapshot_flat()`；
2. 5 条非 positions 路径的 `TermPostings{term, pl_copy, ords}` →
   `TermPostings{term, FlatPostings fp}`，评分循环 `items[i].tf` → `fp.tfs[i]`；
3. phrase/near 与 explain 不动（explain 本就持 accessor 短读、无拷贝）。

验收：ctest 全量 + 新增「查询中并发 add_doc 同 term」TSan 用例；
基准（见 §6）给出 before/after。

### Phase 2 = 指针发布 + 已发布前缀只读（按基准证据决定是否做）

目标：读路径完全零拷贝（含 phrase 的 positions）。

1. map 值改 `std::shared_ptr<PostingList>`（非 const——尾部追加仍原地）；
   读者 accessor 下拷 shared_ptr 即释放桶锁。
2. `PostingList` 加 `std::atomic<std::uint32_t> published_count`：
   - 写者 `items.push_back(...)` **完成后** release-store count+1；
   - 读者 acquire-load 后只读 `[0, published_count)` 前缀。
   单写者 + release/acquire → 前缀内容的写入 happens-before 读者可见，无锁安全。
3. `items` 由 `vector` 改 `std::deque`（或自实现 chunked array）：
   追加不搬移已发布元素——这是前缀只读成立的前提
   （vector 扩容会整体搬迁，读者悬空）。
4. `blocks` 同理加 `published_blocks` 原子；**finalized 列表上的首次追加**
   （唯一的弹尾突变）改走「克隆 → 修改 → 换指针」的替换路径，规避对已
   发布 blocks 的回退（频率低：仅 load 后每词一次）。
5. `max_tf` → `atomic<uint32_t>` relaxed。
6. `compact()` / `load()` / `finalize_all_postings()` 统一改为
   「构造新 PostingList → accessor 下换 shared_ptr」；旧版本由在读快照的
   shared_ptr 引用计数自然续命，读完释放。
7. phrase/near 改为：拿 shared_ptr 后直接在 `[0, published_count)` 上
   `find()` + 读 positions，零拷贝。

Phase 2 的代价：`deque` 的二分/遍历比 vector 略慢（间接寻址）、
save/load/compact 全要过一遍、内存序推理需要 TSan 背书。
**仅当 Phase 1 后基准显示拷贝带宽仍是瓶颈时启动。**

## 5. 明确不做 / 边界

- 不动 `rebuild_index()` 换整个 InvertedIndex 的上层互斥假设（fields_ 的
  发布是另一个独立问题，见审计报告 §健壮性）；
- 不动磁盘格式（Phase 2 的 deque 仅内存形态，save 仍按序写）；
- `compressed_ords` 的内存冗余（审计 #2）与本设计正交：Phase 2 落地后
  顺手把内存中的 `compressed_ords` 砍掉（save 时现编码）收益更顺。

## 6. 基准先行（依赖审计 #7）

实施前先落地两个固定基准，Phase 1/2 各拿数字：

1. `search_hot_term`：100k posting 热词，单线程 QPS + p99；
2. `search_while_indexing`：4 dirty 线程查询 × IndexPool 持续 add_doc 同
   一批热词，查询 p99 + 索引吞吐双指标。

判定标准：Phase 1 预期 search_hot_term 延迟降 50%+（分配主导时更多）；
若 Phase 1 后 profile 显示 snapshot_flat 的 memcpy 仍占查询时间 >30%，
启动 Phase 2。
