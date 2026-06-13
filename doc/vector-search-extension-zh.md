# 向量搜索扩展设计：HNSW + RRF 混合检索

本文档描述在当前 C++ Bitcask 引擎之上扩展**向量检索（ANN）**与**混合检索（BM25 + ANN）**的落地设计。

配合以下文档阅读：
- `doc/vector-db-design-zh.md` —— 总体 V1–V6 里程碑与单域引擎蓝图
- `doc/hnsw-design-zh.md` —— HNSW 向量索引设计（并发/持久化/RRF/实施表）
- `doc/cpp-arch.md` —— C++ 模块布局与构建入口
- `doc/format-zh.md` —— 磁盘格式

---

## 0. 定位与边界

| 项 | 决策 | 理由 |
|---|---|---|
| **目标规模** | ≤1M 向量（每 cask） | 内存 HNSW 单图在该量级下最简单、最准 |
| **稠密索引** | HNSW，**单图常驻内存** | 召回最好，merge 时整体重建 |
| **混合策略** | **RRF**（Reciprocal Rank Fusion）默认 | 零调参，对 BM25 分数与向量距离的分布不敏感 |
| **实现** | **自研** HNSW（`hnsw.hpp` / `hnsw.cpp`） | per-node spin lock 并发读、AVX2/AVX-512 距离内核、int8 量化 + VNNI 粗筛 |
| **距离度量** | cosine / L2 / dot 可配 | 内积用于已归一化向量；cosine 默认 |
| **元数据过滤** | V1 **查询后过滤**起步 | 100% 召回正确；后续再加 filter-while-search |
| **量化** | V1 **不引入**（f32） | 百万级内存可承受；接口预留 `vec_quantized` 位 |
| **多 collection** | 独立实例 | 避免 dim 不同互相干扰；配置文件指定 |

**不在本文档范围**：V1 完整单域改造（ord/type 字段）、HNSW 副本重建、跨 collection 查询——这些已在 `vector-db-design-zh.md` 中规划。

---

## 1. 现状盘点

| 层 | 状态 | 文件 / 位置 |
|---|---|---|
| **磁盘格式** | ✅ | `format.hpp` / `codec.hpp` 中 DocValue 已有 `optional<span<const float>> vector`，`kFlagHasVector` 标志位已定义 |
| **编解码** | ✅ | `encode_doc_value` / `decode_doc_value` 已支持 `[dim:varint][f32×dim]` 的读写（DocValue v3） |
| **存储** | ✅ | 向量作为 DocValue 的一部分已落盘 |
| **BM25 倒排** | ✅ | `InvertedIndex` + `SearchLayer::search_text/fields/phrase` 已可用 |
| **HNSW 索引** | ✅ | `hnsw.hpp` / `hnsw.cpp`（V3.3–V3.9），per-node 锁 + AVX2/AVX-512 距离内核 |
| **距离度量** | ✅ | cosine / L2 / dot（`hnsw_kernels.hpp`，运行时 SIMD 分发） |
| **search_vector API** | ✅ | `cask_search_vector/4,5` NIF + `bitcask:search_vector/2-5` Erlang |
| **search_hybrid + RRF** | ✅ | `SearchLayer::search_hybrid`（RRF `Σ 1/(60+rank)`） |

**全部已实现。** 向量存储、HNSW 索引、距离度量、混合检索均已落地。

---

## 2. 总体架构

```
                        SearchLayer（新增向量路径）
                       ┌──────────────────────────────────────┐
                       │  fields_           （每字段 BM25）      │
 on_write() ───────────┤    "\x01default" → InvertedIndex      │
    │                  │    "title"       → InvertedIndex      │
    │                  │    "body"        → InvertedIndex      │
    │                  │                                      │
    │                  │  vector_fields_  （每字段 HNSW，平行）  │
    │                  │    "$vector"     → VectorIndex        │
    │                  │    "title_vec"   → VectorIndex        │
    │                  │                                      │
    │                  │  index_          （ord↔ext 映射）       │
    │                  │  synonym_map_                         │
    │                  │  cache_                                │
    │                  └──────────────────────────────────────┘
    │
 search_text(q)   ─────►  analyze → InvertedIndex.search → top-k BM25 hits
 search_vector(v) ─────►  HNSWIndex.search       → top-k vector hits
 search_hybrid(q,v) ───►  两路并行 → RRF 融合       → top-k hybrid hits
```

