%% -------------------------------------------------------------------
%% bitcask_embedder_llama:
%%   bitcask_embedder 的 provider 实现 —— **进程内**本地嵌入，走 llama.cpp。
%%
%%   与 bitcask_embedder_openai 的关系：那个把文本发给 HTTP 端点，这个在
%%   BEAM 进程里自己算。两者在 bitcask_embedder 门面下可互换：
%%
%%       {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_llama}, #{
%%           model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
%%           pooling    => last,      %% Qwen3-Embedding 要 last
%%           n_ctx      => 2048       %% 按你的切块长度设，见下
%%       }),
%%       {ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>),
%%       Dim  = bitcask_embedder:dim(Ctx),
%%       ok   = bitcask_embedder_llama:close(Ctx).
%%
%%   === ⚠️ 先读这三条，都是会咬人的 ===
%%
%%   (1) **init/1 会把整份权重装进内存，每调一次装一份。** 它不是廉价的
%%       构造函数。正确用法是**开一次、把 Ctx 传给所有需要它的进程**（NIF
%%       资源是普通 term，跨进程传递安全）。要复用已有句柄用 handle =>。
%%
%%   (2) **同一个 Ctx 上的 embed 是串行的。** llama_context 不是线程安全的，
%%       C++ 侧用互斥量保证正确性。要并行就开多个 Ctx，代价是每个一份权重。
%%
%%   (3) **本地档不是 HTTP 档的替代品，是另开一档。** CPU 上跑得动的是 0.6B /
%%       1024 维这一类；2560 维的 4B/8B 模型在 CPU 上不现实。换档 = 落库维度
%%       变了 = 全量重建索引。别把这当成"把 url 换成 model_path"。
%%
%%   === Opts ===
%%     model_path   — GGUF 路径（binary | string）。与 handle 二选一。
%%     handle       — 已经 model_load 出来的句柄，复用它（此时不再加载权重，
%%                    close/1 也**不会**关它——谁开的谁关）。
%%     pooling      — unspecified（默认）| last | cls | mean | none | rank
%%                    ⚠️ 解析成 NONE 会在加载期被拒。Qwen3-Embedding 要 last，
%%                       BERT/BGE 要 cls，E5/GTE 要 mean。社区重新量化上传的
%%                       GGUF 经常不带 pooling_type，那时必须显式配。
%%     n_ctx        — 默认 2048。⚠️ 这是**性能旋钮**不只是长度上限：计算图按它
%%                    分配，取模型的 n_ctx_train（Qwen3-Embedding 是 32768）会
%%                    让每次前向都按最坏情况算。设成略大于你的切块长度。
%%     n_threads    — 默认 max(1, 逻辑核数 - 2)。⚠️ 满核实测比留 2 核慢一倍。
%%     backend      — auto（默认）| cuda | vulkan | cpu。**部署到目标机后由运行期
%%                    自己决策**：auto 按 CUDA > Vulkan 挑第一个真的有 GPU 的
%%                    后端族，都没有就 CPU。不需要按机器改配置。
%%     gpu_index    — 默认 0（绑第 0 张卡）。⚠️ 多卡机器上**默认只用一张**：
%%                    嵌入模型切层跨卡是反优化。多卡要的是**数据并行**——开 N 个
%%                    embedder 进程、各绑一张卡（见文件头「多卡」一节）。
%%     split_mode   — none（默认）| layer | row。只有大模型单卡装不下才用后两个。
%%     n_gpu_layers — 默认 auto（有 GPU 就全卸载，没有就 0）。也可给具体数字，
%%                    或 0 = 强制纯 CPU。
%%                    ⚠️ 显存不够会**自动回落纯 CPU 而不报错**（宁可慢也别不能
%%                       用），但回落可观测：info/1 报 backend / fell_back_to_cpu /
%%                       gpu_fallback_reason / gpu_layers_effective。加载后查一次。
%%     dim          — 可选。给了就与模型实际维度**核对**，不一致直接报错
%%                    （防的是"换了模型忘了改配置，索引静静地写进错的维度"）。
%%     vector_dim   — 可选 MRL 截断维度（≤ dim；缺省 = dim）。本地档没有服务端
%%                    可以代劳，所以是在 Erlang 侧截断 + 重新 L2 归一化。
%%     max_input_bytes — 默认 32768。embed 前的字节级保守截断（UTF-8 下字节数
%%                    ≤ N ⟹ token 数 ≤ N）。这是**第一道**闸，token 级的第二道
%%                    在下面的 truncate。
%%     truncate     — 默认 false。token 数超 n_ctx 时：false 报
%%                    {error,{too_many_tokens,NTok,NCtx}}；true 截断并继续。
%%                    ⚠️ 没有"静默截断"这个选项。
%%     normalize    — 默认 true（L2 归一化；之后余弦 = 点积）。
%%
%%   === 多卡 ===
%%
%%   **不会自动做多卡负载，这是有意的。** llama 的 split_mode 默认把模型的层切到
%%   所有卡上（模型并行），对嵌入模型是反优化：0.6B 权重一张卡装得下，切开只多出
%%   跨卡传输，还把 N 张卡的并行能力浪费在**一条串行**的请求路径上（一个
%%   llama_context 同时只服务一次前向）。
%%
%%   嵌入要的是**数据并行**：一卡一个 context，N 路并发。做法是开 N 个 embedder
%%   进程、各绑一张卡，再在上层轮询/取空闲：
%%
%%       {ok, #{devices := Devs}} = bitcask_llama_nifs:backend_info(),
%%       Gpus = [D || #{type := gpu} = D <- Devs],
%%       [bitcask_embedder_server:start_link(
%%          {local, list_to_atom("emb_" ++ integer_to_list(I))},
%%          #{provider => {custom, bitcask_embedder_llama},
%%            config   => #{model_path => Path, pooling => last,
%%                          n_ctx => 512, gpu_index => I}})
%%        || I <- lists:seq(0, length(Gpus) - 1)],
%%
%%   每个进程各占一份权重的显存（0.6B Q8_0 ≈ 640 MB，多数卡都装得下多份）。
%%   真需要模型并行（大模型单卡装不下）才配 `split_mode => layer` +
%%   `gpu_index => all`。
%%
%%   Vec 格式 = f32 小端 binary（VDim×4 字节），与 NIF 跨界 / DocValue 存储
%%   格式一致，与 openai provider 完全相同。
%% -------------------------------------------------------------------
-module(bitcask_embedder_llama).

