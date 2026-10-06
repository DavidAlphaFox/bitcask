%% =========================================================================
%% bitcask_query
%%
%%   结构化查询 DSL：key 条件 + 全文条件 + meta 条件，规划器挑一个索引驱动。
%%
%%     {ok, Rows} = bitcask_query:q(H, #{
%%         key    => {prefix, <<"doc:">>},          % | {range, Lo, Hi} | {eq, K}
%%         text   => {match, <<"分布式 存储">>},     % | {phrase,Q} | {fields,Q}
%%                                                   % | {near,Q,Slop} | {fuzzy,Q,MaxEdit}
%%                                                   % | {wildcard,P}
%%         where  => [{<<"year">>, gte, 2024},
%%                    {'or', [{<<"cat">>, in, [<<"db">>, <<"kv">>]},
%%                            {<<"hot">>, eq, true}]}],
%%         limit  => 100,                            % | infinity（默认）
%%         select => [key, text, meta, score]        % 默认全要
%%     }).
%%     Row = #{key => K, text => T, meta => #{binary() => V} | undefined,
%%             score => float()}                     % score 只在 text 驱动时有
%%
%%   为什么不是 match spec / QLC：值是要分词的字符串，全文条件只能交给倒排
%%   （C++ analyzer），BEAM 侧逐行拿原文比没法和分词结果一致；结构化条件只能
%%   落在 meta 上。所以查询拆成三类条件，由规划器决定谁驱动：
%%
%%     有 text      → search_* 驱动（按分数降序）。match 把 where 下推成引擎
%%                    meta filter；其它几种引擎不收 filter，逐条 get 后在 BEAM
%%                    求值。key 条件对命中做后过滤。
%%     有 key 无 text → {eq,K} 走 get；prefix/range 走 range（按 key 升序）。
%%     都没有       → 全表 range（按 key 升序）；OKI 不可用（no_index）回落 fold
%%                    （顺序未定义）。
%%
%%   where 语义与引擎 MetaFilter 逐条对齐（meta_filter.hpp）：
%%     * 无 meta 的文档过不了任何非空 where（含 neq）。
%%     * eq/neq/in 只在同类型间相等：1 与 1.0 不等；缺失字段读作 undefined，
%%       所以 {F, eq, undefined} 命中缺失字段。in 对缺失字段恒假。
%%     * gt/gte/lt/lte 只比 integer-integer、float-float，其它组合恒假。
%%     * exists = 字段存在且非 null。
%%
%%   ⚠️ 已知约束（上游改了再删，见 libbitcask feedbacks/2026-10-06-meta-filter-query-gaps.md）：
%%     * 引擎带 filter 的 search_text 只多取一次 max(K×4,64) 个候选再后过滤，
%%       不够就静默少给。这里按「返回不足 → 用同样候选数的无 filter 查询判断
%%       候选是否已穷尽 → 未穷尽就 K 翻倍重查」补齐；正确，但重查有成本。
%%     * fold/range 不带 meta：有 where 或要 meta 时逐行补一次 get，text 也取
%%       get 那一份，保证同一行的 text/meta 来自同一版本。range 本身是 per-key
%%       弱一致（非快照），查询期间的并发写可能部分可见。
%%     * 引擎 topK 上限 100 万（cpp/nif/term_conv.hpp kMaxTopK）。text 驱动在
%%       这个上限内凑不够 / 判不了穷尽 → {error, {too_many_hits, 1000000}}，
%%       不静默截断。
%% =========================================================================
-module(bitcask_query).

-export([q/2]).

%% 与 cpp/nif/term_conv.hpp 的 kMaxTopK 同值：NIF 会把更大的 K 静默压到这里。
-define(MAX_TOPK, 1000000).

-define(SELECT_ALL, [key, text, meta, score]).

-type key_cond()  :: {prefix, binary()}
                   | {range, binary() | undefined, binary() | undefined}
                   | {eq, binary()}.
-type text_cond() :: {match | phrase | fields | wildcard, binary()}
                   | {near, binary(), non_neg_integer()}
                   | {fuzzy, binary(), non_neg_integer()}.
