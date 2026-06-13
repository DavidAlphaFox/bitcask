# GetResultView 零拷贝设计（V6.1）

> 状态：已实施（V6.1.2–V6.1.5）。get() 返回 GetResultView 零拷贝视图，get_owned() 保留拷贝语义。

## 1. 问题

`Cask::get()` 返回的 `GetResult` 持有 3 个 `std::vector`（value/meta/vector），
每次 get 调用产生 2–3 次堆分配 + 2–3 次堆释放。NIF 热路径（100K+ gets/sec）
下，这些临时分配消耗大量 malloc/free 带宽和内存带宽。

**当前三次拷贝链**：

```
pread buffer (内核)
  → DataFile::read() 返回 ReadRecord { vector<byte> key, value }     ← 拷贝 1（pread→vector）
    → decode_doc_value(rec.value) 返回 DocValueView { span text/meta/vector_raw }  ← 零拷贝
      → Cask::get() 构造 GetResult { vector<byte> value, meta, vector<float> }     ← 拷贝 2
        → NIF make_binary_checked() 拷贝到 ErlNifBinary                            ← 拷贝 3
```

**目标**：消除拷贝 2（GetResult 中间层），让 NIF 直接从 ReadRecord 的 spans
拷贝到 Erlang binary。结果：

- 拷贝次数：3 → 2（拷贝 3 不可避免——Erlang VM 管理自己的堆）
- 临时堆分配：2–3 次/get → 0 次/get
- 内存带宽节省：~1× value + ~1× meta size/get

## 2. 设计方案

### 2.1 GetResultView 结构

```cpp
// cask.hpp
struct GetResultView {
private:
    friend class Cask;
    fileops::ReadRecord storage_;         // ① 声明在前→初始化在前

public:
    std::span<const std::byte> value;     // text 段（指向 storage_.value）
    std::span<const std::byte> meta;      // meta 段（可为空）
    std::span<const float> vector;        // 向量段（空=无向量）
    std::uint32_t tstamp = 0;
    std::uint64_t ord = 0;

    GetResult to_owned() const;

    // 可移动（std::expected 要求），不可拷贝
    GetResultView(GetResultView&& other) noexcept;
    GetResultView(const GetResultView&) = delete;
    GetResultView& operator=(const GetResultView&) = delete;

private:
    explicit GetResultView(fileops::ReadRecord&& rec);
};
```

**核心思路**：`storage_`（ReadRecord）通过 move 语义从 `DataFile::read()` 转入
`GetResultView`，spans 在构造函数体内从 `storage_.value` 派生。单一所有权，
无 shared_ptr 开销。

### 2.2 所有权模型

```
Cask::get(key)
  │
  ├─ keydir_->get(key) → Entry（offset, file_id, ...）
  ├─ df->read(offset, sz) → ReadRecord（owned vectors）
  │
  └─ GetResultView(std::move(*rec))
       ├─ storage_ = move(rec)        // vector 指针窃取，O(1)
       ├─ decode_doc_value(storage_.value) → spans  // O(1) 指针运算
       └─ value/meta/vector = spans   // 指向 storage_ 内部

调用方持有 GetResultView 期间：
  - storage_ 存活 → spans 有效
  - GetResultView 析构 → storage_ 析构 → spans 无效
```

**无需 shared_ptr 的理由**：
- 所有权链始终唯一：DataFile::read → Cask::get → NIF handler → Erlang binary 创建 → GetResultView 析构
- 无跨线程共享场景
- atomic refcount 对此路径是纯开销

### 2.3 Move 构造函数——span 重推导

`std::expected<GetResultView, CaskFault>` 要求 T 可移动构造。
移动后原对象的 spans 悬空，必须在 move 构造函数中从新 `storage_` 重新推导：

```cpp
GetResultView::GetResultView(GetResultView&& other) noexcept
    : storage_(std::move(other.storage_))
    , tstamp(other.tstamp)
    , ord(other.ord)
{
    // other 的 spans 现在悬空——从自己的 storage_ 重推导
    if (!storage_.value.empty()) {
        auto dv = codec::decode_doc_value(
            std::span<const std::byte>(storage_.value));
        if (dv) {
            value = dv->text;
            meta  = dv->meta;
            if (dv->has_vector && dv->dim > 0) {
                vector = std::span<const float>(
                    reinterpret_cast<const float*>(dv->vector_raw.data()),
                    dv->dim);
            }
        }
    }
}
```

`decode_doc_value` 仅做指针运算（解析 DocValue 头部偏移量），O(1) 无分配，
重推导代价可忽略。

### 2.4 API 变更

| 方法 | 返回类型 | 语义 | 调用方 |
|------|---------|------|--------|
| `Cask::get(key)` | `expected<GetResultView, CaskFault>` | 零拷贝 view（热路径） | NIF handler |
| `Cask::get_owned(key)` | `expected<GetResult, CaskFault>` | 拷贝语义（向后兼容） | benchmark |

