%% Cypher 子集 Q2-4（写语句）与 Q2-5（全文 @@、向量 <=>、score()）。
%% 写的结果用图层 API 核对（同一个数据模型）；检索结果与直接调引擎接口对照。
-module(bitcask_cypher_write_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, bitcask_cypher).
-define(G, graphdb).

with_graph(F) -> with_graph([], F).
with_graph(Opts, F) ->
    bitcask_test_util:with_dir("cypher_w_", fun(D) ->
        R = ?G:open(D, [read_write | Opts]),
        try F(R) after ?G:close(R) end
    end).

q(R, Q) -> q(R, Q, #{}).
q(R, Q, P) ->
    case ?C:q(R, Q, P) of
        {ok, Res} -> Res;
        Other -> erlang:error({query_failed, Q, Other})
    end.

rows(R, Q) -> maps:get(rows, q(R, Q)).
rows(R, Q, P) -> maps:get(rows, q(R, Q, P)).
col(R, Q) -> [V || [V] <- rows(R, Q)].
col(R, Q, P) -> [V || [V] <- rows(R, Q, P)].

ok_inv(R) -> ?assertMatch({ok, _}, ?G:check_invariants(R)).

%% =========================================================================
%% Q2-4：写
%% =========================================================================

create_nodes_and_edges_test() ->
    with_graph(fun(R) ->
        #{rows := [[A, B]], stats := S} =
            q(R, "CREATE (a:Person:Admin {name: 'ann', age: 31})-[:KNOWS {since: 2020}]->(b:Person {name: 'bob'}) "
                 "RETURN id(a), id(b)"),
        ?assertEqual(#{nodes_created => 2, relationships_created => 1, labels_added => 3, properties_set => 4}, S),
        %% 图层 API 读得到（同一个模型、同一个 id）
        ?assertEqual({ok, #{id => A, labels => [<<"Person">>, <<"Admin">>],
                            properties => #{<<"name">> => <<"ann">>, <<"age">> => 31}}}, ?G:vertex(R, A)),
        {ok, K} = ?G:etype_id(R, <<"KNOWS">>),                      %% 关系类型自动注册
        {ok, #{props := P}} = ?G:edge(R, A, K, B),
        ?assertEqual(#{<<"since">> => 2020}, graphdb_model:decode_edge_props(P)),
        ?assertEqual({ok, [A, B]}, ?G:vertices_by_label(R, <<"Person">>)),
        %% 反方向、连到已有的顶点、平行边取下一个 rank
        q(R, "MATCH (a {name: 'ann'}), (b {name: 'bob'}) CREATE (a)<-[:KNOWS]-(b), (a)-[:KNOWS]->(b)"),
        ?assertEqual([0, 1], [Rk || [_, _, _, Rk] <- col(R, "MATCH ({name: 'ann'})-[r:KNOWS]->({name: 'bob'}) RETURN id(r)")]),
        ?assertEqual([<<"ann">>], col(R, "MATCH ({name: 'bob'})-[:KNOWS]->(x) RETURN x.name")),
        %% 没有 RETURN：不返回行
        ?assertMatch(#{columns := [], rows := []}, q(R, "CREATE (:Thing)")),
        ok_inv(R)
    end).

shared_id_space_test() ->
    with_graph(fun(R) ->
        ok = ?G:put_vertex(R, 100, #{labels => [<<"X">>]}),
        {ok, 101} = ?G:create_vertex(R, #{}),        %% 计数器建起来：从现有最大 id + 1……
        ok = ?G:put_vertex(R, 200, <<"v">>),         %% ……再被指定 id 推高
        [[A]] = rows(R, "CREATE (n:Y) RETURN id(n)"),
        ?assertEqual(201, A),
        ?assertEqual({ok, 202}, ?G:create_vertex(R, #{})),
        [[B1], [B2], [B3]] = rows(R, "UNWIND $xs AS x CREATE (n:Z {v: x}) RETURN id(n) ORDER BY id(n)", #{xs => [1, 2, 3]}),
        ?assertEqual([203, 204, 205], [B1, B2, B3]),
        ?assertEqual([1, 2, 3], col(R, "MATCH (n:Z) RETURN n.v ORDER BY n.v"))
    end).

set_remove_test() ->
    %% L2 度量：向量原样存（cosine 写入时归一化）
    with_graph([{vector_dim, 3}, {vector_metric, l2}, {analyzer, whitespace}], fun(R) ->
        [[V]] = rows(R, "CREATE (n:P {name: 'x', a: 1, b: 2}) RETURN id(n)"),
        #{stats := S1} = q(R, "MATCH (n:P) SET n.a = n.a + 10, n.c = 'new', n.b = null, n:Q:P"),
        ?assertEqual(#{properties_set => 3, labels_added => 1}, S1),
        ?assertEqual({ok, #{id => V, labels => [<<"P">>, <<"Q">>],
                            properties => #{<<"name">> => <<"x">>, <<"a">> => 11, <<"c">> => <<"new">>}}},
                     ?G:vertex(R, V)),
        q(R, "MATCH (n:P) SET n += {d: true, a: null}"),
        ?assertMatch({ok, #{properties := #{<<"d">> := true, <<"c">> := <<"new">>} = Pr}} when not is_map_key(<<"a">>, Pr),
                     ?G:vertex(R, V)),
        q(R, "MATCH (n:P) SET n = {only: 1}"),
        ?assertMatch({ok, #{labels := [<<"P">>, <<"Q">>], properties := #{<<"only">> := 1} = Pr2}}
                       when map_size(Pr2) =:= 1, ?G:vertex(R, V)),
        %% 正文与向量
        q(R, "MATCH (n:P) SET n.text = 'hello world', n.embedding = [1, 2, 3]"),
        ?assertEqual([[<<"hello world">>, << <<X:32/float-little>> || X <- [1.0, 2.0, 3.0] >>]],
                     rows(R, "MATCH (n:P) RETURN n.text, n.embedding")),
        q(R, "MATCH (n:P) REMOVE n.only, n.embedding, n:Q"),
        ?assertEqual([[null, null, [<<"P">>]]], rows(R, "MATCH (n:P) RETURN n.only, n.embedding, labels(n)")),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"Q">>)),
        %% 关系属性
        q(R, "MATCH (n:P) CREATE (n)-[:R {w: 1}]->(:P2)"),
        q(R, "MATCH ()-[r:R]->() SET r.w = r.w + 1, r.t = 'x'"),
        ?assertEqual([#{<<"w">> => 2, <<"t">> => <<"x">>}], col(R, "MATCH ()-[r:R]->() RETURN properties(r)")),
        q(R, "MATCH ()-[r:R]->() REMOVE r.t"),
        ?assertEqual([#{<<"w">> => 2}], col(R, "MATCH ()-[r:R]->() RETURN properties(r)")),
        %% 类型校验：嵌套 map / 非字符串列表报执行错误，什么都不写
        ?assertMatch({error, #{stage := exec, message := <<"unsupported property type", _/binary>>}},
                     ?C:q(R, "MATCH (n:P) SET n.m = {a: 1}")),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n:P) SET n.l = [1, 'a']")),
        ok_inv(R)
    end).

delete_test() ->
    with_graph(fun(R) ->
        q(R, "CREATE (a:N {k: 1})-[:E]->(b:N {k: 2})-[:E]->(c:N {k: 3})"),
        ?assertMatch({error, #{stage := exec, message := <<"cannot delete node", _/binary>>}},
                     ?C:q(R, "MATCH (n:N {k: 2}) DELETE n")),
        ?assertEqual([[3]], rows(R, "MATCH (n:N) RETURN count(*)")),       %% 原子：什么都没删
        #{stats := S1} = q(R, "MATCH (a:N {k: 1})-[r:E]->(b) DELETE r"),
        ?assertEqual(#{relationships_deleted => 1}, S1),
        #{stats := S2} = q(R, "MATCH (n:N {k: 1}) DELETE n"),
        ?assertEqual(#{nodes_deleted => 1}, S2),
        %% 同一条语句里先删关系再删顶点
        #{stats := S3} = q(R, "MATCH (b:N {k: 2})-[r]->(c) DELETE r, b"),
        ?assertEqual(#{relationships_deleted => 1, nodes_deleted => 1}, S3),
        q(R, "MATCH (c:N {k: 3}) CREATE (c)-[:E]->(:N {k: 4}), (c)-[:E]->(c)"),
        #{stats := S4} = q(R, "MATCH (c:N {k: 3}) DETACH DELETE c"),
        ?assertEqual(#{relationships_deleted => 2, nodes_deleted => 1}, S4),
        ?assertEqual([4], col(R, "MATCH (n:N) RETURN n.k")),
        ?assertEqual({ok, col(R, "MATCH (n:N) RETURN id(n)")}, ?G:vertices_by_label(R, <<"N">>)),
        ?assertEqual([[0]], rows(R, "MATCH ()-[r]->() RETURN count(r)")),
        ok_inv(R)
    end).

statement_atomicity_test() ->
    with_graph(fun(R) ->
        {ok, _} = ?C:q(R, "CREATE (:Seed)"),
        Before = graphdb_model:read_counter(R),
        ?assertMatch({error, #{stage := exec, message := <<"division by zero">>}},
                     ?C:q(R, "CREATE (n:X {v: 1})-[:E]->(m:X) SET n.v = 1 / 0")),
        ?assertEqual([[0]], rows(R, "MATCH (n:X) RETURN count(*)")),
        ?assertEqual(Before, graphdb_model:read_counter(R)),          %% 计数器也没动
        %% 关系类型在语句开始前注册（事务之外、幂等），语句失败也留着
        ?assertMatch({ok, _}, ?G:etype_id(R, <<"E">>)),
        ok_inv(R)
    end).

%% 一条语句写多少顶点默认不限（openCypher TCK Return6 [4] 一条语句建 7251 个）；
%% 应用环境 cypher_max_write_vertices 可以设上限。
write_vertex_cap_test() ->
    with_graph(fun(R) ->
        #{stats := #{nodes_created := 20000, relationships_created := 10000}} =
            q(R, "UNWIND range(1, 10000) AS i CREATE (:A {i: i})-[:T]->(:B)"),
        ?assertEqual([[10000]], rows(R, "MATCH (n:B) RETURN count(*)")),
        ok = application:set_env(bitcask_cypher, cypher_max_write_vertices, 100),
        try
            ?assertMatch({error, #{stage := exec, message := <<"one statement may write at most 100 ", _/binary>>}},
                         ?C:q(R, "UNWIND range(1, 101) AS x CREATE (:C {x: x})")),
            ?assertEqual([[0]], rows(R, "MATCH (n:C) RETURN count(*)")),
            #{stats := #{nodes_created := 100}} = q(R, "UNWIND range(1, 100) AS x CREATE (:C {x: x})")
        after
            application:unset_env(bitcask_cypher, cypher_max_write_vertices)
        end,
        %% 调高过的 min_heap_size 在语句结束时恢复
        {min_heap_size, MH} = process_info(self(), min_heap_size),
        ?assert(MH < 100000),
        ok_inv(R)
    end).

concurrent_updates_test_() ->
    {"8 个进程各做 20 次 MATCH … SET c.n = c.n + 1：不丢更新；8×20 个并发 CREATE 的 id 互不相同",
     {timeout, 120, fun() ->
        with_graph(fun(R) ->
            q(R, "CREATE (:Counter {n: 0})"),
            Me = self(),
            Run = fun(Q) ->
                          Ps = [spawn_link(fun() ->
                                                   [ {ok, _} = ?C:q(R, Q, #{}, [{retries, infinity}])
                                                     || _ <- lists:seq(1, 20)],
                                                   Me ! {done, self()}
                                           end) || _ <- lists:seq(1, 8)],
                          [receive {done, P} -> ok end || P <- Ps]
                  end,
            Run("MATCH (c:Counter) SET c.n = c.n + 1"),
            ?assertEqual([160], col(R, "MATCH (c:Counter) RETURN c.n")),
            Run("CREATE (:Item)"),
            Ids = col(R, "MATCH (n:Item) RETURN id(n)"),
            ?assertEqual(160, length(lists:usort(Ids))),
            ok_inv(R)
        end)
     end}}.

transaction_test() ->
    with_graph(fun(R) ->
        {atomic, Res} = ?G:transaction(R, fun(Tx) ->
            {ok, _} = ?C:q(Tx, "CREATE (:T {k: 1})"),
            {ok, _} = ?C:q(Tx, "MATCH (t:T) CREATE (t)-[:E]->(:T {k: 2})"),
            {ok, #{rows := Rows}} = ?C:q(Tx, "MATCH (a:T)-[:E]->(b:T) RETURN a.k, b.k"),   %% 读到本事务的写
            ok = ?G:put_edge_txn(Tx, 1, 99, 2),                                           %% 与图层事务 API 混用
            Rows
        end),
        ?assertEqual([[1, 2]], Res),
        ?assertEqual([[2]], rows(R, "MATCH (n:T) RETURN count(*)")),
        %% 语句出错 → 整个事务中止，前面的语句也不留痕迹
        ?assertMatch({aborted, {cypher, #{stage := exec}}},
                     ?G:transaction(R, fun(Tx) ->
                                               {ok, _} = ?C:q(Tx, "CREATE (:T {k: 3})"),
                                               ?C:q(Tx, "MATCH (n:T {k: 3}) DELETE n, n.k")
                                       end)),
        ?assertEqual([[2]], rows(R, "MATCH (n:T) RETURN count(*)")),
        ok_inv(R)
    end).

%% =========================================================================
%% Q2-5：全文与向量
%% =========================================================================

docs(R) ->
    Vec = fun(L) -> << <<X:32/float-little>> || X <- L >> end,
    Mk = fun(Labels, Name, Text, V) ->
                 {ok, Id} = ?G:create_vertex(R, #{labels => Labels, props => #{name => Name},
                                                  text => Text, vector => Vec(V)}),
                 Id
         end,
    #{a => Mk([<<"Doc">>], <<"a">>, <<"graph databases store edges">>, [1.0, 0.0, 0.0]),
      b => Mk([<<"Doc">>], <<"b">>, <<"vector search finds neighbours">>, [0.9, 0.1, 0.0]),
      c => Mk([<<"Doc">>, <<"Hot">>], <<"c">>, <<"graph and vector together">>, [0.0, 1.0, 0.0]),
      d => Mk([<<"Note">>], <<"d">>, <<"cooking recipes">>, [0.0, 0.0, 1.0]),
      e => Mk([<<"Doc">>], <<"e">>, <<"graphs graphing graphite">>, [0.5, 0.5, 0.0])}.

search_opts() -> [{analyzer, whitespace}, {vector_dim, 3}].

fulltext_test() ->
    with_graph(search_opts(), fun(R) ->
        Ids = docs(R),
        N = fun(Q) -> lists:sort(col(R, "MATCH (n) WHERE n.text @@ $q RETURN n.name", #{q => Q})) end,
        ?assertEqual([<<"a">>, <<"c">>], N(<<"graph">>)),
        ?assertEqual([<<"c">>], N(<<"graph vector">>)),                  %% 并列：都要出现
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], N(<<"graph OR vector">>)),
        ?assertEqual([<<"a">>], N(<<"graph -vector">>)),                %% 排除
        ?assertEqual([<<"c">>], N(<<"\"graph and vector\"">>)),         %% 短语
        ?assertEqual([<<"a">>, <<"c">>, <<"e">>], N(<<"graph*">>)),       %% 前缀
        ?assertEqual([<<"a">>, <<"c">>, <<"e">>], N(<<"graphs~">>)),     %% 模糊：graphs 与 graph 差一个字符
        %% score() 与引擎的 BM25 分一致；全文取点按分数降序
        {ok, Hits} = bitcask:search_text(R, <<"graph">>, 10),
        Expect = [{V, S} || {<<_:4/binary, "n", V:64/big>>, _, S} <- Hits],
        Got = [{V, S} || [V, S] <- rows(R, "MATCH (n) WHERE n.text @@ 'graph' RETURN id(n), score(n)")],
        ?assertEqual(lists:sort(Expect), lists:sort(Got)),
        {ok, #{ops := [{fts_seek, <<"n">>, <<"text">>, _} | _]}} =
            ?C:explain(R, "MATCH (n:Doc) WHERE n.text @@ 'x' AND n.name = 'a' RETURN n"),
        %% 展开得到的顶点上做过滤（不是取点）
        q(R, "MATCH (a {name: 'a'}), (b) WHERE b.name IN ['b', 'c'] CREATE (a)-[:L]->(b)"),
        ?assertEqual([<<"c">>], col(R, "MATCH ({name: 'a'})-[:L]->(m) WHERE m.text @@ 'together' RETURN m.name")),
        ?assertEqual([true], col(R, "MATCH ({name: 'a'})-[:L]->(m) WHERE m.text @@ 'together' RETURN score(m) > 0")),
        %% 只支持 text；不是字符串 → 执行错误
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n) WHERE n.name @@ 'a' RETURN n")),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n) WHERE n.text @@ 1 RETURN n")),
        _ = Ids
    end).

fulltext_needs_index_mode_test() ->
    with_graph(fun(R) ->
        {ok, _} = ?G:create_vertex(R, #{text => <<"x">>}),
        ?assertMatch({error, #{stage := exec, message := <<"full-text search needs", _/binary>>}},
                     ?C:q(R, "MATCH (n) WHERE n.text @@ 'x' RETURN n"))
    end).

vector_test() ->
    with_graph(search_opts(), fun(R) ->
        Ids = docs(R),
        Q = [1.0, 0.2, 0.0],
        QBin = << <<X:32/float-little>> || X <- Q >>,
        All = [maps:get(K, Ids) || K <- [a, b, c, d, e]],
        Brute = fun(Vids, K) ->
                        {ok, Hs} = bitcask:vector_rank(R, QBin, [graphdb:nkey(V) || V <- Vids], K),
                        [V || {<<_:4/binary, "n", V:64/big>>, _, _} <- Hs]
                end,
        %% top-k：与对全体精确排序一致；走向量取点
        ?assertEqual(Brute(All, 3),
                     col(R, "MATCH (n) RETURN id(n) ORDER BY n.embedding <=> $q LIMIT 3", #{q => Q})),
        {ok, #{ops := [{vector_topk, <<"n">>, _, [], [], [], undefined, {lit, 3}} | _]}} =
            ?C:explain(R, "MATCH (n) RETURN n ORDER BY n.embedding <=> $q LIMIT 3"),
        %% 带标签 + 别的条件：仍回满 k 个通过条件的
        Docs = [maps:get(K, Ids) || K <- [a, b, c, e]],
        Want = [V || V <- Brute(Docs, 4), V =/= maps:get(b, Ids)],
        #{rows := Rows, stats := #{vector_exhaustive := true}} =
            q(R, "MATCH (n:Doc) WHERE n.name <> 'b' RETURN id(n), n.embedding <=> $q AS d ORDER BY d LIMIT 3", #{q => Q}),
        ?assertEqual(lists:sublist(Want, 3), [V || [V, _] <- Rows]),
        Ds = [D || [_, D] <- Rows],
        ?assertEqual(lists:sort(Ds), Ds),
        %% 距离 = 引擎相似度分数的相反数
        {ok, [{_, _, S0}]} = bitcask:vector_rank(R, QBin, [graphdb:nkey(maps:get(a, Ids))], 1),
        ?assertEqual([-S0], col(R, "MATCH (n {name: 'a'}) RETURN n.embedding <=> $q", #{q => Q})),
        %% 阈值形态
        Thr = -0.9,
        Exp = lists:sort([V || V <- All,
                               begin {ok, [{_, _, S}]} = bitcask:vector_rank(R, QBin, [graphdb:nkey(V)], 1),
                                     -S < Thr end]),
        ?assertEqual(Exp, lists:sort(col(R, "MATCH (n) WHERE n.embedding <=> $q < $t RETURN id(n)", #{q => Q, t => Thr}))),
        {ok, #{ops := [{vector_range, <<"n">>, _, _, undefined} | _]}} =
            ?C:explain(R, "MATCH (n) WHERE n.embedding <=> $q < 0.5 RETURN n"),
        %% 候选由图模式给出：在邻居里按向量排序
        q(R, "MATCH (a {name: 'd'}), (x) WHERE x.name IN ['a', 'c', 'e'] CREATE (a)-[:L]->(x)"),
        Nbrs = [maps:get(K, Ids) || K <- [a, c, e]],
        ?assertEqual(Brute(Nbrs, 2),
                     col(R, "MATCH ({name: 'd'})-[:L]->(m) RETURN id(m) ORDER BY m.embedding <=> $q LIMIT 2", #{q => Q})),
        %% 没有向量的顶点：距离 null（排在最后）
        {ok, NoVec} = ?G:create_vertex(R, #{labels => [<<"Doc">>]}),
        ?assertEqual([null], col(R, "MATCH (n) WHERE id(n) = $i RETURN n.embedding <=> $q", #{i => NoVec, q => Q})),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n) RETURN n.name <=> $q", #{q => Q}))
    end).

vector_needs_config_test() ->
    with_graph(fun(R) ->
        {ok, _} = ?G:create_vertex(R, #{}),
        ?assertMatch({error, #{stage := exec}},
                     ?C:q(R, "MATCH (n) RETURN n ORDER BY n.embedding <=> [1.0] LIMIT 1"))
    end).

%% =========================================================================
%% 二期：MERGE
%% =========================================================================

merge_node_test() ->
    with_graph(fun(R) ->
        Q = "MERGE (u:User {name: $n}) ON CREATE SET u.created = 1 ON MATCH SET u.hits = coalesce(u.hits, 0) + 1 "
            "RETURN id(u), u.created, u.hits",
        #{rows := [[U, 1, null]], stats := S1} = q(R, Q, #{n => <<"ann">>}),
        ?assertEqual(#{nodes_created => 1, labels_added => 1, properties_set => 2}, S1),
        ?assertMatch(#{rows := [[U, 1, 1]], stats := #{properties_set := 1}}, q(R, Q, #{n => <<"ann">>})),
        ?assertMatch(#{rows := [[U, 1, 2]]}, q(R, Q, #{n => <<"ann">>})),
        %% 不同的值 → 新顶点；与图层 API 同一份数据
        [[U2, 1, null]] = rows(R, Q, #{n => <<"bob">>}),
        ?assertNotEqual(U, U2),
        ?assertMatch({ok, #{labels := [<<"User">>], properties := #{<<"name">> := <<"ann">>, <<"hits">> := 2}}},
                     ?G:vertex(R, U)),
        {ok, V3} = ?G:create_vertex(R, #{labels => [<<"User">>], props => #{name => <<"carl">>}}),
        ?assertEqual([V3], col(R, "MERGE (u:User {name: 'carl'}) RETURN id(u)")),
        %% 多标签：要全部标签都有才算匹配
        [[M1]] = rows(R, "MERGE (u:User:Admin {name: 'ann'}) RETURN id(u)"),
        ?assertNotEqual(U, M1),
        ?assertEqual([M1], col(R, "MERGE (u:Admin:User {name: 'ann'}) RETURN id(u)")),
        %% 匹配到多个：每个一行
        {ok, _} = ?C:q(R, "CREATE (:Dup {k: 1}), (:Dup {k: 1})"),
        ?assertEqual(2, length(rows(R, "MERGE (d:Dup {k: 1}) RETURN d"))),
        %% 按输入行逐行 MERGE：同一个值只建一次
        #{stats := S2} = q(R, "UNWIND ['x', 'y', 'x'] AS n MERGE (:Tag {name: n})"),
        ?assertEqual(2, maps:get(nodes_created, S2)),
        ?assertEqual([<<"x">>, <<"y">>], col(R, "MATCH (t:Tag) RETURN t.name ORDER BY t.name")),
        %% 没有标签：全量找
        ?assertEqual([U], col(R, "MERGE (u {name: 'ann', hits: 2}) RETURN id(u)")),
        %% null 属性不能 MERGE；出错不留痕迹
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MERGE (u:User {name: $n}) RETURN u", #{n => null})),
        ?assertMatch({error, _}, ?C:q(R, "MERGE (u:Boom {k: 1}) SET u.x = 1 / 0")),
        ?assertEqual([], rows(R, "MATCH (b:Boom) RETURN b")),
        ok_inv(R)
    end).

merge_rel_test() ->
    with_graph(fun(R) ->
        {ok, _} = ?C:q(R, "CREATE (:P {n: 1}), (:P {n: 2})"),
        Q = "MATCH (a:P {n: 1}), (b:P {n: 2}) MERGE (a)-[r:KNOWS {since: 2020}]->(b) "
            "ON CREATE SET r.c = true ON MATCH SET r.m = true RETURN r.since, r.c, r.m",
        ?assertMatch(#{rows := [[2020, true, null]], stats := #{relationships_created := 1}}, q(R, Q)),
        ?assertMatch(#{rows := [[2020, true, true]]}, q(R, Q)),
        %% 反着写同一条边：匹配上
        ?assertEqual([1], col(R, "MATCH (a:P {n: 1}), (b:P {n: 2}) MERGE (b)<-[r:KNOWS]-(a) RETURN count(r)")),
        %% 属性不同 → 新的平行边；类型不同 → 新边（类型自动注册）
        q(R, "MATCH (a:P {n: 1}), (b:P {n: 2}) MERGE (a)-[:KNOWS {since: 1999}]->(b)"),
        q(R, "MATCH (a:P {n: 1}), (b:P {n: 2}) MERGE (a)-[:LIKES]->(b)"),
        ?assertEqual([[<<"KNOWS">>, 2], [<<"LIKES">>, 1]],
                     rows(R, "MATCH (:P {n: 1})-[r]->(:P {n: 2}) RETURN type(r) AS t, count(*) ORDER BY t")),
        {ok, K} = ?G:etype_id(R, <<"LIKES">>),
        ?assertMatch({ok, _}, ?G:edge(R, 1, K, 2)),
        %% 方向相反是另一条边
        q(R, "MATCH (a:P {n: 1}), (b:P {n: 2}) MERGE (a)<-[:LIKES]-(b)"),
        ?assertEqual([1], col(R, "MATCH (:P {n: 2})-[r:LIKES]->(:P {n: 1}) RETURN count(r)")),
        %% 端点是 OPTIONAL MATCH 带来的 null → 执行错误
        ?assertMatch({error, #{stage := exec}},
                     ?C:q(R, "MATCH (a:P {n: 1}) OPTIONAL MATCH (a)-[:NONE]->(z) MERGE (a)-[:T]->(z)")),
        ok_inv(R)
    end).

%% 并发 MERGE 同一个节点：只建一个（按标签找走前缀锁，冲突的一方重跑后看见对方建的）。
merge_concurrent_test_() ->
    {timeout, 60, fun() ->
        with_graph(fun(R) ->
            Self = self(),
            Ps = [spawn_link(fun() ->
                                     Res = [?C:q(R, "MERGE (u:Hot {name: 'z'}) ON MATCH SET u.n = coalesce(u.n, 0) + 1 RETURN id(u)")
                                            || _ <- lists:seq(1, 10)],
                                     Self ! {done, self(), Res}
                             end) || _ <- lists:seq(1, 8)],
            All = lists:append([receive {done, P, Res} -> Res end || P <- Ps]),
            Ids = lists:usort([Id || {ok, #{rows := [[Id]]}} <- All]),
            ?assertEqual(80, length([ok || {ok, _} <- All])),
            ?assertMatch([_], Ids),
            ?assertEqual([[1, 79]], rows(R, "MATCH (u:Hot) RETURN count(u), max(u.n)")),
            ok_inv(R)
        end)
    end}.

%% 整条模式的 MERGE：端点可以未绑定、可以多跳；整条匹配不上就整条建（openCypher 语义：
%% 端点单独存在也会新建）。
merge_pattern_test() ->
    with_graph(fun(R) ->
        Q = "MERGE (a:X {k: 1})-[r:T]->(b:Y {k: 2}) ON CREATE SET r.c = 1 ON MATCH SET r.m = 1 RETURN id(a), id(b), r.c, r.m",
        #{rows := [[A, B, 1, null]], stats := S1} = q(R, Q),
        ?assertEqual(#{nodes_created => 2, labels_added => 2, properties_set => 3, relationships_created => 1}, S1),
        ?assertMatch(#{rows := [[A, B, 1, 1]]}, q(R, Q)),
        %% 只有一端不同 → 整条新建（X {k: 1} 有两个了）
        q(R, "MERGE (a:X {k: 1})-[:T]->(b:Y {k: 3})"),
        ?assertEqual([2], col(R, "MATCH (x:X {k: 1}) RETURN count(x)")),
        %% 起点已绑定、终点未绑定
        [[Z]] = rows(R, "MATCH (a) WHERE id(a) = $a MERGE (a)-[:U]->(z:Z {k: 9}) RETURN id(z)", #{a => A}),
        ?assertMatch(#{rows := [[Z]], stats := S2} when map_size(S2) =:= 0,
                     q(R, "MATCH (a) WHERE id(a) = $a MERGE (a)-[:U]->(z:Z {k: 9}) RETURN id(z)", #{a => A})),
        %% 多跳
        [[C1]] = rows(R, "MERGE (:A)-[:T]->(:B)-[:T]->(c:C) RETURN id(c)"),
        ?assertEqual([C1], col(R, "MERGE (:A)-[:T]->(:B)-[:T]->(c:C) RETURN id(c)")),
        ?assertEqual([[1, 1, 1]], rows(R, "MATCH (a:A), (b:B), (c:C) RETURN count(a), count(b), count(c)")),
        %% 关系类型自动注册；null 属性报错
        ?assertMatch({ok, _}, ?G:etype_id(R, <<"U">>)),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MERGE (a:X {k: $k})-[:T]->(:Y)", #{k => null})),
        ok_inv(R)
    end).

%% CREATE p = … / MERGE p = …（openCypher 对齐第 3 组）；UNION 的写语句在一个事务里。
named_write_paths_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[2, [1, 2, 3]]],
                     rows(R, "CREATE p = (:R {i: 1})-[:U]->(:R {i: 2})-[:U]->(:R {i: 3}) RETURN length(p), [x IN nodes(p) | x.i]")),
        %% MERGE：已有就绑定已有的；没有就整条建
        ?assertEqual([[1, [1, 2]]], rows(R, "MERGE p = (:R {i: 1})-[:U]->(:R {i: 2}) RETURN length(p), [x IN nodes(p) | x.i]")),
        ?assertEqual([3], col(R, "MATCH (r:R) RETURN count(r)")),
        #{rows := [[1]], stats := S1} = q(R, "MERGE p = (:S {i: 1})-[:U]->(:S {i: 2}) RETURN length(p)"),
        ?assertEqual(2, maps:get(nodes_created, S1)),
        ?assertMatch(#{rows := [[1]], stats := S2} when map_size(S2) =:= 0,
                     q(R, "MERGE p = (:S {i: 1})-[:U]->(:S {i: 2}) RETURN length(p)")),
        %% 单节点路径
        ?assertEqual([[0]], rows(R, "CREATE p = (:Z) RETURN length(p)")),
        %% UNION 两段都写
        ?assertEqual([[9], [10]], rows(R, "CREATE (x:Q {n: 9}) RETURN x.n AS a UNION ALL CREATE (y:Q {n: 10}) RETURN y.n AS a")),
        ?assertEqual([2], col(R, "MATCH (q:Q) RETURN count(q)")),
        %% 后一段出错 → 前一段的写也回滚
        ?assertMatch({error, _}, ?C:q(R, "CREATE (x:Q {n: 11}) RETURN x.n AS a UNION ALL CREATE (y:Q {n: $nope}) RETURN 1 / 0 AS a")),
        ?assertEqual([2], col(R, "MATCH (q:Q) RETURN count(q)")),
        ok_inv(R)
    end).

%% 检索的函数形式（二期）：与直接调引擎接口的命中一致；作为起点 / 作为过滤两种用法；score(n)。
search_functions_test() ->
    with_graph(search_opts(), fun(R) ->
        Ids = docs(R),
        Name = maps:from_list([{V, K} || {K, V} <- maps:to_list(Ids)]),
        Engine = fun(F) -> {ok, Hs} = F(), lists:sort([atom_to_binary(maps:get(V, Name))
                                                        || {<<_:4/binary, "n", V:64/big>>, _, _} <- Hs]) end,
        N = fun(Q) -> lists:sort(col(R, Q)) end,
        ?assertEqual(Engine(fun() -> bitcask:search_phrase(R, <<"graph and vector">>, 100) end),
                     N("MATCH (n) WHERE fts.phrase(n.text, 'graph and vector') RETURN n.name")),
        ?assertEqual(Engine(fun() -> bitcask:search_near(R, <<"graph together">>, 3, 100) end),
                     N("MATCH (n) WHERE fts.near(n.text, 'graph together', 3) RETURN n.name")),
        ?assertEqual(Engine(fun() -> bitcask:search_wildcard(R, <<"graph*">>, 100) end),
                     N("MATCH (n) WHERE fts.wildcard(n.text, 'graph*') RETURN n.name")),
        ?assertEqual(Engine(fun() -> bitcask:search_fuzzy(R, <<"grph">>, 1, 100) end),
                     N("MATCH (n) WHERE fts.fuzzy(n.text, 'grph') RETURN n.name")),
        ?assertEqual(Engine(fun() -> bitcask:search_fuzzy(R, <<"grap">>, 2, 100) end),
                     N("MATCH (n) WHERE fts.fuzzy(n.text, 'grap', 2) RETURN n.name")),
        %% 作为起点：explain 是 search_seek，按分数降序；score(n) 是引擎分数
        {ok, #{ops := [{search_seek, <<"n">>, <<"fts.wildcard">>, _} | _]}} =
            ?C:explain(R, "MATCH (n) WHERE fts.wildcard(n.text, 'graph*') RETURN n"),
        {ok, Hs} = bitcask:search_wildcard(R, <<"graph*">>, 100),
        Best = lists:max([Sc || {_, _, Sc} <- Hs]),
        [[_, S1] | _] = rows(R, "MATCH (n) WHERE fts.wildcard(n.text, 'graph*') RETURN n.name, score(n) ORDER BY score(n) DESC"),
        ?assert(abs(S1 - Best) < 1.0e-6),
        %% 作为过滤（起点是标签）：与起点用法结果相同
        ?assertEqual(N("MATCH (n) WHERE fts.wildcard(n.text, 'graph*') AND n:Doc RETURN n.name"),
                     N("MATCH (n:Doc) WHERE n.name <> 'zz' AND (fts.wildcard(n.text, 'graph*') OR false) RETURN n.name")),
        %% 混合检索：与 search_hybrid 的前 k 一致
        Q = [1.0, 0.1, 0.0],
        QBin = << <<X:32/float-little>> || X <- Q >>,
        {ok, HH} = bitcask:search_hybrid(R, <<"graph">>, QBin, 3),
        ?assertEqual(lists:sort([atom_to_binary(maps:get(V, Name)) || {<<_:4/binary, "n", V:64/big>>, _, _} <- HH]),
                     lists:sort(col(R, "MATCH (n) WHERE search.hybrid(n, 'graph', $q, 3) RETURN n.name", #{q => Q}))),
        ?assertEqual(3, length(rows(R, "MATCH (n) WHERE search.hybrid(n, 'graph', $q, 3) RETURN n", #{q => Q}))),
        %% null 参数 → 不命中；坏参数 / 第一个参数不对
        ?assertEqual([], rows(R, "MATCH (n) WHERE fts.phrase(n.text, $q) RETURN n", #{q => null})),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n) WHERE fts.near(n.text, 'a', -1) RETURN n")),
        ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "MATCH (n) WHERE fts.phrase(n.name, 'a') RETURN n")),
        ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "MATCH (n) WHERE foo.bar(n) RETURN n")),
        _ = Ids
    end).

%% =========================================================================
%% 属性索引（二期）
%% =========================================================================

property_index_test_() ->
    {timeout, 120, fun() ->
        with_graph(fun(R) ->
            %% 已有数据上建索引
            [{ok, _} = ?G:create_vertex(R, #{labels => [<<"P">>],
                                            props => #{k => case I rem 3 of 0 -> I rem 10; 1 -> float(I rem 10); 2 -> I rem 10 end,
                                                       s => iolist_to_binary(["s", integer_to_list(I rem 7)])}})
             || I <- lists:seq(1, 300)],
            [{ok, _} = ?G:create_vertex(R, #{labels => [<<"Q">>], props => #{k => 3}}) || _ <- lists:seq(1, 20)],
            ok = ?G:create_index(R, <<"P">>, <<"k">>),
            ok = ?G:create_index(R, <<"P">>, <<"s">>),
            ok = ?G:create_index(R, <<"P">>, <<"k">>),                         %% 幂等
            ?assertEqual({ok, [{<<"P">>, <<"k">>, ready}, {<<"P">>, <<"s">>, ready}]}, ?G:indexes(R)),
            ?assertEqual({error, {not_indexable, <<"text">>}}, ?G:create_index(R, <<"P">>, <<"text">>)),
            ok_inv(R),
            %% 结果与不走索引的写法一致
            Ids = fun(Q, P) -> lists:sort(col(R, Q, P)) end,
            Same = fun(Cond, P) ->
                           ?assertEqual({Cond, Ids("MATCH (n:P) WHERE NOT (NOT (" ++ Cond ++ ")) RETURN id(n)", P)},
                                        {Cond, Ids("MATCH (n:P) WHERE " ++ Cond ++ " RETURN id(n)", P)})
                   end,
            [Same(C, #{v => 3}) || C <- ["n.k = 3", "n.k = 3.0", "n.k = $v", "n.k IN [1, 2.0, 9]", "n.k < 3",
                                         "n.k <= 2.5", "n.k > 7", "n.k >= 7.0", "n.s = 's3'", "n.s < 's2'",
                                         "n.s >= 's5'", "n.k = 3 AND n.s = 's3'", "n.k > 2 AND n.k < 5"]],
            ?assertEqual(Ids("MATCH (n:P) WHERE NOT (NOT (n.k = 4)) RETURN id(n)", #{}),
                         Ids("MATCH (n:P {k: 4}) RETURN id(n)", #{})),
            %% 确实走了索引：删掉一个顶点的索引项，它就不在走索引的结果里（不走索引的写法仍查得到）
            [V1 | _] = Ids("MATCH (n:P) WHERE n.k = 5 RETURN id(n)", #{}),
            {ok, #{properties := #{<<"k">> := K5}}} = ?G:vertex(R, V1),
            XK = graphdb_model:xkey(<<"P">>, <<"k">>, K5, V1),
            ok = bitcask:delete(R, XK),
            ?assertNot(lists:member(V1, Ids("MATCH (n:P) WHERE n.k = 5 RETURN id(n)", #{}))),
            ?assert(lists:member(V1, Ids("MATCH (n:P) WHERE NOT (NOT (n.k = 5)) RETURN id(n)", #{}))),
            ?assertMatch({error, _}, ?G:check_invariants(R)),
            ok = bitcask:put(R, XK, <<>>),
            ok_inv(R),
            %% 各条写路径都维护索引
            [[A]] = rows(R, "CREATE (n:P {k: 42, s: 'new'}) RETURN id(n)"),
            ?assertEqual([A], col(R, "MATCH (n:P) WHERE n.k = 42 RETURN id(n)")),
            q(R, "MATCH (n:P) WHERE n.k = 42 SET n.k = 43"),
            ?assertEqual([], col(R, "MATCH (n:P) WHERE n.k = 42 RETURN id(n)")),
            ?assertEqual([A], col(R, "MATCH (n:P) WHERE n.k = 43 RETURN id(n)")),
            q(R, "MATCH (n:P) WHERE n.k = 43 REMOVE n:P"), ok_inv(R),
            q(R, "MATCH (n) WHERE id(n) = $a SET n:P", #{a => A}), ok_inv(R),
            q(R, "MATCH (n) WHERE id(n) = $a REMOVE n.k", #{a => A}), ok_inv(R),
            q(R, "MERGE (n:P {k: 77}) ON CREATE SET n.s = 'm'"), ok_inv(R),
            ?assertEqual(1, length(col(R, "MATCH (n:P) WHERE n.k = 77 RETURN id(n)"))),
            ok = ?G:put_vertex(R, 9000, #{labels => [<<"P">>], props => #{k => 88}}), ok_inv(R),
            ok = ?G:put_vertex(R, 9000, #{labels => [<<"P">>], props => #{k => 89}}), ok_inv(R),
            ?assertEqual([9000], col(R, "MATCH (n:P) WHERE n.k = 89 RETURN id(n)")),
            ok = ?G:remove_labels(R, 9000, [<<"P">>]), ok_inv(R),
            ok = ?G:set_labels(R, 9000, [<<"P">>]), ok_inv(R),
            ok = ?G:del_vertex(R, 9000), ok_inv(R),
            {atomic, _} = ?G:transaction(R, fun(Tx) -> ?C:q(Tx, "MATCH (n:P) WHERE n.k = 77 SET n.k = 78") end), ok_inv(R),
            {atomic, _} = ?G:transaction(R, fun(Tx) -> ?G:put_vertex_txn(Tx, A, <<"plain">>) end), ok_inv(R),
            q(R, "MATCH (n:P) WHERE n.k = 78 DETACH DELETE n"), ok_inv(R),
            %% 删索引：索引项清空，查询照样对
            ok = ?G:drop_index(R, <<"P">>, <<"k">>),
            ?assertEqual({ok, [{<<"P">>, <<"s">>, ready}]}, ?G:indexes(R)),
            Pre = graphdb_model:xprefix(<<"P">>, <<"k">>),
            ?assertEqual([], bitcask:range(R, {Pre, bitcask:prefix_succ(Pre)})),
            Same("n.k = 3", #{}),
            ok_inv(R)
        end)
    end}.

%% 边写边建索引：建完之后索引与数据一致（写入要么被补建扫到，要么自己维护了索引）。
%% 写语句 / 调用方事务里的标签扫描走属性索引：结果与不走索引一致，看得见本事务之前的写。
txn_label_scan_index_test() ->
    with_graph(fun(R) ->
        [q(R, "CREATE (:P {k: $k, i: $i})", #{k => I rem 5, i => I}) || I <- lists:seq(1, 50)],
        Hits = fun() -> lists:sort(col(R, "MATCH (n:P) WHERE n.k = 3 SET n.hit = true RETURN n.i")) end,
        Range = fun() -> lists:sort(col(R, "MATCH (n:P) WHERE n.k >= 3 SET n.hit = true RETURN n.i")) end,
        In = fun() -> lists:sort(col(R, "MATCH (n:P) WHERE n.k IN [1, 4.0] SET n.hit = true RETURN n.i")) end,
        Before = {Hits(), Range(), In()},
        ok = ?G:create_index(R, <<"P">>, <<"k">>),
        ?assertEqual(Before, {Hits(), Range(), In()}),
        ?assertEqual(10, length(element(1, Before))),
        %% 调用方事务里：先建、再按索引找得到；改掉 k 的那个找不到
        {atomic, {ok, #{rows := Rows}}} =
            ?G:transaction(R, fun(Tx) ->
                                      {ok, _} = ?C:q(Tx, "CREATE (:P {k: 3, i: 100})"),
                                      {ok, _} = ?C:q(Tx, "MATCH (n:P {i: 3}) SET n.k = 0"),
                                      ?C:q(Tx, "MATCH (n:P) WHERE n.k = 3 RETURN n.i ORDER BY n.i")
                              end),
        ?assertEqual(lists:sort(element(1, Before) -- [3]) ++ [100], [I || [I] <- Rows]),
        ok_inv(R)
    end).

%% 防幻读：并发的「数一遍再建一个」可串行化——每条语句数到的个数互不相同（有 / 没有属性索引）。
txn_label_scan_phantom_test_() ->
    [{timeout, 120, fun() -> phantom_case(false) end},
     {timeout, 120, fun() -> phantom_case(true) end}].

phantom_case(WithIndex) ->
    with_graph(fun(R) ->
        q(R, "CREATE (:P {k: 0})"),
        WithIndex andalso (ok =:= ?G:create_index(R, <<"P">>, <<"k">>)),
        Self = self(),
        N = 8, Each = 5,
        Pids = [spawn_link(fun() ->
                                   [q(R, "MATCH (n:P) WHERE n.k = 1 WITH count(n) AS c CREATE (:P {k: 1, c: c})")
                                    || _ <- lists:seq(1, Each)],
                                   Self ! {done, self()}
                           end) || _ <- lists:seq(1, N)],
        [receive {done, P} -> ok end || P <- Pids],
        Cs = lists:sort(col(R, "MATCH (n:P) WHERE n.k = 1 RETURN n.c")),
        ?assertEqual(lists:seq(0, N * Each - 1), Cs),
        ok_inv(R)
    end).

property_index_concurrent_build_test_() ->
    {timeout, 120, fun() ->
        with_graph(fun(R) ->
            [{ok, _} = ?G:create_vertex(R, #{labels => [<<"C">>], props => #{k => I}}) || I <- lists:seq(1, 500)],
            Self = self(),
            Ws = [spawn_link(fun() ->
                                     [begin
                                          {ok, _} = ?G:create_vertex(R, #{labels => [<<"C">>], props => #{k => W * 1000 + I}}),
                                          {ok, _} = ?C:q(R, "MATCH (n:C) WHERE n.k = $k SET n.k = $k + 100000", #{k => I})
                                      end || I <- lists:seq(1, 60)],
                                     Self ! {done, self()}
                             end) || W <- [1, 2, 3]],
            ok = ?G:create_index(R, <<"C">>, <<"k">>),
            [receive {done, W} -> ok end || W <- Ws],
            ok_inv(R),
            ?assertEqual(lists:sort(col(R, "MATCH (n:C) WHERE NOT (NOT (n.k > 100000)) RETURN id(n)")),
                         lists:sort(col(R, "MATCH (n:C) WHERE n.k > 100000 RETURN id(n)")))
        end)
    end}.
