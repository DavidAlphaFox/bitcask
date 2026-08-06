%% -------------------------------------------------------------------
%% bitcask_embedder_proxy:
%%   bitcask_embedder 的 provider 实现 —— 把 embed 转给一个
%%   bitcask_embedder_server 进程。
%%
%%   一般不用直接写它：`bitcask:open(Dir, [{embedder, ServerRef}])` 会替你
%%   建这层代理。显式用法：
%%
%%       {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_proxy},
%%                                        #{server => my_embedder}).
%%
%%   === 它在 open 时做的唯一一件事 ===
%%
%%   向 server 问一次 spec：拿到 dim / vector_dim（open 要用它定集合维度）与
%%   默认超时。之后热路径上只有一次 gen_server:call，没有额外的往返。
%%
%%   ⚠️ **维度是 open 时快照的。** server 在运行中被换成另一个模型的话，
%%      已经打开的 cask 仍按旧维度写——但那本来就是不该做的事（换模型 =
%%      落库维度变了 = 全量重建索引）。这里不去追踪它，只是说明边界。
%%
%%   === Opts ===
%%     server  — 必填。pid() | 注册名 | {global,_} | {via,_,_}
%%     timeout — 可选。覆盖 server 自己报的 embed 超时
%% -------------------------------------------------------------------
-module(bitcask_embedder_proxy).

-behaviour(bitcask_embedder).

-export([init/1, embed/2]).
-export([info/1]).

%% ===================================================================
%% Provider behaviour: init/1
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) when is_map(Opts) ->
    case maps:get(server, Opts, undefined) of
        undefined ->
            {error, {missing_opt, server}};
        Ref ->
            case bitcask_embedder_server:spec(Ref) of
                {error, _} = E ->
                    E;
                {ok, #{dim := Dim, vector_dim := VDim} = Spec} ->
                    Timeout = maps:get(timeout, Opts,
                                       maps:get(timeout, Spec, 60000)),
                    Cfg = #{server => Ref, timeout => Timeout},
                    {ok, #{module     => ?MODULE,
                           dim        => Dim,
                           vector_dim => VDim,
                           config     => Cfg}}
            end
    end.

%% ===================================================================
%% Provider behaviour: embed/2
%% ===================================================================

-spec embed(map(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{server := Ref, timeout := T}, Text) ->
    %% server 挂了返回 {error, {embedder_not_running, _}}，不会把调用方带走
    %% ——见 bitcask_embedder_server:call/3。
    bitcask_embedder_server:embed(Ref, Text, T).

%% 透传到 server 的 provider info（llama 是模型参数）。排错用。
-spec info(bitcask_embedder:ctx() | map()) -> {ok, map()} | {error, term()}.
info(#{config := Cfg})    -> info(Cfg);
info(#{server := Ref})    -> bitcask_embedder_server:info(Ref).
