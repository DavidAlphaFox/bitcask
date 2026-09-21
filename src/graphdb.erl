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
%%   et <etype:32> <src:64> <dst:64> <rank:64>   → 按类型全局列边（值恒 <<>>，
%%                                          P3：edges_by_type 的 O(该类型边数) 索引）
%%   deg  <vid:64> <etype:32> → u64       → 出度计数（P3，put_edge/del_edge 同批维护）
%%   degi <vid:64> <etype:32> → u64       → 入度计数（P3，同上）
%%
%% ⚠️ deg/degi 是读-判-写计数（引擎无 CAS）：直通 API（put_edge/del_edge）
%% 下并发对同一端点加边可能丢计数，单写者语义（每图一个写进程 / 串行写）
%% 下精确。**要并发写且计数精确，用事务式 API**（见下）。del_vertex 级联会
%% 聚合邻居计数器增量，一次 RMW 对齐。per-etype 计数缺失时 degree/3 回退
%% 按需计数。
%%
%% === 事务式 API（X1-5，doc/txn-layer-design-zh.md）===
%%
%%   graphdb:transaction(H, fun(Tx) ->
%%       ok = graphdb:put_edge_txn(Tx, 1, 7, 2),
%%       ok = graphdb:del_edge_txn(Tx, 1, 7, 3),
%%       graphdb:degree_txn(Tx, 1, 7)
%%   end)                                   → {atomic, {ok, N}} | {aborted, Why}
%%
%%   put_edge_txn / del_edge_txn / edge_txn / degree_txn / put_vertex_txn /
%%   get_vertex_txn 是对应直通函数的事务内版本：读走 bitcask_txn:read
%%（上锁），写进事务缓冲，提交时与同事务的其它改动一起进**一条** txn_commit
%%   批。边键 + 反向键 + et + 两个计数器全在锁下，并发加边到同一端点的计数
%%   **精确**（2PL 可串行化）；死锁自动重跑。计数器 RMW 直接拿写锁
%%（read/3 的 write 模式），避免读锁升级型死锁。
%%
%%   前缀锁版本（X1-6）：out_edges_txn / in_edges_txn 对 e<vid>/ei<vid>
%%   前缀拿读锁再扫（bitcask_txn:prefix_range，合并本事务缓冲）——扫描期间
%%   没人能往这个顶点上加/删边（无幻读）；degree_txn/2 同理。del_vertex_txn
%%   对两个前缀拿**写**锁做级联：incident 边三键、邻居计数器 RMW、自身全部
%%   计数键（deg<vid>/degi<vid> 前缀扫）、顶点键，一批提交。
%%
%%   ⚠️ 直通 put_edge 与 put_edge_txn **不要混用于同一图的边写入**：直通
%%      绕过锁，与事务并发时计数器行为未定义（bitcask_txn §4.8）。要么全走
%%      事务，要么全走直通 + 单写者。只读的直通扫描（out_edges/bfs/…）随便用，
%%      仍是 per-key 弱一致。
%%   ⚠️ put_vertex_txn 的 Doc 只收 binary（事务批只装 binary；索引模式的
%%      #{text=>...} 文档请走直通 put_vertex）。
%%   ⚠️ hub 顶点的 del_vertex_txn 是一条大批（不像直通版分 @DEL_BATCH 段）：
%%      要么全成要么全不成，但持前缀写锁的时间 = 扫 + 提交。
%%   ⚠️ Fun 必须无副作用（可能重跑）。
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

         transaction/2, transaction/3,
         put_vertex_txn/3, get_vertex_txn/2,
         put_edge_txn/4, put_edge_txn/5, edge_txn/4, edge_txn/5,
         del_edge_txn/4, del_edge_txn/5, del_vertex_txn/2,
         out_edges_txn/2, out_edges_txn/3, in_edges_txn/2, in_edges_txn/3,
         degree_txn/2, degree_txn/3,

         out_edges/2, out_edges/3, in_edges/2, in_edges/3,
         neighbors/3, neighbors_where/4,
         degree/2, degree/3, edges_by_type/2, edges_by_type/3,

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
            %% 每条 incident 边（无论从哪侧收集）都要摘掉正向 + 反向 + et 三个键；
            %% 自环会在两侧各出现一次 → 重复 remove，原子批按 LWW apply，无害。
            PairF = fun(#{src := S, etype := T, dst := D, rank := R}) ->
                        [{remove, ekey(S, T, D, R)},
                         {remove, eikey(D, T, S, R)},
                         {remove, etkey(T, S, D, R)}]
                    end,
            PairI = fun(#{dst := D, etype := T, src := S, rank := R}) ->
                        [{remove, ekey(S, T, D, R)},
                         {remove, eikey(D, T, S, R)},
                         {remove, etkey(T, S, D, R)}]
                    end,
            %% 邻居计数器增量聚合：in 边 (X→vid) 使 X 的出度 -1；
            %% out 边 (vid→Y) 使 Y 的入度 -1。同 (端点, etype) 合并成一次 RMW。
            DecOut = agg_counts([{S, T} || #{src := S, etype := T} <- In]),
            DecIn  = agg_counts([{D, T} || #{dst := D, etype := T} <- Out]),
            CounterOps =
                [counter_delta(Handle, degkey(X, T), -C)
                 || {{X, T}, C} <- maps:to_list(DecOut)]
                ++ [counter_delta(Handle, degikey(Y, T), -C)
                    || {{Y, T}, C} <- maps:to_list(DecIn)],
            OwnEtypes = lists:usort([T || #{etype := T} <- Out]
                                    ++ [T || #{etype := T} <- In]),
            OwnCounters = [{remove, degkey(Vid, T)}  || T <- OwnEtypes]
                        ++ [{remove, degikey(Vid, T)} || T <- OwnEtypes],
            Ops = lists:flatmap(PairF, Out)
                ++ lists:flatmap(PairI, In)
                ++ CounterOps
                ++ OwnCounters
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
    %% upsert：边已存在 → 只改属性（计数器/et 不动）；否则全量插入。
    case edge(Handle, Src, Etype, Dst, Rank) of
        {ok, _} ->
            bitcask:put_batch_atomic(Handle, [{put, ekey(Src, Etype, Dst, Rank), Props}]);
        {error, not_found} ->
            bitcask:put_batch_atomic(
              Handle, [{put, ekey(Src, Etype, Dst, Rank), Props},
                       {put, eikey(Dst, Etype, Src, Rank), <<>>},
                       {put, etkey(Etype, Src, Dst, Rank), <<>>},
                       {put, degkey(Src, Etype),  <<(bump(Handle, degkey(Src, Etype), 1)):64/big>>},
                       {put, degikey(Dst, Etype), <<(bump(Handle, degikey(Dst, Etype), 1)):64/big>>}]);
        {error, _} = E ->
            E
    end.

%% 读-改-写计数基值（缺 key = 0）。
bump(Handle, Key, Delta) ->
    case bitcask:get(Handle, Key) of
        {ok, <<N:64/big>>} -> max(0, N + Delta);
        _                  -> max(0, Delta)
    end.

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
    case edge(Handle, Src, Etype, Dst, Rank) of
        {error, not_found} ->
            ok;                                  %% 幂等删除
        {ok, _} ->
            bitcask:put_batch_atomic(
              Handle, [{remove, ekey(Src, Etype, Dst, Rank)},
                       {remove, eikey(Dst, Etype, Src, Rank)},
                       {remove, etkey(Etype, Src, Dst, Rank)},
                       {put, degkey(Src, Etype),  <<(bump(Handle, degkey(Src, Etype), -1)):64/big>>},
                       {put, degikey(Dst, Etype), <<(bump(Handle, degikey(Dst, Etype), -1)):64/big>>}]);
        {error, _} = E ->
            E
    end.

%% =========================================================================
%% 事务式 API — 计数器精确的并发写（bitcask_txn 之上，模块头有说明）
%%
%% 与直通版本逐一对应；区别只在 IO 走哪条路：
%%   读  bitcask:get            →  bitcask_txn:read/3（上锁；RMW 直接写锁）
%%   写  bitcask:put_batch_atomic →  bitcask_txn:write / delete（进缓冲）
%% 引擎读错误在事务里没法继续，直接 abort(Reason) → {aborted, Reason}。
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
    Rank  = maps:get(rank, Opts, 0),
    Props = maps:get(props, Opts, <<>>),
    true = is_binary(Props) orelse erlang:error(badarg, [Tx, Src, Etype, Dst, Opts]),
    EK = ekey(Src, Etype, Dst, Rank),
    %% 边键本来就要写，直接写锁读——两个事务同时 upsert 同一条边不会
    %% 各自持读锁再互等升级。
    case txn_read(Tx, EK, write) of
        {ok, _} ->
            bitcask_txn:write(Tx, EK, Props);          %% upsert：只改属性
        not_found ->
            ok = bitcask_txn:write(Tx, EK, Props),
            ok = bitcask_txn:write(Tx, eikey(Dst, Etype, Src, Rank), <<>>),
            ok = bitcask_txn:write(Tx, etkey(Etype, Src, Dst, Rank), <<>>),
            ok = bump_txn(Tx, degkey(Src, Etype), 1),
            bump_txn(Tx, degikey(Dst, Etype), 1)
    end.

edge_txn(Tx, Src, Etype, Dst) -> edge_txn(Tx, Src, Etype, Dst, 0).
edge_txn(Tx, Src, Etype, Dst, Rank) ->
    case txn_read(Tx, ekey(Src, Etype, Dst, Rank), read) of
        {ok, Props} when is_binary(Props) ->
            {ok, #{src => Src, etype => Etype, dst => Dst,
                   rank => Rank, props => Props}};
        {ok, _}   -> {error, invalid_edge_props};
        not_found -> {error, not_found}
    end.

del_edge_txn(Tx, Src, Etype, Dst) -> del_edge_txn(Tx, Src, Etype, Dst, 0).
del_edge_txn(Tx, Src, Etype, Dst, Rank) ->
    EK = ekey(Src, Etype, Dst, Rank),
    case txn_read(Tx, EK, write) of
        not_found ->
            ok;                                  %% 幂等删除（边键仍留写锁，无害）
        {ok, _} ->
            ok = bitcask_txn:delete(Tx, EK),
            ok = bitcask_txn:delete(Tx, eikey(Dst, Etype, Src, Rank)),
            ok = bitcask_txn:delete(Tx, etkey(Etype, Src, Dst, Rank)),
            ok = bump_txn(Tx, degkey(Src, Etype), -1),
            bump_txn(Tx, degikey(Dst, Etype), -1)
    end.

%% 度数。per-etype：读锁下读计数键；计数键缺失（P3 前存量）→ 前缀读锁
%% 下按需扫描。undefined：前缀读锁下数全部出边（无总数键）。
degree_txn(Tx, Vid) -> degree_txn(Tx, Vid, undefined).
degree_txn(Tx, Vid, undefined) ->
    {Lo, _Hi} = out_range(Vid, undefined),
    {ok, length(txn_prefix_range(Tx, Lo, read))};
degree_txn(Tx, Vid, Etype) ->
    ok = v_t32(Etype),
    case txn_read(Tx, degkey(Vid, Etype), read) of
        {ok, <<N:64/big>>} -> {ok, N};
        {ok, _}            -> {error, invalid_degree_record};
        not_found          ->
            {Lo, _Hi} = out_range(Vid, Etype),
            {ok, length(txn_prefix_range(Tx, Lo, read))}
    end.

%% 邻接扫描的事务版：前缀读锁 + 合并缓冲。Opts 同直通版（etype / limit）。
%% 返回 {ok, [edge()]}（与直通版同形；引擎错误已在事务内 abort）。
out_edges_txn(Tx, Vid) -> out_edges_txn(Tx, Vid, #{}).
out_edges_txn(Tx, Vid, Opts) when is_map(Opts) ->
    {Lo, _Hi} = out_range(Vid, maps:get(etype, Opts, undefined)),
    Rows = txn_prefix_range(Tx, Lo, read),
    Edges = [#{src => Src, etype => T, dst => D, rank => R, props => maybe_props(V)}
             || {K, V} <- Rows, {ok, Src, T, D, R} <- [parse_e(K)], Src =:= Vid],
    {ok, take_limit(Edges, opt_limit(Opts))}.

in_edges_txn(Tx, Vid) -> in_edges_txn(Tx, Vid, #{}).
in_edges_txn(Tx, Vid, Opts) when is_map(Opts) ->
    {Lo, _Hi} = in_range(Vid, maps:get(etype, Opts, undefined)),
    Rows = txn_prefix_range(Tx, Lo, read),
    Edges = [#{dst => Dst, etype => T, src => S, rank => R, props => maybe_props(V)}
             || {K, V} <- Rows, {ok, Dst, T, S, R} <- [parse_ei(K)], Dst =:= Vid],
    {ok, take_limit(Edges, opt_limit(Opts))}.

take_limit(L, infinity) -> L;
take_limit(L, N)        -> lists:sublist(L, N).

%% 级联删除的事务版（与直通 del_vertex 语义对齐，但一批提交、无幻读）：
%%   1. e<vid> / ei<vid> 两个前缀拿写锁——扫描期间没人能再挂边上来；
%%   2. 每条 incident 边摘正向 + 反向 + et 三键；邻居计数器逐条 RMW
%%      （缓冲读自己的写，同邻居多条边自然累加，不必像直通版先聚合）；
%%   3. 自身计数键按 deg<vid> / degi<vid> 前缀扫掉（直通版只删有边的 etype，
%%      这里连零值残留一起清）；自环的邻居 RMW 会被随后的 delete 覆盖；
%%   4. 顶点键。
del_vertex_txn(Tx, Vid) ->
    {OutLo, _} = out_range(Vid, undefined),
    {InLo, _}  = in_range(Vid, undefined),
    ok = bitcask_txn:lock_prefix(Tx, OutLo, write),
    ok = bitcask_txn:lock_prefix(Tx, InLo, write),
    {ok, Out} = out_edges_txn(Tx, Vid),
    {ok, In}  = in_edges_txn(Tx, Vid),
    lists:foreach(
      fun(#{src := S, etype := T, dst := D, rank := R}) ->
              ok = bitcask_txn:delete(Tx, ekey(S, T, D, R)),
              ok = bitcask_txn:delete(Tx, eikey(D, T, S, R)),
              ok = bitcask_txn:delete(Tx, etkey(T, S, D, R))
      end, Out ++ In),
    [ok = bump_txn(Tx, degikey(D, T), -1) || #{dst := D, etype := T} <- Out],
    [ok = bump_txn(Tx, degkey(S, T), -1)  || #{src := S, etype := T} <- In],
    DegLo  = <<"deg",  Vid:64/big>>,
    DegiLo = <<"degi", Vid:64/big>>,
    [ok = bitcask_txn:delete(Tx, K) || {K, _} <- txn_prefix_range(Tx, DegLo, write),
                                        byte_size(K) =:= 3 + 8 + 4],
    [ok = bitcask_txn:delete(Tx, K) || {K, _} <- txn_prefix_range(Tx, DegiLo, write),
                                        byte_size(K) =:= 4 + 8 + 4],
    bitcask_txn:delete(Tx, nkey(Vid)).

txn_prefix_range(Tx, Prefix, Lock) ->
    case bitcask_txn:prefix_range(Tx, Prefix, [{lock, Lock}]) of
        {error, Reason} -> bitcask_txn:abort(Reason);
        Rows            -> Rows
    end.

%% 计数 RMW：写锁下读、算、写回缓冲。缺 key = 0，不下穿 0。
bump_txn(Tx, Key, Delta) ->
    N = case txn_read(Tx, Key, write) of
            {ok, <<Cur:64/big>>} -> max(0, Cur + Delta);
            _                    -> max(0, Delta)
        end,
    bitcask_txn:write(Tx, Key, <<N:64/big>>).

%% 事务内读：引擎错误直接中止事务（拿到一半的读没法给出正确结果）。
txn_read(Tx, Key, Lock) ->
    case bitcask_txn:read(Tx, Key, Lock) of
        {error, Reason} -> bitcask_txn:abort(Reason);
        Other           -> Other
    end.

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
        {ok, Edges}    -> {ok, dedupe([D || #{dst := D} <- Edges])}
    end;
edge_endpoints(Handle, Vid, in) ->
    case in_edges(Handle, Vid) of
        {error, _} = E -> E;
        {ok, Edges}    -> {ok, dedupe([S || #{src := S} <- Edges])}
    end.

%% 度数。per-etype：O(1) 读 deg 计数键（P3 前的存量数据无计数键 → 回退按需
%% 计数）；undefined：O(出度) 全量计数（计数键按 etype 分立，无总数键）。
degree(Handle, Vid) -> degree(Handle, Vid, undefined).
degree(Handle, Vid, undefined) ->
    count_out(Handle, Vid, undefined);
degree(Handle, Vid, Etype) ->
    ok = v_t32(Etype),
    case bitcask:get(Handle, degkey(Vid, Etype)) of
        {ok, <<N:64/big>>} -> {ok, N};
        {ok, _}            -> {error, invalid_degree_record};
        not_found          -> count_out(Handle, Vid, Etype);   %% 只数该类型
        {error, _} = E     -> E
    end.

%% 按需计数：O(出度) 前缀扫描，Etype = undefined 数全部。
count_out(Handle, Vid, Etype) ->
    {Lo, Hi} = out_range(Vid, Etype),
    case range_take(Handle, Lo, Hi, infinity, fun(_K, _V) -> {ok, count} end) of
        {error, _} = E -> E;
        {ok, Items}    -> {ok, length(Items)}
    end.

%% et 家族：按类型全局列边（key 序 = (src, dst, rank) 字典序）。
%% 边属性不落在 et 键上——需要属性时对结果逐条 edge/5 点查。
edges_by_type(Handle, Etype) -> edges_by_type(Handle, Etype, #{}).
edges_by_type(Handle, Etype, Opts) when is_map(Opts) ->
    ok = v_t32(Etype),
    Lo = <<"et", Etype:32/big>>,
    Limit = opt_limit(Opts),
    range_take(Handle, Lo, succ(Lo), Limit,
               fun(K, _V) ->
                   case K of
                       <<"et", Etype:32/big, S:64/big, D:64/big, R:64/big>> ->
                           {ok, #{src => S, etype => Etype, dst => D,
                                  rank => R, props => <<>>}};
                       _ -> skip
                   end
               end).

%% 属性过滤遍历：逐跳在 Erlang 侧过滤（设计文档 §6.5 两阶段法的朴素版——
%% 检索候选集求交可用 search_fields 的结果直接与 neighbors 的 vid 集求交）。
%% Pred(neighbor_vid, VertexValue | undefined) -> boolean()；端点顶点缺失
%% （悬挂边）时 Value 为 undefined。
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

counter_delta(Handle, Key, Delta) ->
    {put, Key, <<(bump(Handle, Key, Delta)):64/big>>}.

agg_counts(Pairs) ->
    lists:foldl(fun(K, M) -> M#{K => maps:get(K, M, 0) + 1} end, #{}, Pairs).

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

degkey(Vid, Etype)  -> <<"deg",  Vid:64/big, Etype:32/big>>.
degikey(Vid, Etype) -> <<"degi", Vid:64/big, Etype:32/big>>.
etkey(Etype, Src, Dst, Rank) ->
    <<"et", Etype:32/big, Src:64/big, Dst:64/big, Rank:64/big>>.

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
