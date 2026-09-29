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

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_embsrv_", Fun).

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
%% 等一批 spawn_monitor 起的进程全部退出，共用一个总 deadline；超时就失败。
%% 以前是 [receive done -> ok after 5000 -> ok end || ...]——超时被吞掉，
%% 消息丢了测试照样绿，最坏还能卡 N × 5 s。
await_all_down(Pids, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    lists:foreach(
      fun({_Pid, MRef}) ->
              Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
              receive {'DOWN', MRef, process, _, _} -> ok
              after Left -> erlang:error({not_all_down, TimeoutMs})
              end
      end, Pids).

pool_dispatch_avoids_busy_worker_test_() ->
    {timeout, 60, fun() ->
        with_pool([0, 1], fun(Pool) ->
            {ok, [W0, W1]} = bitcask_embedder_pool:workers(Pool),
            %% 空闲时平局随机：两个都可能，但一定是其中之一。
            {PickedIdle, _} = pick_probe([W0, W1]),
            ?assert(lists:member(PickedIdle, [W0, W1])),
            %% 把 W0 灌忙，派发必须换到 W1。
            Pids = [spawn_monitor(fun() ->
                        _ = bitcask_embedder_server:embed(W0, <<"x x x">>)
                    end) || _ <- lists:seq(1, 200)],
            %% 等消息真的堆进 W0 的邮箱
            (fun Wait(0) -> ok;
                 Wait(N) ->
                     case qlen_probe(W0) of
                         {0, L} when L > 0 -> ok;
                         _ -> timer:sleep(5), Wait(N - 1)
                     end
             end)(100),
            %% 采样合一（feedbacks/2026-09-18-embedder-pool-dispatch-flaky）：
            %% pick 判定与其依据的邮箱快照取自同一时刻。快照里 W0 确实 >0
            %% 才断言选了 W1；若 mock 在采样前排空（两个 0 平局回退首元素
            %% W0），本条自动不作数——与上面 Wait 的「没堆起来就不作数」
            %% 同一意图，但不再有「guard 采样 >0、pick 再采样已排空」的
            %% 竞态窗口（全量套件并行负载下偶发假红的根因）。
            {Picked, Loads} = pick_probe([W0, W1]),
            case maps:get(W0, Loads) of
                L when L > 0 -> ?assertEqual(W1, Picked);
                0 -> ok      %% mock 在 pick 采样前排空，这条不作数
            end,
            ok = await_all_down(Pids, 10000)
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
            Pids = [spawn_monitor(fun() ->
                        _ = bitcask_embedder_server:embed(W0, <<"x x x">>)
                    end) || _ <- lists:seq(1, 50)],
            %% W1 完全不受影响，立刻可服务
            ?assertMatch({ok, _}, bitcask_embedder_server:embed(W1, <<"x">>, 5000)),
            %% 收尾
            ok = await_all_down(Pids, 10000)
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
%% 返回 {胜者, 各 worker 采样到的邮箱长度映射}——判定与依据出自同一份
%% 快照，调用方能分辨「真选了忙的那个」和「采样后平局回退首元素」。
%% 采样合一：pick 的判定和它依据的负载快照来自同一组 process_info。
pick_probe(Ws) ->
    Probes = [{bitcask_embedder_proxy:load(X), rand:uniform(), X} || X <- Ws],
    {_, _, W} = lists:min(Probes),
    {W, maps:from_list([{X, L} || {{_, L}, _, X} <- Probes])}.

qlen_probe(W) -> bitcask_embedder_proxy:load(W).

%% ===================================================================
%% 派发必须看得见"正在算"的 worker（不只是邮箱长度）
%%
%% ⚠️ gen_server 先把请求从邮箱取走再跑 handle_call：一个正在做前向的 worker
%%    邮箱长度是 0，跟闲着的一样。旧实现只看队列长度，平局按名字取 `_0`——
%%    第二个请求排到正在忙的 `_0` 后面，旁边的 `_1` 空着。mock 是瞬时的，
%%    这里用一个会 sleep 的 provider（在本文件里现编现载）把 worker 卡在
%%    handle_call 里。
%% ===================================================================

%% 慢 provider：embed 睡 config 里的 delay 毫秒再返回 mock 的向量。
%% 现编现载，不给 test/ 多加一个模块。
slow_mock_module() ->
    Mod = bc_slow_mock_embedder,
    case code:is_loaded(Mod) of
        {file, _} -> Mod;
        false ->
            Src = [
              "-module(bc_slow_mock_embedder).",
              "-export([init/1, embed/2]).",
              "init(#{delay := D}) -> {ok, #{module => bc_slow_mock_embedder, dim => 4, config => #{delay => D}}}.",
              "embed(#{delay := D}, Text) -> timer:sleep(D), bitcask_embedder_mock:embed(Text)."
            ],
            Forms = [begin
                         {ok, Ts, _} = erl_scan:string(L),
                         {ok, F} = erl_parse:parse_form(Ts),
                         F
                     end || L <- Src],
            {ok, Mod, Bin} = compile:forms(Forms, []),
            {module, Mod} = code:load_binary(Mod, "bc_slow_mock_embedder.erl", Bin),
            Mod
    end.

pool_dispatch_sees_running_worker_test_() ->
    {timeout, 60, fun() ->
        Mod = slow_mock_module(),
        Delay = 400,
        Name = list_to_atom("bc_slowpool_" ++ integer_to_list(erlang:unique_integer([positive]))),
        {ok, Pid} = bitcask_embedder_pool:start_link(
                      {local, Name},
                      #{provider => {custom, Mod}, slots => 2,
                        config => #{delay => Delay}}),
        try
            {ok, [W0, W1] = Ws} = bitcask_embedder_pool:workers(Name),
            {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                             #{server => Name}),
            %% 第一个请求：随便落到谁身上，把它卡在 handle_call 里。
            Parent = self(),
            spawn_link(fun() -> Parent ! {first, bitcask_embedder:embed(Ctx, <<"x">>)} end),
            %% 等到恰好一个 worker 报"在算"（邮箱仍是 0）。
            Busy = (fun Wait(0) -> error(no_worker_became_busy);
                        Wait(N) ->
                            case [W || W <- Ws, bitcask_embedder_proxy:load(W) =:= {0, 1}] of
                                [B] -> B;
                                _   -> timer:sleep(5), Wait(N - 1)
                            end
                    end)(200),
            Idle = hd(Ws -- [Busy]),
            ?assertEqual({0, 0}, bitcask_embedder_proxy:load(Idle)),
            %% 核心断言：邮箱都是 0，但 pick 必须避开正在算的那个。
            ?assertEqual(Idle, bitcask_embedder_proxy:pick(Ws)),
            ?assertEqual(Idle, bitcask_embedder_proxy:pick([W1, W0])),   %% 与顺序无关
            %% 佐证：第二个请求经 proxy 走，耗时 ≈ 1 × Delay 而不是排在第一个后面的 2 ×。
            {Us, R2} = timer:tc(fun() -> bitcask_embedder:embed(Ctx, <<"x">>) end),
            ?assertMatch({ok, _}, R2),
            ?assert(Us < Delay * 1500),   %% < 1.5 × Delay（排队的话 ≥ ~1.9 ×）
            receive {first, R1} -> ?assertMatch({ok, _}, R1) after 5000 -> error(first_timeout) end
        after
            unlink(Pid),
            exit(Pid, shutdown)
        end
    end}.

%% ===================================================================
%% slots 下 n_threads 按 worker 数均分
%% ===================================================================

worker_threads_split_test() ->
    %% 8 核留 2：4 个 worker 各 1；2 个各 3；1 个拿满 6。
    ?assertEqual(1, bitcask_embedder_pool:worker_threads(8, 4)),
    ?assertEqual(3, bitcask_embedder_pool:worker_threads(8, 2)),
    ?assertEqual(6, bitcask_embedder_pool:worker_threads(8, 1)),
    %% 核比 worker 少也至少 1，绝不为 0。
    ?assertEqual(1, bitcask_embedder_pool:worker_threads(2, 4)),
    ?assertEqual(1, bitcask_embedder_pool:worker_threads(1, 1)),
    ?assertEqual(15, bitcask_embedder_pool:worker_threads(128, 8)).

%% 注入只发生在"不绑卡 + 没显式给"的 worker 上：从 child spec 里的 start 参数看。
worker_threads_injection_test_() ->
    {timeout, 30, fun() ->
        Avail = case erlang:system_info(logical_processors_available) of
                    N when is_integer(N), N > 0 -> N;
                    _ -> erlang:system_info(schedulers_online)
                end,
        Expect = bitcask_embedder_pool:worker_threads(Avail, 3),
        %% 不绑卡、没显式给 → 注入均分值
        with_slots_pool(3, #{}, fun(Sup) ->
            Cfgs = worker_cfgs(Sup),
            ?assertEqual(3, length(Cfgs)),
            ?assert(lists:all(fun(C) -> maps:get(n_threads, C) =:= Expect end, Cfgs))
        end),
        %% 显式 n_threads 原样保留
        with_slots_pool(2, #{n_threads => 7}, fun(Sup) ->
            ?assertEqual([7, 7], [maps:get(n_threads, C) || C <- worker_cfgs(Sup)])
        end),
        %% GPU 绑定（backend / gpu_index）不注入
        with_slots_pool(2, #{backend => cuda}, fun(Sup) ->
            ?assertNot(lists:any(fun(C) -> maps:is_key(n_threads, C) end, worker_cfgs(Sup)))
        end),
        with_slots_pool(2, #{gpu_index => 1}, fun(Sup) ->
            ?assertNot(lists:any(fun(C) -> maps:is_key(n_threads, C) end, worker_cfgs(Sup)))
        end)
    end}.

with_slots_pool(K, Cfg, Fun) ->
    Name = list_to_atom("bc_thrpool_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} = bitcask_embedder_pool:start_link(
                  {local, Name},
                  #{provider => {custom, bitcask_embedder_mock}, slots => K, config => Cfg}),
    try Fun(Pid)
    after unlink(Pid), exit(Pid, shutdown)
    end.

%% 每个 worker child 的 start 参数里的 config（按 index 顺序）。
worker_cfgs(Sup) ->
    Ids = lists:sort([Id || {{bc_emb_worker, _, _} = Id, _, _, _} <- supervisor:which_children(Sup)]),
    [begin
         {ok, #{start := {_, _, [_Reg, Opts]}}} = supervisor:get_childspec(Sup, Id),
         maps:get(config, Opts)
     end || Id <- Ids].

%% ===================================================================
%% 6.6.1：bitcask:put_docs/2 —— 自动 embed 走一次 embed_batch
%% ===================================================================

put_docs_batches_embed_test_() ->
    {"put_docs：5 篇里 3 篇要 embed → 恰好一次 embed_batch、零次 embed；向量写进去了",
     fun() ->
        with_dir(fun(D) ->
            H = bitcask:open(D, ?VOPTS ++ [{embedder, {{custom, bitcask_embedder_mock}, #{}}}]),
            V = bitcask_embedder_mock:vec_bin([0.0, 1.0, 0.0, 0.0]),
            Docs = [{<<"a">>, #{text => <<"x x x">>}},
                    {<<"b">>, #{text => <<"x x y">>, vector => V}},   %% 已带向量，不 embed
                    {<<"c">>, #{text => <<"x y y">>}},
                    {<<"d">>, <<"plain binary">>},                     %% 不是文档
                    {<<"e">>, #{text => <<"z z z">>}}],
            meck:new(bitcask_embedder, [passthrough]),
            try
                ?assertEqual(ok, bitcask:put_docs(H, Docs)),
                ?assertEqual(1, meck:num_calls(bitcask_embedder, embed_batch, '_')),
                ?assertEqual(0, meck:num_calls(bitcask_embedder, embed, '_')),
                %% 批里只有真正需要的三条，顺序同输入
                ?assert(meck:called(bitcask_embedder, embed_batch,
                                    ['_', [<<"x x x">>, <<"x y y">>, <<"z z z">>]]))
            after
                meck:unload(bitcask_embedder)
            end,
            [?assertMatch({ok, _}, bitcask:get(H, K)) || K <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>]],
            %% 向量确实按各自文本生成：查 "z z z" 的向量应命中 e
            {ok, Hits} = bitcask:search_vector(H, bitcask_embedder_mock:vec_bin([0.0, 0.0, 0.0, 1.0]), 1),
            ?assertEqual([<<"e">>], [K || {K, _, _} <- Hits]),
            ?assertEqual(ok, bitcask:put_docs(H, [])),
            bitcask:close(H)
        end)
     end}.

put_docs_embed_failure_writes_nothing_test_() ->
    {"put_docs：embed 整批失败 / 单条失败 → 一条都不写，报 embed_failed",
     fun() ->
        with_dir(fun(D) ->
            H = bitcask:open(D, ?VOPTS ++ [{embedder, {{custom, bitcask_embedder_mock}, #{}}}]),
            Docs = [{<<"a">>, #{text => <<"x">>}}, {<<"b">>, <<"bin">>}, {<<"c">>, #{text => <<"y">>}}],
            meck:new(bitcask_embedder, [passthrough]),
            try
                meck:expect(bitcask_embedder, embed_batch, fun(_, _) -> {error, boom} end),
                ?assertEqual({error, {embed_failed, boom}}, bitcask:put_docs(H, Docs)),
                meck:expect(bitcask_embedder, embed_batch,
                            fun(_, Ts) -> {ok, [case T of
                                                    <<"y">> -> {error, too_long};
                                                    _ -> {ok, bitcask_embedder_mock:vec_bin([1.0, 0.0, 0.0, 0.0])}
                                                end || T <- Ts]} end),
                ?assertEqual({error, {embed_failed, [{<<"c">>, too_long}]}}, bitcask:put_docs(H, Docs))
            after
                meck:unload(bitcask_embedder)
            end,
            [?assertEqual(not_found, bitcask:get(H, K)) || K <- [<<"a">>, <<"b">>, <<"c">>]],
            %% 没配 embedder 的句柄：文档原样逐条写，不碰 embedder
            bitcask:close(H),
            H2 = bitcask:open(D ++ "/kv", [read_write]),      %% 新目录：索引模式的目录 KV 模式打不开
            ?assertEqual(ok, bitcask:put_docs(H2, [{<<"p">>, <<"1">>}, {<<"q">>, <<"2">>}])),
            ?assertEqual({ok, <<"2">>}, bitcask:get(H2, <<"q">>)),
            bitcask:close(H2)
        end)
     end}.

%% ===================================================================
%% scatter：总 deadline、并发等待、残留消息、worker 没起来时重试
%% ===================================================================

%% 慢 provider 的 2-worker 池；Timeout 是 proxy ctx 的每条超时。
with_slow_pool(Delay, Timeout, Fun) ->
    Mod = slow_mock_module(),
    Name = list_to_atom("bc_slowpool_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} = bitcask_embedder_pool:start_link(
                  {local, Name},
                  #{provider => {custom, Mod}, slots => 2, config => #{delay => Delay}}),
    try
        {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
                                         #{server => Name, timeout => Timeout}),
        Fun(Name, Ctx)
    after
        unlink(Pid),
        exit(Pid, shutdown),
        (fun W(0) -> ok; W(N) ->
            case whereis(Name) of undefined -> ok; _ -> timer:sleep(10), W(N-1) end
         end)(100)
    end.

%% 各段并发等、一个总 deadline：两段都超时，总耗时≈一段的超时，迟到的结果
%% 不落进调用方信箱。⚠️ 这是回归测试，不区分新旧实现——这里 worker 自己的
%% 调用超时先到，旧收集端从没等满过；旧实现真正的问题（收集端兜底
%% T*4+60000 比单段 > 5 条时的 worker 超时还短、先放弃后残留消息）要等 60 s
%% 以上才能复现，不适合放进单测。
scatter_segments_time_out_together_test_() ->
    {timeout, 60, fun() ->
        %% 每条睡 300 ms，超时 100 ms/条 → 每段 2 条、段超时 200 ms，必超时
        with_slow_pool(300, 100, fun(_Pool, Ctx) ->
            T0 = erlang:monotonic_time(millisecond),
            {ok, Rs} = bitcask_embedder:embed_batch(Ctx, [<<"a">>, <<"b">>, <<"c">>, <<"d">>]),
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            ?assertEqual(4, length(Rs)),
            ?assertEqual([], [R || R <- Rs, element(1, R) =/= error]),
            %% 两段并发：≈200 ms；串行等会 ≥ 400 ms
            ?assert(Elapsed < 380),
            %% 等慢 worker 真的跑完，确认迟到的结果没有落进调用方信箱
            timer:sleep(700),
            {messages, Msgs} = process_info(self(), messages),
            ?assertEqual([], [M || M <- Msgs, is_tuple(M), tuple_size(M) >= 2,
                                   is_reference(element(1, M))])
        end)
    end}.

%% 某个 worker 没起来（被 kill、supervisor 还没拉起）：它分到的那段换活着的
%% worker 重试一次——整批全部成功，而不是那一段全是 embedder_not_running。
scatter_retries_segment_of_dead_worker_test_() ->
    {timeout, 60, fun() ->
        Texts = [<<"x">>, <<"x x x">>, <<"z z z">>, <<"x y y">>],
        Expect = [begin {ok, V} = bitcask_embedder_mock:embed(T), {ok, V} end || T <- Texts],
        with_pool([0, 1], fun(Pool) ->
            {ok, C} = bitcask_embedder:new({custom, bitcask_embedder_proxy}, #{server => Pool}),
            {ok, [W0, _]} = bitcask_embedder_pool:workers(Pool),
            [begin
                 case whereis(W0) of
                     undefined -> ok;
                     P -> exit(P, kill)
                 end,
                 ?assertEqual({ok, Expect}, bitcask_embedder:embed_batch(C, Texts))
             end || _ <- lists:seq(1, 20)]
        end)
    end}.
