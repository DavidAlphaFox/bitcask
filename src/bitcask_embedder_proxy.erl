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
%%   === 池 ===
%%
%%   `server` 也可以是一个 bitcask_embedder_pool（N 个各绑一张卡的 worker）。
%%   这时 init 拿到的是 worker 的**注册名列表**，embed 时**直接打其中一个**：
%%
%%   ⚠️ **绝不经协调者转发。** 让一个进程去 gen_server:call worker 的话，那个
%%      进程自己就成了新的串行点，N 个 worker 等于白开。池是个 supervisor，
%%      它不参与热路径。
%%
%%   ⚠️ 缓存的是**注册名**不是 pid：worker 重启后 pid 变而名字不变，缓存名字
%%      不会失效。
%%
%%   选谁：取消息队列最短的那个。N 很小（就是卡数），一次 O(N) 的
%%   process_info 比任何集中式调度都便宜，而且天然反映"谁在忙"——
%%   worker 是串行的，队列长度就是它欠的活。
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
-export([info/1, workers/1]).

%% ===================================================================
%% Provider behaviour: init/1
%% ===================================================================

-spec init(map()) -> {ok, bitcask_embedder:ctx()} | {error, term()}.
init(Opts) when is_map(Opts) ->
    case maps:get(server, Opts, undefined) of
        undefined ->
            {error, {missing_opt, server}};
        Ref ->
            %% 池还是单进程？先问池，问不到就当单进程。
            {Probe, Workers} =
                case bitcask_embedder_pool:workers(Ref) of
                    {ok, [W | _] = Ws} -> {W, Ws};
                    {error, _}         -> {Ref, undefined}
                end,
            case bitcask_embedder_server:spec(Probe) of
                {error, _} = E ->
                    E;
                {ok, #{dim := Dim, vector_dim := VDim} = Spec} ->
                    Timeout = maps:get(timeout, Opts,
                                       maps:get(timeout, Spec, 60000)),
                    Cfg0 = #{server => Ref, timeout => Timeout},
                    Cfg = case Workers of
                              undefined -> Cfg0;
                              _         -> Cfg0#{workers => Workers}
                          end,
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
embed(#{workers := Ws, timeout := T}, Text) ->
    %% 池：直接打最闲的那个 worker，中间没有协调者。
    bitcask_embedder_server:embed(pick(Ws), Text, T);
embed(#{server := Ref, timeout := T}, Text) ->
    %% server 挂了返回 {error, {embedder_not_running, _}}，不会把调用方带走
    %% ——见 bitcask_embedder_server:call/3。
    bitcask_embedder_server:embed(Ref, Text, T).

%% 取消息队列最短的 worker。
%%
%% worker 是串行的（一个 llama_context 同时只服务一次前向），所以队列长度就是
%% 它欠的活 —— 这比轮询更贴近"谁真的闲着"，尤其在请求耗时不均时（查询 35 ms
%% 与长文档 890 ms 差一个数量级）。
%%
%% ⚠️ 没起来的 worker（whereis 返回 undefined）要排到最后而不是被直接选中：
%%    选中它只会拿到 {error, {embedder_not_running, _}}，而此刻别的 worker
%%    明明是好的。重启中的那一个不该拖垮整池。
pick([W]) -> W;
pick(Ws) ->
    Scored = [{qlen(W), W} || W <- Ws],
    {_, Best} = lists:min(Scored),
    Best.

qlen(W) ->
    case whereis(W) of
        undefined -> {1, 0};                    %% 没起来：排最后
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} -> {0, N};
                undefined              -> {1, 0}  %% 刚好死在这一刻
            end
    end.

%% 透传到 server 的 provider info（llama 是模型参数）。排错用。
-spec info(bitcask_embedder:ctx() | map()) -> {ok, map()} | {error, term()}.
info(#{config := Cfg})       -> info(Cfg);
info(#{workers := [W | _]})  -> bitcask_embedder_server:info(W);
info(#{server := Ref})       -> bitcask_embedder_server:info(Ref).

%% 池里的 worker 名字（排错 / 上层想自己调度时用）。单进程时返回 []。
-spec workers(bitcask_embedder:ctx() | map()) -> [atom()].
workers(#{config := Cfg})   -> workers(Cfg);
workers(#{workers := Ws})   -> Ws;
workers(#{})                -> [].
