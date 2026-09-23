%% =========================================================================
%% bitcask_app
%%
%%   OTP application 行为模块。bitcask 注册成 application 是为了让
%%   bitcask:open/2 在 catch application:start(bitcask) 时把所有默认参数
%%   （max_file_size、open_timeout、sync_strategy 之类）从 .app.src 的 env
%%   段加载进来。
%%
%%   start/2 把控制权交给 bitcask_sup（顶层 supervisor）；该 supervisor 启
%%   动 bitcask_merge_worker 单例。stop/1 是 OTP 要求的回调，bitcask 没有
%%   需要在 application 下线时收尾的全局资源——sup 会自动 shutdown 子进
%%   程；NIF 资源由 BEAM GC 兜底。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case apply_thread_limits() of
        ok             -> bitcask_sup:start_link();
        {error, _} = E -> E
    end.

stop(_State) ->
    ok.

%% libbitcask 6.6.0：env `{thread_limits, {IndexWorkers, SearchSlots}}` 在首个
%% 索引模式库 open 之前应用（bitcask:open/2 先 start application）。undefined
%% （默认）= 不设，沿用 hardware_concurrency。已冻结且值不同 → application
%% 起不来：配了上限却静默不生效，比起不来更难查（同 embedder 的取舍）。
apply_thread_limits() ->
    case application:get_env(bitcask, thread_limits, undefined) of
        undefined ->
            ok;
        {IW, SS} when is_integer(IW), IW >= 0, is_integer(SS), SS >= 0 ->
            bitcask:set_thread_limits(IW, SS);
        Other ->
            {error, {bad_thread_limits, Other}}
    end.
