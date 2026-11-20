%% =========================================================================
%% graphdb_adj — 当前图层布局（第 1 版）的邻接表：盘上编解码 + 读原语 + 写会话
%%
%% 设计文档：doc/graph-adjacency-pack-design-zh.md（§4 盘上契约、§5 条件写、
%% §6 写路径）。graphdb 是门面（API / 重试 / 遍历 / 事务包装），本模块是它
%% 唯一碰 `a` / `p` 家族字节的地方；graphdb_analytics 复用这里的编解码。
%%
%% ---- Key 家族 ----
%%   <1,"_g:"> a <vid:64>                                  邻接表头（13 B）
%%   <1,"_g:"> a <vid:64> <dir:8> <etype:32> <o:64> <r:64> 分块（34 B）；(o,r)
%%                                                        是块的
%%                                                     **下界**：块 0 恒为 (0,0)，
%%                                                     其后各块 = 建块时的首条。
%%                                                     条目 e 属于下界 ≤ e 的最后
%%                                                     一块。下界在块分裂 / 删除时
%%                                                     才变，删掉块内首条不改 key。
%%   <1,"_g:"> p <src:64> <etype:32> <dst:64> <rank:64>   外置边属性
%%   dir：0 = 出，1 = 入。头 key 是同顶点全部块 key 的前缀。
%%
%% ---- 值 ----
%%   Head  = <<1:8, NGroups:16, Group × NGroups>>，组按 (Dir, Etype) 升序
%%   Group = <<Dir:8, GFlags:8, Etype:32, Count:64, Body>>
%%           Body（内联）= Entry × Count
%%           Body（分块）= <<NChunks:32, <<O:64, R:64>> × NChunks>>（各块下界）
%%   Chunk = <<1:8, GFlags:8, Count:32, Entry × Count>>
%%   GFlags: bit0 has_rank、bit1 has_props、bit2 chunked
%%   Entry = <<O:64>> [<<R:64>>]（has_rank） [<<PLen:16, Props/bytes>>]（has_props）
%%           PLen = 16#FFFF：属性在 p 家族。条目按 (O, R) 升序。
%%   入边条目恒无属性（属性只在出边一侧存一份）。
%%
%% ---- 不变式 ----
%%   1. 对称：(a, t, b, r) 在 a 的出边组 ⟺ 在 b 的入边组，同批写。
%%   2. 头即版本：对一个顶点邻接的任何修改都重写它的头，所以头 key 的 LSN 就是
%%      该顶点（含全部块）的**已提交**版本。libbitcask ≤ 12.0.0 的原子批对读者
%%      不提供读隔离——批内各 key 逐条生效，且按 key 字节序（头 key 是自己块 key 的
%%      前缀 ⇒ 同一顶点总是头先生效、块后生效），并发读者可能读到「新头 + 旧块 /
%%      缺块」；上游 12.0.1（S63）已把整批发布收进一个临界区。写会话仍把前置条件
%%      覆盖整个读集：改过的头、读过的每个块（改了的挂在它的 put / remove 上，
%%      没改的发 check，读到缺失的用 absent），以及会话读过但没改的顶点的头——
%%      即使有人绕过图层协议直写块，读-改-写也不会静默覆盖。一致性读同理：读集
%%      在写锁下用只含 check 的批校验（graphdb consistent_read）。上游反馈
%%      libbitcask feedbacks/2026-11-20-atomic-batch-no-read-isolation.md。
%%   3. Count = 实际条目数；块目录 = 实际存在的块 key。
%%
%% ---- IO 抽象 ----
%%   Io :: {direct, Handle}          直通：读带 LSN，提交走带条件的原子批
%%       | {txn, Tx, read | write}   事务：读走 bitcask_txn（头用 read_guarded，
%%                                   版本由 bitcask_txn 记、提交时自动带条件），
%%                                   写进事务缓冲
%% =========================================================================
-module(graphdb_adj).

-export([prefix/0, range/1, head_key/1, chunk_key/4, group_prefix/3, pkey/4, gkey/0,
         parse_chunk_key/1,
         encode_head/1, decode_head/1, encode_chunk/1, decode_chunk/1,
         default_cfg/0, encode_cfg/1, decode_cfg/1,
         %% 读原语
         entries/5, entries_guarded/5, lookup/6, counts/2,
         %% 写会话
         new_session/2, put_edge/6, del_edge/5, all_entries/2, commit/1, commit/2,
         %% 分析 / 校验用的纯函数
         build_vertex/3, groups_info/1]).

