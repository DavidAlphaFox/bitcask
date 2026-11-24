%% =========================================================================
%% bitcask_cypher_tz — 命名时区（IANA，读系统 zoneinfo 的 TZif 文件）
%%
%%   目录：应用环境 bitcask_cypher.tz_dir > 环境变量 TZDIR > /usr/share/zoneinfo。
%%   backzone：有的发行版（Debian 等）带 backzone 编 zoneinfo，被 IANA 合并掉的时区（Europe/Stockholm 等）
%%   保留各自 1970 年以前的数据；IANA 的缺省编法（也是 Java / Neo4j 用的）把它们编成指向合并目标的链接。
%%   缺省按后者解析（?MERGED 表，openCypher TCK 也按它）；应用环境 bitcask_cypher.tz_backzone = true 时照用本机文件。
%%   时区名照旧显示用户写的那个（同 java.time 的 ZoneId）。
%%   TZif v1 / v2+（RFC 8536）：转换时刻表 + 文件尾的 POSIX TZ 规则（精简格式的 zoneinfo 只存到最后一次
%%   规则变化，之后的年份全靠这条规则）。解析结果按时区名缓存在 persistent_term。
%%
%%   offset_at_utc(Zone, UtcSeconds)          -> 偏移秒
%%   resolve_local(Zone, LocalSeconds, Pref)   -> {LocalSeconds2, 偏移秒}
%%       本地时刻在时区里的偏移：落在重叠段（秋季回拨）时优先用 Pref（若有效），否则用较早的那个
%%       （夏令时偏移）；落在空隙（春季拨快）时把本地时刻往后挪空隙那么长（java.time 的规则）。
%% =========================================================================
-module(bitcask_cypher_tz).

-export([is_zone_name/1, exists/1, offset_at_utc/2, resolve_local/3]).

-define(CACHE(Z), {?MODULE, zone, Z, backzone()}).

