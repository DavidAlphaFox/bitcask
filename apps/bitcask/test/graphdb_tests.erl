%% -------------------------------------------------------------------
%% graphdb_tests:
%%   图存储层 v2（doc/graph-adjacency-pack-design-zh.md：一个顶点两个 KV +
%%   按 LSN 条件写）的门面覆盖：
%%     - key codec      字节级精确性（n / a / p 定宽大端）+ succ 字典序后继
%%     - 顶点/边 CRUD   两端同批、点查、upsert、自环、大属性落 p 家族、级联删除
%%     - 邻接读取       out/in、etype 收窄、limit、度数（出 / 入）
%%     - 遍历           BFS（depth/dir/etype）、k-hop、双向最短路
%%     - 批量接口       put_edges / del_edges
%%     - 并发           直通写多进程打同一 hub：不丢边、度数精确、两端对称
%%     - 布局           g 键、参数持久化、v1 库拒开
%%     - etype registry 注册/回查/幂等
%%     - 持久性         重开后的可见性
%% -------------------------------------------------------------------
-module(graphdb_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GP, <<1, "_g:">>).

with_dir(Fun) -> bitcask_test_util:with_dir("graphdb_tests_", Fun).

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
    {"nkey = <<1,\"_g:\">> + \"n\" + vid 大端 8 字节",
     ?_assertEqual(<<?GP/binary, "n", 0, 0, 0, 0, 0, 0, 0, 42>>,
                   graphdb:nkey(42))}.

