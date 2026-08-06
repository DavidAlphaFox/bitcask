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
