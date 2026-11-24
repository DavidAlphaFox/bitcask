%% =========================================================================
%% bitcask_cypher — 图查询语言（openCypher 子集）的对外入口
%%
%% 设计：doc/cypher-query-design-zh.md；使用说明：doc/cypher-zh.md / doc/cypher-en.md。
%% 读：MATCH（多个模式、变长、shortestPath）、WHERE、WITH、UNWIND、RETURN（DISTINCT / 聚合 /
%% ORDER BY / SKIP / LIMIT）；写：CREATE / SET / REMOVE / DELETE / DETACH DELETE；检索：
%% v.text @@ '…'（全文）、v.embedding <=> $q（向量距离）、score(v)。
%% 与图层 API 共用一套数据模型（graphdb_model）：同一个 id 空间、同一份标签索引。
%%
%% 写语句（第 8 节）：整条语句在一个 bitcask_txn 事务里执行——读都带锁和版本守卫，写进
%% 缓冲，提交时一条原子批；冲突 / 死锁由事务层整条重跑（语句必须没有外部副作用，它也确实
%% 没有）。在 graphdb:transaction/2 里把事务（Tx）当第一个参数传进来时，语句加入那个事务、
%% 读得到它之前的写；语句出错时整个事务中止（{aborted, {cypher, Error}}）。
%%
%%   q(HandleOrTx, Query)          -> {ok, Result} | {error, Error}
%%   q(HandleOrTx, Query, Params)  -> 同上；Params :: #{binary() | atom() => Value}
%%   q(Handle, Query, Params, Opts)-> Opts 传给写语句的事务（retries / timeout /
%%                                    lock_wait_timeout / sync，缺省 [{sync, no_sync}]）
%%   prepare(Handle, Query)    -> {ok, Prepared} | {error, Error}   解析 + 检查一次，多次执行
%%   explain(Handle, Query)    -> {ok, PlanTerm} | {error, Error}
%%   writes(Query | Prepared)  -> boolean()
%%
%%   Result :: #{columns := [binary()], rows := [[Value]], stats := map()}
%%   Error  :: #{stage := parse | semantic | plan | exec, message := binary(),
%%               line => L, column => C}
%%
%% 值：null | true | false | 整数 | 浮点 | binary（字符串）| 列表 | map；顶点
%% #{id, labels, properties}，边 #{src, type, dst, rank, properties}，路径
%% #{nodes, relationships}。参数里的 undefined 视同 null，atom key 转 binary。
%% =========================================================================
-module(bitcask_cypher).

-export([q/2, q/3, q/4, prepare/2, explain/2, writes/1, parse/1,
         cursor/2, cursor/3, cursor/4, fetch/2, columns/1, close/1,
         register_procedure/2, register_function/2, unregister/1, registered/0]).

%% 用户过程 / 函数（全节点范围；见 bitcask_cypher_registry 与 doc/cypher-zh.md「扩展」一节）。
register_procedure(Name, Spec) -> bitcask_cypher_registry:register_procedure(Name, Spec).
register_function(Name, Spec) -> bitcask_cypher_registry:register_function(Name, Spec).
unregister(Name) -> bitcask_cypher_registry:unregister(Name).
registered() -> bitcask_cypher_registry:list().

-define(PLAN_CACHE, {?MODULE, plan_cache}).
-define(PLAN_CACHE_MAX, 128).

-record(bitcask_cypher_prepared, {text :: binary(), analysis :: map(), plan :: term()}).

