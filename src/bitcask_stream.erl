%% =========================================================================
%% bitcask_stream
%%
%%   流式 fold 接口。底层走一个 producer 进程：
%%
%%     stream(Ref)         spawn 一个 producer 进程，立刻 cask_fold_start
%%                         拿到独立 IterRef；返回 StreamRef。
%%     next(StreamRef)     消费者拉一条；producer 收到 next 才 cask_fold_next
%%                         一条返回（pull-with-backpressure，无内存堆积）。
%%     stop(StreamRef)     显式结束；幂等。
%%     with_stream(Ref, F) RAII 包装：自动 stop。
%%
%%   producer 同时等三种消息：
%%     {bitcask_stream_next, From}  — 拉下一条
%%     bitcask_stream_stop           — 消费者主动结束
%%     {'DOWN', Mon, _, _, _}        — 消费者崩溃
%%   三条退出路径都汇聚到 try/after，保证 cask_fold_release 一定执行。
%%
%%   StreamRef 由 spawn 它的进程独占；跨进程共享是 undefined behaviour。
%%
%%   底层用 cask_fold_start（多 IterRef 并发）而不是 cask_iterator
%%   （per-cask 单实例），所以同一个 Ref 上可以同时开多个 stream。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_stream).

-export([stream/1,
         next/1,
         stop/1,
         with_stream/2]).

%% StreamRef 的 opaque 形态。带前缀 atom 是为了让 dialyzer / 模式匹配
%% 一眼能识别，并防止跟普通 {Pid, Mon} 元组混淆。
-define(STREAM(Pid, MRef), {bitcask_stream, Pid, MRef}).

%% =========================================================================
%% 公共 API
%% =========================================================================

%% 在 Ref 上开一个流。返回的 StreamRef 由当前进程独占。
%% 失败原因可能是 NIF 启动 fold 失败（read-only ref + 已 close 等）。
-spec stream(reference()) -> {ok, term()} | {error, term()}.
stream(Ref) ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(fun() -> producer_init(Ref, Parent) end),
    receive
        {bitcask_stream_ready, Pid} ->
            {ok, ?STREAM(Pid, MRef)};
        {bitcask_stream_error, Pid, Reason} ->
            erlang:demonitor(MRef, [flush]),
            {error, Reason};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason}
    end.

%% 拉下一条。
%%   {ok, Key, Value} - 一条 entry
%%   done             - 迭代完成（idempotent：之后再调还返回 done）
%%   {error, Reason}  - 迭代过程出错或 producer 异常退出
-spec next(term()) -> {ok, binary(), binary()} | done | {error, term()}.
next(?STREAM(Pid, MRef)) ->
    Pid ! {bitcask_stream_next, self()},
    receive
        {bitcask_stream_entry, Pid, K, V}    -> {ok, K, V};
        {bitcask_stream_done,  Pid}          -> done;
        {bitcask_stream_error, Pid, Reason}  -> {error, Reason};
        %% producer 在我们 send next 之前就死了的情况——通常是 done 之后
        %% 自己退出（不会发生，本实现 producer 收到 done 后会 drain；但
        %% 兜底处理）。
        {'DOWN', MRef, process, Pid, normal} -> done;
        {'DOWN', MRef, process, Pid, Reason} -> {error, {producer_died, Reason}}
    end.

%% 显式停止；幂等。不等 producer 实际清理完毕——producer 自己的 try/after
%% 会保证 cask_fold_release 在它退出前跑掉。
-spec stop(term()) -> ok.
stop(?STREAM(Pid, MRef)) ->
    Pid ! bitcask_stream_stop,
    erlang:demonitor(MRef, [flush]),
    ok.

%% 作用域包装：with_stream(Ref, fun(S) -> ... end) 自动管 stop。
%% 无论 Fun 正常返回还是抛异常，stop 都跑（try/after 保护）。
-spec with_stream(reference(), fun((term()) -> X)) -> X | {error, term()}.
with_stream(Ref, Fun) ->
    case stream(Ref) of
        {ok, S} ->
            try Fun(S)
            after stop(S)
            end;
        {error, _} = E ->
            E
    end.

%% =========================================================================
%% Producer 内部实现
%% =========================================================================

%% 启动 fold；成功就发 ready，进入主循环；失败就报错给 parent 后退出。
%% 关键：try/after 保证无论怎么退出 cask_fold_release 都跑。
producer_init(Ref, Parent) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1) of
        {ok, IterRef} ->
            ParentMon = erlang:monitor(process, Parent),
            Parent ! {bitcask_stream_ready, self()},
            try producer_loop(IterRef, ParentMon)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, Reason} ->
            Parent ! {bitcask_stream_error, self(), Reason}
    end.

%% 主循环：等 next 请求 / stop / consumer DOWN。
%% next 取到 done 或 error 之后转入 drain 状态——不再拉新数据，但保留
%% 进程响应能力，让 consumer 可以再调 next（拿到幂等的 done）或 stop。
producer_loop(IterRef, ParentMon) ->
    receive
        {bitcask_stream_next, From} ->
            case bitcask_cpp_nifs:cask_fold_next(IterRef) of
                done ->
                    From ! {bitcask_stream_done, self()},
                    drain_loop(ParentMon);
                {ok, K, V} ->
                    From ! {bitcask_stream_entry, self(), K, V},
                    producer_loop(IterRef, ParentMon);
                {error, Reason} ->
                    From ! {bitcask_stream_error, self(), Reason},
                    drain_loop(ParentMon)
            end;
        bitcask_stream_stop ->
            ok;
        {'DOWN', ParentMon, process, _, _} ->
            ok
    end.

%% 终态等待：producer 已经吃完 / 出错过，但保留进程响应 next（幂等返回
%% done）和 stop。consumer 不再用就靠 monitor 兜底退出。
drain_loop(ParentMon) ->
    receive
        {bitcask_stream_next, From} ->
            From ! {bitcask_stream_done, self()},
            drain_loop(ParentMon);
        bitcask_stream_stop ->
            ok;
        {'DOWN', ParentMon, process, _, _} ->
            ok
    end.
