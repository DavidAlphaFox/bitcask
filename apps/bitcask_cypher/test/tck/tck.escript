#!/usr/bin/env escript
%%! -noshell
%% =========================================================================
%% openCypher TCK 运行器：解析 Gherkin 场景（含 Scenario Outline / Examples），每个场景在一个
%% 新建的图上执行，比对结果 / 写统计 / 错误，按目录汇总通过率，失败明细写进报告。
%%
%%   apps/bitcask_cypher/test/tck/fetch.sh                      # 先拉场景集（_build/tck/openCypher）
%%   rebar3 compile
%%   escript apps/bitcask_cypher/test/tck/tck.escript [--filter 子串] [--tck 目录] [--report 文件] [--jobs N]
%%
%% 判定：
%%   pass        结果 / 写统计全部符合
%%   期望报错的场景：阶段（编译期 = 解析 / 语义 / 规划；运行期 = 执行）、错误类型（type）与细节代码
%%               （detail，如 SyntaxError: VariableAlreadyBound）都对上才算 pass。
%%               --phase-only：只比阶段（对上记 pass-phase，旧判定）
%%   fail        其余（原因写进报告）
%% =========================================================================
-mode(compile).

main(Args) ->
    Opts = opts(Args, #{tck => "_build/tck/openCypher/tck", filter => "", report => "_build/tck/report.txt",
                        jobs => 4}),
    code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(bitcask),
    Tck = maps:get(tck, Opts),
    filelib:is_dir(Tck) orelse begin io:format("no TCK at ~s (run apps/bitcask_cypher/test/tck/fetch.sh)~n", [Tck]), halt(2) end,
    Work = filename:absname("_build/tck/work"),
    os:cmd("rm -rf " ++ Work), ok = filelib:ensure_dir(filename:join(Work, "x")),
    Files = lists:sort(filelib:wildcard(filename:join(Tck, "features/**/*.feature"))),
    Filter = maps:get(filter, Opts),
    Scenarios = [S#{group => group(Tck, F), file => rel(Tck, F)}
                 || F <- Files, S <- parse_feature(F),
                    Filter =:= "" orelse string:find(rel(Tck, F) ++ " " ++ maps:get(name, S), Filter) =/= nomatch],
    io:format("~b scenarios~n", [length(Scenarios)]),
    T0 = erlang:monotonic_time(millisecond),
    %% 注册过程是全节点的（persistent_term）：声明了过程的场景串行跑，免得互相覆盖
    Numbered = lists:zip(lists:seq(1, length(Scenarios)), Scenarios),
    Run = fun({I, S}) -> {I, {S, run_scenario(S, Tck, filename:join(Work, "s" ++ integer_to_list(I)))}} end,
    {WithProc, Plain} = lists:partition(fun({_, S}) -> uses_procedure(S) end, Numbered),
    R1 = pmap(Run, Plain, maps:get(jobs, Opts)),
    R2 = [Run(X) || X <- WithProc],
    Results = [R || {_, R} <- lists:keysort(1, R1 ++ R2)],
    os:cmd("rm -rf " ++ Work),
    report(Results, maps:get(report, Opts), erlang:monotonic_time(millisecond) - T0).

