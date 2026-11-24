%% =========================================================================
%% graphdb_model — 图的数据模型：顶点 id 分配、标签与标签索引、属性编码
%%
%% 设计：doc/cypher-query-design-zh.md 第 4、8.2、11 节。图层 API（graphdb）与
%% Cypher 执行器共用这一份模型——同一个 id 空间、同一份标签索引、同一种属性编码。
%%
%% key（<<1,"_g:">> 全局前缀之后）：
%%   c                              → id 高水位：「下一个可发的 id」，<<N:72/big>>
%%   l <len:16> <label> <vid:64>    → 标签索引项，值为空
%% 顶点 n<vid> 文档：meta 的保留键 `_labels`（字符串数组）存标签，其余键是属性；
%% text 段是正文（对 Cypher 暴露为属性 `text`），vector 段是向量。
%% 边属性：meta 编码的二进制；旧的任意二进制解不出来时整体暴露为 `_raw`。
%%
%% id 规则（8.2）：
%%   * 分配（create_vertex）在建顶点的那条原子批里带版本条件读写计数器，并对发出的
%%     id 带「n<vid>、a<vid> 都不存在」的条件——分配器永远不覆盖已有数据；
%%   * 指定 id 的写入（put_vertex、put_edge 的端点）在 vid ≥ 计数器时把计数器推到
%%     vid + 1（bump_watermark/2）；计数器还没建（从未分配过）时不碰它，第一次分配时
%%     按现有最大 vid 初始化。
%% =========================================================================
-module(graphdb_model).

-export([ckey/0, lkey/2, label_prefix/1,
         read_counter/1, bump_watermark/2, allocate/3, max_vid/1,
         to_doc/1, doc_labels/1, decode_vertex/2, vertex_exists/2,
         labels_from_meta/1, props_from_doc/1,
         norm_labels/1, norm_props/1, encode_meta_props/2,
         encode_edge_props/1, decode_edge_props/1,
         label_ops/3, label_vids/3,
         doc_info/1, doc_model/1, model_doc/1,
         txn_allocate/2, txn_update_vertex/3, txn_vertex_info/2, txn_vertex_exists/2,
         txn_bump_watermark/2,
         %% 扩展值类型的编解码挂点（bitcask_cypher 注册时间 / 空间值、NaN / Infinity）
         register_value_codec/1, unregister_value_codec/0, value_codec/0,
         %% 属性索引（二期）
         skey/0, xprefix/2, xkey/4, schema/1, txn_schema/1, index_ops/4, doc_lp/1,
         index_scalar/1, ready_index/3, create_index/3, drop_index/3, list_indexes/1,
         index_problems/1]).