-behaviour(bitcask_embedder).

-export([init/1, embed/2, embed_batch/2]).
-export([close/1, info/1, token_count/2]).

-define(DEFAULT_MAX_INPUT_BYTES, 32768).
%% ⚠️ 不用模型的 n_ctx_train 当默认值：见文件头 (Opts) n_ctx 那条。2048 覆盖
%% 常见的切块长度，又不至于让计算图按 32768 分配。
-define(DEFAULT_N_CTX, 2048).

%% ===================================================================
%% Provider behaviour: init/1
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) when is_map(Opts) ->
    case bitcask_llama_nifs:available() of
        false ->
            %% 构建时没开 BITCASK_WITH_LLAMA，或发行包里没带那组 .so。
            %% 这是配置问题，给一条能照做的错，别让调用方去 catch undef。
            %% 把 load_nif 的原始原因带上——"文件不存在"和"符号解析失败"
            %% （priv/ 里少了 libggml-base.so 那种）要修的东西完全不同。
            {error, {llama_nif_unavailable,
                     <<"priv/bitcask_llama.so not loaded; rebuild with "
                       "BITCASK_WITH_LLAMA=1 rebar3 compile">>,
                     bitcask_llama_nifs:load_status()}};
        true ->
            init_1(Opts)
    end.

init_1(Opts) ->
    case acquire_model(Opts) of
        {error, _} = E ->
            E;
        {ok, Model, Owned} ->
            case bitcask_llama_nifs:model_info(Model) of
                {error, _} = E ->
                    maybe_close(Model, Owned),
                    E;
                {ok, Info} ->
                    case build_ctx(Opts, Model, Owned, Info) of
                        {error, _} = E -> maybe_close(Model, Owned), E;
                        {ok, _} = Ok   -> Ok
                    end
            end
    end.

