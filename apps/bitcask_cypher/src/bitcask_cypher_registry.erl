%% =========================================================================
%% bitcask_cypher_registry — Cypher 的用户过程与用户函数（doc/cypher-phase3-design-zh.md 第 5 节）
%%
%%   全节点范围，存在 persistent_term（注册很少、查得很多）。每次改动 generation 加一：
%%   bitcask_cypher 的计划缓存看到 generation 变了就整体清空（缓存的计划里已经解析过名字）。
%%
%%   过程：#{args => [Name | {Name, Default}], outputs => [Name], mode => read | write,
%%           fn => fun((Ctx, [Arg]) -> [map()] | Stream)}
%%   函数：#{arity => N | [N], fn => fun((Ctx, [Arg]) -> Value)}
%%   Ctx = #{handle => H, txn => Tx | undefined, params => map()}
%% =========================================================================
-module(bitcask_cypher_registry).

-export([register_procedure/2, register_function/2, unregister/1, list/0, generation/0,
         procedure/1, function/1, call_procedure/4, call_function/4]).

-define(C(T, D, M), bitcask_cypher_error:code(T, D, M)).    %% openCypher 错误类型 / 细节代码
-define(KEY, {?MODULE, registry}).
-define(RESERVED, [<<"db">>, <<"fts">>, <<"search">>, <<"date">>, <<"time">>, <<"localtime">>,
                   <<"datetime">>, <<"localdatetime">>, <<"duration">>, <<"point">>]).

-type name() :: binary() | string() | atom().

