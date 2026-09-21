%% -------------------------------------------------------------------
%% graphdb_txn_tests:
%%   graphdb 事务式 API（X1-5，bitcask_txn 之上）覆盖：
%%     - put_edge_txn   五键同批落地、提交前不可见、upsert 不动计数
%%     - del_edge_txn   幂等、计数回落、同事务加删净零
%%     - 并发计数       N 进程并发对同一 hub 加边 → 度数精确（直通 API 做
%%                      不到的那件事）
%%     - abort / 顶点   中止不落盘；put/get_vertex_txn
%%     - degree 回退    计数键缺失时只数该 etype（顺手修的直通 degree/3）
%% -------------------------------------------------------------------
-module(graphdb_txn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(G, graphdb).

with_dir(Fun) ->
    catch application:load(bitcask),
    {ok, _} = application:ensure_all_started(bitcask),
    Dir = "/tmp/graphdb_txn_tests_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

-define(FAST, [{sync, no_sync}]).

dsts({ok, Edges}) -> [D || #{dst := D} <- Edges].
srcs({ok, Edges}) -> [S || #{src := S} <- Edges].

put_edge_txn_test_() ->
    {"put_edge_txn：五键同批；提交前对直通读不可见；upsert 只改 props",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            Res = ?G:transaction(R, fun(Tx) ->
                ok = ?G:put_edge_txn(Tx, 1, 7, 2, #{props => <<"p1">>}),
                ok = ?G:put_edge_txn(Tx, 1, 7, 3),
                %% 事务内读自己的写
                ?assertMatch({ok, #{props := <<"p1">>}}, ?G:edge_txn(Tx, 1, 7, 2)),
                ?assertEqual({ok, 2}, ?G:degree_txn(Tx, 1, 7)),
                %% 直通读看不到（缓冲未提交）
                ?assertEqual({error, not_found}, ?G:edge(R, 1, 7, 2)),
                ?assertEqual({ok, 0}, ?G:degree(R, 1, 7)),
                done
            end, ?FAST),
            ?assertEqual({atomic, done}, Res),
            ?assertEqual([2, 3], dsts(?G:out_edges(R, 1))),
            ?assertEqual([1], srcs(?G:in_edges(R, 2))),
            ?assertEqual([{1, 2}, {1, 3}],
                         [{S, Dd} || #{src := S, dst := Dd} <- element(2, ?G:edges_by_type(R, 7))]),
            ?assertEqual({ok, 2}, ?G:degree(R, 1, 7)),
            ?assertMatch({ok, #{props := <<"p1">>}}, ?G:edge(R, 1, 7, 2)),
            %% upsert：props 变、计数不变
            ?assertEqual({atomic, ok},
                         ?G:transaction(R, fun(Tx) ->
                             ?G:put_edge_txn(Tx, 1, 7, 2, #{props => <<"p2">>})
                         end, ?FAST)),
            ?assertMatch({ok, #{props := <<"p2">>}}, ?G:edge(R, 1, 7, 2)),
            ?assertEqual({ok, 2}, ?G:degree(R, 1, 7)),
            ?assertMatch(#{locks := 0, txns := 0}, bitcask_txn_locker:status()),
            ?G:close(R)
        end)
     end}.

del_edge_txn_test_() ->
    {"del_edge_txn：幂等；计数回落；同事务加删净零",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            ok = ?G:put_edge(R, 1, 7, 2),
            ok = ?G:put_edge(R, 1, 7, 3),
            ?assertEqual({atomic, ok},
                         ?G:transaction(R, fun(Tx) ->
                             ok = ?G:del_edge_txn(Tx, 1, 7, 2),
                             ?G:del_edge_txn(Tx, 1, 7, 2)          %% 幂等
                         end, ?FAST)),
            ?assertEqual([3], dsts(?G:out_edges(R, 1))),
            ?assertEqual({error, not_found}, ?G:edge(R, 1, 7, 2)),
            ?assertEqual([], srcs(?G:in_edges(R, 2))),
            ?assertEqual({ok, 1}, ?G:degree(R, 1, 7)),
            %% 同事务加再删：净零
            Res = ?G:transaction(R, fun(Tx) ->
                      ok = ?G:put_edge_txn(Tx, 1, 7, 9),
                      {ok, 2} = ?G:degree_txn(Tx, 1, 7),
                      ?G:del_edge_txn(Tx, 1, 7, 9)
                  end, ?FAST),
            ?assertEqual({atomic, ok}, Res),
            ?assertEqual([3], dsts(?G:out_edges(R, 1))),
            ?assertEqual({ok, 1}, ?G:degree(R, 1, 7)),
            ?assertEqual([], [E || E = #{dst := 9} <- element(2, ?G:edges_by_type(R, 7))]),
            ?G:close(R)
        end)
     end}.

abort_and_vertex_test_() ->
    {"abort 不落盘；put/get_vertex_txn；顶点 Doc 只收 binary",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            ?assertEqual({aborted, nope},
                         ?G:transaction(R, fun(Tx) ->
                             ok = ?G:put_vertex_txn(Tx, 1, <<"alice">>),
                             ok = ?G:put_edge_txn(Tx, 1, 7, 2),
                             bitcask_txn:abort(nope)
                         end, ?FAST)),
            ?assertEqual({error, not_found}, ?G:get_vertex(R, 1)),
            ?assertEqual({ok, 0}, ?G:degree(R, 1, 7)),
            ?assertEqual({atomic, {error, not_found}},
                         ?G:transaction(R, fun(Tx) ->
                             ok = ?G:put_vertex_txn(Tx, 1, <<"alice">>),
                             {ok, <<"alice">>} = ?G:get_vertex_txn(Tx, 1),
                             ?G:get_vertex_txn(Tx, 2)
                         end, ?FAST)),
            ?assertEqual({ok, <<"alice">>}, ?G:get_vertex(R, 1)),
            ?assertMatch({aborted, {function_clause, _}},
                         ?G:transaction(R, fun(Tx) ->
                             ?G:put_vertex_txn(Tx, 1, #{text => <<"x">>})
                         end)),
            ?G:close(R)
        end)
     end}.

concurrent_hub_degree_exact_test_() ->
    {"16 进程并发对同一 hub 加边（含同一端点的入度）→ deg/degi 精确",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            Hub = 1, NProc = 16, PerProc = 25,
            Parent = self(),
            Pids = [spawn_link(fun() ->
                        Rs = [?G:transaction(R, fun(Tx) ->
                                  Dst = P * 1000 + I,
                                  ok = ?G:put_edge_txn(Tx, Hub, 7, Dst),
                                  %% 反向也压同一端点：Dst→Hub 使 Hub 的入度也是热点
                                  ?G:put_edge_txn(Tx, Dst, 7, Hub)
                              end, [{retries, infinity} | ?FAST])
                              || I <- lists:seq(1, PerProc)],
                        Parent ! {self(), Rs}
                    end) || P <- lists:seq(1, NProc)],
            All = lists:append([receive {P, Rs} -> Rs end || P <- Pids]),
            ?assertEqual([], [X || X <- All, X =/= {atomic, ok}]),
            N = NProc * PerProc,
            ?assertEqual({ok, N}, ?G:degree(R, Hub, 7)),           %% 计数键
            ?assertEqual({ok, N}, ?G:degree(R, Hub, undefined)),   %% 实扫
            ?assertEqual(N, length(srcs(?G:in_edges(R, Hub)))),
            ?assertEqual(2 * N, length(element(2, ?G:edges_by_type(R, 7)))),
            ?assertMatch(#{locks := 0, txns := 0, waiting := 0}, bitcask_txn_locker:status()),
            ?G:close(R)
        end)
     end}}.

degree_fallback_per_etype_test_() ->
    {"计数键缺失时 degree/3 与 degree_txn/3 只数该 etype",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            %% 手工造 P3 前的存量：只有边键，没有计数键
            ok = bitcask:put_batch_atomic(R, [{put, ?G:ekey(1, 7, 2), <<>>},
                                              {put, ?G:ekey(1, 7, 3), <<>>},
                                              {put, ?G:ekey(1, 8, 4), <<>>}]),
            ?assertEqual({ok, 2}, ?G:degree(R, 1, 7)),
            ?assertEqual({ok, 1}, ?G:degree(R, 1, 8)),
            ?assertEqual({ok, 0}, ?G:degree(R, 1, 9)),
            ?assertEqual({ok, 3}, ?G:degree(R, 1, undefined)),
            ?assertEqual({atomic, [{ok, 2}, {ok, 1}, {ok, 0}]},
                         ?G:transaction(R, fun(Tx) ->
                             [?G:degree_txn(Tx, 1, T) || T <- [7, 8, 9]]
                         end)),
            ?G:close(R)
        end)
     end}.

%% ===================================================================
%% 前缀锁版本（X1-6）：out/in_edges_txn、degree_txn/2、del_vertex_txn
%% ===================================================================

out_edges_txn_merges_buffer_test_() ->
    {"out_edges_txn/in_edges_txn：看到本事务未提交的加/删；etype、limit 生效",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            ok = ?G:put_edge(R, 1, 7, 2),
            ok = ?G:put_edge(R, 1, 7, 3),
            ok = ?G:put_edge(R, 1, 8, 4),
            Res = ?G:transaction(R, fun(Tx) ->
                ok = ?G:put_edge_txn(Tx, 1, 7, 9),
                ok = ?G:del_edge_txn(Tx, 1, 7, 2),
                {ok, Out}  = ?G:out_edges_txn(Tx, 1),
                {ok, Out7} = ?G:out_edges_txn(Tx, 1, #{etype => 7}),
                {ok, Lim}  = ?G:out_edges_txn(Tx, 1, #{limit => 2}),
                {ok, In9}  = ?G:in_edges_txn(Tx, 9),
                {ok, In2}  = ?G:in_edges_txn(Tx, 2),
                {ok, Deg}  = ?G:degree_txn(Tx, 1),
                {[E || #{dst := E} <- Out], [E || #{dst := E} <- Out7], length(Lim),
                 [S || #{src := S} <- In9], In2, Deg}
            end, ?FAST),
            ?assertEqual({atomic, {[3, 9, 4], [3, 9], 2, [1], [], 3}}, Res),
            %% 直通视图与提交一致
            ?assertEqual([3, 9, 4], dsts(?G:out_edges(R, 1))),
            ?assertMatch(#{locks := 0, prefix_locks := 0}, bitcask_txn_locker:status()),
            ?G:close(R)
        end)
     end}.

del_vertex_txn_test_() ->
    {"del_vertex_txn：级联删 incident 边三键、邻居计数回落、自身计数/顶点清空；自环",
     fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            [ok = ?G:put_vertex(R, V, <<"v">>) || V <- [1, 2, 3]],
            ok = ?G:put_edge(R, 1, 7, 2),
            ok = ?G:put_edge(R, 1, 8, 2),
            ok = ?G:put_edge(R, 3, 7, 1),
            ok = ?G:put_edge(R, 1, 7, 1),                      % 自环
            ok = ?G:put_edge(R, 2, 7, 3),                      % 无关边
            ?assertEqual({atomic, ok},
                         ?G:transaction(R, fun(Tx) -> ?G:del_vertex_txn(Tx, 1) end, ?FAST)),
            ?assertEqual({error, not_found}, ?G:get_vertex(R, 1)),
            ?assertEqual([], dsts(?G:out_edges(R, 1))),
            ?assertEqual([], srcs(?G:in_edges(R, 1))),
            ?assertEqual([], srcs(?G:in_edges(R, 2))),
            ?assertEqual([], dsts(?G:out_edges(R, 3))),
            ?assertEqual([3], dsts(?G:out_edges(R, 2))),       % 无关边还在
            ?assertEqual([{2, 3}], [{S, Dd} || #{src := S, dst := Dd} <- element(2, ?G:edges_by_type(R, 7))]),
            ?assertEqual([], element(2, ?G:edges_by_type(R, 8))),
            %% 邻居计数：3 的出度 7 → 0；2 的入度 7/8 → 0；2 的出度 7 仍 1
            ?assertEqual({ok, 0}, ?G:degree(R, 3, 7)),
            ?assertEqual({ok, 1}, ?G:degree(R, 2, 7)),
            %% 自身计数键全没了（不是归零，是删除）
            ?assertEqual([], bitcask:range(R, {<<"deg", 1:64/big>>, <<"deg", 2:64/big>>})),
            ?assertEqual([], bitcask:range(R, {<<"degi", 1:64/big>>, <<"degi", 2:64/big>>})),
            ?assertMatch(#{locks := 0, prefix_locks := 0}, bitcask_txn_locker:status()),
            ?G:close(R)
        end)
     end}.

%% 全图不变式：每个 (vid, etype) 的 deg/degi 计数 == 实际 e/ei 键数；
%% 每条 e 键有配对的 ei 与 et，反之亦然。
check_invariants(R) ->
    Es  = [{S, T, Dd, Rk} || {<<"e", S:64/big, T:32/big, Dd:64/big, Rk:64/big>>, _}
                              <- bitcask:range(R, {<<"e">>, <<"f">>})],
    Eis = [{S, T, Dd, Rk} || {<<"ei", Dd:64/big, T:32/big, S:64/big, Rk:64/big>>, _}
                              <- bitcask:range(R, {<<"ei">>, <<"ej">>})],
    Ets = [{S, T, Dd, Rk} || {<<"et", T:32/big, S:64/big, Dd:64/big, Rk:64/big>>, _}
                              <- bitcask:range(R, {<<"et">>, <<"eu">>})],
    ?assertEqual(lists:sort(Es), lists:sort(Eis)),
    ?assertEqual(lists:sort(Es), lists:sort(Ets)),
    Degs  = [{{V, T}, N} || {<<"deg", V:64/big, T:32/big>>, <<N:64/big>>}
                             <- bitcask:range(R, {<<"deg">>, <<"deh">>})],
    Degis = [{{V, T}, N} || {<<"degi", V:64/big, T:32/big>>, <<N:64/big>>}
                             <- bitcask:range(R, {<<"degi">>, <<"degj">>})],
    Count = fun(Pairs) -> lists:foldl(fun(K, M) -> M#{K => maps:get(K, M, 0) + 1} end, #{}, Pairs) end,
    OutC = Count([{S, T} || {S, T, _, _} <- Es]),
    InC  = Count([{Dd, T} || {_, T, Dd, _} <- Es]),
    %% 计数键可以多（值为 0 的残留），但凡存在必须等于实际数；有边必有计数键
    [?assertEqual({K, maps:get(K, OutC, 0)}, {K, N}) || {K, N} <- Degs],
    [?assertEqual({K, maps:get(K, InC, 0)}, {K, N})  || {K, N} <- Degis],
    [?assert(lists:keymember(K, 1, Degs))  || K <- maps:keys(OutC)],
    [?assert(lists:keymember(K, 1, Degis)) || K <- maps:keys(InC)],
    length(Es).

concurrent_insert_vs_del_vertex_test_() ->
    {"8 个加边进程 vs 2 个 del_vertex_txn 进程随机交错 → 计数/三键不变式成立",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            NV = 12,
            Parent = self(),
            Ins = [spawn_link(fun() ->
                      rand:seed(exsss, {P, P, P}),
                      [{atomic, ok} = ?G:transaction(R, fun(Tx) ->
                           ?G:put_edge_txn(Tx, rand:uniform(NV), 7, rand:uniform(NV),
                                           #{rank => rand:uniform(3)})
                       end, [{retries, infinity} | ?FAST]) || _ <- lists:seq(1, 60)],
                      Parent ! {self(), done}
                  end) || P <- lists:seq(1, 8)],
            Del = [spawn_link(fun() ->
                      rand:seed(exsss, {P, P, P}),
                      [{atomic, ok} = ?G:transaction(R, fun(Tx) ->
                           ?G:del_vertex_txn(Tx, rand:uniform(NV))
                       end, [{retries, infinity} | ?FAST]) || _ <- lists:seq(1, 15)],
                      Parent ! {self(), done}
                  end) || P <- lists:seq(100, 101)],
            [receive {P, done} -> ok end || P <- Ins ++ Del],
            NEdges = check_invariants(R),
            ?assert(NEdges >= 0),
            ?assertMatch(#{locks := 0, prefix_locks := 0, txns := 0, waiting := 0},
                         bitcask_txn_locker:status()),
            ?G:close(R)
        end)
     end}}.
