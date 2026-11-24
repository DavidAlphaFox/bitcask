%% =========================================================================
%% bitcask_cypher_plan — 逻辑计划（doc/cypher-query-design-zh.md 第 6、7 节）
%%
%% 与 Cypher 语法无关：输入是 bitcask_cypher_sema 规范化后的子句，输出一条算子流水线。
%% 执行时从「一行空 map」开始，依次经过每个算子（取点算子对每个输入行各扫一遍，
%% 所以互不连通的模式自然就是嵌套循环——不需要单独的 cross 算子）。
%%
%%   {plan, [Op], Columns}
%%
%% 算子（一期，只读）：
%%   {node_by_id, V, IdExpr}                    id(v) = e / id(v) IN e 起点
%%   {node_by_id, V, IdExpr, nocheck}           同上，紧跟从 v 出发的一跳展开：不单独查存在
%%   {label_scan, V, Label}                     标签索引起点
%%   {label_scan, V, Label, #{push, fetch}}     同上，另带下推条件 / 批量取文档（见下）
%%   {all_nodes_scan, V}                        全部顶点（n 文档 ∪ 邻接表头）
%%   {all_nodes_scan, V, Push}                  有下推条件时：只扫 n 文档，条件交给引擎
%%   {node_check, V, Labels, PropsExpr}         标签 / 内联属性过滤
%%   {expand, From, R, Types, Dir, To, Into, Unique}
%%                                              一跳；Into = 另一端已绑定（查边是否存在）；
%%                                              Unique = 本 MATCH 里已绑定的关系变量（关系唯一性）
%%   {var_expand, From, R, Types, Dir, Min, Max, To, Into, Unique}
%%   {rel_check, R, PropsExpr}                  关系内联属性（变长时逐条）
%%   {shortest_path, P, From, R, Types, Dir, Min, Max, To}
%%   {all_shortest_paths, P, From, R, Types, Dir, Min, Max, To}   每条最短路一行（二期）
%%   {build_path, P, StartVar, [{RelVar, NodeVar}]}              普通命名路径 p = (a)-[r]->(b)…（二期）
%%   {call_proc, Name, [{Column, Var}]}                         CALL db.labels() YIELD …（二期）
%%   {filter, Expr} | {unwind, Expr, V}
%%   {project, [{Name, Expr}], Keep}            Keep = true：保留原有变量（ORDER BY 还要用）
%%   {aggregate, [{Name, Expr}]}                隐式分组：不含聚合的项是分组键
%%   {distinct, [Name]} | {sort, [{Expr, asc | desc}]} | {skip, Expr} | {limit, Expr}
%%   {select, [Name]}                           只留这些列（WITH 之后的作用域 / 最终结果）
%%
%% 检索取点（第 9 节，Q2-5）：
%%   {fts_seek, V, Prop, QueryExpr}             v.text @@ '…' 是 WHERE 的合取项
%%   {search_seek, V, FnName, [ArgExpr]}        fts.phrase / near / wildcard / fuzzy / fields(…)、search.hybrid(…) 是合取项（二期）
%%   {vector_range, V, QExpr, TExpr, Label}     v.embedding <=> q < t（或 <=）
%%   {vector_topk, V, QExpr, Labels, Props, Conjs, Skip, Limit}
%%                                              MATCH (v) … RETURN … ORDER BY v.embedding <=> q LIMIT k
%% 写（第 8 节，Q2-4；整条语句在一个事务里执行）：
%%   {create, [Chain]} | {set, [Item]} | {remove, [Item]} | {delete, Detach, [Expr]}
%%   {merge_node, V, [Label], PropsExpr, OnCreate, OnMatch}
%%   {merge_rel, From, R, Type, PropsExpr, out | in, To, OnCreate, OnMatch}
%%                                              MERGE（二期）：先按模式找，没有再建；之后套 ON CREATE / ON MATCH 的 SET
%%   {merge_pattern, [Op], Chain, OnCreate, OnMatch}
%%                                              整条模式的 MERGE：[Op] 是查找子流水线，找不到就整条 CREATE
%% 可选匹配（二期）：
%%   {optional, [Op], NewVars}                  OPTIONAL MATCH：对每个输入行跑一遍子流水线；没有结果时交出原行，
%%                                              本子句新引入的变量（NewVars）为 null
%%
%% 条件下推（第 7.3 节）：起点是标签扫描 / 全量扫描时，节点上其余的标签、内联属性，以及 WHERE
%% 里只涉及这个变量、另一边是常量 / 参数的比较（= < <= > >=）、IN、IS NOT NULL 收进 Push：
%%   {has_label, L} | {has_any_label, [L]} | {cmp, Key, eq | lt | le | gt | ge, Expr} | {in, Key, Expr}
%%   | {exists, Key}
%% 执行器把它们放宽成引擎 meta filter 的必要条件（整数与浮点两边都查、比较放宽到含等号）交给
%% 引擎，原来的过滤照常留着——下推只负责少读，结果不变。fetch = 后面的算子要用到这个顶点的
%% 标签 / 属性（不只是 id）：标签扫描按块用一次 range 连文档一起取，不再逐个点读。
%%
%% 规则（第 7 节，没有统计信息）：每个连通的模式选一个起点——已绑定的变量 >
%% id(v) 条件 > 有标签（标签扫描，其余标签做过滤）> 全量扫描；从起点沿模式逐跳展开，
%% 另一端已绑定时「展开到」；WHERE 拆成合取项，变量一齐全就立刻过滤。
%% =========================================================================
-module(bitcask_cypher_plan).

-export([plan/1, sub_match/2, sub_query/2, all_ops/1]).

plan(#{query := {union, Mode, Parts}}) ->
    %% UNION：每段单独规划成子流水线，列名（含顺序）必须一致
    try
        Subs = [begin
                    {Ops0, _Bound, Cols} = clauses(Clauses, [], [], undefined),
                    {annotate_scans(Ops0), Cols}
                end || Clauses <- Parts],
        [{_, Cols1} | _] = Subs,
        lists:all(fun({_, C}) -> C =:= Cols1 end, Subs) orelse
            throw({plan_error, bitcask_cypher_error:code('SyntaxError', 'DifferentColumnsInUnion',
                                                         "all parts of a UNION must return the same column names"), undefined}),
        {ok, {plan, [{union, Mode, [O || {O, _} <- Subs], Cols1}], Cols1}}
    catch throw:{plan_error, Msg, Loc} -> plan_error(Msg, Loc)
    end;
plan(#{query := Clauses}) ->
    try
        {Ops0, _Bound, Cols} = clauses(Clauses, [], [], undefined),
        Ops = annotate_scans(Ops0),
        {ok, {plan, Ops, case Cols of undefined -> []; _ -> Cols end}}
    catch throw:{plan_error, Msg, Loc} -> plan_error(Msg, Loc)
    end.

%% 子查询表达式的子计划：Bound 是导入的外层变量。
sub_query({union, Mode, Parts}, Bound) ->
    Subs = [begin {O, _, C} = clauses(Cs, Bound, [], undefined), {annotate_scans(O), C} end || Cs <- Parts],
    %% EXISTS { … UNION … } 的各段可以没有 RETURN（没有列）
    Cols = case Subs of [{_, undefined} | _] -> []; [{_, C0} | _] -> C0 end,
    [{union, Mode, [O || {O, _} <- Subs], Cols}];
sub_query(Clauses, Bound) ->
    {O, _, _} = clauses(Clauses, Bound, [], undefined),
    annotate_scans(O).

%% 计划里的全部算子，递归进子流水线（关系类型预注册、判断有没有写用）。
all_ops(Ops) ->
    lists:append([[Op | all_ops(sub_ops(Op))] || Op <- Ops]).

sub_ops({union, _, Subs, _}) -> lists:append(Subs);
sub_ops({optional, Ops, _}) -> Ops;
sub_ops({merge_pattern, Find, _, _, _}) -> Find;
sub_ops(_) -> [].

plan_error(Msg, Loc) ->
    Base = bitcask_cypher_error:to_map(plan, Msg),
    {error, case Loc of
                {L, C} -> Base#{line => L, column => C};
                _      -> Base
            end}.

%% 子模式（模式谓词 / 模式推导）：Bound 是外层已绑定、子模式用到的变量。
sub_match(Part, Bound) ->
    {Ops, _} = match([Part], undefined, Bound, none),
    annotate_scans(Ops).

clauses([], Bound, Acc, Cols) -> {lists:append(lists:reverse(Acc)), Bound, Cols};
clauses([C | Rest], Bound, Acc, Cols0) ->
    {Ops, Bound2, Cols} = clause(C, Bound, Rest),
    clauses(Rest, Bound2, [Ops | Acc], case Cols of undefined -> Cols0; _ -> Cols end).

clause({match, Parts, Where, _Loc}, Bound, Rest) ->
    {Ops, B2} = match(Parts, Where, Bound, vector_hint(Parts, Rest)),
    {Ops, B2, undefined};
clause({optional_match, Parts, Where, _Loc}, Bound, _Rest) ->
    {Ops, B2} = match(Parts, Where, Bound, none),
    {[{optional, Ops, [V || V <- B2, not lists:member(V, Bound)]}], B2, undefined};
clause({call_proc, Name, Args, Pairs, Where, _Loc}, Bound, _Rest) ->
    {[{call_proc, Name, Args, Pairs}] ++ [{filter, Where} || Where =/= undefined],
     lists:foldl(fun add_bound/2, Bound, [V || {_, V} <- Pairs]), undefined};
clause({merge_pattern, {named_chain, P, Chain}, OnC, OnM, Loc}, Bound, Rest) ->
    {Ops, B2, Cols} = clause({merge_pattern, Chain, OnC, OnM, Loc}, Bound, Rest),
    {Ops ++ [path_op(P, Chain)], add_bound(P, B2), Cols};
clause({merge_pattern, Chain, OnC, OnM, _Loc}, Bound, _Rest) ->
    %% 整条模式：查找用与 MATCH 相同的规划（子流水线），找不到就整条建出来
    {Find, B2} = match([Chain], undefined, Bound, none),
    {[{merge_pattern, Find, Chain, OnC, OnM}], B2, undefined};
clause({merge_node, V, Labels, Props, OnC, OnM, _Loc}, Bound, _Rest) ->
    {[{merge_node, V, Labels, Props, OnC, OnM}], add_bound(V, Bound), undefined};
clause({merge_rel, From, R, Type, Props, Dir, To, OnC, OnM, _Loc}, Bound, _Rest) ->
    {[{merge_rel, From, R, Type, Props, Dir, To, OnC, OnM}], add_bound(R, Bound), undefined};
clause({create, Parts0, _Loc}, Bound, _Rest) ->
    %% CREATE p = (…)：先整条建出来，再把路径拼到 p
    Parts = [case P of {named_chain, _, C} -> C; C -> C end || P <- Parts0],
    PathOps = [path_op(P, C) || {named_chain, P, C} <- Parts0],
    New = lists:append([chain_vars(P) || P <- Parts]) ++ [P || {named_chain, P, _} <- Parts0],
    {[{create, Parts} | PathOps], lists:foldl(fun add_bound/2, Bound, New), undefined};
clause({set, Items, _Loc}, Bound, _Rest) ->
    {[{set, Items}], Bound, undefined};
clause({remove, Items, _Loc}, Bound, _Rest) ->
    {[{remove, Items}], Bound, undefined};
clause({delete, Detach, Es, _Loc}, Bound, _Rest) ->
    {[{delete, Detach, Es}], Bound, undefined};
clause(C, Bound, _Rest) ->
    clause(C, Bound).

path_op(P, {chain, N0, Steps}) ->
    {build_path, P, node_var(N0), [{RV, node_var(N)} || {{rel, RV, _, _, _, _, _}, N} <- Steps]}.

chain_vars({chain, {node, V0, _, _, _}, Steps}) ->
    [V0 | lists:append([[R, N] || {{rel, R, _, _, _, _, _}, {node, N, _, _, _}} <- Steps])].

%% MATCH (v[:L] {…}) [WHERE …] 后面紧跟 RETURN / WITH … ORDER BY v.embedding <=> q LIMIT k
%% （不聚合、不 DISTINCT）：起点换成向量 top-k 检索（第 9.1 节的第二种形态）。
vector_hint([{chain, {node, V, _, _, _}, []}], [Next | _]) ->
    case Next of
        {return, false, Items, false, [{K, asc} | _], Skip, Limit, _} when Limit =/= undefined ->
            topk_hint(V, resolve_item(K, Items), Skip, Limit);
        {with, false, Items, false, [{K, asc} | _], Skip, Limit, _, _} when Limit =/= undefined ->
            topk_hint(V, resolve_item(K, Items), Skip, Limit);
        _ -> none
    end;
vector_hint(_, _) -> none.

resolve_item({var, N} = K, Items) ->
    case lists:keyfind(N, 1, Items) of
        {_, E} -> E;
        false  -> K
    end;
resolve_item(K, _Items) -> K.

topk_hint(V, {op, '<=>', {prop, {var, V}, <<"embedding">>}, QE}, Skip, Limit) ->
    case bitcask_cypher_sema:expr_vars(QE) of
        [] -> {vector_topk, V, QE, Skip, Limit};
        _  -> none
    end;
topk_hint(_, _, _, _) -> none.

clause({unwind, E, V, _Loc}, Bound) ->
    {[{unwind, E, V}], Bound ++ [V], undefined};
clause({with, Distinct, Items, HasAgg, Order, Skip, Limit, Where, _Loc}, _Bound) ->
    Names = [N || {N, _} <- Items],
    %% WITH … WHERE 在 ORDER BY / SKIP / LIMIT 之后、只留投影列之前过滤（这时投影前的变量还在行里）
    Proj = projection(Distinct, Items, HasAgg, Order, Skip, Limit),
    {Head, [{select, _} = Sel]} = lists:split(length(Proj) - 1, Proj),
    Ops = Head ++ [{filter, Where} || Where =/= undefined] ++ [Sel],
    {Ops, Names, undefined};
clause({return, Distinct, Items, HasAgg, Order, Skip, Limit, _Loc}, _Bound) ->
    Names = [N || {N, _} <- Items],
    {projection(Distinct, Items, HasAgg, Order, Skip, Limit), Names, Names}.

projection(Distinct, Items, HasAgg, Order, Skip, Limit) ->
    Names = [N || {N, _} <- Items],
    Head = case {HasAgg, Distinct} of
               {true, false}  -> [{aggregate, Items}];
               {true, true}   -> [{aggregate, Items}, {distinct, Names}];
               {false, true}  -> [{project, Items, false}, {distinct, Names}];
               {false, false} -> [{project, Items, true}]
           end,
    Head ++ [{sort, Order} || Order =/= []]
         ++ [{skip, Skip} || Skip =/= undefined]
         ++ [{limit, Limit} || Limit =/= undefined]
         ++ [{select, Names}].

%% =========================================================================
%% MATCH
%% =========================================================================

-record(n, {var :: binary(), labels = [] :: [binary()], props = [] :: [term()]}).
-record(r, {var :: binary(), from :: binary(), to :: binary(),
            types :: [binary()] | {lexpr, term()} | {qpp, map()},     %% 类型名列表 / 复杂标签表达式 / 量化组
            props :: [term()], dir :: out | in | both,
            min :: non_neg_integer(), max :: non_neg_integer(),
            list = false :: boolean()}).           %% 显式变长（*1..1 也是）：变量是关系列表

match(Parts, Where, Bound0, Hint) ->
    put({?MODULE, hint}, Hint),
    try match_(Parts, Where, Bound0)
    after erase({?MODULE, hint})
    end.

match_(Parts, Where, Bound0) ->
    {Nodes, Rels, Shorts} = collect(Parts),
    PathChains = [{P, C} || {named_chain, P, C} <- Parts] ++ [{P, C} || {searched_chain, P, _, C} <- Parts],
    Paths = [{P, node_var(N0), [{step_rel_var(R), node_var(N)} || {R, N} <- Steps]}
             || {P, {chain, N0, Steps}} <- PathChains],
    %% 路径搜索前缀：先给输入行打标记（不同输入行的路径不混在一起挑），全部条件过滤之后按 (标记, 起点, 终点)
    %% 分组、按长度挑
    Searches = [{P, M, node_var(N0), node_var(last_node(N0, Steps))}
                || {searched_chain, P, M, {chain, N0, Steps}} <- Parts],
    {TagOps, SelOps} = case Searches of
                           [] -> {[], []};
                           _ -> {[{tag_rows, <<"  rowtag">>}],
                                 [{path_select, M, P, S, E, <<"  rowtag">>} || {P, M, S, E} <- Searches]
                                 ++ [{drop_vars, [<<"  rowtag">>]}]}
                       end,
    Conj = conjuncts(Where),
    %% 连通分量（只看普通关系；最短路的两端各自归属所在的分量，最短路本身最后展开）
    Comps = components([N#n.var || N <- Nodes], Rels),
    %% 之前子句已绑定、这里又写了标签 / 属性的节点：先过滤
    PreOps = TagOps ++ lists:append([node_checks(N, []) || N <- Nodes, lists:member(N#n.var, Bound0)]),
    {Ops1, B1, Conj1, Here1} =
        lists:foldl(fun(Comp, {Ops, B, Cs, Here}) ->
                            {O2, B2, Cs2, H2} = plan_component(Comp, Nodes, Rels, B, Cs, Here),
                            {Ops ++ O2, B2, Cs2, H2}
                    end, {PreOps, Bound0, Conj, []}, Comps),
    {Ops2, B2, Conj2} =
        lists:foldl(fun({Kind, P, From, R, To}, {Ops, B, Cs}) ->
                            Op = {Kind, P, From, R#r.var, R#r.types, R#r.dir,
                                  R#r.min, R#r.max, To},
                            B3 = B ++ [R#r.var] ++ [P || P =/= undefined],
                            Checks = [{rel_check, R#r.var, Pr} || Pr <- R#r.props],
                            {Fs, Cs2} = ready_filters(Cs, B3),
                            {Ops ++ [Op] ++ Checks ++ Fs, B3, Cs2}
                    end, {Ops1, B1, Conj1}, Shorts),
    _ = Here1,
    %% 普通命名路径：模式都展开完之后拼出路径值；引用路径变量的条件随后过滤
    PathOps = [{build_path, P, Start, Steps} || {P, Start, Steps} <- Paths],
    B3 = B2 ++ [P || {P, _, _} <- Paths],
    {PFs, Conj3} = ready_filters(Conj2, B3),
    Rest = [{filter, C} || C <- Conj3],
    {Ops2 ++ PathOps ++ PFs ++ Rest ++ SelOps, B3}.

step_rel_var({rel, RV, _, _, _, _, _}) -> RV;
step_rel_var({qpp, _, _, _, _, #{rels := RV}}) -> RV.

last_node(N0, []) -> N0;
last_node(_N0, Steps) -> element(2, lists:last(Steps)).

%% 模式 → 节点表（同一变量的多次出现合并标签与属性）、关系表、最短路表。
collect(Parts) ->
    lists:foldl(fun(P, Acc) -> collect_part(P, Acc) end, {[], [], []}, Parts).

collect_part({named_chain, _P, Chain}, Acc) ->
    collect_part(Chain, Acc);
collect_part({searched_chain, _P, _M, Chain}, Acc) ->
    collect_part(Chain, Acc);
collect_part({all_shortest, P, N0, R, N1, Loc}, Acc) ->
    {Ns, Rs, Ss} = collect_part({shortest, P, N0, R, N1, Loc}, Acc),
    {Ns, Rs, lists:droplast(Ss) ++ [setelement(1, lists:last(Ss), all_shortest_paths)]};
collect_part({chain, N0, Steps}, {Ns, Rs, Ss}) ->
    Ns1 = add_node(N0, Ns),
    {Ns2, Rs2, _} =
        lists:foldl(fun({{qpp, Body, W, Min, Max, #{rels := RV, vars := GVs}}, {node, NV, _, _, _} = N},
                        {NsA, RsA, Prev}) ->
                            %% 量化组：当成连接两端的一条「边」参与分量规划，展开时生成 qpp_expand
                            R = #r{var = RV, from = Prev, to = NV,
                                   types = {qpp, #{body => Body, where => W, vars => GVs}},
                                   props = [], dir = out, min = Min, max = Max, list = true},
                            {add_node(N, NsA), RsA ++ [R], NV};
                       ({{rel, RV, Types, Props, Dir, {Min, Max0}, _}, {node, NV, _, _, _} = N},
                        {NsA, RsA, Prev}) ->
                            {Max, IsList} = case Max0 of {list, M} -> {M, true}; M -> {M, false} end,
                            R = #r{var = RV, from = Prev, to = NV, types = Types,
                                   props = [Props || Props =/= undefined], dir = Dir,
                                   min = Min, max = Max, list = IsList},
                            {add_node(N, NsA), RsA ++ [R], NV}
                    end, {Ns1, Rs, node_var(N0)}, Steps),
    {Ns2, Rs2, Ss};
collect_part({shortest, P, N0, {rel, RV, Types, Props, Dir, {Min, Max}, _}, N1, _Loc}, {Ns, Rs, Ss}) ->
    Ns2 = add_node(N1, add_node(N0, Ns)),
    R = #r{var = RV, from = node_var(N0), to = node_var(N1), types = Types,
           props = [Props || Props =/= undefined], dir = Dir, min = Min, max = Max},
    {Ns2, Rs, Ss ++ [{shortest_path, P, node_var(N0), R, node_var(N1)}]}.

node_var({node, V, _, _, _}) -> V.

add_node({node, V, Labels, Props, _}, Ns) ->
    case lists:keyfind(V, #n.var, Ns) of
        false ->
            Ns ++ [#n{var = V, labels = Labels, props = [Props || Props =/= undefined]}];
        #n{labels = L0, props = P0} = N ->
            N2 = N#n{labels = L0 ++ [L || L <- Labels, not lists:member(L, L0)],
                     props = P0 ++ [Props || Props =/= undefined]},
            lists:keyreplace(V, #n.var, Ns, N2)
    end.

%% 合取项拆分。
conjuncts(undefined) -> [];
conjuncts({op, 'and', A, B}) -> conjuncts(A) ++ conjuncts(B);
conjuncts(E) -> [E].

%% 变量已全部绑定的合取项 → filter（按原顺序），其余留着。
ready_filters(Cs, Bound) ->
    {Ready, Rest} = lists:partition(fun(C) -> subset(bitcask_cypher_sema:expr_vars(C), Bound) end, Cs),
    {[{filter, C} || C <- Ready], Rest}.

subset(Vs, Bound) -> lists:all(fun(V) -> lists:member(V, Bound) end, Vs).

%% 连通分量：按节点首次出现的顺序。
components(Vars, Rels) ->
    Adj = lists:foldl(fun(#r{from = F, to = T}, M) ->
                              M#{F => [T | maps:get(F, M, [])], T => [F | maps:get(T, M, [])]}
                      end, #{}, Rels),
    {Comps, _} = lists:foldl(fun(V, {Acc, Seen}) ->
                                     case is_map_key(V, Seen) of
                                         true -> {Acc, Seen};
                                         false ->
                                             {Comp, Seen2} = reach([V], Adj, Seen#{V => true}, [V]),
                                             {Acc ++ [Comp], Seen2}
                                     end
                             end, {[], #{}}, Vars),
    Comps.

reach([], _Adj, Seen, Acc) -> {lists:reverse(Acc), Seen};
reach([V | Q], Adj, Seen, Acc) ->
    New = [N || N <- lists:usort(maps:get(V, Adj, [])), not is_map_key(N, Seen)],
    Seen2 = lists:foldl(fun(N, S) -> S#{N => true} end, Seen, New),
    reach(Q ++ New, Adj, Seen2, lists:reverse(New) ++ Acc).

%% 一个连通分量：选起点 → 逐跳展开。Here = 本 MATCH 里已绑定的关系变量（关系唯一性）。
plan_component(Comp, Nodes, Rels, B0, Cs0, Here0) ->
    CompNodes = [N || N <- Nodes, lists:member(N#n.var, Comp)],
    CompRels = [R || R <- Rels, lists:member(R#r.from, Comp)],
    {StartOps, Start, Cs1} = start(CompNodes, B0, Cs0),
    B1 = add_bound(Start#n.var, B0),
    Checks0 = case lists:member(Start#n.var, B0) of
                  true  -> [];                    %% 已绑定的：绑定时（或 PreOps）已过滤
                  false -> node_checks(Start, StartOps)
              end,
    {F0, Cs2} = ready_filters(Cs1, B1),
    expand_all(CompRels, CompNodes, B1, Cs2, Here0, StartOps ++ Checks0 ++ F0).

expand_all([], _Nodes, B, Cs, Here, Ops) -> {Ops, B, Cs, Here};
expand_all(Rels, Nodes, B, Cs, Here, Ops) ->
    case pick_rel(Rels, B) of
        none ->
            %% 不该出现（分量是连通的）；兜底：剩下的从未绑定的一端起扫
            throw({plan_error, "internal: disconnected pattern component", undefined});
        {R, Rest} ->
            {From, To, Dir} = case lists:member(R#r.from, B) of
                                  true  -> {R#r.from, R#r.to, R#r.dir};
                                  false -> {R#r.to, R#r.from, flip(R#r.dir)}
                              end,
            Into = lists:member(To, B),
            Op = case {R#r.types, R#r.min, R#r.max, R#r.list} of
                     {{qpp, Spec}, Min, Max, _} ->
                         %% 量化组：从终点一侧展开时用倒过来的组体，组变量列表与关系列表最后翻回模式顺序
                         Reversed = From =/= R#r.from,
                         Spec2 = case Reversed of true -> reverse_qpp(Spec); false -> Spec end,
                         {qpp_expand, From, R#r.var, Spec2, Min, Max, To, Into, Here, Reversed};
                     {_, 1, 1, false} -> {expand, From, R#r.var, R#r.types, Dir, To, Into, Here};
                     {_, Min, Max, _} ->
                         %% 从模式的终点一侧反向展开时，关系列表要翻回模式的方向（执行器按 Reversed 翻转）
                         Reversed = From =/= R#r.from,
                         {var_expand, From, R#r.var, R#r.types, Dir, Min, Max, To, Into, Here, Reversed}
                 end,
            B2 = add_bound(To, add_bound(R#r.var, B)),
            RelChecks = [{rel_check, R#r.var, P} || P <- R#r.props],
            NodeChecks = case Into of
                             true  -> [];
                             false -> node_checks(lists:keyfind(To, #n.var, Nodes), [])
                         end,
            {Fs, Cs2} = ready_filters(Cs, B2),
            expand_all(Rest, Nodes, B2, Cs2, Here ++ [R#r.var], Ops ++ [Op] ++ RelChecks ++ NodeChecks ++ Fs)
    end.

%% 组体倒过来：N0 -R1- N1 … -Rk- Nk → Nk -Rk'- … -R1'- N0（关系方向翻转）
reverse_qpp(#{body := {chain, N0, Steps}} = Spec) ->
    Nodes = [N0 | [N || {_, N} <- Steps]],
    Rels = [flip_rel_dir(R) || {R, _} <- Steps],
    [Last | RevNodes] = lists:reverse(Nodes),
    Spec#{body := {chain, Last, lists:zip(lists:reverse(Rels), RevNodes)}}.

flip_rel_dir({rel, V, Ts, Ps, Dir, VL, L}) -> {rel, V, Ts, Ps, flip(Dir), VL, L}.

pick_rel(Rels, B) ->
    case lists:splitwith(fun(R) -> not (lists:member(R#r.from, B) orelse lists:member(R#r.to, B)) end, Rels) of
        {_, []}            -> none;
        {Before, [R | After]} -> {R, Before ++ After}
    end.

flip(out) -> in;
flip(in) -> out;
flip(both) -> both.

add_bound(V, B) ->
    case lists:member(V, B) of
        true  -> B;
        false -> B ++ [V]
    end.

%% 起点：{Ops, StartNode, 剩下的合取项}。优先级（第 7.1 节）：已绑定 > id() 条件 >
%% 全文 @@ > 向量（top-k 提示 / 阈值）> 标签 > 全量扫描。
start(CompNodes, B, Cs) ->
    case [N || N <- CompNodes, lists:member(N#n.var, B)] of
        [N | _] -> {[], N, Cs};
        [] ->
            case find_id_conj(CompNodes, B, Cs) of
                {N, IdExpr, Cs2} -> {[{node_by_id, N#n.var, IdExpr}], N, Cs2};
                none -> start_search(CompNodes, B, Cs)
            end
    end.

start_search(CompNodes, B, Cs) ->
    Vars = [N#n.var || N <- CompNodes],
    case find_conj(fun(C) -> fts_pin(C, Vars, B) end, Cs) of
        {{V, Prop, QE}, Cs2} ->
            {[{fts_seek, V, Prop, QE}], lists:keyfind(V, #n.var, CompNodes), Cs2};
        {{search, V, Name, Args}, Cs2} ->
            {[{search_seek, V, Name, Args}], lists:keyfind(V, #n.var, CompNodes), Cs2};
        none ->
            case get({?MODULE, hint}) of
                {vector_topk, V, QE, Skip, Limit} when Vars =:= [V] ->
                    N = hd(CompNodes),
                    Mine = [C || C <- Cs, subset(bitcask_cypher_sema:expr_vars(C), [V | B])],
                    {[{vector_topk, V, QE, plain(N#n.labels), N#n.props, Mine, Skip, Limit}], N, Cs};
                _ ->
                    case find_conj(fun(C) -> vrange_pin(C, Vars, B) end, Cs) of
                        {{V, QE, TE}, _} ->
                            N = lists:keyfind(V, #n.var, CompNodes),
                            Label = case plain(N#n.labels) of [L | _] -> L; [] -> undefined end,
                            %% 阈值条件留作过滤（检索只给候选）
                            {[{vector_range, V, QE, TE, Label}], N, Cs};
                        none ->
                            case [N || N <- CompNodes, plain(N#n.labels) =/= []] of
                                [N | _] ->
                                    [L0 | _] = plain(N#n.labels),
                                    Push = pushdown(N, N#n.labels -- [L0], Cs),
                                    {[{label_scan, N#n.var, L0, #{push => Push, fetch => false}}], N, Cs};
                                [] ->
                                    N = hd(CompNodes),
                                    case pushdown(N, N#n.labels, Cs) of
                                        []   -> {[{all_nodes_scan, N#n.var}], N, Cs};
                                        Push -> {[{all_nodes_scan, N#n.var, Push}], N, Cs}
                                    end
                            end
                    end
            end
    end.

find_conj(F, Cs) -> find_conj(F, Cs, []).
find_conj(_F, [], _Seen) -> none;
find_conj(F, [C | Rest], Seen) ->
    case F(C) of
        none -> find_conj(F, Rest, [C | Seen]);
        X    -> {X, lists:reverse(Seen) ++ Rest}
    end.

fts_pin({op, '@@', {prop, {var, V}, Prop}, QE}, Vars, B) ->
    case lists:member(V, Vars) andalso subset(bitcask_cypher_sema:expr_vars(QE), B) of
        true  -> {V, Prop, QE};
        false -> none
    end;
fts_pin({call, Name, _, [First | Rest]} = C, Vars, B) ->
    V = case First of
            {prop, {var, X}, <<"text">>} -> X;
            {var, X} -> X;
            _ -> none
        end,
    case is_search_fn(Name) andalso lists:member(V, Vars)
         andalso subset(lists:append([bitcask_cypher_sema:expr_vars(A) || A <- Rest]), B) of
        true  -> _ = C, {search, V, Name, Rest};
        false -> none
    end;
fts_pin(_, _, _) -> none.

is_search_fn(N) ->
    lists:member(N, [<<"fts.phrase">>, <<"fts.near">>, <<"fts.wildcard">>, <<"fts.fuzzy">>,
                     <<"fts.fields">>, <<"search.hybrid">>]).

vrange_pin({op, Cmp, {op, '<=>', {prop, {var, V}, <<"embedding">>}, QE}, TE}, Vars, B)
  when Cmp =:= '<'; Cmp =:= '<=' ->
    case lists:member(V, Vars) andalso
         subset(bitcask_cypher_sema:expr_vars(QE) ++ bitcask_cypher_sema:expr_vars(TE), B) of
        true  -> {V, QE, TE};
        false -> none
    end;
vrange_pin(_, _, _) -> none.

%% id(v) = e、e = id(v)、id(v) IN e，且 e 只用到已绑定的变量。
find_id_conj(Nodes, B, Cs) ->
    Vars = [N#n.var || N <- Nodes],
    find_id_conj(Cs, Nodes, Vars, B, []).

find_id_conj([], _Nodes, _Vars, _B, _Seen) -> none;
find_id_conj([C | Rest], Nodes, Vars, B, Seen) ->
    case id_pin(C) of
        {V, E} ->
            case lists:member(V, Vars) andalso subset(bitcask_cypher_sema:expr_vars(E), B) of
                true  -> {lists:keyfind(V, #n.var, Nodes), E, lists:reverse(Seen) ++ Rest};
                false -> find_id_conj(Rest, Nodes, Vars, B, [C | Seen])
            end;
        none -> find_id_conj(Rest, Nodes, Vars, B, [C | Seen])
    end.

id_pin({op, '=', {call, <<"id">>, false, [{var, V}]}, E}) -> {V, E};
id_pin({op, '=', E, {call, <<"id">>, false, [{var, V}]}}) -> {V, E};
id_pin({op, in, {call, <<"id">>, false, [{var, V}]}, E}) -> {V, {id_list, E}};
id_pin(_) -> none.

%% 节点上起点算子没覆盖的标签与内联属性。
node_checks(#n{var = V, labels = Ls, props = Ps}, StartOps) ->
    Covered = case StartOps of
                  [{label_scan, V, L}] -> [L];
                  [{label_scan, V, L, _}] -> [L];
                  %% 第一个标签已作为 meta 过滤（_labels contains）下推给向量检索
                  [{vector_topk, V, _, [L | _], _, _, _, _}] -> [L];
                  [{vector_range, V, _, _, L}] when L =/= undefined -> [L];
                  _                    -> []
              end,
    Need = [L || L <- Ls, not lists:member(L, Covered)],
    case {Need, Ps} of
        {[], []} -> [];
        _        -> [{node_check, V, Need, Ps}]
    end.

%% =========================================================================
%% 条件下推（第 7.3 节）
%% =========================================================================

%% 节点 N（变量 V）上能交给引擎的条件：OtherLabels、内联属性（字面映射）、只涉及 V 与常量 /
%% 参数的合取项。正文（text）与向量（embedding）不在 meta 里，不下推。
pushdown(#n{var = V, props = Ps}, OtherLabels, Cs) ->
    label_push(OtherLabels)
        ++ lists:append([inline_push(P) || P <- Ps])
        ++ lists:append([conj_push(C, V) || C <- Cs]).

inline_push({map, KEs}) ->
    [{cmp, K, eq, E} || {K, E} <- KEs, pushable_key(K), bitcask_cypher_sema:expr_vars(E) =:= []];
inline_push(_) -> [].

conj_push({op, '=', {prop, {var, V}, K}, E}, V) -> cmp_push(K, eq, E);
conj_push({op, '=', E, {prop, {var, V}, K}}, V) -> cmp_push(K, eq, E);
conj_push({op, Op, {prop, {var, V}, K}, E}, V) when Op =:= '<'; Op =:= '<='; Op =:= '>'; Op =:= '>=' ->
    cmp_push(K, rel(Op), E);
conj_push({op, Op, E, {prop, {var, V}, K}}, V) when Op =:= '<'; Op =:= '<='; Op =:= '>'; Op =:= '>=' ->
    cmp_push(K, flip_rel(rel(Op)), E);
conj_push({op, in, {prop, {var, V}, K}, E}, V) ->
    case pushable_key(K) andalso bitcask_cypher_sema:expr_vars(E) =:= [] of
        true  -> [{in, K, E}];
        false -> []
    end;
conj_push({is_null, {prop, {var, V}, K}, false}, V) ->
    [{exists, K} || pushable_key(K)];
conj_push({has_labels, {var, V}, Ls}, V) ->
    label_push(Ls);
conj_push(_, _) -> [].

cmp_push(K, Op, E) ->
    case pushable_key(K) andalso bitcask_cypher_sema:expr_vars(E) =:= [] of
        true  -> [{cmp, K, Op, E}];
        false -> []
    end.

%% 标签条件：普通标签 → has_label；A|B → has_any_label（引擎 contains_any）；A&B 拆开；!A、% 不下推。
label_push(Ls) ->
    lists:append([case L of
                      B when is_binary(B) -> [{has_label, B}];
                      {any, As} -> case lists:all(fun is_binary/1, As) of
                                       true -> [{has_any_label, As}];
                                       false -> []
                                   end;
                      {all, As} -> label_push(As);           %% 都要：各项分别下推
                      _ -> []                                 %% !A、%：不下推
                  end || L <- Ls]).

plain(Ls) -> [L || L <- Ls, is_binary(L)].

rel('<') -> lt;
rel('<=') -> le;
rel('>') -> gt;
rel('>=') -> ge.

flip_rel(lt) -> gt;
flip_rel(le) -> ge;
flip_rel(gt) -> lt;
flip_rel(ge) -> le.

pushable_key(<<"text">>) -> false;
pushable_key(<<"embedding">>) -> false;
pushable_key(K) -> is_binary(K).

%% 标签扫描之后的算子要不要这个顶点的标签 / 属性（变量出现在 id(v) 之外的地方）：要就
%% fetch = true。没有下推、也不用 fetch 的标签扫描还原成三元组（explain 形态不变）。
annotate_scans(Ops) -> annotate_scans(Ops, [], []).

%% Tail = 本列表之后还要执行的算子（OPTIONAL MATCH 的子流水线之后还有外层的算子）。
annotate_scans([], _Tail, Acc) -> lists:reverse(Acc);
%% id(v) 起点紧跟从 v 出发的一跳展开（不是「展开到」也可以——展开到同样要 v 有边）：
%% 存在性检查交给展开（没有边就没有行）。变长（可能 0 跳）不在此列。
annotate_scans([{node_by_id, V, E}, {expand, V, _, _, _, _, _, _} = X | Rest], Tail, Acc) ->
    annotate_scans([X | Rest], Tail, [{node_by_id, V, E, nocheck} | Acc]);
annotate_scans([{label_scan, V, L, #{push := Push} = M} | Rest], Tail, Acc) ->
    Fetch = uses_vertex_data(V, [Rest, Tail]),
    Op = case {Push, Fetch} of
             {[], false} -> {label_scan, V, L};
             _           -> {label_scan, V, L, M#{fetch => Fetch}}
         end,
    annotate_scans(Rest, Tail, [Op | Acc]);
annotate_scans([{merge_pattern, Find, Chain, OnC, OnM} | Rest], Tail, Acc) ->
    annotate_scans(Rest, Tail, [{merge_pattern, annotate_scans(Find, [Rest, Tail, OnC, OnM], []), Chain, OnC, OnM} | Acc]);
annotate_scans([{union, _, _, _} = U | Rest], Tail, Acc) ->
    annotate_scans(Rest, Tail, [U | Acc]);
annotate_scans([{optional, Sub, New} | Rest], Tail, Acc) ->
    annotate_scans(Rest, Tail, [{optional, annotate_scans(Sub, [Rest, Tail], []), New} | Acc]);
annotate_scans([Op | Rest], Tail, Acc) ->
    annotate_scans(Rest, Tail, [Op | Acc]).

uses_vertex_data(V, Term) -> uses(V, Term).

uses(V, {call, <<"id">>, _, [{var, V}]}) -> false;
uses(V, {var, V}) -> true;
uses(V, {node_check, V, _, _}) -> true;
uses(V, T) when is_tuple(T) -> uses(V, tuple_to_list(T));
uses(V, [H | T]) -> uses(V, H) orelse uses(V, T);
uses(V, M) when is_map(M) -> uses(V, maps:to_list(M));
uses(_, _) -> false.
