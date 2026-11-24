%% =========================================================================
%% bitcask_cypher_ieee — Cypher 浮点的 NaN / Infinity（IEEE 754 语义）
%%
%%   Erlang 的浮点表示不了 NaN 与无穷，用三个原子代替（也是结果里的对外形态）：
%%     'NaN' | 'Infinity' | '-Infinity'
%%   这里实现它们参与的算术（含普通浮点的溢出、除以浮点 0）、比较、数学函数；规则同 Java（Neo4j）。
%% =========================================================================
-module(bitcask_cypher_ieee).

-export([is_special/1, is_num/1, arith/3, neg/1, compare/2, order_rank/1, math1/2, text/1, parse/1, to_float/1]).

-define(INF, 'Infinity').
-define(NINF, '-Infinity').
-define(NAN, 'NaN').

is_special(X) -> X =:= ?NAN orelse X =:= ?INF orelse X =:= ?NINF.

%% 数值（含 NaN / 无穷）。
is_num(X) -> is_number(X) orelse is_special(X).

%% ---- 扩展表示 ----------------------------------------------------------------
x(N) when is_number(N) -> {f, float(N)};
x(?INF) -> inf;
x(?NINF) -> ninf;
x(?NAN) -> nan.

v({f, F}) -> F;
v(inf) -> ?INF;
v(ninf) -> ?NINF;
v(nan) -> ?NAN.

sgn({f, F}) when F > 0 -> 1;
sgn({f, F}) when F < 0 -> -1;
sgn({f, _}) -> 0;
sgn(inf) -> 1;
sgn(ninf) -> -1.

inf(S) when S > 0 -> inf;
inf(_) -> ninf.

%% ---- 算术 --------------------------------------------------------------------
%% Op ∈ '+' '-' '*' '/' '%' '^'；A、B 是数值（至少一边是浮点或特殊值——整数与整数的运算不走这里）。
arith(Op, A, B) -> v(ar(Op, x(A), x(B))).

ar('^', _, {f, Z}) when Z == 0 -> {f, 1.0};                          %% Java：pow(NaN, 0) = 1.0
ar(_, nan, _) -> nan;
ar(_, _, nan) -> nan;
ar('+', inf, ninf) -> nan;
ar('+', ninf, inf) -> nan;
ar('+', X, _) when X =:= inf; X =:= ninf -> X;
ar('+', _, Y) when Y =:= inf; Y =:= ninf -> Y;
ar('+', {f, A}, {f, B}) -> safe(fun() -> A + B end, fun() -> inf(sgn({f, A})) end);
ar('-', X, Y) -> ar('+', X, xneg(Y));
ar('*', X, Y) when X =:= inf; X =:= ninf; Y =:= inf; Y =:= ninf ->
    case sgn(X) * sgn(Y) of 0 -> nan; S -> inf(S) end;
ar('*', {f, A}, {f, B}) -> safe(fun() -> A * B end, fun() -> inf(sgn({f, A}) * sgn({f, B})) end);
ar('/', X, Y) when (X =:= inf orelse X =:= ninf), (Y =:= inf orelse Y =:= ninf) -> nan;
ar('/', X, Y) when X =:= inf; X =:= ninf ->
    case sgn(Y) of 0 -> X; S -> inf(sgn(X) * S) end;
ar('/', {f, _}, Y) when Y =:= inf; Y =:= ninf -> {f, 0.0};
ar('/', {f, A}, {f, B}) when B == 0 ->
    case sgn({f, A}) of 0 -> nan; S -> inf(S) end;
ar('/', {f, A}, {f, B}) -> safe(fun() -> A / B end, fun() -> inf(sgn({f, A}) * sgn({f, B})) end);
ar('%', X, _) when X =:= inf; X =:= ninf -> nan;
ar('%', {f, _}, {f, B}) when B == 0 -> nan;
ar('%', {f, A}, Y) when Y =:= inf; Y =:= ninf -> {f, A};
ar('%', {f, A}, {f, B}) -> {f, math:fmod(A, B)};
ar('^', X, Y) -> pow(X, Y).

%% Java Math.pow 的规则（Neo4j 用它）
pow({f, 1.0}, Y) when Y =:= inf; Y =:= ninf -> nan;
pow({f, -1.0}, Y) when Y =:= inf; Y =:= ninf -> nan;
pow({f, A}, inf) -> case abs(A) > 1 of true -> inf; false -> {f, 0.0} end;
pow({f, A}, ninf) -> case abs(A) > 1 of true -> {f, 0.0}; false -> inf end;
pow(inf, {f, B}) -> case B > 0 of true -> inf; false -> {f, 0.0} end;
pow(ninf, {f, B}) ->
    case {B > 0, odd_int(B)} of
        {true, true} -> ninf;
        {true, false} -> inf;
        {false, _} -> {f, 0.0}
    end;
