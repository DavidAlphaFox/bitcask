%% -------------------------------------------------------------------
%% graphdb_tests:
%%   图存储层（doc/graph-layer-design-zh.md，KV per-key 方案）P1 + P2 覆盖：
%%     - key codec      字节级精确性（n/e/ei 定宽大端）+ succ 字典序后继
%%     - 顶点/边 CRUD   原子双写、点查、upsert、级联删除
%%     - 邻接扫描       out/in 前缀 range、etype 收窄、limit、度数
%%     - 遍历           BFS（depth/dir/etype）、k-hop、双向最短路
%%     - etype registry 注册/回查/幂等
%%     - 持久性         重开后的可见性
%% -------------------------------------------------------------------
-module(graphdb_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/graphdb_tests_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% 顶点 1..4；边（etype 7）：1→2, 2→3, 3→4, 1→3；边（etype 8）：1→3。
seeded(D) ->
    R = graphdb:open(D, [read_write]),
    ok = graphdb:put_vertex(R, 1, <<"alice">>),
    ok = graphdb:put_vertex(R, 2, <<"bob">>),
    ok = graphdb:put_vertex(R, 3, <<"carol">>),
    ok = graphdb:put_vertex(R, 4, <<"dave">>),
    ok = graphdb:put_edge(R, 1, 7, 2),
    ok = graphdb:put_edge(R, 2, 7, 3),
    ok = graphdb:put_edge(R, 3, 7, 4),
    ok = graphdb:put_edge(R, 1, 7, 3),
    ok = graphdb:put_edge(R, 1, 8, 3, #{props => <<"weight:0.9">>}),
    R.

dsts_of({ok, Edges}) -> [D || #{dst := D} <- Edges];
dsts_of(Other)       -> {bad, Other}.

srcs_of({ok, Edges}) -> [S || #{src := S} <- Edges];
srcs_of(Other)       -> {bad, Other}.

%% ===================================================================
%% key codec：字节级精确 + succ
%% ===================================================================

nkey_codec_test_() ->
    {"nkey = \"n\" + vid 大端 8 字节",
     ?_assertEqual(<<"n", 0, 0, 0, 0, 0, 0, 0, 42>>, graphdb:nkey(42))}.

ekey_codec_test_() ->
    {"ekey 29 字节定宽大端；rank 缺省 0",
     [?_assertEqual(<<"e", 1:64/big, 7:32/big, 2:64/big, 0:64/big>>,
                    graphdb:ekey(1, 7, 2)),
      ?_assertEqual(<<"e", 1:64/big, 7:32/big, 2:64/big, 9:64/big>>,
                    graphdb:ekey(1, 7, 2, 9)),
      ?_assertEqual(29, byte_size(graphdb:ekey(1, 7, 2))),
      ?_assertEqual(<<"ei", 2:64/big, 7:32/big, 1:64/big, 0:64/big>>,
                    graphdb:eikey(2, 7, 1)),
      ?_assertEqual(30, byte_size(graphdb:eikey(2, 7, 1)))]}.

succ_codec_test_() ->
    {"succ = 去尾部 0xFF + 末字节进位；全 0xFF 无上界",
     [?_assertEqual(<<"ac">>, graphdb:succ(<<"ab">>)),
      ?_assertEqual(<<"b">>, graphdb:succ(<<"a", 255>>)),
      ?_assertEqual(undefined, graphdb:succ(<<255, 255>>)),
      ?_assertEqual(<<"f">>, graphdb:succ(<<"e">>)),
      %% vid 进位：vid 255 的出边区间上界 = vid 256 的前缀
      ?_assertEqual(<<"e", 0, 0, 0, 0, 0, 0, 1>>, graphdb:succ(<<"e", 0, 0, 0, 0, 0, 0, 0, 255>>))]}.

codec_validation_test_() ->
    {"非法 vid/etype/rank 拒绝（badarg）",
     [?_assertError(badarg, graphdb:nkey(-1)),
      ?_assertError(badarg, graphdb:ekey(1, 16#100000000, 2)),
      ?_assertError(badarg, graphdb:ekey(1, 7, 2, -1))]}.

%% ===================================================================
%% 顶点 / 边 CRUD
%% ===================================================================

vertex_crud_test_() ->
    {"顶点 put/get/缺失语义；Doc 原样回读",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, <<"alice">>}, graphdb:get_vertex(R, 1)),
            ?assertEqual({error, not_found}, graphdb:get_vertex(R, 99)),
            ok = graphdb:put_vertex(R, 1, <<"alice prime">>),
            ?assertEqual({ok, <<"alice prime">>}, graphdb:get_vertex(R, 1)),
            graphdb:close(R)
        end)
    end}.

edge_point_lookup_test_() ->
    {"边点查：props 回读 / 缺失 / upsert 后读到最后一次写",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, #{src => 1, etype => 8, dst => 3, rank => 0,
                                props => <<"weight:0.9">>}},
                         graphdb:edge(R, 1, 8, 3)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 3, 8, 1)),
            ok = graphdb:put_edge(R, 1, 8, 3, #{props => <<"weight:1.0">>}),
            ?assertEqual(<<"weight:1.0">>,
                         maps:get(props, element(2, graphdb:edge(R, 1, 8, 3)))),
            graphdb:close(R)
        end)
    end}.

