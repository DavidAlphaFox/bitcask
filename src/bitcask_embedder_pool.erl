%% -------------------------------------------------------------------
%% bitcask_embedder_pool:
%%   一组 bitcask_embedder_server，每个绑一张（或一组）GPU —— **数据并行**。
%%
%%   === 为什么是数据并行，不是把 layer 切到多张卡上 ===
%%
%%   嵌入模型的关键事实是**它很小而请求很多**（0.6B Q8_0 才 640 MB）。这种情况下
%%   把 layer 切到 N 张卡上（模型并行）是反优化：
%%
%%     * 每层边界都要跨卡传输，而一次前向本来只有几十毫秒；
%%     * 更要命的是**一个 llama_context 同时只服务一次前向**，切完之后 N 张卡
%%       仍然只在处理 1 个请求 —— 等于把 N 张卡的算力当 1 张用。
%%
%%   数据并行是：**一卡跑全部 layer，N 个 instance 各占一卡**，N 个请求真并发。
%%   这正好对上本仓库的结构（一句柄 = 一 llama_context = 串行）。
%%
%%       请求A → worker_0 → [卡0: 全部 layer]
%%       请求B → worker_1 → [卡1: 全部 layer]     ← 真并发
%%       请求C → worker_2 → [卡2: 全部 layer]
%%
%%   单卡显存占用仍是**一份**权重（各在各的卡上），不是 N 份叠在一张卡上。
%%
%%   === ⚠️ 协调者绝不能在热路径上 ===
%%
%%   本模块是个 **supervisor**，不是 gen_server —— 它不转发任何 embed。
%%   如果让一个协调进程去 `gen_server:call` worker，那个协调者自己就成了新的
%%   串行点，N 个 worker 等于白开。所以：
%%
%%     * worker 用**稳定注册名**（`Pool_0` / `Pool_1` …）注册，重启后名字不变；
%%     * 调用方（bitcask_embedder_proxy）拿到名字列表后**直接打 worker**，
%%       中间没有任何一跳。
%%
%%   稳定名字还顺带解决了"worker 重启后 pid 变了"——缓存名字不会失效，缓存 pid 会。
%%
%%   === 用 ===
%%
%%       {bitcask, [{embedder,
%%           #{name      => my_embedder,
%%             provider  => {custom, bitcask_embedder_llama},
%%             instances => [0, 1, 2, 3],        %% 4 卡，各一个 instance
%%             config    => #{model_path => <<"...gguf">>, pooling => last}}}]}
%%
%%       H = bitcask:open(Dir, [read_write, {analyzer, whitespace},
%%                              {embedder, my_embedder}]).
%%
%%   `instances` 的取值：
%%
%%     [0, 1, 2, 3]      4 个 instance，各占 1 张卡（模型单卡装得下，首选）
%%     [[0,1], [2,3]]    2 个 instance，各横跨 2 张卡（单卡装不下时）
%%     [[0,1,2,3]]       1 个 instance 跨 4 张卡（极大模型，退化成无并发）
%%     auto              由 provider 探测：**枚举到的、且装得下模型的**卡，
%%                       一卡一个
%%
%%   扁平写法是"每组一张卡"的简写。组内多于一张时 `split_mode` 缺省自动变成
%%   `layer`（模型并行）；可在 `config` 里显式覆盖。
%%
%%   `per_gpu => K`（默认 1）在上面的基础上把每个 instance 复制 K 份 —— 同一张卡
%%   开 K 个 context。⚠️ 一个 context 同时只服务一次前向，所以同卡多开确实能多几路
%%   并发；但它们抢同一批 SM，收益**不一定线性**，而显存按份数实打实地涨。这条
%%   没有实测数据，所以是显式选项、不进默认路径。
%%
%%   === ⚠️ 失败策略按写法不同，这条不对称是有意的 ===
%%
%%     显式列表 → **全都必须起来**，任一起不来则整个 application 起不来。
%%                写下卡号是一种意图声明：你说了要 2 号卡，它起不来就是配置与
%%                现实不符。
%%     auto     → **尽力而为**：起不来的那个跳过（日志里记原因），其余照起；
%%                一个都没起来才算失败。auto 本来就是"有什么用什么"，一张卡忙着
%%                不该拖垮整个 application。
%%
%%   ⚠️ "尽力而为"必须配"说得出来"：8 张卡只起来 1 个时业务拿到的是 1/8 的吞吐，
%%      而一切看起来正常。`status/1` 报 requested / started / missing。
%%
%%   ⚠️ **`auto` 不去猜"该用哪几张卡"**：这个进程能看见哪几张本来就是运维侧的
%%      标准手段（`GGML_CUDA_DEVICES` / `CUDA_VISIBLE_DEVICES` /
%%      `GGML_VK_VISIBLE_DEVICES` / 容器设备透传），我们不该另造一套。
%%
%%   === ⚠️ 启动是串行的 ===
%%
%%   supervisor 顺序启动 child，每个 child 在 init 里同步加载模型。N 个
%%   instance 就是 N 次加载（0.6B 实测 542 ms/次，8 卡 ≈ 4.3 s；8B 会是几十秒）。
%%   这是**故意没有改成并行/懒加载**的：那样 worker 的启动失败会绕过
%%   supervisor 的启动期检查，退化成"起来了但随后反复重启"，而
%%   「配了 embedder 却起不来就让 application 死」这条策略正是靠启动期同步失败
%%   才成立的（见 bitcask_sup 的头注释）。用容量换确定性。
%% -------------------------------------------------------------------
-module(bitcask_embedder_pool).

-behaviour(supervisor).

-export([start_link/2, child_spec/3, workers/1, worker_name/2, is_pool/1,
         status/1]).
-export([start_worker_lenient/3]).
-export([init/1]).

%% supervisor 的启动超时：N 次模型加载都在这里面。给足。
-define(WORKER_SHUTDOWN, 30000).

%% ===================================================================
%% API
%% ===================================================================

%% ⚠️ 配置校验在这里做，不在 init 里 —— supervisor 的 init/1 **没有**
%%    `{stop, Reason}` 这个返回（那是 gen_server 的），用了会被判成
%%    `{error, {bad_return, ...}}`，把真正的原因埋在两层包裹里。
%%    校验本来就是纯函数，提前做，错误就是裸的 {error, {bad_opt, _}}。
-spec start_link({local, atom()}, map()) -> {ok, pid()} | {error, term()}.
start_link({local, Name} = Reg, Opts) when is_atom(Name), is_map(Opts) ->
    case resolve_groups(Opts) of
        {error, _} = E ->
            E;
        {ok, Groups0, Mode} ->
            Groups = expand_per_gpu(Groups0, maps:get(per_gpu, Opts, 1)),
            case supervisor:start_link(Reg, ?MODULE, {Name, Groups, Mode, Opts}) of
                {error, _} = E ->
                    E;
                {ok, Pid} ->
                    %% ⚠️ auto 模式下起不来的 worker 被记成 undefined（child 的
                    %%    start 返回 ignore），supervisor 照常起来。这里收口两件事：
                    %%    ① 一个都没起来就不算成功——8 张卡只起来 0 个还说 ok，
                    %%       业务拿到的是"配了 embedder 但每次 embed 都失败"；
                    %%    ② 把**实际**起来的名字写进 persistent_term，别让调用方
                    %%       缓存一堆从没起来的名字。
                    Live = live_workers(Name, length(Groups)),
                    case Live of
                        [] ->
                            unlink(Pid),
                            exit(Pid, shutdown),
                            {error, {no_worker_started, Mode}};
                        _ ->
                            persistent_term:put(pt_key(Name), Live),
                            {ok, Pid}
                    end
            end
    end.

%% slots 优先：`slots => K` 是"K 路并发"的直接表达，展开成 K 个不绑卡的
%% group（worker_spec 对 none 组不注入 gpu_index，配置原样透传）；没给 slots
%% 才走 instances 那条设备拓扑的路。失败策略沿用 explicit：你要了 K 个槽位，
%% 起不满就该死给你看，而不是悄悄降成低并发。
resolve_groups(Opts) ->
    HasSlots = maps:is_key(slots, Opts),
    HasInstances = maps:is_key(instances, Opts),
    if
        %% 冲突检查必须在这里做，不能留给 resolve_instances——slots 分支
        %% 在它之前就返回了，留给它就是永远不可达（首版就栽在这）。
        HasSlots andalso HasInstances ->
            {error, {bad_opt, {slots_conflicts_with_instances, Opts}}};
        HasSlots ->
            case maps:get(slots, Opts) of
                K when is_integer(K), K >= 1 ->
                    {ok, lists:duplicate(K, none), explicit};
                _ ->
                    {error, {bad_opt, slots}}
            end;
        true ->
            resolve_instances(Opts)
    end.

%% instances 的三种写法：
%%   [0,1,2] / [[0,1],[2,3]]  显式 —— **全都必须起来**（见下）
%%   auto                     由 provider 探测 —— 尽力而为
%% slots 的写法：
%%   K（正整数）              K 个**不绑卡**的并发槽位 —— 等价 K × [none]。
%%
%% === ⚠️ slots 与 instances 的语义差别 ===
%%
%%   instances 绑定的是**设备拓扑**（哪张卡放哪个 instance），每组注入
%%   `gpu_index`；slots 表达的是**并发度**——K 个同配置 worker，配置原样
%%   透传（不注入任何 gpu_index，绑卡与否由 config 自带的 backend /
%%   gpu_index 决定）。K 个 worker = K 份权重 + K 个 context = K 路真正
%%   并发的 forward；要的是并发就是它的用途，别拿它当"多卡"用。
resolve_instances(Opts) ->
    case maps:get(instances, Opts, undefined) of
        undefined ->
            %% slots 与 instances 同时给 = 意图不明，当场拒绝而不是猜。
            case maps:is_key(slots, Opts) of
                true  -> {error, {bad_opt, {slots_conflicts_with_instances, Opts}}};
                false -> {error, {missing_opt, instances}}
            end;
        auto ->
            case provider_auto_instances(Opts) of
                {error, _} = E -> E;
                %% 一张可用的卡都没有 → 一个不绑卡的 instance（纯 CPU）。
                %% auto 的语义是"有什么用什么"，没卡时仍然该可用。
                {ok, []}       -> {ok, [none], auto};
                {ok, Groups}   -> {ok, Groups, auto}
            end;
        Instances when is_list(Instances), Instances =/= [] ->
            case validate_instances(Instances) of
                {error, _} = E -> E;
                {ok, Groups}   -> {ok, Groups, explicit}
            end;
        _ ->
            {error, {bad_opt, instances}}
    end.

%% auto 需要 provider 告诉我们这台机器上有哪些可用的卡 —— 这件事只有 provider
%% 知道（HTTP 档根本没有卡的概念）。没实现这个可选回调的 provider 不支持 auto。
provider_auto_instances(Opts) ->
    Mod = case maps:get(provider, Opts, undefined) of
              {custom, M} -> M;
              _           -> undefined
          end,
    Cfg = maps:get(config, Opts, #{}),
    case Mod =/= undefined andalso
         (code:ensure_loaded(Mod) =/= {error, nofile}) andalso
         erlang:function_exported(Mod, auto_instances, 1) of
        true  -> Mod:auto_instances(Cfg);
        false -> {error, {instances_auto_unsupported, Mod}}
    end.

%% per_gpu：同一张卡上开 K 个 instance。
%%
%% ⚠️ **默认 1，不要随手调大。** 一个 llama_context 同时只服务一次前向，所以同卡
%%    多开确实能多几路并发；但它们抢的是同一批 SM，收益**不一定线性**，而显存是
%%    实打实按份数涨的。这条没有实测数据，所以是显式选项、不进默认路径。
expand_per_gpu(Groups, K) when is_integer(K), K > 1 ->
    lists:append([lists:duplicate(K, G) || G <- Groups]);
expand_per_gpu(Groups, _) ->
    Groups.

%% 实际起来了的 worker 名（按 index 顺序）。
live_workers(Name, N) ->
    [W || I <- lists:seq(0, N - 1),
          W <- [worker_name(Name, I)],
          whereis(W) =/= undefined].

%% -------------------------------------------------------------------
%% status/1 —— 要了几个、实际起了几个。
%%
%% ⚠️ 这个函数是 auto 模式"尽力而为"的**必要配套**：8 张卡只起来 1 个时业务拿到
%%    的是 1/8 的吞吐，而一切看起来正常。少了就必须问得出来。
%% -------------------------------------------------------------------
-spec status(atom()) -> {ok, map()} | {error, term()}.
status(Pool) when is_atom(Pool) ->
    case whereis(Pool) of
        undefined -> {error, not_a_pool};
        _ ->
            All  = persistent_term:get(pt_key({all, Pool}), []),
            Live = case persistent_term:get(pt_key(Pool), undefined) of
                       undefined -> [];
                       L -> [W || W <- L, whereis(W) =/= undefined]
                   end,
            {ok, #{requested => length(All),
                   started   => length(Live),
                   workers   => Live,
                   missing   => All -- Live}}
    end.

-spec child_spec(term(), {local, atom()}, map()) -> supervisor:child_spec().
child_spec(Id, Reg, Opts) ->
    #{id => Id,
      start => {?MODULE, start_link, [Reg, Opts]},
      restart => permanent,
      %% infinity 是 supervisor 类型 child 的要求（它要把关停传递下去）。
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

%% worker 的稳定注册名。⚠️ 稳定是关键：调用方缓存的是名字，worker 重启后
%% 名字不变，缓存不会失效（缓存 pid 就会）。
-spec worker_name(atom(), non_neg_integer()) -> atom().
worker_name(Pool, Idx) ->
    list_to_atom(atom_to_list(Pool) ++ "_" ++ integer_to_list(Idx)).

%% 池里全部 worker 的注册名，按 instances 的顺序。
%%
%% 不是池（传进来的是单个 embedder server，或者根本没起来）时返回
%% {error, not_a_pool} —— 调用方据此走单进程那条路。
%%
%% ⚠️ **不靠 supervisor:which_children 判别。** 那个函数的 spec 声明返回值一定是
%%    list，"不是 list ⇒ 不是池"这条分支在类型上不可达（dialyzer 会指出来），而
%%    它实际可达只是因为对普通 gen_server 调它会拿到那个 gen_server 自己的回复
%%    —— 靠一个规格外的行为做判别本身就脆。
%%    改成：池在 init 里把 worker 名字表写进 persistent_term。这份数据在池的整个
%%    生命周期里**不变**（名字是稳定的，worker 重启也不换），所以只写一次，
%%    persistent_term 的写入代价（一次全局 GC 扫描）只付一次。
%%
%% ⚠️ 池必须**按注册名**引用。传 pid 会得到 not_a_pool —— worker 的稳定名字由池名
%%    派生，没有名字就没有池。bitcask_sup 在 instances 在场时强制要求 name。
-spec workers(atom() | pid()) -> {ok, [atom()]} | {error, term()}.
workers(Pool) when is_atom(Pool) ->
    %% 先看池进程是否活着：persistent_term 里可能留着已死池的残余。
    case whereis(Pool) of
        undefined -> {error, not_a_pool};
        _ ->
            case persistent_term:get(pt_key(Pool), undefined) of
                undefined -> {error, not_a_pool};
                Ws        -> {ok, Ws}
            end
    end;
workers(_Pid) ->
    {error, not_a_pool}.

pt_key(Pool) -> {?MODULE, workers, Pool}.

-spec is_pool(atom() | pid()) -> boolean().
is_pool(Ref) ->
    case workers(Ref) of
        {ok, _} -> true;
        _       -> false
    end.

%% ===================================================================
%% supervisor
%% ===================================================================

%% Groups 已由 start_link 校验并归一（每项是非空的卡下标列表）。
init({Name, Groups, Mode, Opts}) ->
    Base = maps:without([instances, slots, name, per_gpu], Opts),
    Idxs = lists:seq(0, length(Groups) - 1),
    Names = [worker_name(Name, I) || I <- Idxs],
    %% worker 名字表写一次就不再变（名字稳定，worker 重启也不换），
    %% 所以 persistent_term 的写入代价只付一次。见 workers/1 的注释。
    %% start_link 之后会把它收窄成**实际起来**的那些。
    persistent_term:put(pt_key(Name), Names),
    persistent_term:put(pt_key({all, Name}), Names),
    Children = [worker_spec(Name, I, G, Base, Mode)
                || {I, G} <- lists:zip(Idxs, Groups)],
    %% one_for_one：一个 worker 挂了只重启它自己。其余卡上那些 context 没理由
    %% 跟着重建——每次重建都是一次模型加载。
    {ok, {{one_for_one, 5, 10}, Children}}.

worker_spec(Pool, Idx, Group, Base, Mode) ->
    WName = worker_name(Pool, Idx),
    Cfg0 = maps:get(config, Base, #{}),
    %% Group = none 表示"不绑卡"（auto 在没有可用 GPU 时的退化）。
    Cfg = case Group of
              none -> Cfg0;
              _    -> Cfg0#{gpu_index => Group}
          end,
    Opts = Base#{config => Cfg},
    %% ⚠️ **失败策略按写法不同而不同，这条不对称是有意的：**
    %%
    %%   显式列表 → 起不来就让 supervisor 失败（一路冒到 application 起不来）。
    %%     写下卡号是一种**意图声明**：你说了要用 2 号卡，它起不来就是配置与
    %%     现实不符，该死给你看。
    %%   auto     → 起不来就 ignore 掉那一个，别的照起。
    %%     auto 本来就是"有什么用什么"，一张卡忙着不该拖垮整个 application。
    %%     少了几个由 status/1 问得出来——"尽力而为"必须配"说得出来"。
    Start = case Mode of
                explicit -> {bitcask_embedder_server, start_link, [{local, WName}, Opts]};
                auto     -> {?MODULE, start_worker_lenient, [{local, WName}, Opts, Idx]}
            end,
    %% child id 里带上 index 和名字，workers/1 靠它认出"这是我们的 worker"
    %% 并还原顺序。
    {{bc_emb_worker, Idx, WName}, Start,
     permanent, ?WORKER_SHUTDOWN, worker, [bitcask_embedder_server]}.

%% auto 模式的 child start：起不来返回 ignore（supervisor 把它记成 undefined
%% 并继续），而不是 {error,_}（那会让整个 supervisor 起不来）。
%%
%% ⚠️ 失败必须**留下痕迹**。静默跳过一张卡的后果是吞吐悄悄少一份，而这正是
%%    整套设计一直在防的那类事。
start_worker_lenient(Reg, Opts, Idx) ->
    case bitcask_embedder_server:start_link(Reg, Opts) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            logger:warning("bitcask_embedder_pool: instance ~p failed to start, "
                           "skipping it (instances => auto). reason=~p", [Idx, Reason]),
            ignore
    end.

%% instances 每一项：整数 = 单卡；非空整数列表 = 卡组。
%%
%% ⚠️ 同一张卡不允许出现在两个 instance 里 —— 那是配置错，后果是两份权重挤在
%%    一张卡上互相抢显存，而表现只是"莫名其妙的 OOM 或慢"。当场拒绝。
validate_instances(Instances) ->
    Norm = lists:map(fun normalize_group/1, Instances),
    case lists:keyfind(error, 1, [{error, X} || {error, X} <- Norm]) of
        {error, _} = E ->
            E;
        false ->
            Groups = [G || {ok, G} <- Norm],
            Flat = lists:append(Groups),
            case length(Flat) =:= length(lists:usort(Flat)) of
                true  -> {ok, Groups};
                false -> {error, {bad_opt, {instances, duplicate_gpu}}}
            end
    end.

normalize_group(I) when is_integer(I), I >= 0 -> {ok, [I]};
normalize_group(L) when is_list(L), L =/= [] ->
    case lists:all(fun(X) -> is_integer(X) andalso X >= 0 end, L) of
        true  -> {ok, L};
        false -> {error, {bad_opt, {instances, L}}}
    end;
normalize_group(X) -> {error, {bad_opt, {instances, X}}}.
