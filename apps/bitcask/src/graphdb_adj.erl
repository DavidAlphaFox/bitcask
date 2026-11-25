%% =========================================================================
%% graphdb_adj — 图层的邻接表：盘上编解码 + 读原语 + 写会话
%%
%% 设计文档：doc/graph-adjacency-pack-design-zh.md（§4 盘上契约、§5 条件写、
%% §6 写路径）；布局 2（块目录外置成 KV 上的 B+ 树、块按条数切）见
%% doc/graph-layout-2-zh.md。graphdb 是门面（API / 重试 / 遍历 / 事务包装），本模块是它
%% 唯一碰 `a` / `d` / `p` 家族字节的地方；graphdb_analytics 复用这里的编解码。
%%
%% ---- 布局 2（`g` 版本 2，新库缺省）相对布局 1 的差别 ----
%%   * 块按条数切：一块最多 chunk_entries 条（缺省 512），另有字节安全上限 chunk_max
%%     （缺省 64 KiB）；不再「超大组放宽到 组字节 / 1024」。安全阀 chunk_count_max：组大到
%%     「块数上限 × 0.7 × 每块条数」以上时每块条数随组放大。
%%   * 块数超过 dir_inline_max（缺省 16）时块目录外置成 `d` 家族的一棵 B+ 树：
%%       <1,"_g:"> d <vid:64> <dir:8> <etype:32> <level:8> <o:64> <r:64>   目录节点（35 B）
%%       DirNode = <<1:8, Level:8, Count:16, <<O:64, R:64>> × Count>>      子节点下界，升序；
%%                 首项 = 节点自己的下界；第 1 层的子节点是块；Count ≤ dir_node_max
%%     组在头里只记 <<NChunks:32, Levels:8>>（GFlags bit3 = 目录外置）；根 = (Levels, (0,0))。
%%     块数降到 dir_inline_max / 2 以下转回内联目录。
%%   * 库的 `g` 是版本 1 就照布局 1 的规则写（旧程序仍能打开）；graphdb:upgrade_layout/2
%%     单向改成版本 2，数据碰到再转。
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
%%           Body（分块、目录外置，布局 2）= <<NChunks:32, Levels:8>>
%%   GFlags: bit0 has_rank、bit1 has_props、bit2 chunked、bit3 目录外置（布局 2）
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
%%   3. Count = 实际条目数；块目录 = 实际存在的块 key（目录外置时 = 自根枚举出的第 1 层
%%      子节点下界集合；`d vid dir etype` 下没有走不到的节点）。
%%      写会话读目录树时读不到某个节点（读头之后有人改过这个顶点）⇒ 会话标过期，提交按
%%      冲突重来，不在过期的树上继续写。
%%
%% ---- IO 抽象 ----
%%   Io :: {direct, Handle}          直通：读带 LSN，提交走带条件的原子批
%%       | {txn, Tx, read | write}   事务：读走 bitcask_txn（头用 read_guarded，
%%                                   版本由 bitcask_txn 记、提交时自动带条件），
%%                                   写进事务缓冲
%% =========================================================================
-module(graphdb_adj).

-export([prefix/0, range/1, head_key/1, chunk_key/4, group_prefix/3, pkey/4, gkey/0,
         parse_chunk_key/1, dir_node_key/5, parse_dir_node_key/1,
         encode_head/1, decode_head/1, encode_chunk/1, decode_chunk/1, decode_chunk/2,
         encode_node/2, decode_node/1,
         default_cfg/0, layout1_cfg/0, layout2/1, encode_cfg/1, decode_cfg/1,
         %% 读原语
         entries/5, entries_guarded/5, edge_maps/6, neighbor_ids/4, lookup/6, counts/2,
         %% 写会话
         new_session/2, put_edge/6, del_edge/5, all_entries/2, first_entries/3,
         commit/1, commit/2,
         %% 分析 / 校验用的纯函数
         build_vertex/3, groups_info/1, out_ids/2, out_entries/2, out_entries/3, chunk_ids/1,
         xdir_check/3]).

-define(VER, 1).
-define(F_RANK,    1).
-define(F_PROPS,   2).
-define(F_CHUNKED, 4).
-define(F_XDIR,    8).
-define(PEXT, 16#FFFF).
-define(LB0, {0, 0}).
-define(LAYOUT_VER, 1).
-define(LAYOUT2_VER, 2).
-define(PREFIX, <<16#01, "_g:">>).
-define(B_OPS_MAX, 16).
-define(ENC_FAST_MIN, 32).               % 条目数达到它才走一遍式编码（小表逐条拼更快）

-record(grp, {dir      :: 0 | 1,
              etype    :: non_neg_integer(),
              count    :: non_neg_integer(),
              flags = 0 :: non_neg_integer(),        %% 分块组：各块标志的并（只升不降）
              %% 内联组：条目表（会话里改过的可能是拉链，见 elist()）。
              %% 分块组：块目录保持盘上的二进制（各块下界 <<O:64, R:64>> 依次排列）——
              %% hub 的目录上千项，解成列表再线性找块曾是 hub 点操作的大头；现在在
              %% 二进制上二分，写回时目录没变就原样复用。
              %% 目录外置的组（布局 2）：{xdir, 块数, 层数}，目录在 `d` 家族。
              body     :: {entries, elist()} | {chunks, binary()}
                        | {xdir, pos_integer(), pos_integer()}}).

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
             %% 目录树（布局 2）：节点 key → 下界表（二进制 <<O:64, R:64>> × n）
             nodes  = #{} :: #{binary() => binary()},
             ndirty = #{} :: #{binary() => true},      %% 要写的目录节点
             ndels  = #{} :: #{binary() => true},      %% 要删的目录节点
             ondisk = #{} :: #{binary() => true},      %% 读到时盘上就有的块 / 节点（外置目录
                                                       %% 的块不在 orig 里，删时靠它判断）
             stale  = false :: boolean(),              %% 读树时遇到缺失的节点 ⇒ 提交按冲突重来
             touched = false :: boolean(),
             henc :: undefined | binary()}).           %% finalize 算好的头编码（emit 复用）