**关键设计原则：**
- 向量索引挂在 `SearchLayer` 之下，与 BM25 的 `fields_` **平行**——`fields_` 管稀疏、`vector_fields_` 管稠密。
- 两者**共享** `Index`（`ord ↔ ext_id` 映射 + `is_live()`）作为「谁是活的」的唯一权威。
- 同一文档**可同时拥有文本字段与向量字段**：DocValue 中 vector 段对应 `$vector` 字段（可重命名），其他文本段对应命名字段。

---

## 3. 数据模型扩展

### 3.1 已有：DocValue 打包布局（不变）

`kDoc` value 当前格式（已实现）：

```
kDoc value:
┌──────┬───────┬──────────────┬──────────────┬──────────────┐
│ ver  │ flags │  vector 段    │   text 段     │   meta 段     │
│ u8   │ u8    │  (可选)       │  (可选)       │  (可选)       │
└──────┴───────┴──────────────┴──────────────┴──────────────┘

flags 位:  bit0=has_vector  bit1=has_text  bit2=has_meta  bit3=vec_quantized

vector 段 (has_vector):  [dim:varint][ f32×dim  或  量化码字 ]
```

无需修改：`vector` 段已存在并已编解码。本设计只新增「使用方式」（检索路径）。

### 3.2 完整 record 结构图（含向量的 kDoc）

一条带文本+向量的 `kDoc` record 在磁盘上的完整字节布局：

```
┌──────────────────────────────────────────────────────────────────────┐
│                    data file record（typed, V1）                       │
├──────────┬───────┬──────────┬──────────┬─────────┬──────────────────┤
│ CRC32    │ Type  │ Tstamp   │ Ord      │ KeySz   │ ValueSz          │
│ u32 大端  │ u8    │ u32 大端  │ u64 大端  │ u16 大端 │ u32 大端          │
│ [0..3]   │ [4]   │ [5..8]   │ [9..16]  │ [17..18]│ [19..22]         │
├──────────┴───────┴──────────┴──────────┴─────────┴──────────────────┤
│ Key (= ext_id，KeySz 字节)                                           │
├──────────────────────────────────────────────────────────────────────┤
│ Value（ValueSz 字节）= DocValue 打包                                  │
│  ┌──────┬───────┬───────────────────┬─────────────┬────────────────┐ │
│  │ Ver  │ Flags │ vector 段(可选)    │ text段(可选) │ meta段(可选)   │ │
│  │ u8   │ u8    │ [dim:varint][f32×dim] │ [len][utf8] │ [len][bytes]   │ │
│  │ [0]  │ [1]   │ [2..]             │             │                │ │
│  └──────┴───────┴───────────────────┴─────────────┴────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘

header = 23 字节（固定）
总长   = 23 + KeySz + ValueSz
```

#### 具体例子

写入 `key="doc1"`, `text="hello world"`, `vector=768维 f32`:

> ⚠️ 下面这个字节例子用的是**早期固定宽度布局**（dim/len 各 4 字节大端），便于
> 直观对照偏移。**当前 DocValue v3 中 dim/len 已改 VByte varint**（768→2 字节
> `0x80 0x06`、11→1 字节），实际偏移会相应缩短，权威定义见 `format-zh.md` §五。

```
Flags = 0x03 (has_vector | has_text)

Value 内容（早期固定宽度示意）:
  [0]       Ver       = 0x03
  [1]       Flags     = 0x03
  [2..5]    dim       = 768           (v3 为 varint)
  [6..3113]           = f32[768]     (3072 字节，小端)
  [3114..3117] len    = 11            (v3 为 varint)
  [3118..3128]        = "hello world"
```

#### 各段 offset 定位（O(1)）

| 操作 | 定位方式 |
|---|---|
| **读向量** | `Ver(1) + Flags(1) + dim(4)` → 向量从 offset 6 开始，长度 `dim×4` |
| **读文本** | 跳过向量段：`6 + dim×4` → 读 `len(4)` → 文本从 `10 + dim×4` 开始 |
| **读 meta** | 跳过向量+文本：`10 + dim×4 + 4 + text_len` → 读 `len(4)` → meta |
| **纯文本无向量** | `Ver(1) + Flags(1)` → 直接读 `len(4)` + text，无 dim 开销 |

> 向量段放最前是关键设计：HNSW 重建只需读前 6 字节（Ver+Flags+dim）即可 memcpy 出全部向量，不碰 text/meta。BM25 重建按 dim 算出向量段长度跳过，直达 text。两条偏路径都 O(1) 定位。