-type field()     :: binary() | atom().
-type value()     :: integer() | float() | binary() | boolean() | undefined.
-type where()     :: {field(), eq | neq | gt | gte | lt | lte, value()}
                   | {field(), in, [value(), ...]}
                   | {field(), exists}
                   | {'and' | 'or', [where(), ...]}
                   | [where()].
-type query()     :: #{key    => key_cond(),
                       text   => text_cond(),
                       where  => where(),
                       limit  => pos_integer() | infinity,
                       select => [key | text | meta | score]}.
-type row()       :: #{key => binary(), text => binary(),
                       meta => #{binary() => value()} | undefined,
                       score => float()}.

-export_type([query/0, row/0, where/0]).

%% =========================================================================
%% 入口
%% =========================================================================

-spec q(term(), query()) -> {ok, [row()]} | {error, term()}.
q(H, Query) when is_map(Query) ->
    try run(H, compile(Query))
    catch
        throw:{bad_query, _} = Bad -> {error, Bad};
        throw:{?MODULE, error, E}  -> E
    end;
q(_H, Query) ->
    {error, {bad_query, Query}}.

%% =========================================================================
%% 校验 + 归一
%% =========================================================================

-record(plan, {key    :: undefined | {eq, binary()}
                       | {range, binary() | undefined, binary() | undefined},
               text   :: undefined | text_cond(),
               %% 归一后：undefined = 无条件，否则顶层一定是 {'and'|'or', _}
               where  :: undefined | where(),
               limit  :: pos_integer() | infinity,
               select :: [key | text | meta | score]}).

compile(Q) ->
    case maps:keys(Q) -- [key, text, where, limit, select] of
        []    -> ok;
        Extra -> throw({bad_query, {unknown_keys, Extra}})
    end,
    #plan{key    = norm_key(maps:get(key, Q, undefined)),
          text   = norm_text(maps:get(text, Q, undefined)),
          where  = norm_where_top(maps:get(where, Q, [])),
          limit  = norm_limit(maps:get(limit, Q, infinity)),
          select = norm_select(maps:get(select, Q, ?SELECT_ALL))}.

norm_key(undefined)                            -> undefined;
norm_key({eq, K}) when is_binary(K)            -> {eq, K};
norm_key({prefix, P}) when is_binary(P)        -> {range, P, bitcask:prefix_succ(P)};
norm_key({range, Lo, Hi} = R) ->
    case bound_ok(Lo) andalso bound_ok(Hi) of
        true  -> R;
        false -> throw({bad_query, {key, R}})
    end;
norm_key(Other)                                -> throw({bad_query, {key, Other}}).

bound_ok(undefined) -> true;
bound_ok(B)         -> is_binary(B).

norm_text(undefined) -> undefined;
norm_text({Kind, Q} = T) when is_binary(Q), (Kind =:= match orelse Kind =:= phrase
                                             orelse Kind =:= fields
                                             orelse Kind =:= wildcard) -> T;
norm_text({Kind, Q, N} = T) when is_binary(Q), is_integer(N), N >= 0,
                                 (Kind =:= near orelse Kind =:= fuzzy) -> T;
norm_text(Other) -> throw({bad_query, {text, Other}}).

norm_limit(infinity)                         -> infinity;
norm_limit(N) when is_integer(N), N > 0      -> N;
norm_limit(Other)                            -> throw({bad_query, {limit, Other}}).

norm_select(S) when is_list(S), S =/= [] ->
    case S -- ?SELECT_ALL of
        [] -> S;
        _  -> throw({bad_query, {select, S}})
    end;
norm_select(S) -> throw({bad_query, {select, S}}).

%% 顶层空列表 = 无 where；嵌套里的空 and/or 一律拒（引擎对空 OR 判真，
%% 和直觉相反，不如直接不让写）。
norm_where_top([]) -> undefined;
norm_where_top(W) ->
    case norm_where(W) of
        {Logic, _} = X when Logic =:= 'and'; Logic =:= 'or' -> X;
        Leaf -> {'and', [Leaf]}
    end.

norm_where(L) when is_list(L)                       -> norm_where({'and', L});
norm_where({Logic, [_ | _] = L}) when Logic =:= 'and'; Logic =:= 'or' ->
    {Logic, [norm_where(W) || W <- L]};
