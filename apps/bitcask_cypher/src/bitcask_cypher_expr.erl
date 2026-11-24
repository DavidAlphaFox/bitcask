%% =========================================================================
%% bitcask_cypher_expr — 查询表达式求值与值语义（doc/cypher-query-design-zh.md 第 5、7.3 节）
%%
%% 与语法无关：输入是 bitcask_cypher_sema 规范化后的表达式（{var, N}、{prop, E, K}、
%% {call, Name, Distinct, Args}、{op, Op, A, B}……），行是 变量名 → 值 的 map。
%%
%% 运行期的值：
%%   null | true | false | integer() | float() | binary()（字符串）| [值] | #{binary() => 值}
%%   {node, Vid}                         顶点（标签 / 属性按需经 bitcask_cypher_exec 读，查询内缓存）
%%   {rel, Src, Etype, Dst, Rank, Props} 边；Props 是属性二进制，或 unknown（入边一侧不存
%%                                       属性，用到时再点查）
%%   {path, [Node], [Rel]}               路径
%%
%% 语义按 openCypher：三值逻辑（null 传播）；1 = 1.0 为真（第 14 节待定项 4）；
%% 不同类型的 = 为假、< 为 null；排序用全序（map < node < rel < list < path < string <
%% boolean < number，null 最后）。
%% =========================================================================
-module(bitcask_cypher_expr).

-define(C(T, D, M), bitcask_cypher_error:code(T, D, M)).    %% openCypher 错误类型 / 细节代码
-define(MAX_INT, 9223372036854775807).
-define(MIN_INT, -9223372036854775808).
%% 浮点的 NaN / 无穷（bitcask_cypher_ieee）
-define(SP(X), (X =:= 'NaN' orelse X =:= 'Infinity' orelse X =:= '-Infinity')).
-define(XNUM(X), (is_number(X) orelse ?SP(X))).
%% 时钟变体（transaction / statement 是语句时钟，realtime 是真实的当前时刻）
-define(CLOCK(C), (C =:= <<"transaction">> orelse C =:= <<"statement">> orelse C =:= <<"realtime">>)).

-export([eval/3, truthy/1, eq/2, compare/2, order_cmp/2, group_key/1, label_ok/2,
         agg_init/2, agg_step/3, agg_final/2, find_aggs/1, replace_aggs/2]).

%% =========================================================================
%% 求值
%% =========================================================================

eval({lit, V}, _Row, _Ctx) when is_integer(V), V > ?MAX_INT ->
    throw({exec_error, ?C('SyntaxError', 'IntegerOverflow', "integer literal is too large (integers are 64-bit)")});
eval({lit, V}, _Row, _Ctx) -> V;
eval({param, P}, _Row, #{params := Ps}) ->
    case maps:find(P, Ps) of
        {ok, V} -> V;
        error   -> throw({exec_error, ?C('ParameterMissing', 'MissingParameter', ["missing parameter $", P])})
    end;
eval({var, V}, Row, _Ctx) ->
    case maps:find(V, Row) of
        {ok, X} -> X;
        error   -> null
    end;
eval({agg_ref, I}, Row, _Ctx) -> maps:get({agg_ref, I}, Row);
eval({prop, E, K}, Row, Ctx) -> prop(eval(E, Row, Ctx), K, Ctx);
eval({has_labels, E, Ls}, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        null -> null;
        {node, _} = N ->
            Have = node_labels(N, Ctx),
            lists:all(fun(L) -> label_ok(L, Have) end, Ls);
        {rel, _, T, _, _, _} ->
            %% 关系的「标签」判断看它的类型（openCypher：r:T）
            Have = [bitcask_cypher_exec:type_name(T, Ctx)],
            lists:all(fun(L) -> label_ok(L, Have) end, Ls);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "label test on a non-node value")})
    end;
