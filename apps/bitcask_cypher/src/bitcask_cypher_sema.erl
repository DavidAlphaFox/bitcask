%% =========================================================================
%% bitcask_cypher_sema — Cypher 子集的语义检查（doc/cypher-query-design-zh.md 第 5、6 节）
%%
%% 输入：bitcask_cypher_parser 的 AST。输出 {ok, Analysis}：
%%   #{query  => 规范化后的子句列表（匿名变量已命名、投影项都有列名、变长上下限已补齐）,
%%     writes => boolean(),
%%     params => [参数名]}
%% 或 {error, #{stage => semantic, message, line, column}}。
%%
%% AST 形态（parser 产出）：
%%   {query, [Clause]}
%%   Clause :: {match, Optional, [Part], Where, Loc} | {unwind, Expr, Var, Loc}
%%           | {with, Distinct, Proj, Order, Skip, Limit, Where, Loc}
%%           | {return, Distinct, Proj, Order, Skip, Limit, Loc}
%%           | {create, [Part], Loc} | {set, [Item], Loc} | {remove, [Item], Loc}
%%           | {delete, Detach, [Expr], Loc}
%%           | {merge, Part, OnCreate :: [SetItem], OnMatch :: [SetItem], Loc}
%%           | {call_proc, Name, [{Var, Var}] | undefined, Where, Loc}
%%   Part   :: {part, PathVar | undefined, {chain, Node, [{Rel, Node}]} | {shortest, single | all, Chain, Loc}}
%%   Node   :: {node, Var | undefined, [Label], PropsExpr | undefined, Loc}
%%   Rel    :: {rel, Var | undefined, [Type], PropsExpr | undefined, out | in | both, VarLen, Loc}
%%   Var    :: {var, Name, Loc}
%%   Expr   :: {lit, V} | {param, Name, Loc} | Var | {has_labels, Var, [L]} | {prop, Expr, Key}
%%           | {call, Name, Distinct, [Expr], Loc} | {count_star, Loc} | {list, [Expr]}
%%           | {map, [{Key, Expr}]} | {op, Op, A, B} | {unop, Op, A} | {is_null, Expr, Bool}
%%           | {case_expr, Subject | undefined, [{When, Then}], Else | undefined, Loc}
%%           | {index, Expr, Expr} | {slice, Expr, Expr | undefined, Expr | undefined}
%%   Label  :: binary() | {any, [binary()]} | {'not', binary()}      （A、A|B、!A；写标签只能是 binary）
%%   排序方向 :: asc | desc | {asc | desc, first | last}            （NULLS FIRST / LAST）
%%
%% 规范化后的子句另有：{optional_match, Parts, Where, Loc}（OPTIONAL MATCH）、
%%   {merge_node, Var, [Label], PropsExpr, OnCreate, OnMatch, Loc}、
%%   {merge_rel, From, RelVar, Type, PropsExpr, out | in, To, OnCreate, OnMatch, Loc}、
%%   {call_proc, Name, [{Column, Var}], Where, Loc}；模式里另有 {named_chain, P, Chain}（普通命名路径）、
%%   {all_shortest, P, N0, Rel, N1, Loc}（allShortestPaths）。
%%
%% 规范化之后：变量名是 binary（匿名变量以两个空格开头，用户写不出来）；投影项是
%% {Name, Expr}；变长是 {Min, Max}（缺省 1..10，第 7.4 节）。
%% =========================================================================
-module(bitcask_cypher_sema).

-export([analyze/1, expr_text/1, is_aggregate/1, contains_aggregate/1, hidden/1,
         expr_vars/1]).

%% 不写上界的 * / *n.. 不限跳数（openCypher）；关系在一条路径里不重复，所以在有限图上必然终止。
-define(DEFAULT_MAX_HOPS, 1000000).
-define(AGGS, [<<"count">>, <<"sum">>, <<"avg">>, <<"min">>, <<"max">>, <<"collect">>,
               <<"percentilecont">>, <<"percentiledisc">>, <<"stdev">>, <<"stdevp">>]).
%% 函数名 → 允许的参数个数
-define(FUNS, #{<<"id">> => [1], <<"labels">> => [1], <<"type">> => [1],
                <<"properties">> => [1], <<"keys">> => [1], <<"coalesce">> => any,
                <<"size">> => [1], <<"length">> => [1], <<"nodes">> => [1],
                <<"relationships">> => [1], <<"startnode">> => [1], <<"endnode">> => [1],
                <<"tointeger">> => [1], <<"tofloat">> => [1], <<"tostring">> => [1],
                <<"toboolean">> => [1], <<"tolower">> => [1], <<"toupper">> => [1],
                <<"abs">> => [1], <<"score">> => [1],
                %% 二期：字符串与列表函数
                <<"substring">> => [2, 3], <<"replace">> => [3], <<"split">> => [2],
                <<"trim">> => [1], <<"ltrim">> => [1], <<"rtrim">> => [1],
                <<"left">> => [2], <<"right">> => [2], <<"reverse">> => [1],
                <<"head">> => [1], <<"tail">> => [1], <<"last">> => [1], <<"range">> => [2, 3],
                %% 二期：检索的函数形式（第 9.2、9.3 节）
                <<"fts.phrase">> => [2], <<"fts.near">> => [3], <<"fts.wildcard">> => [2],
                <<"fts.fuzzy">> => [2, 3], <<"fts.fields">> => [2], <<"search.hybrid">> => [3, 4],
                <<"count">> => [1], <<"sum">> => [1], <<"avg">> => [1], <<"min">> => [1],
                <<"max">> => [1], <<"collect">> => [1],
                %% openCypher：统计聚合
                <<"percentilecont">> => [2], <<"percentiledisc">> => [2], <<"stdev">> => [1], <<"stdevp">> => [1],
                %% openCypher：数学 / 三角 / 时间戳
                <<"ceil">> => [1], <<"floor">> => [1], <<"round">> => [1], <<"sign">> => [1],
                <<"rand">> => [0], <<"sqrt">> => [1], <<"exp">> => [1], <<"log">> => [1], <<"log10">> => [1],
                <<"e">> => [0], <<"pi">> => [0], <<"sin">> => [1], <<"cos">> => [1], <<"tan">> => [1],
                <<"cot">> => [1], <<"asin">> => [1], <<"acos">> => [1], <<"atan">> => [1], <<"atan2">> => [2],
                <<"degrees">> => [1], <<"radians">> => [1], <<"haversin">> => [1], <<"timestamp">> => [0],
                %% LOAD CSV 的当前行号 / 文件
                <<"isnan">> => [1],
                %% 时间 / 空间（第三期设计第 7 节）
                <<"date">> => [0, 1], <<"localtime">> => [0, 1], <<"time">> => [0, 1],
                <<"localdatetime">> => [0, 1], <<"datetime">> => [0, 1], <<"duration">> => [1],
                <<"datetime.fromepoch">> => [1, 2], <<"datetime.fromepochmillis">> => [1],
                <<"duration.between">> => [2], <<"duration.inmonths">> => [2], <<"duration.indays">> => [2],
                <<"duration.inseconds">> => [2],
                <<"date.truncate">> => [2, 3], <<"localtime.truncate">> => [2, 3], <<"time.truncate">> => [2, 3],
                <<"localdatetime.truncate">> => [2, 3], <<"datetime.truncate">> => [2, 3],
                <<"date.transaction">> => [0, 1], <<"date.statement">> => [0, 1], <<"date.realtime">> => [0, 1], <<"time.transaction">> => [0, 1], <<"time.statement">> => [0, 1], <<"time.realtime">> => [0, 1], <<"localtime.transaction">> => [0, 1], <<"localtime.statement">> => [0, 1], <<"localtime.realtime">> => [0, 1], <<"datetime.transaction">> => [0, 1], <<"datetime.statement">> => [0, 1], <<"datetime.realtime">> => [0, 1], <<"localdatetime.transaction">> => [0, 1], <<"localdatetime.statement">> => [0, 1], <<"localdatetime.realtime">> => [0, 1],
                <<"point">> => [1], <<"point.distance">> => [2], <<"distance">> => [2],
                <<"point.withinbbox">> => [3]}).

%% 内置过程（CALL）：名字（小写）→ 输出列。
-define(PROCS, #{<<"db.labels">> => [<<"label">>],
                 <<"db.relationshiptypes">> => [<<"relationshipType">>],
                 <<"db.propertykeys">> => [<<"propertyKey">>]}).

%% 静态类型已知的值变量的种类（不能当节点 / 关系用；list 可以当变长关系的值）
-define(IS_VALUE_KIND(K), (K =:= v_boolean orelse K =:= v_integer orelse K =:= v_float orelse K =:= v_string
                           orelse K =:= v_map orelse K =:= list)).

-record(st, {scope = [] :: [{binary(), atom()}],   %% 有序：绑定先后（RETURN * 的列序）
             anon = 0 :: non_neg_integer()}).

%% =========================================================================

analyze({union, [{first, C1} | Rest]}) ->
    %% UNION：每段独立分析（各自的变量作用域），每段都要以 RETURN 结尾；列名一致在规划时查
    try
        [{Mode, _, _} | _] = Rest,
        [fail('SyntaxError', 'InvalidClauseComposition', "UNION and UNION ALL can't be mixed in one query", L) || {M, _, L} <- Rest, M =/= Mode],
        Outs = [begin
                    Clauses = standalone_call(Cs),
                    check_order(Clauses),
                    Last = lists:last(Clauses),
                    element(1, Last) =:= return orelse
                        fail('SyntaxError', 'InvalidClauseComposition', "each part of a UNION must end with RETURN", loc_of(Last)),
                    {Out, _St} = clauses(Clauses, #st{}, []),
                    {Out, Clauses}
                end || Cs <- [C1 | [C || {_, C, _} <- Rest]]],
        {ok, #{query => {union, Mode, [O || {O, _} <- Outs]},
               writes => lists:any(fun is_write/1, lists:append([Cs || {_, Cs} <- Outs])),
               params => lists:usort(collect_params([Cs || {_, Cs} <- Outs]))}}
    catch throw:{sema, Msg, Loc} -> {error, err(Msg, Loc)}
    end;
analyze({query, Clauses0}) ->
    try
        Clauses = standalone_call(Clauses0),
        check_order(Clauses),
        {Out, _St} = clauses(Clauses, #st{}, []),
        {ok, #{query => Out,
               writes => lists:any(fun is_write/1, Clauses),
               params => lists:usort(collect_params(Clauses))}}
    catch throw:{sema, Msg, Loc} -> {error, err(Msg, Loc)}
    end.

%% 单独一条 CALL p()（不带 YIELD）：交出过程的全部输出列（等同 YIELD 全部 + RETURN 全部）。
standalone_call([{call_proc, Name, implicit, Y, W, Loc}]) ->
    %% 单独一条、不带括号的 CALL：参数取同名的查询参数（openCypher 的隐式参数）
    {_, ArgSpec, _} = proc_info(Name, Loc),
    standalone_call([{call_proc, Name, [{param, A, Loc} || {A, _} <- ArgSpec], Y, W, Loc}]);
standalone_call([{call_proc, Name, Args, Y, undefined, Loc}]) when Y =:= undefined; Y =:= all ->
    case proc_info(Name, Loc) of
        {[], _, _} ->
            %% 没有输出列的过程：结果没有列、没有行
            [{call_proc, Name, Args, [], undefined, Loc}];
        {Cols, _, _} ->
            Vars = [{var, C, Loc} || C <- Cols],
            [{call_proc, Name, Args, [{V, V} || V <- Vars], undefined, Loc},
             {return, false, {items, [{item, V, undefined} || V <- Vars]}, [], undefined, undefined, Loc}]
    end;
standalone_call([{call_proc, Name, Args, Ys, undefined, Loc}]) when is_list(Ys) ->
    %% openCypher：单独一条 CALL 的 YIELD 列表就是结果列（等同再 RETURN 这些名字）
    [{call_proc, Name, Args, Ys, undefined, Loc},
     {return, false, {items, [{item, A, undefined} || {_, A} <- Ys]}, [], undefined, undefined, Loc}];
standalone_call(Clauses) -> Clauses.

%% AST 里出现的全部参数名。累加器遍历：不把元组转成列表、不逐层拼接结果
%% （原写法每条查询要分配上百个中间列表，是文本查询的大头之一）。
collect_params(T) -> cp(T, []).

