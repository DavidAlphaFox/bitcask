%% Cypher 子集的词法（doc/cypher-query-design-zh.md 第 5 节）。
%% 关键字不区分大小写；`STARTS WITH` / `ENDS WITH` / `IS NULL` / `IS NOT NULL` 合成一个
%% 记号（语法里就是一个后缀 / 中缀运算符，免得 WITH、NULL 与子句关键字、字面量打架）。
%% 记号：{Cat, Loc} 或 {Cat, Loc, Value}，Loc = {Line, Column}。

Definitions.

D   = [0-9]
L   = [A-Za-z_]
A   = [A-Za-z0-9_]
%% 非 ASCII 字符：能不能进标识符（XID_START / XID_CONTINUE）在动作里用 Unicode 属性核对
U   = [\x{80}-\x{10FFFF}]
WS  = [\s\t\r\n]
%% 数字（openCypher 2024.3：数字之间可以有单个下划线，1_000、0x_1F）
DI  = {D}(_?{D})*
EXP = [eE][+-]?{DI}

Rules.

{WS}+                                   : skip_token.
//[^\n]*                                : skip_token.
/\*([^*]|\*+[^*/])*\*+/                 : skip_token.

%% 浮点可带后缀 f / d（1.5f、1e3D；值照旧是双精度）
{DI}\.{DI}({EXP})?[fFdD]?               : float_token(norm_float(num_chars(TokenChars)), TokenLoc).
{DI}{EXP}[fFdD]?                        : float_token(norm_float(num_chars(TokenChars)), TokenLoc).
\.{DI}({EXP})?[fFdD]?                   : float_token(norm_float([$0 | num_chars(TokenChars)]), TokenLoc).
0[xX](_?[0-9A-Fa-f])+                   : {token, {int, TokenLoc, list_to_integer(no_us(tl(tl(TokenChars))), 16)}}.
0[oO](_?[0-7])+                         : {token, {int, TokenLoc, list_to_integer(no_us(tl(tl(TokenChars))), 8)}}.
{DI}                                    : int_token(list_to_integer(no_us(TokenChars)), TokenLoc).
%% 数字后面直接跟字母（0x1A2Z、92233h5、0x）：非法数字字面量。放在合法数字规则之后——等长时合法规则优先。
{D}{A}*                                 : {error, code('InvalidNumberLiteral', ["invalid number literal ", TokenChars])}.
%% 同样的东西后面跟冒号（{1B2c3e67: 1}——当映射键用）：语法错误（键得是名字，不是数字）
{D}+{L}{A}*{WS}*:                       : {error, code('UnexpectedSyntax', ["a map key must be a name, not ", string:trim(lists:droplast(TokenChars))])}.

