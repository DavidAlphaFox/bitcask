%% -------------------------------------------------------------------
%% bitcask_llama_tests:
%%   本地嵌入后端（llama.cpp NIF）的 eunit。
%%
%%   === 这套测试的分档，以及为什么必须分档 ===
%%
%%   (甲) **总是跑**：NIF 没构建时的降级路径。BITCASK_WITH_LLAMA 默认关，所以
%%        CI 与绝大多数开发机走的就是这一档——它必须给出一条能照做的错，而不是
%%        undef 或崩溃。这一档是本文件存在的主要理由。
%%
%%   (乙) **NIF 装上了才跑**：后端发现（ggml 从 priv/ 找到 CPU 变体）。不需要
%%        模型文件。⚠️ 这一档能抓到"13 个变体没被搬进 priv/"那类构建事故——
%%        症状是构建全绿、devices 返回 0。
%%
%%   (丙) **给了模型才跑**：真的加载 + 嵌入。用环境变量指定 GGUF：
%%
%%            BITCASK_TEST_GGUF=/path/to/Qwen3-Embedding-0.6B-Q8_0.gguf \
%%            BITCASK_WITH_LLAMA=1 rebar3 eunit
%%
%%        不硬编码路径、不下载模型：几百 MB 的权重不属于测试依赖。
%%
%%   ⚠️ 池化配错这件事**只有 (丙) 档的自检探针能抓住**。GGUF 带了错的
%%      pooling_type 时加载会成功、嵌入会成功、向量长度也对，只是语义全错。
%%      唯一的判据是"近义句相似度显著高于无关句"。
%% -------------------------------------------------------------------
-module(bitcask_llama_tests).

-include_lib("eunit/include/eunit.hrl").

%% 自检阈值：近义 - 无关。实测 Qwen3-Embedding-0.6B 上是 0.59，取 0.15 留足余量
%% ——这是在测"池化是不是彻底配错了"，不是在测模型质量。
-define(SELFCHECK_MARGIN, 0.15).

model_path() -> os:getenv("BITCASK_TEST_GGUF").

%% ===================================================================
%% (甲) 总是跑：NIF 缺失时的降级
%% ===================================================================

load_status_shape_test() ->
    %% 不论装没装上，这两个都必须能问，且不抛异常。
    %% ⚠️ 这条同时钉住 on_load 的那个决定：load_nif 失败时 on_load 仍返回 ok，
    %%    否则 BEAM 会撤掉整个模块，连这两个函数都会是 undef。
    ?assert(is_boolean(bitcask_llama_nifs:available())),
    case bitcask_llama_nifs:load_status() of
        ok              -> ok;
        {error, _Reason} -> ok
    end.