eval({list, Es}, Row, Ctx) -> [eval(E, Row, Ctx) || E <- Es];
%% 列表推导 / 量词 / reduce：局部变量绑在行上（覆盖同名的外层变量）
eval({list_comp, X, L, W, P}, Row, Ctx) ->
    case eval(L, Row, Ctx) of
        null -> null;
        Xs when is_list(Xs) ->
            [case P of undefined -> V; _ -> eval(P, Row#{X => V}, Ctx) end
             || V <- Xs, W =:= undefined orelse truthy(eval(W, Row#{X => V}, Ctx))];
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "list comprehension needs a list")})
    end;
eval({quant, K, X, L, Pred}, Row, Ctx) ->
    case eval(L, Row, Ctx) of
        null -> null;
        Xs when is_list(Xs) -> quantify(K, [eval(Pred, Row#{X => V}, Ctx) || V <- Xs]);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', [atom_to_list(K), "() needs a list"])})
    end;
eval({reduce, Acc, Init, X, L, E}, Row, Ctx) ->
    case eval(L, Row, Ctx) of
        null -> null;
        Xs when is_list(Xs) ->
            lists:foldl(fun(V, A) -> eval(E, Row#{Acc => A, X => V}, Ctx) end, eval(Init, Row, Ctx), Xs);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "reduce() needs a list")})
    end;
eval({exists, {pattern_pred, _, _} = P}, Row, Ctx) -> eval(P, Row, Ctx);
eval({exists, P}, Row, Ctx) -> eval(P, Row, Ctx) =/= null;
%% 子查询表达式
eval({subq, Kind, Inner, Outer, Col}, Row, Ctx) -> bitcask_cypher_exec:subq_eval(Kind, Inner, Outer, Col, Row, Ctx);
%% 模式谓词：以当前行为起点，子模式能匹配上至少一行
eval({pattern_pred, Part, Outer}, Row, Ctx) ->
    case bitcask_cypher_exec:pattern_rows(Part, Outer, Row, Ctx, 1) of
        null -> null;
        Rows -> Rows =/= []
    end;
%% 模式推导：子模式的每个匹配（过 WHERE）投影成一个值
eval({pattern_comp, Part, W, P, Outer}, Row, Ctx) ->
    case bitcask_cypher_exec:pattern_rows(Part, Outer, Row, Ctx, infinity) of
        null -> null;
        Rows -> [eval(P, R, Ctx) || R <- Rows, W =:= undefined orelse truthy(eval(W, R, Ctx))]
    end;
eval({map_proj, VarE, Items}, Row, Ctx) ->
    case eval(VarE, Row, Ctx) of
        null -> null;
        Base ->
            Props = fun() -> case Base of
                                 {node, _} -> node_props(Base, Ctx);
                                 {rel, _, _, _, _, _} -> bitcask_cypher_exec:rel_props(Base, Ctx);
                                 M when is_map(M) -> M;
                                 _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "map projection needs a node, relationship or map")})
                             end end,
            lists:foldl(fun({prop_sel, K}, Acc) -> Acc#{K => maps:get(K, Props(), null)};
                           (all_props, Acc) -> maps:merge(Acc, Props());
                           ({entry, K, E}, Acc) -> Acc#{K => eval(E, Row, Ctx)};
                           ({var_sel, V}, Acc) -> Acc#{V => eval({var, V}, Row, Ctx)}
                        end, #{}, Items)
    end;
eval({index, E, I}, Row, Ctx) -> index(eval(E, Row, Ctx), eval(I, Row, Ctx), Ctx);
eval({slice, E, F, T}, Row, Ctx) ->
    slice(eval(E, Row, Ctx), opt_eval(F, Row, Ctx), opt_eval(T, Row, Ctx));
eval({map, KEs}, Row, Ctx) -> maps:from_list([{K, eval(E, Row, Ctx)} || {K, E} <- KEs]);
eval({is_null, E, Want}, Row, Ctx) -> (eval(E, Row, Ctx) =:= null) =:= Want;
%% CASE：通用形式取第一个条件为 true 的分支（null / false 都不算）；简单形式取第一个与主体
%% 相等（= 为 true）的分支；都不中取 ELSE，没有 ELSE 为 null。只求值用到的分支。
eval({case_expr, undefined, Alts, Else}, Row, Ctx) ->
    case_pick(fun(W) -> eval(W, Row, Ctx) =:= true end, Alts, Else, Row, Ctx);
eval({case_expr, Subj, Alts, Else}, Row, Ctx) ->
    S = eval(Subj, Row, Ctx),
    case_pick(fun(W) -> eq(S, eval(W, Row, Ctx)) =:= true end, Alts, Else, Row, Ctx);
eval({unop, 'not', E}, Row, Ctx) -> lnot(eval(E, Row, Ctx));
eval({unop, '-', {lit, V}}, _Row, _Ctx) when V =:= ?MAX_INT + 1 -> ?MIN_INT;   %% -9223372036854775808
eval({unop, '-', E}, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        null -> null;
        N when is_integer(N) -> int64(-N);
        N when is_number(N) -> -N;
        N when ?SP(N) -> bitcask_cypher_ieee:neg(N);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "unary minus on a non-number")})
    end;
eval({op, 'and', A, B}, Row, Ctx) ->
    case eval(A, Row, Ctx) of
        false -> false;
        VA -> land(VA, eval(B, Row, Ctx))
    end;
eval({op, 'or', A, B}, Row, Ctx) ->
    case eval(A, Row, Ctx) of
        true -> true;
        VA -> lor(VA, eval(B, Row, Ctx))
    end;
eval({op, 'xor', A, B}, Row, Ctx) -> lxor(eval(A, Row, Ctx), eval(B, Row, Ctx));
%% 全文匹配（第 9.2 节）：左边必须是 v.<属性>，按顶点判断（查询内对同一个查询串只检索一次）。
eval({op, '@@', {prop, {var, V}, Prop}, Q}, Row, Ctx) ->
    case {maps:get(V, Row, null), eval(Q, Row, Ctx)} of
        {null, _} -> null;
        {_, null} -> null;
        {{node, Vid}, QS} when is_binary(QS) -> bitcask_cypher_exec:fts_match(V, Vid, Prop, QS, Ctx);
        {{node, _}, _} -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the right side of @@ must be a string")});
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the left side of @@ must be a node property")})
    end;
eval({op, '@@', _, _}, _Row, _Ctx) ->
    throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the left side of @@ must be a node property, e.g. n.text")});
%% 向量距离（第 9.1 节）：库配置的度量下「越小越近」——取引擎相似度分数的相反数
%% （cosine / dot：负的内积；L2：平方距离）。
eval({op, '<=>', {prop, {var, V}, <<"embedding">>}, Q}, Row, Ctx) ->
    case {maps:get(V, Row, null), eval(Q, Row, Ctx)} of
        {null, _} -> null;
        {_, null} -> null;
        {{node, Vid}, QV} -> bitcask_cypher_exec:vector_distance(Vid, QV, Ctx);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the left side of <=> must be a node's embedding")})
    end;
eval({op, '<=>', _, _}, _Row, _Ctx) ->
    throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the left side of <=> must be n.embedding")});
eval({call, <<"score">>, _, [{var, V}]}, Row, _Ctx) ->
    bitcask_cypher_exec:fts_score(V, Row);
%% 检索的函数形式（二期）：第一个参数是 n.text 或 n，按顶点判断是否命中
eval({call, <<Ns:3/binary, ".", _/binary>> = Name, _, [First | Rest]}, Row, Ctx) when Ns =:= <<"fts">> ->
    search_call(Name, First, Rest, Row, Ctx);
eval({call, <<"search.", _/binary>> = Name, _, [First | Rest]}, Row, Ctx) ->
    search_call(Name, First, Rest, Row, Ctx);
eval({op, Op, A, B}, Row, Ctx) -> binop(Op, eval(A, Row, Ctx), eval(B, Row, Ctx));
eval({call, Name, _D, Args}, Row, Ctx) ->
    Vs = [eval(A, Row, Ctx) || A <- Args],
    case binary:match(Name, <<".">>) of
        nomatch -> call(Name, Vs, Ctx);
        _ ->
            %% 带命名空间：注册的用户函数（不能占内置的命名空间），否则是内置的 ns.f
            case bitcask_cypher_registry:function(Name) of
                {ok, _} -> bitcask_cypher_exec:user_function(Name, Vs, Ctx);
                error -> call(Name, Vs, Ctx)
            end
    end;
eval(count_star, _Row, _Ctx) -> throw({exec_error, ?C('SyntaxError', 'InvalidAggregation', "count(*) outside an aggregation")}).

truthy(true) -> true;
truthy(_)    -> false.

%% ---- 三值逻辑 ----

lnot(null) -> null;
lnot(true) -> false;
lnot(false) -> true;
lnot(_) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "NOT on a non-boolean value")}).

land(false, _) -> false;
land(_, false) -> false;
land(true, true) -> true;
land(A, B) when (A =:= null orelse A =:= true), (B =:= null orelse B =:= true) -> null;
land(_, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "AND on a non-boolean value")}).

lor(true, _) -> true;
lor(_, true) -> true;
lor(false, false) -> false;
lor(A, B) when (A =:= null orelse A =:= false), (B =:= null orelse B =:= false) -> null;
lor(_, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "OR on a non-boolean value")}).

lxor(null, _) -> null;
lxor(_, null) -> null;
lxor(A, B) when is_boolean(A), is_boolean(B) -> A =/= B;
lxor(_, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "XOR on a non-boolean value")}).

search_call(Name, First, Rest, Row, Ctx) ->
    V = case First of
            {prop, {var, X}, _} -> X;
            {var, X} -> X
        end,
    case maps:get(V, Row, null) of
        null -> null;
        {node, Vid} -> bitcask_cypher_exec:search_match(V, Vid, Name, [eval(A, Row, Ctx) || A <- Rest], Ctx);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', [Name, "() needs a node"])})
    end.

%% 量词的三值语义（openCypher）：false / null 的处理同 AND / OR 的推广。
quantify(all, Rs) ->
    case lists:member(false, Rs) of
        true -> false;
        false -> case lists:member(null, Rs) of true -> null; false -> true end
    end;
quantify(any, Rs) ->
    case lists:member(true, Rs) of
        true -> true;
        false -> case lists:member(null, Rs) of true -> null; false -> false end
    end;
quantify(none, Rs) ->
    case quantify(any, Rs) of true -> false; false -> true; null -> null end;
quantify(single, Rs) ->
    T = length([x || true <- Rs]),
    case {T, lists:member(null, Rs)} of
        {N, _} when N > 1 -> false;
        {1, false} -> true;
        {_, true} -> null;
        {0, false} -> false
    end.