norm_where({F, exists})                             -> {field(F), exists};
norm_where({F, in, [_ | _] = Vs} = W) ->
    [value(V, W) || V <- Vs],
    {field(F), in, Vs};
norm_where({F, Op, V} = W) when Op =:= eq; Op =:= neq; Op =:= gt;
                                Op =:= gte; Op =:= lt; Op =:= lte ->
    value(V, W),
    {field(F), Op, V};
norm_where(Other) -> throw({bad_query, {where, Other}}).

field(F) when is_binary(F) -> F;
field(F) when is_atom(F)   -> atom_to_binary(F, utf8);
field(F)                   -> throw({bad_query, {field, F}}).

value(V, _) when is_boolean(V); V =:= undefined; is_float(V); is_binary(V) -> ok;
value(V, _) when is_integer(V), V >= -(1 bsl 63), V < (1 bsl 63)        -> ok;
value(_, W) -> throw({bad_query, {where, W}}).

%% =========================================================================
%% 执行
%% =========================================================================

run(H, #plan{text = undefined, key = {eq, K}} = P) ->
    {ok, case fetch_row(H, K, P) of
             skip -> [];
             Row  -> [Row]
         end};
run(H, #plan{text = undefined, key = Key} = P) ->
    {Lo, Hi} = case Key of
                   undefined         -> {undefined, undefined};
                   {range, L, R}     -> {L, R}
               end,
    scan(H, Lo, Hi, P);
run(H, #plan{} = P) ->
    text_driven(H, P).

%% ---- key 驱动：range（有序）/ fold 兜底 ---------------------------------

scan(H, Lo, Hi, #plan{limit = Limit} = P) ->
    Step = fun(K, V, Acc) ->
                   case scan_row(H, K, V, P) of
                       skip -> Acc;
                       Row  -> take(Row, Acc, Limit)
                   end
           end,
    RangeFun = fun(K, V, _T, _O, Acc) -> Step(K, V, Acc) end,
    Res = try bitcask:range_fold(H, {Lo, Hi}, [], RangeFun, {0, []})
          catch throw:{?MODULE, done, Done} -> Done
          end,
    case Res of
        {error, no_index} ->
            %% 只读打开一个从未建过 OKI 的目录。fold 是快照、顺序未定义，
            %% 按 key 边界在 BEAM 侧过滤。
            FoldFun = fun(K, V, Acc) ->
                              case in_bounds(K, Lo, Hi) of
                                  true  -> Step(K, V, Acc);
                                  false -> Acc
                              end
                      end,
            finish(try bitcask:fold(H, FoldFun, {0, []})
                   catch throw:{?MODULE, done, Done2} -> Done2
                   end);
        Other ->
            finish(Other)
    end.

%% 攒满 limit 就抛出去提前结束迭代（range_fold / fold 的 after 会放迭代器）。
take(Row, {N, Rows}, Limit) ->
    Acc = {N + 1, [Row | Rows]},
    case Limit =/= infinity andalso N + 1 >= Limit of
        true  -> throw({?MODULE, done, Acc});
        false -> Acc
    end.

finish({error, _} = E) -> E;
finish({_N, Rows})     -> {ok, lists:reverse(Rows)}.

%% range/fold 给的 V 只有 text。需要 meta（where 或 select）时整行改用 get
%% 那一份——text 和 meta 才是同一版本。
scan_row(H, K, V, #plan{where = W, select = S} = P) ->
    case W =:= undefined andalso not lists:member(meta, S) of
        true  -> shape(#{key => K, text => V, meta => undefined}, S);
        false -> fetch_row(H, K, P)
    end.

fetch_row(H, K, #plan{where = W, select = S}) ->
    case get_doc(H, K) of
        skip -> skip;
        #{meta := M} = Doc ->
            case W =:= undefined orelse eval(W, M) of
                true  -> shape(Doc, S);
                false -> skip
            end
    end.

%% get 的两种形态：索引模式 #{text, meta}，KV 模式裸 binary（没有 meta）。
%% 删了 / 过期了 → skip（迭代与 get 之间被删是常态，不是错）。
get_doc(H, K) ->
    case bitcask:get(H, K) of
        {ok, #{text := T, meta := MB}} -> #{key => K, text => T, meta => meta(MB)};
        {ok, Bin} when is_binary(Bin)  -> #{key => K, text => Bin, meta => undefined};
        not_found                      -> skip;
        {error, _} = E                 -> throw({?MODULE, error, E});
        Other                          -> throw({?MODULE, error, {error, Other}})
    end.

%% meta 是调用方给的任意 binary（不一定出自 encode_meta）。解不开按「无
%% meta」处理——引擎 meta_lookup 对坏 blob 也是什么都查不到。
meta(undefined) -> undefined;
meta(<<>>)      -> undefined;
meta(Bin) ->
    try bitcask:decode_meta(Bin)
    catch error:badarg -> undefined
    end.

shape(Row, S) -> maps:with(S, Row).

in_bounds(K, Lo, Hi) ->
    (Lo =:= undefined orelse K >= Lo) andalso (Hi =:= undefined orelse K < Hi).

%% ---- text 驱动 ---------------------------------------------------------
%%
%% 凑不够 limit 就翻倍 K 重查。⚠️ 大 K 的结果**不是**小 K 结果的延长：
%% 同分时引擎按 key 升序挑进 top-K、输出却按 ord 降序排（K=5 给
%% d0005..d0001，K=1000 时 d0001 排最后）。所以每轮按引擎最新给的顺序从头
%% 组装，已经求值过的 key 记在 Seen 里，不重复 get。

text_driven(H, #plan{limit = Limit, key = Key, where = W} = P) ->
    PostFilter = Key =/= undefined orelse (W =/= undefined andalso not pushable(P)),
    K0 = case Limit of
             infinity             -> ?MAX_TOPK;
             L when PostFilter    -> min(max(L * 4, 64), ?MAX_TOPK);
             L                    -> min(L, ?MAX_TOPK)
         end,
    try text_loop(H, P, K0, #{})
    catch throw:{?MODULE, done, Acc} -> finish(Acc)
    end.

text_loop(H, #plan{limit = Limit, select = S} = P, KReq, Seen0) ->
    case search(H, P, KReq) of
        {error, _} = E -> E;
        {ok, Hits, Exhausted} ->
            {Acc, Seen} =
                lists:foldl(
                  fun({Key, _Ord, Score}, {A, Sn}) ->
                          {Row, Sn1} = case Sn of
                                           #{Key := R} -> {R, Sn};
                                           _ -> R = text_row(H, Key, P),
                                                {R, Sn#{Key => R}}
                                       end,
                          case Row of
                              skip -> {A, Sn1};
                              _    -> {take(shape(Row#{score => Score}, S), A, Limit), Sn1}
                          end
                  end, {{0, []}, Seen0}, Hits),
            if
                Exhausted         -> finish(Acc);
                KReq >= ?MAX_TOPK -> {error, {too_many_hits, ?MAX_TOPK}};
                %% limit 未满（满了已在 take 里抛出）且候选没穷尽 → 翻倍。
                true              -> text_loop(H, P, min(KReq * 2, ?MAX_TOPK), Seen)
            end
    end.

%% 一条命中 → 行（不含 score）或 skip。
text_row(H, Key, #plan{key = KC, where = W, select = S} = P) ->
    case key_ok(Key, KC) of
        false -> skip;
        true ->
            BeamWhere = W =/= undefined andalso not pushable(P),
            case BeamWhere orelse lists:member(text, S) orelse lists:member(meta, S) of
                false -> #{key => Key};
                true ->
                    case get_doc(H, Key) of
                        skip -> skip;
                        #{meta := M} = Doc ->
                            case not BeamWhere orelse eval(W, M) of
                                true  -> Doc;
                                false -> skip
                            end
                    end
            end
    end.

key_ok(_K, undefined)      -> true;
key_ok(K, {eq, K2})        -> K =:= K2;
key_ok(K, {range, Lo, Hi}) -> in_bounds(K, Lo, Hi).

%% 只有 search_text 收 meta filter。
pushable(#plan{text = {match, _}, where = W}) -> W =/= undefined;
pushable(#plan{})                             -> false.

%% 返回 {ok, Hits, Exhausted}：Exhausted = 倒排里已经没有更多候选。
search(H, #plan{text = {match, Q}} = P, KReq) ->
    case pushable(P) of
        false -> plain(bitcask:search_text(H, Q, KReq), KReq);
        true ->
            case bitcask:search_text(H, Q, KReq, to_filter(P#plan.where)) of
                {ok, Hits} when length(Hits) >= KReq ->
                    {ok, Hits, false};
                {ok, Hits} ->
                    %% 返回不足 K：可能真没了，也可能是引擎 max(K×4,64) 的
                    %% 候选被 filter 筛空了。用同样候选数的无 filter 查询判断。
                    Cand = min(max(KReq * 4, 64), ?MAX_TOPK),
                    case bitcask:search_text(H, Q, Cand) of
                        {ok, All}      -> {ok, Hits, length(All) < Cand};
                        {error, _} = E -> E
                    end;
                Other -> err(Other)
            end
    end;
search(H, #plan{text = {phrase, Q}}, K)      -> plain(bitcask:search_phrase(H, Q, K), K);
search(H, #plan{text = {fields, Q}}, K)      -> plain(bitcask:search_fields(H, Q, K), K);
search(H, #plan{text = {wildcard, Q}}, K)    -> plain(bitcask:search_wildcard(H, Q, K), K);
search(H, #plan{text = {near, Q, Slop}}, K)  -> plain(bitcask:search_near(H, Q, Slop, K), K);
search(H, #plan{text = {fuzzy, Q, Ed}}, K)   -> plain(bitcask:search_fuzzy(H, Q, Ed, K), K).

plain({ok, Hits}, K) -> {ok, Hits, length(Hits) < K};
plain(Other, _K)     -> err(Other).

%% search NIF 的故障可能是裸 atom（no_index 等，见 bitcask:normalize_error）。
err({error, _} = E) -> E;
err(Other)          -> {error, Other}.

%% where → 引擎 MetaFilter term（nif_helpers.cpp parse_filter_term）。
to_filter({Logic, Ws}) ->
    {Leaves, Subs} = lists:partition(fun is_leaf/1, Ws),
    #{logic      => Logic,
      conditions => [leaf(W) || W <- Leaves],
      children   => [to_filter(W) || W <- Subs]}.

is_leaf({Logic, L}) when (Logic =:= 'and' orelse Logic =:= 'or'), is_list(L) -> false;
is_leaf(_) -> true.

leaf({F, exists})   -> #{key => F, op => exists};
leaf({F, in, Vs})   -> #{key => F, op => in, values => Vs};
leaf({F, Op, V})    -> #{key => F, op => Op, value => V}.

%% ---- BEAM 侧求值（与 meta_filter.hpp 对齐，见模块头）---------------------

eval(_W, undefined)    -> false;             % 无 meta 过不了任何 where
eval({'and', Ws}, M)   -> lists:all(fun(W) -> eval(W, M) end, Ws);
eval({'or', Ws}, M)    -> lists:any(fun(W) -> eval(W, M) end, Ws);
eval({F, exists}, M)   -> maps:get(F, M, undefined) =/= undefined;
eval({F, in, Vs}, M) ->
    case maps:get(F, M, undefined) of
        undefined -> false;
        S         -> lists:any(fun(V) -> same(S, V) end, Vs)
    end;
eval({F, eq, V}, M)    -> same(maps:get(F, M, undefined), V);
eval({F, neq, V}, M)   -> not same(maps:get(F, M, undefined), V);
eval({F, Op, V}, M)    -> ordered(Op, maps:get(F, M, undefined), V).

same(A, B) when is_integer(A), is_integer(B) -> A =:= B;
same(A, B) when is_float(A), is_float(B)     -> A == B;
same(A, B) when is_binary(A), is_binary(B)   -> A =:= B;
same(A, B) when is_boolean(A), is_boolean(B) -> A =:= B;
same(undefined, undefined)                   -> true;
same(_, _)                                   -> false.

ordered(Op, A, B) when (is_integer(A) andalso is_integer(B));
                       (is_float(A) andalso is_float(B)) ->
    case Op of
        gt  -> A > B;
        gte -> A >= B;
        lt  -> A < B;
        lte -> A =< B
    end;
ordered(_, _, _) -> false.
