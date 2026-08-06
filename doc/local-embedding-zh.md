# 本地嵌入后端（llama.cpp / ggml）

English version: [`local-embedding-en.md`](local-embedding-en.md)。

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
                  zen4,alderlake,sapphirerapids}.so   ← 14 个 CPU 变体（x86；ARM 上另一套）
priv/libggml.so* priv/libllama.so*
```

**这些变体是运行时按 CPU 微架构 `dlopen` 的**，不是构建期选一个。发行时必须
全带上——少发一个的表现是"那一档 CPU 的用户悄悄没有本地嵌入"，你这边永远
测不出来。`rebar3 clean` 会一并清掉。

> ⚠️ `GGML_NATIVE` 被强制设为 `OFF`。默认的 `ON` 会按**构建机**的指令集编译，
> 产物在老 CPU 上是 `SIGILL` 当场崩（在 BEAM 里就是 node 没了），不是降速。

---

## 3. 用

### 3.0 两档 embedder，只有一档需要进程

| | HTTP 档（`openai` / `anthropic`） | 内置档（`llama`） |
|---|---|---|
| 状态 | 无状态，配置就是几个字段 | 几百 MB 权重 + 非线程安全的 context |
| 并发 | 本来就该并发 | 本来就必须串行 |
| 怎么用 | `{embedder, {openai, Cfg}}`，**不需要配置任何进程** | 走 `bitcask_embedder_server` 进程 |

共享的逻辑（输入裁剪、维度校验、MRL 截断+重归一）在
`bitcask_embedder_util`，两档共用一份。

### 3.1 内置档的形态：application env + `bitcask_sup`

```erlang
%% sys.config / app env
{bitcask, [
  {embedder, #{name     => my_embedder,
               provider => {custom, bitcask_embedder_llama},
               config   => #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
                             pooling    => last,
                             n_ctx      => 512}}}
]}.
```

```erlang
%% 之后所有 cask 都只写一个名字
H1 = bitcask:open(Dir1, [read_write, {analyzer, whitespace}, {embedder, my_embedder}]),
H2 = bitcask:open(Dir2, [read_write, {analyzer, whitespace}, {embedder, my_embedder}]),

ok = bitcask:put(H1, <<"d1">>, #{text => <<"猫在垫子上睡觉"/utf8>>}),
{ok, R} = bitcask:search_vector(H1, {text, <<"猫咪在睡觉"/utf8>>}, 3).
```

集合维度仍然由 embedder 的 `vector_dim` 推出，不用也不该再写 `{vector_dim, N}`。

**没配就没有这个 child**，bitcask 不依赖 embedder。也可以不用 app env，自己
`start_link/2` 或用 `child_spec/3` 挂进你自己的 supervision tree。

> ⚠️ **配了却起不来（GGUF 路径写错、pooling 解析成 NONE …）会让整个 bitcask
> application 起不来，这是有意的。** 配置了嵌入模型就说明业务要用它，此时
> "静静地降级成没有嵌入能力"比当场死掉危险得多：前者要等到检索结果不对才发现，
> 而那时候库已经写脏了（维度和语义都不对）。
>
> 为此 `bitcask:open/2` 也**不再吞掉** `application:start` 的失败——从前那句
> `catch application:start(bitcask)` 会把它吃干净，然后照常返回一个看起来正常
> 的句柄。现在返回 `{error, {bitcask_app_start_failed, Reason}}`。

**为什么本地模型必须走进程**——三件事一次解决：

1. **权重只装一份。** `{Provider, Cfg}` 那条是每 `open` 一次建一个 ctx，也就是
   每个 cask 一份几百 MB 的权重。
2. **生命周期有主。** `bitcask:close/1` **只关 cask ref，不关 embedder**。走
   `{Provider, Cfg}` 的话模型会一直占着内存直到那个 ctx term 被 GC，而释放又会
   占住 BEAM 的资源回收线程几十到几百毫秒。进程形态下 `terminate/2` 里显式释放
   （`child_spec` 的 shutdown 给了 30 秒——几 GB 权重的 munmap 不是瞬间完成的）。
3. **串行是本来就要的。** `llama_context` 不是线程安全的。gen_server 的单进程
   语义就是这个约束本身，而且排队发生在 Erlang 消息队列里，不是让多个 dirty
   调度线程堵在一把 C 互斥量上。

`{embedder, _}` 接受 `pid()` / 注册名 / `{global, _}` / `{via, M, N}`。进程没起来
时 `open` 返回 `{error, {embedder_not_running, Ref}}`；运行中挂掉时 `put` 拿到的
是 `{error, {embedder_not_running, _}}` 而**不会把调用方一起带走**。

> ⚠️ **不要把 HTTP provider 塞进这个进程。** 它无状态、请求本来就该并发，进了
> 进程之后所有 embed 排成一条链，吞吐被锁死在单进程上。HTTP 档直接写
> `{embedder, {openai, Cfg}}`，不需要配置任何进程。

### 3.2 直接配进 `bitcask:open`（单 cask、生命周期不重要时）

```erlang
H = bitcask:open(Dir, [read_write, {analyzer, whitespace},
      {embedder, {{custom, bitcask_embedder_llama},
                  #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
                    pooling    => last,
                    n_ctx      => 512}}}]).