is_agg(N) ->
    lists:member(N, [<<"count">>, <<"sum">>, <<"avg">>, <<"min">>, <<"max">>, <<"collect">>,
                     <<"percentilecont">>, <<"percentiledisc">>, <<"stdev">>, <<"stdevp">>]).

opt_eval(undefined, _Row, _Ctx) -> undefined;
opt_eval(E, Row, Ctx) -> eval(E, Row, Ctx).

%% 标签表达式里的一项：A（有）、{any, [项]}（任一）、{all, [项]}（都要）、{'not', 项}（没有）、wildcard（有任意标签）。
label_ok(L, Have) when is_binary(L) -> lists:member(L, Have);
label_ok({any, Ls}, Have) -> lists:any(fun(L) -> label_ok(L, Have) end, Ls);
label_ok({all, Ls}, Have) -> lists:all(fun(L) -> label_ok(L, Have) end, Ls);
label_ok({'not', L}, Have) -> not label_ok(L, Have);
label_ok(wildcard, Have) -> Have =/= [].

%% 下标：列表按整数（负数从末尾数，越界 null）；映射 / 顶点 / 关系按字符串键取属性。
index(null, _I, _Ctx) -> null;
index(_V, null, _Ctx) -> null;
index(L, I, _Ctx) when is_list(L), is_integer(I) ->
    N = length(L),
    J = case I < 0 of true -> N + I; false -> I end,
    case J >= 0 andalso J < N of
        true  -> lists:nth(J + 1, L);
        false -> null
    end;
index(V, K, Ctx) when is_binary(K) -> prop(V, K, Ctx);
%% 下标类型不对：映射用非字符串取 → MapElementAccessByNonString；列表用非整数取 →
%% ListElementAccessByNonInteger；别的值不能取下标 → InvalidArgumentType（都是 TypeError）
index(V, _, _) when is_map(V); element(1, V) =:= node; element(1, V) =:= rel ->
    throw({exec_error, ?C('TypeError', 'MapElementAccessByNonString', "invalid index: maps take a string key")});
index(V, _, _) when is_list(V) ->
    throw({exec_error, ?C('TypeError', 'ListElementAccessByNonInteger', "invalid index: lists take an integer")});
index(_, _, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "invalid index: only lists and maps can be indexed")}).

%% 切片 [from..to)：两端可省、可为负；越界截断。
slice(null, _F, _T) -> null;
slice(_L, null, _T) -> null;
slice(_L, _F, null) -> null;
slice(L, F, T) when is_list(L) ->
    N = length(L),
    Norm = fun(undefined, D) -> D;
              (X, _) when is_integer(X), X < 0 -> max(0, N + X);
              (X, _) when is_integer(X) -> min(N, X);
              (_, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "slice bounds must be integers")})
           end,
    From = Norm(F, 0),
    To = Norm(T, N),
    case To > From of
        true  -> lists:sublist(L, From + 1, To - From);
        false -> []
    end;
slice(_, _, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "slicing needs a list")}).

case_pick(_Hit, [], undefined, _Row, _Ctx) -> null;
case_pick(_Hit, [], Else, Row, Ctx) -> eval(Else, Row, Ctx);
case_pick(Hit, [{W, T} | Rest], Else, Row, Ctx) ->
    case Hit(W) of
        true  -> eval(T, Row, Ctx);
        false -> case_pick(Hit, Rest, Else, Row, Ctx)
    end.

%% ---- 运算符 ----

binop(regex, null, _) -> null;
binop(regex, _, null) -> null;
binop(regex, S, P) when is_binary(S), is_binary(P) -> regex_match(S, P);
binop(regex, _, _) -> null;
binop('=', A, B) -> eq(A, B);
binop('<>', A, B) -> lnot(eq(A, B));
binop('<', A, B) -> rel_cmp(A, B, fun(C) -> C =:= lt end);
binop('<=', A, B) -> rel_cmp(A, B, fun(C) -> C =/= gt end);
binop('>', A, B) -> rel_cmp(A, B, fun(C) -> C =:= gt end);
binop('>=', A, B) -> rel_cmp(A, B, fun(C) -> C =/= lt end);
binop(in, _A, null) -> null;
binop(in, A, L) when is_list(L) ->
    lists:foldl(fun(_X, true) -> true;
                   (X, Acc) ->
                        case eq(A, X) of
                            true  -> true;
                            null  -> null;
                            false -> Acc
                        end
                end, false, L);
binop(in, _A, _B) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "IN needs a list on the right")});
binop(starts_with, A, B) -> str_test(A, B, fun(X, Y) -> string:prefix(X, Y) =/= nomatch end);
binop(ends_with, A, B) ->
    str_test(A, B, fun(X, Y) ->
                           byte_size(Y) =< byte_size(X) andalso
                               binary:part(X, byte_size(X) - byte_size(Y), byte_size(Y)) =:= Y
                   end);
binop(contains, A, B) -> str_test(A, B, fun(X, Y) -> Y =:= <<>> orelse binary:match(X, Y) =/= nomatch end);
binop(_Op, null, _) -> null;
binop(_Op, _, null) -> null;
binop('+', A, B) when is_integer(A), is_integer(B) -> int64(A + B);
%% 浮点（含 NaN / 无穷）：IEEE 754 语义——溢出得无穷、除以浮点 0 得无穷或 NaN（bitcask_cypher_ieee）
binop('^', A, B) when ?XNUM(A), ?XNUM(B) -> bitcask_cypher_ieee:arith('^', A, B);    %% 幂总是浮点
binop(Op, A, B) when (Op =:= '+' orelse Op =:= '-' orelse Op =:= '*'), ?XNUM(A), ?XNUM(B),
                     not (is_integer(A) andalso is_integer(B)) ->
    bitcask_cypher_ieee:arith(Op, A, B);
binop(Op, A, B) when (Op =:= '/' orelse Op =:= '%'), ?XNUM(A), ?XNUM(B),
                     not (is_integer(A) andalso is_integer(B)) ->
    bitcask_cypher_ieee:arith(Op, A, B);
binop('+', A, B) when is_binary(A), ?SP(B) -> <<A/binary, (bitcask_cypher_ieee:text(B))/binary>>;
binop('+', A, B) when ?SP(A), is_binary(B) -> <<(bitcask_cypher_ieee:text(A))/binary, B/binary>>;
binop('+', A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
%% 字符串 + 数值 / 数值 + 字符串：数值按 toString 转成文本再拼接（openCypher）
binop('+', A, B) when is_binary(A), is_number(B) -> <<A/binary, (num_text(B))/binary>>;
binop('+', A, B) when is_number(A), is_binary(B) -> <<(num_text(A))/binary, B/binary>>;
binop('+', A, B) when is_list(A), is_list(B) -> A ++ B;
binop('+', A, B) when is_list(A) -> A ++ [B];
binop('+', A, B) when is_list(B) -> [A | B];
binop('-', A, B) when is_integer(A), is_integer(B) -> int64(A - B);

binop('*', A, B) when is_integer(A), is_integer(B) -> int64(A * B);

binop('/', A, B) when is_integer(A), is_integer(B) ->
    B =:= 0 andalso throw({exec_error, ?C('ArithmeticError', 'DivisionByZero', "division by zero")}),
    A div B;

binop('%', A, B) when is_integer(A), is_integer(B) ->
    B =:= 0 andalso throw({exec_error, ?C('ArithmeticError', 'DivisionByZero', "division by zero")}),
    A rem B;

%% 时间值 ± Duration、Duration 的加减乘除（bitcask_cypher_temporal 里不适用的照样报类型不符）
binop('+', A, B) when is_tuple(A); is_tuple(B) -> bitcask_cypher_temporal:plus(A, B);
binop('-', A, B) when is_tuple(A); is_tuple(B) -> bitcask_cypher_temporal:minus(A, B);
binop('*', A, B) when is_tuple(A); is_tuple(B) -> bitcask_cypher_temporal:times(A, B);
binop('/', A, B) when is_tuple(A) -> bitcask_cypher_temporal:divide(A, B);
binop(Op, _A, _B) ->
    throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["type mismatch for operator ", atom_to_list(Op)])}).