-define(VID_MAX, 16#FFFFFFFFFFFFFFFF).
-define(LABELS, <<"_labels">>).
-define(BUMP_TRIES, 32).
-define(ALLOC_TRIES, 64).

%% =========================================================================
%% key
%% =========================================================================

ckey() -> << (graphdb_adj:prefix())/binary, "c" >>.

lkey(Label, Vid) ->
    << (label_prefix(Label))/binary, Vid:64/big >>.

label_prefix(Label) when is_binary(Label) ->
    << (graphdb_adj:prefix())/binary, "l", (byte_size(Label)):16/big, Label/binary >>.

nkey(Vid) -> << (graphdb_adj:prefix())/binary, "n", Vid:64/big >>.

%% =========================================================================
%% id 计数器
%% =========================================================================

%% {ok, Next, Ord} | absent | {error, _}
read_counter(H) ->
    case bitcask:get_with_ord(H, ckey()) of
        {ok, V, Ord} ->
            case vbin(V) of
                <<N:72/big>> -> {ok, N, Ord};
                _            -> {error, bad_vid_counter}
            end;
        not_found      -> absent;
        {error, _} = E -> E
    end.

enc_counter(N) -> <<N:72/big>>.

%% 指定 id 的写入推高水位：MaxVid ≥ 计数器时把计数器推到 MaxVid + 1。计数器还没建
%% 时不碰（第一次分配时按现有最大 vid 初始化）。与之后的数据写入不在一个批里——
%% 只会让水位偏高（id 本来就不回收），不会让分配器发出已占用的 id（分配还带存在性条件）。
bump_watermark(_H, undefined) ->
    ok;
bump_watermark(H, MaxVid) ->
    bump_watermark(H, MaxVid, ?BUMP_TRIES).

bump_watermark(_H, _MaxVid, 0) ->
    {error, conflict};
bump_watermark(H, MaxVid, N) ->
    case read_counter(H) of
        absent -> ok;
        {ok, Next, _Ord} when MaxVid < Next -> ok;
        {ok, _Next, Ord} ->
            case bitcask:put_batch_atomic(H, [{put, ckey(), enc_counter(MaxVid + 1), {ord, Ord}}]) of
                ok                     -> ok;
                {error, {conflict, _}} -> bump_watermark(H, MaxVid, N - 1);
                {error, read_only}     -> ok;
                {error, _} = E         -> E
            end;
        {error, _} = E -> E
    end.

%% 分配一个新 id 并在同一条原子批里建顶点：Build(Vid) -> [Op]（顶点文档、标签索引项……）。
%% 返回 {ok, Vid} | {error, _}。
allocate(H, Build, Retries) ->
    allocate(H, Build, Retries, 0, 0).

allocate(_H, _Build, Retries, Attempt, _Floor) when Retries =/= infinity, Attempt > Retries ->
    {error, conflict};
allocate(H, Build, Retries, Attempt, Floor) ->
    case counter_or_init(H) of
        {error, _} = E -> E;
        {Next, Cond} ->
            Vid = max(Next, Floor),
            case Vid > ?VID_MAX of
                true -> {error, vid_exhausted};
                false ->
                    Ops = [{put, ckey(), enc_counter(Vid + 1), Cond},
                           {check, nkey(Vid), absent},
                           {check, graphdb_adj:head_key(Vid), absent}
                           | Build(Vid)],
                    case bitcask:put_batch_atomic(H, Ops) of
                        ok ->
                            {ok, Vid};
                        {error, {conflict, 1}} ->         %% 计数器被并发推进了
                            backoff(Attempt),
                            allocate(H, Build, Retries, Attempt + 1, Floor);
                        {error, {conflict, I}} when I =:= 2; I =:= 3 ->
                            %% 这个 id 已被占（指定 id 的写入没推水位，或推水位与写入之间
                            %% 的空当）：越过它
                            allocate(H, Build, Retries, Attempt + 1, Vid + 1);
                        {error, {conflict, _}} ->
                            backoff(Attempt),
                            allocate(H, Build, Retries, Attempt + 1, Floor);
                        {error, _} = E ->
                            E
                    end
            end
    end.

backoff(Attempt) -> timer:sleep(rand:uniform(1 bsl min(Attempt, 6)) - 1).

%% {Next, Cond}：计数器在就用它；不在就按现有最大 vid 初始化（Cond = absent）。
counter_or_init(H) ->
    case read_counter(H) of
        {ok, Next, Ord} -> {Next, {ord, Ord}};
        absent ->
            case max_vid(H) of
                {ok, none}     -> {1, absent};
                {ok, Max}      -> {Max + 1, absent};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

%% 现有最大 vid（n 与 a 两个家族）：{ok, Vid | none}。key 里 vid 是定宽大端，字典序 =
%% 数值序；在 vid 上二分「[F X, 家族尾) 里还有没有 key」，每个家族 64 次区间探测。
max_vid(H) ->
    try
        A = family_max(H, <<"n">>),
        B = family_max(H, <<"a">>),
        {ok, case {A, B} of
                 {none, none} -> none;
                 {none, _}    -> B;
                 {_, none}    -> A;
                 _            -> max(A, B)
             end}
    catch throw:{graphdb_model, E} -> E
    end.

family_max(H, F) ->
    {_Lo, Hi} = graphdb_adj:range(F),
    Base = << (graphdb_adj:prefix())/binary, F/binary >>,
    Has = fun(X) -> any_key(H, << Base/binary, X:64/big >>, Hi) end,
    case Has(0) of
        false -> none;
        true  -> bsearch(Has, 0, ?VID_MAX)
    end.

%% Has(Lo) 为真；找最大的 X 使 Has(X) 为真。
bsearch(_Has, Lo, Hi) when Lo >= Hi -> Lo;
bsearch(Has, Lo, Hi) ->
    Mid = Lo + (Hi - Lo + 1) div 2,
    case Has(Mid) of
        true  -> bsearch(Has, Mid, Hi);
        false -> bsearch(Has, Lo, Mid - 1)
    end.

any_key(H, Lo, Hi) ->
    try bitcask:range_fold(H, {Lo, Hi}, [{batch, 1}],
                           fun(_K, _V, _T, _O, _A) -> throw({graphdb_model_found}) end, false) of
        {error, _} = E -> throw({graphdb_model, E});
        _              -> false
    catch throw:{graphdb_model_found} -> true
    end.

%% =========================================================================
%% 顶点文档
%% =========================================================================

%% 图层 API 收的顶点形态 → 写给引擎的值：
%%   binary                                  —— 原样（没有标签、没有属性）
%%   #{labels => [L], props => #{K => V}, text => Bin, vector => Vec}
%%                                           —— 模型形态（四个键都可省）
%%   其余 map（#{text, meta, vector, fields}） —— 引擎文档原样；meta 里若有 `_labels` 也算标签
to_doc(Bin) when is_binary(Bin) ->
    Bin;
to_doc(M) when is_map(M), map_size(M) =:= 0 ->
    #{text => <<>>};
to_doc(#{} = M) when is_map_key(labels, M); is_map_key(props, M) ->
    Labels = norm_labels(maps:get(labels, M, [])),
    Props = norm_props(maps:get(props, M, #{})),
    Text = maps:get(text, M, <<>>),
    is_binary(Text) orelse erlang:error({badarg, {text, Text}}),
    Base = case encode_meta_props(Labels, Props) of
               undefined -> #{text => Text};
               Meta      -> #{text => Text, meta => Meta}
           end,
    case maps:find(vector, M) of
        {ok, V} when V =/= undefined, V =/= null -> Base#{vector => V};
        _                                         -> Base
    end;
to_doc(#{} = Doc) ->
    Doc;
to_doc(Bad) ->
    erlang:error({badarg, {vertex_doc, Bad}}).

%% 写给引擎的值里的标签。
doc_labels(Bin) when is_binary(Bin) -> [];
doc_labels(#{meta := Meta}) when is_binary(Meta) -> labels_from_meta(Meta);
doc_labels(#{}) -> [].

labels_from_meta(undefined) -> [];
labels_from_meta(Meta) when is_binary(Meta) ->
    case safe_decode_meta(Meta) of
        {ok, #{?LABELS := Ls}} when is_list(Ls) -> Ls;
        {ok, #{?LABELS := L}} when is_binary(L) -> [L];
        _                                       -> []
    end.

%% 引擎 get_doc 的结果 → 属性 map（去掉 `_labels`；正文非空且没有同名属性时暴露为 `text`）。
props_from_doc(#{text := Text} = Doc) ->
    P0 = case maps:get(meta, Doc, undefined) of
             undefined -> #{};
             Meta ->
                 case safe_decode_meta(Meta) of
                     {ok, M} -> maps:remove(?LABELS, M);
                     error   -> #{<<"_raw_meta">> => Meta}
                 end
         end,
    P = maps:filter(fun(_K, V) -> V =/= undefined end, P0),
    case Text of
        <<>> -> P;
        _ when is_map_key(<<"text">>, P) -> P;
        _ -> P#{<<"text">> => Text}
    end.

%% get_doc 的结果 → #{labels, properties, vector}（Cypher 执行器用；vector 不进 properties）。
%% meta 只解码一次，标签与属性一遍取出（扫描 / 聚合时每个顶点都走这里）。语义同
%% labels_from_meta/1 + props_from_doc/1。
doc_info(Doc) ->
    Vec = case maps:get(vector, Doc, undefined) of
              V when is_binary(V) -> V;
              _ -> null
          end,
    {Labels, P} = case maps:get(meta, Doc, undefined) of
                      undefined -> {[], #{}};
                      Meta ->
                          case safe_decode_meta(Meta) of
                              {ok, M} -> split_meta(M);
                              error   -> {[], #{<<"_raw_meta">> => Meta}}
                          end
                  end,
    Props = case maps:get(text, Doc, <<>>) of
                <<>> -> P;
                _ when is_map_key(<<"text">>, P) -> P;
                Text -> P#{<<"text">> => Text}
            end,
    #{labels => Labels, properties => Props, vector => Vec}.

split_meta(M) ->
    maps:fold(fun(?LABELS, Ls, {_, Acc}) when is_list(Ls) -> {Ls, Acc};
                 (?LABELS, L, {_, Acc}) when is_binary(L) -> {[L], Acc};
                 (?LABELS, _, A) -> A;
                 (_K, undefined, A) -> A;
                 (K, V, {Ls, Acc}) -> {Ls, Acc#{K => V}}
              end, {[], #{}}, M).

%% {ok, #{id, labels, properties}} | {error, not_found} | {error, _}。只有邻接表、
%% 没有 n 文档的顶点（悬挂端点）也算存在：没有标签、没有属性。
decode_vertex(H, Vid) ->
    case bitcask:get_doc(H, nkey(Vid)) of
        {ok, Doc} ->
            {ok, #{id => Vid,
                   labels => labels_from_meta(maps:get(meta, Doc, undefined)),
                   properties => props_from_doc(Doc)}};
        not_found ->
            case bitcask:get(H, graphdb_adj:head_key(Vid)) of
                {ok, _}        -> {ok, #{id => Vid, labels => [], properties => #{}}};
                not_found      -> {error, not_found};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

vertex_exists(H, Vid) ->
    case bitcask:get_with_ord(H, nkey(Vid)) of
        {ok, _, _} -> true;
        not_found ->
            case bitcask:get_with_ord(H, graphdb_adj:head_key(Vid)) of
                {ok, _, _} -> true;
                _          -> false
            end;
        _ -> false
    end.

%% =========================================================================
%% 标签 / 属性的校验与编码
%% =========================================================================

norm_labels(Ls) when is_list(Ls) ->
    dedupe([norm_label(L) || L <- Ls]);
norm_labels(Bad) ->
    erlang:error({badarg, {labels, Bad}}).

norm_label(L) when is_atom(L), L =/= undefined, L =/= null -> norm_label(atom_to_binary(L));
norm_label(L) when is_binary(L), L =/= <<>>, byte_size(L) < 16#FFFF -> L;
norm_label(Bad) -> erlang:error({badarg, {label, Bad}}).

dedupe(L) ->
    {Out, _} = lists:foldl(fun(X, {Acc, Seen}) ->
                                   case is_map_key(X, Seen) of
                                       true  -> {Acc, Seen};
                                       false -> {[X | Acc], Seen#{X => true}}
                                   end
                           end, {[], #{}}, L),
    lists:reverse(Out).

%% 属性 map：key 转 binary；值为 null / undefined 的键丢掉（= 不存在）；下划线开头的名字
%% 留给实现；值只能是 meta 支持的类型（第 4 节：没有嵌套的列表与映射）。
norm_props(P) when is_map(P) ->
    maps:fold(fun(K0, V, Acc) ->
                      K = norm_key(K0),
                      case V of
                          null      -> Acc;
                          undefined -> Acc;
                          _         -> Acc#{K => check_value(K, V)}
                      end
              end, #{}, P);
norm_props(Bad) ->
    erlang:error({badarg, {props, Bad}}).

norm_key(K) when is_atom(K) -> norm_key(atom_to_binary(K));
norm_key(<<"_", _/binary>> = K) -> erlang:error({badarg, {reserved_property, K}});
norm_key(K) when is_binary(K), K =/= <<>> -> K;
norm_key(Bad) -> erlang:error({badarg, {property_key, Bad}}).

check_value(_K, V) when is_integer(V), V >= -16#8000000000000000, V =< 16#7FFFFFFFFFFFFFFF -> V;
check_value(_K, V) when is_float(V) -> V;
check_value(_K, V) when is_binary(V) -> V;
check_value(_K, V) when is_boolean(V) -> V;
%% 列表：元素同一种类型（字符串 / 整数 / 浮点 / 布尔 / 同一种扩展类型）；空列表可以。
check_value(K, V) when is_list(V) ->
    case list_kind(V) of
        {ok, _} -> V;
        error -> erlang:error({badarg, {unsupported_property_type, K}})
    end;
check_value(K, V) ->
    %% 扩展类型（注册的编解码模块认得的值，如时间 / 空间值）：存成文本 + `_types` 里记类型
    case ext_value(V) of
        true -> V;
        false -> erlang:error({badarg, {unsupported_property_type, K}})
    end.

%% ---- 扩展值类型的编解码挂点 -------------------------------------------------
%% 引擎 meta 只能存标量与字符串数组。别的值（bitcask_cypher 的时间 / 空间值、NaN / Infinity）由上层注册
%% 一个编解码模块，实现 4 个回调：
%%   is_value(V) -> boolean()            这个值归它管吗
%%   type_tag(V) -> binary()             类型标记（记进 `_types`，如 <<"date">>；浮点特殊值用 <<"float">>）
%%   to_text(V) -> binary()              存储文本
%%   from_text(Tag, Text) -> V           读回（Tag = <<"float">> 时只会收到非数字文本，如 <<"NaN">>）
%% 没注册时：写这类值报 unsupported_property_type；读到带这类标记的属性，按存储文本原样返回（数据照样兼容）。
-define(CODEC_KEY, {?MODULE, value_codec}).

-spec register_value_codec(module()) -> ok.
register_value_codec(Mod) when is_atom(Mod) ->
    case persistent_term:get(?CODEC_KEY, undefined) of
        Mod -> ok;
        _ -> persistent_term:put(?CODEC_KEY, Mod)
    end.

-spec unregister_value_codec() -> ok.
unregister_value_codec() ->
    _ = persistent_term:erase(?CODEC_KEY),
    ok.

-spec value_codec() -> module() | undefined.
value_codec() -> persistent_term:get(?CODEC_KEY, undefined).

ext_value(V) ->
    case value_codec() of
        undefined -> false;
        M -> M:is_value(V)
    end.

%% 读回扩展值；没有编解码模块或解不了 → 原样文本。
ext_from(Tag, Text) ->
    case value_codec() of
        undefined -> Text;
        M -> try M:from_text(Tag, Text) catch _:_ -> Text end
    end.

%% 标签 + 属性 → meta blob；两者都空 → undefined（不写 meta）。
encode_meta_props([], P) when map_size(P) =:= 0 -> undefined;
encode_meta_props([], P) -> bitcask:encode_meta(typed_out(P));
encode_meta_props(Labels, P) -> bitcask:encode_meta((typed_out(P))#{?LABELS => Labels}).

%% 扩展值 → 规范文本，`_types` = [<<"属性名\t类型">>]（引擎 meta 只能存标量与字符串数组）。
-define(TYPES, <<"_types">>).

typed_out(P) ->
    {P2, Ts} = maps:fold(fun(K, [_ | _] = V, {Acc, T} = A) ->
                                 %% 非字符串的列表：元素存成文本（字符串数组），`_types` 里记 list:<类型>
                                 case list_kind(V) of
                                     {ok, binary} -> A;
                                     {ok, Kind} ->
                                         {Acc#{K => [elem_text(Kind, X) || X <- V]},
                                          [<<K/binary, "\tlist:", Kind/binary>> | T]};
                                     error -> A
                                 end;
                            (K, V, {Acc, T} = A) ->
                                 case is_number(V) orelse is_binary(V) orelse is_boolean(V) orelse V =:= [] of
                                     true -> A;
                                     false ->
                                         M = value_codec(),
                                         {Acc#{K => M:to_text(V)}, [<<K/binary, "\t", (M:type_tag(V))/binary>> | T]}
                                 end
                         end, {P, []}, P),
    case Ts of
        [] -> P2;
        _ -> P2#{?TYPES => lists:sort(Ts)}
    end.

%% 解码后的 meta：按 `_types` 把文本还原成列表元素 / 扩展值，去掉 `_types`。
typed_in(#{?TYPES := Ts} = M) when is_list(Ts) ->
    lists:foldl(fun(T, Acc) ->
                        case binary:split(T, <<"\t">>) of
                            [K, <<"list:", Kind/binary>>] ->
                                case maps:find(K, Acc) of
                                    {ok, Texts} when is_list(Texts) ->
                                        try Acc#{K => [elem_in(Kind, X) || X <- Texts]}
                                        catch _:_ -> Acc
                                        end;
                                    _ -> Acc
                                end;
                            [K, Tag] ->
                                case maps:find(K, Acc) of
                                    {ok, Text} when is_binary(Text) -> Acc#{K => ext_from(Tag, Text)};
                                    _ -> Acc
                                end;
                            _ -> Acc
                        end
                end, maps:remove(?TYPES, M), Ts);
typed_in(#{?TYPES := _} = M) -> maps:remove(?TYPES, M);
typed_in(M) -> M.

%% 列表属性的元素类型：binary | int | float | bool | 扩展类型标记（同一种）；混合 → error。
list_kind([]) -> {ok, binary};
list_kind([H | _] = L) ->
    Kind = elem_kind(H),
    case Kind =/= error andalso lists:all(fun(X) -> elem_kind(X) =:= Kind end, L) of
        true -> {ok, Kind};
        false -> error
    end.

elem_kind(X) when is_binary(X) -> binary;
elem_kind(X) when is_integer(X), X >= -16#8000000000000000, X =< 16#7FFFFFFFFFFFFFFF -> <<"int">>;
elem_kind(X) when is_float(X) -> <<"float">>;
elem_kind(X) when is_boolean(X) -> <<"bool">>;
elem_kind(X) ->
    case ext_value(X) of
        true -> (value_codec()):type_tag(X);         %% NaN / Infinity 的标记是 <<"float">>，与浮点同类
        false -> error
    end.

elem_text(<<"int">>, X) -> integer_to_binary(X);
elem_text(<<"float">>, X) when is_float(X) -> float_to_binary(X, [short]);
elem_text(<<"bool">>, X) -> atom_to_binary(X);
elem_text(_, X) -> (value_codec()):to_text(X).

elem_in(<<"int">>, T) -> binary_to_integer(T);
elem_in(<<"float">>, T) ->
    try binary_to_float(T) catch error:badarg -> ext_from(<<"float">>, T) end;
elem_in(<<"bool">>, <<"true">>) -> true;
elem_in(<<"bool">>, <<"false">>) -> false;
elem_in(Tag, T) -> ext_from(Tag, T).

%% 边属性：binary 原样（旧用法）；map 走 meta 编码（空 map → <<>>）。
encode_edge_props(B) when is_binary(B) -> B;
encode_edge_props(M) when is_map(M) ->
    P = norm_props(M),
    case map_size(P) of
        0 -> <<>>;
        _ -> bitcask:encode_meta(typed_out(P))
    end;
encode_edge_props(Bad) ->
    erlang:error({badarg, {edge_props, Bad}}).

%% 边属性二进制 → map：空 → #{}；meta 编码 → 解开；别的二进制 → #{<<"_raw">> => B}。
decode_edge_props(<<>>) -> #{};
decode_edge_props(B) when is_binary(B) ->
    case safe_decode_meta(B) of
        {ok, M} -> maps:filter(fun(_K, V) -> V =/= undefined end, M);
        error   -> #{<<"_raw">> => B}
    end.

safe_decode_meta(B) ->
    try {ok, typed_in(bitcask:decode_meta(B))}
    catch _:_ -> error
    end.

%% =========================================================================
%% 标签索引
%% =========================================================================

%% 顶点 Vid 的标签从 Old 变成 New 时要写的索引 op（与顶点文档同批）。
%% =========================================================================
%% 属性索引（二期，设计稿第 4 节）
%%
%% 声明存在一个 key 里：<G> s → term_to_binary([{Label, Prop, building | ready}])。
%% 索引项：<G> x <len16 Label> <len16 Prop> <EncVal> <Vid:64> → <<>>；EncVal 用
%% bitcask_query_index 的保序、自定界编码，只给标量值（整数 / 浮点 / 字符串 / 布尔）建项
%% （列表值在 Cypher 里不会等于任何标量，跳过不影响等值 / 范围查询的完整性）。
%%
%% 维护：每个改顶点标签 / 属性的写入经 index_ops/4 同批增删标签索引项与属性索引项。直通写
%% 在原子批里带 {check, skey(), 读到的版本}：create_index / drop_index 改了声明，读到旧声明的
%% 写入整批冲突、重读重来，所以不会有写入漏维护新索引。事务写经 txn_schema/1（带守卫的读）。
%% =========================================================================

skey() -> << (graphdb_adj:prefix())/binary, "s" >>.

xprefix(Label, Prop) ->
    << (graphdb_adj:prefix())/binary, "x", (byte_size(Label)):16/big, Label/binary,
       (byte_size(Prop)):16/big, Prop/binary >>.

xkey(Label, Prop, Val, Vid) ->
    << (xprefix(Label, Prop))/binary, (bitcask_query_index:enc(Val))/binary, Vid:64/big >>.

%% {Cond, [{Label, Prop, State}]}：Cond 是直通写要带的前置条件（absent | {ord, N}）。
schema(H) ->
    case bitcask:get_with_ord(H, skey()) of
        not_found -> {absent, []};
        {ok, V, Ord} -> {{ord, Ord}, decode_schema(vbin(V))};
        {error, _} = E -> E
    end.

txn_schema(Tx) ->
    %% 声明只由事务外的带条件原子批改写：守卫足够，不拿锁（不改变事务间的锁交织）
    case bitcask_txn:peek_guarded(Tx, skey()) of
        not_found -> [];
        {ok, V} -> decode_schema(vbin(V));
        {error, R} -> bitcask_txn:abort(R)
    end.

decode_schema(B) ->
    try binary_to_term(B, [safe]) of
        L when is_list(L) -> L;
        _ -> []
    catch _:_ -> []
    end.

%% 引擎文档 / to_doc 的结果 / binary / undefined → {标签, 属性}。
doc_lp(#{meta := M}) when is_binary(M) ->
    case safe_decode_meta(M) of
        {ok, Map} -> split_meta(Map);
        error -> {[], #{}}
    end;
doc_lp(_) -> {[], #{}}.

index_scalar(V) when is_integer(V); is_float(V); is_binary(V); is_boolean(V) -> true;
index_scalar(_) -> false.

%% 顶点 Vid 的 {标签, 属性} 从 Old 变成 New 时要写的索引 op（标签索引 + 属性索引）。
index_ops(Decls, Vid, {OL, OP}, {NL, NP}) ->
    label_ops(Vid, OL, NL) ++
        lists:append([prop_index_ops(L, P, Vid, OL, OP, NL, NP) || {L, P, _} <- Decls]).

prop_index_ops(L, P, Vid, OL, OP, NL, NP) ->
    Key = fun(Ls, Ps) ->
                  case lists:member(L, Ls) andalso maps:find(P, Ps) of
                      {ok, V} -> case index_scalar(V) of true -> xkey(L, P, V, Vid); false -> none end;
                      _ -> none
                  end
          end,
    case {Key(OL, OP), Key(NL, NP)} of
        {Same, Same} -> [];
        {Old, New} -> [{remove, Old} || Old =/= none] ++ [{put, New, <<>>} || New =/= none]
    end.

%% 就绪的索引里有没有 (Label, Prop)。
ready_index(Decls, Label, Prop) -> lists:member({Label, Prop, ready}, Decls).

list_indexes(H) ->
    case schema(H) of
        {error, _} = E -> E;
        {_, Decls} -> {ok, [{L, P, S} || {L, P, S} <- Decls]}
    end.

%% 声明 (Label, Prop) 的属性索引并从现有数据建好：先写声明（building）——此后的写入都会维护它，
%% 读到旧声明的在途写入整批冲突重来；再按标签索引逐块补建（每块带顶点版本条件，期间被改的
%% 顶点重读重来）；最后标 ready（规划器只用 ready 的）。已存在 → ok（幂等）。
create_index(H, Label, Prop) ->
    case set_decl(H, fun(Ds) ->
                             case [S || {L, P, S} <- Ds, L =:= Label, P =:= Prop] of
                                 [ready] -> unchanged;
                                 [_] -> Ds;                                   %% building：接着补
                                 [] -> Ds ++ [{Label, Prop, building}]
                             end
                     end, 16) of
        unchanged -> ok;
        ok ->
            case backfill(H, Label, Prop, undefined) of
                ok ->
                    set_decl(H, fun(Ds) -> [case {L, P} of {Label, Prop} -> {L, P, ready}; _ -> D end
                                            || {L, P, _} = D <- Ds] end, 16);
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

%% 删掉声明（此后的写入不再维护）再按前缀删光索引项。
drop_index(H, Label, Prop) ->
    case set_decl(H, fun(Ds) -> [D || {L, P, _} = D <- Ds, {L, P} =/= {Label, Prop}] end, 16) of
        ok -> purge_prefix(H, xprefix(Label, Prop));
        unchanged -> ok;
        {error, _} = E -> E
    end.

set_decl(_H, _F, 0) -> {error, conflict};
set_decl(H, F, N) ->
    case schema(H) of
        {error, _} = E -> E;
        {Cond, Ds} ->
            case F(Ds) of
                unchanged -> unchanged;
                Ds -> ok;
                New ->
                    case bitcask:put_batch_atomic(H, [{put, skey(), term_to_binary(New), Cond}]) of
                        ok -> ok;
                        {error, {conflict, _}} -> set_decl(H, F, N - 1);
                        {error, _} = E -> E
                    end
            end
    end.

backfill(H, Label, Prop, After) ->
    case label_vids(H, Label, {256, After}) of
        {error, _} = E -> E;
        {ok, []} -> ok;
        {ok, Vids} ->
            case backfill_chunk(H, Label, Prop, Vids, 8) of
                ok when length(Vids) < 256 -> ok;
                ok -> backfill(H, Label, Prop, lists:last(Vids));
                {error, _} = E -> E
            end
    end.

backfill_chunk(_H, _L, _P, _Vids, 0) -> {error, conflict};
backfill_chunk(H, L, P, Vids, N) ->
    Ops = lists:append(
            [case bitcask:get_with_ord(H, nkey(Vid)) of
                 {ok, _, Ord} ->
                     {Ls, Ps} = case bitcask:get_doc(H, nkey(Vid)) of {ok, D} -> doc_lp(D); _ -> {[], #{}} end,
                     Put = case lists:member(L, Ls) andalso maps:find(P, Ps) of
                               {ok, V} -> [{put, xkey(L, P, V, Vid), <<>>} || index_scalar(V)];
                               _ -> []
                           end,
                     [{check, nkey(Vid), {ord, Ord}} || Put =/= []] ++ Put;
                 _ -> []
             end || Vid <- Vids]),
    case Ops of
        [] -> ok;
        _ ->
            case bitcask:put_batch_atomic(H, Ops) of
                ok -> ok;
                {error, {conflict, _}} -> backfill_chunk(H, L, P, Vids, N - 1);
                {error, _} = E -> E
            end
    end.

purge_prefix(H, Pre) ->
    Fun = fun(K, _V, _T, _O, Acc) -> [K | Acc] end,
    case bitcask:range_fold(H, {Pre, bitcask:prefix_succ(Pre)}, [{batch, 1024}], Fun, []) of
        {error, _} = E -> E;
        [] -> ok;
        Keys -> purge_keys(H, Keys)
    end.

purge_keys(_H, []) -> ok;
purge_keys(H, Keys) ->
    {Now, Rest} = lists:split(min(1000, length(Keys)), Keys),
    case bitcask:put_batch_atomic(H, [{remove, K} || K <- Now]) of
        ok -> purge_keys(H, Rest);
        {error, _} = E -> E
    end.

%% check_invariants 用：就绪索引的索引项与顶点文档一致。
index_problems(H) ->
    case schema(H) of
        {error, E} -> [{schema_unreadable, E}];
        {_, Decls} ->
            lists:append([index_problems(H, L, P) || {L, P, ready} <- Decls])
    end.

index_problems(H, L, P) ->
    Pre = xprefix(L, P),
    PL = byte_size(Pre),
    Have = case bitcask:range_fold(H, {Pre, bitcask:prefix_succ(Pre)}, [{batch, 1024}],
                                   fun(<<_:PL/binary, Rest/binary>>, _V, _T, _O, Acc) -> [Rest | Acc] end, []) of
               {error, _} -> error;
               Ks -> lists:sort(Ks)
           end,
    Want = case label_vids(H, L, {infinity, undefined}) of
               {ok, Vids} ->
                   lists:sort(lists:append(
                                [case bitcask:get_doc(H, nkey(Vid)) of
                                     {ok, D} ->
                                         {_, Ps} = doc_lp(D),
                                         case maps:find(P, Ps) of
                                             {ok, V} -> [<< (bitcask_query_index:enc(V))/binary, Vid:64/big >>
                                                         || index_scalar(V)];
                                             error -> []
                                         end;
                                     _ -> []
                                 end || Vid <- Vids]));
               _ -> error
           end,
    case Have =:= Want of
        true -> [];
        false -> [{property_index_mismatch, L, P}]
    end.

label_ops(Vid, Old, New) ->
    [{remove, lkey(L, Vid)} || L <- Old, not lists:member(L, New)] ++
    [{put, lkey(L, Vid), <<>>} || L <- New, not lists:member(L, Old)].

%% 带某个标签的顶点 id（升序）。Limit = infinity | N；After = 只要大于它的 id（分页
%% 续扫用，undefined = 从头）。返回 {ok, [Vid]} | {error, _}。
label_vids(H, Label, {Limit, After}) ->
    Pre = label_prefix(Label),
    Lo = case After of
             undefined -> Pre;
             A         -> << Pre/binary, (A + 1):64/big >>
         end,
    Batch = case Limit of infinity -> 256; N -> max(1, min(1024, N)) end,
    PreLen = byte_size(Pre),
    Fun = fun(<< _:PreLen/binary, Vid:64/big >>, _V, _T, _O, {C, Acc}) ->
                  Acc2 = [Vid | Acc],
                  case Limit =/= infinity andalso C + 1 >= Limit of
                      true  -> throw({graphdb_model_lim, Acc2});
                      false -> {C + 1, Acc2}
                  end;
             (_, _, _, _, A) -> A
          end,
    case Limit of
        0 -> {ok, []};
        _ ->
            try bitcask:range_fold(H, {Lo, bitcask:prefix_succ(Pre)}, [{batch, Batch}],
                                   Fun, {0, []}) of
                {error, _} = E -> E;
                {_, Acc}       -> {ok, lists:reverse(Acc)}
            catch throw:{graphdb_model_lim, Acc} -> {ok, lists:reverse(Acc)}
            end
    end.

vbin(#{text := T}) -> T;
vbin(B) when is_binary(B) -> B.

%% =========================================================================
%% 事务里的顶点读写（Cypher 写语句；doc/cypher-query-design-zh.md 第 8 节）
%%
%% 读都经 bitcask_txn 的版本守卫（读集校验），写进事务缓冲、提交时一条原子批。
%% 模型：#{labels, props, text, vector, fields}——props 不含正文（正文是 text 段，
%% 对外暴露为属性 `text`）与向量（vector 段，对外是 `embedding`）。
%% =========================================================================

%% 引擎文档 → 模型。meta 解不开 → error（不覆盖看不懂的数据）。
doc_model(D) ->
    Props = case maps:get(meta, D, undefined) of
                undefined -> {ok, #{}};
                Meta ->
                    case safe_decode_meta(Meta) of
                        {ok, M} -> {ok, maps:filter(fun(_K, V) -> V =/= undefined end,
                                                    maps:remove(?LABELS, M))};
                        error -> error
                    end
            end,
    case Props of
        error -> error;
        {ok, P} ->
            {ok, #{labels => labels_from_meta(maps:get(meta, D, undefined)),
                   props => P,
                   text => case maps:get(text, D, <<>>) of T when is_binary(T) -> T; _ -> <<>> end,
                   vector => maps:get(vector, D, undefined),
                   fields => maps:get(fields, D, #{})}}
    end.

empty_model() -> #{labels => [], props => #{}, text => <<>>, vector => undefined, fields => #{}}.

%% 模型 → 写给引擎的文档 map。
model_doc(#{labels := L, props := P, text := T} = M) ->
    B0 = #{text => T},
    B1 = case encode_meta_props(L, P) of
             undefined -> B0;
             Meta      -> B0#{meta => Meta}
         end,
    B2 = case maps:get(vector, M, undefined) of
             V when is_binary(V) -> B1#{vector => V};
             _                   -> B1
         end,
    case maps:get(fields, M, #{}) of
        Fs when map_size(Fs) =:= 0 -> B2;
        Fs                         -> B2#{fields => Fs}
    end.

%% 事务里分配 id 并建顶点：Build(Vid) -> [{put, K, V} | {remove, K}]，经事务写入。
%% 计数器拿写锁（建顶点的事务在它上面串行）；越过已被占用的 id（n 文档或邻接表头
%% 存在——读的时候登记了「不存在」守卫，直通写者插进来会让事务重跑）。
txn_allocate(Tx, Build) ->
    H = bitcask_txn:handle(Tx),
    CK = ckey(),
    Next = case bitcask_txn:read_guarded(Tx, CK, write) of
               {ok, V} ->
                   case vbin(V) of
                       <<N:72/big>> -> N;
                       _ -> bitcask_txn:abort(bad_vid_counter)
                   end;
               not_found ->
                   case max_vid(H) of
                       {ok, none} -> 1;
                       {ok, M}    -> M + 1;
                       {error, R} -> bitcask_txn:abort(R)
                   end;
               {error, R} -> bitcask_txn:abort(R)
           end,
    Vid = txn_probe(Tx, Next),
    ok = bitcask_txn:write(Tx, CK, enc_counter(Vid + 1)),
    txn_apply(Tx, Build(Vid)),
    {ok, Vid}.

%% 事务里的「指定 id 推高水位」：读计数器（本事务缓冲优先；读锁），vid 不低于它时经事务
%% 写回 vid + 1。不能像直通写那样在事务外推——同一个事务若已分配过 id，它对计数器带着
%% 版本守卫，事务外的写会让守卫失效、事务一直重跑。计数器还没建时不碰。
txn_bump_watermark(Tx, MaxVid) ->
    CK = ckey(),
    case bitcask_txn:read(Tx, CK, read) of
        not_found -> ok;
        {ok, V} ->
            case vbin(V) of
                <<N:72/big>> when MaxVid < N -> ok;
                <<_:72/big>> -> bitcask_txn:write(Tx, CK, enc_counter(MaxVid + 1));
                _ -> bitcask_txn:abort(bad_vid_counter)
            end;
        {error, R} -> bitcask_txn:abort(R)
    end.

txn_probe(_Tx, V) when V > ?VID_MAX -> bitcask_txn:abort(vid_exhausted);
txn_probe(Tx, V) ->
    %% n 文档随后要写：直接拿写锁；邻接表头只看在不在（不写它）：读模式 + 守卫即可
    case {bitcask_txn:read_guarded(Tx, nkey(V), write),
          bitcask_txn:read_guarded(Tx, graphdb_adj:head_key(V), read)} of
        {not_found, not_found} -> V;
        {{error, R}, _} -> bitcask_txn:abort(R);
        {_, {error, R}} -> bitcask_txn:abort(R);
        _ -> txn_probe(Tx, V + 1)
    end.

txn_apply(Tx, Ops) ->
    lists:foreach(fun({put, K, V}) -> ok = bitcask_txn:write(Tx, K, V);
                     ({remove, K}) -> ok = bitcask_txn:delete(Tx, K)
                  end, Ops).

%% 读改写一个顶点：Fun(Model) -> Model。顶点没有 n 文档但有邻接表（悬挂端点）时从空模型
%% 开始；顶点不存在 → {error, not_found}。返回 {ok, Old, New}。
txn_update_vertex(Tx, Vid, Fun) ->
    NK = nkey(Vid),
    Old = case bitcask_txn:read_doc_guarded(Tx, NK, write) of
              {ok, D} ->
                  case doc_model(D) of
                      {ok, M} -> M;
                      error   -> bitcask_txn:abort({bad_vertex_meta, Vid})
                  end;
              not_found ->
                  case bitcask_txn:read_guarded(Tx, graphdb_adj:head_key(Vid), read) of
                      {ok, _}    -> empty_model();
                      not_found  -> not_found;
                      {error, R} -> bitcask_txn:abort(R)
                  end;
              {error, R} -> bitcask_txn:abort(R)
          end,
    case Old of
        not_found -> {error, not_found};
        _ ->
            New = Fun(Old),
            ok = bitcask_txn:write(Tx, NK, model_doc(New)),
            txn_apply(Tx, index_ops(txn_schema(Tx), Vid, {maps:get(labels, Old), maps:get(props, Old)},
                                    {maps:get(labels, New), maps:get(props, New)})),
            {ok, Old, New}
    end.

%% 事务里读顶点（读锁 + 版本守卫）：{ok, #{labels, properties, vector}} | {error, not_found}。
txn_vertex_info(Tx, Vid) ->
    case bitcask_txn:read_doc_guarded(Tx, nkey(Vid), read) of
        {ok, D} -> {ok, doc_info(D)};
        not_found ->
            case txn_vertex_exists(Tx, Vid) of
                true  -> {ok, #{labels => [], properties => #{}, vector => null}};
                false -> {error, not_found}
            end;
        {error, R} -> bitcask_txn:abort(R)
    end.

txn_vertex_exists(Tx, Vid) ->
    case bitcask_txn:read_guarded(Tx, nkey(Vid), read) of
        {ok, _} -> true;
        not_found ->
            case bitcask_txn:read_guarded(Tx, graphdb_adj:head_key(Vid), read) of
                {ok, _}    -> true;
                not_found  -> false;
                {error, R} -> bitcask_txn:abort(R)
            end;
        {error, R} -> bitcask_txn:abort(R)
    end.