```

⚠️ 上面那三条限制都在：一个 cask 一份权重、`close/1` 不释放。多 cask 或长跑
服务用 §3.1。

### 3.3 单独用（不接 cask）

```erlang
{ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                 #{model_path => <<"/models/qwen3-emb.gguf">>,
                                   pooling => last, n_ctx => 512}),
{ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>),   %% f32 小端 binary
{ok, Info} = bitcask_embedder_llama:info(Ctx),
ok = bitcask_embedder_llama:close(Ctx).
```

也可以自己先加载、再把句柄交给多个 ctx / 进程复用（`handle =>` 传进去的句柄
`owned = false`，`close/1` **不会**动它——只有 `model_path =>` 自己加载出来的
才归它关）：

```erlang
{ok, _} = bitcask_llama_nifs:ensure_backend(),
{ok, M} = bitcask_llama_nifs:model_load(
            <<"/models/qwen3-emb.gguf">>, #{pooling => last, n_ctx => 512}),
{ok, Pid} = bitcask_embedder_server:start_link(
              #{provider => {custom, bitcask_embedder_llama},
                config   => #{handle => M}}),
%% ... 用完
ok = bitcask_embedder_server:stop(Pid),
ok = bitcask_llama_nifs:model_close(M).   %% 谁开的谁关
```

### 3.4 GPU（NVIDIA CUDA / Vulkan）

bitcask 是跑在服务器上的产品，取舍是**性能优先，体积不是约束**。

**构建期探测 SDK，运行期探测显卡** —— 这两件事在不同的机器上发生，所以分开做：
构建机决定"编进哪些后端"，目标机上由 Erlang **自己**决定"用哪个后端"，不需要
脚本、也不需要按机器改配置。

#### 构建期 vs 运行期：分开问

这是两个不同的问题，而且经常发生在**不同的机器**上：

| | 问什么 | 谁回答 | 在哪台机器 |
|---|---|---|---|
| **构建期** | 有没有 CUDA **SDK**？ | `find_package(CUDAToolkit)` | 构建机（常常没有卡） |
| **运行期** | 有没有对应的**卡**？ | ggml 枚举到的设备 | 部署机（常常没有 toolkit） |

构建期的答案会**烧进 .so**，运行期能问出来：

```erlang
{ok, B} = bitcask_llama_nifs:build_info().
%% #{cuda_built => true, cuda_version => <<"12.4">>,
%%   cuda_archs => <<"50-virtual,61-virtual,...,90-virtual">>}

{ok, R} = bitcask_llama_nifs:backend_info().
%% #{count => 2, gpu_count => 1, devices => [#{type => gpu, ...}, ...]}

{ok, S} = bitcask_llama_nifs:gpu_status().   %% 把两者对到一起
%% #{status => ok | cpu_only_build | no_gpu_device | backend_not_initialized, ...}
```

> ⚠️ **只问运行期是不够的。** 看到"0 个 GPU 设备"时，如果不知道这个包编没编
> CUDA，就分不清病因——而两种病要修的东西完全不同：

| `status` | 意思 | 修什么 |
|---|---|---|
| `ok` | 编了 CUDA，也枚举到了 GPU | — |
| `cpu_only_build` | 包里根本没有 CUDA | **重新构建**（装驱动没用） |
| `no_gpu_device` | 包里有 CUDA，机器上没枚举到卡 | 装驱动 / 容器 `--gpus all` 透传 / 查 `libggml-cuda.so` 的依赖 |
| `backend_not_initialized` | 还没 `ensure_backend/0` | 先调它 |

脚本也按这条线切开——两段可以在不同机器上分别跑：

```sh
scripts/detect-llama-backends.sh --build     # 构建机：有没有 SDK
scripts/detect-llama-backends.sh --runtime   # 部署机：有没有卡 + 这个包用不用得上
scripts/detect-llama-backends.sh             # 两段都跑
```

#### 构建期：探测 SDK，决定编什么

两个 GPU 后端各自一个开关，语义一致，默认都是 `AUTO`（探测到 SDK 就编入）：

| 开关 | 需要的 SDK | 说明 |
|---|---|---|
| `BITCASK_LLAMA_CUDA=AUTO\|ON\|OFF` | CUDA Toolkit（nvcc + cublas 开发包） | NVIDIA |
| `BITCASK_LLAMA_VULKAN=AUTO\|ON\|OFF` | Vulkan loader + `glslc` + SPIRV-Headers | AMD / Intel / 也能跑 N 卡 |

两个可以同时开。发布构建请用 `ON`——`AUTO` 在缺 SDK 的机器上会**悄悄**产出纯 CPU
的包，而两种包长得一模一样。

> ⚠️ Vulkan 的 `AUTO` 必须把**三个**依赖都确认到位才开：ggml-vulkan 的
> CMakeLists 里 `find_package(Vulkan COMPONENTS glslc REQUIRED)` 与
> `find_package(SPIRV-Headers CONFIG REQUIRED)` 都是 `REQUIRED`，只探到一个就
> 打开 `GGML_VULKAN` 会**直接把构建炸掉**——而 AUTO 的全部意义是"没有就安静地
> 不编"。

`scripts/detect-llama-backends.sh` 是**构建期工具**：CMake 只会说"没找到"，它会
说**缺哪个包**，并给出建议的构建命令。

#### 运行期：Erlang 自己决定用哪个后端

部署到目标机之后不需要脚本，也不需要按机器改配置：

```erlang
%% 默认就是 backend => auto
{ok, M} = bitcask_llama_nifs:model_load(Path, #{pooling => last, n_ctx => 512}).
```

`auto` 按 **CUDA > Vulkan > CPU** 的顺序挑第一个**真的有 GPU** 的后端族。顺序不是
随手定的：同一张 N 卡上 CUDA 路径比 Vulkan 快且成熟，Vulkan 是给没有 CUDA 的卡
兜底的。`n_gpu_layers` 默认也是 auto（有 GPU 就全卸载，没有就 0）。

也可以强制：`backend => cuda | vulkan | cpu`。未知取值报
`{error, {bad_backend, _}}` 而不是静默当成默认值。

> ⚠️ **只选一族是正确性要求，不是策略。** CUDA 与 Vulkan 同时编进包里时，两者会
> **各自枚举同一张物理卡**——一张 4090 会以 `CUDA0` 和 `Vulkan0` 两个设备出现。
> `llama_model_params.devices` 为 NULL 时"使用全部可用设备"，于是 llama 会把同
> 一张卡当成两张去切分模型层。表现不是报错，是显存被重复占用 + 莫名其妙的慢或
> OOM。

#### 多卡：一卡跑全部 layer，N 个 instance（数据并行）

**不会自动做多卡负载，这是有意的。** llama 的 `split_mode` 默认是 `LAYER`——把
模型的层切到所有卡上（模型并行）。对**嵌入模型**那是反优化：

- 0.6B 权重一张卡装得下，切开之后每层边界都要跨卡传输，而一次前向本来只有几十毫秒；
- 更要命的是**一个 `llama_context` 同时只服务一次前向**，切完之后 N 张卡仍然只
  在处理 1 个请求——等于把 N 张卡的算力当 1 张用。

要的是**数据并行**：一卡跑全部 layer，N 个 instance 各占一卡，N 个请求真并发。

```
   请求A → worker_0 → [卡0: 全部 layer]
   请求B → worker_1 → [卡1: 全部 layer]     ← 真并发
   请求C → worker_2 → [卡2: 全部 layer]
```

单卡显存占用仍是**一份**权重（各在各的卡上），不是 N 份叠在一张卡上。

```erlang
{bitcask, [{embedder,
    #{name      => my_embedder,
      provider  => {custom, bitcask_embedder_llama},
      instances => [0, 1, 2, 3],     %% 4 卡，各一个 instance
      config    => #{model_path => <<"...gguf">>, pooling => last}}}]}.
```

`instances` 只接受**显式的卡（组）列表**：

| 写法 | 含义 |
|---|---|
| `[0, 1, 2, 3]` | 4 个 instance，各占 1 张卡（模型单卡装得下，**首选**） |
| `[[0,1], [2,3]]` | 2 个 instance，各横跨 2 张卡（单卡装不下时） |
| `[[0,1,2,3]]` | 1 个 instance 跨 4 张卡（极大模型，退化成无并发） |

扁平写法是"每组一张卡"的简写。组内多于一张时 `split_mode` 缺省自动变成 `layer`；
可在 `config` 里显式覆盖。⚠️ `split_mode => none` 配多张卡是自相矛盾，会被当场
拒绝（而不是默默只用第一张）。

> ⚠️ **不提供 `auto`（按机器上的卡数自动开）是有意的**：共享机器上别的租户也在
> 用 GPU，一个被嵌入的库默认把整机的卡全占了不合适。要用哪几张由部署方写明。
>
> ⚠️ 同一张卡出现在两个 instance 里会被拒绝——两份权重挤一张卡互相抢显存，而
> 表现只是"莫名其妙的 OOM 或慢"。

**热路径上没有协调者。** `bitcask_embedder_pool` 是个 **supervisor**，不转发任何
`embed`：worker 用稳定注册名（`my_embedder_0` / `_1` …）注册，调用方拿到名字列表
后**直接打 worker**。让一个进程去 `gen_server:call` worker 的话，那个进程自己就
成了新的串行点，N 个 worker 等于白开。选谁：取消息队列最短的那个（worker 是串行
的，队列长度就是它欠的活）。

> ⚠️ **启动是串行的**：supervisor 顺序起 child，每个在 init 里同步加载模型。
> N 个 instance = N 次加载（0.6B 实测 542 ms/次，8 卡 ≈ 4.3 s；8B 会是几十秒）。
> 故意没改成并行/懒加载——那样 worker 的启动失败会绕过 supervisor 的启动期检查，
> 而「配了 embedder 却起不来就让 application 死」这条策略正是靠启动期同步失败才
> 成立的。用容量换确定性。

#### 单卡装不下怎么办

三条出路，按优先级：

1. **部分卸载（单卡，首选）**——`n_gpu_layers => N` 给具体数字，能塞多少层塞多少，
   剩下的留 CPU。塞进 80% 的层通常已经拿到大部分加速。
2. **模型并行（跨卡）**——`instances => [[0,1]]`，一个 instance 横跨 2 张卡。代价
   是这一组卡同时只服务一个请求，拿并发换容量。
3. **换量化档**——Q8 → Q4 直接砍一半显存。这是你的选择，库不替你做。

加载前会做一次**粗检**（GGUF 文件大小 vs 组内可用显存之和），明显装不下时提前报：

```erlang
{error, {model_too_large, <<"GGUF is 8.2 GiB but the selected 1 GPU(s) have 5.6 GiB free. "
                            "Options: n_gpu_layers => N ... or split_mode => layer ...">>}}
```

> ⚠️ **只是粗检，不是精确预测，也绝不用它去自动决定 `n_gpu_layers`。** llama 的
> 实际占用还包括 compute buffer 与 KV cache，都随 `n_ctx` / `n_batch` 变。它的定位
> 是"明显装不下时提前拦住并指出出路"——真正的判据仍然是 llama 自己那次尝试。
> 自动算 N 的代价是静默地少卸载几层，又是一种没人发现的慢。
>
> 不做这一步的话，装不下的表现是：llama OOM → 回落重试 `ngl=0` → **整体退回纯
> CPU**，90% 本来装得下的层被白白挪回 CPU。

#### 两件与部署有关的事

**(1) CUDA 运行时随包走。** `GGML_STATIC` 与我们必须开的 `BUILD_SHARED_LIBS=ON`
冲突（前者会加全局 `-static`），所以 `libggml-cuda.so` 是**动态**链
cudart / cublas / cublasLt 的。默认 `BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=ON` 会把
这三个库平铺进 `priv/`，和它们的使用者并排、靠 `$ORIGIN` 解析。

> cuBLAS 确实很大（CUDA 12 下几百 MB），但换掉的是一整类"构建机上好好的、到
> 目标机就没 GPU"的故障——而且那种故障**不报错**：ggml 对后端 `dlopen` 失败是
> 容忍的，失败只是跳过，于是静默降级成纯 CPU。体积不是约束，这个交换是划算的。
> 要关掉设 `-DBITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=OFF`（那样目标机必须自己装匹配
> 版本的 CUDA 运行时）。

**(2) 驱动不随包走，也不能随包走。** `libcuda.so.1` 来自 NVIDIA 驱动，版本要与
GPU 匹配，只能由目标机提供。容器里还要透传设备（`docker --gpus all`），否则驱动
库在、GPU 却看不见。

#### CUDA 架构覆盖

因为 `GGML_NATIVE=OFF`，ggml 会编一整条线：`50/61/70/75/80-virtual` +
`86/89-real` + `90-virtual`（+ Blackwell，取决于 toolkit 版本），覆盖 Maxwell 到
Blackwell。产物大得多，但**换一台机器就没有可用 kernel** 这类事不会发生——服务器
产品的正确取舍。要收窄自己设 `-DCMAKE_CUDA_ARCHITECTURES=89-real` 之类。

#### 用

```erlang
{bitcask, [{embedder, #{name => my_embedder,
                        provider => {custom, bitcask_embedder_llama},
                        config => #{model_path => <<"/models/qwen3-emb.gguf">>,
                                    pooling    => last,
                                    n_ctx      => 512}}}]}.
```

`backend` 与 `n_gpu_layers` 默认都是 auto —— 有卡就用，没卡就 CPU，**不用改配置**。

#### ⚠️ 加载之后一定要查一次有没有悄悄回落

```erlang
{ok, I} = bitcask_embedder_llama:info(Ctx),
maps:with([gpu_layers_requested, gpu_layers_effective,
           fell_back_to_cpu, gpu_fallback_reason], I).
```

显存不够时 NIF 会**自动回落纯 CPU 而不是报错**（宁可慢也别不能用），但回落是
可观测的。三种情形：

| 情形 | `gpu_layers_effective` | `fell_back_to_cpu` | 说明 |
|---|---|---|---|
| `backend => cpu`（明确要 CPU） | 0 | `false` | 不是降级 |
| auto，但这台机器没有 GPU | 0 | `false` | **正常的自动决策**，不是故障；`gpu_fallback_reason` 仍会说明为什么 |
| 显式要了 GPU，包/机器没有 | **0** | **`true`** | 原因按**请求的那一族**给 |
| 要了，显存不够 | **0** | **`true`** | 带 llama 的原话 |
| 成功 | = requested | `false` | `backend` = `CUDA`/`Vulkan`，`gpu_device` = 设备名 |

> ⚠️ 原因是**按请求的那一族**判的：包里编了 Vulkan 没编 CUDA 而你要 `cuda`，
> 说"有 GPU 后端但没设备"是错的——你要的那个后端压根不在包里。两种要修的东西
> 不同（重新构建 vs 装驱动）。

> ⚠️ **`gpu_layers_effective` 是按"有没有 GPU 设备"算的，不是按请求值。**
> 这不是多此一举：纯 CPU 构建上请求 `n_gpu_layers=999`，llama **不报错**——
> 没有 GPU 可用就默默一层都不卸载。按请求值上报会说"999 层在显存里"而实际是 0，
> 比不上报更糟。`gpu_offload_reporting_is_truthful_test_` 钉着这条不变式。

### 3.5 批量 embed（索引侧的吞吐杠杆）

单条路径每次前向只喂一条序列，固定开销（建图、清 KV、唤醒线程池）全摊在这一条
上。批量把 N 条塞进**一次** decode，池化后各出一个向量。

```erlang
{ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_llama},
              #{model_path => ..., pooling => last, n_ctx => 512,
                batch_size => 16}),                    %% ← 开批量
{ok, Rs} = bitcask_embedder:embed_batch(Ctx, Texts).
%% Rs = [{ok, Vec} | {error, Reason}]，顺序与输入一一对应
```

#### 返回的是**逐条**结果

外层 `{ok, _}` 只表示"这一批跑完了"，内层每条各自成败：

```erlang
{ok, [{ok, <<...>>},
      {error, empty_text},
      {error, {too_many_tokens, 2001, 512}},
      {ok, <<...>>}]}
```

> ⚠️ 一条坏文档不该让另外 63 条白算。整批失败会逼调用方要么丢掉整批、要么退化成
> 一条一条重试，两个都更差。顺序严格对应输入——调用方靠下标对回自己的 key。

#### `batch_size` 会放大显存/内存

⚠️ **llama 的 `n_ctx` 是所有序列共享的总预算**（`n_ctx_seq = n_ctx / n_seq_max`，
`llama-context.cpp:290`）。所以实现里用 `n_ctx × batch_size` 去建 context——
不这么做的话，一开批量就把**每条文本的可用长度悄悄缩小 batch_size 倍**，原本放得下
的文本开始报 `too_many_tokens`，而配置里的 `n_ctx` 一个字没变。

代价是 KV cache 与计算缓冲按 `batch_size` 线性增长。实际生效值看 `info/1` 的
`n_ctx`（每序列）/ `batch_size` / `n_batch`。

#### 传多少条都行

C++ 侧按两个上限自动切块：序列数 ≤ `batch_size`，token 总数 ≤ `n_batch`。
⚠️ 切块是**必须**的不是优化——把 1000 条一次塞进去只会拿到一个负返回值，而那个
负值不会告诉你是因为条数太多。

#### 池 + 批量

配了 `instances` 时，一批会被**拆开并行打到各个 worker**（K 张卡各跑一次批量
decode），结果按原顺序拼回。⚠️ 拆分后各段是并行发出的，否则就退化成串行地逐个
worker 喂，K 张卡里同时只有一张在算。某个 worker 那一段失败只影响那一段。

#### 实测

> ⚠️ **测量条件不干净**：测的时候机器上有**别的**满载进程（load 9.8 / 8 核）。
> 两个 arm 交错跑、取 3 次中位数，所以比值相对可信；但超订会放大"每次调用的
> 固定开销"，而那正是批量在摊薄的东西——**安静机器上倍数会明显小于下表**。
> 绝对耗时完全不可信（同一条 276 token 的文档在 §6 安静时是 890 ms）。

| 文本 | 条数 | 逐条 | 批量 | 加速 |
|---|---|---|---|---|
| 短（5 token，查询档） | 64 | 7778 ms | 1108 ms | **7.0x** |
| 中（30 token） | 32 | 27196 ms | 9517 ms | **2.9x** |

单次非交错的测量给出过 2.4x / 1.04x / 0.79x（长文本更慢），与上表矛盾——那组是
被不均匀的干扰扭曲的。**长文本档没有可信数据**。

**结论：`batch_size` 默认 1（不开），这是有意的。** 收益随文本变短而增大，而
长文本档在本机测不出可信结论。开之前在**你自己的硬件和文本长度分布上**量一遍。

`batch_size = 1` 时 `embed_batch/2` 仍然可用，只是退化成逐条 decode，结果一致、
没有加速。

#### 其它 provider

`embed_batch/2` 是 `bitcask_embedder` 的**可选**回调。provider 没实现时框架自动
退化成逐条 `embed/2`，结果形状完全一致——调用方不必知道 provider 支不支持。

**HTTP 档（`openai` / `anthropic`）也实现了原生批量**：一次请求带一个数组，
`max_batch`（默认 64）控制一次最多几条（端点对数组长度与总 token 都有上限，超了
是**整个请求**失败，所以按它切块）。

> ⚠️ **响应按 `index` 字段归位，不按返回顺序 zip。** OpenAI 兼容响应的每个对象
> 都带 `index`，而"data 与 input 同序"只是常见实现的行为、不是协议保证
> （vLLM / TEI / llama.cpp server 各家不同，并发实现尤其容易乱序）。按顺序 zip
> 的后果是**把向量配到别的文档上**——不报错、维度也对，只是检索结果从此不对，
> 而且查不出来。index 不是 `0..N-1` 的排列时宁可整批报错，也不猜映射。
>
> ⚠️ 空串在客户端就挡掉，不发给端点：OpenAI 兼容端点对数组里的空串会让**整个
> 请求**报 400，一条空文档就把同批的另外 63 条一起废掉。

解析逻辑是纯函数（`bitcask_embedder_util:parse_embedding_batch/3`），有不打网络的
单测（`test/bitcask_embedder_util_tests.erl`）——包括故意乱序返回的那一条。


---

## 4. 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `model_path` | — | GGUF 路径。与 `handle` 二选一 |
| `handle` | — | 复用已加载的句柄（`close/1` 不会关它——谁开的谁关） |
| `pooling` | `unspecified` | `last` \| `cls` \| `mean` \| `none` \| `rank`。见 §5 |
| `n_ctx` | `2048` | **性能旋钮**，见 §6 |
| `n_threads` | `max(1, 可用核数-2)` | 见 §6 |
| `backend` | `auto` | `auto`（CUDA > Vulkan > CPU）\| `cuda` \| `vulkan` \| `cpu`。见 §3.4 |
| `gpu_index` | `0` | 绑第几张卡；也可给卡组 `[0,1]` 或 `all`。多卡见 §3.4 |
| `split_mode` | `none` | `none` \| `layer` \| `row`。大模型单卡装不下才用后两个 |
| `batch_size` | `1` | 一次 decode 喂几条序列。见 §3.5；⚠️ 显存按它线性增长 |
| `n_gpu_layers` | `auto` | 有 GPU 就全卸载，没有就 0。见 §3.4 |
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
%% 构建期：这个包编进去了什么（与这台机器无关）
bitcask_llama_nifs:build_info().
%% 运行期：这台机器上真正枚举到了什么
bitcask_llama_nifs:backend_info().
%% 两者对到一起的诊断
bitcask_llama_nifs:gpu_status().

bitcask_llama_nifs:available().    %% false = 没构建 / .so 没装上
bitcask_llama_nifs:load_status().  %% load_nif 的原始原因
bitcask_llama_nifs:ensure_backend().  %% {ok, N}；N=0 就是没有匹配本机 CPU 的变体
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
| 配了 GPU 却还是慢 | 查 `info/1` 的 `fell_back_to_cpu` / `gpu_fallback_reason`，见 §3.4 |
| `gpu_status()` 返回 `cpu_only_build` | 包里没编 CUDA —— **重新构建**，装驱动没用 |
| `{error, {model_too_large, _}}` | 单卡装不下——见 §3.4「单卡装不下怎么办」的三条出路 |
| `{error, {bad_opt, {instances, duplicate_gpu}}}` | 同一张卡出现在两个 instance 里 |
| `{error, {bad_gpu_index, _}}` | `gpu_index` 超出这台机器的卡数 —— 按 `backend_info()` 的设备表开池 |
| `{error, {bad_backend, _}}` / `{error, {bad_split_mode, _}}` | 取值只能是 auto\|cuda\|vulkan\|cpu / none\|layer\|row |
| `gpu_status()` 返回 `no_gpu_device` | 包里有 CUDA 但机器上没卡 —— 装驱动 / 容器透传 / 查依赖，跑 `scripts/detect-llama-backends.sh --runtime` |

## 8. 测试

构建期 SDK 探测（**构建机**上跑；运行期不需要脚本）：

```sh
scripts/detect-llama-backends.sh
```

```sh
# (甲) 降级路径 —— 总是跑，不需要构建这个后端
rebar3 eunit --module=bitcask_llama_tests

# (乙)+(丙) 真的加载模型跑
BITCASK_WITH_LLAMA=1 BITCASK_TEST_GGUF=/models/Qwen3-Embedding-0.6B-Q8_0.gguf \
  rebar3 eunit --module=bitcask_llama_tests
```

不硬编码模型路径、不下载权重：几百 MB 的文件不属于测试依赖。
