%% =========================================================================
%% bitcask_cypher_error — Cypher 错误的类型与细节代码（openCypher 的 error type / detail code）
%%
%%   错误 map：#{stage => parse | semantic | plan | exec, message => binary(),
%%              type => <<"SyntaxError">> …, detail => <<"VariableAlreadyBound">> …,
%%              line => L, column => C}（type / detail 能归类时才有）
%%
%%   抛错的地方把消息包成 code(Type, Detail, Msg)（原子），照常 throw({exec_error, Msg}) /
%%   throw({sema, Msg, Loc})；接住的地方用 to_map/2 展开。没包的消息：parse 阶段归 SyntaxError /
%%   UnexpectedSyntax，其余不带 type。
%%
%%   类型：SyntaxError、SemanticError、ParameterMissing、TypeError、ArgumentError、EntityNotFound、
%%   ConstraintVerificationFailed、ProcedureError（openCypher TCK 用到的那些）。
%% =========================================================================
-module(bitcask_cypher_error).

-export([code/3, to_map/2, append/2, message/1, is_coded/1]).

-type msg() :: iodata() | {cypher_code, atom(), atom(), iodata()}.
-export_type([msg/0]).

-spec code(atom(), atom(), iodata()) -> msg().
code(Type, Detail, {cypher_code, _, _, Msg}) -> {cypher_code, Type, Detail, Msg};
code(Type, Detail, Msg) -> {cypher_code, Type, Detail, Msg}.

is_coded({cypher_code, _, _, _}) -> true;
is_coded(_) -> false.

%% 只要文本（丢掉代码）。
message({cypher_code, _, _, Msg}) -> message(Msg);
message(Msg) -> Msg.

%% 往消息后面接文本，代码不变。
append({cypher_code, T, D, Msg}, Extra) -> {cypher_code, T, D, [Msg, Extra]};
append(Msg, Extra) -> [Msg, Extra].

-spec to_map(atom(), msg()) -> map().
to_map(Stage, {cypher_code, T, D, Msg}) ->
    M = #{stage => Stage, message => bin(Msg), type => atom_to_binary(T)},
    case D of
        none -> M;
        _ -> M#{detail => atom_to_binary(D)}
    end;
to_map(parse, Msg) ->
    to_map(parse, code('SyntaxError', 'UnexpectedSyntax', Msg));
to_map(Stage, Msg) ->
    #{stage => Stage, message => bin(Msg)}.

bin(Msg) ->
    case unicode:characters_to_binary(Msg) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~tp", [Msg]))
    end.
