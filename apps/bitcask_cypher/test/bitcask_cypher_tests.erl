%% Cypher 子集（doc/cypher-query-design-zh.md）Q2-1～Q2-3：
%%   * 解析 / 语义检查：第 5 节一期语法逐条有正例，非法输入报阶段与行列；
%%   * 执行：在同一张图上，查询结果与用图层 API 手算的结果对照。
-module(bitcask_cypher_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, bitcask_cypher).
-define(G, graphdb).

%% =========================================================================
%% 解析与语义检查（Q2-1）
%% =========================================================================

parses_phase1_syntax_test_() ->
    Ok = [
        %% 二期：命名路径、allShortestPaths、标签表达式、NULLS、=~、下标 / 切片、新函数、CALL
        "MATCH p = (a)-[r:T]->(b)<-[*1..2]-(c) WHERE length(p) > 1 RETURN p, nodes(p), relationships(p)",
        "MATCH p = allShortestPaths((a)-[:T*..5]->(b)) RETURN p",
        "MATCH (n:A|B:!C) WHERE n:D|E AND NOT n:!F RETURN n",
        "MATCH (n) RETURN n ORDER BY n.x DESC NULLS LAST, n.y NULLS first",
        "MATCH (n) WHERE n.s =~ '^a.*' RETURN n.list[0], n.list[1..], n.list[..-1], n['key'], [1, 2, 3][$i]",
        "RETURN substring('ab', 1), replace('a', 'a', 'b'), split('a,b', ','), trim(' a '), ltrim(' a'), rtrim('a '), "
        "left('ab', 1), right('ab', 1), reverse('ab'), head([1]), tail([1]), last([1]), range(1, 3), range(1, 9, 2)",
        "CALL db.labels()",
        "CALL db.relationshipTypes() YIELD relationshipType AS t WHERE t <> 'X' RETURN t",
        "CALL db.labels() YIELD label MATCH (n) WHERE label IN labels(n) RETURN label, count(n)",
        %% 二期：OPTIONAL MATCH、MERGE、CASE
        "MATCH (a) OPTIONAL MATCH (a)-[r:T]->(b) WHERE b.x > 1 RETURN a, r, b",
        "OPTIONAL MATCH (n:X) RETURN n",
        "MERGE (n:A {k: 1}) RETURN n",
        "MERGE (x:A) ON CREATE SET x.y = 1",
        "MERGE (n:A) ON MATCH SET n.m = 1 ON CREATE SET n.c = 1, n:B ON MATCH SET n.m2 = 2 RETURN n",
        "MATCH (a), (b) MERGE (a)-[r:T {w: 1}]->(b) ON CREATE SET r.c = true RETURN r",
        "MATCH (a), (b) MERGE (a)<-[:T]-(b)",
        "MERGE (a:X {k: 1})-[r:T]->(b:Y)-[:U]->(c) ON CREATE SET r.c = 1 RETURN a, b, c",
        "MATCH (a) MERGE (a)-[:T]->(:Z {k: 2})",
        "RETURN CASE WHEN 1 > 2 THEN 'a' WHEN true THEN 'b' ELSE 'c' END",
        "MATCH (n) RETURN CASE n.k WHEN 1 THEN 'one' END, CASE WHEN n.k IS NULL THEN 0 END AS z",
        "MATCH (n) RETURN n.case, n.end, n.when",
        %% MATCH / WHERE / 节点 / 关系 / 方向 / 多类型
        "MATCH (n) RETURN n",
        "MATCH (n:Person:Admin {name: 'x', age: 3}) WHERE n.age > 1 RETURN n",
        "MATCH (a)-[r:KNOWS]->(b), (b)<-[:KNOWS|LIKES]-(c), (c)-[:A|:B]-(d) RETURN a, r, b, c, d",
        "MATCH (a)-->(b)<--(c)--(d) RETURN d",
        "MATCH (a)<-->(b) RETURN b",
        "match (n) where n.x = 1 return n",                      %% 关键字不分大小写
        %% 变长
        "MATCH (a)-[*]->(b) RETURN b",
        "MATCH (a)-[r:T*2]->(b) RETURN r",
        "MATCH (a)-[:T*1..3]->(b) RETURN b",
        "MATCH (a)-[:T*..3]->(b) RETURN b",
        "MATCH (a)-[:T*2..]->(b) RETURN b",
        "MATCH (a)-[:T*0..1 {w: 1}]->(b) RETURN b",
        %% 最短路
        "MATCH p = shortestPath((a)-[:T*]->(b)) RETURN p, length(p), nodes(p), relationships(p)",
        "MATCH shortestPath((a:X {id: 1})-[*..5]-(b:Y)) RETURN a, b",
        %% RETURN / WITH / ORDER / SKIP / LIMIT / DISTINCT / *
        "MATCH (n) RETURN DISTINCT n.name AS name ORDER BY name DESC SKIP 1 LIMIT $k",
        "MATCH (n) RETURN *",
        "MATCH (n) RETURN *, n.x AS x",
        "MATCH (n) WITH n, count(*) AS c WHERE c > 1 RETURN n, c ORDER BY c ASCENDING, n.name DESCENDING",
        "MATCH (n) WITH DISTINCT n.city AS city ORDER BY city LIMIT 3 RETURN city",
        "MATCH (n) WITH * RETURN n",
        "UNWIND $list AS x RETURN x",
        "UNWIND [1, 2.5, 'a', true, false, null, [1], {a: 1}] AS x RETURN x",
        %% 表达式
        "RETURN 1 + 2 * 3 - 4 / 2 % 3 ^ 2 AS v, -1 AS m, 'a' + 'b' AS s",
        "RETURN 1 = 1 AND 2 <> 3 OR NOT false XOR true AS b",
        "RETURN 1 < 2, 2 <= 2, 3 > 2, 3 >= 3",
        "RETURN 'abc' STARTS WITH 'a', 'abc' ENDS WITH 'c', 'abc' CONTAINS 'b', 1 IN [1, 2]",
        "RETURN null IS NULL, 1 IS NOT NULL",
        "MATCH (n) WHERE n:Person:Admin RETURN n",
        "RETURN coalesce(null, 1), size([1]), toInteger('3'), toFloat(1), toString(1), toLower('A'), toUpper('a'), abs(-1)",
        "MATCH (n)-[r]->(m) RETURN id(n), labels(n), type(r), properties(r), keys(n), startNode(r), endNode(r)",
        "MATCH (n) RETURN count(*), count(n), count(DISTINCT n.x), sum(n.x), avg(n.x), min(n.x), max(n.x), collect(n.x)",
        "MATCH (n) RETURN count(*) + 1 AS c1",
        "MATCH (n) RETURN n.order, n.`weird name`, n.limit",             %% 关键字当属性名
        "MATCH (n:Order) RETURN n",                                        %% 关键字当标签
        "MATCH (`my var`) RETURN `my var`",
        "RETURN 'it\\'s', \"dq \\\"x\\\"\", '\\u4e2d', 1.5e3, 2E-1, 7",
        "// comment\nMATCH (n) /* block\ncomment */ RETURN n;",
        "MATCH (n {name: $name}) RETURN n",
        "CREATE (n $props)",
        %% 写子句（Q2-4 执行；现在要能解析、能检查）
        "CREATE (n:Person {name: 'x'})",
        "CREATE (a:A)-[:T {w: 1}]->(b:B)<-[:U]-(c)",
        "MATCH (a), (b) CREATE (a)-[:T]->(b)",
        "MATCH (n) SET n.x = 1, n += {y: 2}, n = {z: 3}, n:L:M",
        "MATCH (n) REMOVE n.x, n:L",
        "MATCH (n) DELETE n",
        "MATCH (n)-[r]->() DETACH DELETE n, r",
        "MATCH (n) SET n.x = 1 RETURN n"
    ],
    [{Q, ?_assertMatch({ok, _}, ?C:parse(Q))} || Q <- Ok].

writes_test() ->
    ?assertNot(?C:writes(<<"MATCH (n) RETURN n">>)),
    ?assert(?C:writes(<<"CREATE (n)">>)),
    ?assert(?C:writes(<<"MATCH (n) SET n.x = 1">>)),
    ?assert(?C:writes(<<"MATCH (n) DETACH DELETE n">>)),
    ?assert(?C:writes(<<"MATCH (n) REMOVE n:L">>)),
    {ok, P} = ?C:prepare(undefined, <<"MATCH (n) RETURN n">>),
    ?assertNot(?C:writes(P)).

err(Q) ->
    {error, E} = case ?C:parse(Q) of
                     {ok, _} -> ?C:explain(undefined, Q);
                     Other -> Other
                 end,
    E.

