%% -------------------------------------------------------------------
%% bitcask_llama_nifs:
%%   priv/bitcask_llama.so 的 Erlang 入口模块 —— 本地嵌入（llama.cpp / ggml）。
%%
%%   这是**第二个** NIF，与 bitcask_cpp_nifs 完全独立：核心 KV/检索不链接
%%   ggml，本模块也不碰 cask。构建默认关闭：
%%
%%       cmake -S . -B _build/cmake -DBITCASK_WITH_LLAMA=ON
%%
%%   没构建时 on_load 失败，本模块所有函数返回 {error, nif_not_loaded}
%%   （不是崩溃）——上层据此降级到 HTTP provider。
%%
%%   本模块是**低阶面**，直接映射 NIF 入口。日常用 bitcask_embedder_llama，
%%   它把这些包成 bitcask_embedder 的 provider。
%%
%%   === 生命周期 ===
%%       ok = bitcask_llama_nifs:ensure_backend(),
%%       {ok, M} = bitcask_llama_nifs:model_load(<<"/path/qwen3-emb.gguf">>, #{}),
%%       {ok, #{dim := Dim}} = bitcask_llama_nifs:model_info(M),
%%       {ok, Vec} = bitcask_llama_nifs:embed(M, <<"hello">>, true, false),
%%       ok = bitcask_llama_nifs:model_close(M).
%%
%%   ⚠️ model_close/1 要主动调。不调也不会泄漏（资源析构会收），但那段
%%      llama_free 会占住 BEAM 的资源回收线程几十到几百毫秒。
%%
%%   ⚠️ **一个句柄 = 一个 llama_context = 串行。** llama_context 不是线程安全
%%      的，C++ 侧用互斥量保证正确性，所以同一句柄上的并发 embed 会排队。
%%      要并行就开多个句柄——代价是每个句柄一份权重的内存。
%%
%%   ⚠️ **ggml 的断言失败是 abort()，会带走整个 node。** 详见
%%      cpp/llama/nif_llama.cpp 的头注释。这是"把推理放进 BEAM 进程"这个
%%      决定本身的代价，不是本模块能兜住的。
%% -------------------------------------------------------------------
-module(bitcask_llama_nifs).

-export([ensure_backend/0,
         backend_info/0,
         model_load/2,
         model_info/1,
         model_close/1,
         tokenize_count/2,
         embed/4,
         last_error/0,
         available/0,
         load_status/0]).

%% 直接对应 NIF 入口，不建议外部调用（backend_init 需要 priv 目录，
%% 用 ensure_backend/0 代替）。
-export([backend_init/1]).

-on_load(init/0).

-define(NOT_LOADED, erlang:nif_error({nif_not_loaded, ?MODULE})).

%% 池化方式 → llama_pooling_type 的整数值。unspecified = 用 GGUF 里带的。
-define(POOLING(X),
        case X of
            unspecified -> -1;
            none        -> 0;
            mean        -> 1;
            cls         -> 2;
            last        -> 3;
            rank        -> 4
        end).

-type model() :: reference().
-export_type([model/0]).

%% -------------------------------------------------------------------
%% on_load
%%
%% ⚠️ **失败也返回 ok，这是有意的。** on_load 返回非 ok 时 BEAM 会把整个模块
%%    从代码表里撤掉，之后对它的任何调用——**包括 available/0 自己**——都是
%%    `undef`。那样调用方拿到的信息就从"NIF 没装上，原因是 X"退化成"这个模块
%%    不存在"，而后者指不到任何可以修的东西（也无法与打错模块名区分）。
%%
%%    所以这里把 load_nif 的结果记进 persistent_term，模块照常加载：
%%      * 装上了 → NIF 入口替换掉下面那批占位实现；
%%      * 没装上 → 占位实现抛 {nif_not_loaded, ?MODULE}，而 available/0 与
%%        load_status/0 仍然能问出真正的原因。
%%    BITCASK_WITH_LLAMA=OFF 构建出来的发行版走的正是第二条。
%% -------------------------------------------------------------------
-define(PT_STATUS, {?MODULE, nif_load_status}).

-spec init() -> ok.
init() ->
    SoName =
        case code:priv_dir(bitcask) of
            {error, bad_name} ->
                case code:which(?MODULE) of
                    Filename when is_list(Filename) ->
                        filename:join([filename:dirname(Filename), "../priv", "bitcask_llama"]);
                    _ ->
                        filename:join("../priv", "bitcask_llama")
                end;
            Dir ->
                filename:join(Dir, "bitcask_llama")
        end,
    Status =
        case erlang:load_nif(SoName, 0) of
            ok             -> ok;
            {error, Reason} -> {error, Reason}
        end,
    persistent_term:put(?PT_STATUS, Status),
    ok.

%% -------------------------------------------------------------------
%% available/0 — NIF 是否装上了。上层用这个先问一句，别靠 catch。
%% load_status/0 — 没装上时的具体原因（load_nif 的原样返回）。
%% -------------------------------------------------------------------
-spec available() -> boolean().
available() -> load_status() =:= ok.

-spec load_status() -> ok | {error, term()}.
load_status() -> persistent_term:get(?PT_STATUS, {error, not_loaded}).

%% -------------------------------------------------------------------
%% ensure_backend/0 — 幂等，把 priv/ 交给 ggml 做后端发现。
%%
%% ⚠️ 必须传 priv 目录：C++ 侧用的是 ggml_backend_load_all_from_path，它把
%%    默认搜索路径整个**替换**掉。裸的 ggml_backend_load_all() 会按 exe 目录 /
%%    cwd / LD_LIBRARY_PATH 去猜——BEAM 的 exe 是 beam.smp、cwd 是用户的工作
%%    目录，两个都不是 priv/，必然猜不到，结果是 0 个后端。
%% -------------------------------------------------------------------
-spec ensure_backend() -> {ok, non_neg_integer()} | {error, term()}.
ensure_backend() ->
    case code:priv_dir(bitcask) of
        {error, bad_name} -> {error, {priv_dir_not_found, bitcask}};
        Dir               -> backend_init(list_to_binary(Dir))
    end.

%% -------------------------------------------------------------------
%% model_load/2
%%
%%   Opts:
%%     pooling      — unspecified（默认）| none | mean | cls | last | rank
%%                    ⚠️ 解析出来是 NONE 会被 C++ 侧当场拒绝并给一条能照做的
%%                       错：Qwen3-Embedding 要 last，BERT/BGE 要 cls，
%%                       E5/GTE 要 mean。
%%     n_threads    — 默认 max(1, 逻辑核数 - 2)。
%%                    ⚠️ 这个默认值不是保守，是实测：满核会比留 2 核**慢一倍**
%%                       （ggml 线程池自旋与调度抢在一起）。而且它是平台相关的
%%                       经验值，必要时覆盖。
%%     n_ctx        — 默认 0 = 用模型的 n_ctx_train。
%%                    ⚠️ 这是**真的性能旋钮**：计算图按它分配，Qwen3-Embedding
%%                       的 n_ctx_train 是 32768，全开会让每次前向都按最坏情况
%%                       算。按你实际的切块长度设小得多的值。C++ 侧会向下钳到
%%                       n_ctx_train，实际生效值看 model_info 的 n_ctx。
%%     n_gpu_layers — 默认 0（纯 CPU）。本仓库默认不编 GPU 后端。
%% -------------------------------------------------------------------
-spec model_load(binary(), map()) -> {ok, model()} | {error, term()}.
model_load(Path, Opts) when is_binary(Path), is_map(Opts) ->
    Pooling = ?POOLING(maps:get(pooling, Opts, unspecified)),
    Threads = maps:get(n_threads, Opts, default_threads()),
    NCtx    = maps:get(n_ctx, Opts, 0),
    Ngl     = maps:get(n_gpu_layers, Opts, 0),
    model_load(Path, Pooling, Threads, NCtx, Ngl).

%% 留 2 核：见 model_load/2 的注释。核数拿不到时退到 1（宁可慢，也不要因为
%% 超订而慢一个数量级——下面那张表说明代价是不对称的）。
%%
%% ⚠️ **必须用 logical_processors_available，不是 logical_processors。**
%%    前者认 CPU 亲和性掩码（taskset / cpuset / 容器），后者报的是**宿主机**的
%%    核数。本机实测：8 vCPU 的容器里 logical_processors=128、
%%    logical_processors_available=8。按前者算出 126 线程，实测（Qwen3-Embedding
%%    0.6B Q8_0、5 token 查询）：
%%
%%        n_threads=4   36.1 ms      n_threads=16   229.2 ms
%%        n_threads=6   33.4 ms  ←   n_threads=64   363.0 ms
%%        n_threads=12 186.0 ms       n_threads=126  665.0 ms   ← 旧默认值
%%
%%    **20 倍**，而且没有任何报错——只是"本地嵌入怎么这么慢"。ggml 的线程池
%%    自旋与调度抢在一起，超订之后是断崖不是渐变。
%%
%% ⚠️ 亲和性覆盖不到 cgroup 的 CPU **配额**（cpu.max 那种按时间片限流的）：那种
%%    环境下三个 system_info 都会报宿主机核数。真跑在配额容器里就显式配
%%    n_threads，别指望这里猜对。
-spec default_threads() -> pos_integer().
default_threads() ->
    Ncpu = first_int([erlang:system_info(logical_processors_available),
                      erlang:system_info(logical_processors_online),
                      erlang:system_info(logical_processors)]),
    case Ncpu of
        N when is_integer(N), N > 2 -> N - 2;
        _                           -> 1
    end.

%% system_info 的这三个都可能返回 unknown。
first_int([N | _]) when is_integer(N), N > 0 -> N;
first_int([_ | T])                           -> first_int(T);
first_int([])                                -> 1.

%% -------------------------------------------------------------------
%% embed/4 — Normalize=true 时做 L2 归一化（之后余弦 = 点积，检索侧省一步）。
%%
%%   Truncate=false（推荐）：token 数超 n_ctx 直接
%%       {error, {too_many_tokens, NTok, NCtx}}
%%   Truncate=true：截断并在返回值里说出来
%%       {ok, Vec, {truncated, NTok, NCtx}}
%%
%%   ⚠️ 没有"静默截断"这个选项，是有意的：静默截断会让调用方以为整段都被
%%      嵌入了，而那正是"检索质量莫名其妙变差"的一个来源。
%%
%%   Vec = f32 小端 binary（dim*4 字节），与 DocValue / HNSW 跨界格式一致。
%% -------------------------------------------------------------------
-spec embed(model(), binary(), boolean(), boolean()) ->
          {ok, binary()} | {ok, binary(), {truncated, integer(), integer()}} | {error, term()}.

%% =============================================================================
%% NIF 占位实现。加载成功后全部被 C++ 替换。
%% =============================================================================
backend_init(_PrivDir)            -> ?NOT_LOADED.
backend_info()                    -> ?NOT_LOADED.
model_load(_P, _Pool, _T, _C, _G) -> ?NOT_LOADED.
model_info(_M)                    -> ?NOT_LOADED.
model_close(_M)                   -> ?NOT_LOADED.
tokenize_count(_M, _Text)         -> ?NOT_LOADED.
embed(_M, _Text, _Norm, _Trunc)   -> ?NOT_LOADED.
last_error()                      -> ?NOT_LOADED.
