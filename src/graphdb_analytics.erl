%% =========================================================================
%% graphdb_analytics — 图 OLAP：CSR 物化缓存 + 样例算法（设计文档 P4 / §7）
%%
%% graphdb（KV per-key）负责图 OLTP；本模块把 `e` 家族（或单 etype 的 `et`
%% 家族）流式物化为**进程内 CSR**（xadj/adjncy 双向：正向 + 转置），随后
%% PageRank / 连通分量 / SSSP 全部在内存索引上迭代——零 KV 访问。物化结果
%% 是可再生缓存：底层图变更后丢弃重建即可（设计文档 §7「缓存语义，非真源」）。
%%
%% 表示：#csr{} 持二进制 CSR（u32 LE 索引、u64 LE vid 表，对齐本库小端约定）
%% + vid→index 反查 map。BEAM 侧逐元素 binary match 遍历——测试与中小图够用；
%% 数亿边量级的生产路径应在 NIF 内物化（P5+ 基准后再定），不在本模块范围。
%%
%% 算法（均为样例级实现）：
%%   pagerank             — 阻尼 + dangling 质量校正，L1 收敛；沿**入边拉取**
%%                          （pull）——每轮 O(N+M)，不是逐边 setelement 拷整个
%%                          rank 元组的 O(N·M)
%%   connected_components — 无向最小标号传播（收敛轮数 = 图直径量级）
%%   sssp                 — 单源最短路径（CSR 无权：即 BFS 距离；带权需把
%%                          边属性纳入物化，后续版本）
%% =========================================================================
-module(graphdb_analytics).

-export([materialize/2,
         vertex_count/1, edge_count/1, vertex_list/1, out_neighbors/2,
         pagerank/2, connected_components/1, sssp/3]).

-type handle() :: term().
-type vid()    :: 0..16#FFFFFFFFFFFFFFFF.

-record(csr, {n      :: non_neg_integer(),        %% |V|
              m      :: non_neg_integer(),        %% |E|（去重后）
              vids   :: binary(),                 %% n × u64 LE，升序
              idx    :: #{vid() => non_neg_integer()},
              xadj   :: binary(),                 %% (n+1) × u32 LE，出边行偏移
              adjncy :: binary(),                 %% m × u32 LE，出边
              xadjr  :: binary(),                 %% (n+1) × u32 LE，入边行偏移
              adjncyr :: binary()}).              %% m × u32 LE，入边

-opaque csr() :: #csr{}.
-export_type([csr/0]).

%% =========================================================================
%% materialize — e / et 家族 → 内存 CSR
%%
%% Opts:
%%   etype => T   只物化该类型的边（走 et 家族前缀扫描，O(该类型边数)）；
%%                缺省物化全图（走 e 家族全扫，O(全表)）。
%% 重边（同 (src,dst) 多 etype / 多 rank）物化时去重——邻接语义按简单图。
%% =========================================================================

-spec materialize(handle(), map()) -> {ok, csr()} | {error, term()}.
materialize(Handle, Opts) when is_map(Opts) ->
    case collect_edges(Handle, maps:get(etype, Opts, undefined)) of
        {error, _} = E -> E;
        {ok, Pairs}    -> {ok, build_csr(lists:usort(Pairs))}
    end.

%% 收集 (Src, Dst) 对：只 cons 进列表，最后一次 usort 去重——range 按 key 序
%% 出货，输入近乎有序，归并排序比逐边 gb_sets 插入便宜得多。
collect_edges(Handle, undefined) ->
    Fun = fun(K, _V, _T, _O, Acc) ->
              case K of
                  <<"e", S:64/big, _Tt:32/big, D:64/big, _Rr:64/big>> ->
                      [{S, D} | Acc];
                  _ -> Acc                                 %% 病理 vid 防御
              end
          end,
    scan(Handle, <<"e">>, <<"f">>, Fun, []);
collect_edges(Handle, Etype) ->
    Fun = fun(K, _V, _T, _O, Acc) ->
              case K of
                  <<"et", Etype:32/big, S:64/big, D:64/big, _Rr:64/big>> ->
                      [{S, D} | Acc];
                  _ -> Acc
              end
          end,
    Lo = <<"et", Etype:32/big>>,
    scan(Handle, Lo, graphdb:succ(Lo), Fun, []).

