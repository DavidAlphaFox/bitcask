# libcask 独立库拆分可行性评估

> 评估将 C++ 非 NIF 部分独立为 `libcask.so` / `libcask.a` 库的可行性。

## 结论：完全可行

现有架构已经是「准分离」状态——C++ 核心与 NIF 胶水之间的边界完全清晰，
构建系统已经模块化，耦合是单向且极薄的。

---

## 1. 现有架构分析

### 1.1 C++ 核心 / NIF 胶水边界

| 层 | 文件 | `erl_nif.h` 依赖 | 可独立？ |
|---|---|---|---|
| **纯 C++ 核心** | `cpp/src/`（24 文件，10 子模块） + `cpp/include/bitcask/`（45 头文件） | **零** | ✅ |
| **NIF 胶水** | `cpp/nif/`（14 文件） | 全部依赖 | ❌ 留在 Erlang 项目 |

关键事实：`cpp/src/` 和 `cpp/include/` 中没有任何一个文件 include 了
`erl_nif.h`，也没有任何 `enif_*` 调用。耦合是单向的——NIF 层调用 C++ 类
（`Cask`、`CaskIter`），C++ 核心对 Erlang 完全无知。

### 1.2 NIF 层文件清单（必须留在 Erlang 项目）

| 文件 | 职责 |
|------|------|
| `nif_main.cpp` | `ErlNifFunc` 注册表 + `ERL_NIF_INIT` 入口 |
| `nif_cask.cpp` | CRUD NIF：open/close/get/put/delete/sync/search_* |
| `nif_cask_iter.cpp` | 迭代 NIF：fold_start/next/release, iterator/next/release |
| `nif_cask_admin.cpp` | 管理 NIF：status/needs_merge/merge/is_empty/is_frozen |
| `nif_cask_meta.cpp` | Meta NIF（encode_meta） |
| `nif_helpers.hpp/cpp` | 共享辅助函数（includes `erl_nif.h` + `bitcask/cask.hpp`） |
| `nif_options.cpp` | 选项解析 |
| `term_conv.hpp` | Term 转换：`get_latin1_string`, `ensure_binary`, `make_ok` 等 |
| `atoms.hpp/cpp` | Erlang atom 缓存 |
| `resources.hpp/cpp` | `ErlNifResourceType` 注册，`CaskHandle` / `CaskIterHandle` |
| `priv_data.hpp` | NIF 私有数据 |

### 1.3 纯 C++ 核心模块清单（可提取为库）

**源文件**（`cpp/src/`，24 文件）：

```
cpp/src/cask/cask.cpp              # 核心 KV 存储
cpp/src/cask/meta_file.cpp
cpp/src/fileops/codec.cpp           # 记录编解码
cpp/src/fileops/data_file.cpp       # 数据文件
cpp/src/fileops/hint_file.cpp       # 提示文件
cpp/src/fileops/migrate.cpp         # 迁移工具
cpp/src/fileops/scanner.cpp         # 扫描器
cpp/src/io/posix_file.cpp           # POSIX I/O
cpp/src/lock/file_lock.cpp          # 文件锁
cpp/src/keydir/keydir.cpp           # 内存 KeyDir
cpp/src/keydir/keydir_registry.cpp
cpp/src/keydir/index.cpp            # Index 侧表
cpp/src/bm25/intersect.cpp          # BM25 倒排交集
cpp/src/bm25/inverted.cpp           # 倒排索引
cpp/src/bm25/inverted_wal.cpp       # WAL
cpp/src/bm25/query_parser.cpp       # 查询解析
cpp/src/merge/merger.cpp            # Merge 执行
cpp/src/merge/merge_policy.cpp      # Merge 策略
cpp/src/search/search_cache.cpp     # 搜索缓存
cpp/src/search/search_layer.cpp     # 搜索层
cpp/src/search/highlighter.cpp      # 高亮
cpp/src/text/analyzer.cpp           # 分词器
cpp/src/text/jieba_analyzer.cpp     # Jieba 中文分词
cpp/src/vector/hnsw.cpp             # HNSW 向量索引
```

**公共头文件**（`cpp/include/bitcask/`，45 文件）：`cask.hpp`, `keydir.hpp`,
`data_file.hpp`, `codec.hpp`, `hnsw.hpp`, `search_layer.hpp`, `analyzer.hpp` 等，
全部为纯 C++。

---

## 2. 构建系统现状

### 2.1 已有的模块化

`cpp/CMakeLists.txt` 已经将 C++ 核心拆成 **11 个独立的 static library**：

```
bitcask_format  → bitcask_io  → bitcask_fileops  → bitcask_keydir
bitcask_bm25    → bitcask_vector → bitcask_search → bitcask_index
bitcask_text    → bitcask_merge → bitcask_cask (顶层，链接以上全部)
```

NIF 的 `bitcask_cpp.so` 只是把这些 static lib 链接在一起再加一层 NIF 入口。

`cpp/CMakeLists.txt` **第 1-9 行已支持脱离顶层 CMake 独立构建**。

### 2.2 当前构建流水线

```
rebar3 compile
  └── CMake pre_hook: cmake -S . -B _build/cmake ...
  └── CMake pre_hook: cmake --build _build/cmake --target bitcask_cpp -j
          └── 链接: bitcask_cask + 7 个 static lib + ZLIB + TBB + Erlang
          └── 输出: priv/bitcask_cpp.so
          └── Post-build: 拷贝 cppjieba dict → priv/dict/

Erlang shell
  └── bitcask_cpp_nifs:init()
          └── erlang:load_nif("priv/bitcask_cpp.so", 0)
```

