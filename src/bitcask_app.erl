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
    bitcask_sup:start_link().

stop(_State) ->
    ok.