%% 字符串：反斜杠转义，或连写两个引号表示一个引号（'it''s'）
'(\\.|''|[^'\\])*'                      : string_token(TokenChars, TokenLoc).
"(\\.|""|[^"\\])*"                      : string_token(TokenChars, TokenLoc).
%% 反引号名字：`` 表示一个反引号，也认反斜杠转义；可以为空
`(\\.|``|[^`\\])*`                      : quoted_name(TokenChars, TokenLoc, ident).

%% 参数：$ 后接 XID_CONTINUE 串（可以数字开头：$0、$1a）或反引号名字
\$({A}|{U})+                            : param_token(tl(TokenChars), TokenLoc).
\$`(\\.|``|[^`\\])*`                    : quoted_name(tl(TokenChars), TokenLoc, param).

[Ss][Tt][Aa][Rr][Tt][Ss]{WS}+[Ww][Ii][Tt][Hh] : {token, {'STARTS_WITH', TokenLoc}}.
[Ee][Nn][Dd][Ss]{WS}+[Ww][Ii][Tt][Hh]         : {token, {'ENDS_WITH', TokenLoc}}.
[Ii][Ss]{WS}+[Nn][Oo][Tt]{WS}+[Nn][Uu][Ll][Ll] : {token, {'IS_NOT_NULL', TokenLoc}}.
[Ii][Ss]{WS}+[Nn][Uu][Ll][Ll]                 : {token, {'IS_NULL', TokenLoc}}.

({L}|{U})({A}|{U})*                     : ident_token(TokenChars, TokenLoc).

<=>                                     : {token, {'<=>', TokenLoc}}.
<=                                      : {token, {'<=', TokenLoc}}.
>=                                      : {token, {'>=', TokenLoc}}.
<>                                      : {token, {'<>', TokenLoc}}.
=~                                      : {token, {'=~', TokenLoc}}.
!                                       : {token, {'!', TokenLoc}}.
\+=                                     : {token, {'+=', TokenLoc}}.
\.\.                                    : {token, {'..', TokenLoc}}.
@@                                      : {token, {'@@', TokenLoc}}.
[(){}\[\],.:|=<>+\-*/%^;&]              : {token, {list_to_atom(TokenChars), TokenLoc}}.

Erlang code.

%% 整数字面量最大到 2^63（-9223372036854775808 的绝对值；正的 2^63 在求值时报错）
%% 浮点字面量超出 IEEE 754 双精度范围（1.34E999）→ 语法错误
float_token(Chars, Loc) ->
    try {token, {float, Loc, list_to_float(Chars)}}
    catch error:badarg -> {error, code('FloatingPointOverflow', "floating point literal is too large")}
    end.

int_token(I, _Loc) when I > 9223372036854775808 ->
    {error, code('IntegerOverflow', "integer literal is too large (integers are 64-bit)")};
int_token(I, Loc) -> {token, {int, Loc, I}}.

%% 词法错误带 openCypher 细节代码（bitcask_cypher 解析失败时展开成 SyntaxError + 细节）
code(Detail, Msg) -> {cypher_code, 'SyntaxError', Detail, Msg}.

-define(KEYWORDS,
        ["MATCH", "OPTIONAL", "WHERE", "RETURN", "WITH", "UNWIND", "AS", "ORDER", "BY",
         "SKIP", "LIMIT", "ASC", "ASCENDING", "DESC", "DESCENDING", "DISTINCT",
         "AND", "OR", "XOR", "NOT", "IN", "NULL", "TRUE", "FALSE", "CONTAINS",
         "CREATE", "SET", "REMOVE", "DELETE", "DETACH", "MERGE", "ON",
         "CASE", "WHEN", "THEN", "ELSE", "END", "NULLS", "CALL", "YIELD",
         "ALL", "ANY", "NONE", "SINGLE", "REDUCE", "EXISTS", "UNION",
         "INF", "INFINITY", "NAN", "OFFSET", "IS",
         "SHORTEST", "PATH", "PATHS", "GROUP", "GROUPS"]).

word(Chars, Loc) ->
    Up = string:uppercase(Chars),
    case lists:member(Up, ?KEYWORDS) of
        true  -> {list_to_atom(Up), Loc, chars_bin(Chars)};   %% 原文留着：关键字也能当名字用
        false -> {ident, Loc, chars_bin(Chars)}
    end.

chars_bin(Chars) -> unicode:characters_to_binary(Chars).

%% 数字里的下划线去掉；浮点再去掉末尾的后缀 f / d
no_us(Chars) -> [C || C <- Chars, C =/= $_].

num_chars(Chars) ->
    Cs = no_us(Chars),
    case lists:last(Cs) of
        S when S =:= $f; S =:= $F; S =:= $d; S =:= $D -> lists:droplast(Cs);
        _ -> Cs
    end.

%% 标识符：ASCII 照旧（可能是关键字）；带非 ASCII 字符的按 Unicode 核对——首字符 XID_START（字母 / 字母数字），
%% 其余 XID_CONTINUE（再加组合符号、数字、连接标点）；不合格（全角破折号当减号用等）是 InvalidUnicodeCharacter。
ident_token(Chars, Loc) ->
    case lists:all(fun(C) -> C < 128 end, Chars) of
        true -> {token, word(Chars, Loc)};
        false ->
            case xid(Chars) of
                true -> {token, {ident, Loc, chars_bin(Chars)}};
                false -> {error, code('InvalidUnicodeCharacter', ["illegal characters \"", Chars, "\""])}
            end
    end.

param_token(Chars, Loc) ->
    case lists:all(fun(C) -> C < 128 end, Chars) orelse xid_continue(Chars) of
        true -> {token, {param, Loc, chars_bin(Chars)}};
        false -> {error, code('InvalidUnicodeCharacter', ["illegal characters \"$", Chars, "\""])}
    end.

xid([C | Rest]) ->
    (C < 128 orelse re:run([C], "^[\\p{L}\\p{Nl}]$", [unicode, ucp]) =/= nomatch) andalso xid_continue(Rest).

xid_continue(Cs) ->
    lists:all(fun(C) when C < 128 -> true;
                 (C) -> re:run([C], "^[\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}]$", [unicode, ucp]) =/= nomatch
              end, Cs).

%% 反引号名字（标识符或 $`参数`）：去掉外层反引号，`` → `，反斜杠转义同字符串
quoted_name(Chars, Loc, Cat) ->
    case unescape(dedup(strip(Chars), $`), []) of
        {ok, S} -> {token, {Cat, Loc, chars_bin(S)}};
        {error, Reason} -> {error, Reason}
    end.

