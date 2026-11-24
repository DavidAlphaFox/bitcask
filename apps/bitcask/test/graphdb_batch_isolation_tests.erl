%% -------------------------------------------------------------------
%% graphdb_batch_isolation_tests:
%%   上游 libbitcask ≤ 12.0.0 的原子批对并发读者不是整批可见：批内各 key 逐条
%%   生效，且按 key 字节序（头 key 是自己块 key 的前缀 ⇒ 同一顶点头先生效、块后
%%   生效）。读者可能读到「新头 + 旧块 / 缺块」（上游反馈 libbitcask
%%   feedbacks/2026-11-20-atomic-batch-no-read-isolation.md；12.0.1 / S63 已修）。
%%
%%   这种交错在压测里极难撞上（窗口在两条 apply 之间），这里用确定性的方式造：
%%   写会话 / 读集先读，再用裸 bitcask:put / delete 改它读过的块——等价于「读者
%%   读到半个批，随后那个批的剩余部分生效」。12.0.1 之后引擎自己的批不会再这样
%%   交错，但绕过图层协议直写块仍能造成同一版本迁移。修复前写会话只对头设条件，
%%   这些提交全都会成功（覆盖别人的块 / 把刚建好的块写空）；修复后必须冲突重来。
%% -------------------------------------------------------------------
-module(graphdb_batch_isolation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OPTS, [read_write, {adj_inline_max, 256}, {adj_chunk_max, 256}]).
-define(BASE, lists:seq(1000, 1399)).

with_dir(Fun) -> bitcask_test_util:with_dir("graphdb_isolation_", Fun).

%% hub 1 → 1000..1399（etype 7），出边组分块。
open_hub(D) ->
    R = graphdb:open(D, ?OPTS),
    ok = graphdb:put_edges(R, [{1, 7, Y} || Y <- ?BASE]),
    ?assert(length(chunk_keys(R, 1)) > 1),
    R.

%% 顶点 Vid 出边 etype 7 的块 key，按 key 序（= 下界序）。
chunk_keys(R, Vid) ->
    [K || {K, _} <- bitcask:range(R, graphdb_adj:range(<<"a">>)),
          {ok, V, 0, 7, _Lb} <- [graphdb_adj:parse_chunk_key(K)], V =:= Vid].

last_chunk(R, Vid) -> lists:last(chunk_keys(R, Vid)).