### 2.3 外部依赖

| 依赖 | 获取方式 | 用途 |
|------|---------|------|
| ZLIB | `find_package(ZLIB REQUIRED)` | 数据压缩 |
| TBB (oneTBB) | `find_package(TBB REQUIRED)`；TSan 构建用 FetchContent 源码 | 并行算法 |
| utf8proc | FetchContent (v2.10.0) | Unicode NFKC 归一化 |
| cppjieba + limonp | FetchContent (v5.6.7 / v1.0.2) | 中文分词 |
| GoogleTest | FetchContent (BUILD_TESTING=ON) | C++ 单元测试 |
| Google Benchmark | FetchContent (BITCASK_BUILD_BENCHMARKS=ON) | 基准测试 |

---

## 3. 耦合分析

### 3.1 唯一耦合点

NIF 与 C++ 核心的桥接只有 `resources.hpp` 中的资源句柄：

```cpp
struct CaskHandle {
    std::unique_ptr<Cask> cask;     // C++ 对象，由 BEAM 资源 GC 管理生命周期
    std::unique_ptr<CaskIter> iter;
};
```

NIF 层做的事就是 **Erlang term → C++ 调用 → Erlang term** 的翻译，没有任何业务逻辑。

### 3.2 NIF 导出函数（40 条注册，30 个唯一函数名）

涵盖：KV CRUD（open/close/get/put/delete/sync）、全文检索（text/phrase/bool/
fields/near/fuzzy/wildcard）、向量检索（vector/hybrid）、迭代（fold/iterator）、
管理（status/needs_merge/merge/is_empty/is_frozen）。

---

## 4. 拆分后的目录结构

```
libcask/  (新独立项目)
├── CMakeLists.txt          # install() 规则 → libcask.so + libcask.a + headers
├── include/bitcask/        # 45 个公共头文件（原样搬出）
├── src/                    # 10 个子模块（原样搬出）
├── tests/                  # GoogleTest（原样搬出）
├── bench/                  # Benchmark（原样搬出）
├── tools/                  # gen_inert_table, migrate_le
└── cmake/                  # utf8proc, cppjieba 的 FetchContent 配置

bitcask/  (当前项目，瘦身后)
├── cpp/nif/                # 14 个 NIF 胶水文件（留在原处）
├── CMakeLists.txt          # find_package(libcask) + 构建 bitcask_cpp.so
├── src/                    # Erlang 代码（不变）
├── priv/                   # bitcask_cpp.so 输出目录
└── rebar.config            # pre_hooks 不变
```

---

## 5. 需要处理的问题

| # | 问题 | 难度 | 说明 |
|---|---|---|---|
| 1 | **CMake install 规则** | 低 | 当前只有 `add_library(... STATIC)`，需加 `install(TARGETS ... EXPORT libcaskConfig)` + 生成 `libcaskConfig.cmake` |
| 2 | **外部依赖管理** | 低 | ZLIB + TBB 用 `find_package`；utf8proc + cppjieba 现在用 FetchContent，独立后可保持不变或改成 find_package |
| 3 | **构建时代码生成** | 低 | `gen_inert_table` 生成 `inert_table.hpp`，需随库走 |
| 4 | **cppjieba 词典文件** | 低 | 现在构建时拷到 `priv/dict/`，分离后可由 NIF 构建侧负责拷贝，或库侧 install |
| 5 | **版本同步** | 中 | 两个仓库需要版本对齐，建议用 Git tag + `find_package(libcask 1.2.0)` |
| 6 | **LTO / sanitizer 一致性** | 中 | 如果 NIF .so 和 libcask.so 分别编译，LTO 无法跨库内联（当前 nif→cask→keydir 调用链受益于跨 TU 内联）。Sanitizer 构建需要两边 flag 一致 |
| 7 | **符号可见性** | 低 | 已有 `-fvisibility=hidden`，库导出只需暴露 `Cask` 类等公共 API |

---

## 6. 两种路径选择

### 路径 A：C++ API 直出（推荐，改动最小）

- libcask 导出 C++ 类（`Cask`、`CaskIter` 等），NIF 层直接 `#include <bitcask/cask.hpp>`
- 要求 NIF 编译器与库编译器 ABI 兼容（同 GCC 版本、同 C++ 标准库）
- 对于自研自用的场景（你控制两端），完全 OK
- 改动量：几乎是零代码修改，只搬文件 + 加 CMake install
- 保留了 LTO 的跨库内联优势

### 路径 B：C API 封装

- 额外写一层 `cask_c_api.h` / `.cpp`，导出 `extern "C"` 函数
- ABI 稳定，可以跨编译器 / 跨语言绑定（Python、Rust 等也能用）
- 改动量：需要写 ~30 个 C wrapper 函数 + 对应的 NIF 适配
- 与路径 A 不冲突，可后续增量追加

### 推荐：路径 A

理由：

1. 当前项目是唯一消费者，不需要 ABI 隔离
2. 现有架构几乎没有耦合，搬文件 + CMake install 就能完成
3. 保留了 LTO 的跨库内联优势（性能路径受益）
4. 如果未来有其他语言绑定需求，再追加 C API（路径 B）是增量工作，不冲突