%% IANA 缺省编法里是链接、backzone 里是独立时区的名字 → 链接目标。由 tzdata 2026b 生成：
%% backward 里的 Link 名 ∩ backzone 里定义的名字（共 142 个；Asia/Hanoi 只在 backzone 里，不在表中）。
-define(MERGED, #{
    <<"Africa/Accra">> => <<"Africa/Abidjan">>, <<"Africa/Addis_Ababa">> => <<"Africa/Nairobi">>,
    <<"Africa/Asmara">> => <<"Africa/Nairobi">>, <<"Africa/Asmera">> => <<"Africa/Nairobi">>,
    <<"Africa/Bamako">> => <<"Africa/Abidjan">>, <<"Africa/Bangui">> => <<"Africa/Lagos">>,
    <<"Africa/Banjul">> => <<"Africa/Abidjan">>, <<"Africa/Blantyre">> => <<"Africa/Maputo">>,
    <<"Africa/Brazzaville">> => <<"Africa/Lagos">>, <<"Africa/Bujumbura">> => <<"Africa/Maputo">>,
    <<"Africa/Conakry">> => <<"Africa/Abidjan">>, <<"Africa/Dakar">> => <<"Africa/Abidjan">>,
    <<"Africa/Dar_es_Salaam">> => <<"Africa/Nairobi">>, <<"Africa/Djibouti">> => <<"Africa/Nairobi">>,
    <<"Africa/Douala">> => <<"Africa/Lagos">>, <<"Africa/Freetown">> => <<"Africa/Abidjan">>,
    <<"Africa/Gaborone">> => <<"Africa/Maputo">>, <<"Africa/Harare">> => <<"Africa/Maputo">>,
    <<"Africa/Kampala">> => <<"Africa/Nairobi">>, <<"Africa/Kigali">> => <<"Africa/Maputo">>,
    <<"Africa/Kinshasa">> => <<"Africa/Lagos">>, <<"Africa/Libreville">> => <<"Africa/Lagos">>,
    <<"Africa/Lome">> => <<"Africa/Abidjan">>, <<"Africa/Luanda">> => <<"Africa/Lagos">>,
    <<"Africa/Lubumbashi">> => <<"Africa/Maputo">>, <<"Africa/Lusaka">> => <<"Africa/Maputo">>,
    <<"Africa/Malabo">> => <<"Africa/Lagos">>, <<"Africa/Maseru">> => <<"Africa/Johannesburg">>,
    <<"Africa/Mbabane">> => <<"Africa/Johannesburg">>, <<"Africa/Mogadishu">> => <<"Africa/Nairobi">>,
    <<"Africa/Niamey">> => <<"Africa/Lagos">>, <<"Africa/Nouakchott">> => <<"Africa/Abidjan">>,
    <<"Africa/Ouagadougou">> => <<"Africa/Abidjan">>, <<"Africa/Porto-Novo">> => <<"Africa/Lagos">>,
    <<"Africa/Timbuktu">> => <<"Africa/Abidjan">>, <<"America/Anguilla">> => <<"America/Puerto_Rico">>,
    <<"America/Antigua">> => <<"America/Puerto_Rico">>,
    <<"America/Argentina/ComodRivadavia">> => <<"America/Argentina/Catamarca">>,
    <<"America/Aruba">> => <<"America/Puerto_Rico">>, <<"America/Atikokan">> => <<"America/Panama">>,
    <<"America/Blanc-Sablon">> => <<"America/Puerto_Rico">>, <<"America/Cayman">> => <<"America/Panama">>,
    <<"America/Coral_Harbour">> => <<"America/Panama">>, <<"America/Creston">> => <<"America/Phoenix">>,
    <<"America/Curacao">> => <<"America/Puerto_Rico">>, <<"America/Dominica">> => <<"America/Puerto_Rico">>,
    <<"America/Ensenada">> => <<"America/Tijuana">>, <<"America/Grenada">> => <<"America/Puerto_Rico">>,
    <<"America/Guadeloupe">> => <<"America/Puerto_Rico">>, <<"America/Kralendijk">> => <<"America/Puerto_Rico">>,
    <<"America/Lower_Princes">> => <<"America/Puerto_Rico">>, <<"America/Marigot">> => <<"America/Puerto_Rico">>,
    <<"America/Montreal">> => <<"America/Toronto">>, <<"America/Montserrat">> => <<"America/Puerto_Rico">>,
    <<"America/Nassau">> => <<"America/Toronto">>, <<"America/Nipigon">> => <<"America/Toronto">>,
    <<"America/Pangnirtung">> => <<"America/Iqaluit">>, <<"America/Port_of_Spain">> => <<"America/Puerto_Rico">>,
    <<"America/Rainy_River">> => <<"America/Winnipeg">>, <<"America/Rosario">> => <<"America/Argentina/Cordoba">>,
    <<"America/St_Barthelemy">> => <<"America/Puerto_Rico">>, <<"America/St_Kitts">> => <<"America/Puerto_Rico">>,
    <<"America/St_Lucia">> => <<"America/Puerto_Rico">>, <<"America/St_Thomas">> => <<"America/Puerto_Rico">>,
    <<"America/St_Vincent">> => <<"America/Puerto_Rico">>, <<"America/Thunder_Bay">> => <<"America/Toronto">>,
    <<"America/Tortola">> => <<"America/Puerto_Rico">>, <<"America/Virgin">> => <<"America/Puerto_Rico">>,
    <<"America/Yellowknife">> => <<"America/Edmonton">>, <<"Antarctica/DumontDUrville">> => <<"Pacific/Port_Moresby">>,
    <<"Antarctica/McMurdo">> => <<"Pacific/Auckland">>, <<"Antarctica/South_Pole">> => <<"Pacific/Auckland">>,
    <<"Antarctica/Syowa">> => <<"Asia/Riyadh">>, <<"Arctic/Longyearbyen">> => <<"Europe/Berlin">>,
    <<"Asia/Aden">> => <<"Asia/Riyadh">>, <<"Asia/Bahrain">> => <<"Asia/Qatar">>, <<"Asia/Brunei">> => <<"Asia/Kuching">>,
    <<"Asia/Chongqing">> => <<"Asia/Shanghai">>, <<"Asia/Chungking">> => <<"Asia/Shanghai">>,
    <<"Asia/Harbin">> => <<"Asia/Shanghai">>, <<"Asia/Kashgar">> => <<"Asia/Urumqi">>,
    <<"Asia/Kuala_Lumpur">> => <<"Asia/Singapore">>, <<"Asia/Kuwait">> => <<"Asia/Riyadh">>,
    <<"Asia/Muscat">> => <<"Asia/Dubai">>, <<"Asia/Phnom_Penh">> => <<"Asia/Bangkok">>,
    <<"Asia/Tel_Aviv">> => <<"Asia/Jerusalem">>, <<"Asia/Vientiane">> => <<"Asia/Bangkok">>,
    <<"Atlantic/Jan_Mayen">> => <<"Europe/Berlin">>, <<"Atlantic/Reykjavik">> => <<"Africa/Abidjan">>,
    <<"Atlantic/St_Helena">> => <<"Africa/Abidjan">>, <<"Australia/Currie">> => <<"Australia/Hobart">>,
    <<"CET">> => <<"Europe/Brussels">>, <<"CST6CDT">> => <<"America/Chicago">>, <<"EET">> => <<"Europe/Athens">>,
    <<"EST">> => <<"America/Panama">>, <<"EST5EDT">> => <<"America/New_York">>,
    <<"Europe/Amsterdam">> => <<"Europe/Brussels">>, <<"Europe/Belfast">> => <<"Europe/London">>,
    <<"Europe/Copenhagen">> => <<"Europe/Berlin">>, <<"Europe/Guernsey">> => <<"Europe/London">>,
    <<"Europe/Isle_of_Man">> => <<"Europe/London">>, <<"Europe/Jersey">> => <<"Europe/London">>,
    <<"Europe/Ljubljana">> => <<"Europe/Belgrade">>, <<"Europe/Luxembourg">> => <<"Europe/Brussels">>,
    <<"Europe/Monaco">> => <<"Europe/Paris">>, <<"Europe/Oslo">> => <<"Europe/Berlin">>,
    <<"Europe/Sarajevo">> => <<"Europe/Belgrade">>, <<"Europe/Skopje">> => <<"Europe/Belgrade">>,
    <<"Europe/Stockholm">> => <<"Europe/Berlin">>, <<"Europe/Tiraspol">> => <<"Europe/Chisinau">>,
    <<"Europe/Uzhgorod">> => <<"Europe/Kyiv">>, <<"Europe/Vaduz">> => <<"Europe/Zurich">>,
    <<"Europe/Zagreb">> => <<"Europe/Belgrade">>, <<"Europe/Zaporozhye">> => <<"Europe/Kyiv">>,
    <<"HST">> => <<"Pacific/Honolulu">>, <<"Iceland">> => <<"Africa/Abidjan">>,
    <<"Indian/Antananarivo">> => <<"Africa/Nairobi">>, <<"Indian/Christmas">> => <<"Asia/Bangkok">>,
    <<"Indian/Cocos">> => <<"Asia/Yangon">>, <<"Indian/Comoro">> => <<"Africa/Nairobi">>,
    <<"Indian/Kerguelen">> => <<"Indian/Maldives">>, <<"Indian/Mahe">> => <<"Asia/Dubai">>,
    <<"Indian/Mayotte">> => <<"Africa/Nairobi">>, <<"Indian/Reunion">> => <<"Asia/Dubai">>, <<"MET">> => <<"Europe/Brussels">>,
    <<"MST">> => <<"America/Phoenix">>, <<"MST7MDT">> => <<"America/Denver">>, <<"PST8PDT">> => <<"America/Los_Angeles">>,
    <<"Pacific/Chuuk">> => <<"Pacific/Port_Moresby">>, <<"Pacific/Enderbury">> => <<"Pacific/Kanton">>,
    <<"Pacific/Funafuti">> => <<"Pacific/Tarawa">>, <<"Pacific/Johnston">> => <<"Pacific/Honolulu">>,
    <<"Pacific/Majuro">> => <<"Pacific/Tarawa">>, <<"Pacific/Midway">> => <<"Pacific/Pago_Pago">>,
    <<"Pacific/Pohnpei">> => <<"Pacific/Guadalcanal">>, <<"Pacific/Ponape">> => <<"Pacific/Guadalcanal">>,
    <<"Pacific/Saipan">> => <<"Pacific/Guam">>, <<"Pacific/Truk">> => <<"Pacific/Port_Moresby">>,
    <<"Pacific/Wake">> => <<"Pacific/Tarawa">>, <<"Pacific/Wallis">> => <<"Pacific/Tarawa">>,
    <<"Pacific/Yap">> => <<"Pacific/Port_Moresby">>, <<"WET">> => <<"Europe/Lisbon">>
}).