uses_procedure(#{steps := Steps}) ->
    lists:any(fun({T, _}) -> lists:prefix("there exists a procedure", T) end, Steps).

opts(["--filter", F | R], M) -> opts(R, M#{filter => F});
opts(["--tck", D | R], M) -> opts(R, M#{tck => D});
opts(["--report", F | R], M) -> opts(R, M#{report => F});
opts(["--jobs", N | R], M) -> opts(R, M#{jobs => list_to_integer(N)});
opts(["--phase-only" | R], M) -> persistent_term:put(tck_phase_only, true), opts(R, M);
opts([], M) -> M.

rel(Tck, F) -> string:prefix(F, filename:join(Tck, "features") ++ "/").
group(Tck, F) -> filename:dirname(rel(Tck, F)).

%% 并行跑（每个场景自己一个目录、一个进程），保持原顺序。
pmap(F, Xs, Jobs) ->
    Self = self(),
    Idx = lists:zip(lists:seq(1, length(Xs)), Xs),
    pmap_loop(F, Idx, Jobs, 0, #{}, Self, length(Xs)).

pmap_loop(_F, [], _Jobs, 0, Acc, _Self, N) -> [maps:get(I, Acc) || I <- lists:seq(1, N)];
pmap_loop(F, [{I, X} | Rest], Jobs, Running, Acc, Self, N) when Running < Jobs ->
    spawn_link(fun() -> Self ! {pmap, I, F(X)} end),
    pmap_loop(F, Rest, Jobs, Running + 1, Acc, Self, N);
pmap_loop(F, Rest, Jobs, Running, Acc, Self, N) ->
    receive {pmap, I, R} ->
            case map_size(Acc) rem 200 of 199 -> io:format("  ~b done~n", [map_size(Acc) + 1]); _ -> ok end,
            pmap_loop(F, Rest, Jobs, Running - 1, Acc#{I => R}, Self, N)
    end.

%% =========================================================================
%% Gherkin
%% =========================================================================

parse_feature(File) ->
    {ok, Bin} = file:read_file(File),
    Lines = [string:trim(L, trailing, "\r") || L <- string:split(unicode:characters_to_list(Bin), "\n", all)],
    {Feature, Bg, Items} = blocks(Lines, "", [], []),
    lists:append([expand(Feature, Bg, It) || It <- Items]).

%% → {特性名, 背景步骤, [{scenario, Name, Steps} | {outline, Name, Steps, [Examples]}]}
blocks([], F, Bg, Acc) -> {F, Bg, lists:reverse(Acc)};
blocks([L | Rest], F, Bg, Acc) ->
    T = string:trim(L),
    case T of
        "Feature:" ++ Name -> blocks(Rest, string:trim(Name), Bg, Acc);
        "Background:" ++ _ -> {Steps, Rest2} = steps(Rest, []), blocks(Rest2, F, Steps, Acc);
        "Scenario Outline:" ++ Name ->
            {Steps, Rest2} = steps(Rest, []),
            {Exs, Rest3} = examples(Rest2, []),
            blocks(Rest3, F, Bg, [{outline, string:trim(Name), Steps, Exs} | Acc]);
        "Scenario:" ++ Name ->
            {Steps, Rest2} = steps(Rest, []),
            blocks(Rest2, F, Bg, [{scenario, string:trim(Name), Steps} | Acc]);
        _ -> blocks(Rest, F, Bg, Acc)
    end.

%% 步骤：关键字行 + 可选的文档串 / 表格。遇到下一个 Scenario / Examples / 文件尾停。
steps([], Acc) -> {lists:reverse(Acc), []};
steps([L | Rest] = All, Acc) ->
    T = string:trim(L),
    case step_text(T) of
        {ok, Text} ->
            {Arg, Rest2} = step_arg(Rest),
            steps(Rest2, [{Text, Arg} | Acc]);
        none ->
            case lists:any(fun(P) -> lists:prefix(P, T) end, ["Scenario", "Examples:", "@", "Feature:"]) of
                true -> {lists:reverse(Acc), All};
                false -> steps(Rest, Acc)
            end
    end.

step_text(T) ->
    case [string:trim(string:prefix(T, K)) || K <- ["Given ", "When ", "Then ", "And ", "But "], lists:prefix(K, T)] of
        [Text] -> {ok, Text};
        [] -> none
    end.

step_arg([L | Rest] = All) ->
    T = string:trim(L),
    case T of
        "\"\"\"" ++ _ ->
            Indent = length(L) - length(string:trim(L, leading)),
            {Doc, Rest2} = docstring(Rest, Indent, []),
            {{doc, Doc}, Rest2};
        "|" ++ _ -> table(All, []);
        "" -> case Rest of [] -> {none, Rest}; _ -> step_arg_blank(Rest, All) end;
        _ -> {none, All}
    end;
step_arg([]) -> {none, []}.

%% 步骤与表格之间不会有空行；空行就结束参数
step_arg_blank(_Rest, All) -> {none, All}.

docstring([L | Rest], Indent, Acc) ->
    case string:trim(L) of
        "\"\"\"" -> {lists:flatten(lists:join("\n", lists:reverse(Acc))), Rest};
        _ ->
            Line = case length(L) >= Indent andalso string:trim(lists:sublist(L, Indent), both) =:= "" of
                       true -> lists:nthtail(Indent, L);
                       false -> string:trim(L, leading)
                   end,
            docstring(Rest, Indent, [Line | Acc])
    end.

table([L | Rest] = All, Acc) ->
    case string:trim(L) of
        "|" ++ _ = T -> table(Rest, [cells(T) | Acc]);
        _ -> {{table, lists:reverse(Acc)}, All}
    end;
table([], Acc) -> {{table, lists:reverse(Acc)}, []}.

%% | a | b |：按未转义的 | 切；\| 是字面量 |。
cells("|") -> [""];
cells(T) ->
    Inner = case lists:last(T) of $| -> lists:droplast(tl(T)); _ -> tl(T) end,
    [string:trim(C) || C <- split_cells(Inner, [], [])].

%% Gherkin 单元格转义：\\ → \、\| → |、\n → 换行（之后才按 TCK 值的文字形态解析）
split_cells([$\\, $\\ | R], Cur, Acc) -> split_cells(R, [$\\ | Cur], Acc);
split_cells([$\\, $n | R], Cur, Acc) -> split_cells(R, [$\n | Cur], Acc);

split_cells([], Cur, Acc) -> lists:reverse([lists:reverse(Cur) | Acc]);
split_cells([$\\, $| | R], Cur, Acc) -> split_cells(R, [$| | Cur], Acc);
split_cells([$| | R], Cur, Acc) -> split_cells(R, [], [lists:reverse(Cur) | Acc]);
split_cells([C | R], Cur, Acc) -> split_cells(R, [C | Cur], Acc).

examples([L | Rest] = All, Acc) ->
    T = string:trim(L),
    case T of
        "Examples:" ++ _ -> {{table, Rows}, Rest2} = table(skip_blank(Rest), []), examples(Rest2, [Rows | Acc]);
        "" -> examples(Rest, Acc);
        "@" ++ _ -> examples(Rest, Acc);
        "#" ++ _ -> examples(Rest, Acc);
        _ -> {lists:reverse(Acc), All}
    end;
examples([], Acc) -> {lists:reverse(Acc), []}.

skip_blank([L | Rest] = All) -> case string:trim(L) of "" -> skip_blank(Rest); _ -> All end;
skip_blank([]) -> [].

expand(F, Bg, {scenario, Name, Steps}) -> [#{feature => F, name => Name, steps => Bg ++ Steps}];
expand(F, Bg, {outline, Name, Steps, Exs}) ->
    lists:append([[#{feature => F, name => Name ++ " #" ++ integer_to_list(I),
                     steps => Bg ++ [subst_step(S, lists:zip(Hdr, Row)) || S <- Steps]}
                   || {I, Row} <- lists:zip(lists:seq(1, length(Rows)), Rows)]
                  || [Hdr | Rows] <- Exs]).

subst_step({Text, Arg}, KVs) ->
    {subst(Text, KVs), case Arg of
                           {doc, D} -> {doc, subst(D, KVs)};
                           {table, Rows} -> {table, [[subst(C, KVs) || C <- R] || R <- Rows]};
                           none -> none
                       end}.

subst(S, KVs) ->
    lists:flatten(lists:foldl(fun({K, V}, Acc) -> lists:flatten(string:replace(Acc, "<" ++ K ++ ">", V, all)) end,
                              S, KVs)).

%% =========================================================================
%% 执行
%% =========================================================================

run_scenario(S, Tck, Dir) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Self ! {self(), catch run_steps(S, Tck, Dir)} end),
    R = receive
            {Pid, Res} -> erlang:demonitor(Ref, [flush]), Res;
            {'DOWN', Ref, process, Pid, Why} -> {fail, {crash, Why}}
        after 30000 ->
            exit(Pid, kill), {fail, timeout}
        end,
    os:cmd("rm -rf " ++ Dir),
    case R of
        pass -> pass;
        pass_phase -> pass_phase;
        {fail, _} = F -> F;
        Other -> {fail, {exception, Other}}
    end.

run_steps(#{steps := Steps}, Tck, Dir) ->
    R = graphdb:open(Dir, [read_write]),
    St0 = #{g => R, params => #{}, result => none, procs => [], tck => Tck, verdict => pass},
    try
        lists:foldl(fun(Step, St) -> St2 = step(Step, St), put(tck_state, St2), St2 end, St0, Steps)
    of
        #{verdict := V} -> V
    catch
        throw:{fail, _} = F -> F
    after
        [bitcask_cypher:unregister(list_to_binary(P)) || P <- maps:get(procs, get_state(), [])],
        graphdb:close(R)
    end.

fail(Why) -> throw({fail, Why}).

get_state() -> case get(tck_state) of undefined -> #{}; S -> S end.

step({"an empty graph", _}, St) -> St;
step({"any graph", _}, St) -> St;
step({"having executed:", {doc, Q}}, #{g := R} = St) ->
    case bitcask_cypher:q(R, Q) of
        {ok, _} -> St;
        {error, E} -> fail({setup_failed, E, Q})
    end;
step({"parameters are:", {table, Rows}}, St) ->
    St#{params => maps:from_list([{list_to_binary(K), to_cypher(parse_value(V))} || [K, V] <- Rows])};
step({"executing query:", {doc, Q}}, St) -> exec(Q, St);
step({"executing control query:", {doc, Q}}, St) -> exec(Q, St);
step({"the result should be empty", _}, #{result := Res} = St) ->
    case Res of
        {ok, #{rows := []}} -> St;
        {ok, #{rows := Rows}} -> fail({expected_empty, length(Rows), Rows});
        {error, E} -> fail({unexpected_error, E})
    end;
step({"no side effects", _}, St) -> side_effects([], St);
step({"the side effects should be:", {table, Rows}}, St) -> side_effects(Rows, St);
step({"the result should be, in any order:", {table, T}}, St) -> compare(T, any, false, St);
step({"the result should be, in order:", {table, T}}, St) -> compare(T, ordered, false, St);
step({"the result should be (ignoring element order for lists):", {table, T}}, St) -> compare(T, any, true, St);
step({"the result should be, in order (ignoring element order for lists):", {table, T}}, St) ->
    compare(T, ordered, true, St);
step({Text, Arg}, St) ->
    case re:run(Text, "^the ([a-z0-9-]+) graph$", [{capture, all_but_first, list}]) of
        {match, [Name]} -> named_graph(Name, St);
        nomatch ->
            case re:run(Text, "^an? (\\w+) should be raised at (compile time|runtime|any time): (\\S+)$",
                        [{capture, all_but_first, list}]) of
                {match, [Type, Phase, Detail]} -> expect_error(Type, Phase, Detail, St);
                nomatch ->
                    case re:run(Text, "^there exists a procedure (.*?)\\s*:$", [{capture, all_but_first, list}]) of
                        {match, [Sig]} -> procedure(Sig, Arg, St);
                        nomatch -> fail({unsupported_step, Text})
                    end
            end
    end.

exec(Q, #{g := R, params := P} = St) ->
    Before = snapshot(R),
    Res = try bitcask_cypher:q(R, Q, P)
          catch C:E -> {error, #{stage => crash, message => iolist_to_binary(io_lib:format("~0p", [{C, E}]))}}
          end,
    St#{result => Res, query => Q, effects => diff(Before, snapshot(R))}.

%% TCK 的 side effects 是执行前后图状态的差（不是操作计数）：节点 / 关系的增删、图里出现的标签名集合、
%% 全部属性（实体, 键, 值）的增删。
snapshot(R) ->
    {ok, #{rows := Ns}} = bitcask_cypher:q(R, "MATCH (n) RETURN id(n), labels(n), properties(n)"),
    {ok, #{rows := Rs}} = bitcask_cypher:q(R, "MATCH ()-[r]->() RETURN id(r), properties(r)"),
    #{nodes => sets:from_list([I || [I, _, _] <- Ns]),
      rels => sets:from_list([I || [I, _] <- Rs]),
      labels => sets:from_list(lists:append([L || [_, L, _] <- Ns])),
      props => sets:from_list([{n, I, K, V} || [I, _, P] <- Ns, {K, V} <- maps:to_list(P)]
                              ++ [{r, I, K, V} || [I, P] <- Rs, {K, V} <- maps:to_list(P)])}.

diff(A, B) ->
    D = fun(K) -> {sets:size(sets:subtract(maps:get(K, B), maps:get(K, A))),
                   sets:size(sets:subtract(maps:get(K, A), maps:get(K, B)))} end,
    {N1, N2} = D(nodes), {R1, R2} = D(rels), {L1, L2} = D(labels), {P1, P2} = D(props),
    #{"+nodes" => N1, "-nodes" => N2, "+relationships" => R1, "-relationships" => R2,
      "+labels" => L1, "-labels" => L2, "+properties" => P1, "-properties" => P2}.

named_graph(Name, #{g := R, tck := Tck} = St) ->
    File = filename:join([Tck, "graphs", Name, Name ++ ".cypher"]),
    {ok, Q} = file:read_file(File),
    case bitcask_cypher:q(R, Q) of
        {ok, _} -> St;
        {error, E} -> fail({graph_setup_failed, Name, E})
    end.

expect_error(Type, Phase, Detail, #{result := Res} = St) ->
    case Res of
        {error, #{stage := Stage}} ->
            Compile = lists:member(Stage, [parse, semantic, plan]),
            Ok = case Phase of
                     "compile time" -> Compile;
                     "runtime" -> Stage =:= exec;
                     "any time" -> true
                 end,
            {_, E} = Res,
            Got = {binary_to_list(maps:get(type, E, <<"-">>)), binary_to_list(maps:get(detail, E, <<"-">>))},
            CodeOk = element(1, Got) =:= Type andalso (Detail =:= "*" orelse element(2, Got) =:= Detail),
            case {Ok, CodeOk, persistent_term:get(tck_phase_only, false)} of
                {false, _, _} -> fail({error_phase, {expected, Phase, Type, Detail}, {got, Res}});
                {true, true, _} -> St;
                {true, false, true} -> St#{verdict => pass_phase};
                {true, false, _} -> fail({error_code, {expected, Type, Detail}, {got, Got}, maps:get(message, E)})
            end;
        {ok, #{rows := Rows}} -> fail({expected_error, Type, Phase, Detail, {got_rows, lists:sublist(Rows, 3)}});
        none -> fail(no_query)
    end.

%% ---- 写统计 ------------------------------------------------------------------
-define(SE, [{"+nodes", nodes_created}, {"-nodes", nodes_deleted},
             {"+relationships", relationships_created}, {"-relationships", relationships_deleted},
             {"+labels", labels_added}, {"-labels", labels_removed},
             {"+properties", properties_set}, {"-properties", properties_removed}]).

side_effects(Rows, #{result := Res} = St) ->
    case Res of
        {error, E} -> fail({unexpected_error, E});
        none -> fail(no_query);
        _ -> ok
    end,
    Want = maps:from_list([{K, list_to_integer(V)} || [K, V] <- Rows]),
    Got = maps:get(effects, St),
    Want2 = maps:merge(maps:from_list([{K, 0} || {K, _} <- ?SE]), Want),
    case Got =:= Want2 of
        true -> St;
        false -> fail({side_effects, {expected, maps:filter(fun(_, V) -> V =/= 0 end, Want2)},
                       {got, maps:filter(fun(_, V) -> V =/= 0 end, Got)}})
    end.

%% ---- 结果比对 ----------------------------------------------------------------
compare([Hdr | Rows], Order, IgnoreListOrder, #{result := Res} = St) ->
    case Res of
        {error, E} -> fail({unexpected_error, E});
        none -> fail(no_query);
        {ok, #{columns := Cols, rows := Got}} ->
            HdrB = [list_to_binary(H) || H <- Hdr, H =/= ""],
            lists:sort(HdrB) =:= lists:sort(Cols) orelse fail({columns, {expected, HdrB}, {got, Cols}}),
            Idx = [index_of(H, Cols) || H <- HdrB],
            Norm = case IgnoreListOrder of true -> fun sort_lists/1; false -> fun(X) -> X end end,
            Want = [[Norm(canon_expected(parse_value(C))) || C <- R] || R <- Rows, R =/= [""]],
            Have = [[Norm(canon_actual(lists:nth(I, Row))) || I <- Idx] || Row <- Got],
            Ok = case Order of
                     ordered -> length(Want) =:= length(Have) andalso lists:all(fun({A, B}) -> eqrow(A, B) end, lists:zip(Want, Have));
                     any -> multiset_eq(Want, Have)
                 end,
            case Ok of
                true -> St;
                false -> fail({result, Order, {expected, lists:sublist(Want, 6)}, {got, lists:sublist(Have, 6)},
                               {counts, length(Want), length(Have)}})
            end
    end.

index_of(X, L) -> index_of(X, L, 1).
index_of(X, [X | _], I) -> I;
index_of(X, [_ | R], I) -> index_of(X, R, I + 1).

multiset_eq([], []) -> true;
multiset_eq([], _) -> false;
multiset_eq([W | Ws], Have) ->
    case take_eq(W, Have, []) of
        {ok, Rest} -> multiset_eq(Ws, Rest);
        error -> false
    end.

take_eq(_W, [], _Acc) -> error;
take_eq(W, [H | T], Acc) ->
    case eqrow(W, H) of
        true -> {ok, lists:reverse(Acc, T)};
        false -> take_eq(W, T, [H | Acc])
    end.

eqrow(A, B) -> length(A) =:= length(B) andalso lists:all(fun({X, Y}) -> eqv(X, Y) end, lists:zip(A, B)).

eqv(A, B) when is_float(A), is_float(B) -> A =:= B orelse abs(A - B) =< 1.0e-12 * max(1.0, abs(A));
eqv({l, A}, {l, B}) -> eqrow(A, B);
eqv({m, A}, {m, B}) -> [K || {K, _} <- A] =:= [K || {K, _} <- B] andalso eqrow([V || {_, V} <- A], [V || {_, V} <- B]);
eqv({n, L1, P1}, {n, L2, P2}) -> L1 =:= L2 andalso eqv(P1, P2);
eqv({r, T1, P1}, {r, T2, P2}) -> T1 =:= T2 andalso eqv(P1, P2);
eqv({p, N1, R1}, {p, N2, R2}) -> eqrow(N1, N2) andalso eqrow(R1, R2);
eqv({d, R1, D}, {d, R2, D}) -> eqv(R1, R2);
eqv(A, B) -> A =:= B.

sort_lists({l, L}) -> {l, lists:sort([sort_lists(X) || X <- L])};
sort_lists({m, KVs}) -> {m, [{K, sort_lists(V)} || {K, V} <- KVs]};
sort_lists(X) -> X.

%% 实际值（bitcask_cypher 的结果形态）→ 规范形态
canon_actual(null) -> null;
canon_actual('NaN') -> {special, nan};
canon_actual('Infinity') -> {special, inf};
canon_actual('-Infinity') -> {special, ninf};
canon_actual(B) when is_boolean(B) -> B;
canon_actual(N) when is_number(N) -> N;
canon_actual(B) when is_binary(B) -> {s, B};
canon_actual(L) when is_list(L) -> {l, [canon_actual(X) || X <- L]};
canon_actual(#{id := _, labels := L, properties := P}) -> {n, lists:sort(L), canon_map(P)};
canon_actual(#{src := _, type := T, dst := _, properties := P}) -> {r, T, canon_map(P)};
canon_actual(#{nodes := Ns, relationships := Rs}) ->
    Ids = [maps:get(id, N) || N <- Ns],
    Dirs = [case maps:get(src, R) =:= Prev of true -> right; false -> left end
            || {R, Prev} <- lists:zip(Rs, lists:sublist(Ids, length(Rs)))],
    {p, [canon_actual(N) || N <- Ns], [{d, canon_actual(R), D} || {R, D} <- lists:zip(Rs, Dirs)]};
canon_actual(M) when is_map(M) -> canon_map(M);
canon_actual(T) when is_tuple(T) ->
    case bitcask_cypher_temporal:is_value(T) of
        true -> {s, bitcask_cypher_temporal:format(T)};
        false -> {other, T}
    end.

canon_map(M) -> {m, lists:sort([{K, canon_actual(V)} || {K, V} <- maps:to_list(M)])}.

%% 期望值（TCK 文字形态的解析结果）→ 规范形态
canon_expected(null) -> null;
canon_expected(B) when is_boolean(B) -> B;
canon_expected({int, I}) -> I;
canon_expected({float, F}) -> F;
canon_expected({special, X}) -> {special, X};
canon_expected({str, B}) -> {s, B};
canon_expected({list, L}) -> {l, [canon_expected(X) || X <- L]};
canon_expected({map, KVs}) -> {m, lists:sort([{K, canon_expected(V)} || {K, V} <- KVs])};
canon_expected({node, Ls, KVs}) -> {n, lists:sort(Ls), canon_expected({map, KVs})};
canon_expected({rel, T, KVs}) -> {r, T, canon_expected({map, KVs})};
canon_expected({path, N0, Steps}) ->
    {p, [canon_expected(N0) | [canon_expected(N) || {_, _, N} <- Steps]],
     [{d, canon_expected(R), D} || {R, D, _} <- Steps]}.

%% 期望值 → Cypher 值（参数、过程表格）
to_cypher(null) -> null;
to_cypher(B) when is_boolean(B) -> B;
to_cypher({int, I}) -> I;
to_cypher({float, F}) -> F;
to_cypher({str, B}) -> B;
to_cypher({list, L}) -> [to_cypher(X) || X <- L];
to_cypher({map, KVs}) -> maps:from_list([{K, to_cypher(V)} || {K, V} <- KVs]);
to_cypher(X) -> fail({unsupported_parameter_value, X}).

%% ---- 过程 --------------------------------------------------------------------
%% test.my.proc(a :: INTEGER?, b :: STRING?) :: (out :: STRING?) + 表格：按输入列匹配，交出输出列。
procedure(Sig, Arg, St) ->
    {match, [Name, InS, OutS]} = re:run(Sig, "^([\\w.]+)\\s*\\((.*?)\\)\\s*::\\s*\\((.*?)\\)\\s*$",
                                        [{capture, all_but_first, list}]),
    Names = fun(S) -> [list_to_binary(string:trim(hd(string:split(P, "::")))) || P <- string:split(S, ",", all),
                                                                                string:trim(P) =/= ""] end,
    Type = fun(P) -> case string:uppercase(string:trim(lists:last(string:split(P, "::")), both, " ?")) of
                         "INTEGER" -> integer; "FLOAT" -> float; "NUMBER" -> number; "STRING" -> string;
                         "BOOLEAN" -> boolean; _ -> any
                     end end,
    Ins = Names(InS), Outs = Names(OutS),
    InTypes = [Type(P) || P <- string:split(InS, ",", all), string:trim(P) =/= ""],
    Rows = case Arg of
               {table, [_Hdr | Rs]} -> [[to_cypher(parse_value(C)) || C <- R] || R <- Rs, R =/= [""]];
               _ -> []
           end,
    NIn = length(Ins),
    Fn = fun(_Ctx, Args) ->
                 [maps:from_list(lists:zip(Outs, lists:nthtail(NIn, R)))
                  || R <- Rows, lists:all(fun({A, B}) -> A == B end,
                                          lists:zip(Args, lists:sublist(R, NIn)))]
         end,
    case bitcask_cypher:register_procedure(list_to_binary(Name),
                                           #{args => [#{name => N, type => T} || {N, T} <- lists:zip(Ins, InTypes)],
                                             outputs => Outs, fn => Fn}) of
        ok -> St#{procs => [Name | maps:get(procs, St)]};
        {error, E} -> fail({procedure_registration, Name, E})
    end.

%% =========================================================================
%% TCK 值的文字形态
%% =========================================================================

parse_value(S) ->
    case value(skip(S)) of
        {V, Rest} ->
            case skip(Rest) of
                "" -> V;
                Extra -> fail({bad_value, S, Extra})
            end
    end.

skip([C | R]) when C =:= $\s; C =:= $\t; C =:= $\n -> skip(R);
skip(S) -> S.

value("null" ++ R) -> {null, R};
value("true" ++ R) -> {true, R};
value("false" ++ R) -> {false, R};
value("NaN" ++ R) -> {{special, nan}, R};
value("-Infinity" ++ R) -> {{special, ninf}, R};
value("Infinity" ++ R) -> {{special, inf}, R};
value("'" ++ R) -> str(R, $', []);
value("\"" ++ R) -> str(R, $", []);
value("[" ++ R) ->
    case skip(R) of
        ":" ++ _ -> rel("[" ++ skip(R));                %% [:T {k: v}] 是关系
        R1 -> list_items(R1, [])
    end;
value("{" ++ R) -> map_items(skip(R), []);
value("<" ++ R) ->
    {N0, R1} = vnode(skip(R)),
    path_steps(skip(R1), N0, []);
value("(" ++ _ = S) -> vnode(S);
value([C | _] = S) when C =:= $-; C =:= $+; C =:= $.; C >= $0, C =< $9 -> number(S);
value(S) -> fail({bad_value_at, S}).

str([Q | R], Q, Acc) -> {{str, unicode:characters_to_binary(lists:reverse(Acc))}, R};
str([$\\, C | R], Q, Acc) ->
    Ch = case C of $n -> $\n; $t -> $\t; $r -> $\r; $b -> $\b; $f -> $\f; $0 -> 0; _ -> C end,
    case C of
        $u -> {Hex, R2} = lists:split(4, R), str(R2, Q, [list_to_integer(Hex, 16) | Acc]);
        _ -> str(R, Q, [Ch | Acc])
    end;
str([C | R], Q, Acc) -> str(R, Q, [C | Acc]);
str([], _Q, _Acc) -> fail(unterminated_string).

list_items("]" ++ R, Acc) -> {{list, lists:reverse(Acc)}, R};
list_items(S, Acc) ->
    {V, R} = value(skip(S)),
    case skip(R) of
        "," ++ R2 -> list_items(skip(R2), [V | Acc]);
        "]" ++ R2 -> {{list, lists:reverse([V | Acc])}, R2};
        Other -> fail({bad_list, Other})
    end.

map_items("}" ++ R, Acc) -> {{map, lists:reverse(Acc)}, R};
map_items(S, Acc) ->
    {K, R0} = key(skip(S)),
    ":" ++ R1 = skip(R0),
    {V, R2} = value(skip(R1)),
    case skip(R2) of
        "," ++ R3 -> map_items(skip(R3), [{K, V} | Acc]);
        "}" ++ R3 -> {{map, lists:reverse([{K, V} | Acc])}, R3};
        Other -> fail({bad_map, Other})
    end.

key("`" ++ R) -> {K, R2} = lists:splitwith(fun(C) -> C =/= $` end, R), {unicode:characters_to_binary(K), tl(R2)};
key(S) -> {K, R} = lists:splitwith(fun(C) -> C =:= $_ orelse C >= $0 andalso C =< $9 orelse C >= $a andalso C =< $z
                                              orelse C >= $A andalso C =< $Z orelse C > 127 end, S),
          {unicode:characters_to_binary(K), R}.

labels(":" ++ R, Acc) -> {L, R2} = key(R), labels(skip(R2), [L | Acc]);
labels(S, Acc) -> {lists:reverse(Acc), S}.

props("{" ++ R) -> {{map, KVs}, R2} = map_items(skip(R), []), {KVs, R2};
props(S) -> {[], S}.

vnode("(" ++ R) ->
    {Ls, R1} = labels(skip(R), []),
    {Ps, R2} = props(skip(R1)),
    ")" ++ R3 = skip(R2),
    {{node, Ls, Ps}, R3}.

rel("[" ++ R) ->
    {[T], R1} = labels(skip(R), []),
    {Ps, R2} = props(skip(R1)),
    "]" ++ R3 = skip(R2),
    {{rel, T, Ps}, R3}.

path_steps(">" ++ R, N0, Acc) -> {{path, N0, lists:reverse(Acc)}, R};
path_steps("<-" ++ R, N0, Acc) ->
    {Rel, R1} = rel(R), "-" ++ R2 = R1,
    {N, R3} = vnode(R2),
    path_steps(skip(R3), N0, [{Rel, left, N} | Acc]);
path_steps("-" ++ R, N0, Acc) ->
    {Rel, R1} = rel(R), "->" ++ R2 = R1,
    {N, R3} = vnode(R2),
    path_steps(skip(R3), N0, [{Rel, right, N} | Acc]).

number(S) ->
    {Tok, R} = lists:splitwith(fun(C) -> lists:member(C, "+-.eE0123456789xXabcdefABCDEFo") end, S),
    V = case re:run(Tok, "^[+-]?\\d+$", [{capture, none}]) of
            match -> {int, list_to_integer(Tok)};
            nomatch ->
                case re:run(Tok, "^([+-]?)0x([0-9a-fA-F]+)$", [{capture, all_but_first, list}]) of
                    {match, [Sg, H]} -> {int, sign(Sg) * list_to_integer(H, 16)};
                    nomatch ->
                        case re:run(Tok, "^([+-]?)(\\d*)\\.?(\\d*)(?:[eE]([+-]?\\d+))?$", [{capture, all_but_first, list}]) of
                            {match, [Sg, I, F | E]} ->
                                Ex = case E of [X] when X =/= "" -> "e" ++ X; _ -> "" end,
                                {float, list_to_float(Sg ++ dflt(I) ++ "." ++ dflt(F) ++ Ex)};
                            nomatch -> fail({bad_number, Tok})
                        end
                end
        end,
    {V, R}.

dflt("") -> "0";
dflt(X) -> X.
sign("-") -> -1;
sign(_) -> 1.

%% =========================================================================
%% 报告
%% =========================================================================

report(Results, File, Ms) ->
    Cnt = fun(Rs) -> {length([x || {_, pass} <- Rs]), length([x || {_, pass_phase} <- Rs]), length(Rs)} end,
    Groups = lists:usort([maps:get(group, S) || {S, _} <- Results]),
    Lines = [begin
                 {P, PP, T} = Cnt([X || {S, _} = X <- Results, maps:get(group, S) =:= G]),
                 io_lib:format("  ~-36s ~4b / ~4b  ~5.1f%   (~b error-phase-only)~n", [G, P + PP, T, pct(P + PP, T), PP])
             end || G <- Groups],
    {P, PP, T} = Cnt(Results),
    Summary = [case PP of
                   0 -> io_lib:format("openCypher TCK: ~b / ~b passed (~.2f%), ~.1f s~n", [P, T, pct(P, T), Ms / 1000]);
                   _ -> io_lib:format("openCypher TCK: ~b / ~b passed (~.2f%; ~b of them error scenarios matched by phase only), "
                                      "~.1f s~n", [P + PP, T, pct(P + PP, T), PP, Ms / 1000])
               end, Lines],
    io:format("~s", [Summary]),
    Fails = [{S, W} || {S, {fail, W}} <- Results],
    Kinds = lists:foldl(fun({_, W}, M) -> K = kind(W), M#{K => maps:get(K, M, 0) + 1} end, #{}, Fails),
    KindLines = [io_lib:format("  ~-28s ~b~n", [K, N]) || {N, K} <- lists:reverse(lists:sort([{N, K} || {K, N} <- maps:to_list(Kinds)]))],
    io:format("failure kinds:~n~s", [KindLines]),
    Detail = [io_lib:format("~n== ~s :: ~s~n~ts~n", [maps:get(file, S), maps:get(name, S), fmt_fail(S, W)]) || {S, W} <- Fails],
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, unicode:characters_to_binary([Summary, "failure kinds:\n", KindLines, Detail])),
    io:format("report: ~s~n", [File]).

pct(_, 0) -> 0.0;
pct(A, B) -> 100 * A / B.

kind({K, _}) when is_atom(K) -> atom_to_list(K);
kind({K, _, _}) when is_atom(K) -> atom_to_list(K);
kind({K, _, _, _}) when is_atom(K) -> atom_to_list(K);
kind({K, _, _, _, _}) when is_atom(K) -> atom_to_list(K);
kind({K, _, _, _, _, _}) when is_atom(K) -> atom_to_list(K);
kind(K) when is_atom(K) -> atom_to_list(K);
kind(_) -> "other".

fmt_fail(S, W) ->
    Q = case [D || {"executing query:", {doc, D}} <- maps:get(steps, S)] of
            [D | _] -> D;
            [] -> ""
        end,
    io_lib:format("~ts~n  -> ~tP", [indent(Q), W, 40]).

indent(Q) -> ["    " ++ L ++ "\n" || L <- string:split(Q, "\n", all)].
