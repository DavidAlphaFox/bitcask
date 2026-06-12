%% -------------------------------------------------------------------
%% bitcask_embedder_mock:
%%   V3.6 eunit 用确定性 mock embedder —— 门禁测试**不打真实端点**。
%%   固定向量表（与 C++ V36HybridRrfFusion 同语料，两路排名已知，便于
%%   手算 RRF 真值）+ phash2 哈希兜底（任意文本 → 确定性向量）。
%%   dim = 4；输出 f32 LE 二进制，与 NIF 跨界格式一致。
%% -------------------------------------------------------------------
-module(bitcask_embedder_mock).

-behaviour(bitcask_embedder).

-export([embed/1, dim/0, vec_bin/1]).

dim() -> 4.

%% 固定表：语料文本 / 查询文本 → 已知向量（cosine 归一化由引擎写入侧做，
%% 此处给的已是单位向量，幂等）。
embed(<<"x x x">>) -> {ok, vec_bin([0.6, 0.8, 0.0, 0.0])};
embed(<<"x x y">>) -> {ok, vec_bin([0.8, 0.6, 0.0, 0.0])};
embed(<<"x y y">>) -> {ok, vec_bin([1.0, 0.0, 0.0, 0.0])};
embed(<<"z z z">>) -> {ok, vec_bin([0.0, 0.0, 0.0, 1.0])};
embed(<<"x">>)     -> {ok, vec_bin([1.0, 0.0, 0.0, 0.0])};
%% 兜底：哈希 → 确定性非零向量（分量 ∈ [1, 256]，恒非零，cosine 下合法）。
embed(Text) when is_binary(Text) ->
    Comps = [float((erlang:phash2({Text, I}, 256)) + 1) || I <- lists:seq(1, 4)],
    {ok, vec_bin(Comps)}.

%% f32 LE 二进制构造（跨界格式锚点，测试也直接用）。
vec_bin(Floats) ->
    << <<X:32/float-little>> || X <- Floats >>.
