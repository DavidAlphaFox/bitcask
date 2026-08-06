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
%%   `instances` 的取值 —— **只接受显式的卡（组）列表，不做 auto**：
%%
%%     [0, 1, 2, 3]      4 个 instance，各占 1 张卡（模型单卡装得下，首选）
%%     [[0,1], [2,3]]    2 个 instance，各横跨 2 张卡（单卡装不下时）
%%     [[0,1,2,3]]       1 个 instance 跨 4 张卡（极大模型，退化成无并发）
%%
%%   扁平写法是"每组一张卡"的简写。组内多于一张时 `split_mode` 缺省自动变成
%%   `layer`（模型并行）；可在 `config` 里显式覆盖。
%%
%%   ⚠️ **不提供 `auto`（按机器上的卡数自动开）是有意的**：共享机器上别的租户
%%      也在用 GPU，一个被嵌入的库默认把整机的卡全占了不合适。要用哪几张由
%%      部署方写明。
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

-export([start_link/2, child_spec/3, workers/1, worker_name/2, is_pool/1]).
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
    case maps:get(instances, Opts, undefined) of
        undefined ->
            {error, {missing_opt, instances}};
        Instances when is_list(Instances), Instances =/= [] ->
            case validate_instances(Instances) of
                {error, _} = E -> E;
                {ok, Groups}   -> supervisor:start_link(Reg, ?MODULE, {Name, Groups, Opts})
            end;
        _ ->
            {error, {bad_opt, instances}}
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
init({Name, Groups, Opts}) ->
    Base = maps:without([instances, name], Opts),
    Idxs = lists:seq(0, length(Groups) - 1),
    %% worker 名字表写一次就不再变（名字稳定，worker 重启也不换），
    %% 所以 persistent_term 的写入代价只付一次。见 workers/1 的注释。
    persistent_term:put(pt_key(Name), [worker_name(Name, I) || I <- Idxs]),
    Children = [worker_spec(Name, I, G, Base)
                || {I, G} <- lists:zip(Idxs, Groups)],
    %% one_for_one：一个 worker 挂了只重启它自己。其余卡上那些 context 没理由
    %% 跟着重建——每次重建都是一次模型加载。
    {ok, {{one_for_one, 5, 10}, Children}}.

worker_spec(Pool, Idx, Group, Base) ->
    WName = worker_name(Pool, Idx),
    Cfg = maps:get(config, Base, #{}),
    Opts = Base#{config => Cfg#{gpu_index => Group}},
    %% child id 里带上 index 和名字，workers/1 靠它认出"这是我们的 worker"
    %% 并还原顺序。
    {{bc_emb_worker, Idx, WName},
     {bitcask_embedder_server, start_link, [{local, WName}, Opts]},
     permanent, ?WORKER_SHUTDOWN, worker, [bitcask_embedder_server]}.

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
