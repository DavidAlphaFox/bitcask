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
-export([init/1, embed/2]).

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
            case validate_dims(Opts, ?DEFAULT_DIM) of
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

%% 校验 dim（原生）与 vector_dim（MRL 落库，缺省 = dim，须正整数且 ≤ dim）。
validate_dims(Opts, DefaultDim) ->
    Dim  = maps:get(dim, Opts, DefaultDim),
    VDim = maps:get(vector_dim, Opts, Dim),
    if
        not (is_integer(Dim) andalso Dim > 0)   -> {error, {bad_opt, dim}};
        not (is_integer(VDim) andalso VDim > 0) -> {error, {bad_opt, vector_dim}};
        VDim > Dim -> {error, {vector_dim_exceeds_dim, VDim, Dim}};
        true -> {ok, Dim, VDim}
    end.

%% 校验三个正整数可选项，返回 {ok, #{Key => Val}}（缺省填默认值）或
%% {error, {bad_opt, Key}}。
validate_limits(Opts) ->
    Specs = [{max_input_bytes,    ?DEFAULT_MAX_INPUT_BYTES},
             {timeout_ms,         ?DEFAULT_TIMEOUT_MS},
             {connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT_MS}],
    lists:foldl(
        fun({Key, Def}, {ok, Acc}) ->
                case maps:get(Key, Opts, Def) of
                    V when is_integer(V), V > 0 -> {ok, Acc#{Key => V}};
                    _ -> {error, {bad_opt, Key}}
                end;
           (_, {error, _} = E) -> E
        end, {ok, #{}}, Specs).

%% ===================================================================
%% Provider behaviour: embed/2
%% ===================================================================

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{url := Url, model := Model} = Cfg, Text) when is_binary(Text) ->
    {ok, _} = application:ensure_all_started(inets),
    MaxIn = maps:get(max_input_bytes, Cfg, ?DEFAULT_MAX_INPUT_BYTES),
    Input = truncate_utf8(Text, MaxIn),
    Dim  = maps:get(dim, Cfg, undefined),
    VDim = maps:get(vector_dim, Cfg, Dim),
    Body0 = #{<<"model">> => Model, <<"input">> => Input},
    Body1 = case is_integer(VDim) andalso VDim =/= Dim of
                true  -> Body0#{<<"dimensions">> => VDim};
                false -> Body0
            end,
    Headers = build_headers(maps:get(api_key, Cfg, undefined)),
    Req = {Url, Headers, "application/json", iolist_to_binary(json_encode(Body1))},
    HttpOpts = [{timeout, maps:get(timeout_ms, Cfg, ?DEFAULT_TIMEOUT_MS)},
                {connect_timeout, maps:get(connect_timeout_ms, Cfg, ?DEFAULT_CONNECT_TIMEOUT_MS)}],
    case httpc:request(post, Req, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, RespBody}} ->
            parse_embedding(RespBody, VDim);
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
parse_embedding(RespBody, Expect) ->
    try json_decode(RespBody) of
        #{<<"data">> := [#{<<"embedding">> := Floats} | _]} when is_list(Floats) ->
            Got = length(Floats),
            case Expect =:= undefined orelse Got =:= Expect of
                true  -> {ok, << <<X:32/float-little>> || X <- Floats >>};
                false -> {error, {dim_mismatch, Got, Expect}}
            end;
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
