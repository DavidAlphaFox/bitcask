%% =========================================================================
%% bitcask_cypher_exec — 逻辑计划的执行器（doc/cypher-query-design-zh.md 第 6、7、10 节）
%%
%% 拉取式：每个算子把输入流变成输出流，流是惰性的（fun() -> done | {Row, Stream}），
%% 所以 LIMIT 之前的扫描 / 展开在凑够行数后就停下。排序、聚合、去重这类算子要看全部
%% 输入，在那里物化。行是 变量名 → 值 的 map（值的形态见 bitcask_cypher_expr 模块头）。
%%
%% 顶点的标签 / 属性、边的属性、关系类型名在一次查询内按需读、就地缓存（进程字典，
%% 查询结束清掉）：一个顶点被多次展开到只读一次文档。
%%
%% IO：{direct, Handle}（只读查询）或 {txn, Tx}（写语句、或调用方传进来的事务）。事务里
%% 的读都经 bitcask_txn（读锁 + 版本守卫，能读到本事务自己的写），写进事务缓冲、提交时
%% 一条原子批（第 8.1 节）。全文 / 向量检索总是读引擎（看不到同一事务里还没提交的写）。
%% =========================================================================
-module(bitcask_cypher_exec).

-export([run/3, run_io/3, open_stream/3, next_rows/2, search_match/5, pattern_rows/5, subq_eval/6, user_function/3,
         statement_now/0, deleted/1,
         node_info/2, node_vector/2, rel_props/2, type_name/2,
         fts_match/5, fts_score/2, vector_distance/3]).

-define(C(T, D, M), bitcask_cypher_error:code(T, D, M)).    %% openCypher 错误类型 / 细节代码
-define(SCAN_CHUNK, 256).
-define(CACHE_MAX, 100000).
-define(NODES, {?MODULE, nodes}).
-define(RELS, {?MODULE, rels}).
-define(TYPES, {?MODULE, types}).
-define(TYPE_IDS, {?MODULE, type_ids}).
-define(STATS, {?MODULE, stats}).
-define(VDIST, {?MODULE, vdist}).
-define(FTS, {?MODULE, fts}).
-define(FTS_SCORE, {?MODULE, fts_score}).
-define(WRITTEN, {?MODULE, written}).
-define(ACTIVE_RUN, {?MODULE, active_run}).
-define(SCHEMA, {?MODULE, schema}).
-define(SUBPLANS, {?MODULE, subplans}).
-define(NOW, {?MODULE, now}).
-define(HEAP0, {?MODULE, heap0}).            %% 大写语句调高 min_heap_size 前的原值（with_run 结束时恢复）
-define(DELETED, {?MODULE, deleted}).        %% 本语句删掉的顶点（之后再读它的属性是错误）                %% 语句时钟（date() / datetime() 等在一条语句里取同一个时刻）
-define(GROW_HEAP_FROM, 4096).             %% 一条语句写到这么多顶点起按翻番调高 min_heap_size
-define(MAX_ALL_PATHS, 100000).             %% allShortestPaths 一次最多交出的路径数
-define(SEARCH_CAP, 1000000).               %% 引擎 topK 上限（cpp/nif/term_conv.hpp kMaxTopK）
-define(CACHES, [?NODES, ?RELS, ?TYPES, ?TYPE_IDS, ?STATS, ?VDIST, ?FTS, ?FTS_SCORE, ?WRITTEN, ?SCHEMA, ?SUBPLANS, ?NOW, ?DELETED]).

run(H, Plan, Params) -> run_io({direct, H}, Plan, Params).

