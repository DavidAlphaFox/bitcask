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
