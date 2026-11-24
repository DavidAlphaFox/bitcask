%% =========================================================================
%% bitcask_cypher_temporal — Cypher 的时间与空间类型（doc/cypher-phase3-design-zh.md 第 7 节）
%%
%%   值（也是对外形态）：
%%     {date, {Y, M, D}}
%%     {localtime, NanosOfDay}
%%     {time, NanosOfDay, OffsetSeconds}
%%     {localdatetime, {Y, M, D}, NanosOfDay}
%%     {datetime, {Y, M, D}, NanosOfDay, OffsetSeconds}
%%     {datetime, {Y, M, D}, NanosOfDay, OffsetSeconds, ZoneName}   %% 命名时区（IANA，bitcask_cypher_tz）
%%     {duration, Months, Days, Seconds, Nanos}       %% 0 =< Nanos < 10^9
%%     {point, Srid, X, Y} | {point, Srid, X, Y, Z}   %% 7203 / 9157 笛卡尔，4326 / 4979 WGS-84
%%
%%   只支持固定偏移（Z、±hh:mm），不支持命名时区（标准库没有 IANA 时区库）。
%%   存储：to_text/1 + type_tag/1，读回 from_text/2（graphdb_model 用 `_types` 记类型）。
%% =========================================================================
-module(bitcask_cypher_temporal).

-export([is_value/1, type_tag/1, construct/3, construct_relabel/3, field/2, plus/2, minus/2, times/2, divide/2,
         eq/2, compare/2, order_key/1, truncate/3, between/3, distance/2, within_bbox/3,
         to_text/1, from_text/2, format/1]).

-define(NS, 1000000000).
-define(NS_DAY, 86400000000000).
-define(MAX_YEAR, 999999999).               %% 年份范围 ±999999999（同 Neo4j / java.time）
-define(EPOCH_DAYS, 719528).               %% calendar:date_to_gregorian_days({1970, 1, 1})
-define(EARTH_RADIUS, 6378140.0).

%% 时间 / 空间值的错误：缺省 ArgumentError / InvalidArgumentValue（文本格式不对、分量越界……）；
%% 参数类型不对（needs / must be a … 一类）是 TypeError / InvalidArgumentType（openCypher 的分类）。
err(Msg) -> throw({exec_error, classify(Msg)}).
err(Fmt, Args) -> throw({exec_error, classify(io_lib:format(Fmt, Args))}).

classify(Msg) ->
    Text = unicode:characters_to_binary(Msg),
    {T, D} = case re:run(Text, "needs (a|two|three|x and y)|must be (a|an|integers|a temporal)|division by zero|out of range",
                          [{capture, first, binary}]) of
                 {match, [<<"division by zero">>]} -> {'ArithmeticError', 'DivisionByZero'};
                 {match, [<<"out of range">>]} -> {'ArgumentError', 'NumberOutOfRange'};
                 {match, _} -> {'TypeError', 'InvalidArgumentType'};
                 nomatch -> {'ArgumentError', 'InvalidArgumentValue'}
             end,
    bitcask_cypher_error:code(T, D, Msg).

%% ---- 识别 ------------------------------------------------------------------

is_value({date, {Y, M, D}}) when is_integer(Y), is_integer(M), is_integer(D) -> true;
is_value({localtime, N}) when is_integer(N) -> true;
is_value({time, N, O}) when is_integer(N), is_integer(O) -> true;
is_value({localdatetime, {_, _, _}, N}) when is_integer(N) -> true;
is_value({datetime, {_, _, _}, N, O}) when is_integer(N), is_integer(O) -> true;
is_value({datetime, {_, _, _}, N, O, Z}) when is_integer(N), is_integer(O), is_binary(Z) -> true;
is_value({duration, Mo, D, S, N}) when is_integer(Mo), is_integer(D), is_integer(S), is_integer(N) -> true;
is_value({point, Srid, X, Y}) when is_integer(Srid), is_number(X), is_number(Y) -> true;
is_value({point, Srid, X, Y, Z}) when is_integer(Srid), is_number(X), is_number(Y), is_number(Z) -> true;
is_value(_) -> false.

type_tag(V) -> atom_to_binary(element(1, V)).

%% ---- 构造 ------------------------------------------------------------------
%% construct(Type, Arg, NowNs)：Arg = none（当前时刻，NowNs 是语句时钟，UTC 纳秒）| 字符串 | 映射 | 别的时间值。