str_test(null, _, _) -> null;
str_test(_, null, _) -> null;
str_test(A, B, F) when is_binary(A), is_binary(B) -> F(A, B);
str_test(_, _, _) -> null.

rel_cmp(A, B, F) ->
    case compare(A, B) of
        null -> null;
        unordered -> false;                                    %% NaN 与数值比大小：全为 false
        C    -> F(C)
    end.

%% 相等（三值）：null 参与 → null；数值按值（1 = 1.0）；列表逐项；map 逐键；
%% 顶点 / 边按身份；不同类型 → false。
eq(null, _) -> null;
eq(_, null) -> null;
eq('NaN', _) -> false;                                     %% NaN 不等于任何值（包括 NaN）
eq(_, 'NaN') -> false;
eq(A, B) when is_number(A), is_number(B) -> A == B;
eq(A, B) when is_list(A), is_list(B) ->
    case length(A) =:= length(B) of
        false -> false;
        true ->
            lists:foldl(fun(_P, false) -> false;
                           ({X, Y}, Acc) ->
                                case eq(X, Y) of
                                    false -> false;
                                    null  -> null;
                                    true  -> Acc
                                end
                        end, true, lists:zip(A, B))
    end;
eq(A, B) when is_map(A), is_map(B) ->
    case lists:sort(maps:keys(A)) =:= lists:sort(maps:keys(B)) of
        false -> false;
        true  -> eq([maps:get(K, A) || K <- lists:sort(maps:keys(A))],
                    [maps:get(K, B) || K <- lists:sort(maps:keys(B))])
    end;
eq({node, A}, {node, B}) -> A =:= B;
eq({rel, S, T, D, R, _}, {rel, S2, T2, D2, R2, _}) -> {S, T, D, R} =:= {S2, T2, D2, R2};
eq({path, Ns, Rs}, {path, Ns2, Rs2}) -> eq(Ns, Ns2) =:= true andalso eq(Rs, Rs2) =:= true;
eq(A, B) when is_tuple(A), is_tuple(B) -> bitcask_cypher_temporal:eq(A, B);
eq(A, B) -> A =:= B.

%% 比较（< 一族）：lt | eq | gt | null（不可比）。
compare(null, _) -> null;
compare(_, null) -> null;
compare(A, B) when is_number(A), is_number(B) -> cmp3(A, B);
compare(A, B) when is_binary(A), is_binary(B) -> cmp3(A, B);
compare(A, B) when is_boolean(A), is_boolean(B) -> cmp3(A, B);
compare(A, B) when is_list(A), is_list(B) -> list_compare(A, B);
compare(A, B) when is_tuple(A), is_tuple(B) -> bitcask_cypher_temporal:compare(A, B);
compare(A, B) when ?XNUM(A), ?XNUM(B) -> bitcask_cypher_ieee:compare(A, B);     %% NaN → unordered
compare(_, _) -> null.

list_compare([], []) -> eq;
list_compare([], _) -> lt;
list_compare(_, []) -> gt;
list_compare([X | Xs], [Y | Ys]) ->
    case compare(X, Y) of
        eq -> list_compare(Xs, Ys);
        C  -> C
    end.

cmp3(A, B) when A < B -> lt;
cmp3(A, B) when A > B -> gt;
cmp3(_, _) -> eq.

%% ORDER BY 用的全序：返回 true 表示 A 排在 B 前面或相等（升序）。
order_cmp(A, B) -> order_key(A) =< order_key(B).

order_key(null) -> {9, 0};
order_key(N) when is_number(N) -> {8, {1, N}};
order_key(X) when ?SP(X) -> {8, {bitcask_cypher_ieee:order_rank(X), 0}};   %% -∞ < 有限数 < +∞ < NaN（键都是二元组）
order_key(B) when is_boolean(B) -> {7, B};
order_key(S) when is_binary(S) -> {6, S};
order_key({path, Ns, Rs}) -> {5, [order_key(X) || X <- Ns ++ Rs]};
order_key(L) when is_list(L) -> {4, [order_key(X) || X <- L]};
order_key({rel, S, T, D, R, _}) -> {3, {S, T, D, R}};
order_key({node, V}) -> {2, V};
order_key(T) when is_tuple(T) -> bitcask_cypher_temporal:order_key(T);
order_key(M) when is_map(M) -> {1, lists:sort([{K, order_key(V)} || {K, V} <- maps:to_list(M)])}.

%% 分组 / 去重的键：数值 1 与 1.0 等价；顶点 / 边按身份。
group_key(F) when is_float(F), F == trunc(F), abs(F) < 1.0e18 -> trunc(F);
group_key(L) when is_list(L) -> [group_key(X) || X <- L];
group_key(M) when is_map(M) -> maps:map(fun(_K, V) -> group_key(V) end, M);
group_key({rel, S, T, D, R, _}) -> {rel, S, T, D, R};
group_key({path, Ns, Rs}) -> {path, [group_key(X) || X <- Ns], [group_key(X) || X <- Rs]};
group_key(V) -> V.

%% =========================================================================
%% 属性与函数
%% =========================================================================

prop(null, _K, _Ctx) -> null;
prop({node, V}, <<"embedding">>, Ctx) -> bitcask_cypher_exec:node_vector(V, Ctx);
prop({node, V} = N, K, Ctx) ->
    bitcask_cypher_exec:deleted(V) andalso throw({exec_error, ?C('EntityNotFound', 'DeletedEntityAccess', ["property `", K, "` of a node deleted earlier in this statement"])}),
    maps:get(K, node_props(N, Ctx), null);
prop({rel, S, T, D, Rk, _} = R, K, Ctx) ->
    bitcask_cypher_exec:deleted({S, T, D, Rk}) andalso
        throw({exec_error, ?C('EntityNotFound', 'DeletedEntityAccess', ["property `", K, "` of a relationship deleted earlier in this statement"])}),
    maps:get(K, bitcask_cypher_exec:rel_props(R, Ctx), null);
prop(M, K, _Ctx) when is_map(M) -> maps:get(K, M, null);
prop(T, K, _Ctx) when is_tuple(T) -> bitcask_cypher_temporal:field(T, K);
prop(_, K, _Ctx) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["cannot read property ", K, " of a non-node value"])}).

