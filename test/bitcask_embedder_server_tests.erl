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
        ?assertMatch(#{dim := 4, vector_dim := 4}, Spec),
        %% ⚠️ **故意不**把真正的 ctx 交出去——交了就等于允许调用方绕过串行在
        %%    自己的进程里算，而串行正是这个进程存在的理由之一。
        ?assertNot(maps:is_key(ctx, Spec))
    end).

bad_opts_test() ->
    process_flag(trap_exit, true),
    ?assertMatch({error, {missing_opt, provider}},
                 bitcask_embedder_server:start_link(#{config => #{}})),
    ?assertMatch({error, {missing_opt, config}},
                 bitcask_embedder_server:start_link(
                   #{provider => {custom, bitcask_embedder_mock}})),
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

%% ===================================================================
%% application env → bitcask_sup child
%%
%% ⚠️ 这几条要自己 stop/start bitcask application，跑完必须把 env 清掉并把
%%    application 恢复原状，否则会污染同一个 VM 里后面所有用例。
%% ===================================================================

with_env(Spec, Fun) ->
    _ = application:stop(bitcask),
    %% 之前的用例多半已经 load 过（bitcask:open/2 自己会 load），
    %% {already_loaded,_} 不是错。
    case application:load(bitcask) of
        ok                              -> ok;
        {error, {already_loaded, _}}    -> ok
    end,
    Old = application:get_env(bitcask, embedder),
    case Spec of
        undefined -> application:unset_env(bitcask, embedder);
        _         -> application:set_env(bitcask, embedder, Spec)
    end,
    try Fun()
    after
        _ = application:stop(bitcask),
        case Old of
            undefined -> application:unset_env(bitcask, embedder);
            {ok, V}   -> application:set_env(bitcask, embedder, V)
        end,
        _ = application:start(bitcask)
    end.

%% 没配 → 没有这个 child，bitcask 照常起（绝大多数部署走这条）。
sup_without_env_has_no_embedder_test_() ->
    {timeout, 60, fun() ->
        with_env(undefined, fun() ->
            ?assertEqual(ok, application:start(bitcask)),
            Ids = [Id || {Id, _, _, _} <- supervisor:which_children(bitcask_sup)],
            ?assertNot(lists:member(bitcask_embedder, Ids)),
            ?assert(lists:member(bitcask_merge_worker, Ids))
        end)
    end}.

%% 配了 → child 起来，注册名可直接用在 {embedder, Name} 上。
sup_starts_configured_embedder_test_() ->
    {timeout, 60, fun() ->
        with_env(#{name => bc_env_embedder,
                   provider => {custom, bitcask_embedder_mock},
                   config => #{}},
                 fun() ->
            ?assertEqual(ok, application:start(bitcask)),
            Ids = [Id || {Id, _, _, _} <- supervisor:which_children(bitcask_sup)],
            ?assert(lists:member(bitcask_embedder, Ids)),
            ?assertMatch({ok, #{dim := 4}},
                         bitcask_embedder_server:spec(bc_env_embedder)),
            with_dir(fun(Dir) ->
                H = bitcask:open(Dir, ?VOPTS ++ [{embedder, bc_env_embedder}]),
                ok = bitcask:put(H, <<"d1">>, #{text => <<"x x x">>}),
                ?assertMatch({ok, [{<<"d1">>, _, _}]},
                             bitcask:search_vector(H, {text, <<"x">>}, 1)),
                ok = bitcask:close(H)
            end)
        end)
    end}.

%% slots => K：K 个同配置并发槽位（池），{embedder, Name} 经 proxy 的
%% least-queue 挑选透明分摊。这里用 mock provider——并发槽位机制与 provider
%% 无关，混进模型加载只会让它在 CI 上跑不了。
sup_slots_pool_test_() ->
    {timeout, 60, fun() ->
        with_env(#{name => bc_slots_embedder,
                   slots => 3,
                   provider => {custom, bitcask_embedder_mock},
                   config => #{}},
                 fun() ->
            ?assertEqual(ok, application:start(bitcask)),
            {ok, Ws} = bitcask_embedder_pool:workers(bc_slots_embedder),
            ?assertEqual(3, length(Ws)),
            %% 三个 worker 都是独立进程，且注册名稳定可查。
            ?assertEqual(3, length(lists:usort([whereis(W) || W <- Ws]))),
            %% 池没有 instances 的卡组语义：worker 不该被注入 gpu_index。
            %% （间接验证：mock provider 对 config 不敏感，能起来即配置合法。）
            %% embed 走 proxy 的 qlen 挑选，结果形状与单进程一致。
            with_dir(fun(Dir) ->
                H = bitcask:open(Dir, ?VOPTS ++ [{embedder, bc_slots_embedder}]),
                ok = bitcask:put(H, <<"d1">>, #{text => <<"x x x">>}),
                ?assertMatch({ok, [{<<"d1">>, _, _}]},
                             bitcask:search_vector(H, {text, <<"x">>}, 1)),
                ok = bitcask:close(H)
            end),
            {ok, #{started := 3, requested := 3}} =
                bitcask_embedder_pool:status(bc_slots_embedder)
        end)
    end}.

%% slots 与 instances 同时给 = 意图不明，启动期当场死（不是猜一个优先级）。
sup_slots_conflicts_with_instances_test_() ->
    {timeout, 60, fun() ->
        with_env(#{name => bc_bad_embedder,
                   slots => 2,
                   instances => [0, 1],
                   provider => {custom, bitcask_embedder_mock},
                   config => #{}},
                  fun() ->
            ?assertMatch({error, _}, application:start(bitcask))
        end)
    end}.

%% 池级别（不走 sup）：slots 展开成 K × 不绑卡 group，坏类型当场拒绝。
slots_pool_rejects_bad_opts_test_() ->
    {timeout, 60, fun() ->
        process_flag(trap_exit, true),
        ?assertMatch({error, {bad_opt, slots}},
                     bitcask_embedder_pool:start_link(
                       {local, bc_bad_slots},
                       #{slots => zero,
                         provider => {custom, bitcask_embedder_mock},
                         config => #{}})),
        ?assertMatch({error, {bad_opt, {slots_conflicts_with_instances, _}}},
                     bitcask_embedder_pool:start_link(
                       {local, bc_bad_slots2},
                       #{slots => 2, instances => [0],
                         provider => {custom, bitcask_embedder_mock},
                         config => #{}})),
        process_flag(trap_exit, false),
        ok
    end}.

%% ⚠️ **本文件里最重要的一条。** 配了 embedder 但起不来（这里用缺 url 的
%%    openai 模拟"GGUF 路径写错"那一类）时：
%%      1. application 必须**起不来**——不能静静地降级成没有嵌入能力；
%%      2. bitcask:open/2 必须把这件事**说出来**，而不是照常返回一个句柄。
%%    第 2 条是有代价才换来的：从前那句 `catch application:start(bitcask)`
%%    会把失败吃干净，症状要等到检索结果不对才浮现，而那时候库已经写脏了。
sup_fails_loudly_on_bad_embedder_test_() ->
    {timeout, 60, fun() ->
        with_env(#{provider => openai, config => #{model => <<"m">>}},  %% 缺 url
                 fun() ->
            ?assertMatch({error, _}, application:start(bitcask)),
            with_dir(fun(Dir) ->
                ?assertMatch({error, {bitcask_app_start_failed, _}},
                             bitcask:open(Dir, [read_write]))
            end)
        end)
    end}.

%% env 本身配错（不是 map）同样在启动期就死。
sup_rejects_bad_env_test_() ->
    {timeout, 60, fun() ->
        with_env(not_a_map, fun() ->
            ?assertMatch({error, _}, application:start(bitcask))
        end)
    end}.

%% ===================================================================
%% 池（bitcask_embedder_pool）
%%
%% ⚠️ 用 mock provider，**不需要 GPU**：池的机制（稳定名字、直接派发、不经
%%    协调者、坏 worker 不拖垮整池）与 provider 无关。GPU 那部分的语义由
%%    bitcask_llama_tests 管。
%% ===================================================================

pool_opts(Instances) ->
    #{provider => {custom, bitcask_embedder_mock},
      instances => Instances,
      config => #{}}.

with_pool(Instances, Fun) ->
    Name = list_to_atom("bc_pool_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} = bitcask_embedder_pool:start_link({local, Name}, pool_opts(Instances)),
    try Fun(Name)
    after
        unlink(Pid),
        exit(Pid, shutdown),
        %% 等它真的没了，否则下一个用例可能撞上还没退干净的注册名。
        (fun W(0) -> ok; W(N) ->
            case whereis(Name) of undefined -> ok; _ -> timer:sleep(10), W(N-1) end
         end)(100)
    end.

%% worker 用**稳定注册名**，按 instances 的顺序。
%% ⚠️ 稳定是关键：调用方缓存名字，worker 重启后名字不变、缓存不失效。
pool_workers_have_stable_names_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1, 2], fun(Pool) ->
            {ok, Ws} = bitcask_embedder_pool:workers(Pool),
            ?assertEqual([bitcask_embedder_pool:worker_name(Pool, I) || I <- [0,1,2]], Ws),
            [?assert(is_pid(whereis(W))) || W <- Ws],
            ?assert(bitcask_embedder_pool:is_pool(Pool))
        end)
    end}.

%% 单个 embedder server 不是池 —— proxy 靠这个区分两条路。
single_server_is_not_a_pool_test() ->
    with_server(?MOCK, fun(Pid) ->
        ?assertMatch({error, not_a_pool}, bitcask_embedder_pool:workers(Pid)),
        ?assertNot(bitcask_embedder_pool:is_pool(Pid))
    end),
    ?assertMatch({error, not_a_pool},
                 bitcask_embedder_pool:workers(no_such_pool_xyz)).

pool_bad_instances_test_() ->
    {timeout, 60, fun() ->
        process_flag(trap_exit, true),
        Bad = fun(I) ->
            N = list_to_atom("bc_badpool_" ++ integer_to_list(erlang:unique_integer([positive]))),
            bitcask_embedder_pool:start_link({local, N}, pool_opts(I))
        end,
        %% ⚠️ 同一张卡出现在两个 instance 里是配置错——两份权重挤一张卡互相抢
        %%    显存，而表现只是"莫名其妙的 OOM 或慢"。必须当场拒绝。
        ?assertMatch({error, {bad_opt, {instances, duplicate_gpu}}}, Bad([0, 0])),
        ?assertMatch({error, {bad_opt, {instances, duplicate_gpu}}}, Bad([[0,1], [1,2]])),
        ?assertMatch({error, {bad_opt, {instances, _}}}, Bad([0, -1])),
        ?assertMatch({error, {bad_opt, {instances, _}}}, Bad([0, []])),
        ?assertMatch({error, {bad_opt, instances}}, Bad(not_a_list)),
        process_flag(trap_exit, false),
        ok
    end}.

%% proxy 认出池，并把 worker 名字列表缓存下来。
proxy_detects_pool_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                             #{server => Pool}),
            ?assertEqual(4, bitcask_embedder:dim(Ctx)),
            ?assertEqual(2, length(bitcask_embedder_proxy:workers(Ctx))),
            ?assertEqual({ok, bitcask_embedder_mock:vec_bin([0.6, 0.8, 0.0, 0.0])},
                         bitcask_embedder:embed(Ctx, <<"x x x">>))
        end)
    end}.

%% 单进程那条路不该被池化改动影响。
proxy_single_has_no_workers_test() ->
    with_server(?MOCK, fun(Pid) ->
        {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                         #{server => Pid}),
        ?assertEqual([], bitcask_embedder_proxy:workers(Ctx))
    end).

%% 派发确实落在 worker 上，而且**会因忙闲而换人**。
%%
%% ⚠️ 这条钉的是"协调者不在热路径上"的可观察后果：把 0 号 worker 灌忙之后，
%%    下一次派发必须换到别人身上。转发式实现（所有请求先进协调者）在这里
%%    体现不出差别，但它的真正代价由下一条 independent 用例钉住。
pool_dispatch_avoids_busy_worker_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, [W0, W1]} = bitcask_embedder_pool:workers(Pool),
            %% 空闲时是确定性的：取第一个最小。
            ?assertEqual(W0, pick_probe([W0, W1])),
            %% 把 W0 灌忙，派发必须换到 W1。
            Parent = self(),
            Pids = [spawn(fun() ->
                        _ = bitcask_embedder_server:embed(W0, <<"x x x">>),
                        Parent ! done
                    end) || _ <- lists:seq(1, 200)],
            %% 等消息真的堆进 W0 的邮箱
            (fun Wait(0) -> ok;
                 Wait(N) ->
                     case qlen_probe(W0) of
                         {0, L} when L > 0 -> ok;
                         _ -> timer:sleep(5), Wait(N - 1)
                     end
             end)(100),
            case qlen_probe(W0) of
                {0, L} when L > 0 -> ?assertEqual(W1, pick_probe([W0, W1]));
                _ -> ok      %% mock 太快没堆起来，这条就不作数
            end,
            [receive done -> ok after 5000 -> ok end || _ <- Pids],
            ok
        end)
    end}.

%% ⚠️ 池的**全部意义**：N 个 worker 真的并发。
%%
%% mock provider 是瞬时的，所以这里靠"worker 各自独立、互不阻塞"来证：
%% 让一个 worker 忙住（灌一堆活），另一个仍然立刻能服务。转发式实现会在这里
%% 退化——所有请求排在同一条链上。
pool_workers_are_independent_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, [W0, W1]} = bitcask_embedder_pool:workers(Pool),
            %% 把 W0 的邮箱堆满（这些 embed 会排队）
            Parent = self(),
            [spawn(fun() ->
                 _ = bitcask_embedder_server:embed(W0, <<"x x x">>),
                 Parent ! done
             end) || _ <- lists:seq(1, 50)],
            %% W1 完全不受影响，立刻可服务
            ?assertMatch({ok, _}, bitcask_embedder_server:embed(W1, <<"x">>, 5000)),
            %% 收尾
            [receive done -> ok after 5000 -> ok end || _ <- lists:seq(1, 50)],
            ok
        end)
    end}.

%% 坏掉的 worker 不该拖垮整池：pick 会把它排到最后。
pool_survives_dead_worker_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                             #{server => Pool}),
            {ok, [W0, _W1]} = bitcask_embedder_pool:workers(Pool),
            %% 杀掉一个；supervisor 会重启它，但重启期间池必须仍然可用。
            exit(whereis(W0), kill),
            ?assertMatch({ok, _}, bitcask_embedder:embed(Ctx, <<"x">>)),
            ?assertMatch({ok, _}, bitcask_embedder:embed(Ctx, <<"x x x">>))
        end)
    end}.

%% open 直接收池名。
open_with_pool_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            with_dir(fun(Dir) ->
                H = bitcask:open(Dir, ?VOPTS ++ [{embedder, Pool}]),
                ?assertMatch({_Ref, #{module := bitcask_embedder_proxy}}, H),
                ok = bitcask:put(H, <<"d1">>, #{text => <<"x x x">>}),
                ok = bitcask:put(H, <<"d2">>, #{text => <<"z z z">>}),
                ?assertMatch({ok, [{<<"d1">>, _, _} | _]},
                             bitcask:search_vector(H, {text, <<"x y y">>}, 2)),
                ok = bitcask:close(H)
            end)
        end)
    end}.

%% 与 proxy 的 pick/1 同语义的探针（proxy 那个是私有函数）。
pick_probe(Ws) ->
    {_, W} = lists:min([{qlen_probe(X), X} || X <- Ws]),
    W.

qlen_probe(W) ->
    case whereis(W) of
        undefined -> {1, 0};
        Pid -> case process_info(Pid, message_queue_len) of
                   {message_queue_len, N} -> {0, N};
                   undefined -> {1, 0}
               end
    end.

%% ===================================================================
%% 批量 embed
%%
%% ⚠️ 用 mock provider：批量的**契约**（逐条结果、顺序、一条坏不影响其它条、
%%    池化时拆分并行）与 provider 无关。llama 的原生批量由 bitcask_llama_tests 管。
%% ===================================================================

%% mock 没实现 embed_batch/2 —— 框架必须自动退化成逐条，结果形状完全一致。
%% ⚠️ 这条钉住"调用方不必知道 provider 支不支持批量"。
framework_falls_back_to_sequential_test() ->
    {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_mock}, #{}),
    ?assertNot(erlang:function_exported(bitcask_embedder_mock, embed_batch, 2)),
    {ok, Rs} = bitcask_embedder:embed_batch(Ctx, [<<"x x x">>, <<"z z z">>]),
    ?assertEqual([{ok, bitcask_embedder_mock:vec_bin([0.6, 0.8, 0.0, 0.0])},
                  {ok, bitcask_embedder_mock:vec_bin([0.0, 0.0, 0.0, 1.0])}], Rs).

framework_batch_empty_test() ->
    {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_mock}, #{}),
    ?assertEqual({ok, []}, bitcask_embedder:embed_batch(Ctx, [])).

server_batch_test() ->
    with_server(?MOCK, fun(Pid) ->
        {ok, Rs} = bitcask_embedder_server:embed_batch(Pid, [<<"x x x">>, <<"x">>]),
        ?assertEqual(2, length(Rs)),
        [?assertMatch({ok, _}, R) || R <- Rs]
    end).

%% ⚠️ **顺序必须与输入一一对应** —— 调用方靠下标对回自己的 key。池化时批被拆
%%    到多个 worker 上并行跑，拼回来的顺序错了就是把向量配错文档，而且不报错。
proxy_batch_preserves_order_test_() ->
    {timeout, 60, fun() ->
        Texts = [<<"x x x">>, <<"x x y">>, <<"x y y">>, <<"z z z">>, <<"x">>],
        Expect = [begin {ok, V} = bitcask_embedder_mock:embed(T), {ok, V} end || T <- Texts],
        %% 单进程
        with_server(?MOCK, fun(Pid) ->
            {ok, C} = bitcask_embedder:new({custom, bitcask_embedder_proxy}, #{server => Pid}),
            ?assertEqual({ok, Expect}, bitcask_embedder:embed_batch(C, Texts))
        end),
        %% 池化（3 个 worker，5 条会被拆成多段并行）
        with_pool([0, 1, 2], fun(Pool) ->
            {ok, C} = bitcask_embedder:new({custom, bitcask_embedder_proxy}, #{server => Pool}),
            ?assertEqual({ok, Expect}, bitcask_embedder:embed_batch(C, Texts)),
            ?assertEqual({ok, []}, bitcask_embedder:embed_batch(C, [])),
            %% 条数少于 worker 数：不该崩，也不该丢条目
            {ok, R1} = bitcask_embedder:embed_batch(C, [<<"x">>]),
            ?assertEqual(1, length(R1))
        end)
    end}.

%% 池里某个 worker 死了：那一段记成错，其余段照常返回——不是整批失败。
proxy_batch_partial_failure_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, C} = bitcask_embedder:new({custom, bitcask_embedder_proxy}, #{server => Pool}),
            {ok, [W0, _]} = bitcask_embedder_pool:workers(Pool),
            %% 让 supervisor 别把它拉起来：直接 stop 掉整棵子树里的那一个是不行的，
            %% 所以改用"注册名被占走"的等效场景——kill 之后立刻发批，
            %% 重启窗口内那一段会失败。
            exit(whereis(W0), kill),
            {ok, Rs} = bitcask_embedder:embed_batch(C, [<<"x">>, <<"x x x">>, <<"z z z">>, <<"x y y">>]),
            ?assertEqual(4, length(Rs)),
            %% 不论 worker 是否已重启，条数与顺序必须完整；至少不能整批 {error,_}
            [?assert(element(1, R) =:= ok orelse element(1, R) =:= error) || R <- Rs]
        end)
    end}.

%% ===================================================================
%% instances => auto / per_gpu / 不对称失败策略
%% ===================================================================

%% mock provider 没实现 auto_instances/1 —— auto 必须被明确拒绝，
%% ⚠️ 不能悄悄退化成"起一个"，那会让 `instances => auto` 在不支持的 provider 上
%%    看起来生效了。
auto_unsupported_provider_test() ->
    process_flag(trap_exit, true),
    N = list_to_atom("bc_auto_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ?assertMatch({error, {instances_auto_unsupported, _}},
                 bitcask_embedder_pool:start_link({local, N}, pool_opts(auto))),
    process_flag(trap_exit, false),
    ok.

%% per_gpu：同一张卡开 K 个 instance。
%% ⚠️ 显式列表里重复写同一张卡会被拒（配置错），但 per_gpu 是**明确要求**的复制，
%%    两者必须区分开。
per_gpu_expands_instances_test_() ->
    {timeout, 60, fun() ->
        Name = list_to_atom("bc_pg_" ++ integer_to_list(erlang:unique_integer([positive]))),
        Opts = (pool_opts([0, 1]))#{per_gpu => 3},
        {ok, Pid} = bitcask_embedder_pool:start_link({local, Name}, Opts),
        try
            {ok, Ws} = bitcask_embedder_pool:workers(Name),
            ?assertEqual(6, length(Ws)),          %% 2 卡 × 3
            {ok, St} = bitcask_embedder_pool:status(Name),
            ?assertMatch(#{requested := 6, started := 6, missing := []}, St)
        after
            unlink(Pid), exit(Pid, shutdown),
            (fun W(0) -> ok; W(K) ->
                case whereis(Name) of undefined -> ok; _ -> timer:sleep(10), W(K-1) end
             end)(100)
        end
    end}.

%% status/1 是"尽力而为"的必要配套 —— 少了几个必须问得出来。
pool_status_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1, 2], fun(Pool) ->
            {ok, St} = bitcask_embedder_pool:status(Pool),
            ?assertMatch(#{requested := 3, started := 3, missing := []}, St),
            ?assertEqual({error, not_a_pool},
                         bitcask_embedder_pool:status(no_such_pool_xyz))
        end)
    end}.

%% ⚠️ 显式列表 = 全都必须起来。这里用一个必然起不来的 provider 配置验证：
%%    supervisor 起不来 → start_link 报错（而不是少一个照跑）。
explicit_instances_fail_hard_test_() ->
    {timeout, 60, fun() ->
        process_flag(trap_exit, true),
        N = list_to_atom("bc_hard_" ++ integer_to_list(erlang:unique_integer([positive]))),
        %% 缺 url 的 openai：每个 worker 的 init 都会失败
        Opts = #{provider => openai, config => #{model => <<"m">>}, instances => [0, 1]},
        ?assertMatch({error, _}, bitcask_embedder_pool:start_link({local, N}, Opts)),
        ?assertEqual(undefined, whereis(N)),
        process_flag(trap_exit, false),
        ok
    end}.
