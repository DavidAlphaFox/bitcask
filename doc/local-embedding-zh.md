# 本地嵌入后端（llama.cpp / ggml）

在 BEAM 进程内直接算 embedding，不经 HTTP 端点。产物是**第二个 NIF**
`priv/bitcask_llama.so`，与核心的 `priv/bitcask_cpp.so` 互不依赖。

**默认不构建。** 关掉时本仓库的构建产物与这个后端存在之前一字不差：不拉子模块、
不加 CMake 开关、不多任何 target。

---

## 1. 先决定要不要用它

这不是"把 `url` 换成 `model_path`"，是**另开一档**。三条摆在前面：

| | HTTP 端点（`bitcask_embedder_openai`） | 本地（`bitcask_embedder_llama`） |
|---|---|---|
| 典型模型 | qwen3-embedding 4B/8B，2560 维 | 0.6B，1024 维（CPU 上跑得动的档） |
| 查询延迟 | 网络往返 + 服务端 | **35 ms**（实测，见下） |
| 索引吞吐 | 服务端并发 | 单句柄串行，276 token ≈ 890 ms |
| 崩溃域 | 端点挂了是 `{error,_}` | **ggml 的 abort() 会带走整个 node** |
| 部署 | 要维护一个服务 | 一个 .so + 一个 GGUF 文件 |

- **换档 = 落库维度变了 = 全量重建索引。** 1024 ≠ 2560，没有平滑迁移。
- **崩溃域那一行是认真的。** ggml 的 `GGML_ASSERT` 失败走 `abort()`，在 BEAM 里
  就是整个 node 连同所有打开的 cask 一起没。NIF 层能做的只有把可预期的失败挡在
  llama 之前（路径、池化、token 数），剩下的属于"把推理放进 VM 进程"这个决定
  本身的代价。不能接受就继续用 HTTP 端点——那本来就是进程隔离的。

用它的理由通常是：查询侧要低延迟、不想维护一个额外服务、或者部署环境根本连不出去。

---

## 2. 构建

```sh
BITCASK_WITH_LLAMA=1 rebar3 compile
```

或直接用 CMake：

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release \
      -DBITCASK_WITH_LLAMA=ON
cmake --build _build/cmake --target bitcask_llama -j
```

首次会拉 `third_party/llama.cpp` 子模块（约 200 MB，钉在 tag `b10257`）并全量
编译，是分钟级。之后增量是 no-op。

构建完 `priv/` 下会多出一组共享库：

```
priv/bitcask_llama.so          ← NIF 本体
priv/libggml-base.so*          ← ggml 核心（必须是共享库）
priv/libggml-cpu-{x64,sse42,sandybridge,ivybridge,haswell,piledriver,
                  skylakex,cannonlake,cascadelake,icelake,cooperlake,
                  zen4,alderlake,sapphirerapids}.so   ← 13 个 CPU 变体
priv/libggml.so* priv/libllama.so*
```

**13 个变体是运行时按 CPU 微架构 `dlopen` 的**，不是构建期选一个。发行时必须
全带上——少发一个的表现是"那一档 CPU 的用户悄悄没有本地嵌入"，你这边永远
测不出来。`rebar3 clean` 会一并清掉。

> ⚠️ `GGML_NATIVE` 被强制设为 `OFF`。默认的 `ON` 会按**构建机**的指令集编译，
> 产物在老 CPU 上是 `SIGILL` 当场崩（在 BEAM 里就是 node 没了），不是降速。

---

## 3. 用

### 3.1 直接配进 `bitcask:open`

与 `openai` provider 完全同形，走 `{custom, Mod}` 这条路：

```erlang
H = bitcask:open(Dir, [read_write, {analyzer, whitespace},
      {embedder, {{custom, bitcask_embedder_llama},
                  #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
                    pooling    => last,
                    n_ctx      => 512}}}]),

