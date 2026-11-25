%% -------------------------------------------------------------------
%% graphdb_layout2_tests:
%%   图层布局 2（doc/graph-layout-2-zh.md）：块按条数切、块目录超过阈值外置成 `d` 家族的
%%   B+ 树、每组块数安全阀、布局 1 照旧、布局 1 → 2 的升级。用很小的参数（每块 4 条、
%%   块数 > 4 外置、节点最多 4 项）逼出多层目录树，随机加边 / 删边，每一步与内存里的
%%   模型对照，并跑 check_invariants。
%% -------------------------------------------------------------------
-module(graphdb_layout2_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GP, <<1, "_g:">>).
-define(TINY, [{adj_inline_max, 64}, {adj_chunk_entries, 4}, {adj_chunk_count_max, 0},
               {adj_dir_inline_max, 4}, {adj_dir_node_max, 4}]).

with_dir(Fun) -> bitcask_test_util:with_dir("graphdb_layout2_tests_", Fun).

open_tiny(D) -> open_tiny(D, []).
open_tiny(D, Extra) -> graphdb:open(D, [read_write | Extra ++ ?TINY]).

%% 顶点 Vid 方向 Dir（0 出 / 1 入）、etype 1 的组：{Count, Body} | none
group_of(R, Vid, Dir) ->
    case bitcask:get(R, graphdb:akey(Vid)) of
        not_found -> none;
        {ok, V} ->
            {ok, Gs} = graphdb_adj:groups_info(V),
            case [{C, B} || {D, 1, C, B} <- Gs, D =:= Dir] of
                [G] -> G;
                []  -> none
            end
    end.

dir_keys(R) -> [K || {K, _} <- bitcask:range(R, graphdb_adj:range(<<"d">>))].

dir_keys(R, Vid, Dir) ->
    [K || K <- dir_keys(R), {ok, V, D, _, _, _} <- [graphdb_adj:parse_dir_node_key(K)],
          V =:= Vid, D =:= Dir].