pow(X, Y) when (X =:= inf orelse X =:= ninf), (Y =:= inf orelse Y =:= ninf) ->
    case Y of inf -> inf; ninf -> {f, 0.0} end;
pow({f, A}, {f, B}) when A < 0, B /= trunc(B) -> nan;
pow({f, A}, {f, B}) when A == 0, B < 0 -> inf;
pow({f, A}, {f, B}) ->
    safe(fun() -> math:pow(A, B) end,
         fun() -> case A < 0 andalso odd_int(B) of true -> ninf; false -> inf end end).

odd_int(B) -> B == trunc(B) andalso abs(trunc(B)) rem 2 =:= 1.

safe(F, Overflow) ->
    try {f, F()}
    catch error:badarith -> Overflow()
    end.

xneg({f, F}) -> {f, -F};
xneg(inf) -> ninf;
xneg(ninf) -> inf;
xneg(nan) -> nan.

neg(X) -> v(xneg(x(X))).

%% ---- 比较 --------------------------------------------------------------------
%% lt | eq | gt | unordered（NaN 与任何数值都不可比：< <= > >= 全为 false）。
compare(A, B) when A =:= ?NAN; B =:= ?NAN -> unordered;
compare(A, B) ->
    case {order_rank(A), order_rank(B)} of
        {R, R} when R =/= 1 -> eq;
        {RA, RB} when RA < RB -> lt;
        {RA, RB} when RA > RB -> gt;
        _ -> case A < B of true -> lt; false -> case A > B of true -> gt; false -> eq end end
    end.

%% ORDER BY 里数值内部的次序：-Infinity < 有限数 < Infinity < NaN（NaN 排在全部数值之后、null 之前）。
order_rank(?NINF) -> 0;
order_rank(?INF) -> 2;
order_rank(?NAN) -> 3;
order_rank(_) -> 1.

%% ---- 一元数学函数 ------------------------------------------------------------
%% math1(Name, X)：X 是数值（含特殊值）；结果按 Java Math 的规则。
math1(_, ?NAN) -> ?NAN;
math1(F, X) when X =:= ?INF; X =:= ?NINF -> math_inf(F, X);
math1(F, N) -> math_fin(F, float(N)).

math_inf(F, X) when F =:= <<"abs">> -> case X of ?INF -> ?INF; ?NINF -> ?INF end;
math_inf(F, X) when F =:= <<"ceil">>; F =:= <<"floor">>; F =:= <<"round">>; F =:= <<"degrees">>;
                    F =:= <<"radians">> -> X;
math_inf(<<"sqrt">>, ?INF) -> ?INF;
math_inf(<<"exp">>, ?INF) -> ?INF;
math_inf(<<"exp">>, ?NINF) -> 0.0;
math_inf(F, ?INF) when F =:= <<"log">>; F =:= <<"log10">> -> ?INF;
math_inf(<<"atan">>, ?INF) -> math:pi() / 2;
math_inf(<<"atan">>, ?NINF) -> -math:pi() / 2;
math_inf(_, _) -> ?NAN.                                     %% sin / cos / tan / sqrt(-∞) / log(-∞) …

math_fin(<<"sqrt">>, N) when N < 0 -> ?NAN;
math_fin(<<"sqrt">>, N) -> math:sqrt(N);
math_fin(F, N) when F =:= <<"log">>; F =:= <<"log10">> ->
    if
        N == 0 -> ?NINF;
        N < 0 -> ?NAN;
        F =:= <<"log">> -> math:log(N);
        true -> math:log10(N)
    end;
math_fin(<<"exp">>, N) -> safe_v(fun() -> math:exp(N) end, ?INF);
math_fin(F, N) when F =:= <<"asin">>; F =:= <<"acos">> ->
    case N >= -1 andalso N =< 1 of
        false -> ?NAN;
        true when F =:= <<"asin">> -> math:asin(N);
        true -> math:acos(N)
    end;
math_fin(<<"cot">>, N) ->
    T = math:tan(N),
    case T == 0 of
        true -> case N >= 0 of true -> ?INF; false -> ?NINF end;
        false -> 1 / T
    end.

safe_v(F, Overflow) ->
    try F() catch error:badarith -> Overflow end.

%% ---- 文本 --------------------------------------------------------------------
text(?NAN) -> <<"NaN">>;
text(?INF) -> <<"Infinity">>;
text(?NINF) -> <<"-Infinity">>.

%% toFloat 认的特殊值写法（同 Java Double.parseDouble）。
parse("NaN") -> ?NAN;
parse("Infinity") -> ?INF;
parse("+Infinity") -> ?INF;
parse("-Infinity") -> ?NINF;
parse(_) -> undefined.

%% 存储里的文本 → 值（与 text/1 互逆，普通浮点照常解析）。
to_float(<<"NaN">>) -> ?NAN;
to_float(<<"Infinity">>) -> ?INF;
to_float(<<"-Infinity">>) -> ?NINF;
to_float(B) -> binary_to_float(B).