字节级权威定义见 `doc/format-zh.md` §五（DocValue 格式）。常量定义见 `cpp/include/bitcask/format.hpp`。

### 3.3 向量字段命名约定

| 字段名 | 类型 | 说明 |
|---|---|---|
| `"$vector"` | 向量 | 默认单向量字段（与"主键 + 文本"配对的最常见用法） |
| `"title_vec"`、`"body_vec"` | 向量 | 多向量字段（同一文档存多模态 embedding） |
| `"title"`、`"body"` | 文本 | 已有命名约定，**不**与向量字段冲突 |
| `"\x01default"` | 文本 | 内部默认文本字段（既有） |

> **`$` 前缀**约定：所有以 `$` 开头的字段名保留给系统（向量、复合字段等），用户字段名禁止使用。这与既有 `\x01default` 的「不可打印前缀作内部命名空间」一脉相承。

### 3.4 DocSlot 扩展（最小）

```cpp
struct DocSlot {
    u32 file_id;
    u64 offset;
    u32 total_sz;
    u32 tstamp;
    u32 doc_len;             // BM25 token 数
    // ─── 新增 ───
    std::optional<u32> dim;  // 该文档向量维度（用于多 dim 共存）
};
```

> 多 dim 场景：每个 `vector_field` 在打开时绑定一个 `dim`，插入时若 `dim` 不匹配则**报错**（V1 不支持异构 dim 混插）。`DocSlot.dim` 仅用于校验与统计。

---

## 4. VectorIndex 类设计

### 4.1 接口

```cpp
// cpp/include/bitcask/vector_index.hpp
namespace bitcask::vector {

enum class Metric { Cosine, L2, InnerProduct };

struct VectorSearchResult {
    std::uint64_t ord;
    float distance;  // 越小越近（cosine 距离 = 1 - sim）
};

class VectorIndex {
public:
    explicit VectorIndex(std::size_t dim, Metric metric = Metric::Cosine);
    ~VectorIndex();

    VectorIndex(const VectorIndex&) = delete;
    VectorIndex& operator=(const VectorIndex&) = delete;
    VectorIndex(VectorIndex&&) noexcept;
    VectorIndex& operator=(VectorIndex&&) noexcept;

    // ─── 写入 ───
    // 插入新节点；ord 必须单调（外部 Index 负责保证）。
    void add_vector(std::uint64_t ord, std::span<const float> vec);

    // 软删：节点保留作路由中转，结果过滤时跳过。
    void mark_deleted(std::uint64_t ord);

    // ─── 查询 ───
    // ef 控制候选集大小（ef ≥ k）；M / ef_construction 在构造时定。
    std::vector<VectorSearchResult>
    search(std::span<const float> query,
           std::size_t k,
           std::size_t ef,
           const bm25::LiveChecker& live) const;

    // ─── 持久化 ───
    // 序列化当前图到指定路径（含向量副本 + 图拓扑 + 元数据）。
    bool save(std::string_view path) const;
    // 从路径反序列化（覆盖当前图）。
    bool load(std::string_view path);

    // ─── 统计 ───
    std::size_t live_count() const noexcept;
    std::size_t total_count() const noexcept;  // 含软删
    std::size_t dim() const noexcept { return dim_; }

private:
    // 持有一个 usearch::index_t 实例（pimpl 模式隐藏头）
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::size_t dim_;
    Metric metric_;
};

}  // namespace bitcask::vector
```

### 4.2 pimpl 隐藏 usearch

usearch 头较重，污染公共头。所有 usearch 类型放在 `cpp/src/vector/vector_index.cpp` 的 `Impl` 中；`vector_index.hpp` 只暴露 `std::span<const float>` / `std::vector<VectorSearchResult>` 这类标准类型。

### 4.3 选型理由：为什么 usearch

| 库 | Header-only | 依赖 | 持久化 | 性能 | 推荐度 |
|---|---|---|---|---|---|
| **usearch** | ✅ | 无（C++17+） | ✅ mmap / save/load | 比 FAISS 快 10x | ⭐⭐⭐ **首选** |
| hnswlib | ✅ | 无 | ❌ 需自己序列化 | 基准线 | ⭐⭐ |
| FAISS | ❌ | BLAS / CUDA | 部分 | 大规模最强 | ⭐（过重） |
| qlut | ❌ | 复杂 | 部分 | 高 QPS | ⭐（依赖重） |

