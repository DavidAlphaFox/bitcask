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

%% 模型原生维度默认值（dim）。MRL 落库维度 vector_dim 缺省 = dim。
%% 其余可选项的默认值与校验见 bitcask_embedder_util:http_init/4（与 openai
%% 共用；本模块只剩默认维度与认证 header 两处差异）。
-define(DEFAULT_DIM, 4096).

%% ===================================================================
%% Provider behaviour: init/1 / embed/2 / embed_batch/2
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) ->
    bitcask_embedder_util:http_init(?MODULE, Opts, ?DEFAULT_DIM, fun build_headers/1).

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{url := _, model := _} = Cfg, Text) when is_binary(Text) ->
    bitcask_embedder_util:http_embed(Cfg, Text).

-spec embed_batch(map(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(#{url := _, model := _} = Cfg, Texts) when is_list(Texts) ->
    bitcask_embedder_util:http_embed_batch(Cfg, Texts).

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


