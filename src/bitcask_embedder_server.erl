%% -------------------------------------------------------------------
%% bitcask_embedder_server:
%%   把一个 embedder provider ctx 装进独立的 gen_server 进程。
%%
%%   === 为什么要有这个进程 ===
%%
%%   `{embedder, {Provider, Cfg}}` 那条路是**每 open 一次建一个 ctx**。对
%%   HTTP provider 无所谓（ctx 只是几个配置字段），但对本地模型
%%   （bitcask_embedder_llama）有三个问题，这个进程正好一次解决：
%%
%%   (1) **权重只装一份。** open 两个 cask = 内存里两份几百 MB 的权重。进程
%%       持有句柄，多少个 cask 都共用同一份。
%%   (2) **生命周期有主。** bitcask:close/1 只关 cask ref，不关 embedder——
%%       模型会一直占着内存直到那个 term 被 GC，而释放又会占住 BEAM 的资源
%%       回收线程。挂进 supervisor 之后，terminate/2 里显式 close，进程死了
%%       资源就回收了。
%%   (3) **串行是本来就要的。** llama_context 不是线程安全的，C++ 侧靠互斥量
%%       保证正确性。gen_server 的单进程语义就是这个约束本身，而且排队发生在
%%       Erlang 侧（消息队列），不是让多个 dirty 调度线程堵在一把 C 互斥量上。
%%
%%   === 怎么起 ===
%%
%%   **推荐：配 application env，由 bitcask_sup 起。** 不配就不起，bitcask
%%   不依赖它：
%%
%%       {bitcask, [{embedder,
%%           #{name     => my_embedder,          %% 可选，注册名
%%             provider => {custom, bitcask_embedder_llama},
%%             config   => #{model_path => <<"/models/qwen3-emb.gguf">>,
%%                           pooling => last, n_ctx => 512}}}]}
%%
%%       H1 = bitcask:open(Dir1, [read_write, {analyzer, whitespace},
%%                                {embedder, my_embedder}]),
%%       H2 = bitcask:open(Dir2, [read_write, {analyzer, whitespace},
%%                                {embedder, my_embedder}]),   %% 共用同一份权重
%%
%%   ⚠️ **配了却起不来（GGUF 路径写错、pooling 解析成 NONE …）会让整个 bitcask
%%      application 起不来，这是有意的**：配置了嵌入模型就说明业务要用它，此时
%%      "静静地降级成没有嵌入能力"比当场死掉危险得多——前者要到检索结果不对
%%      才发现，那时候库已经写脏了。
%%      为此 bitcask:open/2 也不再吞掉 application:start 的失败（从前那句
%%      `catch application:start(bitcask)` 会把它吃干净）。
%%
%%   也可以自己 start_link / 放进自己的 supervision tree：
%%
%%       ChildSpec = bitcask_embedder_server:child_spec(
%%                     my_embedder, {local, my_embedder}, #{provider => ..., config => ...}),
%%
%%   === Opts ===
%%     provider  — 必填。{custom, Mod} | openai | anthropic，同 bitcask_embedder:new/2
%%     config    — 必填。provider 的配置 map
%%     timeout   — embed 调用超时（毫秒），默认 60000
%%
%%   === ⚠️ 只把**有状态** provider 放进来 ===
%%
%%   两类 provider 的差别只在"向量从哪来"，而那个差别决定了要不要进程：
%%
%%     * **HTTP 档**（openai / anthropic）——无状态，配置就是几个字段，HTTP
%%       请求本来就该并发。**不要**放进这个进程：所有 embed 会排成一条链，
%%       吞吐被锁死在单进程上。直接写 {embedder, {openai, Cfg}}，不需要配置
%%       任何进程。
%%     * **内置档**（bitcask_embedder_llama）——有状态（几百 MB 权重 + 非线程
%%       安全的 context），装一次要复用，本来就必须串行。**这个进程就是为它
%%       存在的。**
%%
%%   两边共享的逻辑（输入裁剪、维度校验、MRL）在 bitcask_embedder_util。
%% -------------------------------------------------------------------
-module(bitcask_embedder_server).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2,
         child_spec/2, child_spec/3,
         embed/2, embed/3,
         embed_batch/2, embed_batch/3,
         spec/1,
         info/1,
         stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(DEFAULT_TIMEOUT, 60000).

-type server_ref() :: pid() | atom() | {global, term()} | {via, module(), term()}.
-export_type([server_ref/0]).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec start_link(Name :: {local, atom()} | {global, term()} | {via, module(), term()},
                 map()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) when is_map(Opts) ->
    gen_server:start_link(Name, ?MODULE, Opts, []).

%% supervisor child spec。默认 permanent / shutdown 30s。
%%
%% ⚠️ shutdown 给 30 秒不是随手写的：terminate/2 里要释放模型，几 GB 的权重
%%    munmap 不是瞬间完成的。默认的 5000 会在收尾做完之前 brutal_kill。
-spec child_spec(term(), map()) -> supervisor:child_spec().
child_spec(Id, Opts) ->
    #{id => Id,
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 30000,
      type => worker,
      modules => [?MODULE]}.

-spec child_spec(term(), tuple(), map()) -> supervisor:child_spec().
child_spec(Id, Name, Opts) ->
    (child_spec(Id, Opts))#{start => {?MODULE, start_link, [Name, Opts]}}.

%% -------------------------------------------------------------------
%% embed/2,3
%%
%% ⚠️ 所有 gen_server:call 的退出都被翻成 {error, _}。**embedder 挂掉不该
%%    把调用方一起带走**——put 的调用方通常是业务进程，它对"嵌入服务没起来"
%%    的正确反应是记一条错，不是自己也死。
%% -------------------------------------------------------------------
-spec embed(server_ref(), binary()) -> {ok, binary()} | {error, term()}.
embed(Ref, Text) -> embed(Ref, Text, ?DEFAULT_TIMEOUT).

