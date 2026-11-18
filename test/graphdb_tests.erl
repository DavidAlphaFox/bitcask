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

%% 0 →(7) 1..50 →(7) 101..150 →(7) 200。第二轮起两侧 frontier 都是 50 个顶点，
%% 走并行分片展开；路径必须与逐点串行语义一致（frontier 序、邻居序）。
wide_graph(D) ->
    R = graphdb:open(D, [read_write]),
    [begin
         ok = graphdb:put_edge(R, 0, 7, I),
         ok = graphdb:put_edge(R, I, 7, 100 + I),
         ok = graphdb:put_edge(R, 100 + I, 7, 200)
     end || I <- lists:seq(1, 50)],
    R.

shortest_path_wide_frontier_test_() ->
    {"两侧 frontier 各 50 个顶点：并行展开，路径 = 串行语义下的第一条",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = wide_graph(D),
            ?assertEqual({ok, [0, 1, 101, 200]}, graphdb:shortest_path(R, 0, 200)),
            ?assertEqual({ok, [7, 107, 200]}, graphdb:shortest_path(R, 7, 200)),
            ?assertEqual({error, no_path}, graphdb:shortest_path(R, 200, 0)),
            graphdb:close(R)
        end)
     end}}.

%% 展开途中引擎报错：串行路径（frontier ≤ 4）与并行路径都返回 {error, _}，
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
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:shortest_path(R, 7, 200)),
                %% 并行：第二层 frontier = [1..50]，7 那片失败、其余片被 kill
                ?assertMatch({error, {graphdb_expand, _}}, graphdb:shortest_path(R, 0, 200))
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
            ?assertEqual({ok, [0, 1, 101, 200]}, graphdb:shortest_path(R, 0, 200)),
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
    {"建库写 g（布局 1 + 参数）；重开以 g 为准；旧图库拒开",
     fun() ->
        with_dir(fun(D) ->
            R = graphdb:open(D, [read_write, {adj_inline_max, 512}]),
            ?assertEqual(#{inline_max => 512, chunk_max => 4096, props_max => 128},
                         graphdb:graph_config(R)),
            {ok, <<1, _/binary>>} = bitcask:get(R, <<?GP/binary, "g">>),
            ok = graphdb:close(R),
            R2 = graphdb:open(D, [read_write, {adj_inline_max, 9999}]),
            ?assertEqual(512, maps:get(inline_max, graphdb:graph_config(R2))),
            ok = graphdb:close(R2),
            ?assertError({badarg, {adj_chunk_max, 1}},
                         graphdb:open(D ++ "_x", [read_write, {adj_chunk_max, 1}]))
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
    {"put_edges 按 src 稳定排序：跨 src 交错的重复边仍是最后一次生效；sort => false / "
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
