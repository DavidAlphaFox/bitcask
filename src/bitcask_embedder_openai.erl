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
-export([init/1, embed/2]).

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
            case validate_dims(Opts, ?DEFAULT_DIM) of
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

%% 校验 dim（模型原生维度）与 vector_dim（MRL 落库维度）。vector_dim 缺省 = dim，
%% 必须为正整数且 ≤ dim（MRL 只能截短，不能扩展）。
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
%% {error, {bad_opt, Key}}。供 init 把校验过的上限并入 config。
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
    %% MRL：vector_dim ≠ dim 时发 dimensions，让服务端按 MRL 截断+重归一。
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

%% 解析 OpenAI 兼容响应：#{<<"data">> := [#{<<"embedding">> := [float()]}]}。
%% Expect = 期望维度（vector_dim）；返回长度不符 → {error,{dim_mismatch,Got,Expect}}
%% （服务端不支持 dimensions、忽略了 MRL 截断时在此暴露，而非静默写错维度）。
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

%% OTP 27+ 内置 json。包一层便于旧 OTP 部署替换实现。
json_encode(Term) -> json:encode(Term).
json_decode(Bin)  -> json:decode(Bin).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

%% 字节级保守截断 + 回退 UTF-8 续延字节，保证截断结果仍是合法 UTF-8 前缀。
truncate_utf8(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_utf8(Bin, Max) ->
    strip_partial(binary:part(Bin, 0, Max), 3).

%% 从尾部剥掉未截全的码点:至多 3 个续延字节(10xxxxxx)+ 1 个落单
%% 首字节(11xxxxxx)。
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