q(Target, Query) -> q(Target, Query, #{}).

q(Target, Query, Params) -> q(Target, Query, Params, []).

q(Target, Query, Params, Opts) when is_map(Params), is_list(Opts) ->
    ok = bitcask_cypher_values:ensure_registered(),
    case prepared(Query) of
        {error, _} = E -> E;
        {ok, #bitcask_cypher_prepared{analysis = A, plan = Plan}} ->
            case Plan of
                {error, _} = E -> E;
                _ ->
                    P = norm_params(Params),
                    case [N || N <- maps:get(params, A), not is_map_key(N, P)] of
                        [] -> run(Target, Plan, P, maps:get(writes, A), Opts);
                        Missing ->
                            {error, bitcask_cypher_error:to_map(semantic, bitcask_cypher_error:code(
                                      'ParameterMissing', 'MissingParameter',
                                      ["missing parameter(s): ", lists:join(", ", [["$", M] || M <- Missing])]))}
                    end
            end
    end.

is_txn(T) -> is_tuple(T) andalso element(1, T) =:= bitcask_txn_ctx.

%% 只读语句 + 句柄：直接读。调用方的事务：加入它。写语句 + 句柄：自己开一个事务。
run(Tx, Plan, P, Writes, _Opts) ->
    case is_txn(Tx) of
        true ->
            case register_types(bitcask_txn:handle(Tx), Plan, spawned) of
                ok ->
                    case bitcask_cypher_exec:run_io({txn, Tx}, Plan, P) of
                        {ok, _} = Ok -> Ok;
                        {error, E} when Writes -> bitcask_txn:abort({cypher, E});
                        {error, _} = Err -> Err
                    end;
                {error, E} -> bitcask_txn:abort({cypher, E})
            end;
        false when not Writes ->
            bitcask_cypher_exec:run(Tx, Plan, P);
        false ->
            write_statement(Tx, Plan, P, _Opts)
    end.

write_statement(H, Plan, P, Opts) ->
    case register_types(H, Plan, direct) of
        {error, _} = E -> E;
        ok ->
            TxOpts0 = case lists:keymember(sync, 1, Opts) of
                          true  -> Opts;
                          false -> [{sync, no_sync} | Opts]       %% 同其它写入口：按句柄的同步策略
                      end,
            %% 读只靠版本守卫、不拿读锁（提交时校验；写照旧加锁）——一条语句是一个很短的
            %% 事务，冲突少，省掉的是每个读到的顶点 / 表头一次锁服务往返。
            TxOpts = case lists:keymember(read_locks, 1, TxOpts0) of
                         true  -> TxOpts0;
                         false -> [{read_locks, guard_only} | TxOpts0]
                     end,
            Fun = fun(Tx) ->
                          case bitcask_cypher_exec:run_io({txn, Tx}, Plan, P) of
                              {ok, R}    -> R;
                              {error, E} -> bitcask_txn:abort({cypher, E})
                          end
                  end,
            case graphdb:transaction(H, Fun, TxOpts) of
                {atomic, R}                -> {ok, R};
                {aborted, {cypher, E}}     -> {error, E};
                {aborted, Why}             -> {error, #{stage => exec,
                                                        message => iolist_to_binary(
                                                                     io_lib:format("transaction aborted: ~p", [Why]))}}
            end
    end.

%% CREATE 用到的关系类型先注册好（幂等；在语句的事务之外做——事务不能嵌套。调用方的事务里
%% 则在另一个进程里注册）。
register_types(H, {plan, Ops0, _}, How) ->
    Ops = bitcask_cypher_plan:all_ops(Ops0),
    Names = lists:usort([T || {create, Chains} <- Ops, {chain, _, Steps} <- Chains,
                              {{rel, _, [T], _, _, _, _}, _} <- Steps]
                        ++ [T || {merge_rel, _, _, T, _, _, _, _, _} <- Ops]
                        ++ [T || {merge_pattern, _, {chain, _, Steps}, _, _} <- Ops,
                                 {{rel, _, [T], _, _, _, _}, _} <- Steps]),
    register_each(H, Names, How).

register_each(_H, [], _How) -> ok;
register_each(H, [N | Rest], How) ->
    case graphdb:etype_id(H, N) of
        {ok, _} -> register_each(H, Rest, How);
        _ ->
            R = case How of
                    direct -> graphdb:register_etype(H, N);
                    spawned ->
                        {Pid, Ref} = spawn_monitor(fun() -> exit({result, graphdb:register_etype(H, N)}) end),
                        receive {'DOWN', Ref, process, Pid, {result, X}} -> X;
                                {'DOWN', Ref, process, Pid, Other} -> {error, Other}
                        end
                end,
            case R of
                {ok, _} -> register_each(H, Rest, How);
                {error, Why} ->
                    {error, #{stage => exec,
                              message => iolist_to_binary(io_lib:format("cannot register relationship type ~ts: ~p",
                                                                        [N, Why]))}}
            end
    end.

prepare(_Handle, Query) ->
    ok = bitcask_cypher_values:ensure_registered(), prepared(Query).

