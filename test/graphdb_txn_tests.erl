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
