#!/usr/bin/env escript
%% cypher_demo — 图查询语言 bitcask_cypher 的完整示例（doc/cypher-zh.md / doc/cypher-en.md）。
%%
%% 用法（仓库根目录，先 rebar3 compile）：
%%   escript examples/cypher_demo.escript [Dir]
%% 缺省在 /tmp 下建一个临时库，跑完删掉。演示：建图（语句与图层 API 混用）、模式匹配、聚合、
%% 变长与最短路、写语句与统计、事务、全文检索 @@、向量检索 <=>、explain、OPTIONAL MATCH / CASE、MERGE。

-mode(compile).

main(Args) ->
    code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(bitcask),
    {Dir, Temp} = case Args of
                      [D] -> {D, false};
                      [] -> {"/tmp/cypher_demo_" ++ integer_to_list(erlang:unique_integer([positive])), true}
                  end,
    %% 全文要索引模式（analyzer），向量要 vector_dim
    G = graphdb:open(Dir, [read_write, {analyzer, whitespace}, {vector_dim, 3}]),
    try demo(G)
    after
        graphdb:close(G),
        Temp andalso os:cmd("rm -rf " ++ Dir)
    end.

demo(G) ->
    step("建图：一条 CREATE 写一条链（新关系类型自动注册）"),
    show(q(G, "CREATE (ann:Person {name: 'ann', age: 31, text: 'graph databases and query languages', embedding: [1.0, 0.1, 0.0]})"
              "-[:KNOWS {since: 2019}]->(bob:Person {name: 'bob', age: 25, text: 'vector search in practice', embedding: [0.2, 1.0, 0.0]})"
              "-[:KNOWS {since: 2021}]->(cat:Person:Admin {name: 'cat', age: 40, text: 'graph theory notes', embedding: [0.9, 0.0, 0.3]})")),

    step("用图层 API 加顶点和边：同一个 id 空间、同一份标签索引"),
    {ok, Acme} = graphdb:create_vertex(G, #{labels => [<<"Company">>], props => #{name => <<"acme">>}}),
    {ok, Works} = graphdb:register_etype(G, <<"WORKS_AT">>),
    [[Ann]] = rows(q(G, "MATCH (p:Person {name: 'ann'}) RETURN id(p)")),
    ok = graphdb:put_edge(G, Ann, Works, Acme, #{props => #{role => <<"engineer">>}}),
    show(q(G, "MATCH (p:Person)-[w:WORKS_AT]->(c:Company) RETURN p.name, w.role, c.name")),

    step("模式匹配 + 条件 + 排序"),
    show(q(G, "MATCH (a:Person)-[k:KNOWS]->(b) WHERE k.since >= $y RETURN a.name, b.name, k.since ORDER BY k.since",
           #{y => 2019})),

    step("聚合（隐式分组）"),
    show(q(G, "MATCH (p:Person) RETURN p:Admin AS admin, count(*) AS n, avg(p.age) AS avg_age ORDER BY admin")),

    step("变长路径与最短路"),
    show(q(G, "MATCH (a:Person {name: 'ann'})-[:KNOWS*1..3]->(x) RETURN x.name")),
    show(q(G, "MATCH p = shortestPath((a {name: 'ann'})-[:KNOWS*]->(c {name: 'cat'})) RETURN length(p) AS hops")),

    step("写：SET / REMOVE 与统计"),
    show(q(G, "MATCH (p:Person {name: 'bob'}) SET p.age = p.age + 1, p:Reviewer, p += {city: 'Berlin'} RETURN p")),
    show(q(G, "MATCH (p:Person {name: 'bob'}) REMOVE p.city, p:Reviewer RETURN p.city, labels(p)")),

    step("事务：多条语句一起提交，后面的语句读得到前面的写"),
    {atomic, {ok, R}} = graphdb:transaction(G, fun(Tx) ->
                      {ok, _} = bitcask_cypher:q(Tx, "CREATE (:Tag {name: 'demo'})"),
                      {ok, _} = bitcask_cypher:q(Tx, "MATCH (t:Tag), (p:Person {name: 'ann'}) CREATE (p)-[:TAGGED]->(t)"),
                      bitcask_cypher:q(Tx, "MATCH (p)-[:TAGGED]->(t:Tag) RETURN p.name, t.name")
                  end),
    show(R),

    step("全文检索 @@ 与 score()"),
    show(q(G, "MATCH (p:Person) WHERE p.text @@ 'graph -theory' RETURN p.name, score(p)")),
    show(q(G, "MATCH (p:Person) WHERE p.text @@ 'graph OR vector' RETURN p.name ORDER BY score(p) DESC")),

    step("向量检索 <=>：全库 top-k，与图模式组合"),
    show(q(G, "MATCH (p:Person) RETURN p.name, p.embedding <=> $q AS d ORDER BY d LIMIT 2", #{q => [1.0, 0.0, 0.0]})),
    show(q(G, "MATCH (:Person {name: 'ann'})-[:KNOWS*1..2]->(x) RETURN x.name ORDER BY x.embedding <=> $q LIMIT 1",
           #{q => [0.0, 1.0, 0.0]})),

    step("explain：看规划器选的起点与算子"),
    {ok, #{ops := Ops}} = bitcask_cypher:explain(G, "MATCH (p:Person)-[:KNOWS]->(b) WHERE p.age > 30 RETURN b.name"),
    [io:format("    ~p~n", [Op]) || Op <- Ops],

    step("OPTIONAL MATCH：没有出边的人也出现，邻居为 null；CASE 分档"),
    show(q(G, "MATCH (p:Person) OPTIONAL MATCH (p)-[:KNOWS]->(f) "
              "RETURN p.name, f.name, CASE WHEN p.age >= 30 THEN 'senior' ELSE 'junior' END AS band ORDER BY p.name")),

    step("MERGE：有就匹配、没有就建；ON CREATE / ON MATCH"),
    show(q(G, "MERGE (c:City {name: 'Berlin'}) ON CREATE SET c.visits = 1 ON MATCH SET c.visits = c.visits + 1 RETURN c.visits")),
    show(q(G, "MERGE (c:City {name: 'Berlin'}) ON CREATE SET c.visits = 1 ON MATCH SET c.visits = c.visits + 1 RETURN c.visits")),
    show(q(G, "MATCH (p:Person {name: 'bob'}), (c:City {name: 'Berlin'}) MERGE (p)-[r:LIVES_IN]->(c) RETURN type(r)")),

    step("删除（DETACH DELETE 连边一起删）"),
    show(q(G, "MATCH (t:Tag) DETACH DELETE t")),
    {ok, _} = graphdb:check_invariants(G),
    io:format("~ndone.~n").

q(G, Query) -> q(G, Query, #{}).
q(G, Query, Params) ->
    case bitcask_cypher:q(G, Query, Params) of
        {ok, R} -> R;
        {error, E} -> erlang:error({query_failed, Query, E})
    end.

rows(#{rows := Rows}) -> Rows.

step(Title) -> io:format("~n== ~ts~n", [Title]).

show(#{columns := Cols, rows := Rows, stats := Stats}) ->
    io:format("  ~p~n", [Cols]),
    [io:format("  ~p~n", [Row]) || Row <- Rows],
    map_size(Stats) > 0 andalso io:format("  stats ~p~n", [Stats]),
    ok.