cp({param, P, _}, Acc) -> [P | Acc];
cp(T, Acc) when is_tuple(T) -> cp_tuple(T, tuple_size(T), Acc);
cp([H | T], Acc) -> cp(T, cp(H, Acc));
cp(_, Acc) -> Acc.

cp_tuple(_T, 0, Acc) -> Acc;
cp_tuple(T, I, Acc) -> cp_tuple(T, I - 1, cp(element(I, T), Acc)).

err(Msg, Loc) ->
    Base = bitcask_cypher_error:to_map(semantic, Msg),
    case Loc of
        {L, C} -> Base#{line => L, column => C};
        L when is_integer(L) -> Base#{line => L};
        _ -> Base
    end.

%% 语义错误都带 openCypher 错误类型与细节代码（bitcask_cypher_error）
fail(Type, Detail, Msg, Loc) -> throw({sema, bitcask_cypher_error:code(Type, Detail, Msg), Loc}).

is_write({create, _, _}) -> true;
is_write({set, _, _}) -> true;
is_write({remove, _, _}) -> true;
is_write({delete, _, _, _}) -> true;
is_write({merge, _, _, _, _}) -> true;
is_write({call_proc, Name, _, _, _, _}) ->
    case bitcask_cypher_registry:procedure(Name) of
        {ok, #{mode := write}} -> true;
        _ -> false
    end;
is_write(_) -> false.

loc_of(C) -> element(tuple_size(C), C).

%% 子句顺序：RETURN 只能在最后；不以 RETURN 结尾的必须以写子句结尾。
check_order(Clauses) ->
    Last = lists:last(Clauses),
    lists:foreach(fun(C) when element(1, C) =:= return, C =/= Last ->
                          fail('SyntaxError', 'InvalidClauseComposition', "RETURN must be the last clause", loc_of(C));
                     (_) -> ok
                  end, Clauses),
    case element(1, Last) of
        return -> ok;
        call_proc when element(5, Last) =:= undefined; element(5, Last) =:= [] ->
            %% 以没有输出列的过程结尾
            case catch proc_info(element(2, Last), loc_of(Last)) of
                {[], _, _} -> ok;
                _ -> fail('SyntaxError', 'InvalidClauseComposition', "query must end with RETURN or an updating clause", loc_of(Last))
            end;
        _ ->
            case is_write(Last) of
                true  -> ok;
                false -> fail('SyntaxError', 'InvalidClauseComposition', "query must end with RETURN or an updating clause", loc_of(Last))
            end
    end.

%% =========================================================================
%% 子句
%% =========================================================================

clauses([], St, Acc) -> {lists:reverse(Acc), St};
clauses([C | Rest], St, Acc) ->
    {C2, St2} = clause(C, St),
    clauses(Rest, St2, [C2 | Acc]).

clause({call_proc, Name, implicit, Yields, Where, Loc}, St0) ->
    %% 查询中间的 CALL 不带括号：只有无参过程可以（有参数的过程只能在单独一条 CALL 里隐式取参数）
    {_, ArgSpec0, _} = proc_info(Name, Loc),
    [] =:= [x || {_, required} <- ArgSpec0] orelse
        fail('SyntaxError', 'InvalidArgumentPassingMode',
             ["procedure `", Name, "` takes arguments: pass them in parentheses (implicit arguments only work "
              "in a standalone CALL)"], Loc),
    clause({call_proc, Name, [], Yields, Where, Loc}, St0);
clause({call_proc, Name, Args, Yields, Where, Loc}, St0) ->
    {Cols, ArgSpec, _Mode} = proc_info(Name, Loc),
    Required = length([x || {_, required} <- ArgSpec]),
    (length(Args) >= Required andalso length(Args) =< length(ArgSpec)) orelse
        fail('SyntaxError', 'InvalidNumberOfArguments', ["wrong number of arguments to procedure `", Name, "` (expected ",
              case Required =:= length(ArgSpec) of
                  true -> integer_to_list(Required);
                  false -> [integer_to_list(Required), "..", integer_to_list(length(ArgSpec))]
              end, ")"], Loc),
    Args2 = [begin no_aggregate(A, "aggregate functions are not allowed in procedure arguments", Loc),
                   expr(A, St0) end || A <- Args],
    check_arg_types(Name, Args2, St0, Loc),
    %% 没有输出列的过程（void）后面可以直接接别的子句：不改变行
    (Yields =:= undefined andalso Cols =/= []) andalso
        fail('SyntaxError', 'UndefinedVariable', "CALL followed by other clauses needs YIELD", Loc),
    Yields =:= all andalso fail('SyntaxError', 'UnexpectedSyntax', "YIELD * is only allowed in a standalone CALL", Loc),
    Yields1 = case Yields of
                  undefined -> [];
                  _ -> Yields
              end,
    {Pairs, St1} =
        lists:mapfoldl(fun({{var, C, CL}, {var, As, AL}}, S) ->
                               lists:member(C, Cols) orelse
                                   fail('SyntaxError', 'UndefinedVariable', ["procedure `", Name, "` has no output `", C, "`"], CL),
                               {{C, As}, declare(As, value, AL, S)}
                       end, St0, Yields1),
    Where2 = case Where of
                 undefined -> undefined;
                 W -> no_aggregate(W, "aggregate functions are not allowed in WHERE", Loc),
                      expr(preds(W, true), St1)
             end,
    {{call_proc, Name, Args2, Pairs, Where2, Loc}, St1};
clause({merge, Part, OnCreate, OnMatch, Loc}, St0) ->
    {Merge, St1} = merge_part(Part, Loc, St0),
    OnC = [set_item(I, Loc, St1) || I <- OnCreate],
    OnM = [set_item(I, Loc, St1) || I <- OnMatch],
    {case Merge of
         {node, V, Labels, Props} -> {merge_node, V, Labels, Props, OnC, OnM, Loc};
         {rel, From, R, Type, Props, Dir, To} -> {merge_rel, From, R, Type, Props, Dir, To, OnC, OnM, Loc};
         {pattern, Chain} -> {merge_pattern, Chain, OnC, OnM, Loc}
     end, St1};
clause({match, Optional, Parts, Where, Loc}, St0) ->
    put({?MODULE, bound_rels}, []),
    {Parts2, St1} = match_parts(Parts, St0),
    BoundRels = erase({?MODULE, bound_rels}),
    St2 = St1,
    Where1 = case Where of
                 undefined -> undefined;
                 W -> no_aggregate(W, "aggregate functions are not allowed in WHERE", Loc),
                      where_type(W, St2),
                      expr(preds(W, true), St2)
             end,
    Where2 = lists:foldl(fun({Anon, V}, undefined) -> {op, '=', {var, Anon}, {var, V}};
                            ({Anon, V}, Acc) -> {op, 'and', Acc, {op, '=', {var, Anon}, {var, V}}}
                         end, Where1, BoundRels),
    Tag = case Optional of true -> optional_match; false -> match end,
    {{Tag, Parts2, Where2, Loc}, St2};
clause({unwind, E, {var, Name, VLoc}, Loc}, St) ->
    no_aggregate(E, "aggregate functions are not allowed in UNWIND", Loc),
    E2 = expr(E, St),
    ElemKind = case E2 of
                   {list, [_ | _] = Es} ->
                       case lists:usort([static_kind(static_type(X, St)) || X <- Es]) of
                           [K] when K =/= value -> K;
                           _ -> value
                       end;
                   _ -> value
               end,
    St2 = declare(Name, ElemKind, VLoc, St),
    {{unwind, E2, Name, Loc}, St2};
clause({with, Distinct, Proj, Order, Skip, Limit, Where, Loc}, St) ->
    {Items, HasAgg, St2} = projection(Proj, with, Loc, St),
    {Order2, Skip2, Limit2} = paging(Order, Skip, Limit, Items, HasAgg orelse Distinct, Loc, St, St2),
    Where2 = case Where of
                 undefined -> undefined;
                 W -> no_aggregate(W, "aggregate functions are not allowed in WHERE", Loc),
                      %% 与 ORDER BY 同样的可见性（无聚合 / DISTINCT 时投影前的变量也可见）
                      post_proj_expr(preds(W, true), Items, HasAgg orelse Distinct, Loc, St, St2, "WHERE")
             end,
    {{with, Distinct, Items, HasAgg, Order2, Skip2, Limit2, Where2, Loc}, St2};
clause({return, Distinct, Proj, Order, Skip, Limit, Loc}, St) ->
    {Items, HasAgg, St2} = projection(Proj, return, Loc, St),
    {Order2, Skip2, Limit2} = paging(Order, Skip, Limit, Items, HasAgg orelse Distinct, Loc, St, St2),
    {{return, Distinct, Items, HasAgg, Order2, Skip2, Limit2, Loc}, St2};
clause({create, Parts, Loc}, St0) ->
    {Parts2, St1} = create_parts(Parts, Loc, St0),
    {{create, Parts2, Loc}, St1};
clause({set, Items, Loc}, St) ->
    Items2 = [set_item(I, Loc, St) || I <- Items],
    {{set, Items2, Loc}, St};
clause({remove, Items, Loc}, St) ->
    Items2 = [remove_item(I, St) || I <- Items],
    {{remove, Items2, Loc}, St};
clause({delete, Detach, Exprs, Loc}, St) ->
    [fail('SyntaxError', 'InvalidDelete', "DELETE takes nodes, relationships or paths; use REMOVE n:Label to remove labels", Loc)
     || {has_labels, _, _} <- Exprs],
    [fail('SyntaxError', 'InvalidArgumentType', ["DELETE takes nodes, relationships or paths, not a ", atom_to_list(T)], Loc)
     || E <- Exprs, T <- [static_type(E, St)], lists:member(T, [integer, float, string, boolean, map])],
    Es = [begin no_aggregate(E, "aggregate functions are not allowed in DELETE", Loc),
                expr(E, St) end || E <- Exprs],
    {{delete, Detach, Es, Loc}, St}.

%% 模式谓词不能引入新变量：命名的节点必须已绑定；关系变量不支持
check_pattern_pred({chain, N0, Steps}, L, St) ->
    lists:foreach(fun({node, {var, V, VL}, _, _, _}) ->
                          kind(V, St) =:= node orelse
                              fail('SyntaxError', 'UndefinedVariable', ["pattern predicates can't introduce new variables (`", V,
                                    "`); use OPTIONAL MATCH or a pattern comprehension"], VL);
                     ({node, undefined, _, _, _}) -> ok
                  end, [N0 | [N || {_, N} <- Steps]]),
    lists:foreach(fun({{rel, {var, V, VL}, _, _, _, _, _}, _}) ->
                          fail('SyntaxError', 'UndefinedVariable', ["relationship variables can't be used in pattern predicates (`", V, "`)"], VL);
                     (_) -> ok
                  end, Steps),
    _ = L,
    _ = match_part({part, undefined, {chain, N0, Steps}}, St, []),
    ok.

%% 图函数的参数：静态类型已知、又不是函数接受的类型 → 编译期类型错误。
fn_arg_types(Name, [A | _], L, St) ->
    Allowed = case Name of
                  <<"labels">> -> [node];
                  <<"type">> -> [relationship];
                  <<"startnode">> -> [relationship];
                  <<"endnode">> -> [relationship];
                  <<"properties">> -> [node, relationship, map];
                  <<"keys">> -> [node, relationship, map];
                  <<"nodes">> -> [path];
                  <<"relationships">> -> [path];
                  <<"length">> -> [path];
                  <<"size">> -> [list, string];
                  _ -> all
              end,
    case {Allowed, static_type(A, St)} of
        {all, _} -> ok;
        {_, _} when element(1, A) =:= pattern_pred ->
            %% size((a)-->()) 之类：模式不是值（openCypher：UnexpectedSyntax）
            fail('SyntaxError', 'UnexpectedSyntax', ["a pattern can't be an argument of ", Name, "()"], L);
        {_, T} when T =:= any; T =:= null -> ok;
        {_, T} -> lists:member(T, Allowed) orelse
                      fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type for ", Name, "(): ", atom_to_list(T)], L)
    end;
fn_arg_types(_, _, _, _) -> ok.

%% WHERE 的值静态看得出不是布尔（WHERE (n)、WHERE 1）→ 编译期类型错误。
where_type(W, St) ->
    case static_type(W, St) of
        T when T =:= boolean; T =:= any; T =:= null -> ok;
        T -> fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type: WHERE needs a boolean, not a ", atom_to_list(T)], undefined)
    end.

%% 布尔运算的操作数静态看得出不是布尔 → 编译期类型错误（openCypher：InvalidArgumentType）。
bool_operand(E, Op, St) ->
    case static_type(E, St) of
        T when T =:= boolean; T =:= null; T =:= any -> ok;
        T -> fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type for ", string:uppercase(atom_to_list(Op)), ": ", atom_to_list(T),
                   " (expected a boolean)"], undefined)
    end.

