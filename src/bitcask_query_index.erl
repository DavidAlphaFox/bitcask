%% =========================================================================
%% bitcask_query_index
%%
%%   bitcask_query 的二级索引（对应 mnesia:index_read）：按 meta 字段建，
%%   让只有 where 的查询不必全表 range。对外入口在 bitcask_query
%%   （create_index / drop_index / indexes / put / delete），本模块是实现。
%%
%%   === 盘上形态 ===
%%
%%   全部放在同一个 cask 里，用保留前缀和用户 key 隔开：
%%
%%     定义   <<0,"bitcask_query:def:", State, Field>>   State = $b 建索引中 | $r 可用
%%     索引项 <<0,"bitcask_query:ix:", Len:16, Field, EncVal, PK>>
%%
%%   值都是空 binary。索引模式下它们成了「空 text、无 meta」的文档：没有词，
%%   全文检索不会命中；实测也不影响 BM25 打分。状态写在 key 里而不是 value
%%   里，是为了不让 analyzer 去切一段 term_to_binary。
%%
%%   EncVal 保序且自定界（前缀无关），所以 eq/in/gt/gte/lt/lte/exists 都能
%%   直接换成索引键上的 range：
%%     bool    <<1, 0|1>>
%%     integer <<2, (I + 2^63):64/big>>                 翻转符号位
%%     float   <<3, X:64/big>>                          IEEE 保序变换（-0.0 归一成 0.0）
%%     binary  <<4, 转义(0 → 0,255)..., 0, 0>>
%%   null 不进索引（exists 本来就排除 null）。类型标签不同的值互不相等、互不
%%   比较，与引擎 MetaFilter 的语义一致（1 与 1.0 不等；大小比较只在同类型内）。
%%
%%   === 一致性 ===
%%
%%   ⚠️ 不是原子的：libbitcask 的原子批 value 只能是 text，带 meta 的文档进
%%   不了同一批（已报上游 feedbacks/2026-10-06-atomic-batch-doc-meta.md）。所以：
%%     * 写：拿该 key 的写锁（bitcask_txn 的锁管理器），先加新索引项、再写
%%       文档、最后删旧索引项。任何一步之间崩溃，最坏是多出过期的索引项，
%%       不会漏。
%%     * 读：索引项只是候选。每条都 get 文档，核对「文档当前值的编码 == 索引
%%       项里的编码」再求值整个 where——过期项永远不会产出行，也不会产出重复行。
%%   前提：索引字段的写入都走 bitcask_query:put/delete。直接 bitcask:put 改了
%%   meta 的话，新值缺索引项（查不到），旧值的项被读校验挡掉；rebuild 能修。
%% =========================================================================
-module(bitcask_query_index).

-export([create/2, drop/2, list/1, put/3, delete/2,
         ranges/2, entry/2, matches/3, is_reserved/1, field/1]).
-export([enc/1]).                       % 测试用：保序性直接验

-define(DEF_PREFIX, <<0, "bitcask_query:def:">>).
-define(IX_PREFIX,  <<0, "bitcask_query:ix:">>).
-define(CHUNK, 1000).

-define(T_BOOL,  1).
-define(T_INT,   2).
-define(T_FLOAT, 3).
-define(T_BIN,   4).

%% =========================================================================
%% 定义
%% =========================================================================

%% [{Field, building | ready}]
list(H) ->
    case bitcask:range(H, {?DEF_PREFIX, bitcask:prefix_succ(?DEF_PREFIX)}) of
        {error, no_index} -> [];      % 只读打开从未写过的目录：没有索引
        {error, _} = E    -> throw({bitcask_query, error, E});
        KVs ->
            P = byte_size(?DEF_PREFIX),
            [{F, state(S)} || {<<_:P/binary, S, F/binary>>, _} <- KVs]
    end.

state($b) -> building;
state($r) -> ready.

def_key(Field, building) -> <<?DEF_PREFIX/binary, $b, Field/binary>>;
def_key(Field, ready)    -> <<?DEF_PREFIX/binary, $r, Field/binary>>.

field(F) when is_binary(F), F =/= <<>>, byte_size(F) < 65536 -> F;
field(F) when is_atom(F) -> field(atom_to_binary(F, utf8));
field(F) -> throw({bad_query, {field, F}}).

%% 建索引：先登记 building（此后经 bitcask_query:put 的写入就开始维护
%% 索引项），再回填存量，最后转 ready——只有 ready 的索引才会被查询选用。
%% 回填与并发写交错时最坏多出过期项，读校验挡掉。已存在 → ok（幂等）。
create(H, Field0) ->
    Field = field(Field0),
    case proplists:get_value(Field, list(H)) of
        ready -> ok;
        _ ->
            ok = batch(H, [{put, def_key(Field, building), <<>>}]),
            backfill(H, Field),
            batch(H, [{remove, def_key(Field, building)},
                      {put, def_key(Field, ready), <<>>}])
    end.