rejects_with_stage_and_location_test_() ->
    Cases = [
        %% {查询, 阶段, 行, 列, 消息片段}
        {"MATCH (n RETURN n", parse, 1, 10, "RETURN"},
        {"MATCH (n)\nRETURN n.", parse, 2, undefined, "end of query"},
        {"MATCH (n) RETURN 'abc", parse, 1, undefined, ""},
        {"MATCH (n) RETURN m", semantic, 1, 18, "`m` not defined"},
        {"MATCH (n) RETURN foo(n)", semantic, 1, 18, "unknown function"},
        {"MATCH (n) RETURN size(n, 1)", semantic, 1, 18, "wrong number"},
        {"MATCH (n) WHERE count(*) > 1 RETURN n", semantic, 1, 1, "WHERE"},
        {"MATCH (n) RETURN count(count(n))", semantic, 1, 11, "nested"},
        {"MATCH (n) WITH n.x RETURN 1", semantic, 1, 11, "aliased"},
        {"MATCH (n) RETURN n MATCH (m) RETURN m", semantic, 1, 11, "last clause"},
        {"MATCH (n)", semantic, 1, 1, "must end"},
        {"MATCH (a) MERGE (a)-[:T*2]->(b) RETURN a", semantic, 1, 20, "variable-length"},
        {"MATCH (a) MERGE (a) RETURN a", semantic, 1, 18, "already bound"},
        {"MATCH (a), (b) MERGE (a)-[:T|U]->(b) RETURN a", semantic, 1, 25, "exactly one"},
        {"MATCH (a), (b) MERGE (a:X)-[:T]->(b) RETURN a", semantic, 1, 23, "bound node"},
        {"MERGE (n {embedding: [1.0]}) RETURN n", semantic, 1, 7, "embedding"},
        {"MERGE (a)-[r:T]->(b)-[r:T]->(c) RETURN a", semantic, 1, 23, "used twice"},
        {"MERGE (a)-[:T]->(b:X|Y) RETURN a", semantic, 1, 17, "label expressions"},
        {"MATCH (a), (b) MERGE (a)-[:T]->(b) ON CREATE SET c.x = 1 RETURN a", semantic, 1, 50, "not defined"},
        {"MATCH (n) WHERE (n)-->(q) RETURN n", semantic, 1, 24, "new variables"},
        {"MATCH (n) WHERE (n)-[r]->() RETURN n", semantic, 1, 22, "relationship variables"},
        {"RETURN [x IN [1] | count(x)]", semantic, undefined, undefined, "inside list comprehensions"},
        {"RETURN exists(1)", semantic, 1, 8, "exists()"},
        {"RETURN 1 AS a UNION RETURN 2 AS b", plan, undefined, undefined, "same column names"},
        {"RETURN 1 AS a UNION ALL RETURN 2 AS a UNION RETURN 3 AS a", semantic, 1, 39, "mixed"},
        {"MATCH (n) RETURN n UNION MATCH (n) SET n.x = 1", semantic, 1, 36, "must end with RETURN"},
        {"CREATE (a) CREATE p = (a)-[:T]->(b) CREATE p = (b)-[:T]->(c)", semantic, 1, 44, "already declared"},
        {"CALL db.labels YIELD * RETURN label", semantic, 1, 1, "standalone"},
        {"WITH true AS n MATCH (n) RETURN n", semantic, 1, 23, "type conflict"},
        {"RETURN 1 AND true", semantic, undefined, undefined, "invalid argument type"},
        {"MATCH (me)--(you) RETURN me.age + count(you)", semantic, 1, 19, "ambiguous aggregation"},
        {"MATCH (a) CREATE (a)", semantic, 1, 19, "already declared"},
        {"WITH 123 AS x RETURN x.num", semantic, undefined, undefined, "can't read property"},
        {"MATCH (n) RETURN type(n)", semantic, 1, 18, "invalid argument type for type()"},
        {"RETURN 1 IN true", semantic, undefined, undefined, "IN needs a list"},
        {"MATCH (n) WHERE (n) RETURN n", semantic, undefined, undefined, "WHERE needs a boolean"},
        {"MATCH (n) RETURN n SKIP 1.5", semantic, 1, 11, "must be an integer"},
        {"RETURN none(x IN ['a'] WHERE x % 2 = 0)", semantic, undefined, undefined, "invalid argument type for %"},
        {"MATCH (n) DELETE 1 + 1", semantic, 1, 11, "DELETE takes"},
        {"CREATE (n:A|B)", semantic, 1, 9, "label expressions"},
        {"MATCH (n) SET n:!X", semantic, 1, 15, "label expressions"},
        {"CALL db.nope()", semantic, 1, 1, "unknown procedure"},
        {"CALL db.labels() YIELD nope RETURN nope", semantic, 1, 24, "no output"},
        {"CALL db.labels() RETURN 1", semantic, 1, 1, "needs YIELD"},
        {"MATCH (n) RETURN n ORDER BY n.x NULLS MIDDLE", parse, 1, 39, "FIRST or LAST"},
        {"MATCH (a)-[r]->(b)-[r]->(c) RETURN a", semantic, 1, 21, "used twice"},
        {"MATCH (a)-[r]->(b) MATCH (r) RETURN r", semantic, 1, 27, "already declared"},
        {"CREATE (a)-[:T]-(b)", semantic, 1, 11, "directed"},
        {"CREATE (a)-[]->(b)", semantic, 1, 11, "exactly one"},
        {"CREATE (a)-[:T*2]->(b)", semantic, 1, 11, "variable-length"},
        {"MATCH (n) RETURN toLower(DISTINCT n.x)", semantic, 1, 18, "DISTINCT"},
        {"MATCH (n) RETURN sum(*)", parse, 1, 18, "count(*)"},
        {"MATCH (n) RETURN n LIMIT n.x", semantic, 1, 11, "SKIP / LIMIT"},
        {"MATCH (n) RETURN n.x AS a, count(*) AS c ORDER BY n.y", semantic, 1, 11, "returned columns"},
        {"MATCH (n) RETURN n AS a, n AS a", semantic, 1, 11, "duplicate"},
        {"MATCH (n) SET m.x = 1", semantic, 1, 15, "not defined"},
        {"UNWIND [1] AS x MATCH (x) RETURN x", semantic, 1, 24, "type conflict"},
        {"MATCH (n)-[r*2]->(m) SET r.x = 1", semantic, 1, 26, "not a node or relationship"},
        {"MATCH (a) CREATE (a:L)-[:T]->(b)", semantic, 1, 19, "already bound"},
        {"MATCH (a) SET a._x = 1", semantic, 1, 15, "reserved"},
        {"MATCH (a) REMOVE a._labels", semantic, 1, 18, "reserved"},
        {"MATCH (a) RETURN score(a.x)", semantic, 1, 18, "score() takes a node variable"}
    ],
    [{Q, fun() ->
                 E = err(Q),
                 ?assertEqual(Stage, maps:get(stage, E)),
                 ?assertEqual(Line, maps:get(line, E, undefined)),
                 Col =:= undefined orelse ?assertEqual(Col, maps:get(column, E, undefined)),
                 Msg = binary_to_list(maps:get(message, E)),
                 ?assert(string:find(Msg, Frag) =/= nomatch)
         end} || {Q, Stage, Line, Col, Frag} <- Cases].