node_props({node, V}, Ctx) -> maps:get(properties, bitcask_cypher_exec:node_info(V, Ctx)).
node_labels({node, V}, Ctx) -> maps:get(labels, bitcask_cypher_exec:node_info(V, Ctx)).

call(<<"coalesce">>, Args, _Ctx) ->
    case [A || A <- Args, A =/= null] of
        [X | _] -> X;
        []      -> null
    end;
call(_Name, [null], _Ctx) -> null;
%% ---- 时间 / 空间（bitcask_cypher_temporal）----
call(T, [], _Ctx) when T =:= <<"date">>; T =:= <<"localtime">>; T =:= <<"time">>;
                       T =:= <<"localdatetime">>; T =:= <<"datetime">> ->
    bitcask_cypher_temporal:construct(binary_to_atom(T), none, bitcask_cypher_exec:statement_now());
call(T, [A], _Ctx) when T =:= <<"date">>; T =:= <<"localtime">>; T =:= <<"time">>;
                        T =:= <<"localdatetime">>; T =:= <<"datetime">>; T =:= <<"duration">>;
                        T =:= <<"point">> ->
    bitcask_cypher_temporal:construct(binary_to_atom(T), A, bitcask_cypher_exec:statement_now());
%% 时钟变体：transaction / statement 是语句时钟（一条语句一个事务），realtime 是真实的当前时刻
call(<<"date.", C/binary>>, Args, _Ctx) when ?CLOCK(C) -> clock(date, C, Args);
call(<<"time.", C/binary>>, Args, _Ctx) when ?CLOCK(C) -> clock(time, C, Args);
call(<<"localtime.", C/binary>>, Args, _Ctx) when ?CLOCK(C) -> clock(localtime, C, Args);
call(<<"datetime.", C/binary>>, Args, _Ctx) when ?CLOCK(C) -> clock(datetime, C, Args);
call(<<"localdatetime.", C/binary>>, Args, _Ctx) when ?CLOCK(C) -> clock(localdatetime, C, Args);
call(<<"datetime.fromepoch">>, [S | Ns], _Ctx) ->
    bitcask_cypher_temporal:construct(datetime, #{<<"epochSeconds">> => S, <<"nanosecond">> => case Ns of [N] -> N; [] -> 0 end},
                               bitcask_cypher_exec:statement_now());
call(<<"datetime.fromepochmillis">>, [Ms], _Ctx) ->
    bitcask_cypher_temporal:construct(datetime, #{<<"epochMillis">> => Ms}, bitcask_cypher_exec:statement_now());
call(<<"duration.between">>, [A, B], _Ctx) -> bitcask_cypher_temporal:between(all, A, B);
call(<<"duration.inmonths">>, [A, B], _Ctx) -> bitcask_cypher_temporal:between(months, A, B);
call(<<"duration.indays">>, [A, B], _Ctx) -> bitcask_cypher_temporal:between(days, A, B);
call(<<"duration.inseconds">>, [A, B], _Ctx) -> bitcask_cypher_temporal:between(seconds, A, B);
call(<<T0:3/binary, _/binary>> = Name, [Unit, V | Over], _Ctx) when is_binary(Unit), length(Over) =< 1,
                                                                       (T0 =:= <<"dat">> orelse T0 =:= <<"tim">>
                                                                        orelse T0 =:= <<"loc">>) ->
    case binary:split(Name, <<".">>) of
        [T, <<"truncate">>] ->
            Type = binary_to_atom(T),
            Tr = bitcask_cypher_temporal:truncate(Type, Unit, V),
            case Over of
                [] -> Tr;
                [null] -> Tr;
                [M] when is_map(M) ->
                    %% 截断之后，映射里给的分量覆盖（openCypher：x.truncate(unit, value, overrides)）
                    bitcask_cypher_temporal:construct_relabel(Type, M#{<<"datetime">> => Tr}, bitcask_cypher_exec:statement_now());
                _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "truncate overrides must be a map")})
            end;
        _ -> throw({exec_error, ?C('SyntaxError', 'UnknownFunction', ["unknown function ", Name])})
    end;
call(D, [A, B], _Ctx) when D =:= <<"point.distance">>; D =:= <<"distance">> -> bitcask_cypher_temporal:distance(A, B);
call(<<"point.withinbbox">>, [P, LL, UR], _Ctx) -> bitcask_cypher_temporal:within_bbox(P, LL, UR);
%% ---- openCypher：数学 / 三角 / 时间戳（没有实数结果的返回 null：Erlang 表示不了 NaN / ∞）----
call(<<"rand">>, [], _Ctx) -> rand:uniform();
call(<<"e">>, [], _Ctx) -> math:exp(1);
call(<<"pi">>, [], _Ctx) -> math:pi();
call(<<"timestamp">>, [], _Ctx) -> os:system_time(millisecond);
call(<<"ceil">>, [N], _Ctx) when is_number(N) -> float(math:ceil(N));
call(<<"floor">>, [N], _Ctx) when is_number(N) -> float(math:floor(N));
call(<<"round">>, [N], _Ctx) when is_number(N) -> float(math:floor(N + 0.5));
call(<<"sign">>, [N], _Ctx) when is_number(N) -> if N > 0 -> 1; N < 0 -> -1; true -> 0 end;
%% 没有实数结果的按 IEEE 754（同 Java / Neo4j）：sqrt(-1) = NaN、log(0) = -Infinity、exp(1000) = Infinity
call(F, [N], _Ctx) when (F =:= <<"sqrt">> orelse F =:= <<"exp">> orelse F =:= <<"log">> orelse F =:= <<"log10">>
                         orelse F =:= <<"asin">> orelse F =:= <<"acos">> orelse F =:= <<"cot">>), ?XNUM(N) ->
    bitcask_cypher_ieee:math1(F, N);
%% NaN / 无穷作参数的其余数学函数
call(F, [X], _Ctx) when ?SP(X), (F =:= <<"sin">> orelse F =:= <<"cos">> orelse F =:= <<"tan">> orelse F =:= <<"atan">>
                                 orelse F =:= <<"degrees">> orelse F =:= <<"radians">> orelse F =:= <<"haversin">>
                                 orelse F =:= <<"ceil">> orelse F =:= <<"floor">> orelse F =:= <<"round">>
                                 orelse F =:= <<"abs">>) ->
    bitcask_cypher_ieee:math1(F, X);
call(<<"sign">>, [X], _Ctx) when ?SP(X) -> case X of 'Infinity' -> 1; '-Infinity' -> -1; 'NaN' -> 0 end;
call(<<"isnan">>, [X], _Ctx) when ?XNUM(X) -> X =:= 'NaN';
call(<<"tofloat">>, [X], _Ctx) when ?SP(X) -> X;
call(<<"tointeger">>, [X], _Ctx) when ?SP(X) -> null;
call(<<"tostring">>, [X], _Ctx) when ?SP(X) -> bitcask_cypher_ieee:text(X);
call(<<"sin">>, [N], _Ctx) when is_number(N) -> math:sin(N);
call(<<"cos">>, [N], _Ctx) when is_number(N) -> math:cos(N);
call(<<"tan">>, [N], _Ctx) when is_number(N) -> math:tan(N);
call(<<"atan">>, [N], _Ctx) when is_number(N) -> math:atan(N);
call(<<"atan2">>, [Y, X], _Ctx) when is_number(Y), is_number(X) -> math:atan2(Y, X);
call(<<"degrees">>, [N], _Ctx) when is_number(N) -> N * 180 / math:pi();
call(<<"radians">>, [N], _Ctx) when is_number(N) -> N * math:pi() / 180;
call(<<"haversin">>, [N], _Ctx) when is_number(N) -> (1 - math:cos(N)) / 2;
%% ---- 二期：字符串与列表 ----
call(<<"substring">>, [S, St], _Ctx) when is_binary(S), is_integer(St), St >= 0 ->
    bin(lists:nthtail(min(St, length(chars(S))), chars(S)));