unavailable_gives_actionable_error_test() ->
    case bitcask_llama_nifs:available() of
        true ->
            {skip, nif_present};
        false ->
            %% 必须是可读的 {error, _}，不是 undef / badarg / 崩溃。
            R = bitcask_embedder_llama:init(#{model_path => <<"/nonexistent.gguf">>}),
            ?assertMatch({error, {llama_nif_unavailable, _Msg, _Reason}}, R)
    end.

%% ===================================================================
%% (乙) NIF 装上了才跑
%% ===================================================================

backend_discovery_test_() ->
    {timeout, 60, fun() ->
        case bitcask_llama_nifs:available() of
            false -> ok;
            true ->
                {ok, N} = bitcask_llama_nifs:ensure_backend(),
                %% ⚠️ 0 个后端 = priv/ 里没有匹配本机 CPU 的 libggml-cpu-* 变体。
                %%    构建是绿的，只有跑起来才看得见——所以这条断言是构建事故的
                %%    唯一防线。
                ?assert(N > 0),
                {ok, #{count := C, devices := Devs}} = bitcask_llama_nifs:backend_info(),
                ?assertEqual(N, C),
                ?assertEqual(N, length(Devs)),
                ?assertMatch([#{name := _, description := _} | _], Devs)
        end
    end}.

ensure_backend_is_idempotent_test_() ->
    {timeout, 60, fun() ->
        case bitcask_llama_nifs:available() of
            false -> ok;
            true ->
                {ok, A} = bitcask_llama_nifs:ensure_backend(),
                {ok, B} = bitcask_llama_nifs:ensure_backend(),
                ?assertEqual(A, B)
        end
    end}.

missing_model_file_test_() ->
    {timeout, 60, fun() ->
        case bitcask_llama_nifs:available() of
            false -> ok;
            true ->
                %% 路径不存在要在 Erlang 侧就拦下来。让 llama 去撞，拿回来的是
                %% 一条 GGUF 内部的错，指不到"你路径写错了"。
                ?assertMatch({error, {model_not_found, _}},
                             bitcask_embedder_llama:init(
                               #{model_path => <<"/nonexistent/nope.gguf">>})),
                ?assertMatch({error, {missing_opt, model_path}},
                             bitcask_embedder_llama:init(#{}))
        end
    end}.

%% ===================================================================
%% (丙) 给了模型才跑
%% ===================================================================

with_model(Fun) ->
    case {bitcask_llama_nifs:available(), model_path()} of
        {true, Path} when is_list(Path) ->
            case filelib:is_regular(Path) of
                false -> ok;
                true ->
                    {ok, Ctx} = bitcask_embedder:new(
                                  {custom, bitcask_embedder_llama},
                                  #{model_path => list_to_binary(Path),
                                    pooling    => last,
                                    n_ctx      => 512}),
                    try Fun(Ctx)
                    after bitcask_embedder_llama:close(Ctx)
                    end
            end;
        _ ->
            ok
    end.

model_info_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            {ok, Info} = bitcask_embedder_llama:info(Ctx),
            #{dim := Dim, n_ctx := NCtx, pooling_type := Pool} = Info,
            ?assert(Dim > 0),
            ?assertEqual(Dim, bitcask_embedder:dim(Ctx)),
            %% n_ctx 我们要了 512，C++ 侧只向下钳，不该给回更大的值。
            ?assert(NCtx =< 512),
            %% 池化必须不是 NONE(0)——NONE 会让 llama_get_embeddings_seq 返回
            %% NULL，加载期就该被拒。
            ?assertNotEqual(0, Pool)
        end)
    end}.

embed_shape_and_norm_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            Dim = bitcask_embedder:dim(Ctx),
            {ok, V} = bitcask_embedder:embed(Ctx, <<"hello world">>),
            %% f32 小端，Dim*4 字节——与 DocValue / HNSW 的跨界格式一致。
            ?assertEqual(Dim * 4, byte_size(V)),
            %% 默认 normalize=true ⇒ 单位长度（之后余弦 = 点积）
            ?assert(abs(math:sqrt(dot(V, V)) - 1.0) < 1.0e-4)
        end)
    end}.

%% ⚠️ 本文件里唯一能抓住"池化配错"的用例，见文件头。
self_check_semantics_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            {ok, A} = bitcask_embedder:embed(Ctx, <<"猫在垫子上睡觉"/utf8>>),
            {ok, B} = bitcask_embedder:embed(Ctx, <<"一只猫正躺在毯子上打盹"/utf8>>),
            {ok, C} = bitcask_embedder:embed(Ctx, <<"量子色动力学的渐近自由"/utf8>>),
            Near = dot(A, B),
            Far  = dot(A, C),
            ?assert(Near - Far > ?SELFCHECK_MARGIN)
        end)
    end}.

%% token 数超 n_ctx：默认报错，**不静默截断**。
too_many_tokens_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            Long = binary:copy(<<"重复的文本片段。"/utf8>>, 400),
            ?assertMatch({error, {too_many_tokens, _NTok, _NCtx}},
                         bitcask_embedder:embed(Ctx, Long))
        end)
    end}.

truncate_opt_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            Handle = maps:get(handle, maps:get(config, Ctx)),
            {ok, C2} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                            #{handle => Handle, truncate => true}),
            Long = binary:copy(<<"重复的文本片段。"/utf8>>, 400),
            {ok, V} = bitcask_embedder:embed(C2, Long),
            ?assertEqual(bitcask_embedder:dim(Ctx) * 4, byte_size(V)),
            %% handle 是借来的，close 不该关掉它——下一条断言就是证据。
            ok = bitcask_embedder_llama:close(C2),
            ?assertMatch({ok, _}, bitcask_embedder:embed(Ctx, <<"still alive">>))
        end)
    end}.