-spec embed(server_ref(), binary(), timeout()) -> {ok, binary()} | {error, term()}.
embed(Ref, Text, Timeout) when is_binary(Text) ->
    call(Ref, {embed, Text}, Timeout).

%% 批量。⚠️ 超时按条数放大：一整批在 worker 里是**一次** call，用单条的超时会
%% 在批量稍大时必然超时，而超时的表现是整批白算。
-spec embed_batch(server_ref(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(Ref, Texts) -> embed_batch(Ref, Texts, batch_timeout(Texts, ?DEFAULT_TIMEOUT)).

-spec embed_batch(server_ref(), [binary()], timeout()) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(Ref, Texts, Timeout) when is_list(Texts) ->
    call(Ref, {embed_batch, Texts}, Timeout).

batch_timeout([], T)    -> T;
batch_timeout(Texts, T) -> T * length(Texts).

%% 给 bitcask_embedder_proxy 在 open 时问一次：维度 + 默认超时。
-spec spec(server_ref()) -> {ok, map()} | {error, term()}.
spec(Ref) -> call(Ref, spec, 5000).

%% provider 自己的 info（llama 是模型参数：dim / n_ctx / pooling / 描述）。
%% provider 没实现 info/1 就返回 {error, not_supported}。
-spec info(server_ref()) -> {ok, map()} | {error, term()}.
info(Ref) -> call(Ref, info, 5000).

-spec stop(server_ref()) -> ok.
stop(Ref) ->
    try gen_server:stop(Ref, normal, 30000)
    catch exit:_ -> ok
    end.

call(Ref, Msg, Timeout) ->
    try
        gen_server:call(Ref, Msg, Timeout)
    catch
        exit:{noproc, _}      -> {error, {embedder_not_running, Ref}};
        exit:{{nodedown, _}, _} -> {error, {embedder_not_running, Ref}};
        exit:{timeout, _}     -> {error, {embedder_timeout, Timeout}};
        exit:Reason           -> {error, {embedder_down, Reason}}
    end.

%% ===================================================================
%% gen_server
%% ===================================================================

init(Opts) ->
    %% ⚠️ trap_exit 是为了 terminate/2 一定会跑到——模型的释放就在那里。
    %%    不设的话 supervisor 关停时进程直接死，llama_free 要等 GC，而 GC
    %%    发生在 BEAM 的资源回收线程上（正是我们想避开的那条路）。
    process_flag(trap_exit, true),
    case {maps:get(provider, Opts, undefined), maps:get(config, Opts, undefined)} of
        {undefined, _} -> {stop, {missing_opt, provider}};
        {_, undefined} -> {stop, {missing_opt, config}};
        {Provider, Cfg} ->
            case bitcask_embedder:new(Provider, Cfg) of
                {error, Reason} ->
                    %% 起不来就明确 stop，别装作起来了——半死的 embedder 会让
                    %% 每一次 put 都在运行期才发现问题。挂在 bitcask_sup 下时
                    %% 这一步的失败会一路冒到 application:start，那正是我们要的
                    %% ——配了模型却路径写错，就该当场死给用户看。
                    {stop, Reason};
                {ok, Ctx} ->
                    {ok, #{provider => Provider,
                           ctx      => Ctx,
                           timeout  => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)}}
            end
    end.

handle_call({embed, Text}, _From, #{ctx := Ctx} = S) ->
    {reply, bitcask_embedder:embed(Ctx, Text), S};

handle_call({embed_batch, Texts}, _From, #{ctx := Ctx} = S) ->
    {reply, bitcask_embedder:embed_batch(Ctx, Texts), S};

handle_call(spec, _From, #{ctx := Ctx, timeout := T} = S) ->
    %% ⚠️ **故意不把 ctx 交出去。** 交了就等于允许调用方绕过串行在自己的进程里
    %%    算，而串行正是这个进程存在的理由之一（llama_context 非线程安全）。
    {reply, {ok, #{dim        => bitcask_embedder:dim(Ctx),
                   vector_dim => bitcask_embedder:vector_dim(Ctx),
                   timeout    => T}}, S};

handle_call(info, _From, #{provider := Provider, ctx := Ctx} = S) ->
    {reply, provider_info(Provider, Ctx), S};

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

%% 释放 provider 持有的资源（llama 是模型权重）。provider 没实现 close/1 就
%% 什么都不用做（HTTP provider 就是这种）。
terminate(_Reason, #{provider := Provider, ctx := Ctx}) ->
    _ = provider_close(Provider, Ctx),
    ok;
terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ===================================================================
%% 内部
%% ===================================================================

provider_module({custom, Mod}) -> Mod;
provider_module(openai)        -> bitcask_embedder_openai;
provider_module(anthropic)     -> bitcask_embedder_anthropic;
provider_module(_)             -> undefined.

%% 可选回调：provider 实现了才调。用 function_exported 而不是 try/catch——
%% catch undef 会把 provider **内部**的 undef 也一起吞掉，那种错误必须冒出来。
provider_close(Provider, Ctx) ->
    apply_optional(provider_module(Provider), close, [Ctx], ok).

provider_info(Provider, Ctx) ->
    apply_optional(provider_module(Provider), info, [Ctx], {error, not_supported}).

apply_optional(undefined, _F, _A, Default) ->
    Default;
apply_optional(Mod, F, A, Default) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, F, length(A)) of
        true  -> apply(Mod, F, A);
        false -> Default
    end.
