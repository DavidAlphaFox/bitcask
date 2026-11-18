%% =========================================================================
%% graphdb_migrate — 图层 v1 → v2 离线迁移（doc/graph-adjacency-pack-design-zh.md §10）
%%
%%   {ok, Stats} = graphdb_migrate:v1_to_v2(SrcDir, DstDir)
%%   {ok, Stats} = graphdb_migrate:v1_to_v2(SrcDir, DstDir, Opts)
%%   ok          = graphdb_migrate:verify(SrcDir, DstDir)
%%
%% 流式，内存占用与图大小无关（只与单个顶点的度数有关）：
%%   * v1 的 `e` 家族按 key 序就是按 src 聚好的出边，`ei` 家族按 key 序就是按
%%     dst 聚好的入边；两路有序游标按 vid 归并，逐顶点拼出 v2 邻接表头（超过
%%     阈值就分块，大属性落 p 家族），攒批写进新目录；
%%   * `n`（顶点）、`t` / `tn`（etype 注册表）原样拷贝；
%%   * `et`、`deg`、`degi` 丢弃（v2 由邻接表头直接给出度数）；
%%   * 非图层的 key（应用自己的数据）**不拷贝**。
%% 不做原地迁移：源目录只读打开、不改一个字节；目标目录必须没有图数据。
%%
%% Opts（proplist）：
%%   {src_opts, L}          源目录 bitcask:open 选项（默认 []，只读；索引模式的
%%                          库要带上同样的 analyzer 等选项）
%%   {dst_opts, L}          目标目录额外的 bitcask:open 选项（read_write 自动加）
%%   {adj_inline_max, N} / {adj_chunk_max, N} / {props_inline_max, N}
%%                          目标库的图参数（同 graphdb:open/2）
%%   {verify, Bool}         迁移后逐顶点核对出入边（默认 true）
%%   {batch_ops, N}         每个原子批的 op 上限（默认 1000）
%%
%% Stats = #{vertices => 写出的邻接表头数, edges => 边数, chunks => 块数,
%%           copied => 拷贝的 n / t / tn 键数}
%% =========================================================================
-module(graphdb_migrate).

-export([v1_to_v2/2, v1_to_v2/3, verify/2, verify/3]).

-define(RANGE_BATCH, 256).
-define(DEFAULT_BATCH_OPS, 1000).

v1_to_v2(SrcDir, DstDir) -> v1_to_v2(SrcDir, DstDir, []).

v1_to_v2(SrcDir, DstDir, Opts) ->
    with_pair(SrcDir, DstDir, Opts, read_write,
              fun(Src, Dst) ->
                      case dst_empty(Dst) of
                          false -> {error, dst_not_empty};
                          true  -> migrate(Src, Dst, Opts)
                      end
              end).

verify(SrcDir, DstDir) -> verify(SrcDir, DstDir, []).

verify(SrcDir, DstDir, Opts) ->
    with_pair(SrcDir, DstDir, Opts, read_only, fun verify_handles/2).

%% =========================================================================
%% 打开 / 关闭
%% =========================================================================

with_pair(SrcDir, DstDir, Opts, Mode, Fun) ->
    SrcOpts = proplists:get_value(src_opts, Opts, []),
    GraphOpts = [O || {K, _} = O <- Opts,
                      lists:member(K, [adj_inline_max, adj_chunk_max, props_inline_max])],
    DstOpts = proplists:get_value(dst_opts, Opts, [])
              ++ [read_write || Mode =:= read_write] ++ GraphOpts,
    case bitcask:open(SrcDir, SrcOpts) of
        {error, _} = E -> E;
        Src ->
            try
                case graphdb:open(DstDir, DstOpts) of
                    {error, _} = E2 -> E2;
                    Dst ->
                        try Fun(Src, Dst)
                        after graphdb:close(Dst)
                        end
                end
            after
                bitcask:close(Src)
            end
    end.

dst_empty(Dst) ->
    Fun = fun(_K, _V, _T, _O, _A) -> throw({graphdb_migrate, nonempty}) end,
    try bitcask:range_fold(Dst, {<<"a">>, <<"b">>}, [], Fun, ok) of
        _ -> true
    catch throw:{graphdb_migrate, nonempty} -> false
    end.

%% =========================================================================
%% 迁移
%% =========================================================================