akey_pkey_codec_test_() ->
    {"akey 13 字节、pkey 33 字节，定宽大端",
     [?_assertEqual(<<?GP/binary, "a", 0, 0, 0, 0, 0, 0, 0, 42>>,
                    graphdb:akey(42)),
      ?_assertEqual(<<?GP/binary, "p", 1:64/big, 7:32/big, 2:64/big, 9:64/big>>,
                    graphdb:pkey(1, 7, 2, 9)),
      ?_assertEqual(33, byte_size(graphdb:pkey(1, 7, 2, 0)))]}.

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
      ?_assertError(badarg, graphdb:akey(-1)),
      ?_assertError(badarg, graphdb:pkey(1, 16#100000000, 2, 0)),
      ?_assertError(badarg, graphdb:pkey(1, 7, 2, -1)),
      ?_assertError(badarg, graphdb:put_edge(no_handle, 1, 16#100000000, 2))]}.

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
    {"del_edge 两端同批摘除",
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
    {"out/in：(etype, 对端, rank) 序输出；etype 收窄；limit",
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
    {"degree / in_degree 读头即得（全类型 / 单类型 / 零度）",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, 3}, graphdb:degree(R, 1, undefined)),
            ?assertEqual({ok, 3}, graphdb:degree(R, 1)),
            ?assertEqual({ok, 1}, graphdb:degree(R, 1, 8)),
            ?assertEqual({ok, 0}, graphdb:degree(R, 4, undefined)),
            ?assertEqual({ok, 3}, graphdb:in_degree(R, 3)),
            ?assertEqual({ok, 2}, graphdb:in_degree(R, 3, 7)),
            ?assertEqual({ok, 0}, graphdb:in_degree(R, 1)),
            ?assertEqual({ok, 0}, graphdb:degree(R, 99)),
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

%% 单字符类型名的名字索引 key 恰好 9 字节，曾被误当成 id key（下一个 id 变成 0x6E0001xx，写 id key
%% 时还覆盖了那个类型的名字索引）。
etype_registry_one_char_names_test_() ->
    {"etype 注册：单字符名字连着注册，id 仍是 1、2、3，双向回查都对",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ?assertEqual([{ok, 1}, {ok, 2}, {ok, 3}, {ok, 4}],
                         [graphdb:register_etype(R, N) || N <- [<<"X">>, <<"Y">>, <<"Z">>, <<"long">>]]),
            ?assertEqual([{ok, 1}, {ok, 2}, {ok, 3}, {ok, 4}],
                         [graphdb:etype_id(R, N) || N <- [<<"X">>, <<"Y">>, <<"Z">>, <<"long">>]]),
            ?assertEqual([{ok, <<"X">>}, {ok, <<"Y">>}, {ok, <<"Z">>}, {ok, <<"long">>}],
                         [graphdb:etype_name(R, I) || I <- [1, 2, 3, 4]]),
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
%% 度数随边原子更新 + 按类型列边 + 属性过滤遍历
%% ===================================================================

degree_counters_test_() ->
    {"度数：插入 +1、del -1、upsert 不重复计数、per-etype 分立",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
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
    {"del_vertex 级联：邻居的度数同批回落",
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
    {"edges_by_type：扫 a 家族，输出序 = (src,dst,rank)，带属性",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            {ok, E7} = graphdb:edges_by_type(R, 7),
            ?assertEqual([{1, 2}, {1, 3}, {2, 3}, {3, 4}],
                         [{S, Dv} || #{src := S, dst := Dv} <- E7]),
            {ok, E8} = graphdb:edges_by_type(R, 8),
            ?assertEqual([{1, 3, <<"weight:0.9">>}],
                         [{S, Dv, P} || #{src := S, dst := Dv, props := P} <- E8]),
            ?assertEqual(2, length(element(2, graphdb:edges_by_type(R, 7, #{limit => 2})))),
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
            ?assertEqual([777], [Dv || #{dst := Dv} <- Fresh]),
            graphdb:close(R)
        end)
    end}.

hub_read_during_writes_test_() ->
    {"分块 hub 一边并发加 / 删边一边读：每次读都有序、无重复、原有边一条不丢；"
     "consistent 读与写完成后的读一致",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            Base = lists:seq(1000, 1399),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- Base]),
            Parent = self(),
            W = spawn_link(fun() ->
                    [ok = graphdb:put_edge(R, 1, 7, 5000 + I, #{retries => infinity})
                     || I <- lists:seq(1, 150)],
                    [ok = graphdb:del_edge(R, 1, 7, 5000 + I) || I <- lists:seq(1, 150, 2)],
                    Parent ! {self(), done}
                end),
            Reads = read_until_done(R, W, 0),
            ?assert(Reads > 0),
            {ok, Final} = graphdb:out_edges(R, 1, #{consistent => true}),
            Dsts = [Y || #{dst := Y} <- Final],
            ?assertEqual(Base ++ [5000 + I || I <- lists:seq(2, 150, 2)], Dsts),
            ?assertEqual({ok, length(Dsts)}, graphdb:degree(R, 1)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

read_until_done(R, W, N) ->
    receive {W, done} -> N
    after 0 ->
        {ok, Es} = graphdb:out_edges(R, 1, #{consistent => true}),
        Ds = [Y || #{dst := Y} <- Es],
        ?assertEqual(lists:usort(Ds), Ds),
        ?assertEqual([], lists:seq(1000, 1399) -- Ds),
        read_until_done(R, W, N + 1)
    end.

%% ===================================================================
%% del_vertex 按边分批（A7）、计数器读错误传播（A8）、etype 注册并发（A9）
%% ===================================================================

%% 邻居的度数（头里的 Count）应恰好等于它现存的条目数。
counters_consistent(R, Etype, Srcs, Dsts) ->
    [begin
         {ok, Edges} = graphdb:out_edges(R, X, #{etype => Etype}),
         ?assertEqual({ok, length(Edges)}, graphdb:degree(R, X, Etype))
     end || X <- Srcs],
    [begin
         {ok, Edges} = graphdb:in_edges(R, Y, #{etype => Etype}),
         ?assertEqual({ok, length(Edges)}, graphdb:in_degree(R, Y, Etype))
     end || Y <- Dsts],
    ?assertMatch({ok, _}, graphdb:check_invariants(R)),
    ok.

del_vertex_many_batches_test_() ->
    {"hub 顶点 del_vertex 按 64 个邻居一批跨多个原子批：邻居度数精确、头与块清空",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            Dsts = lists:seq(1001, 1150),
            Srcs = lists:seq(2001, 2150),
            %% 300 个邻居 > 64 → 5 批
            [ok = graphdb:put_edge(R, 1, 7, Y) || Y <- Dsts],
            [ok = graphdb:put_edge(R, X, 7, 1) || X <- Srcs],
            ok = graphdb:put_edge(R, 1, 7, 1),           %% 自环
            ?assertEqual({ok, 151}, graphdb:degree(R, 1, 7)),
            ok = graphdb:del_vertex(R, 1),
            ?assertEqual({ok, []}, graphdb:out_edges(R, 1)),
            ?assertEqual({ok, []}, graphdb:in_edges(R, 1)),
            counters_consistent(R, 7, Srcs, Dsts),
            [?assertEqual({ok, 0}, graphdb:degree(R, X, 7)) || X <- Srcs],
            %% 自身的邻接表头（与块）整体删掉
            ?assertEqual(not_found, bitcask:get(R, graphdb:akey(1))),
            ?assertEqual([], bitcask:range(R, {graphdb:akey(1), graphdb:akey(2)})),
            ?assertEqual({ok, 0}, graphdb:degree(R, 1, 7)),
            graphdb:close(R)
        end)
     end}}.

del_vertex_partial_failure_converges_test_() ->
    {"del_vertex 第 2 批失败：已提交的批自洽（两端对称、度数精确）；重跑收敛",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            Dsts = lists:seq(1001, 1150),
            Srcs = lists:seq(2001, 2150),
            [ok = graphdb:put_edge(R, 1, 7, Y) || Y <- Dsts],
            [ok = graphdb:put_edge(R, X, 7, 1) || X <- Srcs],
            Calls = counters:new(1, []),
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, put_batch_atomic,
                        fun(H, Ops) ->
                                counters:add(Calls, 1, 1),
                                case counters:get(Calls, 1) of
                                    2 -> {error, injected};
                                    _ -> meck:passthrough([H, Ops])
                                end
                        end),
            try
                ?assertEqual({error, injected}, graphdb:del_vertex(R, 1)),
                ?assert(counters:get(Calls, 1) >= 2)
            after
                meck:unload(bitcask)
            end,
            %% 第 1 批已提交、第 2 批没提交：顶点还在，剩下的边与计数自洽
            ?assertMatch({ok, [_ | _]}, graphdb:out_edges(R, 1)),
            counters_consistent(R, 7, Srcs, Dsts),
            %% 重跑：收敛到全删、全部计数精确
            ok = graphdb:del_vertex(R, 1),
            ?assertEqual({ok, []}, graphdb:out_edges(R, 1)),
            ?assertEqual({ok, []}, graphdb:in_edges(R, 1)),
            counters_consistent(R, 7, Srcs, Dsts),
            [?assertEqual({ok, 0}, graphdb:degree(R, X, 7)) || X <- Srcs],
            ?assertEqual(not_found, bitcask:get(R, graphdb:akey(1))),
            graphdb:close(R)
        end)
     end}}.

head_read_error_propagates_test_() ->
    {"邻接表头读错误 → put_edge/del_edge 返回 {error, _}，整批不提交；坏头不被覆盖",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            ?assertEqual({ok, 2}, graphdb:degree(R, 1, 7)),
            Boom = graphdb:akey(9),
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, get_with_ord,
                        fun(_H, K) when K =:= Boom -> {error, io_error};
                           (H, K) -> meck:passthrough([H, K])
                        end),
            try
                ?assertEqual({error, io_error}, graphdb:put_edge(R, 1, 7, 9)),
                ?assertEqual({error, io_error}, graphdb:put_edge(R, 9, 7, 1)),
                ?assertEqual({error, io_error}, graphdb:del_vertex(R, 9))
            after
                meck:unload(bitcask)
            end,
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 7, 9)),
            ?assertEqual({ok, #{src => 1, etype => 7, dst => 2, rank => 0, props => <<>>}},
                         graphdb:edge(R, 1, 7, 2)),
            ?assertEqual({ok, 2}, graphdb:degree(R, 1, 7)),
            %% 记录形态不对也不覆盖
            ok = bitcask:put(R, graphdb:akey(5), <<"garbage">>),
            ?assertEqual({error, {bad_adj, 5}}, graphdb:put_edge(R, 5, 7, 6)),
            ?assertEqual({error, {bad_adj, 5}}, graphdb:put_edge(R, 6, 7, 5)),
            ?assertEqual({error, {bad_adj, 5}}, graphdb:out_edges(R, 5)),
            ?assertEqual({ok, <<"garbage">>}, bitcask:get(R, graphdb:akey(5))),
            ?assertEqual({ok, []}, graphdb:out_edges(R, 6)),
            graphdb:close(R)
        end)
     end}.

register_etype_concurrent_test_() ->
    {"16 进程并发注册 16 个不同名字 → 16 个不同 id；同名并发 → 同一个 id",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            Me = self(),
            Names = [<<"et-", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 16)],
            Ps = [spawn_link(fun() -> Me ! {self(), graphdb:register_etype(R, N)} end)
                  || N <- Names],
            Ids = [receive {P, {ok, Id}} -> Id end || P <- Ps],
            ?assertEqual(lists:seq(1, 16), lists:sort(Ids)),
            %% 名字 ↔ id 双向一致
            [?assertEqual({ok, N}, graphdb:etype_name(R, element(2, graphdb:etype_id(R, N))))
             || N <- Names],
            Ps2 = [spawn_link(fun() -> Me ! {self(), graphdb:register_etype(R, <<"same">>)} end)
                   || _ <- lists:seq(1, 16)],
            Same = [receive {P, Res} -> Res end || P <- Ps2],
            ?assertEqual([{ok, 17}], lists:usort(Same)),
            ?assertEqual({ok, 17}, graphdb:register_etype(R, <<"same">>)),
            ?assertEqual({ok, 18}, graphdb:register_etype(R, <<"later">>)),
            graphdb:close(R)
        end)
     end}}.

%% ===================================================================
%% 6.7.0 B 档：hub 去重不再二次方、expand 分片 + 失败清理、
%% range_take 计数、strict 计数（$i 开头的 vid）
%% ===================================================================

neighbors_hub_dedupe_test_() ->
    {"hub 5000 出邻居（前 100 个经第二个 etype 重复）：去重、保序、长度 5000",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ok = graphdb:put_edges(R, [{0, 7, I} || I <- lists:seq(1, 5000)]),
            [ok = graphdb:put_edge(R, 0, 8, I) || I <- lists:seq(1, 100)],
            {ok, Ns} = graphdb:neighbors(R, 0, out),
            ?assertEqual(lists:seq(1, 5000), Ns),
            %% limit 走计数路径：拿前 10 个（etype 7 块在前，按 dst 升序）
            ?assertEqual(lists:seq(1, 10), dsts_of(graphdb:out_edges(R, 0, #{limit => 10}))),
            ?assertEqual({ok, 5100}, graphdb:degree(R, 0)),
            graphdb:close(R)
        end)
     end}}.

bfs_expand_failure_cleans_up_test_() ->
    {"展开途中引擎报错：bfs 返回 {error,{graphdb_expand,_}}，信箱里没有残留的 worker 消息",
     fun() ->
        with_dir(fun(D) ->
            R = seeded(D),
            Boom = graphdb:akey(3),
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, get_with_ord,
                        fun(_H, K) when K =:= Boom -> {error, boom};
                           (H, K) -> meck:passthrough([H, K])
                        end),
            try
                %% 第二层 frontier = [2, 3]：3 的展开失败，2 那片被 kill
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:bfs(R, 1, #{})),
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:k_hop(R, 1, 3, #{}))
            after
                meck:unload(bitcask)
            end,
            timer:sleep(50),
            {messages, Msgs} = process_info(self(), messages),
            Leaked = [M || M <- Msgs,
                           (is_tuple(M) andalso tuple_size(M) =:= 5
                            andalso element(3, M) =:= process)          %% DOWN（带 tag 或不带）
                           orelse (is_tuple(M) andalso tuple_size(M) =:= 3
                                   andalso is_reference(element(1, M)))], %% {Ref, Idx, Lists}
            ?assertEqual([], Leaked),
            %% 引擎恢复后照常
            ?assertEqual({ok, [{1, 0}, {2, 1}, {3, 1}, {4, 2}]}, graphdb:bfs(R, 1, #{})),
            graphdb:close(R)
        end)
     end}.

bfs_large_frontier_test_() ->
    {"星形 0→1..300 再 →301：frontier 300 个顶点分片展开，结果与逐点语义一致",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            [ok = graphdb:put_edge(R, 0, 7, I) || I <- lists:seq(1, 300)],
            [ok = graphdb:put_edge(R, I, 7, 301) || I <- lists:seq(1, 300)],
            {ok, Reach} = graphdb:bfs(R, 0, #{}),
            ?assertEqual([{0, 0} | [{I, 1} || I <- lists:seq(1, 300)]] ++ [{301, 2}], Reach),
            ?assertEqual({ok, lists:seq(1, 300) ++ [301]}, graphdb:k_hop(R, 0, 2, #{})),
            graphdb:close(R)
        end)
     end}}.

extreme_vids_chunk_ranges_test_() ->
    {"vid / etype 取到边界（0、2^64-1、2^32-1）且分块：相邻顶点的块区间互不串扰",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 128}, {adj_chunk_max, 128}]),
            Max = 16#FFFFFFFFFFFFFFFF, TMax = 16#FFFFFFFF,
            ok = graphdb:put_edges(R, [{Max, TMax, I} || I <- lists:seq(1, 100)]
                                      ++ [{Max - 1, TMax, I} || I <- lists:seq(201, 300)]
                                      ++ [{I, TMax, Max} || I <- lists:seq(1, 100)]
                                      ++ [{0, 0, I} || I <- lists:seq(1, 100)]),
            ?assertEqual(lists:seq(1, 100), dsts_of(graphdb:out_edges(R, Max))),
            ?assertEqual(lists:seq(201, 300), dsts_of(graphdb:out_edges(R, Max - 1))),
            ?assertEqual(lists:seq(1, 100), srcs_of(graphdb:in_edges(R, Max))),
            ?assertEqual(lists:seq(1, 100), dsts_of(graphdb:out_edges(R, 0))),
            ?assertEqual({ok, 100}, graphdb:degree(R, Max, TMax)),
            ?assertEqual({ok, 100}, graphdb:in_degree(R, Max)),
            {ok, #{chunks := NC}} = graphdb:check_invariants(R),
            ?assert(NC > 4),
            graphdb:close(R)
        end)
     end}}.

%% ===================================================================
%% shortest_path：大 frontier 并行展开、失败清理
%% ===================================================================

%% 0 →(7) 1..300 →(7) 1001..1300 →(7) 5000。第二轮起两侧 frontier 都是 300 个顶点
%% （超过串行阈值 256），走并行分片展开；路径必须与逐点串行语义一致（frontier 序、邻居序）。
wide_graph(D) ->
    R = graphdb:open(D, [read_write]),
    ok = graphdb:put_edges(R, lists:append([[{0, 7, I}, {I, 7, 1000 + I}, {1000 + I, 7, 5000}]
                                            || I <- lists:seq(1, 300)])),
    R.

shortest_path_wide_frontier_test_() ->
    {"两侧 frontier 各 300 个顶点：并行展开，路径 = 串行语义下的第一条",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = wide_graph(D),
            ?assertEqual({ok, [0, 1, 1001, 5000]}, graphdb:shortest_path(R, 0, 5000)),
            ?assertEqual({ok, [7, 1007, 5000]}, graphdb:shortest_path(R, 7, 5000)),
            ?assertEqual({error, no_path}, graphdb:shortest_path(R, 5000, 0)),
            graphdb:close(R)
        end)
     end}}.

%% 展开途中引擎报错：串行路径（frontier ≤ 256）与并行路径都返回 {error, _}，
%% 调用方信箱里不留 worker 的结果 / DOWN。
shortest_path_expand_failure_test_() ->
    {"展开失败：串行 / 并行两条路径都返回 {error,{graphdb_expand,_}}，信箱干净",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = wide_graph(D),
            Boom = graphdb:akey(7),                 %% 顶点 7 的邻接表头
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, get_with_ord,
                        fun(_H, K) when K =:= Boom -> {error, boom};
                           (H, K) -> meck:passthrough([H, K])
                        end),
            try
                %% 串行：起点就是 7，第一层 frontier = [7]
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:shortest_path(R, 7, 5000)),
                %% 并行：第三轮展开 fwd frontier = [1..300]，7 那片失败、其余片被 kill
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:shortest_path(R, 0, 5000))
            after
                meck:unload(bitcask)
            end,
            timer:sleep(50),
            {messages, Msgs} = process_info(self(), messages),
            Leaked = [M || M <- Msgs,
                           (is_tuple(M) andalso tuple_size(M) =:= 5
                            andalso element(3, M) =:= process)
                           orelse (is_tuple(M) andalso tuple_size(M) =:= 3
                                   andalso is_reference(element(1, M)))],
            ?assertEqual([], Leaked),
            ?assertEqual({ok, [0, 1, 1001, 5000]}, graphdb:shortest_path(R, 0, 5000)),
            graphdb:close(R)
        end)
     end}}.

%% ===================================================================
%% v2：key 数量、大属性、自环、批量接口、布局
%% ===================================================================

key_count_is_per_vertex_test_() ->
    {"10 个顶点之间 90 条边：key = 10 个顶点 + 10 个邻接表头 + g（v1 是 10 + 270 + 计数键）",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            Vs = lists:seq(1, 10),
            [ok = graphdb:put_vertex(R, V, <<"v">>) || V <- Vs],
            ok = graphdb:put_edges(R, [{S, 7, T} || S <- Vs, T <- Vs, S =/= T]),
            Keys = bitcask:list_keys(R),
            ?assertEqual(21, length(Keys)),
            ?assertEqual({ok, 9}, graphdb:degree(R, 3)),
            ?assertEqual({ok, 9}, graphdb:in_degree(R, 3)),
            graphdb:close(R)
        end)
     end}.

large_props_lifecycle_test_() ->
    {"属性超过 props_inline_max 落 p 家族；改小回内联并删 p 键；删边连 p 键一起删",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {props_inline_max, 16}]),
            Big = binary:copy(<<"x">>, 100),
            PK = graphdb:pkey(1, 7, 2, 0),
            ok = graphdb:put_edge(R, 1, 7, 2, #{props => Big}),
            ?assertEqual({ok, Big}, bitcask:get(R, PK)),
            ?assertMatch({ok, #{props := Big}}, graphdb:edge(R, 1, 7, 2)),
            ?assertMatch({ok, [#{props := Big}]}, graphdb:out_edges(R, 1)),
            ?assertMatch({ok, [#{props := Big}]}, graphdb:edges_by_type(R, 7)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            Big2 = binary:copy(<<"y">>, 50),
            ok = graphdb:put_edge(R, 1, 7, 2, #{props => Big2}),
            ?assertEqual({ok, Big2}, bitcask:get(R, PK)),
            ok = graphdb:put_edge(R, 1, 7, 2, #{props => <<"small">>}),
            ?assertEqual(not_found, bitcask:get(R, PK)),
            ?assertMatch({ok, #{props := <<"small">>}}, graphdb:edge(R, 1, 7, 2)),
            ok = graphdb:put_edge(R, 1, 7, 2, #{props => Big}),
            ok = graphdb:del_edge(R, 1, 7, 2),
            ?assertEqual(not_found, bitcask:get(R, PK)),
            ?assertEqual({ok, []}, graphdb:out_edges(R, 1)),
            ok = graphdb:put_edge(R, 1, 7, 3, #{props => Big}),
            ok = graphdb:del_vertex(R, 1),
            ?assertEqual(not_found, bitcask:get(R, graphdb:pkey(1, 7, 3, 0))),
            ?assertMatch({ok, #{edges := 0}}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}.

self_loop_and_rank_test_() ->
    {"自环两侧各一条、同一个头里改两组；多 rank 平行边；删自环 / del_vertex 清干净",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ok = graphdb:put_edge(R, 1, 7, 1),
            ok = graphdb:put_edge(R, 1, 7, 2, #{rank => 5}),
            ok = graphdb:put_edge(R, 1, 7, 2, #{rank => 9, props => <<"r9">>}),
            ?assertEqual({ok, 3}, graphdb:degree(R, 1)),
            ?assertEqual({ok, 1}, graphdb:in_degree(R, 1)),
            ?assertEqual([{1, 0}, {2, 5}, {2, 9}],
                         [{Dv, Rk} || #{dst := Dv, rank := Rk} <- element(2, graphdb:out_edges(R, 1))]),
            ?assertMatch({ok, #{props := <<"r9">>}}, graphdb:edge(R, 1, 7, 2, 9)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 7, 2)),
            ok = graphdb:del_edge(R, 1, 7, 1),
            ?assertEqual({ok, 0}, graphdb:in_degree(R, 1)),
            ok = graphdb:put_edge(R, 1, 7, 1),
            ok = graphdb:del_vertex(R, 1),
            ?assertEqual(not_found, bitcask:get(R, graphdb:akey(1))),
            ?assertEqual({ok, []}, graphdb:in_edges(R, 2)),
            ?assertMatch({ok, #{edges := 0, vertices := 0}}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}.

put_del_edges_batch_test_() ->
    {"put_edges / del_edges：跨批（> 256 个顶点）、批内 upsert 取最后一次、幂等删",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            Es = [{I, 7, I + 1} || I <- lists:seq(1, 600)],
            ok = graphdb:put_edges(R, Es ++ [{1, 7, 2, #{props => <<"last">>}}]),
            ?assertMatch({ok, #{props := <<"last">>}}, graphdb:edge(R, 1, 7, 2)),
            {ok, Path} = graphdb:shortest_path(R, 1, 601),
            ?assertEqual(lists:seq(1, 601), Path),
            ok = graphdb:del_edges(R, [{I, 7, I + 1} || I <- lists:seq(1, 600, 2)]
                                      ++ [{1, 7, 2, 0}, {999, 7, 1000}]),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 7, 2)),
            ?assertMatch({ok, _}, graphdb:edge(R, 2, 7, 3)),
            ?assertMatch({ok, #{edges := 300}}, graphdb:check_invariants(R)),
            ?assertError(badarg, graphdb:put_edges(R, [{1, 7}])),
            graphdb:close(R)
        end)
     end}}.

layout_and_config_test_() ->
    {"建库写 g（缺省布局 2 + 参数；指定布局 1）；重开以 g 为准；旧图库拒开",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 512}]),
            ?assertEqual(#{layout => 2, inline_max => 512, chunk_max => 65536, props_max => 128,
                           chunk_entries => 512, chunk_count_max => 65536,
                           dir_inline_max => 16, dir_node_max => 256},
                         graphdb:graph_config(R)),
            {ok, <<2, _:22/binary>>} = bitcask:get(R, <<?GP/binary, "g">>),
            ok = graphdb:close(R),
            R2 = graphdb:open(D, [read_write, {adj_inline_max, 9999}]),
            ?assertEqual(512, maps:get(inline_max, graphdb:graph_config(R2))),
            ok = graphdb:close(R2),
            ?assertError({badarg, {adj_chunk_max, 1}},
                         graphdb:open(D ++ "_x", [read_write, {adj_chunk_max, 1}])),
            ?assertError({badarg, {adj_layout, 3}},
                         graphdb:open(D ++ "_x", [read_write, {adj_layout, 3}])),
            ?assertError({badarg, {adj_dir_node_max, 2}},
                         graphdb:open(D ++ "_x", [read_write, {adj_dir_node_max, 2}]))
        end),
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_layout, 1}, {adj_inline_max, 512}]),
            ?assertEqual(#{layout => 1, inline_max => 512, chunk_max => 4096, props_max => 128},
                         graphdb:graph_config(R)),
            {ok, <<1, _:10/binary>>} = bitcask:get(R, <<?GP/binary, "g">>),
            ok = graphdb:close(R)
        end),
        with_dir(fun(D) ->
            B = bitcask:open(D, [read_write]),
            %% 加全局前缀前的中间布局是 g 版本 2。
            ok = bitcask:put(B, <<"g">>, <<2:8, 4096:32/big, 4096:32/big, 128:16/big>>),
            ok = bitcask:close(B),
            ?assertEqual({error, graph_layout_unprefixed_v2},
                         graphdb:open(D, [read_write]))
        end),
        with_dir(fun(D) ->
            B = bitcask:open(D, [read_write]),
            ok = bitcask:put(B, <<"e", 1:64/big, 7:32/big, 2:64/big, 0:64/big>>, <<>>),
            ok = bitcask:put(B, <<"ei", 2:64/big, 7:32/big, 1:64/big, 0:64/big>>, <<>>),
            ok = bitcask:close(B),
            ?assertEqual({error, graph_layout_v1}, graphdb:open(D, [read_write])),
            %% 拒开后写锁已释放
            B2 = bitcask:open(D, [read_write]),
            ok = bitcask:close(B2)
        end)
     end}.

%% ===================================================================
%% 直通写的并发正确性（条件写 + 重试，§12「并发正确性」）
%% ===================================================================

concurrent_direct_writers_same_hub_test_() ->
    {"16 进程直通 put_edge 打同一 hub（出入两侧都是热点）：不丢边、度数 = 条目数、两端对称",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ?assertEqual({error, not_found}, graphdb:get_vertex(R, 1)),   %% 预热
            Hub = 1, NProc = 16, PerProc = 25,
            Parent = self(),
            Pids = [spawn_link(fun() ->
                        Rs = [begin
                                  Dst = P * 1000 + I,
                                  A = graphdb:put_edge(R, Hub, 7, Dst, #{retries => infinity}),
                                  B = graphdb:put_edge(R, Dst, 7, Hub, #{retries => infinity}),
                                  {A, B}
                              end || I <- lists:seq(1, PerProc)],
                        Parent ! {self(), Rs}
                    end) || P <- lists:seq(1, NProc)],
            All = lists:append([receive {P, Rs} -> Rs end || P <- Pids]),
            ?assertEqual([], [X || X <- All, X =/= {ok, ok}]),
            N = NProc * PerProc,
            ?assertEqual({ok, N}, graphdb:degree(R, Hub, 7)),
            ?assertEqual({ok, N}, graphdb:in_degree(R, Hub, 7)),
            ?assertEqual(N, length(element(2, graphdb:out_edges(R, Hub)))),
            ?assertEqual(N, length(element(2, graphdb:in_edges(R, Hub)))),
            ?assertMatch({ok, #{edges := E}} when E =:= 2 * N, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

concurrent_mixed_ops_invariants_test_() ->
    {"8 个加 / 删边进程 + 2 个 del_vertex 进程在 12 个顶点上随机交错（分块阈值调小）"
     "→ 对称、度数、块目录不变式成立",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 128}, {adj_chunk_max, 128}]),
            ?assertEqual({error, not_found}, graphdb:get_vertex(R, 1)),
            NV = 12,
            Parent = self(),
            Ws = [spawn_link(fun() ->
                      rand:seed(exsss, {P, P, P}),
                      [begin
                           S = rand:uniform(NV), T = rand:uniform(NV),
                           Rk = rand:uniform(4),
                           ok = case rand:uniform(3) of
                                    3 -> retry_conflict(fun() -> graphdb:del_edge(R, S, 7, T, Rk) end);
                                    _ -> graphdb:put_edge(R, S, 7, T, #{rank => Rk, retries => infinity})
                                end
                       end || _ <- lists:seq(1, 120)],
                      Parent ! {self(), done}
                  end) || P <- lists:seq(1, 8)],
            Ds = [spawn_link(fun() ->
                      rand:seed(exsss, {P, P, P}),
                      [ok = del_vertex_retry(R, rand:uniform(NV)) || _ <- lists:seq(1, 10)],
                      Parent ! {self(), done}
                  end) || P <- [100, 101]],
            [receive {P, done} -> ok end || P <- Ws ++ Ds],
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

%% del_vertex / del_edge 自带 8 次重试；热点下仍可能耗尽，测试里耗尽就再来。
del_vertex_retry(R, V) ->
    retry_conflict(fun() -> graphdb:del_vertex(R, V) end).

retry_conflict(F) ->
    case F() of
        {error, conflict} -> retry_conflict(F);
        Other             -> Other
    end.

put_edges_sort_and_batch_opts_test_() ->
    {"put_edges 稳定排序：跨 src 交错的重复边仍是最后一次生效；sort => false / "
     "batch_vids 小批结果相同；坏选项 badarg",
     {timeout, 60, fun() ->
        Edges = [{S, 7, D, #{props => integer_to_binary(I)}}
                 || I <- lists:seq(1, 300), S <- [(I * 7) rem 13], D <- [(I * 11) rem 17]],
        Snap = fun(R) -> [{V, element(2, graphdb:out_edges(R, V)), element(2, graphdb:in_edges(R, V))}
                          || V <- lists:seq(0, 17)] end,
        Results = [with_dir(fun(D) ->
                       R = graphdb:open(D, [read_write]),
                       ok = graphdb:put_edges(R, Edges, O),
                       ?assertMatch({ok, _}, graphdb:check_invariants(R)),
                       Sn = Snap(R),
                       graphdb:close(R),
                       Sn
                   end) || O <- [#{}, #{sort => false}, #{batch_vids => 2}, #{batch_vids => 4096}]],
        ?assertEqual(1, length(lists:usort(Results))),
        %% 最后一次生效：(S, D) 对的最后一个 I
        Last = maps:from_list([{{S, D}, P} || {S, _, D, #{props := P}} <- Edges]),
        [{0, Out, _} | _] = hd(Results),
        ?assert(Out =/= []),
        [?assertEqual(maps:get({0, Dv}, Last), P) || #{dst := Dv, props := P} <- Out],
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ?assertError(badarg, graphdb:put_edges(R, [{1, 7, 2}], #{sort => maybe_not})),
            ?assertError(badarg, graphdb:put_edges(R, [{1, 7, 2}], #{batch_vids => 1})),
            ok = graphdb:del_edges(R, [{1, 7, 2}], #{sort => false, batch_vids => 2}),
            graphdb:close(R)
        end)
     end}}.

%% ===================================================================
%% 自审小问题的回归
%% ===================================================================

config_without_cache_test_() ->
    {"图参数随用随读 g：bitcask:open 拿到的句柄也用建库参数写；关库不留进程外残留",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:close(R),
            B = bitcask:open(D, [read_write]),
            ?assertEqual(256, maps:get(inline_max, graphdb:graph_config(B))),
            ok = graphdb:put_edges(B, [{1, 7, Y} || Y <- lists:seq(1, 100)]),
            {ok, #{chunks := NC}} = graphdb:check_invariants(B),
            ?assert(NC > 0),                       %% 按 256 分了块，不是默认 4 KiB
            ok = bitcask:close(B),
            ?assertEqual([], [K || {{graphdb_cfg, _} = K, _} <- persistent_term:get()])
        end)
     end}.

v1_probe_needs_reverse_key_test_() ->
    {"应用自己有 29 字节的 \"e…\" key（没有配对的 ei）：不误判成 v1 库",
     fun() ->
        with_dir(fun(D) ->
            B = bitcask:open(D, [read_write]),
            ok = bitcask:put(B, <<"e", 0:224>>, <<"app">>),
            ok = bitcask:close(B),
            R = graphdb:open(D, [read_write]),
            ?assertNotMatch({error, _}, R),
            ok = graphdb:put_edge(R, 1, 7, 2),
            ?assertEqual({ok, <<"app">>}, bitcask:get(R, <<"e", 0:224>>)),
            graphdb:close(R)
        end)
     end}.

del_vertex_opts_test_() ->
    {"del_vertex/3：batch_neighbors => infinity 时 150 个邻居一批原子删完；坏选项 badarg",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(100, 249)]),
            Calls = counters:new(1, []),
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, put_batch_atomic,
                        fun(H, Ops) -> counters:add(Calls, 1, 1), meck:passthrough([H, Ops]) end),
            try
                ok = graphdb:del_vertex(R, 1, #{batch_neighbors => infinity, retries => infinity})
            after
                meck:unload(bitcask)
            end,
            ?assertEqual(1, counters:get(Calls, 1)),
            ?assertMatch({ok, #{edges := 0}}, graphdb:check_invariants(R)),
            ?assertError(badarg, graphdb:del_vertex(R, 1, #{batch_neighbors => 0})),
            graphdb:close(R)
        end)
     end}}.

%% ===================================================================
%% G10：hub 路径的性能回归（读写次数 / 写盘量是确定的，不看墙钟）
%% ===================================================================

%% 统计 Fun 运行期间 bitcask 门面上若干函数的调用次数：#{Name => N}。
count_calls(Names, Fun) ->
    C = counters:new(length(Names), []),
    Idx = maps:from_list(lists:zip(Names, lists:seq(1, length(Names)))),
    meck:new(bitcask, [passthrough]),
    [meck:expect(bitcask, N,
                 case N of
                     get_with_ord ->
                         fun(H, K) -> counters:add(C, maps:get(N, Idx), 1), meck:passthrough([H, K]) end;
                     put_batch_atomic ->
                         fun(H, Ops) -> counters:add(C, maps:get(N, Idx), 1), meck:passthrough([H, Ops]) end;
                     range_fold ->
                         fun(H, Rg, O, F, A) -> counters:add(C, maps:get(N, Idx), 1),
                                               meck:passthrough([H, Rg, O, F, A]) end
                 end) || N <- Names],
    Res = try Fun() after meck:unload(bitcask) end,
    {Res, maps:map(fun(_N, I) -> counters:get(C, I) end, Idx)}.

del_vertex_hub_reads_only_needed_chunks_test_() ->
    {"del_vertex 删分块 hub：每轮只读够一批邻居的块，读次数与轮数成正比（不是每轮读全部块）；"
     "同一邻居跨组 / 跨方向、自环都删干净",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            Out7 = lists:seq(1001, 3000),                 %% 2000 条出边 → 几十个块
            In8  = lists:seq(2501, 3300),                 %% 800 条入边，与 Out7 重叠 500 个邻居
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- Out7]),
            ok = graphdb:put_edges(R, [{X, 8, 1} || X <- In8]),
            ok = graphdb:put_edges(R, [{1, 9, Y, #{rank => 3}} || Y <- lists:seq(1001, 1100)]),
            ok = graphdb:put_edge(R, 1, 7, 1),            %% 自环
            {ok, #{chunks := NChunks}} = graphdb:check_invariants(R),
            ?assert(NChunks > 60),
            BatchN = 16,
            {ok, #{get_with_ord := Gets, put_batch_atomic := Rounds, range_fold := Ranges}} =
                count_calls([get_with_ord, put_batch_atomic, range_fold],
                            fun() -> graphdb:del_vertex(R, 1, #{batch_neighbors => BatchN}) end),
            ?assertEqual(0, Ranges),
            ?assert(Rounds >= 2300 div BatchN),
            %% 每轮：V 的头 + 至多几个块 + BatchN 个邻居的头。旧实现每轮另读全部 NChunks 个块。
            ?assert(Gets =< Rounds * (BatchN + 8)),
            ?assertEqual(not_found, bitcask:get(R, graphdb:akey(1))),
            ?assertEqual([], bitcask:range(R, {graphdb:akey(1), graphdb:akey(2)})),
            ?assertMatch({ok, #{edges := 0, chunks := 0}}, graphdb:check_invariants(R)),
            [?assertEqual({ok, 0}, graphdb:in_degree(R, Y)) || Y <- [1001, 2000, 3000]],
            [?assertEqual({ok, 0}, graphdb:degree(R, X)) || X <- [2501, 3300]],
            graphdb:close(R)
        end)
     end}}.

chunked_read_by_directory_test_() ->
    {"分块组的直通读按块目录点读（布局 1：目录在头里）：limit 只读用到的块、不开 range；全量 / "
     "etype / 事务读结果不变；目录里有、盘上没有的块按空处理；degree 只读头",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_layout, 1}, {adj_inline_max, 256},
                                 {adj_chunk_max, 256}]),
            Dsts = lists:seq(1001, 3000),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- Dsts]),
            ok = graphdb:put_edges(R, [{1, 8, Y} || Y <- lists:seq(5001, 5010)]),
            {Lim, #{get_with_ord := G1, range_fold := Rg1}} =
                count_calls([get_with_ord, range_fold],
                            fun() -> graphdb:out_edges(R, 1, #{limit => 5}) end),
            ?assertEqual(lists:seq(1001, 1005), dsts_of(Lim)),
            ?assertEqual({2, 0}, {G1, Rg1}),              %% 头 + 块 0
            {Deg, #{get_with_ord := G2}} =
                count_calls([get_with_ord], fun() -> graphdb:degree(R, 1, 7) end),
            ?assertEqual({{ok, 2000}, 1}, {Deg, G2}),
            {Full, #{range_fold := Rg3}} =
                count_calls([range_fold], fun() -> graphdb:out_edges(R, 1) end),
            ?assertEqual(Dsts ++ lists:seq(5001, 5010), dsts_of(Full)),
            ?assertEqual(0, Rg3),
            ?assertEqual(lists:seq(5001, 5010), dsts_of(graphdb:out_edges(R, 1, #{etype => 8}))),
            %% limit 跨到下一个组
            ?assertEqual(lists:seq(2996, 3000) ++ [5001, 5002],
                         lists:nthtail(1995, dsts_of(graphdb:out_edges(R, 1, #{limit => 2002})))),
            ?assertEqual({atomic, lists:seq(1001, 1005)},
                         graphdb:transaction(
                           R, fun(Tx) -> dsts_of(graphdb:out_edges_txn(Tx, 1, #{limit => 5})) end)),
            ?assertEqual({atomic, 2010},
                         graphdb:transaction(
                           R, fun(Tx) -> length(dsts_of(graphdb:out_edges_txn(Tx, 1))) end)),
            %% 绕过图层删掉一个中间块：弱一致读跳过它，不报错
            [_, {K2, V2} | _] = [KV || {K, _} = KV <- bitcask:range(R, {graphdb:akey(1), graphdb:akey(2)}),
                                       byte_size(K) =:= 34],
            {ok, Gone} = graphdb_adj:decode_chunk(V2),
            ok = bitcask:delete(R, K2),
            ?assertEqual((Dsts -- [O || {O, _, _} <- Gone]) ++ lists:seq(5001, 5010),
                         dsts_of(graphdb:out_edges(R, 1))),
            graphdb:close(R)
        end)
     end}}.

put_edges_sorts_by_dst_within_src_test_() ->
    {"put_edges 默认按 (src, etype, dst, rank) 排序：hub 的 dst 乱序输入，结果与 sort => false "
     "相同，写盘量少一半以上（一批边落在相邻的块里）",
     {timeout, 120, fun() ->
        N = 3000,
        Edges = [{1, 7, 1000 + (I * 7919) rem 3001} || I <- lists:seq(1, N)],
        Run = fun(O) ->
                  with_dir(fun(D) ->
                      R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
                      ok = graphdb:put_edges(R, Edges, O#{batch_vids => 64}),
                      ?assertMatch({ok, #{edges := N}}, graphdb:check_invariants(R)),
                      Out = dsts_of(graphdb:out_edges(R, 1)),
                      graphdb:close(R),
                      Bytes = lists:sum([filelib:file_size(F)
                                         || F <- filelib:wildcard(filename:join(D, "*.data"))]),
                      {Out, Bytes}
                  end)
              end,
        {OutS, BytesS} = Run(#{}),
        {OutU, BytesU} = Run(#{sort => false}),
        ?assertEqual(OutU, OutS),
        ?assertEqual(lists:usort([D || {_, _, D} <- Edges]), OutS),
        ?assert(BytesS * 2 < BytesU)
     end}}.

%% ===================================================================
%% G11：读路径直接在二进制上解、块目录二分、会话里的条目拉链
%% ===================================================================

read_paths_select_groups_test_() ->
    {"读只解要的组：按方向 / 类型挑组，跳过带属性、带 rank、外置属性、分块的组；"
     "edge 点查内联 / rank / 属性 / 分块；limit 跨组；事务读同结果",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256},
                                 {props_inline_max, 8}]),
            Big = binary:copy(<<"x">>, 40),                       %% > props_inline_max → 外置
            ok = graphdb:put_edges(R, [{1, 3, Y, #{props => <<"p", (Y rem 7 + $0)>>}} || Y <- [10, 11, 12]]),
            ok = graphdb:put_edge(R, 1, 3, 13, #{props => Big}),
            ok = graphdb:put_edges(R, [{1, 4, 20, #{rank => K}} || K <- [0, 5, 9]]),
            ok = graphdb:put_edges(R, [{1, 5, Y, #{rank => 2, props => <<"q">>}} || Y <- [30, 31]]),
            ok = graphdb:put_edges(R, [{1, 6, Y} || Y <- [40, 41, 42]]),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(1001, 1400)]),   %% 分块
            ok = graphdb:put_edges(R, [{X, 8, 1} || X <- [50, 51]]),
            ok = graphdb:put_edges(R, [{60, 9, 1, #{rank => K}} || K <- [1, 2]]),
            {ok, #{chunks := NC}} = graphdb:check_invariants(R),
            ?assert(NC >= 4),
            %% etype 过滤：前面各种形态的组都被跳过
            ?assertEqual([40, 41, 42], dsts_of(graphdb:out_edges(R, 1, #{etype => 6}))),
            ?assertEqual(lists:seq(1001, 1400), dsts_of(graphdb:out_edges(R, 1, #{etype => 7}))),
            {ok, E3} = graphdb:out_edges(R, 1, #{etype => 3}),
            ?assertEqual([{10, <<"p3">>}, {11, <<"p4">>}, {12, <<"p5">>}, {13, Big}],
                         [{Dv, P} || #{dst := Dv, props := P} <- E3]),
            {ok, E4} = graphdb:out_edges(R, 1, #{etype => 4}),
            ?assertEqual([{20, 0}, {20, 5}, {20, 9}], [{Dv, K} || #{dst := Dv, rank := K} <- E4]),
            {ok, E5} = graphdb:out_edges(R, 1, #{etype => 5}),
            ?assertEqual([#{src => 1, etype => 5, dst => 30, rank => 2, props => <<"q">>},
                          #{src => 1, etype => 5, dst => 31, rank => 2, props => <<"q">>}], E5),
            %% 全部出边：组序 × 条目序；limit 跨组
            {ok, All} = graphdb:out_edges(R, 1),
            ?assertEqual(4 + 3 + 2 + 3 + 400, length(All)),
            ?assertEqual(lists:sublist(All, 9), element(2, graphdb:out_edges(R, 1, #{limit => 9}))),
            ?assertEqual(lists:sublist(All, 15), element(2, graphdb:out_edges(R, 1, #{limit => 15}))),
            ?assertEqual({ok, All}, graphdb:out_edges(R, 1, #{consistent => true})),
            ?assertEqual({atomic, {ok, All}},
                         graphdb:transaction(R, fun(Tx) -> graphdb:out_edges_txn(Tx, 1) end)),
            %% 入边
            {ok, In} = graphdb:in_edges(R, 1),
            ?assertEqual([{50, 8, 0}, {51, 8, 0}, {60, 9, 1}, {60, 9, 2}],
                         [{S, T, K} || #{src := S, etype := T, rank := K, dst := 1, props := <<>>} <- In]),
            %% 度数：只读各组的头
            ?assertEqual({ok, 412}, graphdb:degree(R, 1)),
            ?assertEqual({ok, 3}, graphdb:degree(R, 1, 4)),
            ?assertEqual({ok, 4}, graphdb:in_degree(R, 1)),
            %% edge 点查
            ?assertMatch({ok, #{props := <<"p4">>}}, graphdb:edge(R, 1, 3, 11)),
            ?assertMatch({ok, #{props := Big}}, graphdb:edge(R, 1, 3, 13)),
            ?assertMatch({ok, #{rank := 5}}, graphdb:edge(R, 1, 4, 20, 5)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 4, 20, 6)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 6, 41, 1)),   %% 无 rank 的组问 rank
            ?assertMatch({ok, #{props := <<>>}}, graphdb:edge(R, 1, 6, 42)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 6, 43)),
            ?assertMatch({ok, _}, graphdb:edge(R, 1, 7, 1001)),
            ?assertMatch({ok, _}, graphdb:edge(R, 1, 7, 1400)),
            [?assertMatch({ok, _}, graphdb:edge(R, 1, 7, Y)) || Y <- lists:seq(1001, 1400, 13)],
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 7, 1401)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 7, 5)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 1, 99, 5)),
            ?assertEqual({error, not_found}, graphdb:edge(R, 777, 7, 5)),
            ?assertEqual({atomic, {ok, 5}},
                         graphdb:transaction(
                           R, fun(Tx) -> {ok, #{rank := K}} = graphdb:edge_txn(Tx, 1, 4, 20, 5), {ok, K} end)),
            graphdb:close(R)
        end)
     end}}.

neighbor_ids_test_() ->
    {"邻居 id：同一对端的多条 rank / 多个类型只出一次、保序；both 只读一次头；"
     "单组结果不再去重也无重复；BFS / 最短路结果不变",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:put_edges(R, [{1, 4, 20, #{rank => K}} || K <- [0, 5, 9]]),
            ok = graphdb:put_edges(R, [{1, 4, 21, #{rank => 1}}, {1, 5, 20}, {1, 5, 22}]),
            ok = graphdb:put_edges(R, [{22, 6, 1}, {23, 6, 1}, {1, 6, 1}]),
            ?assertEqual({ok, [20, 21, 22, 1]}, graphdb:neighbors(R, 1, out)),
            ?assertEqual({ok, [1, 22, 23]}, graphdb:neighbors(R, 1, in)),
            {Both, #{get_with_ord := G}} =
                count_calls([get_with_ord], fun() -> graphdb:neighbors(R, 1, both) end),
            ?assertEqual({{ok, [20, 21, 22, 1, 23]}, 1}, {Both, G}),
            ?assertEqual({ok, []}, graphdb:neighbors(R, 999, both)),
            %% 分块的带 rank 组：同一对端的 rank 跨块也只出一次
            ok = graphdb:put_edges(R, [{2, 7, Y, #{rank => K}} || Y <- lists:seq(100, 180), K <- [1, 2, 3]]),
            {ok, #{chunks := NC}} = graphdb:check_invariants(R),
            ?assert(NC >= 2),
            ?assertEqual({ok, lists:seq(100, 180)}, graphdb:neighbors(R, 2, out)),
            %% 遍历：both 方向
            {ok, Reach} = graphdb:bfs(R, 23, #{dir => both, depth => 2}),
            ?assertEqual([{23, 0}, {1, 1}, {20, 2}, {21, 2}, {22, 2}], Reach),
            ?assertEqual({ok, [23, 1, 20]}, graphdb:shortest_path(R, 23, 20)),
            graphdb:close(R)
        end)
     end}}.

bad_head_read_errors_test_() ->
    {"头 / 块损坏：各读入口都报 {error, {bad_adj…}}，不崩、不当成空",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:put_edge(R, 1, 7, 2),
            ok = bitcask:put(R, graphdb:akey(1), <<1, 1:16, 0, 0, 7:32, 2:64, 9:64>>),  %% Count 2、只有 1 条
            ?assertEqual({error, {bad_adj, 1}}, graphdb:out_edges(R, 1)),
            ?assertEqual({error, {bad_adj, 1}}, graphdb:in_edges(R, 1)),
            ?assertEqual({error, {bad_adj, 1}}, graphdb:degree(R, 1)),
            ?assertEqual({error, {bad_adj, 1}}, graphdb:edge(R, 1, 7, 9)),
            ?assertEqual({error, {bad_adj, 1}}, graphdb:neighbors(R, 1, both)),
            ?assertEqual({error, {bad_adj, 1}}, graphdb:put_edge(R, 1, 7, 3)),
            %% 坏块
            ok = graphdb:put_edges(R, [{5, 7, Y} || Y <- lists:seq(1001, 1200)]),
            [{CK, _} | _] = [KV || {K, _} = KV <- bitcask:range(R, {graphdb:akey(5), graphdb:akey(6)}),
                                   byte_size(K) =:= 34],
            ok = bitcask:put(R, CK, <<1, 0, 3:32, 1:64>>),
            ?assertEqual({error, {bad_adj_chunk, CK}}, graphdb:out_edges(R, 5)),
            ?assertEqual({error, {bad_adj_chunk, CK}}, graphdb:edge(R, 5, 7, 1001)),
            ?assertEqual({error, {bad_adj_chunk, CK}}, graphdb:neighbors(R, 5, out)),
            ?assertEqual({ok, 200}, graphdb:degree(R, 5)),           %% 度数只看头
            graphdb:close(R)
        end)
     end}.

session_zipper_matches_model_test_() ->
    {"一个会话里对同一张条目表做升序 / 降序 / 乱序的加、改、删（内联与分块，含 rank 与"
     "属性）：结果与模型一致，不变式成立",
     {timeout, 120, fun() ->
        rand:seed(exsss, {7, 8, 9}),
        Run = fun(Order) ->
            with_dir(fun(D) ->
                R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
                Base = [{1, 7, Y, #{rank => Y rem 3}} || Y <- lists:seq(2000, 2600, 2)],
                ok = graphdb:put_edges(R, Base),
                Model0 = maps:from_list([{{Y, K}, <<>>} || {_, _, Y, #{rank := K}} <- Base]),
                %% 三轮：每轮一个大批（一个会话），混着加 / 改属性 / 重复加
                Final = lists:foldl(
                  fun(Round, Model) ->
                      Ys0 = [1990 + rand:uniform(640) || _ <- lists:seq(1, 300)],
                      Ys = case Order of
                               asc  -> lists:sort(Ys0);
                               desc -> lists:reverse(lists:sort(Ys0));
                               rnd  -> Ys0
                           end,
                      Puts = [{1, 7, Y, #{rank => Y rem 3,
                                          props => case Y rem 5 of 0 -> <<"r", (Round + $0)>>; _ -> <<>> end}}
                              || Y <- Ys],
                      ok = graphdb:put_edges(R, Puts, #{sort => false, batch_vids => 100000}),
                      M1 = lists:foldl(fun({_, _, Y, #{rank := K, props := P}}, M) -> M#{{Y, K} => P} end,
                                       Model, Puts),
                      Dels0 = [K || {K, _} <- maps:to_list(M1), rand:uniform(4) =:= 1],
                      Dels = case Order of
                                 asc  -> lists:sort(Dels0);
                                 desc -> lists:reverse(lists:sort(Dels0));
                                 rnd  -> [K || {_, K} <- lists:sort([{rand:uniform(), K} || K <- Dels0])]
                             end,
                      ok = graphdb:del_edges(R, [{1, 7, Y, K} || {Y, K} <- Dels] ++ [{1, 7, 9, 9}],
                                             #{sort => false, batch_vids => 100000}),
                      M2 = maps:without(Dels, M1),
                      {ok, Out} = graphdb:out_edges(R, 1),
                      ?assertEqual(lists:sort(maps:to_list(M2)),
                                   [{{Y, K}, P} || #{dst := Y, rank := K, props := P} <- Out]),
                      ?assertEqual({ok, map_size(M2)}, graphdb:degree(R, 1)),
                      ?assertMatch({ok, _}, graphdb:check_invariants(R)),
                      M2
                  end, Model0, [1, 2, 3]),
                %% 对端的入边组也对得上
                [?assertEqual({ok, length([1 || {{Y2, _}, _} <- maps:to_list(Final), Y2 =:= Y])},
                              graphdb:in_degree(R, Y)) || Y <- [2000, 2100, 2333, 2600]],
                graphdb:close(R)
            end)
        end,
        [Run(O) || O <- [asc, desc, rnd]]
     end}}.

%% ===================================================================
%% G12：定宽条目表在会话里保持二进制，单条增删直接拼接
%% ===================================================================

%% 顶点邻接的盘上字节（头 + 全部块）。
adj_bytes(R, V) ->
    bitcask:range(R, {graphdb:akey(V), graphdb:akey(V + 1)}).

binary_entry_list_single_ops_test_() ->
    {"单条加 / 删边直接在条目区二进制上改：内联组的落盘字节与一次建成的完全相同（含 rank 出现"
     "又删光后收窄回 8 字节宽、加属性后转带属性格式再删回来）；分块 hub 上逐条加删对模型",
     {timeout, 120, fun() ->
        %% ---- 内联：逐条操作 vs 一次建成，字节相同 ----
        Final = [{1, 7, Y} || Y <- [5, 9, 12, 20, 33, 47]] ++ [{1, 8, 3}],
        A = with_dir(fun(D) ->
                R = graphdb:open(D, [read_write]),
                [ok = graphdb:put_edge(R, 1, 7, Y) || Y <- [33, 5, 47, 12, 99, 9, 20, 1]],
                ok = graphdb:put_edge(R, 1, 7, 12),                        %% 原样已在
                ok = graphdb:del_edge(R, 1, 7, 99),
                ok = graphdb:del_edge(R, 1, 7, 1),
                ok = graphdb:del_edge(R, 1, 7, 1000),                      %% 不存在
                ok = graphdb:put_edge(R, 1, 7, 12, #{rank => 4}),          %% 8 → 16 字节宽
                ok = graphdb:put_edge(R, 1, 7, 12, #{rank => 2}),
                ?assertMatch({ok, #{rank := 4}}, graphdb:edge(R, 1, 7, 12, 4)),
                ok = graphdb:del_edge(R, 1, 7, 12, 3),                     %% 不存在的 rank
                ok = graphdb:del_edge(R, 1, 7, 12, 4),
                ok = graphdb:del_edge(R, 1, 7, 12, 2),                     %% rank 删光 → 收窄
                ok = graphdb:put_edge(R, 1, 7, 20, #{props => <<"p">>}),   %% 转带属性
                ?assertMatch({ok, #{props := <<"p">>}}, graphdb:edge(R, 1, 7, 20)),
                ok = graphdb:put_edge(R, 1, 7, 20),                        %% 属性清掉
                ok = graphdb:put_edge(R, 1, 8, 3),
                ok = graphdb:put_edge(R, 1, 8, 4),
                ok = graphdb:del_edge(R, 1, 8, 4),
                ?assertMatch({ok, #{edges := 7}}, graphdb:check_invariants(R)),
                Bs = [adj_bytes(R, V) || V <- [1, 3, 5, 12, 20, 47]],
                graphdb:close(R),
                Bs
            end),
        B = with_dir(fun(D) ->
                R = graphdb:open(D, [read_write]),
                ok = graphdb:put_edges(R, Final),
                Bs = [adj_bytes(R, V) || V <- [1, 3, 5, 12, 20, 47]],
                graphdb:close(R),
                Bs
            end),
        ?assertEqual(B, A),
        %% ---- 分块 hub：逐条加删（穿过块分裂 / 空块删除），与模型一致 ----
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(1000, 1600, 2)]),
            rand:seed(exsss, {11, 12, 13}),
            M = lists:foldl(
                  fun(I, Model) ->
                      Y = 990 + rand:uniform(640),
                      case rand:uniform(3) of
                          1 ->
                              ok = graphdb:del_edge(R, 1, 7, Y),
                              maps:remove({Y, 0}, Model);
                          2 when I rem 50 =:= 0 ->
                              ok = graphdb:put_edge(R, 1, 7, Y, #{rank => 6}),
                              Model#{{Y, 6} => true};
                          _ ->
                              ok = graphdb:put_edge(R, 1, 7, Y),
                              Model#{{Y, 0} => true}
                      end
                  end,
                  maps:from_list([{{Y, 0}, true} || Y <- lists:seq(1000, 1600, 2)]),
                  lists:seq(1, 1500)),
            {ok, Out} = graphdb:out_edges(R, 1),
            ?assertEqual(lists:sort(maps:keys(M)), [{Y, K} || #{dst := Y, rank := K} <- Out]),
            ?assertEqual({ok, map_size(M)}, graphdb:degree(R, 1)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            %% 整段删光：空块删掉、组转回内联 / 消失
            ok = graphdb:del_edges(R, [{1, 7, Y, K} || {Y, K} <- maps:keys(M)]),
            ?assertEqual([], adj_bytes(R, 1)),
            ?assertMatch({ok, #{edges := 0, chunks := 0}}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
     end}}.

binary_entry_list_batch_ops_test_() ->
    {"一个会话里对同一张定宽表改超过 16 次（二进制表转拉链）：结果与逐条提交相同、字节相同",
     {timeout, 60, fun() ->
        Ys = [((I * 37) rem 101) + 1 || I <- lists:seq(1, 60)],
        Run = fun(Mode) ->
            with_dir(fun(D) ->
                R = graphdb:open(D, [read_write]),
                ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- lists:seq(200, 230)]),
                case Mode of
                    batch  -> ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- Ys], #{sort => false}),
                              ok = graphdb:del_edges(R, [{1, 7, Y} || Y <- lists:sublist(Ys, 25)],
                                                     #{sort => false});
                    single -> [ok = graphdb:put_edge(R, 1, 7, Y) || Y <- Ys],
                              [ok = graphdb:del_edge(R, 1, 7, Y) || Y <- lists:sublist(Ys, 25)]
                end,
                ?assertMatch({ok, _}, graphdb:check_invariants(R)),
                Res = {dsts_of(graphdb:out_edges(R, 1)), adj_bytes(R, 1)},
                graphdb:close(R),
                Res
            end)
        end,
        {OutB, BytesB} = Run(batch),
        ?assertEqual({OutB, BytesB}, Run(single)),
        ?assertEqual(lists:usort(lists:seq(200, 230) ++ (Ys -- lists:sublist(Ys, 25))), OutB)
     end}}.


%% ===================================================================
%% edges_by_type 带 limit：只解还差的条目、range 取小批；结果 = 全量结果的前缀
%% ===================================================================

edges_by_type_limit_prefix_test_() ->
    {"edges_by_type limit：内联组 / 分块组 / 带属性 / 带 rank 混合，任意 limit 的结果都是全量结果的前缀",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            %% 顶点 5：600 条无属性出边（分块）；顶点 9：带属性、带 rank 的内联边；
            %% 顶点 20..60：每个 3 条；顶点 3 只有入边。别的类型夹在中间。
            ok = graphdb:put_edges(R, [{5, 7, I} || I <- lists:seq(100, 699)]),
            [ok = graphdb:put_edge(R, 9, 7, I, #{rank => Rk, props => <<"p", I:8, Rk:8>>})
             || I <- lists:seq(1, 6), Rk <- [0, 2]],
            ok = graphdb:put_edges(R, [{V, 7, V + K} || V <- lists:seq(20, 60), K <- [1, 2, 3]]),
            ok = graphdb:put_edges(R, [{V, 8, 3} || V <- lists:seq(1, 80)]),
            {ok, All} = graphdb:edges_by_type(R, 7),
            ?assertEqual(600 + 12 + 41 * 3, length(All)),
            ?assertEqual(lists:sort([{S, Dv, Rk} || #{src := S, dst := Dv, rank := Rk} <- All]),
                         [{S, Dv, Rk} || #{src := S, dst := Dv, rank := Rk} <- All]),
            lists:foreach(
              fun(L) ->
                      {ok, Got} = graphdb:edges_by_type(R, 7, #{limit => L}),
                      ?assertEqual({L, lists:sublist(All, L)}, {L, Got})
              end, [0, 1, 2, 5, 13, 100, 599, 600, 601, 612, 613, 700, length(All), length(All) + 5]),
            graphdb:close(R),
            %% 重开（行已落盘）结果相同
            R2 = graphdb:open(D, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]),
            ?assertEqual({ok, lists:sublist(All, 650)}, graphdb:edges_by_type(R2, 7, #{limit => 650})),
            graphdb:close(R2)
        end)
     end}}.

neighbors_where_many_test_() ->
    {"neighbors_where：300 个邻居、一半悬挂，结果同逐个 get_vertex；无邻居 / 入边方向",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write]),
            ok = graphdb:put_edges(R, [{1, 7, I} || I <- lists:seq(2, 301)]),
            %% 偶数有顶点值，奇数是悬挂邻居
            [ok = graphdb:put_vertex(R, I, integer_to_binary(I)) || I <- lists:seq(2, 301, 2)],
            Pred = fun(_N, undefined) -> true;
                      (_N, V) -> binary_to_integer(V) rem 4 =:= 0
                   end,
            Expect = [N || N <- lists:seq(2, 301),
                           Pred(N, case graphdb:get_vertex(R, N) of {ok, V} -> V; _ -> undefined end)],
            ?assertEqual({ok, Expect}, graphdb:neighbors_where(R, 1, out, Pred)),
            ?assertEqual({ok, []}, graphdb:neighbors_where(R, 999, out, Pred)),
            ?assertEqual({ok, [1]}, graphdb:neighbors_where(R, 2, in, fun(_, undefined) -> true; (_, _) -> false end)),
            graphdb:close(R)
        end)
     end}}.