-define(VER, 1).
-define(F_RANK,    1).
-define(F_PROPS,   2).
-define(F_CHUNKED, 4).
-define(PEXT, 16#FFFF).
-define(LB0, {0, 0}).
-define(LAYOUT_VER, 1).
-define(PREFIX, <<16#01, "_g:">>).

-record(grp, {dir      :: 0 | 1,
              etype    :: non_neg_integer(),
              count    :: non_neg_integer(),
              flags = 0 :: non_neg_integer(),        %% 分块组：各块标志的并（只升不降）
              body     :: {entries, [entry()]} | {chunks, [lb()]}}).

-record(vs, {vid      :: non_neg_integer(),
             hcond    :: absent | {ord, non_neg_integer()} | txn,
             existed = false :: boolean(),           %% 读到时头 key 是否存在
             groups = [] :: [#grp{}],
             chunks = #{} :: #{binary() => [entry()]}, %% 已读入的块（key → 条目）
             dirty  = #{} :: #{binary() => true},      %% 要写的块
             dels   = #{} :: #{binary() => true},      %% 要删的块
             orig   = #{} :: #{binary() => true},      %% 读到时盘上已有的块（只给它们发删除）
             rconds = #{} :: #{binary() => absent | {ord, non_neg_integer()}},
                                                       %% 直通读过的块 → 读到时的版本（提交条件）
             extra  = [] :: [term()],                  %% p 家族 op（逆序）
             touched = false :: boolean()}).

-record(sess, {io :: {direct, term()} | {txn, term(), read | write},
               cfg :: map(), vs = #{} :: #{non_neg_integer() => #vs{}}}).

-type entry() :: {non_neg_integer(), non_neg_integer(), binary() | ext}.
-type lb()    :: {non_neg_integer(), non_neg_integer()}.

%% =========================================================================
%% Keys
%% =========================================================================

%% 所有图层 key 的全局命名空间：Ctrl-A "_g:"，避免和应用 KV / 全文索引 key 冲突。
prefix() -> ?PREFIX.

%% 家族扫描区间。Family 只能是单字节家族名（a / p / n / t）。
range(Family) when is_binary(Family), byte_size(Family) =:= 1 ->
    Lo = << ?PREFIX/binary, Family/binary >>,
    {Lo, bitcask:prefix_succ(Lo)}.

head_key(Vid) -> << ?PREFIX/binary, "a", Vid:64/big >>.

chunk_key(Vid, Dir, Etype, {O, R}) ->
    << ?PREFIX/binary, "a", Vid:64/big, Dir:8, Etype:32/big,
       O:64/big, R:64/big >>.

group_prefix(Vid, Dir, Etype) ->
    << ?PREFIX/binary, "a", Vid:64/big, Dir:8, Etype:32/big >>.

pkey(S, T, D, R) ->
    << ?PREFIX/binary, "p", S:64/big, T:32/big, D:64/big, R:64/big >>.

gkey() -> << ?PREFIX/binary, "g" >>.

parse_chunk_key(<< _P:4/binary, "a", Vid:64/big, Dir:8, Etype:32/big,
                   O:64/big, R:64/big >> = K)
  when binary_part(K, 0, 4) =:= ?PREFIX, Dir =< 1 ->
    {ok, Vid, Dir, Etype, {O, R}};
parse_chunk_key(_) ->
    skip.

%% =========================================================================
%% 图参数（记在 `g` 键）
%% =========================================================================

default_cfg() ->
    #{inline_max => 4096, chunk_max => 4096, props_max => 128}.

encode_cfg(#{inline_max := I, chunk_max := C, props_max := P}) ->
    <<?LAYOUT_VER:8, I:32/big, C:32/big, P:16/big>>.

decode_cfg(<<?LAYOUT_VER:8, I:32/big, C:32/big, P:16/big>>) ->
    {ok, #{inline_max => I, chunk_max => C, props_max => P}};
decode_cfg(<<Ver:8, _/binary>>) ->
    {error, {graph_layout, Ver}};
decode_cfg(_) ->
    {error, {graph_layout, unknown}}.

%% =========================================================================
%% 条目编解码
%% =========================================================================

flags_of(Entries) ->
    lists:foldl(fun({_O, R, P}, F) ->
                        F1 = case R of 0 -> F; _ -> F bor ?F_RANK end,
                        case P of <<>> -> F1; _ -> F1 bor ?F_PROPS end
                end, 0, Entries).

enc_entries(Entries, F) ->
    [enc_entry(E, F) || E <- Entries].

enc_entry({O, R, P}, F) ->
    RankPart = case F band ?F_RANK of 0 -> <<>>; _ -> <<R:64/big>> end,
    PropPart = case F band ?F_PROPS of
                   0 -> <<>>;
                   _ when P =:= ext -> <<?PEXT:16/big>>;
                   _ -> <<(byte_size(P)):16/big, P/binary>>
               end,
    <<O:64/big, RankPart/binary, PropPart/binary>>.

entry_size({_O, _R, P}, F) ->
    8 + case F band ?F_RANK of 0 -> 0; _ -> 8 end
      + case F band ?F_PROPS of
            0 -> 0;
            _ when P =:= ext -> 2;
            _ -> 2 + byte_size(P)
        end.

body_size(Entries) ->
    F = flags_of(Entries),
    lists:foldl(fun(E, Acc) -> Acc + entry_size(E, F) end, 0, Entries).

%% 定宽（无属性）组走 binary comprehension；带属性逐条解。
dec_entries(Bin, Count, F) when F band ?F_PROPS =:= 0 ->
    W = case F band ?F_RANK of 0 -> 8; _ -> 16 end,
    case Bin of
        <<Body:(Count * W)/binary, Rest/binary>> ->
            Es = case W of
                     8  -> [{O, 0, <<>>} || <<O:64/big>> <= Body];
                     16 -> [{O, R, <<>>} || <<O:64/big, R:64/big>> <= Body]
                 end,
            {ok, Es, Rest};
        _ ->
            error
    end;
dec_entries(Bin, Count, F) ->
    dec_prop_entries(Bin, Count, F band ?F_RANK =/= 0, []).

dec_prop_entries(Rest, 0, _HasRank, Acc) ->
    {ok, lists:reverse(Acc), Rest};
dec_prop_entries(Bin, N, HasRank, Acc) ->
    case dec_prop_entry(Bin, HasRank) of
        {ok, E, Rest} -> dec_prop_entries(Rest, N - 1, HasRank, [E | Acc]);
        error         -> error
    end.

dec_prop_entry(<<O:64/big, R:64/big, ?PEXT:16/big, Rest/binary>>, true) ->
    {ok, {O, R, ext}, Rest};
dec_prop_entry(<<O:64/big, R:64/big, L:16/big, P:L/binary, Rest/binary>>, true) ->
    {ok, {O, R, P}, Rest};
dec_prop_entry(<<O:64/big, ?PEXT:16/big, Rest/binary>>, false) ->
    {ok, {O, 0, ext}, Rest};
dec_prop_entry(<<O:64/big, L:16/big, P:L/binary, Rest/binary>>, false) ->
    {ok, {O, 0, P}, Rest};
dec_prop_entry(_, _) ->
    error.

%% =========================================================================
%% 头 / 块编解码
%% =========================================================================

%% NGroups 只有 16 位：超了宁可报错也不能截断写坏（一个顶点要有 3 万多种 etype）。
encode_head(Groups) when length(Groups) > 16#FFFF ->
    erlang:error({too_many_groups, length(Groups)});
encode_head(Groups) ->
    iolist_to_binary([<<?VER:8, (length(Groups)):16/big>>
                      | [enc_group(G) || G <- Groups]]).

enc_group(#grp{dir = D, etype = T, count = C, body = {entries, Es}}) ->
    F = flags_of(Es),
    [<<D:8, F:8, T:32/big, C:64/big>> | enc_entries(Es, F)];
enc_group(#grp{dir = D, etype = T, count = C, flags = F0, body = {chunks, Lbs}}) ->
    F = (F0 band (?F_RANK bor ?F_PROPS)) bor ?F_CHUNKED,
    [<<D:8, F:8, T:32/big, C:64/big, (length(Lbs)):32/big>>
     | [<<O:64/big, R:64/big>> || {O, R} <- Lbs]].

decode_head(<<?VER:8, N:16/big, Rest/binary>>) ->
    dec_groups(N, Rest, undefined, []);
decode_head(_) ->
    error.

dec_groups(0, <<>>, _Prev, Acc) ->
    {ok, lists:reverse(Acc)};
dec_groups(0, _Trailing, _Prev, _Acc) ->
    error;
dec_groups(N, <<D:8, F:8, T:32/big, C:64/big, Rest/binary>>, Prev, Acc)
  when D =< 1, C > 0, (Prev =:= undefined orelse {D, T} > Prev) ->
    case F band ?F_CHUNKED of
        0 ->
            case dec_entries(Rest, C, F) of
                {ok, Es, Rest2} ->
                    dec_groups(N - 1, Rest2, {D, T},
                               [#grp{dir = D, etype = T, count = C, flags = F,
                                     body = {entries, Es}} | Acc]);
                error ->
                    error
            end;
        _ ->
            case Rest of
                <<NC:32/big, Dir:(NC * 16)/binary, Rest2/binary>> when NC > 0 ->
                    Lbs = [{O, R} || <<O:64/big, R:64/big>> <= Dir],
                    case hd(Lbs) =:= ?LB0 of
                        true ->
                            dec_groups(N - 1, Rest2, {D, T},
                                       [#grp{dir = D, etype = T, count = C,
                                             flags = F band (?F_RANK bor ?F_PROPS),
                                             body = {chunks, Lbs}} | Acc]);
                        false ->
                            error
                    end;
                _ ->
                    error
            end
    end;
dec_groups(_N, _Bin, _Prev, _Acc) ->
    error.

encode_chunk(Entries) ->
    F = flags_of(Entries),
    iolist_to_binary([<<?VER:8, F:8, (length(Entries)):32/big>> | enc_entries(Entries, F)]).

decode_chunk(<<?VER:8, F:8, C:32/big, Rest/binary>>) ->
    case dec_entries(Rest, C, F) of
        {ok, Es, <<>>} -> {ok, Es};
        _              -> error
    end;
decode_chunk(_) ->
    error.

%% =========================================================================
%% IO
%% =========================================================================

%% 头：{ok, Bin, Cond} | {absent, Cond} | {error, _}。直通模式 Cond 是
%% {ord, N} / absent；事务模式恒为 txn（版本由 bitcask_txn 守卫）。
io_head({direct, H}, K) ->
    case bitcask:get_with_ord(H, K) of
        {ok, V, Ord}   -> {ok, vbin(V), {ord, Ord}};
        not_found      -> {absent, absent};
        {error, _} = E -> E
    end;
io_head({txn, Tx, Lock}, K) ->
    case bitcask_txn:read_guarded(Tx, K, Lock) of
        {ok, V}         -> {ok, vbin(V), txn};
        not_found       -> {absent, txn};
        {error, Reason} -> bitcask_txn:abort(Reason)
    end.

%% 前缀扫描（只用于直通读分块组；事务里按块目录点读）：Fun(K, V, Acc) -> Acc；
%% 可 throw({graphdb_adj_stop, Acc}) 提前停。
io_fold({direct, H}, Prefix, Fun, Acc0) ->
    Wrapped = fun(K, V, _T, _O, A) -> Fun(K, vbin(V), A) end,
    try bitcask:range_fold(H, {Prefix, bitcask:prefix_succ(Prefix)}, [], Wrapped, Acc0)
    catch throw:{graphdb_adj_stop, Acc} -> Acc
    end.

%% ok | conflict | {error, _}
io_commit(_Io, []) ->
    ok;
io_commit({direct, H}, Ops) ->
    case bitcask:put_batch_atomic(H, Ops) of
        ok                     -> ok;
        {error, {conflict, _}} -> conflict;
        {error, _} = E         -> E
    end;
io_commit({txn, Tx, _Lock}, Ops) ->
    lists:foreach(fun({put, K, V, _C}) -> ok = bitcask_txn:write(Tx, K, V);
                     ({put, K, V})     -> ok = bitcask_txn:write(Tx, K, V);
                     ({remove, K, _C}) -> ok = bitcask_txn:delete(Tx, K);
                     ({remove, K})     -> ok = bitcask_txn:delete(Tx, K);
                     ({check, _K, _C}) -> ok      %% 头版本已由 read_guarded 守卫
                  end, Ops).

%% 索引模式下引擎回的是 #{text, meta}：邻接值只取 text 段。
vbin(#{text := T}) -> T;
vbin(B) when is_binary(B) -> B.

%% =========================================================================
%% 读原语
%% =========================================================================

%% 顶点 Vid 在 Dir 方向的条目：[{Etype, Other, Rank, Props}]，组序 × 条目序。
%% Etype = undefined 取全部类型；Limit = infinity | N。Props 可能是 ext
%% （属性在 p 家族，由调用方按需解析）。
entries(Io, Vid, Dir, Etype, Limit) ->
    case load(Io, Vid) of
        {error, _} = E -> E;
        {ok, Vs} ->
            Gs = [G || #grp{dir = D, etype = T} = G <- Vs#vs.groups,
                       D =:= Dir, Etype =:= undefined orelse T =:= Etype],
            collect_groups(Io, Vid, Gs, Limit, [])
    end.

collect_groups(_Io, _Vid, _Gs, 0, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
collect_groups(_Io, _Vid, [], _Limit, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
collect_groups(Io, Vid, [#grp{etype = T, body = {entries, Es}} | Gs], Limit, Acc) ->
    Taken = take(Es, Limit),
    collect_groups(Io, Vid, Gs, dec_limit(Limit, length(Taken)),
                   [[{T, O, R, P} || {O, R, P} <- Taken] | Acc]);
collect_groups({txn, _, _} = Io, Vid, [#grp{dir = D, etype = T, body = {chunks, Lbs}} | Gs],
               Limit, Acc) ->
    %% 事务里按头的块目录逐块点读（经事务缓冲、点锁），不拿前缀锁：持有头的锁即
    %% 覆盖它名下全部块（§8）。
    case load_group_chunks(Io, #vs{vid = Vid, hcond = txn}, Vid, D, T, Lbs) of
        {error, _} = E -> E;
        {ok, All, _} ->
            Es = take(All, Limit),
            collect_groups(Io, Vid, Gs, dec_limit(Limit, length(Es)),
                           [[{T, O, R, P} || {O, R, P} <- Es] | Acc])
    end;
collect_groups(Io, Vid, [#grp{dir = D, etype = T, body = {chunks, _}} | Gs], Limit, Acc) ->
    case read_chunks(Io, Vid, D, T, Limit) of
        {error, _} = E -> E;
        Es ->
            collect_groups(Io, Vid, Gs, dec_limit(Limit, length(Es)),
                           [[{T, O, R, P} || {O, R, P} <- Es] | Acc])
    end.

%% 同 entries/5，但分块组按头的块目录逐块点读并记下每个读到的 key 的版本：
%% {ok, Entries, Checks}，Checks = [{check, Key, Cond}]（头 + 读过的块）。调用方
%% 在引擎写锁下用只含 check 的原子批校验 Checks 仍是当前版本，即得一致快照
%% （graphdb consistent_read；读集校验还能挡住绕过图层协议直写块的写入者，
%% 见不变式 2）。
%% 只用于直通模式。
entries_guarded({direct, _} = Io, Vid, Dir, Etype, Limit) ->
    case load(Io, Vid) of
        {error, _} = E -> E;
        {ok, Vs0} ->
            Gs = [G || #grp{dir = D, etype = T} = G <- Vs0#vs.groups,
                       D =:= Dir, Etype =:= undefined orelse T =:= Etype],
            case guarded_groups(Io, Vs0, Gs, Limit, []) of
                {error, _} = E -> E;
                {ok, Es, #vs{vid = V, hcond = HC, rconds = RC}} ->
                    {ok, Es, [{check, head_key(V), HC} |
                              [{check, K, C} || {K, C} <- lists:sort(maps:to_list(RC))]]}
            end
    end.

guarded_groups(_Io, Vs, _Gs, 0, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Vs};
guarded_groups(_Io, Vs, [], _Limit, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Vs};
guarded_groups(Io, Vs, [#grp{etype = T, body = {entries, Es}} | Gs], Limit, Acc) ->
    Taken = take(Es, Limit),
    guarded_groups(Io, Vs, Gs, dec_limit(Limit, length(Taken)),
                   [[{T, O, R, P} || {O, R, P} <- Taken] | Acc]);
guarded_groups(Io, Vs, [#grp{dir = D, etype = T, body = {chunks, Lbs}} | Gs], Limit, Acc) ->
    case guarded_chunks(Io, Vs, D, T, Lbs, Limit, []) of
        {error, _} = E -> E;
        {ok, Es, Vs1} ->
            guarded_groups(Io, Vs1, Gs, dec_limit(Limit, length(Es)),
                           [[{T, O, R, P} || {O, R, P} <- Es] | Acc])
    end.

guarded_chunks(_Io, Vs, _D, _T, _Lbs, 0, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Vs};
guarded_chunks(_Io, Vs, _D, _T, [], _Limit, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Vs};
guarded_chunks(Io, #vs{vid = Vid} = Vs, D, T, [Lb | Lbs], Limit, Acc) ->
    case get_chunk(Io, Vs, chunk_key(Vid, D, T, Lb)) of
        {error, _} = E -> E;
        {ok, Es, Vs1}  ->
            Taken = take(Es, Limit),
            guarded_chunks(Io, Vs1, D, T, Lbs, dec_limit(Limit, length(Taken)), [Taken | Acc])
    end.

%% 一个分块组的全部条目（块按 key 序 = 下界序 = 条目序）。Limit 到了就停扫。
read_chunks(Io, Vid, Dir, Etype, Limit) ->
    Prefix = group_prefix(Vid, Dir, Etype),
    Fun = fun(K, V, {N, Acc}) ->
                  case {byte_size(K), decode_chunk(V)} of
                      {34, {ok, Es}} ->
                          Taken = take(Es, dec_limit(Limit, N)),
                          N2 = N + length(Taken),
                          Acc2 = lists:reverse(Taken, Acc),
                          case Limit =/= infinity andalso N2 >= Limit of
                              true  -> throw({graphdb_adj_stop, {N2, Acc2}});
                              false -> {N2, Acc2}
                          end;
                      {34, error} ->
                          throw({graphdb_adj_stop, {error, {bad_adj_chunk, K}}});
                      _ ->
                          {N, Acc}
                  end
          end,
    case io_fold(Io, Prefix, Fun, {0, []}) of
        {error, _} = E -> E;
        {_N, Acc}      -> lists:reverse(Acc)
    end.

take(L, infinity) -> L;
take(L, N)        -> lists:sublist(L, N).

dec_limit(infinity, _) -> infinity;
dec_limit(N, K)        -> max(0, N - K).

%% 点查一条条目：{ok, Props} | not_found | {error, _}。
lookup(Io, Vid, Dir, Etype, Other, Rank) ->
    case load(Io, Vid) of
        {error, _} = E -> E;
        {ok, Vs} ->
            case get_entry(Io, Vs, Dir, Etype, Other, Rank) of
                {ok, none, _}  -> not_found;
                {ok, P, _}     -> {ok, P};
                {error, _} = E -> E
            end
    end.

%% 各组的 {Dir, Etype, Count}。
counts(Io, Vid) ->
    case load(Io, Vid) of
        {error, _} = E -> E;
        {ok, Vs}       -> {ok, [{D, T, C} || #grp{dir = D, etype = T, count = C} <- Vs#vs.groups]}
    end.

%% =========================================================================
%% 顶点状态
%% =========================================================================

load(Io, Vid) ->
    case io_head(Io, head_key(Vid)) of
        {ok, Bin, Cond} ->
            case decode_head(Bin) of
                {ok, Gs} -> {ok, #vs{vid = Vid, hcond = Cond, existed = true, groups = Gs,
                                     orig = chunk_keys_of(Vid, Gs)}};
                error    -> {error, {bad_adj, Vid}}
            end;
        {absent, Cond} ->
            {ok, #vs{vid = Vid, hcond = Cond}};
        {error, _} = E ->
            E
    end.

chunk_keys_of(Vid, Gs) ->
    maps:from_list([{chunk_key(Vid, D, T, Lb), true}
                    || #grp{dir = D, etype = T, body = {chunks, Lbs}} <- Gs, Lb <- Lbs]).

find_group([#grp{dir = D, etype = T} = G | _], D, T) -> {ok, G};
find_group([_ | Gs], D, T) -> find_group(Gs, D, T);
find_group([], _D, _T) -> none.

store_group(Gs, #grp{dir = D, etype = T} = G) ->
    store_group(Gs, {D, T}, G, []).

store_group([#grp{dir = D, etype = T} | Gs], {D, T}, G, Acc) ->
    lists:reverse(Acc, [G | Gs]);
store_group([#grp{dir = D, etype = T} = H | Gs], Key, G, Acc) when {D, T} < Key ->
    store_group(Gs, Key, G, [H | Acc]);
store_group(Gs, _Key, G, Acc) ->
    lists:reverse(Acc, [G | Gs]).

drop_group(Gs, D, T) ->
    [G || #grp{dir = D2, etype = T2} = G <- Gs, {D2, T2} =/= {D, T}].

%% 有序条目表上的查 / 写 / 删（按 (O, R)）。
ent_find([{O, R, P} | _], O, R) -> {ok, P};
ent_find([{O2, R2, _} | Es], O, R) when {O2, R2} < {O, R} -> ent_find(Es, O, R);
ent_find(_, _O, _R) -> none.

ent_put(Es, {O, R, _} = E) -> ent_put(Es, O, R, E, []).

ent_put([{O, R, Old} | Es], O, R, E, Acc) ->
    {Old, lists:reverse(Acc, [E | Es])};
ent_put([{O2, R2, _} = H | Es], O, R, E, Acc) when {O2, R2} < {O, R} ->
    ent_put(Es, O, R, E, [H | Acc]);
ent_put(Es, _O, _R, E, Acc) ->
    {none, lists:reverse(Acc, [E | Es])}.

ent_del(Es, O, R) -> ent_del(Es, O, R, []).

ent_del([{O, R, Old} | Es], O, R, Acc) -> {Old, lists:reverse(Acc, Es)};
ent_del([{O2, R2, _} = H | Es], O, R, Acc) when {O2, R2} < {O, R} ->
    ent_del(Es, O, R, [H | Acc]);
ent_del(Es, _O, _R, Acc) -> {none, lists:reverse(Acc, Es)}.

%% 下界表里最后一个 ≤ Key 的下界（块 0 恒为 (0, 0)，必有）。
locate_lb([Lb | Lbs], Key) -> locate_lb(Lbs, Key, Lb).
locate_lb([Lb | Lbs], Key, _Cur) when Lb =< Key -> locate_lb(Lbs, Key, Lb);
locate_lb(_, _Key, Cur) -> Cur.

%% 读块（会话内缓存），带版本：直通记进 rconds（提交时作条件），事务经
%% read_guarded 由 bitcask_txn 登记。块 key 缺失按空块处理并标脏（自愈成真实
%% 空块）：真缺失时 absent 条件允许自愈写成真实空块；若块随后被任何人补上
%% （例如绕过图层协议直写，或 libbitcask ≤ 12.0.0 那种「新头已生效、新块还没
%% 生效」的交错），提交时 absent 条件必然不成立，这次计算整个作废重来，不会把
%% 别人刚写的块覆盖成空。
get_chunk(Io, #vs{chunks = Cs} = Vs, Key) ->
    case maps:find(Key, Cs) of
        {ok, Es} -> {ok, Es, Vs};
        error ->
            case io_head(Io, Key) of
                {ok, Bin, Cond} ->
                    case decode_chunk(Bin) of
                        {ok, Es} -> {ok, Es, rcond(Vs#vs{chunks = Cs#{Key => Es}}, Key, Cond)};
                        error    -> {error, {bad_adj_chunk, Key}}
                    end;
                {absent, Cond} ->
                    Vs1 = rcond(Vs#vs{chunks = Cs#{Key => []},
                                      dirty = (Vs#vs.dirty)#{Key => true}}, Key, Cond),
                    {ok, [], touch(Vs1)};
                {error, _} = E ->
                    E
            end
    end.

rcond(Vs, _Key, txn) -> Vs;
rcond(#vs{rconds = RC} = Vs, Key, Cond) -> Vs#vs{rconds = RC#{Key => Cond}}.

set_chunk(#vs{chunks = Cs, dirty = Dy, dels = Ds} = Vs, Key, Es) ->
    Vs#vs{chunks = Cs#{Key => Es}, dirty = Dy#{Key => true}, dels = maps:remove(Key, Ds)}.

del_chunk(#vs{chunks = Cs, dirty = Dy, dels = Ds} = Vs, Key) ->
    Vs#vs{chunks = maps:remove(Key, Cs), dirty = maps:remove(Key, Dy), dels = Ds#{Key => true}}.

%% {ok, Props | none, Vs'} | {error, _}
get_entry(Io, #vs{vid = Vid, groups = Gs} = Vs, Dir, T, O, R) ->
    case find_group(Gs, Dir, T) of
        none -> {ok, none, Vs};
        {ok, #grp{body = {entries, Es}}} ->
            {ok, found(ent_find(Es, O, R)), Vs};
        {ok, #grp{body = {chunks, Lbs}}} ->
            Key = chunk_key(Vid, Dir, T, locate_lb(Lbs, {O, R})),
            case get_chunk(Io, Vs, Key) of
                {ok, Es, Vs1}  -> {ok, found(ent_find(Es, O, R)), Vs1};
                {error, _} = E -> E
            end
    end.

found({ok, P}) -> P;
found(none)    -> none.

%% upsert：{ok, Old | none, Vs'} | {error, _}
put_entry(Io, #vs{vid = Vid, groups = Gs} = Vs, Dir, T, O, R, P) ->
    E = {O, R, P},
    case find_group(Gs, Dir, T) of
        none ->
            G = #grp{dir = Dir, etype = T, count = 1, body = {entries, [E]}},
            {ok, none, touch(Vs#vs{groups = store_group(Gs, G)})};
        {ok, #grp{count = C, body = {entries, Es}} = G} ->
            {Old, Es2} = ent_put(Es, E),
            G2 = G#grp{count = C + new(Old), body = {entries, Es2}},
            {ok, Old, touch(Vs#vs{groups = store_group(Gs, G2)})};
        {ok, #grp{count = C, flags = F, body = {chunks, Lbs}} = G} ->
            Key = chunk_key(Vid, Dir, T, locate_lb(Lbs, {O, R})),
            case get_chunk(Io, Vs, Key) of
                {ok, Es, Vs1} ->
                    {Old, Es2} = ent_put(Es, E),
                    G2 = G#grp{count = C + new(Old), flags = F bor flags_of([E])},
                    Vs2 = set_chunk(Vs1#vs{groups = store_group(Gs, G2)}, Key, Es2),
                    {ok, Old, touch(Vs2)};
                {error, _} = Err ->
                    Err
            end
    end.

new(none) -> 1;
new(_)    -> 0.

%% {ok, Old | none, Vs'} | {error, _}；条目不存在时 Vs 不标脏。
del_entry(Io, #vs{vid = Vid, groups = Gs} = Vs, Dir, T, O, R) ->
    case find_group(Gs, Dir, T) of
        none -> {ok, none, Vs};
        {ok, #grp{count = C, body = {entries, Es}} = G} ->
            case ent_del(Es, O, R) of
                {none, _} -> {ok, none, Vs};
                {Old, []} -> {ok, Old, touch(Vs#vs{groups = drop_group(Gs, Dir, T)})};
                {Old, Es2} ->
                    G2 = G#grp{count = C - 1, body = {entries, Es2}},
                    {ok, Old, touch(Vs#vs{groups = store_group(Gs, G2)})}
            end;
        {ok, #grp{count = C, body = {chunks, Lbs}} = G} ->
            Key = chunk_key(Vid, Dir, T, locate_lb(Lbs, {O, R})),
            case get_chunk(Io, Vs, Key) of
                {ok, Es, Vs1} ->
                    case ent_del(Es, O, R) of
                        {none, _} -> {ok, none, Vs1};
                        {Old, Es2} ->
                            G2 = G#grp{count = C - 1},
                            Vs2 = set_chunk(Vs1#vs{groups = store_group(Gs, G2)}, Key, Es2),
                            {ok, Old, touch(Vs2)}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

touch(Vs) -> Vs#vs{touched = true}.

%% 全部条目（读入全部块）：{ok, [{Dir, Etype, O, R, P}], Vs'} | {error, _}
vs_all_entries(Io, #vs{vid = Vid, groups = Gs} = Vs0) ->
    case lists:foldl(
      fun(_G, {error, _} = E) -> E;
         (#grp{dir = D, etype = T, body = {entries, Es}}, {ok, Acc, Vs}) ->
              {ok, [[{D, T, O, R, P} || {O, R, P} <- Es] | Acc], Vs};
         (#grp{dir = D, etype = T, body = {chunks, Lbs}}, {ok, Acc, Vs}) ->
              case load_group_chunks(Io, Vs, Vid, D, T, Lbs) of
                  {ok, Es, Vs2}  -> {ok, [[{D, T, O, R, P} || {O, R, P} <- Es] | Acc], Vs2};
                  {error, _} = E -> E
              end
      end, {ok, [], Vs0}, Gs)
    of
        {ok, Acc, Vs} -> {ok, lists:append(lists:reverse(Acc)), Vs};
        {error, _} = E -> E
    end.

load_group_chunks(Io, Vs0, Vid, D, T, Lbs) ->
    lists:foldl(fun(_Lb, {error, _} = E) -> E;
                   (Lb, {ok, Acc, Vs}) ->
                        case get_chunk(Io, Vs, chunk_key(Vid, D, T, Lb)) of
                            {ok, Es, Vs2}  -> {ok, Acc ++ Es, Vs2};
                            {error, _} = E -> E
                        end
                end, {ok, [], Vs0}, Lbs).

%% =========================================================================
%% 收尾：分块维护 + 生成 op
%% =========================================================================

%% {ok, Ops, Vs'} | {error, _}
finalize(Io, #vs{touched = false} = Vs, Cfg) ->
    %% all_entries/2 只读（用于 del_vertex）也可能修复过 chunk 状态：读非块 0
    %% 的空块时会把“头目录里有、盘上没有”的块补成真实空块并标脏。此时头尚未
    %% 被标 touched，仍必须把这类自愈块提交，否则下次读到坏块。
    case maps:size(Vs#vs.dirty) =/= 0 orelse maps:size(Vs#vs.dels) =/= 0 of
        false -> {ok, [], Vs};
        true  ->
            case normalize_chunked(Vs, Cfg) of
                #vs{dirty = Dy} = Vs1 when map_size(Dy) =:= 0, map_size(Vs1#vs.dels) =:= 0 ->
                    {ok, [], Vs1};
                Vs1 ->
                    Vs2 = Vs1#vs{touched = true},
                    case unchunk_small(Io, Vs2, Cfg) of
                        {error, _} = E -> E;
                        {ok, Vs3} ->
                            Vs4 = chunk_oversized(Vs3, Cfg),
                            {ok, emit_ops(Vs4), Vs4}
                    end
            end
    end;
finalize(_Io, #vs{vid = Vid, groups = Gs}, _Cfg) when length(Gs) > 16#FFFF ->
    {error, {too_many_groups, Vid}};
finalize(Io, Vs0, Cfg) ->
    Vs1 = normalize_chunked(Vs0, Cfg),
    case unchunk_small(Io, Vs1, Cfg) of
        {error, _} = E -> E;
        {ok, Vs2} ->
            Vs3 = chunk_oversized(Vs2, Cfg),
            {ok, emit_ops(Vs3), Vs3}
    end.

%% 分块组：脏块过大 → 分裂；空块（非块 0）→ 删；组空 → 删组与全部块。
normalize_chunked(#vs{groups = Gs} = Vs0, Cfg) ->
    lists:foldl(fun(#grp{body = {chunks, _}} = G, Vs) -> normalize_group(G, Vs, Cfg);
                   (_, Vs) -> Vs
                end, Vs0, Gs).

normalize_group(#grp{dir = D, etype = T, count = 0, body = {chunks, Lbs}}, #vs{vid = Vid} = Vs, _Cfg) ->
    Vs1 = lists:foldl(fun(Lb, A) -> del_chunk(A, chunk_key(Vid, D, T, Lb)) end, Vs, Lbs),
    Vs1#vs{groups = drop_group(Vs1#vs.groups, D, T)};
normalize_group(#grp{dir = D, etype = T, count = C, body = {chunks, Lbs}} = G,
                #vs{vid = Vid} = Vs0, Cfg) ->
    Max = eff_chunk_max(C, Cfg),
    {Lbs2, Vs2} =
        lists:foldl(
          fun(Lb, {AccLbs, Vs}) ->
                  Key = chunk_key(Vid, D, T, Lb),
                  case maps:is_key(Key, Vs#vs.dirty) of
                      false ->
                          {[Lb | AccLbs], Vs};
                      true ->
                          Es = maps:get(Key, Vs#vs.chunks),
                          case Es of
                              [] when Lb =/= ?LB0 ->
                                  {AccLbs, del_chunk(Vs, Key)};
                              _ ->
                                  case split_balanced(Es, Max) of
                                      [_] ->
                                          {[Lb | AccLbs], Vs};
                                      [First | More] ->
                                          VsA = set_chunk(Vs, Key, First),
                                          {NewLbs, VsB} =
                                              lists:foldl(
                                                fun([{O, R, _} | _] = Piece, {L, VV}) ->
                                                        NLb = {O, R},
                                                        {[NLb | L],
                                                         set_chunk(VV, chunk_key(Vid, D, T, NLb), Piece)}
                                                end, {[], VsA}, More),
                                          {NewLbs ++ [Lb | AccLbs], VsB}
                                  end
                          end
                  end
          end, {[], Vs0}, Lbs),
    G2 = G#grp{body = {chunks, lists:reverse(Lbs2)}},
    Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}.

%% 单块值上限：超大组放宽到 组字节 / 1024，让块目录保持在约 1024 项内（§4.3）。
eff_chunk_max(Count, #{chunk_max := CM}) ->
    max(CM, (Count * 8) div 1024).

%% 已有块超限：切成 n = max(2, ⌈字节/Max⌉) 片、每片约等大（对半分裂的推广）。
%% 只超一点点时就是对半分，随机插入下两半各有余量，不会下一条又分裂。
split_balanced(Es, Max) ->
    Size = 6 + body_size(Es),
    case Size =< Max of
        true  -> [Es];
        false ->
            N = max(2, (Size + Max - 1) div Max),
            split_entries(Es, Size div N + 1)
    end.

%% 按字节贪心切片（块头 6 B）；每片至少一条。
split_entries(Es, Max) ->
    F = flags_of(Es),
    split_entries(Es, F, Max, 6, [], []).

split_entries([], _F, _Max, _Sz, Cur, Acc) ->
    lists:reverse([lists:reverse(Cur) | Acc]);
split_entries([E | Es], F, Max, Sz, Cur, Acc) ->
    ESz = entry_size(E, F),
    case Cur =/= [] andalso Sz + ESz > Max of
        true  -> split_entries(Es, F, Max, 6 + ESz, [E], [lists:reverse(Cur) | Acc]);
        false -> split_entries(Es, F, Max, Sz + ESz, [E | Cur], Acc)
    end.

%% 分块组缩到 inline_max / 4 以下 → 转回内联（滞回：分块门是头 > inline_max）。
unchunk_small(Io, #vs{groups = Gs} = Vs0, #{inline_max := IM}) ->
    Thresh = IM div 4,
    lists:foldl(
      fun(_G, {error, _} = E) -> E;
         (#grp{dir = D, etype = T, count = C, flags = F, body = {chunks, Lbs}} = G, {ok, Vs}) ->
              MinW = 8 + case F band ?F_RANK of 0 -> 0; _ -> 8 end
                       + case F band ?F_PROPS of 0 -> 0; _ -> 2 end,
              case C * MinW < Thresh of
                  false -> {ok, Vs};
                  true ->
                      case load_group_chunks(Io, Vs, Vs#vs.vid, D, T, Lbs) of
                          {error, _} = E -> E;
                          {ok, Es, Vs1} ->
                              case body_size(Es) < Thresh of
                                  false -> {ok, Vs1};
                                  true ->
                                      Vs2 = lists:foldl(
                                              fun(Lb, A) ->
                                                      del_chunk(A, chunk_key(Vs1#vs.vid, D, T, Lb))
                                              end, Vs1, Lbs),
                                      G2 = G#grp{flags = 0, body = {entries, Es}},
                                      {ok, Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}}
                              end
                      end
              end;
         (_, Acc) -> Acc
      end, {ok, Vs0}, Gs).

%% 头超过 inline_max → 把最大的内联组转为分块，直到放得下或没有可转的组
%% （只转体积 > inline_max / 4 的组，与 unchunk_small 的门槛构成滞回）。
chunk_oversized(#vs{groups = Gs} = Vs, #{inline_max := IM} = Cfg) ->
    case byte_size(encode_head(Gs)) =< IM of
        true -> Vs;
        false ->
            Cands = [{body_size(Es), G} || #grp{body = {entries, Es}} = G <- Gs,
                                           length(Es) >= 2],
            case [X || {Sz, _} = X <- Cands, Sz > IM div 4] of
                [] -> Vs;
                Big ->
                    {_, G} = lists:max(Big),
                    chunk_oversized(chunkify(Vs, G, Cfg), Cfg)
            end
    end.

chunkify(#vs{vid = Vid} = Vs0, #grp{dir = D, etype = T, count = C, body = {entries, Es}} = G, Cfg) ->
    [First | More] = split_entries(Es, eff_chunk_max(C, Cfg)),
    Vs1 = set_chunk(Vs0, chunk_key(Vid, D, T, ?LB0), First),
    {Lbs, Vs2} = lists:foldl(fun([{O, R, _} | _] = Piece, {L, V}) ->
                                     {[{O, R} | L], set_chunk(V, chunk_key(Vid, D, T, {O, R}), Piece)}
                             end, {[], Vs1}, More),
    G2 = G#grp{flags = flags_of(Es), body = {chunks, [?LB0 | lists:reverse(Lbs)]}},
    Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}.

%% 头 op（带条件）+ 块删除 + 块写入 + p 家族 op。
emit_ops(#vs{vid = Vid, hcond = Cond, existed = Existed, groups = Gs,
             chunks = Cs, dirty = Dy, dels = Ds, orig = Orig, extra = Extra, rconds = RC}) ->
    HK = head_key(Vid),
    HeadOps = case Gs of
                  [] when Existed -> [cond_op({remove, HK}, Cond)];
                  []              -> [];
                  _               -> [cond_op({put, HK, encode_head(Gs)}, Cond)]
              end,
    %% 本次会话里新建又删掉的块从没落过盘，不发删除（否则白写一条墓碑）。
    %% 读过的块带读到时的版本作条件；读过没改的块发 check（读集校验，见不变式 2）。
    Dels = [chunk_op({remove, K}, RC) || K <- lists:sort(maps:keys(Ds)), maps:is_key(K, Orig)],
    Puts = [chunk_op({put, K, encode_chunk(maps:get(K, Cs))}, RC) || K <- lists:sort(maps:keys(Dy))],
    HeadOps ++ Dels ++ Puts ++ read_checks(RC, Dy, Ds) ++ lists:reverse(Extra).

chunk_op({put, K, _} = Op, RC) ->
    case maps:find(K, RC) of {ok, C} -> cond_op(Op, C); error -> Op end;
chunk_op({remove, K} = Op, RC) ->
    case maps:find(K, RC) of {ok, C} -> cond_op(Op, C); error -> Op end.

read_checks(RC, Dy, Ds) ->
    [{check, K, C} || {K, C} <- lists:sort(maps:to_list(RC)),
                      not maps:is_key(K, Dy), not maps:is_key(K, Ds)].

%% 会话读过但不改的顶点：头 + 读过的块都发 check（它们参与了这次的决定）。
guard_ops(#vs{vid = Vid, hcond = HC, rconds = RC, dirty = Dy, dels = Ds}) ->
    [{check, head_key(Vid), HC} || HC =/= txn] ++ read_checks(RC, Dy, Ds).

cond_op(Op, txn) -> Op;
cond_op({put, K, V}, Cond) -> {put, K, V, Cond};
cond_op({remove, K}, Cond) -> {remove, K, Cond}.

%% =========================================================================
%% 写会话：同一批里改若干顶点，提交时每个改过的头带一个条件
%% =========================================================================

new_session(Io, Cfg) -> #sess{io = Io, cfg = Cfg}.

sess_vs(#sess{io = Io, vs = M} = S, Vid) ->
    case maps:find(Vid, M) of
        {ok, Vs} -> {ok, Vs, S};
        error ->
            case load(Io, Vid) of
                {ok, Vs}       -> {ok, Vs, S#sess{vs = M#{Vid => Vs}}};
                {error, _} = E -> E
            end
    end.

sess_store(#sess{vs = M} = S, #vs{vid = Vid} = Vs) -> S#sess{vs = M#{Vid => Vs}}.

%% 加边（upsert）。{ok, S'} | {error, _}
put_edge(S0, Src, T, Dst, R, Props) ->
    #sess{io = Io, cfg = #{props_max := PM}} = S0,
    PStore = case byte_size(Props) > PM of true -> ext; false -> Props end,
    case sess_vs(S0, Src) of
        {error, _} = E -> E;
        {ok, VsS, S1} ->
            case get_entry(Io, VsS, 0, T, Dst, R) of
                {error, _} = E -> E;
                {ok, PStore, VsS1} when PStore =/= ext ->
                    {ok, sess_store(S1, VsS1)};             %% 原样存在：不写
                {ok, _Cur, VsS1} ->
                    put_edge_write(S1, VsS1, Src, T, Dst, R, Props, PStore)
            end
    end.

put_edge_write(S1, VsS1, Src, T, Dst, R, Props, PStore) ->
    #sess{io = Io} = S1,
    case put_entry(Io, VsS1, 0, T, Dst, R, PStore) of
        {error, _} = E -> E;
        {ok, Old, VsS2} ->
            PK = pkey(Src, T, Dst, R),
            Extra = case {Old, PStore} of
                        {_, ext} -> [{put, PK, Props}];
                        {ext, _} -> [{remove, PK}];
                        _        -> []
                    end,
            S2 = sess_store(S1, VsS2#vs{extra = Extra ++ VsS2#vs.extra}),
            case Old of
                none -> other_side(S2, Dst, fun(Vs) -> put_entry(Io, Vs, 1, T, Src, R, <<>>) end);
                _    -> {ok, S2}
            end
    end.

%% 改对端顶点（入边组）。
other_side(S, Vid, Fun) ->
    case sess_vs(S, Vid) of
        {error, _} = E -> E;
        {ok, Vs, S1} ->
            case Fun(Vs) of
                {ok, _Old, Vs1} -> {ok, sess_store(S1, Vs1)};
                {error, _} = E  -> E
            end
    end.

%% 删边（幂等）。{ok, S'} | {error, _}
del_edge(S0, Src, T, Dst, R) ->
    #sess{io = Io} = S0,
    case sess_vs(S0, Src) of
        {error, _} = E -> E;
        {ok, VsS, S1} ->
            case del_entry(Io, VsS, 0, T, Dst, R) of
                {error, _} = E -> E;
                {ok, none, VsS1} ->
                    {ok, sess_store(S1, VsS1)};
                {ok, Old, VsS1} ->
                    Extra = case Old of ext -> [{remove, pkey(Src, T, Dst, R)}]; _ -> [] end,
                    S2 = sess_store(S1, VsS1#vs{extra = Extra ++ VsS1#vs.extra}),
                    other_side(S2, Dst, fun(Vs) -> del_entry(Io, Vs, 1, T, Src, R) end)
            end
    end.

%% 顶点的全部条目：{ok, [{Dir, Etype, O, R, P}], S'} | {error, _}
all_entries(S0, Vid) ->
    #sess{io = Io} = S0,
    case sess_vs(S0, Vid) of
        {error, _} = E -> E;
        {ok, Vs, S1} ->
            case vs_all_entries(Io, Vs) of
                {ok, Es, Vs1}  -> {ok, Es, sess_store(S1, Vs1)};
                {error, _} = E -> E
            end
    end.

%% 提交：ok | conflict | {error, _}。直通模式是一条带条件的原子批；事务模式
%% 把 op 写进事务缓冲（条件由 bitcask_txn 的版本守卫在提交时带上）。
%% 也可以带额外 op（如 del_vertex 的顶点键删除）：commit/2。
commit(S) -> commit(S, []).

commit(#sess{io = Io, cfg = Cfg, vs = M}, ExtraOps) ->
    Res = lists:foldl(fun(_V, {error, _} = E) -> E;
                         ({_Vid, Vs}, {ok, Acc, Guards}) ->
                              case finalize(Io, Vs, Cfg) of
                                  {ok, [], Vs1}  -> {ok, Acc, [guard_ops(Vs1) | Guards]};
                                  {ok, Ops, _}   -> {ok, [Ops | Acc], Guards};
                                  {error, _} = E -> E
                              end
                      end, {ok, [], []}, lists:sort(maps:to_list(M))),
    case Res of
        {error, _} = E -> E;
        {ok, [], _} when ExtraOps =:= [] ->
            ok;                                   %% 什么都不写：只读的决定在读时即成立
        {ok, Acc, Guards} ->
            io_commit(Io, lists:append(lists:reverse(Acc)) ++ ExtraOps ++
                          lists:append(lists:reverse(Guards)))
    end.

%% =========================================================================
%% 纯函数：迁移 / 分析 / 校验
%% =========================================================================

%% 从完整条目表直接建一个顶点的 op（目标库是新的、无条件）：
%%   Out = [{Etype, Dst, Rank, Props}]，In = [{Etype, Src, Rank}]，各自已按
%%   (Etype, Other, Rank) 升序。Props 超过 props_max 的落 p 家族。
%% 返回 {Ops, NChunks}。
build_vertex(Vid, {Out, In}, #{props_max := PM} = Cfg) ->
    {OutEs, PutsP} =
        lists:foldr(fun({T, D, R, P}, {Acc, Ps}) ->
                            case byte_size(P) > PM of
                                true  -> {[{0, T, {D, R, ext}} | Acc], [{put, pkey(Vid, T, D, R), P} | Ps]};
                                false -> {[{0, T, {D, R, P}} | Acc], Ps}
                            end
                    end, {[], []}, Out),
    InEs = [{1, T, {S, R, <<>>}} || {T, S, R} <- In],
    Gs = to_groups(OutEs ++ InEs),
    Vs0 = #vs{vid = Vid, hcond = absent, groups = Gs, touched = true},
    Vs = chunk_oversized(Vs0, Cfg),
    Ops = case Gs of [] -> []; _ -> emit_ops(Vs) end,
    NChunks = map_size(Vs#vs.dirty),
    {[strip_cond(Op) || Op <- Ops] ++ PutsP, NChunks}.

strip_cond({put, K, V, _}) -> {put, K, V};
strip_cond(Op) -> Op.

%% [{Dir, Etype, Entry}]（(Dir, Etype) 有序、组内条目有序）→ 内联组。
to_groups([]) -> [];
to_groups([{D, T, _} | _] = L) ->
    {Mine, Rest} = lists:splitwith(fun({D2, T2, _}) -> {D2, T2} =:= {D, T} end, L),
    Es = [E || {_, _, E} <- Mine],
    [#grp{dir = D, etype = T, count = length(Es), body = {entries, Es}} | to_groups(Rest)].

%% 头 binary → [{Dir, Etype, Count, {entries, [Entry]} | {chunks, [Lb]}}]
groups_info(Bin) ->
    case decode_head(Bin) of
        {ok, Gs} -> {ok, [{D, T, C, B} || #grp{dir = D, etype = T, count = C, body = B} <- Gs]};
        error    -> error
    end.