call(<<"substring">>, [S, St, Len], _Ctx) when is_binary(S), is_integer(St), St >= 0, is_integer(Len), Len >= 0 ->
    Cs = chars(S),
    bin(lists:sublist(Cs, min(St, length(Cs)) + 1, Len));
call(<<"replace">>, [S, F, T], _Ctx) when is_binary(S), is_binary(F), is_binary(T) ->
    case F of
        <<>> -> S;
        _    -> iolist_to_binary(string:replace(S, F, T, all))
    end;
call(<<"split">>, [S, D], _Ctx) when is_binary(S), is_binary(D) ->
    case D of
        <<>> -> [bin([C]) || C <- chars(S)];
        _    -> [iolist_to_binary(P) || P <- string:split(S, D, all)]
    end;
call(<<"trim">>, [S], _Ctx) when is_binary(S) -> iolist_to_binary(string:trim(S, both));
call(<<"ltrim">>, [S], _Ctx) when is_binary(S) -> iolist_to_binary(string:trim(S, leading));
call(<<"rtrim">>, [S], _Ctx) when is_binary(S) -> iolist_to_binary(string:trim(S, trailing));
call(<<"left">>, [S, N], _Ctx) when is_binary(S), is_integer(N), N >= 0 -> bin(lists:sublist(chars(S), N));
call(<<"right">>, [S, N], _Ctx) when is_binary(S), is_integer(N), N >= 0 ->
    Cs = chars(S),
    bin(lists:nthtail(max(0, length(Cs) - N), Cs));
call(<<"reverse">>, [S], _Ctx) when is_binary(S) -> bin(lists:reverse(chars(S)));
call(<<"reverse">>, [L], _Ctx) when is_list(L) -> lists:reverse(L);
call(<<"head">>, [[]], _Ctx) -> null;
call(<<"head">>, [[X | _]], _Ctx) -> X;
call(<<"tail">>, [[]], _Ctx) -> [];
call(<<"tail">>, [[_ | T]], _Ctx) -> T;
call(<<"last">>, [[]], _Ctx) -> null;
call(<<"last">>, [L], _Ctx) when is_list(L) -> lists:last(L);
call(<<"range">>, [A, B], Ctx) -> call(<<"range">>, [A, B, 1], Ctx);
call(<<"range">>, [A, B, Step], _Ctx) when is_integer(A), is_integer(B), is_integer(Step), Step =/= 0 ->
    %% 步长与起止方向相反 → 空列表（div 向零取整，range(0, 1, -123) 不能得到 [0]）
    N = case (B - A) * Step < 0 of true -> 0; false -> (B - A) div Step + 1 end,
    N > 10000000 andalso throw({exec_error, ?C('ArgumentError', 'NumberOutOfRange', "range() would produce more than 10000000 elements")}),
    case N > 0 of
        true  -> lists:seq(A, A + (N - 1) * Step, Step);
        false -> []
    end;
call(<<"range">>, [_, _, 0], _Ctx) -> throw({exec_error, ?C('ArgumentError', 'NumberOutOfRange', "range() step must not be 0")});
%% 多参数函数：任一参数为 null → null；否则是参数类型不对
call(Name, Args, _Ctx) when length(Args) > 1, Name =/= <<"coalesce">> ->
    case lists:member(null, Args) of
        true  -> null;
        false -> throw({exec_error, ?C('ArgumentError', 'InvalidArgumentType', ["invalid argument type for ", Name])})
    end;
call(<<"id">>, [{node, V}], _Ctx) -> V;
call(<<"id">>, [{rel, S, T, D, R, _}], _Ctx) -> [S, T, D, R];
call(<<"labels">>, [{node, V} = N], Ctx) ->
    bitcask_cypher_exec:deleted(V) andalso throw({exec_error, ?C('EntityNotFound', 'DeletedEntityAccess', "labels() of a node deleted earlier in this statement")}),
    node_labels(N, Ctx);
call(<<"type">>, [{rel, _, T, _, _, _}], Ctx) -> bitcask_cypher_exec:type_name(T, Ctx);
call(<<"properties">>, [{node, _} = N], Ctx) -> node_props(N, Ctx);
call(<<"properties">>, [{rel, _, _, _, _, _} = R], Ctx) -> bitcask_cypher_exec:rel_props(R, Ctx);
call(<<"properties">>, [M], _Ctx) when is_map(M) -> M;
call(<<"keys">>, [{node, _} = N], Ctx) -> lists:sort(maps:keys(node_props(N, Ctx)));
call(<<"keys">>, [{rel, _, _, _, _, _} = R], Ctx) -> lists:sort(maps:keys(bitcask_cypher_exec:rel_props(R, Ctx)));
call(<<"keys">>, [M], _Ctx) when is_map(M) -> lists:sort(maps:keys(M));
call(<<"size">>, [L], _Ctx) when is_list(L) -> length(L);
call(<<"size">>, [S], _Ctx) when is_binary(S) -> length(unicode:characters_to_list(S));
call(<<"length">>, [{path, _, Rs}], _Ctx) -> length(Rs);
call(<<"length">>, [L], _Ctx) when is_list(L) -> length(L);
call(<<"length">>, [S], _Ctx) when is_binary(S) -> length(unicode:characters_to_list(S));
call(<<"nodes">>, [{path, Ns, _}], _Ctx) -> Ns;
call(<<"relationships">>, [{path, _, Rs}], _Ctx) -> Rs;
call(<<"startnode">>, [{rel, S, _, _, _, _}], _Ctx) -> {node, S};
call(<<"endnode">>, [{rel, _, _, D, _, _}], _Ctx) -> {node, D};
call(<<"tointeger">>, [N], _Ctx) when is_integer(N) -> N;
call(<<"tointeger">>, [F], _Ctx) when is_float(F) -> int64(trunc(F));
call(<<"tointeger">>, [S], _Ctx) when is_binary(S) ->
    case parse_number(S) of
        null -> null;
        N when ?SP(N) -> null;
        N    -> int64(trunc(N))
    end;
call(<<"tointeger">>, [B], _Ctx) when is_boolean(B) -> case B of true -> 1; false -> 0 end;
call(<<"tofloat">>, [N], _Ctx) when is_number(N) -> float(N);
call(<<"tofloat">>, [S], _Ctx) when is_binary(S) ->
    case parse_number(S) of
        null -> null;
        N when ?SP(N) -> N;
        N    -> float(N)
    end;
