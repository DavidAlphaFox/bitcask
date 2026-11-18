%% -------------------------------------------------------------------
%% graphdb_migrate_tests:
%%   图层 v1 → v2 离线迁移（doc/graph-adjacency-pack-design-zh.md §10）：
%%     - 用 v1 的盘上布局直接造源库（n / e / ei / et / deg / degi / t / tn，
%%       外加一个首字节是 $i 的病理 vid）
%%     - 迁移后 v2 读出的出 / 入边、属性、度数、顶点、etype 注册表与源一致；
%%       et / deg / degi 不进新库；hub 按目标参数分块；大属性落 p 家族
%%     - 源库只读、一个字节不改；目标库非空拒绝；verify 能发现不一致
%% -------------------------------------------------------------------
-module(graphdb_migrate_tests).

-include_lib("eunit/include/eunit.hrl").

with_dirs(Fun) ->
    bitcask_test_util:with_dir("graphdb_migrate_src_", fun(Src) ->
        bitcask_test_util:with_dir("graphdb_migrate_dst_", fun(Dst) -> Fun(Src, Dst) end)
    end).

%% v1 布局写一组边：{S, T, D, R, Props}。按 v1 的写法每边 3 个键 + 计数键。
write_v1(Dir, Vertices, Edges, Etypes) ->
    B = bitcask:open(Dir, [read_write]),
    [ok = bitcask:put(B, <<"n", V:64/big>>, Doc) || {V, Doc} <- Vertices],
    [begin
         ok = bitcask:put(B, <<"t", Id:32/big>>, Name),
         ok = bitcask:put(B, <<"tn", (byte_size(Name)):16/big, Name/binary>>, <<Id:32/big>>)
     end || {Id, Name} <- Etypes],
    ok = bitcask:put_batch_atomic(
           B, lists:append(
                [[{put, <<"e", S:64/big, T:32/big, D:64/big, R:64/big>>, P},
                  {put, <<"ei", D:64/big, T:32/big, S:64/big, R:64/big>>, <<>>},
                  {put, <<"et", T:32/big, S:64/big, D:64/big, R:64/big>>, <<>>}]
                 || {S, T, D, R, P} <- Edges])),
    Count = fun(Ks) -> lists:foldl(fun(K, M) -> M#{K => maps:get(K, M, 0) + 1} end, #{}, Ks) end,
    ok = bitcask:put_batch_atomic(
           B, [{put, <<"deg", V:64/big, T:32/big>>, <<N:64/big>>}
               || {{V, T}, N} <- maps:to_list(Count([{S, T} || {S, T, _, _, _} <- Edges]))]
              ++ [{put, <<"degi", V:64/big, T:32/big>>, <<N:64/big>>}
                  || {{V, T}, N} <- maps:to_list(Count([{D, T} || {_, T, D, _, _} <- Edges]))]),
    ok = bitcask:close(B).

sample_edges() ->
    IVid = 16#69 bsl 56,                       %% v1 的病理 vid：e<vid> 区间混进 ei 键
    [{1, 7, 2, 0, <<>>}, {1, 7, 3, 0, <<"w=1">>}, {1, 8, 3, 0, <<>>},
     {1, 7, 3, 4, <<>>},                        %% 平行边（rank 4）
     {2, 7, 3, 0, <<>>}, {3, 7, 1, 0, <<>>},
     {5, 7, 5, 0, <<>>},                        %% 自环
     {IVid, 7, 5, 0, <<>>}, {9, 7, IVid, 0, <<>>},
     {6, 9, 1, 0, binary:copy(<<"z">>, 300)}].  %% 大属性

snapshot(H, Vids) ->
    [{V, element(2, graphdb:out_edges(H, V)), element(2, graphdb:in_edges(H, V))} || V <- Vids].

migrate_basic_test_() ->
    {"v1 源库 → v2：边 / 属性 / 度数 / 顶点 / etype 一致；et/deg/degi 不进新库；源库不变",
     {timeout, 60, fun() ->
        with_dirs(fun(Src, Dst) ->
            Edges = sample_edges(),
            write_v1(Src, [{1, <<"alice">>}, {2, <<"bob">>}], Edges, [{7, <<"follows">>}]),
            SrcKeys0 = src_keys(Src),
            {ok, Stats} = graphdb_migrate:v1_to_v2(Src, Dst),
            Vids = lists:usort(lists:append([[S, D] || {S, _, D, _, _} <- Edges])),
            ?assertMatch(#{vertices := NV, edges := NE, copied := 4}
                           when NV =:= length(Vids) andalso NE =:= length(Edges), Stats),
            ?assertEqual(SrcKeys0, src_keys(Src)),
            H = graphdb:open(Dst, []),
            try
                ?assertMatch({ok, #{edges := NE2}} when NE2 =:= length(Edges),
                             graphdb:check_invariants(H)),
                ?assertEqual({ok, <<"alice">>}, graphdb:get_vertex(H, 1)),
                ?assertEqual({ok, 7}, graphdb:etype_id(H, <<"follows">>)),
                ?assertEqual({ok, <<"follows">>}, graphdb:etype_name(H, 7)),
                ?assertEqual([{2, 0}, {3, 0}, {3, 4}],
                             [{D, R} || #{dst := D, rank := R} <- element(2, graphdb:out_edges(H, 1, #{etype => 7}))]),
                ?assertMatch({ok, #{props := <<"w=1">>}}, graphdb:edge(H, 1, 7, 3)),
                ?assertEqual({ok, 4}, graphdb:degree(H, 1)),
                ?assertEqual({ok, 4}, graphdb:in_degree(H, 3)),
                ?assertEqual({ok, 2}, graphdb:in_degree(H, 5, 7)),     %% 自环 + 病理 vid
                ?assertEqual({ok, 1}, graphdb:degree(H, 5)),
                ?assertMatch({ok, #{props := <<"zzz", _/binary>>}}, graphdb:edge(H, 6, 9, 1)),
                ?assertMatch({ok, _}, bitcask:get(H, graphdb:pkey(6, 9, 1, 0))),
                IVid = 16#69 bsl 56,
                ?assertEqual([5], [D || #{dst := D} <- element(2, graphdb:out_edges(H, IVid))]),
                ?assertEqual([9], [S || #{src := S} <- element(2, graphdb:in_edges(H, IVid))]),
                Keys = bitcask:list_keys(H),
                ?assertEqual([], [K || <<"e", _/binary>> = K <- Keys]),
                ?assertEqual([], [K || <<"deg", _/binary>> = K <- Keys])
            after
                graphdb:close(H)
            end
        end)
     end}}.

migrate_hub_chunked_test_() ->
    {"hub 顶点按目标参数分块；迁移结果与逐条 v2 写入的结果逐顶点相同",
     {timeout, 120, fun() ->
        with_dirs(fun(Src, Dst) ->
            Edges = [{1, 7, D, 0, <<>>} || D <- lists:seq(100, 600)]
                    ++ [{S, 7, 1, 0, <<>>} || S <- lists:seq(700, 900)]
                    ++ [{2, 8, D, 0, <<"p">>} || D <- lists:seq(100, 140)],
            write_v1(Src, [], Edges, []),
            Opts = [{adj_inline_max, 256}, {adj_chunk_max, 256}],
            {ok, #{chunks := NC}} = graphdb_migrate:v1_to_v2(Src, Dst, [{batch_ops, 50} | Opts]),
            ?assert(NC > 10),
            Ref = Dst ++ "_ref",
            R2 = graphdb:open(Ref, [read_write | Opts]),
            ok = graphdb:put_edges(R2, [{S, T, D, #{rank => R, props => P}} || {S, T, D, R, P} <- Edges]),
            H = graphdb:open(Dst, []),
            try
                Vids = [1, 2, 100, 600, 700, 900],
                ?assertEqual(snapshot(R2, Vids), snapshot(H, Vids)),
                ?assertMatch({ok, #{chunks := C}} when C > 10, graphdb:check_invariants(H)),
                ?assertEqual(ok, graphdb_migrate:verify(Src, Dst))
            after
                graphdb:close(H),
                graphdb:close(R2),
                os:cmd("rm -rf " ++ Ref)
            end
        end)
     end}}.

migrate_guards_test_() ->
    {"目标库已有图数据 → dst_not_empty；verify 发现缺失的顶点；v2 库直接打开 v1 目录被拒",
     {timeout, 60, fun() ->
        with_dirs(fun(Src, Dst) ->
            write_v1(Src, [], sample_edges(), []),
            ?assertEqual({error, graph_layout_v1}, graphdb:open(Src, [])),
            {ok, _} = graphdb_migrate:v1_to_v2(Src, Dst, [{verify, false}]),
            ?assertEqual({error, dst_not_empty}, graphdb_migrate:v1_to_v2(Src, Dst)),
            ?assertEqual(ok, graphdb_migrate:verify(Src, Dst)),
            H = graphdb:open(Dst, [read_write]),
            ok = bitcask:delete(H, graphdb:akey(2)),
            ok = graphdb:close(H),
            ?assertMatch({error, {mismatch, 2}}, graphdb_migrate:verify(Src, Dst))
        end)
     end}}.

src_keys(Dir) ->
    B = bitcask:open(Dir, []),
    try lists:sort([{K, bitcask:get(B, K)} || K <- bitcask:list_keys(B)])
    after bitcask:close(B)
    end.
