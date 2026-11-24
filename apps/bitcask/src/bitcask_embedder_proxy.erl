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
%%   选谁：负载最轻的那个（正在算的那一次 + 邮箱里排队的）。N 很小（就是
%%   卡数），一次 O(N) 的 process_info 比任何集中式调度都便宜，而且天然反映
%%   "谁在忙"——worker 是串行的，手上那一次加队列长度就是它欠的活。
%%   ⚠️ 只看队列长度不够：gen_server 先把请求从邮箱取走再跑 handle_call，
%%      正在做前向的 worker 队列也是 0，跟闲着的分不开。见 pick/1。
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

-export([init/1, embed/2, embed_batch/2]).
-export([info/1, workers/1]).
-export([pick/1, load/1]).                  % 测试 / 排错用

%% scatter 的总 deadline 在最长那段的 worker 超时之上再留的余量。
-define(SCATTER_MARGIN_MS, 5000).

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

%% ===================================================================
%% embed_batch/2 —— 池化时**把批拆开、并行打到各个 worker**。
%%
%% 这是池 + 批量叠加起来的收益：K 个 worker × 每个一次批量 decode。
%% ⚠️ 拆分后各段并行发出（每段一个进程），否则就退化成串行地逐个 worker 喂，
%%    K 张卡里同时只有一张在算。
%% ⚠️ 结果必须按**原顺序**拼回去——调用方靠下标对回自己的 key。
%% ===================================================================
-spec embed_batch(map(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(#{workers := Ws, timeout := T}, Texts) when is_list(Texts) ->
    case chunk(Texts, length(Ws)) of
        []      -> {ok, []};
        [Only]  -> bitcask_embedder_server:embed_batch(pick(Ws), Only, T * length(Only));
        Chunks  -> scatter(Chunks, Ws, T)
    end;
embed_batch(#{server := Ref, timeout := T}, Texts) when is_list(Texts) ->
    bitcask_embedder_server:embed_batch(Ref, Texts, T * max(1, length(Texts))).

%% 均分成 K 段（最后几段可能少一条）。空输入 → []。
chunk([], _K) -> [];
chunk(Texts, K) when K =< 1 -> [Texts];
chunk(Texts, K) ->
    N = length(Texts),
    Per = (N + K - 1) div K,
    split(Texts, Per).

split([], _)  -> [];
split(L, Per) ->
    case length(L) =< Per of
        true  -> [L];
        false ->
            {H, Tl} = lists:split(Per, L),
            [H | split(Tl, Per)]
    end.

%% 多段并发：每段交给一个 worker，结果按原顺序拼回。
%%
%% 并发骨架用 bitcask_embedder_util:run_chunks/4（spawn_monitor + 单一总
%% deadline + 到点 kill + 收尾 flush）。以前这里自己 spawn + 逐段 receive，有
%% 四个问题：
%%   * 收集端兜底 T*4+60000 比 worker 自己的超时 T*length(C) 还短（一段 > 5 条
%%     就反了）——先放弃、把本来会回来的结果丢掉；
%%   * 逐段各等一个完整超时，最坏 K 倍；
%%   * 放弃后辅助进程迟早还会发结果，带着整段向量永远留在调用方信箱里；
%%     辅助进程是裸 spawn，崩了只能干等到超时；
%%   * 固定取前 K 个 worker，不看负载也不管死活，挂掉的照样分到一段。
%% 现在：worker 按负载排序（没起来的排最后），总 deadline = 最长那段的超时 +
%% 余量；某段因为 worker 没起来而失败，换一个活着的 worker 重试一次。
scatter(Chunks, Ws, T) ->
    Ranked = [W || {_, _, W} <- lists:sort([{load(W), rand:uniform(), W} || W <- Ws])],
    Pairs = lists:zip(lists:sublist(Ranked, length(Chunks)), Chunks),
    Results0 = run_pairs(Pairs, T),
    Results = retry_not_running(Results0, Pairs, Ranked, T),
    %% 任一段整体失败 → 该段的每一条都记成那个错，其余段照常返回。
    {ok, lists:append([per_item(R, C, T) || {R, {_W, C}} <- lists:zip(Results, Pairs)])}.

run_pairs(Pairs, T) ->
    Deadline = lists:max([chunk_timeout(C, T) || {_, C} <- Pairs]) + ?SCATTER_MARGIN_MS,
    bitcask_embedder_util:run_chunks(
      Pairs, length(Pairs), Deadline,
      fun({W, C}) -> bitcask_embedder_server:embed_batch(W, C, chunk_timeout(C, T)) end).

chunk_timeout(C, T) -> T * length(C).

%% worker 没起来（重启中）的那几段，换活着的 worker 再来一次；没有活着的
%% 就保留原错误。只重试一次——再失败说明不是瞬时问题。
retry_not_running(Results, Pairs, Ranked, T) ->
    Failed = [{I, W, C} || {I, {{ok, {error, {embedder_not_running, _}}}, {W, C}}}
                               <- lists:zip(lists:seq(1, length(Pairs)),
                                            lists:zip(Results, Pairs))],
    Dead = [W || {_, W, _} <- Failed],
    Alive = [W || W <- Ranked, not lists:member(W, Dead), element(1, load(W)) =:= 0],
    case {Failed, Alive} of
        {[], _} -> Results;
        {_, []} -> Results;
        _ ->
            N = length(Alive),
            Again = [{lists:nth((K rem N) + 1, Alive), C}
                     || {K, {_, _, C}} <- lists:zip(lists:seq(0, length(Failed) - 1), Failed)],
            Patch = maps:from_list(lists:zip([I || {I, _, _} <- Failed], run_pairs(Again, T))),
            [maps:get(I, Patch, R) || {I, R} <- lists:zip(lists:seq(1, length(Results)), Results)]
    end.

per_item({ok, {ok, Rs}}, _C, _T)             -> Rs;
per_item({ok, {error, _} = E}, C, _T)        -> lists:duplicate(length(C), E);
per_item({error, {chunk_timeout, _}}, C, T)  -> lists:duplicate(length(C), {error, {embedder_timeout, T}});
per_item({error, _} = E, C, _T)              -> lists:duplicate(length(C), E).

%% 取负载最轻的 worker：负载 = 正在算的那一次（0/1）+ 邮箱里排队的条数。
%%
%% worker 是串行的（一个 llama_context 同时只服务一次前向），所以这个数就是
%% 它欠的活 —— 这比轮询更贴近"谁真的闲着"，尤其在请求耗时不均时（查询 35 ms
%% 与长文档 890 ms 差一个数量级）。
%%
%% ⚠️ **必须算上"正在算的那一次"**：gen_server 先把请求从邮箱取出再跑
%%    handle_call，一个正在做 890 ms 前向的 worker 邮箱长度是 0，跟闲着的一样。
%%    只看队列长度时两个 worker 平局，lists:min 再按名字排序，`_0` 永远赢——
%%    两路并发的池实际只有一路在干活。"在算"由 current_function 判定：闲着的
%%    gen_server 停在 gen_server 模块自己的 receive 循环里，跑 handle_call 时
%%    当前函数是 provider 的（llama 是 NIF 存根、mock 是它自己的 embed）。
%%    gen_server 模块内的分发只有微秒级，漏判窗口可以忽略。
%% ⚠️ 平局随机打破，不按名字：否则同时到达的一批请求全砸在同一个上。
%% ⚠️ 没起来的 worker（whereis 返回 undefined）要排到最后而不是被直接选中：
%%    选中它只会拿到 {error, {embedder_not_running, _}}，而此刻别的 worker
%%    明明是好的。重启中的那一个不该拖垮整池。
-spec pick([atom(), ...]) -> atom().
pick([W]) -> W;
pick(Ws) ->
    Scored = [{load(W), rand:uniform(), W} || W <- Ws],
    {_, _, Best} = lists:min(Scored),
    Best.

%% {Down, Load}：Down = 1 表示没起来（排最后）；Load = 在算(0/1) + 队列长度。
-spec load(atom()) -> {0 | 1, non_neg_integer()}.
load(W) ->
    case whereis(W) of
        undefined -> {1, 0};                    %% 没起来：排最后
        Pid ->
            case process_info(Pid, [message_queue_len, current_function]) of
                [{message_queue_len, N}, {current_function, CF}] ->
                    {0, N + busy(CF)};
                undefined ->
                    {1, 0}                      %% 刚好死在这一刻
            end
    end.

%% 闲着的 gen_server 当前函数在 gen_server 模块里（loop / receive）；
%% 其它任何模块都意味着它正在跑 handle_call。hibernate 过的进程当前函数是
%% {erlang, hibernate, 3}，也算闲。
busy({gen_server, _, _}) -> 0;
busy({erlang, hibernate, _}) -> 0;
busy(_) -> 1.

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
