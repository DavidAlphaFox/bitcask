%% =========================================================================
%% bitcask_sup
%%
%%   bitcask 的顶层 supervisor。M6 之后只剩一个 child：
%%
%%     bitcask_merge_worker  — 全局 merge 调度器（窗口 + 去重 + 限流）
%%
%%   旧的 bitcask_merge_delete 已经随 legacy 一并删除——cask_cpp 在
%%   merge 完成时直接 unlink 掉旧 data file，不需要单独的延迟删除 worker
%%   来跟 fold 迭代器协调。
%%
%%   重启策略 one_for_one：merge_worker 挂掉只重启它自己（也只可能它一个挂）。
%%   maxR=5, maxT=10：10 秒内重启 5 次以上就放弃，让上层 application 决定怎么办。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_sup).

-behaviour(supervisor).

-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-include_lib("pulse_otp/include/pulse_otp.hrl").
-endif.

-export([start_link/0]).
-export([init/1]).

%% supervisor child spec 缩写：永久子进程，shutdown 等 5s。
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10}, [?CHILD(bitcask_merge_worker, worker)]}}.