migrate(Src, Dst, Opts) ->
    Cfg = graphdb:graph_config(Dst),
    BatchOps = proplists:get_value(batch_ops, Opts, ?DEFAULT_BATCH_OPS),
    true = is_integer(BatchOps) andalso BatchOps > 0,
    CE = cur_open(Src, <<"e">>, <<"f">>, fun parse_e/2),
    CI = cur_open(Src, <<"ei">>, <<"ej">>, fun parse_ei/2),
    try
        Stats0 = #{vertices => 0, edges => 0, chunks => 0, copied => 0},
        case merge_loop(CE, CI, Dst, Cfg, BatchOps, [], 0, Stats0) of
            {error, _} = E -> E;
            {ok, Stats1} ->
                case copy_families(Src, Dst, BatchOps, Stats1) of
                    {error, _} = E -> E;
                    {ok, Stats} ->
                        case proplists:get_value(verify, Opts, true) of
                            false -> {ok, Stats};
                            true ->
                                case verify_handles(Src, Dst) of
                                    ok             -> {ok, Stats};
                                    {error, _} = E -> E
                                end
                        end
                end
        end
    after
        cur_close(CE),
        cur_close(CI)
    end.

%% 两路游标按 vid 归并；每个 vid 拼一个顶点。
merge_loop(CE, CI, Dst, Cfg, BatchOps, Pending, NPending, Stats) ->
    case {cur_peek(CE), cur_peek(CI)} of
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E;
        {{eof, _}, {eof, _}} ->
            case flush(Dst, Pending) of
                ok -> {ok, Stats};
                E  -> E
            end;
        {{HE, CE1}, {HI, CI1}} ->
            Vid = min(head_vid(HE), head_vid(HI)),
            case {cur_take(CE1, Vid), cur_take(CI1, Vid)} of
                {{error, _} = E, _} -> E;
                {_, {error, _} = E} -> E;
                {{Out, CE2}, {In, CI2}} ->
                    {Ops, NCh} = graphdb_adj:build_vertex(Vid, {Out, In}, Cfg),
                    Stats2 = Stats#{vertices := maps:get(vertices, Stats) + 1,
                                    edges := maps:get(edges, Stats) + length(Out),
                                    chunks := maps:get(chunks, Stats) + NCh},
                    Pending2 = lists:reverse(Ops, Pending),
                    NP2 = NPending + length(Ops),
                    case NP2 >= BatchOps of
                        true ->
                            case flush(Dst, Pending2) of
                                ok -> merge_loop(CE2, CI2, Dst, Cfg, BatchOps, [], 0, Stats2);
                                E  -> E
                            end;
                        false ->
                            merge_loop(CE2, CI2, Dst, Cfg, BatchOps, Pending2, NP2, Stats2)
                    end
            end
    end.

head_vid(eof)         -> infinity;
head_vid({Vid, _Item}) -> Vid.

flush(_Dst, []) -> ok;
flush(Dst, RevOps) ->
    bitcask:put_batch_atomic(Dst, lists:reverse(RevOps)).

%% v1 解析：严格定长（`e` 区间里混着 30 字节的 ei / et 键）。
parse_e(<<"e", S:64/big, T:32/big, D:64/big, R:64/big>>, V) -> {S, {T, D, R, vbin(V)}};
parse_e(_, _) -> skip.

parse_ei(<<"ei", D:64/big, T:32/big, S:64/big, R:64/big>>, _V) -> {D, {T, S, R}};
parse_ei(_, _) -> skip.

%% n / t / tn 原样拷贝（t 区间同时罩住 tn）。
copy_families(Src, Dst, BatchOps, Stats) ->
    lists:foldl(fun(_R, {error, _} = E) -> E;
                   ({Lo, Hi}, {ok, St}) -> copy_range(Src, Dst, Lo, Hi, BatchOps, St)
                end, {ok, Stats}, [{<<"n">>, <<"o">>}, {<<"t">>, <<"u">>}]).