usearch 的关键优势：
- **单头文件** `include/ust.hpp`，拖进 `third_party/usearch/` 即可，零编译依赖。
- **磁盘视图**模式（`view()`）可在不占内存的代价下做大库的「懒加载」，未来超百万时无需换库。
- 支持 `f16` / `i8` 量化（V1 用不到，接口预留）。
- Apache 2.0 许可。

### 4.4 第三方集成方式

```cmake
# cmake/third_party_usearch.cmake
add_library(usearch INTERFACE)
target_include_directories(usearch INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/usearch/include
)
target_compile_features(usearch INTERFACE cxx_std_23)
```

vendored 仓库：`https://github.com/unum-cloud/usearch`（仅取 `include/` 目录，10.x 单头版本）。

---

## 5. SearchLayer 扩展

### 5.1 新增成员

```cpp
class SearchLayer {
    // 已有
    std::unordered_map<std::string, std::unique_ptr<bm25::InvertedIndex>> fields_;
    std::unique_ptr<bm25::InvertedIndex> default_field_;
    // ……

    // ─── 新增 ───
    std::unordered_map<std::string, std::unique_ptr<vector::VectorIndex>> vector_fields_;
    std::unique_ptr<vector::VectorIndex> default_vector_;  // 字段名 "$vector"
};
```

### 5.2 新增方法

```cpp
// ─── 写入路径扩展 ───
// 在现有 on_write_fields() 末尾追加（如果 doc 含 vector）：
void SearchLayer::on_write_vector(std::uint64_t ord, std::string_view field,
                                  std::span<const float> vec);

// 在 on_delete_fields() 对应位置追加：
void SearchLayer::on_delete_vector(std::uint64_t ord);

// ─── 查询 ───
std::expected<std::vector<SearchHit>, Error>
SearchLayer::search_vector(std::span<const float> query,
                           std::size_t k,
                           std::string_view field = "$vector",
                           std::size_t ef = 0) const;  // ef=0 → 默认 4*k

std::expected<std::vector<SearchHit>, Error>
SearchLayer::search_hybrid(std::string_view text_query,
                           std::span<const float> vec_query,
                           std::size_t k,
                           std::string_view text_field = "\x01default",
                           std::string_view vec_field = "$vector") const;
```

### 5.3 写入路径集成点

```cpp
// search_layer.cpp
void SearchLayer::on_write_fields(ord_t ord, const DocValue& dv) {
    // 已有：文本字段
    for (auto& [field, text] : dv.text_fields()) {
        field_index(field).add_doc(ord, analyze(text));
    }

    // ─── 新增：向量字段 ───
    if (auto vec = dv.vector()) {
        vector_field_index("$vector").add_vector(ord, *vec);
    }
    // 未来多向量：dv.vector_fields() 遍历
}
```

`vector_field_index(name)` 是与现有 `field_index(name)` 同款的懒创建工厂：

```cpp
vector::VectorIndex& SearchLayer::vector_field_index(std::string_view name) {
    if (name == "$vector" || name.empty()) {
        if (!default_vector_) {
            default_vector_ = std::make_unique<vector::VectorIndex>(dim_, metric_);
            // 重建时从快照恢复
            if (auto path = vector_snapshot_path("$vector"); fs::exists(path))
                default_vector_->load(path);
        }
        return *default_vector_;
    }
    auto [it, inserted] = vector_fields_.try_emplace(
        std::string{name}, nullptr);
    if (inserted) {
        it->second = std::make_unique<vector::VectorIndex>(dim_, metric_);
    }
    return *it->second;
}
```

### 5.4 删除路径

```cpp
void SearchLayer::on_delete_fields(ord_t ord) {
    // 已有：BM25 软删
    for (auto& [_, idx] : fields_) idx->remove_doc(ord);
    default_field_->remove_doc(ord);

    // ─── 新增：向量软删 ───
    for (auto& [_, vidx] : vector_fields_) vidx->mark_deleted(ord);
    if (default_vector_) default_vector_->mark_deleted(ord);
}
```

### 5.5 重建恢复

`replay_wal()` 末尾追加：

```cpp
for (auto& op : wal) {
    if (op.type == WalOp::Add) {
        auto dv = codec::decode_doc_value(record.value());
        if (dv.vector()) {
            vector_field_index("$vector").add_vector(op.ord, *dv.vector());
        }
    } else if (op.type == WalOp::Delete) {
        if (default_vector_) default_vector_->mark_deleted(op.ord);
    }
}
```

