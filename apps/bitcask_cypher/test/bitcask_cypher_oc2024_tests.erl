%% openCypher 2024.3 文法对齐（grammar/openCypher.bnf；TASK.md O1～O6）。
-module(bitcask_cypher_oc2024_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, bitcask_cypher).

with_graph(F) ->
    bitcask_test_util:with_dir("cypher_oc2024_", fun(D) ->
        R = graphdb:open(D, [read_write]),
        try
            {ok, _} = ?C:q(R, "CREATE (a:A {name: 'a', num: 1})-[:T {w: 1}]->(b:B {name: 'b', num: 2})"
                              "-[:T {w: 2}]->(c:C {name: 'c', num: 3}), (a)-[:U {w: 3}]->(c)"),
            F(R)
        after
            graphdb:close(R)
        end
    end).

rows(R, Q) -> rows(R, Q, #{}).
rows(R, Q, P) ->
    case ?C:q(R, Q, P) of
        {ok, #{rows := Rows}} -> Rows;
        Other -> erlang:error({query_failed, Q, Other})
    end.

one(R, Q) -> [[V]] = rows(R, Q), V.
err(R, Q) -> {error, E} = ?C:q(R, Q), E.

%% ---- O1 词法与名字 ------------------------------------------------------------
lexical_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[1000, 31, 15, 10.5]], rows(R, "RETURN 1_000, 0x_1F, 0o_17, 1_0.5")),
        ?assertEqual([[1.5, 2.5, 1000.0, 1.5]], rows(R, "RETURN 1.5f, 2.5d, 1e3F, 1.5D")),
        ?assertEqual([['Infinity', 'Infinity', '-Infinity', true]], rows(R, "RETURN INF, INFINITY, -INF, isNaN(NAN)")),
        ?assertEqual([[<<"it's">>, <<"say \"hi\"">>]], rows(R, "RETURN 'it''s', \"say \"\"hi\"\"\"")),
        ?assertEqual(<<"`A", 16#1F600/utf8>>, one(R, "RETURN '\\`\\u0041\\U01F600'")),
        ?assertEqual(<<"a`b">>, hd(maps:get(columns, element(2, ?C:q(R, "WITH 1 AS `a``b` RETURN `a``b`"))))),
        ?assertMatch(#{detail := <<"InvalidNumberLiteral">>}, err(R, "RETURN 1_")),
        ?assertMatch(#{detail := <<"InvalidUnicodeCharacter">>}, err(R, "RETURN 42 \x{2014} 41"))
    end).

names_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[<<"a">>]], rows(R, "MATCH (ñ:A) RETURN ñ.name")),
        ?assertEqual([1], [V || [V] <- rows(R, "RETURN 1 AS 名字")]),
        ?assertEqual([[3]], rows(R, "RETURN $p + $`weird name` + $0", #{p => 1, <<"weird name">> => 1, <<"0">> => 1})),
        %% 关键字都可以当变量名
        ?assertEqual([[1, 2, 3]], rows(R, "RETURN 1 AS count, 2 AS match, 3 AS order")),
        ?assertEqual([[1]], rows(R, "WITH 1 AS return RETURN return")),
        ?assertEqual([[<<"a">>]], rows(R, "MATCH (match:A) RETURN match.name")),
        ?assertEqual([[2]], rows(R, "MATCH ()-[order:T {w: 2}]->() RETURN order.w")),
        ?assertEqual([[1]], rows(R, "MATCH (n:A) RETURN count(DISTINCT n)"))
    end).

%% ---- O2 子句与表达式 ----------------------------------------------------------
clauses_test() ->
    with_graph(fun(R) ->
        ok = ?C:register_procedure(<<"oc.echo">>, #{args => [x], outputs => [out], fn => fun(_, [X]) -> [#{out => X}] end}),
        try
            ?assertEqual([[7]], rows(R, "CALL oc.echo(7) YIELD out"))
        after
            ?C:unregister(<<"oc.echo">>)
        end,
        ?assertEqual([[1]], rows(R, "RETURN 1 AS x UNION DISTINCT RETURN 1 AS x")),
        ?assertEqual([[1]], rows(R, "RETURN ALL 1 AS x")),
        ?assertEqual([[1]], rows(R, "WITH ALL 1 AS x RETURN x")),
        ?assertEqual([[true]], rows(R, "RETURN all(x IN [1] WHERE x > 0)")),
        ?assertEqual([[2], [3]], rows(R, "MATCH (n) RETURN n.num ORDER BY n.num OFFSET 1")),
        ?assertEqual([[2]], rows(R, "MATCH (n) WITH n ORDER BY n.num OFFSET 1 LIMIT 1 RETURN n.num")),
        ?assertEqual([[<<"x">>, <<"y">>]], rows(R, "RETURN CASE 2 WHEN 1, 2 THEN 'x' END, CASE 3 WHEN 1, 2 THEN 'x' ELSE 'y' END")),
        ?assertMatch(#{stage := parse}, err(R, "RETURN CASE WHEN true, false THEN 1 END")),
        ?assertEqual([[2]], rows(R, "MATCH (a:A), (c:C) RETURN length(shortestPath((a)-[:T*]->(c)))")),
        ?assertEqual([[1]], rows(R, "MATCH (a:A), (c:C) RETURN size(allShortestPaths((a)-[*]-(c)))")),
        ?assertEqual([[3]], rows(R, "MATCH (n) WHERE EXISTS { MATCH (n)-->() UNION MATCH (n)<--(:A) } RETURN count(n)"))
    end).

set_targets_test() ->
    with_graph(fun(R) ->
        rows(R, "MATCH (n:A) SET n['p'] = 3, (n).q = 4"),
        rows(R, "MATCH (n:A) WITH {node: n} AS m SET m.node.r = 5"),
        ?assertEqual([[3, 4, 5]], rows(R, "MATCH (n:A) RETURN n.p, n.q, n.r")),
        rows(R, "MATCH (n:A) WITH n, 'p' AS k REMOVE n[k], n.q"),
        ?assertEqual([[null, null, 5]], rows(R, "MATCH (n:A) RETURN n.p, n.q, n.r")),
        rows(R, "MATCH (:A)-[r:U]->() SET r['x'] = 9"),
        ?assertEqual([[9]], rows(R, "MATCH ()-[r:U]->() RETURN r.x")),
        ?assertMatch(#{type := <<"TypeError">>}, err(R, "MATCH (n:A) SET n[1] = 2")),
        ?assertMatch(#{stage := parse}, err(R, "MATCH (n:A) REMOVE n"))
    end).

%% ---- O3 元素模式里的 WHERE ------------------------------------------------------
element_where_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[<<"b">>], [<<"c">>]], rows(R, "MATCH (n WHERE n.num > 1) RETURN n.name ORDER BY n.name")),
        ?assertEqual([[<<"a">>]], rows(R, "MATCH (n:A WHERE n.num = 1) RETURN n.name")),
        ?assertEqual([[2], [3]], rows(R, "MATCH ()-[r WHERE r.w > 1]->() RETURN r.w ORDER BY r.w")),
        ?assertEqual([[<<"c">>]], rows(R, "MATCH (:A)-[r:T|U WHERE r.w = 3]->(m) RETURN m.name")),
        %% 与子句的 WHERE 做 AND；OPTIONAL MATCH 里同样
        ?assertEqual([[<<"c">>]], rows(R, "MATCH (n WHERE n.num > 1) WHERE n.name <> 'b' RETURN n.name")),
        ?assertEqual([[<<"a">>, null]], rows(R, "MATCH (a:A) OPTIONAL MATCH (a)-->(m WHERE m.num > 9) RETURN a.name, m")),
        %% EXISTS { 模式 } 与模式推导里
        ?assertEqual([[1]], rows(R, "MATCH (n) WHERE EXISTS { (n)-[r WHERE r.w = 3]->() } RETURN count(n)")),
        ?assertEqual([[[<<"c">>]]], rows(R, "MATCH (a:A) RETURN [(a)-->(m WHERE m.num = 3) | m.name]")),
        %% 变长关系上的 WHERE 不收；CREATE 里不收
        ?assertMatch(#{stage := parse}, err(R, "MATCH ()-[r* WHERE true]->() RETURN 1")),
        ?assertMatch(#{stage := semantic}, err(R, "CREATE (n WHERE true)"))
    end).

%% ---- O4 标签表达式 ------------------------------------------------------------
label_expressions_test() ->
    with_graph(fun(R) ->
        rows(R, "MATCH (n:A) SET n:X"),
        Names = fun(Q) -> [N || [N] <- rows(R, Q)] end,
        ?assertEqual([<<"a">>], Names("MATCH (n IS A) RETURN n.name")),
        ?assertEqual([<<"a">>, <<"b">>], Names("MATCH (n IS A|B) RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"a">>], Names("MATCH (n:A&X) RETURN n.name")),
        ?assertEqual([], Names("MATCH (n:A&B) RETURN n.name")),
        ?assertEqual([<<"b">>, <<"c">>], Names("MATCH (n:!A) RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], Names("MATCH (n:%) RETURN n.name ORDER BY n.name")),
        ?assertEqual([<<"b">>], Names("MATCH (n:(A|B)&!X) RETURN n.name")),
        ?assertEqual([<<"b">>], Names("MATCH (n IS !A&!C) RETURN n.name")),
        ?assertEqual([<<"a">>], Names("MATCH (n:A:X) RETURN n.name")),
        %% WHERE 里
        ?assertEqual([<<"a">>], Names("MATCH (n) WHERE n IS A RETURN n.name")),
        ?assertEqual([<<"a">>], Names("MATCH (n) WHERE n:A&X RETURN n.name")),
        ?assertEqual([<<"b">>, <<"c">>], Names("MATCH (n) WHERE n:!A RETURN n.name ORDER BY n.name")),
        ?assertEqual([[true], [false], [false]], rows(R, "MATCH (n) RETURN n IS A ORDER BY n.name")),
        %% 关系
        ?assertEqual([1, 2], [W || [W] <- rows(R, "MATCH ()-[r IS T]->() RETURN r.w ORDER BY r.w")]),
        ?assertEqual([3], [W || [W] <- rows(R, "MATCH ()-[r:!T]->() RETURN r.w")]),
        ?assertEqual([1, 2, 3], [W || [W] <- rows(R, "MATCH ()-[r:%]->() RETURN r.w ORDER BY r.w")]),
        ?assertEqual([], [W || [W] <- rows(R, "MATCH ()-[r:T&U]->() RETURN r.w")]),
        ?assertEqual([1, 2, 3], [W || [W] <- rows(R, "MATCH ()-[r:T|:U]->() RETURN r.w ORDER BY r.w")]),
        ?assertEqual([[true]], rows(R, "MATCH ()-[r:U]->() RETURN r:U&!T")),
        %% 写标签只能是普通名字
        ?assertMatch(#{stage := semantic}, err(R, "CREATE (n:A|B)"))
    end).

%% ---- O5 路径搜索前缀 ----------------------------------------------------------
%% 图：a -T-> b -T-> c，a -U-> c；a 到 c 两条路：长 1（经 U）、长 2（经 b）
path_search_test() ->
    with_graph(fun(R) ->
        Lens = fun(Q) -> [L || [L] <- rows(R, Q)] end,
        ?assertEqual([1, 2], Lens("MATCH p = ALL (:A)-[*]->(:C) RETURN length(p) ORDER BY length(p)")),
        ?assertEqual([1], Lens("MATCH p = ANY SHORTEST (:A)-[*]->(:C) RETURN length(p)")),
        ?assertEqual([1], Lens("MATCH p = ALL SHORTEST PATHS (:A)-[*]->(:C) RETURN length(p)")),
        ?assertEqual([1, 2], Lens("MATCH p = SHORTEST 2 PATHS (:A)-[*]->(:C) RETURN length(p) ORDER BY length(p)")),
        ?assertEqual([1], Lens("MATCH p = SHORTEST 1 (:A)-[*]->(:C) RETURN length(p)")),
        ?assertEqual([1], Lens("MATCH p = SHORTEST GROUP (:A)-[*]->(:C) RETURN length(p)")),
        ?assertEqual([1, 2], Lens("MATCH p = SHORTEST 2 GROUPS (:A)-[*]->(:C) RETURN length(p) ORDER BY length(p)")),
        ?assertEqual(1, length(Lens("MATCH p = ANY (:A)-[*]->(:C) RETURN length(p)"))),
        ?assertEqual(2, length(Lens("MATCH p = ANY 2 PATHS (:A)-[*]->(:C) RETURN length(p)"))),
        ?assertEqual([[1]], rows(R, "MATCH p = SHORTEST $k (:A)-[*]->(:C) RETURN length(p)", #{k => 1})),
        %% 多跳的一般模式：按 (起点, 终点) 分组
        ?assertEqual([[<<"b">>, 1], [<<"c">>, 1]],
                     rows(R, "MATCH ALL SHORTEST (a:A)-->(m) RETURN m.name, count(*) ORDER BY m.name")),
        %% WHERE 先过滤再挑
        ?assertEqual([2], Lens("MATCH p = SHORTEST 1 (:A)-[*]->(:C) WHERE length(p) > 1 RETURN length(p)")),
        %% 每个输入行各挑各的
        ?assertEqual(2, length(rows(R, "UNWIND [1, 1] AS x MATCH ANY SHORTEST (:A)-[*]->(c:C) RETURN x"))),
        %% 路径变量可以不写
        ?assertEqual([[<<"c">>]], rows(R, "MATCH ANY SHORTEST (:A)-[*]->(c:C) RETURN c.name")),
        ?assertMatch(#{stage := semantic}, err(R, "CREATE ANY (:X)-[:R]->(:Y)")),
        ?assertMatch({error, #{type := <<"ArgumentError">>}}, ?C:q(R, "MATCH SHORTEST $k (:A)-[*]->(:C) RETURN 1", #{k => -1}))
    end).

%% ---- O6 量化路径 --------------------------------------------------------------
%% 图：a -T(w1)-> b -T(w2)-> c，a -U(w3)-> c
quantified_paths_test() ->
    with_graph(fun(R) ->
        Names = fun(Q) -> [N || [N] <- rows(R, Q)] end,
        ?assertEqual([[<<"b">>, 1], [<<"c">>, 2]],
                     rows(R, "MATCH (:A) ((x)-[:T]->(y)){1,2} (c) RETURN c.name, size(x) ORDER BY c.name")),
        %% 组变量是每次重复一个值的列表
        ?assertEqual([[[<<"a">>, <<"b">>], [<<"b">>, <<"c">>], [1, 2]]],
                     rows(R, "MATCH (:A) ((x)-[r:T]->(y)){2} (c) RETURN [n IN x | n.name], [n IN y | n.name], [e IN r | e.w]")),
        ?assertEqual([<<"b">>, <<"c">>], Names("MATCH (:A) ((x)-[:T]->(y))+ (c) RETURN c.name ORDER BY c.name")),
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], Names("MATCH (:A) ((x)-[:T]->(y))* (c) RETURN c.name ORDER BY c.name")),
        %% 组里的 WHERE 与标签每次重复各算一次
        ?assertEqual([], Names("MATCH (:A) ((x)-[r:T]->(y) WHERE r.w > 1){1,2} (c) RETURN c.name")),
        ?assertEqual([<<"c">>], Names("MATCH (:B) ((x)-[r:T]->(y) WHERE r.w > 1)+ (c) RETURN c.name")),
        ?assertEqual([<<"b">>], Names("MATCH (:A) ((x)-[:T]->(y:B)){1,2} (c) RETURN c.name")),
        ?assertEqual([], Names("MATCH (:A) ((x)-[r:T]->(y WHERE y.num > 2)){1,2} (c) RETURN c.name")),   %% 第一次重复的 y = b 就不满足
        ?assertEqual([<<"c">>], Names("MATCH (:B) ((x)-[r:T]->(y WHERE y.num > 2)){1,2} (c) RETURN c.name")),
        %% 量化关系
        ?assertEqual([<<"b">>, <<"c">>], Names("MATCH (:A)-[:T]->{1,2}(c) RETURN c.name ORDER BY c.name")),
        ?assertEqual([<<"b">>, <<"c">>, <<"c">>], Names("MATCH (:A)-->+(c) RETURN c.name ORDER BY c.name")),
        ?assertEqual([<<"b">>], Names("MATCH (:A)-[r:T WHERE r.w = 1]->+(c) RETURN c.name")),
        %% 路径变量穿过量化组
        ?assertEqual([[2, [<<"a">>, <<"b">>, <<"c">>]]],
                     rows(R, "MATCH p = (:A) ((x)-[:T]->(y)){2} (c) RETURN length(p), [n IN nodes(p) | n.name]")),
        %% 右端已绑定：从右往左展开，列表顺序仍按模式
        ?assertEqual([[<<"a">>, [<<"a">>, <<"b">>]]],
                     rows(R, "MATCH (c:C) WITH c MATCH (a) ((x)-[:T]->(y)){2} (c) RETURN a.name, [n IN x | n.name]")),
        %% 组变量在组外按列表用
        ?assertEqual([<<"c">>], Names("MATCH (:A) ((x)-[:T]->(y)){1,2} (c) WHERE size(x) = 2 RETURN c.name")),
        %% 不带量词的括号路径、子路径变量
        ?assertEqual([2, 3], Names("MATCH ((a)-[r]->(b) WHERE r.w > 1) RETURN r.w ORDER BY r.w")),
        ?assertEqual([1], Names("MATCH (p = (:A)-[:U]->()) RETURN length(p)")),
        ?assertEqual([<<"c">>], Names("MATCH (:A) ((x)-[:T]->(y)) ((u)-[:T]->(v)) (c) RETURN c.name")),
        %% 相邻的两个节点模式是同一个节点（两个名字都能用）
        ?assertEqual([[true, <<"a">>]], rows(R, "MATCH (a:A) (b) RETURN a = b, b.name")),
        %% 报错
        ?assertMatch(#{stage := semantic}, err(R, "MATCH (a) (((x)-->(y)){1,2}){2} (c) RETURN c")),
        ?assertMatch(#{stage := semantic}, err(R, "MATCH (a) ((x)-[*]->(y)){2} (c) RETURN c")),
        ?assertMatch(#{detail := <<"VariableAlreadyBound">>}, err(R, "MATCH (a:A) ((a)-->(y)){2} (c) RETURN c")),
        ?assertMatch(#{stage := semantic}, err(R, "MATCH (a) ((x)){2} (c) RETURN c")),
        ?assertMatch(#{stage := parse}, err(R, "MATCH (a)-[:T*1..2]->{2}(c) RETURN c"))
    end).