scan(Handle, Lo, Hi, Fun, Acc0) ->
    case bitcask:range_fold(Handle, {Lo, Hi}, [], Fun, Acc0) of
        {error, _} = E -> E;
        Acc            -> {ok, Acc}
    end.

%% 排序去重后的边对 → 双向 CSR 二进制。
build_csr(EdgeList) ->
    Vids = lists:usort(lists:append([[S, D] || {S, D} <- EdgeList])),
    N = length(Vids),
    Idx = maps:from_list(lists:zip(Vids, lists:seq(0, N - 1))),
    %% 每条边只查一次 index。index 随 vid 单调，所以 Out 与 EdgeList 同序，
    %% 不必再排；Rev 才要排。
    Out = [{maps:get(S, Idx), maps:get(D, Idx)} || {S, D} <- EdgeList],
    Rev = lists:sort([{J, I} || {I, J} <- Out]),
    {Xadj, Adjncy} = csr_arrays(Out, N),
    {XadjR, AdjncyR} = csr_arrays(Rev, N),
    #csr{n = N,
         m = length(Out),
         vids = << <<V:64/little>> || V <- Vids >>,
         idx = Idx,
         xadj = Xadj, adjncy = Adjncy,
         xadjr = XadjR, adjncyr = AdjncyR}.

%% 排序好的 (i, j) 对 → {xadj 二进制 (N+1 项), adjncy 二进制}。
csr_arrays(SortedPairs, N) ->
    Adjncy = << <<J:32/little>> || {_, J} <- SortedPairs >>,
    Counts = src_counts(SortedPairs, 0, 0, [], N),
    Xadj = prefix_sums(Counts, 0, [0]),
    {list_to_u32bin(Xadj), Adjncy}.

%% SortedPairs 按 src 升序 → 每个 src index 的出边数（长度 N）。
src_counts(Pairs, I, Cnt, Acc, N) when I < N ->
    case Pairs of
        [{I, _} | Rest] -> src_counts(Rest, I, Cnt + 1, Acc, N);
        _               -> src_counts(Pairs, I + 1, 0, [Cnt | Acc], N)
    end;
src_counts(_Pairs, _I, _Cnt, Acc, _N) -> lists:reverse(Acc).

%% 计数 → 前缀和（长度 N+1，首项 0）。Out 为逆序累积。
prefix_sums([], _Acc, Out) -> lists:reverse(Out);
prefix_sums([C | Rest], Acc, [Acc | _] = Out) ->
    prefix_sums(Rest, Acc + C, [Acc + C | Out]).

list_to_u32bin(L) -> << <<X:32/little>> || X <- L >>.

%% =========================================================================
%% 访问器
%% =========================================================================