run_io(Io, {plan, Ops, Cols}, Params) ->
    H = case Io of
            {direct, H0} -> H0;
            {txn, Tx}    -> bitcask_txn:handle(Tx)
        end,
    Ctx = #{io => Io, h => H, params => Params},
    with_run(fun() ->
                     S = lists:foldl(fun(Op, In) -> op(Op, In, Ctx) end, single(#{}), Ops),
                     result(to_list(S), Cols, Ctx)
             end).

%% 查询内缓存用到时才建（cget/1 把不存在当空 map）。顶层查询只需在结束时清掉；嵌套
%% 调用（调用方事务里再跑语句、或语句里回调）才保存外层的、结束时恢复。
with_run(F) ->
    Saved = case get(?ACTIVE_RUN) of
                undefined -> top;
                _ -> [{K, V} || K <- ?CACHES, (V = get(K)) =/= undefined]
            end,
    [erase(K) || K <- ?CACHES, Saved =/= top],
    put(?ACTIVE_RUN, true),
    try F()
    catch
        throw:{exec_error, Msg} ->
            {error, bitcask_cypher_error:to_map(exec, Msg)}
    after
        [erase(K) || K <- ?CACHES],
        case Saved of
            top -> erase(?ACTIVE_RUN), restore_heap();
            _   -> [put(K, V) || {K, V} <- Saved]
        end
    end.

%% 没有 RETURN 的语句（以写子句结尾）不返回行
result(Rows, Cols, Ctx) ->
    Out = case Cols of
              [] -> [];
              _  -> [[out(maps:get(C, R, null), Ctx) || C <- Cols] || R <- Rows]
          end,
    Stats = maps:filter(fun(_K, V) -> V =/= 0 end, cget(?STATS)),
    {ok, #{columns => Cols, rows => Out, stats => Stats}}.

%% ---- 流式游标（bitcask_cypher:cursor/3,4 的游标进程里调用）----------------
%% open_stream：在调用进程里建好查询内缓存与惰性流水线（不清缓存——游标进程结束时随进程消失）。
%% 返回 {ok, Cols, State} | {error, Error}。next_rows(State, N)：取至多 N 行（已转成对外形态），
%% 返回 {ok, Rows, more | done, State2} | {error, Error}。
open_stream(Io, {plan, Ops, Cols}, Params) ->
    H = case Io of {direct, H0} -> H0 end,
    Ctx = #{io => Io, h => H, params => Params},
    put(?ACTIVE_RUN, true),
    try
        S = lists:foldl(fun(Op, In) -> op(Op, In, Ctx) end, single(#{}), Ops),
        {ok, Cols, {S, Cols, Ctx}}
    catch throw:{exec_error, Msg} ->
              {error, bitcask_cypher_error:to_map(exec, Msg)}
    end.

next_rows({S, Cols, Ctx}, N) ->
    try
        {Rows, Rest} = pull(S, N, []),
        Out = [[out(maps:get(C, R, null), Ctx) || C <- Cols] || R <- Rows],
        case Rest of
            done -> {ok, Out, done, {fun() -> done end, Cols, Ctx}};
            S2   -> {ok, Out, more, {S2, Cols, Ctx}}
        end
    catch throw:{exec_error, Msg} ->
              {error, bitcask_cypher_error:to_map(exec, Msg)}
    end.

select_paths(Mode, K, P, Rows) ->
    Len = fun(Row) -> case maps:get(P, Row, null) of {path, _, Rels} -> length(Rels); _ -> 0 end end,
    Sorted = [R || {_, R} <- lists:keysort(1, [{Len(R), R} || R <- Rows])],
    case {Mode, Sorted} of
        {_, []} -> [];
        {{any, _}, _} -> lists:sublist(Rows, K);
        {{shortest, _}, _} -> lists:sublist(Sorted, K);
        {any_shortest, [First | _]} -> [First];
        {all_shortest, [First | _]} -> Min = Len(First), [R || R <- Sorted, Len(R) =:= Min];
        {{groups, _}, _} ->
            Lens = lists:sublist(lists:usort([Len(R) || R <- Sorted]), K),
            [R || R <- Sorted, lists:member(Len(R), Lens)]
    end.

%% 取 N 行；流尽了 Rest = done（多看一步，免得调用方再白取一次才知道结束）。
pull(S, 0, Acc) ->
    case S() of
        done -> {lists:reverse(Acc), done};
        {X, S2} -> {lists:reverse(Acc), fun() -> {X, S2} end}
    end;
pull(S, N, Acc) ->
    case S() of
        done -> {lists:reverse(Acc), done};
        {X, S2} -> pull(S2, N - 1, [X | Acc])
    end.

cget(K) ->
    case get(K) of
        undefined -> #{};
        M -> M
    end.

%% =========================================================================
%% 算子
%% =========================================================================

op({node_by_id, V, IdE, nocheck}, In, Ctx) ->
    %% 规划器确认紧接着就是从 V 出发的一跳展开：没有边的 id 在展开时自然消失，有边的
    %% 顶点一定存在——省掉每个起点一次存在性点读。
    flatmap(fun(Row) -> [Row#{V => {node, Id}} || Id <- start_ids(IdE, Row, Ctx)] end, In);
op({node_by_id, V, IdE}, In, Ctx) ->
    flatmap(fun(Row) ->
                    [Row#{V => {node, Id}} || Id <- start_ids(IdE, Row, Ctx), vertex_exists(Id, Ctx)]
            end, In);
op({label_scan, V, Label}, In, #{io := {txn, Tx}}) ->
    Pre = graphdb_model:label_prefix(Label),
    PL = byte_size(Pre),
    flatmap(fun(Row) ->
                    [Row#{V => {node, Vid}} || {<<_:PL/binary, Vid:64/big>>, _} <- txn_prefix(Tx, Pre)]
            end, In);
op({label_scan, V, Label}, In, Ctx) ->
    H = h(Ctx),
    Fetch = fun(After) -> check(graphdb_model:label_vids(H, Label, {?SCAN_CHUNK, After})) end,
    flatmap(fun(Row) -> map(fun(Vid) -> Row#{V => {node, Vid}} end, chunked(Fetch, undefined)) end, In);
op({label_scan, V, Label, M}, In, #{io := {txn, _}} = Ctx) ->
    %% 事务里：有就绪的属性索引可用就读索引条目（锁的是该值 / 该属性的索引前缀，比锁整个标签
    %% 窄，同样防幻读——索引条目与标签条目同批写）；否则照旧带前缀读锁扫标签索引
    Push = maps:get(push, M, []),
    case Push of
        [] -> op({label_scan, V, Label}, In, Ctx);
        _ ->
            flatmap(fun(Row) ->
                            case index_seek(Label, Push, Row, Ctx) of
                                {ok, Vids} -> [Row#{V => {node, Vid}} || Vid <- Vids];
                                none -> to_list(op({label_scan, V, Label}, single(Row), Ctx))
                            end
                    end, In)
    end;
op({label_scan, V, Label, #{push := Push}}, In, Ctx) ->
    %% 第 7.3 节：标签索引按块给出 vid；一块里 vid 分布够密时，对这一段 vid 做一次 range，
    %% 标签与下推条件交给引擎过滤，文档（正文 + meta）随同一次读回来、填进顶点缓存——不再
    %% 逐个 get_doc。太稀疏的块（跨度超过个数的 4 倍）照旧逐个读，免得为几个顶点扫一大段。
    H = h(Ctx),
    Fetch = fun(After) -> check(graphdb_model:label_vids(H, Label, {?SCAN_CHUNK, After})) end,
    flatmap(fun(Row) ->
                    case index_seek(Label, Push, Row, Ctx) of
                        {ok, Vids} ->
                            %% 属性索引（二期）：条件交给索引，原有过滤照常
                            map(fun(Vid) -> Row#{V => {node, Vid}} end, from_list(Vids));
                        none ->
                            {Filter, Strict} = engine_filter([{has_label, Label} | Push], Row, Ctx),
                            Expand = fun(Vs) -> fetch_chunk(Vs, Filter, Strict, Ctx) end,
                            map(fun(Vid) -> Row#{V => {node, Vid}} end, chunked_by(Fetch, Expand, undefined))
                    end
            end, In);
op({all_nodes_scan, V}, In, #{io := {txn, Tx}}) ->
    P = graphdb_adj:prefix(),
    Vids = fun(F) -> [Vid || {<<_:4/binary, _:8, Vid:64/big>>, _} <- txn_prefix(Tx, <<P/binary, F/binary>>)] end,
    flatmap(fun(Row) ->
                    All = lists:usort(Vids(<<"n">>) ++ Vids(<<"a">>)),
                    [Row#{V => {node, Vid}} || Vid <- All]
            end, In);
op({all_nodes_scan, V, _Push}, In, #{io := {txn, _}} = Ctx) ->
    op({all_nodes_scan, V}, In, Ctx);
op({all_nodes_scan, V, Push}, In, Ctx) ->
    %% 有下推条件：条件都要 meta，只有邻接表头、没有 n 文档的顶点不可能满足——只扫 n 文档，
    %% 条件交给引擎，文档随同一次读回来。
    flatmap(fun(Row) ->
                    {Filter, _} = engine_filter(Push, Row, Ctx),
                    Fetch = fun(After) -> scan_docs(After, Filter, Ctx) end,
                    map(fun(Vid) -> Row#{V => {node, Vid}} end, chunked(Fetch, undefined))
            end, In);
op({all_nodes_scan, V}, In, Ctx) ->
    H = h(Ctx),
    flatmap(fun(Row) ->
                    S = merge_sorted(chunked(fun(A) -> family_vids(H, <<"n">>, A) end, undefined),
                                     chunked(fun(A) -> family_vids(H, <<"a">>, A) end, undefined)),
                    map(fun(Vid) -> Row#{V => {node, Vid}} end, S)
            end, In);
op({fts_seek, V, Prop, QE}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case eval(QE, Row, Ctx) of
                        null -> [];
                        QS when is_binary(QS) ->
                            Hits = fts_set(Prop, QS, Ctx),
                            Ordered = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Hits)),
                            [Row#{V => {node, Vid}, score_key(V) => Sc} || {Vid, Sc} <- Ordered];
                        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "the right side of @@ must be a string")})
                    end
            end, In);
op({search_seek, V, Name, ArgEs}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case search_args(Name, [eval(E, Row, Ctx) || E <- ArgEs]) of
                        null -> [];
                        Vals ->
                            Hits = search_set(Name, Vals, Ctx),
                            Ordered = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Hits)),
                            [Row#{V => {node, Vid}, score_key(V) => Sc} || {Vid, Sc} <- Ordered]
                    end
            end, In);
op({vector_range, V, QE, TE, Label}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case {eval(QE, Row, Ctx), eval(TE, Row, Ctx)} of
                        {null, _} -> [];
                        {_, null} -> [];
                        {Q, T} when is_number(T) ->
                            [Row#{V => {node, Vid}} || Vid <- vector_range(to_f32(Q), T, Label, Ctx)];
                        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "vector threshold must be a number")})
                    end
            end, In);
op({vector_topk, V, QE, Labels, PropsEs, Conjs, SkipE, LimitE}, In, Ctx) ->
    K = count_or_zero(SkipE, Ctx) + count_arg(LimitE, "LIMIT", Ctx),
    flatmap(fun(Row) ->
                    case eval(QE, Row, Ctx) of
                        null -> [];
                        Q ->
                            Label = case Labels of [L | _] -> L; [] -> undefined end,
                            %% 第一个标签由引擎按 meta 过滤；其余标签、内联属性、合取项在这里判断——
                            %% 都没有时不读候选的文档
                            Rest = tl(Labels ++ [x]) -- [x],
                            Pass = case {Rest, PropsEs, Conjs} of
                                       {[], [], []} -> fun(_) -> true end;
                                       _ ->
                                           fun(Vid) ->
                                                   R1 = Row#{V => {node, Vid}},
                                                   node_ok(Vid, Rest, PropsEs, R1, Ctx) andalso
                                                       lists:all(fun(C) -> bitcask_cypher_expr:truthy(eval(C, R1, Ctx)) end, Conjs)
                                           end
                                   end,
                            [Row#{V => {node, Vid}} || Vid <- vector_topk(to_f32(Q), K, Label, Pass, Ctx)]
                    end
            end, In);
op({optional, Sub, New}, In, Ctx) ->
    %% OPTIONAL MATCH：每个输入行各跑一遍子流水线；一行都没有时交出原行、新变量为 null。
    flatmap(fun(Row) ->
                    S = lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Sub),
                    case S() of
                        done -> [lists:foldl(fun(V, R) -> R#{V => null} end, Row, New)];
                        {X, S2} -> append(from_list([X]), S2)
                    end
            end, In);
op({merge_node, V, Labels, PropsE, OnC, OnM}, In, Ctx) ->
    %% MERGE (v:L {…})：按标签（没有标签就全量）+ 属性找；找到几个就交出几行（各自套 ON MATCH），
    %% 一个都没有就建一个（套 ON CREATE）。按标签找走事务的前缀读锁，与并发的 MERGE 串行。
    Tx = txn(Ctx),
    from_list(lists:append(
      [begin
           merge_props(PropsE, Row, Ctx),
           Find = case Labels of
                      [L | More] -> [{label_scan, V, L}, {node_check, V, More, [P || P <- [PropsE], P =/= undefined]}];
                      []         -> [{all_nodes_scan, V}, {node_check, V, [], [P || P <- [PropsE], P =/= undefined]}]
                  end,
           case to_list(lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Find)) of
               [] ->
                   R1 = create_node({node, V, Labels, PropsE, undefined}, Row, Tx, Ctx),
                   [apply_sets(OnC, R1, Tx, Ctx)];
               Found ->
                   [apply_sets(OnM, R, Tx, Ctx) || R <- Found]
           end
       end || Row <- to_list(In)]));
op({merge_rel, From, R, Type, PropsE, Dir, To, OnC, OnM}, In, Ctx) ->
    %% MERGE (a)-[r:T {…}]->(b)：两端已绑定；找 a、b 之间这种类型、属性相符的边，没有就建一条。
    Tx = txn(Ctx),
    from_list(lists:append(
      [begin
           merge_props(PropsE, Row, Ctx),
           lists:foreach(fun(N) ->
                                 case maps:get(N, Row, null) of
                                     {node, _} -> ok;
                                     _ -> throw({exec_error, ?C('SemanticError', 'none', ["MERGE needs `", N, "` to be a node (it is null)"])})
                                 end
                         end, [From, To]),
           Find = [{expand, From, R, [Type], Dir, To, true, []}] ++
                  [{rel_check, R, PropsE} || PropsE =/= undefined],
           case to_list(lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Find)) of
               [] ->
                   {node, A} = maps:get(From, Row),
                   {node, B} = maps:get(To, Row),
                   R1 = create_rel({rel, R, [Type], PropsE, Dir, {1, 1}, undefined}, A, B, Row, Tx, Ctx),
                   [apply_sets(OnC, R1, Tx, Ctx)];
               Found ->
                   [apply_sets(OnM, Rw, Tx, Ctx) || Rw <- Found]
           end
       end || Row <- to_list(In)]));
op({merge_pattern, Find, {chain, N0, Steps} = Chain, OnC, OnM}, In, Ctx) ->
    %% 整条模式的 MERGE：查找子流水线有结果 → 逐行套 ON MATCH；没有 → 整条 CREATE 再套 ON CREATE。
    Tx = txn(Ctx),
    Nodes = [N0 | [N || {_, N} <- Steps]],
    from_list(lists:append(
      [begin
           [merge_props(P, Row, Ctx) || {node, _, _, P, _} <- Nodes],
           [merge_props(P, Row, Ctx) || {{rel, _, _, P, _, _, _}, _} <- Steps],
           [throw({exec_error, ?C('SemanticError', 'none', ["MERGE needs `", V, "` to be a node (it is null)"])})
            || {node, V, _, _, _} <- Nodes, maps:get(V, Row, undefined) =:= null],
           case to_list(lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Find)) of
               [] -> [apply_sets(OnC, create_chain(Chain, Row, Tx, Ctx), Tx, Ctx)];
               Found -> [apply_sets(OnM, R, Tx, Ctx) || R <- Found]
           end
       end || Row <- to_list(In)]));
op({create, Chains}, In, Ctx) ->
    Tx = txn(Ctx),
    from_list([lists:foldl(fun(Ch, R) -> create_chain(Ch, R, Tx, Ctx) end, Row, Chains)
               || Row <- to_list(In)]);
op({set, Items}, In, Ctx) ->
    Tx = txn(Ctx),
    from_list([lists:foldl(fun(It, R) -> set_item(It, R, Tx, Ctx) end, Row, Items)
               || Row <- to_list(In)]);
op({remove, Items}, In, Ctx) ->
    Tx = txn(Ctx),
    from_list([lists:foldl(fun(It, R) -> remove_item(It, R, Tx, Ctx) end, Row, Items)
               || Row <- to_list(In)]);
op({delete, Detach, Es}, In, Ctx) ->
    Tx = txn(Ctx),
    Rows = to_list(In),
    Vals = lists:append([[eval(E, Row, Ctx) || E <- Es] || Row <- Rows]),
    {Nodes, Rels} = delete_targets(Vals, {[], []}),
    delete_all(lists:usort(Rels), lists:usort(Nodes), Detach, Tx, Ctx),
    from_list(Rows);
op({node_check, V, Labels, PropsEs}, In, Ctx) ->
    filter(fun(Row) ->
                   case maps:get(V, Row, null) of
                       {node, Vid} -> node_ok(Vid, Labels, PropsEs, Row, Ctx);
                       _ -> false
                   end
           end, In);
op({rel_check, R, PropsE}, In, Ctx) ->
    filter(fun(Row) ->
                   Rels = case maps:get(R, Row, null) of
                              L when is_list(L) -> L;
                              null -> [];
                              X -> [X]
                          end,
                   lists:all(fun(Rel) -> props_match(rel_props(Rel, Ctx), [PropsE], Row, Ctx) end, Rels)
           end, In);
op({expand, From, R, Types, Dir, To, Into, Unique}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case maps:get(From, Row, null) of
                        {node, V} ->
                            Used = used_rels(Unique, Row),
                            Target = target(Into, To, Row),
                            [Row#{R => Rel, To => {node, O}}
                             || {Rel, O} <- edges(V, Types, Dir, Ctx),
                                Target =:= any orelse Target =:= O,
                                not is_map_key(rel_id(Rel), Used)];
                        _ -> []
                    end
            end, In);
op({var_expand, From, R, Types, Dir, Min, Max, To, Into, Unique}, In, Ctx) ->
    op({var_expand, From, R, Types, Dir, Min, Max, To, Into, Unique, false}, In, Ctx);
op({var_expand, From, R, Types, Dir, Min, Max, To, Into, Unique, Reversed}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case maps:get(From, Row, null) of
                        {node, V} ->
                            Used = used_rels(Unique, Row),
                            Target = target(Into, To, Row),
                            Paths = var_paths(V, Types, Dir, Min, Max, Used, Ctx),
                            [Row#{R => case Reversed of true -> lists:reverse(Rels); false -> Rels end, To => {node, O}}
                             || {O, Rels} <- Paths, Target =:= any orelse Target =:= O];
                        _ -> []
                    end
            end, In);
%% 量化组（量化路径）：从 From 起按组体逐次深度优先展开（每次重复：组体第一个节点 = 当前节点，沿组体的关系走到
%% 最后一个节点，检查标签 / 属性与组的 WHERE；关系在整条路径里不能重复，也不能用到 Unique 里已用的）。重复次数在
%% [Min, Max] 内的每一种都出一行：To = 终点，R = 整段的关系列表，组变量 = 每次重复一个值的列表（按模式顺序）。
op({qpp_expand, From, R, Spec, Min, Max, To, Into, Unique, Reversed}, In, Ctx) ->
    #{vars := GVars} = Spec,
    flatmap(fun(Row) ->
                    case maps:get(From, Row, null) of
                        {node, V} ->
                            Target = target(Into, To, Row),
                            Results = qpp_dfs(V, 0, [], used_rels(Unique, Row), [], Spec, Min, Max, Row, Ctx),
                            [begin
                                 Its = case Reversed of true -> lists:reverse(Iters); false -> Iters end,
                                 Rels2 = case Reversed of true -> lists:reverse(Rels); false -> Rels end,
                                 Groups = maps:from_list([{GV, [maps:get(GV, It, null) || It <- Its]} || GV <- GVars]),
                                 maps:merge(Row#{R => Rels2, To => {node, E}}, Groups)
                             end || {E, Iters, Rels} <- Results, Target =:= any orelse Target =:= E];
                        _ -> []
                    end
            end, In);
op({shortest_path, P, From, R, Types, Dir, Min, Max, To}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case {maps:get(From, Row, null), maps:get(To, Row, null)} of
                        {{node, A}, {node, B}} ->
                            case shortest(A, B, Types, Dir, Min, Max, Ctx) of
                                none -> [];
                                {Nodes, Rels} ->
                                    Row1 = Row#{R => Rels},
                                    [case P of
                                         undefined -> Row1;
                                         _ -> Row1#{P => {path, [{node, N} || N <- Nodes], Rels}}
                                     end]
                            end;
                        _ -> []
                    end
            end, In);
op({all_shortest_paths, P, From, R, Types, Dir, Min, Max, To}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case {maps:get(From, Row, null), maps:get(To, Row, null)} of
                        {{node, A}, {node, B}} ->
                            [case P of
                                 undefined -> Row#{R => Rels};
                                 _ -> Row#{R => Rels, P => {path, [{node, N} || N <- Nodes], Rels}}
                             end || {Nodes, Rels} <- all_shortest(A, B, Types, Dir, Min, Max, Ctx)];
                        _ -> []
                    end
            end, In);
%% UNION：各段的子流水线依次接起来（惰性：前一段流完才开始跑下一段）；UNION 再按列去重
op({union, Mode, Subs, Cols}, In, Ctx) ->
    %% 顶层的输入是一个空行；在子查询里是导入的外层变量
    All = flatmap(fun(Row) ->
                          lists:foldr(fun(Ops, Acc) ->
                                              append(fun() -> (run_sub(Ops, Row, Ctx))() end, Acc)
                                      end, empty(), Subs)
                  end, In),
    Only = map(fun(Row) -> maps:with(Cols, Row) end, All),
    case Mode of
        all -> Only;
        distinct -> op({distinct, Cols}, Only, Ctx)
    end;
%% 路径搜索前缀（openCypher 2024.3）：tag_rows 给输入行打标记；path_select 把行按 (标记, 起点, 终点) 分组（分组按
%% 第一次出现的顺序），组内按路径长度稳定排序后挑：
%%   {any, K} 前 K 条；any_shortest 最短的一条；all_shortest 全部最短的；{shortest, K} 最短的 K 条；
%%   {groups, K} 长度在最小的 K 种之内的全部。
op({tag_rows, T}, In, _Ctx) ->
    map(fun(Row) -> Row#{T => make_ref()} end, In);
op({drop_vars, Vs}, In, _Ctx) ->
    map(fun(Row) -> maps:without(Vs, Row) end, In);
op({path_select, Mode, P, S, E, T}, In, Ctx) ->
    K = case Mode of
            {_, KE} ->
                case eval(KE, #{}, Ctx) of
                    N when is_integer(N), N >= 0 -> N;
                    _ -> throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue',
                                               "the number of paths must be a non-negative integer")})
                end;
            _ -> undefined
        end,
    lazy(fun() ->
                 Rows = to_list(In),
                 {Order, Groups} =
                     lists:foldl(fun(Row, {O, G}) ->
                                         Key = {maps:get(T, Row, null), maps:get(S, Row, null), maps:get(E, Row, null)},
                                         case maps:find(Key, G) of
                                             {ok, L} -> {O, G#{Key := [Row | L]}};
                                             error -> {[Key | O], G#{Key => [Row]}}
                                         end
                                 end, {[], #{}}, Rows),
                 from_list(lists:append([select_paths(Mode, K, P, lists:reverse(maps:get(Key, Groups)))
                                         || Key <- lists:reverse(Order)]))
         end);
op({build_path, P, Start, Steps}, In, _Ctx) ->
    map(fun(Row) -> Row#{P => build_path(maps:get(Start, Row, null), Steps, Row)} end, In);
op({call_proc, Name, [], Pairs}, In, Ctx) when Name =:= <<"db.labels">>; Name =:= <<"db.relationshiptypes">>;
                                                Name =:= <<"db.propertykeys">> ->
    %% 内置过程与行无关：只算一次
    Recs = call_proc(Name, Ctx),
    flatmap(fun(Row) ->
                    [lists:foldl(fun({Col, V}, R) -> R#{V => maps:get(Col, Rec)} end, Row, Pairs) || Rec <- Recs]
            end, In);
op({call_proc, Name, Args, []}, In, Ctx) ->
    %% 没有输出列的过程：每行调一次（为副作用），行原样往下
    map(fun(Row) ->
                case bitcask_cypher_registry:call_procedure(Name, [eval(A, Row, Ctx) || A <- Args], proc_ctx(Ctx), #{}) of
                    {stream, S} -> _ = to_list(S);
                    _ -> ok
                end,
                Row
        end, In);
op({call_proc, Name, Args, Pairs}, In, Ctx) ->
    %% 用户过程：每行按求值后的参数调一次
    flatmap(fun(Row) ->
                    Out = case bitcask_cypher_registry:call_procedure(
                                 Name, [eval(A, Row, Ctx) || A <- Args], proc_ctx(Ctx), #{}) of
                              {stream, S} -> S;
                              L -> from_list(L)
                          end,
                    map(fun(Rec) -> lists:foldl(fun({Col, V}, R) -> R#{V => maps:get(Col, Rec)} end, Row, Pairs) end,
                        Out)
            end, In);
op({filter, E}, In, Ctx) ->
    filter(fun(Row) -> bitcask_cypher_expr:truthy(eval(E, Row, Ctx)) end, In);
op({unwind, E, V}, In, Ctx) ->
    flatmap(fun(Row) ->
                    case eval(E, Row, Ctx) of
                        null -> [];
                        L when is_list(L) -> [Row#{V => X} || X <- L];
                        X -> [Row#{V => X}]
                    end
            end, In);
op({project, Items, Keep}, In, Ctx) ->
    map(fun(Row) ->
                P = maps:from_list([{N, eval(E, Row, Ctx)} || {N, E} <- Items]),
                case Keep of
                    true  -> maps:merge(Row, P);
                    false -> P
                end
        end, In);
op({aggregate, Items}, In, Ctx) ->
    from_list(aggregate(Items, to_list(In), Ctx));
op({distinct, Names}, In, _Ctx) ->
    {Out, _} = lists:foldl(fun(Row, {Acc, Seen}) ->
                                   K = [bitcask_cypher_expr:group_key(maps:get(N, Row, null)) || N <- Names],
                                   case is_map_key(K, Seen) of
                                       true  -> {Acc, Seen};
                                       false -> {[Row | Acc], Seen#{K => true}}
                                   end
                           end, {[], #{}}, to_list(In)),
    from_list(lists:reverse(Out));
op({sort, Keys}, In, Ctx) ->
    Rows0 = to_list(In),
    prefetch_distances(Keys, Rows0, Ctx),
    Keyed = [{[eval(E, Row, Ctx) || {E, _} <- Keys], Row} || Row <- Rows0],
    Dirs = [D || {_, D} <- Keys],
    Sorted = lists:sort(fun({Ka, _}, {Kb, _}) -> sort_le(Ka, Kb, Dirs) end, Keyed),
    from_list([Row || {_, Row} <- Sorted]);
op({skip, E}, In, Ctx) ->
    drop(count_arg(E, "SKIP", Ctx), In);
op({limit, E}, In, Ctx) ->
    take(count_arg(E, "LIMIT", Ctx), In);
op({select, Names}, In, _Ctx) ->
    map(fun(Row) -> maps:from_list([{N, maps:get(N, Row, null)} || N <- Names]) end, In).

eval(E, Row, Ctx) -> bitcask_cypher_expr:eval(E, Row, Ctx).

%% id(v) = e / id(v) IN e 的候选 id（去重、只留合法 vid）。
start_ids({id_list, E}, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        L when is_list(L) -> lists:usort([I || I <- L, is_vid(I)]);
        null -> [];
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "id(v) IN needs a list")})
    end;
start_ids(E, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        I -> case is_vid(I) of true -> [I]; false -> [] end
    end.

node_ok(Vid, Labels, PropsEs, Row, Ctx) ->
    #{labels := Have} = Info = node_info(Vid, Ctx),
    lists:all(fun(L) -> bitcask_cypher_expr:label_ok(L, Have) end, Labels)
        andalso props_match(maps:get(properties, Info), PropsEs, Row, Ctx).

count_or_zero(undefined, _Ctx) -> 0;
count_or_zero(E, Ctx) -> count_arg(E, "SKIP", Ctx).

txn(#{io := {txn, Tx}}) -> Tx;
txn(_) -> throw({exec_error, "internal: updating clause outside a transaction"}).

txn_prefix(Tx, Prefix) ->
    case bitcask_txn:prefix_range(Tx, Prefix) of
        {error, R} -> bitcask_txn:abort(R);
        Rows       -> Rows
    end.

vertex_exists(Vid, #{io := {direct, H}}) -> graphdb_model:vertex_exists(H, Vid);
vertex_exists(Vid, #{io := {txn, Tx}}) -> graphdb_model:txn_vertex_exists(Tx, Vid).

stat(K, N) ->
    S = cget(?STATS),
    put(?STATS, S#{K => maps:get(K, S, 0) + N}).

h(#{h := H}) -> H.

is_vid(I) -> is_integer(I) andalso I >= 0 andalso I =< 16#FFFFFFFFFFFFFFFF.

check({ok, X}) -> X;
check({error, R}) -> throw({exec_error, io_lib:format("storage error: ~p", [R])}).

target(false, _To, _Row) -> any;
target(true, To, Row) ->
    case maps:get(To, Row, null) of
        {node, O} -> O;
        _         -> none
    end.

count_arg(E, What, Ctx) ->
    case eval(E, #{}, Ctx) of
        N when is_integer(N), N >= 0 -> N;
        N when is_integer(N) -> throw({exec_error, ?C('SyntaxError', 'NegativeIntegerArgument', [What, " needs a non-negative integer"])});
        _ -> throw({exec_error, ?C('SyntaxError', 'InvalidArgumentType', [What, " needs a non-negative integer"])})
    end.

props_match(_Props, [], _Row, _Ctx) -> true;
props_match(Props, [PE | Rest], Row, Ctx) ->
    case eval(PE, Row, Ctx) of
        M when is_map(M) ->
            lists:all(fun({K, V}) -> bitcask_cypher_expr:eq(maps:get(K, Props, null), V) =:= true end,
                      maps:to_list(M))
                andalso props_match(Props, Rest, Row, Ctx);
        null -> false;
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "pattern properties must be a map")})
    end.

%% ORDER BY：逐键比较；DESC 反转（null 在 ASC 最后、DESC 最前）。
sort_le([], [], []) -> true;
sort_le([A | As], [B | Bs], [{_D, Nulls} | Ds]) when A =:= null; B =:= null ->
    %% NULLS FIRST / LAST：null 的位置与方向无关
    case {A, B} of
        {null, null} -> sort_le(As, Bs, Ds);
        {null, _}    -> Nulls =:= first;
        {_, null}    -> Nulls =:= last
    end;
sort_le([A | As], [B | Bs], [{D, _} | Ds]) ->
    sort_le([A | As], [B | Bs], [D | Ds]);
sort_le([A | As], [B | Bs], [D | Ds]) ->
    case bitcask_cypher_expr:order_cmp(A, B) andalso bitcask_cypher_expr:order_cmp(B, A) of
        true -> sort_le(As, Bs, Ds);                      %% 相等：看下一个键
        false ->
            Le = bitcask_cypher_expr:order_cmp(A, B),
            case D of asc -> Le; desc -> not Le end
    end.

%% =========================================================================
%% 聚合（隐式分组）
%% =========================================================================

aggregate(Items, Rows, Ctx) ->
    Plain = [{N, E} || {N, E} <- Items, not bitcask_cypher_sema:contains_aggregate(E)],
    {AggItems, _} =
        lists:mapfoldl(fun({N, E}, Base) ->
                               case bitcask_cypher_sema:contains_aggregate(E) of
                                   false -> {skip, Base};
                                   true ->
                                       Specs = bitcask_cypher_expr:find_aggs(E),
                                       Refd = [{Base + I, A} || {I, A} <- Specs],
                                       {{N, bitcask_cypher_expr:replace_aggs(E, Base), Refd}, Base + length(Specs)}
                               end
                       end, 0, Items),
    Aggs = [A || A <- AggItems, A =/= skip],
    Specs = lists:append([Refd || {_, _, Refd} <- Aggs]),
    Init = [{Ref, bitcask_cypher_expr:agg_init(A, Ctx)} || {Ref, A} <- Specs],
    {Groups, Order} =
        lists:foldl(
          fun(Row, {G, Ord}) ->
                  Vals = [{N, eval(E, Row, Ctx)} || {N, E} <- Plain],
                  K = [bitcask_cypher_expr:group_key(V) || {_, V} <- Vals],
                  {Vals0, Accs0, Ord2} = case maps:find(K, G) of
                                             {ok, {Vs, As}} -> {Vs, As, Ord};
                                             error          -> {Vals, Init, [K | Ord]}
                                         end,
                  Accs = [{Ref, step(Acc, spec(Ref, Specs), Row, Ctx)} || {Ref, Acc} <- Accs0],
                  {G#{K => {Vals0, Accs}}, Ord2}
          end, {#{}, []}, Rows),
    Keys = case {Order, Plain} of
               {[], []} -> [none];                       %% 没有分组键、没有输入行：仍出一行
               _        -> lists:reverse(Order)
           end,
    [begin
         {Vals, Accs} = case K of
                            none -> {[], Init};
                            _    -> maps:get(K, Groups)
                        end,
         Refs = maps:from_list([{{agg_ref, Ref}, bitcask_cypher_expr:agg_final(Acc, Ctx)} || {Ref, Acc} <- Accs]),
         Base = maps:from_list(Vals),
         AggVals = [{N, eval(E, maps:merge(Base, Refs), Ctx)} || {N, E, _} <- Aggs],
         maps:merge(Base, maps:from_list(AggVals))
     end || K <- Keys].

spec(Ref, Specs) -> element(2, lists:keyfind(Ref, 1, Specs)).

step(Acc, count_star, _Row, Ctx) -> bitcask_cypher_expr:agg_step(Acc, true, Ctx);
step(Acc, {call, _, _, [Arg]}, Row, Ctx) -> bitcask_cypher_expr:agg_step(Acc, eval(Arg, Row, Ctx), Ctx);
%% percentileCont / percentileDisc(expr, p)
step(Acc, {call, _, _, [Arg, PE]}, Row, Ctx) ->
    bitcask_cypher_expr:agg_step(Acc, {pct, eval(Arg, Row, Ctx), eval(PE, Row, Ctx)}, Ctx).

%% =========================================================================
%% 图访问
%% =========================================================================

%% {Rel, 另一端 vid} 列表。Types = [] → 全部类型；类型名查不到 → 没有这种边；
%% {lexpr, 项}（T&U、!T、%、括号）→ 取全部类型、按类型名过滤。
edges(V, {lexpr, Term}, Dir, Ctx) ->
    [E || {{rel, _, T, _, _, _}, _} = E <- edges(V, [], Dir, Ctx),
          bitcask_cypher_expr:label_ok(Term, [type_name(T, Ctx)])];
edges(V, Types, Dir, Ctx) ->
    case type_ids(Types, Ctx) of
        [] -> [];
        Ids ->
            Opts = [case T of all -> #{}; _ -> #{etype => T} end || T <- Ids],
            Out = case Dir of
                      in -> [];
                      _  -> lists:append([out_edges(V, O, Ctx) || O <- Opts])
                  end,
            InE = case Dir of
                      out -> [];
                      _   -> lists:append([in_edges(V, O, Ctx) || O <- Opts])
                  end,
            case Dir of
                both -> Out ++ [E || {{rel, S, _, _, _, _}, _} = E <- InE, S =/= V];  %% 自环只算一次
                _    -> Out ++ InE
            end
    end.

out_edges(V, Opts, Ctx) ->
    Es = case Ctx of
             #{io := {txn, Tx}} -> check(graphdb:out_edges_txn(Tx, V, Opts));
             _                  -> check(graphdb:out_edges(h(Ctx), V, Opts))
         end,
    [{{rel, V, T, D, R, P}, D} || #{etype := T, dst := D, rank := R, props := P} <- Es].

in_edges(V, Opts, Ctx) ->
    Es = case Ctx of
             #{io := {txn, Tx}} -> check(graphdb:in_edges_txn(Tx, V, Opts));
             _                  -> check(graphdb:in_edges(h(Ctx), V, Opts))
         end,
    [{{rel, S, T, V, R, unknown}, S} || #{etype := T, src := S, rank := R} <- Es].

type_ids([], _Ctx) -> [all];
type_ids(Names, Ctx) ->
    lists:usort([Id || N <- Names, Id <- [type_id(N, Ctx)], Id =/= none]).

type_id(Name, Ctx) ->
    Cache = cget(?TYPE_IDS),
    case maps:find(Name, Cache) of
        {ok, Id} -> Id;
        error ->
            Id = case graphdb:etype_id(h(Ctx), Name) of
                     {ok, I} -> I;
                     _       -> none
                 end,
            put(?TYPE_IDS, Cache#{Name => Id}),
            Id
    end.

rel_id({rel, S, T, D, R, _}) -> {S, T, D, R}.

used_rels(Vars, Row) ->
    lists:foldl(fun(V, Acc) ->
                        case maps:get(V, Row, null) of
                            {rel, _, _, _, _, _} = R -> Acc#{rel_id(R) => true};
                            L when is_list(L) ->
                                lists:foldl(fun(R, A) -> A#{rel_id(R) => true} end, Acc, L);
                            _ -> Acc
                        end
                end, #{}, Vars).

%% 变长展开：深度优先，路径内一条边不重复（也不与本 MATCH 已绑定的关系重复）。
%% [{终点, [Rel]}]，按深度优先的发现序。
var_paths(V, Types, Dir, Min, Max, Used, Ctx) ->
    lists:reverse(dfs(V, 0, [], Used, Types, Dir, Min, Max, Ctx, [])).

dfs(V, Depth, Rels, Used, Types, Dir, Min, Max, Ctx, Acc0) ->
    Acc = case Depth >= Min of
              true  -> [{V, lists:reverse(Rels)} | Acc0];
              false -> Acc0
          end,
    case Depth < Max of
        false -> Acc;
        true ->
            lists:foldl(fun({Rel, O}, A) ->
                                Id = rel_id(Rel),
                                case is_map_key(Id, Used) of
                                    true  -> A;
                                    false -> dfs(O, Depth + 1, [Rel | Rels], Used#{Id => true},
                                                 Types, Dir, Min, Max, Ctx, A)
                                end
                        end, Acc, edges(V, Types, Dir, Ctx))
    end.

%% 最短路：{[Vid], [Rel]} | none。单一类型（或不限类型）的有向查询走图层的双向 BFS
%% （graphdb:shortest_path/4），其余走这里的单向 BFS。
shortest(A, A, _Types, _Dir, Min, _Max, _Ctx) ->
    case Min of
        0 -> {[A], []};
        _ -> none
    end;
shortest(A, B, Types, Dir, Min, Max, #{io := {direct, _}} = Ctx) when Dir =/= both, is_list(Types), length(Types) =< 1 ->
    Etype = case Types of
                [] -> undefined;
                [T] -> type_id(T, Ctx)
            end,
    case Etype of
        none -> none;
        _ ->
            Opts = case Etype of undefined -> #{}; _ -> #{etype => Etype} end,
            {S, D} = case Dir of out -> {A, B}; in -> {B, A} end,
            case graphdb:shortest_path(h(Ctx), S, D, Opts) of
                {ok, Path0} ->
                    Path = case Dir of out -> Path0; in -> lists:reverse(Path0) end,
                    Len = length(Path) - 1,
                    case Len >= Min andalso Len =< Max of
                        true  -> {Path, path_rels(Path, Types, Dir, Ctx)};
                        false -> none
                    end;
                {error, no_path} -> none;
                {error, R} -> throw({exec_error, io_lib:format("shortestPath failed: ~p", [R])})
            end
    end;
shortest(A, B, Types, Dir, Min, Max, Ctx) ->
    bfs([A], #{A => root}, B, 0, Types, Dir, Min, Max, Ctx).

bfs(_Frontier, _Seen, _B, Depth, _Types, _Dir, _Min, Max, _Ctx) when Depth >= Max -> none;
bfs([], _Seen, _B, _Depth, _Types, _Dir, _Min, _Max, _Ctx) -> none;
bfs(Frontier, Seen, B, Depth, Types, Dir, Min, Max, Ctx) ->
    {Next, Seen2, Found} =
        lists:foldl(fun(_U, {_, _, true} = Acc) -> Acc;
                       (U, {Nx, Sn, false}) ->
                            lists:foldl(fun(_E, {_, _, true} = A) -> A;
                                           ({Rel, O}, {N2, S2, false}) ->
                                                case is_map_key(O, S2) of
                                                    true  -> {N2, S2, false};
                                                    false -> {[O | N2], S2#{O => {U, Rel}}, O =:= B}
                                                end
                                        end, {Nx, Sn, false}, edges(U, Types, Dir, Ctx))
                    end, {[], Seen, false}, Frontier),
    case Found of
        true ->
            {Nodes, Rels} = unwind_path(B, Seen2, [], []),
            case length(Rels) >= Min of
                true  -> {Nodes, Rels};
                false -> none
            end;
        false ->
            bfs(lists:reverse(Next), Seen2, B, Depth + 1, Types, Dir, Min, Max, Ctx)
    end.

%% allShortestPaths：按层 BFS，记下每个顶点在最短距离上的全部前驱（顶点, 边），到达 B 的那一层
%% 走完就停，再从 B 回溯出全部路径。路径数有上限（?MAX_ALL_PATHS），超过报错。
all_shortest(A, A, _Types, _Dir, Min, _Max, _Ctx) ->
    case Min of 0 -> [{[A], []}]; _ -> [] end;
all_shortest(A, B, Types, Dir, Min, Max, Ctx) ->
    case all_bfs([A], #{A => 0}, #{}, B, 0, Types, Dir, Max, Ctx) of
        none -> [];
        {Depth, Preds} when Depth >= Min ->
            Paths = all_unwind(B, Preds, A),
            length(Paths) > ?MAX_ALL_PATHS andalso
                throw({exec_error, ?C('ArgumentError', 'NumberOutOfRange', io_lib:format("allShortestPaths: more than ~b paths", [?MAX_ALL_PATHS]))}),
            Paths;
        _ -> []
    end.

all_bfs(_Frontier, _Dist, _Preds, _B, Depth, _Types, _Dir, Max, _Ctx) when Depth >= Max -> none;
all_bfs([], _Dist, _Preds, _B, _Depth, _Types, _Dir, _Max, _Ctx) -> none;
all_bfs(Frontier, Dist, Preds, B, Depth, Types, Dir, Max, Ctx) ->
    D1 = Depth + 1,
    {Next, Dist2, Preds2} =
        lists:foldl(fun(U, Acc0) ->
                            lists:foldl(fun({Rel, O}, {Nx, Ds, Ps}) ->
                                                case maps:find(O, Ds) of
                                                    error ->
                                                        {[O | Nx], Ds#{O => D1}, Ps#{O => [{U, Rel}]}};
                                                    {ok, D1} ->
                                                        {Nx, Ds, Ps#{O => [{U, Rel} | maps:get(O, Ps)]}};
                                                    {ok, _} ->
                                                        {Nx, Ds, Ps}
                                                end
                                        end, Acc0, edges(U, Types, Dir, Ctx))
                    end, {[], Dist, Preds}, Frontier),
    case is_map_key(B, Dist2) of
        true  -> {D1, Preds2};
        false -> all_bfs(lists:reverse(Next), Dist2, Preds2, B, D1, Types, Dir, Max, Ctx)
    end.

all_unwind(A, _Preds, A) -> [{[A], []}];
all_unwind(V, Preds, A) ->
    [{Ns ++ [V], Rs ++ [Rel]} || {U, Rel} <- lists:reverse(maps:get(V, Preds)),
                                 {Ns, Rs} <- all_unwind(U, Preds, A)].

%% 普通命名路径：从起点出发，依次接上每一步的关系（变长是一串关系），每条关系的另一端就是
%% 下一个顶点。有一段是 null（OPTIONAL MATCH 没匹配上）→ 整条路径 null。
build_path({node, A}, Steps, Row) ->
    try
        {Nodes, Rels} =
            lists:foldl(fun({RV, _NV}, {Ns, Rs}) ->
                                Seg = case maps:get(RV, Row, null) of
                                          null -> throw(null_path);
                                          L when is_list(L) -> L;
                                          One -> [One]
                                      end,
                                lists:foldl(fun({rel, S, _, D, _, _} = Rel, {[{node, Cur} | _] = Ns2, Rs2}) ->
                                                    Next = case S of Cur -> D; _ -> S end,
                                                    {[{node, Next} | Ns2], [Rel | Rs2]}
                                            end, {Ns, Rs}, Seg)
                        end, {[{node, A}], []}, Steps),
        {path, lists:reverse(Nodes), lists:reverse(Rels)}
    catch throw:null_path -> null
    end;
build_path(_, _Steps, _Row) -> null.

%% 内置过程（CALL）：返回 [#{列名 => 值}]。
call_proc(<<"db.labels">>, Ctx) ->
    [#{<<"label">> => L} || L <- all_labels(h(Ctx))];
call_proc(<<"db.relationshiptypes">>, Ctx) ->
    Pre = << (graphdb_adj:prefix())/binary, "tn" >>,
    PL = byte_size(Pre),
    case bitcask:range(h(Ctx), {Pre, bitcask:prefix_succ(Pre)}) of
        {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
        KVs -> [#{<<"relationshipType">> => N} || {<<_:PL/binary, Len:16/big, N:Len/binary>>, _} <- KVs]
    end;
call_proc(<<"db.propertykeys">>, Ctx) ->
    %% 顶点属性名（meta 里除 _labels 之外的键）：扫一遍顶点文档
    Base = << (graphdb_adj:prefix())/binary, "n" >>,
    Fun = fun(_K, #{meta := M}, _T, _O, Acc) when is_binary(M) ->
                  try bitcask:decode_meta(M) of
                      Map -> maps:merge(Acc, maps:from_keys(maps:keys(Map), true))
                  catch _:_ -> Acc
                  end;
             (_, _, _, _, Acc) -> Acc
          end,
    case bitcask:range_fold(h(Ctx), {Base, bitcask:prefix_succ(Base)}, [{want_meta, true}], Fun, #{}) of
        {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
        Keys -> [#{<<"propertyKey">> => K} || K <- lists:sort(maps:keys(Keys)), binary:first(K) =/= $_]
    end.

%% 标签索引里出现过的全部标签：每次跳到下一个标签的前缀之后（不逐个顶点扫）。
all_labels(H) ->
    Base = << (graphdb_adj:prefix())/binary, "l" >>,
    all_labels(H, byte_size(Base), Base, bitcask:prefix_succ(Base), []).

all_labels(H, BL, Lo, Hi, Acc) ->
    Fun = fun(K, _V, _T, _O, _A) -> throw({bitcask_exec_first, K}) end,
    First = try bitcask:range_fold(H, {Lo, Hi}, [{batch, 1}], Fun, none) of
                {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
                none -> none
            catch throw:{bitcask_exec_first, K} -> K
            end,
    case First of
        <<_:BL/binary, Len:16/big, L:Len/binary, _/binary>> ->
            all_labels(H, BL, bitcask:prefix_succ(graphdb_model:label_prefix(L)), Hi, [L | Acc]);
        _ -> lists:reverse(Acc)
    end.

unwind_path(V, Seen, Ns, Rs) ->
    case maps:get(V, Seen) of
        root     -> {[V | Ns], Rs};
        {U, Rel} -> unwind_path(U, Seen, [V | Ns], [Rel | Rs])
    end.

%% 图层最短路给的是顶点序列：相邻两点之间取一条符合类型 / 方向的边。
path_rels([_], _Types, _Dir, _Ctx) -> [];
path_rels([U, V | Rest], Types, Dir, Ctx) ->
    Rel = case [Rel || {Rel, O} <- edges(U, Types, Dir, Ctx), O =:= V] of
              [R | _] -> R;
              [] -> throw({exec_error, "shortestPath: edge vanished while reading the path"})
          end,
    [Rel | path_rels([V | Rest], Types, Dir, Ctx)].

deleted(Vid) -> is_map_key(Vid, cget(?DELETED)).

%% 语句时钟：一条语句里第一次用到时取（UTC 纳秒），之后不变。
statement_now() ->
    case get(?NOW) of
        undefined -> T = os:system_time(nanosecond), put(?NOW, T), T;
        T -> T
    end.

%% 交给用户过程 / 函数的上下文。事务里给事务的句柄（经它的读写不受 2PL 保护）与 Tx 本身。
proc_ctx(#{io := {direct, H}, params := P}) -> #{handle => H, txn => undefined, params => P};
proc_ctx(#{io := {txn, Tx}, params := P}) -> #{handle => bitcask_txn:handle(Tx), txn => Tx, params => P}.

user_function(Name, Args, Ctx) ->
    bitcask_cypher_registry:call_function(Name, Args, proc_ctx(Ctx), #{}).

%% ---- 子流水线（UNION 的各段、EXISTS { … } 子查询）--------------------------------
run_sub(Ops, Row, Ctx) ->
    lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Ops).


%% EXISTS / COUNT / COLLECT { … }：以当前行的外层变量为输入跑子查询（计划在查询内缓存）。
subq_eval(Kind, Inner, Outer, Col, Row, Ctx) ->
    Key = {subq, Inner, Outer},
    Cache = cget(?SUBPLANS),
    Ops = case maps:find(Key, Cache) of
              {ok, O} -> O;
              error ->
                  O = bitcask_cypher_plan:sub_query(Inner, Outer),
                  put(?SUBPLANS, Cache#{Key => O}),
                  O
          end,
    S = run_sub(Ops, maps:with(Outer, Row), Ctx),
    case Kind of
        exists -> case S() of done -> false; _ -> true end;
        count -> length(to_list(S));
        collect -> [maps:get(Col, R, null) || R <- to_list(S)]
    end.

%% ---- 子模式（模式谓词 / 模式推导）----------------------------------------------
%% 以当前行（外层变量 Outer 已绑定）为输入跑子模式的计划，至多取 Limit 行。外层变量里有 null
%% （OPTIONAL MATCH 没匹配上）→ null。计划按 {子模式, Outer} 在一次查询内缓存。
pattern_rows(Part, Outer, Row, Ctx, Limit) ->
    case [V || V <- Outer, maps:get(V, Row, null) =:= null] of
        [_ | _] -> null;
        [] ->
            Key = {Part, Outer},
            Cache = cget(?SUBPLANS),
            Ops = case maps:find(Key, Cache) of
                      {ok, O} -> O;
                      error ->
                          O = bitcask_cypher_plan:sub_match(Part, Outer),
                          put(?SUBPLANS, Cache#{Key => O}),
                          O
                  end,
            S = lists:foldl(fun(Op, I) -> op(Op, I, Ctx) end, single(Row), Ops),
            case Limit of
                infinity -> to_list(S);
                N -> to_list(take(N, S))
            end
    end.

%% ---- 属性索引（二期）----------------------------------------------------------
%% 标签扫描的下推条件里有 (Label, 属性) 的就绪索引可用时，用索引取 vid：等值 > IN > 大小比较。
%% 区间按保序编码算：数值两种类型都扫（整数 / 浮点，边界放宽到含等号），字符串只扫字符串。
%% 拿到的是候选（超集），原有过滤照常把关。索引声明一次查询内只读一次。
index_seek(Label, Push, Row, Ctx) ->
    Decls = case get(?SCHEMA) of
                undefined ->
                    D = case Ctx of
                            %% 事务里读声明带守卫：并发的建 / 删索引让本事务提交失败重跑
                            #{io := {txn, Tx}} -> graphdb_model:txn_schema(Tx);
                            _ -> case graphdb_model:schema(h(Ctx)) of {error, _} -> []; {_, Ds} -> Ds end
                        end,
                    put(?SCHEMA, {decls, D}),
                    D;
                {decls, D} -> D
            end,
    Usable = [P || P <- Push, index_key(P) =/= none,
                   graphdb_model:ready_index(Decls, Label, index_key(P))],
    Ranked = lists:sort(fun(A, B) -> index_rank(A) =< index_rank(B) end, Usable),
    pick_index(Ranked, Label, Row, Ctx).

index_key({cmp, K, _, _}) -> K;
index_key({in, K, _}) -> K;
index_key(_) -> none.

index_rank({cmp, _, eq, _}) -> 0;
index_rank({in, _, _}) -> 1;
index_rank(_) -> 2.

pick_index([], _Label, _Row, _Ctx) -> none;
pick_index([P | Rest], Label, Row, Ctx) ->
    case index_ranges(P, Label, Row, Ctx) of
        none -> pick_index(Rest, Label, Row, Ctx);
        Ranges ->
            Base = graphdb_model:xprefix(Label, index_key(P)),
            Vids = lists:usort(lists:append([index_scan(Base, Lo, Hi, Ctx) || {Lo, Hi} <- Ranges])),
            {ok, Vids}
    end.

%% 条件 → 要扫的键区间 [{Lo, Hi}]（Hi 不含）；值不合用（null / 列表 …）→ none。
index_ranges({cmp, K, eq, E}, L, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        V -> case graphdb_model:index_scalar(V) of
                 true -> [point_range(L, K, X) || X <- num_variants(V)];
                 false -> none
             end
    end;
index_ranges({in, K, E}, L, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        Vs when is_list(Vs) ->
            case lists:all(fun graphdb_model:index_scalar/1, Vs) of
                true -> [point_range(L, K, X) || V <- Vs, X <- num_variants(V)];
                false -> none
            end;
        _ -> none
    end;
index_ranges({cmp, K, Op, E}, L, Row, Ctx) ->
    Base = graphdb_model:xprefix(L, K),
    case eval(E, Row, Ctx) of
        V when is_integer(V); is_float(V) ->
            IntB = case is_integer(V) of true -> V; false -> int_bound(Op, V) end,
            [side_range(Base, Op, IntB), side_range(Base, Op, float(V))];
        V when is_binary(V) -> [side_range(Base, Op, V)];
        _ -> none
    end.

point_range(L, K, V) ->
    P = << (graphdb_model:xprefix(L, K))/binary, (bitcask_query_index:enc(V))/binary >>,
    {P, bitcask:prefix_succ(P)}.

%% 某一类型内、按 Op 的一侧（都放宽成含等号）。类型的边界取编码的首字节。
side_range(Base, Op, V) ->
    Enc = bitcask_query_index:enc(V),
    <<Tag, _/binary>> = Enc,
    TypeLo = <<Base/binary, Tag>>,
    TypeHi = <<Base/binary, (Tag + 1)>>,
    At = <<Base/binary, Enc/binary>>,
    case Op of
        _ when Op =:= lt; Op =:= le -> {TypeLo, bitcask:prefix_succ(At)};
        _ -> {At, TypeHi}
    end.

%% 事务里：点值区间锁它自己的前缀（Lo 就是前缀），大小比较的区间锁整个属性的前缀 Base。
index_scan(Base, Lo, Hi, #{io := {txn, Tx}}) ->
    LockP = case bitcask:prefix_succ(Lo) of Hi -> Lo; _ -> Base end,
    [vid_of(K) || {K, _} <- txn_rows(bitcask_txn:prefix_range(Tx, LockP, [{within, {Lo, Hi}}]))];
index_scan(_Base, Lo, Hi, Ctx) -> index_scan(Lo, Hi, Ctx).

vid_of(K) ->
    S = byte_size(K) - 8,
    <<_:S/binary, Vid:64/big>> = K,
    Vid.

txn_rows({error, R}) -> bitcask_txn:abort(R);
txn_rows(Rows) -> Rows.

index_scan(Lo, Hi, Ctx) ->
    Fun = fun(K, _V, _T, _O, Acc) ->
                  S = byte_size(K) - 8,
                  <<_:S/binary, Vid:64/big>> = K,
                  [Vid | Acc]
          end,
    case bitcask:range_fold(h(Ctx), {Lo, Hi}, [{batch, 1024}], Fun, []) of
        {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
        Acc -> Acc
    end.

%% ---- 条件下推（第 7.3 节）----------------------------------------------------

%% Push → 引擎 meta filter（#{logic, conditions, children}）。每个条件都放宽成 Cypher 条件的
%% 必要条件：引擎里整数与浮点不互相比较、1 与 1.0 不相等，所以数值两边都查；跨类型的大小比较
%% 放宽到含等号（浮点舍入不会漏行）；字符串不比大小（引擎只比数值）；值是 null / 列表 / 映射的
%% 条件不下推（Cypher 这边永远不为真，或引擎表达不了）。Strict = 至少下推了一个属性条件。
engine_filter(Push, Row, Ctx) ->
    {Conds, Ors} = lists:foldl(fun(P, Acc) -> push_one(P, Row, Ctx, Acc) end, {[], []}, Push),
    Strict = lists:any(fun({has_label, _}) -> false; (_) -> true end, Push),  %% has_any_label 也算
    {#{logic => 'and', conditions => lists:reverse(Conds),
       children => [#{logic => 'or', conditions => Alts, children => []} || Alts <- lists:reverse(Ors)]},
     Strict}.

push_one({has_label, L}, _Row, _Ctx, {Cs, Os}) ->
    {[#{key => <<"_labels">>, op => contains, value => L} | Cs], Os};
push_one({has_any_label, Ls}, _Row, _Ctx, {Cs, Os}) ->
    {[#{key => <<"_labels">>, op => contains_any, values => Ls} | Cs], Os};
push_one({exists, K}, _Row, _Ctx, {Cs, Os}) ->
    {[#{key => K, op => exists} | Cs], Os};
push_one({cmp, K, Op, E}, Row, Ctx, {Cs, Os} = Acc) ->
    case cmp_alts(K, Op, eval(E, Row, Ctx)) of
        []    -> Acc;
        [One] -> {[One | Cs], Os};
        Alts  -> {Cs, [Alts | Os]}
    end;
push_one({in, K, E}, Row, Ctx, {Cs, Os} = Acc) ->
    case eval(E, Row, Ctx) of
        L when is_list(L), L =/= [] ->
            case lists:all(fun scalar/1, L) of
                %% lists:uniq 按 =:= 去重（usort 按 ==，会把 1 与 1.0 当成一个）
                true  -> {[#{key => K, op => in, values => lists:uniq(lists:append([num_variants(X) || X <- L]))} | Cs], Os};
                false -> Acc
            end;
        _ -> Acc
    end.

cmp_alts(K, eq, V) ->
    case scalar(V) of
        true  -> [#{key => K, op => eq, value => X} || X <- num_variants(V)];
        false -> []
    end;
cmp_alts(K, Op, V) when is_integer(V) ->
    [#{key => K, op => strict_op(Op), value => V},
     #{key => K, op => loose_op(Op), value => float(V)}];
cmp_alts(K, Op, V) when is_float(V) ->
    [#{key => K, op => strict_op(Op), value => V},
     #{key => K, op => loose_op(Op), value => int_bound(Op, V)}];
cmp_alts(_K, _Op, _V) -> [].                         %% 字符串 / 布尔 / null：不下推大小比较

strict_op(lt) -> lt;
strict_op(le) -> lte;
strict_op(gt) -> gt;
strict_op(ge) -> gte.

loose_op(lt) -> lte;
loose_op(le) -> lte;
loose_op(gt) -> gte;
loose_op(ge) -> gte.

%% 浮点上界 / 下界换成整数界：n < 2.5 的整数 n 满足 n =< ceil(2.5)（放宽，不漏）。
int_bound(Op, F) when Op =:= lt; Op =:= le -> clamp_int(ceil(F));
int_bound(_, F) -> clamp_int(floor(F)).

clamp_int(I) -> max(-16#8000000000000000, min(16#7FFFFFFFFFFFFFFF, I)).

%% 等值的数值两种写法：整数 c 也查浮点 c（c 能精确表示时）；整数值的浮点也查对应整数。
num_variants(I) when is_integer(I) ->
    F = float(I),
    case trunc(F) =:= I of
        true  -> [I, F];
        false -> [I]
    end;
num_variants(F) when is_float(F) ->
    case F == trunc(F) andalso abs(F) < 9.2e18 of
        true  -> [F, trunc(F)];
        false -> [F]
    end;
num_variants(X) -> [X].

scalar(V) when is_integer(V) -> V >= -16#8000000000000000 andalso V =< 16#7FFFFFFFFFFFFFFF;
scalar(V) -> is_float(V) orelse is_binary(V) orelse is_boolean(V).

%% 标签索引的一块 vid：够密就一次 range 取文档（带 filter），否则原样交出（逐个按需读）。
%% Strict 时 range 没交出来的 vid 一定不满足下推条件，直接丢掉。
fetch_chunk([], _Filter, _Strict, _Ctx) -> [];
fetch_chunk(Vs, Filter, Strict, Ctx) ->
    Min = hd(Vs),
    Max = lists:last(Vs),
    case Max - Min + 1 =< 4 * length(Vs) of
        false -> Vs;
        true ->
            Got = range_docs(Min, Max, Filter, Ctx),
            case Strict of
                true  -> [V || V <- Vs, is_map_key(V, Got)];
                false -> Vs
            end
    end.

%% n 文档的 [Min, Max] 一段：带 filter 的 range，文档转成顶点信息填进缓存；返回 vid 集合。
range_docs(Min, Max, Filter, Ctx) ->
    Base = << (graphdb_adj:prefix())/binary, "n" >>,
    BL = byte_size(Base),
    Hi = case Max of
             16#FFFFFFFFFFFFFFFF -> bitcask:prefix_succ(Base);
             _ -> << Base/binary, (Max + 1):64/big >>
         end,
    Fun = fun(<< _:BL/binary, Vid:64/big >>, Doc, _T, _O, Acc) -> [{Vid, Doc} | Acc];
             (_, _, _, _, Acc) -> Acc
          end,
    case bitcask:range_fold(h(Ctx), {<< Base/binary, Min:64/big >>, Hi},
                            [{want_meta, true}, {filter, Filter}, {batch, ?SCAN_CHUNK}], Fun, []) of
        {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
        Docs -> cache_docs(Docs)
    end.

%% 全量扫描 + 下推：n 文档从 After 之后起、满足 filter 的至多一批（文档进缓存）。
scan_docs(After, Filter, Ctx) ->
    Base = << (graphdb_adj:prefix())/binary, "n" >>,
    BL = byte_size(Base),
    Lo = case After of
             undefined -> Base;
             16#FFFFFFFFFFFFFFFF -> none;
             A -> << Base/binary, (A + 1):64/big >>
         end,
    case Lo of
        none -> [];
        _ ->
            Fun = fun(<< _:BL/binary, Vid:64/big >>, Doc, _T, _O, {C, Acc}) ->
                          Acc2 = [{Vid, Doc} | Acc],
                          case C + 1 >= ?SCAN_CHUNK of
                              true  -> throw({bitcask_exec_chunk, Acc2});
                              false -> {C + 1, Acc2}
                          end;
                     (_, _, _, _, A) -> A
                  end,
            FOpt = case Filter of
                       #{conditions := [], children := []} -> [];
                       _ -> [{filter, Filter}]
                   end,
            Docs = try bitcask:range_fold(h(Ctx), {Lo, bitcask:prefix_succ(Base)},
                                          [{want_meta, true}, {batch, ?SCAN_CHUNK} | FOpt],
                                          Fun, {0, []}) of
                       {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
                       {_, Acc}   -> Acc
                   catch throw:{bitcask_exec_chunk, Acc} -> Acc
                   end,
            Got = cache_docs(Docs),
            lists:sort(maps:keys(Got))
    end.

%% range 读回的文档 → 顶点信息进查询内缓存（与 load_vertex 同形）。向量不随 range 读回：
%% 标成 unknown，真用到（n.embedding）时 node_vector/2 再单独读一次。
cache_docs(Docs) ->
    Infos = maps:from_list([{Vid, (graphdb_model:doc_info(D))#{vector => unknown}} || {Vid, D} <- Docs]),
    Cache = cget(?NODES),
    put(?NODES, case map_size(Cache) + map_size(Infos) > ?CACHE_MAX of
                    true  -> Infos;
                    %% 逐项 put（O(块大小 · log n)），不 maps:merge 整张表
                    false -> maps:fold(fun(K, V, C) -> C#{K => V} end, Cache, Infos)
                end),
    Infos.

%% 一个家族里的顶点 id（n 文档 / 邻接表头；块 key 跳过），从 After 之后起至多一批。
family_vids(H, F, After) ->
    Base = << (graphdb_adj:prefix())/binary, F/binary >>,
    Lo = case After of
             undefined -> Base;
             16#FFFFFFFFFFFFFFFF -> none;
             A -> << Base/binary, (A + 1):64/big >>
         end,
    case Lo of
        none -> [];
        _ ->
            BL = byte_size(Base),
            Fun = fun(<< _:BL/binary, Vid:64/big >>, _V, _T, _O, {C, Acc}) ->
                          case C + 1 >= ?SCAN_CHUNK of
                              true  -> throw({bitcask_exec_chunk, [Vid | Acc]});
                              false -> {C + 1, [Vid | Acc]}
                          end;
                     (_, _, _, _, A) -> A
                  end,
            try bitcask:range_fold(H, {Lo, bitcask:prefix_succ(Base)}, [{batch, ?SCAN_CHUNK}],
                                   Fun, {0, []}) of
                {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])});
                {_, Acc}   -> lists:reverse(Acc)
            catch throw:{bitcask_exec_chunk, Acc} -> lists:reverse(Acc)
            end
    end.

%% =========================================================================
%% 顶点 / 边的按需读取（查询内缓存）
%% =========================================================================

node_info(Vid, Ctx) ->
    Cache = cget(?NODES),
    case maps:find(Vid, Cache) of
        {ok, I} -> I;
        error ->
            I = case load_vertex(Vid, Ctx) of
                    {ok, Info} -> Info;
                    {error, not_found} -> #{labels => [], properties => #{}, vector => null};
                    {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])})
                end,
            put(?NODES, cache_put(Cache, Vid, I)),
            I
    end.

%% 顶点向量（f32 二进制或 null）。range 批量取回的顶点没带向量（unknown），这里补读。
node_vector(Vid, Ctx) ->
    case maps:get(vector, node_info(Vid, Ctx)) of
        unknown ->
            I = case load_vertex(Vid, Ctx) of
                    {ok, Info} -> Info;
                    {error, not_found} -> #{labels => [], properties => #{}, vector => null};
                    {error, R} -> throw({exec_error, io_lib:format("storage error: ~p", [R])})
                end,
            put(?NODES, cache_put(cget(?NODES), Vid, I)),
            maps:get(vector, I);
        Vec -> Vec
    end.

rel_props({rel, _, _, _, _, P}, _Ctx) when is_binary(P) ->
    graphdb_model:decode_edge_props(P);
rel_props({rel, S, T, D, R, unknown}, Ctx) ->
    Cache = cget(?RELS),
    Key = {S, T, D, R},
    case maps:find(Key, Cache) of
        {ok, P} -> P;
        error ->
            P = case edge_props_raw(S, T, D, R, Ctx) of
                    {ok, #{props := B}} -> graphdb_model:decode_edge_props(B);
                    {error, not_found}  -> #{};
                    {error, E} -> throw({exec_error, io_lib:format("storage error: ~p", [E])})
                end,
            put(?RELS, cache_put(Cache, Key, P)),
            P
    end.

%% 关系类型名；没注册名字的类型（图层 API 直接用数字）返回那个整数。
type_name(T, Ctx) ->
    Cache = cget(?TYPES),
    case maps:find(T, Cache) of
        {ok, N} -> N;
        error ->
            N = case graphdb:etype_name(h(Ctx), T) of
                    {ok, Name} -> Name;
                    _          -> T
                end,
            put(?TYPES, Cache#{T => N}),
            N
    end.

load_vertex(Vid, #{io := {txn, Tx}}) ->
    graphdb_model:txn_vertex_info(Tx, Vid);
load_vertex(Vid, Ctx) ->
    case bitcask:get_doc(h(Ctx), nkey(Vid)) of
        {ok, D} -> {ok, graphdb_model:doc_info(D)};
        not_found ->
            case graphdb_model:vertex_exists(h(Ctx), Vid) of
                true  -> {ok, #{labels => [], properties => #{}, vector => null}};
                false -> {error, not_found}
            end;
        {error, _} = E -> E
    end.

edge_props_raw(S, T, D, R, #{io := {txn, Tx}}) -> graphdb:edge_txn(Tx, S, T, D, R);
edge_props_raw(S, T, D, R, Ctx) -> graphdb:edge(h(Ctx), S, T, D, R).

nkey(Vid) -> << (graphdb_adj:prefix())/binary, "n", Vid:64/big >>.

forget_vertex(Vid) -> put(?NODES, maps:remove(Vid, cget(?NODES))).
forget_rel(S, T, D, R) -> put(?RELS, maps:remove({S, T, D, R}, cget(?RELS))).

cache_put(Cache, K, V) when map_size(Cache) >= ?CACHE_MAX -> #{K => V};
cache_put(Cache, K, V) -> Cache#{K => V}.

%% 对外的值形态（第 10 节）。
out({node, Vid}, Ctx) ->
    #{labels := L, properties := P} = node_info(Vid, Ctx),
    #{id => Vid, labels => L, properties => P};
out({rel, S, T, D, R, _} = Rel, Ctx) ->
    #{src => S, type => type_name(T, Ctx), dst => D, rank => R, properties => rel_props(Rel, Ctx)};
out({path, Ns, Rs}, Ctx) ->
    #{nodes => [out(N, Ctx) || N <- Ns], relationships => [out(R, Ctx) || R <- Rs]};
out(L, Ctx) when is_list(L) -> [out(X, Ctx) || X <- L];
out(M, Ctx) when is_map(M) -> maps:map(fun(_K, V) -> out(V, Ctx) end, M);
out(V, _Ctx) -> V.

%% =========================================================================
%% 写（第 8 节；只在事务里）
%% =========================================================================

%% 记一个被写到的顶点。一条语句写多少顶点默认不限（整条语句仍是一个事务、一条提交批）；应用环境
%% bitcask_cypher.cypher_max_write_vertices = N 可以设上限，超过就报错（提示分成多条语句）。
note_written(Vid) ->
    W = cget(?WRITTEN),
    case is_map_key(Vid, W) of
        true -> ok;
        false ->
            case max_write_vertices() of
                Max when is_integer(Max), map_size(W) >= Max ->
                    throw({exec_error, ?C('SemanticError', 'none', io_lib:format("one statement may write at most ~b vertices "
                                                     "(cypher_max_write_vertices); split the work into "
                                                     "several statements", [Max]))});
                _ ->
                    put(?WRITTEN, W#{Vid => true}),
                    N = map_size(W) + 1,
                    (N >= ?GROW_HEAP_FROM andalso N band (N - 1) =:= 0) andalso grow_heap()
            end
    end,
    forget_vertex(Vid).

%% 大写语句：事务缓冲、锁表、守卫、写过的顶点都在本进程堆上，活数据随写入量线性增长；按 OTP 缺省的
%% 堆增长（大堆每次约 +20%）会反复做全量 GC，总耗时变成超线性（5 万条关系 + 10 万个顶点一条语句 15 s，分成 10 条 6.4 s）。
%% 写到的顶点数每翻一番就把 min_heap_size 提到当前堆的两倍——全量 GC 次数变成对数级（同一负载 5.5 s）。
%% 语句结束（with_run 顶层）恢复原值，之后的 GC 把堆缩回去。
grow_heap() ->
    {total_heap_size, H} = process_info(self(), total_heap_size),
    Old = process_flag(min_heap_size, 2 * H),
    get(?HEAP0) =:= undefined andalso put(?HEAP0, Old),
    ok.

restore_heap() ->
    case erase(?HEAP0) of
        undefined -> ok;
        Old -> process_flag(min_heap_size, Old), ok
    end.

max_write_vertices() ->
    case application:get_env(bitcask_cypher, cypher_max_write_vertices) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> infinity
    end.

%% 校验失败（graphdb_model 的 badarg）→ 执行错误。
model_call(F) ->
    try F()
    catch error:{badarg, {reserved_property, K}} ->
              throw({exec_error, ?C('SemanticError', 'none', ["property names starting with `_` are reserved: ", K])});
          error:{badarg, {unsupported_property_type, K}} ->
              throw({exec_error, ?C('TypeError', 'InvalidPropertyType', ["unsupported property type for `", K,
                                  "` (allowed: null, boolean, integer, float, string, temporal values, points, and lists whose elements all have one of these types)"])});
          error:{badarg, {label, L}} ->
              throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', io_lib:format("invalid label ~p", [L]))});
          error:{badarg, What} ->
              throw({exec_error, ?C('TypeError', 'InvalidPropertyType', io_lib:format("invalid value: ~p", [What]))})
    end.

%% ON CREATE / ON MATCH 的 SET 项。
apply_sets(Items, Row, Tx, Ctx) ->
    lists:foldl(fun(It, R) -> set_item(It, R, Tx, Ctx) end, Row, Items).

%% MERGE 按值匹配：属性里不能有 null（null 永远匹配不上，每次都会新建一个）。
merge_props(undefined, _Row, _Ctx) -> ok;
merge_props(E, Row, Ctx) ->
    case [K || {K, null} <- maps:to_list(props_arg(E, Row, Ctx))] of
        [] -> ok;
        [K | _] -> throw({exec_error, ?C('SemanticError', 'MergeReadOwnWrites', ["cannot MERGE with a null value for property `", K, "`"])})
    end.

props_arg(undefined, _Row, _Ctx) -> #{};
props_arg(E, Row, Ctx) ->
    case eval(E, Row, Ctx) of
        M when is_map(M) -> M;
        null -> #{};
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "properties must be a map")})
    end.

%% 属性 map 里的 text / embedding 是顶点文档的正文 / 向量，其余是属性。
split_special(M) ->
    {maps:get(<<"text">>, M, null), maps:get(<<"embedding">>, M, null),
     maps:without([<<"text">>, <<"embedding">>], M)}.

create_chain({chain, N0, Steps}, Row0, Tx, Ctx) ->
    Row1 = create_node(N0, Row0, Tx, Ctx),
    {Row, _} = lists:foldl(fun({Rel, N}, {R, {node, Prev}}) ->
                                   R2 = create_node(N, R, Tx, Ctx),
                                   {node, Next} = bound_node(N, R2),
                                   R3 = create_rel(Rel, Prev, Next, R2, Tx, Ctx),
                                   {R3, {node, Next}}
                           end, {Row1, bound_node(N0, Row1)}, Steps),
    Row.

bound_node({node, V, _, _, _}, Row) ->
    case maps:get(V, Row, null) of
        {node, _} = N -> N;
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["CREATE needs `", V, "` to be a node"])})
    end.

create_node({node, V, Labels, PropsE, _}, Row, Tx, Ctx) ->
    case maps:get(V, Row, undefined) of
        {node, _} -> Row;                                   %% 已绑定：只是连到它
        null -> throw({exec_error, ?C('SemanticError', 'none', ["cannot create a relationship to a null node `", V, "`"])});
        _ ->
            {Text, Emb, Props} = split_special(props_arg(PropsE, Row, Ctx)),
            Spec0 = #{labels => Labels, props => Props},
            Spec1 = case Text of null -> Spec0; T when is_binary(T) -> Spec0#{text => T};
                        _ -> throw({exec_error, ?C('TypeError', 'InvalidPropertyType', "property `text` must be a string")}) end,
            Spec = case Emb of null -> Spec1; E -> Spec1#{vector => to_f32(E)} end,
            Doc = model_call(fun() -> graphdb_model:to_doc(Spec) end),
            {ok, Vid} = graphdb_model:txn_allocate(
                          Tx, fun(Vid) -> [{put, nkey(Vid), Doc}
                                           | graphdb_model:index_ops(graphdb_model:txn_schema(Tx), Vid, {[], #{}},
                                                                     graphdb_model:doc_lp(Doc))] end),
            note_written(Vid),
            stat(nodes_created, 1),
            stat(labels_added, length(Labels)),
            stat(properties_set, map_size(Props) + length([x || X <- [Text, Emb], X =/= null])),
            Row#{V => {node, Vid}}
    end.

create_rel({rel, RV, [Type], PropsE, Dir, _, _}, Prev, Next, Row, Tx, Ctx) ->
    {S, D} = case Dir of out -> {Prev, Next}; in -> {Next, Prev}; both -> {Prev, Next} end,   %% 无向的 MERGE：从左到右建
    T = case type_id(Type, Ctx) of
            none -> throw({exec_error, ["relationship type `", Type, "` is not registered"]});
            Id -> Id
        end,
    Props = props_arg(PropsE, Row, Ctx),
    PBin = model_call(fun() -> graphdb_model:encode_edge_props(Props) end),
    Rank = next_rank(Tx, S, T, D, graphdb:rank_floor_txn(Tx, S, T, D)),   %% 不复用删掉的关系 id
    ok = txn_ok(graphdb:put_edge_txn(Tx, S, T, D, #{rank => Rank, props => PBin})),
    note_written(S), note_written(D),
    stat(relationships_created, 1),
    stat(properties_set, map_size(Props)),
    Row#{RV => {rel, S, T, D, Rank, PBin}}.

%% 两点之间同类型的第二条边取下一个 rank（第 4 节「平行边」）；从 rank 下限（删过的最大 rank + 1）找起。
next_rank(Tx, S, T, D, R) ->
    case graphdb:edge_txn(Tx, S, T, D, R) of
        {ok, _}            -> next_rank(Tx, S, T, D, R + 1);
        {error, not_found} -> R
    end.

txn_ok(ok) -> ok;
txn_ok({error, R}) -> bitcask_txn:abort(R).

set_item({set_prop_x, TE, KS, E}, Row, Tx, Ctx) -> set_item_x(TE, KS, E, Row, Tx, Ctx);
set_item({set_prop, V, Key, E}, Row, Tx, Ctx) ->
    set_prop(V, Key, eval(E, Row, Ctx), Row, Tx, Ctx);
set_item({set_props, V, E, Mode}, Row, Tx, Ctx) ->
    New = case eval(E, Row, Ctx) of
              M when is_map(M) -> M;
              {node, SrcVid} -> node_props_with_specials(SrcVid, Ctx);
              {rel, _, _, _, _, _} = SrcRel -> rel_props(SrcRel, Ctx);
              null -> #{};
              _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "SET n = / += needs a map")})
          end,
    case maps:get(V, Row, null) of
        null -> Row;
        {node, Vid} ->
            update_vertex(Vid, fun(M0) -> assign_props(M0, New, Mode) end, Tx),
            stat(properties_set, map_size(New)),
            Row;
        {rel, _, _, _, _, _} = Rel ->
            Cur = case Mode of replace -> #{}; merge -> rel_props(Rel, Ctx) end,
            stat(properties_set, map_size(New)),
            write_rel_props(V, Rel, maps:merge(Cur, New), Row, Tx, Ctx);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["cannot set properties of `", V, "`"])})
    end;
set_item({set_labels, V, Labels}, Row, Tx, _Ctx) ->
    case maps:get(V, Row, null) of
        null -> Row;
        {node, Vid} ->
            {Old, New} = update_vertex(Vid, fun(M) ->
                                                   L0 = maps:get(labels, M),
                                                   M#{labels := L0 ++ [L || L <- Labels, not lists:member(L, L0)]}
                                           end, Tx),
            stat(labels_added, length(maps:get(labels, New)) - length(maps:get(labels, Old))),
            Row;
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["cannot set labels on `", V, "`"])})
    end.

%% SET / REMOVE 的一般目标：求出图元素与键
set_item_x(TE, KS, E, Row, Tx, Ctx) ->
    Key = case KS of
              {dyn, KE} ->
                  case eval(KE, Row, Ctx) of
                      K when is_binary(K) ->
                          case K of
                              <<"_", _/binary>> ->
                                  throw({exec_error, ?C('SemanticError', none, ["property names starting with `_` are reserved: ", K])});
                              _ -> K
                          end;
                      null -> null;
                      _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "a property key must be a string")})
                  end;
              K -> K
          end,
    case Key of
        null -> Row;
        _ ->
            Slot = case TE of {var, V} -> V; _ -> <<"  set_target">> end,
            Target = eval(TE, Row, Ctx),
            Row2 = set_prop(Slot, Key, eval(E, Row, Ctx), Row#{Slot => Target}, Tx, Ctx),
            case TE of {var, _} -> Row2; _ -> maps:remove(Slot, Row2) end
    end.

remove_item({set_prop_x, TE, KS, E}, Row, Tx, Ctx) -> set_item_x(TE, KS, E, Row, Tx, Ctx);
remove_item({remove_prop, V, Key}, Row, Tx, Ctx) ->
    set_prop(V, Key, null, Row, Tx, Ctx);
remove_item({remove_labels, V, Labels}, Row, Tx, _Ctx) ->
    case maps:get(V, Row, null) of
        null -> Row;
        {node, Vid} ->
            {Old, New} = update_vertex(Vid, fun(M) ->
                                                   M#{labels := [L || L <- maps:get(labels, M),
                                                                      not lists:member(L, Labels)]}
                                           end, Tx),
            stat(labels_removed, length(maps:get(labels, Old)) - length(maps:get(labels, New))),
            Row;
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["cannot remove labels from `", V, "`"])})
    end.

set_prop(V, Key, Val, Row, Tx, Ctx) ->
    case maps:get(V, Row, null) of
        null -> Row;                                        %% 对 null 的 SET 什么都不做
        {node, Vid} ->
            update_vertex(Vid, fun(M) -> assign_props(M, #{Key => Val}, merge) end, Tx),
            stat(properties_set, 1),
            Row;
        {rel, _, _, _, _, _} = Rel ->
            stat(properties_set, 1),
            write_rel_props(V, Rel, maps:put(Key, Val, rel_props(Rel, Ctx)), Row, Tx, Ctx);
        _ -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', ["cannot set a property of `", V, "`"])})
    end.

node_props_with_specials(Vid, Ctx) ->
    #{properties := P} = node_info(Vid, Ctx),
    case node_vector(Vid, Ctx) of null -> P; Vec -> P#{<<"embedding">> => Vec} end.

%% 模型上的属性赋值：null = 删除；text / embedding 落到正文 / 向量。
%% replace：属性与正文整体换成 New（向量与标签不动，除非 New 里给了 embedding）。
assign_props(M0, New, Mode) ->
    M = case Mode of
            replace -> M0#{props := #{}, text := <<>>};
            merge   -> M0
        end,
    maps:fold(fun(<<"text">>, null, Acc) -> Acc#{text := <<>>};
                 (<<"text">>, T, Acc) when is_binary(T) -> Acc#{text := T};
                 (<<"text">>, _, _) -> throw({exec_error, ?C('TypeError', 'InvalidPropertyType', "property `text` must be a string")});
                 (<<"embedding">>, null, Acc) -> Acc#{vector := undefined};
                 (<<"embedding">>, E, Acc) -> Acc#{vector := to_f32(E)};
                 (K, null, Acc) -> Acc#{props := maps:remove(K, maps:get(props, Acc))};
                 (K, V, Acc) ->
                      [{K2, V2}] = maps:to_list(model_call(fun() -> graphdb_model:norm_props(#{K => V}) end)),
                      Acc#{props := maps:put(K2, V2, maps:get(props, Acc))}
              end, M, New).

update_vertex(Vid, F, Tx) ->
    note_written(Vid),
    case graphdb_model:txn_update_vertex(Tx, Vid, F) of
        {ok, Old, New} -> {Old, New};
        {error, not_found} -> throw({exec_error, ?C('EntityNotFound', 'none', io_lib:format("node ~b no longer exists", [Vid]))})
    end.

write_rel_props(V, {rel, S, T, D, R, _}, Props0, Row, Tx, _Ctx) ->
    is_map_key(<<"_raw">>, Props0) andalso
        throw({exec_error, ?C('SemanticError', 'none', "this relationship has legacy binary properties; they cannot be edited from Cypher")}),
    Props = maps:filter(fun(_K, X) -> X =/= null end, Props0),
    PBin = model_call(fun() -> graphdb_model:encode_edge_props(Props) end),
    ok = txn_ok(graphdb:put_edge_txn(Tx, S, T, D, #{rank => R, props => PBin})),
    forget_rel(S, T, D, R),
    Row#{V => {rel, S, T, D, R, PBin}}.

delete_targets([], Acc) -> Acc;
delete_targets([null | Rest], Acc) -> delete_targets(Rest, Acc);
delete_targets([{node, V} | Rest], {Ns, Rs}) -> delete_targets(Rest, {[V | Ns], Rs});
delete_targets([{rel, S, T, D, R, _} | Rest], {Ns, Rs}) -> delete_targets(Rest, {Ns, [{S, T, D, R} | Rs]});
delete_targets([{path, Nodes, Rels} | Rest], Acc) -> delete_targets(Nodes ++ Rels ++ Rest, Acc);
delete_targets([L | Rest], Acc) when is_list(L) -> delete_targets(L ++ Rest, Acc);
delete_targets([_ | _], _Acc) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "DELETE needs nodes, relationships or paths")}).

%% 先删关系、再删顶点（同一条语句里先 DELETE r 再 DELETE n 也行）。不带 DETACH 时
%% 顶点还有边就报错；DETACH 走图层的级联删顶点（事务版）。
delete_all(Rels, Nodes, Detach, Tx, Ctx) ->
    lists:foreach(fun({S, T, D, R}) ->
                          case graphdb:edge_txn(Tx, S, T, D, R) of
                              {ok, _} ->
                                  ok = txn_ok(graphdb:del_edge_txn(Tx, S, T, D, R)),
                                  ok = graphdb:retire_rank_txn(Tx, S, T, D, R),
                                  put(?DELETED, (cget(?DELETED))#{{S, T, D, R} => true}),
                                  note_written(S), note_written(D),
                                  forget_rel(S, T, D, R),
                                  stat(relationships_deleted, 1);
                              {error, not_found} -> ok
                          end
                  end, Rels),
    lists:foreach(fun(Vid) ->
                          case graphdb_model:txn_vertex_exists(Tx, Vid) of
                              false -> ok;
                              true ->
                                  Incident = lists:usort([rel_id(Rel) || {Rel, _} <- edges(Vid, [], both, Ctx)]
                                                         ++ [rel_id(Rel) || {Rel, _} <- edges(Vid, [], in, Ctx)]),
                                  case {Incident, Detach} of
                                      {[_ | _], false} ->
                                          throw({exec_error, ?C('ConstraintVerificationFailed', 'DeleteConnectedNode', io_lib:format(
                                                               "cannot delete node ~b: it still has relationships; "
                                                               "use DETACH DELETE", [Vid]))});
                                      _ -> ok
                                  end,
                                  [note_written(X) || {S, _, D, _} <- Incident, X <- [S, D]],
                                  note_written(Vid),
                                  put(?DELETED, (cget(?DELETED))#{Vid => true}),
                                  graphdb:del_vertex_txn(Tx, Vid),
                                  stat(relationships_deleted, length(Incident)),
                                  stat(nodes_deleted, 1)
                          end
                  end, Nodes).

%% =========================================================================
%% 全文（第 9.2 节）
%% =========================================================================

score_key(V) -> <<"  score ", V/binary>>.

%% score(v)：经全文取点（fts_seek）的行带着分数；经 @@ 过滤的取最近一次判断时记下的分数。
fts_score(V, Row) ->
    case maps:find(score_key(V), Row) of
        {ok, S} -> S;
        error ->
            case maps:get(V, Row, null) of
                {node, Vid} -> maps:get({V, Vid}, cget(?FTS_SCORE), null);
                _ -> null
            end
    end.

fts_match(V, Vid, Prop, QS, Ctx) ->
    Hits = fts_set(Prop, QS, Ctx),
    case maps:find(Vid, Hits) of
        {ok, Sc} ->
            put(?FTS_SCORE, (cget(?FTS_SCORE))#{{V, Vid} => Sc}),
            true;
        error -> false
    end.

%% ---- 检索的函数形式（二期）-----------------------------------------------------
%% fts.phrase(n.text, q)、fts.near(n.text, q, slop)、fts.wildcard(n.text, pat)、fts.fuzzy(n.text, w[, edits])、
%% fts.fields(n, q)：取引擎的全部命中；search.hybrid(n, text, vec[, k])：引擎的混合检索（RRF）取前 k（缺省 10）。
%% 作为表达式按顶点判断是否命中（并记下分数给 score(n)）；作为 WHERE 合取项由规划器钉成起点（search_seek）。

search_match(V, Vid, Name, Vals0, Ctx) ->
    case search_args(Name, Vals0) of
        null -> null;
        Vals ->
            case maps:find(Vid, search_set(Name, Vals, Ctx)) of
                {ok, Sc} -> put(?FTS_SCORE, (cget(?FTS_SCORE))#{{V, Vid} => Sc}), true;
                error -> false
            end
    end.

%% 参数校验（不含第一个：顶点 / 正文）；任一为 null → null。
search_args(_Name, Vals) ->
    case lists:member(null, Vals) of
        true -> null;
        false -> Vals
    end.

search_set(Name, Vals, Ctx) ->
    Key = {Name, Vals},
    Cache = cget(?FTS),
    case maps:find(Key, Cache) of
        {ok, M} -> M;
        error ->
            M = search_eval(Name, Vals, h(Ctx)),
            put(?FTS, Cache#{Key => M}),
            M
    end.

search_eval(<<"fts.phrase">>, [Q], H) when is_binary(Q) -> fetch_all(fun(K) -> bitcask:search_phrase(H, Q, K) end);
search_eval(<<"fts.near">>, [Q, Slop], H) when is_binary(Q), is_integer(Slop), Slop >= 0 ->
    fetch_all(fun(K) -> bitcask:search_near(H, Q, Slop, K) end);
search_eval(<<"fts.wildcard">>, [P], H) when is_binary(P) -> fetch_all(fun(K) -> bitcask:search_wildcard(H, P, K) end);
search_eval(<<"fts.fuzzy">>, [W], H) -> search_eval(<<"fts.fuzzy">>, [W, 1], H);
search_eval(<<"fts.fuzzy">>, [W, Ed], H) when is_binary(W), is_integer(Ed), Ed >= 0, Ed =< 2 ->
    fetch_all(fun(K) -> bitcask:search_fuzzy(H, W, Ed, K) end);
search_eval(<<"fts.fields">>, [Q], H) when is_binary(Q) -> fetch_all(fun(K) -> bitcask:search_fields(H, Q, K) end);
search_eval(<<"search.hybrid">>, [T, V], H) -> search_eval(<<"search.hybrid">>, [T, V, 10], H);
search_eval(<<"search.hybrid">>, [T, V, K], H) when is_binary(T), is_integer(K), K > 0 ->
    case bitcask:search_hybrid(H, T, to_f32(V), min(K, ?SEARCH_CAP)) of
        {ok, Hits} -> vertex_hits(Hits);
        {error, no_index} -> throw({exec_error, ?C('SemanticError', 'none', "hybrid search needs the graph opened in index mode with vectors")});
        no_index -> throw({exec_error, ?C('SemanticError', 'none', "hybrid search needs the graph opened in index mode with vectors")});
        {error, R} -> throw({exec_error, io_lib:format("hybrid search failed: ~p", [R])})
    end;
search_eval(Name, _Vals, _H) ->
    throw({exec_error, ?C('ArgumentError', 'InvalidArgumentType', ["invalid arguments to ", Name, "()"])}).

%% 查询串 → 命中的顶点 #{Vid => 分数}（一次查询内按查询串缓存）。
fts_set(<<"text">>, QS, Ctx) ->
    Cache = cget(?FTS),
    case maps:find(QS, Cache) of
        {ok, M} -> M;
        error ->
            M = fts_eval(fts_parse(QS), h(Ctx)),
            put(?FTS, Cache#{QS => M}),
            M
    end;
fts_set(Prop, _QS, _Ctx) ->
    throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', ["full-text matching works on the node text (n.text @@ '...'); `", Prop,
                        "` is not a full-text property"])}).

%% 查询串的最小写法（同 LatticeDB）：并列的词都要出现；大写 OR 连接的二选一；-词 排除；
%% "短语"；前缀*；词~ 模糊（编辑距离 1）。→ {[[Item]], [Item]}（AND 组，每组是 OR 的备选；排除项）。
fts_parse(QS) ->
    Toks = fts_tokens(unicode:characters_to_list(QS), []),
    {Groups, Neg} = fts_group(Toks, [], []),
    Groups =:= [] andalso throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', "full-text query has no positive terms")}),
    {Groups, Neg}.

fts_tokens([], Acc) -> lists:reverse(Acc);
fts_tokens([C | Rest], Acc) when C =:= $\s; C =:= $\t; C =:= $\n -> fts_tokens(Rest, Acc);
fts_tokens([$-, $" | Rest], Acc) ->
    {P, Rest2} = lists:splitwith(fun(X) -> X =/= $" end, Rest),
    fts_tokens(drop_quote(Rest2), [{neg, {phrase, bin(P)}} | Acc]);
fts_tokens([$" | Rest], Acc) ->
    {P, Rest2} = lists:splitwith(fun(X) -> X =/= $" end, Rest),
    fts_tokens(drop_quote(Rest2), [{phrase, bin(P)} | Acc]);
fts_tokens(Chars, Acc) ->
    {W, Rest} = lists:splitwith(fun(X) -> X =/= $\s andalso X =/= $\t andalso X =/= $\n end, Chars),
    Tok = case W of
              "OR" -> 'or';
              [$- | W2] when W2 =/= [] -> {neg, word(W2)};
              _ -> word(W)
          end,
    fts_tokens(Rest, [Tok | Acc]).

drop_quote([$" | R]) -> R;
drop_quote(R) -> R.

word(W) ->
    case lists:reverse(W) of
        [$* | R] when R =/= [] -> {prefix, bin(lists:reverse(R))};
        [$~ | R] when R =/= [] -> {fuzzy, bin(lists:reverse(R))};
        _ -> {term, bin(W)}
    end.

bin(L) -> unicode:characters_to_binary(L).

fts_group([], Groups, Neg) -> {lists:reverse(Groups), Neg};
fts_group([{neg, I} | Rest], Groups, Neg) -> fts_group(Rest, Groups, [I | Neg]);
fts_group(['or' | Rest], [G | Groups], Neg) ->
    case Rest of
        [I | Rest2] when I =/= 'or', element(1, I) =/= neg -> fts_group(Rest2, [G ++ [I] | Groups], Neg);
        _ -> throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', "full-text query: OR needs a term on both sides")})
    end;
fts_group(['or' | _], [], _Neg) -> throw({exec_error, ?C('ArgumentError', 'InvalidArgumentValue', "full-text query: OR needs a term on both sides")});
fts_group([I | Rest], Groups, Neg) -> fts_group(Rest, [[I] | Groups], Neg).

%% 组内并集（分数取最大）、组间交集（分数相加）、减去排除项。
fts_eval({Groups, Neg}, H) ->
    Sets = [lists:foldl(fun(I, Acc) -> maps:merge_with(fun(_K, A, B) -> max(A, B) end, Acc, fts_item(I, H)) end,
                        #{}, G) || G <- Groups],
    [First | More] = Sets,
    Inter = lists:foldl(fun(S, Acc) ->
                                maps:fold(fun(K, V, A) ->
                                                  case maps:find(K, S) of
                                                      {ok, V2} -> A#{K => V + V2};
                                                      error -> A
                                                  end
                                          end, #{}, Acc)
                        end, First, More),
    lists:foldl(fun(I, Acc) -> maps:without(maps:keys(fts_item(I, H)), Acc) end, Inter, Neg).

fts_item({term, W}, H) -> fetch_all(fun(K) -> bitcask:search_text(H, W, K) end);
fts_item({phrase, P}, H) -> fetch_all(fun(K) -> bitcask:search_phrase(H, P, K) end);
fts_item({prefix, W}, H) -> fetch_all(fun(K) -> bitcask:search_wildcard(H, <<W/binary, "*">>, K) end);
fts_item({fuzzy, W}, H) -> fetch_all(fun(K) -> bitcask:search_fuzzy(H, W, 1, K) end).

%% 全部命中（K 翻倍直到返回不满 K；全文检索没有阈值形态，需要的是命中集合）→ #{Vid => 分数}。
fetch_all(F) -> fetch_all(F, 1024).

fetch_all(F, K) ->
    case F(K) of
        {ok, Hits} when length(Hits) < K -> vertex_hits(Hits);
        {ok, _} when K >= ?SEARCH_CAP ->
            throw({exec_error, ?C('ArgumentError', 'NumberOutOfRange', "full-text term matches more than 1000000 documents; narrow the query")});
        {ok, _} -> fetch_all(F, min(K * 2, ?SEARCH_CAP));
        {error, no_index} ->
            throw({exec_error, ?C('SemanticError', 'none', "full-text search needs the graph opened in index mode ({analyzer, ...})")});
        {error, R} -> throw({exec_error, io_lib:format("full-text search failed: ~p", [R])});
        no_index ->
            throw({exec_error, ?C('SemanticError', 'none', "full-text search needs the graph opened in index mode ({analyzer, ...})")})
    end.

vertex_hits(Hits) ->
    P = graphdb_adj:prefix(),
    maps:from_list([{Vid, float(Sc)} || {<<P0:4/binary, "n", Vid:64/big>>, _Ord, Sc} <- Hits, P0 =:= P]).

%% =========================================================================
%% 向量（第 9.1 节）
%% =========================================================================

%% 查询向量：f32 小端 binary，或数值列表。
to_f32(B) when is_binary(B), byte_size(B) rem 4 =:= 0 -> B;
to_f32(L) when is_list(L) ->
    lists:all(fun is_number/1, L) orelse throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "a vector must be a list of numbers")}),
    << <<(float(X)):32/float-little>> || X <- L >>;
to_f32(_) -> throw({exec_error, ?C('TypeError', 'InvalidArgumentType', "a vector must be a list of numbers or an f32 binary")}).

%% 一个顶点到查询向量的距离（越小越近）：引擎相似度分数的相反数；顶点没有向量 → null。
vector_distance(Vid, QV, Ctx) ->
    Q = to_f32(QV),
    Cache = cget(?VDIST),
    case maps:find({Vid, Q}, Cache) of
        {ok, D} -> D;
        error ->
            fill_distances([Vid], Q, Ctx),
            maps:get({Vid, Q}, cget(?VDIST))
    end.

fill_distances(Vids, Q, Ctx) ->
    Keys = [nkey(V) || V <- Vids],
    Got = case bitcask:vector_rank(h(Ctx), Q, Keys, length(Keys)) of
              {ok, Hits} -> maps:from_list([{Vid, -float(Sc)} || {Vid, Sc} <- hit_vids(Hits)]);
              {error, R} -> throw({exec_error, io_lib:format("vector ranking failed: ~p", [R])})
          end,
    Cache = cget(?VDIST),
    put(?VDIST, lists:foldl(fun(V, C) -> C#{{V, Q} => maps:get(V, Got, null)} end, Cache, Vids)).

hit_vids(Hits) ->
    P = graphdb_adj:prefix(),
    [{Vid, Sc} || {<<P0:4/binary, "n", Vid:64/big>>, _Ord, Sc} <- Hits, P0 =:= P].

%% ORDER BY v.embedding <=> q：排序前对全部行的顶点一次批量算距离（bitcask:vector_rank）。
prefetch_distances(Keys, Rows, Ctx) ->
    lists:foreach(
      fun({{op, '<=>', {prop, {var, V}, <<"embedding">>}, QE}, _}) ->
              case bitcask_cypher_sema:expr_vars(QE) of
                  [] ->
                      case eval(QE, #{}, Ctx) of
                          null -> ok;
                          QV ->
                              Q = to_f32(QV),
                              Cache = cget(?VDIST),
                              Vids = lists:usort([Vid || Row <- Rows, {node, Vid} <- [maps:get(V, Row, null)],
                                                         not is_map_key({Vid, Q}, Cache)]),
                              Vids =/= [] andalso fill_distances(Vids, Q, Ctx),
                              ok
                      end;
                  _ -> ok
              end;
         (_) -> ok
      end, Keys).

label_filter(undefined) -> undefined;
label_filter(L) -> #{key => <<"_labels">>, op => contains, value => L}.

search_vec(Q, K, Label, Ctx) ->
    case bitcask:search_vector(h(Ctx), Q, K, 0, label_filter(Label)) of
        {ok, Hits} ->
            Vs = hit_vids(Hits),
            Cache = cget(?VDIST),
            put(?VDIST, lists:foldl(fun({V, Sc}, C) -> C#{{V, Q} => -float(Sc)} end, Cache, Vs)),
            {length(Hits), [{V, -float(Sc)} || {V, Sc} <- Vs]};
        {error, R} -> throw({exec_error, vector_error(R)});
        R -> throw({exec_error, vector_error(R)})
    end.

vector_error(no_index) -> "vector search needs the graph opened with {vector_dim, N} in index mode";
vector_error(R) -> io_lib:format("vector search failed: ~p", [R]).

exhaustive(B) ->
    S = cget(?STATS),
    put(?STATS, S#{vector_exhaustive => B andalso maps:get(vector_exhaustive, S, true)}).

%% 阈值形态：距离 < T（规划器把条件本身留作过滤，这里只给候选）。K 翻倍直到最后一个
%% 命中的距离已不小于 T、或引擎给不满 K。
vector_range(Q, T, Label, Ctx) -> vector_range(Q, T, Label, Ctx, 64).

vector_range(Q, T, Label, Ctx, K) ->
    {N, Hits} = search_vec(Q, K, Label, Ctx),
    Done = N < K orelse Hits =:= [] orelse element(2, lists:last(Hits)) >= T,
    case Done orelse K >= ?SEARCH_CAP of
        true ->
            exhaustive(Done),
            [V || {V, D} <- Hits, D =< T];
        false -> vector_range(Q, T, Label, Ctx, min(K * 4, ?SEARCH_CAP))
    end.

%% top-k 形态：要 K 行通过其余条件的。检索候选按距离升序，逐个过条件；不够就把检索的
%% k 翻倍（至多 64 倍或引擎上限），仍不够时 stats 里标 vector_exhaustive => false。
vector_topk(_Q, 0, _Label, _Pass, _Ctx) -> [];
vector_topk(Q, K, Label, Pass, Ctx) ->
    Cap = min(?SEARCH_CAP, max(K * 64, 1024)),
    vector_topk(Q, K, Label, Pass, Ctx, min(Cap, max(K * 2, 16)), Cap).

vector_topk(Q, K, Label, Pass, Ctx, Ask, Cap) ->
    {N, Hits} = search_vec(Q, Ask, Label, Ctx),
    Ok = [V || {V, _} <- Hits, Pass(V)],
    case length(Ok) >= K orelse N < Ask of
        true ->
            exhaustive(true),
            lists:sublist(Ok, K);
        false when Ask >= Cap ->
            exhaustive(false),
            Ok;
        false -> vector_topk(Q, K, Label, Pass, Ctx, min(Cap, Ask * 4), Cap)
    end.

%% =========================================================================
%% 惰性流
%% =========================================================================

empty() -> fun() -> done end.

single(X) -> fun() -> {X, empty()} end.

%% 量化组的深度优先展开：返回 [{终点, [每次重复的绑定], 关系列表（走过的顺序）}]，短的在前。
qpp_dfs(Cur, I, ItsRev, Used, RelsRev, Spec, Min, Max, Row, Ctx) ->
    Here = case I >= Min of
               true -> [{Cur, lists:reverse(ItsRev), lists:reverse(RelsRev)}];
               false -> []
           end,
    More = case Max =:= infinity orelse I < Max of
               true ->
                   lists:append([qpp_dfs(End, I + 1, [Bind | ItsRev], Used2, lists:reverse(IterRels, RelsRev),
                                         Spec, Min, Max, Row, Ctx)
                                 || {End, Bind, IterRels, Used2} <- qpp_iteration(Cur, Used, Spec, Row, Ctx)]);
               false -> []
           end,
    Here ++ More.

%% 一次重复：从节点 Cur 起匹配组体。返回 [{终点, 绑定, 这次的关系（按组体顺序）, 用过的关系}]。
qpp_iteration(Cur, Used, #{body := {chain, N0, Steps}, where := W}, Row, Ctx) ->
    case qpp_node_ok(N0, Cur, #{}, Row, Ctx) of
        false -> [];
        Bind0 ->
            [{End, Bind, Rels, U}
             || {End, Bind, Rels, U} <- qpp_walk(Cur, Steps, Bind0, [], Used, Row, Ctx),
                W =:= undefined orelse bitcask_cypher_expr:truthy(eval(W, maps:merge(Row, Bind), Ctx))]
    end.

qpp_walk(Cur, [], Bind, RelsRev, Used, _Row, _Ctx) -> [{Cur, Bind, lists:reverse(RelsRev), Used}];
qpp_walk(Cur, [{{rel, RV, Types, Props, Dir, _, _}, N} | Rest], Bind, RelsRev, Used, Row, Ctx) ->
    lists:append([case is_map_key(rel_id(Rel), Used) orelse
                          (Props =/= undefined andalso
                           not props_match(rel_props(Rel, Ctx), [Props], maps:merge(Row, Bind), Ctx)) of
                      true -> [];
                      false ->
                          Bind1 = bind_var(RV, Rel, Bind),
                          case qpp_node_ok(N, O, Bind1, Row, Ctx) of
                              false -> [];
                              Bind2 -> qpp_walk(O, Rest, Bind2, [Rel | RelsRev], Used#{rel_id(Rel) => true}, Row, Ctx)
                          end
                  end || {Rel, O} <- edges(Cur, Types, Dir, Ctx)]).

%% 组体里的节点：标签 / 属性对得上 → 绑定后的 Bind；否则 false
qpp_node_ok({node, NV, Labels, Props, _}, Vid, Bind, Row, Ctx) ->
    PropsEs = [Props || Props =/= undefined],
    case (Labels =:= [] andalso PropsEs =:= []) orelse node_ok(Vid, Labels, PropsEs, maps:merge(Row, Bind), Ctx) of
        true -> bind_var(NV, {node, Vid}, Bind);
        false -> false
    end.

bind_var(undefined, _V, Bind) -> Bind;
bind_var(Name, V, Bind) -> Bind#{Name => V}.

%% 第一次取的时候才算（物化一类的算子用）
lazy(F) -> fun() -> (F())() end.

from_list([]) -> empty();
from_list([X | Xs]) -> fun() -> {X, from_list(Xs)} end.

to_list(S) -> to_list(S(), []).
to_list(done, Acc) -> lists:reverse(Acc);
to_list({X, S}, Acc) -> to_list(S(), [X | Acc]).

append(A, B) ->
    fun() ->
            case A() of
                done    -> B();
                {X, A2} -> {X, append(A2, B)}
            end
    end.

%% F(Row) -> list() | stream()
flatmap(F, S) ->
    fun() ->
            case S() of
                done -> done;
                {X, S2} ->
                    Out = case F(X) of
                              L when is_list(L) -> from_list(L);
                              St -> St
                          end,
                    (append(Out, flatmap(F, S2)))()
            end
    end.

map(F, S) ->
    fun() ->
            case S() of
                done    -> done;
                {X, S2} -> {F(X), map(F, S2)}
            end
    end.

filter(P, S) ->
    fun() -> filter_next(P, S) end.

filter_next(P, S) ->
    case S() of
        done -> done;
        {X, S2} ->
            case P(X) of
                true  -> {X, filter(P, S2)};
                false -> filter_next(P, S2)
            end
    end.

take(0, _S) -> empty();
take(N, S) ->
    fun() ->
            case S() of
                done    -> done;
                {X, S2} -> {X, take(N - 1, S2)}
            end
    end.

drop(0, S) -> S;
drop(N, S) ->
    fun() ->
            case S() of
                done    -> done;
                {_, S2} -> (drop(N - 1, S2))()
            end
    end.

%% 分批取的有序 id 流：Fetch(After) -> [Vid]（升序，至多 ?SCAN_CHUNK 个）。
chunked(Fetch, After) ->
    fun() ->
            case Fetch(After) of
                [] -> done;
                Vs ->
                    Rest = case length(Vs) < ?SCAN_CHUNK of
                               true  -> empty();
                               false -> chunked(Fetch, lists:last(Vs))
                           end,
                    (append(from_list(Vs), Rest))()
            end
    end.

%% 两条升序 id 流的并集（去重）。
%% chunked 的变体：每块经 Expand 变换后再交出（块可能变空，空块不代表结束）；
%% 是否还有下一块看 Fetch 原始的块大小。
chunked_by(Fetch, Expand, After) ->
    fun() ->
            case Fetch(After) of
                [] -> done;
                Vs ->
                    Rest = case length(Vs) < ?SCAN_CHUNK of
                               true  -> empty();
                               false -> chunked_by(Fetch, Expand, lists:last(Vs))
                           end,
                    (append(from_list(Expand(Vs)), Rest))()
            end
    end.

merge_sorted(A, B) ->
    fun() -> merge_next(A(), B()) end.

merge_next(done, done) -> done;
merge_next(done, {Y, B2}) -> {Y, B2};
merge_next({X, A2}, done) -> {X, A2};
merge_next({X, A2}, {Y, B2}) when X < Y -> {X, merge_sorted(A2, fun() -> {Y, B2} end)};
merge_next({X, A2}, {Y, B2}) when X > Y -> {Y, merge_sorted(fun() -> {X, A2} end, B2)};
merge_next({X, A2}, {_Y, B2}) -> {X, merge_sorted(A2, B2)}.
