%% =========================================================================
%% graphdb — 图存储层（当前布局第 1 版：一个顶点两个 KV，按 LSN 条件写）
%%
%% 设计文档：doc/graph-adjacency-pack-design-zh.md（盘上布局与写路径）；
%% 遍历算法、OLAP 物化、etype 注册沿用 doc/graph-layer-design-zh.md。
%% 邻接表的字节格式与读写原语在 graphdb_adj；本模块是门面。
%%
%% 布局（<<1,"_g:">> 全局前缀 + 家族字节 + 定宽大端；字典序 = 数值序）：
%%
%%   <<1,"_g:">> n <vid:64> → 顶点内容（透传给 bitcask:put，binary 或 #{text=>...}）
%%   <<1,"_g:">> a <vid:64> → 邻接表头：出边组 + 入边组 + 各组度数
%%   <<1,"_g:">> a <vid:64> <dir:8> <etype:32> <o:64> <r:64>
%%                     → hub 的分块（某组超过阈值才有；(o, r) 是块下界）
%%   <<1,"_g:">> p <src:64> <etype:32> <dst:64> <rank:64>
%%                     → 超过 props_inline_max 的边属性
%%   <<1,"_g:">> t <etype:32> / tn <len:16> <name> → etype 注册表（不变）
%%   <<1,"_g:">> g     → 图元信息：布局版本 1 + 分块参数
%%
%% key 数量 ≈ 2 × 有边的顶点数 + hub 块数（v1 是 3 × 边数 + 计数键）。
%%
%% === 并发：按 LSN 的条件写（libbitcask 8.0.0）===
%%
%% 每次写边都是对两端邻接表头的读-改-写：读头时带回 LSN，提交原子批时对每个
%% 改过的头带前置条件「LSN 仍是我读到的」（不存在则「仍不存在」）。别人先改了
%% → 引擎整批拒绝 → 重读重试（默认 8 次、指数抖动退避，耗尽 {error, conflict}；
%% Opts 里 retries => N | infinity 可调）。不丢边、度数精确、两端对称——不再
%% 需要「单写者」约定，也不需要事务层兜底。热点顶点上大量并发单边写会反复
%% 重试，这种负载用 put_edges/2（按顶点聚合，一个顶点一批只写一次）。
%%
%% === 事务式 API ===
%%
%%   graphdb:transaction(H, fun(Tx) ->
%%       ok = graphdb:put_edge_txn(Tx, 1, 7, 2),
%%       ok = graphdb:del_edge_txn(Tx, 1, 7, 3),
%%       graphdb:degree_txn(Tx, 1, 7)
%%   end)                                   → {atomic, {ok, N}} | {aborted, Why}
%%
%%   锁粒度是顶点的邻接表头（点锁；持有头的锁即覆盖它名下全部块，不再需要
%%   前缀锁）。头经 bitcask_txn:read_guarded 读：读到的版本在提交时作为条件
%%   带进提交批，所以**直通写与事务写可以混用**——直通写者插进来只会让事务
%%   重跑（与死锁同一条路径），不会被覆盖。
%%   ⚠️ put_vertex_txn 的 Doc 只收 binary（事务批只装 binary）。
%%   ⚠️ del_vertex_txn 是单批（hub 顶点的批会很大）；直通 del_vertex 按 64 个
%%      邻居一批。
%%   ⚠️ Fun 必须无副作用（可能重跑）。
%%
%% === 一致性 ===
%%   * 未分块顶点：取邻居 = 一次点查，得到该顶点邻接的原子快照。
%%   * 分块顶点：头与块分次读；out_edges/in_edges 的 #{consistent => true}
%%     在读前读后比对头的 LSN，不等则重扫（不变式「头即版本」保证正确）。
%%   * 多跳遍历跨跳弱一致，与 v1 相同。
%%
%% === 布局版本 ===
%%   open 时：有新 `g` 且版本 1 → 用它记下的参数；没有新 `g` 但有旧无前缀 `g` →
%%   {error, graph_layout_unprefixed_v2}；有 v1 的 `e` 家族 →
%%   {error, graph_layout_v1}（不提供自动迁移）；都没有
%%   且可写 → 写新 `g`。分块参数只在建库时生效（之后以 `g` 为准）：
%%     {adj_inline_max, N}    头超过 N 字节就把最大的组分块（默认 4096）
%%     {adj_chunk_max, N}     单块上限（默认 4096）
%%     {props_inline_max, N}  边属性超过 N 字节落 p 家族（默认 128）
%% =========================================================================
-module(graphdb).

-export([open/1, open/2, close/1, graph_config/1,

         nkey/1, akey/1, pkey/4, succ/1,

         put_vertex/3, get_vertex/2, del_vertex/2, del_vertex/3,
         put_edge/4, put_edge/5, edge/4, edge/5, del_edge/4, del_edge/5,
         put_edges/2, put_edges/3, del_edges/2, del_edges/3,

         transaction/2, transaction/3,
         put_vertex_txn/3, get_vertex_txn/2,
         put_edge_txn/4, put_edge_txn/5, edge_txn/4, edge_txn/5,
         del_edge_txn/4, del_edge_txn/5, del_vertex_txn/2,
         out_edges_txn/2, out_edges_txn/3, in_edges_txn/2, in_edges_txn/3,
         degree_txn/2, degree_txn/3,

         out_edges/2, out_edges/3, in_edges/2, in_edges/3,
         neighbors/3, neighbors_where/4,
         degree/2, degree/3, in_degree/2, in_degree/3,
         edges_by_type/2, edges_by_type/3,
         check_invariants/1,

         bfs/3, k_hop/4, shortest_path/3, shortest_path/4,

         register_etype/2, etype_id/2, etype_name/2]).

