%% =========================================================================
%% graphdb — 图存储层（KV per-key：k = 顶点，OKI range 遍历）
%%
%% 设计文档：doc/graph-layer-design-zh.md（2026-09 重订版）。本模块落地其中
%% 的 P1（key codec + CRUD + 前缀遍历 + del_vertex 级联 + etype registry）
%% 与 P2（BFS / k-hop / 双向最短路）。
%%
%% 布局（家族字节 + 定宽大端，零分隔符；字典序 = 数值序）：
%%
%%   n  <vid:64>                          → 顶点内容（透传给 bitcask:put，
%%                                          binary 或 #{text=>...} Doc 均可）
%%   e  <src:64> <etype:32> <dst:64> <rank:64>   → 出边（值 = 边属性 binary）
%%   ei <dst:64> <etype:32> <src:64> <rank:64>   → 反向导航键（值恒 <<>>）
%%   t  <etype:32>                        → etype intern 名字
%%   tn <len:16> <name>                   → name → etype id
%%
%% 关键性质：
%%   * 取邻居 = 一次 OKI 前缀 range，O(出度)（bitcask:range/3，[Lo,Hi) 字典序）
%%   * 点查   = O(1) keydir + 单 pread
%%   * 边的双向键经 put_batch_atomic 原子双写——崩溃后反向键永不悬挂
%%   * 每写即持久；无整图物化、无检查点、无 value_too_large 封顶
%%
%% ⚠️ 一致性：单次 range 是 per-key 弱一致（与 parallel_scan 同档，非 fold
%% 快照）；多跳遍历**跨跳弱一致**——遍历期间的并发写可能部分可见。需要全局
%% 快照的算法请用 bitcask:fold（见设计文档 §6.5）。
%%
%% ⚠️ 病理 vid 防御：vid 首字节为 'i'(0x69) / 't'(0x74)（即 vid ≥ 16#6900…，
%% ~7.5e18 量级）时，`ei` / `et` 家族 key 可能落入 `e` 家族的前缀扫描区间。
%% 所有扫描解析走 strict parse（家族字节 + 精确 29/30 字节 + owner vid 校验），
%% 不匹配的条目一律跳过——泄漏的键被无害过滤。
%%
%% ⚠️ del_vertex 对度数 > @DEL_BATCH 的顶点分多个原子批删除：跨批不原子
%% （设计文档 §5 批量级联的 MVP 取舍）。
%%
%% 复杂度注记：BFS 的 frontier 展开是一顶点一进程并行（设计文档 §6.2），
%% 每个进程自开自用自己的 range 迭代器（迭代器不可跨进程共享的契约天然
%% 满足）；结果按 frontier 顺序收集，输出确定。
%% =========================================================================
-module(graphdb).

-export([open/1, open/2, close/1,

         nkey/1, ekey/3, ekey/4, eikey/3, eikey/4, succ/1,

         put_vertex/3, get_vertex/2, del_vertex/2,
         put_edge/4, put_edge/5, edge/4, edge/5, del_edge/4, del_edge/5,

         out_edges/2, out_edges/3, in_edges/2, in_edges/3,
         neighbors/3, degree/3,

         bfs/3, k_hop/4, shortest_path/3, shortest_path/4,

         register_etype/2, etype_id/2, etype_name/2]).

-define(DEL_BATCH, 500).
-define(VID_MAX,  16#FFFFFFFFFFFFFFFF).
-define(ETYPE_MAX, 16#FFFFFFFF).
-define(RANK_MAX,  16#FFFFFFFFFFFFFFFF).
-define(EXPAND_TIMEOUT_MS, 30000).
-define(ROOT, root).

-type handle() :: term().                       %% bitcask:open/2 的返回值，不透明透传
-type vid()    :: 0..16#FFFFFFFFFFFFFFFF.
-type etype()  :: 0..16#FFFFFFFF.
-type rank()   :: 0..16#FFFFFFFFFFFFFFFF.
-type edge()   :: #{src => vid(), etype => etype(), dst => vid(),
                    rank => rank(), props => binary()}.
-type dir()    :: out | in | both.
-type bfs_opts() :: #{depth => non_neg_integer() | infinity,   %% 默认 infinity
                      dir   => dir(),                          %% 默认 out
                      etype => etype(),                        %% 默认不过滤
                      visit => fun((vid(), non_neg_integer()) -> term())}.
-type edge_opts() :: #{rank  => rank(),                        %% 默认 0
                       props => binary()}.                     %% 默认 <<>>