%% 静态类型（粗略）：字面量、列表 / 映射字面量、比较与布尔运算、已知种类的变量；别的是 any。
static_type({paren, E}, St) -> static_type(E, St);
static_type({lit, null}, _) -> null;
static_type({lit, B}, _) when is_boolean(B) -> boolean;
static_type({lit, I}, _) when is_integer(I) -> integer;
static_type({lit, F}, _) when is_float(F) -> float;
static_type({lit, X}, _) when X =:= 'NaN'; X =:= 'Infinity'; X =:= '-Infinity' -> float;
static_type({lit, S}, _) when is_binary(S) -> string;
static_type({list, _}, _) -> list;
static_type({map, _}, _) -> map;
static_type({op, Op, _, _}, _) when Op =:= 'and'; Op =:= 'or'; Op =:= 'xor'; Op =:= '='; Op =:= '<>'; Op =:= '<';
                                    Op =:= '<='; Op =:= '>'; Op =:= '>='; Op =:= in; Op =:= starts_with;
                                    Op =:= ends_with; Op =:= contains; Op =:= regex -> boolean;
static_type({unop, 'not', _}, _) -> boolean;
static_type({op, Op, A, B}, St) when Op =:= '+'; Op =:= '-'; Op =:= '*'; Op =:= '/'; Op =:= '%'; Op =:= '^' ->
    case {static_type(A, St), static_type(B, St)} of
        {_, _} when Op =:= '^' -> float;
        {integer, integer} -> integer;
        {X, Y} when (X =:= integer orelse X =:= float), (Y =:= integer orelse Y =:= float) -> float;
        {string, _} when Op =:= '+' -> string;
        {_, string} when Op =:= '+' -> string;
        {list, _} when Op =:= '+' -> list;
        {_, list} when Op =:= '+' -> list;
        _ -> any
    end;
static_type({pattern_pred_ok, _, _}, _) -> boolean;
static_type({pattern_pred, _, _}, _) -> boolean;
static_type({is_null, _, _}, _) -> boolean;
static_type({var, V}, St) -> static_type({var, V, undefined}, St);
static_type({var, V, _}, St) ->
    case kind(V, St) of
        node -> node;
        rel -> relationship;
        path -> path;
        rel_list -> list;
        list -> list;
        v_boolean -> boolean;
        v_integer -> integer;
        v_float -> float;
        v_string -> string;
        v_map -> map;
        _ -> any
    end;
static_type(_, _) -> any.

%% 过程的 {输出列, 参数说明 [{名, required | 缺省值}], read | write}：内置的 db.*，或注册的用户过程。
proc_info(Name, Loc) ->
    case maps:find(Name, ?PROCS) of
        {ok, Cs} -> {Cs, [], read};
        error ->
            case bitcask_cypher_registry:procedure(Name) of
                {ok, #{outputs := Outs, args := Args, mode := Mode}} -> {Outs, Args, Mode};
                error -> fail('ProcedureError', 'ProcedureNotFound', ["unknown procedure `", Name, "`"], Loc)
            end
    end.

%% 过程参数的静态类型检查（注册时声明了类型的参数）。
check_arg_types(Name, Args, St, Loc) ->
    Types = case bitcask_cypher_registry:procedure(Name) of
                {ok, #{types := Ts}} -> Ts;
                _ -> []
            end,
    [begin
         S = static_type(A, St),
         arg_type_ok(S, T) orelse
             fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type for procedure `", Name, "`: ", atom_to_list(S), " given, ",
                   atom_to_list(T), " expected"], Loc)
     end || {A, T} <- lists:zip(lists:sublist(Args, length(Types)), lists:sublist(Types, length(Args)))],
    ok.

arg_type_ok(S, _) when S =:= any; S =:= null -> true;
arg_type_ok(_, any) -> true;
arg_type_ok(integer, T) -> lists:member(T, [integer, float, number]);
arg_type_ok(float, T) -> lists:member(T, [float, number]);
arg_type_ok(S, T) -> S =:= T.

