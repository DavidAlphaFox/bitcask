# Bitcask — 日志结构哈希表，支持 BM25 全文检索与向量近邻搜索

[![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

[English](README_EN.md) · 📖 **API 参考**：[中文](doc/api-zh.md) · [English](doc/api-en.md) · 📝 [更新日志](CHANGELOG.md) · 🗺️ [路线图](ROADMAP.md)

Bitcask 是一个日志结构（log-structured）的哈希表键值存储引擎，使用 C++23 实现，
通过 Erlang NIF 接口对外暴露。磁盘格式采用带类型记录（`kDoc`/`kTombstone`）与
逐次写入序号（ordinal），可选 DocValue 编码（text + vector + metadata）。

主要特性：BM25 全文检索、向量近似最近邻搜索（三引擎可选：`hnsw` 内存图 /
`ivfrq` 磁盘档 / `diskann` 实验性）、RRF 混合检索（融合文本与向量两路排序信号）。

实现为单一 C++23 NIF（`cpp/`）+ 薄 Erlang 门面（`src/bitcask.erl`），所有操作经由
`bitcask_cpp_nifs` → `priv/bitcask_cpp.so`。

## 构建

### rebar3（Erlang + C++ NIF）

```sh
rebar3 compile        # 编译 priv/bitcask_cpp.so
rebar3 eunit          # Erlang/NIF 测试 (eunit)
rebar3 do xref, dialyzer
```

要求 Erlang ≥ 22.0；C++ NIF 构建另需 **ICU 开发包**（6.3 起：Debian/Ubuntu
`libicu-dev`，Fedora `libicu-devel`，macOS `brew install icu4c`）——默认走
系统 ICU，找不到才回落 vendored `third_party/icu`（380 MB，`--recursive`
有意跳过）。

可选的本地嵌入后端（llama.cpp），**默认不构建**：

```sh
BITCASK_WITH_LLAMA=1 rebar3 compile   # 额外产出 priv/bitcask_llama.so 与一组 vendored ggml/llama 库
```

关掉时构建产物与这个后端存在之前一字不差：不拉子模块、不加 CMake 开关、不多
任何 target。见 [doc/local-embedding-zh.md](doc/local-embedding-zh.md)。

### CMake（C++ 测试 + 基准）

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure   # 400+ GoogleTests
```

Sanitizer（一次只能开一种——ASan 和 TSan 互斥）：

```sh
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON
```

基准（仅 Release）：

```sh
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench
```

## 快速上手（`rebar3 shell`）

编译 NIF 并进入 Erlang shell：

```sh
rebar3 shell        # 先编译，再启动 REPL
```

**键值模式** — 纯二进制值：

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).   % 返回 {CaskRef, EmbedderCtx}
{#Ref<0.1234.5678.90>,undefined}
2> bitcask:put(R, <<"k">>, <<"hello">>).
ok
3> bitcask:get(R, <<"k">>).
{ok,<<"hello">>}
4> bitcask:close(R).
ok
```

**有序范围查询**（6.0.0）— 按 key 字典序取 `[Lo, Hi)`，代价 O(range) 而不是
O(全表) 过滤。两端都可以传 `undefined` 表示无界：

```erlang
1> R = bitcask:open("/tmp/db", [read_write]).
2> [bitcask:put(R, <<"user:", (integer_to_binary(N))/binary>>, <<"v">>)
    || N <- lists:seq(1, 3)].
3> bitcask:range(R, {<<"user:">>, <<"user;">>}).     % 前缀扫描：`;` = `:` 的下一个字节
[{<<"user:1">>,<<"v">>},{<<"user:2">>,<<"v">>},{<<"user:3">>,<<"v">>}]
4> bitcask:range_fold(R, {<<"user:">>, undefined}, [{prefetch, 64}],
                      fun(K, _V, _T, _O, Acc) -> [K | Acc] end, []).
[<<"user:3">>,<<"user:2">>,<<"user:1">>]
```

> ⚠️ range 是 **per-key 弱一致**（迭代期间的并发写可能部分可见），不是
> `fold/3` 的快照语义。需要快照请继续用 `fold`。
> OKI 不可用时按成因分两个码：只读/`merge_only` 打开一个从未建过索引的目录 →
> `{error, no_index}`（读写重开即建）；可写 open 重建失败 →
> `{error, index_rebuild_failed}`（IO/环境问题，**数据在、只有索引不在**）。

**原子批与多键事务**（6.0.0）— 崩溃/掉电后整批要么全生效要么全不生效：

```erlang
1> bitcask:put_batch_atomic(R, [{put, <<"a">>, <<"1">>},
                                {put, <<"b">>, <<"2">>},
                                {remove, <<"old">>}]).
ok
2> bitcask:txn_commit(R, [{put, <<"x">>, <<"1">>}, {put, <<"y">>, <<"2">>}]).
ok
3> bitcask:txn_commit(R, [{put, <<"d">>, <<"1">>}, {put, <<"d">>, <<"2">>}]).
{error,{invalid_option,<<"txn: duplicate key in ops">>}}      % 零副作用
```

> `txn_commit` 比 `put_batch_atomic` 多一层校验（非空 / key 非空 / key 不重复 /
> 不占用 `_txn:` 前缀），第三参可选 `sync_on_commit`（默认）或 `no_sync`。
> ⚠️ 两者**不提供隔离性与 CAS**——中间态对并发读者可见，键集重叠的并发提交
> 需应用层串行化。⚠️ **首次调用把目录 meta 懒升级为 v6**，此后不能被早于
> 上游 5.1.0 的读端打开。

**BM25 全文检索** — 用 `{analyzer, ...}` 打开即可启用。每次 `put` 自动索引；
返回 `{ok, [{Key, Ord, Score}, ...]}`，按分数降序：

```erlang
%% 分析器: whitespace（英文） | ngram（CJK n-gram） | jieba（中文分词）
1> R = bitcask:open("/tmp/idx", [read_write, {analyzer, whitespace}]).
{#Ref<0.9876.5432.10>,undefined}
2> bitcask:put(R, <<"d1">>, <<"the quick brown fox">>).
ok
3> bitcask:put(R, <<"d2">>, <<"a lazy brown dog">>).
ok
4> bitcask:search_text(R, <<"brown">>).               % 两篇都命中
{ok,[{<<"d2">>,1,0.18232},{<<"d1">>,0,0.18232}]}
5> bitcask:search_phrase(R, <<"quick brown">>).       % 仅 d1 有相邻短语
{ok,[{<<"d1">>,0,0.69315}]}
6> bitcask:search_fuzzy(R, <<"quikc">>, 2).           % 拼写错误，编辑距离 ≤ 2
{ok,[{<<"d1">>,0,0.69315}]}
7> bitcask:search_wildcard(R, <<"fox*">>).            % 前缀通配符
{ok,[{<<"d1">>,0,0.69315}]}
8> bitcask:close(R).
ok
```

> 在**未指定分析器**的 cask 上调用任何 `search_*` 函数将返回 `{error, no_index}`。

> **同义词**（v3.0.0）：open 时加 `{synonym_file, Path}`（每行逗号分隔一组同义词），
> 查询自动展开。open-time 不可变配置（取代已删除的运行期 `set_synonym_map/2`）——
> 运行期更换词典需重开库。

**向量搜索** — 向量搜索需索引模式（`{analyzer, ...}`）；引擎缺省 `hnsw`，如需磁盘档
在 open 时加 `{vector_engine, ivfrq | diskann}`（建库固定，不可运行期切换）。**推荐流程：open
时把 embedder 作为 `{Provider, Cfg}` 传入，open 内部建 ctx 并自动把集合维度设为
embedder 的 `vector_dim`——无需外部 `new`、也无需单独写 `{vector_dim, N}`。** 之后
`put #{text => ...}` / 查询都自动 embed。`open` 返回 `{CaskRef, EmbedderCtx}`
元组，整体当 Handle 传给后续调用：

```erlang
%% 1) open 直接配 embedder（Provider = openai | anthropic | {custom,Mod}）。
%%    OpenAI 兼容端点，如 llama.cpp server / vLLM。
1> H = bitcask:open("/tmp/vec", [read_write, {analyzer, whitespace},
1>     {embedder, {openai, #{
1>         url => "http://localhost:8080/v1/embeddings",
1>         model => <<"qwen3-embedding">>,
1>         dim => 2560,                    % 模型原生维度
1>         vector_dim => 1024,             % 可选 MRL 截断维度（≤dim；缺省=dim）
1>         max_input_bytes => 32768,       % 可选（默认 32768）
1>         timeout_ms => 30000,            % 可选（默认 30000）
1>         connect_timeout_ms => 5000}}]). % 可选（默认 5000）
{#Ref<0.1.2.3>, #{module => bitcask_embedder_openai, dim => 2560,
                  vector_dim => 1024, config => #{...}}}
%% 2) put 只给 text → 自动 embed 入库
2> bitcask:put(H, <<"d1">>, #{text => <<"the quick brown fox">>}).
ok
%% 3) 混合检索：向量位省略 / 传 auto → 用句柄 embedder 自动 embed 查询文本
3> bitcask:search_hybrid(H, <<"fast brown animal">>).
{ok,[{<<"d1">>,0,0.0328}]}
%% 4) 纯向量检索：查询传 {text, _} → 自动 embed（分数为 cosine 相似度，示意）
4> bitcask:search_vector(H, {text, <<"fast brown animal">>}).
{ok,[{<<"d1">>,0,0.83}]}
%% 5) 需要原始向量时用 embed/2 门面
5> {ok, Q} = bitcask:embed(H, <<"fast brown animal">>).
6> bitcask:close(H).
ok
```

> **MRL（Matryoshka）**：`dim` 永远是模型原生维度；`vector_dim` 是 MRL 截断后的
> 落库/检索维度（≤ dim，缺省 = dim）。二者不一致时 embed 请求自动带
> `dimensions => vector_dim`，由服务端按 MRL 截断+重归一（端点需支持）。
>
> **低层路径（不用 embedder）**：open 省略 `embedder`、改写 `{vector_dim, N}`；`put`
> 用 `#{text => T, vector => V}` 自带 f32 小端序向量
> （`V = << <<X:32/float-little>> || X <- Floats >>`），查询传向量二进制。
> 例如 `vector_dim=4`、库里 `[1,0,0,0]`、查 `[0.9,0.1,0,0]` →
> `search_vector(H, V)` 返回 `{ok,[{<<"d1">>,0,0.99388}]}`（cosine = 0.9/√0.82）。

> **两档 embedder**：HTTP 档（`openai` / `anthropic`）无状态、请求本来就该并发，
> 直接写 `{embedder, {openai, Cfg}}`，**不需要配置任何进程**；内置档（下面的
> 本地模型）有状态、必须串行，走 `bitcask_embedder_server` 进程 ——
> application env 配 `{embedder, #{name, provider, config}}`，由 `bitcask_sup`
> 起，`{embedder, my_embedder}` 引用。**多个 cask 共用一份权重**，生命周期跟着
> 进程走。⚠️ 配了却起不来会让整个 bitcask application 起不来（有意如此：静静地
> 降级成没有嵌入能力比当场死掉危险得多）。共享逻辑在 `bitcask_embedder_util`。

> **本地嵌入（可选，默认不构建）**：`{custom, bitcask_embedder_llama}` 在 BEAM
> 进程内用 llama.cpp 直接算 embedding，不经 HTTP 端点。`BITCASK_WITH_LLAMA=1
> rebar3 compile` 打开；产物是独立的第二个 NIF（`priv/bitcask_llama.so` + 一组
> vendored ggml/llama 共享库），核心 `bitcask_cpp.so` 不受影响。
> ⚠️ 这是**另开一档**不是替换 HTTP 端点：CPU 上跑得动的是 0.6B/1024 维这一类，
> 换档 = 落库维度变了 = 全量重建索引；而且 ggml 的 `abort()` 会带走整个 node。
> 取舍、实测数字（查询 35 ms；`n_threads` 超订会慢 20 倍）与排错见
> [doc/local-embedding-zh.md](doc/local-embedding-zh.md)。

> **GPU（NVIDIA CUDA / Vulkan）**：**构建期探测 SDK、运行期探测显卡**，两件事在
> 不同机器上发生所以分开做。构建期两个开关都默认 `AUTO`（`BITCASK_LLAMA_CUDA` /
> `BITCASK_LLAMA_VULKAN`）；运行期由 Erlang 自己按 CUDA > Vulkan > CPU 挑
> （`backend => auto`），**不需要按机器改配置、也不需要脚本**。
> ⚠️ 多卡机器上**默认只用一张**：嵌入模型切层跨卡是反优化，要的是数据并行——
> 开 N 个 embedder 进程各绑一张卡（`gpu_index`）。
> 旧描述：默认 `AUTO`——构建机上有 CUDA Toolkit 就编进去
> （`BITCASK_LLAMA_CUDA=AUTO|ON|OFF`）。发布构建请用 `ON`，AUTO 在缺 toolkit 的
> 机器上会**悄悄**产出纯 CPU 包。CUDA 运行时（cudart/cublas/cublasLt）默认随包
> 平铺进 `priv/`——体积不是约束，换掉的是"目标机缺 libcublas → ggml 静默跳过
> → 降级纯 CPU"这一整类故障。先跑 `scripts/detect-llama-backends.sh` 探测环境
> 并核对运行时真正枚举到了什么（`--build` 问 SDK、`--runtime` 问显卡，两段可以
> 在不同机器上跑）。构建期事实烧在 .so 里，运行期用 `bitcask_llama_nifs:gpu_status()`
> 把两者对到一起——只看运行期的话，"0 个 GPU"分不清是包里没编 CUDA（要重新构建）
> 还是机器没驱动（要装驱动）。

> **向量双引擎**（v4.0.0）：open 时加 `{vector_engine, hnsw | ivfrq | diskann}`
> 选定引擎（默认 `hnsw`，内存图，≤数 M 向量；`ivfrq` IVF 磁盘段，10M-100M 推荐；
> `diskann` Vamana 图，实验性）。建库一次性选定并持久化进 `bitcask.meta`；重开
> 不符 → `{error, mode_mismatch}`；运行期不可切换（离线工具 `vec_engine_migrate`
> 只改 meta，首次 open 全量 fold 重建，可回滚）。各引擎调优选项（`hnsw_m` /
> `hnsw_ef_construction` / `hnsw_build_nav_int8` / `vector_ivf_nlist` /
> `vector_ivf_nprobe` / `vector_diskann_r` / `vector_diskann_l_build`）以 `0`
> 表示自动默认。

## API 概览

| 函数 | 说明 |
|------|------|
| `open/1,2` | 打开 cask（KV 模式或通过 `{analyzer, ...}` 启用索引模式） |
| `get/2`, `put/3`, `delete/2`, `sync/1` | 核心 KV 操作 |
| `fold/3,6`, `fold_keys/3,6`, `list_keys/1` | 迭代（**快照一致**，代价 O(全表)） |
| `range/2,3`, `range_fold/5` | 有序范围查询 `[Lo, Hi)`，代价 **O(range)**；per-key 弱一致（非快照）；`{prefetch, N}` 可批量并发取值 |
| `put_batch_atomic/2`, `txn_commit/2,3` | 跨崩溃原子批 / 多键事务；`Ops :: [{put,K,V} \| {remove,K}]`；⚠️ 首次调用把目录 meta 懒升级为 v6 |
| `stream/1`, `next/1`, `stop/1`, `with_stream/2` | 流式迭代 |
| `merge/1,2,3`, `needs_merge/1,2`, `status/1` | 合并管理 |
| `search_text/2,3`, `search_phrase/2,3`, `search_fields/2,3` | BM25 检索（全文 / 短语 / `field:term^boost`） |
| `search_near/3,4`, `search_fuzzy/3,4`, `search_wildcard/2,3` | 近邻 / 模糊（编辑距离）/ 通配符搜索 |
| `search_vector/2,3,4,5`, `search_hybrid/2,3,4,5` | 向量近邻（HNSW / IVF-RaBitQ / DiskANN 三引擎，`open` 时 `{vector_engine, ...}` 选定）/ RRF 混合检索（BM25 + 向量）；查询传 `{text,_}`（vector）或 `auto`（hybrid）自动 embed；`/5` 末参为 meta filter |
| `embed/2` | 用句柄 embedder 把文本编码成向量（`{ok, Vec}`/`{error, no_embedder}`） |
| `is_empty_estimate/1`, `is_frozen/1`, `close_write_file/1` | 工具函数 |

## 文档

| 文件 | 内容 |
|------|------|
| `doc/api-zh.md` / `doc/api-en.md` | **API 参考**：能力、参数含义与限制、返回值（中/英） |
| `doc/USAGE.md` | 教程：打开、合并、配置、搜索 |
| `doc/local-embedding-zh.md` / `doc/local-embedding-en.md` | **本地嵌入后端**（llama.cpp NIF）：构建、embedder 进程、静默失败的三个来源、实测数字（中/EN） |
| `doc/format-zh.md` | 磁盘格式字节级规范（带类型记录、DocValue、提示文件、锁；字节序统一小端） |
| `doc/migrate-le.md` / `doc/migrate-le-en.md` | **迁移工具** `migrate_le`：把旧大端（v1）目录离线迁移成小端（v2）（中/EN） |
| `doc/cpp-arch.md` | C++ 模块布局、锁策略、构建入口 |
| `doc/migration.md` | 特性状态与 API 参考 |
| `doc/concurrency-zh.md` | 并发与共享语义 |
| `doc/put-flow-zh.md` | put(K,V) 完整调用链 |
| `doc/vector-db-design-zh.md` | 向量库设计方案（V1–V6 蓝图） |
| `doc/vector-search-extension-zh.md` | 向量搜索扩展：HNSW + RRF 混合检索 |
| `doc/hnsw-design-zh.md` | HNSW 向量索引设计（并发/持久化/RRF/实施表） |
| `doc/keydir-sharding-design-zh.md` | KeyDir 分片并发 + 屏障 v2 写者闸门 |
| `doc/unified-architecture-plan-zh.md` | 统一架构计划（已实施） |
| `doc/libcask-extraction-zh.md` | **libcask 独立库拆分可行性评估**（2.2.0 规划） |
| `ROADMAP.md` / `ROADMAP_EN.md` | **路线图**：6.4.0 / 6.3.2 / 6.3.1 / 6.2.2 / 6.2.1 / 6.1.0 / 6.0.0 / 5.1.0 / 5.0.0 / 4.0.0 / 3.1.0 / 3.0.0 落地 + 2.1.1 已落地（P5–P15）+ 2.2.0 规划（libcask 独立 / V7+ 向量优化）（中/英） |
| `TASK.md` | 详细任务拆分与历史 |

## 项目状态

- **C++ NIF** 覆盖全部核心 KV 操作（`get`/`put`/`delete`/`sync`/`fold`/`merge`）
- **BM25 全文检索** — 文本 / 短语 / 多字段 / 近邻 / 模糊 / 通配符，外加同义词与高亮
- **向量检索（三引擎）** — 近似最近邻搜索，open 时经 `{vector_engine, hnsw | ivfrq | diskann}` 选定并持久化进 `bitcask.meta`（**建库固定**，重开不符 → `{error, mode_mismatch}`）：`hnsw`（默认，内存图，≤ 数 M 向量，支持 cosine / L2 / dot，per-node 锁并发读，BCVS 快照持久化，merge 重建物理清死）、`ivfrq`（IVF-RaBitQ 磁盘档，10M–100M 推荐）、`diskann`（Vamana 盘上图，**实验性**）；磁盘档引擎要求 cosine / dot
- **RRF 混合检索** — 经 Reciprocal Rank Fusion 融合 BM25 与向量两路（`score = Σ 1/(60+rank)`，每路取 `K' = max(K×4, 64)`）
- **Embedder behaviour** — `bitcask_embedder` 回调 + OpenAI 兼容参考实现
- **Jieba 中文分析器** 已集成（whitespace / ngram / jieba）
- **带类型记录格式**（`kDoc`/`kTombstone` + 逐次写入序号）为默认格式
- **统一架构** — Cask 与 Collection 已合并为单一引擎，按配置（`{analyzer, ...}`）启用 KV 或索引模式
- **2.1.1 系统优化**（2026-06）— HNSW int8-only 内存模式（向量内存 −80%）、sealed 文件 mmap 零拷贝读、read 句柄 fd 预算 LRU、统一 `search.ckpt` 恢复路径、全盘字节序统一小端 + `migrate_le` 迁移工具（[文档](doc/migrate-le.md)）、hybrid 两路并行、merge I/O 顺序优化、open 后台 merge；详见 [`CHANGELOG.md`](CHANGELOG.md)
- **并发加固**（2026-06 审计）— 索引读路径与异步索引 worker 并发安全：`meta_blob`/搜索缓存锁内拷贝不逃逸、倒排索引快照安全遍历、跨线程标量原子化、IndexPool 消费者异常兜底；详见 [`doc/concurrency-zh.md` §6](doc/concurrency-zh.md)
- **3.0.0**（2026-06-25）— 升级 libbitcask v3.0.0（ABI 破坏，`SOVERSION` 1→3）：同义词词典改为 open-time 不可变选项 `{synonym_file, Path}`（移除运行期 `set_synonym_map/2`）；随库引入 `Cask` handle 多线程安全、`parallel_scan` 全表并行扫描、异步索引 MapReduce 流水线、批量检索
- **3.1.0**（2026-07-01）— 升级 libbitcask v3.1.0（ABI 不破坏）：`{max_read_handles, unlimited}` / `{auto_compact_dead_ratio, R}` 选项、错误原子 `closed`；随库引入 read 句柄默认上限（按 `RLIMIT_NOFILE` 自动推导）、`bitcask.meta` v3 加 CRC32、field.schema FSCH v1 头 + CRC
- **4.0.0**（2026-07-13）— 升级 libbitcask v4.0.0（ABI 破坏，`SOVERSION` 3→4，源码级兼容）：`{vector_engine, hnsw|ivfrq|diskann}` 向量双引擎 + 调优选项、`{auto_checkpoint_min_docs, N}` 崩溃恢复重放有界；随库引入 IVF-RaBitQ-lite 引擎、DiskANN 引擎（实验性）、AVX2 int8 内核、HNSW `.qc8` mmap 化；`examples/` Wikipedia 检索库示例
- **4.1.0**（2026-07-15）— 升级 libbitcask v4.1.0（ABI 不破坏，`SOVERSION` 保持 4，盘上格式不变）：对 Erlang 调用方**无 API 变更**，重编即得；随库引入 Phase 5/6 深度审计成果——修复 `close/1` 拆卸路径的进程级永久挂死（`IndexPool` 计数泄漏 + `unregister_lib` 无界 `flush`）、hnsw 三处原子写 rename 前补 `fdatasync`（此前崩溃即半截文件）、`RowChunks`/`MmapSegment` 资源泄漏；`file_util` 归并使 fsync 纪律 4 套收敛为 1 套
- **6.4.0**（2026-09-08，当前版本）— 本地嵌入后端两个产品决定：**`slots => K` 并发槽位**（新配置：K 个同配置 worker = K 路真正并发的 forward，配置原样透传、proxy least-queue 透明分摊，起不满就死，与 `instances` 互斥）与**设备选择只认独立 GPU**（随 llama.cpp b10859 的 IGPU 类型：核显不参与 GPU 加速，没有独显直接走 CPU——刻意取舍：嵌入负载小、iGPU 驱动与显存共享策略参差）。`backend_info`/`gpu_status` 设备表 `type` 扩为 `cpu/gpu/igpu/accel/meta` 五档。复用既有池机制，核心 KV/检索零变化，无 ABI / 盘上格式变更
- **6.3.2**（2026-09-08）— 升级 llama.cpp `b10257` → **`b10859`**（本地嵌入后端，opt-in；**不涉及 libbitcask**，核心 `bitcask_cpp.so` 零变化）：NIF 源码零改动，CPU 与 Vulkan 两档构建全路径复核通过——14 个 CPU 变体、`libggml-vulkan.so` 正常落 `priv/`、`build_info` / `gpu_status` 的构建期/运行期诊断三态（vulkan on/off、gpu_count、cpu_only_build）如实。⚠️ 上游沿用「只认 Discrete/Integrated GPU」的 Vulkan 设备过滤：llvmpipe 等 CPU 软件渲染设备默认跳过（`GGML_VK_VISIBLE_DEVICES` 可强制纳入，诊断用）。⚠️ 从旧 pin 原地升级会留下 `libggml-*.so.0.18.0` 残骸（无害，`rebar3 clean` 清除）
- **6.3.1**（2026-09-08）— 升级 libbitcask 6.2.2 → **6.3.1**（跨上游 6.3.0 + 6.3.1 两版；既有 C API 与 C++ 公开头签名/枚举/结构体布局零改动，新增皆为 additive，`SOVERSION` 保持 6，盘上格式不动、无迁移）：对 Erlang 调用方**无 API 变更**，NIF 代码一行没改，重编即得。⚠️ **新增构建依赖 ICU**（≥ 60）：文本底座从 utf8proc 迁到 ICU（NFKC_Casefold / 字符属性 / GB18030 等编码转换），默认走系统 `libicu-dev`，vendored `third_party/icu`（380 MB，`update = none` 被有意跳过）为回落；CI apt 列表已随动。⚠️ 索引可复现性：分词 = NFKC_Casefold 表 = ICU 版本，系统 ICU 漂移时新旧文档可能切成不同 term（召回悄悄变少、无显式症状），`bitcask.meta` 现记录建索引时的 ICU/Unicode 主版本并在重开不一致时告警（只告警不拒开）；要钉死版本用 `-DBITCASK_ICU_PROVIDER=vendored`。随库带入 S39 C API 增量（多字段文档 `bitcask_put_doc_ex`、meta 编解码、search 分页 `*_ex`、`bitcask_search_text_highlight`），Erlang 门面暂未开到
- **6.2.2**（2026-09-01）— 升级 libbitcask 6.2.1 → **6.2.2**（PATCH，纯可移植性；C API 与 C++ 公开头的签名/枚举/结构体布局零改动，`SOVERSION` 保持 6，盘上格式不动、无迁移）：对 Erlang 调用方**无 API 变更**，本仓库 Erlang / NIF 代码一行没改，重编即得。上游把库编译到 **libc++**（FreeBSD 15 / macOS 的默认标准库）上——四处 `std::atomic<std::shared_ptr<T>>` 改走新的 `AtomicSharedPtr<T>` shim（libstdc++ 上就是 `std::atomic` 的别名，**本仓库逐字零变化**；libc++ 缺 P0718R2 偏特化，落到互斥量兜底）、`hnsw` 的 `atomic_ref` 去 const、bundled oneTBB 头改标 SYSTEM。随库带入一条**真 UB 修复**：`IndexPool` 超时用例里的 use-after-scope，Linux 上一直静默通过（libstdc++ 放过「解锁未持有的 mutex」），libc++ 必炸
- **6.2.1**（2026-08-14）— 升级 libbitcask 6.1.0 → **6.2.1**（跨上游 6.2.0 + 6.2.1 两版；C API 与 C++ 公开头零改动，`SOVERSION` 保持 6，盘上格式不动、无迁移）：对 Erlang 调用方**无 API 变更**，重编即得。随库带入上游 Windows 移植（MSVC 原生 x64）与 I/O 稳健性收口——**撕裂尾部覆盖**（写入偏移锚定到最后一个完整 record，崩溃/掉电后尾部半条 record 不再当有效数据）、裸 POSIX 调用收进 `bitcask::io` seam、SIMD 改运行期 CPU 探测（换机器不再 SIGILL）。构建侧：上游路径改用 `PROJECT_SOURCE_DIR` 后，本仓库那段 `third_party/*` 符号链接 workaround 已删除。⚠️ 唯一对外可见的行为变化是 `bitcask.write.lock` 多了第二行（进程实例令牌，POSIX 恒为 `0`），两个解析器都只看首行、新旧双向兼容
- **6.1.0**（2026-08-06）— 升级 libbitcask 6.0.0 → **6.1.0**（MINOR，纯增量：新枚举值追加在尾部，ABI 未破坏，`SOVERSION` 保持 6，无盘上格式变更、无迁移）：`range` 的「索引不可用」按成因拆成两个错误码——`{error, no_index}`（本句柄本就不建索引：只读/`merge_only` 打开无 OKI 的目录，读写重开即建）与新增的 `{error, index_rebuild_failed}`（可写 open 试建而败，IO/环境问题）。⚠️ 后者意味着**数据在、只有索引不在**，值得告警而不是当成空库
- **6.0.0**（2026-08-06）— 升级 libbitcask v5.0.0 → **6.0.0**（跨上游 5.1.0 + 6.0.0 两版；ABI 破坏，`SOVERSION` 5→6，本仓库源码级依赖重编即可）：新开三块 API——`range/2,3` + `range_fold/5` 有序范围查询（O(range)，上游实测 15×）、`put_batch_atomic/2` 跨崩溃原子批、`txn_commit/2,3` 多键事务；新增 `{keydir_cache_entries, N}` 选项（keydir 磁盘驻留 Level B，上游 1 亿 key 实测常驻 -90%）；`open/2` 的错误现在带 detail（`{error, {io_error \| invalid_option, Msg}}`）。⚠️ **存量目录必须先离线迁移**：上游 5.1.0 的 hint ord flag-day 使 `bitcask.meta` v4 → v5，5.x 写出的目录被干净拒开，用 `bitcask_migrate hintord <src> <dst>` 非破坏性迁移（data 字节零改动）
- **5.1.0**（2026-08-06）— 本地嵌入后端（llama.cpp / ggml，**默认不构建**）+ 独立 embedder 进程。**不涉及 libbitcask 升级**，无 ABI / 盘上格式变更，关掉时产物与 5.0.0 一字不差：独立第二 NIF `priv/bitcask_llama.so`（`BITCASK_WITH_LLAMA=1` 打开），`bitcask_embedder_server` 让多个 cask 共用一份权重且生命周期跟着进程走，CUDA 支持（`BITCASK_LLAMA_CUDA=AUTO|ON|OFF`）+ 构建期/运行期分离诊断（`build_info/0` / `backend_info/0` / `gpu_status/0`）+ 探测脚本 `scripts/detect-llama-backends.sh`；⚠️ `bitcask:open/2` 不再吞掉 `application:start` 失败（返回 `{error, {bitcask_app_start_failed, _}}`，有意的行为变更）
- **5.0.0**（2026-07-17）— 升级 libbitcask v5.0.0（64 位时间戳 flag-day，ABI + **盘上格式**双破坏，`SOVERSION` 4→5）：`tstamp`/`expiry_at` 全链路 u32→u64（Y2038 前瞻），修复极大 `expiry_secs` 下 u32 求和回绕致全库误判过期；对 Erlang 调用方**无 API 变更**（`tstamp` 本就是任意精度整数）；`bitcask.meta` v4 门禁干净拒开旧 u32 纪元库，存量库用上游 `bitcask_migrate tstamp64` 非破坏性离线迁移，无须重灌

## 许可证

Apache 2.0；详见 `LICENSE`。
