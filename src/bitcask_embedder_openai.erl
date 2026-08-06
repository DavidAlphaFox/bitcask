%% -------------------------------------------------------------------
%% bitcask_embedder_openai:
%%   bitcask_embedder 的 provider 实现 — OpenAI 兼容 /v1/embeddings 协议
%%   （名字示意协议形态，任何兼容端点均可，如 llama.cpp server / vLLM）。
%%
%%   新 API（推荐）：
%%     bitcask_embedder:new(openai, #{
%%         url => "http://...", model => <<"qwen3-embedding">>, dim => 2560,
%%         max_input_bytes    => 32768,  %% 可选，按模型上下文窗口设；默认 32768
%%         timeout_ms         => 30000,  %% 可选，请求总超时；默认 30000
%%         connect_timeout_ms => 5000    %% 可选，建连超时；默认 5000
%%     })
%%
%%   可选项（均为正整数，缺省用默认值；非正整数 → {error,{bad_opt,Key}}）：
%%     max_batch（默认 64）— embed_batch 一次请求最多几条（端点对数组长度与
%%       总 token 都有上限，超了是整个请求失败）。
%%     max_input_bytes（默认 32768）— embed 前对输入做字节级保守截断的上限。
%%       模型上下文有 token 上限，超长输入端点会报错/截断；这里在客户端先按
%%       字节裁剩（UTF-8 下字节数 ≤ N ⟹ token 数 ≤ N，保守安全）。
%%     timeout_ms（默认 30000）— 单次 embedding 请求的总超时（毫秒）。
%%     connect_timeout_ms（默认 5000）— 建连超时（毫秒）。
%%   旧 API（deprecated，保留向后兼容）：
%%     embed/1 — 从 application env 取配置
%%     embed/3 — 显式传 Url/Model/Text
%%
%%   JSON：用 OTP 27+ 内置 json 模块（仓库本机 OTP 28，erl -version 实证）。
%%
%%   输入截断：端点输入上限 32K token。此处做字节级保守截断（粗糙但
%%   安全：UTF-8 下 1 token ≥ 1 字节，截到 32768 字节必 ≤ 32K token），
%%   并回退尾部 UTF-8 续延字节避免截出非法编码。
%% -------------------------------------------------------------------
-module(bitcask_embedder_openai).

-behaviour(bitcask_embedder).

%% New context-based API
-export([init/1, embed/2, embed_batch/2]).

%% Legacy API (deprecated — use bitcask_embedder:new/2 + embed/2 + dim/1)
-export([embed/1, embed/3, dim/0]).

%% 可选项默认值（均为正整数；可在 new/2 的 Opts 里覆盖，缺省用这些）：
%%   max_input_bytes    — embed 前输入的字节级保守上限，约对应 32K token 的
%%                        上下文窗口（UTF-8 下字节数 ≤ N ⟹ token 数 ≤ N）。
%%   timeout_ms         — 单次 embedding 请求的总超时（毫秒）。
%%   connect_timeout_ms — 建连超时（毫秒）。
-define(DEFAULT_MAX_INPUT_BYTES, 32768).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 5000).
%% 模型原生维度默认值（dim）。MRL 落库维度 vector_dim 缺省 = dim。
-define(DEFAULT_DIM, 2560).

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
                                dim        => Dim,    %% 供 embed 决定是否发 dimensions
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
%% {error, {bad_opt, Key}}。供 init 把校验过的上限并入 config。
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
%% Legacy API (deprecated)
%% ===================================================================

%% @deprecated Use bitcask_embedder:new(openai, Opts) + bitcask_embedder:embed/2.
-spec embed(binary()) -> {ok, binary()} | {error, term()}.
embed(Text) when is_binary(Text) ->
    case {application:get_env(bitcask, embedder_url),
          application:get_env(bitcask, embedder_model)} of
        {{ok, Url}, {ok, Model}} -> embed(#{url => Url, model => to_bin(Model)}, Text);
        _ -> {error, embedder_not_configured}
    end.

%% @deprecated Use bitcask_embedder:new/2 + bitcask_embedder:embed/2.
-spec embed(string(), binary(), binary()) -> {ok, binary()} | {error, term()}.
embed(Url, Model, Text) when is_binary(Text) ->
    embed(#{url => Url, model => to_bin(Model)}, Text).

%% @deprecated Use bitcask_embedder:dim/1.
-spec dim() -> pos_integer().
dim() ->
    case application:get_env(bitcask, embedder_dim) of
        {ok, D} when is_integer(D), D > 0 -> D;
        _ -> 2560
    end.

%% ===================================================================
%% Internal
%% ===================================================================

%% OpenAI 兼容端点使用 Bearer token 认证。
build_headers(undefined) -> [];
build_headers(ApiKey) when is_binary(ApiKey) ->
    [{"Authorization", "Bearer " ++ binary_to_list(ApiKey)}];
build_headers(ApiKey) when is_list(ApiKey) ->
    [{"Authorization", "Bearer " ++ ApiKey}].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