%% EXISTS { … }（以及内部的 COLLECT，shortestPath 表达式用）：子查询看得见全部外层变量（隐式导入），可以引入新变量，
%% 不能写。返回 {子句（或 {union, Mode, [子句]}）, COLLECT 的列名, 引用到的外层变量}。
subq(Kind, Body0, Loc, St) ->
    Body = case Body0 of
               {pattern_form, Parts0, Where, L} -> {query, [{match, false, Parts0, Where, L}]};
               B -> B
           end,
    Parts = case Body of
                {query, Cs} -> [Cs];
                {union, Ps} -> [element(2, P) || P <- Ps]
            end,
    Analysed =
        [begin
             lists:any(fun is_write/1, Cs) andalso
                 fail('SyntaxError', 'InvalidClauseComposition', ["updating clauses are not allowed in ", string:uppercase(atom_to_list(Kind)), " subqueries"], Loc),
             [fail('SyntaxError', 'InvalidClauseComposition', "RETURN must be the last clause", loc_of(C)) || C <- lists:droplast(Cs), element(1, C) =:= return],
             {Out, _} = clauses(Cs, St, []),
             Last = lists:last(Out),
             Col = case {Kind, element(1, Last)} of
                       {collect, return} ->
                           case element(3, Last) of
                               [{N, _}] -> N;
                               _ -> fail('SyntaxError', 'InvalidClauseComposition', "a COLLECT subquery must return exactly one column", loc_of(Last))
                           end;
                       {collect, _} -> fail('SyntaxError', 'InvalidClauseComposition', "a COLLECT subquery must end with RETURN", Loc);
                       _ -> undefined
                   end,
             {Out, Col}
         end || Cs <- Parts],
    Inner = case Analysed of
                [{O, _}] -> O;
                _ -> {union, case Body of {union, [_, {M, _, _} | _]} -> M end, [O || {O, _} <- Analysed]}
            end,
    [{_, Col1} | _] = Analysed,
    Visible = [V || {V, _} <- St#st.scope, not hidden(V)],
    Outer = [V || V <- Visible, mentions(V, Inner)],
    {Inner, Col1, Outer}.

uses_rand({call, <<"rand">>, _, _}) -> true;
uses_rand({call, <<"rand">>, _, _, _}) -> true;
uses_rand(E) -> lists:any(fun uses_rand/1, children(E)).

%% 项里有没有出现这个变量名（任何位置的同一个 binary；多算无害：只是多导入一个变量）。
mentions(V, V) -> true;
mentions(V, T) when is_tuple(T) -> mentions_list(V, tuple_to_list(T));
mentions(V, L) when is_list(L) -> mentions_list(V, L);
mentions(V, M) when is_map(M) -> mentions_list(V, maps:values(M));
mentions(_, _) -> false.

mentions_list(V, L) -> lists:any(fun(X) -> mentions(V, X) end, L).

set_item({set_prop, {var, V, L}, Key, E}, Loc, St) when is_binary(Key) ->
    must_be(V, [node, rel], L, St),
    reserved_key(Key, L),
    no_aggregate(E, "aggregate functions are not allowed in SET", Loc),
    {set_prop, V, Key, expr(E, St)};
%% 目标是一般的后缀表达式（m.node.p、(n).p）或键是表达式（n['k']）：执行时求出图元素与键
set_item({set_prop, Target, Key, E}, Loc, St) ->
    no_aggregate(E, "aggregate functions are not allowed in SET", Loc),
    {set_prop_x, expr(Target, St), set_key(Key, Loc, St), expr(E, St)};
set_item({set_props, {var, V, L}, E, Mode}, Loc, St) ->
    must_be(V, [node, rel], L, St),
    no_aggregate(E, "aggregate functions are not allowed in SET", Loc),
    {set_props, V, expr(E, St), Mode};
set_item({set_labels, {var, V, L}, Labels}, _Loc, St) ->
    must_be(V, [node], L, St),
    plain_labels(Labels, L),
    {set_labels, V, Labels}.

%% 写标签（CREATE / MERGE / SET / REMOVE）只能是普通标签，不能是 A|B、!A 这类表达式。
plain_labels(Labels, L) ->
    lists:all(fun is_binary/1, Labels) orelse
        fail('SyntaxError', 'UnexpectedSyntax', "label expressions (A|B, !A) can only be used for matching", L).

remove_item({remove_prop, {var, V, L}, Key}, St) when is_binary(Key) ->
    must_be(V, [node, rel], L, St),
    reserved_key(Key, L),
    {remove_prop, V, Key};
remove_item({remove_prop, Target, Key}, St) ->
    {set_prop_x, expr(Target, St), set_key(Key, undefined, St), {lit, null}};
remove_item({remove_labels, {var, V, L}, Labels}, St) ->
    must_be(V, [node], L, St),
    plain_labels(Labels, L),
    {remove_labels, V, Labels}.

set_key({dyn, KE}, _Loc, St) -> {dyn, expr(KE, St)};
set_key(K, Loc, _St) -> reserved_key(K, Loc), K.

reserved_key(<<"_", _/binary>> = K, L) ->
    fail('SemanticError', 'none', ["property names starting with `_` are reserved: ", K], L);
reserved_key(_, _) -> ok.

must_be(V, Kinds, L, St) ->
    case kind(V, St) of
        undefined -> fail('SyntaxError', 'UndefinedVariable', ["variable `", V, "` not defined"], L);
        %% 类型静态未知的值（UNWIND / FOREACH 的元素、列表下标等）：放行，执行时检查
        value -> ok;
        K -> lists:member(K, Kinds) orelse
                 fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` is not a ", kinds_text(Kinds)], L)
    end.

kinds_text([node])      -> "node";
kinds_text([node, rel]) -> "node or relationship".

%% =========================================================================
%% 模式
%% =========================================================================

%% MATCH 的模式：节点变量可以引用已绑定的节点（连接）；关系变量在同一个 MATCH 里只能出现一次，
%% 也不能复用之前绑定的关系变量。
match_parts(Parts, St0) ->
    [no_param_props(P) || P <- Parts],
    {Out, St, _RelsHere} =
        lists:foldl(fun(P, {Acc, S, Rels}) ->
                            {P2, S2, Rels2} = match_part(P, S, Rels),
                            {[P2 | Acc], S2, Rels2}
                    end, {[], St0, []}, Parts),
    {lists:reverse(Out), St}.

%% MATCH 的模式里属性不能是参数（MATCH (n $p)；openCypher：InvalidParameterUse）
no_param_props({part, _, {shortest, _, Chain, _}}) -> no_param_props({part, undefined, Chain});
no_param_props({part, _, {chain, N0, Steps}}) ->
    lists:foreach(fun({node, _, _, {param, _, L}, _}) -> param_props_fail(L);
                     ({rel, _, _, {param, _, L}, _, _, _}) -> param_props_fail(L);
                     (_) -> ok
                  end, [N0 | lists:append([[R, N] || {R, N} <- Steps])]);
no_param_props(_) -> ok.

-spec param_props_fail(term()) -> no_return().
param_props_fail(L) ->
    fail('SyntaxError', 'InvalidParameterUse', "a parameter can't be used as the properties of a MATCH pattern", L).

%% 路径搜索前缀（openCypher 2024.3）。单条变长关系上的 ANY SHORTEST / ALL SHORTEST 走最短路的 BFS（同 shortestPath /
%% allShortestPaths）；别的：照常匹配，再按 (起点, 终点) 分组、按长度挑（规划成 path_select）。路径变量没写就用隐藏的。
match_part({part, PathVar, {search, Mode, Chain, Loc}}, St0, Rels0) ->
    case {Mode, Chain} of
        {M, {chain, _, [{{rel, _, _, _, _, VarLen, _}, _}]}}
          when (M =:= any_shortest orelse M =:= all_shortest), VarLen =/= undefined ->
            Kind = case M of any_shortest -> single; all_shortest -> all end,
            match_part({part, PathVar, {shortest, Kind, Chain, Loc}}, St0, Rels0);
        _ ->
            {Chain2, St1, Rels1} = match_part({part, undefined, Chain}, St0, Rels0),
            {P, St2} = case PathVar of
                           undefined -> anon(St1);
                           {var, PV, PL} -> {PV, declare(PV, path, PL, St1)}
                       end,
            {{searched_chain, P, search_mode(Mode, Loc, St2), Chain2}, St2, Rels1}
    end;
match_part({part, PathVar, {shortest, Kind, Chain, Loc}}, St0, Rels0) ->
    Tag = case Kind of single -> shortest; all -> all_shortest end,
    case Chain of
        {chain, N0, [{Rel, N1}]} ->
            {N0b, St1} = node_pat(N0, St0),
            {N1b, St2} = node_pat(N1, St1),
            {Relb, St3, Rels1} = rel_pat(Rel, St2, Rels0, shortest),
            {P, St4} = case PathVar of
                           undefined -> {undefined, St3};
                           {var, PV, PL} -> {PV, declare(PV, path, PL, St3)}
                       end,
            {{Tag, P, N0b, Relb, N1b, Loc}, St4, Rels1};
        _ ->
            fail('SyntaxError', 'InvalidRelationshipPattern', "shortestPath needs exactly one relationship pattern", Loc)
    end;
match_part({part, {var, P, PL}, {chain, _, _} = Chain}, St0, Rels0) ->
    %% 普通命名路径（二期）：先照常检查模式，再声明路径变量
    {Chain2, St1, Rels1} = match_part({part, undefined, Chain}, St0, Rels0),
    {{named_chain, P, Chain2}, declare(P, path, PL, St1), Rels1};
match_part({part, undefined, {chain, N0, Steps}}, St0, Rels0) ->
    {N0b, St1} = node_pat(N0, St0),
    {Steps2, St2, Rels2} =
        lists:foldl(fun({{qpp, _, _, _, _, _} = Q, N}, {Acc, S, Rs}) ->
                            {Qb, S1, Rs1} = qpp_step(Q, S, Rs),
                            {Nb, S2} = node_pat(N, S1),
                            {[{Qb, Nb} | Acc], S2, Rs1};
                       ({Rel, N}, {Acc, S, Rs}) ->
                            {Relb, S1, Rs1} = rel_pat(Rel, S, Rs, match),
                            {Nb, S2} = node_pat(N, S1),
                            {[{Relb, Nb} | Acc], S2, Rs1}
                    end, {[], St1, Rels0}, Steps),
    {{chain, N0b, lists:reverse(Steps2)}, St2, Rels2}.

%% 量化组 ((x)-[r]->(y)){m,n}（openCypher 2024.3 的量化路径）：组体在临时作用域里检查（看得见外层变量；组里的变量
%% 是单个节点 / 关系，组的 WHERE 在这里检查）；回到外层后组里的具名变量是列表（每次重复一个值），不能与外层变量
%% 重名。组体里不能再有变长关系或量化组，至少一条关系。结果：{qpp, 组体链, WHERE, Min, Max, 关系列表变量}——关系
%% 列表变量（隐藏）装整段的关系，拼路径用。
qpp_step({qpp, {chain, _B0, BSteps} = Body, W, Min, Max, L}, St0, Rels0) ->
    BSteps =:= [] andalso
        fail('SyntaxError', 'InvalidRelationshipPattern', "a quantified path pattern needs at least one relationship", L),
    lists:foreach(fun({{qpp, _, _, _, _, QL}, _}) ->
                          fail('SyntaxError', 'InvalidRelationshipPattern', "quantified path patterns can't be nested", QL);
                     ({{rel, _, _, _, _, VL, RL}, _}) when VL =/= undefined ->
                          fail('SyntaxError', 'InvalidRelationshipPattern',
                               "a variable-length relationship can't be used inside a quantified path pattern", RL);
                     (_) -> ok
                  end, BSteps),
    (is_integer(Min) andalso Min >= 0 andalso (Max =:= infinity orelse (is_integer(Max) andalso Max >= Min)))
        orelse fail('SyntaxError', 'InvalidRelationshipPattern', "invalid quantifier bounds", L),
    Outer = [V || {V, _} <- St0#st.scope],
    {Body2, StB, Rels1} = match_part({part, undefined, Body}, St0, Rels0),
    Inner = [V || {V, _} <- StB#st.scope, not lists:member(V, Outer)],
    %% 组里写了外层已有的变量：不允许（组里的是每次重复各一个）
    [fail('SyntaxError', 'VariableAlreadyBound',
          ["variable `", V, "` is already bound outside the quantified path pattern"], L)
     || V <- part_vars(Body2), V =/= undefined, not hidden(V), lists:member(V, Outer)],
    W2 = case W of
             undefined -> undefined;
             _ -> no_aggregate(W, "aggregate functions are not allowed in WHERE", L),
                  where_type(W, StB),
                  expr(preds(W, true), StB)
         end,
    GroupVars = [V || V <- Inner, not hidden(V)],
    St1 = lists:foldl(fun(V, S) -> declare(V, list, L, S) end, St0#st{anon = StB#st.anon}, GroupVars),
    {RVar, St2} = anon(St1),
    {{qpp, Body2, W2, Min, Max, #{rels => RVar, vars => GroupVars}}, St2, Rels1}.

search_mode(M, _Loc, _St) when is_atom(M) -> M;
search_mode({M, K}, Loc, St) ->
    case K of
        {lit, N} when is_integer(N), N >= 0 -> ok;
        {param, _, _} -> ok;
        _ -> fail('SyntaxError', 'InvalidArgumentType', "the number of paths must be a non-negative integer", Loc)
    end,
    {M, expr(K, St)}.

node_pat({node, Var, Labels, Props, Loc}, St0) ->
    {Name, St1} = case Var of
                      undefined -> anon(St0);
                      {var, V, VL} ->
                          case kind(V, St0) of
                              undefined -> {V, declare(V, node, VL, St0)};
                              node      -> {V, St0};
                              %% 类型静态未知的值（UNWIND / FOREACH 元素、coalesce(…)、WITH null AS a…）当节点用：
                              %% 当作已绑定的节点，执行时检查
                              value     -> {V, St0};
                              K when ?IS_VALUE_KIND(K) ->
                                  fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` is not a node (type conflict)"], VL);
                              K -> fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` already declared as ", atom_to_list(K)], VL)
                          end
                  end,
    Props2 = props_expr(Props, Loc, St1),
    {{node, Name, Labels, Props2, Loc}, St1}.

rel_pat({rel, Var, Types, Props, Dir, VarLen, Loc}, St0, Rels, Ctx) ->
    {Min, Max} = varlen(VarLen, Ctx, Loc),
    Kind = case VarLen =:= undefined andalso Ctx =/= shortest of
               true  -> rel;
               false -> rel_list
           end,
    {Name, St1} = case Var of
                      undefined -> anon(St0);
                      {var, V, VL} ->
                          lists:member(V, Rels) andalso
                              fail('SyntaxError', 'RelationshipUniquenessViolation', ["relationship variable `", V, "` used twice in one MATCH"], VL),
                          case {kind(V, St0), Kind, Ctx} of
                              {undefined, _, _} -> {V, declare(V, Kind, VL, St0)};
                              %% 已绑定的关系（或关系列表）再出现在 MATCH 的模式里：模式用一个隐藏变量，
                              %% 子句的 WHERE 补一个「隐藏变量 = 已绑定的值」（openCypher：必须是同一条关系）
                              {K0, rel, match} when K0 =:= rel; K0 =:= value -> bound_rel(V, St0);
                              {K0, rel_list, match} when K0 =:= rel_list; K0 =:= value; K0 =:= list -> bound_rel(V, St0);
                              {K0, _, _} when ?IS_VALUE_KIND(K0) ->
                                  fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` is not a relationship (type conflict)"], VL);
                              _ -> fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` already declared"], VL)
                          end
                  end,
    Props2 = props_expr(Props, Loc, St1),
    %% 显式写了 *1..1：仍是变长（变量是关系列表），用 {list, 1} 标出，免得规划成单跳
    Max2 = case {Kind, Min, Max, Ctx} of {rel_list, 1, 1, C} when C =/= shortest -> {list, 1}; _ -> Max end,
    {{rel, Name, Types, Props2, Dir, {Min, Max2}, Loc}, St1, [Name | Rels]}.

bound_rel(V, St0) ->
    {Anon, St1} = anon(St0),
    put({?MODULE, bound_rels}, [{Anon, V} | case get({?MODULE, bound_rels}) of undefined -> []; L -> L end]),
    {Anon, St1}.

varlen(undefined, shortest, _Loc) -> {1, ?DEFAULT_MAX_HOPS};
varlen(undefined, _, _Loc) -> {1, 1};
varlen({Min0, Max0}, _, _Loc) ->
    Min = case Min0 of undefined -> 1; _ -> Min0 end,
    Max = case Max0 of undefined -> max(Min, ?DEFAULT_MAX_HOPS); _ -> Max0 end,
    %% 下界大于上界合法，只是匹配不出任何路径（openCypher）
    {Min, Max}.

props_expr(undefined, _Loc, _St) -> undefined;
props_expr({param, _, _} = P, _Loc, St) -> expr(P, St);
props_expr({where, _}, Loc, _St) ->
    fail('SyntaxError', 'UnexpectedSyntax', "WHERE inside a pattern is only allowed in MATCH, EXISTS { … } and pattern comprehensions", Loc);
props_expr({map, _} = M, Loc, St) ->
    no_aggregate(M, "aggregate functions are not allowed in patterns", Loc),
    expr(M, St).

create_parts(Parts, _Loc, St0) ->
    create_parts_(Parts, St0).

create_parts_(Parts, St0) ->
    lists:mapfoldl(
      fun({part, _, {shortest, _, _, L}}, _S) -> fail('SyntaxError', 'InvalidClauseComposition', "shortestPath is not allowed in CREATE", L);
         ({part, _, {search, _, _, L}}, _S) -> fail('SyntaxError', 'InvalidClauseComposition', "a path search prefix is not allowed in CREATE", L);
         ({part, {var, P, PL}, {chain, _, _} = C}, S) ->
              %% CREATE p = (…)：建完把路径绑到 p（规划成 build_path）
              kind(P, S) =:= undefined orelse fail('SyntaxError', 'VariableAlreadyBound', ["variable `", P, "` already declared"], PL),
              {[C2], S2} = create_parts_([{part, undefined, C}], S),
              {{named_chain, P, C2}, declare(P, path, PL, S2)};
         ({part, undefined, {chain, {node, {var, V, VL}, _, _, _} = N0, []}}, S) ->
              %% 单独一个已绑定的节点：CREATE (a) 没有可建的东西（openCypher：VariableAlreadyBound）
              kind(V, S) =:= undefined orelse fail('SyntaxError', 'VariableAlreadyBound', ["variable `", V, "` already declared (CREATE of a bound node)"], VL),
              {N0b, S1} = create_node(N0, S),
              {{chain, N0b, []}, S1};
         ({part, undefined, {chain, N0, Steps}}, S) ->
              {N0b, S1} = create_node(N0, S),
              {Steps2, S2} =
                  lists:mapfoldl(fun({{rel, RVar, Types, _, Dir, VarLen, RL} = Rel, N}, Sx) ->
                                         case RVar of
                                             {var, RV, RVL} ->
                                                 kind(RV, Sx) =:= undefined orelse
                                                     fail('SyntaxError', 'VariableAlreadyBound',
                                                          ["variable `", RV, "` already declared (CREATE can't reuse a bound relationship)"], RVL);
                                             _ -> ok
                                         end,
                                         VarLen =:= undefined orelse
                                             fail('SyntaxError', 'CreatingVarLength', "variable-length relationships are not allowed in CREATE", RL),
                                         Dir =:= both andalso
                                             fail('SyntaxError', 'RequiresDirectedRelationship', "CREATE needs a directed relationship", RL),
                                         is_list(Types) andalso length(Types) =:= 1 orelse
                                             fail('SyntaxError', 'NoSingleRelationshipType', "CREATE needs exactly one relationship type", RL),
                                         {Relb, Sy, _} = rel_pat(Rel, Sx, [], create),
                                         {Nb, Sz} = create_node(N, Sy),
                                         {{Relb, Nb}, Sz}
                                 end, S1, Steps),
              {{chain, N0b, Steps2}, S2}
      end, St0, Parts).

%% CREATE 里引用已绑定的节点只是「连到它」：不能再给它写标签 / 属性（那是 SET 的事）。
create_node({node, {var, V, VL}, Labels, Props, _} = N, St) ->
    case kind(V, St) of
        node when Labels =/= []; Props =/= undefined ->
            fail('SyntaxError', 'VariableAlreadyBound', ["can't add labels or properties to the already bound node `", V,
                  "` in CREATE; use SET"], VL);
        _ -> plain_labels(Labels, VL), node_pat(N, St)
    end;