explain(_Handle, Query) ->
    ok = bitcask_cypher_values:ensure_registered(),
    case prepared(Query) of
        {error, _} = E -> E;
        {ok, #bitcask_cypher_prepared{plan = {error, _} = E}} -> E;
        {ok, #bitcask_cypher_prepared{plan = {plan, Ops, Cols}}} ->
            {ok, #{ops => Ops, columns => Cols}}
    end.

writes(#bitcask_cypher_prepared{analysis = #{writes := W}}) -> W;
writes(Query) ->
    case parse(Query) of
        {ok, #{writes := W}} -> W;
        {error, _} = E       -> erlang:error({bad_query, E})
    end.

%% 文本 → 语义检查后的分析结果（不规划）。
parse(Query) ->
    Text = text(Query),
    Src = unicode:characters_to_list(Text),
    case bitcask_cypher_lexer:string(Src, 1) of
        {ok, Tokens00, End} ->
            Tokens0 = raw_items(drop_set_all(soft_keywords(Tokens00)), Src),
            Tokens = mark_patterns(Tokens0),
            case bitcask_cypher_parser:parse(Tokens ++ [{'$end', End}]) of
                {ok, Ast} -> bitcask_cypher_sema:analyze(Ast);
                {error, {Loc, _Mod, Msg}} ->
                    SynText = syntax_msg(Msg, Loc, Tokens),
                    {error, loc_err(parse, case in_varlen(Loc, Tokens) of
                                               true -> bitcask_cypher_error:code('SyntaxError', 'InvalidRelationshipPattern', SynText);
                                               false -> SynText
                                           end, Loc)}
            end;
        {error, {Loc, _Mod, {user, {cypher_code, _, _, _} = Coded}}, _} ->
            {error, loc_err(parse, Coded, Loc)};
        {error, {Loc, Mod, {illegal, Chars} = Desc}, _} ->
            %% 非 ASCII 的怪字符（全角破折号 — 当减号用等）：InvalidUnicodeCharacter
            Msg = Mod:format_error(Desc),
            {error, loc_err(parse, case lists:any(fun(C) -> C > 127 end, Chars) of
                                       true -> bitcask_cypher_error:code('SyntaxError', 'InvalidUnicodeCharacter', Msg);
                                       false -> Msg
                                   end, Loc)};
        {error, {Loc, Mod, Desc}, _} ->
            {error, loc_err(parse, Mod:format_error(Desc), Loc)}
    end.

%% yecc 的报错文本把记号值原样 write 出来（<<"RETURN">>）；换成源文本里的写法。
%% 语法动作里 return_error 给出的自定义文本原样保留。
syntax_msg(Msg, Loc, Tokens) ->
    case Msg of
        ["syntax error before: " | _] -> syntax_near(Msg, Loc, Tokens);
        _                             -> Msg
    end.

syntax_near(Msg, Loc, Tokens) ->
    case lists:keyfind(Loc, 2, Tokens) of
        false ->
            case Msg of
                [_, []] -> "unexpected end of query";
                _       -> unexpected_end_or(Msg)
            end;
        Tok -> ["syntax error near ", token_text(Tok)]
    end.

unexpected_end_or(Msg) ->
    case lists:flatten(io_lib:format("~ts", [Msg])) of
        "syntax error before: " ++ _ -> "unexpected end of query";
        Other -> Other
    end.

token_text({string, _, V}) -> ["'", V, "'"];
token_text({int, _, V}) -> integer_to_list(V);
token_text({float, _, V}) -> float_to_list(V, [short]);
token_text({param, _, V}) -> ["$", V];
token_text({_Cat, _, V}) when is_binary(V) -> ["`", V, "`"];
token_text({'$end', _}) -> "end of query";
token_text({Cat, _}) -> ["`", atom_to_list(Cat), "`"].

prepared(#bitcask_cypher_prepared{} = P) -> {ok, P};
prepared(Query) ->
    %% 按查询文本缓存解析 + 规划的结果（调用进程的进程字典，至多 ?PLAN_CACHE_MAX 条，满了
    %% 整体清空重来）。计划与参数值无关，同一段文本反复执行时省掉词法 / 语法 / 语义 / 规划
    %% （一跳查询 19 µs 里约 12 µs）。只缓存成功的结果：出错的查询照常每次报错。
    Text = text(Query),
    %% 用户过程 / 函数的注册表一变（名字解析结果可能不同），缓存整体作废
    Gen = bitcask_cypher_registry:generation(),
    Cache = case get(?PLAN_CACHE) of
                {Gen, C} -> C;
                _ -> #{}
            end,
    case Cache of
        #{Text := P} -> {ok, P};
        _ ->
            case prepare_text(Text) of
                {ok, P} = Ok ->
                    put(?PLAN_CACHE, {Gen, case map_size(Cache) >= ?PLAN_CACHE_MAX of
                                               true  -> #{Text => P};
                                               false -> Cache#{Text => P}
                                           end}),
                    Ok;
                Err -> Err
            end
    end.

prepare_text(Query) ->
    case parse(Query) of
        {error, _} = E -> E;
        {ok, A} ->
            Plan = case bitcask_cypher_plan:plan(A) of
                       {ok, Pl} -> Pl;
                       {error, _} = E -> E
                   end,
            {ok, #bitcask_cypher_prepared{text = text(Query), analysis = A, plan = Plan}}
    end.

%% ---- 关键字当变量名（openCypher 2024.3：关键字都不保留）------------------------
%% LALR 文法里让每个关键字都能当变量会到处冲突，这里按上下文把「这里不可能是关键字」的关键字记号换成名字：
%%   1. AS 之后（别名、YIELD 别名、UNWIND 变量）；
%%   2. 节点模式 ( K 后面是 : ) { WHERE；关系模式 -[ K 后面是 : ] * { WHERE；
%%   3. 路径变量 K = （紧跟在 MATCH / MERGE / CREATE / , 之后）；
%%   4. 以上声明过的名字（原文一致）再出现、后面接的是表达式可以接的东西（运算符、分隔符、子句关键字）。
%% 字面量关键字（NULL / TRUE / FALSE / INF / INFINITY / NAN）不换。
-define(LIT_KW, ['NULL', 'TRUE', 'FALSE', 'INF', 'INFINITY', 'NAN']).
-define(AFTER_EXPR, ['.', ',', ')', ']', '}', '=', '<>', '<', '>', '<=', '>=', '+', '-', '*', '/', '%', '^', '[', ':',
                     ';', '|', '=~', '+=', '$end', 'AND', 'OR', 'XOR', 'IN', 'IS_NULL', 'IS_NOT_NULL', 'STARTS_WITH',
                     'ENDS_WITH', 'CONTAINS', 'AS', 'ORDER', 'SKIP', 'LIMIT', 'WHERE', 'RETURN', 'WITH', 'UNION', 'ASC',
                     'ASCENDING', 'DESC', 'DESCENDING', 'THEN', 'ELSE', 'END', 'WHEN', 'MATCH', 'OPTIONAL', 'CREATE',
                     'MERGE', 'SET', 'REMOVE', 'DELETE', 'DETACH', 'UNWIND', 'CALL', 'YIELD', 'ON', 'NULLS',
                     'OFFSET', 'IS']).

%% RETURN ALL … / WITH ALL …：ALL 是缺省的集合量词（与 DISTINCT 相对），没有作用，去掉。后面跟 ( 的是量词
%% 函数 all(x IN … WHERE …)，不动。
drop_set_all([{K, _, _} = T, {'ALL', _, _} | [{Next, _} | _] = Rest]) when (K =:= 'RETURN' orelse K =:= 'WITH'), Next =/= '(' ->
    [T | drop_set_all(Rest)];
drop_set_all([{K, _, _} = T, {'ALL', _, _} | [{Next, _, _} | _] = Rest]) when (K =:= 'RETURN' orelse K =:= 'WITH'), Next =/= '(' ->
    [T | drop_set_all(Rest)];
drop_set_all([T | Rest]) -> [T | drop_set_all(Rest)];
drop_set_all([]) -> [].

soft_keywords(Tokens) -> soft_kw(Tokens, none, none, #{}, []).

%% ( 是函数调用的括号（前面是函数名或函数式关键字）时不是节点模式
-define(CALL_KW, [ident, 'EXISTS', 'ALL', 'ANY', 'NONE', 'SINGLE', 'REDUCE']).

soft_kw([], _P, _PP, _Decl, Acc) -> lists:reverse(Acc);
soft_kw([T | Rest], P, PP, Decl, Acc) ->
    Next = case Rest of [N | _] -> element(1, N); [] -> '$end' end,
    T2 = case is_kw(T) of
             false -> T;
             true ->
                 Text = element(3, T),
                 Conv = P =:= 'AS'
                     orelse (P =:= '(' andalso not lists:member(PP, ?CALL_KW)
                             andalso lists:member(Next, [':', ')', '{', 'WHERE']))
                     orelse (P =:= '[' andalso PP =:= '-' andalso lists:member(Next, [':', ']', '*', '{', 'WHERE']))
                     orelse (Next =:= '=' andalso lists:member(P, ['MATCH', 'MERGE', 'CREATE', ',']))
                     orelse (is_map_key(Text, Decl) andalso lists:member(Next, ?AFTER_EXPR)),
                 case Conv of
                     true -> {ident, element(2, T), Text};
                     false -> T
                 end
         end,
    Decl2 = case T2 =/= T of
                true -> Decl#{element(3, T2) => true};
                false -> Decl
            end,
    soft_kw(Rest, element(1, T2), P, Decl2, [T2 | Acc]).

is_kw({Cat, _, Text}) when is_atom(Cat), is_binary(Text) ->
    Cat =/= ident andalso Cat =/= string andalso Cat =/= param andalso Cat =/= int andalso Cat =/= float
        andalso Cat =/= raw_text andalso not lists:member(Cat, ?LIT_KW)
        andalso string:uppercase(atom_to_binary(Cat)) =:= atom_to_binary(Cat)
        andalso string:uppercase(Text) =:= atom_to_binary(Cat);
is_kw(_) -> false.

%% 语法错误出在关系模式的变长部分（[:T*-2]、[:T..]）：从出错的记号往回找，`*` / `..` 在前、中间没有 `]`、
%% 再往前是 `[`（openCypher：InvalidRelationshipPattern）
in_varlen(Loc, Tokens) ->
    Before = lists:takewhile(fun(T) -> element(2, T) =< Loc end, Tokens),       %% 含出错的那个记号
    Rev = lists:reverse(Before),
    case lists:splitwith(fun(T) -> not lists:member(element(1, T), ['*', '..', ']', '[']) end, Rev) of
        {_, [{Star, _} | Rest]} when Star =:= '*'; Star =:= '..' ->
            case lists:splitwith(fun(T) -> not lists:member(element(1, T), [']', '[']) end, Rest) of
                {_, [{'[', _} | _]} -> true;
                _ -> false
            end;
        _ -> false
    end.

text(B) when is_binary(B) -> B;
text(L) when is_list(L) -> unicode:characters_to_binary(L);
text(Bad) -> erlang:error({badarg, Bad}).

loc_err(Stage, Msg, Loc) ->
    %% 消息里可能有非 Latin-1 字符（词法错误回显的源文本，如全角破折号）
    Base = bitcask_cypher_error:to_map(Stage, Msg),
    case Loc of
        {L, C} -> Base#{line => L, column => C};
        L when is_integer(L) -> Base#{line => L};
        _ -> Base
    end.

norm_params(P) ->
    maps:fold(fun(K, V, Acc) -> Acc#{key(K) => value(V)} end, #{}, P).

key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> atom_to_binary(K);
key(K) when is_list(K) -> unicode:characters_to_binary(K);
key(Bad) -> erlang:error({badarg, {param_name, Bad}}).

value(undefined) -> null;
value(null) -> null;
value(B) when is_boolean(B) -> B;
value(N) when is_number(N) -> N;
value(B) when is_binary(B) -> B;
value(L) when is_list(L) -> [value(X) || X <- L];
value(M) when is_map(M) -> maps:fold(fun(K, V, Acc) -> Acc#{key(K) => value(V)} end, #{}, M);
value(X) when X =:= 'NaN'; X =:= 'Infinity'; X =:= '-Infinity' -> X;     %% 浮点的特殊值（bitcask_cypher_ieee）
value(T) when is_tuple(T) ->
    %% 时间 / 空间值（bitcask_cypher_temporal 的元组形态）
    case bitcask_cypher_temporal:is_value(T) of
        true -> T;
        false -> erlang:error({badarg, {param_value, T}})
    end;
value(Bad) -> erlang:error({badarg, {param_value, Bad}}).

%% =========================================================================
%% 流式游标（二期）：只读查询逐批取结果，不一次物化全部行。
%%
%%   {ok, C} = bitcask_cypher:cursor(Handle, Query, Params[, Opts]),
%%   {ok, Rows, more | done} = bitcask_cypher:fetch(C, 100),
%%   ok = bitcask_cypher:close(C).
%%
%% 游标是一个独立进程，持有惰性流水线与查询内缓存；执行器本身是拉取式的，LIMIT 前的扫描 /
%% 展开按需推进。排序、聚合、DISTINCT 这类算子仍要看全部输入（第一次 fetch 时物化）。
%% 游标进程 monitor 开游标的进程，它退出即关闭；空闲超过 {idle_timeout, Ms}（缺省 300000）
%% 也关闭，之后 fetch → {error, cursor_closed}。只能在句柄上开（事务状态属于调用方进程）；
%% 写语句 → {error, …}。
%% =========================================================================

-record(bitcask_cypher_cursor, {pid :: pid(), columns :: [binary()]}).

cursor(Handle, Query) -> cursor(Handle, Query, #{}, []).
cursor(Handle, Query, Params) -> cursor(Handle, Query, Params, []).

cursor(Handle, Query, Params, Opts) when is_map(Params), is_list(Opts) ->
    ok = bitcask_cypher_values:ensure_registered(),
    case is_txn(Handle) of
        true -> {error, #{stage => exec, message => <<"cursors can only be opened on a handle, not inside a transaction">>}};
        false ->
            case prepared(Query) of
                {error, _} = E -> E;
                {ok, #bitcask_cypher_prepared{plan = {error, _} = E}} -> E;
                {ok, #bitcask_cypher_prepared{analysis = A, plan = Plan}} ->
                    case maps:get(writes, A) of
                        true -> {error, #{stage => exec, message => <<"cursors are only for read-only queries">>}};
                        false ->
                            P = norm_params(Params),
                            case [N || N <- maps:get(params, A), not is_map_key(N, P)] of
                                [] -> start_cursor(Handle, Plan, P, Opts);
                                Missing ->
                                    {error, #{stage => semantic,
                                              message => iolist_to_binary(["missing parameter(s): ",
                                                                           lists:join(", ", [["$", M] || M <- Missing])])}}
                            end
                    end
            end
    end.

start_cursor(Handle, Plan, P, Opts) ->
    Owner = self(),
    Idle = proplists:get_value(idle_timeout, Opts, 300000),
    (is_integer(Idle) andalso Idle > 0) orelse erlang:error({badarg, {idle_timeout, Idle}}),
    Ref = make_ref(),
    Pid = spawn(fun() ->
                        Mon = erlang:monitor(process, Owner),
                        case bitcask_cypher_exec:open_stream({direct, Handle}, Plan, P) of
                            {ok, Cols, St} -> Owner ! {Ref, {ok, Cols}}, cursor_loop(St, Mon, Idle);
                            {error, _} = E -> Owner ! {Ref, E}
                        end
                end),
    PMon = erlang:monitor(process, Pid),
    receive
        {Ref, {ok, Cols}} -> erlang:demonitor(PMon, [flush]),
                             {ok, #bitcask_cypher_cursor{pid = Pid, columns = Cols}};
        {Ref, {error, _} = E} -> erlang:demonitor(PMon, [flush]), E;
        {'DOWN', PMon, process, Pid, Why} ->
            {error, #{stage => exec, message => iolist_to_binary(io_lib:format("cursor failed: ~p", [Why]))}}
    end.

cursor_loop(St, Mon, Idle) ->
    receive
        {fetch, From, Tag, N} ->
            case bitcask_cypher_exec:next_rows(St, N) of
                {ok, Rows, more, St2} -> From ! {Tag, {ok, Rows, more}}, cursor_loop(St2, Mon, Idle);
                {ok, Rows, done, _}   -> From ! {Tag, {ok, Rows, done}};
                {error, _} = E        -> From ! {Tag, E}
            end;
        {close, From, Tag} -> From ! {Tag, ok};
        {'DOWN', Mon, process, _, _} -> ok
    after Idle -> ok
    end.

fetch(#bitcask_cypher_cursor{pid = Pid}, N) when is_integer(N), N > 0 ->
    call_cursor(Pid, fun(Tag) -> {fetch, self(), Tag, N} end).

columns(#bitcask_cypher_cursor{columns = Cols}) -> Cols.

close(#bitcask_cypher_cursor{pid = Pid}) ->
    case call_cursor(Pid, fun(Tag) -> {close, self(), Tag} end) of
        ok -> ok;
        {error, #{message := <<"cursor_closed">>}} -> ok
    end.

call_cursor(Pid, Msg) ->
    Mon = erlang:monitor(process, Pid),
    Tag = Mon,
    Pid ! Msg(Tag),
    receive
        {Tag, Reply} -> erlang:demonitor(Mon, [flush]), Reply;
        {'DOWN', Mon, process, Pid, _} -> {error, #{stage => exec, message => <<"cursor_closed">>}}
    end.

%% =========================================================================
%% 记号预处理：表达式位置的模式（模式谓词 / exists(…) / 模式推导）前后插入 PATTERN /
%% PATTERN_END。节点模式的开头 (a) 与带括号的表达式 (a) 在 LALR 里分不开，所以在这里认：
%% 只看表达式区（MATCH / CREATE / MERGE 之后到下一个子句关键字之间是模式区，不处理），找
%% 「节点 (关系 节点)+」——关系必须以 -[ 、-- 、<-[ 、<-- 开头，所以 (a) < -1、(a) - (b)
%% 仍是运算；(a)--(b) 是模式（与 openCypher 相同）。
%% =========================================================================

%% =========================================================================
%% 投影项的源文本：没有别名的 RETURN / WITH 投影项，列名是它在查询里的原样写法（openCypher：
%% RETURN cOuNt( * ) 的列名就是 "cOuNt( * )"）。在每个没有别名的投影项前插一个 {raw_text, Loc, 文本}
%% 记号，语法把它带进 {item, E, {raw, 文本}}。
%% =========================================================================

-define(ITEM_END, ['ORDER', 'SKIP', 'LIMIT', 'WHERE', 'UNION', 'MATCH', 'OPTIONAL', 'CREATE', 'MERGE', 'SET',
                   'DELETE', 'DETACH', 'REMOVE', 'WITH', 'RETURN', 'UNWIND', 'CALL', ';']).

raw_items(Toks, Src) ->
    Starts = line_starts(Src),
    raw_walk(Toks, Src, Starts, []).

line_starts(Src) ->
    {_, Acc} = lists:foldl(fun($\n, {I, A}) -> {I + 1, [I + 1 | A]}; (_, {I, A}) -> {I + 1, A} end, {0, [0]}, Src),
    list_to_tuple(lists:reverse(Acc)).

offset({L, C}, Starts) when L =< tuple_size(Starts) -> element(L, Starts) + C - 1;
offset(_, _) -> undefined.

raw_walk([], _Src, _St, Acc) -> lists:reverse(Acc);
raw_walk([T | Rest], Src, St, Acc) when element(1, T) =:= 'RETURN'; element(1, T) =:= 'WITH' ->
    {Acc1, Rest1} = case Rest of
                        [{'DISTINCT', _, _} = D | R1] -> {[D, T | Acc], R1};
                        _ -> {[T | Acc], Rest}
                    end,
    raw_proj(Rest1, Src, St, Acc1);
raw_walk([T | Rest], Src, St, Acc) -> raw_walk(Rest, Src, St, [T | Acc]).

raw_proj([{'*', _} = Star | Rest], Src, St, Acc) ->
    case Rest of
        [{',', _} = C | R2] -> raw_proj(R2, Src, St, [C, Star | Acc]);
        _ -> raw_walk(Rest, Src, St, [Star | Acc])
    end;
raw_proj(Toks, Src, St, Acc) ->
    {Item, Rest} = take_item(Toks, 0, []),
    case Item of
        [] -> raw_walk(Toks, Src, St, Acc);
        [First | _] ->
            Acc1 = case top_level_as(Item, 0) of
                       true -> lists:reverse(Item, Acc);
                       false ->
                           S = offset(element(2, First), St),
                           E = case Rest of
                                   [Next | _] -> offset(element(2, Next), St);
                                   [] -> length(Src)
                               end,
                           case is_integer(S) andalso is_integer(E) andalso E > S of
                               true ->
                                   Text = string:trim(lists:sublist(Src, S + 1, E - S), trailing),
                                   lists:reverse(Item, [{raw_text, element(2, First), unicode:characters_to_binary(Text)} | Acc]);
                               false -> lists:reverse(Item, Acc)
                           end
                   end,
            case Rest of
                [{',', _} = C | R2] -> raw_proj(R2, Src, St, [C | Acc1]);
                _ -> raw_walk(Rest, Src, St, Acc1)
            end
    end.

%% 一个投影项的记号：到深度 0 的逗号、子句关键字或多出来的闭括号为止。
take_item([], _D, Acc) -> {lists:reverse(Acc), []};
take_item([T | Rest] = All, D, Acc) ->
    Cat = element(1, T),
    if
        D =:= 0, Cat =:= ',' -> {lists:reverse(Acc), All};
        D =:= 0 -> case lists:member(Cat, ?ITEM_END) orelse Cat =:= ')' orelse Cat =:= ']' orelse Cat =:= '}' of
                       true -> {lists:reverse(Acc), All};
                       false -> take_item(Rest, depth(key_kw(Cat, Rest), D), [T | Acc])
                   end;
        true -> take_item(Rest, depth(key_kw(Cat, Rest), D), [T | Acc])
    end.

%% CASE / END 后面跟 : 是映射键（{end: 1}），不算层
key_kw(C, [{':', _} | _]) when C =:= 'CASE'; C =:= 'END' -> key;
key_kw(C, _) -> C.

%% CASE … END 也算一层（CASE x WHEN 1, 2 THEN … 里的逗号不分投影项）
depth(C, D) when C =:= '('; C =:= '['; C =:= '{'; C =:= 'CASE' -> D + 1;
depth(C, D) when C =:= ')'; C =:= ']'; C =:= '}'; C =:= 'END' -> D - 1;
depth(_, D) -> D.

top_level_as([], _) -> false;
top_level_as([T | R], D) ->
    case element(1, T) of
        'AS' when D =:= 0 -> true;
        C -> top_level_as(R, depth(C, D))
    end.

mark_patterns(Toks) -> mark(Toks, expr, none, [], [], 0).

-define(PATTERN_START, ['MATCH', 'CREATE', 'MERGE']).
-define(EXPR_START, ['WHERE', 'RETURN', 'WITH', 'UNWIND', 'SET', 'REMOVE', 'DELETE', 'DETACH', 'ON',
                     'ORDER', 'SKIP', 'LIMIT', 'CALL', 'YIELD', 'UNION']).

%% Stack：进入子查询的 { 时压入 {深度, 外层模式}，配对的 } 弹出恢复（子查询里的子句会改模式）。
mark([], _Mode, _Prev, Acc, _Stack, _D) -> lists:reverse(Acc);
mark([{'{', _} = T | Rest], Mode, Prev, Acc, Stack, D) ->
    case Prev =:= 'EXISTS' of
        %% 子查询体：简写的 EXISTS { (a)-->(b) … } 开头是模式区
        true -> mark(Rest, pattern, '{', [T | Acc], [{D + 1, Mode} | Stack], D + 1);
        false -> mark(Rest, Mode, '{', [T | Acc], Stack, D + 1)
    end;
mark([{'}', _} = T | Rest], Mode, _Prev, Acc, Stack, D) ->
    case Stack of
        [{D, Outer} | Stack1] -> mark(Rest, Outer, '}', [T | Acc], Stack1, D - 1);
        _ -> mark(Rest, Mode, '}', [T | Acc], Stack, D - 1)
    end;
mark([T | Rest], Mode, Prev, Acc, Stack, D) ->
    Cat = element(1, T),
    Mode2 = case lists:member(Cat, ?PATTERN_START) of
                true when Prev =/= 'ON' -> pattern;           %% ON CREATE / ON MATCH 不是模式区
                _ ->
                    case lists:member(Cat, ?EXPR_START) of
                        true -> expr;
                        false -> Mode
                    end
            end,
    case {Mode2, Cat} of
        {expr, '('} ->
            case chain_len([T | Rest]) of
                none -> mark(Rest, Mode2, Cat, [T | Acc], Stack, D);
                N ->
                    {Pat, After} = lists:split(N, [T | Rest]),
                    Loc = element(2, T),
                    Last = lists:last(Pat),
                    mark(After, Mode2, element(1, Last),
                         [{'PATTERN_END', element(2, Last)} | lists:reverse(Pat, [{'PATTERN', Loc} | Acc])],
                         Stack, D)
            end;
        _ -> mark(Rest, Mode2, Cat, [T | Acc], Stack, D)
    end.


%% 从 ( 开始的「节点 (关系 节点)+」占几个记号；不是（或只有一个节点）→ none。
chain_len(Toks) ->
    case node_len(Toks) of
        none -> none;
        N1 ->
            case steps_len(lists:nthtail(N1, Toks), 0, 0) of
                {0, _} -> none;
                {_Steps, Len} -> N1 + Len
            end
    end.

steps_len(Toks, Steps, Len) ->
    case rel_len(Toks) of
        none -> {Steps, Len};
        R ->
            case node_len(lists:nthtail(R, Toks)) of
                none -> {Steps, Len};
                N -> steps_len(lists:nthtail(R + N, Toks), Steps + 1, Len + R + N)
            end
    end.

%% 节点模式：( [变量] [: / IS 标签表达式] [{…} | $参数 | WHERE …] )
node_len([{'(', _} | Rest] = Toks) ->
    {N1, R1} = case Rest of
                   [V | R] -> case is_name(V) andalso element(1, V) =/= ':' of
                                  true -> {1, R};
                                  false -> {0, Rest}
                              end;
                   [] -> {0, Rest}
               end,
    {N2, R2} = labels_len(R1, 0),
    case R2 of
        [{'WHERE', _, _} | _] ->
            %% 元素模式里的 WHERE：到配对的 ) 为止
            balanced(Toks, '(', ')', 0, 0);
        _ ->
            case props_len(R2) of
                none -> none;
                {N3, R3} ->
                    case R3 of
                        [{')', _} | _] -> 1 + N1 + N2 + N3 + 1;
                        _ -> none
                    end
            end
    end;
node_len(_) -> none.

%% 标签部分：以 : 或 IS 开头，之后是标签表达式的记号（名字、: | & ! %、括号分组）
labels_len([{K, _} | _] = Toks, N) when K =:= ':' -> label_toks(Toks, N);
labels_len([{'IS', _, _} | _] = Toks, N) -> label_toks(Toks, N);
labels_len(Toks, N) -> {N, Toks}.

label_toks([{K, _} | Rest], N) when K =:= ':'; K =:= '|'; K =:= '&'; K =:= '!'; K =:= '%' -> label_toks(Rest, N + 1);
label_toks([{'IS', _, _} | Rest], N) -> label_toks(Rest, N + 1);
label_toks([{'WHERE', _, _} | _] = Toks, N) -> {N, Toks};
label_toks([{'(', _} | _] = Toks, N) ->
    case balanced(Toks, '(', ')', 0, 0) of
        none -> {N, Toks};
        G -> label_toks(lists:nthtail(G, Toks), N + G)
    end;
label_toks([T | Rest] = Toks, N) ->
    case is_name(T) of
        true -> label_toks(Rest, N + 1);
        false -> {N, Toks}
    end;
label_toks([], N) -> {N, []}.

props_len([{'{', _} | _] = Toks) ->
    case balanced(Toks, '{', '}', 0, 0) of
        none -> none;
        N -> {N, lists:nthtail(N, Toks)}
    end;
props_len([{param, _, _} | Rest]) -> {1, Rest};
props_len(Rest) -> {0, Rest}.

%% 关系模式：-[…]-、-[…]->、<-[…]-、<-[…]->、--、-->、<--、<-->
rel_len([{'<', _}, {'-', _} | Rest]) ->
    case rel_body(Rest) of none -> none; N -> 2 + N end;
rel_len([{'-', _} | Rest]) ->
    case rel_body(Rest) of none -> none; N -> 1 + N end;
rel_len(_) -> none.

%% 「-」之后：[…] - [>]  或  - [>]
rel_body([{'[', _} | _] = Toks) ->
    case balanced(Toks, '[', ']', 0, 0) of
        none -> none;
        N ->
            case lists:nthtail(N, Toks) of
                [{'-', _}, {'>', _} | _] -> N + 2;
                [{'-', _} | _] -> N + 1;
                _ -> none
            end
    end;
rel_body([{'-', _}, {'>', _} | _]) -> 2;
rel_body([{'-', _} | _]) -> 1;
rel_body(_) -> none.

%% 从开括号起到配对的闭括号（含）共几个记号。
balanced([], _O, _C, _D, _N) -> none;
balanced([T | Rest], O, C, D, N) ->
    case element(1, T) of
        O -> balanced(Rest, O, C, D + 1, N + 1);
        C when D =:= 1 -> N + 1;
        C -> balanced(Rest, O, C, D - 1, N + 1);
        _ -> balanced(Rest, O, C, D, N + 1)
    end.

%% 能当名字的记号（标识符或关键字）。
is_name({ident, _, _}) -> true;
is_name({Cat, _, Text}) when is_atom(Cat), is_binary(Text) ->
    Cat =/= string andalso Cat =/= param;
is_name(_) -> false.