%% handle => 复用（不拥有）；否则 model_path => 加载（拥有）。
acquire_model(Opts) ->
    case maps:get(handle, Opts, undefined) of
        undefined ->
            case maps:get(model_path, Opts, undefined) of
                undefined ->
                    {error, {missing_opt, model_path}};
                Path0 ->
                    Path = to_bin(Path0),
                    case filelib:is_regular(Path) of
                        %% 先自己看一眼。让 llama 去撞不存在的路径，拿回来的是
                        %% 一条 GGUF 内部的错，指不到"你路径写错了"。
                        false -> {error, {model_not_found, Path}};
                        true  -> load_model(Path, Opts)
                    end
            end;
        H ->
            {ok, H, false}
    end.

load_model(Path, Opts) ->
    case bitcask_llama_nifs:ensure_backend() of
        {error, _} = E ->
            E;
        {ok, 0} ->
            {error, {no_ggml_backend,
                     <<"ggml loaded 0 backends from priv/; the libggml-cpu-* "
                       "variants are missing or none matched this CPU">>}};
        {ok, _N} ->
            LoadOpts = maps:with([pooling, n_threads, n_gpu_layers, backend,
                                  gpu_index, split_mode, batch_size], Opts),
            NCtx = maps:get(n_ctx, Opts, ?DEFAULT_N_CTX),
            case bitcask_llama_nifs:model_load(Path, LoadOpts#{n_ctx => NCtx}) of
                {ok, M}        -> {ok, M, true};
                {error, _} = E -> E
            end
    end.

build_ctx(Opts, Model, Owned, #{dim := Dim} = Info) ->
    case check_dims(Opts, Dim) of
        {error, _} = E ->
            E;
        {ok, VDim} ->
            case bitcask_embedder_util:validate_limits(
                   Opts, [{max_input_bytes, ?DEFAULT_MAX_INPUT_BYTES}]) of
                {error, _} = E ->
                    E;
                {ok, #{max_input_bytes := MaxIn}} ->
                    Cfg = #{handle          => Model,
                            owned           => Owned,
                            dim             => Dim,
                            vector_dim      => VDim,
                            max_input_bytes => MaxIn,
                            truncate        => maps:get(truncate, Opts, false) =:= true,
                            normalize       => maps:get(normalize, Opts, true) =/= false,
                            info            => Info},
                    {ok, #{module     => ?MODULE,
                           dim        => Dim,
                           vector_dim => VDim,
                           config     => Cfg}}
            end
    end.

%% dim 给了就核对；vector_dim 必须 ≤ dim。
%%
%% ⚠️ 这条核对是**故意严格**的：换模型忘了改配置的后果不是报错，而是索引静静地
%%    写进另一个维度的向量，等到检索结果不对才发现，那时候库已经脏了。
check_dims(Opts, ActualDim) ->
    case maps:get(dim, Opts, undefined) of
        undefined ->
            vdim(Opts, ActualDim);
        ActualDim ->
            vdim(Opts, ActualDim);
        Other ->
            {error, {dim_mismatch, [{configured, Other}, {model, ActualDim}]}}
    end.

vdim(Opts, Dim) ->
    case maps:get(vector_dim, Opts, Dim) of
        V when is_integer(V), V > 0, V =< Dim -> {ok, V};
        _                                     -> {error, {bad_opt, vector_dim}}
    end.

%% ===================================================================
%% Provider behaviour: embed/2
%%
%% 注意框架传进来的是 ctx 的 config 子 map，不是完整 ctx（与 openai 一致）。
%% ===================================================================

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{handle := M} = Cfg, Text) when is_binary(Text) ->
    MaxIn = maps:get(max_input_bytes, Cfg, ?DEFAULT_MAX_INPUT_BYTES),
    Input = bitcask_embedder_util:truncate_utf8(Text, MaxIn),
    Norm  = maps:get(normalize, Cfg, true),
    Trunc = maps:get(truncate, Cfg, false),
    case bitcask_llama_nifs:embed(M, Input, Norm, Trunc) of
        {ok, Vec} ->
            {ok, apply_mrl(Vec, Cfg)};
        {ok, Vec, {truncated, _NTok, _NCtx}} ->
            %% Trunc=true 时才可能走到这里；调用方显式选了截断，不再报错，
            %% 但**说出来**——静默截断是检索质量退化里最难查的一种。
            {ok, apply_mrl(Vec, Cfg)};
        {error, _} = E ->
            E
    end.