call(<<"tostring">>, [S], _Ctx) when is_binary(S) -> S;
call(<<"tostring">>, [N], _Ctx) when is_integer(N) -> integer_to_binary(N);
call(<<"tostring">>, [F], _Ctx) when is_float(F) -> num_text(F);
call(<<"tostring">>, [B], _Ctx) when is_boolean(B) -> atom_to_binary(B);
call(<<"tostring">>, [T], _Ctx) when is_tuple(T) ->
    case bitcask_cypher_temporal:is_value(T) of
        true -> bitcask_cypher_temporal:format(T);
        false -> throw({exec_error, ?C('TypeError', 'InvalidArgumentValue', "invalid argument type for tostring")})
    end;
call(<<"toboolean">>, [B], _Ctx) when is_boolean(B) -> B;
call(<<"toboolean">>, [S], _Ctx) when is_binary(S) ->
    case string:lowercase(S) of
        <<"true">>  -> true;
        <<"false">> -> false;
        _           -> null
    end;
call(<<"tolower">>, [S], _Ctx) when is_binary(S) -> string:lowercase(S);
call(<<"toupper">>, [S], _Ctx) when is_binary(S) -> string:uppercase(S);
call(<<"abs">>, [N], _Ctx) when is_integer(N) -> int64(abs(N));
call(<<"abs">>, [N], _Ctx) when is_number(N) -> abs(N);
call(Name, _Args, _Ctx) ->
    case is_agg(Name) of
        true  -> throw({exec_error, ?C('SyntaxError', 'InvalidAggregation', ["aggregate function ", Name, " used outside an aggregation"])});
        false -> throw({exec_error, ?C('TypeError', 'InvalidArgumentValue', ["invalid argument type for ", Name])})
    end.

%% =~ 匹配整个字符串（同 Java 的 matches）。编译结果按模式缓存在进程字典里（一条查询里同一个
%% 模式反复用）。模式不合法 → 执行错误。
regex_match(S, P) ->
    K = {?MODULE, regex, P},
    MP = case get(K) of
             undefined ->
                 case re:compile(<<"^(?:", P/binary, ")$">>, [unicode]) of
                     {ok, C} -> put(K, C), C;
                     {error, {Why, _}} -> throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', ["invalid regular expression: ", Why])})
                 end;
             C -> C
         end,
    re:run(S, MP, [{capture, none}]) =:= match.

chars(S) -> unicode:characters_to_list(S).
bin(Cs) -> unicode:characters_to_binary(Cs).

pct_check(P) when is_number(P), P >= 0, P =< 1 -> ok;
pct_check(_) -> throw({exec_error, ?C('ArgumentError', 'NumberOutOfRange', "percentile must be a number between 0.0 and 1.0")}).