---

## 6. 查询路径

### 6.1 search_vector

```cpp
std::expected<std::vector<SearchHit>, Error>
SearchLayer::search_vector(std::span<const float> query, std::size_t k,
                           std::string_view field, std::size_t ef) const {
    if (k == 0) return std::vector<SearchHit>{};
    if (ef == 0) ef = std::max<size_t>(k * 4, 64);

    const auto& vidx = const_cast<SearchLayer*>(this)->vector_field_index(field);

    // 1. HNSW 出候选（含 markDeleted 的 ord——usearch 自身不过滤）
    auto raw = vidx.search(query, k, ef, index_);

    // 2. LiveChecker 过滤死点（与 BM25 路径共用 index_）
    std::vector<SearchHit> hits;
    hits.reserve(raw.size());
    for (auto& r : raw) {
        if (!index_.is_live(r.ord)) continue;
        auto ext = index_.ord_to_ext(r.ord);
        if (!ext) continue;
        hits.push_back(SearchHit{
            .key = std::move(*ext),
            .ord = r.ord,
            .score = -r.distance  // 距离 → 分数（越大越相关）
        });
        if (hits.size() >= k) break;
    }
    return hits;
}
```

### 6.2 search_hybrid + RRF 融合

```cpp
std::expected<std::vector<SearchHit>, Error>
SearchLayer::search_hybrid(std::string_view text_query,
                            std::span<const float> vec_query,
                            std::size_t k,
                            std::string_view text_field,
                            std::string_view vec_field) const {
    if (k == 0) return std::vector<SearchHit>{};

    // 1. 两路并行（候选数 ×3 以给 RRF 足够排位空间）
    const size_t candidate_k = std::max<size_t>(k * 3, 32);
    auto bm25 = search_text_into_vec(text_query, candidate_k, text_field);  // 重载：返回原始 ord+score
    auto vec  = search_vector_raw(vec_query, candidate_k, vec_field);

    // 2. RRF 融合 (Cormack et al., 2009, k=60)
    constexpr float rrf_k = 60.0f;
    std::unordered_map<ord_t, float> rrf_scores;
    std::unordered_map<ord_t, SearchHit> hit_map;

    for (size_t rank = 0; rank < bm25.size(); ++rank) {
        auto ord = bm25[rank].ord;
        if (!index_.is_live(ord)) continue;
        rrf_scores[ord] += 1.0f / (rrf_k + rank + 1);
        hit_map.try_emplace(ord, SearchHit{ord, bm25[rank].key, 0.0f});
    }
    for (size_t rank = 0; rank < vec.size(); ++rank) {
        auto ord = vec[rank].ord;
        if (!index_.is_live(ord)) continue;
        rrf_scores[ord] += 1.0f / (rrf_k + rank + 1);
        hit_map.try_emplace(ord, SearchHit{ord, vec[rank].key, 0.0f});
    }

    // 3. 部分排序取 top-k
    using ScoredOrd = std::pair<ord_t, float>;
    std::vector<ScoredOrd> ranked(rrf_scores.begin(), rrf_scores.end());
    size_t top = std::min(k, ranked.size());
    std::partial_sort(ranked.begin(), ranked.begin() + top, ranked.end(),
                      [](const ScoredOrd& a, const ScoredOrd& b) {
                          return a.second > b.second;
                      });

    // 4. 翻译 + 组装
    std::vector<SearchHit> hits;
    hits.reserve(top);
    for (size_t i = 0; i < top; ++i) {
        auto it = hit_map.find(ranked[i].first);
        if (it == hit_map.end()) continue;
        SearchHit h = it->second;
        h.score = ranked[i].second;
        hits.push_back(std::move(h));
    }
    return hits;
}
```

### 6.3 为何选 RRF 而非线性加权和

| 策略 | 优势 | 劣势 |
|---|---|---|
| **RRF**（默认） | 零调参、不需要分数归一化、对 BM25 与余弦距离分布差异鲁棒 | 无理论最优性保证 |
| 线性加权 `α·BM25 + (1-α)·cosine` | 可解释 | 需归一化到同一尺度；α 敏感 |
| Condorcet / Borda 融合 | 投票论基础 | 计算贵；对召回长尾不友好 |
| 倒数归一化 + 加权 | 平衡两者 | 实现复杂 |