%% 连写的两个引号字符 → 一个（反斜杠转义的不动）
dedup([$\\, C | Rest], Q) -> [$\\, C | dedup(Rest, Q)];
dedup([Q, Q | Rest], Q) -> [$\\, Q | dedup(Rest, Q)];
dedup([C | Rest], Q) -> [C | dedup(Rest, Q)];
dedup([], _Q) -> [].

strip(Chars) -> lists:droplast(tl(Chars)).

norm_float(Chars) ->
    %% "1e5" 这种 list_to_float 不收：补成 "1.0e5"
    case lists:member($., Chars) of
        true  -> Chars;
        false ->
            {M, E} = lists:splitwith(fun(C) -> C =/= $e andalso C =/= $E end, Chars),
            M ++ ".0" ++ E
    end.

string_token([Q | _] = Chars, Loc) ->
    case unescape(dedup(strip(Chars), Q), []) of
        {ok, S}         -> {token, {string, Loc, chars_bin(S)}};
        {error, Reason} -> {error, Reason}
    end.


unescape([], Acc) -> {ok, lists:reverse(Acc)};
unescape([$\\, C | Rest], Acc) ->
    case C of
        $n  -> unescape(Rest, [$\n | Acc]);
        $t  -> unescape(Rest, [$\t | Acc]);
        $r  -> unescape(Rest, [$\r | Acc]);
        $b  -> unescape(Rest, [$\b | Acc]);
        $f  -> unescape(Rest, [$\f | Acc]);
        $0  -> unescape(Rest, [0 | Acc]);
        $\\ -> unescape(Rest, [$\\ | Acc]);
        $'  -> unescape(Rest, [$' | Acc]);
        $"  -> unescape(Rest, [$" | Acc]);
        $`  -> unescape(Rest, [$` | Acc]);
        $U  ->
            %% \U + 6 位十六进制（openCypher 2024.3）
            case Rest of
                [A1, A2, A3, A4, A5, A6 | Rest6] ->
                    case catch list_to_integer([A1, A2, A3, A4, A5, A6], 16) of
                        N6 when is_integer(N6), N6 =< 16#10FFFF -> unescape(Rest6, [N6 | Acc]);
                        _ -> {error, code('InvalidUnicodeLiteral', "bad \\U escape")}
                    end;
                _ -> {error, code('InvalidUnicodeLiteral', "bad \\U escape")}
            end;
        $u  ->
            case Rest of
                [A, B, C2, D | Rest2] ->
                    case catch list_to_integer([A, B, C2, D], 16) of
                        N when is_integer(N) -> unescape(Rest2, [N | Acc]);
                        _ -> {error, code('InvalidUnicodeLiteral', "bad \\u escape")}
                    end;
                _ -> {error, code('InvalidUnicodeLiteral', "bad \\u escape")}
            end;
        _   -> {error, "unknown escape \\" ++ [C]}
    end;
unescape([C | Rest], Acc) -> unescape(Rest, [C | Acc]).