backfill(H, Field) ->
    Fun = fun(K, #{meta := MB}, Acc) ->
                  case is_reserved(K) of
                      true  -> Acc;
                      false -> flush([{put, E, <<>>} || E <- entries(K, MB, [Field])] ++ Acc,
                                     H, ?CHUNK)
                  end;
             (_K, _V, Acc) -> Acc                 % KV 模式：没有 meta，没有索引项
          end,
    Rest = case bitcask:range_fold(H, {undefined, undefined}, [{want_meta, true}],
                                   fun(K, V, _T, _O, A) -> Fun(K, V, A) end, []) of
               {error, _} = E -> throw({bitcask_query, error, E});
               Acc            -> Acc
           end,
    flush(Rest, H, 1).

flush(Ops, H, Min) when length(Ops) >= Min, Ops =/= [] -> ok = batch(H, Ops), [];
flush(Ops, _H, _Min) -> Ops.

%% 删索引：先撤定义（查询立刻不再选用、写入不再维护），再分块删索引项。
drop(H, Field0) ->
    Field = field(Field0),
    ok = batch(H, [{remove, def_key(Field, S)} || S <- [building, ready]]),
    P = field_prefix(Field),
    Fun = fun(K, _V, _T, _O, Acc) -> flush([{remove, K} | Acc], H, ?CHUNK) end,
    case bitcask:range_fold(H, {P, bitcask:prefix_succ(P)}, [], Fun, []) of
        {error, _} = E -> E;
        Rest           -> flush(Rest, H, 1), ok
    end.

batch(_H, []) -> ok;
batch(H, Ops) ->
    case bitcask:put_batch_atomic(H, Ops) of
        ok             -> ok;
        {error, _} = E -> throw({bitcask_query, error, E})
    end.

is_reserved(<<0, "bitcask_query:", _/binary>>)     -> true;
is_reserved(<<0, "bitcask_txn:idem:", _/binary>>)  -> true;
is_reserved(_)                                      -> false.

%% =========================================================================
%% 写入（维护索引项）
%% =========================================================================

%% Doc 与 bitcask:put 相同的形态。没有任何索引 → 直通 bitcask:put。
put(H, Key, Doc) when is_binary(Key) ->
    reject_reserved(Key),
    case [F || {F, _} <- list(H)] of
        []     -> bitcask:put(H, Key, Doc);
        Fields -> locked(H, Key, fun(Old) -> write(H, Key, Doc, Old, Fields) end)
    end.

delete(H, Key) when is_binary(Key) ->
    reject_reserved(Key),
    case [F || {F, _} <- list(H)] of
        []     -> bitcask:delete(H, Key);
        Fields -> locked(H, Key, fun(Old) -> remove(H, Key, Old, Fields) end)
    end.

reject_reserved(Key) ->
    is_reserved(Key) andalso throw({bad_query, {reserved_key, Key}}).

%% 同一个 key 的索引维护者之间互斥：借 bitcask_txn 拿写锁（只读事务——
%% 缓冲为空，提交时不碰引擎），锁下直接读写引擎。Fun 幂等，锁等待超时导致
%% 重跑也安全。旧值在锁下用 bitcask:get 读（不经 bitcask_txn:read：缓冲
%% 为空时两者等价，而 get 在索引模式下给的是 #{text, meta}）。
locked(H, Key, Fun) ->
    R = bitcask_txn:transaction(
          H, fun(Tx) ->
                     ok = bitcask_txn:lock_key(Tx, Key, write),
                     Old = case bitcask:get(H, Key) of
                               {ok, V}        -> meta_blob(V);
                               not_found      -> undefined;
                               {error, _} = E -> bitcask_txn:abort(E)
                           end,
                     Fun(Old)
             end, [{retries, 10}]),
    case R of
        {atomic, ok}               -> ok;
        {atomic, {error, _} = E}   -> E;
        {aborted, {error, _} = E}  -> E;
        {aborted, Why}             -> {error, Why}
    end.

write(H, Key, tombstone, Old, Fields) ->
    remove(H, Key, Old, Fields);
write(H, Key, Doc, Old, Fields) ->
    NewE = entries(Key, new_meta(Doc), Fields),
    OldE = entries(Key, Old, Fields),
    ok = batch(H, [{put, E, <<>>} || E <- NewE -- OldE]),
    case bitcask:put(H, Key, Doc) of
        ok ->
            ok = batch(H, [{remove, E} || E <- OldE -- NewE]);
        Err ->
            %% 文档没写进去：刚加的项是过期项，读校验会挡掉，不必回滚。
            Err
    end.

remove(H, Key, Old, Fields) ->
    case bitcask:delete(H, Key) of
        ok  -> batch(H, [{remove, E} || E <- entries(Key, Old, Fields)]);
        Err -> Err
    end.

meta_blob(#{meta := MB}) -> MB;
meta_blob(_)             -> undefined.

new_meta(#{meta := MB}) when is_binary(MB) -> MB;
new_meta(_)                                -> undefined.

%% 一篇文档在给定字段上的索引项。坏 meta / 无 meta / 字段为 null → 无项。
entries(_Key, undefined, _Fields) -> [];
entries(Key, MetaBlob, Fields) ->
    case decode(MetaBlob) of
        undefined -> [];
        M -> [<<(field_prefix(F))/binary, (enc(V))/binary, Key/binary>>
              || F <- Fields, (V = maps:get(F, M, undefined)) =/= undefined]
    end.

decode(<<>>) -> undefined;
decode(B) ->
    try bitcask:decode_meta(B)
    catch error:badarg -> undefined
    end.

field_prefix(Field) ->
    <<?IX_PREFIX/binary, (byte_size(Field)):16/big, Field/binary>>.

%% =========================================================================
%% 查询：条件 → 索引键区间；索引项 → {PK, EncVal}；读校验
%% =========================================================================

%% 条件 → 升序、不重叠的 [{Lo, Hi}]（Hi 不含）。
ranges(Field, Cond) ->
    P = field_prefix(Field),
    case Cond of
        exists        -> [{P, bitcask:prefix_succ(P)}];
        %% eq undefined（命中缺失字段）不走索引——规划器不会把它交过来。
        {eq, V} when V =/= undefined -> [eq_range(P, V)];
        %% in 里的 undefined 永远不命中（引擎 In 对缺失字段恒假），直接去掉。
        {in, Vs} -> [eq_range(P, V) || V <- lists:usort(fun(A, B) -> enc(A) =< enc(B) end,
                                                          [V || V <- Vs, V =/= undefined])];
        {Op, V} when is_integer(V); is_float(V) ->
            T = tag(V),
            TLo = <<P/binary, T>>,
            THi = <<P/binary, (T + 1)>>,
            At  = <<P/binary, (enc(V))/binary>>,
            [case Op of
                 gt  -> {bitcask:prefix_succ(At), THi};
                 gte -> {At, THi};
                 lt  -> {TLo, At};
                 lte -> {TLo, bitcask:prefix_succ(At)}
             end];
        {_Op, _V} -> []           % 非数值的大小比较：引擎恒假
    end.

eq_range(P, V) ->
    At = <<P/binary, (enc(V))/binary>>,
    {At, bitcask:prefix_succ(At)}.

%% 索引键 → {PK, EncVal}。
entry(Field, IxKey) ->
    P = field_prefix(Field),
    PL = byte_size(P),
    <<_:PL/binary, Rest/binary>> = IxKey,
    N = enc_len(Rest),
    <<Enc:N/binary, PK/binary>> = Rest,
    {PK, Enc}.

%% 读校验：文档当前在该字段上的值编码后是否就是索引项里那份。
matches(Field, Enc, MetaMap) when is_map(MetaMap) ->
    case maps:get(Field, MetaMap, undefined) of
        undefined -> false;
        V         -> enc(V) =:= Enc
    end;
matches(_Field, _Enc, _) ->
    false.

%% =========================================================================
%% 保序编码
%% =========================================================================

%% 只用于大小比较的区间（只有数值参与）。
tag(V) when is_integer(V) -> ?T_INT;
tag(V) when is_float(V)   -> ?T_FLOAT.

enc(true)  -> <<?T_BOOL, 1>>;
enc(false) -> <<?T_BOOL, 0>>;
enc(I) when is_integer(I) -> <<?T_INT, (I + (1 bsl 63)):64/big>>;
enc(F) when is_float(F) ->
    %% -0.0 与 0.0 在引擎里相等（double ==），编码也要相同。
    <<B:64/big>> = case F == 0.0 of
                       true  -> <<0.0:64/float-big>>;
                       false -> <<F:64/float-big>>
                   end,
    X = case B bsr 63 of
            1 -> (bnot B) band 16#FFFFFFFFFFFFFFFF;    % 负数：全翻
            0 -> B bor (1 bsl 63)                      % 正数：翻符号位
        end,
    <<?T_FLOAT, X:64/big>>;
enc(B) when is_binary(B) ->
    <<?T_BIN, (escape(B))/binary, 0, 0>>.

escape(B) -> binary:replace(B, <<0>>, <<0, 255>>, [global]).

enc_len(<<?T_BOOL, _/binary>>)  -> 2;
enc_len(<<?T_INT, _/binary>>)   -> 9;
enc_len(<<?T_FLOAT, _/binary>>) -> 9;
enc_len(<<?T_BIN, Rest/binary>>) -> 1 + str_len(Rest, 0).

%% 转义后的字符串在 <<0,0>> 处结束（<<0,255>> 是转义的 0）。
str_len(<<0, 0, _/binary>>, N)   -> N + 2;
str_len(<<0, 255, R/binary>>, N) -> str_len(R, N + 2);
str_len(<<_, R/binary>>, N)      -> str_len(R, N + 1).