-define(DEFAULT_RETRIES, 8).
-define(BATCH_VIDS, 256).                   % put_edges / del_edges 每批涉及的顶点上限
-define(DEL_NEIGHBORS, 64).                 % del_vertex 每批处理的邻居数
-define(CONSISTENT_TRIES, 32).
-define(VID_MAX,  16#FFFFFFFFFFFFFFFF).
-define(ETYPE_MAX, 16#FFFFFFFF).
-define(RANK_MAX,  16#FFFFFFFFFFFFFFFF).
-define(EXPAND_TIMEOUT_MS, 30000).
-define(EXPAND_SEQ_MAX, 4).                 % frontier 不超过它就串行展开
-define(ROOT, root).
-define(V1_PROBE, 64).                      % v1 探测最多核对的候选数

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
-type edge_opts() :: #{rank    => rank(),                      %% 默认 0
                       props   => binary(),                    %% 默认 <<>>
                       retries => non_neg_integer() | infinity}. %% 默认 8

-export_type([handle/0, vid/0, etype/0, rank/0, edge/0, dir/0,
              bfs_opts/0, edge_opts/0]).

%% =========================================================================
%% open / close
%% =========================================================================

open(Dir) -> open(Dir, []).

open(Dir, Opts) when is_list(Opts) ->
    {GOpts, BOpts} = lists:partition(fun is_graph_opt/1, Opts),
    case bitcask:open(Dir, BOpts) of
        {error, _} = E -> E;
        H ->
            case init_layout(H, GOpts, proplists:get_bool(read_write, BOpts)) of
                ok             -> H;
                {error, _} = E -> _ = bitcask:close(H), E
            end
    end.

close(Handle) ->
    bitcask:close(Handle).

%% 本句柄生效的图参数（#{inline_max, chunk_max, props_max}）。
graph_config(Handle) -> cfg(Handle).

is_graph_opt({K, _}) -> lists:member(K, [adj_inline_max, adj_chunk_max, props_inline_max]);
is_graph_opt(_)      -> false.

init_layout(H, GOpts, RW) ->
    case bitcask:get(H, graphdb_adj:gkey()) of
        {ok, V} ->
            case graphdb_adj:decode_cfg(vbin(V)) of
                {ok, _Cfg}     -> ok;
                {error, _} = E -> E
            end;
        not_found ->
            Cfg = cfg_from_opts(GOpts),
            case has_unprefixed_v2(H) of
                true  -> {error, graph_layout_unprefixed_v2};
                false ->
                    case has_v1_edges(H) of
                        true  -> {error, graph_layout_v1};
                        false when RW ->
                            case bitcask:put(H, graphdb_adj:gkey(),
                                             graphdb_adj:encode_cfg(Cfg)) of
                                ok    -> ok;
                                Other -> normalize_error(Other)
                            end;
                        false -> ok
                    end
            end;
        {error, _} when not RW ->
            ok;                                    %% 只读打开从未写过的目录（无 OKI）
        Other ->
            normalize_error(Other)
    end.

cfg_from_opts(GOpts) ->
    D = graphdb_adj:default_cfg(),
    I = proplists:get_value(adj_inline_max, GOpts, maps:get(inline_max, D)),
    C = proplists:get_value(adj_chunk_max, GOpts, maps:get(chunk_max, D)),
    P = proplists:get_value(props_inline_max, GOpts, maps:get(props_max, D)),
    true = (is_integer(I) andalso I >= 64 andalso I < 1 bsl 32)
        orelse erlang:error({badarg, {adj_inline_max, I}}),
    true = (is_integer(C) andalso C >= 64 andalso C < 1 bsl 32)
        orelse erlang:error({badarg, {adj_chunk_max, C}}),
    true = (is_integer(P) andalso P >= 0 andalso P < 16#FFFF)
        orelse erlang:error({badarg, {props_inline_max, P}}),
    #{inline_max => I, chunk_max => C, props_max => P}.

%% 图参数随用随读 `g` 键（每次写会话一次点查，不进任何进程外缓存——句柄不论经
%% graphdb:close 还是 bitcask:close 关掉都不留残留）。没有 `g`（只读打开的空目录、
%% 绕过 graphdb:open 拿到的句柄）或读不到就用默认值：参数只影响分块形状，任何
%% 形状都能正确解码。
cfg(H) ->
    case bitcask:get(H, graphdb_adj:gkey()) of
        {ok, V} ->
            case graphdb_adj:decode_cfg(vbin(V)) of
                {ok, Cfg} -> Cfg;
                _         -> graphdb_adj:default_cfg()
            end;
        _ ->
            graphdb_adj:default_cfg()
    end.

%% v1 库探测：`e` 家族里有一条严格 29 字节的出边 key，**并且**它配对的 `ei` 反向
%% key 也在——应用自己恰好有 29 字节的 "e…" key 不会被误判。最多核对前
%% @V1_PROBE 条候选。
has_v1_edges(H) ->
    Fun = fun(<<"e", S:64/big, T:32/big, D:64/big, R:64/big>>, _V, _T, _O, N) ->
                  case bitcask:get(H, <<"ei", D:64/big, T:32/big, S:64/big, R:64/big>>) of
                      {ok, _} -> throw({graphdb, v1});
                      _ when N + 1 >= ?V1_PROBE -> throw({graphdb, not_v1});
                      _ -> N + 1
                  end;
             (_, _, _, _, N) -> N
          end,
    try bitcask:range_fold(H, {<<"e">>, <<"f">>}, [], Fun, 0) of
        _ -> false
    catch
        throw:{graphdb, v1}     -> true;
        throw:{graphdb, not_v1} -> false
    end.

%% 加全局前缀前的中间布局用 g 版本 2。没有新 `g` 但存在旧 `g` 配置时，宁可拒开，
%% 也不能把旧图数据晾在一边再建一套新前缀数据。
has_unprefixed_v2(H) ->
    case bitcask:get(H, <<"g">>) of
        {ok, <<2:8, _:32/big, _:32/big, _:16/big>>} -> true;
        _ -> false
    end.

%% =========================================================================
%% key codec（公开以便测试 / 工具复用；调用方请勿手工拼这些 key）
%% =========================================================================

%% 顶点 key：<<1, "_g:">> ++ "n" ++ vid 大端 8 字节。
nkey(Vid) ->
    ok = v_v64(Vid),
    << (graphdb_adj:prefix())/binary, "n", Vid:64/big >>.

%% 邻接表头 key：<<1, "_g:">> ++ "a" ++ vid 大端 8 字节。
akey(Vid) ->
    ok = v_v64(Vid),
    graphdb_adj:head_key(Vid).

%% 大属性 key：29 字节。
pkey(Src, Etype, Dst, Rank) ->
    ok = v_v64(Src), ok = v_t32(Etype), ok = v_v64(Dst), ok = v_r64(Rank),
    graphdb_adj:pkey(Src, Etype, Dst, Rank).

%% 字典序后继：去尾部连续 0xFF 字节、末字节 +1；全 0xFF → undefined（无上界）。
%% 实现在 bitcask:prefix_succ/1；空 binary 不是合法前缀（function_clause）。
-spec succ(binary()) -> binary() | undefined.
succ(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    bitcask:prefix_succ(Bin).

%% =========================================================================
%% 顶点
%% =========================================================================

%% Doc 为 binary，或 #{text => ...} 等 bitcask:put 支持的文档形态。
put_vertex(Handle, Vid, Doc) ->
    bitcask:put(Handle, nkey(Vid), Doc).        %% nkey 顺带校验 vid

get_vertex(Handle, Vid) ->
    normalize_not_found(bitcask:get(Handle, nkey(Vid))).

%% 级联删除（§6.3）：按邻居分批（每批 ≤ batch_neighbors 个邻居，默认
%% @DEL_NEIGHBORS），每批一条带条件的原子批——同时改邻居的头与 V 自己的头，
%% 提交后图仍满足对称不变式，中途失败重跑即收敛。最后一批删 V 的头（条件：
%% 期间没人给 V 加边）、残余块、相关 p 键与顶点键 n<V>。邻居数不超过一批时
%% 整个删除是单批原子的。
%% Opts：retries => N | infinity（每批的冲突重试，默认 8）；
%%       batch_neighbors => N | infinity（infinity = 无论多少邻居都一批原子删完，
%%       批会很大，hub 上与并发写者冲突时整批重来）。
%% 顶点键 n<V> 的删除不带条件：与并发 put_vertex 是「删除对写入」的后写胜出，
%% 与 bitcask:delete 对 put 的语义一致。
del_vertex(Handle, Vid) -> del_vertex(Handle, Vid, #{}).

del_vertex(Handle, Vid, Opts) when is_map(Opts) ->
    _ = nkey(Vid),
    Batch = case maps:get(batch_neighbors, Opts, ?DEL_NEIGHBORS) of
                infinity -> infinity;
                N when is_integer(N), N >= 1 -> N;
                Bad -> erlang:error(badarg, [Opts, Bad])
            end,
    del_vertex_rounds(Handle, Vid, Batch, opt_retries(Opts)).

del_vertex_rounds(Handle, Vid, Batch, Retries) ->
    case with_retry(fun() -> del_vertex_round(Handle, Vid, Batch) end, Retries) of
        more  -> del_vertex_rounds(Handle, Vid, Batch, Retries);
        Other -> Other
    end.

del_vertex_round(Handle, Vid, BatchN) ->
    S0 = graphdb_adj:new_session({direct, Handle}, cfg(Handle)),
    case graphdb_adj:all_entries(S0, Vid) of
        {error, _} = E -> E;
        {ok, Es, S1} ->
            Others = lists:usort([O || {_, _, O, _, _} <- Es, O =/= Vid]),
            {Batch, Rest} = split_at(BatchN, Others),
            Last = Rest =:= [],
            Sel = maps:from_list([{O, true} || O <- Batch] ++ [{Vid, true} || Last]),
            Mine = [E || {_, _, O, _, _} = E <- Es, maps:is_key(O, Sel)],
            case remove_incident(S1, Vid, Mine) of
                {error, _} = E -> E;
                {ok, S2} ->
                    Extra = case Last of
                                true  -> [{check, graphdb_adj:head_key(Vid), absent} || Es =:= []]
                                         ++ [{remove, nkey(Vid)}];
                                false -> []
                            end,
                    case graphdb_adj:commit(S2, Extra) of
                        ok when Last -> ok;
                        ok           -> more;
                        Other        -> Other
                    end
            end
    end.

%% 从会话里摘掉 Vid 的一组条目（出边条目 (0,T,O,R) = 边 Vid→O；入边条目
%% (1,T,O,R) = 边 O→Vid）。自环在两侧各出现一次，第二次是幂等空操作。
remove_incident(S, _Vid, []) -> {ok, S};
remove_incident(S, Vid, [{Dir, T, O, R, _P} | Rest]) ->
    Res = case Dir of
              0 -> graphdb_adj:del_edge(S, Vid, T, O, R);
              1 -> graphdb_adj:del_edge(S, O, T, Vid, R)
          end,
    case Res of
        {ok, S1}       -> remove_incident(S1, Vid, Rest);
        {error, _} = E -> E
    end.

split_at(infinity, L) -> {L, []};
split_at(N, L) when length(L) =< N -> {L, []};
split_at(N, L) -> lists:split(N, L).

%% =========================================================================
%% 边 — 两端邻接表同批改，头带条件（§6.1 / §6.2）
%% =========================================================================

put_edge(Handle, Src, Etype, Dst) -> put_edge(Handle, Src, Etype, Dst, #{}).
put_edge(Handle, Src, Etype, Dst, Opts) when is_map(Opts) ->
    {Rank, Props} = edge_opts(Opts, [Handle, Src, Etype, Dst, Opts]),
    ok = v_edge(Src, Etype, Dst, Rank),
    with_session(Handle, fun(S) -> graphdb_adj:put_edge(S, Src, Etype, Dst, Rank, Props) end,
                 opt_retries(Opts)).

del_edge(Handle, Src, Etype, Dst) -> del_edge(Handle, Src, Etype, Dst, 0).
del_edge(Handle, Src, Etype, Dst, Rank) ->
    ok = v_edge(Src, Etype, Dst, Rank),
    with_session(Handle, fun(S) -> graphdb_adj:del_edge(S, Src, Etype, Dst, Rank) end,
                 ?DEFAULT_RETRIES).

%% 点查（rank 缺省 0）。upsert 后读到的是最后一次写入。
edge(Handle, Src, Etype, Dst) -> edge(Handle, Src, Etype, Dst, 0).
edge(Handle, Src, Etype, Dst, Rank) ->
    ok = v_edge(Src, Etype, Dst, Rank),
    Io = {direct, Handle},
    case graphdb_adj:lookup(Io, Src, 0, Etype, Dst, Rank) of
        {ok, P} ->
            case resolve_props(Io, Src, Etype, Dst, Rank, P) of
                {ok, Props}    -> {ok, #{src => Src, etype => Etype, dst => Dst,
                                         rank => Rank, props => Props}};
                {error, _} = E -> E
            end;
        not_found      -> {error, not_found};
        {error, _} = E -> E
    end.

%% 批量加边（§6.4）：[{S, T, D} | {S, T, D, Opts}]。先按 src 稳定排序，再按涉及的
%% 顶点切批（每批 ≤ batch_vids 个顶点，默认 @BATCH_VIDS），批内每个顶点读一次、改
%% 一次、写一次；每批独立原子、独立重试。批与批之间不原子——中途失败时前面的批
%% 已经提交（排序后「前面」指 src 较小的批）。
%% Opts：retries（同 put_edge）、sort => false（保持输入顺序切批）、
%% batch_vids => N（离线装载可调大；整图放进一批时每个头只写一次，但一批越大，
%% 与并发写者冲突时整批重来的代价越大）。
put_edges(Handle, Edges) -> put_edges(Handle, Edges, #{}).
put_edges(Handle, Edges, Opts) when is_list(Edges), is_map(Opts) ->
    Norm = [norm_put(E, Handle) || E <- Edges],
    run_batches(Handle, maybe_sort(Norm, Opts),
                fun(S, {Src, T, Dst, R, P}) -> graphdb_adj:put_edge(S, Src, T, Dst, R, P) end,
                opt_retries(Opts), opt_batch_vids(Opts)).

%% 批量删边：[{S, T, D} | {S, T, D, Rank}]，幂等。切批与原子性同 put_edges。
del_edges(Handle, Edges) -> del_edges(Handle, Edges, #{}).
del_edges(Handle, Edges, Opts) when is_list(Edges), is_map(Opts) ->
    Norm = [norm_del(E) || E <- Edges],
    run_batches(Handle, maybe_sort(Norm, Opts),
                fun(S, {Src, T, Dst, R}) -> graphdb_adj:del_edge(S, Src, T, Dst, R) end,
                opt_retries(Opts), opt_batch_vids(Opts)).

%% sort => true（默认）：按 src 稳定排序再切批——同一个 src 的边落进同一批，src 的头
%% 一批只写一次。稳定排序保证同一条边的多次 upsert 仍按调用方给的顺序生效。
maybe_sort(Items, Opts) ->
    case maps:get(sort, Opts, true) of
        true  -> lists:keysort(1, Items);
        false -> Items;
        Bad   -> erlang:error(badarg, [Opts, Bad])
    end.

opt_batch_vids(Opts) ->
    case maps:get(batch_vids, Opts, ?BATCH_VIDS) of
        N when is_integer(N), N >= 2 -> N;
        Bad -> erlang:error(badarg, [Opts, Bad])
    end.

norm_put({S, T, D}, H) -> norm_put({S, T, D, #{}}, H);
norm_put({S, T, D, Opts} = E, H) when is_map(Opts) ->
    {R, P} = edge_opts(Opts, [H, E]),
    ok = v_edge(S, T, D, R),
    {S, T, D, R, P};
norm_put(Bad, H) -> erlang:error(badarg, [H, Bad]).

norm_del({S, T, D}) -> norm_del({S, T, D, 0});
norm_del({S, T, D, R} = E) ->
    ok = v_edge(S, T, D, R),
    E;
norm_del(Bad) -> erlang:error(badarg, [Bad]).

run_batches(_Handle, [], _Apply, _Retries, _Max) -> ok;
run_batches(Handle, Items, Apply, Retries, Max) ->
    {Batch, Rest} = take_batch(Items, Max, #{}, []),
    Res = with_session(Handle,
                       fun(S0) ->
                               lists:foldl(fun(_It, {error, _} = E) -> E;
                                              (It, {ok, S}) -> Apply(S, It)
                                           end, {ok, S0}, Batch)
                       end, Retries),
    case Res of
        ok    -> run_batches(Handle, Rest, Apply, Retries, Max);
        Other -> Other
    end.

%% 依序取边，直到再加一条就会让涉及的顶点数超过 Max。
take_batch([], _Max, _Vids, Acc) -> {lists:reverse(Acc), []};
take_batch([It | Rest] = All, Max, Vids, Acc) ->
    Vids2 = Vids#{element(1, It) => true, element(3, It) => true},
    case map_size(Vids2) > Max andalso Acc =/= [] of
        true  -> {lists:reverse(Acc), All};
        false -> take_batch(Rest, Max, Vids2, [It | Acc])
    end.

%% 一次会话：Build(Session) -> {ok, S'} | {error, _}；提交冲突就整个重来。
with_session(Handle, Build, Retries) ->
    with_retry(fun() ->
                       S0 = graphdb_adj:new_session({direct, Handle}, cfg(Handle)),
                       case Build(S0) of
                           {ok, S1}       -> graphdb_adj:commit(S1);
                           {error, _} = E -> E
                       end
               end, Retries).

%% Fun() -> conflict | Result。conflict 退避后重来，耗尽 {error, conflict}。
with_retry(Fun, Retries) -> with_retry(Fun, Retries, 0).

with_retry(Fun, Retries, Attempt) ->
    case Fun() of
        conflict when Retries =:= infinity; Attempt < Retries ->
            timer:sleep(rand:uniform(1 bsl min(Attempt, 6)) - 1),
            with_retry(Fun, Retries, Attempt + 1);
        conflict ->
            {error, conflict};
        Other ->
            Other
    end.

edge_opts(Opts, Args) ->
    Rank  = maps:get(rank, Opts, 0),
    Props = maps:get(props, Opts, <<>>),
    true = is_binary(Props) orelse erlang:error(badarg, Args),
    {Rank, Props}.

opt_retries(Opts) ->
    case maps:get(retries, Opts, ?DEFAULT_RETRIES) of
        infinity -> infinity;
        N when is_integer(N), N >= 0 -> N;
        Bad -> erlang:error(badarg, [Opts, Bad])
    end.

%% ext → 读 p 家族。p 键缺失（与头不一致，只可能是并发改动的瞬间）按空属性。
resolve_props(Io, S, T, D, R, ext) ->
    Key = graphdb_adj:pkey(S, T, D, R),
    Res = case Io of
              {direct, H}    -> bitcask:get(H, Key);
              {txn, Tx, _}   -> bitcask_txn:read(Tx, Key, read)
          end,
    case Res of
        {ok, V}        -> {ok, vbin(V)};
        not_found      -> {ok, <<>>};
        {error, _} = E -> E
    end;
resolve_props(_Io, _S, _T, _D, _R, P) ->
    {ok, P}.

%% =========================================================================
%% 事务式 API（bitcask_txn 之上，模块头有说明）
%% =========================================================================

-spec transaction(handle(), fun((term()) -> term())) -> {atomic, term()} | {aborted, term()}.
transaction(Handle, Fun) -> bitcask_txn:transaction(Handle, Fun).

-spec transaction(handle(), fun((term()) -> term()), list()) ->
          {atomic, term()} | {aborted, term()}.
transaction(Handle, Fun, Opts) -> bitcask_txn:transaction(Handle, Fun, Opts).

put_vertex_txn(Tx, Vid, Doc) when is_binary(Doc) ->
    bitcask_txn:write(Tx, nkey(Vid), Doc).

get_vertex_txn(Tx, Vid) ->
    normalize_not_found(txn_read(Tx, nkey(Vid), read)).

put_edge_txn(Tx, Src, Etype, Dst) -> put_edge_txn(Tx, Src, Etype, Dst, #{}).
put_edge_txn(Tx, Src, Etype, Dst, Opts) when is_map(Opts) ->
    {Rank, Props} = edge_opts(Opts, [Tx, Src, Etype, Dst, Opts]),
    ok = v_edge(Src, Etype, Dst, Rank),
    txn_session(Tx, fun(S) -> graphdb_adj:put_edge(S, Src, Etype, Dst, Rank, Props) end).

del_edge_txn(Tx, Src, Etype, Dst) -> del_edge_txn(Tx, Src, Etype, Dst, 0).
del_edge_txn(Tx, Src, Etype, Dst, Rank) ->
    ok = v_edge(Src, Etype, Dst, Rank),
    txn_session(Tx, fun(S) -> graphdb_adj:del_edge(S, Src, Etype, Dst, Rank) end).

edge_txn(Tx, Src, Etype, Dst) -> edge_txn(Tx, Src, Etype, Dst, 0).
edge_txn(Tx, Src, Etype, Dst, Rank) ->
    ok = v_edge(Src, Etype, Dst, Rank),
    Io = {txn, Tx, read},
    case graphdb_adj:lookup(Io, Src, 0, Etype, Dst, Rank) of
        {ok, P} ->
            {ok, Props} = txn_ok(resolve_props(Io, Src, Etype, Dst, Rank, P)),
            {ok, #{src => Src, etype => Etype, dst => Dst, rank => Rank, props => Props}};
        not_found ->
            {error, not_found};
        {error, Reason} ->
            bitcask_txn:abort(Reason)
    end.

%% 度数（读锁下读头）。Etype = undefined：全部出边。
degree_txn(Tx, Vid) -> degree_txn(Tx, Vid, undefined).
degree_txn(Tx, Vid, Etype) ->
    _ = nkey(Vid),
    case graphdb_adj:counts({txn, Tx, read}, Vid) of
        {ok, Cs}        -> {ok, sum_counts(Cs, 0, Etype)};
        {error, Reason} -> bitcask_txn:abort(Reason)
    end.

out_edges_txn(Tx, Vid) -> out_edges_txn(Tx, Vid, #{}).
out_edges_txn(Tx, Vid, Opts) when is_map(Opts) ->
    txn_ok(adj_edges({txn, Tx, read}, Vid, 0, Opts#{consistent => false})).

in_edges_txn(Tx, Vid) -> in_edges_txn(Tx, Vid, #{}).
in_edges_txn(Tx, Vid, Opts) when is_map(Opts) ->
    txn_ok(adj_edges({txn, Tx, read}, Vid, 1, Opts#{consistent => false})).

%% 级联删除的事务版：单批（锁住 V 与全部邻居的头），无幻读。
del_vertex_txn(Tx, Vid) ->
    _ = nkey(Vid),
    S0 = graphdb_adj:new_session({txn, Tx, write}, cfg(bitcask_txn:handle(Tx))),
    case graphdb_adj:all_entries(S0, Vid) of
        {error, Reason} -> bitcask_txn:abort(Reason);
        {ok, Es, S1} ->
            case remove_incident(S1, Vid, Es) of
                {error, Reason} -> bitcask_txn:abort(Reason);
                {ok, S2} ->
                    ok = graphdb_adj:commit(S2),
                    bitcask_txn:delete(Tx, nkey(Vid))
            end
    end.

txn_session(Tx, Build) ->
    S0 = graphdb_adj:new_session({txn, Tx, write}, cfg(bitcask_txn:handle(Tx))),
    case Build(S0) of
        {ok, S1}        -> graphdb_adj:commit(S1);
        {error, Reason} -> bitcask_txn:abort(Reason)
    end.

txn_ok({error, Reason}) -> bitcask_txn:abort(Reason);
txn_ok(Ok)              -> Ok.

txn_prefix_range(Tx, Prefix, Lock) ->
    case bitcask_txn:prefix_range(Tx, Prefix, [{lock, Lock}]) of
        {error, Reason} -> bitcask_txn:abort(Reason);
        Rows            -> Rows
    end.

%% 事务内读：引擎错误直接中止事务（拿到一半的读没法给出正确结果）。
txn_read(Tx, Key, Lock) ->
    case bitcask_txn:read(Tx, Key, Lock) of
        {error, Reason} -> bitcask_txn:abort(Reason);
        Other           -> Other
    end.

%% =========================================================================
%% 邻接读取（§7.1）
%%
%% Opts（map）：
%%   etype => T          收窄到单一边类型
%%   limit => N          最多返回 N 条（分块组提前停扫）
%%   consistent => true  分块顶点也给原子快照（读前读后比对头的 LSN）
%% =========================================================================

out_edges(Handle, Vid) -> out_edges(Handle, Vid, #{}).
out_edges(Handle, Vid, Opts) when is_map(Opts) ->
    adj_edges({direct, Handle}, Vid, 0, Opts).

in_edges(Handle, Vid) -> in_edges(Handle, Vid, #{}).
in_edges(Handle, Vid, Opts) when is_map(Opts) ->
    adj_edges({direct, Handle}, Vid, 1, Opts).

adj_edges(Io, Vid, Dir, Opts) ->
    _ = nkey(Vid),
    Etype = opt_etype(Opts),
    Limit = opt_limit(Opts),
    Read = fun() -> graphdb_adj:entries(Io, Vid, Dir, Etype, Limit) end,
    Res = case maps:get(consistent, Opts, false) of
              true  -> consistent_read(Io, Vid, Read, ?CONSISTENT_TRIES);
              false -> Read()
          end,
    case Res of
        {error, _} = E -> E;
        {ok, Es}       -> to_edges(Io, Vid, Dir, Es, [])
    end.

%% 读前读后头的 LSN 不等 → 重扫；连续撞上写就带抖动退避（0..2^k ms），把
%% 重扫挪进写与写之间的空当。@CONSISTENT_TRIES 次都撞上 → inconsistent_read。
consistent_read(_Io, _Vid, _Read, 0) ->
    {error, inconsistent_read};
consistent_read(Io, Vid, Read, N) when N < ?CONSISTENT_TRIES ->
    timer:sleep(rand:uniform(1 bsl min(?CONSISTENT_TRIES - N, 5)) - 1),
    consistent_read_once(Io, Vid, Read, N);
consistent_read(Io, Vid, Read, N) ->
    consistent_read_once(Io, Vid, Read, N).

consistent_read_once(Io, Vid, Read, N) ->
    case graphdb_adj:head_cond(Io, Vid) of
        {error, _} = E -> E;
        {ok, C1} ->
            case Read() of
                {error, _} = E -> E;
                {ok, _} = Ok ->
                    case graphdb_adj:head_cond(Io, Vid) of
                        {ok, C1}       -> Ok;
                        {ok, _}        -> consistent_read(Io, Vid, Read, N - 1);
                        {error, _} = E -> E
                    end
            end
    end.

to_edges(_Io, _Vid, _Dir, [], Acc) ->
    {ok, lists:reverse(Acc)};
to_edges(Io, Vid, 0, [{T, D, R, P} | Rest], Acc) ->
    case resolve_props(Io, Vid, T, D, R, P) of
        {ok, Props} ->
            to_edges(Io, Vid, 0, Rest,
                     [#{src => Vid, etype => T, dst => D, rank => R, props => Props} | Acc]);
        {error, _} = E ->
            E
    end;
to_edges(Io, Vid, 1, [{T, S, R, _P} | Rest], Acc) ->
    to_edges(Io, Vid, 1, Rest,
             [#{dst => Vid, etype => T, src => S, rank => R, props => <<>>} | Acc]).

%% 双向邻居：out ++ in 去重保序（顶点自身/自环不特殊处理）。
neighbors(Handle, Vid, Dir) when Dir =:= out; Dir =:= in ->
    edge_endpoints(Handle, Vid, Dir);
neighbors(Handle, Vid, both) ->
    case {edge_endpoints(Handle, Vid, out), edge_endpoints(Handle, Vid, in)} of
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E;
        {{ok, Out}, {ok, In}} -> {ok, dedupe(Out ++ In)}
    end.

edge_endpoints(Handle, Vid, Dir) ->
    case graphdb_adj:entries({direct, Handle}, nvid(Vid), dir_code(Dir), undefined, infinity) of
        {error, _} = E -> E;
        {ok, Es}       -> {ok, dedupe([O || {_T, O, _R, _P} <- Es])}
    end.

%% 出度（Etype = undefined：全部类型）。读头即得，O(1)。
degree(Handle, Vid) -> degree(Handle, Vid, undefined).
degree(Handle, Vid, Etype) -> count_dir(Handle, Vid, 0, Etype).

%% 入度，同上。
in_degree(Handle, Vid) -> in_degree(Handle, Vid, undefined).
in_degree(Handle, Vid, Etype) -> count_dir(Handle, Vid, 1, Etype).

count_dir(Handle, Vid, Dir, Etype) ->
    _ = nkey(Vid),
    Etype =:= undefined orelse v_t32(Etype),
    case graphdb_adj:counts({direct, Handle}, Vid) of
        {ok, Cs}       -> {ok, sum_counts(Cs, Dir, Etype)};
        {error, _} = E -> E
    end.

sum_counts(Cs, Dir, Etype) ->
    lists:sum([C || {D, T, C} <- Cs, D =:= Dir, Etype =:= undefined orelse T =:= Etype]).

%% 按类型列全库边（§9）：扫整个 `a` 家族、按 etype 过滤，O(V + E)。
%% 输出序 = (src, dst, rank)，带属性。高频使用请走 graphdb_analytics 物化。
edges_by_type(Handle, Etype) -> edges_by_type(Handle, Etype, #{}).
edges_by_type(Handle, Etype, Opts) when is_map(Opts) ->
    ok = v_t32(Etype),
    Limit = opt_limit(Opts),
    Emit = fun(Src, Es, {N, Acc}) ->
                   Taken = case Limit of infinity -> Es; _ -> lists:sublist(Es, Limit - N) end,
                   N2 = N + length(Taken),
                   Acc2 = lists:reverse([{Src, D, R, P} || {D, R, P} <- Taken], Acc),
                   case Limit =/= infinity andalso N2 >= Limit of
                       true  -> throw({graphdb, limit, Acc2});
                       false -> {N2, Acc2}
                   end
           end,
    Fun = fun(<< _P:4/binary, "a", Src:64/big >>, V, _T, _O, A) ->
                  case graphdb_adj:groups_info(vbin(V)) of
                      {ok, Gs} ->
                          case lists:keyfind(Etype, 2, [G || {0, _, _, _} = G <- Gs]) of
                              {0, Etype, _C, {entries, Es}} -> Emit(Src, Es, A);
                              _ -> A
                          end;
                      error -> A
                  end;
             (<< _P:4/binary, "a", Src:64/big, 0:8, T:32/big, _:128 >>,
              V, _T, _O, A) when T =:= Etype ->
                  case graphdb_adj:decode_chunk(vbin(V)) of
                      {ok, Es} -> Emit(Src, Es, A);
                      error    -> A
                  end;
             (_, _, _, _, A) -> A
          end,
    Raw = case Limit of
              0 -> {ok, []};
              _ ->
                  try bitcask:range_fold(Handle, graphdb_adj:range(<<"a">>), [],
                                         Fun, {0, []}) of
                      {error, _} = Err -> Err;
                      {_, Acc}         -> {ok, lists:reverse(Acc)}
                  catch throw:{graphdb, limit, Acc} -> {ok, lists:reverse(Acc)}
                  end
          end,
    case Raw of
        {error, _} = E -> E;
        {ok, L}        -> to_edges({direct, Handle}, Etype, L, [])
    end.

to_edges(_Io, _T, [], Acc) -> {ok, lists:reverse(Acc)};
to_edges(Io, T, [{S, D, R, P} | Rest], Acc) ->
    case resolve_props(Io, S, T, D, R, P) of
        {ok, Props}    -> to_edges(Io, T, Rest,
                                   [#{src => S, etype => T, dst => D, rank => R,
                                      props => Props} | Acc]);
        {error, _} = E -> E
    end.

%% 属性过滤遍历：Pred(neighbor_vid, VertexValue | undefined) -> boolean()；
%% 端点顶点缺失（悬挂边）时 Value 为 undefined。
neighbors_where(Handle, Vid, Dir, Pred) when is_function(Pred, 2) ->
    case neighbors(Handle, Vid, Dir) of
        {error, _} = E -> E;
        {ok, Ns} ->
            {ok, lists:filter(fun(N) ->
                                  Pred(N, case get_vertex(Handle, N) of
                                              {ok, V}   -> V;
                                              _Other    -> undefined
                                          end)
                              end, Ns)}
    end.

%% =========================================================================
%% 全图不变式校验（§4.5）：扫 `a` / `p` 家族，检查
%%   * 头 / 块可解码；块目录与实际块 key 一致；块内条目落在自己的下界区间；
%%   * 每组 Count = 实际条目数；
%%   * 对称：出边集合 = 入边集合；
%%   * 外置属性：标 ext 的出边 ⟺ 有 p 键。
%% 返回 {ok, #{vertices, edges, chunks}} | {error, [Problem]}（最多 20 条）。
%% 内存 O(E)，诊断 / 测试用。
%% =========================================================================

check_invariants(Handle) ->
    Scan = fun(<< _P:4/binary, "a", Vid:64/big >>, V, _T, _O, {Hs, Cs, Bad}) ->
                   case graphdb_adj:groups_info(vbin(V)) of
                       {ok, Gs} -> {Hs#{Vid => Gs}, Cs, Bad};
                       error    -> {Hs, Cs, [{bad_head, Vid} | Bad]}
                   end;
              (<< _P:4/binary, "a", _:64, _:8, _:32, _:64, _:64 >> = K,
               V, _T, _O, {Hs, Cs, Bad}) ->
                   case {graphdb_adj:parse_chunk_key(K), graphdb_adj:decode_chunk(vbin(V))} of
                       {{ok, Vid, D, T, Lb}, {ok, Es}} -> {Hs, Cs#{{Vid, D, T, Lb} => Es}, Bad};
                       _ -> {Hs, Cs, [{bad_chunk, K} | Bad]}
                   end;
              (_, _, _, _, A) -> A
           end,
    PScan = fun(<< _P:4/binary, "p", S:64/big, T:32/big, D:64/big, R:64/big >>,
                 _V, _T, _O, Acc) ->
                    [{S, T, D, R} | Acc];
               (_, _, _, _, Acc) -> Acc
            end,
    case {bitcask:range_fold(Handle, graphdb_adj:range(<<"a">>), [],
                             Scan, {#{}, #{}, []}),
          bitcask:range_fold(Handle, graphdb_adj:range(<<"p">>), [],
                             PScan, [])} of
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E;
        {{Heads, Chunks, Bad0}, PKeys} ->
            {Out, In, Bad1, Used} =
                maps:fold(fun(Vid, Gs, Acc) -> check_vertex(Vid, Gs, Chunks, Acc) end,
                          {[], [], Bad0, #{}}, Heads),
            Orphans = [{orphan_chunk, K} || K <- maps:keys(Chunks), not maps:is_key(K, Used)],
            OutSet = lists:sort([{S, T, D, R} || {S, T, D, R, _} <- Out]),
            InSet = lists:sort(In),
            Sym = case OutSet =:= InSet of
                      true  -> [];
                      false -> [{asymmetric, lists:sublist(OutSet -- InSet, 5),
                                 lists:sublist(InSet -- OutSet, 5)}]
                  end,
            Ext = lists:sort([{S, T, D, R} || {S, T, D, R, ext} <- Out]),
            PSet = lists:sort(PKeys),
            Props = case Ext =:= PSet of
                        true  -> [];
                        false -> [{props_mismatch, lists:sublist(Ext -- PSet, 5),
                                   lists:sublist(PSet -- Ext, 5)}]
                    end,
            case Bad1 ++ Orphans ++ Sym ++ Props of
                [] -> {ok, #{vertices => map_size(Heads), edges => length(OutSet),
                             chunks => map_size(Chunks)}};
                Problems -> {error, lists:sublist(Problems, 20)}
            end
    end.

check_vertex(Vid, Gs, Chunks, Acc0) ->
    lists:foldl(
      fun({D, T, C, Body}, {Out, In, Bad, Used}) ->
              {Es, Bad2, Used2} =
                  case Body of
                      {entries, L} -> {L, Bad, Used};
                      {chunks, Lbs} -> chunk_entries(Vid, D, T, Lbs, Chunks, Bad, Used)
                  end,
              Bad3 = case length(Es) =:= C of
                         true  -> Bad2;
                         false -> [{count_mismatch, Vid, D, T, C, length(Es)} | Bad2]
                     end,
              case D of
                  0 -> {[{Vid, T, O, R, P} || {O, R, P} <- Es] ++ Out, In, Bad3, Used2};
                  1 -> {Out, [{O, T, Vid, R} || {O, R, _} <- Es] ++ In, Bad3, Used2}
              end
      end, Acc0, Gs).

chunk_entries(Vid, D, T, Lbs, Chunks, Bad0, Used0) ->
    Bounds = lists:zip(Lbs, tl(Lbs) ++ [infinity]),
    lists:foldl(
      fun({Lb, Next}, {Es, Bad, Used}) ->
              Key = {Vid, D, T, Lb},
              case maps:find(Key, Chunks) of
                  error -> {Es, [{missing_chunk, Key} | Bad], Used};
                  {ok, CEs} ->
                      InRange = lists:all(fun({O, R, _}) ->
                                                  {O, R} >= Lb andalso
                                                      (Next =:= infinity orelse {O, R} < Next)
                                          end, CEs),
                      Bad2 = case InRange of true -> Bad; false -> [{chunk_range, Key} | Bad] end,
                      {Es ++ CEs, Bad2, Used#{Key => true}}
              end
      end, {[], Bad0, Used0}, Bounds).

%% =========================================================================
%% 遍历 — BFS / k-hop / 双向最短路（设计文档 §6.2–§6.4）
%%
%% frontier 展开按片并行（见 expand_grouped）；展开一个顶点 = 读它的邻接表头
%%（分块组再加一次前缀 range），只取邻居 vid、不解析属性。
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
    %% expand/4 在展开失败（引擎错误 / 工作进程超时）时 raise；这里收成
    %% spec 承诺的 {error, _}，k_hop 的错误分支才是活的。
    try bfs_layers(Handle, [Start], #{Start => true}, 0, MaxDepth,
                   Dir, Etype, Visit, [[{Start, 0}]])
    catch
        error:{graphdb_expand, Reason} -> {error, {graphdb_expand, Reason}};
        error:graphdb_expand_timeout   -> {error, graphdb_expand_timeout}
    end.

%% Acc 是**逆序的层列表**（每层一个 [{Vid, Depth}]），最后 append 一次——
%% 以前每层 `Acc ++ [...]` 整拷累积结果，深图上是 O(V·depth)。
bfs_layers(_Handle, _Frontier, _Visited, Depth, MaxDepth, _Dir, _Etype, _Visit,
           Acc) when Depth >= MaxDepth ->
    {ok, lists:append(lists:reverse(Acc))};
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
        [] -> {ok, lists:append(lists:reverse(Acc))};
        Fresh ->
            D1 = Depth + 1,
            [maybe_visit(Visit, N, D1) || N <- Fresh],
            bfs_layers(Handle, Fresh, Visited2, D1, MaxDepth, Dir, Etype, Visit,
                       [[{N, D1} || N <- Fresh] | Acc])
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
    %% 展开失败（引擎错误 / worker 超时）由 expand_grouped raise，这里收成
    %% {error, _}，与 bfs/3 一致。
    try bidir(Handle, Etype, #{Src => ?ROOT}, [Src], 1, #{Dst => ?ROOT}, [Dst], 1)
    catch
        error:{graphdb_expand, Reason} -> {error, {graphdb_expand, Reason}};
        error:graphdb_expand_timeout   -> {error, graphdb_expand_timeout}
    end.

%% 每轮：选 frontier 较小的一侧展开一层；新节点命中对侧 visited → 拼路径。
%% 父指针：fwd 侧 parent = 发现者（指向起点方向）；bwd 侧展开用 in 边
%%（找到的是前驱），parent = 发现者（指向终点方向）——两侧父链都指向
%% 本侧 root，stitch 时天然拼成 Src→Dst。
%% frontier 的长度作为参数带着走（FwdN / BwdN），不每轮 length/1。
bidir(Handle, Etype, FwdMap, FwdF, FwdN, BwdMap, BwdF, BwdN) ->
    case FwdN =< BwdN of
        true ->
            case expand_layer(Handle, FwdF, out, Etype, FwdMap) of
                {[], 0, _FwdMap2} ->
                    {error, no_path};
                {NewF, NewN, FwdMap2} ->
                    case first_in(NewF, BwdMap) of
                        not_found ->
                            bidir(Handle, Etype, FwdMap2, NewF, NewN, BwdMap, BwdF, BwdN);
                        M ->
                            {ok, stitch(M, FwdMap2, BwdMap)}
                    end
            end;
        false ->
            case expand_layer(Handle, BwdF, in, Etype, BwdMap) of
                {[], 0, _BwdMap2} ->
                    {error, no_path};
                {NewF, NewN, BwdMap2} ->
                    case first_in(NewF, FwdMap) of
                        not_found ->
                            bidir(Handle, Etype, FwdMap, FwdF, FwdN, BwdMap2, NewF, NewN);
                        M ->
                            {ok, stitch(M, FwdMap, BwdMap2)}
                    end
            end
    end.

%% 展开一层：新节点并入 visited（parent = 发现者），去重保序。
%% 返回 {NewFrontier, 长度, Map2}；frontier 耗尽 → {[], 0, Map}。
%% 取邻居走 expand_grouped（大 frontier 并行），折叠顺序仍是 frontier 序、
%% 邻居序——父指针与最终路径和逐点串行完全一致。
expand_layer(Handle, Frontier, Dir, Etype, Map) ->
    Grouped = expand_grouped(Handle, Frontier, Dir, Etype),
    {NewFR, N, Map2} =
        lists:foldl(fun({V, Nbrs}, Acc0) ->
                        lists:foldl(fun(Nb, {Fs, Cnt, M}) ->
                                        case maps:is_key(Nb, M) of
                                            true  -> {Fs, Cnt, M};
                                            false -> {[Nb | Fs], Cnt + 1, M#{Nb => V}}
                                        end
                                    end, Acc0, Nbrs)
                    end,
                    {[], 0, Map}, lists:zip(Frontier, Grouped)),
    {lists:reverse(NewFR), N, Map2}.

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
%% 注册是「读-判-写」：在 bitcask_txn 事务里对 "t" 前缀（同时罩住 t<id> 与
%% tn<name> 两个家族）拿写锁再做——并发注册不同名字不会算出同一个 Next
%% 把两种边类型合并，同名并发也只会得到一个 id。已注册的名字走只读路径
%%（缓冲为空不碰引擎）。
%% =========================================================================

register_etype(Handle, Name) when is_binary(Name), Name =/= <<>>,
                                  byte_size(Name) < 16#FFFF ->
    Res = bitcask_txn:transaction(
            Handle,
            fun(Tx) ->
                    TPrefix = << (graphdb_adj:prefix())/binary, "t" >>,
                    ok = bitcask_txn:lock_prefix(Tx, TPrefix, write),
                    case txn_read(Tx, tnkey(Name), write) of
                        {ok, <<Id:32/big>>} ->
                            {ok, Id};
                        {ok, _} ->
                            {error, invalid_etype_record};
                        not_found ->
                            Next = next_etype_id_txn(Tx),
                            ok = bitcask_txn:write(
                                   Tx, << TPrefix/binary, Next:32/big >>, Name),
                            ok = bitcask_txn:write(Tx, tnkey(Name), <<Next:32/big>>),
                            {ok, Next}
                    end
            end),
    case Res of
        {atomic, R}                      -> R;
        {aborted, {commit_failed, Why}}  -> {error, Why};
        {aborted, Why}                   -> {error, Why}
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
    case bitcask:get(
           Handle, << (graphdb_adj:prefix())/binary, "t", Id:32/big >>) of
        {ok, Name} when is_binary(Name) -> {ok, Name};
        {ok, _}                         -> {error, invalid_etype_record};
        not_found                       -> {error, not_found};
        {error, _} = E                  -> E
    end.

tnkey(Name) ->
    << (graphdb_adj:prefix())/binary, "tn", (byte_size(Name)):16/big,
       Name/binary >>.

%% t 家族扫描：前缀 <<1, "_g:t">>。同区间里会混进 "tn…" 更长的 key，
%% strict 9 字节解析过滤。id 从 1 起。前缀写锁已在调用方持有。
next_etype_id_txn(Tx) ->
    Ids = [Id || {<< _P:4/binary, "t", Id:32/big >>, _V}
                   <- txn_prefix_range(Tx, << (graphdb_adj:prefix())/binary, "t" >>,
                                     write)],
    lists:max([0 | Ids]) + 1.


%% =========================================================================
%% 内部
%% =========================================================================

%% 并行展开 frontier（设计文档 §6.2）；结果按 frontier 顺序拼接，输出确定。
%%
%% frontier 切成至多 dirty_io_schedulers 片（读头的 get 与分块组的 range 都
%% 走 NIF，真正的并行度按 dirty IO 调度器数算），一片一个进程顺序展开——以前一顶点一
%% 进程，一万个 frontier 就一万次 spawn + 结果拷贝，并行度却没多一分。
%% 每片把 {Ref, Idx, [邻居列表]} 发回；调用方按 Idx 拼接。
%% 失败纪律：任一片挂掉 / 总超时 → 其余全部 kill + demonitor flush，再 raise
%% （bfs/3 收成 {error, _}）——以前失败只 raise 不清理，别的片的 DOWN 会漏进
%% 调用方信箱；每片各自 30s 的超时也会叠加成 30s × 片数。
expand(Handle, Frontier, Dir, Etype) ->
    lists:append(expand_grouped(Handle, Frontier, Dir, Etype)).

%% 与 Frontier 等长同序的 [[邻居]]——shortest_path 要按"谁发现的"记父指针，
%% 不能用拍平的结果。小 frontier（≤ @EXPAND_SEQ_MAX）就地串行：双向搜索开头
%% 两侧都只有 1 个顶点，起进程比那一两次 range 还贵。失败统一 raise
%% {graphdb_expand, Reason}（并行路径是 worker 的退出原因）。
expand_grouped(Handle, Frontier, Dir, Etype) when length(Frontier) =< ?EXPAND_SEQ_MAX ->
    try [neighbor_list(Handle, V, Dir, Etype) || V <- Frontier]
    catch error:Reason -> erlang:error({graphdb_expand, Reason})
    end;
expand_grouped(Handle, Frontier, Dir, Etype) ->
    K = max(1, min(length(Frontier), erlang:system_info(dirty_io_schedulers))),
    Slices = slice(Frontier, ceil_div(length(Frontier), K)),
    Ref = make_ref(), Me = self(),
    %% monitor 带 tag：DOWN 消息以 {Ref, 'DOWN'} 开头，只匹配我们自己的 worker，
    %% 不会误吞调用方的其它 DOWN。
    Workers = [{Idx, spawn_opt(fun() ->
                                   Me ! {Ref, Idx, [neighbor_list(Handle, V, Dir, Etype)
                                                    || V <- Slice]}
                               end, [{monitor, [{tag, {Ref, 'DOWN'}}]}])}
               || {Idx, Slice} <- lists:zip(lists:seq(1, length(Slices)), Slices)],
    Deadline = erlang:monotonic_time(millisecond) + ?EXPAND_TIMEOUT_MS,
    Results = collect_slices(Workers, Ref, Deadline, #{}),
    lists:append([maps:get(Idx, Results) || {Idx, _} <- Workers]).

collect_slices([], _Ref, _Deadline, Acc) ->
    Acc;
collect_slices(Workers, Ref, Deadline, Acc) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, Idx, Lists} ->
            {value, {Idx, {_Pid, MRef}}, Rest} = lists:keytake(Idx, 1, Workers),
            erlang:demonitor(MRef, [flush]),
            collect_slices(Rest, Ref, Deadline, Acc#{Idx => Lists});
        {{Ref, 'DOWN'}, _MRef, process, _Pid, Reason} ->
            %% 结果消息总先于同一发送者的 DOWN 到达，所以走到这里一定是异常退出
            kill_workers(Workers, Ref),
            erlang:error({graphdb_expand, Reason})
    after Wait ->
            kill_workers(Workers, Ref),
            erlang:error(graphdb_expand_timeout)
    end.

%% 杀掉剩下的 worker，并保证调用方信箱里不留它们的任何消息。
%% ⚠️ 不能 kill 完直接 demonitor(flush)：已经把结果发出来的 worker，它的
%%    {Ref, Idx, Lists} 可能还没到或刚到，demonitor 只清 DOWN 不清它。要**等
%%    每个 worker 的 DOWN**——同一发送者的信号有序，DOWN 到了，它之前发的结果
%%    一定已经在信箱里——再把 {Ref, _, _} 全部清掉。（6.7.0 发版检查时整模块
%%    跑偶发撞上：别的片 worker 刚好在失败那一刻交了结果。）
kill_workers(Workers, Ref) ->
    [exit(Pid, kill) || {_, {Pid, _MRef}} <- Workers],
    [receive {{Ref, 'DOWN'}, MRef, process, _, _} -> ok
     after 5000 -> erlang:demonitor(MRef, [flush])
     end || {_, {_Pid, MRef}} <- Workers],
    flush_results(Ref).

flush_results(Ref) ->
    receive {Ref, _Idx, _Lists} -> flush_results(Ref)
    after 0 -> ok
    end.

%% 按 N 个一片连续切（保序）。调用方保证 L 非空（空 frontier 不会走到 expand）。
slice(L, N) -> slice(L, N, N, [], []).

slice([], _N, _Left, Cur, Acc)   -> lists:reverse([lists:reverse(Cur) | Acc]);
slice(L, N, 0, Cur, Acc)         -> slice(L, N, N, [], [lists:reverse(Cur) | Acc]);
slice([X | T], N, Left, Cur, Acc) -> slice(T, N, Left - 1, [X | Cur], Acc).

ceil_div(A, B) -> (A + B - 1) div B.

%% 展开只要邻居 vid：直接解邻接表条目，不解析属性（不碰 p 家族）。
neighbor_list(Handle, V, both, Etype) ->
    neighbor_list(Handle, V, out, Etype) ++ neighbor_list(Handle, V, in, Etype);
neighbor_list(Handle, V, Dir, Etype) ->
    case graphdb_adj:entries({direct, Handle}, V, dir_code(Dir), Etype, infinity) of
        {ok, Es}       -> [O || {_T, O, _R, _P} <- Es];
        {error, _} = E -> erlang:error(E)
    end.

maybe_visit(undefined, _Vid, _Depth) -> ok;
maybe_visit(Visit, Vid, Depth) when is_function(Visit, 2) -> _ = Visit(Vid, Depth), ok.

%% 保序去重。cons + 末尾 reverse——hub 上不做 O(d²) 的逐项拷贝。
dedupe(L) ->
    {L2, _} = lists:foldl(fun(V, {Out, Seen}) ->
                              case is_map_key(V, Seen) of
                                  true  -> {Out, Seen};
                                  false -> {[V | Out], Seen#{V => true}}
                              end
                          end, {[], #{}}, L),
    lists:reverse(L2).

normalize_not_found(not_found)      -> {error, not_found};
normalize_not_found({error, _} = E) -> E;
normalize_not_found({ok, _} = Ok)   -> Ok.

normalize_error({error, _} = E) -> E;
normalize_error(Reason)         -> {error, Reason}.

%% 索引模式下引擎回的是 #{text, meta}：图层的值只取 text 段。
vbin(#{text := T}) -> T;
vbin(B) when is_binary(B) -> B.

dir_code(out) -> 0;
dir_code(in)  -> 1.

nvid(Vid) -> _ = nkey(Vid), Vid.

opt_limit(Opts) ->
    case maps:get(limit, Opts, infinity) of
        infinity -> infinity;
        N when is_integer(N), N >= 0 -> N;
        Bad -> erlang:error(badarg, [Opts, Bad])
    end.

opt_etype(Opts) ->
    case maps:get(etype, Opts, undefined) of
        undefined -> undefined;
        T -> ok = v_t32(T), T
    end.

v_edge(S, T, D, R) ->
    ok = v_v64(S), ok = v_t32(T), ok = v_v64(D), ok = v_r64(R).

v_v64(V) when is_integer(V), V >= 0, V =< ?VID_MAX     -> ok;
v_v64(_)   -> erlang:error(badarg).
v_t32(T) when is_integer(T), T >= 0, T =< ?ETYPE_MAX   -> ok;
v_t32(_)   -> erlang:error(badarg).
v_r64(R) when is_integer(R), R >= 0, R =< ?RANK_MAX    -> ok;
v_r64(_)   -> erlang:error(badarg).