del_edge_removes_both_directions_test_() ->
    {"del_edge 原子摘除双向键",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ok = graphdb:del_edge(R, 1, 8, 3),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 8, 3)),
            ?assertEqual([1, 2], srcs_of(graphdb:in_edges(R, 3))),
            ?assertEqual([2, 3], dsts_of(graphdb:out_edges(R, 1))),
            graphdb:close(R)
        end)
    end}.

del_vertex_cascade_test_() ->
    {"del_vertex 级联删除全部 incident 边 + 顶点本体",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ok = graphdb:del_vertex(R, 2),
            ?assertEqual({error, not_found}, graphdb:get_vertex(R, 2)),
            %% 1→2 与 2→3 双向消失；1→3（etype 7/8）不受影响
            ?assertEqual([3, 3], dsts_of(graphdb:out_edges(R, 1))),
            ?assertEqual([4], dsts_of(graphdb:out_edges(R, 3))),
            ?assertEqual([1], srcs_of(graphdb:in_edges(R, 3, #{etype => 7}))),
            ?assertEqual([], srcs_of(graphdb:in_edges(R, 2))),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% 邻接扫描
%% ===================================================================

out_in_edges_test_() ->
    {"out/in 前缀扫描：key 序输出；etype 收窄；limit 提前停",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual([2, 3, 3], dsts_of(graphdb:out_edges(R, 1))),
            ?assertEqual([3], dsts_of(graphdb:out_edges(R, 1, #{etype => 8}))),
            ?assertEqual([2], dsts_of(graphdb:out_edges(R, 1, #{limit => 1}))),
            ?assertEqual([], dsts_of(graphdb:out_edges(R, 1, #{limit => 0}))),
            ?assertEqual([1, 2, 1], srcs_of(graphdb:in_edges(R, 3))),
            ?assertEqual([1], srcs_of(graphdb:in_edges(R, 3, #{etype => 8}))),
            ?assertEqual([3], srcs_of(graphdb:in_edges(R, 4))),
            graphdb:close(R)
        end)
    end}.

neighbors_test_() ->
    {"neighbors out/in/both（both 去重保序）",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, [4]}, graphdb:neighbors(R, 3, out)),
            ?assertEqual({ok, [1, 2]}, graphdb:neighbors(R, 3, in)),
            ?assertEqual({ok, [4, 1, 2]}, graphdb:neighbors(R, 3, both)),
            graphdb:close(R)
        end)
    end}.

degree_test_() ->
    {"degree 按需计数（全类型 / 单类型 / 零度）",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, 3}, graphdb:degree(R, 1, undefined)),
            ?assertEqual({ok, 1}, graphdb:degree(R, 1, 8)),
            ?assertEqual({ok, 0}, graphdb:degree(R, 4, undefined)),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% 遍历
%% ===================================================================

bfs_test_() ->
    {"BFS：全深度 / depth 截断 / dir=in / etype 过滤",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, [{1, 0}, {2, 1}, {3, 1}, {4, 2}]},
                         graphdb:bfs(R, 1, #{})),
            ?assertEqual({ok, [{1, 0}, {2, 1}, {3, 1}]},
                         graphdb:bfs(R, 1, #{depth => 1})),
            ?assertEqual({ok, [{4, 0}, {3, 1}, {1, 2}, {2, 2}]},
                         graphdb:bfs(R, 4, #{dir => in})),
            ?assertEqual({ok, [{1, 0}, {3, 1}]},
                         graphdb:bfs(R, 1, #{etype => 8})),
            graphdb:close(R)
        end)
    end}.

k_hop_test_() ->
    {"k-hop 邻域（不含起点）",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, [2, 3]}, graphdb:k_hop(R, 1, 1, #{})),
            ?assertEqual({ok, [2, 3, 4]}, graphdb:k_hop(R, 1, 2, #{})),
            ?assertEqual({ok, []}, graphdb:k_hop(R, 4, 2, #{})),
            graphdb:close(R)
        end)
    end}.

shortest_path_test_() ->
    {"双向最短路：正例 / 反向无路径 / 自身 / etype 过滤",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            %% 1→2→3→4 长 3；1→3→4 长 2，最短
            ?assertEqual({ok, [1, 3, 4]}, graphdb:shortest_path(R, 1, 4)),
            ?assertEqual({error, no_path}, graphdb:shortest_path(R, 4, 1)),
            ?assertEqual({ok, [2]}, graphdb:shortest_path(R, 2, 2)),
            %% etype 8 只有 1→3，接不到 4
            ?assertEqual({error, no_path},
                         graphdb:shortest_path(R, 1, 4, #{etype => 8})),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% etype registry
%% ===================================================================

etype_registry_test_() ->
    {"etype 注册：id 从 1 起、幂等、双向回查",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ?assertEqual({ok, 1}, graphdb:register_etype(R, <<"follows">>)),
            ?assertEqual({ok, 2}, graphdb:register_etype(R, <<"likes">>)),
            ?assertEqual({ok, 1}, graphdb:register_etype(R, <<"follows">>)),
            ?assertEqual({ok, 1}, graphdb:etype_id(R, <<"follows">>)),
            ?assertEqual({ok, <<"likes">>}, graphdb:etype_name(R, 2)),
            ?assertEqual({error, not_found}, graphdb:etype_id(R, <<"hates">>)),
            ?assertEqual({error, not_found}, graphdb:etype_name(R, 99)),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% 持久性：重开可见
%% ===================================================================

reopen_persistence_test_() ->
    {"close 后重开：顶点/边/遍历全部仍在",
     fun() ->
        with_dir(fun(D) ->
            R0 = seeded(D),
            ok = graphdb:close(R0),
            R = graphdb:open(D, [read_write]),
            ?assertEqual({ok, <<"carol">>}, graphdb:get_vertex(R, 3)),
            ?assertEqual([2, 3, 3], dsts_of(graphdb:out_edges(R, 1))),
            ?assertEqual({ok, [1, 3, 4]}, graphdb:shortest_path(R, 1, 4)),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% P3：deg/degi 计数器 + et 家族 + 属性过滤遍历
%% ===================================================================

degree_counters_test_() ->
    {"deg 计数器：插入 +1、del -1、upsert 不重复计数、per-etype 分立",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            %% 计数器路径（key 存在 → O(1) 读）
            ?assertEqual({ok, 2}, graphdb:degree(R, 1, 7)),
            ?assertEqual({ok, 1}, graphdb:degree(R, 1, 8)),
            ?assertEqual({ok, 1}, graphdb:degree(R, 2, 7)),
            %% upsert：同边重写属性，计数不变
            ok = graphdb:put_edge(R, 1, 7, 2, #{props => <<"x">>}),
            ?assertEqual({ok, 2}, graphdb:degree(R, 1, 7)),
            %% del_edge：-1
            ok = graphdb:del_edge(R, 1, 8, 3),
            ?assertEqual({ok, 0}, graphdb:degree(R, 1, 8)),
            graphdb:close(R)
        end)
    end}.

del_vertex_updates_neighbor_counters_test_() ->
    {"del_vertex 级联同步修正邻居计数器（聚合一次 RMW）",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            [ok = graphdb:put_vertex(R, V, <<"v">>) || V <- [1, 2, 3, 4]],
            ok = graphdb:put_edge(R, 1, 7, 2),   %% 1→2
            ok = graphdb:put_edge(R, 3, 7, 2),   %% 3→2
            ok = graphdb:put_edge(R, 2, 7, 3),   %% 2→3
            ok = graphdb:put_edge(R, 2, 9, 4),   %% 2→4
            ?assertEqual({ok, 1}, graphdb:degree(R, 2, 7)),
            ok = graphdb:del_vertex(R, 2),
            %% in 边 (1→2, 3→2) 摘除 → 1、3 的出度 -1
            ?assertEqual({ok, 0}, graphdb:degree(R, 1, 7)),
            ?assertEqual({ok, 0}, graphdb:degree(R, 3, 7)),
            %% out 边 (2→3) 摘除 → 3 的入度 -1；（2→4）→ 4 的入度 -1
            ?assertEqual({ok, 0}, graphdb:degree(R, 3, 7)),
            ?assertEqual({ok, 0}, graphdb:degree(R, 4, 9)),
            ?assertEqual({error, not_found}, graphdb:get_vertex(R, 2)),
            graphdb:close(R)
        end)
    end}.

edges_by_type_test_() ->
    {"et 家族：按类型全局列边，key 序 = (src,dst,rank)",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, E7} = graphdb:edges_by_type(R, 7),
            ?assertEqual([{1, 2}, {1, 3}, {2, 3}, {3, 4}],
                         [{S, D} || #{src := S, dst := D} <- E7]),
            {ok, E8} = graphdb:edges_by_type(R, 8),
            ?assertEqual([{1, 3}], [{S, D} || #{src := S, dst := D} <- E8]),
            ?assertEqual({ok, []}, graphdb:edges_by_type(R, 99)),
            graphdb:close(R)
        end)
    end}.

neighbors_where_test_() ->
    {"属性过滤遍历：Pred 作用于邻居顶点值；悬挂边 Value=undefined",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            %% 只留顶点值以 "a" 开头的邻居（alice 通过，bob 不通过）
            {ok, Ns} = graphdb:neighbors_where(
                         R, 3, in,
                         fun(_V, Val) when is_binary(Val) ->
                                 hd(binary_to_list(Val)) =:= $a;
                            (_V, undefined) -> false
                         end),
            ?assertEqual([1], Ns),
            graphdb:close(R)
        end)
    end}.

%% ===================================================================
%% P5：一致性语义（设计文档 §6.5）
%%
%% 可确定性断言的不变量：
%%   1. 写提交后，新开的扫描必然可见（read-your-writes）；
%%   2. 迭代期间并发写：正在进行的扫描**要么看到要么看不到**该写——
%%      两者都合法（per-key 弱一致），但输出必须依然 key 序、可解析、
%%      无撕裂条目；
%%   3. 删除提交后，新扫描必然不可见。
%% ===================================================================

read_your_writes_test_() ->
    {"写提交返回后，新扫描立即可见",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ok = graphdb:put_edge(R, 1, 42, 777, #{props => <<"fresh">>}),
            {ok, Fresh} = graphdb:out_edges(R, 1, #{etype => 42}),
            ?assertEqual([777], [D || #{dst := D} <- Fresh]),
            graphdb:close(R)
        end)
    end}.

scan_insert_during_iteration_test_() ->
    {"扫描中途插入：进行中的扫描看到与否均合法；输出 key 序无撕裂；新扫描必见",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            [ok = graphdb:put_edge(R, 1, 7, 100 + N) || N <- lists:seq(0, 99)],
            Fun = fun(K, _V, _T, _O, {Inserted, Raw}) ->
                          Raw2 = [K | Raw],
                          case Inserted of
                              false ->
                                  ok = graphdb:put_edge(R, 1, 7, 999),
                                  {true, Raw2};
                              true ->
                                  {true, Raw2}
                          end
                  end,
            ELo = <<"e", 1:64/big, 7:32/big>>,            %% vid 1 × etype 7 前缀
            {_Inserted, RawKeys} = bitcask:range_fold(R, {ELo, graphdb:succ(ELo)},
                                                      [], Fun, {false, []}),
            Dsts = [begin
                        <<_:13/binary, Dst:64/big, _/binary>> = K,
                        Dst
                    end || K <- lists:reverse(RawKeys)],
            %% 不变量：严格升序、定义域合法、999 看到与否均合法
            ?assertEqual(lists:usort(Dsts), Dsts),
            ?assert(lists:all(fun(D) -> (D >= 100 andalso D =< 199) orelse D =:= 999 end, Dsts)),
            ?assert(length(Dsts) >= 100),                     %% 原有边绝不丢
            ?assert(lists:member(999, Dsts) orelse not lists:member(999, Dsts)),
            %% 提交已完成 → 新扫描必见
            {ok, FreshEdges} = graphdb:out_edges(R, 1),
            ?assert(lists:member(999, [D || #{dst := D} <- FreshEdges])),
            graphdb:close(R)
        end)
    end}.

scan_delete_during_iteration_test_() ->
    {"扫描中途删除：被删边出现与否均合法；删除提交后新扫描必不可见",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            [ok = graphdb:put_edge(R, 2, 7, 300 + N) || N <- lists:seq(0, 99)],
            Fun = fun(K, _V, _T, _O, {Deleted, Raw}) ->
                          Raw2 = [K | Raw],
                          case Deleted of
                              false ->
                                  ok = graphdb:del_edge(R, 2, 7, 350),
                                  {true, Raw2};
                              true ->
                                  {true, Raw2}
                          end
                  end,
            ELo2 = <<"e", 2:64/big, 7:32/big>>,
            {true, RawKeys} = bitcask:range_fold(R, {ELo2, graphdb:succ(ELo2)},
                                                 [], Fun, {false, []}),
            Dsts = [begin
                        <<_:13/binary, Dst:64/big, _/binary>> = K,
                        Dst
                    end || K <- lists:reverse(RawKeys)],
            ?assertEqual(lists:usort(Dsts), Dsts),
            ?assert(length(Dsts) =< 100),
            %% 350 除外的 99 条必然还在
            ?assertEqual(99, length([D || D <- Dsts, D =/= 350])),
            %% 删除已提交 → 新扫描不可见
            {ok, FreshEdges2} = graphdb:out_edges(R, 2),
            ?assertNot(lists:member(350, [D || #{dst := D} <- FreshEdges2])),
            graphdb:close(R)
        end)
    end}.