`get_owned()` 内部调用 `get()` 后 `.to_owned()`：

```cpp
std::expected<GetResult, CaskFault>
Cask::get_owned(std::span<const std::byte> key) {
    auto v = get(key);
    if (!v) return std::unexpected(v.error());
    return v->to_owned();
}
```

**影响面**：仅 2 个调用方需更新：
1. `nif_cask.cpp:51` — 改为消费 `GetResultView` 的 spans
2. `cask_bench.cpp:113` — 改为 `get_owned()`

### 2.5 NIF 层适配

`make_binary_checked` 已接受 `span<const byte>`，无需修改签名。
NIF handler 直接从 view 的 spans 创建 Erlang binary：

```cpp
// nif_cask.cpp — 改造后
auto r = h->cask->get(as_bytes(key));   // GetResultView
if (!r) return fault_to_term(env, r.error());

if (h->cask->has_search()) {
    ERL_NIF_TERM map = enif_make_new_map(env);
    ERL_NIF_TERM text_val = make_binary_checked(env, r->value);  // span→Erlang binary
    enif_make_map_put(env, map, atoms().text, text_val, &map);
    ERL_NIF_TERM meta_val = r->meta.empty() ? atoms().undefined
                                             : make_binary_checked(env, r->meta);
    enif_make_map_put(env, map, atoms().meta, meta_val, &map);
    return make_ok(env, map);
}
ERL_NIF_TERM val_bin = make_binary_checked(env, r->value);
return make_ok(env, val_bin);
```

**消除的拷贝**：`r->value` 和 `r->meta` 不再是 `vector<byte>`（堆分配+memcpy），
而是直接指向 `ReadRecord::value` 内部的 spans。`make_binary_checked` 仍需一次
`enif_alloc_binary + memcpy`（拷贝 3，不可避免），但省掉了中间的 vector 构造。

### 2.6 Fold/Stream 批量 API（V6.1.4 设计预留）

`next_batch(n)` 返回 `std::vector<GetResultView>`，每项持有一个独立 ReadRecord。
单次 NIF 调用返回 n 条记录，减少 NIF 调用开销（每次 NIF 调用 ~1μs 的 BEAM
scheduler 切换成本）。

Erlang 侧新增 `stream_fold/4` wrapper，内部循环调用 `cask_fold_next_batch`
直到 EOI。

## 3. 前置条件与约束

- **`std::expected` 要求 T 可移动构造**——GetResultView 满足（定义了 move ctor）
- **`decode_doc_value` 必须是 O(1) 无分配**——当前实现仅做指针运算，满足
- **ReadRecord 的 vector move 是指针窃取**——C++ 标准保证 `std::vector` 的 move
  是 O(1) pointer steal（非 SSO 场景），满足
- **GetResultView 不可比 Cask 活得更久**——当前代码中 get() 返回的 view 在
  同一个栈帧内消费（NIF handler），满足。ReadRecord 的数据来自 pread，
  不依赖 DataFile 的生命周期

## 4. 性能预期

| 指标 | 改造前 | 改造后 |
|------|--------|--------|
| get() 堆分配次数 | 2–3（value/meta/vector vectors） | 0 |
| value 数据 memcpy 次数 | 2（ReadRecord→GetResult→ErlNif） | 1（ReadRecord→ErlNif） |
| meta 数据 memcpy 次数 | 2 | 1 |
| 100K gets/sec 节省 | — | ~200K–300K malloc/free + ~100MB/s 内存带宽 |

## 5. 子任务拆分

| # | 内容 | 依赖 |
|---|------|------|
| V6.1.1 | 设计文档（本文档） | — |
| V6.1.2 | C++ `GetResultView` 定义 + `Cask::get()` 返回 view + `get_owned()` + 调用方适配 | V6.1.1 |
| V6.1.3 | NIF `make_binary_checked` span 适配 + TSan 生命周期测试 | V6.1.2 |
| V6.1.4 | fold/stream 批量：`Cask::next_batch(n)` + Erlang wrapper | V6.1.2 |
| V6.1.5 | 基准 `BM_Cask_Get_Hot`：目标 < 90% baseline | V6.1.2 |

## 6. 不做的事

- **不引入 `enif_make_resource_binary`**——Erlang VM 的 binary 路径足够快，
  resource binary 引入 GC 交互复杂度不值得
- **不改变 `DataFile::read()` 签名**——ReadRecord 返回 by value 已满足需求，
  move 进 GetResultView 是零开销的
- **不做 mmap 零拷贝**——pread → vector 的拷贝（拷贝 1）暂不优化，
  归入后续 V7+ 评估