copy_range(Src, Dst, Lo, Hi, BatchOps, Stats) ->
    Fun = fun(K, V, _T, _O, {Ops, N, Copied}) ->
                  Ops2 = [{put, K, copy_value(V)} | Ops],
                  case N + 1 >= BatchOps of
                      true ->
                          case flush(Dst, Ops2) of
                              ok -> {[], 0, Copied + 1};
                              E  -> throw({graphdb_migrate, E})
                          end;
                      false ->
                          {Ops2, N + 1, Copied + 1}
                  end
          end,
    try bitcask:range_fold(Src, {Lo, Hi}, [], Fun, {[], 0, 0}) of
        {error, _} = E -> E;
        {Ops, _N, Copied} ->
            case flush(Dst, Ops) of
                ok -> {ok, Stats#{copied := maps:get(copied, Stats) + Copied}};
                E  -> E
            end
    catch throw:{graphdb_migrate, E} -> E
    end.

%% 索引模式的值是 #{text, meta}：meta 为 undefined 时去掉（doc map 只收 binary）。
copy_value(#{text := T, meta := undefined}) -> #{text => T};
copy_value(#{text := _} = M) -> maps:with([text, meta], M);
copy_value(B) when is_binary(B) -> B.

vbin(#{text := T}) -> T;
vbin(B) when is_binary(B) -> B.

%% =========================================================================
%% 核对：逐顶点比对 v1 的出 / 入边与 v2 读出来的结果，外加 v2 头数 = 顶点数
%% =========================================================================

verify_handles(Src, Dst) ->
    CE = cur_open(Src, <<"e">>, <<"f">>, fun parse_e/2),
    CI = cur_open(Src, <<"ei">>, <<"ej">>, fun parse_ei/2),
    try verify_loop(CE, CI, Dst, 0) of
        {ok, NV} ->
            case count_heads(Dst) of
                NV             -> ok;
                {error, _} = E -> E;
                N              -> {error, {head_count_mismatch, NV, N}}
            end;
        Other ->
            Other
    after
        cur_close(CE),
        cur_close(CI)
    end.

verify_loop(CE, CI, Dst, NV) ->
    case {cur_peek(CE), cur_peek(CI)} of
        {{error, _} = E, _} -> E;
        {_, {error, _} = E} -> E;
        {{eof, _}, {eof, _}} -> {ok, NV};
        {{HE, CE1}, {HI, CI1}} ->
            Vid = min(head_vid(HE), head_vid(HI)),
            case {cur_take(CE1, Vid), cur_take(CI1, Vid)} of
                {{error, _} = E, _} -> E;
                {_, {error, _} = E} -> E;
                {{Out, CE2}, {In, CI2}} ->
                    case {graphdb:out_edges(Dst, Vid), graphdb:in_edges(Dst, Vid)} of
                        {{ok, O2}, {ok, I2}} ->
                            Out2 = [{T, D, R, P} || #{etype := T, dst := D, rank := R,
                                                      props := P} <- O2],
                            In2 = [{T, S, R} || #{etype := T, src := S, rank := R} <- I2],
                            case {Out2 =:= Out, In2 =:= In} of
                                {true, true} -> verify_loop(CE2, CI2, Dst, NV + 1);
                                _            -> {error, {mismatch, Vid}}
                            end;
                        {{error, _} = E, _} -> E;
                        {_, {error, _} = E} -> E
                    end
            end
    end.

count_heads(Dst) ->
    Fun = fun(<<"a", _:64>>, _V, _T, _O, N) -> N + 1;
             (_, _, _, _, N) -> N
          end,
    bitcask:range_fold(Dst, {<<"a">>, <<"b">>}, [], Fun, 0).

%% =========================================================================
%% 有序游标（range 迭代器 + 批量拉取）：两路归并要同时推进两个迭代器，
%% range_fold 的回调形态做不到，这里直接用 range NIF。
%% =========================================================================

-record(cur, {it :: term(), buf = [] :: list(), done = false :: boolean(),
              parse :: undefined | fun((binary(), term()) -> term()),
              err = undefined :: undefined | {error, term()}}).

cur_open(H, Lo, Hi, Parse) ->
    case bitcask_cpp_nifs:cask_range_start(element(1, H), [{lo, Lo}, {hi, Hi}]) of
        {ok, It} -> #cur{it = It, parse = Parse};
        {error, _} = E -> #cur{done = true, err = E};
        Other -> #cur{done = true, err = {error, Other}}
    end.

cur_close(#cur{it = undefined}) -> ok;
cur_close(#cur{it = It}) -> _ = bitcask_cpp_nifs:cask_range_release(It), ok.

%% {eof | {Vid, Item}, Cur'} | {error, _}
cur_peek(#cur{err = {error, _} = E}) -> E;
cur_peek(#cur{buf = [H | _]} = C) -> {H, C};
cur_peek(#cur{buf = [], done = true} = C) -> {eof, C};
cur_peek(#cur{buf = [], it = It, parse = Parse} = C) ->
    case bitcask_cpp_nifs:cask_range_next_batch(It, ?RANGE_BATCH) of
        done -> {eof, C#cur{done = true}};
        {ok, Entries} ->
            Items = [X || {K, V, _T, _O} <- Entries, X <- [Parse(K, V)], X =/= skip],
            C2 = C#cur{buf = Items, done = length(Entries) < ?RANGE_BATCH},
            cur_peek(C2);
        {error, _} = E -> E;
        Other -> {error, Other}
    end.

%% 取走开头所有 vid = Vid 的条目：{[Item], Cur'} | {error, _}
cur_take(C, Vid) -> cur_take(C, Vid, []).

cur_take(C, Vid, Acc) ->
    case cur_peek(C) of
        {error, _} = E -> E;
        {{Vid, Item}, #cur{buf = [_ | T]} = C1} -> cur_take(C1#cur{buf = T}, Vid, [Item | Acc]);
        {_, C1} -> {lists:reverse(Acc), C1}
    end.