经验上 RRF 在 Elasticsearch / Vespa / Weaviate 的生产环境中表现稳健，作为默认；Erlang 层留 `{fusion, linear}` 旋钮供高级用户切换。

### 6.4 ef 参数语义

| 参数 | 默认 | 说明 |
|---|---|---|
| `k` | 用户指定 | 返回前 k 个 |
| `ef` | `4k`（最低 64） | HNSW 候选集大小。越大越准、越慢；`ef = k` 退化为朴素图遍历 |

---

## 7. 持久化与恢复

### 7.1 三类产物

| 产物 | 路径 | 内容 | 作用 |
|---|---|---|---|
| **数据**（已存在） | `*.bitcask.data` | `kDoc`（含 vector 段）/ `kTombstone` | 唯一真相 |
| **向量索引快照**（新增） | `vectors/$vector.usearch` | usearch 序列化（向量数组 + HNSW 拓扑 + 入口 + 参数） | 加速恢复；查询不依赖 |
| **checkpoint 清单**（已存在） | `index.ckpt` | `W`（覆盖到的最大 ord）+ 段清单 + 统计 | 锚定一致性 |

### 7.2 checkpoint 写入时机

`save_snapshot()` 末尾追加：

```cpp
void SearchLayer::save_snapshot(const std::filesystem::path& dir) const {
    // 已有：BM25 段
    bm25_snapshot_->save(dir / "bm25" / "seg-current.inv");

    // ─── 新增：向量索引 ───
    std::filesystem::create_directories(dir / "vectors");
    for (auto& [name, vidx] : vector_fields_) {
        vidx->save(dir / "vectors" / (name + ".usearch"));
    }
    if (default_vector_) {
        default_vector_->save(dir / "vectors" / "$vector.usearch");
    }

    // 写 checkpoint.ckpt（原子 rename）
    write_checkpoint_atomic(dir / "index.ckpt", {
        .watermark_ord = index_.next_ord() - 1,
        .vector_segments = collect_vector_segment_meta(dir / "vectors"),
        // …… 既有字段
    });
}
```

`load_snapshot()` 开头追加：

```cpp
void SearchLayer::load_snapshot(const std::filesystem::path& dir) {
    // 已有：BM25 段
    bm25_snapshot_->load(dir / "bm25" / "seg-current.inv");

    // ─── 新增：向量段 ───
    auto vec_dir = dir / "vectors";
    if (std::filesystem::exists(vec_dir)) {
        for (auto& entry : std::filesystem::directory_iterator(vec_dir)) {
            if (entry.path().extension() != ".usearch") continue;
            std::string name = entry.path().stem().string();
            vector_field_index(name).load(entry.path());
        }
    }

    // 已有：回放 WAL
    if (wal_enabled_) replay_wal();
}
```

### 7.3 原子性与崩溃语义

- **写快照时**：先写临时文件 `.usearch.tmp` → fsync → rename → fsync 目录条目（POSIX 保证）。崩溃在 rename 前 → 旧图有效；rename 后 → 新图有效。
- **CRC 校验失败** → 退化为「扫所有 data record 重建 BM25 + HNSW」（同 BM25 兜底，详见 `vector-db-design-zh.md` §8.5）。
- **向量段缺失** → 当作"该字段从空开始"，仅靠 WAL 回放补全。

---

## 8. 写路径与并发

### 8.1 并发模型

| 子结构 | 锁 | 说明 |
|---|---|---|
| `fields_`（BM25） | 按 term 分片 `shared_mutex` | 已有 |
| `vector_fields_`（HNSW） | **HNSW 自带 per-node 锁** | usearch 内部 `atomic` + rwlock；不挂外层粗锁 |
| `index_` | 既有 `shared_mutex` | 读多写少 |
| 全局统计 / epoch | 既有机制 | 切出独立锁 |

usearch 内部已经为插入/查询做了无锁化或细粒度锁，**不**需要我们在外面再包一把 `mutex` 保护 HNSW 本身。

### 8.2 upsert 路径

```
upsert(ext_id, {text?, vector?, metadata?}):
  1. 分配新 ord（写锁短暂保护）
  2. append 一条 kDoc record 到 data file（提交点）
  3. 更新 Index 侧表
  4. on_write_fields(ord, dv):       # 文本走 BM25
  5. on_write_vector(ord, dv.vec):   # 向量走 HNSW
  6. 若 update：旧 ord 在两边都 markDeleted
  7. 写 WAL（可选，S8.9 已实现）
```

### 8.3 延迟特征