clock(T, Clock, Args) ->
    Now = case Clock of <<"realtime">> -> os:system_time(nanosecond); _ -> bitcask_cypher_exec:statement_now() end,
    V = bitcask_cypher_temporal:construct(T, none, Now),
    case Args of
        [] -> V;
        [null] -> null;
        [Tz] when is_binary(Tz) -> bitcask_cypher_temporal:construct(T, #{<<"datetime">> => V, <<"timezone">> => Tz}, Now);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the time zone argument must be a string")})
    end.

%% 字符串 → 数值：整数 `[+-]digits`；浮点 `1.5`、`.5`、`5.`、`1e3`、`-2.5E-3`；别的 → null。
parse_number(S) ->
    Str = string:trim(binary_to_list(S)),
    case bitcask_cypher_ieee:parse(Str) of
        undefined -> parse_finite(Str);
        Special -> Special
    end.

parse_finite(Str) ->
    case re:run(Str, "^[+-]?\\d+$", [{capture, none}]) of
        match -> list_to_integer(Str);
        nomatch ->
            case re:run(Str, "^([+-]?)(\\d*)(?:\\.(\\d*))?(?:[eE]([+-]?\\d+))?$", [{capture, all_but_first, list}]) of
                {match, [Sign, IntP, FracP | ExpP]} when IntP =/= "" orelse (FracP =/= "" andalso FracP =/= []) ->
                    I = case IntP of "" -> "0"; _ -> IntP end,
                    F = case FracP of "" -> "0"; _ -> FracP end,
                    E = case ExpP of [X] when X =/= "" -> "e" ++ X; _ -> "" end,
                    try list_to_float(Sign ++ I ++ "." ++ F ++ E)
                    catch error:badarg -> null
                    end;
                _ -> null
            end
    end.

%% toString 的数值文本（字符串拼接也用）。
num_text(I) when is_integer(I) -> integer_to_binary(I);
num_text(F) -> float_to_binary(F, [short]).

%% 64 位整数（openCypher 的 INTEGER）：超出就是执行错误。
int64(I) when I > ?MAX_INT; I < ?MIN_INT -> throw({exec_error, ?C('ArithmeticError', 'IntegerOverflow', "integer overflow")});
int64(I) -> I.

%% =========================================================================
%% 聚合
%% =========================================================================

%% 表达式里的聚合调用：[{Ref, AggExpr}]（Ref 从 0 起，按出现顺序）。
find_aggs(E) ->
    {_, Acc} = walk_aggs(E, []),
    lists:reverse(Acc).

walk_aggs(count_star = E, Acc) -> {E, [{length(Acc), E} | Acc]};
walk_aggs({call, N, _D, _Args} = E, Acc) ->
    case is_agg(N) of
        true  -> {E, [{length(Acc), E} | Acc]};
        false -> walk_children(E, Acc)
    end;
walk_aggs(E, Acc) -> walk_children(E, Acc).

walk_children({call, _, _, Args}, Acc) -> lists:foldl(fun(A, {_, Ac}) -> walk_aggs(A, Ac) end, {x, Acc}, Args);
walk_children({list, Es}, Acc) -> lists:foldl(fun(A, {_, Ac}) -> walk_aggs(A, Ac) end, {x, Acc}, Es);
walk_children({map, KEs}, Acc) -> lists:foldl(fun({_, A}, {_, Ac}) -> walk_aggs(A, Ac) end, {x, Acc}, KEs);
walk_children({op, _, A, B}, Acc) -> {_, A1} = walk_aggs(A, Acc), walk_aggs(B, A1);
walk_children({unop, _, A}, Acc) -> walk_aggs(A, Acc);
walk_children({is_null, A, _}, Acc) -> walk_aggs(A, Acc);
walk_children({prop, A, _}, Acc) -> walk_aggs(A, Acc);
walk_children({list_comp, _, L, _, _}, Acc) -> walk_aggs(L, Acc);
walk_children({quant, _, _, L, _}, Acc) -> walk_aggs(L, Acc);
walk_children({reduce, _, Init, _, L, _}, Acc) -> {_, A1} = walk_aggs(Init, Acc), walk_aggs(L, A1);
walk_children({exists, E}, Acc) -> walk_aggs(E, Acc);
walk_children({case_expr, Subj, Alts, Else}, Acc) ->
    Parts = [S || S <- [Subj], S =/= undefined] ++ lists:append([[W, T] || {W, T} <- Alts])
            ++ [E || E <- [Else], E =/= undefined],
    lists:foldl(fun(A, {_, Ac}) -> walk_aggs(A, Ac) end, {x, Acc}, Parts);
walk_children(E, Acc) -> {E, Acc}.

%% 把表达式里的聚合调用按出现顺序换成 {agg_ref, Ref}（与 find_aggs/1 的编号一致）。
replace_aggs(E, Base) ->
    {E2, _} = repl(E, Base),
    E2.

repl(count_star, N) -> {{agg_ref, N}, N + 1};
repl({call, Name, D, Args} = E, N) ->
    case is_agg(Name) of
        true -> {{agg_ref, N}, N + 1};
        false ->
            {Args2, N2} = lists:mapfoldl(fun repl/2, N, Args),
            _ = E,
            {{call, Name, D, Args2}, N2}
    end;
repl({list, Es}, N) -> {Es2, N2} = lists:mapfoldl(fun repl/2, N, Es), {{list, Es2}, N2};
repl({map, KEs}, N) ->
    {KEs2, N2} = lists:mapfoldl(fun({K, E}, Acc) -> {E2, Acc2} = repl(E, Acc), {{K, E2}, Acc2} end, N, KEs),
    {{map, KEs2}, N2};
repl({op, Op, A, B}, N) -> {A2, N1} = repl(A, N), {B2, N2} = repl(B, N1), {{op, Op, A2, B2}, N2};
repl({unop, Op, A}, N) -> {A2, N1} = repl(A, N), {{unop, Op, A2}, N1};
repl({is_null, A, W}, N) -> {A2, N1} = repl(A, N), {{is_null, A2, W}, N1};
repl({prop, A, K}, N) -> {A2, N1} = repl(A, N), {{prop, A2, K}, N1};
repl({list_comp, X, L, W, P}, N) -> {L2, N1} = repl(L, N), {{list_comp, X, L2, W, P}, N1};
repl({quant, K, X, L, Pred}, N) -> {L2, N1} = repl(L, N), {{quant, K, X, L2, Pred}, N1};
repl({reduce, Acc, Init, X, L, E}, N) ->
    {I2, N1} = repl(Init, N), {L2, N2} = repl(L, N1), {{reduce, Acc, I2, X, L2, E}, N2};
repl({exists, E}, N) -> {E2, N1} = repl(E, N), {{exists, E2}, N1};
repl({case_expr, Subj, Alts, Else}, N) ->
    {S2, N1} = repl_opt(Subj, N),
    {Alts2, N2} = lists:mapfoldl(fun({W, T}, Acc) ->
                                         {W2, Acc1} = repl(W, Acc),
                                         {T2, Acc2} = repl(T, Acc1),
                                         {{W2, T2}, Acc2}
                                 end, N1, Alts),
    {E2, N3} = repl_opt(Else, N2),
    {{case_expr, S2, Alts2, E2}, N3};
repl(E, N) -> {E, N}.

repl_opt(undefined, N) -> {undefined, N};
repl_opt(E, N) -> repl(E, N).

%% 累加器：{Fun, Distinct, Seen, State}
agg_init(count_star, _) -> {count_star, false, #{}, 0};
agg_init({call, N, D, _}, _) ->
    S0 = case N of
             <<"count">>   -> 0;
             <<"sum">>     -> 0;
             <<"avg">>     -> {0, 0};
             <<"min">>     -> null;
             <<"max">>     -> null;
             <<"collect">> -> [];
             <<"percentilecont">> -> {[], undefined};
             <<"percentiledisc">> -> {[], undefined};
             <<"stdev">>   -> [];
             <<"stdevp">>  -> []
         end,
    {N, D, #{}, S0}.

agg_step({count_star, D, Seen, C}, _V, _) -> {count_star, D, Seen, C + 1};
agg_step(Acc, null, _) -> Acc;
%% percentileCont / percentileDisc：值与百分位一起来（执行器 step/4）
agg_step(Acc, {pct, null, _}, _) -> Acc;
agg_step({N, D, Seen, {Vals, _}}, {pct, V, P}, _) when is_number(V) -> {N, D, Seen, {[V | Vals], P}};
agg_step({N, _, _, _}, {pct, _, _}, _) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', [N, "() of a non-number"])});
agg_step({N, true, Seen, S}, V, Ctx) ->
    K = group_key(V),
    case is_map_key(K, Seen) of
        true  -> {N, true, Seen, S};
        false -> agg_step({N, false, Seen#{K => true}, S}, V, Ctx, true)
    end;
agg_step(Acc, V, Ctx) -> agg_step(Acc, V, Ctx, false).

agg_step({N, _D, Seen, S}, V, _Ctx, WasDistinct) ->
    S2 = case N of
             <<"count">> -> S + 1;
             <<"sum">> when is_integer(V), is_integer(S) -> int64(S + V);
             <<"sum">> when ?XNUM(V) -> binop('+', S, V);
             <<"sum">> -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "sum() of a non-number")});
             <<"avg">> when ?XNUM(V) -> {Sum, C} = S, {binop('+', Sum, V), C + 1};
             <<"avg">> -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "avg() of a non-number")});
             <<"min">> -> case S =:= null orelse order_cmp(V, S) of true -> V; false -> S end;
             <<"max">> -> case S =:= null orelse not order_cmp(V, S) of true -> V; false -> S end;
             <<"collect">> -> [V | S];
             S2N when (S2N =:= <<"stdev">> orelse S2N =:= <<"stdevp">>), is_number(V) -> [V | S];
             S2N when S2N =:= <<"stdev">>; S2N =:= <<"stdevp">> -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', [S2N, "() of a non-number"])})
         end,
    {N, WasDistinct, Seen, S2}.

agg_final({count_star, _, _, C}, _) -> C;
agg_final({<<"avg">>, _, _, {_, 0}}, _) -> null;
agg_final({<<"avg">>, _, _, {Sum, _C}}, _) when ?SP(Sum) -> Sum;
agg_final({<<"avg">>, _, _, {Sum, C}}, _) -> Sum / C;
agg_final({<<"collect">>, _, _, L}, _) -> lists:reverse(L);
agg_final({<<"percentilecont">>, _, _, {[], _}}, _) -> null;
agg_final({<<"percentilecont">>, _, _, {Vals, P}}, _) ->
    Xs = list_to_tuple(lists:sort(Vals)),
    pct_check(P),
    Pos = P * (tuple_size(Xs) - 1),
    Lo = trunc(math:floor(Pos)), Hi = trunc(math:ceil(Pos)),
    A = element(Lo + 1, Xs), B = element(Hi + 1, Xs),
    float(A + (B - A) * (Pos - Lo));
agg_final({<<"percentiledisc">>, _, _, {[], _}}, _) -> null;
agg_final({<<"percentiledisc">>, _, _, {Vals, P}}, _) ->
    Xs = list_to_tuple(lists:sort(Vals)),
    pct_check(P),
    N = tuple_size(Xs),
    F = P * N,
    Idx = case F > 0 andalso F == math:floor(F) of
              true -> trunc(F) - 1;
              false -> trunc(math:floor(F))
          end,
    element(min(N - 1, max(0, Idx)) + 1, Xs);
agg_final({Sd, _, _, Vals}, _) when Sd =:= <<"stdev">>; Sd =:= <<"stdevp">> ->
    N = length(Vals),
    Den = case Sd of <<"stdev">> -> N - 1; _ -> N end,
    case Den > 0 of
        false -> 0.0;
        true ->
            M = lists:sum(Vals) / N,
            math:sqrt(lists:sum([(X - M) * (X - M) || X <- Vals]) / Den)
    end;
agg_final({_, _, _, S}, _) -> S.
