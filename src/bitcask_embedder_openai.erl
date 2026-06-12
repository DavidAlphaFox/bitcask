%% -------------------------------------------------------------------
%% bitcask_embedder_openai:
%%   bitcask_embedder 的参考实现 — OpenAI 兼容 /v1/embeddings 协议
%%   （名字示意协议形态，任何兼容端点均可，如 llama.cpp server / vLLM）。
%%
%%   配置（application env）：
%%     {bitcask, embedder_url}    — 端点完整 URL，string()
%%                                  例 "http://192.168.186.1:8080/v1/embeddings"
%%     {bitcask, embedder_model}  — 模型名，binary()，例 <<"qwen3-embedding">>
%%     {bitcask, embedder_dim}    — 可选，维度声明（默认 2560，
%%                                  即部署目标 qwen3-embedding 的输出维度）
%%
%%   JSON：用 OTP 27+ 内置 json 模块（仓库本机 OTP 28，erl -version 实证）。
%%   更老 OTP 上本模块可以编译（对 json 模块的调用是运行期解析），但
%%   embed/1 会在调用时 undef —— 网络路径不进 eunit 门禁，属于可接受的
%%   显式降级；需要支持旧 OTP 的部署自行替换 json_encode/json_decode。
%%
%%   输入截断：端点输入上限 32K token。此处做**字节级保守截断**（粗糙但
%%   安全：UTF-8 下 1 token ≥ 1 字节，截到 32768 字节必 ≤ 32K token），
%%   并回退尾部 UTF-8 续延字节避免截出非法编码（json:encode 会拒收）。
%%   按 token 精确截断需要分词器，不属于本层职责。
%%
%%   eunit 不打真实端点：门禁测试用 mock embedder；本模块的网络路径仅由
%%   test/bitcask_vector_tests.erl 里默认 skip 的手动用例覆盖
%%   （BITCASK_EMBEDDER_LIVE=1 开启）。
%% -------------------------------------------------------------------
-module(bitcask_embedder_openai).

-behaviour(bitcask_embedder).

-export([embed/1, embed/3, dim/0]).

%% 32K token 上限的字节级保守界（注释见模块头）。
-define(MAX_INPUT_BYTES, 32768).
-define(HTTP_TIMEOUT_MS, 30000).

%% behaviour 入口：从 application env 取端点配置。
-spec embed(binary()) -> {ok, binary()} | {error, term()}.
embed(Text) when is_binary(Text) ->
    case {application:get_env(bitcask, embedder_url),
          application:get_env(bitcask, embedder_model)} of
        {{ok, Url}, {ok, Model}} -> embed(Url, Model, Text);
        _ -> {error, embedder_not_configured}
    end.

%% 显式传配置的变体（测试/多端点场景）。
-spec embed(string(), binary(), binary()) -> {ok, binary()} | {error, term()}.
embed(Url, Model, Text) when is_binary(Text) ->
    {ok, _} = application:ensure_all_started(inets),
    Input = truncate_utf8(Text, ?MAX_INPUT_BYTES),
    Body = json_encode(#{<<"model">> => to_bin(Model), <<"input">> => Input}),
    Req = {Url, [], "application/json", iolist_to_binary(Body)},
    HttpOpts = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 5000}],
    case httpc:request(post, Req, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, RespBody}} ->
            parse_embedding(RespBody);
        {ok, {{_, Code, Reason}, _Hdrs, RespBody}} ->
            {error, {http_status, Code, Reason, RespBody}};
        {error, Reason} ->
            {error, {http_error, Reason}}
    end.

%% 维度声明：env 可覆盖；默认 2560（qwen3-embedding 部署目标实测）。
-spec dim() -> pos_integer().
dim() ->
    case application:get_env(bitcask, embedder_dim) of
        {ok, D} when is_integer(D), D > 0 -> D;
        _ -> 2560
    end.

%% =========================================================================
%% 内部
%% =========================================================================

%% 解析 OpenAI 兼容响应：#{<<"data">> := [#{<<"embedding">> := [float()]}]}。
%% 输出端点已 L2 归一化（实测 norm=1.0）；引擎写入侧归一化对其幂等。
parse_embedding(RespBody) ->
    try json_decode(RespBody) of
        #{<<"data">> := [#{<<"embedding">> := Floats} | _]} when is_list(Floats) ->
            {ok, << <<X:32/float-little>> || X <- Floats >>};
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

%% 字节级保守截断 + 回退 UTF-8 续延字节（10xxxxxx），保证截断结果仍是
%% 合法 UTF-8 前缀。最多回退 3 字节（UTF-8 码点 ≤ 4 字节）。
truncate_utf8(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_utf8(Bin, Max) ->
    strip_partial(binary:part(Bin, 0, Max), 3).

%% 从尾部剥掉未截全的码点:至多 3 个续延字节(10xxxxxx)+ 1 个落单
%% 首字节(11xxxxxx)。合法 UTF-8 不会出现 >3 个连续续延字节,故 N=3 足够;
%% 输入本身非法 UTF-8 不在本层契约内(json:encode 会拒收)。
strip_partial(<<>>, _) -> <<>>;
strip_partial(Bin, N) ->
    Sz = byte_size(Bin),
    case binary:at(Bin, Sz - 1) of
        B when B band 16#C0 =:= 16#80, N > 0 ->   %% 续延字节,继续回退
            strip_partial(binary:part(Bin, 0, Sz - 1), N - 1);
        B when B >= 16#C0 ->                      %% 多字节首字节落单,丢弃
            binary:part(Bin, 0, Sz - 1);
        _ -> Bin                                  %% ASCII / 完整码点收尾
    end.