-record(sess, {io :: {direct, term()} | {txn, term(), read | write},
               cfg :: map(), vs = #{} :: #{non_neg_integer() => #vs{}}}).

-type entry() :: {non_neg_integer(), non_neg_integer(), binary() | ext}.
%% 条目表：按 (O, R) 升序的列表；写会话里正在改的表是「拉链」{z, RevLeft, Right}
%%（RevLeft 逆序、全部小于 Right），游标停在上次改动处——批量加边按 (src, etype, dst,
%% rank) 排过序，同一张表上的插入是升序的，接着上次的位置找，不必每条从头走。
%% 拉链只存在于会话内（touched 的组 / dirty 的块），finalize 开头统一拍平。
%% 定宽（无属性）的表从盘上读进会话时不解码，保持二进制 {b, W, Bin, NOps}（W = 8 无
%% rank / 16 带 rank，Bin 即盘上的条目区）：单条增删在二进制上二分定位、直接拼接，
%% 写回时原样落盘——以前改一条边要把整块（约 500 条）解成列表再整个编回去。同一张
%% 表在一个会话里改到 @B_OPS_MAX 次（批量装载）就转成拉链，免得每条都拷一遍整块。
-type elist() :: [entry()] | {z, [entry()], [entry()]}
               | {b, 8 | 16, binary(), non_neg_integer()}.

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

%% 目录节点（布局 2）：层 Level（≥ 1）上下界为 {O, R} 的节点。
dir_node_key(Vid, Dir, Etype, Level, {O, R}) ->
    << ?PREFIX/binary, "d", Vid:64/big, Dir:8, Etype:32/big, Level:8,
       O:64/big, R:64/big >>.

parse_dir_node_key(<< _P:4/binary, "d", Vid:64/big, Dir:8, Etype:32/big, Level:8,
                      O:64/big, R:64/big >> = K)
  when binary_part(K, 0, 4) =:= ?PREFIX, Dir =< 1, Level >= 1 ->
    {ok, Vid, Dir, Etype, Level, {O, R}};
parse_dir_node_key(_) ->
    skip.

%% =========================================================================
%% 图参数（记在 `g` 键）
%% =========================================================================

%% 新库缺省 = 布局 2：头超 4 KiB 分块；块按条数切（512 条）、另有 64 KiB 字节安全上限；
%% 每组块数安全阀 65536（0 = 不限）；块超过 16 个时块目录外置，节点最多 256 项。
default_cfg() ->
    #{layout => 2, inline_max => 4096, chunk_max => 65536, props_max => 128,
      chunk_entries => 512, chunk_count_max => 65536, dir_inline_max => 16, dir_node_max => 256}.

%% 布局 1 的缺省（块目录总在头里、单块 ≤ 4 KiB、超大组放宽到 组字节 / 1024）。
layout1_cfg() ->
    #{layout => 1, inline_max => 4096, chunk_max => 4096, props_max => 128}.

layout2(#{layout := 2}) -> true;
layout2(_)              -> false.

encode_cfg(#{layout := 2, inline_max := I, chunk_max := C, props_max := P,
             chunk_entries := CE, chunk_count_max := CC, dir_inline_max := DI,
             dir_node_max := DN}) ->
    <<?LAYOUT2_VER:8, I:32/big, C:32/big, P:16/big, CE:32/big, CC:32/big,
      DI:16/big, DN:16/big>>;
encode_cfg(#{inline_max := I, chunk_max := C, props_max := P}) ->
    <<?LAYOUT_VER:8, I:32/big, C:32/big, P:16/big>>.

decode_cfg(<<?LAYOUT_VER:8, I:32/big, C:32/big, P:16/big>>) ->
    {ok, #{layout => 1, inline_max => I, chunk_max => C, props_max => P}};
decode_cfg(<<?LAYOUT2_VER:8, I:32/big, C:32/big, P:16/big, CE:32/big, CC:32/big,
             DI:16/big, DN:16/big>>) ->
    {ok, #{layout => 2, inline_max => I, chunk_max => C, props_max => P,
           chunk_entries => CE, chunk_count_max => CC, dir_inline_max => DI,
           dir_node_max => DN}};
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
    {F, _N, Data} = e_enc(Es),
    [<<D:8, F:8, T:32/big, C:64/big>> | Data];
enc_group(#grp{dir = D, etype = T, count = C, flags = F0, body = {chunks, Dir}}) ->
    F = (F0 band (?F_RANK bor ?F_PROPS)) bor ?F_CHUNKED,
    [<<D:8, F:8, T:32/big, C:64/big, (byte_size(Dir) div 16):32/big>>, Dir];
enc_group(#grp{dir = D, etype = T, count = C, flags = F0, body = {xdir, N, Lv}}) ->
    F = (F0 band (?F_RANK bor ?F_PROPS)) bor ?F_CHUNKED bor ?F_XDIR,
    [<<D:8, F:8, T:32/big, C:64/big, N:32/big, Lv:8>>].

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
    case F band (?F_CHUNKED bor ?F_XDIR) of
        ?F_XDIR ->
            error;                                   %% 目录外置必须同时是分块组
        X when X =:= ?F_CHUNKED bor ?F_XDIR ->
            case Rest of
                <<NC:32/big, Lv:8, Rest2/binary>> when NC > 0, Lv > 0 ->
                    dec_groups(N - 1, Rest2, {D, T},
                               [#grp{dir = D, etype = T, count = C,
                                     flags = F band (?F_RANK bor ?F_PROPS),
                                     body = {xdir, NC, Lv}} | Acc]);
                _ ->
                    error
            end;
        0 ->
            case dec_entries_s(Rest, C, F) of
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
    {F, N, Data} = e_enc(Entries),
    iolist_to_binary([<<?VER:8, F:8, N:32/big>> | Data]).

%% 条目表 → {Flags, 条数, iodata}。二进制表原样输出；列表在条目多且定宽时一遍
%% binary comprehension 编出（逐条拼小二进制在 500 条的块上是 28 µs 对 3.6 µs）。
e_enc({b, 8, Bin, _})  -> {0, byte_size(Bin) div 8, [Bin]};
e_enc({b, 16, Bin, _}) -> {?F_RANK, byte_size(Bin) div 16, [Bin]};
e_enc({z, _, _} = Z)   -> e_enc(e_list(Z));
e_enc(Es) when is_list(Es) ->
    F = flags_of(Es),
    N = length(Es),
    Data = case F of
               0 when N >= ?ENC_FAST_MIN ->
                   [<< <<O:64/big>> || {O, _, _} <- Es >>];
               ?F_RANK when N >= ?ENC_FAST_MIN ->
                   [<< <<O:64/big, R:64/big>> || {O, R, _} <- Es >>];
               _ ->
                   enc_entries(Es, F)
           end,
    {F, N, Data}.

%% 会话用的解码：定宽表不解，保持二进制（见 elist()）；带属性的照旧解成列表。
dec_entries_s(Bin, Count, F) when F band ?F_PROPS =:= 0 ->
    W = entry_width(F),
    case Bin of
        <<Body:(Count * W)/binary, Rest/binary>> -> {ok, {b, W, Body, 0}, Rest};
        _                                        -> error
    end;
dec_entries_s(Bin, Count, F) ->
    dec_entries(Bin, Count, F).

decode_chunk_s(<<?VER:8, F:8, C:32/big, Rest/binary>>) ->
    case dec_entries_s(Rest, C, F) of
        {ok, Es, <<>>} -> {ok, Es};
        _              -> error
    end;
decode_chunk_s(_) ->
    error.

decode_chunk(<<?VER:8, F:8, C:32/big, Rest/binary>>) ->
    case dec_entries(Rest, C, F) of
        {ok, Es, <<>>} -> {ok, Es};
        _              -> error
    end;
decode_chunk(_) ->
    error.

%% 同 decode_chunk/1，至多解 Limit 条（infinity = 全部）。
decode_chunk(Bin, infinity) ->
    decode_chunk(Bin);
decode_chunk(<<?VER:8, F:8, C:32/big, Rest/binary>>, Limit) when is_integer(Limit), Limit >= 0 ->
    dec_entries_lim(Rest, C, F, Limit);
decode_chunk(_, _) ->
    error.

%% 目录节点（布局 2）：下界表保持二进制（<<O:64, R:64>> × n），点查在字节上二分，
%% 要改时直接拼接——同块目录。
encode_node(Level, Lbs) when is_binary(Lbs) ->
    <<?VER:8, Level:8, (byte_size(Lbs) div 16):16/big, Lbs/binary>>.

%% {ok, Level, LbsBin} | error：长度不符、Count = 0、Level = 0、下界不严格升序都算畸形。
decode_node(<<?VER:8, Level:8, N:16/big, Lbs/binary>>)
  when N > 0, Level > 0, byte_size(Lbs) =:= N * 16 ->
    case lbs_ascending(Lbs) of
        true  -> {ok, Level, Lbs};
        false -> error
    end;
decode_node(_) ->
    error.

%% 下界严格升序：一遍走完二进制（匹配上下文复用，不切子二进制）。
lbs_ascending(<<O:64/big, R:64/big, Rest/binary>>) -> lbs_asc(Rest, O, R);
lbs_ascending(<<>>)                               -> true.

lbs_asc(<<O:64/big, R:64/big, Rest/binary>>, PO, PR)
  when O > PO; O =:= PO, R > PR ->
    lbs_asc(Rest, O, R);
lbs_asc(<<>>, _PO, _PR) ->
    true;
lbs_asc(_, _PO, _PR) ->
    false.

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
rg_groups(Io, Vid, [{D, T, F, _C, Body} | Sel], Limit, Mode, Guard, Acc, Checks) ->
    Res = case Body of
              {chunks, Dir}  -> rg_chunks(Io, Vid, D, T, Dir, Limit, Mode, Guard, [], 0, Checks);
              {xdir, _N, Lv} -> rg_xdir(Io, Vid, D, T, Lv, ?LB0, Limit, Mode, Guard, [], 0, Checks)
          end,
    case Res of
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

%% 目录外置的组（布局 2）：自根深度优先，第 1 层节点的下界表交给 rg_chunks 逐块点读；
%% Limit（整组的上限）到了就停——只取开头几条时只走最左一路。读不到的节点按空处理
%% （弱一致读，同缺块）；Guard 时它与读过的节点都记进 Checks。
rg_xdir(Io, Vid, D, T, Level, Lb, Limit, Mode, Guard, Acc, N, Checks) ->
    case dec_limit(Limit, N) of
        0 ->
            {ok, Acc, N, Checks};
        Rem ->
            Key = dir_node_key(Vid, D, T, Level, Lb),
            case read_node(Io, Key, Level) of
                {ok, Lbs, Cond} when Level =:= 1 ->
                    rg_chunks(Io, Vid, D, T, Lbs, Rem, Mode, Guard, Acc, N,
                              [{check, Key, Cond} || Guard] ++ Checks);
                {ok, Lbs, Cond} ->
                    rg_xdir_children(Io, Vid, D, T, Level - 1, Lbs, Limit, Mode, Guard, Acc, N,
                                     [{check, Key, Cond} || Guard] ++ Checks);
                {absent, Cond} ->
                    {ok, Acc, N, [{check, Key, Cond} || Guard] ++ Checks};
                {error, _} = E ->
                    E
            end
    end.

rg_xdir_children(_Io, _Vid, _D, _T, _Level, <<>>, _Limit, _Mode, _Guard, Acc, N, Checks) ->
    {ok, Acc, N, Checks};
rg_xdir_children(Io, Vid, D, T, Level, <<O:64/big, R:64/big, More/binary>>, Limit, Mode, Guard,
                 Acc, N, Checks) ->
    case rg_xdir(Io, Vid, D, T, Level, {O, R}, Limit, Mode, Guard, Acc, N, Checks) of
        {ok, Acc2, N2, Checks2} ->
            rg_xdir_children(Io, Vid, D, T, Level, More, Limit, Mode, Guard, Acc2, N2, Checks2);
        {error, _} = E ->
            E
    end.

%% 读一个目录节点：{ok, LbsBin, Cond} | {absent, Cond} | {error, _}；层号与 key 不符、
%% 解不开 ⇒ {error, {bad_adj_dir, Key}}。
read_node(Io, Key, Level) ->
    case io_head(Io, Key) of
        {ok, Bin, Cond} ->
            case decode_node(Bin) of
                {ok, Level, Lbs} -> {ok, Lbs, Cond};
                _                -> {error, {bad_adj_dir, Key}}
            end;
        Other ->
            Other
    end.

%% 目录外置的组里 (O, R) 所在块的下界（逐层点读）：{ok, Lb} | absent | {error, _}。
xlocate(Io, Vid, D, T, Level, Lb, Key) ->
    case read_node(Io, dir_node_key(Vid, D, T, Level, Lb), Level) of
        {ok, Lbs, _} when Level =:= 1 -> {ok, locate_lb(Lbs, Key)};
        {ok, Lbs, _}                  -> xlocate(Io, Vid, D, T, Level - 1, locate_lb(Lbs, Key), Key);
        {absent, _}                   -> absent;
        {error, _} = E                -> E
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
    case F band (?F_CHUNKED bor ?F_XDIR) of
        ?F_XDIR ->
            error;
        X when X =:= ?F_CHUNKED bor ?F_XDIR ->
            case Rest of
                <<NC:32/big, Lv:8, Rest2/binary>> when NC > 0, Lv > 0 ->
                    Acc2 = case Want of
                               true  -> [{D, T, F band (?F_RANK bor ?F_PROPS), C,
                                          {xdir, NC, Lv}} | Acc];
                               false -> Acc
                           end,
                    sel_groups(N - 1, Rest2, {D, T}, DirSel, Etype, Acc2);
                _ ->
                    error
            end;
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
                     raw ->
                         Es;
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

dec_fixed(raw, _T, 8, Body)    -> [{O, 0, <<>>} || <<O:64/big>> <= Body];
dec_fixed(raw, _T, 16, Body)   -> [{O, R, <<>>} || <<O:64/big, R:64/big>> <= Body];
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
                    lookup_chunk(Io, chunk_key(Vid, Dir, Etype, locate_lb(DirBin, {Other, Rank})),
                                 Other, Rank);
                {ok, [{_, _, _F, _C, {xdir, _N, Lv}}]} ->
                    case xlocate(Io, Vid, Dir, Etype, Lv, ?LB0, {Other, Rank}) of
                        {ok, Lb}       -> lookup_chunk(Io, chunk_key(Vid, Dir, Etype, Lb), Other, Rank);
                        absent         -> not_found;          %% 弱一致：读头之后树被改过
                        {error, _} = E -> E
                    end
            end
    end.

lookup_chunk(Io, Key, Other, Rank) ->
    case io_head(Io, Key) of
        {ok, <<?VER:8, CF:8, CC:32/big, Body/binary>>, _} ->
            case find_in_body(CF, CC, Body, Other, Rank) of
                error -> {error, {bad_adj_chunk, Key}};
                Res   -> Res
            end;
        {ok, _, _}     -> {error, {bad_adj_chunk, Key}};
        {absent, _}    -> not_found;
        {error, _} = E -> E
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

%% ---- 二进制下界表上的增删改（目录节点用）----

%% 按序插入（已在就不动）。
lb_insert(Bin, {O, R}) ->
    case b_find(Bin, 16, O, R) of
        {found, _}    -> Bin;
        {absent, Pos} ->
            <<A:(Pos * 16)/binary, B/binary>> = Bin,
            <<A/binary, O:64/big, R:64/big, B/binary>>
    end.

lb_delete(Bin, {O, R}) ->
    case b_find(Bin, 16, O, R) of
        {found, Pos} ->
            <<A:(Pos * 16)/binary, _:16/binary, B/binary>> = Bin,
            <<A/binary, B/binary>>;
        {absent, _} ->
            Bin
    end.

%% 子项改名：Old → New（New 落在 Old 与后一项之间，序不变）。
lb_replace(Bin, {O, R}, {NO, NR}) ->
    case b_find(Bin, 16, O, R) of
        {found, Pos} ->
            <<A:(Pos * 16)/binary, _:16/binary, B/binary>> = Bin,
            <<A/binary, NO:64/big, NR:64/big, B/binary>>;
        {absent, _} ->
            Bin
    end.

lb_first(<<O:64/big, R:64/big, _/binary>>) -> {O, R}.

lb_count(Bin) -> byte_size(Bin) div 16.

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
e_list({b, 8, Bin, _})    -> [{O, 0, <<>>} || <<O:64/big>> <= Bin];
e_list({b, 16, Bin, _})   -> [{O, R, <<>>} || <<O:64/big, R:64/big>> <= Bin];
e_list(L) when is_list(L) -> L.

e_empty([])               -> true;
e_empty({z, [], []})      -> true;
e_empty({b, _, <<>>, _})  -> true;
e_empty(_)                -> false.

%% 条目区的字节数（= 落盘后的条目区大小；二进制表不必解码）。
e_bytes({b, _, Bin, _}) -> byte_size(Bin);
e_bytes(Es)             -> body_size(e_list(Es)).

%% 带 rank 的二进制表删到一条 rank 都不剩时收窄成 8 字节宽——与「列表重新编码时
%% 标志按实际条目算」保持同样的落盘字节。只对改过的表检查。
e_canon({b, 16, Bin, N} = Es) when N > 0 ->
    case b_has_rank(Bin) of
        true  -> Es;
        false -> {b, 8, << <<O:64/big>> || <<O:64/big, _:64>> <= Bin >>, N}
    end;
e_canon({z, _, _} = Z) -> e_list(Z);
e_canon(Es)            -> Es.

b_has_rank(<<_:64, 0:64, Rest/binary>>) -> b_has_rank(Rest);
b_has_rank(<<>>)                        -> false;
b_has_rank(_)                           -> true.

%% 定宽条目区 [Lo, Hi) 上第一个 ≥ Key 的位置（下标）。
b_lower(_Bin, _W, Lo, Hi, _Key) when Lo >= Hi -> Lo;
b_lower(Bin, W, Lo, Hi, Key) ->
    Mid = (Lo + Hi) div 2,
    case b_at(Bin, W, Mid) < Key of
        true  -> b_lower(Bin, W, Mid + 1, Hi, Key);
        false -> b_lower(Bin, W, Lo, Mid, Key)
    end.

b_at(Bin, 8, I)  -> <<_:(I * 8)/binary, O:64/big, _/binary>> = Bin, {O, 0};
b_at(Bin, 16, I) -> <<_:(I * 16)/binary, O:64/big, R:64/big, _/binary>> = Bin, {O, R}.

%% {found | absent, 位置}；8 字节宽的表里问带 rank 的 key 一定不在。
b_find(Bin, W, O, R) ->
    C = byte_size(Bin) div W,
    Pos = b_lower(Bin, W, 0, C, {O, R}),
    case Pos < C andalso b_at(Bin, W, Pos) =:= {O, R} of
        true  -> {found, Pos};
        false -> {absent, Pos}
    end.

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
%% 二进制表：无属性、宽度装得下（8 字节宽只收 rank 0）且本会话改得还不多时直接拼接；
%% 否则转成列表走拉链。
ent_put({b, W, Bin, N}, {O, R, <<>>}) when N < ?B_OPS_MAX, (W =:= 16 orelse R =:= 0) ->
    case b_find(Bin, W, O, R) of
        {found, _} ->
            {<<>>, {b, W, Bin, N}};
        {absent, Pos} ->
            <<A:(Pos * W)/binary, B/binary>> = Bin,
            New = case W of
                      8  -> <<A/binary, O:64/big, B/binary>>;
                      16 -> <<A/binary, O:64/big, R:64/big, B/binary>>
                  end,
            {none, {b, W, New, N + 1}}
    end;
ent_put({b, _, _, _} = Es, E) ->
    ent_put(e_list(Es), E);
ent_put(Es, {O, R, _} = E) ->
    case e_seek(Es, {O, R}) of
        {L, [{O, R, Old} | T]} -> {Old, {z, L, [E | T]}};
        {L, Rt}                -> {none, {z, L, [E | Rt]}}
    end.

%% {Old, Es'} | {none, Es}（不存在时原样返回）。
ent_del({b, 8, _, _} = Es, _O, R) when R =/= 0 ->
    {none, Es};
ent_del({b, W, Bin, N} = Es, O, R) when N < ?B_OPS_MAX ->
    case b_find(Bin, W, O, R) of
        {found, Pos} ->
            <<A:(Pos * W)/binary, _:W/binary, B/binary>> = Bin,
            {<<>>, {b, W, <<A/binary, B/binary>>, N + 1}};
        {absent, _} ->
            {none, Es}
    end;
ent_del({b, _, _, _} = Es, O, R) ->
    case ent_del(e_list(Es), O, R) of
        {none, _} -> {none, Es};
        Found     -> Found
    end;
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
                    case decode_chunk_s(Bin) of
                        {ok, Es} -> {ok, Es, rcond(Vs#vs{chunks = Cs#{Key => Es},
                                                         ondisk = (Vs#vs.ondisk)#{Key => true}},
                                                   Key, Cond)};
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

%% ---- 目录树（布局 2）：会话内 ----
%% 节点按 key 缓存在 #vs.nodes（key → 下界表二进制）；改过的进 ndirty、要删的进 ndels、
%% 读到时盘上有的进 ondisk。直通模式读到的版本进 rconds（与块同一张表，提交时作条件）。

%% {ok, LbsBin, Vs'} | {error, _}。读不到 ⇒ 标 stale，按只有 (0,0) 一项继续算（结果不会提交）。
get_node(Io, #vs{nodes = Ns} = Vs, Key, Level) ->
    case maps:find(Key, Ns) of
        {ok, Lbs} -> {ok, Lbs, Vs};
        error ->
            case read_node(Io, Key, Level) of
                {ok, Lbs, Cond} ->
                    {ok, Lbs, rcond(Vs#vs{nodes = Ns#{Key => Lbs},
                                          ondisk = (Vs#vs.ondisk)#{Key => true}}, Key, Cond)};
                {absent, _} ->
                    {ok, <<0:128>>, Vs#vs{stale = true}};
                {error, _} = E ->
                    E
            end
    end.

set_node(#vs{nodes = Ns, ndirty = Dy, ndels = Ds} = Vs, Key, Lbs) ->
    Vs#vs{nodes = Ns#{Key => Lbs}, ndirty = Dy#{Key => true}, ndels = maps:remove(Key, Ds)}.

del_node(#vs{nodes = Ns, ndirty = Dy, ndels = Ds} = Vs, Key) ->
    Vs#vs{nodes = maps:remove(Key, Ns), ndirty = maps:remove(Key, Dy), ndels = Ds#{Key => true}}.

%% 沿树走到 Key 所在的块：{ok, Path, 块下界, Vs'} | {error, _}。
%% Path = [{Level, 节点下界}]，自第 1 层往上到根（逆序，便于自底向上改）。
xwalk(Io, Vs, Vid, D, T, Levels, Key) ->
    xwalk(Io, Vs, Vid, D, T, Levels, ?LB0, Key, []).

xwalk(Io, Vs, Vid, D, T, Level, Nlb, Key, Path) ->
    case get_node(Io, Vs, dir_node_key(Vid, D, T, Level, Nlb), Level) of
        {error, _} = E -> E;
        {ok, Lbs, Vs1} ->
            C = locate_lb(Lbs, Key),
            Path1 = [{Level, Nlb} | Path],
            case Level of
                1 -> {ok, Path1, C, Vs1};
                _ -> xwalk(Io, Vs1, Vid, D, T, Level - 1, C, Key, Path1)
            end
    end.

%% 整棵树：{ok, 全部块下界（二进制，有序）, 全部节点 key, Vs'} | {error, _}。
xall(Io, Vs, Vid, D, T, Levels) ->
    xall(Io, Vs, Vid, D, T, Levels, <<0:128>>, []).

xall(Io, Vs0, Vid, D, T, Level, Nlbs, Keys0) ->
    Res = lists:foldl(
            fun(_, {error, _} = E) -> E;
               (Nlb, {ok, Acc, Keys, Vs}) ->
                    K = dir_node_key(Vid, D, T, Level, Nlb),
                    case get_node(Io, Vs, K, Level) of
                        {ok, Lbs, Vs1} -> {ok, [Lbs | Acc], [K | Keys], Vs1};
                        {error, _} = E -> E
                    end
            end, {ok, [], Keys0, Vs0}, dir_lbs(Nlbs)),
    case Res of
        {error, _} = E -> E;
        {ok, Parts, Keys, Vs} ->
            Children = iolist_to_binary(lists:reverse(Parts)),
            case Level of
                1 -> {ok, Children, Keys, Vs};
                _ -> xall(Io, Vs, Vid, D, T, Level - 1, Children, Keys)
            end
    end.

%% 第 1 层节点（Path 的头）换成 Lbs1，自底向上处理溢出：超过 dir_node_max 对半分裂、
%% 右半的下界登记进上一层；根分裂 ⇒ 新根在上一层（下界 (0,0)），层数加一。→ {Levels', Vs'}
xput_path(Vs, Vid, D, T, Levels, [{Level, Nlb} | Up], Lbs, #{dir_node_max := Max} = Cfg) ->
    K = dir_node_key(Vid, D, T, Level, Nlb),
    case lb_count(Lbs) =< Max of
        true ->
            {Levels, set_node(Vs, K, Lbs)};
        false ->
            Half = (lb_count(Lbs) + 1) div 2,
            <<Left:(Half * 16)/binary, Right/binary>> = Lbs,
            Rlb = lb_first(Right),
            Vs1 = set_node(set_node(Vs, K, Left), dir_node_key(Vid, D, T, Level, Rlb), Right),
            case Up of
                [] ->
                    {Levels + 1, set_node(Vs1, dir_node_key(Vid, D, T, Level + 1, ?LB0),
                                          <<0:128, (element(1, Rlb)):64/big,
                                            (element(2, Rlb)):64/big>>)};
                [{PLevel, PNlb} | _] ->
                    PLbs = maps:get(dir_node_key(Vid, D, T, PLevel, PNlb), Vs1#vs.nodes),
                    xput_path(Vs1, Vid, D, T, Levels, Up, lb_insert(PLbs, Rlb), Cfg)
            end
    end.

%% 全部块下界（二进制）→ 新建一棵树（节点装满到 dir_node_max）→ {Levels, Vs'}。
xbuild(Vs, Vid, D, T, Lbs, #{dir_node_max := Max}) ->
    xbuild(Vs, Vid, D, T, 1, Lbs, Max).

xbuild(Vs0, Vid, D, T, Level, Lbs, Max) ->
    Parts = lb_parts(Lbs, Max * 16, []),
    Vs = lists:foldl(fun(P, V) -> set_node(V, dir_node_key(Vid, D, T, Level, lb_first(P)), P) end,
                     Vs0, Parts),
    case Parts of
        [_] -> {Level, Vs};
        _   -> xbuild(Vs, Vid, D, T, Level + 1,
                      << <<(element(1, lb_first(P))):64/big, (element(2, lb_first(P))):64/big>>
                         || P <- Parts >>, Max)
    end.

lb_parts(Bin, Sz, Acc) when byte_size(Bin) =< Sz -> lists:reverse([Bin | Acc]);
lb_parts(Bin, Sz, Acc) ->
    <<P:Sz/binary, Rest/binary>> = Bin,
    lb_parts(Rest, Sz, [P | Acc]).

%% 从 Path 的头那个节点里摘掉子项 X：
%%   摘空 ⇒ 删这个节点、再从上一层摘掉它（最左一路的下界是 (0,0)，块 0 从不删，摘不到根）；
%%   X 是首项 ⇒ 节点改名为新的首项（上一层跟着改，必要时继续往上）；否则就地改。
xremove(Vs, Vid, D, T, [{Level, Nlb} | Up], X) ->
    K = dir_node_key(Vid, D, T, Level, Nlb),
    Lbs = lb_delete(maps:get(K, Vs#vs.nodes), X),
    if
        Lbs =:= <<>>, Up =/= [] ->
            xremove(del_node(Vs, K), Vid, D, T, Up, Nlb);
        Lbs =:= <<>> ->
            set_node(Vs, K, Lbs);                     %% 不该发生（块 0 恒在）：留给不变式校验报
        X =:= Nlb ->
            New = lb_first(Lbs),
            Vs1 = set_node(del_node(Vs, K), dir_node_key(Vid, D, T, Level, New), Lbs),
            xrelabel(Vs1, Vid, D, T, Up, Nlb, New);
        true ->
            set_node(Vs, K, Lbs)
    end.

%% Path 的头那个节点里的子项 Old 改名为 New；Old 恰好是这个节点自己的下界 ⇒ 节点也改名，
%% 继续往上。根的下界恒为 (0,0)，不会被改名。
xrelabel(Vs, _Vid, _D, _T, [], _Old, _New) ->
    Vs;
xrelabel(Vs, Vid, D, T, [{Level, Nlb} | Up], Old, New) ->
    K = dir_node_key(Vid, D, T, Level, Nlb),
    Lbs = lb_replace(maps:get(K, Vs#vs.nodes), Old, New),
    case Nlb =:= Old of
        true  -> xrelabel(set_node(del_node(Vs, K), dir_node_key(Vid, D, T, Level, New), Lbs),
                          Vid, D, T, Up, Old, New);
        false -> set_node(Vs, K, Lbs)
    end.

%% 分块组里 (O, R) 所在块的下界：{ok, Lb, Vs'} | {error, _}。
leaf_lb(_Io, Vs, _Vid, _D, _T, {chunks, Dirb}, Key) ->
    {ok, locate_lb(Dirb, Key), Vs};
leaf_lb(Io, Vs, Vid, D, T, {xdir, _N, Lv}, Key) ->
    case xwalk(Io, Vs, Vid, D, T, Lv, Key) of
        {ok, _Path, Lb, Vs1} -> {ok, Lb, Vs1};
        {error, _} = E       -> E
    end.

%% 分块组的全部块下界（二进制）：{ok, Lbs, NodeKeys, Vs'} | {error, _}。
group_lbs(_Io, Vs, _Vid, _D, _T, {chunks, Dirb}) -> {ok, Dirb, [], Vs};
group_lbs(Io, Vs, Vid, D, T, {xdir, _N, Lv})     -> xall(Io, Vs, Vid, D, T, Lv).

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
        {ok, #grp{count = C, flags = F, body = Body} = G} ->
            case leaf_chunk(Io, Vs, Vid, Dir, T, Body, {O, R}) of
                {ok, Key, Es, Vs1} ->
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

%% 分块组里 Key 所在的块：{ok, 块 key, 条目, Vs'} | {error, _}。
leaf_chunk(Io, Vs, Vid, Dir, T, Body, Key) ->
    case leaf_lb(Io, Vs, Vid, Dir, T, Body, Key) of
        {ok, Lb, Vs1} ->
            CK = chunk_key(Vid, Dir, T, Lb),
            case get_chunk(Io, Vs1, CK) of
                {ok, Es, Vs2}  -> {ok, CK, Es, Vs2};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

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
        {ok, #grp{count = C, body = Body} = G} ->
            case leaf_chunk(Io, Vs, Vid, Dir, T, Body, {O, R}) of
                {ok, Key, Es, Vs1} ->
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
vs_first_groups(Io, Vs0, Vid, [#grp{dir = D, etype = T, body = Body} | Gs], Max, Seen, Acc) ->
    %% 目录外置的组先把整棵树读进会话（节点数是块数的 1/256 量级），再逐块走
    case group_lbs(Io, Vs0, Vid, D, T, Body) of
        {error, _} = E -> E;
        {ok, Dirb, _NKeys, Vs} ->
            case vs_first_chunks(Io, Vs, Vid, D, T, Dirb, Max, Seen, Acc) of
                {more, Vs1, Seen1, Acc1} -> vs_first_groups(Io, Vs1, Vid, Gs, Max, Seen1, Acc1);
                {stop, Vs1, Acc1}        -> {ok, lists:append(lists:reverse(Acc1)), false, Vs1};
                {error, _} = E           -> E
            end
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

%% 会话里的拉链统一拍平成列表、改过的二进制表规整宽度（e_canon）。只有 touched 的
%% 组 / dirty 的块会是拉链或改过的二进制表；没改过的二进制表原样留着，写回时直出。
flatten(#vs{groups = Gs, chunks = Cs, dirty = Dy} = Vs) ->
    Gs2 = [case G of
               #grp{body = {entries, Es}} when not is_list(Es) ->
                   G#grp{body = {entries, e_canon(Es)}};
               _ -> G
           end || G <- Gs],
    Cs2 = maps:fold(fun(K, _, A) ->
                            case A of
                                #{K := Es} when not is_list(Es) -> A#{K := e_canon(Es)};
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
            case normalize_chunked(Io, Vs, Cfg) of
                {error, _} = E ->
                    E;
                {ok, #vs{dirty = Dy} = Vs1} when map_size(Dy) =:= 0, map_size(Vs1#vs.dels) =:= 0 ->
                    {ok, [], Vs1};
                {ok, Vs1} ->
                    finalize_2(Io, Vs1#vs{touched = true}, Cfg)
            end
    end;
finalize_1(_Io, #vs{vid = Vid, groups = Gs}, _Cfg) when length(Gs) > 16#FFFF ->
    {error, {too_many_groups, Vid}};
finalize_1(Io, Vs0, Cfg) ->
    case normalize_chunked(Io, Vs0, Cfg) of
        {error, _} = E -> E;
        {ok, Vs1}      -> finalize_2(Io, Vs1, Cfg)
    end.

%% 内联组 ⟷ 分块组、内联目录 ⟷ 外置目录的转换，然后生成 op。
%% chunk_oversized 之后再 xrebalance 一次：新分块的组可能一上来就超过 dir_inline_max 块。
finalize_2(Io, Vs1, Cfg) ->
    case unchunk_small(Io, Vs1, Cfg) of
        {error, _} = E -> E;
        {ok, Vs2} ->
            case xrebalance(Io, Vs2, Cfg) of
                {error, _} = E -> E;
                {ok, Vs3} ->
                    case xrebalance(Io, chunk_oversized(Vs3, Cfg), Cfg) of
                        {error, _} = E -> E;
                        {ok, Vs4}      -> {ok, emit_ops(Vs4), Vs4}
                    end
            end
    end.

%% 分块组：脏块过大 → 分裂；空块（非块 0）→ 删；组空 → 删组与全部块（与目录节点）。
%% {ok, Vs'} | {error, _}
normalize_chunked(Io, #vs{groups = Gs} = Vs0, Cfg) ->
    lists:foldl(fun(_, {error, _} = E) -> E;
                   (#grp{body = {entries, _}}, Acc) -> Acc;
                   (G, {ok, Vs}) -> normalize_group(Io, G, Vs, Cfg)
                end, {ok, Vs0}, Gs).

normalize_group(_Io, #grp{dir = D, etype = T, count = 0, body = {chunks, Dirb}},
                #vs{vid = Vid} = Vs, _Cfg) ->
    Vs1 = lists:foldl(fun(Lb, A) -> del_chunk(A, chunk_key(Vid, D, T, Lb)) end, Vs, dir_lbs(Dirb)),
    {ok, Vs1#vs{groups = drop_group(Vs1#vs.groups, D, T)}};
normalize_group(Io, #grp{dir = D, etype = T, count = 0, body = {xdir, _, Lv}},
                #vs{vid = Vid} = Vs, _Cfg) ->
    %% 整组删空：删全部块与全部目录节点。块按「目录 = 实际块」视为盘上已有。
    case xall(Io, Vs, Vid, D, T, Lv) of
        {error, _} = E -> E;
        {ok, Lbs, NKeys, Vs1} ->
            Vs2 = lists:foldl(fun(Lb, A) ->
                                      K = chunk_key(Vid, D, T, Lb),
                                      del_chunk(A#vs{ondisk = (A#vs.ondisk)#{K => true}}, K)
                              end, Vs1, dir_lbs(Lbs)),
            Vs3 = lists:foldl(fun(K, A) -> del_node(A, K) end, Vs2, NKeys),
            {ok, Vs3#vs{groups = drop_group(Vs3#vs.groups, D, T)}}
    end;
normalize_group(Io, #grp{dir = D, etype = T, count = C, body = Body} = G,
                #vs{vid = Vid} = Vs0, Cfg) ->
    %% 只看本组里改过的块（从 dirty 表反查），不遍历整个块目录；目录只在有块被删 /
    %% 分裂时才改——hub 上绝大多数写只改一两个块的内容，目录原样复用。
    Mine = lists:sort([Lb || K <- maps:keys(Vs0#vs.dirty),
                             {ok, V, D2, T2, Lb} <- [parse_chunk_key(K)],
                             V =:= Vid, D2 =:= D, T2 =:= T]),
    {Removed, Added, Vs2} =
        lists:foldl(
          fun(Lb, {Rm, Ad, Vs}) ->
                  Key = chunk_key(Vid, D, T, Lb),
                  Es = maps:get(Key, Vs#vs.chunks),
                  case e_empty(Es) andalso Lb =/= ?LB0 of
                      true ->
                          {[Lb | Rm], Ad, del_chunk(Vs, Key)};
                      false ->
                          case split_chunk(Es, C, Cfg) of
                              [_] ->
                                  {Rm, Ad, Vs};
                              [First | More] ->
                                  VsA = set_chunk(Vs, Key, First),
                                  {NewLbsR, VsB} =
                                      lists:foldl(
                                        fun([{O, R, _} | _] = Piece, {L, VV}) ->
                                                NLb = {O, R},
                                                {[NLb | L],
                                                 set_chunk(VV, chunk_key(Vid, D, T, NLb), Piece)}
                                        end, {[], VsA}, More),
                                  {Rm, [{Lb, lists:reverse(NewLbsR)} | Ad], VsB}
                          end
                  end
          end, {[], [], Vs0}, Mine),
    case {Removed, Added, Body} of
        {[], [], _} ->
            {ok, Vs2};
        {_, _, {chunks, Dirb}} ->
            RmSet = maps:from_list([{Lb, true} || Lb <- Removed]),
            AdMap = maps:from_list(Added),
            Lbs2 = lists:append([case maps:is_key(Lb, RmSet) of
                                     true  -> [];
                                     false -> [Lb | maps:get(Lb, AdMap, [])]
                                 end || Lb <- dir_lbs(Dirb)]),
            G2 = G#grp{body = {chunks, lbs_dir(Lbs2)}},
            {ok, Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}};
        {_, _, {xdir, N, Lv}} ->
            New = lists:sort(lists:append([L || {_, L} <- Added])),
            case xdir_apply(Io, Vs2, Vid, D, T, Lv, lists:sort(Removed), New, Cfg) of
                {error, _} = E -> E;
                {ok, Lv2, Vs3} ->
                    N2 = N + length(New) - length(Removed),
                    G2 = G#grp{body = {xdir, N2, Lv2}},
                    {ok, Vs3#vs{groups = store_group(Vs3#vs.groups, G2)}}
            end
    end.

%% 外置目录上摘掉删掉的块、登记新块，最后根只剩一个子节点就降层：{ok, Levels', Vs'} | {error, _}。
xdir_apply(Io, Vs0, Vid, D, T, Lv0, Removed, New, Cfg) ->
    R1 = lists:foldl(
           fun(_, {error, _} = E) -> E;
              (Lb, {ok, Lv, Vs}) ->
                   case xwalk(Io, Vs, Vid, D, T, Lv, Lb) of
                       {ok, Path, _, Vs1} -> {ok, Lv, xremove(Vs1, Vid, D, T, Path, Lb)};
                       {error, _} = E     -> E
                   end
           end, {ok, Lv0, Vs0}, Removed),
    R2 = lists:foldl(
           fun(_, {error, _} = E) -> E;
              (Lb, {ok, Lv, Vs}) ->
                   case xwalk(Io, Vs, Vid, D, T, Lv, Lb) of
                       {ok, [{L1, N1} | _] = Path, _, Vs1} ->
                           Lbs1 = maps:get(dir_node_key(Vid, D, T, L1, N1), Vs1#vs.nodes),
                           {Lv2, Vs2} = xput_path(Vs1, Vid, D, T, Lv, Path, lb_insert(Lbs1, Lb), Cfg),
                           {ok, Lv2, Vs2};
                       {error, _} = E ->
                           E
                   end
           end, R1, New),
    case R2 of
        {error, _} = E -> E;
        {ok, Lv, Vs}   -> xshrink(Io, Vs, Vid, D, T, Lv)
    end.

xshrink(Io, Vs, Vid, D, T, Lv) when Lv > 1 ->
    RK = dir_node_key(Vid, D, T, Lv, ?LB0),
    case get_node(Io, Vs, RK, Lv) of
        {error, _} = E -> E;
        {ok, Lbs, Vs1} ->
            case lb_count(Lbs) of
                1 -> xshrink(Io, del_node(Vs1, RK), Vid, D, T, Lv - 1);
                _ -> {ok, Lv, Vs1}
            end
    end;
xshrink(_Io, Vs, _Vid, _D, _T, Lv) ->
    {ok, Lv, Vs}.

%% 布局 2：内联目录的块数超过 dir_inline_max ⇒ 外置成树；外置目录的块数降到
%% dir_inline_max / 2 以下 ⇒ 转回内联（滞回）。{ok, Vs'} | {error, _}
xrebalance(Io, #vs{groups = Gs} = Vs0, #{layout := 2, dir_inline_max := DI} = Cfg) ->
    lists:foldl(
      fun(_, {error, _} = E) -> E;
         (#grp{dir = D, etype = T, body = {chunks, Dirb}} = G, {ok, #vs{vid = Vid} = Vs})
           when byte_size(Dirb) > DI * 16 ->
              {Lv, Vs1} = xbuild(Vs, Vid, D, T, Dirb, Cfg),
              G2 = G#grp{body = {xdir, lb_count(Dirb), Lv}},
              {ok, Vs1#vs{groups = store_group(Vs1#vs.groups, G2), henc = undefined}};
         (#grp{dir = D, etype = T, body = {xdir, N, Lv}} = G, {ok, #vs{vid = Vid} = Vs})
           when N < DI div 2 ->
              case xall(Io, Vs, Vid, D, T, Lv) of
                  {error, _} = E -> E;
                  {ok, Lbs, NKeys, Vs1} ->
                      Vs2 = lists:foldl(fun(K, A) -> del_node(A, K) end, Vs1, NKeys),
                      G2 = G#grp{body = {chunks, Lbs}},
                      {ok, Vs2#vs{groups = store_group(Vs2#vs.groups, G2), henc = undefined}}
              end;
         (_, Acc) ->
              Acc
      end, {ok, Vs0}, Gs);
xrebalance(_Io, Vs, _Cfg) ->
    {ok, Vs}.

%% 单块值上限（布局 1）：超大组放宽到 组字节 / 1024，让块目录保持在约 1024 项内（§4.3）。
eff_chunk_max(Count, #{chunk_max := CM}) ->
    max(CM, (Count * 8) div 1024).

%% 布局 2 每块条数的有效上限：chunk_entries；组大到「块数安全阀 × 七成满」以上时随组放大
%% （安全阀 0 = 不限）。
eff_entries(Count, #{chunk_entries := E, chunk_count_max := M}) when M > 0 ->
    max(E, ceil_div(Count * 10, M * 7));
eff_entries(_Count, #{chunk_entries := E}) ->
    E.

ceil_div(A, B) -> (A + B - 1) div B.

%% 已有块超限就切：布局 1 按字节（超大组放宽）；布局 2 条数 / 字节两个上限取先到的，
%% 切成约等大的 k 片。没超 ⇒ [Es]（原样，二进制表不展开）。
split_chunk(Es, Count, #{layout := 2, chunk_max := B} = Cfg) ->
    E = eff_entries(Count, Cfg),
    N = e_count(Es),
    Size = 6 + e_bytes(Es),
    case N =< E andalso Size =< B of
        true  -> [Es];
        false ->
            K = lists:max([2, ceil_div(N, E), ceil_div(Size, B)]),
            split_by(e_list(Es), ceil_div(N, K), B)
    end;
split_chunk(Es, Count, Cfg) ->
    split_balanced(Es, eff_chunk_max(Count, Cfg)).

%% 内联组转分块时的切片：布局 1 按字节装满；布局 2 按条数 / 字节装满。
split_initial(Es, Count, #{layout := 2, chunk_max := B} = Cfg) ->
    split_by(Es, eff_entries(Count, Cfg), B);
split_initial(Es, Count, Cfg) ->
    split_entries(Es, eff_chunk_max(Count, Cfg)).

e_count({b, W, Bin, _}) -> byte_size(Bin) div W;
e_count(Es)             -> length(e_list(Es)).

%% 按条数与字节贪心切片（块头 6 B）：加上下一条会超过 MaxE 条或 MaxB 字节就切；每片至少一条。
split_by(Es, MaxE, MaxB) ->
    F = flags_of(Es),
    split_by(Es, F, MaxE, MaxB, 6, 0, [], []).

split_by([], _F, _ME, _MB, _Sz, _N, Cur, Acc) ->
    lists:reverse([lists:reverse(Cur) | Acc]);
split_by([E | Es], F, ME, MB, Sz, N, Cur, Acc) ->
    ESz = entry_size(E, F),
    case Cur =/= [] andalso (N >= ME orelse Sz + ESz > MB) of
        true  -> split_by(Es, F, ME, MB, 6 + ESz, 1, [E], [lists:reverse(Cur) | Acc]);
        false -> split_by(Es, F, ME, MB, Sz + ESz, N + 1, [E | Cur], Acc)
    end.

%% 已有块超限：切成 n = max(2, ⌈字节/Max⌉) 片、每片约等大（对半分裂的推广）。
%% 只超一点点时就是对半分，随机插入下两半各有余量，不会下一条又分裂。
split_balanced(Es, Max) ->
    Size = 6 + e_bytes(Es),
    case Size =< Max of
        true  -> [Es];                               %% 原样（二进制表不展开）
        false ->
            N = max(2, (Size + Max - 1) div Max),
            split_entries(e_list(Es), Size div N + 1)
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
         (#grp{body = {entries, _}}, Acc) -> Acc;
         (#grp{dir = D, etype = T, count = C, flags = F, body = Body} = G, {ok, Vs}) ->
              MinW = 8 + case F band ?F_RANK of 0 -> 0; _ -> 8 end
                       + case F band ?F_PROPS of 0 -> 0; _ -> 2 end,
              case C * MinW < Thresh of
                  false -> {ok, Vs};
                  true  -> unchunk_group(Io, Vs, G, D, T, Body, Thresh)
              end
      end, {ok, Vs0}, Gs).

unchunk_group(Io, #vs{vid = Vid} = Vs0, G, D, T, Body, Thresh) ->
    case group_lbs(Io, Vs0, Vid, D, T, Body) of
        {error, _} = E -> E;
        {ok, Lbs, NKeys, Vs} ->
            case load_group_chunks(Io, Vs, Vid, D, T, Lbs) of
                {error, _} = E -> E;
                {ok, Es, Vs1} ->
                    case body_size(Es) < Thresh of
                        false -> {ok, Vs1};
                        true ->
                            Vs2 = lists:foldl(fun(Lb, A) -> del_chunk(A, chunk_key(Vid, D, T, Lb)) end,
                                              Vs1, dir_lbs(Lbs)),
                            Vs3 = lists:foldl(fun(K, A) -> del_node(A, K) end, Vs2, NKeys),
                            G2 = G#grp{flags = 0, body = {entries, Es}},
                            {ok, Vs3#vs{groups = store_group(Vs3#vs.groups, G2), henc = undefined}}
                    end
            end
    end.

%% 头超过 inline_max → 把最大的内联组转为分块，直到放得下或没有可转的组
%% （只转体积 > inline_max / 4 的组，与 unchunk_small 的门槛构成滞回）。
%% 顺带把定稿的头编码记进 henc，emit_ops 直接用（以前量一次大小编一遍、写出时再编一遍）。
chunk_oversized(#vs{groups = Gs} = Vs, #{inline_max := IM} = Cfg) ->
    Enc = encode_head(Gs),
    case byte_size(Enc) =< IM of
        true -> Vs#vs{henc = Enc};
        false ->
            Cands = [{body_size(L), G#grp{body = {entries, L}}}
                     || #grp{body = {entries, Es}} = G <- Gs,
                        L <- [e_list(Es)], length(L) >= 2],
            case [X || {Sz, _} = X <- Cands, Sz > IM div 4] of
                [] -> Vs#vs{henc = Enc};
                Big ->
                    {_, G} = lists:max(Big),
                    chunk_oversized(chunkify(Vs, G, Cfg), Cfg)
            end
    end.

chunkify(#vs{vid = Vid} = Vs0, #grp{dir = D, etype = T, count = C, body = {entries, Es}} = G, Cfg) ->
    [First | More] = split_initial(Es, C, Cfg),
    Vs1 = set_chunk(Vs0, chunk_key(Vid, D, T, ?LB0), First),
    {Lbs, Vs2} = lists:foldl(fun([{O, R, _} | _] = Piece, {L, V}) ->
                                     {[{O, R} | L], set_chunk(V, chunk_key(Vid, D, T, {O, R}), Piece)}
                             end, {[], Vs1}, More),
    G2 = G#grp{flags = flags_of(Es), body = {chunks, lbs_dir([?LB0 | lists:reverse(Lbs)])}},
    Vs2#vs{groups = store_group(Vs2#vs.groups, G2)}.

%% 头 op（带条件）+ 块删除 + 块写入 + 目录节点删除 / 写入 + p 家族 op。
emit_ops(#vs{vid = Vid, hcond = Cond, existed = Existed, groups = Gs, henc = HEnc,
             chunks = Cs, dirty = Dy, dels = Ds, orig = Orig, extra = Extra, rconds = RC,
             nodes = Ns, ndirty = NDy, ndels = NDs, ondisk = OD}) ->
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
    %% 表曾占 degree / edge / put_edge 约 3/4 的 CPU。外置目录的块不在 orig 的头里，
    %% 靠 ondisk（读到过 / 整组拆除时按不变式记下）判断。
    Dels = case map_size(Ds) of
               0 -> [];
               _ ->
                   OnDisk = chunk_keys_of(Vid, Orig),
                   [chunk_op({remove, K}, RC) || K <- lists:sort(maps:keys(Ds)),
                                                 maps:is_key(K, OnDisk) orelse maps:is_key(K, OD)]
           end,
    Puts = [chunk_op({put, K, encode_chunk(maps:get(K, Cs))}, RC)
            || K <- lists:sort(maps:keys(Dy))],
    NDels = [chunk_op({remove, K}, RC) || K <- lists:sort(maps:keys(NDs)), maps:is_key(K, OD)],
    NPuts = [chunk_op({put, K, encode_node(node_level(K), maps:get(K, Ns))}, RC)
             || K <- lists:sort(maps:keys(NDy))],
    HeadOps ++ Dels ++ Puts ++ NDels ++ NPuts
        ++ read_checks(RC, [Dy, Ds, NDy, NDs]) ++ lists:reverse(Extra).

node_level(K) -> {ok, _, _, _, Lv, _} = parse_dir_node_key(K), Lv.

chunk_op({put, K, _} = Op, RC) ->
    case maps:find(K, RC) of {ok, C} -> cond_op(Op, C); error -> Op end;
chunk_op({remove, K} = Op, RC) ->
    case maps:find(K, RC) of {ok, C} -> cond_op(Op, C); error -> Op end.

%% 读过、没改的块 / 目录节点：发 check。
read_checks(RC, Written) ->
    [{check, K, C} || {K, C} <- lists:sort(maps:to_list(RC)),
                      not lists:any(fun(M) -> maps:is_key(K, M) end, Written)].

%% 会话读过但不改的顶点：头 + 读过的块 / 节点都发 check（它们参与了这次的决定）。
guard_ops(#vs{vid = Vid, hcond = HC, rconds = RC, dirty = Dy, dels = Ds, ndirty = NDy, ndels = NDs}) ->
    [{check, head_key(Vid), HC} || HC =/= txn] ++ read_checks(RC, [Dy, Ds, NDy, NDs]).

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

commit(#sess{io = Io, vs = M} = S, ExtraOps) ->
    case lists:any(fun(#vs{stale = St}) -> St end, maps:values(M)) of
        true  -> stale_conflict(Io);
        false -> commit_1(S, ExtraOps)
    end.

%% 读目录树时遇到缺失的节点：读头之后有人改过这个顶点，这次算出来的东西不能用。
%% 直通 ⇒ conflict（调用方重来）；事务 ⇒ 走 bitcask_txn 的重启路径（同版本守卫失败）。
stale_conflict({direct, _}) -> conflict;
stale_conflict({txn, _, _}) -> throw({bitcask_txn_restart, {conflict, stale_adj_dir}}).

commit_1(#sess{io = Io, cfg = Cfg, vs = M}, ExtraOps) ->
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
    %% 新顶点只会「内联目录 → 外置」，不读盘（Io 用不到）
    {ok, Vs} = xrebalance(none, chunk_oversized(Vs0, Cfg), Cfg),
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

%% 全库扫描（物化 / 按类型列边）用：只解头里**内联**的出边组，入边组与块目录跳过。
%% 分块的出边组的条目在它的块里，扫描方按 key 序紧跟着头读到。
%%   out_ids/2      各内联出边组的对端 id（Etype = undefined 取全部类型）
%%   out_entries/2  某一类型内联出边组的条目 [{Dst, Rank, Props}]
%%   chunk_ids/1    一个块里的对端 id
out_ids(HeadBin, Etype) ->
    inline_out(HeadBin, Etype, ids).

out_entries(HeadBin, Etype) when is_integer(Etype) ->
    inline_out(HeadBin, Etype, raw).

%% 同 out_entries/2，至多解 Limit 条（infinity = 全部）。截断时只解前 Limit 条：
%% 定宽组取条目区的前 Limit × 宽度字节，带属性的组逐条解到第 Limit 条为止
%% （其后的字节不再校验）。
out_entries(HeadBin, Etype, infinity) ->
    out_entries(HeadBin, Etype);
out_entries(HeadBin, Etype, Limit) when is_integer(Etype), is_integer(Limit), Limit >= 0 ->
    case sel_groups(HeadBin, 0, Etype) of
        error     -> error;
        {ok, Sel} -> inline_out_lim(Sel, Limit, [])
    end.

inline_out_lim(_Sel, 0, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
inline_out_lim([], _Limit, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
inline_out_lim([{_D, _T, F, C, {inline, Body}} | Sel], Limit, Acc) ->
    case dec_entries_lim(Body, C, F, Limit) of
        {ok, L} -> inline_out_lim(Sel, Limit - length(L), [L | Acc]);
        error   -> error
    end;
inline_out_lim([{_D, _T, _F, _C, _Chunked} | Sel], Limit, Acc) ->
    inline_out_lim(Sel, Limit, Acc).

%% 条目区（Count 条）的前 min(Count, Limit) 条，raw 形态 {O, R, P}。
%% Limit ≥ Count 时与整组解码同样做完整校验。
dec_entries_lim(Body, Count, F, Limit) when Limit >= Count ->
    case dec_entries(Body, Count, F) of
        {ok, Es, <<>>} -> {ok, Es};
        _              -> error
    end;
dec_entries_lim(Body, Count, F, Limit) when F band ?F_PROPS =:= 0 ->
    W = entry_width(F),
    case byte_size(Body) =:= Count * W of
        false -> error;
        true  -> {ok, dec_fixed(raw, 0, W, binary_part(Body, 0, Limit * W))}
    end;
dec_entries_lim(Body, _Count, F, Limit) ->
    case dec_prop_entries(Body, Limit, F band ?F_RANK =/= 0, []) of
        {ok, Es, _Rest} -> {ok, Es};
        error           -> error
    end.

inline_out(HeadBin, Etype, Mode) ->
    case sel_groups(HeadBin, 0, Etype) of
        error     -> error;
        {ok, Sel} -> inline_out_1(Sel, Mode, [])
    end.

inline_out_1([], _Mode, Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
inline_out_1([{_D, T, F, C, {inline, Body}} | Sel], Mode, Acc) ->
    case dec_body(Mode, T, F, C, Body) of
        {ok, L} -> inline_out_1(Sel, Mode, [L | Acc]);
        error   -> error
    end;
inline_out_1([{_D, _T, _F, _C, _Chunked} | Sel], Mode, Acc) ->
    inline_out_1(Sel, Mode, Acc).

chunk_ids(<<?VER:8, F:8, C:32/big, Body/binary>>) -> dec_body(ids, 0, F, C, Body);
chunk_ids(_)                                      -> error.

%% 全库校验用：核对一棵目录树。Nodes = 扫 `d` 家族得到的
%% #{{Vid, Dir, Etype, Level, Lb} => {ok, Level, LbsBin} | error}。
%% → {全部块下界（列表，按树序）, 用到的节点 key 列表, Problems}：节点在、解得开、层号对、
%% 首项 = 节点下界、块下界整体严格升序、第 1 层项数之和 = 头里记的块数 N。
xdir_check(Nodes, {Vid, D, T}, {N, Lv}) ->
    {Lbs, Used, Bad} = xdir_check_level(Nodes, Vid, D, T, Lv, [?LB0], [], []),
    Order = case lbs_ascending(lbs_dir(Lbs)) of
                true  -> [];
                false -> [{dir_order, Vid, D, T}]
            end,
    Cnt = case length(Lbs) =:= N of
              true  -> [];
              false -> [{dir_chunk_count, Vid, D, T, N, length(Lbs)}]
          end,
    {Lbs, Used, Bad ++ Order ++ Cnt}.

xdir_check_level(Nodes, Vid, D, T, Level, Nlbs, Used0, Bad0) ->
    {ChildrenR, Used, Bad} =
        lists:foldl(
          fun(Nlb, {Acc, U, B}) ->
                  K = {Vid, D, T, Level, Nlb},
                  case maps:find(K, Nodes) of
                      error ->
                          {Acc, U, [{missing_dir_node, K} | B]};
                      {ok, error} ->
                          {Acc, [K | U], [{bad_dir_node, K} | B]};
                      {ok, {ok, L, Bin}} ->
                          Cl = dir_lbs(Bin),
                          B2 = if L =/= Level -> [{dir_node_level, K, L} | B];
                                  hd(Cl) =/= Nlb -> [{dir_node_bound, K} | B];
                                  true -> B
                               end,
                          {lists:reverse(Cl, Acc), [K | U], B2}
                  end
          end, {[], Used0, Bad0}, Nlbs),
    Children = lists:reverse(ChildrenR),
    case Level of
        1 -> {Children, Used, Bad};
        _ -> xdir_check_level(Nodes, Vid, D, T, Level - 1, Children, Used, Bad)
    end.

%% 头 binary → [{Dir, Etype, Count, {entries, [Entry]} | {chunks, [Lb]} | {xdir, N, Levels}}]
groups_info(Bin) ->
    case decode_head(Bin) of
        {ok, Gs} ->
            {ok, [{D, T, C, case B of
                                {chunks, Dir} -> {chunks, dir_lbs(Dir)};
                                {xdir, N, Lv} -> {xdir, N, Lv};
                                {entries, Es} -> {entries, e_list(Es)}
                            end} || #grp{dir = D, etype = T, count = C, body = B} <- Gs]};
        error ->
            error
    end.