vertex_count(#csr{n = N}) -> N.
edge_count(#csr{m = M}) -> M.

vertex_list(#csr{vids = V, n = N}) -> [u64(V, I) || I <- lists:seq(0, N - 1)].

%% 顶点 Vid 的出邻居（vid 列表，物化序）；未知顶点 → 空表。
out_neighbors(#csr{idx = Idx, xadj = XA, adjncy = AJ} = Csr, Vid) ->
    case maps:find(Vid, Idx) of
        error -> {ok, []};
        {ok, I} ->
            S = u32(XA, I), E = u32(XA, I + 1),
            {ok, [vid_of(Csr, u32(AJ, K)) || K <- lists:seq(S, E - 1)]}
    end.

vid_of(#csr{vids = V}, I) -> u64(V, I).

%% =========================================================================
%% PageRank — 阻尼 + dangling 质量校正，L1 收敛
%%
%% Opts: #{damping => 0.85, eps => 1.0e-10, max_iter => 100}
%% 返回 #{Vid => Rank}（总和 ≈ 1；空图 → #{}）。
%% =========================================================================

pagerank(#csr{n = 0}, _Opts) -> #{};
pagerank(#csr{} = Csr, Opts) when is_map(Opts) ->
    Damping = maps:get(damping, Opts, 0.85),
    Eps     = maps:get(eps, Opts, 1.0e-10),
    MaxIter = maps:get(max_iter, Opts, 100),
    true = (is_float(Damping) andalso Damping >= 0.0 andalso Damping =< 1.0)
        orelse erlang:error(badarg, [Csr, Opts]),
    N = Csr#csr.n,
    OutDeg = list_to_tuple([outdeg(Csr, I) || I <- lists:seq(0, N - 1)]),
    R0 = list_to_tuple(lists:duplicate(N, 1.0 / N)),
    Final = pr_iter(Csr, OutDeg, R0, Damping, Eps, MaxIter, 0),
    #{vid_of(Csr, I) => element(I + 1, Final) || I <- lists:seq(0, N - 1)}.

%% 一轮 = 两趟线性扫：① 每个顶点的贡献 R_j / outdeg_j（dangling 的记 0，
%% 质量另算）→ 元组；② 沿转置 CSR（xadjr/adjncyr）把每个顶点的入邻居贡献
%% 加起来，按 index 序 cons 出列表再 list_to_tuple 一次。
%% ⚠️ 以前是沿出边 scatter：每条边 setelement 一次 N 元组——编译器只对同一
%%    函数体里连续的 setelement 免拷贝，递归里每次都整拷，一轮 O(N·M)。
pr_iter(_Csr, _OutDeg, R, _D, _Eps, MaxIter, Iter) when Iter >= MaxIter -> R;
pr_iter(#csr{n = N} = Csr, OutDeg, R, D, Eps, MaxIter, Iter) ->
    {Contrib, Dangling} = contrib(N, R, OutDeg, [], 0.0),
    Base = (1.0 - D) / N + D * Dangling / N,
    New = list_to_tuple(pull(Csr, Contrib, Base, D, N - 1, [])),
    case l1(New, R) < Eps of
        true  -> New;
        false -> pr_iter(Csr, OutDeg, New, D, Eps, MaxIter, Iter + 1)
    end.

%% 从后往前扫（I 递减），cons 出来的列表自然是正序。
contrib(0, _R, _OutDeg, Acc, Dangling) ->
    {list_to_tuple(Acc), Dangling};
contrib(I, R, OutDeg, Acc, Dangling) ->
    Rank = element(I, R),
    case element(I, OutDeg) of
        0   -> contrib(I - 1, R, OutDeg, [0.0 | Acc], Dangling + Rank);
        Deg -> contrib(I - 1, R, OutDeg, [Rank / Deg | Acc], Dangling)
    end.

pull(_Csr, _Contrib, _Base, _D, I, Acc) when I < 0 -> Acc;
pull(#csr{xadjr = XR, adjncyr = AR} = Csr, Contrib, Base, D, I, Acc) ->
    Sum = sum_range(AR, u32(XR, I), u32(XR, I + 1), Contrib, 0.0),
    pull(Csr, Contrib, Base, D, I - 1, [Base + D * Sum | Acc]).

sum_range(_AJ, S, S, _Contrib, Acc) -> Acc;
sum_range(AJ, S, E, Contrib, Acc) ->
    sum_range(AJ, S + 1, E, Contrib, Acc + element(u32(AJ, S) + 1, Contrib)).

l1(New, Old) -> l1(tuple_size(New), New, Old, 0.0).

l1(0, _New, _Old, Acc) -> Acc;
l1(I, New, Old, Acc) ->
    l1(I - 1, New, Old, abs(element(I, New) - element(I, Old)) + Acc).

outdeg(Csr, I) -> u32(Csr#csr.xadj, I + 1) - u32(Csr#csr.xadj, I).

%% =========================================================================
%% 连通分量 — 无向最小标号传播（弱连通；收敛轮数 = 直径量级）
%% 返回 #{Vid => ComponentMinVid}。
%% =========================================================================

connected_components(#csr{n = 0}) -> #{};
connected_components(#csr{n = N} = Csr) ->
    Labels0 = list_to_tuple(lists:seq(0, N - 1)),
    Final = cc_iter(Csr, Labels0),
    CompIdx = lists:usort([element(I + 1, Final) || I <- lists:seq(0, N - 1)]),
    %% 分量代表 = 分量内最小 index 对应的 vid
    MinVid = maps:from_list([{L, vid_of(Csr, L)} || L <- CompIdx]),
    #{vid_of(Csr, I) => maps:get(element(I + 1, Final), MinVid)
      || I <- lists:seq(0, N - 1)}.

cc_iter(Csr, Labels) ->
    {New, Changed} = cc_pass(Csr, Labels, 0, false, []),
    case Changed of
        true  -> cc_iter(Csr, New);
        false -> Labels
    end.

cc_pass(#csr{} = Csr, Labels, I, Changed, Acc) when I < tuple_size(Labels) ->
    M0 = element(I + 1, Labels),
    M1 = cc_min_range(Csr#csr.adjncy,
                      u32(Csr#csr.xadj, I), u32(Csr#csr.xadj, I + 1), M0, Labels),
    M2 = cc_min_range(Csr#csr.adjncyr,
                      u32(Csr#csr.xadjr, I), u32(Csr#csr.xadjr, I + 1), M1, Labels),
    case M2 < M0 of
        true  -> cc_pass(Csr, Labels, I + 1, true, [M2 | Acc]);
        false -> cc_pass(Csr, Labels, I + 1, Changed, [M0 | Acc])
    end;
cc_pass(_Csr, _Labels, _I, Changed, Acc) ->
    {list_to_tuple(lists:reverse(Acc)), Changed}.

cc_min_range(_AJ, S, S, M, _Labels) -> M;
cc_min_range(AJ, S, E, M, Labels) ->
    L = element(u32(AJ, S) + 1, Labels),
    cc_min_range(AJ, S + 1, E, min(L, M), Labels).

%% =========================================================================
%% SSSP — CSR 无权（BFS 距离）。返回 {ok, #{Vid => Dist}}（仅可达顶点）。
%% Opts 保留（当前内容被忽略）。
%% =========================================================================

%% 一张 map 兼作 visited 与距离表（#{Index => Depth}）：只碰可达顶点，
%% O(V+E)。以前是 N 元组逐点 setelement（每次整拷，O(N·可达数)）外加一张
%% 冗余的 seen map，末了还全表扫一遍挑 < Inf 的。
sssp(#csr{} = Csr, Src, Opts) when is_map(Opts) ->
    case maps:find(Src, Csr#csr.idx) of
        error -> {error, not_found};
        {ok, SI} ->
            Final = bfs_layers(Csr, [SI], 0, #{SI => 0}),
            {ok, maps:fold(fun(I, Dd, M) -> M#{vid_of(Csr, I) => Dd} end, #{}, Final)}
    end.

bfs_layers(Csr, Frontier, Depth, Dist) ->
    D1 = Depth + 1,
    {FreshR, Dist2} =
        lists:foldl(fun(J, {Fs, M}) ->
                        case is_map_key(J, M) of
                            true  -> {Fs, M};
                            false -> {[J | Fs], M#{J => D1}}
                        end
                    end,
                    {[], Dist}, lists:append([adj_idxs(Csr, I) || I <- Frontier])),
    case FreshR of
        [] -> Dist2;
        _  -> bfs_layers(Csr, lists:reverse(FreshR), D1, Dist2)
    end.

adj_idxs(Csr, I) ->
    adj_range(Csr#csr.adjncy, u32(Csr#csr.xadj, I), u32(Csr#csr.xadj, I + 1), []).

adj_range(_AJ, S, S, Acc) -> lists:reverse(Acc);
adj_range(AJ, S, E, Acc)  -> adj_range(AJ, S + 1, E, [u32(AJ, S) | Acc]).

%% ---- CSR 二进制原语 ----

u32(Bin, I) ->
    <<_:I/unit:32, X:32/little, _/binary>> = Bin,
    X.

u64(Bin, I) ->
    <<_:I/unit:64, X:64/little, _/binary>> = Bin,
    X.
