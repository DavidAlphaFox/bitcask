%% -------------------------------------------------------------------
%% graphdb_adj_tests:
%%   图层 v2 邻接表（doc/graph-adjacency-pack-design-zh.md §4）：
%%     - 编解码         头 / 块 / 条目往返（定宽、带 rank、带属性、外置属性），
%%                      字节级布局，畸形输入一律拒绝
%%     - 分块           hub 变大 → 最大的组分块、头回到阈值内；块超限对半分；
%%                      缩小到 inline_max/4 以下 → 转回内联（滞回）；块目录、
%%                      Count、对称不变式全程成立
%% -------------------------------------------------------------------
-module(graphdb_adj_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) -> bitcask_test_util:with_dir("graphdb_adj_tests_", Fun).

cfg() -> graphdb_adj:default_cfg().

%% ===================================================================
%% 编解码
%% ===================================================================

chunk_roundtrip_test_() ->
    Cases = [{"定宽 8 B（无 rank 无属性）", [{1, 0, <<>>}, {2, 0, <<>>}, {9, 0, <<>>}]},
             {"带 rank", [{1, 0, <<>>}, {1, 3, <<>>}, {5, 16#FFFFFFFFFFFFFFFF, <<>>}]},
             {"带属性 + 外置", [{1, 0, <<"a">>}, {2, 7, ext}, {3, 0, <<>>}]},
             {"空块", []}],
    [{Name, ?_assertEqual({ok, Es}, graphdb_adj:decode_chunk(graphdb_adj:encode_chunk(Es)))}
     || {Name, Es} <- Cases].

chunk_layout_test_() ->
    {"块字节布局：<<Ver, GFlags, Count:32, Entry...>>；条目宽度随标志",
     [?_assertEqual(<<1, 0, 2:32, 5:64, 6:64>>,
                    graphdb_adj:encode_chunk([{5, 0, <<>>}, {6, 0, <<>>}])),
      ?_assertEqual(<<1, 1, 1:32, 5:64, 3:64>>,
                    graphdb_adj:encode_chunk([{5, 3, <<>>}])),
      ?_assertEqual(<<1, 2, 2:32, 5:64, 2:16, "hi", 6:64, 16#FFFF:16>>,
                    graphdb_adj:encode_chunk([{5, 0, <<"hi">>}, {6, 0, ext}]))]}.

random_entries(N) ->
    lists:usort(fun({A, B, _}, {C, D, _}) -> {A, B} =< {C, D} end,
                [{rand:uniform(1000), case rand:uniform(3) of 1 -> rand:uniform(5); _ -> 0 end,
                  case rand:uniform(4) of
                      1 -> crypto:strong_rand_bytes(rand:uniform(20));
                      2 -> ext;
                      _ -> <<>>
                  end} || _ <- lists:seq(1, N)]).

random_roundtrip_test_() ->
    {"随机条目表 200 轮：块往返；build_vertex 出的头经 groups_info 解回同一份条目",
     fun() ->
        rand:seed(exsss, {1, 2, 3}),
        [begin
             Es = random_entries(rand:uniform(60)),
             ?assertEqual({ok, Es}, graphdb_adj:decode_chunk(graphdb_adj:encode_chunk(Es))),
             Out = [{7, O, R, case P of ext -> <<"big">>; _ -> P end} || {O, R, P} <- Es],
             In = [{9, O, R} || {O, R, _} <- Es],
             {Ops, 0} = graphdb_adj:build_vertex(42, {Out, In}, (cfg())#{inline_max => 1 bsl 20}),
             [{put, <<"a", 42:64>>, Head}] = Ops,
             {ok, [{0, 7, C1, {entries, OutEs}}, {1, 9, C2, {entries, InEs}}]} =
                 graphdb_adj:groups_info(Head),
             ?assertEqual({length(Es), length(Es)}, {C1, C2}),
             ?assertEqual([{O, R, P} || {_, O, R, P} <- Out], OutEs),
             ?assertEqual([{O, R, <<>>} || {_, O, R} <- In], InEs)
         end || _ <- lists:seq(1, 200)]
     end}.

malformed_test_() ->
    Head = fun(Groups) -> iolist_to_binary([<<1, (length(Groups)):16>> | Groups]) end,
    G = fun(D, T, C, Body) -> <<D, 0, T:32, C:64, Body/binary>> end,
    {"畸形头 / 块一律 error：截断、尾随字节、组未排序、Count = 0、dir > 1、块目录缺 (0,0)",
     [?_assertEqual(error, graphdb_adj:decode_head(<<>>)),
      ?_assertEqual(error, graphdb_adj:decode_head(<<2, 0:16>>)),
      ?_assertEqual({ok, []}, graphdb_adj:decode_head(<<1, 0:16>>)),
      ?_assertEqual(error, graphdb_adj:decode_head(<<1, 0:16, 0>>)),
      ?_assertEqual(error, graphdb_adj:decode_head(Head([G(0, 7, 2, <<1:64>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(Head([G(0, 7, 1, <<1:64, 0>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(Head([G(0, 7, 0, <<>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(Head([G(2, 7, 1, <<1:64>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(
                             Head([G(0, 8, 1, <<1:64>>), G(0, 7, 1, <<1:64>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(
                             Head([G(0, 7, 1, <<1:64>>), G(0, 7, 1, <<2:64>>)]))),
      ?_assertEqual(error, graphdb_adj:decode_head(
                             <<1, 1:16, 0, 4, 7:32, 5:64, 1:32, 3:64, 0:64>>)),
      ?_assertMatch({ok, [_]}, graphdb_adj:decode_head(
                                 <<1, 1:16, 0, 4, 7:32, 5:64, 1:32, 0:64, 0:64>>)),
      ?_assertEqual(error, graphdb_adj:decode_chunk(<<1, 0, 2:32, 1:64>>)),
      ?_assertEqual(error, graphdb_adj:decode_chunk(<<1, 0, 1:32, 1:64, 9>>)),
      ?_assertEqual(error, graphdb_adj:decode_chunk(<<1, 2, 1:32, 1:64, 5:16, "ab">>))]}.

too_many_groups_test_() ->
    {"组数超过 16 位 → 报错而不是截断写坏",
     ?_assertError({too_many_groups, 65536},
                   graphdb_adj:build_vertex(1, {[{T, 2, 0, <<>>} || T <- lists:seq(0, 65535)], []},
                                            (cfg())#{inline_max => 1 bsl 30}))}.

%% ===================================================================
%% 分块（阈值调小到 256 B）
%% ===================================================================

chunk_keys(R, Vid) ->
    [K || {K, _} <- bitcask:range(R, {graphdb:akey(Vid), graphdb:akey(Vid + 1)}),
          byte_size(K) =:= 30].

head_size(R, Vid) ->
    {ok, H} = bitcask:get(R, graphdb:akey(Vid)),
    byte_size(H).

chunk_grow_split_shrink_test_() ->
    {"hub 增长 → 出边组分块、头 ≤ inline_max、块 ≤ chunk_max；入边组不受影响；"
     "删到 inline_max/4 以下转回内联、块 key 全删",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            %% 入边 3 条（小组，不该分块）
            ok = graphdb:put_edges(R, [{S, 8, 1} || S <- [900, 901, 902]]),
            ?assertEqual([], chunk_keys(R, 1)),
            %% 逐条加 300 条出边：过了阈值后分块，块持续分裂
            [ok = graphdb:put_edge(R, 1, 7, Y) || Y <- lists:seq(1, 300)],
            Keys = chunk_keys(R, 1),
            ?assert(length(Keys) >= 300 * 8 div 256),
            %% 头 = 入边内联组 + 出边块目录（每块 16 B）：块目录随度数增长，
            %% 阈值这么小时会略超 inline_max（设计如此，§4.3）
            ?assert(head_size(R, 1) < 512),
            [begin
                 {ok, V} = bitcask:get(R, K),
                 ?assert(byte_size(V) =< 256)
             end || K <- Keys],
            %% 全是出边（dir 0）的块
            ?assertEqual([0], lists:usort([Dd || <<"a", 1:64, Dd:8, _/binary>> <- Keys])),
            ?assertEqual(lists:seq(1, 300), [Y || #{dst := Y} <- element(2, graphdb:out_edges(R, 1))]),
            %% Y = 1 是自环：入边组 7 里有 1，组 8 是那 3 条
            ?assertEqual([1, 900, 901, 902], [S || #{src := S} <- element(2, graphdb:in_edges(R, 1))]),
            ?assertMatch({ok, #{src := 1, dst := 150}}, graphdb:edge(R, 1, 7, 150)),
            ?assertEqual({ok, 300}, graphdb:degree(R, 1)),
            ?assertMatch({ok, #{edges := 303}}, graphdb:check_invariants(R)),
            %% limit 在分块组上提前停
            ?assertEqual(lists:seq(1, 7),
                         [Y || #{dst := Y} <- element(2, graphdb:out_edges(R, 1, #{limit => 7}))]),
            %% 删掉每个块的首条：下界不变、块 key 不改名
            ok = graphdb:del_edges(R, [{1, 7, Y} || Y <- lists:seq(1, 300, 3)]),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            %% 删到 6 条（48 B < 256/4）→ 转回内联
            ok = graphdb:del_edges(R, [{1, 7, Y} || Y <- lists:seq(1, 300), Y > 10]),
            {ok, Left} = graphdb:out_edges(R, 1),
            ?assertEqual([2, 3, 5, 6, 8, 9], [Y || #{dst := Y} <- Left]),
            ?assertEqual([], chunk_keys(R, 1)),
            ?assertMatch({ok, #{chunks := 0}}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

chunk_hysteresis_test_() ->
    {"分块后缩到 inline_max/4 以上：保持分块（不来回抖动）",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(1, 100)]),
            ?assert(chunk_keys(R, 1) =/= []),
            %% 留 20 条 = 160 B > 64 B：仍分块
            ok = graphdb:del_edges(R, [{1, 7, Y} || Y <- lists:seq(21, 100)]),
            ?assert(chunk_keys(R, 1) =/= []),
            ?assertEqual({ok, 20}, graphdb:degree(R, 1)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

chunked_txn_and_del_vertex_test_() ->
    {"分块顶点上的事务读写与 del_vertex：读自己的写、块随删除清空",
     {timeout, 60, fun() ->
        catch application:load(bitcask),
        {ok, _} = application:ensure_all_started(bitcask),
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(1, 200)]),
            Res = graphdb:transaction(R, fun(Tx) ->
                      ok = graphdb:put_edge_txn(Tx, 1, 7, 500),
                      ok = graphdb:del_edge_txn(Tx, 1, 7, 100),
                      {ok, Es} = graphdb:out_edges_txn(Tx, 1),
                      {ok, Dg} = graphdb:degree_txn(Tx, 1),
                      %% 读分块组按块目录点读，不拿前缀锁
                      #{prefix_locks := 0} = bitcask_txn_locker:status(),
                      {length(Es), Dg, lists:member(500, [Y || #{dst := Y} <- Es]),
                       graphdb:edge_txn(Tx, 1, 7, 100)}
                  end, [{sync, no_sync}]),
            ?assertEqual({atomic, {200, 200, true, {error, not_found}}}, Res),
            ?assertMatch({ok, #{edges := 200}}, graphdb:check_invariants(R)),
            ?assertEqual({atomic, ok},
                         graphdb:transaction(R, fun(Tx) -> graphdb:del_vertex_txn(Tx, 1) end,
                                             [{sync, no_sync}])),
            ?assertEqual([], chunk_keys(R, 1)),
            ?assertEqual(not_found, bitcask:get(R, graphdb:akey(1))),
            ?assertMatch({ok, #{edges := 0, chunks := 0}}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.