raw(R, K) ->
    case bitcask:get(R, K) of
        {ok, #{text := T}} -> T;
        {ok, B}            -> B
    end.

session(R) -> graphdb_adj:new_session({direct, R}, graphdb:graph_config(R)).

out_dsts(R, Vid) ->
    {ok, Es} = graphdb:out_edges(R, Vid),
    [Y || #{dst := Y} <- Es].

%% 写会话读到旧块，之后块被改（同一批的块晚于头生效）：提交必须冲突。
stale_chunk_read_conflicts_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hub(D),
            {ok, S} = graphdb_adj:put_edge(session(R), 1, 7, 5000, 0, <<>>),
            Ck = last_chunk(R, 1),                       % 5000 落在最后一块
            ok = bitcask:put(R, Ck, raw(R, Ck)),         % 块的版本变了（内容不变）
            ?assertEqual(conflict, graphdb_adj:commit(S)),
            %% 正常路径重来即可
            ok = graphdb:put_edge(R, 1, 7, 5000),
            ?assertEqual(?BASE ++ [5000], out_dsts(R, 1)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

%% 写会话读到「目录有、盘上缺」的块（新头已生效、新块还没生效），之后块落盘：
%% 修复前自愈会把这个块写成只剩新条目（整块的边丢失）；修复后 absent 条件冲突。
missing_chunk_mid_batch_conflicts_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hub(D),
            Ck = last_chunk(R, 1),
            Bytes = raw(R, Ck),
            ok = bitcask:delete(R, Ck),                  % 模拟批的块尚未生效
            {ok, S} = graphdb_adj:put_edge(session(R), 1, 7, 5000, 0, <<>>),
            ok = bitcask:put(R, Ck, Bytes),              % 批的剩余部分生效
            ?assertEqual(conflict, graphdb_adj:commit(S)),
            ?assertEqual(?BASE, out_dsts(R, 1)),         % 一条没丢
            ok = graphdb:put_edge(R, 1, 7, 5000),
            ?assertEqual(?BASE ++ [5000], out_dsts(R, 1)),
            ?assertMatch({ok, _}, graphdb:check_invariants(R)),
            graphdb:close(R)
        end)
    end}.

%% 会话读过但没改的顶点也参与校验：1→1000 已存在（只读、不写），同一会话再改 2、3；
%% 顶点 1 读过的块随后变了 ⇒ 整个提交冲突。
read_only_vertex_guarded_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hub(D),
            {ok, S1} = graphdb_adj:put_edge(session(R), 1, 7, 1000, 0, <<>>),
            {ok, S2} = graphdb_adj:put_edge(S1, 2, 7, 3, 0, <<>>),
            [Ck0 | _] = chunk_keys(R, 1),                % 1000 在块 0
            ok = bitcask:put(R, Ck0, raw(R, Ck0)),
            ?assertEqual(conflict, graphdb_adj:commit(S2)),
            ?assertEqual([], out_dsts(R, 2)),
            %% 没人改它时照常提交
            {ok, S3} = graphdb_adj:put_edge(session(R), 1, 7, 1000, 0, <<>>),
            {ok, S4} = graphdb_adj:put_edge(S3, 2, 7, 3, 0, <<>>),
            ?assertEqual(ok, graphdb_adj:commit(S4)),
            ?assertEqual([3], out_dsts(R, 2)),
            %% 什么都不写的会话不提交批
            {ok, S5} = graphdb_adj:put_edge(session(R), 1, 7, 1000, 0, <<>>),
            ?assertEqual(ok, graphdb_adj:commit(S5)),
            graphdb:close(R)
        end)
    end}.

%% 一致性读：读集（头 + 读过的块）在写锁下校验；块在读之后变了 ⇒ 校验不过。
consistent_read_validates_chunks_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hub(D),
            {ok, Es, Checks} = graphdb_adj:entries_guarded({direct, R}, 1, 0, 7, infinity),
            ?assertEqual(length(?BASE), length(Es)),
            ?assertEqual(1 + length(chunk_keys(R, 1)), length(Checks)),
            ?assertEqual(ok, bitcask:put_batch_atomic(R, Checks)),   % 只校验、不写
            Ck = last_chunk(R, 1),
            ok = bitcask:put(R, Ck, raw(R, Ck)),
            ?assertMatch({error, {conflict, _}}, bitcask:put_batch_atomic(R, Checks)),
            %% limit：只读到够数的块，读集也只含这些块
            {ok, Es5, Checks5} = graphdb_adj:entries_guarded({direct, R}, 1, 0, 7, 5),
            ?assertEqual(5, length(Es5)),
            ?assertEqual(2, length(Checks5)),
            %% 门面
            {ok, All} = graphdb:out_edges(R, 1, #{consistent => true}),
            ?assertEqual(?BASE, [Y || #{dst := Y} <- All]),
            {ok, Five} = graphdb:out_edges(R, 1, #{consistent => true, limit => 5}),
            ?assertEqual(lists:sublist(?BASE, 5), [Y || #{dst := Y} <- Five]),
            %% 未分块 / 不存在的顶点
            ok = graphdb:put_edge(R, 9, 7, 10),
            ?assertMatch({ok, [#{dst := 10}]}, graphdb:out_edges(R, 9, #{consistent => true})),
            ?assertEqual({ok, []}, graphdb:out_edges(R, 404, #{consistent => true})),
            graphdb:close(R),
            %% 只读句柄：不做写锁校验，照常返回
            R2 = graphdb:open(D, []),
            {ok, All2} = graphdb:out_edges(R2, 1, #{consistent => true}),
            ?assertEqual(?BASE, [Y || #{dst := Y} <- All2]),
            graphdb:close(R2)
        end)
    end}.
