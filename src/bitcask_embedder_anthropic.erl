%% -------------------------------------------------------------------
%% bitcask_embedder_anthropic:
%%   bitcask_embedder 的 provider 实现 — Anthropic 兼容协议。
%%
%%   ⚠️ Anthropic 目前尚未公开 embedding API（Claude 系列为 LLM，
%%   只有 /v1/messages 文本生成端点）。本模块按预期 API 结构写好，
%%   当 Anthropic 上线 embedding 端点时，填入实际 URL 和响应解析即可。
%%
%%   认证风格：x-api-key header + anthropic-version header
%%   （与 Claude /v1/messages 一致，区别于 OpenAI 的 Bearer token）。
%%
%%   用法：
%%       {ok, Ctx} = bitcask_embedder:new(anthropic, #{
%%           url     => "https://api.anthropic.com/v1/embeddings",
%%           model   => <<"claude-embed">>,
%%           dim     => 4096,
%%           api_key => <<"sk-ant-...">>,
%%           max_input_bytes    => 32768,  %% 可选，按模型上下文窗口设；默认 32768
%%           timeout_ms         => 30000,  %% 可选，请求总超时；默认 30000
%%           connect_timeout_ms => 5000    %% 可选，建连超时；默认 5000
%%       }),
%%       {ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>).
%% -------------------------------------------------------------------
-module(bitcask_embedder_anthropic).

-behaviour(bitcask_embedder).

%% Provider behaviour API
-export([init/1, embed/2, embed_batch/2]).

%% 可选项默认值（均为正整数；可在 new/2 的 Opts 里覆盖，缺省用这些）：
%%   max_input_bytes    — embed 前输入的字节级保守上限，约对应 32K token
%%                        （UTF-8 下字节数 ≤ N ⟹ token 数 ≤ N）。
%%   timeout_ms         — 单次 embedding 请求的总超时（毫秒）。
%%   connect_timeout_ms — 建连超时（毫秒）。
-define(DEFAULT_MAX_INPUT_BYTES, 32768).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 5000).
%% 模型原生维度默认值（dim）。MRL 落库维度 vector_dim 缺省 = dim。
-define(DEFAULT_DIM, 4096).

%% ===================================================================
%% Provider behaviour: init/1
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) ->
    case {maps:get(url, Opts, undefined), maps:get(model, Opts, undefined)} of
        {undefined, _} -> {error, {missing_opt, url}};
        {_, undefined} -> {error, {missing_opt, model}};
        {Url, Model} ->
            case bitcask_embedder_util:validate_dims(Opts, ?DEFAULT_DIM) of
                {ok, Dim, VDim} ->
                    case validate_limits(Opts) of
                        {ok, Limits} ->
                            Base = #{
                                url        => Url,
                                model      => to_bin(Model),
                                api_key    => maps:get(api_key, Opts, undefined),
                                dim        => Dim,
                                vector_dim => VDim
                            },
                            {ok, #{
                                module     => ?MODULE,
                                dim        => Dim,
                                vector_dim => VDim,
                                config     => maps:merge(Base, Limits)
                            }};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end
    end.

%% 校验三个正整数可选项，返回 {ok, #{Key => Val}}（缺省填默认值）或
%% {error, {bad_opt, Key}}。
validate_limits(Opts) ->
    bitcask_embedder_util:validate_limits(
      Opts, [{max_input_bytes,    ?DEFAULT_MAX_INPUT_BYTES},
             {timeout_ms,         ?DEFAULT_TIMEOUT_MS},
             {connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT_MS}]).

%% ===================================================================
%% Provider behaviour: embed/2
%% ===================================================================

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{url := _, model := _} = Cfg, Text) when is_binary(Text) ->
    bitcask_embedder_util:http_embed(
      Cfg, Text, build_headers(maps:get(api_key, Cfg, undefined)),
      ?DEFAULT_MAX_INPUT_BYTES).

%% ===================================================================
%% embed_batch/2（bitcask_embedder 的可选回调）—— 一次请求带一个数组
%%
%% ⚠️ 逐条结果，顺序与输入一一对应。响应按 `index` 字段归位，**不按返回顺序
%%    zip** —— 详见 bitcask_embedder_util:parse_embedding_batch/3 的注释：
%%    按顺序 zip 的后果是把向量配到别的文档上，不报错、维度也对。
%%
%% 可选项 max_batch（默认 64）：一次请求最多几条。端点对数组长度与总 token
%% 都有上限，超了是**整个请求**失败，所以按它切块。
%% ===================================================================
-spec embed_batch(map(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(#{url := _, model := _} = Cfg, Texts) when is_list(Texts) ->
    bitcask_embedder_util:http_embed_batch(
      Cfg, Texts, build_headers(maps:get(api_key, Cfg, undefined)),
      ?DEFAULT_MAX_INPUT_BYTES).
%% ===================================================================
%% Internal
%% ===================================================================

%% Anthropic 认证：x-api-key header + anthropic-version header。
%% 区别于 OpenAI 的 Bearer token。
build_headers(undefined) ->
    [{"anthropic-version", "2023-06-01"}];
build_headers(ApiKey) when is_binary(ApiKey) ->
    [{"x-api-key", binary_to_list(ApiKey)},
     {"anthropic-version", "2023-06-01"}];
build_headers(ApiKey) when is_list(ApiKey) ->
    [{"x-api-key", ApiKey},
     {"anthropic-version", "2023-06-01"}].



to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