%% MRL：截断到 vector_dim 之后必须**重新**归一化，否则长度不再是 1，
%% 点积当余弦用就不再是夹角。
mrl_truncation_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            Handle = maps:get(handle, maps:get(config, Ctx)),
            VDim = 256,
            {ok, C2} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                            #{handle => Handle, vector_dim => VDim}),
            ?assertEqual(VDim, bitcask_embedder:vector_dim(C2)),
            {ok, V} = bitcask_embedder:embed(C2, <<"hello">>),
            ?assertEqual(VDim * 4, byte_size(V)),
            ?assert(abs(math:sqrt(dot(V, V)) - 1.0) < 1.0e-4)
        end)
    end}.

dim_mismatch_is_rejected_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            Handle = maps:get(handle, maps:get(config, Ctx)),
            %% 换了模型忘了改配置 → 索引静静地写进另一个维度的向量。必须当场拦。
            ?assertMatch({error, {dim_mismatch, _}},
                         bitcask_embedder:new({custom, bitcask_embedder_llama},
                                              #{handle => Handle, dim => 999999})),
            ?assertMatch({error, {bad_opt, vector_dim}},
                         bitcask_embedder:new({custom, bitcask_embedder_llama},
                                              #{handle => Handle, vector_dim => 999999}))
        end)
    end}.

closed_handle_test_() ->
    {timeout, 300, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        {ok, Ctx} = bitcask_embedder:new(
                                      {custom, bitcask_embedder_llama},
                                      #{model_path => list_to_binary(Path),
                                        pooling => last, n_ctx => 512}),
                        ok = bitcask_embedder_llama:close(Ctx),
                        %% 关掉之后是可辨认的错误，不是崩溃 / use-after-free。
                        ?assertEqual({error, closed},
                                     bitcask_embedder:embed(Ctx, <<"x">>)),
                        %% 幂等
                        ok = bitcask_embedder_llama:close(Ctx)
                end;
            _ ->
                ok
        end
    end}.

empty_text_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            %% 空输入没有"正确的向量"可给，零向量在余弦里是静默失败。
            ?assertEqual({error, empty_text}, bitcask_embedder:embed(Ctx, <<>>))
        end)
    end}.