get_reg() ->
    persistent_term:get(?KEY, #{gen => 0, procs => #{}, funs => #{}}).

put_reg(#{gen := G} = R) ->
    persistent_term:put(?KEY, R#{gen := G + 1}),
    ok.

-spec generation() -> non_neg_integer().
generation() -> maps:get(gen, get_reg()).

-spec register_procedure(name(), map()) -> ok | {error, term()}.
register_procedure(Name0, Spec) ->
    try
        Name = check_name(Name0),
        %% 参数：Name | {Name, Default} | #{name := Name, type => integer | float | number | string | boolean | any,
        %%        default => D}（声明了类型的参数在编译期按字面量检查）
        Args3 = [case A of
                     #{name := N} = AM -> {bin(N), maps:get(default, AM, required), maps:get(type, AM, any)};
                     {N, D} -> {bin(N), D, any};
                     N -> {bin(N), required, any}
                 end || A <- maps:get(args, Spec, [])],
        [lists:member(T, [integer, float, number, string, boolean, any]) orelse throw({bad_spec, {type, T}})
         || {_, _, T} <- Args3],
        Args = [{N, D} || {N, D, _} <- Args3],
        Types = [T || {_, _, T} <- Args3],
        check_args_order(Args),
        Outs = [bin(O) || O <- maps:get(outputs, Spec)],      %% 可以为空：只为副作用的过程（openCypher 的 void 过程）
        Mode = maps:get(mode, Spec, read),
        lists:member(Mode, [read, write]) orelse throw({bad_spec, mode}),
        Fn = maps:get(fn, Spec),
        is_function(Fn, 2) orelse throw({bad_spec, fn}),
        #{procs := Ps, funs := Fs} = R = get_reg(),
        is_map_key(Name, Fs) andalso throw({already_a_function, Name}),
        put_reg(R#{procs := Ps#{Name => #{args => Args, types => Types, outputs => Outs, mode => Mode, fn => Fn}}})
    catch
        throw:Why -> {error, Why};
        error:{badkey, K} -> {error, {missing, K}}
    end.

-spec register_function(name(), map()) -> ok | {error, term()}.
register_function(Name0, Spec) ->
    try
        Name = check_name(Name0),
        Arities = case maps:get(arity, Spec) of
                      N when is_integer(N), N >= 0 -> [N];
                      L when is_list(L) -> [N || N <- L, is_integer(N), N >= 0];
                      _ -> throw({bad_spec, arity})
                  end,
        Arities =/= [] orelse throw({bad_spec, arity}),
        Fn = maps:get(fn, Spec),
        is_function(Fn, 2) orelse throw({bad_spec, fn}),
        #{procs := Ps, funs := Fs} = R = get_reg(),
        is_map_key(Name, Ps) andalso throw({already_a_procedure, Name}),
        put_reg(R#{funs := Fs#{Name => #{arity => Arities, fn => Fn}}})
    catch
        throw:Why -> {error, Why};
        error:{badkey, K} -> {error, {missing, K}}
    end.

-spec unregister(name()) -> ok.
unregister(Name0) ->
    Name = string:lowercase(bin(Name0)),
    #{procs := Ps, funs := Fs} = R = get_reg(),
    case is_map_key(Name, Ps) orelse is_map_key(Name, Fs) of
        true -> put_reg(R#{procs := maps:remove(Name, Ps), funs := maps:remove(Name, Fs)});
        false -> ok
    end.

%% 已注册的名字：#{procedures => [Name], functions => [Name]}。
-spec list() -> #{procedures := [binary()], functions := [binary()]}.
list() ->
    #{procs := Ps, funs := Fs} = get_reg(),
    #{procedures => lists:sort(maps:keys(Ps)), functions => lists:sort(maps:keys(Fs))}.

-spec procedure(binary()) -> {ok, map()} | error.
procedure(Name) -> maps:find(Name, maps:get(procs, get_reg())).

-spec function(binary()) -> {ok, map()} | error.
function(Name) -> maps:find(Name, maps:get(funs, get_reg())).

%% 调用过程：补缺省参数，结果规范成「键 = 输出名」的 map 流（缺的为 null）。过程里的
%% 事务控制信号（冲突重跑 / 中止 / 超时）原样往外抛，别的错误变成执行错误。
call_procedure(Name, Args0, PCtx, _Opts) ->
    case procedure(Name) of
        error -> throw({exec_error, bitcask_cypher_error:code('ProcedureError', 'ProcedureNotFound',
                                                              ["procedure `", Name, "` is not registered"])});
        {ok, #{args := Spec, outputs := Outs, fn := Fn}} ->
            Args = Args0 ++ [D || {_, D} <- lists:nthtail(length(Args0), Spec)],
            Res = guarded(Name, "procedure", fun() -> Fn(PCtx, Args) end),
            Norm = fun(M) when is_map(M) -> maps:from_list([{O, out_value(M, O)} || O <- Outs]);
                      (Bad) -> throw({exec_error, ?C('ProcedureError', 'none', io_lib:format("procedure ~ts returned a non-map row: ~0p",
                                                                [Name, Bad]))})
                   end,
            case Res of
                L when is_list(L) -> [Norm(M) || M <- L];
                S when is_function(S, 0) -> {stream, map_stream(Name, Norm, S)};
                Bad -> throw({exec_error, ?C('ProcedureError', 'none', io_lib:format("procedure ~ts returned ~0p (expected a list of maps)",
                                                        [Name, Bad]))})
            end
    end.

call_function(Name, Args, PCtx, _Opts) ->
    case function(Name) of
        error -> throw({exec_error, bitcask_cypher_error:code('SyntaxError', 'UnknownFunction',
                                                              ["function `", Name, "` is not registered"])});
        {ok, #{fn := Fn}} -> guarded(Name, "function", fun() -> Fn(PCtx, Args) end)
    end.

guarded(Name, What, F) ->
    try F()
    catch
        throw:{exec_error, _} = E -> throw(E);
        throw:T when is_atom(T); is_tuple(T) ->
            case is_txn_signal(T) of
                true -> throw(T);
                false -> throw({exec_error, ?C('ProcedureError', 'none', io_lib:format("~s ~ts failed: ~0p", [What, Name, T]))})
            end;
        Class:Reason ->
            throw({exec_error, ?C('ProcedureError', 'none', io_lib:format("~s ~ts failed: ~0p", [What, Name, {Class, Reason}]))})
    end.

%% bitcask_txn 的 throw 标签（bitcask_txn_abort / _restart / _timeout，可能带参数）
is_txn_signal(T) ->
    Tag = case T of
              A when is_atom(A) -> A;
              _ when tuple_size(T) > 0 -> element(1, T);
              _ -> undefined
          end,
    is_atom(Tag) andalso lists:prefix("bitcask_txn_", atom_to_list(Tag)).

map_stream(Name, Norm, S) ->
    fun() ->
            case guarded(Name, "procedure", S) of
                done -> done;
                {Row, Next} -> {Norm(Row), map_stream(Name, Norm, Next)}
            end
    end.

out_value(M, O) ->
    case maps:find(O, M) of
        {ok, V} -> V;
        error ->
            try maps:get(binary_to_existing_atom(O), M, null)
            catch error:badarg -> null
            end
    end.

%% 名字：带命名空间（a.b / a.b.c），每段是标识符；不能占用内置的命名空间。小写存。
check_name(Name0) ->
    Name = string:lowercase(bin(Name0)),
    Segs = binary:split(Name, <<".">>, [global]),
    length(Segs) >= 2 orelse throw({bad_name, Name, "a namespace is required (ns.name)"}),
    lists:all(fun(S) -> re:run(S, "^[a-z_][a-z0-9_]*$") =/= nomatch end, Segs)
        orelse throw({bad_name, Name}),
    lists:member(hd(Segs), ?RESERVED) andalso throw({reserved_namespace, hd(Segs)}),
    Name.

check_args_order(Args) ->
    {_, Bad} = lists:foldl(fun({_, required}, {true, _}) -> {true, true};
                              ({_, required}, {false, B}) -> {false, B};
                              (_, {_, B}) -> {true, B}
                           end, {false, false}, Args),
    Bad andalso throw({bad_spec, "arguments with defaults must come last"}),
    ok.

bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A);
bin(L) when is_list(L) -> unicode:characters_to_binary(L).