- **append** 极快（已有路径）。
- **BM25 切词 + posting** 较便宜（`μs` 级）。
- **HNSW 插入**是主开销（`M=16, ef_construction=200` 下单次 `~100μs`）。
- **HNSW 查询**（`ef=64`）`~10–50μs`。

→ 写吞吐主要受 HNSW 插入限制。V1 同步插入；要降尾延迟可后续把 HNSW 插入排队异步化（代价是「写完到可被向量检索」短暂滞后）。

---

## 9. Cask 公共 API

### 9.1 C++ API

```cpp
// cask.hpp
class Cask {
public:
    // 已有：put / get / delete / search_text / search_phrase / merge / …

    // ─── 新增 ───
    std::expected<std::vector<SearchHit>, Error>
    put_vector(const std::string& key, std::span<const float> vec);

    std::expected<std::vector<SearchHit>, Error>
    search_vector(std::span<const float> query, std::size_t k,
                  std::string_view field = "$vector",
                  std::size_t ef = 0) const;

    std::expected<std::vector<SearchHit>, Error>
    search_hybrid(std::string_view text_query,
                  std::span<const float> vec_query,
                  std::size_t k) const;

    // 配置
    void set_vector_metric(vector::Metric m) noexcept;
    void set_hnsw_params(std::size_t M = 16, std::size_t ef_construction = 200);
};
```

### 9.2 Erlang API

```erlang
%% 打开 collection 时启用向量字段
R = bitcask:collection_open("/tmp/db", [
    {analyzer, ngram},
    {vector_field, <<"$vector">>},
    {vector_dim, 768},
    {vector_metric, cosine}
]).

%% 写入带向量的文档
bitcask:collection_put_vector(R, <<"doc1">>, <<"文本内容">>, VectorBinary).

%% 纯向量检索
{ok, Hits} = bitcask:search_vector(R, QueryVecBinary, 10).

%% 混合检索
{ok, Hits} = bitcask:search_hybrid(R, <<"降息 政策">>, QueryVecBinary, 10).

%% 自定义融合策略
{ok, Hits} = bitcask:search_hybrid(R, Text, Vec, 10, [
    {fusion, rrf},           % 默认
    {fusion, {linear, 0.6}}  % 文本权重 0.6
]).
```

### 9.3 NIF 入口

```cpp
// nif_cask.cpp
static ERL_NIF_TERM cask_search_vector(ErlNifEnv*, int, ERL_NIF_TERM args[]) {
    auto* handle = …;
    auto query = take_binary_arg(args[1]);
    auto k     = take_uint_arg(args[2]);
    auto field = take_binary_arg(args[3], "$vector");
    return cpp_to_term(handle->cask.search_vector(query, k, field));
}

static ERL_NIF_TERM cask_search_hybrid(ErlNifEnv*, int, ERL_NIF_TERM args[]) {
    auto* handle = …;
    auto text   = take_binary_arg(args[1]);
    auto vec    = take_binary_arg(args[2]);
    auto k      = take_uint_arg(args[3]);
    return cpp_to_term(handle->cask.search_hybrid(text, vec, k));
}
```

Erlang 端 binary 视为 `<<F32:little-float, F32, …>>`，NIF 侧零拷贝 `span` 直接传给 HNSW。

---

## 10. 已知风险与权衡

| 风险 | 严重度 | 缓解 |
|---|---|---|
| **HNSW 插入是 upsert 延迟主因** | 中 | V1 同步；可后续异步队列化 |
| **usearch 单头文件污染公共 include** | 低 | pimpl 隔离，`vector_index.cpp` 内部 include |
| **多 dim 混用** | 低 | `Cask` 打开时绑定一个 dim，不匹配报错 |
| **大向量删除率导致 HNSW 召回漂移** | 中 | 删除率触发 merge 整体重建（沿用 `merge_policy.hpp`） |
| **RRF 分数不可解释** | 低 | 提供 `linear` 融合备选；返回结果时附 `bm25_rank` / `vec_rank` 元信息 |
| **元数据过滤用查询后过滤效率低** | 中 | 1M 规模下 top-k×3 候选再过滤通常 <10ms；V2 引入 filter-while-search |
| **WAL 在 HNSW 上未实现（已有 BM25 WAL 未覆盖向量）** | 中 | V1 先在内存中插入 HNSW；WAL 记录只回放文本 → 向量从 data file 重新解码补全 |

---

## 11. 测试策略