construct(Type, null, _Now) when Type =/= point -> null;
construct(point, Arg, _Now) -> point(Arg);
construct(duration, Arg, _Now) -> duration(Arg);
construct(Type, none, Now) ->
    {Date, Ns} = utc_parts(Now),
    compose(Type, #{date => Date, ns => Ns, off => 0});
construct(Type, S, _Now) when is_binary(S) -> parse(Type, S);
construct(Type, M, Now) when is_map(M) -> from_map(Type, M, Now, convert);
construct(Type, V, _Now) ->
    case is_value(V) andalso element(1, V) =/= duration andalso element(1, V) =/= point of
        true -> compose(Type, parts(V));
        false -> err("~s() needs a string, a map or a temporal value", [Type])
    end.

%% x.truncate(unit, value, overrides) 的覆盖：timezone 只换标签，不换算时刻。
construct_relabel(Type, M, Now) when is_map(M) -> from_map(Type, M, Now, relabel).

utc_parts(Ns) ->
    Days = floor_div(Ns, ?NS_DAY),
    {gdate(?EPOCH_DAYS + Days), Ns - Days * ?NS_DAY}.

%% 时间值 → 组成部分（没有的为 undefined）。
parts({date, D}) -> #{date => D, ns => undefined, off => undefined, zone => undefined};
parts({localtime, N}) -> #{date => undefined, ns => N, off => undefined, zone => undefined};
parts({time, N, O}) -> #{date => undefined, ns => N, off => O, zone => undefined};
parts({localdatetime, D, N}) -> #{date => D, ns => N, off => undefined, zone => undefined};
parts({datetime, D, N, O}) -> #{date => D, ns => N, off => O, zone => undefined};
parts({datetime, D, N, O, Z}) -> #{date => D, ns => N, off => O, zone => Z}.

%% 组成部分 → 类型（缺日期的不能变成带日期的；缺时间取 0 点；缺偏移取 UTC）。
compose(Type, #{date := D, ns := N, off := O} = P) ->
    Ns = case N of undefined -> 0; _ -> N end,
    Off = case O of undefined -> 0; _ -> O end,
    Zone = maps:get(zone, P, undefined),
    NeedDate = lists:member(Type, [date, localdatetime, datetime]),
    NeedDate andalso D =:= undefined andalso err("can't make a ~s from a value without a date", [Type]),
    case Type of
        date -> {date, D};
        localtime -> {localtime, Ns};
        time -> {time, Ns, Off};
        localdatetime -> {localdatetime, D, Ns};
        datetime when Zone =:= undefined -> {datetime, D, Ns, Off};
        datetime -> zoned(D, Ns, O, Zone)
    end.

%% 命名时区里的本地日期时刻 → {datetime, D, Ns, Off, Zone}：偏移按时区规则解析（重叠段优先用 Pref，
%% 空隙段把时刻往后挪）。
zoned(D, Ns, Pref, Zone) ->
    Local = (gdays(D) - ?EPOCH_DAYS) * 86400 + Ns div ?NS,
    {Local2, Off} = bitcask_cypher_tz:resolve_local(Zone, Local, Pref),
    {D2, Ns2} = case Local2 =:= Local of
                    true -> {D, Ns};
                    false -> shift(D, Ns, Local2 - Local)
                end,
    {datetime, D2, Ns2, Off, Zone}.

%% 时间值所在的 UTC 时刻（纳秒）→ 命名时区里的本地日期时刻。
in_zone(UtcNs, Zone) ->
    Off = bitcask_cypher_tz:offset_at_utc(Zone, floor_div(UtcNs, ?NS)),
    {D, N} = utc_parts(UtcNs + Off * ?NS),
    {datetime, D, N, Off, Zone}.

%% timezone 参数：偏移（Z、±hh:mm…）或 IANA 时区名。
tz_arg(Tz) when is_binary(Tz) ->
    case Tz of
        <<C, _/binary>> when C =:= $+; C =:= $-; C =:= $Z; C =:= $z -> {off, parse_offset(Tz)};
        _ ->
            bitcask_cypher_tz:is_zone_name(Tz) orelse err(["invalid time zone: ", Tz]),
            bitcask_cypher_tz:exists(Tz) orelse err(["unknown time zone: ", Tz]),
            {zone, Tz}
    end;
tz_arg(_) -> err("timezone must be a string such as 'Z', '+01:00' or 'Europe/Stockholm'").

%% ---- 解析 ------------------------------------------------------------------

parse(date, S) -> {date, parse_date(S)};
parse(localtime, S0) ->
    {S, _} = split_zone(S0),
    case parse_time(S) of
        {N, undefined} -> {localtime, N};
        {N, _} -> {localtime, N}
    end;
parse(time, S0) ->
    {S, Zone} = split_zone(S0),
    {N, O} = parse_time(S),
    case {O, Zone} of
        {undefined, undefined} -> {time, N, 0};
        {undefined, _} ->
            %% 只有时区名：按今天的日期取偏移
            {Today, _} = utc_parts(os:system_time(nanosecond)),
            {datetime, _, N2, O2, _} = zoned(Today, N, undefined, Zone),
            {time, N2, O2};
        _ -> {time, N, O}
    end;
parse(localdatetime, S0) ->
    {S, _} = split_zone(S0),
    {D, T} = split_dt(S),
    {N, _} = case T of none -> {0, undefined}; _ -> parse_time(T) end,
    {localdatetime, D, N};
parse(datetime, S0) ->
    {S, Zone} = split_zone(S0),
    {D, T} = split_dt(S),
    {N, O} = case T of none -> {0, undefined}; _ -> parse_time(T) end,
    case Zone of
        undefined -> {datetime, D, N, case O of undefined -> 0; _ -> O end};
        _ -> zoned(D, N, O, Zone)
    end.

%% 末尾的 [Area/Location]：拆出时区名（并校验存在）。
split_zone(S) ->
    case re:run(S, "^(.*)\\[([^\\]]+)\\]$", [{capture, all_but_first, binary}]) of
        {match, [Rest, Z]} ->
            {zone, Z} = tz_arg(Z),
            {Rest, Z};
        nomatch -> {S, undefined}
    end.

split_dt(S) ->
    case re:run(S, "^([^Tt]+)(?:[Tt](.+))?$", [{capture, all_but_first, binary}]) of
        {match, [D]} -> {parse_date(D), none};
        {match, [D, T]} -> {parse_date(D), T};
        nomatch -> err(["invalid date-time: ", S])
    end.

parse_date(S) ->
    R = fun(P) -> re:run(S, P, [{capture, all_but_first, list}]) end,
    I = fun list_to_integer/1,
    D = case R("^([+-]?\\d{4,})-(\\d{2})-(\\d{2})$") of
            {match, [Y, M, Dd]} -> {I(Y), I(M), I(Dd)};
            nomatch ->
                case R("^(\\d{4})(\\d{2})(\\d{2})$") of
                    {match, [Y, M, Dd]} -> {I(Y), I(M), I(Dd)};
                    nomatch ->
                      case R("^(\\d{4})(\\d{2})$") of
                       {match, [Y, M]} -> {I(Y), I(M), 1};
                       nomatch ->
                        case R("^([+-]?\\d{4,})-?W(\\d{2})(?:-?(\\d))?$") of
                            {match, [Y, W]} -> week_date(I(Y), I(W), 1);
                            {match, [Y, W, Wd]} -> week_date(I(Y), I(W), I(Wd));
                            nomatch ->
                                case R("^([+-]?\\d{4,})-?(\\d{3})$") of
                                    {match, [Y, O]} -> ordinal_date(I(Y), I(O));
                                    nomatch ->
                                        case R("^([+-]?\\d{4,})-(\\d{2})$") of
                                            {match, [Y, M]} -> {I(Y), I(M), 1};
                                            nomatch ->
                                                case R("^([+-]?\\d{4,})$") of
                                                    {match, [Y]} -> {I(Y), 1, 1};
                                                    nomatch -> err(["invalid date: ", S])
                                                end
                                        end
                                end
                        end
                      end
                end
        end,
    check_date(D).

check_date({Y, M, D} = Date) ->
    (abs(Y) =< ?MAX_YEAR andalso M >= 1 andalso M =< 12 andalso D >= 1 andalso D =< last_day(Y, M)) orelse
        err("invalid date ~ts", [date_text(Date)]),
    Date.

week_date(Y, W, Wd) ->
    (W >= 1 andalso W =< weeks_in_year(Y) andalso Wd >= 1 andalso Wd =< 7) orelse
        err("invalid week date ~b-W~2..0b-~b", [Y, W, Wd]),
    gdate(week1_monday(Y) + (W - 1) * 7 + Wd - 1).

week1_monday(Y) ->
    Jan4 = gdays({Y, 1, 4}),
    Jan4 - (dow({Y, 1, 4}) - 1).

weeks_in_year(Y) -> (week1_monday(Y + 1) - week1_monday(Y)) div 7.

ordinal_date(Y, O) ->
    Len = case leap(Y) of true -> 366; false -> 365 end,
    (O >= 1 andalso O =< Len) orelse err("invalid ordinal date ~b-~3..0b", [Y, O]),
    gdate(gdays({Y, 1, 1}) + O - 1).

%% ---- 前推公历（含负年份；calendar 只收 Y >= 0）----------------------------
%% 天数从 0000-01-01 起算（与 calendar:date_to_gregorian_days 一致），年份范围同 Neo4j：±999999999。
%% 算法：Howard Hinnant 的 days_from_civil / civil_from_days（400 年一个周期）。
gdays({Y0, M, D}) ->
    Y = case M =< 2 of true -> Y0 - 1; false -> Y0 end,
    Era = floor_div(Y, 400),
    Yoe = Y - Era * 400,
    Mp = case M > 2 of true -> M - 3; false -> M + 9 end,
    Doy = (153 * Mp + 2) div 5 + D - 1,
    Doe = Yoe * 365 + Yoe div 4 - Yoe div 100 + Doy,
    Era * 146097 + Doe + 60.                                  %% 0000-03-01 是第 60 天

gdate(Days) ->
    Z = Days - 60,
    Era = floor_div(Z, 146097),
    Doe = Z - Era * 146097,
    Yoe = (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365,
    Doy = Doe - (365 * Yoe + Yoe div 4 - Yoe div 100),
    Mp = (5 * Doy + 2) div 153,
    D = Doy - (153 * Mp + 2) div 5 + 1,
    M = case Mp < 10 of true -> Mp + 3; false -> Mp - 9 end,
    Y = Yoe + Era * 400 + (case M =< 2 of true -> 1; false -> 0 end),
    {Y, M, D}.

leap(Y) -> Y rem 4 =:= 0 andalso (Y rem 100 =/= 0 orelse Y rem 400 =:= 0).

last_day(Y, 2) -> case leap(Y) of true -> 29; false -> 28 end;
last_day(_, M) when M =:= 4; M =:= 6; M =:= 9; M =:= 11 -> 30;
last_day(_, _) -> 31.

%% 1 = 周一 … 7 = 周日（0000-01-01 是周六）
dow(Date) -> mod(gdays(Date) + 5, 7) + 1.

%% 时刻：HH[:MM[:SS[.f]]] 或 HHMM[SS[.f]]，后跟可选偏移。返回 {纳秒, 偏移秒 | undefined}。
parse_time(S) ->
    case re:run(S, "^(\\d{2})(?::?(\\d{2})(?::?(\\d{2})(?:[.,](\\d{1,9}))?)?)?(Z|z|[+-]\\d{2}(?::?\\d{2})?)?$",
                [{capture, all_but_first, list}]) of
        {match, Gs} ->
            G = fun(I) -> case length(Gs) >= I of true -> lists:nth(I, Gs); false -> "" end end,
            Num = fun("") -> 0; (X) -> list_to_integer(X) end,
            {H, Mi, Se} = {Num(G(1)), Num(G(2)), Num(G(3))},
            Frac = case G(4) of "" -> 0; F -> list_to_integer(string:left(F, 9, $0)) end,
            (H < 24 andalso Mi < 60 andalso Se < 60) orelse err(["invalid time: ", S]),
            Off = case G(5) of "" -> undefined; O -> parse_offset(O) end,
            {((H * 60 + Mi) * 60 + Se) * ?NS + Frac, Off};
        nomatch -> err(["invalid time: ", S])
    end.

parse_offset(O) when is_binary(O) -> parse_offset(binary_to_list(O));
parse_offset("Z") -> 0;
parse_offset("z") -> 0;
parse_offset([Sign | Rest]) when Sign =:= $+; Sign =:= $- ->
    {H, M, Sec} = case [C || C <- Rest, C =/= $:] of
                      [A, B] -> {list_to_integer([A, B]), 0, 0};
                      [A, B, C, D] -> {list_to_integer([A, B]), list_to_integer([C, D]), 0};
                      [A, B, C, D, E, F] -> {list_to_integer([A, B]), list_to_integer([C, D]), list_to_integer([E, F])};
                      _ -> err(["invalid time zone offset: ", [Sign | Rest]])
                  end,
    (H =< 18 andalso M < 60 andalso Sec < 60) orelse err(["invalid time zone offset: ", [Sign | Rest]]),
    S = (H * 60 + M) * 60 + Sec,
    case Sign of $+ -> S; $- -> -S end;
parse_offset(O) -> err(["invalid time zone offset: ", O]).

%% ---- 映射构造 --------------------------------------------------------------

from_map(Type, M0, Now, TzMode) ->
    M = maps:filter(fun(_, V) -> V =/= null end, M0),
    %% 基础值：date / time / datetime 键给的别的时间值，其余键覆盖（time 键连同偏移 / 时区名）
    Base0 = lists:foldl(fun(K, Acc) ->
                                case maps:find(K, M) of
                                    {ok, V} ->
                                        is_value(V) orelse err("`~s` must be a temporal value", [K]),
                                        P = parts(V),
                                        maps:merge(Acc, maps:filter(fun(_, X) -> X =/= undefined end,
                                                                    case K of
                                                                        <<"date">> -> maps:with([date], P);
                                                                        <<"time">> -> maps:with([ns, off, zone], P);
                                                                        _ -> P
                                                                    end));
                                    error -> Acc
                                end
                        end, #{date => undefined, ns => undefined, off => undefined, zone => undefined},
                        [<<"datetime">>, <<"date">>, <<"time">>]),
    BaseE = case {maps:find(<<"epochSeconds">>, M), maps:find(<<"epochMillis">>, M)} of
                {{ok, Es}, _} when is_integer(Es) ->
                    {D0, N0} = utc_parts(Es * ?NS + int(M, <<"nanosecond">>, 0)),
                    Base0#{date := D0, ns := N0, off := 0, zone := undefined};
                {_, {ok, Em}} when is_integer(Em) ->
                    {D0, N0} = utc_parts(Em * 1000000 + int(M, <<"nanosecond">>, 0)),
                    Base0#{date := D0, ns := N0, off := 0, zone := undefined};
                {error, error} -> Base0;
                _ -> err("epochSeconds / epochMillis must be integers")
            end,
    Tz = case maps:find(<<"timezone">>, M) of
             {ok, TzV} -> tz_arg(TzV);
             error -> none
         end,
    Base = BaseE,
    Epoch = maps:is_key(<<"epochSeconds">>, M) orelse maps:is_key(<<"epochMillis">>, M),
    DateKeys = [<<"year">>, <<"month">>, <<"day">>, <<"week">>, <<"dayOfWeek">>, <<"ordinalDay">>,
                <<"quarter">>, <<"dayOfQuarter">>],
    TimeKeys = [<<"hour">>, <<"minute">>, <<"second">>, <<"millisecond">>, <<"microsecond">>, <<"nanosecond">>],
    Date = case lists:any(fun(K) -> maps:is_key(K, M) end, DateKeys) of
               false -> maps:get(date, Base);
               true -> map_date(M, maps:get(date, Base))
           end,
    Ns = case not Epoch andalso lists:any(fun(K) -> maps:is_key(K, M) end, TimeKeys) of
             false -> maps:get(ns, Base);
             true -> map_time(M, maps:get(ns, Base))
         end,
    Date1 = case {Type, Date} of
                {T, undefined} when T =:= date; T =:= localdatetime; T =:= datetime ->
                    %% 只给了时间部分：日期取今天（openCypher：缺的高位分量取当前值）
                    {Today, _} = utc_parts(Now),
                    Today;
                _ -> Date
            end,
    %% 新的 timezone：先用全部分量在基础值的时区里得到本地时刻，再换算到新时区（同一时刻）；
    %% x.truncate 的覆盖映射（relabel）只换标签。
    SrcOff = maps:get(off, Base), SrcZone = maps:get(zone, Base),
    {Date2, Ns2, Off, Zone} =
        case {TzMode, Tz} of
            {_, none} -> {Date1, Ns, SrcOff, SrcZone};
            {convert, _} when is_integer(SrcOff), Ns =/= undefined ->
                {TodayC, _} = utc_parts(Now),
                DC = case Date1 of undefined -> TodayC; _ -> Date1 end,
                SrcOff2 = case SrcZone of
                              undefined -> SrcOff;
                              _ -> element(4, zoned(DC, Ns, SrcOff, SrcZone))   %% 新日期上的偏移
                          end,
                UtcNs = (gdays(DC) - ?EPOCH_DAYS) * ?NS_DAY + Ns - SrcOff2 * ?NS,
                case Tz of
                    {off, NewOff} ->
                        {CD, CN} = utc_parts(UtcNs + NewOff * ?NS),
                        {case Date1 of undefined -> undefined; _ -> CD end, CN, NewOff, undefined};
                    {zone, Z} ->
                        {datetime, ZD, ZN, ZO, _} = in_zone(UtcNs, Z),
                        {case Date1 of undefined -> undefined; _ -> ZD end, ZN, ZO, Z}
                end;
            {_, {off, O1}} -> {Date1, Ns, O1, undefined};
            {_, {zone, Z1}} -> {Date1, Ns, undefined, Z1}
        end,
    case {Type, Zone} of
        {time, Z2} when Z2 =/= undefined ->
            %% Time 不带时区名：按日期（没有就是今天）在这个时区的偏移
            {TodayT, _} = utc_parts(Now),
            DT = case Date2 of undefined -> TodayT; _ -> Date2 end,
            NsT = case Ns2 of undefined -> 0; _ -> Ns2 end,
            {datetime, _, NsT2, OffT, _} = zoned(DT, NsT, Off, Z2),
            {time, NsT2, OffT};
        _ -> compose(Type, #{date => Date2, ns => Ns2, off => Off, zone => Zone})
    end.

%% 时刻平移 DeltaSec 秒（有日期时跨日进位）。
shift(Date, Ns, Delta) ->
    T = gdays(Date) * ?NS_DAY + Ns + Delta * ?NS,
    Days = floor_div(T, ?NS_DAY),
    {gdate(Days), T - Days * ?NS_DAY}.

%% 映射里的日期分量：按给出的键选表示法（周 / 季度 / 序数 / 日历），没给的分量从基础值（date / datetime 键）
%% 的同一表示法里取，没有基础值时取 1。周表示法里 year 是周年（weekYear）。
map_date(M, Base) ->
    Has = fun(K) -> maps:is_key(K, M) end,
    Need = fun(V, What) -> case V of undefined -> err(["a date needs ", What]); _ -> V end end,
    BY = case Base of undefined -> undefined; {Yb, _, _} -> Yb end,
    D = case {Has(<<"week">>) orelse Has(<<"dayOfWeek">>), Has(<<"quarter">>) orelse Has(<<"dayOfQuarter">>),
              Has(<<"ordinalDay">>)} of
            {true, _, _} ->
                {BWY, BW} = case Base of undefined -> {undefined, 1}; _ -> iso_week(Base) end,
                BDow = case Base of undefined -> 1; _ -> dow(Base) end,
                WY = Need(int(M, <<"year">>, BWY), "a year"),
                week_date(WY, int(M, <<"week">>, BW), int(M, <<"dayOfWeek">>, BDow));
            {_, true, _} ->
                Y = Need(int(M, <<"year">>, BY), "a year"),
                {BQ, BDq} = case Base of
                                undefined -> {1, 1};
                                {Yb2, Mb, _} -> {(Mb - 1) div 3 + 1, gdays(Base) - gdays({Yb2, ((Mb - 1) div 3) * 3 + 1, 1}) + 1}
                            end,
                Q = int(M, <<"quarter">>, BQ),
                (Q >= 1 andalso Q =< 4) orelse err("quarter must be 1..4"),
                DQ = int(M, <<"dayOfQuarter">>, BDq),
                Start = gdays({Y, (Q - 1) * 3 + 1, 1}),
                End = gdays({Y + (Q div 4), (Q rem 4) * 3 + 1, 1}),
                (DQ >= 1 andalso Start + DQ - 1 < End) orelse err("dayOfQuarter out of range"),
                gdate(Start + DQ - 1);
            {_, _, true} ->
                Y = Need(int(M, <<"year">>, BY), "a year"),
                ordinal_date(Y, int(M, <<"ordinalDay">>, 1));
            _ ->
                {BM, BD} = case Base of undefined -> {1, 1}; {_, Mb, Db} -> {Mb, Db} end,
                Y = Need(int(M, <<"year">>, BY), "a year"),
                {Y, int(M, <<"month">>, BM), int(M, <<"day">>, BD)}
        end,
    check_date(D).

map_time(M, Base) ->
    B = case Base of undefined -> 0; _ -> Base end,
    BH = B div (3600 * ?NS), BMi = (B div (60 * ?NS)) rem 60, BS = (B div ?NS) rem 60,
    H = int(M, <<"hour">>, BH), Mi = int(M, <<"minute">>, BMi), S = int(M, <<"second">>, BS),
    Sub = sub_second(M, B rem ?NS),
    (H >= 0 andalso H < 24 andalso Mi >= 0 andalso Mi < 60 andalso S >= 0 andalso S < 60
     andalso Sub >= 0 andalso Sub < ?NS) orelse err("time component out of range"),
    ((H * 60 + Mi) * 60 + S) * ?NS + Sub.

%% 亚秒分量：没给的从基础值取。millisecond 换掉毫秒位；microsecond 在给了 millisecond 时是毫秒内的微秒
%% （0..999），否则是秒内的微秒；nanosecond 在给了更粗的分量时只换它下面那几位，单独给且小于 1000 时
%% 保留基础值的毫秒 / 微秒位（x.truncate('millisecond', t, {nanosecond: 2})）。
sub_second(M, Base) ->
    Ms = maps:find(<<"millisecond">>, M), Us = maps:find(<<"microsecond">>, M), Ns = maps:find(<<"nanosecond">>, M),
    Chk = fun(V) -> is_integer(V) orelse err("sub-second components must be integers"), V end,
    S1 = case Ms of {ok, A} -> Chk(A) * 1000000 + Base rem 1000000; error -> Base end,
    S2 = case {Us, Ms} of
             {{ok, U}, {ok, _}} -> (S1 div 1000000) * 1000000 + Chk(U) * 1000 + S1 rem 1000;
             {{ok, U}, error} -> Chk(U) * 1000 + S1 rem 1000;
             _ -> S1
         end,
    case {Ns, Us, Ms} of
        {{ok, N}, {ok, _}, _} -> (S2 div 1000) * 1000 + Chk(N);
        {{ok, N}, error, {ok, _}} -> (S2 div 1000000) * 1000000 + Chk(N);
        {{ok, N}, error, error} when N < 1000, Base =/= 0 -> (S2 div 1000) * 1000 + Chk(N);
        {{ok, N}, error, error} -> Chk(N);
        _ -> S2
    end.

int(M, K, Def) ->
    case maps:find(K, M) of
        {ok, V} when is_integer(V) -> V;
        {ok, _} -> err("`~s` must be an integer", [K]);
        error -> Def
    end.

%% ---- Duration --------------------------------------------------------------

duration(S) when is_binary(S) ->
    %% ISO 8601 的备用格式 PYYYY-MM-DDThh:mm:ss[.f]
    case re:run(S, "^P(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2}(?:\\.\\d+)?)$",
                [{capture, all_but_first, list}]) of
        {match, [Y, Mo, D, H, Mi, Se]} ->
            I = fun list_to_integer/1,
            make_dur(I(Y) * 12 + I(Mo), I(D), I(H) * 3600 + I(Mi) * 60 + to_num(Se), 0);
        nomatch -> parse_duration(S)
    end;
duration(M) when is_map(M) ->
    Num = fun(K) -> case maps:find(K, M) of
                        {ok, V} when is_number(V) -> V;
                        {ok, null} -> 0;
                        {ok, _} -> err("`~s` must be a number", [K]);
                        error -> 0
                    end end,
    make_dur(Num(<<"years">>) * 12 + Num(<<"quarters">>) * 3 + Num(<<"months">>),
             Num(<<"weeks">>) * 7 + Num(<<"days">>),
             Num(<<"hours">>) * 3600 + Num(<<"minutes">>) * 60 + Num(<<"seconds">>),
             Num(<<"milliseconds">>) * 1000000 + Num(<<"microseconds">>) * 1000 + Num(<<"nanoseconds">>));
duration({duration, _, _, _, _} = D) -> D;
duration(null) -> null;
duration(_) -> err("duration() needs a string or a map").

%% 分量可以是小数：小数的月按平均月长（30.436875 天）折成整天，余数与小数的天按 86400 秒折进秒分量
%% （月、天、秒三者各自独立，openCypher / Neo4j 的规则：duration({months: 0.75}) = P22DT19H51M49.5S）。
make_dur(Mo, D, S, N) ->
    MoI = trunc(Mo),
    D2 = D + (Mo - MoI) * 30.436875,
    DI = trunc(D2),
    TotalNs = round((S + (D2 - DI) * 86400) * ?NS + N),
    norm_dur(MoI, DI, TotalNs).

norm_dur(Mo, D, TotalNs) ->
    S = floor_div(TotalNs, ?NS),
    {duration, Mo, D, S, TotalNs - S * ?NS}.

parse_duration(S) ->
    Num = "([-+]?\\d+(?:[.,]\\d+)?)",
    P = "^([-+])?P(?:" ++ Num ++ "Y)?(?:" ++ Num ++ "M)?(?:" ++ Num ++ "W)?(?:" ++ Num ++ "D)?"
        ++ "(?:T(?:" ++ Num ++ "H)?(?:" ++ Num ++ "M)?(?:" ++ Num ++ "S)?)?$",
    case re:run(S, P, [{capture, all_but_first, list}]) of
        {match, Gs0} ->
            Gs = Gs0 ++ lists:duplicate(8 - length(Gs0), ""),
            [Sign | Vals] = Gs,
            lists:all(fun(V) -> V =:= "" end, Vals) andalso err(["invalid duration: ", S]),
            [Y, Mo, W, D, H, Mi, Se] = [case V of
                                            "" -> 0;
                                            _ -> to_num(lists:map(fun($,) -> $.; (C) -> C end, V))
                                        end || V <- Vals],
            Dur = make_dur(Y * 12 + Mo, W * 7 + D, H * 3600 + Mi * 60 + Se, 0),
            case Sign of "-" -> neg(Dur); _ -> Dur end;
        nomatch -> err(["invalid duration: ", S])
    end.

to_num(S) ->
    case string:to_float(S) of
        {F, ""} -> F;
        _ -> list_to_integer(S)
    end.

neg({duration, Mo, D, S, N}) -> norm_dur(-Mo, -D, -(S * ?NS + N)).

%% ---- 运算 ------------------------------------------------------------------

plus({duration, M1, D1, S1, N1}, {duration, M2, D2, S2, N2}) ->
    norm_dur(M1 + M2, D1 + D2, (S1 + S2) * ?NS + N1 + N2);
plus({duration, _, _, _, _} = D, T) -> plus(T, D);
plus(T, {duration, _, _, _, _} = D) ->
    case is_value(T) andalso element(1, T) =/= point of
        true -> add(T, D);
        false -> mismatch('+')
    end;
plus(_, _) -> mismatch('+').

minus({duration, _, _, _, _} = A, {duration, _, _, _, _} = B) -> plus(A, neg(B));
minus(T, {duration, _, _, _, _} = D) -> plus(T, neg(D));
minus(_, _) -> mismatch('-').

times({duration, Mo, D, S, N}, X) when is_integer(X) -> norm_dur(Mo * X, D * X, (S * ?NS + N) * X);
times({duration, _, _, _, _} = Dur, X) when is_float(X) -> scale_dur(Dur, frac(X));
times(X, {duration, _, _, _, _} = D) when is_number(X) -> times(D, X);
times(_, _) -> mismatch('*').

divide({duration, _, _, _, _}, X) when X == 0 -> err("division by zero");
divide({duration, _, _, _, _} = Dur, X) when is_number(X) -> {P, Q} = frac(X), scale_dur(Dur, {Q, P});
divide(_, _) -> mismatch('/').

%% Duration × P/Q：按精确分数算，月的小数部分按平均月长（146097 / 4800 天）折成天、天的小数折成秒，
%% 最后的纳秒向零截断（Neo4j 的 DurationValue.approximate 逐级截断；用分数免得浮点误差多出 1 纳秒）。
scale_dur({duration, Mo, D, S, N}, {P, Q0}) ->
    {P1, Q} = case Q0 < 0 of true -> {-P, -Q0}; false -> {P, Q0} end,
    MoI = (Mo * P1) div Q,                                     %% 月：Mo·P/Q 向零取整
    MoR = Mo * P1 - MoI * Q,                                   %% 余下的月 = MoR / Q
    DNum = D * P1 * 4800 + MoR * 146097,                       %% 天 = DNum / (Q·4800)
    DDen = Q * 4800,
    DI = DNum div DDen,
    DR = DNum - DI * DDen,
    NsNum = (S * ?NS + N) * P1 * 4800 + DR * 86400 * ?NS,       %% 纳秒 = NsNum / (Q·4800)
    norm_dur(MoI, DI, NsNum div DDen).

%% 数 → 精确分数 {P, Q}（浮点取最短十进制表示：0.1 → 1/10）。
frac(X) when is_integer(X) -> {X, 1};
frac(X) when is_float(X) ->
    {Mant, Exp} = case string:split(float_to_list(X, [short]), "e") of
                      [M] -> {M, 0};
                      [M, E] -> {M, list_to_integer(E)}
                  end,
    {IntS, FracS} = case string:split(Mant, ".") of [I] -> {I, ""}; [I, F] -> {I, F} end,
    Num = list_to_integer(IntS ++ FracS),
    E2 = Exp - length(FracS),
    case E2 >= 0 of
        true -> {Num * pow10(E2), 1};
        false -> {Num, pow10(-E2)}
    end.

pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

mismatch(Op) -> throw({exec_error, bitcask_cypher_error:code('TypeError', 'InvalidArgumentType',
                                                             ["type mismatch for operator ", atom_to_list(Op)])}).

%% 时间值 + Duration：先加月（日期截到月底），再加天，再加秒 / 纳秒（满一天进位）；没有日期的
%% 时间类型只加秒部分（按一天取模）。
%% 命名时区：月 / 天在本地日历上加（偏移按时区重新解析），秒部分加在时刻上再换回本地。
add({datetime, D, Ns, O, Z}, {duration, Mo, Dd, S, N}) ->
    {datetime, D1, N1, O1} = add({datetime, D, Ns, O}, {duration, Mo, Dd, 0, 0}),
    {datetime, D2, N2, O2, Z} = zoned(D1, N1, O1, Z),
    UtcNs = (gdays(D2) - ?EPOCH_DAYS) * ?NS_DAY + N2 - O2 * ?NS + S * ?NS + N,
    in_zone(UtcNs, Z);
add(T, {duration, Mo, Dd, S, N}) ->
    #{date := D, ns := Ns0, off := O} = parts(T),
    Ns = case Ns0 of undefined -> 0; _ -> Ns0 end,
    Total = Ns + S * ?NS + N,
    case D of
        undefined ->
            rebuild(T, #{date => undefined, ns => mod(Total, ?NS_DAY), off => O});
        {Y, M, Day} ->
            Mi = Y * 12 + (M - 1) + Mo,
            Y2 = floor_div(Mi, 12), M2 = Mi - Y2 * 12 + 1,
            abs(Y2) =< ?MAX_YEAR orelse err("date out of range"),
            Day2 = min(Day, last_day(Y2, M2)),
            case Ns0 of
                undefined ->
                    %% Date：Duration 的秒分量只取整天数（向零取整），不满一天的丢掉
                    DurNs = S * ?NS + N,
                    rebuild(T, #{date => gdate(gdays({Y2, M2, Day2}) + Dd + DurNs div ?NS_DAY), ns => undefined, off => O});
                _ ->
                    Carry = floor_div(Total, ?NS_DAY),
                    Date2 = gdate(gdays({Y2, M2, Day2}) + Dd + Carry),
                    rebuild(T, #{date => Date2, ns => Total - Carry * ?NS_DAY, off => O})
            end
    end.

rebuild(T, P) -> compose(element(1, T), P).

%% ---- 比较 ------------------------------------------------------------------

%% 同类型才可比：DateTime / Time 按时刻；Duration 与 Point 只有相等。
eq(A, B) ->
    case {element(1, A), element(1, B)} of
        {duration, duration} -> A =:= B;
        {point, point} ->
            tuple_size(A) =:= tuple_size(B) andalso element(2, A) =:= element(2, B)
                andalso lists:all(fun(I) -> element(I, A) == element(I, B) end, lists:seq(3, tuple_size(A)));
        {T, T} -> instant(A) =:= instant(B);
        _ -> false
    end.

compare(A, B) ->
    case {element(1, A), element(1, B)} of
        {T, T} when T =/= duration, T =/= point ->
            case is_value(A) andalso is_value(B) of
                true -> cmp3(instant(A), instant(B));
                false -> null
            end;
        _ -> null
    end.

cmp3(A, B) when A < B -> lt;
cmp3(A, B) when A > B -> gt;
cmp3(_, _) -> eq.

instant({date, D}) -> gdays(D);
instant({localtime, N}) -> N;
instant({time, N, O}) -> N - O * ?NS;
instant({localdatetime, D, N}) -> gdays(D) * ?NS_DAY + N;
instant({datetime, D, N, O}) -> gdays(D) * ?NS_DAY + N - O * ?NS;
instant({datetime, D, N, O, _Z}) -> gdays(D) * ?NS_DAY + N - O * ?NS.

%% ORDER BY 的全序位置（Neo4j 5）：… 路径(5) < Point < DateTime < LocalDateTime < Date < Time <
%% LocalTime < Duration < 字符串(6) …
order_key({point, Srid, X, Y}) -> {5.1, {Srid, X, Y, 0}};
order_key({point, Srid, X, Y, Z}) -> {5.1, {Srid, X, Y, Z}};
order_key({datetime, _, _, _} = V) -> {5.2, instant(V)};
order_key({datetime, _, _, _, _} = V) -> {5.2, instant(V)};
order_key({localdatetime, _, _} = V) -> {5.3, instant(V)};
order_key({date, _} = V) -> {5.4, instant(V)};
order_key({time, _, _} = V) -> {5.5, instant(V)};
order_key({localtime, _} = V) -> {5.6, instant(V)};
order_key({duration, Mo, D, S, N}) -> {5.7, {Mo, D, S, N}};
order_key(V) -> {0, V}.

%% ---- 访问 ------------------------------------------------------------------

field({point, Srid, X, Y}, K) -> point_field(Srid, X, Y, null, K);
field({point, Srid, X, Y, Z}, K) -> point_field(Srid, X, Y, Z, K);
field({duration, Mo, D, S, N}, K) -> dur_field(Mo, D, S, N, K);
field(V, K) ->
    case is_value(V) of
        true -> temporal_field(V, K);
        false -> throw({exec_error, bitcask_cypher_error:code('TypeError', 'InvalidArgumentType',
                                                              ["cannot read property ", K, " of a non-node value"])})
    end.

temporal_field(V, K) ->
    #{date := D, ns := N, off := O} = parts(V),
    case date_field(D, K) of
        nofield ->
            case time_field(N, K) of
                nofield ->
                    case offset_field(V, O, K) of
                        nofield -> null;
                        X -> X
                    end;
                X -> X
            end;
        X -> X
    end.

date_field(undefined, _) -> nofield;
date_field({Y, M, D} = Date, K) ->
    case K of
        <<"year">> -> Y;
        <<"quarter">> -> (M - 1) div 3 + 1;
        <<"month">> -> M;
        <<"day">> -> D;
        <<"week">> -> element(2, iso_week(Date));
        <<"weekYear">> -> element(1, iso_week(Date));
        <<"dayOfWeek">> -> dow(Date);
        <<"weekDay">> -> dow(Date);
        <<"ordinalDay">> -> gdays(Date) - gdays({Y, 1, 1}) + 1;
        <<"dayOfQuarter">> -> gdays(Date) - gdays({Y, ((M - 1) div 3) * 3 + 1, 1}) + 1;
        _ -> nofield
    end.

iso_week({Y, _, _} = Date) ->
    Days = gdays(Date),
    WY = case Days >= week1_monday(Y + 1) of
             true -> Y + 1;
             false -> case Days < week1_monday(Y) of true -> Y - 1; false -> Y end
         end,
    {WY, (Days - week1_monday(WY)) div 7 + 1}.

time_field(undefined, _) -> nofield;
time_field(N, K) ->
    case K of
        <<"hour">> -> N div (3600 * ?NS);
        <<"minute">> -> (N div (60 * ?NS)) rem 60;
        <<"second">> -> (N div ?NS) rem 60;
        <<"millisecond">> -> (N rem ?NS) div 1000000;
        <<"microsecond">> -> (N rem ?NS) div 1000;
        <<"nanosecond">> -> N rem ?NS;
        _ -> nofield
    end.

offset_field(_V, undefined, _) -> nofield;
offset_field(V, O, K) ->
    case K of
        <<"timezone">> when tuple_size(V) =:= 5 -> element(5, V);     %% 命名时区：时区名
        <<"timezone">> -> offset_text(O);
        <<"offset">> -> offset_text(O);
        <<"offsetMinutes">> -> O div 60;
        <<"offsetSeconds">> -> O;
        <<"epochSeconds">> when element(1, V) =:= datetime -> floor_div(epoch_ns(V), ?NS);
        <<"epochMillis">> when element(1, V) =:= datetime -> floor_div(epoch_ns(V), 1000000);
        _ -> nofield
    end.

epoch_ns({datetime, D, N, O}) -> (gdays(D) - ?EPOCH_DAYS) * ?NS_DAY + N - O * ?NS;
epoch_ns({datetime, D, N, O, _}) -> (gdays(D) - ?EPOCH_DAYS) * ?NS_DAY + N - O * ?NS.

dur_field(Mo, D, S, N, K) ->
    case K of
        <<"years">> -> Mo div 12;
        <<"quarters">> -> Mo div 3;
        <<"months">> -> Mo;
        <<"weeks">> -> D div 7;
        <<"days">> -> D;
        <<"hours">> -> S div 3600;
        <<"minutes">> -> S div 60;
        <<"seconds">> -> S;
        <<"milliseconds">> -> S * 1000 + N div 1000000;
        <<"microseconds">> -> S * 1000000 + N div 1000;
        <<"nanoseconds">> -> S * ?NS + N;
        <<"quartersOfYear">> -> (Mo rem 12) div 3;
        <<"monthsOfQuarter">> -> Mo rem 3;
        <<"monthsOfYear">> -> Mo rem 12;
        <<"daysOfWeek">> -> D rem 7;
        <<"minutesOfHour">> -> (S div 60) rem 60;
        <<"secondsOfMinute">> -> S rem 60;
        <<"millisecondsOfSecond">> -> N div 1000000;
        <<"microsecondsOfSecond">> -> N div 1000;
        <<"nanosecondsOfSecond">> -> N;
        _ -> null
    end.

point_field(Srid, X, Y, Z, K) ->
    Geo = Srid =:= 4326 orelse Srid =:= 4979,
    case K of
        <<"x">> -> X;
        <<"y">> -> Y;
        <<"z">> -> Z;
        <<"longitude">> when Geo -> X;
        <<"latitude">> when Geo -> Y;
        <<"height">> when Geo -> Z;
        <<"srid">> -> Srid;
        <<"crs">> -> crs_name(Srid);
        _ -> null
    end.

%% ---- truncate / between ----------------------------------------------------

truncate(Type, Unit0, V) ->
    is_value(V) andalso element(1, V) =/= duration andalso element(1, V) =/= point orelse
        err("truncate needs a temporal value"),
    Unit = string:lowercase(Unit0),
    #{date := D, ns := N, off := O} = Parts = parts(V),
    D2 = case {D, Unit} of
             {undefined, _} -> undefined;
             {{Y, _, _}, <<"millennium">>} -> {(Y div 1000) * 1000, 1, 1};
             {{Y, _, _}, <<"century">>} -> {(Y div 100) * 100, 1, 1};
             {{Y, _, _}, <<"decade">>} -> {(Y div 10) * 10, 1, 1};
             {{Y, _, _}, <<"year">>} -> {Y, 1, 1};
             {_, <<"weekyear">>} -> {WY, _} = iso_week(D), gdate(week1_monday(WY));
             {{Y, M, _}, <<"quarter">>} -> {Y, ((M - 1) div 3) * 3 + 1, 1};
             {{Y, M, _}, <<"month">>} -> {Y, M, 1};
             {_, <<"week">>} -> gdate(gdays(D) - dow(D) + 1);
             _ -> D
         end,
    DateUnits = [<<"millennium">>, <<"century">>, <<"decade">>, <<"year">>, <<"weekyear">>, <<"quarter">>,
                 <<"month">>, <<"week">>, <<"day">>],
    Unit2 = case lists:member(Unit, DateUnits ++ [<<"hour">>, <<"minute">>, <<"second">>, <<"millisecond">>,
                                                   <<"microsecond">>]) of
                true -> Unit;
                false -> err(["unknown truncation unit: ", Unit0])
            end,
    N2 = case {N, lists:member(Unit2, DateUnits), Unit2} of
             {undefined, _, _} -> undefined;
             {_, true, _} -> 0;
             {_, _, <<"hour">>} -> N - N rem (3600 * ?NS);
             {_, _, <<"minute">>} -> N - N rem (60 * ?NS);
             {_, _, <<"second">>} -> N - N rem ?NS;
             {_, _, <<"millisecond">>} -> N - N rem 1000000;
             {_, _, <<"microsecond">>} -> N - N rem 1000
         end,
    (D =:= undefined andalso lists:member(Unit2, DateUnits) andalso Unit2 =/= <<"day">>) andalso
        err(["can't truncate a time to ", Unit0]),
    compose(Type, #{date => D2, ns => N2, off => O, zone => maps:get(zone, Parts)}).

%% duration.between(a, b) / inMonths / inDays / inSeconds。两边都有偏移时先换到 UTC；有一边
%% 没有日期就只比时刻（秒部分）。
between(_Kind, null, _) -> null;
between(_Kind, _, null) -> null;
between(Kind, A, B) ->
    (is_value(A) andalso is_value(B)) orelse err("duration.between needs two temporal values"),
    PA0 = parts(A), PB0 = parts(B),
    PA1 = in_other_zone(PA0, PB0), PB1 = in_other_zone(PB0, PA0),
    PA = utc(PA1, PB1), PB = utc(PB1, PA1),
    case {maps:get(date, PA), maps:get(date, PB)} of
        {DA, DB} when DA =:= undefined; DB =:= undefined ->
            Diff = ns0(PB) - ns0(PA),
            case Kind of
                months -> norm_dur(0, 0, 0);
                days -> norm_dur(0, 0, 0);
                _ -> norm_dur(0, 0, Diff)
            end;
        {DA, DB} ->
            NA = ns0(PA), NB = ns0(PB),
            Total = (gdays(DB) - gdays(DA)) * ?NS_DAY + NB - NA,
            case Kind of
                seconds -> norm_dur(0, 0, Total);
                days -> norm_dur(0, Total div ?NS_DAY, 0);
                _ ->
                    {YA, MA, _} = DA, {YB, MB, _} = DB,
                    Mo0 = (YB * 12 + MB) - (YA * 12 + MA),
                    Mo = adjust_months(Mo0, DA, NA, DB, NB),
                    {localdatetime, DM, NM} = add({localdatetime, DA, NA}, {duration, Mo, 0, 0, 0}),
                    Rest = (gdays(DB) - gdays(DM)) * ?NS_DAY + NB - NM,
                    case Kind of
                        months -> norm_dur(Mo, 0, 0);
                        all -> norm_dur(Mo, Rest div ?NS_DAY, Rest rem ?NS_DAY)
                    end
            end
    end.

adjust_months(Mo, DA, NA, DB, NB) ->
    {localdatetime, DM, NM} = add({localdatetime, DA, NA}, {duration, Mo, 0, 0, 0}),
    Over = (gdays(DM) - gdays(DB)) * ?NS_DAY + NM - NB,
    if
        Mo > 0, Over > 0 -> adjust_months(Mo - 1, DA, NA, DB, NB);
        Mo < 0, Over < 0 -> adjust_months(Mo + 1, DA, NA, DB, NB);
        true -> Mo
    end.

%% 一边是命名时区的 DateTime、另一边没有偏移：没有偏移的那边按同一时区解释（没有日期就用对方的日期）
%% ——夏令时切换那天 00:00 到 04:00 是 5 小时。
in_other_zone(#{off := undefined} = P, #{zone := Z, date := OD}) when is_binary(Z) ->
    D = case maps:get(date, P) of undefined -> OD; D0 -> D0 end,
    N = case maps:get(ns, P) of undefined -> 0; N0 -> N0 end,
    {datetime, D2, N2, O2, Z} = zoned(D, N, undefined, Z),
    P#{date := D2, ns := N2, off := O2, zone := Z};
in_other_zone(P, _) -> P.

ns0(#{ns := undefined}) -> 0;
ns0(#{ns := N}) -> N.

%% 两边都有偏移：把这一边换成 UTC 的日期 + 时刻。
utc(#{off := O} = P, #{off := O2}) when is_integer(O), is_integer(O2) ->
    case P of
        #{date := undefined, ns := N} -> P#{ns := mod(N - O * ?NS, ?NS_DAY), off := 0};
        #{date := D, ns := N0} ->
            N = case N0 of undefined -> 0; _ -> N0 end,
            T = gdays(D) * ?NS_DAY + N - O * ?NS,
            Days = floor_div(T, ?NS_DAY),
            P#{date := gdate(Days), ns := T - Days * ?NS_DAY, off := 0}
    end;
utc(P, _) -> P.

%% ---- Point -----------------------------------------------------------------

point(M) when is_map(M) ->
    G = fun(K) -> case maps:find(K, M) of
                      {ok, V} when is_number(V) -> V;
                      {ok, null} -> undefined;
                      {ok, _} -> err("point coordinate `~s` must be a number", [K]);
                      error -> undefined
                  end end,
    Crs = case maps:find(<<"crs">>, M) of
              {ok, C} when is_binary(C) -> string:lowercase(C);
              _ -> undefined
          end,
    SridIn = case maps:find(<<"srid">>, M) of
                 {ok, S} when is_integer(S) -> S;
                 _ -> undefined
             end,
    {X, Y, Z, Geo} =
        case {G(<<"longitude">>), G(<<"latitude">>)} of
            {Lon, Lat} when Lon =/= undefined, Lat =/= undefined -> {Lon, Lat, G(<<"height">>), true};
            _ ->
                case {G(<<"x">>), G(<<"y">>)} of
                    {X0, Y0} when X0 =/= undefined, Y0 =/= undefined ->
                        {X0, Y0, G(<<"z">>), lists:member(Crs, [<<"wgs-84">>, <<"wgs-84-3d">>])
                                                 orelse lists:member(SridIn, [4326, 4979])};
                    _ -> err("point() needs x and y, or longitude and latitude")
                end
        end,
    Srid = case {Geo, Z} of
               {true, undefined} -> 4326;
               {true, _} -> 4979;
               {false, undefined} -> 7203;
               {false, _} -> 9157
           end,
    (SridIn =:= undefined orelse SridIn =:= Srid) orelse err("srid ~b doesn't match the coordinates", [SridIn]),
    case Z of
        undefined -> {point, Srid, float(X), float(Y)};
        _ -> {point, Srid, float(X), float(Y), float(Z)}
    end;
point(null) -> null;
point({point, _, _, _} = P) -> P;
point({point, _, _, _, _} = P) -> P;
point(_) -> err("point() needs a map").

crs_name(7203) -> <<"cartesian">>;
crs_name(9157) -> <<"cartesian-3d">>;
crs_name(4326) -> <<"wgs-84">>;
crs_name(4979) -> <<"wgs-84-3d">>;
crs_name(_) -> null.

%% 同一坐标系才有距离：笛卡尔是欧氏距离，WGS-84 是大圆距离（米，3D 再计入高度差）。
distance(A, B) when element(1, A) =:= point, element(1, B) =:= point, element(2, A) =:= element(2, B) ->
    case element(2, A) of
        S when S =:= 7203; S =:= 9157 ->
            math:sqrt(lists:sum([(element(I, A) - element(I, B)) * (element(I, A) - element(I, B))
                                 || I <- lists:seq(3, tuple_size(A))]));
        _ ->
            Lon1 = rad(element(3, A)), Lat1 = rad(element(4, A)),
            Lon2 = rad(element(3, B)), Lat2 = rad(element(4, B)),
            H = math:pow(math:sin((Lat2 - Lat1) / 2), 2)
                + math:cos(Lat1) * math:cos(Lat2) * math:pow(math:sin((Lon2 - Lon1) / 2), 2),
            D = 2 * ?EARTH_RADIUS * math:asin(min(1.0, math:sqrt(H))),
            case tuple_size(A) of
                5 -> math:sqrt(D * D + math:pow(element(5, A) - element(5, B), 2));
                _ -> D
            end
    end;
distance(A, B) when element(1, A) =:= point, element(1, B) =:= point -> null;
distance(_, _) -> err("point.distance needs two points").

rad(D) -> D * math:pi() / 180.

within_bbox(P, LL, UR) when element(1, P) =:= point, element(1, LL) =:= point, element(1, UR) =:= point ->
    case element(2, P) =:= element(2, LL) andalso element(2, P) =:= element(2, UR) of
        false -> null;
        true ->
            {X, Y} = {element(3, P), element(4, P)},
            {X1, Y1} = {element(3, LL), element(4, LL)},
            {X2, Y2} = {element(3, UR), element(4, UR)},
            InX = case element(2, P) of
                      S when (S =:= 4326 orelse S =:= 4979), X1 > X2 -> X >= X1 orelse X =< X2;   %% 跨日界线
                      _ -> X >= X1 andalso X =< X2
                  end,
            InX andalso Y >= Y1 andalso Y =< Y2
    end;
within_bbox(_, _, _) -> err("point.withinBBox needs three points").

%% ---- 文本 ------------------------------------------------------------------

format({point, Srid, X, Y}) ->
    iolist_to_binary(["point({srid: ", integer_to_list(Srid), ", x: ", num(X), ", y: ", num(Y), "})"]);
format({point, Srid, X, Y, Z}) ->
    iolist_to_binary(["point({srid: ", integer_to_list(Srid), ", x: ", num(X), ", y: ", num(Y),
                      ", z: ", num(Z), "})"]);
format(V) -> to_text(V).

to_text({date, D}) -> date_text(D);
to_text({localtime, N}) -> time_text(N);
to_text({time, N, O}) -> <<(time_text(N))/binary, (offset_text(O))/binary>>;
to_text({localdatetime, D, N}) -> <<(date_text(D))/binary, "T", (time_text(N))/binary>>;
to_text({datetime, D, N, O}) -> <<(date_text(D))/binary, "T", (time_text(N))/binary, (offset_text(O))/binary>>;
to_text({datetime, D, N, O, Z}) ->
    <<(date_text(D))/binary, "T", (time_text(N))/binary, (offset_text(O))/binary, "[", Z/binary, "]">>;
to_text({duration, Mo, D, S, N}) -> dur_text(Mo, D, S, N);
to_text({point, Srid, X, Y}) -> iolist_to_binary([integer_to_list(Srid), ";", num(X), ";", num(Y)]);
to_text({point, Srid, X, Y, Z}) -> iolist_to_binary([integer_to_list(Srid), ";", num(X), ";", num(Y), ";", num(Z)]).

from_text(<<"point">>, T) ->
    case binary:split(T, <<";">>, [global]) of
        [S, X, Y] -> {point, binary_to_integer(S), bin_num(X), bin_num(Y)};
        [S, X, Y, Z] -> {point, binary_to_integer(S), bin_num(X), bin_num(Y), bin_num(Z)}
    end;
from_text(<<"duration">>, T) -> parse_duration(T);
from_text(Tag, T) -> parse(binary_to_existing_atom(Tag), T).

bin_num(B) ->
    try binary_to_float(B)
    catch error:badarg -> float(binary_to_integer(B))
    end.

num(X) when is_integer(X) -> integer_to_list(X);
num(X) -> float_to_list(X, [short]).

date_text({Y, M, D}) ->
    %% ISO 8601 / java.time：超过 4 位的年份带 +，负年份带 -、至少 4 位（-0001）
    YS = if Y > 9999 -> io_lib:format("+~b", [Y]);
            Y < 0 -> ["-", string:pad(integer_to_list(-Y), 4, leading, $0)];
            true -> io_lib:format("~4..0b", [Y]) end,
    iolist_to_binary([YS, io_lib:format("-~2..0b-~2..0b", [M, D])]).

time_text(N) ->
    S = N div ?NS, F = N rem ?NS,
    %% 秒与小数部分都是 0 时只写到分（openCypher / Neo4j：12:00、12:31:14、12:31:14.5）
    Base = case S rem 60 =:= 0 andalso F =:= 0 of
               true -> io_lib:format("~2..0b:~2..0b", [S div 3600, (S div 60) rem 60]);
               false -> io_lib:format("~2..0b:~2..0b:~2..0b", [S div 3600, (S div 60) rem 60, S rem 60])
           end,
    Frac = case F of
               0 -> "";
               _ -> [$. | string:trim(io_lib:format("~9..0b", [F]), trailing, "0")]
           end,
    iolist_to_binary([Base, Frac]).

offset_text(0) -> <<"Z">>;
offset_text(O) ->
    Sign = case O < 0 of true -> "-"; false -> "+" end,
    A = abs(O),
    H = A div 3600, M = (A div 60) rem 60, S = A rem 60,
    iolist_to_binary([Sign, io_lib:format("~2..0b:~2..0b", [H, M]),
                      case S of 0 -> ""; _ -> io_lib:format(":~2..0b", [S]) end]).

%% P1Y2M3DT4H5M6.5S；全零是 PT0S。秒的小数部分保留到纳秒、去掉尾零。
dur_text(0, 0, 0, 0) -> <<"PT0S">>;
dur_text(Mo, D, S, N) ->
    Y = Mo div 12, M = Mo rem 12,
    TotalNs = S * ?NS + N,
    Neg = TotalNs < 0,
    A = abs(TotalNs),
    H = A div (3600 * ?NS), Mi = (A div (60 * ?NS)) rem 60, Sec = (A div ?NS) rem 60, F = A rem ?NS,
    Sg = fun(V) -> case Neg of true -> -V; false -> V end end,
    DatePart = [[integer_to_list(Y), "Y"] || Y =/= 0] ++ [[integer_to_list(M), "M"] || M =/= 0]
        ++ [[integer_to_list(D), "D"] || D =/= 0],
    SecText = case F of
                  0 -> integer_to_list(Sg(Sec));
                  _ -> [case Neg of true -> "-"; false -> "" end, integer_to_list(Sec), ".",
                        string:trim(io_lib:format("~9..0b", [F]), trailing, "0")]
              end,
    TimePart = [[integer_to_list(Sg(H)), "H"] || H =/= 0] ++ [[integer_to_list(Sg(Mi)), "M"] || Mi =/= 0]
        ++ [[SecText, "S"] || Sec =/= 0 orelse F =/= 0],
    iolist_to_binary(["P", DatePart, case TimePart of [] -> ""; _ -> ["T", TimePart] end]).

%% ---- 小工具 ----------------------------------------------------------------

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

mod(A, B) -> A - floor_div(A, B) * B.
