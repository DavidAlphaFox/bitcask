%% -------------------------------------------------------------------
%% graphdb_txn_tests:
%%   graphdb 事务式 API（bitcask_txn 之上；图层 v2：锁邻接表头）覆盖：
%%     - put_edge_txn   两端邻接表同批落地、提交前不可见、upsert 不动度数
%%     - del_edge_txn   幂等、度数回落、同事务加删净零
%%     - 并发度数       N 进程并发对同一 hub 加边 → 度数精确
%%     - abort / 顶点   中止不落盘；put/get_vertex_txn
%%     - 混用           直通写与事务写同时打同一 hub：都不丢（版本守卫让事务
%%                      冲突重跑）
%% -------------------------------------------------------------------
-module(graphdb_txn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(G, graphdb).

with_dir(Fun) ->
    catch application:load(bitcask),
    {ok, _} = application:ensure_all_started(bitcask),
    bitcask_test_util:with_dir("graphdb_txn_tests_", Fun).

-define(FAST, [{sync, no_sync}]).

dsts({ok, Edges}) -> [D || #{dst := D} <- Edges].

%% 锁的释放是异步的（cast），断言"锁表清零"要等一下。
%% 只等锁表清空（locks / prefix_locks / waiting 归零），不管 txns——agent 还活着
%% 时它们的事务仍注册着，txns 不会归零，用 wait_clean/0 会白白轮询满 1 s。
wait_locks_clean() -> wait_locks_clean(50).
wait_locks_clean(0) -> bitcask_txn_locker:status();
wait_locks_clean(N) ->
    case bitcask_txn_locker:status() of
        #{locks := 0, prefix_locks := 0, waiting := 0} = S -> S;
        _ -> timer:sleep(20), wait_locks_clean(N - 1)
    end.

wait_clean() -> wait_clean(50).
wait_clean(0) -> bitcask_txn_locker:status();
wait_clean(N) ->
    case bitcask_txn_locker:status() of
        #{locks := 0, txns := 0, waiting := 0} = S -> S;
        _ -> timer:sleep(20), wait_clean(N - 1)
    end.
srcs({ok, Edges}) -> [S || #{src := S} <- Edges].

put_edge_txn_test_() ->
    {"put_edge_txn：两端同批；提交前对直通读不可见；upsert 只改 props",
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
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
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
    {"16 进程并发对同一 hub 加边（含同一端点的入度）→ 出 / 入度精确",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            %% 6.9.0 首次公共读会对 Level A 目录做受控 OKI 重建；重建窗口内
            %% 并发读者显式得到 index_corrupt。这里先串行预热，避免把迁移
            %% 窗口混进并发事务断言。
            ?assertEqual({error, not_found}, ?G:get_vertex(R, 1)),
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
            ?assertEqual({ok, N}, ?G:degree(R, Hub, 7)),
            ?assertEqual({ok, N}, ?G:in_degree(R, Hub, 7)),
            ?assertEqual(N, length(dsts(?G:out_edges(R, Hub)))),
            ?assertEqual(N, length(srcs(?G:in_edges(R, Hub)))),
            ?assertEqual(2 * N, length(element(2, ?G:edges_by_type(R, 7)))),
            ?assertMatch(#{locks := 0, txns := 0, waiting := 0}, wait_clean()),
            ?G:close(R)
        end)
     end}}.

mixed_direct_and_txn_writers_test_() ->
    {"8 个直通写进程 + 8 个事务写进程同时往同一 hub 加边：一条不丢、两端对称",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            ?assertEqual({error, not_found}, ?G:get_vertex(R, 1)),
            Hub = 1, PerProc = 25,
            Parent = self(),
            Direct = [spawn_link(fun() ->
                          Rs = [?G:put_edge(R, Hub, 7, P * 1000 + I, #{retries => infinity})
                                || I <- lists:seq(1, PerProc)],
                          Parent ! {self(), Rs}
                      end) || P <- lists:seq(1, 8)],
            Txn = [spawn_link(fun() ->
                       Rs = [case ?G:transaction(R, fun(Tx) ->
                                       ?G:put_edge_txn(Tx, Hub, 7, P * 1000 + I)
                                   end, [{retries, infinity} | ?FAST]) of
                                 {atomic, ok} -> ok;
                                 Other        -> Other
                             end || I <- lists:seq(1, PerProc)],
                       Parent ! {self(), Rs}
                   end) || P <- lists:seq(11, 18)],
            All = lists:append([receive {P, Rs} -> Rs end || P <- Direct ++ Txn]),
            ?assertEqual([], [X || X <- All, X =/= ok]),
            ?assertEqual({ok, 16 * PerProc}, ?G:degree(R, Hub, 7)),
            ?assertMatch({ok, #{edges := E}} when E =:= 16 * PerProc, ?G:check_invariants(R)),
            ?assertMatch(#{locks := 0, txns := 0, waiting := 0}, wait_clean()),
            ?G:close(R)
        end)
     end}}.

%% ===================================================================
%% 邻接读取 / 级联删除的事务版：out/in_edges_txn、degree_txn/2、del_vertex_txn
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
            ?assertMatch(#{locks := 0, prefix_locks := 0}, wait_locks_clean()),
            ?G:close(R)
        end)
     end}.

del_vertex_txn_test_() ->
    {"del_vertex_txn：级联删 incident 边（两端）、邻居度数回落、自身头/顶点清空；自环",
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
            %% 邻居度数：3 的出度 7 → 0；2 的入度 → 0；2 的出度 7 仍 1
            ?assertEqual({ok, 0}, ?G:degree(R, 3, 7)),
            ?assertEqual({ok, 0}, ?G:in_degree(R, 2)),
            ?assertEqual({ok, 1}, ?G:degree(R, 2, 7)),
            %% 自身邻接表头删除（不是留个空头）
            ?assertEqual(not_found, bitcask:get(R, ?G:akey(1))),
            ?assertMatch({ok, _}, ?G:check_invariants(R)),
            ?assertMatch(#{locks := 0, prefix_locks := 0}, wait_locks_clean()),
            ?G:close(R)
        end)
     end}.

%% 全图不变式（对称、度数、块目录、p 键）交给 graphdb:check_invariants/1。
check_invariants(R) ->
    {ok, #{edges := N}} = ?G:check_invariants(R),
    N.

concurrent_insert_vs_del_vertex_test_() ->
    {"8 个加边进程 vs 2 个 del_vertex_txn 进程随机交错 → 对称 / 度数不变式成立",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = ?G:open(D, [read_write]),
            %% 6.9.0 首次公共读可能触发受控 OKI 重建；并发事务前先预热，
            %% 迁移窗口的显式 index_corrupt 不应参与并发不变式压测。
            ?assertEqual({error, not_found}, ?G:get_vertex(R, 1)),
            NV = 12,
            Parent = self(),
            #{lock_wait_timeouts := LWT0} = bitcask_txn_locker:status(),
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
            %% 锁表清零；且没有一次是靠兜底计时器脱困的——跨分片死锁检测必达
            ?assertMatch(#{locks := 0, prefix_locks := 0, txns := 0, waiting := 0},
                         wait_clean()),
            #{lock_wait_timeouts := LWT1} = bitcask_txn_locker:status(),
            ?assertEqual(LWT0, LWT1),
            ?G:close(R)
        end)
     end}}.