-export_type([handle/0, vid/0, etype/0, rank/0, edge/0, dir/0,
              bfs_opts/0, edge_opts/0]).

%% =========================================================================
%% open / close — 薄透传（Handle 形态与语义同 bitcask）
%% =========================================================================

open(Dir) -> bitcask:open(Dir).
open(Dir, Opts) -> bitcask:open(Dir, Opts).
close(Handle) -> bitcask:close(Handle).

%% =========================================================================
%% key codec（公开以便测试 / 工具复用；调用方请勿手工拼这些 key）
%% =========================================================================

%% 顶点 key：<<"n">> ++ vid 大端 8 字节。
nkey(Vid) ->
    ok = v_v64(Vid),
    <<"n", Vid:64/big>>.

%% 出边 key：29 字节。rank 缺省 0（简单图：同 (src,etype,dst) 至多一条）。
ekey(Src, Etype, Dst) -> ekey(Src, Etype, Dst, 0).
ekey(Src, Etype, Dst, Rank) ->
    ok = v_v64(Src), ok = v_t32(Etype), ok = v_v64(Dst), ok = v_r64(Rank),
    <<"e", Src:64/big, Etype:32/big, Dst:64/big, Rank:64/big>>.

%% 反向导航键：30 字节，值恒 <<>>（属性只在正向存一份——设计文档 §5 写放大账）。
eikey(Dst, Etype, Src) -> eikey(Dst, Etype, Src, 0).
eikey(Dst, Etype, Src, Rank) ->
    ok = v_v64(Dst), ok = v_t32(Etype), ok = v_v64(Src), ok = v_r64(Rank),
    <<"ei", Dst:64/big, Etype:32/big, Src:64/big, Rank:64/big>>.