ok = bitcask:put(H, <<"d1">>, #{text => <<"猫在垫子上睡觉"/utf8>>}),
{ok, R} = bitcask:search_vector(H, {text, <<"猫咪在睡觉"/utf8>>}, 3).
```

集合维度由 embedder 的 `vector_dim` 推出，不用也不该再写 `{vector_dim, N}`。

> ⚠️ **`bitcask:close/1` 不会关掉 embedder。** 它只关 cask ref。对 HTTP provider
> 无所谓（没东西要释放），但这里意味着权重一直占着内存，直到那个 ctx term 被 GC
> ——而释放会占住 BEAM 的资源回收线程几十到几百毫秒。
>
> 而且 **`bitcask:open` 每调一次就装一份权重**（它内部替你调 `bitcask_embedder:new`）。
> 两个 cask 用同一个模型 = 内存里两份。
>
> 所以多 cask / 需要显式生命周期时，**自己先加载一次，再用 `handle =>` 传进去**：
>
> ```erlang
> {ok, _} = bitcask_llama_nifs:ensure_backend(),
> {ok, M} = bitcask_llama_nifs:model_load(
>             <<"/models/qwen3-emb.gguf">>, #{pooling => last, n_ctx => 512}),
>
> H1 = bitcask:open(Dir1, [read_write, {analyzer, whitespace},
>        {embedder, {{custom, bitcask_embedder_llama}, #{handle => M}}}]),
> H2 = bitcask:open(Dir2, [...same...]),   %% 复用同一份权重
>
> ok = bitcask:close(H1), ok = bitcask:close(H2),
> ok = bitcask_llama_nifs:model_close(M).  %% 谁开的谁关
> ```
>
> `handle =>` 传进去的句柄 `owned = false`，`bitcask_embedder_llama:close/1`
> **不会**动它——只有 `model_path =>` 自己加载出来的才归它关。

### 3.2 单独用

```erlang
{ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                 #{model_path => <<"/models/qwen3-emb.gguf">>,
                                   pooling => last, n_ctx => 512}),
{ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>),   %% f32 小端 binary
{ok, Info} = bitcask_embedder_llama:info(Ctx),
ok = bitcask_embedder_llama:close(Ctx).
```

---

## 4. 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `model_path` | — | GGUF 路径。与 `handle` 二选一 |
| `handle` | — | 复用已加载的句柄（`close/1` 不会关它——谁开的谁关） |
| `pooling` | `unspecified` | `last` \| `cls` \| `mean` \| `none` \| `rank`。见 §5 |
| `n_ctx` | `2048` | **性能旋钮**，见 §6 |
| `n_threads` | `max(1, 可用核数-2)` | 见 §6 |
| `n_gpu_layers` | `0` | 本仓库默认不编 GPU 后端 |
| `dim` | — | 给了就与模型实际维度核对，不符直接报错 |
| `vector_dim` | `= dim` | MRL 截断维度（≤ dim），Erlang 侧截断 + 重归一 |
| `max_input_bytes` | `32768` | embed 前的字节级保守截断（第一道闸） |
| `truncate` | `false` | token 数超 `n_ctx` 时：`false` 报错，`true` 截断 |
| `normalize` | `true` | L2 归一化（之后余弦 = 点积） |

---

## 5. 三个会静默出错的地方（都已经在代码里挡住了，但要知道为什么）

### (甲) 池化方式配错

`pooling` 解析成 `NONE` 时 `llama_get_embeddings_seq()` 返回 NULL。失败链是：

```
GGUF 没带 modules.json → 转换时不写 {arch}.pooling_type
  → llama-model.cpp:1089  非必需 key，保持 UNSPECIFIED
  → llama-context.cpp:233-235  两边都 UNSPECIFIED → 静默退到 NONE
  → llama_get_embeddings_seq() 返回 NULL
```

NIF **在加载这一步就拒绝 NONE**，给一条能照做的错。但注意：

> ⚠️ **配成"错的那一个"（GGUF 带了错值）这条链检测不出来。** 加载会成功、嵌入
> 会成功、向量长度也对，只是语义全错。唯一的判据是自检探针——
> `test/bitcask_llama_tests.erl` 的 `self_check_semantics_test_`：近义句相似度
> 必须显著高于无关句。换模型时**跑一遍那个用例**。

对照表：Qwen3-Embedding 要 `last`，BERT/BGE 要 `cls`，E5/GTE 要 `mean`。
官方仓库的 GGUF 通常带对了，**社区重新量化上传的经常不带**。

### (乙) 向量长度用 `n_embd_out` 而不是 `n_embd`

池化后的缓冲区是按 `hparams.n_embd_out()` 分配的（`llama-context.cpp:1511`
的注释原文："use n_embd_out (not n_embd_inp)"）。带投影层的嵌入模型上两者不等，
用 `n_embd` 会读过界或少读一截，**两种坏法都不报错**。`model_info` 同时报出
`dim`（= n_embd_out，落库用的）与 `n_embd`，不一致时能一眼看见。

### (丙) 没有"静默截断"这个选项

token 数超 `n_ctx` 时默认返回 `{error, {too_many_tokens, NTok, NCtx}}`。
显式 `truncate => true` 才截断。静默截断会让调用方以为整段都被嵌入了，而那
正是"检索质量莫名其妙变差"最难查的一个来源。

同理，零范数向量返回 `{error, zero_norm}` 而不是一个全零向量——NaN/零向量在
余弦里不报错，只是让这一条永远排不上来。

---

## 6. 性能：两个旋钮，一个是断崖

实测环境：8 vCPU 容器（宿主 128 核）、`Qwen3-Embedding-0.6B-Q8_0`、`n_ctx=512`。

### `n_threads` —— 超订是断崖，不是渐变

| n_threads | 查询（5 token） | 文档（276 token） |
|---|---|---|
| 1 | 122.9 ms | 3709 ms |
| 4 | 36.1 ms | 1028 ms |
| **6** | **33.4 ms** | **936 ms** |
| 12 | 186.0 ms | 1635 ms |
| 64 | 363.0 ms | 1212 ms |
| 126 | 665.0 ms | 1675 ms |

> ⚠️ **默认值用的是 `erlang:system_info(logical_processors_available)`，不是
> `logical_processors`。** 后者报的是**宿主机**核数，不认 CPU 亲和性掩码
> （taskset / cpuset / 容器）。这台机器上两者分别是 8 和 128——按后者算出 126
> 线程，比最优**慢 20 倍**，而且没有任何报错，只是"本地嵌入怎么这么慢"。
>
> 亲和性覆盖不到 cgroup 的 CPU **配额**（`cpu.max` 那种按时间片限流的）。真跑
> 在配额容器里就显式配 `n_threads`，别指望默认值猜对。

### `n_ctx` —— 它不只是长度上限

计算图按 `n_ctx` 分配，取模型的 `n_ctx_train`（Qwen3-Embedding 是 32768）会让
每次前向都按最坏情况算：

| n_ctx | 查询（5 token） |
|---|---|
| 512 | 35.2 ms |
| 2048 | 38.2 ms |
| 8192 | 57.1 ms |

设成略大于你的切块长度。NIF 会向下钳到 `n_ctx_train`（嵌入模型超出训练长度
没有正确语义），实际生效值看 `model_info` 的 `n_ctx`。

### 并发

**一个句柄 = 一个 `llama_context` = 串行。** `llama_context` 不是线程安全的，
C++ 侧用互斥量保证正确性，同一句柄上的并发 `embed` 会排队。要并行就开多个句柄
——代价是每个句柄一份权重的内存。

`embed` 挂在 `ERL_NIF_DIRTY_JOB_CPU_BOUND` 上，不会阻塞普通调度线程。

---

## 7. 排错

```erlang
bitcask_llama_nifs:available().    %% false = 没构建 / .so 没装上
bitcask_llama_nifs:load_status().  %% load_nif 的原始原因
bitcask_llama_nifs:ensure_backend().  %% {ok, N}；N=0 就是没有匹配本机 CPU 的变体
bitcask_llama_nifs:backend_info().    %% 跑在哪个后端上
bitcask_llama_nifs:last_error().      %% llama/ggml 打的最后一条 error
```

`BITCASK_LLAMA_LOG=1` 让 llama/ggml 的日志原样透到 stderr（默认全部吞掉，只留
最近一条 error 给 `last_error/0`）。

| 症状 | 原因 |
|---|---|
| `{error, {llama_nif_unavailable, _, _}}` | 没开 `BITCASK_WITH_LLAMA` 构建 |
| `ensure_backend` 返回 `{ok, 0}` | `priv/` 里没有匹配本机 CPU 的 `libggml-cpu-*` |
| `{error, {pooling_none, _}}` | GGUF 没带 `pooling_type`，显式配 `pooling` |
| `{error, {model_not_found, _}}` | 路径不对（Erlang 侧就拦下了，没进 llama） |
| `{error, {dim_mismatch, _}}` | 配置里的 `dim` 与模型实际维度不符 |
| `{error, closed}` | 句柄已 `close/1` |
| 本地嵌入慢一个数量级 | `n_threads` 超订，见 §6 |

## 8. 测试

```sh
# (甲) 降级路径 —— 总是跑，不需要构建这个后端
rebar3 eunit --module=bitcask_llama_tests

# (乙)+(丙) 真的加载模型跑
BITCASK_WITH_LLAMA=1 BITCASK_TEST_GGUF=/models/Qwen3-Embedding-0.6B-Q8_0.gguf \
  rebar3 eunit --module=bitcask_llama_tests
```

不硬编码模型路径、不下载权重：几百 MB 的文件不属于测试依赖。
