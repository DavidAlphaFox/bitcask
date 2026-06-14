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
%%           api_key => <<"sk-ant-...">>
%%       }),
%%       {ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>).
%% -------------------------------------------------------------------
-module(bitcask_embedder_anthropic).

-behaviour(bitcask_embedder).

%% Provider behaviour API
-export([init/1, embed/2]).

%% 32K token 上限的字节级保守界。
-define(MAX_INPUT_BYTES, 32768).
-define(HTTP_TIMEOUT_MS, 30000).

%% ===================================================================
%% Provider behaviour: init/1
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) ->
    case {maps:get(url, Opts, undefined), maps:get(model, Opts, undefined)} of
        {undefined, _} -> {error, {missing_opt, url}};
        {_, undefined} -> {error, {missing_opt, model}};
        {Url, Model} ->
            Dim = maps:get(dim, Opts, 4096),
            {ok, #{
                module => ?MODULE,
                dim    => Dim,
                config => #{
                    url     => Url,
                    model   => to_bin(Model),
                    api_key => maps:get(api_key, Opts, undefined)
                }
            }}
    end.

%% ===================================================================
%% Provider behaviour: embed/2
%% ===================================================================

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{url := Url, model := Model} = Cfg, Text) when is_binary(Text) ->
    {ok, _} = application:ensure_all_started(inets),
    Input = truncate_utf8(Text, ?MAX_INPUT_BYTES),
    Body = json_encode(#{<<"model">> => Model, <<"input">> => Input}),
    Headers = build_headers(maps:get(api_key, Cfg, undefined)),
    Req = {Url, Headers, "application/json", iolist_to_binary(Body)},
    HttpOpts = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 5000}],
    case httpc:request(post, Req, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, RespBody}} ->
            parse_embedding(RespBody);
        {ok, {{_, Code, Reason}, _Hdrs, RespBody}} ->
            {error, {http_status, Code, Reason, RespBody}};
        {error, Reason} ->
            {error, {http_error, Reason}}
    end.

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

%% 解析 Anthropic embedding 响应。
%% 预期格式与 OpenAI 兼容：#{<<"data">> := [#{<<"embedding">> := [float()]}]}。
%% 待 Anthropic 公布实际 API 后，按实际格式调整此处。
parse_embedding(RespBody) ->
    try json_decode(RespBody) of
        #{<<"data">> := [#{<<"embedding">> := Floats} | _]} when is_list(Floats) ->
            {ok, << <<X:32/float-little>> || X <- Floats >>};
        Other ->
            {error, {unexpected_response, Other}}
    catch
        _:Reason -> {error, {bad_json, Reason}}
    end.

%% OTP 27+ 内置 json。
json_encode(Term) -> json:encode(Term).
json_decode(Bin)  -> json:decode(Bin).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

%% 字节级保守截断（与 openai provider 一致）。
truncate_utf8(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_utf8(Bin, Max) ->
    strip_partial(binary:part(Bin, 0, Max), 3).

strip_partial(<<>>, _) -> <<>>;
strip_partial(Bin, N) ->
    Sz = byte_size(Bin),
    case binary:at(Bin, Sz - 1) of
        B when B band 16#C0 =:= 16#80, N > 0 ->
            strip_partial(binary:part(Bin, 0, Sz - 1), N - 1);
        B when B >= 16#C0 ->
            binary:part(Bin, 0, Sz - 1);
        _ -> Bin
    end.