%% 字典序后继：去尾部连续 0xFF 字节、末字节 +1；全 0xFF → undefined（无上界）。
%% 例：succ(<<"ab">>) = <<"ac">>，succ(<<"a",255>>) = <<"b">>。
-spec succ(binary()) -> binary() | undefined.
succ(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    Rev = lists:reverse(binary_to_list(Bin)),
    case do_succ(Rev) of
        undefined -> undefined;
        L         -> list_to_binary(lists:reverse(L))
    end.

do_succ([])           -> undefined;             %% 全 0xFF：无上界
do_succ([255 | Rest]) -> do_succ(Rest);
do_succ([B | Rest])   -> [B + 1 | Rest].        %% B < 255（255 已被上一子句吃掉）

%% strict 解析：非本家族 / 长度不符 → skip（见模块头「病理 vid 防御」）。
parse_e(<<"e", Src:64/big, Etype:32/big, Dst:64/big, Rank:64/big>>) ->
    {ok, Src, Etype, Dst, Rank};
parse_e(_) ->
    skip.

parse_ei(<<"ei", Dst:64/big, Etype:32/big, Src:64/big, Rank:64/big>>) ->
    {ok, Dst, Etype, Src, Rank};
parse_ei(_) ->
    skip.

%% =========================================================================
%% 顶点
%% =========================================================================

%% Doc 为 binary，或 #{text => ...} 等 bitcask:put 支持的文档形态
%%（索引模式下自动进 BM25 / 向量——设计文档 §5）。
put_vertex(Handle, Vid, Doc) ->
    _ = nkey(Vid),                              %% 借 codec 校验 vid
    bitcask:put(Handle, nkey(Vid), Doc).

get_vertex(Handle, Vid) ->
    normalize_not_found(bitcask:get(Handle, nkey(Vid))).

%% 级联删除：先收集全部 incident 边的双向 key，再连同顶点 key 一并删除。
%% 度数 ≤ @DEL_BATCH 的顶点单批原子；超过则分批（跨批不原子，见模块头）。
del_vertex(Handle, Vid) ->
    case {Vid, out_edges(Handle, Vid), in_edges(Handle, Vid)} of
        {{error, _} = E, _, _} -> E;
        {_, {error, _} = E, _} -> E;
        {_, _, {error, _} = E} -> E;
        {_, {ok, Out}, {ok, In}} ->
            %% 每条 incident 边（无论从哪侧收集）都要摘掉正向 + 反向两个键；
            %% 自环会在两侧各出现一次 → 重复 remove，原子批按 LWW apply，无害。
            PairF = fun(#{src := S, etype := T, dst := D, rank := R}) ->
                        [{remove, ekey(S, T, D, R)}, {remove, eikey(D, T, S, R)}]
                    end,
            PairI = fun(#{dst := D, etype := T, src := S, rank := R}) ->
                        [{remove, ekey(S, T, D, R)}, {remove, eikey(D, T, S, R)}]
                    end,
            Ops = lists:flatmap(PairF, Out)
                ++ lists:flatmap(PairI, In)
                ++ [{remove, nkey(Vid)}],
            del_chunks(Handle, Ops)
    end.

del_chunks(_Handle, []) -> ok;
del_chunks(Handle, Ops) ->
    {Chunk, Rest} = take_at_most(Ops, ?DEL_BATCH),
    case bitcask:put_batch_atomic(Handle, Chunk) of
        ok    -> del_chunks(Handle, Rest);
        Error -> Error
    end.

take_at_most(Ops, N) -> take_at_most(Ops, N, []).
take_at_most(Ops, 0, Acc) -> {lists:reverse(Acc), Ops};
take_at_most([], _N, Acc) -> {lists:reverse(Acc), []};
take_at_most([Op | Rest], N, Acc) -> take_at_most(Rest, N - 1, [Op | Acc]).

%% =========================================================================
%% 边 — 双向键原子双写（设计文档 §5）
%% =========================================================================

put_edge(Handle, Src, Etype, Dst) -> put_edge(Handle, Src, Etype, Dst, #{}).
put_edge(Handle, Src, Etype, Dst, Opts) when is_map(Opts) ->
    Rank  = maps:get(rank, Opts, 0),
    Props = maps:get(props, Opts, <<>>),
    true = is_binary(Props) orelse erlang:error(badarg, [Handle, Src, Etype, Dst, Opts]),
    _ = ekey(Src, Etype, Dst, Rank),            %% 借 codec 校验四元组
    bitcask:put_batch_atomic(
      Handle, [{put, ekey(Src, Etype, Dst, Rank), Props},
               {put, eikey(Dst, Etype, Src, Rank), <<>>}]).

%% 点查（rank = 0 的简单图语义）。upsert 后读到的是最后一次写入。
edge(Handle, Src, Etype, Dst) -> edge(Handle, Src, Etype, Dst, 0).
edge(Handle, Src, Etype, Dst, Rank) ->
    case bitcask:get(Handle, ekey(Src, Etype, Dst, Rank)) of
        {ok, Props} when is_binary(Props) ->
            {ok, #{src => Src, etype => Etype, dst => Dst,
                   rank => Rank, props => Props}};
        {ok, _} -> {error, invalid_edge_props};
        Other   -> normalize_not_found(Other)
    end.

del_edge(Handle, Src, Etype, Dst) -> del_edge(Handle, Src, Etype, Dst, 0).
del_edge(Handle, Src, Etype, Dst, Rank) ->
    _ = ekey(Src, Etype, Dst, Rank),
    bitcask:put_batch_atomic(Handle, [{remove, ekey(Src, Etype, Dst, Rank)},
                                      {remove, eikey(Dst, Etype, Src, Rank)}]).

%% =========================================================================
%% 邻接扫描 — OKI 前缀 range（设计文档 §6.1）
%%
%% Opts（map）：
%%   etype => T     收窄到单一边类型（谓词左到右下推：前缀 +4 字节）
%%   limit => N     最多返回 N 条（hub 顶点提前停）
%%
%% ⚠️ per-key 弱一致：扫描期间的并发写可能部分可见。
%% =========================================================================

out_edges(Handle, Vid) -> out_edges(Handle, Vid, #{}).
out_edges(Handle, Vid, Opts) when is_map(Opts) ->
    {Lo, Hi} = out_range(Vid, maps:get(etype, Opts, undefined)),
    Limit = opt_limit(Opts),
    Owner = Vid,
    range_take(Handle, Lo, Hi, Limit,
               fun(K, V) ->
                   case parse_e(K) of
                       {ok, Src, T, D, R} when Src =:= Owner ->
                           {ok, #{src => Src, etype => T, dst => D,
                                  rank => R, props => maybe_props(V)}};
                       _ -> skip
                   end
               end).

in_edges(Handle, Vid) -> in_edges(Handle, Vid, #{}).
in_edges(Handle, Vid, Opts) when is_map(Opts) ->
    {Lo, Hi} = in_range(Vid, maps:get(etype, Opts, undefined)),
    Limit = opt_limit(Opts),
    Owner = Vid,
    range_take(Handle, Lo, Hi, Limit,
               fun(K, V) ->
                   case parse_ei(K) of
                       {ok, Dst, T, S, R} when Dst =:= Owner ->
                           {ok, #{dst => Dst, etype => T, src => S,
                                  rank => R, props => maybe_props(V)}};
                       _ -> skip
                   end
               end).

%% 双向邻居：out ++ in 去重保序（顶点自身/自环不特殊处理）。
neighbors(Handle, Vid, Dir) when Dir =:= out; Dir =:= in ->
    edge_endpoints(Handle, Vid, Dir);
neighbors(Handle, Vid, both) ->
    case {edge_endpoints(Handle, Vid, out), edge_endpoints(Handle, Vid, in)} of
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E;
        {{ok, Out}, {ok, In}} -> {ok, dedupe(Out ++ In)}
    end.

edge_endpoints(Handle, Vid, out) ->
    case out_edges(Handle, Vid) of
        {error, _} = E -> E;
        {ok, Edges}    -> {ok, [D || #{dst := D} <- Edges]}
    end;
edge_endpoints(Handle, Vid, in) ->
    case in_edges(Handle, Vid) of
        {error, _} = E -> E;
        {ok, Edges}    -> {ok, [S || #{src := S} <- Edges]}
    end.

%% 度数：按需计数（deg 计数键家族是设计文档 P3，未启用）。
degree(Handle, Vid, Etype) ->
    {Lo, Hi} = out_range(Vid, Etype),
    case range_take(Handle, Lo, Hi, infinity, fun(_K, _V) -> {ok, count} end) of
        {error, _} = E -> E;
        {ok, Items}    -> {ok, length(Items)}
    end.

%% [Lo, Hi) 构造：谓词左到右下推——给 vid 收全部，给 vid+etype 收窄一段。
out_range(Vid, undefined) ->
    Lo = <<"e", Vid:64/big>>,
    {Lo, succ(Lo)};
out_range(Vid, Etype) ->
    ok = v_t32(Etype),
    Lo = <<"e", Vid:64/big, Etype:32/big>>,
    {Lo, succ(Lo)}.

in_range(Vid, undefined) ->
    Lo = <<"ei", Vid:64/big>>,
    {Lo, succ(Lo)};
in_range(Vid, Etype) ->
    ok = v_t32(Etype),
    Lo = <<"ei", Vid:64/big, Etype:32/big>>,
    {Lo, succ(Lo)}.

%% =========================================================================
%% 遍历 — BFS / k-hop / 双向最短路（设计文档 §6.2–§6.4）
%%
%% frontier 展开是一顶点一进程并行；每个进程自开自用 range 迭代器
%%（bitcask Cask 句柄多线程安全；单迭代器单进程契约天然满足）。
%% 输出按「frontier 顺序 × 层序」确定。
%% =========================================================================

%% 返回 {ok, [{Vid, Depth}]}，含起点（depth 0），按 BFS 发现序。
-spec bfs(handle(), vid(), bfs_opts()) -> {ok, [{vid(), non_neg_integer()}]} | {error, term()}.
bfs(Handle, Start, Opts) when is_map(Opts) ->
    _ = nkey(Start),
    MaxDepth = maps:get(depth, Opts, infinity),
    true = (is_integer(MaxDepth) andalso MaxDepth >= 0) orelse (MaxDepth =:= infinity)
        orelse erlang:error(badarg, [Handle, Start, Opts]),
    Dir = maps:get(dir, Opts, out),
    true = (Dir =:= out orelse Dir =:= in orelse Dir =:= both)
        orelse erlang:error(badarg, [Handle, Start, Opts]),
    Etype = maps:get(etype, Opts, undefined),
    Visit = maps:get(visit, Opts, undefined),
    maybe_visit(Visit, Start, 0),
    bfs_layers(Handle, [Start], #{Start => true}, 0, MaxDepth,
               Dir, Etype, Visit, [{Start, 0}]).

bfs_layers(_Handle, _Frontier, _Visited, Depth, MaxDepth, _Dir, _Etype, _Visit,
           Acc) when Depth >= MaxDepth ->
    {ok, Acc};
bfs_layers(Handle, Frontier, Visited, Depth, MaxDepth, Dir, Etype, Visit, Acc) ->
    Nbrs = expand(Handle, Frontier, Dir, Etype),
    {FreshR, Visited2} =
        lists:foldl(fun(N, {Fs, M}) ->
                        case maps:is_key(N, M) of
                            true  -> {Fs, M};
                            false -> {[N | Fs], M#{N => true}}
                        end
                    end,
                    {[], Visited}, Nbrs),
    case lists:reverse(FreshR) of
        [] -> {ok, Acc};
        Fresh ->
            D1 = Depth + 1,
            [maybe_visit(Visit, N, D1) || N <- Fresh],
            bfs_layers(Handle, Fresh, Visited2, D1, MaxDepth, Dir, Etype, Visit,
                       Acc ++ [{N, D1} || N <- Fresh])
    end.

%% k-hop 邻域：距起点 1..K 跳的顶点（不含起点），BFS 发现序。
k_hop(Handle, Start, K, Opts) when is_map(Opts) ->
    case bfs(Handle, Start, Opts#{depth => K}) of
        {error, _} = E -> E;
        {ok, Reach}    -> {ok, [V || {V, D} <- Reach, D > 0]}
    end.

%% 双向最短路（有向：前进沿 out，回溯沿 in；每次展开较小一侧）。
%% 返回 {ok, [Src, ..., Dst]} | {error, no_path}。
shortest_path(Handle, Src, Dst) -> shortest_path(Handle, Src, Dst, #{}).
shortest_path(_Handle, Src, Dst, _Opts) when Src =:= Dst ->
    _ = nkey(Src), {ok, [Src]};
shortest_path(Handle, Src, Dst, Opts) when is_map(Opts) ->
    _ = nkey(Src), _ = nkey(Dst),
    Etype = maps:get(etype, Opts, undefined),
    bidir(Handle, Src, Dst, Etype,
          #{Src => ?ROOT}, [Src], #{Dst => ?ROOT}, [Dst]).

%% 每轮：选 frontier 较小的一侧展开一层；新节点命中对侧 visited → 拼路径。
%% 父指针：fwd 侧 parent = 发现者（指向起点方向）；bwd 侧展开用 in 边
%%（找到的是前驱），parent = 发现者（指向终点方向）——两侧父链都指向
%% 本侧 root，stitch 时天然拼成 Src→Dst。
bidir(Handle, Src, Dst, Etype, FwdMap, FwdF, BwdMap, BwdF) ->
    case length(FwdF) =< length(BwdF) of
        true ->
            case expand_layer(Handle, FwdF, out, Etype, FwdMap) of
                {[], _FwdMap2} ->
                    {error, no_path};
                {NewF, FwdMap2} ->
                    case first_in(NewF, BwdMap) of
                        not_found ->
                            bidir(Handle, Src, Dst, Etype, FwdMap2, NewF, BwdMap, BwdF);
                        M ->
                            {ok, stitch(M, FwdMap2, BwdMap)}
                    end
            end;
        false ->
            case expand_layer(Handle, BwdF, in, Etype, BwdMap) of
                {[], _BwdMap2} ->
                    {error, no_path};
                {NewF, BwdMap2} ->
                    case first_in(NewF, FwdMap) of
                        not_found ->
                            bidir(Handle, Src, Dst, Etype, FwdMap, FwdF, BwdMap2, NewF);
                        M ->
                            {ok, stitch(M, FwdMap, BwdMap2)}
                    end
            end
    end.

%% 展开一层：新节点并入 visited（parent = 发现者），去重保序。
%% 返回 {NewFrontier, Map2}；frontier 耗尽 → {[], Map}。
expand_layer(Handle, Frontier, Dir, Etype, Map) ->
    {NewFR, Map2} =
        lists:foldl(fun(V, {Fs, M}) ->
                        Nbrs = neighbor_list(Handle, V, Dir, Etype),
                        lists:foldl(fun(N, {Fs2, M2}) ->
                                        case maps:is_key(N, M2) of
                                            true  -> {Fs2, M2};
                                            false -> {[N | Fs2], M2#{N => V}}
                                        end
                                    end,
                                    {Fs, M}, Nbrs)
                    end,
                    {[], Map}, Frontier),
    {lists:reverse(NewFR), Map2}.

first_in([], _Map) -> not_found;
first_in([V | Rest], Map) ->
    case maps:is_key(V, Map) of
        true  -> V;
        false -> first_in(Rest, Map)
    end.

%% 路径拼接：Head = walk_up(M, FwdMap) = [Src..M]（fwd root 在 Src）；
%% Tail = walk_up(M, BwdMap) = [Dst..M]（bwd root 在 Dst），反转得 [M..Dst]。
%% 拼接去掉重复的 meet 点。
stitch(M, FwdMap, BwdMap) ->
    Head = walk_up(M, FwdMap, []),
    Tail = lists:reverse(walk_up(M, BwdMap, [])),
    Head ++ tl(Tail).

walk_up(V, Map, Acc) ->
    case maps:get(V, Map) of
        ?ROOT               -> [V | Acc];   %% [root .. V]，Acc 已是 V→root 的中段
        P when is_integer(P) -> walk_up(P, Map, [V | Acc])
    end.

%% =========================================================================
%% etype registry（设计文档 §3.4：t / tn 家族）
%%
%% ⚠️ 注册是「读-判-写」，并发盲注册同名会双 id 分叉——低频操作，调用方须
%% 串行化（或建库时一次性注册，open-time schema）。
%% =========================================================================

register_etype(Handle, Name) when is_binary(Name), Name =/= <<>>,
                                  byte_size(Name) < 16#FFFF ->
    case etype_id(Handle, Name) of
        {ok, _} = Ok ->
            Ok;
        {error, not_found} ->
            case next_etype_id(Handle) of
                {error, _} = E ->
                    E;
                {ok, Next} ->
                    Ops = [{put, <<"t", Next:32/big>>, Name},
                           {put, tnkey(Name), <<Next:32/big>>}],
                    case bitcask:put_batch_atomic(Handle, Ops) of
                        ok    -> {ok, Next};
                        Error -> Error
                    end
            end
    end;
register_etype(_Handle, Name) -> erlang:error(badarg, [Name]).

etype_id(Handle, Name) when is_binary(Name) ->
    case bitcask:get(Handle, tnkey(Name)) of
        {ok, <<Id:32/big>>} -> {ok, Id};
        {ok, _}             -> {error, invalid_etype_record};
        not_found           -> {error, not_found};
        {error, _} = E      -> E
    end.

etype_name(Handle, Id) ->
    ok = v_t32(Id),
    case bitcask:get(Handle, <<"t", Id:32/big>>) of
        {ok, Name} when is_binary(Name) -> {ok, Name};
        {ok, _}                         -> {error, invalid_etype_record};
        not_found                       -> {error, not_found};
        {error, _} = E                  -> E
    end.

tnkey(Name) -> <<"tn", (byte_size(Name)):16/big, Name/binary>>.

%% t 家族扫描：["t", "u")（"u" = succ("t")）。同区间里会混进 "tn"/"t…" 更长的
%% key（如 "tn…"），strict 5 字节解析过滤。id 从 1 起。
next_etype_id(Handle) ->
    case bitcask:range(Handle, {<<"t">>, <<"u">>}) of
        {error, _} = E -> E;
        Entries ->
            Ids = [Id || {<<"t", Id:32/big>>, _V} <- Entries],
            {ok, lists:max([0 | Ids]) + 1}
    end.

%% =========================================================================
%% 内部
%% =========================================================================

%% 一顶点一进程展开（设计文档 §6.2）；结果按 frontier 顺序收齐，输出确定。
expand(Handle, Frontier, Dir, Etype) ->
    Mons = [spawn_monitor(fun() -> exit({graphdb, neighbor_list(Handle, V, Dir, Etype)}) end)
            || V <- Frontier],
    lists:append([receive
                      {'DOWN', MRef, process, _Pid, {graphdb, L}} -> L;
                      {'DOWN', MRef, process, _Pid, Reason} ->
                          erlang:error({graphdb_expand, Reason})
                  after ?EXPAND_TIMEOUT_MS ->
                          erlang:error(graphdb_expand_timeout)
                  end
                  || {_, MRef} <- Mons]).

neighbor_list(Handle, V, out, Etype) ->
    case out_edges(Handle, V, etype_opt(Etype)) of
        {ok, Edges}    -> [D || #{dst := D} <- Edges];
        {error, _} = E -> erlang:error(E)
    end;
neighbor_list(Handle, V, in, Etype) ->
    case in_edges(Handle, V, etype_opt(Etype)) of
        {ok, Edges}    -> [S || #{src := S} <- Edges];
        {error, _} = E -> erlang:error(E)
    end;
neighbor_list(Handle, V, both, Etype) ->
    neighbor_list(Handle, V, out, Etype) ++ neighbor_list(Handle, V, in, Etype).

etype_opt(undefined) -> #{};
etype_opt(Etype) when is_integer(Etype) -> #{etype => Etype}.

maybe_visit(undefined, _Vid, _Depth) -> ok;
maybe_visit(Visit, Vid, Depth) when is_function(Visit, 2) -> _ = Visit(Vid, Depth), ok.

%% 前缀扫描 + 可选 limit：超限即抛出携带已收集结果（range_fold 的 after 兜底
%% 会释放迭代器）。仅捕获本模块的 throw，其余异常原样传播。
range_take(Handle, Lo, Hi, Limit, Parse) when Limit =:= infinity ->
    do_range_take(Handle, Lo, Hi, Limit, Parse);
range_take(Handle, Lo, Hi, Limit, Parse) when is_integer(Limit), Limit >= 0 ->
    case Limit of
        0 -> {ok, []};
        _ -> try do_range_take(Handle, Lo, Hi, Limit, Parse)
             catch throw:{graphdb, limit, L} -> {ok, L} end
    end.

do_range_take(Handle, Lo, Hi, Limit, Parse) ->
    Fun = fun(K, V, _T, _O, Acc) ->
              case Parse(K, V) of
                  skip -> Acc;
                  {ok, Item} ->
                      Acc2 = [Item | Acc],
                      case (Limit =:= infinity) orelse (length(Acc2) < Limit) of
                          true  -> Acc2;
                          false -> throw({graphdb, limit, lists:reverse(Acc2)})
                      end
              end
          end,
    case bitcask:range_fold(Handle, {Lo, Hi}, [], Fun, []) of
        {error, _} = E -> E;
        Acc            -> {ok, lists:reverse(Acc)}
    end.

maybe_props(<<>>) -> <<>>;
maybe_props(V) when is_binary(V) -> V;
maybe_props(_) -> <<>>.                          %% 防御：非 binary 边值按空处理

dedupe(L) ->
    {L2, _} = lists:foldl(fun(V, {Out, Seen}) ->
                              case maps:is_key(V, Seen) of
                                  true  -> {Out, Seen};
                                  false -> {Out ++ [V], Seen#{V => true}}
                              end
                          end, {[], #{}}, L),
    L2.

normalize_not_found(not_found)      -> {error, not_found};
normalize_not_found({error, _} = E) -> E;
normalize_not_found({ok, _} = Ok)   -> Ok.

opt_limit(Opts) ->
    case maps:get(limit, Opts, infinity) of
        infinity -> infinity;
        N when is_integer(N), N >= 0 -> N;
        Bad -> erlang:error(badarg, [Opts, Bad])
    end.

v_v64(V) when is_integer(V), V >= 0, V =< ?VID_MAX     -> ok;
v_v64(_)   -> erlang:error(badarg).
v_t32(T) when is_integer(T), T >= 0, T =< ?ETYPE_MAX   -> ok;
v_t32(_)   -> erlang:error(badarg).
v_r64(R) when is_integer(R), R >= 0, R =< ?RANK_MAX    -> ok;
v_r64(_)   -> erlang:error(badarg).