%% 像时区名的字符串：Area/Location（也收 UTC、Etc/GMT+1 之类）；不允许 .. 与绝对路径。
-spec is_zone_name(binary()) -> boolean().
is_zone_name(Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) < 64 ->
    re:run(Name, "^[A-Za-z][A-Za-z0-9_+\\-]*(/[A-Za-z0-9_+\\-]+)*$", [{capture, none}]) =:= match
        andalso binary:match(Name, <<"..">>) =:= nomatch;
is_zone_name(_) -> false.

-spec exists(binary()) -> boolean().
exists(Name) ->
    try load(Name) of _ -> true
    catch throw:{exec_error, _} -> false
    end.

zone_dir() ->
    case application:get_env(bitcask_cypher, tz_dir) of
        {ok, D} when D =/= undefined -> D;
        _ -> case os:getenv("TZDIR") of
                 false -> "/usr/share/zoneinfo";
                 "" -> "/usr/share/zoneinfo";
                 D -> D
             end
    end.

load(Name) ->
    case persistent_term:get(?CACHE(Name), undefined) of
        undefined ->
            is_zone_name(Name) orelse throw({exec_error, bitcask_cypher_error:code('ArgumentError', 'InvalidArgumentValue',
                                                                                   ["invalid time zone name: ", Name])}),
            File = filename:join(zone_dir(), binary_to_list(data_name(Name))),
            Z = case file:read_file(File) of
                    {ok, Bin} ->
                        try parse(Bin)
                        catch _:_ -> throw({exec_error, ["can't read time zone data for ", Name]})
                        end;
                    {error, _} -> throw({exec_error, bitcask_cypher_error:code('ArgumentError', 'InvalidArgumentValue', ["unknown time zone: ", Name,
                                                       " (looked in ", zone_dir(), ")"])})
                end,
            persistent_term:put(?CACHE(Name), Z),
            Z;
        Z -> Z
    end.