%% ===================================================================
%% embed_batch/2（bitcask_embedder 的可选回调）—— 一次 decode 喂多条。
%%
%% 逐条结果，顺序与输入一一对应。⚠️ 一条坏文档不该让另外 63 条白算。
%% 需要 init 时配了 batch_size > 1 才真的批量（否则退化成逐条 decode）。
%% ===================================================================
-spec embed_batch(map(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(#{handle := M} = Cfg, Texts) when is_list(Texts) ->
    MaxIn = maps:get(max_input_bytes, Cfg, ?DEFAULT_MAX_INPUT_BYTES),
    Norm  = maps:get(normalize, Cfg, true),
    Trunc = maps:get(truncate, Cfg, false),
    Inputs = [bitcask_embedder_util:truncate_utf8(T, MaxIn) || T <- Texts],
    case bitcask_llama_nifs:embed_batch(M, Inputs, Norm, Trunc) of
        {ok, Rs}       -> {ok, [apply_mrl_result(R, Cfg) || R <- Rs]};
        {error, _} = E -> E
    end.

apply_mrl_result({ok, Vec}, Cfg) -> {ok, apply_mrl(Vec, Cfg)};
apply_mrl_result({error, _} = E, _) -> E.

%% MRL 截断 + 重归一。实现在 bitcask_embedder_util——HTTP 档那条路是服务端
%% 替我们做的（请求里带 dimensions），**本地档没人代劳**，只能在 Erlang 侧做。
apply_mrl(Vec, Cfg) ->
    Dim  = maps:get(dim, Cfg),
    VDim = maps:get(vector_dim, Cfg, Dim),
    case VDim =:= Dim of
        true  -> Vec;
        false -> bitcask_embedder_util:mrl_truncate(
                   Vec, VDim, maps:get(normalize, Cfg, true))
    end.

%% ===================================================================
%% 额外 API（不在 behaviour 里）
%% ===================================================================

%% 关掉 init/1 加载的模型。传 handle 复用的 Ctx 不会关那个句柄——谁开的谁关。
%% 幂等。
-spec close(bitcask_embedder:ctx() | map()) -> ok.
close(#{config := Cfg}) -> close(Cfg);
close(#{handle := M, owned := true}) -> bitcask_llama_nifs:model_close(M);
close(#{}) -> ok.

%% 模型的实际参数（dim / n_ctx / pooling_type / 描述）。排错入口：
%% "到底加载的是哪个模型、生效的 n_ctx 是多少、池化是不是我以为的那个"。
-spec info(bitcask_embedder:ctx() | map()) -> {ok, map()} | {error, term()}.
info(#{config := Cfg}) -> info(Cfg);
info(#{handle := M})   -> bitcask_llama_nifs:model_info(M).

%% 这段文本在这个模型的分词器下是多少 token。切块参数调优用。
-spec token_count(bitcask_embedder:ctx() | map(), binary()) ->
          {ok, non_neg_integer()} | {error, term()}.
token_count(#{config := Cfg}, Text) -> token_count(Cfg, Text);
token_count(#{handle := M}, Text)   -> bitcask_llama_nifs:tokenize_count(M, Text).

%% ===================================================================
%% 内部
%% ===================================================================

maybe_close(M, true)  -> _ = bitcask_llama_nifs:model_close(M), ok;
maybe_close(_, false) -> ok.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
