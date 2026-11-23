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
         entries/5, entries_guarded/5, edge_maps/6, neighbor_ids/4, lookup/6, counts/2,
         %% 写会话
         new_session/2, put_edge/6, del_edge/5, all_entries/2, first_entries/3,
         commit/1, commit/2,
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
              %% 内联组：条目表（会话里改过的可能是拉链，见 elist()）。
              %% 分块组：块目录保持盘上的二进制（各块下界 <<O:64, R:64>> 依次排列）——
              %% hub 的目录上千项，解成列表再线性找块曾是 hub 点操作的大头；现在在
              %% 二进制上二分，写回时目录没变就原样复用。
              body     :: {entries, elist()} | {chunks, binary()}}).

-record(vs, {vid      :: non_neg_integer(),
             hcond    :: absent | {ord, non_neg_integer()} | txn,
             existed = false :: boolean(),           %% 读到时头 key 是否存在
             groups = [] :: [#grp{}],
             chunks = #{} :: #{binary() => elist()},   %% 已读入的块（key → 条目）
             dirty  = #{} :: #{binary() => true},      %% 要写的块
             dels   = #{} :: #{binary() => true},      %% 要删的块
             orig   = [] :: [#grp{}],                  %% 读到时的组（提交时由它算盘上已有的块，
                                                       %% 只给它们发删除；读路径不为此建表）
             rconds = #{} :: #{binary() => absent | {ord, non_neg_integer()}},
                                                       %% 直通读过的块 → 读到时的版本（提交条件）
             extra  = [] :: [term()],                  %% p 家族 op（逆序）
             touched = false :: boolean(),
             henc :: undefined | binary()}).           %% finalize 算好的头编码（emit 复用）

-record(sess, {io :: {direct, term()} | {txn, term(), read | write},
               cfg :: map(), vs = #{} :: #{non_neg_integer() => #vs{}}}).

-type entry() :: {non_neg_integer(), non_neg_integer(), binary() | ext}.
%% 条目表：按 (O, R) 升序的列表；写会话里正在改的表是「拉链」{z, RevLeft, Right}
%%（RevLeft 逆序、全部小于 Right），游标停在上次改动处——批量加边按 (src, etype, dst,
%% rank) 排过序，同一张表上的插入是升序的，接着上次的位置找，不必每条从头走。
%% 拉链只存在于会话内（touched 的组 / dirty 的块），finalize 开头统一拍平。
-type elist() :: [entry()] | {z, [entry()], [entry()]}.

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

enc_group(#grp{dir = D, etype = T, count = C, body = {entries, Es0}}) ->
    Es = e_list(Es0),
    F = flags_of(Es),
    [<<D:8, F:8, T:32/big, C:64/big>> | enc_entries(Es, F)];
enc_group(#grp{dir = D, etype = T, count = C, flags = F0, body = {chunks, Dir}}) ->
    F = (F0 band (?F_RANK bor ?F_PROPS)) bor ?F_CHUNKED,
    [<<D:8, F:8, T:32/big, C:64/big, (byte_size(Dir) div 16):32/big>>, Dir].

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
                    case Dir of
                        <<0:64, 0:64, _/binary>> ->          %% 块 0 的下界恒为 (0, 0)
                            dec_groups(N - 1, Rest2, {D, T},
                                       [#grp{dir = D, etype = T, count = C,
                                             flags = F band (?F_RANK bor ?F_PROPS),
                                             body = {chunks, Dir}} | Acc]);
                        _ ->
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

%% 读路径不建会话状态：直接在头 / 块的二进制上挑出要的组（方向、类型），别的组按
%% 字节数跳过，要的组一遍解成调用方要的形态（条目元组 / 边 map / 邻居 id）。
%% 以前是「整头解成记录 → 取条目 → 补类型 → 转 map → 逐条看属性」四遍。

%% 顶点 Vid 在 Dir 方向的条目：[{Etype, Other, Rank, Props}]，组序 × 条目序。
%% Etype = undefined 取全部类型；Limit = infinity | N。Props 可能是 ext
%% （属性在 p 家族，由调用方按需解析）。
entries(Io, Vid, Dir, Etype, Limit) ->
    case read_groups(Io, Vid, Dir, Etype, Limit, tuples, false) of
        {ok, Es, _NG, _Props, _Checks} -> {ok, Es};
        {error, _} = E                 -> E
    end.

%% 同 entries/5，并记下每个读到的 key 的版本：{ok, Entries, Checks}，
%% Checks = [{check, Key, Cond}]（头 + 读过的块；读到缺失的块记 absent）。调用方
%% 在引擎写锁下用只含 check 的原子批校验 Checks 仍是当前版本，即得一致快照
%% （graphdb consistent_read；读集校验还能挡住绕过图层协议直写块的写入者，
%% 见不变式 2）。只用于直通模式。
entries_guarded({direct, _} = Io, Vid, Dir, Etype, Limit) ->
    case read_groups(Io, Vid, Dir, Etype, Limit, tuples, true) of
        {ok, Es, _NG, _Props, Checks} -> {ok, Es, Checks};
        {error, _} = E                -> E
    end.

%% 直接出边 map（graphdb 的 edge() 形态）：{ok, Maps, HasProps, Checks}。
%%   Dir = 0：#{src => Vid, etype, dst, rank, props}；props 可能是 ext（HasProps 为
%%            true 时调用方再过一遍把 ext 换成 p 家族的值）。
%%   Dir = 1：#{dst => Vid, etype, src, rank, props => <<>>}（入边一侧不存属性）。
%% Guard = true 时 Checks 同 entries_guarded/5，否则为 []。
edge_maps(Io, Vid, Dir, Etype, Limit, Guard) ->
    case read_groups(Io, Vid, Dir, Etype, Limit, {maps, Vid, Dir}, Guard) of
        {ok, Ms, _NG, Props, Checks} -> {ok, Ms, Props andalso Dir =:= 0, Checks};
        {error, _} = E               -> E
    end.

%% 邻居 vid：{ok, Ids, Unique}。DirSel = 0 | 1 | both（both：出边组在前、入边组在后，
%% 只读一次头）。同一组内相邻的重复（同一个对端的多条 rank）已去掉；Unique = true
%% 表示 Ids 整体无重复（只来自一个组）——调用方可以不再去重。
neighbor_ids(Io, Vid, DirSel, Etype) ->
    case read_groups(Io, Vid, DirSel, Etype, infinity, ids, false) of
        {ok, Ids, NG, _Props, _Checks} -> {ok, Ids, NG =< 1};
        {error, _} = E                 -> E
    end.

%% {ok, 扁平结果, 选中的组数, 选中的组里是否有带属性的, Checks} | {error, _}
read_groups(Io, Vid, DirSel, Etype, Limit, Mode, Guard) ->
    HK = head_key(Vid),
    case io_head(Io, HK) of
        {error, _} = E ->
            E;
        {absent, HC} ->
            {ok, [], 0, false, [{check, HK, HC} || Guard]};
        {ok, Bin, HC} ->
            case sel_groups(Bin, DirSel, Etype) of
                error ->
                    {error, {bad_adj, Vid}};
                {ok, Sel} ->
                    Props = lists:any(fun({_, _, F, _, _}) -> F band ?F_PROPS =/= 0 end, Sel),
                    case rg_groups(Io, Vid, Sel, Limit, Mode, Guard, [], []) of
                        {ok, Parts, Checks} ->
                            {ok, lists:append(lists:reverse(Parts)), length(Sel), Props,
                             [{check, HK, HC} || Guard] ++ lists:reverse(Checks)};
                        {error, _} = E ->
                            E
                    end
            end
    end.

rg_groups(_Io, _Vid, _Sel, 0, _Mode, _Guard, Acc, Checks) ->
    {ok, Acc, Checks};
rg_groups(_Io, _Vid, [], _Limit, _Mode, _Guard, Acc, Checks) ->
    {ok, Acc, Checks};
rg_groups(Io, Vid, [{_D, T, F, C, {inline, Body}} | Sel], Limit, Mode, Guard, Acc, Checks) ->
    case dec_body(Mode, T, F, C, Body) of
        {ok, L} when Limit =:= infinity ->
            rg_groups(Io, Vid, Sel, infinity, Mode, Guard, [L | Acc], Checks);
        {ok, L0} ->
            L = lists:sublist(L0, Limit),
            rg_groups(Io, Vid, Sel, Limit - length(L), Mode, Guard, [L | Acc], Checks);
        error ->
            {error, {bad_adj, Vid}}
    end;
rg_groups(Io, Vid, [{D, T, F, _C, {chunks, Dir}} | Sel], Limit, Mode, Guard, Acc, Checks) ->
    case rg_chunks(Io, Vid, D, T, Dir, Limit, Mode, Guard, [], 0, Checks) of
        {ok, Parts, N, Checks2} ->
            %% 分块的带 rank 组取 id：同一对端的多条 rank 可能跨块相邻，整组拼好再去一遍。
            Acc2 = case Mode =:= ids andalso F band ?F_RANK =/= 0 of
                       true  -> [adj_dedupe(lists:append(lists:reverse(Parts))) | Acc];
                       false -> Parts ++ Acc
                   end,
            rg_groups(Io, Vid, Sel, dec_limit(Limit, N), Mode, Guard, Acc2, Checks2);
        {error, _} = E ->
            E
    end.

%% 一个分块组：按头的块目录逐块点读（块序 = 下界序 = 条目序），Limit 到了就停。
%% 直通与事务同一条路：事务里经事务缓冲、点锁（持有头的锁即覆盖它名下全部块，§8），
%% 不拿前缀锁。不走前缀 range：range 一次往返按批取块（limit 10 也要搬一批 4 KiB 的
%% 块），而且 libbitcask ≤ 12.0.1 的范围迭代器在每次写之后要重排整个未落盘的内存
%% 增量（libbitcask feedbacks/2026-11-23-range-iter-after-write-resorts-memdelta.md，
%% 12.0.2 已修）。
%% 目录里有、盘上读不到的块按空处理：这条路是弱一致读（头与块分次读，中间可能插进
%% 一次删块 / 分裂）；Guard = true 时把它记成 absent 条件，由调用方在写锁下校验。
rg_chunks(_Io, _Vid, _D, _T, _Dir, 0, _Mode, _Guard, Acc, N, Checks) ->
    {ok, Acc, N, Checks};
rg_chunks(_Io, _Vid, _D, _T, <<>>, _Limit, _Mode, _Guard, Acc, N, Checks) ->
    {ok, Acc, N, Checks};
rg_chunks(Io, Vid, D, T, <<O:64/big, R:64/big, Dir/binary>>, Limit, Mode, Guard, Acc, N, Checks) ->
    Key = chunk_key(Vid, D, T, {O, R}),
    case io_head(Io, Key) of
        {ok, <<?VER:8, CF:8, CC:32/big, Body/binary>>, Cond} ->
            case dec_body(Mode, T, CF, CC, Body) of
                {ok, L} when Limit =:= infinity ->
                    rg_chunks(Io, Vid, D, T, Dir, infinity, Mode, Guard,
                              [L | Acc], N, [{check, Key, Cond} || Guard] ++ Checks);
                {ok, L0} ->
                    L = lists:sublist(L0, Limit),
                    K = length(L),
                    rg_chunks(Io, Vid, D, T, Dir, Limit - K, Mode, Guard,
                              [L | Acc], N + K, [{check, Key, Cond} || Guard] ++ Checks);
                error ->
                    {error, {bad_adj_chunk, Key}}
            end;
        {ok, _Bad, _Cond} ->
            {error, {bad_adj_chunk, Key}};
        {absent, Cond} ->
            rg_chunks(Io, Vid, D, T, Dir, Limit, Mode, Guard, Acc, N,
                      [{check, Key, Cond} || Guard] ++ Checks);
        {error, _} = E ->
            E
    end.

%% 头二进制 → 选中的组 [{Dir, Etype, Flags, Count, {inline, Body} | {chunks, DirBin}}]
%% （头里的顺序 = (Dir, Etype) 升序）。没选中的组只算字节数跳过；结构校验与
%% decode_head/1 同口径（版本、组序、Dir、Count、长度、块 0 下界、无尾随字节）。
sel_groups(<<?VER:8, N:16/big, Rest/binary>>, DirSel, Etype) ->
    sel_groups(N, Rest, undefined, DirSel, Etype, []);
sel_groups(_, _DirSel, _Etype) ->
    error.

sel_groups(0, <<>>, _Prev, _DirSel, _Etype, Acc) ->
    {ok, lists:reverse(Acc)};
sel_groups(0, _Trailing, _Prev, _DirSel, _Etype, _Acc) ->
    error;
sel_groups(N, <<D:8, F:8, T:32/big, C:64/big, Rest/binary>>, Prev, DirSel, Etype, Acc)
  when D =< 1, C > 0, (Prev =:= undefined orelse {D, T} > Prev) ->
    Want = (DirSel =:= both orelse D =:= DirSel)
        andalso (Etype =:= undefined orelse T =:= Etype),
    case F band ?F_CHUNKED of
        0 ->
            case split_body(Rest, C, F) of
                {ok, Body, Rest2} ->
                    Acc2 = case Want of
                               true  -> [{D, T, F, C, {inline, Body}} | Acc];
                               false -> Acc
                           end,
                    sel_groups(N - 1, Rest2, {D, T}, DirSel, Etype, Acc2);
                error ->
                    error
            end;
        _ ->
            case Rest of
                <<NC:32/big, Dir:(NC * 16)/binary, Rest2/binary>> when NC > 0 ->
                    case Dir of
                        <<0:64, 0:64, _/binary>> ->
                            Acc2 = case Want of
                                       true  -> [{D, T, F band (?F_RANK bor ?F_PROPS), C,
                                                  {chunks, Dir}} | Acc];
                                       false -> Acc
                                   end,
                            sel_groups(N - 1, Rest2, {D, T}, DirSel, Etype, Acc2);
                        _ ->
                            error
                    end;
                _ ->
                    error
            end
    end;
sel_groups(_N, _Bin, _Prev, _DirSel, _Etype, _Acc) ->
    error.

%% 内联组的条目区：定宽组直接按 Count × 宽度切；带属性的要走一遍才知道多长。
split_body(Bin, C, F) when F band ?F_PROPS =:= 0 ->
    W = entry_width(F),
    case Bin of
        <<Body:(C * W)/binary, Rest/binary>> -> {ok, Body, Rest};
        _                                    -> error
    end;
split_body(Bin, C, F) ->
    case skip_prop_entries(Bin, C, F band ?F_RANK =/= 0) of
        {ok, Rest} ->
            Len = byte_size(Bin) - byte_size(Rest),
            {ok, binary:part(Bin, 0, Len), Rest};
        error ->
            error
    end.

skip_prop_entries(Rest, 0, _HasRank) -> {ok, Rest};
skip_prop_entries(<<_:128, ?PEXT:16/big, Rest/binary>>, N, true) ->
    skip_prop_entries(Rest, N - 1, true);
skip_prop_entries(<<_:128, L:16/big, _:L/binary, Rest/binary>>, N, true) ->
    skip_prop_entries(Rest, N - 1, true);
skip_prop_entries(<<_:64, ?PEXT:16/big, Rest/binary>>, N, false) ->
    skip_prop_entries(Rest, N - 1, false);
skip_prop_entries(<<_:64, L:16/big, _:L/binary, Rest/binary>>, N, false) ->
    skip_prop_entries(Rest, N - 1, false);
skip_prop_entries(_, _N, _HasRank) -> error.

entry_width(F) -> case F band ?F_RANK of 0 -> 8; _ -> 16 end.

%% 一段条目区（恰好 Count 条，不多不少）→ 调用方要的形态。定宽组一遍 binary
%% comprehension 直接出结果；带属性的先解成条目再转。
%%   tuples          [{Etype, O, R, P}]
%%   {maps, Vid, 0}  出边 map；{maps, Vid, 1} 入边 map
%%   ids             [O]（带 rank 的组去掉相邻重复）
dec_body(Mode, T, F, C, Body) when F band ?F_PROPS =:= 0 ->
    W = entry_width(F),
    case byte_size(Body) =:= C * W of
        false -> error;
        true  -> {ok, dec_fixed(Mode, T, W, Body)}
    end;
dec_body(Mode, T, F, C, Body) ->
    case dec_prop_entries(Body, C, F band ?F_RANK =/= 0, []) of
        {ok, Es, <<>>} ->
            {ok, case Mode of
                     tuples ->
                         [{T, O, R, P} || {O, R, P} <- Es];
                     {maps, V, 0} ->
                         [#{src => V, etype => T, dst => O, rank => R, props => P}
                          || {O, R, P} <- Es];
                     {maps, V, 1} ->
                         [#{dst => V, etype => T, src => O, rank => R, props => <<>>}
                          || {O, R, _P} <- Es];
                     ids ->
                         adj_dedupe([O || {O, _R, _P} <- Es])
                 end};
        _ ->
            error
    end.

dec_fixed(tuples, T, 8, Body)  -> [{T, O, 0, <<>>} || <<O:64/big>> <= Body];
dec_fixed(tuples, T, 16, Body) -> [{T, O, R, <<>>} || <<O:64/big, R:64/big>> <= Body];
dec_fixed({maps, V, 0}, T, 8, Body) ->
    [#{src => V, etype => T, dst => O, rank => 0, props => <<>>} || <<O:64/big>> <= Body];
dec_fixed({maps, V, 0}, T, 16, Body) ->
    [#{src => V, etype => T, dst => O, rank => R, props => <<>>}
     || <<O:64/big, R:64/big>> <= Body];
dec_fixed({maps, V, 1}, T, 8, Body) ->
    [#{dst => V, etype => T, src => O, rank => 0, props => <<>>} || <<O:64/big>> <= Body];
dec_fixed({maps, V, 1}, T, 16, Body) ->
    [#{dst => V, etype => T, src => O, rank => R, props => <<>>}
     || <<O:64/big, R:64/big>> <= Body];
dec_fixed(ids, _T, 8, Body)  -> [O || <<O:64/big>> <= Body];
dec_fixed(ids, _T, 16, Body) -> adj_dedupe([O || <<O:64/big, _R:64>> <= Body]).

%% 去掉相邻重复（条目按 (O, R) 升序，同一个 O 的多条 rank 相邻）。
adj_dedupe([X | [X | _] = T]) -> adj_dedupe(T);
adj_dedupe([X | T])           -> [X | adj_dedupe(T)];
adj_dedupe([])                -> [].

dec_limit(infinity, _) -> infinity;
dec_limit(N, K)        -> max(0, N - K).

%% 点查一条条目：{ok, Props} | not_found | {error, _}。只挑出那一组；内联组在条目区
%% 上找，分块组在块目录上二分出所在的块、再点读那一块。
lookup(Io, Vid, Dir, Etype, Other, Rank) ->
    case io_head(Io, head_key(Vid)) of
        {error, _} = E -> E;
        {absent, _}    -> not_found;
        {ok, Bin, _} ->
            case sel_groups(Bin, Dir, Etype) of
                error    -> {error, {bad_adj, Vid}};
                {ok, []} -> not_found;
                {ok, [{_, _, F, C, {inline, Body}}]} ->
                    case find_in_body(F, C, Body, Other, Rank) of
                        error -> {error, {bad_adj, Vid}};
                        Res   -> Res
                    end;
                {ok, [{_, _, _F, _C, {chunks, DirBin}}]} ->
                    Key = chunk_key(Vid, Dir, Etype, locate_lb(DirBin, {Other, Rank})),
                    case io_head(Io, Key) of
                        {ok, <<?VER:8, CF:8, CC:32/big, Body/binary>>, _} ->
                            case find_in_body(CF, CC, Body, Other, Rank) of
                                error -> {error, {bad_adj_chunk, Key}};
                                Res   -> Res
                            end;
                        {ok, _, _}     -> {error, {bad_adj_chunk, Key}};
                        {absent, _}    -> not_found;
                        {error, _} = E -> E
                    end
            end
    end.

%% {ok, Props} | not_found | error
find_in_body(F, C, Body, O, R) when F band ?F_PROPS =:= 0 ->
    W = entry_width(F),
    case byte_size(Body) =:= C * W of
        false -> error;
        true when W =:= 8, R =/= 0 -> not_found;
        true ->
            case bsearch_fixed(Body, W, 0, C, O, R) of
                true  -> {ok, <<>>};
                false -> not_found
            end
    end;
find_in_body(F, C, Body, O, R) ->
    case dec_prop_entries(Body, C, F band ?F_RANK =/= 0, []) of
        {ok, Es, <<>>} ->
            case ent_find(Es, O, R) of
                {ok, P} -> {ok, P};
                none    -> not_found
            end;
        _ ->
            error
    end.

%% 定宽条目区 [Lo, Hi) 上二分找 (O, R)。
bsearch_fixed(_Body, _W, Lo, Hi, _O, _R) when Lo >= Hi -> false;
bsearch_fixed(Body, W, Lo, Hi, O, R) ->
    Mid = (Lo + Hi) div 2,
    K = case W of
            8  -> <<_:(Mid * 8)/binary, MO:64/big, _/binary>> = Body, {MO, 0};
            16 -> <<_:(Mid * 16)/binary, MO:64/big, MR:64/big, _/binary>> = Body, {MO, MR}
        end,
    if K =:= {O, R} -> true;
       K < {O, R}   -> bsearch_fixed(Body, W, Mid + 1, Hi, O, R);
       true         -> bsearch_fixed(Body, W, Lo, Mid, O, R)
    end.

%% 各组的 {Dir, Etype, Count}：只读各组的头，不解条目。
counts(Io, Vid) ->
    case io_head(Io, head_key(Vid)) of
        {error, _} = E -> E;
        {absent, _}    -> {ok, []};
        {ok, Bin, _} ->
            case sel_groups(Bin, both, undefined) of
                {ok, Sel} -> {ok, [{D, T, C} || {D, T, _F, C, _Body} <- Sel]};
                error     -> {error, {bad_adj, Vid}}
            end
    end.

%% =========================================================================
%% 顶点状态
%% =========================================================================

load(Io, Vid) ->
    case io_head(Io, head_key(Vid)) of
        {ok, Bin, Cond} ->
            case decode_head(Bin) of
                {ok, Gs} -> {ok, #vs{vid = Vid, hcond = Cond, existed = true, groups = Gs,
                                     orig = Gs}};
                error    -> {error, {bad_adj, Vid}}
            end;
        {absent, Cond} ->
            {ok, #vs{vid = Vid, hcond = Cond}};
        {error, _} = E ->
            E
    end.

chunk_keys_of(Vid, Gs) ->
    maps:from_list([{chunk_key(Vid, D, T, {O, R}), true}
                    || #grp{dir = D, etype = T, body = {chunks, Dir}} <- Gs,
                       <<O:64/big, R:64/big>> <= Dir]).

%% 块目录：二进制 ⟷ 下界列表（只在目录要变 / 要整组遍历时才展开）。
dir_lbs(Dir) -> [{O, R} || <<O:64/big, R:64/big>> <= Dir].
lbs_dir(Lbs) -> << <<O:64/big, R:64/big>> || {O, R} <- Lbs >>.

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

%% 有序条目列表上的查找（按 (O, R)）。
ent_find([{O, R, P} | _], O, R) -> {ok, P};
ent_find([{O2, R2, _} | Es], O, R) when {O2, R2} < {O, R} -> ent_find(Es, O, R);
ent_find(_, _O, _R) -> none.

%% ---- 条目表 elist()：列表或拉链（类型说明见文件头的 -type）----

e_list({z, L, R})         -> lists:reverse(L, R);
e_list(L) when is_list(L) -> L.

e_empty([])           -> true;
e_empty({z, [], []})  -> true;
e_empty(_)            -> false.

%% 把游标移到 Key：返回 {RevLeft, Right}，RevLeft 全部 < Key ≤ Right 的首条。
%% 从上次停的位置接着走——升序的一串操作摊下来每次 O(1)。
e_seek({z, [{O, R, _} | _] = L, Rt}, K) when {O, R} >= K -> z_back(L, Rt, K);
e_seek({z, L, Rt}, K)                                     -> z_fwd(L, Rt, K);
e_seek(L, K) when is_list(L)                              -> z_fwd([], L, K).

z_fwd(L, [{O, R, _} = H | T], K) when {O, R} < K -> z_fwd([H | L], T, K);
z_fwd(L, Rt, _K)                                 -> {L, Rt}.

z_back([{O, R, _} = H | T], Rt, K) when {O, R} >= K -> z_back(T, [H | Rt], K);
z_back(L, Rt, _K)                                   -> {L, Rt}.

%% upsert：{Old | none, Es'}。一次定位同时完成「查原值」和「写入」。
ent_put(Es, {O, R, _} = E) ->
    case e_seek(Es, {O, R}) of
        {L, [{O, R, Old} | T]} -> {Old, {z, L, [E | T]}};
        {L, Rt}                -> {none, {z, L, [E | Rt]}}
    end.

%% {Old, Es'} | {none, Es}（不存在时原样返回）。
ent_del(Es, O, R) ->
    case e_seek(Es, {O, R}) of
        {L, [{O, R, Old} | T]} -> {Old, {z, L, T}};
        _                      -> {none, Es}
    end.

%% 块目录（二进制）里最后一个 ≤ Key 的下界：二分。块 0 恒为 (0, 0)，必有。
locate_lb(Dir, Key) -> locate_lb(Dir, 0, byte_size(Dir) div 16, Key).

locate_lb(Dir, Lo, Hi, _Key) when Hi - Lo =< 1 ->
    <<_:(Lo * 16)/binary, O:64/big, R:64/big, _/binary>> = Dir,
    {O, R};
locate_lb(Dir, Lo, Hi, Key) ->
    Mid = (Lo + Hi) div 2,
    <<_:(Mid * 16)/binary, O:64/big, R:64/big, _/binary>> = Dir,
    case {O, R} =< Key of
        true  -> locate_lb(Dir, Mid, Hi, Key);
        false -> locate_lb(Dir, Lo, Mid, Key)
    end.

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

%% upsert：{ok, Old | none | same, Vs'} | {error, _}。
%% same = 条目原样已在（同样的内联属性）：不改、不标脏（外置属性恒重写）。
put_entry(Io, #vs{vid = Vid, groups = Gs} = Vs, Dir, T, O, R, P) ->
    E = {O, R, P},
    case find_group(Gs, Dir, T) of
        none ->
            G = #grp{dir = Dir, etype = T, count = 1, body = {entries, [E]}},
            {ok, none, touch(Vs#vs{groups = store_group(Gs, G)})};
        {ok, #grp{count = C, body = {entries, Es}} = G} ->
            case ent_put(Es, E) of
                {P, _} when P =/= ext ->
                    {ok, same, Vs};
                {Old, Es2} ->
                    G2 = G#grp{count = C + new(Old), body = {entries, Es2}},
                    {ok, Old, touch(Vs#vs{groups = store_group(Gs, G2)})}
            end;
        {ok, #grp{count = C, flags = F, body = {chunks, Dirb}} = G} ->
            Key = chunk_key(Vid, Dir, T, locate_lb(Dirb, {O, R})),
            case get_chunk(Io, Vs, Key) of
                {ok, Es, Vs1} ->
                    case ent_put(Es, E) of
                        {P, _} when P =/= ext ->
                            {ok, same, Vs1};
                        {Old, Es2} ->
                            G2 = G#grp{count = C + new(Old), flags = F bor flags_of([E])},
                            Vs2 = set_chunk(Vs1#vs{groups = store_group(Gs, G2)}, Key, Es2),
                            {ok, Old, touch(Vs2)}
                    end;
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
                {Old, Es2} ->
                    case e_empty(Es2) of
                        true ->
                            {ok, Old, touch(Vs#vs{groups = drop_group(Gs, Dir, T)})};
                        false ->
                            G2 = G#grp{count = C - 1, body = {entries, Es2}},
                            {ok, Old, touch(Vs#vs{groups = store_group(Gs, G2)})}
                    end
            end;
        {ok, #grp{count = C, body = {chunks, Dirb}} = G} ->
            Key = chunk_key(Vid, Dir, T, locate_lb(Dirb, {O, R})),
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

%% 按组序（内联组整组、分块组逐块）读条目，直到「不同的对端顶点数 > MaxOthers」或
%% 读完：{ok, [{Dir, Etype, O, R, P}], Complete, Vs'} | {error, _}。Complete = 该顶点
%% 的条目已全部读到。MaxOthers = infinity 读全部。对端不计 Vid 自己（自环）。
%% 块目录边走边读（不先展开成列表）：hub 分轮删除时每轮只碰目录的开头几项。
vs_first_entries(Io, #vs{vid = Vid, groups = Gs} = Vs, MaxOthers) ->
    vs_first_groups(Io, Vs, Vid, Gs, MaxOthers, #{}, []).

vs_first_groups(_Io, Vs, _Vid, [], _Max, _Seen, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), true, Vs};
vs_first_groups(_Io, Vs, _Vid, _Gs, Max, Seen, Acc) when is_integer(Max), map_size(Seen) > Max ->
    {ok, lists:append(lists:reverse(Acc)), false, Vs};
vs_first_groups(Io, Vs, Vid, [#grp{dir = D, etype = T, body = {entries, Es0}} | Gs], Max, Seen, Acc) ->
    Es = e_list(Es0),
    vs_first_groups(Io, Vs, Vid, Gs, Max, seen_others(Es, Vid, Seen),
                    [[{D, T, O, R, P} || {O, R, P} <- Es] | Acc]);
vs_first_groups(Io, Vs, Vid, [#grp{dir = D, etype = T, body = {chunks, Dirb}} | Gs], Max, Seen, Acc) ->
    case vs_first_chunks(Io, Vs, Vid, D, T, Dirb, Max, Seen, Acc) of
        {more, Vs1, Seen1, Acc1} -> vs_first_groups(Io, Vs1, Vid, Gs, Max, Seen1, Acc1);
        {stop, Vs1, Acc1}        -> {ok, lists:append(lists:reverse(Acc1)), false, Vs1};
        {error, _} = E           -> E
    end.

vs_first_chunks(_Io, Vs, _Vid, _D, _T, <<>>, _Max, Seen, Acc) ->
    {more, Vs, Seen, Acc};
vs_first_chunks(_Io, Vs, _Vid, _D, _T, _Dirb, Max, Seen, Acc) when is_integer(Max), map_size(Seen) > Max ->
    {stop, Vs, Acc};
vs_first_chunks(Io, Vs, Vid, D, T, <<LO:64/big, LR:64/big, Dirb/binary>>, Max, Seen, Acc) ->
    case get_chunk(Io, Vs, chunk_key(Vid, D, T, {LO, LR})) of
        {error, _} = E -> E;
        {ok, Es0, Vs1} ->
            Es = e_list(Es0),
            vs_first_chunks(Io, Vs1, Vid, D, T, Dirb, Max, seen_others(Es, Vid, Seen),
                            [[{D, T, O, R, P} || {O, R, P} <- Es] | Acc])
    end.

seen_others(Es, Vid, Seen) ->
    lists:foldl(fun({O, _R, _P}, M) when O =/= Vid -> M#{O => true};
                   (_, M) -> M
                end, Seen, Es).

%% 一个分块组的全部条目。各块逆序攒起来最后拼一次。
load_group_chunks(Io, Vs0, Vid, D, T, Dirb) ->
    Res = lists:foldl(fun(_Lb, {error, _} = E) -> E;
                         (Lb, {ok, Acc, Vs}) ->
                              case get_chunk(Io, Vs, chunk_key(Vid, D, T, Lb)) of
                                  {ok, Es, Vs2}  -> {ok, [e_list(Es) | Acc], Vs2};
                                  {error, _} = E -> E
                              end
                      end, {ok, [], Vs0}, dir_lbs(Dirb)),
    case Res of
        {ok, Acc, Vs} -> {ok, lists:append(lists:reverse(Acc)), Vs};
        {error, _} = E -> E
    end.

%% =========================================================================
%% 收尾：分块维护 + 生成 op
%% =========================================================================

%% {ok, Ops, Vs'} | {error, _}
finalize(Io, Vs, Cfg) ->
    finalize_1(Io, flatten(Vs), Cfg).

%% 会话里的拉链统一拍平成列表（只有 touched 的组 / dirty 的块会是拉链）。
flatten(#vs{groups = Gs, chunks = Cs, dirty = Dy} = Vs) ->
    Gs2 = [case G of
               #grp{body = {entries, {z, _, _} = Z}} -> G#grp{body = {entries, e_list(Z)}};
               _ -> G
           end || G <- Gs],
    Cs2 = maps:fold(fun(K, _, A) ->
                            case A of
                                #{K := {z, _, _} = Z} -> A#{K := e_list(Z)};
                                _ -> A
                            end
                    end, Cs, Dy),
    Vs#vs{groups = Gs2, chunks = Cs2}.

finalize_1(Io, #vs{touched = false} = Vs, Cfg) ->
    %% all_entries/2、first_entries/3 只读（用于 del_vertex）也可能修复过 chunk 状态：读非块 0
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
finalize_1(_Io, #vs{vid = Vid, groups = Gs}, _Cfg) when length(Gs) > 16#FFFF ->
    {error, {too_many_groups, Vid}};
finalize_1(Io, Vs0, Cfg) ->
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

normalize_group(#grp{dir = D, etype = T, count = 0, body = {chunks, Dirb}}, #vs{vid = Vid} = Vs, _Cfg) ->
    Vs1 = lists:foldl(fun(Lb, A) -> del_chunk(A, chunk_key(Vid, D, T, Lb)) end, Vs, dir_lbs(Dirb)),
    Vs1#vs{groups = drop_group(Vs1#vs.groups, D, T)};
normalize_group(#grp{dir = D, etype = T, count = C, body = {chunks, Dirb}} = G,
                #vs{vid = Vid} = Vs0, Cfg) ->
    %% 只看本组里改过的块（从 dirty 表反查），不遍历整个块目录；目录只在有块被删 /
    %% 分裂时才展开重建——hub 上绝大多数写只改一两个块的内容，目录原样复用。
    Mine = lists:sort([Lb || K <- maps:keys(Vs0#vs.dirty),
                             {ok, V, D2, T2, Lb} <- [parse_chunk_key(K)],
                             V =:= Vid, D2 =:= D, T2 =:= T]),
    Max = eff_chunk_max(C, Cfg),
    {Changes, Vs2} =
        lists:foldl(
          fun(Lb, {Ch, Vs}) ->
                  Key = chunk_key(Vid, D, T, Lb),
                  case maps:get(Key, Vs#vs.chunks) of
                      [] when Lb =/= ?LB0 ->
                          {[{Lb, remove} | Ch], del_chunk(Vs, Key)};
                      Es ->
                          case split_balanced(Es, Max) of
                              [_] ->
                                  {Ch, Vs};
                              [First | More] ->
                                  VsA = set_chunk(Vs, Key, First),
                                  {NewLbsR, VsB} =
                                      lists:foldl(
                                        fun([{O, R, _} | _] = Piece, {L, VV}) ->
                                                NLb = {O, R},
                                                {[NLb | L],
                                                 set_chunk(VV, chunk_key(Vid, D, T, NLb), Piece)}
                                        end, {[], VsA}, More),
                                  {[{Lb, {add, lists:reverse(NewLbsR)}} | Ch], VsB}
                          end
                  end
          end, {[], Vs0}, Mine),
    case Changes of
        [] ->
            Vs2;
        _ ->
            M = maps:from_list(Changes),
            Lbs2 = lists:append([case maps:find(Lb, M) of
                                     error            -> [Lb];
                                     {ok, remove}     -> [];
                                     {ok, {add, New}} -> [Lb | New]
                                 end || Lb <- dir_lbs(Dirb)]),
            G2 = G#grp{body = {chunks, lbs_dir(Lbs2)}},
            Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}
    end.

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
         (#grp{dir = D, etype = T, count = C, flags = F, body = {chunks, Dirb}} = G, {ok, Vs}) ->
              MinW = 8 + case F band ?F_RANK of 0 -> 0; _ -> 8 end
                       + case F band ?F_PROPS of 0 -> 0; _ -> 2 end,
              case C * MinW < Thresh of
                  false -> {ok, Vs};
                  true ->
                      case load_group_chunks(Io, Vs, Vs#vs.vid, D, T, Dirb) of
                          {error, _} = E -> E;
                          {ok, Es, Vs1} ->
                              case body_size(Es) < Thresh of
                                  false -> {ok, Vs1};
                                  true ->
                                      Vs2 = lists:foldl(
                                              fun(Lb, A) ->
                                                      del_chunk(A, chunk_key(Vs1#vs.vid, D, T, Lb))
                                              end, Vs1, dir_lbs(Dirb)),
                                      G2 = G#grp{flags = 0, body = {entries, Es}},
                                      {ok, Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}}
                              end
                      end
              end;
         (_, Acc) -> Acc
      end, {ok, Vs0}, Gs).

%% 头超过 inline_max → 把最大的内联组转为分块，直到放得下或没有可转的组
%% （只转体积 > inline_max / 4 的组，与 unchunk_small 的门槛构成滞回）。
%% 顺带把定稿的头编码记进 henc，emit_ops 直接用（以前量一次大小编一遍、写出时再编一遍）。
chunk_oversized(#vs{groups = Gs} = Vs, #{inline_max := IM} = Cfg) ->
    Enc = encode_head(Gs),
    case byte_size(Enc) =< IM of
        true -> Vs#vs{henc = Enc};
        false ->
            Cands = [{body_size(Es), G} || #grp{body = {entries, Es}} = G <- Gs,
                                           length(Es) >= 2],
            case [X || {Sz, _} = X <- Cands, Sz > IM div 4] of
                [] -> Vs#vs{henc = Enc};
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
    G2 = G#grp{flags = flags_of(Es), body = {chunks, lbs_dir([?LB0 | lists:reverse(Lbs)])}},
    Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}.

%% 头 op（带条件）+ 块删除 + 块写入 + p 家族 op。
emit_ops(#vs{vid = Vid, hcond = Cond, existed = Existed, groups = Gs, henc = HEnc,
             chunks = Cs, dirty = Dy, dels = Ds, orig = Orig, extra = Extra, rconds = RC}) ->
    HK = head_key(Vid),
    HeadOps = case Gs of
                  [] when Existed -> [cond_op({remove, HK}, Cond)];
                  []              -> [];
                  _ when is_binary(HEnc) -> [cond_op({put, HK, HEnc}, Cond)];
                  _               -> [cond_op({put, HK, encode_head(Gs)}, Cond)]
              end,
    %% 本次会话里新建又删掉的块从没落过盘，不发删除（否则白写一条墓碑）。
    %% 读过的块带读到时的版本作条件；读过没改的块发 check（读集校验，见不变式 2）。
    %% 盘上已有的块集合只在真有块要删时才算：hub 的头有上千个块，每次读头都建这张
    %% 表曾占 degree / edge / put_edge 约 3/4 的 CPU。
    Dels = case map_size(Ds) of
               0 -> [];
               _ ->
                   OnDisk = chunk_keys_of(Vid, Orig),
                   [chunk_op({remove, K}, RC) || K <- lists:sort(maps:keys(Ds)),
                                                 maps:is_key(K, OnDisk)]
           end,
    Puts = [chunk_op({put, K, encode_chunk(e_list(maps:get(K, Cs)))}, RC)
            || K <- lists:sort(maps:keys(Dy))],
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
            case put_entry(Io, VsS, 0, T, Dst, R, PStore) of
                {error, _} = E ->
                    E;
                {ok, same, VsS1} ->
                    {ok, sess_store(S1, VsS1)};             %% 原样存在：不写
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
    case first_entries(S0, Vid, infinity) of
        {ok, Es, true, S1} -> {ok, Es, S1};
        {error, _} = E     -> E
    end.

%% 顶点靠前的一段条目，够 MaxOthers 个以上不同的对端就停：
%% {ok, Entries, Complete, S'} | {error, _}。只读入用到的块——del_vertex 分轮删 hub
%% 时每轮只碰当前这几个块，不再每轮把全部块读一遍（那是 O(度数²)：20 万邻居 450 s）。
first_entries(S0, Vid, MaxOthers) ->
    #sess{io = Io} = S0,
    case sess_vs(S0, Vid) of
        {error, _} = E -> E;
        {ok, Vs, S1} ->
            case vs_first_entries(Io, Vs, MaxOthers) of
                {ok, Es, Complete, Vs1} -> {ok, Es, Complete, sess_store(S1, Vs1)};
                {error, _} = E          -> E
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
        {ok, Gs} ->
            {ok, [{D, T, C, case B of
                                {chunks, Dir} -> {chunks, dir_lbs(Dir)};
                                {entries, Es} -> {entries, e_list(Es)}
                            end} || #grp{dir = D, etype = T, count = C, body = B} <- Gs]};
        error ->
            error
    end.