backzone() -> application:get_env(bitcask_cypher, tz_backzone, false) =:= true.

%% 读哪个时区文件：缺省把被合并的名字换成合并目标（见模块头）。
data_name(Name) ->
    case backzone() of
        true -> Name;
        false -> maps:get(Name, ?MERGED, Name)
    end.

%% ---- TZif ------------------------------------------------------------------
%% → #{trans => {{UtcSec, Off}, …}（升序）, first => Off（第一次转换之前）, rule => POSIX 规则 | none}
parse(<<"TZif", Ver, _:15/binary, _/binary>> = Bin) ->
    {Counts1, Body1} = counts(Bin),
    case Ver of
        0 -> block(Body1, Counts1, 4, none);
        _ ->
            %% 跳过 v1 数据块，读 v2 头与 64 位数据块，再读文件尾的规则
            Skip = block_size(Counts1, 4),
            <<_:Skip/binary, Rest/binary>> = Body1,
            {Counts2, Body2} = counts(Rest),
            Size2 = block_size(Counts2, 8),
            <<Block2:Size2/binary, Footer/binary>> = Body2,
            Rule = case binary:split(Footer, <<"\n">>, [global]) of
                       [<<>>, TZ | _] when TZ =/= <<>> -> posix(binary_to_list(TZ));
                       _ -> none
                   end,
            block(Block2, Counts2, 8, Rule)
    end.