create_node({node, _, Labels, _, L} = N, St) ->
    plain_labels(Labels, L),
    node_pat(N, St).

%% MERGE 的模式（第 5 节二期）：单个节点 (v:L {…})，或两端都是已绑定节点的单条有向关系
%% (a)-[r:T {…}]->(b)。新变量在这里声明；两端已绑定时不能再写标签 / 属性。
merge_part({part, {var, P, PL}, {chain, _, _} = C}, Loc, St0) ->
    %% MERGE p = (…)：按整条模式 MERGE，查到 / 建好后把路径绑到 p
    kind(P, St0) =:= undefined orelse fail('SyntaxError', 'VariableAlreadyBound', ["variable `", P, "` already declared"], PL),
    {{pattern, C2}, St1} = merge_whole(C, Loc, St0),
    {{pattern, {named_chain, P, C2}}, declare(P, path, PL, St1)};
merge_part({part, _, {search, _, _, L}}, _Loc, _St) ->
    fail('SyntaxError', 'InvalidClauseComposition', "a path search prefix is not allowed in MERGE", L);
merge_part({part, undefined, {shortest, _, _, L}}, _Loc, _St) ->
    fail('SyntaxError', 'InvalidClauseComposition', "shortestPath is not allowed in MERGE", L);
merge_part({part, undefined, {chain, {node, Var, Labels, Props, NL} = N, []}}, _Loc, St0) ->
    case Var of
        {var, V, VL} when V =/= undefined ->
            kind(V, St0) =:= undefined orelse
                fail('SyntaxError', 'VariableAlreadyBound', ["MERGE (", V, ") would merge an already bound variable; use MATCH or SET"], VL);
        _ -> ok
    end,
    merge_props_check(Props, NL),
    plain_labels(Labels, NL),
    {{node, Name, Labels, Props2, _}, St1} = node_pat(N, St0),
    {{node, Name, Labels, Props2}, St1};
merge_part({part, undefined, {chain, N0, [{_Rel, N1}]}} = Part, Loc, St0) ->
    case bound_plain(N0, St0) andalso bound_plain(N1, St0) of
        true  -> merge_rel_part(Part, Loc, St0);
        false -> merge_whole(element(3, Part), Loc, St0)
    end;
merge_part({part, undefined, {chain, _, [_, _ | _]} = C}, Loc, St0) ->
    merge_whole(C, Loc, St0);
merge_part({part, undefined, {chain, {node, _, _, _, L}, _}}, _Loc, _St) ->
    fail('SyntaxError', 'InvalidRelationshipPattern', "MERGE supports a single node, or a single relationship between two already bound nodes", L).

%% 已绑定、没写标签 / 属性的节点（两端都是这种时走单条关系的 MERGE）。
bound_plain({node, {var, V, _}, [], undefined, _}, St) -> kind(V, St) =:= node;
bound_plain(_, _St) -> false.

%% 整条模式的 MERGE（二期）：端点可以未绑定（带标签 / 属性）、可以多跳。整条匹配不上就把整条
%% 模式建出来（openCypher 语义：端点单独存在也会新建）。已绑定的端点不能再写标签 / 属性；
%% 关系要有向、一个类型、不是变长；属性只能是字面映射。
merge_whole({chain, N0, Steps} = Chain, _Loc, St0) ->
    lists:foreach(fun({node, Var, Labels, Props, NL}) ->
                          case Var of
                              {var, V, VL} ->
                                  case kind(V, St0) of
                                      undefined -> ok;
                                      node when Labels =:= [], Props =:= undefined -> ok;
                                      node -> fail('SyntaxError', 'VariableAlreadyBound', ["can't add labels or properties to the bound node `", V, "` in MERGE"], VL);
                                      K -> fail('SyntaxError', 'VariableTypeConflict', ["variable `", V, "` already declared as ", atom_to_list(K)], VL)
                                  end;
                              undefined -> ok
                          end,
                          plain_labels(Labels, NL),
                          merge_props_check(Props, NL)
                  end, [N0 | [N || {_, N} <- Steps]]),
    lists:foreach(fun({{rel, RVar, Types, RProps, _Dir, VarLen, RL}, _}) ->
                          merge_rel_unbound(RVar, St0),
                          VarLen =:= undefined orelse fail('SyntaxError', 'CreatingVarLength', "variable-length relationships are not allowed in MERGE", RL),
                          is_list(Types) andalso length(Types) =:= 1 orelse fail('SyntaxError', 'NoSingleRelationshipType', "MERGE needs exactly one relationship type", RL),
                          merge_props_check(RProps, RL),
                          case RVar of
                              {var, V, VL} -> kind(V, St0) =:= undefined orelse
                                                  fail('SyntaxError', 'VariableAlreadyBound', ["variable `", V, "` already declared"], VL);
                              undefined -> ok
                          end
                  end, Steps),
    {Chain2, St1, _} = match_part({part, undefined, Chain}, St0, []),
    {{pattern, Chain2}, St1}.

merge_rel_part({part, undefined, {chain, N0, [{{rel, RVar, Types, RProps, Dir, VarLen, RL}, N1}]}}, _Loc, St0) ->
    From = merge_endpoint(N0, St0),
    To = merge_endpoint(N1, St0),
    merge_rel_unbound(RVar, St0),
    VarLen =:= undefined orelse fail('SyntaxError', 'CreatingVarLength', "variable-length relationships are not allowed in MERGE", RL),
    is_list(Types) andalso length(Types) =:= 1 orelse fail('SyntaxError', 'NoSingleRelationshipType', "MERGE needs exactly one relationship type", RL),
    merge_props_check(RProps, RL),
    {{rel, R, [Type], RProps2, Dir, _, _}, St1, _} =
        rel_pat({rel, RVar, Types, RProps, Dir, undefined, RL}, St0, [], create),
    {{rel, From, R, Type, RProps2, Dir, To}, St1}.

%% MERGE 的关系变量不能是已绑定的（openCypher：VariableAlreadyBound）——先于类型等检查
merge_rel_unbound({var, V, VL}, St) ->
    kind(V, St) =:= undefined orelse
        fail('SyntaxError', 'VariableAlreadyBound', ["variable `", V, "` already declared (MERGE can't reuse a bound relationship)"], VL);
merge_rel_unbound(_, _) -> ok.

merge_endpoint({node, {var, V, VL}, Labels, Props, _}, St) ->
    case kind(V, St) of
        node when Labels =:= [], Props =:= undefined -> V;
        node -> fail('SyntaxError', 'VariableAlreadyBound', ["can't add labels or properties to the bound node `", V, "` in MERGE"], VL);
        _ -> fail('SyntaxError', 'InvalidRelationshipPattern', ["MERGE of a relationship needs `", V, "` to be an already bound node"], VL)
    end;
merge_endpoint({node, undefined, _, _, L}, _St) ->
    fail('SyntaxError', 'InvalidRelationshipPattern', "MERGE of a relationship needs both ends to be already bound nodes", L).

%% MERGE 的属性只能是字面映射（按值匹配），不能匹配向量。
merge_props_check(undefined, _L) -> ok;
merge_props_check({map, KEs}, L) ->
    lists:keymember(<<"embedding">>, 1, KEs) andalso fail('SyntaxError', 'InvalidParameterUse', "MERGE cannot match on `embedding`", L),
    ok;
merge_props_check(_, L) -> fail('SyntaxError', 'InvalidParameterUse', "MERGE properties must be a map literal", L).

%% =========================================================================
%% 投影（WITH / RETURN）
%% =========================================================================