%% 构建期事实（build_info/0）与运行期事实（backend_info/0）必须**分开可问**，
%% 且 gpu_status/0 把两者对到一起时不能自相矛盾。
%%
%% ⚠️ 分开问是必须的：只看运行期的话，"0 个 GPU 设备"分不清是包里根本没编
%%    CUDA、还是包编了但这台机器没驱动 —— 前者要重新构建，后者要装驱动。
%% 本用例在带 CUDA 和纯 CPU 两种包上都成立。
build_vs_runtime_split_test_() ->
    {timeout, 60, fun() ->
        case bitcask_llama_nifs:available() of
            false -> ok;
            true ->
                %% 构建期：与这台机器无关，不需要 ensure_backend。
                {ok, B} = bitcask_llama_nifs:build_info(),
                #{cuda_built := Built, cuda_version := Ver, cuda_archs := Archs,
                  vulkan_built := VkBuilt} = B,
                ?assert(is_boolean(Built)),
                ?assert(is_boolean(VkBuilt)),
                ?assert(is_binary(Ver)),
                ?assert(is_binary(Archs)),
                %% 没编 CUDA 就不该谎报版本/架构。
                case Built of
                    false ->
                        ?assertEqual(<<>>, Ver),
                        ?assertEqual(<<>>, Archs);
                    true ->
                        ?assert(byte_size(Ver) > 0),
                        ?assert(byte_size(Archs) > 0)
                end,

                %% 运行期：ensure_backend 之后才有设备。
                {ok, _} = bitcask_llama_nifs:ensure_backend(),
                {ok, Rt} = bitcask_llama_nifs:backend_info(),
                #{count := Cnt, gpu_count := NGpu, devices := Devs} = Rt,
                ?assertEqual(Cnt, length(Devs)),
                ?assert(NGpu =< Cnt),
                %% gpu_count 必须与 devices 里 type=gpu 的条数一致，否则两个
                %% 数据源在互相打架。
                ?assertEqual(NGpu, length([D || #{type := gpu} = D <- Devs])),

                %% 合成诊断不能与两边的事实矛盾。
                {ok, S} = bitcask_llama_nifs:gpu_status(),
                AnyGpuBuilt = Built orelse VkBuilt,
                case maps:get(status, S) of
                    cpu_only_build -> ?assertEqual(false, AnyGpuBuilt);
                    ok             -> ?assert(AnyGpuBuilt), ?assert(NGpu > 0);
                    no_gpu_device  -> ?assert(AnyGpuBuilt), ?assertEqual(0, NGpu)
                end
        end
    end}.

%% 运行期后端选择：部署到目标机后由 Erlang 侧自己决定用 CUDA / Vulkan / CPU。
%%
%% ⚠️ 这里钉的不变式在**任何**机器上都成立（有卡、没卡、编了 GPU、没编）：
%%    显式 backend=cpu 一定不上 GPU；未知 backend / split_mode 报错而不是静默
%%    当成默认值；auto 在没有 GPU 时是**正常结果**而不是故障（不标 fell_back），
%%    但要留下"为什么没用上卡"的说明。
backend_selection_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true  -> run_backend_selection(list_to_binary(Path))
                end;
            _ -> ok
        end
    end}.

run_backend_selection(Path) ->
    Base = #{pooling => last, n_ctx => 512},
    %% 未知取值必须报错——静默当成默认值会让"我配了 cuda"变成一句空话。
    ?assertMatch({error, {bad_backend, _}},
                 bitcask_llama_nifs:model_load(Path, Base#{backend => opencl})),
    ?assertMatch({error, {bad_split_mode, _}},
                 bitcask_llama_nifs:model_load(Path, Base#{split_mode => tensor})),

    %% 显式 CPU：一定不上 GPU，且不算回落（是明确要求，不是降级）。
    {ok, H0} = bitcask_llama_nifs:model_load(Path, Base#{backend => cpu}),
    {ok, I0} = bitcask_llama_nifs:model_info(H0),
    ?assertEqual(<<"cpu">>, maps:get(backend_requested, I0)),
    ?assertEqual(<<>>, maps:get(backend, I0)),
    ?assertEqual(0, maps:get(gpu_layers_effective, I0)),
    ?assertEqual(false, maps:get(fell_back_to_cpu, I0)),
    ?assertMatch({ok, _}, bitcask_llama_nifs:embed(H0, <<"hi">>, true, false)),
    ok = bitcask_llama_nifs:model_close(H0),

    %% auto：结果取决于机器，但不变式处处成立。
    ok = check_auto_backend(Path, Base).

%% auto 路径的不变式。
check_auto_backend(Path, Base) ->
    {ok, H} = bitcask_llama_nifs:model_load(Path, Base),
    {ok, I} = bitcask_llama_nifs:model_info(H),
    #{backend := Backend, gpu_layers_effective := Eff,
      fell_back_to_cpu := Fell, gpu_device := Dev} = I,
    ?assertEqual(<<"auto">>, maps:get(backend_requested, I)),
    case Backend of
        <<>> ->
            %% 没挑到 GPU：一定 0 层、一定不是"回落"（auto 无卡是正常决策），
            %% 但必须留下说明。
            ?assertEqual(0, Eff),
            ?assertEqual(false, Fell),
            ?assertEqual(<<>>, Dev),
            ?assert(byte_size(maps:get(gpu_fallback_reason, I)) > 0);
        Fam ->
            %% 挑到了：族名只可能是这两个，设备名非空，且默认只绑一张卡。
            ?assert(Fam =:= <<"CUDA">> orelse Fam =:= <<"Vulkan">>),
            ?assert(byte_size(Dev) > 0),
            ?assertEqual(0, maps:get(gpu_index, I))
    end,
    ?assertMatch({ok, _}, bitcask_llama_nifs:embed(H, <<"hi">>, true, false)),
    ok = bitcask_llama_nifs:model_close(H),
    ok.

%% ⚠️ **GPU 卸载必须诚实上报。**
%%
%% 这条钉的是一个真的会撒谎的场景：纯 CPU 构建上请求 n_gpu_layers=999，llama
%% **不报错**——没有 GPU 可用就默默一层都不卸载。只按"请求值"上报的话，
%% model_info 会说 999 层在显存里而实际是 0，比不上报更糟。
%%
%% 本用例在有卡和无卡的机器上都成立：
%%   * 无 GPU → effective 必须是 0 且 fell_back_to_cpu=true，还要给出原因；
%%   * 有 GPU 且装得下 → effective = requested，fell_back_to_cpu=false；
%%   * 有 GPU 但显存不够 → 回落，effective=0 且带 llama 的原话。
%% 三种都要求 effective ≤ requested，且 effective=0 与 fell_back 同真同假。
gpu_offload_reporting_is_truthful_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true  -> run_gpu_report(list_to_binary(Path))
                end;
            _ -> ok
        end
    end}.

run_gpu_report(Path) ->
    %% 不要 GPU：不算回落。
    {ok, M0} = bitcask_llama_nifs:model_load(
                 Path, #{pooling => last, n_ctx => 512, n_gpu_layers => 0}),
    {ok, I0} = bitcask_llama_nifs:model_info(M0),
    ?assertMatch(#{gpu_layers_requested := 0, gpu_layers_effective := 0,
                   fell_back_to_cpu := false}, I0),
    ?assertEqual(<<>>, maps:get(gpu_fallback_reason, I0)),
    ok = bitcask_llama_nifs:model_close(M0),

    %% 要全部层。结果取决于这台机器，但不变式在任何机器上都成立。
    {ok, M1} = bitcask_llama_nifs:model_load(
                 Path, #{pooling => last, n_ctx => 512, n_gpu_layers => 999}),
    {ok, I1} = bitcask_llama_nifs:model_info(M1),
    #{gpu_layers_requested := Req,
      gpu_layers_effective := Eff,
      fell_back_to_cpu     := Fell,
      gpu_fallback_reason  := Reason} = I1,
    ?assertEqual(999, Req),
    %% 绝不能声称卸载了比请求更多的层。
    ?assert(Eff =< Req),
    %% effective=0 ⟺ 回落了。两者不同步就说明上报在撒谎。
    ?assertEqual(Eff =:= 0, Fell),
    %% 回落了就必须说得出为什么——"悄悄回落"正是要防的那件事。
    case Fell of
        true  -> ?assert(byte_size(Reason) > 0);
        false -> ?assertEqual(<<>>, Reason)
    end,
    %% 无论走哪条路，嵌入本身都得能用。
    ?assertMatch({ok, _}, bitcask_llama_nifs:embed(M1, <<"hello">>, true, false)),
    ok = bitcask_llama_nifs:model_close(M1).

token_count_test_() ->
    {timeout, 300, fun() ->
        with_model(fun(Ctx) ->
            {ok, N} = bitcask_embedder_llama:token_count(Ctx, <<"hello world">>),
            ?assert(N > 0),
            {ok, M} = bitcask_embedder_llama:token_count(
                        Ctx, <<"hello world hello world hello world">>),
            ?assert(M > N)
        end)
    end}.

%% ===================================================================
%% (丙') 独立 embedder 进程 —— 本地模型的推荐形态
%%
%% 进程无关的那部分（proxy / open 收进程引用 / 错误路径）在
%% bitcask_embedder_server_tests 里用 mock provider 测，不需要模型。这里只测
%% 本地模型**特有**的那两条：权重只装一份、进程退出时释放。
%% ===================================================================

server_shares_one_model_across_casks_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true  -> run_server_share(Path)
                end;
            _ -> ok
        end
    end}.

run_server_share(Path) ->
    {ok, Pid} = bitcask_embedder_server:start_link(
                  #{provider => {custom, bitcask_embedder_llama},
                    config   => #{model_path => list_to_binary(Path),
                                  pooling => last, n_ctx => 512}}),
    D1 = tmpdir(), D2 = tmpdir(),
    try
        %% info 透过 proxy/server 一路问到模型——排错时这条路必须通。
        {ok, #{dim := Dim}} = bitcask_embedder_server:info(Pid),
        ?assert(Dim > 0),

        Opts = [read_write, {analyzer, whitespace}, {embedder, Pid}],
        H1 = bitcask:open(D1, Opts),
        H2 = bitcask:open(D2, Opts),
        ok = bitcask:put(H1, <<"a">>, #{text => <<"猫在垫子上睡觉"/utf8>>}),
        ok = bitcask:put(H2, <<"b">>, #{text => <<"一只狗在奔跑"/utf8>>}),
        ?assertMatch({ok, [{<<"a">>, _, _}]},
                     bitcask:search_vector(H1, {text, <<"猫咪"/utf8>>}, 1)),

        %% ⚠️ bitcask:close/1 不该动模型——它归进程管。
        ok = bitcask:close(H1),
        ?assertMatch({ok, _}, bitcask_embedder_server:embed(Pid, <<"still alive">>)),
        ?assertMatch({ok, [{<<"b">>, _, _}]},
                     bitcask:search_vector(H2, {text, <<"狗"/utf8>>}, 1)),
        ok = bitcask:close(H2)
    after
        os:cmd("rm -rf " ++ D1 ++ " " ++ D2),
        bitcask_embedder_server:stop(Pid)
    end.

%% 进程退出 ⇒ terminate/2 释放模型。这是这条路相对 {Provider,Cfg} 的核心差别，
%% 也是唯一能证明"没泄漏"的可观测点。
server_terminate_releases_model_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        {ok, M} = bitcask_llama_nifs:model_load(
                                    list_to_binary(Path),
                                    #{pooling => last, n_ctx => 512}),
                        {ok, Pid} = bitcask_embedder_server:start_link(
                                      #{provider => {custom, bitcask_embedder_llama},
                                        config   => #{handle => M}}),
                        ?assertMatch({ok, _}, bitcask_embedder_server:embed(Pid, <<"x">>)),
                        ok = bitcask_embedder_server:stop(Pid),
                        %% handle 是借来的（owned=false），进程退出**不该**关它。
                        ?assertMatch({ok, _},
                                     bitcask_llama_nifs:embed(M, <<"x">>, true, false)),
                        ok = bitcask_llama_nifs:model_close(M),
                        ?assertEqual({error, closed},
                                     bitcask_llama_nifs:embed(M, <<"x">>, true, false))
                end;
            _ -> ok
        end
    end}.

tmpdir() ->
    D = "/tmp/bitcask_llama_" ++ os:getpid() ++ "_" ++
        integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(D),
    D.

%% ===================================================================
%% helpers
%% ===================================================================

dot(A, B) ->
    lists:sum([X * Y || {X, Y} <- lists:zip(floats(A), floats(B))]).

floats(Bin) -> [F || <<F:32/float-little>> <= Bin].

%% ===================================================================
%% 批量 embed（llama 原生：一次 decode 喂多条）
%% ===================================================================

%% ⚠️ 本组最重要的一条：**批量结果必须与逐条逐字节一致**。
%%    不一致意味着 seq_id / pos 的填法错了，而那种错**不报错**——向量看起来
%%    正常、维度也对，只是语义悄悄不对。这是唯一测得出来的方式。
batch_matches_single_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true  -> run_batch_match(list_to_binary(Path))
                end;
            _ -> ok
        end
    end}.

run_batch_match(Path) ->
    Texts = [<<"猫在垫子上睡觉"/utf8>>,
             <<"一只狗在院子里奔跑"/utf8>>,
             <<"量子色动力学的渐近自由"/utf8>>,
             <<"hello world">>],
    Base = #{model_path => Path, pooling => last, n_ctx => 512},
    {ok, C1} = bitcask_embedder:new({custom, bitcask_embedder_llama}, Base),
    Singles = [begin {ok, V} = bitcask_embedder:embed(C1, T), V end || T <- Texts],
    bitcask_embedder_llama:close(C1),

    {ok, CB} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                    Base#{batch_size => 4}),
    {ok, IB} = bitcask_embedder_llama:info(CB),
    %% ⚠️ 每条序列的 n_ctx 不能因为开了批量就缩水——llama 的 n_ctx 是所有序列
    %%    共享的总预算，实现里必须乘上 batch_size 才能维持每条 512。
    ?assert(maps:get(n_ctx, IB) >= 512),
    ?assertEqual(4, maps:get(batch_size, IB)),

    {ok, Rs} = bitcask_embedder:embed_batch(CB, Texts),
    ?assertEqual(length(Texts), length(Rs)),
    Batched = [begin {ok, V} = R, V end || R <- Rs],
    ?assertEqual(Singles, Batched),
    bitcask_embedder_llama:close(CB).

%% 逐条错误：一条坏文档不该让其它条白算，且顺序保持。
batch_per_item_errors_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        {ok, C} = bitcask_embedder:new(
                                    {custom, bitcask_embedder_llama},
                                    #{model_path => list_to_binary(Path),
                                      pooling => last, n_ctx => 512, batch_size => 4}),
                        Long = binary:copy(<<"重复的文本片段。"/utf8>>, 400),
                        {ok, Rs} = bitcask_embedder:embed_batch(
                                     C, [<<"ok one">>, <<>>, Long, <<"ok two">>]),
                        ?assertMatch([{ok, _},
                                      {error, empty_text},
                                      {error, {too_many_tokens, _, _}},
                                      {ok, _}], Rs),
                        bitcask_embedder_llama:close(C)
                end;
            _ -> ok
        end
    end}.

%% 传的条数远多于 batch_size：C++ 侧必须自动切块，一条不丢、顺序不乱。
%% ⚠️ 不切块的话 llama_decode 会拒绝整块并返回一个负值，而那个负值不会告诉你
%%    是因为条数太多。
batch_chunks_beyond_batch_size_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        {ok, C} = bitcask_embedder:new(
                                    {custom, bitcask_embedder_llama},
                                    #{model_path => list_to_binary(Path),
                                      pooling => last, n_ctx => 512, batch_size => 4}),
                        N = 13,   %% 故意不是 batch_size 的整数倍
                        Texts = [integer_to_binary(I) || I <- lists:seq(1, N)],
                        {ok, Rs} = bitcask_embedder:embed_batch(C, Texts),
                        ?assertEqual(N, length(Rs)),
                        [?assertMatch({ok, _}, R) || R <- Rs],
                        %% 逐条重算，验证切块没有把向量配错到别的位置上
                        [begin
                             {ok, V} = bitcask_embedder:embed(C, T),
                             {ok, VB} = lists:nth(I, Rs),
                             ?assertEqual(V, VB)
                         end || {I, T} <- lists:zip(lists:seq(1, N), Texts)],
                        bitcask_embedder_llama:close(C)
                end;
            _ -> ok
        end
    end}.

%% ===================================================================
%% instances => auto（provider 侧的探测）
%% ===================================================================

%% ⚠️ `auto` 在**没有可用 GPU** 时必须返回 {ok, []}（池据此退化成一个不绑卡的
%%    CPU instance），而不是报错。auto 的语义是"有什么用什么"——没卡就让整个
%%    application 起不来，那不是 auto 该有的行为。
%%    本机没有 GPU，所以这条走的正是那条降级路径；有卡的机器上它会返回卡下标。
auto_instances_test_() ->
    {timeout, 300, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        Cfg = #{model_path => list_to_binary(Path),
                                pooling => last, n_ctx => 512},
                        {ok, Groups} = bitcask_embedder_llama:auto_instances(Cfg),
                        ?assert(is_list(Groups)),
                        %% 每项都是"一卡一个 instance"的族内下标
                        [?assertMatch([I] when is_integer(I) andalso I >= 0, G)
                         || G <- Groups],
                        {ok, #{gpu_count := NGpu}} = bitcask_llama_nifs:backend_info(),
                        %% 探测出来的不可能多于机器上真有的卡
                        ?assert(length(Groups) =< NGpu),
                        %% 没卡 → 空表（池会退化成一个 CPU instance）
                        case NGpu of
                            0 -> ?assertEqual([], Groups);
                            _ -> ok
                        end
                end;
            _ -> ok
        end
    end}.

%% 池 + auto 端到端：无卡时是一个不绑卡的 instance，仍然能 embed。
pool_auto_end_to_end_test_() ->
    {timeout, 600, fun() ->
        case {bitcask_llama_nifs:available(), model_path()} of
            {true, Path} when is_list(Path) ->
                case filelib:is_regular(Path) of
                    false -> ok;
                    true ->
                        Name = list_to_atom("bc_llama_auto_" ++
                                 integer_to_list(erlang:unique_integer([positive]))),
                        {ok, Pid} = bitcask_embedder_pool:start_link(
                                      {local, Name},
                                      #{provider => {custom, bitcask_embedder_llama},
                                        instances => auto,
                                        config => #{model_path => list_to_binary(Path),
                                                    pooling => last, n_ctx => 512}}),
                        try
                            {ok, St} = bitcask_embedder_pool:status(Name),
                            %% ⚠️ 尽力而为必须配说得出来：起了几个、少了哪些
                            #{requested := Req, started := Started} = St,
                            ?assert(Started >= 1),
                            ?assert(Started =< Req),
                            {ok, Ctx} = bitcask_embedder:new(
                                          {custom, bitcask_embedder_proxy}, #{server => Name}),
                            ?assertMatch({ok, _}, bitcask_embedder:embed(Ctx, <<"hello">>))
                        after
                            unlink(Pid), exit(Pid, shutdown),
                            (fun W(0) -> ok; W(K) ->
                                case whereis(Name) of
                                    undefined -> ok; _ -> timer:sleep(10), W(K-1)
                                end
                             end)(200)
                        end
                end;
            _ -> ok
        end
    end}.
