%% Cypher 三期（doc/cypher-phase3-design-zh.md，TASK.md Q7）：EXISTS 子查询、用户过程 / 函数、时间与空间类型
%% （FOREACH、CALL {} 子查询、COUNT / COLLECT 子查询、LOAD CSV 这些 Neo4j 扩展已删，见 TASK.md O7）。
-module(bitcask_cypher_phase3_tests).
-include_lib("eunit/include/eunit.hrl").

-define(C, bitcask_cypher).
-define(G, graphdb).

with_graph(F) ->
    bitcask_test_util:with_dir("cypher_p3_", fun(D) ->
        R = ?G:open(D, [read_write]),
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
err(R, Q) -> {error, E} = ?C:q(R, Q), E.

ok_inv(R) -> ?assertMatch({ok, _}, ?G:check_invariants(R)).

chain(R) ->
    q(R, "CREATE (a:P {n: 1})-[:T]->(b:P {n: 2})-[:T]->(c:P {n: 3}), (a)-[:T]->(c)").

%% =========================================================================
%% Q7-3 EXISTS 子查询（COUNT / COLLECT 子查询是 Neo4j 扩展，已删）
%% =========================================================================

subquery_expressions_test() ->
    with_graph(fun(R) ->
        chain(R),
        ?assertEqual([[1, false], [2, true], [3, true]],
                     rows(R, "MATCH (n:P) RETURN n.n, EXISTS { (n)<--() } ORDER BY n.n")),
        ?assertEqual([1, 2], col(R, "MATCH (n:P) WHERE EXISTS { MATCH (n)-->(m) WHERE m.n = 3 } RETURN n.n ORDER BY n.n")),
        %% 子查询之后的模式谓词：记号预处理的模式区要恢复
        ?assertEqual([1, 2], col(R, "MATCH (n:P) WHERE EXISTS { MATCH (n)-->(m) WHERE m.n = 3 } AND (n)-->() "
                                    "RETURN n.n ORDER BY n.n")),
        ?assertEqual([1, 2, 3], col(R, "MATCH (n:P) WHERE EXISTS { MATCH (n)-->(m) RETURN m UNION MATCH (n)<--(m) RETURN m } "
                                       "RETURN n.n ORDER BY n.n")),
        ?assertEqual([[3, 3]], rows(R, "MATCH (n:P) RETURN count(*), count(n)")),
        ?assertMatch(#{stage := semantic}, err(R, "MATCH (n:P) RETURN EXISTS { MATCH (n) CREATE (:X) }")),
        %% 已删的 Neo4j 扩展语法：语法错
        [?assertMatch(#{stage := parse}, err(R, Q)) || Q <- [
            "MATCH (n:P) RETURN COUNT { (n)-->() }",
            "MATCH (n:P) RETURN COLLECT { MATCH (n)-->(m) RETURN m.n }",
            "MATCH (n:P) FOREACH (x IN [1] | SET n.f = x)",
            "MATCH (n:P) CALL { WITH n RETURN n.n AS k } RETURN k",
            "MATCH (n:P) CALL (n) { RETURN n.n AS k } RETURN k",
            "UNWIND [1] AS x CALL (x) { CREATE (:W) } IN TRANSACTIONS",
            "LOAD CSV FROM 'a.csv' AS r RETURN r"]]
    end).

%% =========================================================================
%% Q7-4 用户过程 / 函数
%% =========================================================================

user_procedures_test_() ->
    {setup,
     fun() ->
             ok = ?C:register_procedure(<<"t3.range">>, #{
                     args => [<<"n">>, {<<"step">>, 1}], outputs => [<<"i">>, <<"sq">>],
                     fn => fun(_Ctx, [N, S]) -> [#{i => I, <<"sq">> => I * I} || I <- lists:seq(1, N, S)] end}),
             ok = ?C:register_function(<<"t3.str.rev">>, #{
                     arity => 1, fn => fun(_, [null]) -> <<"NULL">>; (_, [S]) -> list_to_binary(lists:reverse(binary_to_list(S))) end}),
             ok = ?C:register_function(<<"t3.boom">>, #{arity => 0, fn => fun(_, _) -> error(kaput) end})
     end,
     fun(_) -> [?C:unregister(N) || N <- [<<"t3.range">>, <<"t3.str.rev">>, <<"t3.boom">>, <<"t3.link">>]] end,
     fun() ->
        with_graph(fun(R) ->
            ?assertEqual([[1, 1], [2, 4], [3, 9]], rows(R, "CALL t3.range(3)")),
            ?assertEqual([[[1, 3, 5]]], rows(R, "CALL t3.range(5, 2) YIELD i RETURN collect(i)")),
            ?assertEqual([[2, 5], [3, 14]], rows(R, "UNWIND [2, 3] AS n CALL t3.range(n) YIELD i, sq RETURN n, sum(sq)")),
            ?assertMatch(#{stage := semantic}, err(R, "CALL t3.range()")),
            ?assertMatch(#{stage := semantic}, err(R, "CALL t3.range(1, 2, 3)")),
            ?assertMatch(#{stage := semantic}, err(R, "CALL t3.range(2) YIELD nope RETURN nope")),
            ?assertEqual([[<<"cba">>, <<"NULL">>, <<"yx">>]],
                         rows(R, "RETURN t3.str.rev('abc'), t3.str.rev(null), T3.STR.REV('xy')")),
            ?assertMatch(#{stage := exec}, err(R, "RETURN t3.boom()")),
            ?assertMatch(#{stage := semantic}, err(R, "RETURN nope.x(1)")),
            %% 名字校验
            ?assertMatch({error, {reserved_namespace, _}}, ?C:register_function(<<"date.x">>, #{arity => 0, fn => fun(_, _) -> 1 end})),
            ?assertMatch({error, _}, ?C:register_function(<<"nonamespace">>, #{arity => 0, fn => fun(_, _) -> 1 end})),
            ?assert(lists:member(<<"t3.range">>, maps:get(procedures, ?C:registered()))),
            %% 写过程：语句算写语句、在事务里；语句出错整条回滚
            {ok, Et} = ?G:register_etype(R, <<"LINK">>),
            ok = ?C:register_procedure(<<"t3.link">>, #{
                    args => [<<"a">>, <<"b">>], outputs => [<<"ok">>], mode => write,
                    fn => fun(#{txn := Tx}, [{node, A}, {node, B}]) ->
                                  ok = ?G:put_edge_txn(Tx, A, Et, B, #{props => #{via => <<"proc">>}}),
                                  [#{ok => true}]
                          end}),
            q(R, "CREATE (:A {name: 'x'}), (:A {name: 'y'})"),
            ?assert(?C:writes(<<"MATCH (a:A), (b:A) CALL t3.link(a, b) YIELD ok RETURN ok">>)),
            ?assertEqual([[true]], rows(R, "MATCH (a:A {name: 'x'}), (b:A {name: 'y'}) CALL t3.link(a, b) YIELD ok RETURN ok")),
            ?assertEqual([[<<"x">>, <<"proc">>, <<"y">>]], rows(R, "MATCH (a)-[r:LINK]->(b) RETURN a.name, r.via, b.name")),
            ?assertMatch(#{stage := exec},
                         err(R, "MATCH (a:A {name: 'x'}), (b:A {name: 'y'}) CALL t3.link(a, b) YIELD ok RETURN 1 / 0")),
            ?assertEqual([1], col(R, "MATCH ()-[r:LINK]->() RETURN count(r)")),
            ok_inv(R)
        end)
     end}.

%% =========================================================================
%% Q7-6 时间与空间类型
%% =========================================================================

tq(R, Q) -> [[fmt(V) || V <- Row] || Row <- rows(R, Q)].

fmt(V) when is_tuple(V) -> bitcask_cypher_temporal:format(V);
fmt(L) when is_list(L) -> [fmt(X) || X <- L];
fmt(V) -> V.

temporal_values_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[<<"2024-05-01">>, <<"2024-05-01">>, <<"2024-01-01">>, <<"2024-02-29">>, <<"2024-05-01">>,
                       <<"2024-02-29">>, <<"2024-04-01">>]],
                     tq(R, "RETURN date('2024-05-01'), date('20240501'), date('2024-W01-1'), date('2024-060'), "
                          "date('2024-05'), date({year: 2024, month: 2, day: 29}), date({year: 2024, quarter: 2})")),
        ?assertEqual([[<<"12:34:56.789">>, <<"12:34:56+01:00">>, <<"2024-05-01T08:30">>, <<"2024-05-01T08:30:00.5Z">>,
                       <<"2024-05-01T08:30-05:00">>]],
                     tq(R, "RETURN localtime('12:34:56.789'), time('12:34:56+01:00'), localdatetime('2024-05-01T08:30'), "
                          "datetime('2024-05-01T08:30:00.5Z'), datetime('2024-05-01T08:30-05:00')")),
        ?assertEqual([[<<"P1Y2M3DT4H5M6.5S">>, <<"P3DT25H">>, <<"PT1.5S">>, <<"P-1D">>, <<"PT0S">>]],
                     tq(R, "RETURN duration('P1Y2M3DT4H5M6.5S'), duration({days: 3, hours: 25}), duration('PT0.5S') * 3, "
                          "duration('-P1D'), duration('P1D') - duration('PT24H') + duration('PT24H') - duration('P1D')")),
        %% 月末截断、访问
        ?assertEqual([[<<"2024-02-29">>, <<"2024-03-01">>, <<"2023-01-31">>, 2024, 1, 31, 3, 5, 31, 1]],
                     tq(R, "WITH date('2024-01-31') AS d RETURN d + duration('P1M'), d + duration('P1M1D'), d - duration('P1Y'), "
                          "d.year, d.month, d.day, d.dayOfWeek, d.week, d.ordinalDay, d.quarter")),
        ?assertEqual([[<<"2024-03-11T00:30+02:00">>, 23, <<"+02:00">>, 120, 1710106200]],
                     tq(R, "WITH datetime('2024-03-10T23:30:00+02:00') AS t RETURN t + duration('PT1H'), t.hour, t.offset, "
                          "t.offsetMinutes, t.epochSeconds")),
        ?assertEqual([[1, 1, 30, 15]], rows(R, "WITH duration('P1Y1M2DT30M15S') AS d RETURN d.years, d.monthsOfYear, "
                                               "d.minutesOfHour, d.secondsOfMinute")),
        %% 比较
        ?assertEqual([[true, true, false, false, null, null]],
                     rows(R, "RETURN date('2024-01-01') < date('2024-01-02'), "
                             "datetime('2024-01-01T00:00Z') = datetime('2024-01-01T01:00+01:00'), "
                             "date('2024-01-01') = '2024-01-01', duration('P1D') = duration('PT24H'), "
                             "duration('P1D') < duration('P2D'), date('2024-01-01') < localtime('10:00')")),
        ?assertEqual([[<<"P1M24D">>, <<"P60D">>, <<"P1M">>, <<"PT1H30M15S">>]],
                     tq(R, "RETURN duration.between(date('2024-01-15'), date('2024-03-10')), "
                          "duration.inDays(date('2024-01-01'), date('2024-03-01')), "
                          "duration.inMonths(date('2024-01-31'), date('2024-02-29')), "
                          "duration.inSeconds(localtime('10:00'), localtime('11:30:15'))")),
        ?assertEqual([[<<"2024-05-01">>, <<"2024-05-17T10:00Z">>, <<"2024-05-13">>]],
                     tq(R, "RETURN date.truncate('month', date('2024-05-17')), datetime.truncate('hour', datetime('2024-05-17T10:45:12Z')), "
                          "date.truncate('week', date('2024-05-17'))")),
        ?assertEqual([[<<"1970-01-01T00:00Z">>, <<"2023-11-14T22:13:20Z">>, <<"2024-05-01">>, <<"09:05">>]],
                     tq(R, "RETURN datetime({epochSeconds: 0}), datetime.fromepochmillis(1700000000000), "
                          "date(datetime('2024-05-01T23:00Z')), localtime({hour: 9, minute: 5})")),
        %% 语句时钟：同一条语句里不变
        ?assertEqual([[true]], rows(R, "UNWIND range(1, 100) AS i WITH collect(datetime()) AS ts RETURN size(ts) = 100 AND all(t IN ts WHERE t = ts[0])")),
        %% 排序全序
        ?assertEqual([[<<"point({srid: 7203, x: 0.0, y: 0.0})">>], [<<"2024-01-01T00:00Z">>], [<<"2024-01-01">>],
                      [<<"2024-01-02">>], [<<"10:00">>], [<<"P1D">>], [<<"a">>], [1]],
                     tq(R, "UNWIND [date('2024-01-02'), 'a', 1, datetime('2024-01-01T00:00Z'), duration('P1D'), "
                          "point({x: 0, y: 0}), localtime('10:00'), date('2024-01-01')] AS v RETURN v ORDER BY v")),
        %% 参数可以直接传元组
        ?assertEqual([[2025]], rows(R, "RETURN ($d + duration('P1Y')).year", #{d => {date, {2024, 6, 1}}})),
        %% 反例
        [?assertMatch(#{stage := exec}, err(R, Q))
         || Q <- ["RETURN date('2024-02-30')", "RETURN datetime('2024-01-01T00:00[Nowhere/Land]')", "RETURN datetime({year: 2024, timezone: '../etc'})",
                  "RETURN date('2024-01-01') + 1", "RETURN duration('P1X')", "RETURN date({month: 1})"]]
    end).

%% 命名时区（系统 zoneinfo）。机器上没有 zoneinfo 时跳过。
named_time_zones_test_() ->
    case bitcask_cypher_tz:exists(<<"Europe/Stockholm">>) of
        false -> [];
        true -> [fun named_time_zones/0]
    end.

named_time_zones() ->
    with_graph(fun(R) ->
        %% 被 IANA 合并掉的时区缺省按合并目标的数据（1818 年的 Stockholm 用柏林的地方时，同 Java / openCypher TCK）；
        %% tz_backzone = true 时照用本机文件（带 backzone 编的 zoneinfo 给出 Stockholm 自己的地方时）
        Q1818 = "RETURN toString(datetime('1818-07-21T21:40:32.142[Europe/Stockholm]'))",
        ?assertEqual([[<<"1818-07-21T21:40:32.142+00:53:28[Europe/Stockholm]">>]], rows(R, Q1818)),
        ok = application:set_env(bitcask_cypher, tz_backzone, true),
        try
            [[Own]] = rows(R, Q1818),
            ?assertMatch(<<"1818-07-21T21:40:32.142+", _/binary>>, Own)
        after
            application:unset_env(bitcask_cypher, tz_backzone)
        end,
        %% 偏移按日期解析（1984 年夏令时 9 月底结束）；输出带时区名
        ?assertEqual([[<<"1984-10-11T12:00+01:00[Europe/Stockholm]">>, <<"1984-07-20T12:00+02:00[Europe/Stockholm]">>,
                       <<"Europe/Stockholm">>, <<"+01:00">>]],
                     tq(R, "WITH datetime({year: 1984, month: 10, day: 11, hour: 12, timezone: 'Europe/Stockholm'}) AS d "
                           "RETURN d, datetime({year: 1984, month: 7, day: 20, hour: 12, timezone: 'Europe/Stockholm'}), "
                           "d.timezone, d.offset")),
        %% 换时区：同一时刻
        ?assertEqual([[<<"1984-10-11T01:00-10:00[Pacific/Honolulu]">>, <<"1984-10-11T16:00+05:00">>]],
                     tq(R, "WITH datetime({year: 1984, month: 10, day: 11, hour: 12, timezone: 'Europe/Stockholm'}) AS d "
                           "RETURN datetime({datetime: d, timezone: 'Pacific/Honolulu'}), datetime({datetime: d, timezone: '+05:00'})")),
        %% 字符串里的时区名；重叠段（秋季回拨）按给出的偏移；空隙（春季拨快）往后挪
        ?assertEqual([[<<"2017-10-29T02:30+01:00[Europe/Stockholm]">>, <<"2017-10-29T02:30+02:00[Europe/Stockholm]">>,
                       <<"2017-03-26T03:30+02:00[Europe/Stockholm]">>]],
                     tq(R, "RETURN datetime('2017-10-29T02:30+01:00[Europe/Stockholm]'), datetime('2017-10-29T02:30[Europe/Stockholm]'), "
                           "datetime('2017-03-26T02:30[Europe/Stockholm]')")),
        %% 跨夏令时切换：时长按时刻算；加一天按本地日历（偏移重新解析）
        ?assertEqual([[<<"PT5H">>, <<"PT25H">>, <<"2017-10-29T12:00+01:00[Europe/Stockholm]">>]],
                     tq(R, "WITH datetime({year: 2017, month: 10, day: 29, hour: 0, timezone: 'Europe/Stockholm'}) AS d "
                           "RETURN duration.inSeconds(d, localdatetime({year: 2017, month: 10, day: 29, hour: 4})), "
                           "duration.inSeconds(d, date({year: 2017, month: 10, day: 30})), "
                           "datetime({year: 2017, month: 10, day: 28, hour: 12, timezone: 'Europe/Stockholm'}) + duration('P1D')")),
        %% 未来年份（zoneinfo 文件尾的规则）、南半球
        ?assertEqual([[<<"+02:00">>, <<"+01:00">>, <<"+11:00">>, <<"+10:00">>]],
                     tq(R, "RETURN datetime({year: 2050, month: 7, day: 1, timezone: 'Europe/Stockholm'}).offset, "
                           "datetime({year: 2050, month: 12, day: 1, timezone: 'Europe/Stockholm'}).offset, "
                           "datetime({year: 2050, month: 1, day: 1, timezone: 'Australia/Sydney'}).offset, "
                           "datetime({year: 2050, month: 7, day: 1, timezone: 'Australia/Sydney'}).offset")),
        %% 存取：类型与时区名不丢
        q(R, "CREATE (:Z {at: datetime('2017-10-29T02:30+01:00[Europe/Stockholm]')})"),
        ?assertEqual([[<<"2017-10-29T02:30+01:00[Europe/Stockholm]">>, <<"Europe/Stockholm">>]],
                     tq(R, "MATCH (z:Z) RETURN z.at, z.at.timezone")),
        %% 时区目录可配置
        Old = application:get_env(bitcask_cypher, tz_dir),
        application:set_env(bitcask_cypher, tz_dir, "/nonexistent"),
        try
            ?assertMatch(#{stage := exec}, err(R, "RETURN datetime({year: 2024, timezone: 'Asia/Tokyo'})"))
        after
            case Old of {ok, V} -> application:set_env(bitcask_cypher, tz_dir, V); undefined -> application:unset_env(bitcask_cypher, tz_dir) end
        end
    end).

spatial_values_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[<<"point({srid: 7203, x: 1.0, y: 2.0})">>, <<"point({srid: 9157, x: 0.0, y: 0.0, z: 3.0})">>,
                       52.5, <<"wgs-84">>, 5.0]],
                     tq(R, "RETURN point({x: 1, y: 2}), point({x: 0, y: 0, z: 3}), point({longitude: 13.4, latitude: 52.5}).latitude, "
                          "point({longitude: 13.4, latitude: 52.5}).crs, point.distance(point({x: 0, y: 0}), point({x: 3, y: 4}))")),
        [[D, Null]] = rows(R, "RETURN point.distance(point({longitude: 13.405, latitude: 52.52}), "
                              "point({longitude: 2.3522, latitude: 48.8566})), "
                              "distance(point({x: 0, y: 0}), point({longitude: 1, latitude: 1}))"),
        ?assert(abs(D - 878000) < 2000),
        ?assertEqual(null, Null),
        ?assertEqual([[true, false, true, true]],
                     rows(R, "RETURN point.withinBBox(point({x: 1, y: 1}), point({x: 0, y: 0}), point({x: 2, y: 2})), "
                             "point.withinBBox(point({x: 3, y: 1}), point({x: 0, y: 0}), point({x: 2, y: 2})), "
                             "point.withinBBox(point({longitude: 179.5, latitude: 0}), point({longitude: 179, latitude: -1}), "
                             "point({longitude: -179, latitude: 1})), point({x: 1, y: 2}) = point({x: 1.0, y: 2.0})"))
    end).

%% 存储：存进去读回来类型不变（`_types` 不进属性），边属性同样，与图层 API 互通。
typed_storage_test() ->
    with_graph(fun(R) ->
        q(R, "CREATE (:E {d: date('2024-05-01'), t: datetime('2024-05-01T10:00+02:00'), lt: localtime('07:15'), "
             "du: duration('P2DT3H'), p: point({x: 1, y: 2, z: 3}), n: 1})"),
        ?assertEqual([[<<"2024-05-01">>, <<"2024-05-01T10:00+02:00">>, <<"07:15">>, <<"P2DT3H">>,
                       <<"point({srid: 9157, x: 1.0, y: 2.0, z: 3.0})">>, 2024,
                       [<<"d">>, <<"du">>, <<"lt">>, <<"n">>, <<"p">>, <<"t">>]]],
                     tq(R, "MATCH (e:E) RETURN e.d, e.t, e.lt, e.du, e.p, e.d.year, keys(e)")),
        ?assertEqual([1], col(R, "MATCH (e:E) WHERE e.d = date('2024-05-01') AND e.t > datetime('2024-05-01T07:00Z') RETURN count(e)")),
        ?assertEqual([[<<"2024-05-02">>]], tq(R, "MATCH (e:E) SET e.d = e.d + duration('P1D') RETURN e.d")),
        ?assertEqual([<<"d">>, <<"du">>, <<"lt">>, <<"n">>, <<"p">>, <<"t">>], col(R, "CALL db.propertyKeys()")),
        q(R, "CREATE (:E2)-[:R {since: date('2020-01-01')}]->(:E2)"),
        ?assertEqual([[<<"2020-01-01">>, 2020]], tq(R, "MATCH ()-[r:R]->() RETURN r.since, r.since.year")),
        %% 图层 API 写、Cypher 读；Cypher 写、图层 API 读
        {ok, V} = ?G:create_vertex(R, #{labels => [<<"Ev">>], props => #{at => {date, {2024, 2, 29}},
                                                                       where => {point, 4326, 13.4, 52.5}}}),
        ?assertEqual([[<<"2025-02-28">>]], tq(R, "MATCH (e:Ev) RETURN e.at + duration('P1Y')")),
        {ok, #{properties := Props}} = ?G:vertex(R, V),
        ?assertEqual(#{<<"at">> => {date, {2024, 2, 29}}, <<"where">> => {point, 4326, 13.4, 52.5}}, Props),
        ?assertError({badarg, _}, ?G:create_vertex(R, #{props => #{bad => {date, nope}}})),
        ok_inv(R)
    end).

%% =========================================================================
%% openCypher 值语义：同类型列表属性、64 位整数溢出、数值文本解析、字符串 + 数值
%% =========================================================================

opencypher_value_semantics_test() ->
    with_graph(fun(R) ->
        ?assertEqual([[[1, 2, 3], [1.5, 2.0], [true, false], [<<"a">>], []]],
                     rows(R, "CREATE (n:L {xs: [1, 2, 3], fs: [1.5, 2.0], bs: [true, false], ss: ['a'], e: []}) "
                             "RETURN n.xs, n.fs, n.bs, n.ss, n.e")),
        ?assertEqual([[[1, 2, 3, 4], true]], rows(R, "MATCH (n:L) SET n.xs = n.xs + [4] RETURN n.xs, 2 IN n.xs")),
        {ok, #{properties := #{<<"xs">> := [1, 2, 3, 4], <<"bs">> := [true, false]} = P}} = ?G:vertex(R, 1),
        ?assertNot(is_map_key(<<"_types">>, P)),
        ?assertMatch(#{stage := exec}, err(R, "CREATE (:L {m: [1, 'a']})")),
        ?assertMatch(#{stage := exec}, err(R, "CREATE (:L {m: [1, 2.5]})")),
        %% 64 位整数
        [?assertMatch(#{stage := exec, message := <<"integer overflow">>}, err(R, Q))
         || Q <- ["RETURN 9223372036854775807 + 1", "RETURN -9223372036854775808 - 1", "RETURN 9223372036854775807 * 2",
                  "UNWIND [9223372036854775807, 1] AS x RETURN sum(x)", "RETURN abs(-9223372036854775807 - 1)"]],
        ?assertEqual([[-9223372036854775808, 9223372036854775807]], rows(R, "RETURN -9223372036854775808, 9223372036854775807")),
        ?assertMatch(#{stage := semantic}, err(R, "RETURN 9223372036854775808")),
        ?assertMatch(#{stage := parse}, err(R, "RETURN 99999999999999999999")),
        %% 数值文本
        ?assertEqual([[1.0e3, 0.5, 5.0, -0.0025, null, 1000, 12]],
                     rows(R, "RETURN toFloat('1e3'), toFloat('.5'), toFloat('5.'), toFloat('-2.5E-3'), toFloat('abc'), "
                             "toInteger('1e3'), toInteger(' 12 ')")),
        %% 字符串 + 数值
        ?assertEqual([[<<"a1">>, <<"1a">>, <<"x1.5">>]], rows(R, "RETURN 'a' + 1, 1 + 'a', 'x' + 1.5")),
        ?assertMatch(#{stage := exec}, err(R, "RETURN 'a' + true")),
        ok_inv(R)
    end).

%% =========================================================================
%% NaN / Infinity（bitcask_cypher_ieee；对外形态 'NaN' / 'Infinity' / '-Infinity'）
%% =========================================================================

nan_infinity_test() ->
    with_graph(fun(R) ->
        ?assertEqual([['NaN', 'Infinity', '-Infinity', 'Infinity', '-Infinity', 'NaN', 'NaN']],
                     rows(R, "RETURN 0.0 / 0.0, 1.0 / 0, -1 / 0.0, 1e308 * 10, -1e308 * 10, "
                             "1 / 0.0 - 1 / 0.0, 0.0 * (1.0 / 0)")),
        ?assertMatch(#{stage := exec}, err(R, "RETURN 1 / 0")),            %% 整数除以 0 仍是错误
        %% 比较：NaN 不等于任何值、和数值比大小全为 false、和别的类型比是 null
        ?assertEqual([[false, true, false, false, false, null, true, false]],
                     rows(R, "WITH 0.0 / 0.0 AS n RETURN n = n, n <> n, n = 1, n < 1, n >= 1, n < 'a', isNaN(n), isNaN(1.5)")),
        ?assertEqual([[true, true, <<"Infinity">>, <<"-Infinity">>, <<"NaN">>, <<"xInfinity">>]],
                     rows(R, "WITH 1.0 / 0 AS i RETURN i = i, i > 1e308, toString(i), toString(-i), toString(0.0 / 0.0), 'x' + i")),
        ?assertEqual([['NaN', '-Infinity', 'NaN', 'Infinity', 'Infinity', 'Infinity', -1]],
                     rows(R, "RETURN sqrt(-1), log(0), log(-1), exp(1000), cot(0), abs(-1.0 / 0), sign(-1.0 / 0)")),
        ?assertEqual([['NaN', 'Infinity', '-Infinity', null]],
                     rows(R, "RETURN toFloat('NaN'), toFloat('Infinity'), toFloat('-Infinity'), toInteger(0.0 / 0.0)")),
        %% 排序：-∞ < 有限数 < +∞ < NaN < null
        ?assertEqual(['-Infinity', 1.5, 2, 'Infinity', 'NaN', null],
                     col(R, "UNWIND [1.5, 0.0 / 0.0, -1.0 / 0, 1.0 / 0, null, 2] AS x RETURN x ORDER BY x")),
        ?assertEqual([['Infinity', 'Infinity', 'Infinity', 1]],
                     rows(R, "UNWIND [1, 2, 1.0 / 0] AS x RETURN sum(x), avg(x), max(x), min(x)")),
        %% 存取（文本 + _types）、参数、图层 API
        q(R, "CREATE (:F {a: 0.0 / 0.0, b: 1.0 / 0, l: [1.5, -1.0 / 0]})"),
        ?assertEqual([['NaN', 'Infinity', [1.5, '-Infinity'], true]], rows(R, "MATCH (n:F) RETURN n.a, n.b, n.l, isNaN(n.a)")),
        ?assertEqual([['Infinity', true]], rows(R, "RETURN $x + 1, $x > 0", #{x => 'Infinity'})),
        {ok, V} = ?G:create_vertex(R, #{props => #{z => '-Infinity'}}),
        ?assertMatch({ok, #{properties := #{<<"z">> := '-Infinity'}}}, ?G:vertex(R, V)),
        ok_inv(R)
    end).

%% =========================================================================
%% 负年份（前推公历，±999999999）与 Duration 乘除（精确分数、纳秒向零截断）
%% =========================================================================

negative_years_test() ->
    with_graph(fun(R) ->
        T = fun(S) -> [[bitcask_cypher_temporal:to_text(V) || V <- Row] || Row <- rows(R, S)] end,
        ?assertEqual([[<<"P1999999998Y11M30D">>]],
                     T("RETURN duration.between(date('-999999999-01-01'), date('+999999999-12-31'))")),
        ?assertEqual([[<<"PT17531639991215H59M59S">>]],
                     T("RETURN duration.inSeconds(localdatetime('-999999999-01-01'), "
                       "localdatetime('+999999999-12-31T23:59:59'))")),
        ?assertEqual([[<<"-0001-02-28">>, <<"0000-01-01">>, <<"-0004-02-29">>, <<"-2000-06-01T12:00Z">>]],
                     T("RETURN date('-0001-03-01') - duration('P1D'), date('-0001-12-31') + duration('P1D'), "
                       "date('-0004-02-29'), datetime('-2000-06-01T12:00Z')")),
        ?assertMatch(#{stage := exec}, err(R, "RETURN date('-0100-02-29')")),      %% -100 不是闰年
        ?assertMatch(#{stage := exec}, err(R, "RETURN date('-1000000000-01-01')")),
        %% 存取与比较
        q(R, "CREATE (:T {d: date('-0500-07-04'), l: [date('-0001-01-01')]})"),
        ?assertEqual([[true, -500]], rows(R, "MATCH (n:T) RETURN n.d < date('0001-01-01'), n.d.year")),
        ok_inv(R)
    end).

duration_scaling_test() ->
    with_graph(fun(R) ->
        T = fun(S) -> [[bitcask_cypher_temporal:to_text(V) || V <- Row] || Row <- rows(R, S)] end,
        ?assertEqual([[<<"P6Y2M22DT13H21M8S">>, <<"P6Y2M22DT13H21M8S">>, <<"P24Y10M28DT32H26M20.000000002S">>,
                       <<"P4Y1M24DT28H23M47.333333333S">>]],
                     T("WITH duration({years: 12, months: 5, days: 14, hours: 16, minutes: 12, seconds: 70, "
                       "nanoseconds: 1}) AS d RETURN d / 2, d * 0.5, d / 0.5, d / 3"))
    end).

%% =========================================================================
%% 关系 id 不复用：删掉的 (src, type, dst, rank) 不会分给新关系（graphdb 的 rank 高水位）
%% =========================================================================

rel_id_no_reuse_test() ->
    with_graph(fun(R) ->
        q(R, "CREATE (a:A), (b:B) CREATE (a)-[:T {name: 'rel1'}]->(b), (a)-[:T {name: 'rel2'}]->(b)"),
        %% 同一条语句里先删后 MERGE（openCypher TCK Merge5 [21]）
        ?assertEqual([[<<"rel3">>], [<<"rel3">>]],
                     rows(R, "MATCH (a)-[t:T]->(b) DELETE t MERGE (a)-[t2:T {name: 'rel3'}]->(b) RETURN t2.name")),
        [[Id3]] = rows(R, "MATCH ()-[t:T]->() RETURN id(t)"),
        %% 以后的语句：删掉再建，id 也是新的
        q(R, "MATCH ()-[t:T]->() DELETE t"),
        q(R, "MATCH (a:A), (b:B) CREATE (a)-[:T {name: 'rel4'}]->(b)"),
        [[Id4]] = rows(R, "MATCH ()-[t:T]->() RETURN id(t)"),
        ?assertNotEqual(Id3, Id4),
        ?assertEqual([[1]], rows(R, "MATCH ()-[t:T]->() RETURN count(t)")),
        ok_inv(R)
    end).

%% =========================================================================
%% 错误类型与细节代码（openCypher；bitcask_cypher_error）：错误 map 带 type / detail
%% =========================================================================

error_codes_test() ->
    with_graph(fun(R) ->
        q(R, "CREATE (:A)-[:T]->(:B)"),
        Code = fun(Q) ->
                       case ?C:q(R, Q) of
                           {error, E} -> {maps:get(stage, E), maps:get(type, E, none), maps:get(detail, E, none)};
                           Ok -> {unexpected, Ok}
                       end
               end,
        %% 解析
        ?assertEqual({parse, <<"SyntaxError">>, <<"UnexpectedSyntax">>}, Code("RETURN [, ]")),
        ?assertEqual({parse, <<"SyntaxError">>, <<"InvalidNumberLiteral">>}, Code("RETURN 0x1Z")),
        ?assertEqual({parse, <<"SyntaxError">>, <<"IntegerOverflow">>}, Code("RETURN 9223372036854775809")),
        ?assertEqual({parse, <<"SyntaxError">>, <<"InvalidRelationshipPattern">>}, Code("MATCH (a)-[:T*-2]->(b) RETURN b")),
        %% 语义
        ?assertEqual({semantic, <<"SyntaxError">>, <<"UndefinedVariable">>}, Code("RETURN x")),
        ?assertEqual({semantic, <<"SyntaxError">>, <<"VariableTypeConflict">>}, Code("MATCH (r) MATCH ()-[r]-() RETURN r")),
        ?assertEqual({semantic, <<"SyntaxError">>, <<"VariableAlreadyBound">>}, Code("MATCH (a) CREATE (a)")),
        ?assertEqual({semantic, <<"SyntaxError">>, <<"InvalidAggregation">>}, Code("MATCH (n) WHERE count(n) > 1 RETURN n")),
        ?assertEqual({semantic, <<"SyntaxError">>, <<"NoExpressionAlias">>}, Code("MATCH (a) WITH a, count(*) RETURN a")),
        ?assertEqual({semantic, <<"ProcedureError">>, <<"ProcedureNotFound">>}, Code("CALL no.such.proc()")),
        ?assertEqual({semantic, <<"ParameterMissing">>, <<"MissingParameter">>}, Code("RETURN $nope")),
        ?assertEqual({semantic, <<"SyntaxError">>, <<"InvalidArgumentType">>}, Code("RETURN NOT 1")),
        %% 规划
        ?assertEqual({plan, <<"SyntaxError">>, <<"DifferentColumnsInUnion">>}, Code("RETURN 1 AS a UNION RETURN 2 AS b")),
        %% 执行
        ?assertEqual({exec, <<"TypeError">>, <<"InvalidArgumentValue">>}, Code("WITH [1] AS x RETURN toInteger(x)")),
        ?assertEqual({exec, <<"ArgumentError">>, <<"NumberOutOfRange">>}, Code("RETURN range(1, 2, 0)")),
        ?assertEqual({exec, <<"TypeError">>, <<"MapElementAccessByNonString">>}, Code("WITH {a: 1} AS m, 0 AS k RETURN m[k]")),
        ?assertEqual({exec, <<"ArithmeticError">>, <<"DivisionByZero">>}, Code("WITH 0 AS z RETURN 1 / z")),
        ?assertEqual({exec, <<"ConstraintVerificationFailed">>, <<"DeleteConnectedNode">>}, Code("MATCH (n:A) DELETE n")),
        ?assertEqual({exec, <<"EntityNotFound">>, <<"DeletedEntityAccess">>}, Code("MATCH (n:B) DETACH DELETE n RETURN n.x")),
        ?assertEqual({exec, <<"TypeError">>, <<"InvalidPropertyType">>}, Code("CREATE (a) SET a.m = [{x: 1}]")),
        ?assertEqual({exec, <<"ArgumentError">>, <<"InvalidArgumentValue">>}, Code("RETURN date('2024-13-01')")),
        %% 只有类型、没有细节代码的
        {error, E} = ?C:q(R, "MERGE (n:M {p: null})"),
        ?assertMatch(#{type := <<"SemanticError">>, detail := <<"MergeReadOwnWrites">>}, E),
        ok_inv(R)
    end).