srcs({ok, Es}) -> [S || #{src := S} <- Es].
dsts({ok, Es}) -> [D || #{dst := D} <- Es].

%% model：#{in => Set, out => Set}，etype 1、rank 0
check_against(R, Hub, M) ->
    Ins = lists:sort(sets:to_list(maps:get(in, M))),
    Outs = lists:sort(sets:to_list(maps:get(out, M))),
    ?assertEqual(Ins, srcs(graphdb:in_edges(R, Hub))),
    ?assertEqual(Outs, dsts(graphdb:out_edges(R, Hub))),
    ?assertEqual(Ins, srcs(graphdb:in_edges(R, Hub, #{consistent => true}))),
    ?assertEqual({ok, length(Ins)}, graphdb:in_degree(R, Hub)),
    ?assertEqual({ok, length(Outs)}, graphdb:degree(R, Hub)),
    ?assertEqual(lists:sublist(Ins, 3), srcs(graphdb:in_edges(R, Hub, #{limit => 3}))),
    {ok, Nb} = graphdb:neighbors(R, Hub, both),
    ?assertEqual(dedupe(Outs ++ Ins), Nb),
    [?assertEqual({ok, <<>>}, graphdb_adj:lookup({direct, R}, Hub, 1, 1, X, 0))
     || X <- lists:sublist(Ins, 20)],
    [?assertMatch({ok, _}, graphdb:edge(R, Hub, 1, X)) || X <- lists:sublist(Outs, 20)],
    ?assertEqual(not_found, graphdb_adj:lookup({direct, R}, Hub, 1, 1, 999999, 0)),
    ?assertMatch({ok, _}, graphdb:check_invariants(R)).

dedupe(L) -> dedupe(L, #{}).
dedupe([], _) -> [];
dedupe([X | T], S) ->
    case maps:is_key(X, S) of
        true  -> dedupe(T, S);
        false -> [X | dedupe(T, S#{X => true})]
    end.

add(M, Side, X) -> M#{Side := sets:add_element(X, maps:get(Side, M))}.
del(M, Side, X) -> M#{Side := sets:del_element(X, maps:get(Side, M))}.
empty_model() -> #{in => sets:new(), out => sets:new()}.

%% ===================================================================
%% 编解码
%% ===================================================================

codec_test_() ->
    L2 = graphdb_adj:default_cfg(),
    L1 = graphdb_adj:layout1_cfg(),
    Odd = L2#{chunk_entries => 7, chunk_count_max => 0, dir_inline_max => 3, dir_node_max => 9},
    [?_assertEqual({ok, C}, graphdb_adj:decode_cfg(graphdb_adj:encode_cfg(C))) || C <- [L1, L2, Odd]]
    ++ [?_assertEqual(23, byte_size(graphdb_adj:encode_cfg(L2))),
        ?_assertEqual(11, byte_size(graphdb_adj:encode_cfg(L1))),
        ?_assertEqual({error, {graph_layout, 3}}, graphdb_adj:decode_cfg(<<3, 0, 0>>)),
        ?_assertEqual({ok, 2, <<0:128, 5:64, 1:64, 9:64, 0:64>>},
                      graphdb_adj:decode_node(graphdb_adj:encode_node(2, <<0:128, 5:64, 1:64, 9:64, 0:64>>))),
        ?_assertEqual(<<1, 2, 1:16, 0:128>>, graphdb_adj:encode_node(2, <<0:128>>)),
        ?_assertEqual(error, graphdb_adj:decode_node(graphdb_adj:encode_node(1, <<5:64, 0:64, 3:64, 0:64>>))),
        ?_assertEqual(error, graphdb_adj:decode_node(<<1, 0, 1:16, 0:128>>)),
        ?_assertEqual(error, graphdb_adj:decode_node(<<1, 1, 0:16>>)),
        ?_assertEqual(error, graphdb_adj:decode_node(<<1, 1, 2:16, 0:128>>)),
        ?_assertEqual(<<?GP/binary, "d", 42:64, 1, 7:32, 3, 9:64, 2:64>>,
                      graphdb_adj:dir_node_key(42, 1, 7, 3, {9, 2})),
        ?_assertEqual({ok, 42, 1, 7, 3, {9, 2}},
                      graphdb_adj:parse_dir_node_key(graphdb_adj:dir_node_key(42, 1, 7, 3, {9, 2}))),
        ?_assertEqual(skip, graphdb_adj:parse_chunk_key(graphdb_adj:dir_node_key(42, 1, 7, 3, {9, 2}))),
        %% 头：目录外置的组 <<Dir, F|chunked|xdir, Etype, Count, NChunks:32, Levels:8>>
        ?_assertEqual({ok, [{1, 7, 900, {xdir, 30, 2}}]},
                      graphdb_adj:groups_info(<<1, 1:16, 1, 12, 7:32, 900:64, 30:32, 2>>)),
        ?_assertEqual(error, graphdb_adj:groups_info(<<1, 1:16, 1, 8, 7:32, 900:64, 30:32, 2>>)),
        ?_assertEqual(error, graphdb_adj:groups_info(<<1, 1:16, 1, 12, 7:32, 900:64, 30:32, 0>>)),
        ?_assertEqual(error, graphdb_adj:groups_info(<<1, 1:16, 1, 12, 7:32, 900:64, 0:32, 1>>))].

new_library_is_layout_2_test() ->
    with_dir(fun(D) ->
        R = graphdb:open(D, [read_write]),
        ok = graphdb:put_edge(R, 1, 1, 2),
        ?assertEqual(graphdb_adj:default_cfg(), graphdb:graph_config(R)),
        ?assertMatch({ok, <<2, _:22/binary>>}, bitcask:get(R, <<?GP/binary, "g">>)),
        graphdb:close(R)
    end).

%% ===================================================================
%% 目录树：随机加 / 删与模型对照
%% ===================================================================

random_hub_matches_model_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = open_tiny(D),
            Hub = 1000000,
            rand:seed(exsss, {7, 7, 7}),
            M1 = lists:foldl(
                   fun(_, M) ->
                           X = rand:uniform(400),
                           case rand:uniform() < 0.85 of
                               true  -> ok = graphdb:put_edge(R, X, 1, Hub), add(M, in, X);
                               false -> ok = graphdb:put_edge(R, Hub, 1, X), add(M, out, X)
                           end
                   end, empty_model(), lists:seq(1, 600)),
            %% 加到多层目录
            {_, {xdir, _, Lv}} = group_of(R, Hub, 1),
            ?assert(Lv >= 3),
            check_against(R, Hub, M1),
            %% 随机删到转回内联目录、再转回内联组
            M2 = lists:foldl(fun(X, M) ->
                                     case rand:uniform() < 0.97 of
                                         true  -> ok = graphdb:del_edge(R, X, 1, Hub), del(M, in, X);
                                         false -> M
                                     end
                             end, M1, shuffle(sets:to_list(maps:get(in, M1)))),
            check_against(R, Hub, M2),
            Left = sets:to_list(maps:get(in, M2)),
            [ok = graphdb:del_edge(R, X, 1, Hub) || X <- Left],
            M3 = M2#{in := sets:new()},
            check_against(R, Hub, M3),
            ?assertEqual(none, group_of(R, Hub, 1)),
            ?assertEqual([], dir_keys(R, Hub, 1)),
            %% 批量加回来、混合 upsert
            Xs = lists:seq(2000, 2599),
            ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- Xs]),
            ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:sublist(Xs, 50)], #{batch_vids => 3}),
            M4 = lists:foldl(fun(X, M) -> add(M, in, X) end, M3, Xs),
            check_against(R, Hub, M4),
            %% 删顶点：块与目录节点一起清掉
            ok = graphdb:del_vertex(R, Hub, #{batch_neighbors => 37}),
            ?assertEqual({ok, 0}, graphdb:in_degree(R, Hub)),
            ?assertEqual([], dir_keys(R)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

random_interleaved_ops_test_() ->
    %% 加 / 删随机交替（同一批顶点反复进出），多个种子；每 300 步对照模型
    {timeout, 300, fun() ->
        [with_dir(fun(D) ->
             R = open_tiny(D),
             Hub = 7777,
             rand:seed(exsss, {Seed, Seed, Seed}),
             lists:foldl(
               fun(Step, M) ->
                       X = rand:uniform(300),
                       Side = case rand:uniform() < 0.8 of true -> in; false -> out end,
                       Add = rand:uniform() < 0.6,
                       M2 = case {Side, Add} of
                                {in, true}   -> ok = graphdb:put_edge(R, X, 1, Hub), add(M, in, X);
                                {in, false}  -> ok = graphdb:del_edge(R, X, 1, Hub), del(M, in, X);
                                {out, true}  -> ok = graphdb:put_edge(R, Hub, 1, X), add(M, out, X);
                                {out, false} -> ok = graphdb:del_edge(R, Hub, 1, X), del(M, out, X)
                            end,
                       case Step rem 300 of
                           0 -> check_against(R, Hub, M2);
                           _ -> ok
                       end,
                       M2
               end, empty_model(), lists:seq(1, 1500)),
             graphdb:close(R)
         end) || Seed <- lists:seq(1, 5)]
    end}.

rank_and_props_in_tree_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_tiny(D, [{props_inline_max, 4}]),
            Hub = 7,
            P = fun(I) -> iolist_to_binary([<<"p">>, integer_to_list(I), <<"-">>,
                                            lists:duplicate(I rem 7, $x)]) end,
            [ok = graphdb:put_edge(R, Hub, 1, 1 + I rem 40, #{rank => I div 40, props => P(I)})
             || I <- lists:seq(0, 119)],
            ?assertMatch({_, {xdir, _, _}}, group_of(R, Hub, 0)),
            ?assertEqual({ok, 120}, graphdb:degree(R, Hub)),
            {ok, Es} = graphdb:out_edges(R, Hub),
            ?assertEqual(120, length(Es)),
            %% 外置属性（p 家族）照常读回
            ?assertMatch({ok, #{props := <<"p41-xxxxxx">>}}, graphdb:edge(R, Hub, 1, 2, 1)),
            [ok = graphdb:del_edge(R, Hub, 1, 1 + I rem 40, I div 40) || I <- lists:seq(0, 59)],
            ?assertEqual({ok, 60}, graphdb:degree(R, Hub)),
            ?assertEqual({error, not_found}, graphdb:edge(R, Hub, 1, 2, 0)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

safety_valve_caps_chunk_count_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 64}, {adj_chunk_entries, 4},
                                 {adj_chunk_count_max, 8}, {adj_dir_inline_max, 64},
                                 {adj_dir_node_max, 4}]),
            Hub = 9,
            ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(1, 2000)]),
            [ok = graphdb:put_edge(R, 5000 + 7 * I, 1, Hub) || I <- lists:seq(0, 199)],
            N = case group_of(R, Hub, 1) of
                    {_, {chunks, Lbs}}  -> length(Lbs);
                    {_, {xdir, NC, _}}  -> NC
                end,
            %% 块数被安全阀压住（每块条数随组放大）
            ?assert(N =< 40),
            ?assertEqual({ok, 2200}, graphdb:in_degree(R, Hub)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

chunk_entries_cap_test() ->
    %% 缺省参数：块按条数（512）切，与组大小无关；块数超过 16 才外置
    with_dir(fun(D) ->
        R = graphdb:open(D, [read_write]),
        Hub = 3,
        ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(1, 6000)], #{batch_vids => 100000}),
        {6000, {chunks, Lbs}} = group_of(R, Hub, 1),
        ?assertEqual(12, length(Lbs)),
        ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(6001, 12000)], #{batch_vids => 100000}),
        ?assertMatch({12000, {xdir, _, 1}}, group_of(R, Hub, 1)),
        ?assertEqual(1, length(dir_keys(R, Hub, 1))),
        [begin
             {ok, Es} = graphdb_adj:decode_chunk(V),
             ?assert(length(Es) =< 512)
         end || {K, V} <- bitcask:range(R, {graphdb:akey(Hub), graphdb:akey(Hub + 1)}),
                byte_size(K) =:= 34],
        ?assertMatch({ok, _}, graphdb:check_invariants(R)),
        graphdb:close(R)
    end).

%% ===================================================================
%% 布局 1 照旧、升级
%% ===================================================================

layout_1_unchanged_and_upgrade_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_layout, 1}, {adj_inline_max, 64},
                                 {adj_chunk_max, 64}]),
            Hub = 5,
            [ok = graphdb:put_edge(R, I, 1, Hub) || I <- lists:seq(1, 300)],
            ?assertMatch(#{layout := 1}, graphdb:graph_config(R)),
            ?assertMatch({300, {chunks, _}}, group_of(R, Hub, 1)),     %% 布局 1：目录总在头里
            ?assertEqual([], dir_keys(R)),
            %% 升级到布局 2：只改 g，之后写到的组再转
            {ok, Cfg} = graphdb:upgrade_layout(R, [{adj_chunk_entries, 4}, {adj_dir_inline_max, 4},
                                                   {adj_dir_node_max, 4}, {adj_inline_max, 999}]),
            ?assertMatch(#{layout := 2, chunk_entries := 4}, Cfg),
            ?assertEqual(64, maps:get(inline_max, Cfg)),                %% inline_max 沿用库里的
            ?assertEqual(Cfg, graphdb:graph_config(R)),
            ?assertEqual({ok, Cfg}, graphdb:upgrade_layout(R, [])),    %% 再升：不写
            ?assertMatch({300, {chunks, _}}, group_of(R, Hub, 1)),     %% 没写之前不动
            ?assertEqual(lists:seq(1, 300), srcs(graphdb:in_edges(R, Hub))),
            ok = graphdb:put_edge(R, 1000, 1, Hub),
            ?assertMatch({301, {xdir, _, _}}, group_of(R, Hub, 1)),    %% 写到之后目录外置
            [ok = graphdb:put_edge(R, 2000 + I, 1, Hub) || I <- lists:seq(0, 199)],
            ?assertEqual({ok, 501}, graphdb:in_degree(R, Hub)),
            ?assertEqual(lists:seq(1, 300) ++ [1000] ++ lists:seq(2000, 2199),
                         srcs(graphdb:in_edges(R, Hub))),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R),
            %% 重开以 g 为准
            R2 = graphdb:open(D, [read_write]),
            ?assertEqual(Cfg, graphdb:graph_config(R2)),
            graphdb:close(R2)
        end)
    end}.

%% ===================================================================
%% 并发 / 事务 / 校验
%% ===================================================================

stale_directory_conflicts_test() ->
    with_dir(fun(D) ->
        R = open_tiny(D),
        Hub = 3,
        ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(1, 199)]),
        {_, {xdir, _, Lv}} = group_of(R, Hub, 1),
        Root = graphdb_adj:dir_node_key(Hub, 1, 1, Lv, {0, 0}),
        S0 = graphdb_adj:new_session({direct, R}, graphdb:graph_config(R)),
        %% 读头之后、走树之前根节点没了（模拟别人改过）：会话标过期，提交当冲突
        {ok, S1} = graphdb_adj:put_edge(S0, 500, 1, 2, 0, <<>>),          %% 先读入 2 的头
        ok = bitcask:delete(R, Root),
        {ok, S2} = graphdb_adj:put_edge(S1, 999, 1, Hub, 0, <<>>),
        ?assertEqual(conflict, graphdb_adj:commit(S2)),
        graphdb:close(R)
    end).

txn_on_external_directory_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_tiny(D),
            Hub = 11,
            ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(1, 120)]),
            ?assertMatch({_, {xdir, _, _}}, group_of(R, Hub, 1)),
            {atomic, ok} = graphdb:transaction(R, fun(Tx) ->
                ok = graphdb:put_edge_txn(Tx, 500, 1, Hub),
                ok = graphdb:del_edge_txn(Tx, 1, 1, Hub),
                ok = graphdb:del_edge_txn(Tx, 2, 1, Hub),
                ok
            end),
            Want = lists:seq(3, 120) ++ [500],
            ?assertEqual({atomic, Want},
                         graphdb:transaction(R, fun(Tx) -> srcs(graphdb:in_edges_txn(Tx, Hub)) end)),
            ?assertEqual(Want, srcs(graphdb:in_edges(R, Hub))),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            {atomic, _} = graphdb:transaction(R, fun(Tx) -> graphdb:del_vertex_txn(Tx, Hub) end),
            ?assertEqual([], dir_keys(R)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

concurrent_writers_on_hub_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = open_tiny(D),
            Hub = 1,
            Self = self(),
            Pids = [spawn_link(fun() ->
                                       [ok = graphdb:put_edge(R, 1000 * W + I, 1, Hub, #{retries => infinity})
                                        || I <- lists:seq(1, 60)],
                                       Self ! {done, W}
                               end) || W <- lists:seq(1, 8)],
            [receive {done, W} -> ok end || W <- lists:seq(1, length(Pids))],
            Want = lists:sort([1000 * W + I || W <- lists:seq(1, 8), I <- lists:seq(1, 60)]),
            ?assertEqual(Want, srcs(graphdb:in_edges(R, Hub))),
            ?assertEqual({ok, 480}, graphdb:in_degree(R, Hub)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

invariants_detect_tree_damage_test() ->
    with_dir(fun(D) ->
        R = open_tiny(D),
        Hub = 4,
        ok = graphdb:put_edges(R, [{X, 1, Hub} || X <- lists:seq(1, 200)]),
        ?assertMatch({ok, _}, graphdb:check_invariants(R)),
        %% 走不到的节点
        Stray = graphdb_adj:dir_node_key(Hub, 0, 1, 1, {0, 0}),
        ok = bitcask:put(R, Stray, graphdb_adj:encode_node(1, <<0:128>>)),
        {error, P1} = graphdb:check_invariants(R),
        ?assert(lists:any(fun({orphan_dir_node, _}) -> true; (_) -> false end, P1)),
        ok = bitcask:delete(R, Stray),
        %% 缺节点
        [K1 | _] = [K || K <- dir_keys(R, Hub, 1), {ok, _, _, _, 1, Lb} <- [graphdb_adj:parse_dir_node_key(K)],
                         Lb =/= {0, 0}],
        ok = bitcask:delete(R, K1),
        {error, P2} = graphdb:check_invariants(R),
        ?assert(lists:any(fun({missing_dir_node, _}) -> true; (_) -> false end, P2)),
        graphdb:close(R)
    end).

shuffle(L) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- L])].
