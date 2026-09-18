%% -------------------------------------------------------------------
%% graphdb_analytics_tests:
%%   P4 覆盖：materialize（全图 / etype 过滤 / 重边去重）→
%%   PageRank（和≈1、排序性）、连通分量（单分量 / 双分量）、SSSP（BFS 距离）。
%% -------------------------------------------------------------------
-module(graphdb_analytics_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/graphdb_analytics_tests_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% 顶点 1..4；边（etype 7）：1→2, 2→3, 3→4, 1→3；边（etype 8）：1→3。
seeded(D) ->
    R = graphdb:open(D, [read_write]),
    [ok = graphdb:put_vertex(R, V, <<"v">>) || V <- [1, 2, 3, 4]],
    [ok = graphdb:put_edge(R, S, 7, Dst) || {S, Dst} <- [{1, 2}, {2, 3}, {3, 4}, {1, 3}]],
    ok = graphdb:put_edge(R, 1, 8, 3, #{props => <<"w">>}),
    R.

sum_ranks(Ranks) ->
    lists:sum([V || {_, V} <- maps:to_list(Ranks)]).

materialize_basic_test_() ->
    {"全图物化：|V|/|E|、重边去重（1→3 双 etype 记一条）、出邻居",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            ?assertEqual(4, graphdb_analytics:vertex_count(Csr)),
            ?assertEqual(4, graphdb_analytics:edge_count(Csr)),
            ?assertEqual([1, 2, 3, 4], graphdb_analytics:vertex_list(Csr)),
            ?assertEqual({ok, [2, 3]}, graphdb_analytics:out_neighbors(Csr, 1)),
            ?assertEqual({ok, [4]}, graphdb_analytics:out_neighbors(Csr, 3)),
            ?assertEqual({ok, []}, graphdb_analytics:out_neighbors(Csr, 4)),
            ?assertEqual({ok, []}, graphdb_analytics:out_neighbors(Csr, 99)),
            graphdb:close(R)
        end)
    end}.

materialize_etype_filter_test_() ->
    {"etype 过滤物化：只含该类型边",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, Csr} = graphdb_analytics:materialize(R, #{etype => 8}),
            ?assertEqual(2, graphdb_analytics:vertex_count(Csr)),
            ?assertEqual(1, graphdb_analytics:edge_count(Csr)),
            ?assertEqual({ok, [3]}, graphdb_analytics:out_neighbors(Csr, 1)),
            graphdb:close(R)
        end)
    end}.

pagerank_test_() ->
    {"PageRank：总和≈1（含 dangling 校验）、入边多者分高",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            Ranks = graphdb_analytics:pagerank(Csr, #{}),
            ?assertEqual(4, maps:size(Ranks)),
            ?assert(abs(sum_ranks(Ranks) - 1.0) < 1.0e-6),
            %% vid 3 有两条入边（1→3, 2→3），排名应高于纯源的 vid 1
            ?assert(maps:get(3, Ranks) > maps:get(1, Ranks)),
            ?assert(maps:get(4, Ranks) > 0.0),
            graphdb:close(R)
        end)
    end}.

connected_components_test_() ->
    {"连通分量：单分量 / 双分量（分量代表 = 最小 vid）",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            ?assertEqual(#{1 => 1, 2 => 1, 3 => 1, 4 => 1},
                         graphdb_analytics:connected_components(Csr)),
            graphdb:close(R),
            %% 双分量：1→2 一族。⚠️ 物化以 e 家族为准——无入出边的孤点
            %% 不进 CSR（模块头注记的限制），故这里不种孤点顶点。
            D2 = D ++ "_2",
            ok = filelib:ensure_path(D2),
            R2 = graphdb:open(D2, [read_write]),
            [ok = graphdb:put_vertex(R2, V, <<"v">>) || V <- [1, 2]],
            ok = graphdb:put_edge(R2, 1, 7, 2),
            {ok, Csr2} = graphdb_analytics:materialize(R2, #{}),
            ?assertEqual(#{1 => 1, 2 => 1},
                         graphdb_analytics:connected_components(Csr2)),
            graphdb:close(R2),
            os:cmd("rm -rf " ++ D2)
        end)
    end}.

sssp_test_() ->
    {"SSSP（无权 BFS 距离）：可达距离 / 孤点 / 未知源",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            ?assertEqual({ok, #{1 => 0, 2 => 1, 3 => 1, 4 => 2}},
                         graphdb_analytics:sssp(Csr, 1, #{})),
            ?assertEqual({ok, #{4 => 0}}, graphdb_analytics:sssp(Csr, 4, #{})),
            ?assertEqual({error, not_found}, graphdb_analytics:sssp(Csr, 99, #{})),
            graphdb:close(R)
        end)
    end}.
