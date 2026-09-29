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

%% ===================================================================
%% 6.6.1 B 档：PageRank 改成沿入边 pull（O(N+M)/轮），SSSP 改成单 map。
%% 与老的逐边 scatter 公式逐点对照——测试里用 map 重写一份 scatter 参考实现。
%% ===================================================================

%% 参考实现：老公式（Base = (1-d)/N + d·dangling/N，沿出边散 d·R_j/deg_j）。
ref_pagerank(Csr, D, Eps, MaxIter) ->
    Vids = graphdb_analytics:vertex_list(Csr),
    N = length(Vids),
    Out = maps:from_list([{V, element(2, graphdb_analytics:out_neighbors(Csr, V))} || V <- Vids]),
    R0 = maps:from_list([{V, 1.0 / N} || V <- Vids]),
    ref_iter(Vids, N, Out, R0, D, Eps, MaxIter, 0).

ref_iter(_Vids, _N, _Out, R, _D, _Eps, MaxIter, It) when It >= MaxIter -> R;
ref_iter(Vids, N, Out, R, D, Eps, MaxIter, It) ->
    Dangling = lists:sum([maps:get(V, R) || V <- Vids, maps:get(V, Out) =:= []]),
    Base = (1.0 - D) / N + D * Dangling / N,
    Acc0 = maps:from_list([{V, Base} || V <- Vids]),
    New = lists:foldl(
            fun(V, Acc) ->
                    case maps:get(V, Out) of
                        [] -> Acc;
                        Ns -> Share = D * maps:get(V, R) / length(Ns),
                              lists:foldl(fun(J, A) -> A#{J => maps:get(J, A) + Share} end,
                                          Acc, Ns)
                    end
            end, Acc0, Vids),
    L1 = lists:sum([abs(maps:get(V, New) - maps:get(V, R)) || V <- Vids]),
    case L1 < Eps of
        true  -> New;
        false -> ref_iter(Vids, N, Out, New, D, Eps, MaxIter, It + 1)
    end.

pagerank_matches_scatter_reference_test_() ->
    {"随机图（40 顶点 / ~120 边，含 dangling 与重边）：pull 版逐点等于 scatter 参考实现（1e-9）",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            rand:seed(exsss, {7, 7, 7}),
            Edges = lists:usort([{rand:uniform(40), rand:uniform(40)} || _ <- lists:seq(1, 120)]),
            [ok = graphdb:put_edge(R, S, 1 + (S rem 2), T) || {S, T} <- Edges, S =/= T],
            %% 重边：同 (src,dst) 第二个 etype，物化时去重
            [ok = graphdb:put_edge(R, S, 9, T) || {S, T} <- lists:sublist(Edges, 10), S =/= T],
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            Opts = #{damping => 0.85, eps => 1.0e-12, max_iter => 200},
            Ranks = graphdb_analytics:pagerank(Csr, Opts),
            Ref = ref_pagerank(Csr, 0.85, 1.0e-12, 200),
            ?assertEqual(maps:size(Ref), maps:size(Ranks)),
            [?assert(abs(maps:get(V, Ranks) - maps:get(V, Ref)) < 1.0e-9)
             || V <- maps:keys(Ref)],
            ?assert(abs(sum_ranks(Ranks) - 1.0) < 1.0e-9),
            graphdb:close(R)
        end)
     end}}.

pagerank_two_cycle_exact_test_() ->
    {"1⇄2：对称，rank 各 0.5；1→2 单边：2 高于 1 且 2 = (1-d)/2 + d·(1/2 + r1)",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ok = graphdb:put_edge(R, 1, 7, 2),
            ok = graphdb:put_edge(R, 2, 7, 1),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            Ranks = graphdb_analytics:pagerank(Csr, #{}),
            ?assert(abs(maps:get(1, Ranks) - 0.5) < 1.0e-9),
            ?assert(abs(maps:get(2, Ranks) - 0.5) < 1.0e-9),
            ok = graphdb:del_edge(R, 2, 7, 1),
            {ok, Csr2} = graphdb_analytics:materialize(R, #{}),
            Ranks2 = graphdb_analytics:pagerank(Csr2, #{}),
            R1 = maps:get(1, Ranks2), R2 = maps:get(2, Ranks2),
            ?assert(R2 > R1),
            %% 不动点：2 是 dangling，其质量按 /N 均摊；1 只收 dangling 份额
            ?assert(abs(R2 - ((1 - 0.85) / 2 + 0.85 * (R2 / 2 + R1))) < 1.0e-8),
            ?assert(abs(R1 - ((1 - 0.85) / 2 + 0.85 * (R2 / 2))) < 1.0e-8),
            graphdb:close(R)
        end)
     end}.

sssp_only_reachable_and_chain_test_() ->
    {"链 1→2→…→50 + 孤立 99：距离逐层 +1，不可达不出现；从中点出发只含后半段",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            [ok = graphdb:put_edge(R, I, 7, I + 1) || I <- lists:seq(1, 49)],
            ok = graphdb:put_vertex(R, 99, <<"lonely">>),
            ok = graphdb:put_edge(R, 99, 7, 98),
            {ok, Csr} = graphdb_analytics:materialize(R, #{}),
            {ok, Dist} = graphdb_analytics:sssp(Csr, 1, #{}),
            ?assertEqual(50, maps:size(Dist)),
            [?assertEqual(I - 1, maps:get(I, Dist)) || I <- lists:seq(1, 50)],
            ?assertNot(maps:is_key(99, Dist)),
            {ok, Dist2} = graphdb_analytics:sssp(Csr, 25, #{}),
            ?assertEqual(26, maps:size(Dist2)),
            ?assertEqual(25, maps:get(50, Dist2)),
            graphdb:close(R)
        end)
     end}.
