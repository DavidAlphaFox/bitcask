%% -------------------------------------------------------------------
%% bitcask_embedder_util_tests:
%%   HTTP 档的响应解析 —— **纯函数，不打网络**。
%%
%%   ⚠️ 这套测试存在的理由：HTTP provider 的解析路径此前**只有一个默认跳过的
%%      手动用例**（bitcask_vector_tests 的 openai_live_test_，要真实端点）。
%%      也就是说解析逻辑基本没测过，而批量解析里有一个会**静默配错向量**的坑
%%      （见 batch_respects_index_order_test）。把解析做成纯函数导出，就能不
%%      依赖端点地钉住它。
%% -------------------------------------------------------------------
-module(bitcask_embedder_util_tests).

-include_lib("eunit/include/eunit.hrl").

-define(U, bitcask_embedder_util).

vec(Fs) -> ?U:vec_bin(Fs).

body(Items) -> iolist_to_binary(json:encode(#{<<"data">> => Items})).

item(Idx, Fs) -> #{<<"index">> => Idx, <<"embedding">> => Fs}.

%% ===================================================================
%% 单条
%% ===================================================================

parse_single_test() ->
    B = body([#{<<"embedding">> => [1.0, 0.0, 0.0, 0.0]}]),
    ?assertEqual({ok, vec([1.0, 0.0, 0.0, 0.0])}, ?U:parse_embedding(B, 4)),
    %% Expect=undefined 时不校验维度
    ?assertEqual({ok, vec([1.0, 0.0, 0.0, 0.0])}, ?U:parse_embedding(B, undefined)).

%% ⚠️ 维度不符必须报错，不能静默写进库：服务端不支持 dimensions、忽略了 MRL
%%    截断时就是这条把它暴露出来的。
parse_single_dim_mismatch_test() ->
    B = body([#{<<"embedding">> => [1.0, 0.0, 0.0]}]),
    ?assertEqual({error, {dim_mismatch, 3, 4}}, ?U:parse_embedding(B, 4)).

parse_single_bad_shape_test() ->
    ?assertMatch({error, {unexpected_response, _}},
                 ?U:parse_embedding(iolist_to_binary(json:encode(#{<<"oops">> => 1})), 4)),
    ?assertMatch({error, {bad_json, _}}, ?U:parse_embedding(<<"not json">>, 4)).

%% ===================================================================
%% 批量
%% ===================================================================

parse_batch_in_order_test() ->
    B = body([item(0, [1.0,0.0,0.0,0.0]), item(1, [0.0,1.0,0.0,0.0])]),
    ?assertEqual({ok, [{ok, vec([1.0,0.0,0.0,0.0])},
                       {ok, vec([0.0,1.0,0.0,0.0])}]},
                 ?U:parse_embedding_batch(B, 4, 2)).

%% ⚠️ **本文件里最重要的一条。**
%%
%% OpenAI 兼容响应的每个对象都带 `index`，而"data 与 input 同序"只是常见实现
%% 的行为、不是协议保证（vLLM / TEI / llama.cpp server 各家不同，并发实现尤其
%% 容易乱序）。按返回顺序 zip 的后果是**把向量配到别的文档上**——不报错、维度
%% 也对，只是检索结果从此不对，而且查不出来。
%%
%% 这里故意让端点乱序返回，结果必须按 index 归位。
batch_respects_index_order_test() ->
    B = body([item(2, [0.0,0.0,1.0,0.0]),
              item(0, [1.0,0.0,0.0,0.0]),
              item(1, [0.0,1.0,0.0,0.0])]),
    ?assertEqual({ok, [{ok, vec([1.0,0.0,0.0,0.0])},
                       {ok, vec([0.0,1.0,0.0,0.0])},
                       {ok, vec([0.0,0.0,1.0,0.0])}]},
                 ?U:parse_embedding_batch(B, 4, 3)).

%% index 不是 0..N-1 的排列 → 宁可整批报错，也不要猜一个映射。
%% ⚠️ 猜错就是静默配错向量，比报错危险得多。
batch_bad_index_set_test() ->
    B = body([item(0, [1.0,0.0,0.0,0.0]), item(0, [0.0,1.0,0.0,0.0])]),
    ?assertMatch({error, {bad_index_set, _}}, ?U:parse_embedding_batch(B, 4, 2)),
    B2 = body([item(1, [1.0,0.0,0.0,0.0]), item(2, [0.0,1.0,0.0,0.0])]),
    ?assertMatch({error, {bad_index_set, _}}, ?U:parse_embedding_batch(B2, 4, 2)).

%% 端点不给 index（有实现省略）→ 退回按位置对应，但条数必须严格相等。
batch_without_index_falls_back_to_position_test() ->
    B = body([#{<<"embedding">> => [1.0,0.0,0.0,0.0]},
              #{<<"embedding">> => [0.0,1.0,0.0,0.0]}]),
    ?assertEqual({ok, [{ok, vec([1.0,0.0,0.0,0.0])},
                       {ok, vec([0.0,1.0,0.0,0.0])}]},
                 ?U:parse_embedding_batch(B, 4, 2)).

%% 条数对不上 → 整批报错。少一条时按位置对应会把后面全体错位。
batch_size_mismatch_test() ->
    B = body([item(0, [1.0,0.0,0.0,0.0])]),
    ?assertEqual({error, {batch_size_mismatch, 1, 2}},
                 ?U:parse_embedding_batch(B, 4, 2)).

%% 逐条维度校验：一条维度不对只影响那一条。
batch_per_item_dim_mismatch_test() ->
    B = body([item(0, [1.0,0.0,0.0,0.0]), item(1, [1.0,0.0,0.0])]),
    ?assertEqual({ok, [{ok, vec([1.0,0.0,0.0,0.0])},
                       {error, {dim_mismatch, 3, 4}}]},
                 ?U:parse_embedding_batch(B, 4, 2)).

batch_bad_shape_test() ->
    ?assertMatch({error, {unexpected_response, _}},
                 ?U:parse_embedding_batch(iolist_to_binary(json:encode(#{})), 4, 1)),
    ?assertMatch({error, {bad_json, _}}, ?U:parse_embedding_batch(<<"nope">>, 4, 1)).

%% ===================================================================
%% 其它共享逻辑（此前也只被间接覆盖）
%% ===================================================================

truncate_utf8_test() ->
    ?assertEqual(<<"abc">>, ?U:truncate_utf8(<<"abc">>, 10)),
    ?assertEqual(<<"ab">>,  ?U:truncate_utf8(<<"abcdef">>, 2)),
    %% ⚠️ 不能截出半个码点：3 字节的"中"截到 2 字节要整个回退。
    ?assertEqual(<<>>, ?U:truncate_utf8(<<"中"/utf8>>, 2)),
    ?assertEqual(<<"中"/utf8>>, ?U:truncate_utf8(<<"中文"/utf8>>, 4)).

mrl_truncate_renormalizes_test() ->
    V = ?U:vec_bin([0.6, 0.8, 0.0, 0.0]),          %% 已是单位向量
    T = ?U:mrl_truncate(V, 2, true),
    ?assertEqual(2 * 4, byte_size(T)),
    %% ⚠️ 截断后必须重新归一：不归一的话模长 < 1 且每条不一样，点积当余弦用
    %%    比较的就不再是夹角。
    Sum = lists:sum([F * F || F <- ?U:floats(T)]),
    ?assert(abs(Sum - 1.0) < 1.0e-6),
    %% 明确说了不归一就别替它做主
    T2 = ?U:mrl_truncate(V, 2, false),
    ?assertEqual(?U:vec_bin([0.6, 0.8]), T2).

l2_normalize_zero_vector_test() ->
    Z = ?U:vec_bin([0.0, 0.0, 0.0]),
    %% 零向量归一会得到 NaN，而 NaN 在余弦里不报错、只是让这一条永远排不上来。
    %% 原样返回，让上层看到一个可辨认的零向量。
    ?assertEqual(Z, ?U:l2_normalize(Z)).

validate_dims_test() ->
    ?assertEqual({ok, 100, 100}, ?U:validate_dims(#{}, 100)),
    ?assertEqual({ok, 100, 50},  ?U:validate_dims(#{vector_dim => 50}, 100)),
    ?assertEqual({error, {vector_dim_exceeds_dim, 200, 100}},
                 ?U:validate_dims(#{vector_dim => 200}, 100)),
    ?assertEqual({error, {bad_opt, dim}}, ?U:validate_dims(#{dim => 0}, 100)).

%% ===================================================================
%% 6.7.0：批量请求的并发骨架 run_chunks/4、切块 chunks/2、init 的上限校验
%% ===================================================================

%% 5 块、并发上限 2：同时在飞的从不超过 2，结果按块序返回。
run_chunks_bounded_and_ordered_test() ->
    Cnt = counters:new(2, [atomics]),          %% 1 = 当前在飞, 2 = 峰值
    Fun = fun(I) ->
                  Now = counters:add(Cnt, 1, 1),
                  _ = Now,
                  Cur = counters:get(Cnt, 1),
                  bump_max(Cnt, Cur),
                  timer:sleep(60),
                  counters:sub(Cnt, 1, 1),
                  I * 10
          end,
    T0 = erlang:monotonic_time(millisecond),
    Res = ?U:run_chunks([1, 2, 3, 4, 5], 2, 10000, Fun),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertEqual([{ok, 10}, {ok, 20}, {ok, 30}, {ok, 40}, {ok, 50}], Res),
    ?assert(counters:get(Cnt, 2) =< 2),
    ?assert(counters:get(Cnt, 2) >= 2),        %% 确实并发了，不是串行
    ?assert(Elapsed >= 3 * 60),                %% 3 轮
    ?assert(Elapsed < 5 * 60),                 %% 而不是 5 轮串行
    ?assertEqual({messages, []}, process_info(self(), messages)).

bump_max(Cnt, Cur) ->
    case counters:get(Cnt, 2) of
        M when M >= Cur -> ok;
        _ -> counters:put(Cnt, 2, Cur)
    end.

%% 一块崩了只影响那一块；其它块照常。
run_chunks_crash_isolated_test() ->
    Fun = fun(2) -> exit(boom); (I) -> I end,
    ?assertEqual([{ok, 1}, {error, {chunk_crashed, boom}}, {ok, 3}],
                 ?U:run_chunks([1, 2, 3], 4, 10000, Fun)).

%% 总 deadline 到：在飞的杀掉、没发的不发，都记 chunk_timeout；不留孤儿进程、
%% 不留迟到消息。
run_chunks_deadline_kills_stragglers_test() ->
    Parent = self(),
    Fun = fun(I) -> Parent ! {worker, self(), I}, timer:sleep(5000), I end,
    Res = ?U:run_chunks([1, 2, 3], 2, 100, Fun),
    ?assertEqual([{error, {chunk_timeout, 100}}, {error, {chunk_timeout, 100}},
                  {error, {chunk_timeout, 100}}], Res),
    Pids = [P || {worker, P, _} <- drain()],
    ?assertEqual(2, length(Pids)),             %% 第 3 块从未发出
    timer:sleep(20),
    ?assertEqual([], [P || P <- Pids, is_process_alive(P)]).

drain() ->
    receive M -> [M | drain()] after 0 -> [] end.

chunks_test() ->
    ?assertEqual([], ?U:chunks([], 10)),
    ?assertEqual([[1, 2, 3]], ?U:chunks([1, 2, 3], 10)),
    ?assertEqual([10, 10, 5], [length(C) || C <- ?U:chunks(lists:seq(1, 25), 10)]),
    ?assertEqual(lists:seq(1, 25), lists:append(?U:chunks(lists:seq(1, 25), 10))).

%% max_batch 以前文档写了却没进 config（util 永远用 64）；0 会让切块死循环，
%% init 必须拒绝。headers 在 init 时拼好一次进 config。
http_init_limits_test() ->
    Base = #{url => "http://127.0.0.1:1/v1/embeddings", model => "m", api_key => <<"k">>},
    {ok, #{config := Cfg}} = bitcask_embedder_openai:init(Base#{max_batch => 10, max_inflight => 2}),
    ?assertMatch(#{max_batch := 10, max_inflight := 2, max_input_bytes := 32768,
                   timeout_ms := 30000, connect_timeout_ms := 5000,
                   headers := [{"Authorization", "Bearer k"}], model := <<"m">>}, Cfg),
    {ok, #{config := Cfg2}} = bitcask_embedder_openai:init(Base),
    ?assertMatch(#{max_batch := 64, max_inflight := 4}, Cfg2),
    ?assertEqual({error, {bad_opt, max_batch}}, bitcask_embedder_openai:init(Base#{max_batch => 0})),
    ?assertEqual({error, {bad_opt, max_inflight}}, bitcask_embedder_openai:init(Base#{max_inflight => 0})),
    ?assertEqual({error, {bad_opt, max_batch}}, bitcask_embedder_anthropic:init(Base#{max_batch => -1})),
    {ok, #{config := Cfg3}} = bitcask_embedder_anthropic:init(Base),
    ?assertMatch(#{headers := [{"x-api-key", "k"}, {"anthropic-version", _}]}, Cfg3),
    %% 专用 httpc profile 起来了，且重复 init 幂等
    ?assert(is_pid(whereis(httpc_bitcask_embedder))),
    ?assertEqual(ok, ?U:ensure_httpc()).