column_names_test() ->
    {ok, #{query := [_, {return, _, Items, _, _, _, _, _}]}} =
        ?C:parse("MATCH (n) RETURN n.name, count(DISTINCT n.x), n.age + 1, 'lit', n AS m, $p"),
    ?assertEqual([<<"n.name">>, <<"count(DISTINCT n.x)">>, <<"n.age + 1">>, <<"'lit'">>, <<"m">>, <<"$p">>],
                 [N || {N, _} <- Items]).

%% =========================================================================
%% 执行（Q2-3）：固定的小图
%% =========================================================================

-record(g, {r :: term(), ids :: map(), knows :: integer(), works :: integer(), likes :: integer()}).

with_people(F) ->
    bitcask_test_util:with_dir("cypher_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try F(people(R)) after ?G:close(R) end
    end).

people(R) ->
    {ok, Knows} = ?G:register_etype(R, <<"KNOWS">>),
    {ok, Works} = ?G:register_etype(R, <<"WORKS_AT">>),
    {ok, Likes} = ?G:register_etype(R, <<"LIKES">>),
    P = fun(Labels, Props) -> {ok, V} = ?G:create_vertex(R, #{labels => Labels, props => Props}), V end,
    Ann = P([<<"Person">>], #{name => <<"ann">>, age => 31, city => <<"Paris">>}),
    Bob = P([<<"Person">>], #{name => <<"bob">>, age => 25, city => <<"Berlin">>}),
    Cat = P([<<"Person">>, <<"Admin">>], #{name => <<"cat">>, age => 40, city => <<"Paris">>}),
    Dan = P([<<"Person">>], #{name => <<"dan">>, age => 19}),
    Eve = P([<<"Person">>], #{name => <<"eve">>, age => 31.0, city => <<"Berlin">>,
                               tags => [<<"x">>, <<"y">>]}),
    Acme = P([<<"Company">>], #{name => <<"acme">>}),
    Globex = P([<<"Company">>], #{name => <<"globex">>}),
    ok = ?G:put_edge(R, Ann, Knows, Bob, #{props => #{since => 2020}}),
    ok = ?G:put_edge(R, Ann, Knows, Bob, #{rank => 1, props => #{since => 2022}}),
    ok = ?G:put_edge(R, Bob, Knows, Cat, #{props => #{since => 2021}}),
    ok = ?G:put_edge(R, Cat, Knows, Ann, #{props => #{since => 2019}}),
    ok = ?G:put_edge(R, Ann, Knows, Dan),
    ok = ?G:put_edge(R, Dan, Knows, Eve),
    ok = ?G:put_edges(R, [{Ann, Works, Acme}, {Bob, Works, Acme}, {Cat, Works, Globex}]),
    ok = ?G:put_edge(R, Eve, Likes, Cat, #{props => <<"legacy:1">>}),
    ok = ?G:put_edge(R, Eve, 99, Ann),                 %% 没注册名字的类型
    ok = ?G:put_edge(R, Eve, 99, 1000),                %% 悬挂端点 1000
    ok = ?G:put_vertex(R, 500, <<"legacy text">>),     %% 旧式纯 binary 顶点
    #g{r = R, knows = Knows, works = Works, likes = Likes,
       ids = #{ann => Ann, bob => Bob, cat => Cat, dan => Dan, eve => Eve,
               acme => Acme, globex => Globex}}.

rows(R, Q) -> rows(R, Q, #{}).
rows(R, Q, P) ->
    case ?C:q(R, Q, P) of
        {ok, #{rows := Rows}} -> Rows;
        Other -> erlang:error({query_failed, Q, Other})
    end.

col(R, Q) -> col(R, Q, #{}).
col(R, Q, P) -> [V || [V] <- rows(R, Q, P)].

id(#g{ids = Ids}, K) -> maps:get(K, Ids).

basic_match_test() ->
    with_people(fun(#g{r = R} = G) ->
        ?assertEqual([<<"cat">>, <<"ann">>, <<"eve">>, <<"bob">>, <<"dan">>],
                     col(R, "MATCH (n:Person) RETURN n.name ORDER BY n.age DESC, n.name")),
        ?assertEqual([[<<"ann">>, <<"Paris">>], [<<"cat">>, <<"Paris">>]],
                     rows(R, "MATCH (n:Person {city: 'Paris'}) RETURN n.name, n.city ORDER BY n.name")),
        ?assertEqual([<<"cat">>], col(R, "MATCH (n:Person:Admin) RETURN n.name")),
        ?assertEqual([<<"cat">>], col(R, "MATCH (n:Admin:Person) RETURN n.name")),
        ?assertEqual([], col(R, "MATCH (n:Nobody) RETURN n")),
        %% 全部顶点 = n 文档 ∪ 邻接表头（含悬挂端点 1000、旧式顶点 500）
        ?assertEqual([[9]], rows(R, "MATCH (n) RETURN count(n)")),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7, 500, 1000], lists:sort(col(R, "MATCH (n) RETURN id(n)"))),
        ?assertEqual([<<"ann">>], col(R, "MATCH (n) WHERE id(n) = $id RETURN n.name", #{id => id(G, ann)})),
        ?assertEqual([<<"ann">>, <<"bob">>],
                     col(R, "MATCH (n) WHERE id(n) IN $ids RETURN n.name ORDER BY n.name",
                         #{ids => [id(G, bob), id(G, ann), 424242, id(G, bob)]})),
        %% 旧式纯 binary 顶点：正文暴露为属性 text；悬挂端点没有标签、没有属性
        ?assertEqual([[<<"legacy text">>, []]], rows(R, "MATCH (n) WHERE id(n) = 500 RETURN n.text, labels(n)")),
        ?assertEqual([[#{id => 1000, labels => [], properties => #{}}]],
                     rows(R, "MATCH (n) WHERE id(n) = 1000 RETURN n"))
    end).

result_value_shapes_test() ->
    with_people(fun(#g{r = R} = G) ->
        [[N, Rel, M]] = rows(R, "MATCH (n {name: 'bob'})-[r:KNOWS]->(m) RETURN n, r, m"),
        ?assertEqual(#{id => id(G, bob), labels => [<<"Person">>],
                       properties => #{<<"name">> => <<"bob">>, <<"age">> => 25, <<"city">> => <<"Berlin">>}}, N),
        ?assertEqual(#{src => id(G, bob), type => <<"KNOWS">>, dst => id(G, cat), rank => 0,
                       properties => #{<<"since">> => 2021}}, Rel),
        ?assertEqual(id(G, cat), maps:get(id, M)),
        %% 没注册名字的类型：type 是整数；旧的任意二进制边属性暴露为 _raw
        ?assertEqual([[99]], rows(R, "MATCH (e {name: 'eve'})-[r]->(a {name: 'ann'}) RETURN type(r)")),
        ?assertEqual([#{<<"_raw">> => <<"legacy:1">>}], col(R, "MATCH ()-[r:LIKES]->() RETURN properties(r)")),
        ?assertEqual([[id(G, bob), G#g.knows, id(G, cat), 0]], col(R, "MATCH ({name: 'bob'})-[r:KNOWS]->() RETURN id(r)"))
    end).

expand_matches_api_test() ->
    with_people(fun(#g{r = R, knows = K} = G) ->
        Ann = id(G, ann),
        {ok, Out} = ?G:out_edges(R, Ann, #{etype => K}),
        ?assertEqual(lists:sort([[Ann, K, D, Rk] || #{dst := D, rank := Rk} <- Out]),
                     lists:sort(col(R, "MATCH (a)-[r:KNOWS]->(b) WHERE id(a) = $a RETURN id(r)", #{a => Ann}))),
        ?assertEqual(lists:sort([D || #{dst := D} <- Out]),
                     lists:sort(col(R, "MATCH (a)-[:KNOWS]->(b) WHERE id(a) = $a RETURN id(b)", #{a => Ann}))),
        %% 入边方向：属性在源端，按需点查
        ?assertEqual([[<<"ann">>, 2019]], rows(R, "MATCH (a {name: 'ann'})<-[r:KNOWS]-(c) RETURN a.name, r.since")),
        %% 无向：两个方向都算，自环只一次
        ?assertEqual(lists:sort([<<"bob">>, <<"bob">>, <<"cat">>, <<"dan">>]),
                     lists:sort(col(R, "MATCH (a {name: 'ann'})-[:KNOWS]-(b) RETURN b.name"))),
        %% 多类型与未知类型
        ?assertEqual(lists:sort([<<"bob">>, <<"bob">>, <<"dan">>, <<"acme">>]),
                     lists:sort(col(R, "MATCH (a {name: 'ann'})-[:KNOWS|WORKS_AT]->(b) RETURN b.name"))),
        ?assertEqual([], col(R, "MATCH (a {name: 'ann'})-[:NOPE]->(b) RETURN b")),
        %% 不带类型：全部出边（含数字类型 99）
        ?assertEqual(lists:sort([id(G, cat), id(G, ann), 1000]),
                     lists:sort(col(R, "MATCH (e {name: 'eve'})-->(b) RETURN id(b)"))),
        %% 平行边：rank 不同算两条
        ?assertEqual([2020, 2022], col(R, "MATCH ({name: 'ann'})-[r:KNOWS]->({name: 'bob'}) RETURN r.since ORDER BY r.since")),
        ?assertEqual([[2]], rows(R, "MATCH ({name: 'ann'})-[r:KNOWS {since: 2022}]->(b) RETURN r.since - 2020"))
    end).

expand_into_and_uniqueness_test() ->
    with_people(fun(#g{r = R}) ->
        %% 两端都已绑定（展开到）：互相认识
        ?assertEqual([], rows(R, "MATCH (a)-[:KNOWS]->(b), (b)-[:KNOWS]->(a) RETURN a.name, b.name")),
        %% 三角形 ann → bob → cat → ann：从三个起点各数一次，ann→bob 有两条平行边，所以每个起点两行
        ?assertEqual([<<"ann">>, <<"ann">>, <<"bob">>, <<"bob">>, <<"cat">>, <<"cat">>],
                     lists:sort(col(R, "MATCH (a)-[:KNOWS]->(b)-[:KNOWS]->(c)-[:KNOWS]->(a) RETURN a.name"))),
        %% 关系唯一性：同一个 MATCH 里一条边不匹配两次
        ?assertEqual([], rows(R, "MATCH (a {name: 'dan'})-[r1]-(b)-[r2]-(a) RETURN r1, r2")),
        ?assertEqual(2, length(rows(R, "MATCH (a {name: 'ann'})-[r1:KNOWS]->(b {name: 'bob'})<-[r2:KNOWS]-(a) RETURN r1, r2"))),
        %% 跨 MATCH 子句不受关系唯一性约束
        ?assertEqual(4, length(rows(R, "MATCH (a {name: 'ann'})-[r1:KNOWS]->(b {name: 'bob'}) MATCH (a)-[r2:KNOWS]->(b) RETURN r1, r2")))
    end).

var_length_test() ->
    with_people(fun(#g{r = R} = G) ->
        Ann = id(G, ann),
        %% ann 沿 KNOWS 1..3 跳能到的（按路径计，平行边与环各算一条路径）
        Got = lists:sort(col(R, "MATCH (a)-[:KNOWS*1..3]->(b) WHERE id(a) = $a RETURN b.name", #{a => Ann})),
        ?assertEqual(lists:sort(manual_paths(R, G#g.knows, Ann, 1, 3)), Got),
        ?assertEqual([<<"ann">>], col(R, "MATCH (a {name: 'ann'})-[:KNOWS*0]->(b) RETURN b.name")),
        ?assert(lists:member(<<"ann">>, col(R, "MATCH (a {name: 'ann'})-[:KNOWS*0..1]->(b) RETURN b.name"))),
        %% 关系变量绑定成列表（两条平行的 ann→bob 各走出一条路径）
        Lists = col(R, "MATCH (a {name: 'ann'})-[r:KNOWS*2]->(c {name: 'cat'}) RETURN r"),
        ?assertEqual([[2020, 2021], [2022, 2021]],
                     lists:sort([[maps:get(<<"since">>, maps:get(properties, X)) || X <- L] || L <- Lists])),
        ?assertEqual([2, 2], col(R, "MATCH (a {name: 'ann'})-[r:KNOWS*2]->(c {name: 'cat'}) RETURN size(r)")),
        %% 两端都已绑定的变长（展开到）
        ?assertEqual([[2], [2]], rows(R, "MATCH (a {name: 'ann'}), (c {name: 'cat'}) MATCH (a)-[r:KNOWS*2]->(c) RETURN size(r)")),
        %% 缺省上限 10：环上的路径不会无限展开（ann→bob→cat→ann 的环）
        N = length(rows(R, "MATCH (a {name: 'ann'})-[:KNOWS*]->(b) RETURN b")),
        ?assertEqual(length(manual_paths(R, G#g.knows, Ann, 1, 10)), N)
    end).

%% 手算：从 V 沿类型 T 的出边，路径内边不重复，长度 Min..Max 的路径终点（名字）。
manual_paths(R, T, V, Min, Max) ->
    Name = fun(X) -> {ok, #{properties := #{<<"name">> := N}}} = ?G:vertex(R, X), N end,
    [Name(E) || E <- mp(R, T, V, 0, Min, Max, #{})].

mp(R, T, V, D, Min, Max, Used) ->
    Here = [V || D >= Min],
    case D < Max of
        false -> Here;
        true ->
            {ok, Es} = ?G:out_edges(R, V, #{etype => T}),
            Here ++ lists:append([mp(R, T, Dst, D + 1, Min, Max, Used#{{V, Dst, Rk} => true})
                                  || #{dst := Dst, rank := Rk} <- Es, not is_map_key({V, Dst, Rk}, Used)])
    end.

shortest_path_test() ->
    with_people(fun(#g{r = R} = G) ->
        {ok, Path} = ?G:shortest_path(R, id(G, ann), id(G, eve), #{etype => G#g.knows}),
        [[Len, Ns]] = rows(R, "MATCH p = shortestPath((a {name: 'ann'})-[:KNOWS*]->(b {name: 'eve'})) "
                              "RETURN length(p), nodes(p)"),
        ?assertEqual(length(Path) - 1, Len),
        ?assertEqual(Path, [maps:get(id, N) || N <- Ns]),
        %% 反方向（沿入边）、无向、上限不够、没有路
        ?assertEqual([[2]], rows(R, "MATCH p = shortestPath((b {name: 'eve'})<-[:KNOWS*]-(a {name: 'ann'})) RETURN length(p)")),
        ?assertEqual([[1]], rows(R, "MATCH p = shortestPath((a {name: 'cat'})-[*]-(b {name: 'eve'})) RETURN length(p)")),
        ?assertEqual([], rows(R, "MATCH p = shortestPath((a {name: 'ann'})-[:KNOWS*..1]->(b {name: 'eve'})) RETURN p")),
        ?assertEqual([], rows(R, "MATCH p = shortestPath((a {name: 'eve'})-[:KNOWS*]->(b {name: 'ann'})) RETURN p")),
        %% 多类型走执行器自己的 BFS；关系变量绑定成列表
        [[2, Rs]] = rows(R, "MATCH shortestPath((a {name: 'cat'})-[r:KNOWS|WORKS_AT*]->(c:Company {name: 'acme'})) "
                            "RETURN size(r), r"),
        ?assertEqual([<<"KNOWS">>, <<"WORKS_AT">>], [maps:get(type, X) || X <- Rs])
    end).

where_semantics_test() ->
    with_people(fun(#g{r = R}) ->
        %% 1 = 1.0（openCypher）：eve 的 age 是浮点 31.0
        ?assertEqual([<<"ann">>, <<"eve">>], col(R, "MATCH (n:Person) WHERE n.age = 31 RETURN n.name ORDER BY n.name")),
        %% 缺失属性是 null：比较得 null，不通过
        ?assertEqual([<<"dan">>], col(R, "MATCH (n:Person) WHERE n.city IS NULL RETURN n.name")),
        ?assertEqual(4, length(col(R, "MATCH (n:Person) WHERE n.city IS NOT NULL RETURN n"))),
        ?assertEqual([], col(R, "MATCH (n:Person) WHERE n.city = null RETURN n")),
        ?assertEqual([<<"bob">>, <<"eve">>], col(R, "MATCH (n:Person) WHERE n.city IN ['Berlin', 'Rome'] RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"bob">>, <<"eve">>], col(R, "MATCH (n:Person) WHERE n.city STARTS WITH 'Be' RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"ann">>, <<"cat">>], col(R, "MATCH (n:Person) WHERE n.city ENDS WITH 'is' RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"eve">>], col(R, "MATCH (n:Person) WHERE 'y' IN n.tags RETURN n.name")),
        ?assertEqual([<<"ann">>, <<"bob">>], col(R, "MATCH (n:Person) WHERE n.age > 20 AND n.age < 35 AND n.name <> 'eve' RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"cat">>, <<"dan">>], col(R, "MATCH (n:Person) WHERE n.age < 20 OR n.age > 35 RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"dan">>], col(R, "MATCH (n:Person) WHERE NOT (n.age >= 20) RETURN n.name")),
        ?assertEqual([<<"ann-Paris">>], col(R, "MATCH (n {name: 'ann'}) RETURN n.name + '-' + n.city")),
        ?assertEqual([[7, 2.5, 1, 8.0, 2, true, null, null]],
                     rows(R, "RETURN 1 + 2 * 3, 5 / 2.0, 7 % 3, 2 ^ 3, 5 / 2, null IS NULL, null = null, 1 < 'a'")),
        ?assertEqual([[true, false, null]], rows(R, "RETURN 1 IN [1, null], 2 IN [1], 2 IN [1, null]")),
        ?assertEqual([[3, 1.5, <<"7">>, <<"abc">>, <<"ABC">>, 4, 2, null]],
                     rows(R, "RETURN toInteger('3'), toFloat('1.5'), toString(7), toLower('ABC'), toUpper('abc'), "
                             "size('中文ab'), size([1, 2]), toInteger('x')"))
    end).

aggregation_test() ->
    with_people(fun(#g{r = R}) ->
        %% count(DISTINCT n.city)：null 不计（dan 没有 city）
        ?assertEqual([[5, 5, 2, 146.0, 29.2, 19, 40]],
                     rows(R, "MATCH (n:Person) RETURN count(*), count(n.age), count(DISTINCT n.city), "
                             "sum(n.age), avg(n.age), min(n.age), max(n.age)")),
        ?assertEqual([[<<"Berlin">>, 2], [<<"Paris">>, 2], [null, 1]],
                     rows(R, "MATCH (n:Person) RETURN n.city AS city, count(*) AS c ORDER BY city")),
        ?assertEqual([[<<"acme">>, [<<"ann">>, <<"bob">>]], [<<"globex">>, [<<"cat">>]]],
                     rows(R, "MATCH (p:Person)-[:WORKS_AT]->(c:Company) "
                             "WITH c.name AS company, p.name AS person ORDER BY person "
                             "RETURN company, collect(person) AS people ORDER BY company")),
        %% 没有输入行：没有分组键时仍出一行；有分组键时没有行
        ?assertEqual([[0, null, []]], rows(R, "MATCH (n:Nobody) RETURN count(*), max(n.x), collect(n.x)")),
        ?assertEqual([], rows(R, "MATCH (n:Nobody) RETURN n.x, count(*)")),
        %% 聚合包在表达式里；按聚合结果排序
        ?assertEqual([[<<"Berlin">>, 3], [<<"Paris">>, 3]],
                     rows(R, "MATCH (n:Person) WHERE n.city IS NOT NULL RETURN n.city AS city, count(*) + 1 AS c ORDER BY c DESC, city")),
        ?assertEqual([[2]], rows(R, "MATCH (n:Person) WITH n.city AS city, count(*) AS c WHERE c > 1 AND city IS NOT NULL RETURN count(*)")),
        %% 1 与 1.0 分到一组（ann 31、eve 31.0）
        [[Age, 2]] = rows(R, "MATCH (n:Person) WHERE n.age > 30 AND n.age < 32 RETURN n.age, count(*)"),
        ?assert(Age == 31)
    end).

distinct_order_paging_test() ->
    with_people(fun(#g{r = R}) ->
        ?assertEqual([<<"Berlin">>, <<"Paris">>, null], col(R, "MATCH (n:Person) RETURN DISTINCT n.city ORDER BY n.city")),
        ?assertEqual([null, <<"Paris">>, <<"Berlin">>], col(R, "MATCH (n:Person) RETURN DISTINCT n.city AS c ORDER BY c DESC")),
        ?assertEqual([<<"bob">>, <<"cat">>], col(R, "MATCH (n:Person) RETURN n.name ORDER BY n.name SKIP 1 LIMIT 2")),
        ?assertEqual([<<"cat">>, <<"dan">>], col(R, "MATCH (n:Person) RETURN n.name ORDER BY n.name SKIP $s LIMIT $l", #{s => 2, l => 2})),
        ?assertEqual([], col(R, "MATCH (n:Person) RETURN n.name LIMIT 0")),
        %% ORDER BY 用投影前的变量（不在结果里）
        ?assertEqual([<<"dan">>, <<"bob">>], col(R, "MATCH (n:Person) RETURN n.name ORDER BY n.age LIMIT 2")),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "MATCH (n) RETURN n LIMIT $l", #{l => -1}))
    end).

unwind_with_pipeline_test() ->
    with_people(fun(#g{r = R}) ->
        ?assertEqual([[1, <<"a">>], [2, <<"a">>]], rows(R, "UNWIND $xs AS x RETURN x, 'a'", #{xs => [1, 2]})),
        ?assertEqual([], rows(R, "UNWIND null AS x RETURN x")),
        ?assertEqual([[5]], rows(R, "UNWIND 5 AS x RETURN x")),
        ?assertEqual([<<"bob">>, <<"dan">>],
                     col(R, "UNWIND ['ann'] AS name MATCH (a:Person {name: name})-[:KNOWS]->(b) "
                            "RETURN DISTINCT b.name ORDER BY b.name")),
        ?assertEqual([[<<"ann">>, 2]],
                     rows(R, "MATCH (a:Person)-[:KNOWS]->(b) WITH a, count(DISTINCT b) AS n WHERE n > 1 "
                             "RETURN a.name, n")),
        ?assertEqual([<<"ann">>, <<"bob">>, <<"cat">>, <<"dan">>, <<"eve">>],
                     col(R, "MATCH (n:Person) WITH n ORDER BY n.name WITH collect(n.name) AS ns UNWIND ns AS x RETURN x"))
    end).

functions_test() ->
    with_people(fun(#g{r = R} = G) ->
        [[Labels, Props, Keys, Type, Start, End, Coal]] =
            rows(R, "MATCH (c {name: 'cat'})-[r:KNOWS]->(a) RETURN labels(c), properties(r), keys(c), type(r), "
                    "id(startNode(r)), id(endNode(r)), coalesce(c.nope, c.city, 'x')"),
        ?assertEqual([<<"Person">>, <<"Admin">>], Labels),
        ?assertEqual(#{<<"since">> => 2019}, Props),
        ?assertEqual([<<"age">>, <<"city">>, <<"name">>], Keys),
        ?assertEqual(<<"KNOWS">>, Type),
        ?assertEqual({id(G, cat), id(G, ann)}, {Start, End}),
        ?assertEqual(<<"Paris">>, Coal),
        ?assertMatch({error, #{stage := exec}}, ?C:q(R, "RETURN 1 / 0")),
        ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "WITH 'a' AS s RETURN s - toInteger('1') * 0 + (s - 1)")),
        ?assertMatch({error, #{stage := semantic, message := <<"missing parameter(s): $x">>}}, ?C:q(R, "RETURN $x"))
    end).

params_test() ->
    with_people(fun(#g{r = R}) ->
        ?assertEqual([[<<"x">>, null, [1, null], #{<<"k">> => 1}]],
                     rows(R, "RETURN $s, $u, $l, $m", #{s => <<"x">>, <<"u">> => undefined, l => [1, undefined], m => #{k => 1}})),
        %% MATCH 的模式里属性不能是参数（openCypher：SyntaxError / InvalidParameterUse）；用 WHERE 或逐个属性
        ?assertMatch({error, #{stage := semantic, type := <<"SyntaxError">>, detail := <<"InvalidParameterUse">>}},
                     ?C:q(R, "MATCH (n:Person $p) RETURN n.name", #{p => #{name => <<"ann">>}})),
        ?assertEqual([<<"ann">>], col(R, "MATCH (n:Person {name: $p.name, city: $p.city}) RETURN n.name",
                                      #{p => #{name => <<"ann">>, city => <<"Paris">>}})),
        {ok, P} = ?C:prepare(R, "MATCH (n:Person {name: $n}) RETURN n.age"),
        ?assertEqual({ok, #{columns => [<<"n.age">>], rows => [[25]], stats => #{}}}, ?C:q(R, P, #{n => <<"bob">>})),
        ?assertEqual({ok, #{columns => [<<"n.age">>], rows => [[40]], stats => #{}}}, ?C:q(R, P, #{n => <<"cat">>}))
    end).

explain_start_choice_test() ->
    Ops = fun(Q) -> {ok, #{ops := O}} = ?C:explain(undefined, Q), O end,
    %% id 条件 > 标签 > 全量扫描
    ?assertMatch([{node_by_id, <<"n">>, {param, <<"i">>}} | _],
                 Ops("MATCH (n:Person) WHERE id(n) = $i RETURN n")),
    ?assertMatch([{node_by_id, <<"n">>, {id_list, {list, _}}} | _],
                 Ops("MATCH (n) WHERE id(n) IN [1, 2] RETURN n")),
    %% 其余标签下推给引擎（第 7.3 节），Erlang 侧照样核对；RETURN n 要文档 ⇒ fetch
    ?assertMatch([{label_scan, <<"n">>, <<"A">>, #{push := [{has_label, <<"B">>}], fetch := true}},
                  {node_check, <<"n">>, [<<"B">>], []} | _],
                 Ops("MATCH (n:A:B) RETURN n")),
    ?assertMatch([{all_nodes_scan, <<"n">>, [{cmp, <<"x">>, eq, {lit, 1}}]} | _], Ops("MATCH (n {x: 1}) RETURN n")),
    ?assertMatch([{all_nodes_scan, <<"n">>} | _], Ops("MATCH (n) RETURN n")),
    %% 只用到 id 的标签扫描不取文档（三元组形态不变）
    ?assertMatch([{label_scan, <<"n">>, <<"A">>} | _], Ops("MATCH (n:A) RETURN id(n), count(*)")),
    %% 下推形态：比较翻转、IN、IS NOT NULL；正文 / 向量、两边都是变量的不下推
    ?assertMatch([{label_scan, <<"n">>, <<"A">>, #{push := [{cmp, <<"k">>, gt, {lit, 3}}, {in, <<"c">>, _},
                                                            {exists, <<"z">>}]}} | _],
                 Ops("MATCH (n:A) WHERE 3 < n.k AND n.c IN ['x', 'y'] AND n.z IS NOT NULL "
                     "AND n.text = 'a' AND n.k = n.j RETURN n")),
    %% 有标签的一端作起点，展开方向随之翻转
    ?assertMatch([{label_scan, <<"b">>, <<"B">>}, {expand, <<"b">>, _, [<<"T">>], in, <<"a">>, false, []} | _],
                 Ops("MATCH (a)-[:T]->(b:B) RETURN a")),
    %% 条件在变量齐全时立刻过滤（展开之前）
    ?assertMatch([{label_scan, <<"a">>, <<"A">>, #{push := [{cmp, <<"x">>, eq, _}]}}, {filter, _},
                  {expand, _, _, _, _, _, _, _} | _],
                 Ops("MATCH (a:A)-->(b) WHERE a.x = 1 RETURN b")),
    %% 已绑定的变量优先作起点：从 a 展开到 b，再查 b 的标签（不扫 B）
    ?assertMatch([{label_scan, <<"a">>, <<"A">>, _}, {project, _, _}, {select, _},
                  {expand, <<"a">>, _, [], out, <<"b">>, false, []},
                  {node_check, <<"b">>, [<<"B">>], []} | _],
                 Ops("MATCH (a:A) WITH a MATCH (b:B), (a)-->(b) RETURN b")),
    %% 两端都已绑定 → 展开到
    ?assertMatch([{label_scan, <<"a">>, _}, {label_scan, <<"b">>, _, #{fetch := true}},
                  {expand, <<"a">>, _, _, out, <<"b">>, true, []} | _],
                 Ops("MATCH (a:A), (b:B) MATCH (a)-->(b) RETURN b")),
    %% 不连通的模式：各自起点（嵌套循环）
    ?assertMatch([{label_scan, <<"a">>, <<"A">>, _}, {label_scan, <<"b">>, <<"B">>, _} | _],
                 Ops("MATCH (a:A), (b:B) RETURN a, b")),
    %% ORDER BY + LIMIT
    ?assertMatch([_, {project, _, true}, {sort, _}, {limit, {lit, 3}}, {select, [<<"n">>]}],
                 Ops("MATCH (n:A) RETURN n ORDER BY n.x LIMIT 3")).

limit_stops_scanning_test() ->
    bitcask_test_util:with_dir("cypher_limit_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            [{ok, _} = ?G:create_vertex(R, #{labels => [<<"L">>]}) || _ <- lists:seq(1, 2000)],
            meck:new(graphdb_model, [passthrough]),
            try
                ?assertEqual([[1]], rows(R, "MATCH (n:L) RETURN id(n) LIMIT 1")),
                %% 2000 个顶点、每批 256：LIMIT 1 只取了第一批
                ?assertEqual(1, meck:num_calls(graphdb_model, label_vids, '_')),
                ?assertEqual([[2000]], rows(R, "MATCH (n:L) RETURN count(*)"))
            after
                meck:unload(graphdb_model)
            end
        after
            ?G:close(R)
        end
    end).

%% 「同一查询 vs 用图层 API 手写」：随机图上的两跳邻居计数。
two_hop_matches_api_test_() ->
    {timeout, 120, fun() ->
        bitcask_test_util:with_dir("cypher_2hop_", fun(D) ->
            R = ?G:open(D, [read_write]),
            try
                {ok, T} = ?G:register_etype(R, <<"E">>),
                rand:seed(exsss, {7, 8, 9}),
                Vs = [begin {ok, V} = ?G:create_vertex(R, #{labels => [<<"V">>], props => #{k => I rem 5}}), V end
                      || I <- lists:seq(1, 200)],
                ok = ?G:put_edges(R, [{lists:nth(rand:uniform(200), Vs), T, lists:nth(rand:uniform(200), Vs)}
                                      || _ <- lists:seq(1, 800)]),
                Out = fun(V) -> {ok, Es} = ?G:out_edges(R, V, #{etype => T}), [{D2, Rk} || #{dst := D2, rank := Rk} <- Es] end,
                Manual = lists:sort(
                           [{V, length([1 || {M, R1} <- Out(V), {W, R2} <- Out(M), {V, M, R1} =/= {M, W, R2}])}
                            || V <- Vs]),
                Got = lists:sort([{V, C} || [V, C] <- rows(R, "MATCH (a:V)-[:E]->(b)-[:E]->(c) RETURN id(a), count(*)")]),
                ?assertEqual([X || {_, C} = X <- Manual, C > 0], Got),
                %% 带属性条件的计数也一致
                K2 = lists:sort([V || V <- Vs, {ok, #{properties := #{<<"k">> := 2}}} <- [?G:vertex(R, V)]]),
                ?assertEqual(K2, lists:sort(col(R, "MATCH (n:V {k: 2}) RETURN id(n)"))),
                ?assertMatch({ok, _}, ?G:check_invariants(R))
            after
                ?G:close(R)
            end
        end)
    end}.

%% =========================================================================
%% 条件下推（第 7.3 节）：下推只负责少读，结果必须与不下推完全一致。参照查询把谓词包成
%% NOT (NOT (P))——三值逻辑下语义相同，但不匹配任何下推形态。数据混入整数 / 浮点 / 字符串 /
%% 布尔 / 缺失、时而整数时而浮点的列；标签 A 有密集段也有稀疏段（走 range 与逐个读两条路）。
%% KV 模式与索引模式各跑一遍。
%% =========================================================================

pushdown_matches_unpushed_test_() ->
    [{timeout, 120, fun() -> pushdown_case(Opts) end}
     || Opts <- [[read_write], [read_write, {analyzer, whitespace}]]].

pushdown_case(Opts) ->
    bitcask_test_util:with_dir("cypher_push_", fun(D) ->
        R = ?G:open(D, Opts),
        try
            %% vid 1..900：600 以内 A 密集（每 3 个里 2 个），600 以后 A 稀疏（每 25 个 1 个），其余 B
            [begin
                 IsA = case I =< 600 of true -> I rem 3 =/= 0; false -> I rem 25 =:= 0 end,
                 Props0 = #{k => I rem 10,
                            f => (I rem 10) + case I rem 2 of 0 -> 0.0; 1 -> 0.5 end,
                            s => iolist_to_binary(["x", integer_to_list(I rem 10)]),
                            b => I rem 4 =:= 0,
                            m => case I rem 3 of 0 -> I rem 5; 1 -> float(I rem 5); 2 -> <<"a">> end},
                 Props = case I rem 7 of 0 -> maps:remove(k, Props0); _ -> Props0#{z => 1} end,
                 Labels = case IsA of true -> [<<"A">>] ++ [<<"B">> || I rem 11 =:= 0]; false -> [<<"B">>] end,
                 ok = ?G:put_vertex(R, I, #{labels => Labels, props => Props})
             end || I <- lists:seq(1, 900)],
            Preds = ["n.k = 3", "n.k = 3.0", "n.f = 2", "n.f = 2.5", "n.f < 3", "n.f >= 2",
                     "n.k < 2.5", "n.k > 7.0", "3 > n.k", "n.k <= 4 AND n.k >= 4.0",
                     "n.s = 'x3'", "n.s < 'x5'", "n.m = 1", "n.m = 2.0", "n.m IN [1, 2.0, 'a']",
                     "n.k IN [1, 9]", "n.z IS NOT NULL", "n.b = true", "n.b = false", "n:B",
                     "n.k = $p", "n.k = null", "n.k > $p AND n.s <> 'x9'", "n.k IN $ps",
                     "n.k = 1 OR n.k = 2", "n.nope = 1"],
            Params = #{p => 5, ps => [2, 3.0, <<"x">>]},
            Ids = fun(Q) -> lists:sort([V || [V] <- rows(R, Q, Params)]) end,
            lists:foreach(
              fun(P) ->
                      Pushed = Ids("MATCH (n:A) WHERE " ++ P ++ " RETURN id(n)"),
                      Plain = Ids("MATCH (n:A) WHERE NOT (NOT (" ++ P ++ ")) RETURN id(n)"),
                      ?assertEqual({P, Plain}, {P, Pushed}),
                      PushedAll = Ids("MATCH (n) WHERE " ++ P ++ " RETURN id(n)"),
                      PlainAll = Ids("MATCH (n) WHERE NOT (NOT (" ++ P ++ ")) RETURN id(n)"),
                      ?assertEqual({all, P, PlainAll}, {all, P, PushedAll})
              end, Preds),
            %% 内联属性 + 多标签
            ?assertEqual(Ids("MATCH (n:A) WHERE NOT (NOT (n.k = 4 AND n:B)) RETURN id(n)"),
                         Ids("MATCH (n:A:B {k: 4}) RETURN id(n)")),
            ?assertEqual(Ids("MATCH (n) WHERE NOT (NOT (n.k = 4)) RETURN id(n)"),
                         Ids("MATCH (n {k: 4.0}) RETURN id(n)")),
            %% 批量取回的文档与逐个读的一致：属性、标签、正文、向量（向量不随 range 读回，按需补读）
            Full = rows(R, "MATCH (n:A) WHERE n.k = 2 RETURN n ORDER BY id(n)"),
            ?assert(length(Full) > 20),
            lists:foreach(fun([#{id := Vid} = N]) ->
                                  {ok, #{labels := L, properties := Pr}} = ?G:vertex(R, Vid),
                                  ?assertEqual(#{id => Vid, labels => L, properties => Pr}, N)
                          end, Full),
            %% 聚合（只取文档、没有下推条件）与逐个读的结果一致
            ?assertEqual(rows(R, "MATCH (n:A) WITH n, n.k AS k RETURN k, count(*) ORDER BY k"),
                         rows(R, "MATCH (n:A) WHERE NOT (NOT (n:A)) RETURN n.k, count(*) ORDER BY n.k"))
        after
            ?G:close(R)
        end
    end).

%% 按查询文本缓存计划（进程字典）：同一段文本第二次直接用缓存；参数不同结果照常；出错的
%% 查询不缓存；超过容量整体清空。
plan_cache_test() ->
    bitcask_test_util:with_dir("cypher_pcache_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            erase({bitcask_cypher, plan_cache}),
            {ok, _} = ?C:q(R, "CREATE (:P {n: 1}), (:P {n: 2})"),
            Q = "MATCH (p:P) WHERE p.n = $n RETURN p.n",
            ?assertEqual([[1]], rows(R, Q, #{n => 1})),
            ?assertEqual([[2]], rows(R, Q, #{n => 2})),
            PC = fun() -> {_Gen, M} = get({bitcask_cypher, plan_cache}), M end,
            ?assert(is_map_key(<<"MATCH (p:P) WHERE p.n = $n RETURN p.n">>, PC())),
            ?assertMatch({error, #{stage := parse}}, ?C:q(R, "MATCH (p RETURN p")),
            ?assertNot(is_map_key(<<"MATCH (p RETURN p">>, PC())),
            [{ok, _} = ?C:q(R, "RETURN " ++ integer_to_list(I)) || I <- lists:seq(1, 200)],
            ?assert(map_size(PC()) =< 128),
            %% 注册表一变，缓存作废
            ok = ?C:register_function(<<"pc.f">>, #{arity => 0, fn => fun(_, []) -> 1 end}),
            ?assertEqual([[1]], rows(R, "RETURN pc.f()")),
            ?assertNot(is_map_key(<<"MATCH (p:P) WHERE p.n = $n RETURN p.n">>, PC())),
            ok = ?C:unregister(<<"pc.f">>),
            ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "RETURN pc.f()")),
            ?assertEqual([[1]], rows(R, Q, #{n => 1}))
        after
            ?G:close(R)
        end
    end).

%% id(v) 起点后紧跟一跳展开时不单独查存在：不存在的 id、没有边的顶点都不出行；单独
%% RETURN a 仍按存在判断。
start_without_existence_check_test() ->
    bitcask_test_util:with_dir("cypher_nocheck_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, #{rows := [[A, B, C]]}} =
                ?C:q(R, "CREATE (a:P)-[:T]->(b:P), (c:P) RETURN id(a), id(b), id(c)"),
            {ok, #{ops := Ops}} = ?C:explain(R, "MATCH (a)-[:T]->(b) WHERE id(a) = $v RETURN id(b)"),
            ?assertMatch([{node_by_id, <<"a">>, _, nocheck} | _], Ops),
            Hop = fun(V) -> rows(R, "MATCH (a)-[:T]->(b) WHERE id(a) = $v RETURN id(b)", #{v => V}) end,
            ?assertEqual([[B]], Hop(A)),
            ?assertEqual([], Hop(C)),                       %% 存在、没有边
            ?assertEqual([], Hop(999999)),                  %% 不存在
            ?assertEqual([[A]], rows(R, "MATCH (b)<-[:T]-(a) WHERE id(b) = $v RETURN id(a)", #{v => B})),
            ?assertEqual([[C]], rows(R, "MATCH (a) WHERE id(a) = $v RETURN id(a)", #{v => C})),
            ?assertEqual([], rows(R, "MATCH (a) WHERE id(a) = $v RETURN id(a)", #{v => 999999})),
            %% 变长（可能 0 跳）照旧查存在
            ?assertEqual([[C]], rows(R, "MATCH (a)-[:T*0..1]->(b) WHERE id(a) = $v RETURN id(b)", #{v => C})),
            ?assertEqual([], rows(R, "MATCH (a)-[:T*0..1]->(b) WHERE id(a) = $v RETURN id(b)", #{v => 999999})),
            %% 嵌套运行（调用方事务里跑语句）：查询内缓存不串
            {atomic, {ok, #{rows := [[1]]}}} =
                ?G:transaction(R, fun(Tx) ->
                                         {ok, _} = ?C:q(Tx, "MATCH (a) WHERE id(a) = $v SET a.k = 1", #{v => C}),
                                         ?C:q(Tx, "MATCH (a) WHERE id(a) = $v RETURN a.k", #{v => C})
                                 end)
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% 二期：OPTIONAL MATCH、CASE
%% =========================================================================

optional_match_test() ->
    bitcask_test_util:with_dir("cypher_opt_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "CREATE (a:P {n: 1})-[:T {w: 5}]->(b:P {n: 2})-[:T]->(c:P {n: 3}), (d:P {n: 4})"),
            %% 一跳：没有出边的行保留，新变量为 null
            ?assertEqual([[1, 2], [2, 3], [3, null], [4, null]],
                         rows(R, "MATCH (a:P) OPTIONAL MATCH (a)-[:T]->(b) RETURN a.n, b.n ORDER BY a.n")),
            %% 关系变量与两跳
            ?assertEqual([[1, 5, 3], [2, null, null], [3, null, null], [4, null, null]],
                         rows(R, "MATCH (a:P) OPTIONAL MATCH (a)-[r:T]->()-[:T]->(c) RETURN a.n, r.w, c.n ORDER BY a.n")),
            %% WHERE 属于可选模式：不满足 → null，不是丢行
            ?assertEqual([[1, null], [2, 3], [3, null], [4, null]],
                         rows(R, "MATCH (a:P) OPTIONAL MATCH (a)-[:T]->(b) WHERE b.n > 2 RETURN a.n, b.n ORDER BY a.n")),
            %% 与聚合 / coalesce 组合
            ?assertEqual([[1, 1, [2]], [2, 1, [3]], [3, 0, []], [4, 0, []]],
                         rows(R, "MATCH (a:P) OPTIONAL MATCH (a)-[:T]->(b) "
                                 "RETURN a.n, count(b), collect(b.n) ORDER BY a.n")),
            ?assertEqual([[1, 2], [3, -1]],
                         rows(R, "MATCH (a:P) WHERE a.n IN [1, 3] OPTIONAL MATCH (a)-[:T]->(b) "
                                 "RETURN a.n, coalesce(b.n, -1) ORDER BY a.n")),
            %% 第一个子句就是 OPTIONAL MATCH：没有匹配时出一行 null
            ?assertEqual([[null]], rows(R, "OPTIONAL MATCH (x:Nope) RETURN x")),
            ?assertEqual([[0]], rows(R, "OPTIONAL MATCH (x:Nope) RETURN count(x)")),
            %% 可选匹配之后再 MATCH：null 顶点展开不出行
            ?assertEqual([[1, 3]],
                         rows(R, "MATCH (a:P) OPTIONAL MATCH (a)-[:T]->(b) MATCH (b)-[:T]->(c) RETURN a.n, c.n")),
            %% 可选模式里引用的已绑定变量带标签：不满足 → 新变量 null，已绑定的照旧
            ?assertEqual([[1, null]], rows(R, "MATCH (a:P {n: 1}) OPTIONAL MATCH (a)-[:T]->(b:Nope) RETURN a.n, b")),
            %% 计划形态
            {ok, #{ops := Ops}} = ?C:explain(R, "MATCH (a:P) OPTIONAL MATCH (a)-[r:T]->(b) RETURN a, b"),
            ?assertMatch([{label_scan, <<"a">>, <<"P">>, _}, {optional, [{expand, <<"a">>, <<"r">>, _, out, <<"b">>, false, _}], [<<"r">>, <<"b">>]} | _], Ops),
            %% 在事务里
            {atomic, {ok, #{rows := [[4, null]]}}} =
                ?G:transaction(R, fun(Tx) -> ?C:q(Tx, "MATCH (a:P {n: 4}) OPTIONAL MATCH (a)-->(b) RETURN a.n, b") end)
        after
            ?G:close(R)
        end
    end).

case_expr_test() ->
    bitcask_test_util:with_dir("cypher_case_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "UNWIND [1, 2, 3, 4] AS i CREATE (:P {n: i})"),
            {ok, _} = ?C:q(R, "CREATE (:P)"),                          %% n 为 null
            ?assertEqual([[1, <<"small">>], [2, <<"small">>], [3, <<"big">>], [4, <<"big">>], [null, <<"none">>]],
                         rows(R, "MATCH (p:P) RETURN p.n, CASE WHEN p.n IS NULL THEN 'none' "
                                 "WHEN p.n > 2 THEN 'big' ELSE 'small' END ORDER BY p.n")),
            %% 简单形式；没有 ELSE → null；主体为 null 不等于任何值
            ?assertEqual([[1, <<"one">>], [2, <<"two">>], [3, null], [4, null], [null, null]],
                         rows(R, "MATCH (p:P) RETURN p.n, CASE p.n WHEN 1 THEN 'one' WHEN 2.0 THEN 'two' END ORDER BY p.n")),
            %% 条件为 null 不算命中
            ?assertEqual([[<<"else">>]], rows(R, "RETURN CASE WHEN null THEN 'x' ELSE 'else' END")),
            %% 套在聚合里、引用聚合结果
            ?assertEqual([[2, 3]], rows(R, "MATCH (p:P) RETURN sum(CASE WHEN p.n > 2 THEN 1 ELSE 0 END), "
                                           "count(CASE WHEN p.n < 4 THEN p END)")),
            ?assertEqual([[<<"many">>]], rows(R, "MATCH (p:P) WITH count(*) AS c RETURN CASE WHEN c > 3 THEN 'many' ELSE 'few' END")),
            ?assertEqual([[<<"big">>, 2], [<<"small">>, 2], [null, 1]],
                         rows(R, "MATCH (p:P) RETURN CASE WHEN p.n > 2 THEN 'big' WHEN p.n > 0 THEN 'small' END AS g, "
                                 "count(*) ORDER BY g")),
            %% WHERE / ORDER BY 里
            ?assertEqual([4, 3], [N || [N] <- rows(R, "MATCH (p:P) WHERE CASE WHEN p.n > 2 THEN true ELSE false END "
                                                      "RETURN p.n ORDER BY CASE p.n WHEN 4 THEN 0 ELSE 1 END")]),
            %% 只求值命中的分支（另一个分支会出错）
            ?assertEqual([[1]], rows(R, "RETURN CASE WHEN true THEN 1 ELSE 1 / 0 END")),
            %% 列名
            {ok, #{columns := [C]}} = ?C:q(R, "RETURN CASE WHEN true THEN 1 END"),
            ?assertEqual(<<"CASE WHEN true THEN 1 END">>, C)
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% 二期其余：命名路径、allShortestPaths、标签表达式、NULLS、=~、函数、下标 / 切片、CALL
%% =========================================================================

phase2_graph(R) ->
    %% a(1) -T-> b(2) -T-> d(4)；a -T-> c(3) -T-> d；e(5) 孤立
    {ok, _} = ?C:q(R, "CREATE (a:P:X {n: 1, s: 'hello world'})-[:T {w: 1}]->(b:P {n: 2})-[:T {w: 2}]->(d:Q {n: 4}), "
                      "(a)-[:T {w: 3}]->(c:Q {n: 3})-[:T {w: 4}]->(d), (e:R {n: 5})"),
    ok.

named_path_and_all_shortest_test() ->
    bitcask_test_util:with_dir("cypher_paths_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            phase2_graph(R),
            %% 普通命名路径：节点 / 关系序列与长度
            ?assertEqual([[2, [1, 2, 4], [1, 2]], [2, [1, 3, 4], [3, 4]]],
                         [[L, [N || #{properties := #{<<"n">> := N}} <- Ns], [W || #{properties := #{<<"w">> := W}} <- Rs]]
                          || [L, Ns, Rs] <- rows(R, "MATCH p = (a {n: 1})-[:T]->(m)-[:T]->(z) "
                                                     "RETURN length(p), nodes(p), relationships(p) ORDER BY m.n")]),
            %% 变长段：中间顶点从关系端点推出；反方向的模式
            ?assertEqual([[1, 2], [1, 3], [2, 4], [2, 4]],
                         rows(R, "MATCH p = (a {n: 1})-[:T*1..2]->(c) RETURN length(p), last(nodes(p)).n "
                                 "ORDER BY length(p), last(nodes(p)).n")),
            ?assertEqual([[[4, 2, 1]], [[4, 3, 1]]],
                         [[[N || #{properties := #{<<"n">> := N}} <- Ns]] || [Ns] <- rows(R,
                             "MATCH p = (d {n: 4})<-[:T]-()<-[:T]-(a) RETURN nodes(p) ORDER BY nodes(p)[1].n")]),
            %% WHERE 引用路径；OPTIONAL MATCH 没匹配上 → 路径 null
            ?assertEqual([[3]], rows(R, "MATCH p = (a {n: 1})-[:T]->(m) WHERE nodes(p)[1].n > 2 RETURN m.n")),
            ?assertEqual([[5, null]], rows(R, "MATCH (e {n: 5}) OPTIONAL MATCH p = (e)-[:T]->() RETURN e.n, p")),
            %% allShortestPaths：两条长度 2 的路；与 shortestPath 同长
            ?assertEqual([[2, 2], [2, 3]],
                         rows(R, "MATCH (a {n: 1}), (d {n: 4}) MATCH p = allShortestPaths((a)-[:T*]->(d)) "
                                 "RETURN length(p), nodes(p)[1].n ORDER BY nodes(p)[1].n")),
            ?assertEqual([[2]], rows(R, "MATCH (a {n: 1}), (d {n: 4}) MATCH p = shortestPath((a)-[:T*]->(d)) RETURN length(p)")),
            ?assertEqual([], rows(R, "MATCH (a {n: 1}), (e {n: 5}) MATCH p = allShortestPaths((a)-[:T*]->(e)) RETURN p")),
            ?assertEqual([], rows(R, "MATCH (a {n: 1}), (d {n: 4}) MATCH p = allShortestPaths((a)-[:T*3..]->(d)) RETURN p")),
            ?assertEqual([[1]], rows(R, "MATCH (a {n: 1}), (b {n: 2}) MATCH p = allShortestPaths((a)-[:T*]-(b)) RETURN length(p)"))
        after
            ?G:close(R)
        end
    end).

label_expr_and_ordering_test() ->
    bitcask_test_util:with_dir("cypher_lexpr_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            phase2_graph(R),
            Ns = fun(Q) -> [N || [N] <- rows(R, Q)] end,
            ?assertEqual([1, 2, 3, 4], Ns("MATCH (n:P|Q) RETURN n.n ORDER BY n.n")),
            ?assertEqual([2], Ns("MATCH (n:P:!X) RETURN n.n")),
            ?assertEqual([3, 4, 5], Ns("MATCH (n:!P) RETURN n.n ORDER BY n.n")),
            ?assertEqual([3, 4, 5], Ns("MATCH (n) WHERE n:Q|R RETURN n.n ORDER BY n.n")),
            ?assertEqual([1], Ns("MATCH (n) WHERE n:P AND NOT n:!X RETURN n.n")),
            ?assertEqual([3], Ns("MATCH (:P {n: 1})-[:T]->(m:Q|R) RETURN m.n")),
            %% 下推等价：A|B 交给引擎 contains_any，结果与不下推一致
            ?assertEqual(Ns("MATCH (n) WHERE NOT (NOT (n:Q|X)) AND n.n > 0 RETURN n.n ORDER BY n.n"),
                         Ns("MATCH (n:Q|X) WHERE n.n > 0 RETURN n.n ORDER BY n.n")),
            {ok, #{ops := [{all_nodes_scan, <<"n">>, [{has_any_label, [<<"Q">>, <<"X">>]} | _]} | _]}} =
                ?C:explain(R, "MATCH (n:Q|X) WHERE n.n > 0 RETURN n"),
            %% NULLS FIRST / LAST，多个排序键
            {ok, _} = ?C:q(R, "CREATE (:S {a: 1, b: null}), (:S {a: 1, b: 2}), (:S {a: null, b: 1})"),
            ?assertEqual([[null, 1], [1, null], [1, 2]],
                         rows(R, "MATCH (s:S) RETURN s.a, s.b ORDER BY s.a NULLS FIRST, s.b NULLS FIRST")),
            ?assertEqual([[1, 2], [1, null], [null, 1]],
                         rows(R, "MATCH (s:S) RETURN s.a, s.b ORDER BY s.a DESC NULLS LAST, s.b DESC NULLS LAST")),
            ?assertEqual([[null, 1], [1, 2], [1, null]],
                         rows(R, "MATCH (s:S) RETURN s.a, s.b ORDER BY s.a DESC, s.b ASC"))
        after
            ?G:close(R)
        end
    end).

phase2_functions_test() ->
    bitcask_test_util:with_dir("cypher_fn2_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            One = fun(Q) -> [[V]] = rows(R, Q), V end,
            %% =~ 匹配整个字符串；null 传播；坏模式 → 执行错误
            ?assertEqual([true, false, true, null],
                         One("RETURN ['hello' =~ 'h.*o', 'hello' =~ 'ell', 'Hello' =~ '(?i)hello', null =~ 'x']")),
            ?assertMatch({error, #{stage := exec}}, ?C:q(R, "RETURN 'a' =~ '('")),
            %% 字符串
            ?assertEqual([<<"ell">>, <<"llo">>, <<>>, <<"a+b+c">>, [<<"a">>, <<"b">>, <<>>, <<"c">>], [<<"中"/utf8>>, <<"文"/utf8>>]],
                         One("RETURN [substring('hello', 1, 3), substring('hello', 2), substring('hi', 5), "
                             "replace('a-b-c', '-', '+'), split('a,b,,c', ','), split('中文', '')]")),
            ?assertEqual([<<"x">>, <<"x  ">>, <<"  x">>, <<"he">>, <<"lo">>, <<"文中"/utf8>>],
                         One("RETURN [trim('  x  '), ltrim('  x  '), rtrim('  x  '), left('hello', 2), right('hello', 2), reverse('中文')]")),
            ?assertEqual([null, null, null], One("RETURN [substring(null, 1), replace('a', null, 'b'), left(null, 1)]")),
            ?assertMatch({error, #{stage := exec}}, ?C:q(R, "RETURN substring('abc', -1)")),
            %% 列表
            ?assertEqual([1, [2, 3], 3, null, [], null, [3, 2, 1]],
                         One("RETURN [head([1, 2, 3]), tail([1, 2, 3]), last([1, 2, 3]), head([]), tail([]), last([]), reverse([1, 2, 3])]")),
            ?assertEqual([[1, 2, 3], [0, 3, 6, 9], [5, 3, 1], []],
                         One("RETURN [range(1, 3), range(0, 10, 3), range(5, 1, -2), range(1, 0)]")),
            ?assertMatch({error, #{stage := exec}}, ?C:q(R, "RETURN range(1, 5, 0)")),
            %% 下标与切片
            ?assertEqual([1, 4, null, [2, 3], [1, 2], [3, 4], [], 7, null],
                         One("RETURN [[1, 2, 3, 4][0], [1, 2, 3, 4][-1], [1, 2, 3, 4][9], [1, 2, 3, 4][1..3], "
                             "[1, 2, 3, 4][..2], [1, 2, 3, 4][-2..], [1, 2][5..], {a: 7}['a'], [1][null]]")),
            ?assertEqual([[2]], rows(R, "RETURN [1, 2, 3][$i]", #{i => 1})),
            {ok, _} = ?C:q(R, "CREATE (:P {name: 'x', tags: ['a', 'b']})"),
            ?assertEqual([<<"x">>, <<"b">>, <<"P">>], One("MATCH (n:P) RETURN [n['name'], n.tags[-1], labels(n)[0]]")),
            ?assertMatch({error, #{stage := exec}}, ?C:q(R, "RETURN [1, 2]['a']"))
        after
            ?G:close(R)
        end
    end).

procedures_test() ->
    bitcask_test_util:with_dir("cypher_procs_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            ?assertEqual([], rows(R, "CALL db.labels()")),
            phase2_graph(R),
            ?assertEqual([[<<"P">>], [<<"Q">>], [<<"R">>], [<<"X">>]], rows(R, "CALL db.labels()")),
            {ok, #{columns := [<<"label">>]}} = ?C:q(R, "CALL db.labels()"),
            ?assertEqual([[<<"T">>]], rows(R, "CALL db.relationshipTypes()")),
            ?assertEqual([[<<"n">>], [<<"s">>]], rows(R, "CALL db.propertyKeys()")),
            ?assertEqual([[[<<"P">>, <<"Q">>, <<"R">>]]],
                         rows(R, "CALL db.labels() YIELD label AS l WHERE l <> 'X' RETURN collect(l)")),
            ?assertEqual([[<<"P">>, 2], [<<"Q">>, 2], [<<"R">>, 1], [<<"X">>, 1]],
                         rows(R, "CALL db.labels() YIELD label MATCH (n) WHERE label IN labels(n) "
                                 "RETURN label, count(n) ORDER BY label")),
            %% 标签没有顶点了就不再列出
            {ok, _} = ?C:q(R, "MATCH (e:R) DETACH DELETE e"),
            ?assertEqual([[<<"P">>], [<<"Q">>], [<<"X">>]], rows(R, "CALL db.labels()")),
            %% 事务里
            {atomic, {ok, #{rows := [[<<"T">>]]}}} =
                ?G:transaction(R, fun(Tx) -> ?C:q(Tx, "CALL db.relationshipTypes()") end)
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% openCypher 对齐（第 1 组）：推导、量词、reduce、映射投影、链式比较、exists、数学 / 统计函数、进制字面量
%% =========================================================================

opencypher_expressions_test() ->
    bitcask_test_util:with_dir("cypher_oc1_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            One = fun(Q) -> [[V]] = rows(R, Q), V end,
            {ok, _} = ?C:q(R, "CREATE (:P {n: 1, name: 'a'})-[:T {w: 2}]->(:P {n: 2, name: 'b'})-[:T {w: 3}]->(:P {n: 3, name: 'c'})"),
            %% 列表推导
            ?assertEqual([[20, 40, 60], [1, 2, 3], [2, 3, 4], [2, 3], null],
                         One("RETURN [[x IN range(1, 6) WHERE x % 2 = 0 | x * 10], [x IN [1, 2, 3]], "
                             "[x IN [1, 2, 3] | x + 1], [x IN [1, 2, 3] WHERE x > 1], [x IN null | x]]")),
            %% 外层同名变量被局部变量遮住，推导外照旧
            ?assertEqual([[[10, 20], 5]], rows(R, "WITH 5 AS x RETURN [x IN [1, 2] | x * 10], x")),
            ?assertEqual([[[<<"a">>, <<"b">>, <<"c">>], 5]],
                         rows(R, "MATCH p = (a {n: 1})-[:T*]->(c {n: 3}) "
                                 "RETURN [x IN nodes(p) | x.name], reduce(s = 0, r IN relationships(p) | s + r.w)")),
            %% 量词（三值语义）
            ?assertEqual([true, true, true, true, false, true],
                         One("RETURN [all(x IN [1, 2] WHERE x > 0), any(x IN [1, 2] WHERE x > 1), "
                             "none(x IN [1, 2] WHERE x > 5), single(x IN [1, 2] WHERE x = 2), "
                             "single(x IN [1, 1] WHERE x = 1), all(x IN [] WHERE false)]")),
            ?assertEqual([null, null, false, null, null],
                         One("RETURN [all(x IN [1, null] WHERE x > 0), any(x IN [null] WHERE x > 0), "
                             "all(x IN [0, null] WHERE x > 0), none(x IN [null] WHERE x > 0), all(x IN null WHERE true)]")),
            ?assertEqual([<<"ab">>, 6], One("RETURN [reduce(a = '', s IN ['a', 'b'] | a + s), reduce(t = 0, x IN [1, 2, 3] | t + x)]")),
            %% reduce 的列表部分可以是聚合
            ?assertEqual([[3]], rows(R, "UNWIND [[1, 2], [3]] AS l RETURN reduce(t = 0, x IN collect(l) | t + size(x))")),
            %% 映射投影
            ?assertEqual([[#{<<"name">> => <<"a">>, <<"n">> => 1},
                           #{<<"name">> => <<"a">>, <<"n">> => 1, <<"extra">> => 2},
                           #{<<"name">> => <<"a">>, <<"five">> => 5}]],
                         rows(R, "MATCH (n:P {n: 1}) WITH n, 5 AS five RETURN n {.name, .n}, n {.*, extra: n.n * 2}, n {.name, five}")),
            ?assertEqual([[#{<<"w">> => 2}, #{<<"k">> => 1}]],
                         rows(R, "MATCH (:P {n: 1})-[r:T]->() WITH r, {k: 1, j: 2} AS m RETURN r {.w}, m {.k}")),
            %% 链式比较
            ?assertEqual([[2], [3]], rows(R, "MATCH (n:P) WHERE 1 < n.n <= 3 RETURN n.n ORDER BY n.n")),
            ?assertEqual([true, false, true, false], One("RETURN [1 < 2 < 3, 3 > 2 > 2, 1 = 1 = 1, 1 < 3 < 2]")),
            %% exists(n.prop)
            ?assertEqual([[3]], rows(R, "MATCH (n:P) WHERE exists(n.name) AND NOT exists(n.nope) RETURN count(*)")),
            %% 进制字面量与数学函数
            ?assertEqual([31, 15, 2.0, 1.0, 3.0, -1, 4.0, 'NaN', '-Infinity', 1.0, 2.0],
                         One("RETURN [0x1F, 0o17, ceil(1.2), floor(1.8), round(2.5), sign(-3), sqrt(16), sqrt(-1), "
                             "log(0), exp(0), log10(100)]")),
            ?assertEqual([true, true, 1.0, 1.0, 180.0, 0.0, true, true],
                         One("RETURN [e() > 2.718, pi() > 3.1415, round(sin(pi() / 2)), cos(0), degrees(pi()), "
                             "haversin(0), timestamp() > 0, 0 <= rand() < 1]")),
            ?assert(abs(One("RETURN atan2(1, 1) * 4") - math:pi()) < 1.0e-12),
            ?assertEqual('NaN', One("RETURN acos(2)")),
            %% 统计聚合
            [[P50c, P50d, Sd, SdP, P0, P100]] =
                rows(R, "UNWIND [1, 2, 3, 4] AS x RETURN percentileCont(x, 0.5), percentileDisc(x, 0.5), "
                        "stDev(x), stDevP(x), percentileCont(x, 0.0), percentileDisc(x, 1.0)"),
            ?assertEqual({2.5, 2, 1.0, 4}, {P50c, P50d, P0, P100}),
            ?assert(abs(Sd - 1.2909944487358056) < 1.0e-12),
            ?assert(abs(SdP - 1.118033988749895) < 1.0e-12),
            ?assertEqual([[null, 0.0]], rows(R, "UNWIND [] AS x RETURN percentileCont(x, 0.5), stDev(x)")),
            ?assertMatch({error, #{stage := exec}}, ?C:q(R, "UNWIND [1] AS x RETURN percentileCont(x, 2)")),
            %% 函数名关键字仍可作变量
            ?assertEqual([[3]], rows(R, "MATCH (all:P) WITH all AS any RETURN count(any)"))
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% openCypher 对齐（第 2 组）：模式谓词、exists(模式)、模式推导
%% =========================================================================

pattern_expressions_test() ->
    bitcask_test_util:with_dir("cypher_oc2_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "CREATE (:P {n: 1, name: 'a'})-[:T {w: 2}]->(:P {n: 2, name: 'b'})-[:T {w: 3}]->(:P {n: 3, name: 'c'})"),
            ?assertEqual([[<<"a">>], [<<"b">>]], rows(R, "MATCH (n:P) WHERE (n)-[:T]->() RETURN n.name ORDER BY n.name")),
            ?assertEqual([[<<"c">>]], rows(R, "MATCH (n:P) WHERE NOT (n)-[:T]->(:P) RETURN n.name")),
            ?assertEqual([[<<"b">>]], rows(R, "MATCH (n:P) WHERE (n)<--({name: 'a'}) RETURN n.name")),
            ?assertEqual([[<<"a">>]], rows(R, "MATCH (n:P) WHERE exists((n)--()) AND (n)-[:T*2]->() RETURN n.name")),
            ?assertEqual([[false, true, false]],
                         rows(R, "MATCH (a:P {n: 1}), (c:P {n: 3}) RETURN exists((a)-->(c)), exists((a)-[:T*]->(c)), exists((c)-->(a))")),
            %% 外层变量是 null（OPTIONAL MATCH 没匹配上）→ null
            ?assertEqual([[<<"a">>, null]],
                         rows(R, "MATCH (n:P {n: 1}) OPTIONAL MATCH (n)-[:X]->(z) RETURN n.name, exists((z)-->())")),
            %% 带括号的表达式仍是表达式
            ?assertEqual([[null, 0]], rows(R, "MATCH (n:P {n: 1}) RETURN (n) < -1, (n.n) - (1)")),
            %% 模式推导
            ?assertEqual([[<<"a">>, [<<"b:2">>]], [<<"b">>, [<<"c:3">>]], [<<"c">>, []]],
                         rows(R, "MATCH (n:P) RETURN n.name, [(n)-[r:T]->(m) | m.name + ':' + toString(r.w)] ORDER BY n.name")),
            ?assertEqual([[[1, 2]]], rows(R, "MATCH (n:P {n: 1}) RETURN [p = (n)-[:T*]->() | length(p)]")),
            ?assertEqual([[<<"a">>, 1], [<<"b">>, 1], [<<"c">>, 1]],
                         rows(R, "MATCH (n:P) RETURN n.name, size([(n)--(m) WHERE m.n > 1 | m]) ORDER BY n.name")),
            ?assertEqual([[2]], rows(R, "MATCH (n:P) WITH n WHERE (n)-->() RETURN count(*)")),
            %% 模式只能当谓词用（openCypher）：投影 / 函数参数里是语法错误
            ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "MATCH (n:P) RETURN (n)-->()")),
            ?assertMatch({error, #{stage := semantic}}, ?C:q(R, "MATCH (n:P) RETURN size((n)-->())")),
            %% 写语句里也能用
            ?assertEqual([[2]], rows(R, "MATCH (n:P {n: 2}) SET n.deg = size([(n)--() | 1]) RETURN n.deg"))
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% openCypher 对齐（第 3 组）：UNION、CALL 省括号 / YIELD *
%% =========================================================================

union_and_call_test() ->
    bitcask_test_util:with_dir("cypher_oc3_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "CREATE (:P {n: 1, name: 'a'})-[:T]->(:P {n: 2, name: 'b'}), (:Q {n: 2})"),
            ?assertEqual([[<<"a">>], [<<"b">>]],
                         lists:sort(rows(R, "MATCH (n:P) RETURN n.name AS x UNION MATCH (n:P) RETURN n.name AS x"))),
            ?assertEqual([[<<"a">>], [<<"b">>], [<<"b">>]],
                         rows(R, "MATCH (n:P) RETURN n.name AS x UNION ALL MATCH (n:P) WHERE n.n > 1 RETURN n.name AS x")),
            ?assertEqual([[1], [2]], rows(R, "RETURN 1 AS a UNION RETURN 1 AS a UNION RETURN 2 AS a")),
            %% 各段同名变量互不相干
            ?assertEqual([[1], [2]], lists:sort(rows(R, "MATCH (n:P) RETURN n.n AS a UNION MATCH (n:Q) RETURN n.n AS a"))),
            {ok, #{columns := [<<"a">>]}} = ?C:q(R, "RETURN 1 AS a UNION RETURN 2 AS a"),
            %% 游标里也行
            {ok, Cur} = ?C:cursor(R, "UNWIND [1, 2] AS a RETURN a UNION ALL UNWIND [3] AS a RETURN a"),
            ?assertEqual({ok, [[1], [2], [3]], done}, ?C:fetch(Cur, 10)),
            %% CALL 省括号 / YIELD *
            ?assertEqual([[<<"P">>], [<<"Q">>]], rows(R, "CALL db.labels")),
            ?assertEqual([[<<"P">>], [<<"Q">>]], rows(R, "CALL db.labels YIELD label RETURN label ORDER BY label")),
            ?assertEqual([[<<"T">>]], rows(R, "CALL db.relationshipTypes() YIELD *"))
        after
            ?G:close(R)
        end
    end).

%% =========================================================================
%% 流式游标
%% =========================================================================

cursor_test() ->
    bitcask_test_util:with_dir("cypher_cursor_", fun(D) ->
        R = ?G:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "UNWIND range(1, 1000) AS i CREATE (:P {n: i})"),
            Q = "MATCH (p:P) WHERE p.n % 3 = 0 RETURN p.n",
            All = rows(R, Q),
            {ok, C} = ?C:cursor(R, Q),
            ?assertEqual([<<"p.n">>], ?C:columns(C)),
            Drain = fun Loop(Acc) ->
                            case ?C:fetch(C, 50) of
                                {ok, Rows, more} -> ?assertEqual(50, length(Rows)), Loop(Acc ++ Rows);
                                {ok, Rows, done} -> Acc ++ Rows
                            end
                    end,
            ?assertEqual(All, Drain([])),
            %% 取完自动关闭；close 幂等
            ?assertMatch({error, #{message := <<"cursor_closed">>}}, ?C:fetch(C, 1)),
            ?assertEqual(ok, ?C:close(C)),
            %% 恰好整批：最后一批就标 done
            {ok, C2} = ?C:cursor(R, "MATCH (p:P) WHERE p.n <= 100 RETURN p.n ORDER BY p.n"),
            ?assertMatch({ok, [_ | _], done}, ?C:fetch(C2, 100)),
            %% 惰性：只取前 5 行，第 500 行才会出错的表达式不会被求值
            {ok, C3} = ?C:cursor(R, "MATCH (p:P) RETURN 10 / (p.n - $k)", #{k => 500}),
            ?assertMatch({ok, [_, _, _, _, _], more}, ?C:fetch(C3, 5)),
            ok = ?C:close(C3),
            %% 参数、预编译的查询都能开
            {ok, Pre} = ?C:prepare(R, "MATCH (p:P) WHERE p.n > $m RETURN count(*)"),
            {ok, C4} = ?C:cursor(R, Pre, #{m => 990}),
            ?assertEqual({ok, [[10]], done}, ?C:fetch(C4, 10)),
            %% 开游标的进程退出 → 游标关闭
            Self = self(),
            spawn(fun() -> {ok, C5} = ?C:cursor(R, "MATCH (p:P) RETURN p.n"), Self ! {c5, C5} end),
            C5 = receive {c5, X} -> X end,
            timer:sleep(50),
            ?assertMatch({error, #{message := <<"cursor_closed">>}}, ?C:fetch(C5, 1)),
            %% 空闲超时
            {ok, C6} = ?C:cursor(R, "MATCH (p:P) RETURN p.n", #{}, [{idle_timeout, 30}]),
            timer:sleep(100),
            ?assertMatch({error, #{message := <<"cursor_closed">>}}, ?C:fetch(C6, 1)),
            %% 写语句、事务里、缺参数、执行错误
            ?assertMatch({error, #{message := <<"cursors are only for read-only", _/binary>>}},
                         ?C:cursor(R, "CREATE (:X)")),
            {atomic, {error, #{message := <<"cursors can only", _/binary>>}}} =
                ?G:transaction(R, fun(Tx) -> ?C:cursor(Tx, "MATCH (p) RETURN p") end),
            ?assertMatch({error, #{message := <<"missing parameter", _/binary>>}}, ?C:cursor(R, "RETURN $x")),
            {ok, C7} = ?C:cursor(R, "RETURN 1 / 0"),
            ?assertMatch({error, #{stage := exec}}, ?C:fetch(C7, 1))
        after
            ?G:close(R)
        end
    end).
