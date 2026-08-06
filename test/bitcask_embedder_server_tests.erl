%% -------------------------------------------------------------------
%% bitcask_embedder_server_tests:
%%   独立 embedder 进程 + bitcask:open 收进程引用这条路。
%%
%%   ⚠️ 用 mock provider（bitcask_embedder_mock），**不依赖 llama 构建**——
%%      这条路本身与 provider 无关，混进模型加载只会让它在 CI 上跑不了。
%%      llama 那一档的进程用法见 bitcask_llama_tests。
%% -------------------------------------------------------------------
-module(bitcask_embedder_server_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MOCK, #{provider => {custom, bitcask_embedder_mock}, config => #{}}).
-define(VOPTS, [read_write, {analyzer, whitespace}]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_embsrv_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

with_server(Opts, Fun) ->
    {ok, Pid} = bitcask_embedder_server:start_link(Opts),
    try Fun(Pid)
    after bitcask_embedder_server:stop(Pid)
    end.

%% ===================================================================
%% 进程本身
%% ===================================================================

start_and_embed_test() ->
    with_server(?MOCK, fun(Pid) ->
        {ok, V} = bitcask_embedder_server:embed(Pid, <<"x x x">>),
        ?assertEqual(bitcask_embedder_mock:vec_bin([0.6, 0.8, 0.0, 0.0]), V)
    end).

spec_reports_dims_test() ->
    with_server(?MOCK, fun(Pid) ->
        {ok, Spec} = bitcask_embedder_server:spec(Pid),
        ?assertMatch(#{dim := 4, vector_dim := 4, mode := serial}, Spec),
        %% serial 模式**故意不**把真正的 ctx 交出去——交了就等于允许调用方
        %% 绕过串行，而串行正是这个进程存在的理由之一。
        ?assertNot(maps:is_key(ctx, Spec))
    end).

direct_mode_hands_out_ctx_test() ->
    with_server(?MOCK#{mode => direct}, fun(Pid) ->
        {ok, Spec} = bitcask_embedder_server:spec(Pid),
        ?assertMatch(#{mode := direct}, Spec),
        ?assert(maps:is_key(ctx, Spec))
    end).

bad_opts_test() ->
    process_flag(trap_exit, true),
    ?assertMatch({error, {missing_opt, provider}},
                 bitcask_embedder_server:start_link(#{config => #{}})),
    ?assertMatch({error, {missing_opt, config}},
                 bitcask_embedder_server:start_link(
                   #{provider => {custom, bitcask_embedder_mock}})),
    ?assertMatch({error, {bad_opt, mode}},
                 bitcask_embedder_server:start_link(?MOCK#{mode => sideways})),
    process_flag(trap_exit, false),
    ok.

%% provider 建不起来 → 进程明确 stop，不装作起来了。半死的 embedder 会让
%% 每一次 put 都在运行期才发现问题。
provider_init_failure_stops_test() ->
    process_flag(trap_exit, true),
    R = bitcask_embedder_server:start_link(
          #{provider => openai, config => #{model => <<"m">>}}),   %% 缺 url
    ?assertMatch({error, {missing_opt, url}}, R),
    process_flag(trap_exit, false),
    ok.

%% ⚠️ embedder 挂掉不该把调用方一起带走。
dead_server_returns_error_test() ->
    {ok, Pid} = bitcask_embedder_server:start_link(?MOCK),
    ok = bitcask_embedder_server:stop(Pid),
    ?assertMatch({error, {embedder_not_running, _}},
                 bitcask_embedder_server:embed(Pid, <<"x">>)),
    ?assertMatch({error, {embedder_not_running, _}},
                 bitcask_embedder_server:spec(Pid)).

unregistered_name_returns_error_test() ->
    ?assertMatch({error, {embedder_not_running, _}},
                 bitcask_embedder_server:embed(no_such_embedder_xyz, <<"x">>)).

%% ===================================================================
%% proxy provider
%% ===================================================================

proxy_needs_server_test() ->
    ?assertMatch({error, {missing_opt, server}},
                 bitcask_embedder:new({custom, bitcask_embedder_proxy}, #{})).

proxy_embeds_through_server_test() ->
    with_server(?MOCK, fun(Pid) ->
        {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                         #{server => Pid}),
        ?assertEqual(4, bitcask_embedder:dim(Ctx)),
        ?assertEqual(4, bitcask_embedder:vector_dim(Ctx)),
        ?assertEqual({ok, bitcask_embedder_mock:vec_bin([0.6, 0.8, 0.0, 0.0])},
                     bitcask_embedder:embed(Ctx, <<"x x x">>))
    end).

%% direct 模式下 embed 在**调用方**进程里算，结果必须与 serial 完全一致。
proxy_direct_mode_test() ->
    with_server(?MOCK#{mode => direct}, fun(Pid) ->
        {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                         #{server => Pid}),
        ?assertEqual({ok, bitcask_embedder_mock:vec_bin([0.6, 0.8, 0.0, 0.0])},
                     bitcask_embedder:embed(Ctx, <<"x x x">>))
    end).

%% ===================================================================
%% bitcask:open 收进程引用
%% ===================================================================

open_with_pid_test_() ->
    {timeout, 60, fun() ->
        with_server(?MOCK, fun(Pid) ->
            with_dir(fun(Dir) ->
                H = bitcask:open(Dir, ?VOPTS ++ [{embedder, Pid}]),
                ?assertMatch({_Ref, #{module := bitcask_embedder_proxy}}, H),
                ok = bitcask:put(H, <<"d1">>, #{text => <<"x x x">>}),
                ok = bitcask:put(H, <<"d2">>, #{text => <<"z z z">>}),
                {ok, R} = bitcask:search_vector(H, {text, <<"x y y">>}, 2),
                %% (1,0,0,0) 查询：d1 (0.6,0.8) = 0.6 应排在 d2 (0,0,0,1) = 0 前面
                ?assertMatch([{<<"d1">>, _, _} | _], R),
                ok = bitcask:close(H)
            end)
        end)
    end}.

open_with_registered_name_test_() ->
    {timeout, 60, fun() ->
        {ok, Pid} = bitcask_embedder_server:start_link({local, bc_test_embedder}, ?MOCK),
        try
            with_dir(fun(Dir) ->
                H = bitcask:open(Dir, ?VOPTS ++ [{embedder, bc_test_embedder}]),
                ok = bitcask:put(H, <<"d1">>, #{text => <<"x x x">>}),
                ?assertMatch({ok, [{<<"d1">>, _, _} | _]},
                             bitcask:search_vector(H, {text, <<"x">>}, 1)),
                ok = bitcask:close(H)
            end)
        after
            bitcask_embedder_server:stop(Pid)
        end
    end}.

%% 一个进程、两个 cask —— 这是这条路存在的主要理由（本地模型只装一份权重）。
two_casks_share_one_server_test_() ->
    {timeout, 60, fun() ->
        with_server(?MOCK, fun(Pid) ->
            with_dir(fun(D1) ->
                with_dir(fun(D2) ->
                    H1 = bitcask:open(D1, ?VOPTS ++ [{embedder, Pid}]),
                    H2 = bitcask:open(D2, ?VOPTS ++ [{embedder, Pid}]),
                    ok = bitcask:put(H1, <<"a">>, #{text => <<"x x x">>}),
                    ok = bitcask:put(H2, <<"b">>, #{text => <<"z z z">>}),
                    ?assertMatch({ok, [{<<"a">>, _, _}]},
                                 bitcask:search_vector(H1, {text, <<"x">>}, 1)),
                    ?assertMatch({ok, [{<<"b">>, _, _}]},
                                 bitcask:search_vector(H2, {text, <<"z z z">>}, 1)),
                    %% ⚠️ bitcask:close/1 不该动 embedder —— 它归进程管。
                    ok = bitcask:close(H1),
                    ?assertMatch({ok, _}, bitcask_embedder_server:embed(Pid, <<"x">>)),
                    ?assertMatch({ok, [{<<"b">>, _, _}]},
                                 bitcask:search_vector(H2, {text, <<"z z z">>}, 1)),
                    ok = bitcask:close(H2)
                end)
            end)
        end)
    end}.

%% embedder 没起来时 open 必须给可读的错，不是崩。
open_with_dead_server_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(Dir) ->
            ?assertMatch({error, {embedder_not_running, _}},
                         bitcask:open(Dir, ?VOPTS ++ [{embedder, no_such_embedder_xyz}]))
        end)
    end}.

%% 既不是 {Provider,Cfg} 也不是进程引用 → 仍然被拒（预建 ctx map 那条老约束）。
open_rejects_prebuilt_ctx_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(Dir) ->
            {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_mock}, #{}),
            ?assertMatch({error, {bad_embedder, _}},
                         bitcask:open(Dir, ?VOPTS ++ [{embedder, Ctx}]))
        end)
    end}.