counts(<<"TZif", _Ver, _:15/binary, IsUt:32, IsStd:32, Leap:32, Time:32, Type:32, Char:32, Rest/binary>>) ->
    {#{isut => IsUt, isstd => IsStd, leap => Leap, time => Time, type => Type, char => Char}, Rest}.

block_size(#{isut := U, isstd := S, leap := L, time := T, type := Ty, char := C}, W) ->
    T * W + T + Ty * 6 + C + L * (W + 4) + S + U.

block(Bin, #{time := T, type := Ty}, W, Rule) ->
    Bits = W * 8,
    TL = T * W,
    <<Times:TL/binary, Idx:T/binary, Types:(Ty * 6)/binary, _/binary>> = Bin,
    Offs = list_to_tuple([Off || <<Off:32/signed, _Dst, _Ab>> <= Types]),
    Trans = [{Tm, element(I + 1, Offs)} || {<<Tm:Bits/signed>>, I} <- lists:zip([X || <<X:W/binary>> <= Times],
                                                                          binary_to_list(Idx))],
    #{trans => list_to_tuple(Trans), first => element(1, Offs), rule => Rule}.

%% ---- 查偏移 ------------------------------------------------------------------
-spec offset_at_utc(binary(), integer()) -> integer().
offset_at_utc(Name, T) ->
    #{trans := Tr, first := First, rule := Rule} = load(Name),
    N = tuple_size(Tr),
    case N of
        0 -> case Rule of none -> First; _ -> rule_offset(Rule, T) end;
        _ ->
            case T < element(1, element(1, Tr)) of
                true -> First;
                false ->
                    I = bsearch(Tr, T, 1, N),
                    case I =:= N andalso Rule =/= none of
                        true -> rule_offset(Rule, T);              %% 最后一次转换之后：规则
                        false -> element(2, element(I, Tr))
                    end
            end
    end.

%% 最大的 i 使 Tr[i].time =< T（已知 Tr[1].time =< T）。
bsearch(_Tr, _T, Lo, Hi) when Lo >= Hi -> Lo;
bsearch(Tr, T, Lo, Hi) ->
    Mid = (Lo + Hi + 1) div 2,
    case element(1, element(Mid, Tr)) =< T of
        true -> bsearch(Tr, T, Mid, Hi);
        false -> bsearch(Tr, T, Lo, Mid - 1)
    end.

-spec resolve_local(binary(), integer(), integer() | undefined) -> {integer(), integer()}.
resolve_local(Name, L, Pref) ->
    OBefore = offset_at_utc(Name, L - 86400),
    OAfter = offset_at_utc(Name, L + 86400),
    Valid = [O || O <- lists:usort([OBefore, OAfter, offset_at_utc(Name, L)]),
                  offset_at_utc(Name, L - O) =:= O],
    case {Valid, lists:member(Pref, Valid)} of
        {_, true} -> {L, Pref};
        {[O], _} -> {L, O};
        {[_, _ | _], _} -> {L, lists:max(Valid)};               %% 重叠：较早的那个（偏移较大）
        {[], _} -> {L + (OAfter - OBefore), OAfter}              %% 空隙：往后挪
    end.

%% ---- POSIX TZ 规则（TZif 文件尾）--------------------------------------------
%% "CET-1CEST,M3.5.0,M10.5.0/3"、"EST5EDT,M3.2.0,M11.1.0"、"<+0330>-3:30"、"HST10"
posix(S0) ->
    {_Std, S1} = tz_name(S0),
    {StdOff, S2} = tz_off(S1),
    Std = -StdOff,                                               %% POSIX 的符号与 UTC 偏移相反
    case S2 of
        "" -> {fixed, Std};
        _ ->
            {_Dst, S3} = tz_name(S2),
            {Dst, S4} = case S3 of
                            [C | _] when C =:= $, -> {Std + 3600, S3};
                            "" -> {Std + 3600, S3};
                            _ -> {DO, R} = tz_off(S3), {-DO, R}
                        end,
            case S4 of
                "," ++ Rules ->
                    [StartS, EndS] = string:split(Rules, ","),
                    {dst, Std, Dst, tz_rule(StartS), tz_rule(EndS)};
                _ -> {dst, Std, Dst, tz_rule("M3.2.0"), tz_rule("M11.1.0")}
            end
    end.

tz_name("<" ++ R) -> {N, ">" ++ R2} = lists:splitwith(fun(C) -> C =/= $> end, R), {N, R2};
tz_name(S) -> lists:splitwith(fun(C) -> (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z) end, S).

%% [+-]hh[:mm[:ss]] → 秒（带符号）
tz_off(S) ->
    {Sign, S1} = case S of "-" ++ R -> {-1, R}; "+" ++ R -> {1, R}; _ -> {1, S} end,
    {Num, Rest} = lists:splitwith(fun(C) -> (C >= $0 andalso C =< $9) orelse C =:= $: end, S1),
    Parts = [list_to_integer(P) || P <- string:split(Num, ":", all)],
    Secs = case Parts of
               [H] -> H * 3600;
               [H, M] -> H * 3600 + M * 60;
               [H, M, Sec] -> H * 3600 + M * 60 + Sec
           end,
    {Sign * Secs, Rest}.

tz_rule(S) ->
    {Date, Time} = case string:split(S, "/") of
                       [D] -> {D, 7200};
                       [D, T] -> {D, element(1, tz_off(T))}
                   end,
    D2 = case Date of
             "M" ++ R -> [M, W, Dw] = [list_to_integer(X) || X <- string:split(R, ".", all)], {m, M, W, Dw};
             "J" ++ R -> {j, list_to_integer(R)};
             R -> {n, list_to_integer(R)}
         end,
    {D2, Time}.

rule_offset({fixed, Off}, _T) -> Off;
rule_offset({dst, Std, Dst, Start, End}, T) ->
    {{Y, _, _}, _} = calendar:gregorian_seconds_to_datetime(T + 62167219200 + Std),
    StartUtc = rule_local(Y, Start) - Std,
    EndUtc = rule_local(Y, End) - Dst,
    InDst = case StartUtc < EndUtc of
                true -> T >= StartUtc andalso T < EndUtc;              %% 北半球
                false -> T >= StartUtc orelse T < EndUtc               %% 南半球
            end,
    case InDst of true -> Dst; false -> Std end.

%% 规则在 Y 年给出的本地时刻（Unix 秒，按规则所在的那个偏移解释）。
rule_local(Y, {Date, Time}) ->
    Day = case Date of
              {m, M, W, Dw} ->
                  First = calendar:date_to_gregorian_days(Y, M, 1),
                  FirstDow = calendar:day_of_the_week(Y, M, 1) rem 7,          %% 0 = 周日
                  D1 = First + ((Dw - FirstDow + 7) rem 7) + (W - 1) * 7,
                  Last = First + calendar:last_day_of_the_month(Y, M) - 1,
                  case D1 > Last of true -> D1 - 7; false -> D1 end;
              {j, N} ->                                                        %% 1..365，不算 2 月 29 日
                  Base = calendar:date_to_gregorian_days(Y, 1, 1) + N - 1,
                  case calendar:is_leap_year(Y) andalso N >= 60 of true -> Base + 1; false -> Base end;
              {n, N} -> calendar:date_to_gregorian_days(Y, 1, 1) + N              %% 0..365
          end,
    (Day - 719528) * 86400 + Time.
