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
%%         vector => VecBin | {text, <<"...">>},      % 向量检索；与 {match,_} 同给 = 混合
%%         ef     => 128,                            % 只对纯向量检索有意义，默认 0
%%         where  => [{<<"year">>, gte, 2024},
%%                    {'or', [{<<"cat">>, in, [<<"db">>, <<"kv">>]},
%%                            {<<"hot">>, eq, true}]}],
%%         limit  => 100,                            % | infinity（默认）
%%         select => [key, text, meta, score]        % 默认全要
%%     }).
%%     Row = #{key => K, text => T, meta => #{binary() => V} | undefined,
%%             score => float()}                     % score 只在检索驱动时有
%%
%%   分页（limit = 每页条数，必须给）：
%%
%%     {ok, Rows1, Cont1} = bitcask_query:page(H, Query#{limit => 50}),
%%     {ok, Rows2, Cont2} = bitcask_query:page(Cont1),    % … 直到 Cont = done
%%
%%   游标不占服务端资源。key 驱动的游标是「下一页起始 key」；检索驱动见
%%   「检索驱动」一节——全文检索翻页不重不漏，向量 / 混合 / search_fields
%%   不重复但可能漏。
%%
%%   为什么不是 match spec / QLC：值是要分词的字符串，全文条件只能交给倒排
%%   （C++ analyzer），BEAM 侧逐行拿原文比没法和分词结果一致；结构化条件只能
%%   落在 meta 上。所以查询拆成三类条件，由规划器决定谁驱动：
%%
%%     有 text / vector → search_* 驱动（按分数降序），where 下推成引擎 meta
%%                    filter；key 条件对命中做后过滤。只有 vector →
%%                    search_vector；vector + {match,_} → search_hybrid（RRF）。
%%                    vector => {text, Bin} 用句柄的 embedder 编码，整个查询
%%                    （含翻页）只 embed 一次。
%%     有 key 无 text → {eq,K} 走 get；prefix/range 走 range（按 key 升序），
%%                    where 下推成 range 的 filter，meta 随条目带回。
%%     都没有       → 全表 range，同上；OKI 不可用（no_index）回落 fold + 逐行
%%                    get、BEAM 求值，收齐后按 key 排序（与 range 路径同序）。
%%
%%   where 语义与引擎 MetaFilter 逐条对齐（meta_filter.hpp），BEAM 侧求值只在
%%   {eq,K} 与 fold 回落两处用：
%%     * 无 meta 的文档过不了任何非空 where（含 neq）。
%%     * eq/neq/in 只在同类型间相等：1 与 1.0 不等；缺失字段读作 undefined，
%%       所以 {F, eq, undefined} 命中缺失字段。in 对缺失字段恒假。
%%     * gt/gte/lt/lte 只比 integer-integer、float-float，其它组合恒假。
%%     * exists = 字段存在且非 null。
%%
%%   一致性：range 是 per-key 弱一致（非快照），查询期间的并发写可能部分可见；
%%   扫描路径同一行的 text 与 meta 出自同一次读。text 驱动时命中只带 key，
%%   text/meta 由随后的 get 取——两次读之间被改写的文档，返回的是新版本
%%   （可能已不满足 where）。
%%
%%   依赖 libbitcask ≥ 6.6.1：带 filter 的全文检索补取到 K（返回不足 K 即已
%%   穷尽），同分命中前缀稳定。向量检索带 filter 时引擎本身可能少给（HNSW），
%%   返回不足 K 也只能当作穷尽。引擎 topK 上限 100 万（cpp/nif/term_conv.hpp
%%   kMaxTopK）：text 驱动在这个上限内凑不够 → {error, {too_many_hits, 1000000}}，
%%   不静默截断。
%% =========================================================================
-module(bitcask_query).

-export([q/2, page/2, page/1, explain/2]).
-export([create_index/2, drop_index/2, indexes/1, put/3, delete/2]).

%% 与 cpp/nif/term_conv.hpp 的 kMaxTopK 同值：NIF 会把更大的 K 静默压到这里。
-define(MAX_TOPK, 1000000).

-define(SELECT_ALL, [key, text, meta, score]).

-record(plan, {key    :: undefined | {eq, binary()}
                       | {range, binary() | undefined, binary() | undefined},
               text   :: undefined | text_cond(),
               %% binary() = f32 LE 查询向量；{text, Bin} 在 start/2 里 embed 成向量
               vector :: undefined | binary() | {text, binary()},
               ef     :: non_neg_integer(),
               %% 二级索引：auto = 能用就用 | none = 不用（对照 / 排错）
               index  :: auto | none,
               %% start/2 选定的索引：{Field, [{Lo, Hi}]}（索引键区间，升序）
               ix = undefined :: undefined | {binary(), [{binary(), binary()}]},
               %% 归一后：undefined = 无条件，否则顶层一定是 {'and'|'or', _}
               where  :: undefined | where(),
               limit  :: pos_integer() | infinity,
               select :: [key | text | meta | score]}).

%% 翻页游标（page/1 的 Cont 里装的就是它）。
-record(cur, {plan    :: #plan{},
              lo      :: binary() | undefined,   % key 驱动：下一页起点（含）
              pos     :: non_neg_integer(),      % 检索驱动：已消费的引擎命中数
              emitted :: #{binary() => true}}).  % 近似检索：已返回的 key

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
                       vector => binary() | {text, binary()},
                       ef     => non_neg_integer(),
                       where  => where(),
                       limit  => pos_integer() | infinity,
                       select => [key | text | meta | score]}.
-type row()       :: #{key => binary(), text => binary(),
                       meta => #{binary() => value()} | undefined,
                       score => float()}.

-opaque cont()    :: done | {?MODULE, term(), tuple()}.

-export_type([query/0, row/0, where/0, cont/0]).

%% =========================================================================
%% 入口
%% =========================================================================

-spec q(term(), query()) -> {ok, [row()]} | {error, term()}.
q(H, Query) when is_map(Query) ->
    guard(fun() ->
                  P = compile(Query),
                  {H, C} = start(H, P),
                  %% 与 page 走同一条路：多取一条判断下一页，这里用不上，丢掉游标。
                  Need = case P#plan.limit of
                             infinity -> infinity;
                             L        -> L + 1
                         end,
                  {Rows, _} = fetch(H, C, Need),
                  {ok, [shape(R, P#plan.select) || R <- Rows]}
          end);
q(_H, Query) ->
    {error, {bad_query, Query}}.

%% 分页：limit = 每页条数（必须给）。返回 {ok, Rows, Cont}，没有下一页时
%% Cont = done（最后一页可能正好满 limit）。Cont 是不透明的 term，带着
%% 句柄与查询；page(Cont) 取下一页，page(done) 返回 {ok, [], done}。
%% Cont 不占服务端资源，丢掉即可。
-spec page(term(), query()) -> {ok, [row()], cont()} | {error, term()}.
page(H, Query) when is_map(Query) ->
    guard(fun() ->
                  P = compile(Query),
                  P#plan.limit =:= infinity andalso
                      throw({bad_query, {limit, required_for_page}}),
                  {H, C} = start(H, P),
                  next_page(H, C)
          end);
page(_H, Query) ->
    {error, {bad_query, Query}}.

-spec page(cont()) -> {ok, [row()], cont()} | {error, term()}.
page(done) ->
    {ok, [], done};
page({?MODULE, H, #cur{} = C}) ->
    guard(fun() -> next_page(H, C) end);
page(Other) ->
    {error, {bad_cont, Other}}.

next_page(H, #cur{plan = #plan{limit = L, select = S}} = C) ->
    {Rows, Next} = fetch(H, C, L + 1),
    {ok, [shape(R, S) || R <- Rows],
     case Next of
         done -> done;
         _    -> {?MODULE, H, Next}
     end}.

%% 查询会怎么执行（不跑）：#{driver => get | range | index | search, ...}。
-spec explain(term(), query()) -> {ok, map()} | {error, term()}.
explain(H, Query) when is_map(Query) ->
    guard(fun() ->
                  {H, #cur{plan = P}} = start(H, compile(Query)),
                  {ok, describe(P)}
          end).

describe(#plan{text = undefined, vector = undefined, key = {eq, _}}) ->
    #{driver => get};
describe(#plan{ix = {F, Ranges}}) ->
    #{driver => index, field => F, ranges => length(Ranges)};
describe(#plan{text = undefined, vector = undefined}) ->
    #{driver => range};
describe(#plan{text = T, vector = V} = P) ->
    #{driver => search,
      kind => case {T, V} of
                  {undefined, _}            -> vector;
                  {_, Vec} when is_binary(Vec) -> hybrid;
                  {Tc, _}                   -> element(1, Tc)
              end,
      cursor => case approximate(P) of true -> dedupe; false -> offset end}.

%% ---- 二级索引（实现见 bitcask_query_index）-------------------------------

%% 在 meta 字段 Field 上建索引（回填存量）。已存在 → ok。
-spec create_index(term(), binary() | atom()) -> ok | {error, term()}.
create_index(H, Field) -> guard(fun() -> bitcask_query_index:create(H, Field) end).

-spec drop_index(term(), binary() | atom()) -> ok | {error, term()}.
drop_index(H, Field) -> guard(fun() -> bitcask_query_index:drop(H, Field) end).

%% [{Field, building | ready}]
-spec indexes(term()) -> [{binary(), building | ready}] | {error, term()}.
indexes(H) -> guard(fun() -> bitcask_query_index:list(H) end).

%% 写 / 删并维护索引项。⚠️ 有索引时，索引字段的写入必须走这两个函数——
%% 直接 bitcask:put 改了 meta，新值就查不到（重建索引可修）。Doc 形态同
%% bitcask:put。保留前缀的 key 拒绝。
-spec put(term(), binary(), term()) -> ok | {error, term()}.
put(H, Key, Doc) -> guard(fun() -> bitcask_query_index:put(H, Key, Doc) end).

-spec delete(term(), binary()) -> ok | {error, term()}.
delete(H, Key) -> guard(fun() -> bitcask_query_index:delete(H, Key) end).

guard(F) ->
    try F()
    catch
        throw:{bad_query, _} = Bad -> {error, Bad};
        throw:{?MODULE, error, E}  -> E
    end.

%% =========================================================================
%% 校验 + 归一
%% =========================================================================

compile(Q) ->
    case maps:keys(Q) -- [key, text, vector, ef, where, limit, select, index] of
        []    -> ok;
        Extra -> throw({bad_query, {unknown_keys, Extra}})
    end,
    Text = norm_text(maps:get(text, Q, undefined)),
    Vector = norm_vector(maps:get(vector, Q, undefined)),
    %% 混合检索的 BM25 一路是词袋（search_hybrid），所以只认 match。
    case {Text, Vector} of
        {{match, _}, _}    -> ok;
        {_, undefined}     -> ok;
        {undefined, _}     -> ok;
        _                  -> throw({bad_query, {hybrid_needs_match, Text}})
    end,
    Ef = case maps:get(ef, Q, 0) of
             E when is_integer(E), E >= 0, Vector =/= undefined, Text =:= undefined -> E;
             0 -> 0;
             E -> throw({bad_query, {ef, E}})            % 只对纯向量检索有意义
         end,
    Index = case maps:get(index, Q, auto) of
                I when I =:= auto; I =:= none -> I;
                I -> throw({bad_query, {index, I}})
            end,
    #plan{key    = norm_key(maps:get(key, Q, undefined)),
          index  = Index,
          text   = Text,
          vector = Vector,
          ef     = Ef,
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

norm_vector(undefined) -> undefined;
norm_vector({text, T} = V) when is_binary(T), T =/= <<>> -> V;
norm_vector(V) when is_binary(V), V =/= <<>>, byte_size(V) rem 4 =:= 0 -> V;
norm_vector(Other) -> throw({bad_query, {vector, Other}}).

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
%%
%% 两种驱动都实现成「从游标处往后取 Need 条」：
%%   q/2    Need = limit（infinity = 全要），游标 = 起点。
%%   page   Need = limit + 1——多取一条只为判断还有没有下一页，不返回。
%% 行在内部始终带 key（游标要用），select 裁剪放到最后。
%% =========================================================================

start(H, P0) ->
    P = choose_index(H, resolve_vector(H, P0)),
    Lo = case P#plan.key of
             {range, L, _} -> L;
             _             -> undefined
         end,
    {H, #cur{plan = P, lo = Lo, pos = 0, emitted = #{}}}.

%% 只有 where 时，看顶层 AND 里有没有已建好（ready）索引字段上的可用条件：
%% eq > in > 大小比较 > exists（越靠前通常越选择性高）。只挑一个；其余条件
%% 连同它自己在读校验时整体再判一遍。有 key / text / vector 条件时不用索引
%% ——那些驱动已经比全表扫描好，而选择性没法事先知道。
choose_index(_H, #plan{index = none} = P) -> P;
choose_index(_H, #plan{where = undefined} = P) -> P;
choose_index(H, #plan{key = undefined, text = undefined, vector = undefined,
                      where = W} = P) ->
    Ready = [F || {F, ready} <- bitcask_query_index:list(H)],
    Conj = case W of
               {'and', L}  -> L;
               {'or', [X]} -> [X];
               _           -> []
           end,
    Cands = lists:sort([{rank(C), F, C} || Leaf <- Conj,
                                            {F, C} <- [ix_cond(Leaf)],
                                            lists:member(F, Ready)]),
    case Cands of
        []                -> P;
        [{_, F, C} | _]   -> P#plan{ix = {F, bitcask_query_index:ranges(F, C)}}
    end;
choose_index(_H, P) -> P.

%% 叶子条件 → {Field, 索引条件}；不能走索引的给 skip（被上面的生成器滤掉）。
ix_cond({_F, eq, undefined})                  -> skip;   % 命中缺失字段，索引里没有
ix_cond({F, eq, V})                           -> {F, {eq, V}};
ix_cond({F, in, Vs})                          -> {F, {in, Vs}};
ix_cond({F, Op, V}) when Op =:= gt; Op =:= gte;
                         Op =:= lt; Op =:= lte -> {F, {Op, V}};
ix_cond({F, exists}) when is_binary(F)        -> {F, exists};
ix_cond(_)                                    -> skip.   % neq、嵌套 and/or

rank({eq, _}) -> 0;
rank({in, _}) -> 1;
rank({_, _})  -> 2;
rank(exists)  -> 3.

%% {text, Bin} 只在这里 embed 一次，结果存进 plan——翻页、K 翻倍都不重复调 embedder。
resolve_vector(H, #plan{vector = {text, T}} = P) ->
    case bitcask:embed(H, T) of
        {ok, V}        -> P#plan{vector = V};
        {error, _} = E -> throw({?MODULE, error, E})
    end;
resolve_vector(_H, P) ->
    P.

%% 取一批：返回 {Rows, 下一游标 | done}。Need = infinity 时一定 done。
fetch(H, #cur{plan = #plan{text = undefined, vector = undefined, key = {eq, K}} = P}, _Need) ->
    {case fetch_row(H, K, P) of
         skip -> [];
         Row  -> [Row]
     end, done};
fetch(H, #cur{plan = #plan{ix = {Field, Ranges}} = P, lo = Cur} = C, Need) ->
    Rows = ix_scan(H, Field, Ranges, Cur, P, Need),
    case split(Rows, Need) of
        {Page, []}                   -> {Page, done};
        {Page, [#{'$ix' := Next} | _]} -> {Page, C#cur{lo = Next}}
    end;
fetch(H, #cur{plan = #plan{text = undefined, vector = undefined} = P, lo = Lo} = C, Need) ->
    Hi = case P#plan.key of
             {range, _, R} -> R;
             undefined     -> undefined
         end,
    Rows = scan(H, Lo, Hi, P, Need),
    case split(Rows, Need) of
        {Page, []}                   -> {Page, done};
        {Page, [#{key := Next} | _]} -> {Page, C#cur{lo = Next}}
    end;
fetch(H, #cur{plan = P, pos = Pos, emitted = Em} = C, Need) ->
    Hits = search_from(H, P, Pos, Em, Need),
    case split(Hits, Need) of
        {Page, []} ->
            {[R || {R, _} <- Page], done};
        {Page, _More} ->
            {_, LastPos} = lists:last(Page),
            Rows = [R || {R, _} <- Page],
            C1 = case approximate(P) of
                     true  -> C#cur{emitted = lists:foldl(fun(#{key := K}, M) -> M#{K => true} end,
                                                          Em, Rows)};
                     false -> C#cur{pos = LastPos}
                 end,
            {Rows, C1}
    end.

%% Need = limit + 1 时把多取的那一条（若有）切出来；其余情况不切。
split(Xs, infinity) -> {Xs, []};
split(Xs, Need) when length(Xs) < Need -> {Xs, []};
split(Xs, Need) -> lists:split(Need - 1, Xs).

%% ---- key 驱动：range（有序）/ fold 兜底 ---------------------------------

scan(H, Lo, Hi, #plan{where = W, select = S} = P, Need) ->
    %% where 下推给 range 的 filter；要 meta 时条目带回 meta（与 text 同一次读）。
    WantMeta = W =/= undefined orelse lists:member(meta, S),
    Opts = [{want_meta, true} || WantMeta] ++
           [{filter, to_filter(W)} || W =/= undefined],
    %% 保留前缀（索引定义 / 索引项 / 事务幂等标记）不是用户数据。带 where 时
    %% 它们本来就没 meta、过不了 filter；不带时在这里跳过。
    RangeFun = fun(K, V, _T, _O, Acc) ->
                       case bitcask_query_index:is_reserved(K) of
                           true  -> Acc;
                           false -> take(range_row(K, V), Acc, Need)
                       end
               end,
    Res = try bitcask:range_fold(H, {Lo, Hi}, Opts, RangeFun, {0, []})
          catch throw:{?MODULE, done, Done} -> Done
          end,
    case Res of
        {error, no_index} ->
            %% 只读打开一个从未建过 OKI 的目录。fold 是快照、顺序未定义——
            %% 收齐后按 key 排序再截，结果顺序与 range 路径一致、可以分页
            %% （代价是每页都全表 fold 一遍，这条路径本来就罕见）。where 逐行
            %% get 后在 BEAM 求值。
            FoldFun = fun(K, V, Acc) ->
                              case in_bounds(K, Lo, Hi)
                                   andalso not bitcask_query_index:is_reserved(K)
                                   andalso fold_row(H, K, V, P) of
                                  false -> Acc;
                                  skip  -> Acc;
                                  Row   -> [Row | Acc]
                              end
                      end,
            case bitcask:fold(H, FoldFun, []) of
                {error, _} = E -> throw({?MODULE, error, E});
                All ->
                    Sorted = lists:sort(fun(#{key := A}, #{key := B}) -> A =< B end, All),
                    case Need of
                        infinity -> Sorted;
                        _        -> lists:sublist(Sorted, Need)
                    end
            end;
        {error, _} = E -> throw({?MODULE, error, E});
        {_N, Rows}     -> lists:reverse(Rows)
    end.

%% ---- 索引驱动 ------------------------------------------------------------
%%
%% 依次走索引键区间（游标 Cur 之前的部分跳过），每个索引项 get 一次文档并
%% 读校验：文档当前值的编码必须就是索引项那份（挡掉过期项，也挡掉重复），
%% 再在 BEAM 侧判整个 where。行按「索引值、主键」升序；'$ix' 记下行对应的
%% 索引键作游标，select 裁剪时自然丢掉。
ix_scan(H, Field, Ranges, Cur, #plan{where = W}, Need) ->
    Fun = fun(IxK, _V, _T, _O, Acc) ->
                  {PK, Enc} = bitcask_query_index:entry(Field, IxK),
                  case get_doc(H, PK) of
                      #{meta := M} = Doc ->
                          case bitcask_query_index:matches(Field, Enc, M)
                               andalso eval(W, M) of
                              true  -> take(Doc#{'$ix' => IxK}, Acc, Need);
                              false -> Acc
                          end;
                      skip -> Acc
                  end
          end,
    Res = try lists:foldl(
                fun({Lo, Hi}, Acc) ->
                        case Cur =/= undefined andalso Hi =< Cur of
                            true -> Acc;                                 % 整段在游标前
                            false ->
                                Lo1 = case Cur =/= undefined andalso Cur > Lo of
                                          true  -> Cur;
                                          false -> Lo
                                      end,
                                case bitcask:range_fold(H, {Lo1, Hi}, [], Fun, Acc) of
                                    {error, _} = E -> throw({?MODULE, error, E});
                                    Acc1           -> Acc1
                                end
                        end
                end, {0, []}, Ranges)
          catch throw:{?MODULE, done, Done} -> Done
          end,
    {_N, Rows} = Res,
    lists:reverse(Rows).

range_row(K, #{text := T, meta := MB}) -> #{key => K, text => T, meta => meta(MB)};
range_row(K, T) when is_binary(T)      -> #{key => K, text => T, meta => undefined}.

%% 攒满 Need 就抛出去提前结束迭代（range_fold 的 after 会放迭代器）。
take(Row, {N, Rows}, Need) ->
    Acc = {N + 1, [Row | Rows]},
    case Need =/= infinity andalso N + 1 >= Need of
        true  -> throw({?MODULE, done, Acc});
        false -> Acc
    end.

%% fold 给的 V 只有 text。需要 meta（where 或 select）时整行改用 get 那一份
%% ——text 和 meta 才是同一版本。
fold_row(H, K, V, #plan{where = W, select = S} = P) ->
    case W =:= undefined andalso not lists:member(meta, S) of
        true  -> #{key => K, text => V, meta => undefined};
        false -> fetch_row(H, K, P)
    end.

fetch_row(H, K, #plan{where = W}) ->
    case get_doc(H, K) of
        skip -> skip;
        #{meta := M} = Doc ->
            case W =:= undefined orelse eval(W, M) of
                true  -> Doc;
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

%% ---- 检索驱动（全文 / 向量 / 混合）---------------------------------------
%%
%% where 下推给引擎。全文检索引擎补取到 K，所以返回不足 K 即候选已穷尽；
%% 有 key 条件时它在 BEAM 侧后过滤，凑不够就翻倍 K 重查。
%%
%% 游标的两种形态：
%%   精确（全文，search_fields 除外）：libbitcask 6.6.1 起同分前缀稳定，小 K
%%       是大 K 的前缀——游标记「已消费的引擎命中数」，下一页从那里接着走，
%%       不重不漏。
%%   近似（向量 / 混合 / search_fields）：K 变了结果就会变（HNSW 近似、RRF
%%       融合、多字段逐字段 top-K 求和），没有前缀关系——每次从头取，按已返回
%%       的 key 去重。保证不重复，**可能漏**（翻页期间排名挤进前面的那些）。
%%       向量检索带 filter 时引擎本身就可能少给（HNSW live callback），返回不足
%%       K 也只能当作穷尽。

approximate(#plan{vector = V}) when V =/= undefined -> true;
approximate(#plan{text = {fields, _}})              -> true;
approximate(#plan{})                                -> false.

%% 返回 [{Row, Pos}]，Pos = 该命中在引擎结果里的序号（1 起），最多 Need 条。
search_from(H, #plan{key = Key} = P, Pos0, Em, Need) ->
    Pos = case approximate(P) of
              true  -> 0;
              false -> Pos0
          end,
    Skip = Pos + map_size(Em),
    K0 = case Need of
             infinity -> ?MAX_TOPK;
             N ->
                 Want = case Key =/= undefined orelse approximate(P) of
                            true  -> max(N * 4, 64);
                            false -> N
                        end,
                 min(Skip + Want, ?MAX_TOPK)
         end,
    search_loop(H, P, K0, Pos, Em, Need, #{}).

search_loop(H, #plan{} = P, KReq, Pos, Em, Need, Cache0) ->
    Hits = case search(H, P, KReq) of
               {ok, Hs}       -> Hs;
               {error, _} = E -> throw({?MODULE, error, E})
           end,
    Tail = lists:nthtail(min(Pos, length(Hits)), Hits),
    {Got, Cache} = collect(H, P, Tail, Pos + 1, Em, Need, Cache0, []),
    if
        Need =/= infinity, length(Got) >= Need -> Got;
        length(Hits) < KReq                    -> Got;     % 候选已穷尽
        KReq >= ?MAX_TOPK                      -> throw({?MODULE, error,
                                                         {error, {too_many_hits, ?MAX_TOPK}}});
        %% 没凑够且候选没穷尽 → 翻倍。Cache 带过去，已经 get 过的不再 get。
        true -> search_loop(H, P, min(KReq * 2, ?MAX_TOPK), Pos, Em, Need, Cache)
    end.

collect(_H, _P, _Hits, _I, _Em, Need, Cache, Acc) when Need =/= infinity,
                                                      length(Acc) >= Need ->
    {lists:reverse(Acc), Cache};
collect(_H, _P, [], _I, _Em, _Need, Cache, Acc) ->
    {lists:reverse(Acc), Cache};
collect(H, P, [{Key, _Ord, Score} | Rest], I, Em, Need, Cache, Acc) ->
    case Em of
        #{Key := _} -> collect(H, P, Rest, I + 1, Em, Need, Cache, Acc);
        _ ->
            {Row, Cache1} = case Cache of
                                #{Key := R} -> {R, Cache};
                                _ -> R = hit_row(H, Key, P), {R, Cache#{Key => R}}
                            end,
            Acc1 = case Row of
                       skip -> Acc;
                       _    -> [{Row#{score => Score}, I} | Acc]
                   end,
            collect(H, P, Rest, I + 1, Em, Need, Cache1, Acc1)
    end.

%% 一条命中 → 行（不含 score）或 skip。where 已由引擎判过。
hit_row(H, Key, #plan{key = KC, select = S}) ->
    case key_ok(Key, KC) of
        false -> skip;
        true ->
            case lists:member(text, S) orelse lists:member(meta, S) of
                false -> #{key => Key};
                true  -> get_doc(H, Key)
            end
    end.

key_ok(_K, undefined)      -> true;
key_ok(K, {eq, K2})        -> K =:= K2;
key_ok(K, {range, Lo, Hi}) -> in_bounds(K, Lo, Hi).

search(H, #plan{text = T, vector = V, ef = Ef, where = W}, K) ->
    F = case W of
            undefined -> undefined;
            _         -> to_filter(W)
        end,
    err(case {T, V} of
            {undefined, _}        -> bitcask:search_vector(H, V, K, Ef, F);
            {{match, Q}, Vec} when is_binary(Vec)
                                  -> bitcask:search_hybrid(H, Q, Vec, K, F);
            {{match, Q}, _}       -> bitcask:search_text(H, Q, K, F);
            {{phrase, Q}, _}      -> bitcask:search_phrase(H, Q, K, F);
            {{fields, Q}, _}      -> bitcask:search_fields(H, Q, K, F);
            {{wildcard, Q}, _}    -> bitcask:search_wildcard(H, Q, K, F);
            {{near, Q, Slop}, _}  -> bitcask:search_near(H, Q, Slop, K, F);
            {{fuzzy, Q, Ed}, _}   -> bitcask:search_fuzzy(H, Q, Ed, K, F)
        end).

%% search NIF 的故障可能是裸 atom（no_index 等，见 bitcask:normalize_error）。
err({ok, _} = Ok)   -> Ok;
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