%% {[{Name, Expr}], HasAgg, NewState}。WITH 之后的作用域只剩投影出来的名字；
%% RETURN 之后不再有子句。
projection(Proj, Which, Loc, St) ->
    {Star, Items0} = case Proj of
                         {star, Is}  -> {true, Is};
                         {items, Is} -> {false, Is}
                     end,
    StarItems = case Star of
                    true ->
                        Vs = [{V, {var, V}} || {V, _K} <- St#st.scope, not hidden(V)],
                        Vs =:= [] andalso Items0 =:= [] andalso
                            Which =:= return andalso
                            fail('SyntaxError', 'NoVariablesInScope', ["`", atom_to_list(Which), " *` with no variables in scope"], Loc),
                        Vs;
                    false -> []
                end,
    %% WITH 里没写别名的表达式：本身是聚合 → NoExpressionAlias；和聚合并列的非聚合表达式 → 分组键不明
    %% （AmbiguousAggregationExpression）
    AnyAgg = Which =:= with andalso
        lists:any(fun({item, E, _}) -> contains_aggregate(catch expr(E, St)) =:= true end, Items0),
    put({?MODULE, with_has_agg}, AnyAgg),
    Items = [item(I, Which, Loc, St) || I <- Items0],
    All = StarItems ++ Items,
    dup_names([N || {N, _} <- All], Loc),
    HasAgg = lists:any(fun({_, E}) -> contains_aggregate(E) end, All),
    lists:foreach(fun({_, E}) -> check_agg_nesting(E, Loc) end, All),
    HasAgg andalso begin
        Keys = [E || {_, E} <- All, not contains_aggregate(E)],
        KeyVars = [V || {var, V} <- Keys],
        [amb_agg(E, Keys, KeyVars, Loc) || {_, E} <- All, contains_aggregate(E)]
    end,
    Scope = [{N, item_kind(E, St)} || {N, E} <- All],
    {All, HasAgg, St#st{scope = Scope}}.

alias_detail(E2) ->
    case not contains_aggregate(E2) andalso get({?MODULE, with_has_agg}) =:= true of
        true -> 'AmbiguousAggregationExpression';
        false -> 'NoExpressionAlias'
    end.

item({item, E, Alias}, Which, Loc, St) ->
    E2 = expr(E, St),
    Name = case Alias of
               {var, A, _} -> A;
               {raw, Raw} ->
                   case E of
                       {var, V, _} -> V;
                       _ when Which =:= with ->
                           fail('SyntaxError', alias_detail(E2), ["expression in WITH must be aliased (use AS): ", expr_text(E)], Loc);
                       _ -> Raw
                   end;
               undefined ->
                   case E of
                       {var, V, _} -> V;
                       _ when Which =:= with ->
                           fail('SyntaxError', alias_detail(E2), ["expression in WITH must be aliased (use AS): ", expr_text(E)], Loc);
                       _ -> expr_text(E)
                   end
           end,
    {Name, E2}.

item_kind({var, V}, St) -> case kind(V, St) of undefined -> value; K -> K end;
item_kind(E, St) -> static_kind(static_type(E, St)).

%% 静态类型 → 变量种类：标量（布尔 / 数值 / 字符串 / 映射）不能当节点或关系用；列表可以当变长关系的值。
static_kind(boolean) -> v_boolean;
static_kind(integer) -> v_integer;
static_kind(float) -> v_float;
static_kind(string) -> v_string;
static_kind(map) -> v_map;
static_kind(list) -> list;
static_kind(_) -> value.

dup_names(Names, Loc) ->
    case Names -- lists:usort(Names) of
        [] -> ok;
        [D | _] -> fail('SyntaxError', 'ColumnNameConflict', ["duplicate column name `", D, "`"], Loc)
    end.

%% ORDER BY / SKIP / LIMIT。聚合或 DISTINCT 之后 ORDER BY 只能用投影出来的名字（或与某个
%% 投影项相同的表达式——改写成引用那一列）；否则投影前的变量也可用。
paging(Order, Skip, Limit, Items, Restricted, Loc, StBefore, StAfter) ->
    Order2 = [{order_expr(E, Items, Restricted, Loc, StBefore, StAfter), Dir} || {E, Dir} <- Order],
    {Order2, paging_expr(Skip, Loc), paging_expr(Limit, Loc)}.

order_expr(E, Items, Restricted, Loc, StBefore, StAfter) ->
    post_proj_expr(E, Items, Restricted, Loc, StBefore, StAfter, "ORDER BY").

%% 投影之后的 ORDER BY / WITH … WHERE（openCypher）：
%%   * 没有聚合、没有 DISTINCT：投影后的名字与投影前的变量都可见（同名时投影后的优先）；
%%   * 有聚合或 DISTINCT：只能用投影出来的列——但和某个投影项**相同的子表达式**会换成那一列
%%     （ORDER BY a.name + 'C' 在投影了 a.name AS name 时可以；avg(x) 已经投影时也可以）。
post_proj_expr(E, Items, Restricted, Loc, StBefore, StAfter, What) ->
    Merged = StAfter#st{scope = StAfter#st.scope ++ [P || {K, _} = P <- StBefore#st.scope,
                                                          not lists:keymember(K, 1, StAfter#st.scope)]},
    ItemMap = [{IE, N} || {N, IE} <- Items],
    E1 = expr(E, Merged),
    E2 = case lists:keyfind(E1, 1, ItemMap) of
             {_, N1} -> {var, N1};                       %% 整个表达式就是某个投影项
             false -> subst_items(E1, ItemMap)
         end,
    case Restricted of
        true ->
            Names = [N || {N, _} <- Items],
            contains_aggregate(E2) andalso
                fail('SyntaxError', 'UndefinedVariable', [What, " after aggregation can only use returned columns or aggregates that are returned"], Loc),
            case [V || V <- expr_vars(E2), not lists:member(V, Names)] of
                [] -> ok;
                Missing ->
                    %% 缺的变量都出现在分组键（不含聚合的投影项）里、表达式又含聚合：是把分组键表达式和聚合
                    %% 混在一起（AmbiguousAggregationExpression）；否则就是用了没投影的变量（UndefinedVariable）
                    KeyVars = lists:append([expr_vars(IE) || {_, IE} <- Items, not contains_aggregate(IE)]),
                    Detail = case contains_aggregate(E1) andalso lists:all(fun(V) -> lists:member(V, KeyVars) end, Missing) of
                                 true -> 'AmbiguousAggregationExpression';
                                 false -> 'UndefinedVariable'
                             end,
                    fail('SyntaxError', Detail, [What, " after aggregation or DISTINCT can only use returned columns"], Loc)
            end,
            E2;
        false ->
            no_aggregate(E, [What, ": aggregate functions here must also be returned"], Loc),
            E2
    end.

%% 规范化表达式里，和某个投影项相同的子表达式换成那一列的变量——只限简单表达式（变量、属性访问）
%% 与聚合；复杂的投影项不能在更大的表达式里复用（openCypher：AmbiguousAggregationExpression）。
subst_items(E, ItemMap) ->
    Simple = case E of {var, _} -> true; {prop, {var, _}, _} -> true; _ -> is_aggregate(E) end,
    case Simple andalso lists:keyfind(E, 1, ItemMap) of
        {_, N} -> {var, N};
        false when is_tuple(E), tuple_size(E) > 0, element(1, E) =/= var, element(1, E) =/= lit,
                   element(1, E) =/= param ->
            list_to_tuple([subst_items(X, ItemMap) || X <- tuple_to_list(E)]);
        false when is_list(E) -> [subst_items(X, ItemMap) || X <- E];
        false -> E
    end.


paging_expr(undefined, _Loc) -> undefined;
paging_expr(E, Loc) ->
    expr_vars(E) =:= [] orelse
        fail('SyntaxError', 'NonConstantExpression', "SKIP / LIMIT must not reference variables", Loc),
    case E of
        {lit, F} when is_float(F) -> fail('SyntaxError', 'InvalidArgumentType', "SKIP / LIMIT must be an integer", Loc);
        {lit, I} when is_integer(I), I < 0 -> fail('SyntaxError', 'NegativeIntegerArgument', "SKIP / LIMIT must not be negative", Loc);
        {unop, '-', {lit, X}} when is_number(X), X > 0 -> fail('SyntaxError', 'NegativeIntegerArgument', "SKIP / LIMIT must not be negative", Loc);
        {lit, V} when not is_integer(V), V =/= null -> fail('SyntaxError', 'InvalidArgumentType', "SKIP / LIMIT must be an integer", Loc);
        _ -> ok
    end,
    contains_aggregate(E) andalso fail('SyntaxError', 'InvalidAggregation', "aggregate functions are not allowed in SKIP / LIMIT", Loc),
    norm(E, #st{}).

%% =========================================================================
%% 表达式
%% =========================================================================

%% 检查变量与函数，去掉位置信息：{var, Name}、{param, Name}、{call, Name, Distinct, Args}。
expr(E0, St) ->
    E = preds(E0, false),
    check_expr(E, St),
    norm(E, St).

%% 模式谓词只能出现在谓词位置（openCypher）：WHERE 的根、其下的 AND / OR / XOR / NOT、exists(…)、
%% 推导 / 量词 / 模式推导的 WHERE 部分、CASE 的 WHEN。这些位置上的 {pattern_pred, …} 换成
%% {pattern_pred_ok, …}；剩下的（投影、函数参数里的）在 check_expr 里报错。幂等。
preds({pattern_pred, C, L}, true) -> {pattern_pred_ok, C, L};
preds({op, Op, A, B}, Ok) when Op =:= 'and'; Op =:= 'or'; Op =:= 'xor' -> {op, Op, preds(A, Ok), preds(B, Ok)};
preds({unop, 'not', A}, Ok) -> {unop, 'not', preds(A, Ok)};
preds({paren, E}, Ok) -> {paren, preds(E, Ok)};
preds({exists, P, L}, _) -> {exists, preds(P, true), L};
preds({list_comp, X, L, W, P}, _) -> {list_comp, X, preds(L, false), preds_opt(W), preds(P, false)};
preds({quant, K, X, L, Pred}, _) -> {quant, K, X, preds(L, false), preds(Pred, true)};
preds({pattern_comp, PVar, Chain, W, P, L}, _) -> {pattern_comp, PVar, Chain, preds_opt(W), preds(P, false), L};
preds({case_expr, Subj, Alts, Else, L}, _) ->
    {case_expr, preds(Subj, false), [{preds(W, Subj =:= undefined), preds(T, false)} || {W, T} <- Alts],
     preds(Else, false), L};
preds({pattern_pred, _, _} = E, false) -> E;
preds(T, _) when is_tuple(T), tuple_size(T) > 0 -> list_to_tuple([preds(X, false) || X <- tuple_to_list(T)]);
preds(L, _) when is_list(L) -> [preds(X, false) || X <- L];
preds(X, _) -> X.

preds_opt(undefined) -> undefined;
preds_opt(W) -> preds(W, true).

check_expr({var, V, L}, St) ->
    kind(V, St) =:= undefined andalso fail('SyntaxError', 'UndefinedVariable', ["variable `", V, "` not defined"], L),
    ok;
check_expr({param, _, _}, _St) -> ok;
check_expr({lit, V}, _St) when is_integer(V), V > 9223372036854775807 ->
    fail('SyntaxError', 'IntegerOverflow', "integer literal is too large (integers are 64-bit)", undefined);
check_expr({lit, _}, _St) -> ok;
check_expr({has_labels, Var, _}, St) -> check_expr(Var, St);
check_expr({prop, E, K}, St) ->
    %% 静态看得出是标量 / 列表 / 路径：取属性是编译期类型错误（openCypher：InvalidArgumentType）
    case static_type(E, St) of
        T when T =:= integer; T =:= float; T =:= string; T =:= boolean; T =:= list; T =:= path ->
            Ty = case T of path -> 'SyntaxError'; _ -> 'TypeError' end,
            fail(Ty, 'InvalidArgumentType', ["invalid argument type: can't read property `", K, "` of a ", atom_to_list(T)], undefined);
        _ -> check_expr(E, St)
    end;
check_expr({count_star, _}, _St) -> ok;
check_expr({call, Name, Distinct, Args, L}, St) ->
    case maps:find(Name, ?FUNS) of
        error ->
            case bitcask_cypher_registry:function(Name) of
                {ok, #{arity := As}} ->
                    lists:member(length(Args), As) orelse
                        fail('SyntaxError', 'InvalidNumberOfArguments', ["wrong number of arguments to `", Name, "`"], L);
                error -> fail('SyntaxError', 'UnknownFunction', ["unknown function `", Name, "`"], L)
            end;
        {ok, any} -> length(Args) >= 1 orelse fail('SyntaxError', 'InvalidNumberOfArguments', ["`", Name, "` needs arguments"], L);
        {ok, Arities} ->
            lists:member(length(Args), Arities) orelse
                fail('SyntaxError', 'InvalidNumberOfArguments', ["wrong number of arguments to `", Name, "`"], L)
    end,
    Distinct andalso not lists:member(Name, ?AGGS) andalso
        fail('SyntaxError', 'InvalidAggregation', ["DISTINCT is only allowed in aggregate functions, not `", Name, "`"], L),
    Name =:= <<"score">> andalso
        case Args of
            [{var, _, _}] -> ok;
            _ -> fail('SyntaxError', 'InvalidArgumentType', "score() takes a node variable", L)
        end,
    search_fn_args(Name, Args, L),
    fn_arg_types(Name, Args, L, St),
    [check_expr(A, St) || A <- Args],
    ok;
check_expr({list, Es}, St) -> [check_expr(E, St) || E <- Es], ok;
check_expr({map, KEs}, St) -> [check_expr(E, St) || {_, E} <- KEs], ok;
check_expr({paren, E}, St) -> check_expr(E, St);
check_expr({op, Op, A, B}, St) when Op =:= 'and'; Op =:= 'or'; Op =:= 'xor' ->
    [bool_operand(X, Op, St) || X <- [A, B]],
    check_expr(A, St), check_expr(B, St);
check_expr({op, in, A, B}, St) ->
    case static_type(B, St) of
        T when T =/= list, T =/= any, T =/= null ->
            fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type: IN needs a list on the right, not a ", atom_to_list(T)], undefined);
        _ -> ok
    end,
    check_expr(A, St), check_expr(B, St);
check_expr({op, Op, A, B}, St) when Op =:= '-'; Op =:= '*'; Op =:= '/'; Op =:= '%'; Op =:= '^' ->
    %% 算术：静态看得出是字符串 / 布尔 / 列表 / 映射 / 图元素 → 编译期类型错误
    [case static_type(X, St) of
         T when T =:= string; T =:= boolean; T =:= list; T =:= map; T =:= node; T =:= relationship; T =:= path ->
             fail('SyntaxError', 'InvalidArgumentType', ["invalid argument type for ", atom_to_list(Op), ": ", atom_to_list(T)], undefined);
         _ -> ok
     end || X <- [A, B]],
    check_expr(A, St), check_expr(B, St);
check_expr({op, _, A, B}, St) -> check_expr(A, St), check_expr(B, St);
check_expr({unop, '-', {lit, 9223372036854775808}}, _St) -> ok;     %% -9223372036854775808
check_expr({unop, 'not', A}, St) -> bool_operand(A, 'not', St), check_expr(A, St);
check_expr({unop, _, A}, St) -> check_expr(A, St);
check_expr({is_null, A, _}, St) -> check_expr(A, St);
check_expr({index, A, I}, St) -> check_expr(A, St), check_expr(I, St);
check_expr({list_comp, {var, X, _}, L, W, P}, St) ->
    check_expr(L, St),
    St2 = with_elem_local(X, L, St),
    [begin no_local_agg(E), check_expr(E, St2) end || E <- [W, P], E =/= undefined],
    ok;
check_expr({quant, _K, {var, X, _}, L, Pred}, St) ->
    check_expr(L, St),
    no_local_agg(Pred),
    check_expr(Pred, with_elem_local(X, L, St));
check_expr({reduce, {var, Acc, _}, Init, {var, X, _}, L, E}, St) ->
    check_expr(Init, St),
    check_expr(L, St),
    no_local_agg(E),
    check_expr(E, with_locals([Acc, X], St));
check_expr({exists, {prop, _, _} = P, _}, St) -> check_expr(P, St);
check_expr({exists, {pattern_pred_ok, _, _} = P, _}, St) -> check_expr(P, St);
check_expr({subq, Kind, Body, Loc}, St) -> _ = subq(Kind, Body, Loc, St), ok;
check_expr({pattern_pred, _, L}, _St) ->
    fail('SyntaxError', 'UnexpectedSyntax', "a pattern can only be used as a predicate (in WHERE, under AND / OR / NOT, or in exists(...))", L);
check_expr({pattern_pred_ok, Chain, L}, St) -> check_pattern_pred(Chain, L, St);
check_expr({exists, {pattern_pred, C, L}, EL}, St) -> check_expr({exists, {pattern_pred_ok, C, L}, EL}, St);
check_expr({pattern_comp, PVar, Chain, W, P, _L}, St) ->
    {_, St2, _} = match_part({part, PVar, Chain}, St, []),
    [begin no_local_agg(E), check_expr(E, St2) end || E <- [W, P], E =/= undefined],
    ok;
check_expr({exists, _, L}, _St) -> fail('SyntaxError', 'InvalidArgumentExpression', "exists() takes a property (n.prop) or a pattern", L);
check_expr({map_proj, {var, V, L} = Var, Items}, St) ->
    check_expr(Var, St),
    _ = L, _ = V,
    lists:foreach(fun({entry, _, E}) -> check_expr(E, St);
                     ({var_sel, VS}) -> check_expr(VS, St);
                     (_) -> ok
                  end, Items);
check_expr({slice, A, F, T}, St) ->
    check_expr(A, St),
    F =:= undefined orelse check_expr(F, St),
    T =:= undefined orelse check_expr(T, St),
    ok;
check_expr({case_expr, Subj, Alts, Else, _}, St) ->
    Subj =:= undefined orelse check_expr(Subj, St),
    [begin check_expr(W, St), check_expr(T, St) end || {W, T} <- Alts],
    Else =:= undefined orelse check_expr(Else, St),
    ok.

norm({var, V, _}, _St) -> {var, V};
norm({param, P, _}, _St) -> {param, P};
norm({lit, _} = L, _St) -> L;
norm({has_labels, {var, V, _}, Ls}, _St) -> {has_labels, {var, V}, Ls};
norm({prop, E, K}, St) -> {prop, norm(E, St), K};
norm({count_star, _}, _St) -> count_star;
norm({call, N, D, Args, _}, St) -> {call, N, D, [norm(A, St) || A <- Args]};
norm({list, Es}, St) -> {list, [norm(E, St) || E <- Es]};
norm({map, KEs}, St) -> {map, [{K, norm(E, St)} || {K, E} <- KEs]};
norm({paren, E}, St) -> norm(E, St);
norm({op, Op, A, B}, St) -> {op, Op, norm(A, St), norm(B, St)};
norm({unop, Op, A}, St) -> {unop, Op, norm(A, St)};
norm({is_null, A, B}, St) -> {is_null, norm(A, St), B};
norm({index, A, I}, St) -> {index, norm(A, St), norm(I, St)};
%% 局部变量在规范化时也要在作用域里（模式推导 / 子查询按作用域算引用的外层变量）
norm({list_comp, {var, X, _}, L, W, P}, St) ->
    St2 = with_elem_local(X, L, St),
    {list_comp, X, norm(L, St), norm_opt(W, St2), norm_opt(P, St2)};
norm({quant, K, {var, X, _}, L, Pred}, St) -> {quant, K, X, norm(L, St), norm(Pred, with_elem_local(X, L, St))};
norm({reduce, {var, Acc, _}, Init, {var, X, _}, L, E}, St) ->
    {reduce, Acc, norm(Init, St), X, norm(L, St), norm(E, with_locals([Acc, X], St))};
norm({exists, E, _}, St) -> {exists, norm(E, St)};
norm({subq, Kind, Body, Loc}, St) ->
    {Inner, Col, Outer} = subq(Kind, Body, Loc, St),
    {subq, Kind, Inner, Outer, Col};
norm({subq, _, _, _, _} = E, _St) -> E;
norm({pattern_pred, _, Outer} = E, _St) when is_list(Outer) -> E;
norm({pattern_pred_ok, Chain, L}, St) -> norm({pattern_pred, Chain, L}, St);
norm({pattern_pred, Chain, _}, St) ->
    {Chain2, _, _} = match_part({part, undefined, Chain}, St, []),
    Part = rename_anon(Chain2),
    {pattern_pred, Part, [V || V <- part_vars(Part), not hidden(V)]};
norm({pattern_comp, PVar, Chain, W, P, _}, St) ->
    {Part0, St2, _} = match_part({part, PVar, Chain}, St, []),
    Part = rename_anon(Part0),
    Wn = norm_opt(W, St2),
    Pn = norm(P, St2),
    Refs = lists:usort(part_vars(Part) ++ lists:append([expr_vars(E) || E <- [Wn, Pn], E =/= undefined])),
    {pattern_comp, Part, Wn, Pn, [V || V <- Refs, kind(V, St) =/= undefined]};
norm({pattern_comp, _, _, _, _} = E, _St) -> E;
norm({map_proj, Var, Items}, St) ->
    {map_proj, norm(Var, St), [case I of
                                   {entry, K, E} -> {entry, K, norm(E, St)};
                                   {var_sel, {var, N, _}} -> {var_sel, N};
                                   Other -> Other
                               end || I <- Items]};
norm({list_comp, _, _, _, _} = E, _St) -> E;
norm({quant, _, _, _, _} = E, _St) -> E;
norm({reduce, _, _, _, _, _} = E, _St) -> E;
norm({exists, _} = E, _St) -> E;
norm({slice, A, F, T}, St) -> {slice, norm(A, St), norm_opt(F, St), norm_opt(T, St)};
norm({case_expr, Subj, Alts, Else, _}, St) ->
    {case_expr, norm_opt(Subj, St), [{norm(W, St), norm(T, St)} || {W, T} <- Alts], norm_opt(Else, St)};
norm({case_expr, _, _, _} = C, _St) -> C;
%% 已经规范化过的（ORDER BY 改写成的 {var, N}）
norm({var, V}, _St) -> {var, V};
norm(count_star, _St) -> count_star.

%% 检索函数的第一个参数：fts.phrase / near / wildcard / fuzzy 要 n.text，fts.fields 与 search.hybrid 要顶点变量。
search_fn_args(Name, Args, L) when Name =:= <<"fts.phrase">>; Name =:= <<"fts.near">>;
                                   Name =:= <<"fts.wildcard">>; Name =:= <<"fts.fuzzy">> ->
    case Args of
        [{prop, {var, _, _}, <<"text">>} | _] -> ok;
        _ -> fail('SyntaxError', 'InvalidArgumentType', [Name, "() takes the node text as its first argument, e.g. ", Name, "(n.text, ...)"], L)
    end;
search_fn_args(Name, Args, L) when Name =:= <<"fts.fields">>; Name =:= <<"search.hybrid">> ->
    case Args of
        [{var, _, _} | _] -> ok;
        _ -> fail('SyntaxError', 'InvalidArgumentType', [Name, "() takes a node variable as its first argument"], L)
    end;
search_fn_args(_, _, _) -> ok.

norm_opt(undefined, _St) -> undefined;
norm_opt(E, St) -> norm(E, St).

is_aggregate({call, N, _, _, _}) -> lists:member(N, ?AGGS);
is_aggregate({call, N, _, _}) -> lists:member(N, ?AGGS);
is_aggregate({count_star, _}) -> true;
is_aggregate(count_star) -> true;
is_aggregate(_) -> false.

contains_aggregate(E) ->
    is_aggregate(E) orelse lists:any(fun contains_aggregate/1, children(E)).

children({paren, E}) -> [E];
children({pattern_pred_ok, _, _}) -> [];
children({has_labels, V, _}) -> [V];
children({prop, E, _}) -> [E];
children({call, _, _, Args, _}) -> Args;
children({call, _, _, Args}) -> Args;
children({list, Es}) -> Es;
children({map, KEs}) -> [E || {_, E} <- KEs];
children({op, _, A, B}) -> [A, B];
children({unop, _, A}) -> [A];
children({is_null, A, _}) -> [A];
children({index, A, I}) -> [A, I];
children({list_comp, _, L, W, P}) -> [L | [E || E <- [W, P], E =/= undefined]];
children({quant, _, _, L, Pred}) -> [L, Pred];
children({reduce, _, Init, _, L, E}) -> [Init, L, E];
children({exists, E, _}) -> [E];
children({exists, E}) -> [E];
children({subq, _, _, _}) -> [];         %% 子查询里的聚合属于子查询自己
children({subq, _, _, _, _}) -> [];
children({pattern_comp, _, _, W, P, _}) -> [E || E <- [W, P], E =/= undefined];
children({map_proj, Var, Items}) -> [Var | [E || {entry, _, E} <- Items] ++ [V || {var_sel, {var, _, _} = V} <- Items]];
children({slice, A, F, T}) -> [A | [X || X <- [F, T], X =/= undefined]];
children({case_expr, Subj, Alts, Else, _}) -> children({case_expr, Subj, Alts, Else});
children({case_expr, Subj, Alts, Else}) ->
    [S || S <- [Subj], S =/= undefined] ++ lists:append([[W, T] || {W, T} <- Alts])
        ++ [E || E <- [Else], E =/= undefined];
children(_) -> [].

%% 子模式（模式谓词 / 模式推导）里的匿名变量换成唯一的名字：免得与外层同号的匿名变量撞上、
%% 执行时被当成已绑定。
rename_anon(Part) ->
    Tag = integer_to_binary(erlang:unique_integer([positive])),
    R = fun(<<"  ", Rest/binary>>) -> <<"  p", Tag/binary, "_", Rest/binary>>; (V) -> V end,
    rn(Part, R).

rn({named_chain, P, C}, R) -> {named_chain, P, rn(C, R)};
rn({searched_chain, P, M, C}, R) -> {searched_chain, R(P), M, rn(C, R)};
rn({chain, N0, Steps}, R) -> {chain, rn(N0, R), [{rn(Rel, R), rn(N, R)} || {Rel, N} <- Steps]};
rn({node, V, Ls, Ps, L}, R) -> {node, R(V), Ls, Ps, L};
rn({rel, V, Ts, Ps, D, VL, L}, R) -> {rel, R(V), Ts, Ps, D, VL, L};
rn({qpp, Body, W, Min, Max, Info}, R) -> {qpp, rn(Body, R), W, Min, Max, Info}.

%% 子模式里出现的变量名（节点、关系、路径）。
part_vars({named_chain, P, C}) -> [P | part_vars(C)];
part_vars({searched_chain, P, _, C}) -> [P | part_vars(C)];
part_vars({chain, {node, V0, _, _, _}, Steps}) ->
    [V0 | lists:append([case R of
                            {rel, RV, _, _, _, _, _} -> [RV, NV];
                            {qpp, Body, _, _, _, _} -> part_vars(Body) ++ [NV]
                        end || {R, {node, NV, _, _, _}} <- Steps])].

%% 推导 / 量词 / reduce 里引用局部变量的部分不能有聚合。
no_local_agg(E) ->
    contains_aggregate(E) andalso
        fail('SyntaxError', 'InvalidAggregation', "aggregate functions are not allowed inside list comprehensions, quantifiers or reduce "
             "(apply them to the list instead)", undefined).

%% 局部变量（推导 / 量词 / reduce）：在当前作用域上覆盖同名变量。
%% 推导 / 量词的局部变量：列表是元素类型一致的字面量时带上元素的种类（静态类型检查用）。
with_elem_local(X, L, St) ->
    K = case L of
            {list, [_ | _] = Es} ->
                case lists:usort([static_kind(static_type(E, St)) || E <- Es]) of
                    [K0] -> K0;
                    _ -> value
                end;
            _ -> value
        end,
    #st{scope = S} = St1 = with_locals([X], St),
    St1#st{scope = lists:keyreplace(X, 1, S, {X, K})}.

with_locals(Names, #st{scope = S} = St) ->
    St#st{scope = [{N, value} || N <- Names] ++ [P || {K, _} = P <- S, not lists:member(K, Names)]}.

no_aggregate(E, Msg, Loc) ->
    contains_aggregate(E) andalso fail('SyntaxError', 'InvalidAggregation', Msg, Loc).

%% 含聚合的投影项里，聚合之外引用变量的部分必须是分组键（同一投影里不含聚合的项）或常量
%% （openCypher：AmbiguousAggregationExpression）。
amb_agg(E, Keys, KeyVars, Loc) ->
    OuterVars = expr_vars(strip_aggs(E)),          %% 聚合之外引用的变量
    %% 能在聚合表达式里复用的分组键只限简单表达式（变量、属性访问）；复杂的分组键不能复用（openCypher）
    SimpleKey = lists:member(E, Keys) andalso case E of {var, _} -> true; {prop, {var, _}, _} -> true; _ -> false end,
    case SimpleKey orelse is_aggregate(E) orelse OuterVars =:= [] of
        true -> ok;
        false ->
            case E of
                {var, _} -> amb_fail(Loc);
                {prop, _, _} -> amb_fail(Loc);
                _ when element(1, E) =:= list_comp; element(1, E) =:= quant; element(1, E) =:= reduce;
                       element(1, E) =:= map_proj; element(1, E) =:= pattern_comp; element(1, E) =:= subq;
                       element(1, E) =:= pattern_pred ->
                    lists:all(fun(V) -> lists:member(V, KeyVars) end, OuterVars) orelse amb_fail(Loc);
                _ -> [amb_agg(C, Keys, KeyVars, Loc) || C <- children(E)], ok
            end
    end.

%% 聚合子表达式换成常量（只看聚合之外的部分）。
strip_aggs(E) ->
    case is_aggregate(E) of
        true -> {lit, null};
        false when is_tuple(E), tuple_size(E) > 0, element(1, E) =/= var, element(1, E) =/= lit,
                   element(1, E) =/= param ->
            list_to_tuple([strip_aggs(X) || X <- tuple_to_list(E)]);
        false when is_list(E) -> [strip_aggs(X) || X <- E];
        false -> E
    end.

-spec amb_fail(term()) -> no_return().
amb_fail(Loc) ->
    fail('SyntaxError', 'AmbiguousAggregationExpression', "ambiguous aggregation: expressions next to an aggregate must be grouping keys (projected on their own) "
         "or constants", Loc).

check_agg_nesting(E, Loc) ->
    case is_aggregate(E) of
        true ->
            lists:any(fun contains_aggregate/1, children(E)) andalso
                fail('SyntaxError', 'NestedAggregation', "aggregate functions cannot be nested", Loc),
            mentions(<<"rand">>, [C || C <- children(E)]) andalso uses_rand(E) andalso
                fail('SyntaxError', 'NonConstantExpression', "aggregate functions need a deterministic argument (rand() is not allowed)", Loc);
        false ->
            [check_agg_nesting(C, Loc) || C <- children(E)],
            ok
    end.

%% 规范化表达式里引用的变量名（推导 / 量词 / reduce 的局部变量不算）。
expr_vars({var, V}) -> [V];
expr_vars({var, V, _}) -> [V];
expr_vars({list_comp, X, L, W, P}) ->
    lists:usort(expr_vars(L) ++ (lists:append([expr_vars(E) || E <- [W, P], E =/= undefined]) -- [X]));
expr_vars({quant, _, X, L, Pred}) -> lists:usort(expr_vars(L) ++ (expr_vars(Pred) -- [X]));
expr_vars({reduce, Acc, Init, X, L, E}) ->
    lists:usort(expr_vars(Init) ++ expr_vars(L) ++ (expr_vars(E) -- [Acc, X]));
expr_vars({pattern_pred, _, Outer}) when is_list(Outer) -> Outer;
expr_vars({subq, _, _, Outer, _}) -> Outer;
expr_vars({pattern_comp, _, _, _, Outer}) -> Outer;
expr_vars({map_proj, Var, Items}) ->
    lists:usort(expr_vars(Var) ++ lists:append([expr_vars(E) || {entry, _, E} <- Items])
                ++ [N || {var_sel, N} <- Items, is_binary(N)]);
expr_vars(E) -> lists:usort(lists:append([expr_vars(C) || C <- children(E)])).

%% =========================================================================
%% 作用域
%% =========================================================================

kind(V, #st{scope = S}) ->
    case lists:keyfind(V, 1, S) of
        {_, K} -> K;
        false  -> undefined
    end.

declare(V, Kind, L, #st{scope = S} = St) ->
    case lists:keyfind(V, 1, S) of
        false -> St#st{scope = S ++ [{V, Kind}]};
        _     -> fail('SyntaxError', 'VariableAlreadyBound', ["variable `", V, "` already declared"], L)
    end.

anon(#st{anon = N, scope = S} = St) ->
    Name = <<"  anon", (integer_to_binary(N))/binary>>,
    {Name, St#st{anon = N + 1, scope = S ++ [{Name, anon}]}}.

hidden(<<"  ", _/binary>>) -> true;
hidden(_) -> false.

%% =========================================================================
%% 列名：没有别名的投影项用表达式的源文本（规范写法）
%% =========================================================================

expr_text(E) -> iolist_to_binary(txt(E)).

txt({var, V, _}) -> V;
txt({var, V}) -> V;
txt({param, P, _}) -> ["$", P];
txt({param, P}) -> ["$", P];
txt({lit, null}) -> "null";
txt({lit, true}) -> "true";
txt({lit, false}) -> "false";
txt({lit, B}) when is_binary(B) -> ["'", B, "'"];
txt({lit, I}) when is_integer(I) -> integer_to_list(I);
txt({lit, F}) when is_float(F) -> float_to_list(F, [short]);
txt({has_labels, V, Ls}) -> [txt(V) | [[":", label_txt(L)] || L <- Ls]];
txt({index, A, I}) -> [txt(A), "[", txt(I), "]"];
txt({list_comp, X, L, W, P}) -> txt({list_comp_, var_txt(X), L, W, P});
txt({list_comp_, X, L, W, P}) ->
    ["[", X, " IN ", txt(L), case W of undefined -> ""; _ -> [" WHERE ", txt(W)] end,
     case P of undefined -> ""; _ -> [" | ", txt(P)] end, "]"];
txt({quant, K, X, L, Pred}) -> [atom_to_list(K), "(", var_txt(X), " IN ", txt(L), " WHERE ", txt(Pred), ")"];
txt({reduce, Acc, Init, X, L, E}) ->
    ["reduce(", var_txt(Acc), " = ", txt(Init), ", ", var_txt(X), " IN ", txt(L), " | ", txt(E), ")"];
txt({exists, E, _}) -> ["exists(", txt(E), ")"];
txt({exists, E}) -> ["exists(", txt(E), ")"];
txt({subq, Kind, _, _}) -> [string:uppercase(atom_to_list(Kind)), <<" { … }"/utf8>>];
txt({subq, Kind, _, _, _}) -> [string:uppercase(atom_to_list(Kind)), <<" { … }"/utf8>>];
txt({pattern_pred, C, _}) -> pat_txt(C);
txt({pattern_pred_ok, C, _}) -> pat_txt(C);
txt({pattern_comp, PVar, C, W, P, _}) ->
    ["[", case PVar of undefined -> ""; _ -> [var_txt(PVar), " = "] end, pat_txt(C),
     case W of undefined -> ""; _ -> [" WHERE ", txt(W)] end, " | ", txt(P), "]"];
txt({pattern_comp, Part, W, P, _}) ->
    ["[", pat_txt(Part), case W of undefined -> ""; _ -> [" WHERE ", txt(W)] end, " | ", txt(P), "]"];
txt({map_proj, Var, Items}) ->
    [txt(Var), " {", join([case I of
                                {prop_sel, K} -> [".", K];
                                all_props -> ".*";
                                {entry, K, E} -> [K, ": ", txt(E)];
                                {var_sel, V} -> var_txt(V)
                            end || I <- Items], ", "), "}"];
txt({slice, A, F, T}) ->
    [txt(A), "[", case F of undefined -> ""; _ -> txt(F) end, "..",
     case T of undefined -> ""; _ -> txt(T) end, "]"];
txt({prop, E, K}) -> [txt(E), ".", K];
txt({count_star, _}) -> "count(*)";
txt(count_star) -> "count(*)";
txt({call, N, D, Args, _}) -> txt({call, N, D, Args});
txt({call, N, D, Args}) ->
    [N, "(", case D of true -> "DISTINCT "; false -> "" end, join([txt(A) || A <- Args], ", "), ")"];
txt({list, Es}) -> ["[", join([txt(E) || E <- Es], ", "), "]"];
txt({map, KEs}) -> ["{", join([[K, ": ", txt(E)] || {K, E} <- KEs], ", "), "}"];
txt({paren, E}) -> ["(", txt(E), ")"];
txt({op, Op, A, B}) -> [txt(A), " ", op_text(Op), " ", txt(B)];
txt({unop, 'not', A}) -> ["NOT ", txt(A)];
txt({unop, '-', A}) -> ["-", txt(A)];
txt({is_null, A, true}) -> [txt(A), " IS NULL"];
txt({is_null, A, false}) -> [txt(A), " IS NOT NULL"];
txt({case_expr, Subj, Alts, Else, _}) -> txt({case_expr, Subj, Alts, Else});
txt({case_expr, Subj, Alts, Else}) ->
    ["CASE", case Subj of undefined -> ""; _ -> [" ", txt(Subj)] end,
     [[" WHEN ", txt(W), " THEN ", txt(T)] || {W, T} <- Alts],
     case Else of undefined -> ""; _ -> [" ELSE ", txt(Else)] end, " END"].

op_text('and') -> "AND";
op_text('or') -> "OR";
op_text('xor') -> "XOR";
op_text(in) -> "IN";
op_text(starts_with) -> "STARTS WITH";
op_text(ends_with) -> "ENDS WITH";
op_text(contains) -> "CONTAINS";
op_text(regex) -> "=~";
op_text(Op) -> atom_to_list(Op).

%% 模式的源文本形态（列名用）。
pat_txt({named_chain, P, C}) -> [var_txt(P), " = ", pat_txt(C)];
pat_txt({searched_chain, _P, _M, C}) -> pat_txt(C);
pat_txt({chain, N0, Steps}) -> [node_txt(N0) | [[rel_txt(Rel), node_txt(N)] || {Rel, N} <- Steps]].

node_txt({node, V, Ls, Ps, _}) ->
    ["(", case V of undefined -> ""; _ -> name_txt(V) end, [[":", label_txt(L)] || L <- Ls],
     case Ps of undefined -> ""; _ -> [" ", txt(Ps)] end, ")"].

rel_txt({qpp, Body, _W, Min, Max, _}) ->
    [" (", pat_txt(Body), "){", integer_to_list(Min), ",", case Max of infinity -> ""; _ -> integer_to_list(Max) end, "} "];
rel_txt({rel, V, Ts, Ps, Dir, VarLen, _}) ->
    Inner = [case V of undefined -> ""; _ -> name_txt(V) end,
             case Ts of
                 [] -> "";
                 {lexpr, T} -> [":", label_txt(T)];
                 _ -> [":", join(Ts, "|")]
             end,
             case VarLen of
                 undefined -> ""; {1, 1} -> "";
                 {A, {list, B}} -> ["*", integer_to_list(A), "..", integer_to_list(B)];
                 {A, B} -> ["*", case A of undefined -> ""; _ -> integer_to_list(A) end, "..",
                            case B of undefined -> ""; _ -> integer_to_list(B) end]
             end,
             case Ps of undefined -> ""; _ -> [" ", txt(Ps)] end],
    Body = case iolist_size(Inner) of 0 -> "-"; _ -> ["-[", Inner, "]-"] end,
    case Dir of out -> [Body, ">"]; in -> ["<", Body]; both -> Body end.

name_txt({var, V, _}) -> V;
name_txt(<<"  ", _/binary>>) -> "";
name_txt(V) when is_binary(V) -> V.

var_txt({var, V, _}) -> V;
var_txt({var, V}) -> V;
var_txt(V) when is_binary(V) -> V.

label_txt({any, Ls}) -> join([label_txt(L) || L <- Ls], "|");
label_txt({'not', L}) -> ["!", label_txt(L)];
label_txt({all, Ls}) -> join([label_txt(L) || L <- Ls], "&");
label_txt(wildcard) -> "%";
label_txt(L) -> L.

join([], _) -> [];
join([X], _) -> [X];
join([X | Xs], Sep) -> [X, Sep | join(Xs, Sep)].