| 测试层 | 用例 |
|---|---|
| **VectorIndex 单元** | 构造 / `add_vector` / `search` 召回率 / `mark_deleted` 过滤 / `save`+`load` 一致性 / 多 metric |
| **SearchLayer 单元** | `search_vector` 端到端 / `search_hybrid` RRF 公式正确性 / 死点过滤 / 缓存失效 |
| **Cask 集成** | 写后立即可查 / close-reopen 后向量可查 / merge 后向量保留 / 100k 文档召回率 > 0.95 |
| **NIF / Erlang** | API 等价于 C++ / binary 编解码无失真 / `search_hybrid` 三种融合策略 |
| **基准** | HNSW 插入/查询 P50 / P99 / RPS / 内存占用（`bench/vector_bench.cpp`） |

**关键不变式：**
- 写 1 条 → 立即可查（同步插入保证）
- close + reopen → 向量结果与 close 前一致
- merge 后 → 向量集合与 merge 前等价（删除项被过滤）
- hybrid 融合 → BM25-only 与 vector-only 各自召回的并集被完整覆盖（RRF 不会"吃掉"任何一路命中）

---

## 12. 实施路线图

| 阶段 | 内容 | 工期估计 |
|---|---|---|
| **V3.0** | 集成 usearch + `VectorIndex` 单元测试（不接 SearchLayer） | 1d |
| **V3.1** | `SearchLayer::search_vector` 端到端 + 死点过滤 | 1d |
| **V3.2** | Cask 层 `put_vector` / `search_vector` API + 集成测试 | 0.5d |
| **V3.3** | NIF + Erlang 门面对象 | 0.5d |
| **V4.0** | `search_hybrid` + RRF 默认 / linear 可选 | 1d |
| **V4.1** | 混合检索集成测试 + 基准 | 0.5d |
| **V5.0** | 向量段持久化（save/load）+ checkpoint 集成 | 1d |
| **V5.1** | merge 时 HNSW 整体重建（沿用既有 merge 路径） | 1d |
| **V6.0** | 多向量字段 + 元数据过滤（filter-while-search 可选） | 待定 |

→ **V3.3 完成后即达到「能存能查」最低可用状态**；V4 加上混合；V5 加上持久化兜底。

---

## 13. 文档与代码导航

| 路径 | 用途 |
|---|---|
| `cpp/include/bitcask/vector_index.hpp` | 公共 API（pimpl 隐藏 usearch） |
| `cpp/src/vector/vector_index.cpp` | usearch 包装实现 |
| `cpp/include/bitcask/search_layer.hpp` | 新增 `vector_fields_` / `search_vector` / `search_hybrid` |
| `cpp/src/search/search_layer.cpp` | 写入路径扩展 / RRF 融合 / 段持久化 |
| `cpp/include/bitcask/cask.hpp` | `put_vector` / `search_vector` / `search_hybrid` |
| `cpp/src/cask/cask.cpp` | 委托给 SearchLayer |
| `cpp/nif/nif_cask.cpp` | `cask_put_vector` / `cask_search_vector` / `cask_search_hybrid` |
| `src/bitcask.erl` | Erlang 门面对象 |
| `third_party/usearch/include/ust.hpp` | vendored 单头文件库 |
| `cpp/tests/vector_index_test.cpp` | 单元测试 |
| `cpp/tests/search_layer_test.cpp` | 新增 `HybridRetrieval` 测试组 |
| `doc/vector-search-extension-zh.md` | 本文档 |

---

## 14. 与 `vector-db-design-zh.md` 的关系

| 维度 | `vector-db-design-zh.md`（已有蓝图） | `vector-search-extension-zh.md`（本文） |
|---|---|---|
| **范围** | V1–V6 全栈（ord/type 字段、单域 merge、ord 重编号等） | **V3–V5 的 HNSW + 混合检索**落地切片 |
| **读者** | 架构师、长期规划者 | C++ 工程师、3 天内动手 |
| **粒度** | 概念 + 原则 + 关键决策 | 接口签名、并发模型、文件路径、测试策略 |
| **前置** | 全文 | 阅读 `vector-db-design-zh.md` §3 + §6 |

**简言之**：本文是蓝图的"动手切片"，可直接据此文排期与开工。`vector-db-design-zh.md` 中已经确定的**关键决策**（ord 永不复用、单 HNSW 单图、merge 整体重建、字符 ngram 分析链）**在本文中沿用，不再讨论**。
