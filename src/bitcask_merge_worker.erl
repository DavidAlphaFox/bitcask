%% =========================================================================
%% bitcask_merge_worker
%%
%%   merge 调度器（不是 merge 实现本身）。把目录级 merge 调用包成一个全局
%%   单例 gen_server，提供四件事：
%%
%%     1. **窗口**：merge_window 应用配置可以是
%%          always | never | {StartHour, EndHour}
%%        非工作时段直接拒绝（do_merge 会判断后跳过）。
%%     2. **去重**：同一目录的多个 merge 请求会在队列里合并参数（usort 排序
%%        Opts、合并 Files / Expired 列表），避免短时间内重复合并。
%%     3. **限流**：全局只允许一个 worker 子进程在跑，其他请求挂队列；
%%        worker 是 spawn_link 出去的临时进程，跑完正常退出，主 gen_server
%%        在 'EXIT' 里出队下一项。
%%     4. **日志**：每次 merge 跑完打印耗时（成功）或原因（失败）。
%%
%%   实际干活的就一行：apply(bitcask, merge, Args)——M6 之后这个 bitcask:merge/N
%%   只有 cask_cpp 一条路径，所以这里的 worker 自然走 C++ NIF。
%%
%%   API:
%%     start_link/0    — supervisor child spec 调用，启动注册到本地名 ?MODULE
%%     merge/1,2,3     — 提交一次 merge 请求，gen_server:call 同步入队
%%     status/0        — 返回 {QueueLen, WorkerPid|undefined}
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_merge_worker).

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% 对外 API
-export([start_link/0,
         merge/1, merge/2, merge/3,
         status/0]).

%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% 内部状态：
%%   queue  — pending 请求列表，元素形如 {Dir, Opts} 或 {Dir, Opts, Files}
%%   worker — 当前 spawn_link 出去的 merge 子进程 pid，无活时为 undefined
-record(state, { queue :: list(),
                 worker :: undefined | pid()}).

-include_lib("kernel/include/logger.hrl").

%% =========================================================================
%% 对外 API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% 三种重载分别对应 bitcask:merge/{1,2,3}：
%%   merge(Dir)               — 让 cask 自己决定要并什么
%%   merge(Dir, Opts)         — 同上，附加调用方给的阈值参数
%%   merge(Dir, Opts, Files)  — 显式指定要并的 {Files, Expired}（legacy 形态）
%%
%% 全部走 gen_server:call/3 同步入队，用 infinity 超时——merge 本身可能很久，
%% 调用方愿意等才提交。
merge(Dir) ->
    merge(Dir, []).

merge(Dir, Opts) ->
    gen_server:call(?MODULE, {merge, [Dir, Opts]}, infinity).

merge(Dir, Opts, Files) ->
    gen_server:call(?MODULE, {merge, [Dir, Opts, Files]}, infinity).

%% 返回 {QueueLen, WorkerPid}。WorkerPid 为 undefined 表示当前空闲。
status() ->
    gen_server:call(?MODULE, {status}, infinity).

%% =========================================================================
%% gen_server 回调
%% =========================================================================

init([]) ->
    %% trap_exit 是为了在 merge worker 子进程异常退出时收到 'EXIT' 消息，
    %% 不被它带挂。子进程 spawn_link，目的是让 merge 跑完把 ports / fd
    %% 之类资源都跟进程一起清掉，避免长时间运行的 gen_server 累积泄漏。
    process_flag(trap_exit, true),
    {ok, #state{ queue = [] }}.

%% 入队 / 去重 / 启动 worker。
handle_call({merge, Args0}, _From, #state { queue = Q } = State) ->
    %% Args0 是 [Dir, Opts] 或 [Dir, Opts, FilesArg]。两种形态的 Opts 都
    %% usort（merge_items 的 umerge 要求两边有序——以前 2 元形态漏了，
    %% 同目录合并时签名不稳、去重失效）；FilesArg 接受 bitcask:merge/3
    %% 认的全部形态：{Files, Expired} 二元组、裸 Files 列表、all。
    [Dirname|_] = Args0,
    Args1 =
        case Args0 of
            [_, Opts0, FilesArg] ->
                [Dirname, lists:usort(Opts0), normalize_files(FilesArg)];
            [_, Opts0] ->
                [Dirname, lists:usort(Opts0)]
        end,
    Args = list_to_tuple(Args1),
    %% queue 里以 Dir 为 key（tuple 第 1 个元素）做去重。
    case lists:keyfind(Dirname, 1, Q) of
        Args ->
            %% 完全相同的请求已经在队列里——直接告诉调用方 already_queued。
            {reply, already_queued, State};
        Partial when is_tuple(Partial) ->
            %% 同一 Dir 已经有 pending，但参数不同——合并它们
            %% （Opts 取并集、Files / Expired 取并集后去除已 expired 的）。
            New = merge_items(Args, Partial),
            Q1 = lists:keyreplace(Dirname, 1, Q, New),
            {reply, ok, State#state{ queue = Q1 }};
        false ->
            case State#state.worker of
                undefined ->
                    %% worker 空闲——立刻 spawn 干活
                    WorkerPid = spawn_link(fun() -> do_merge(Args1) end),
                    {reply, ok, State#state { worker = WorkerPid }};
                _ ->
                    %% worker 在忙——挂队列，等 'EXIT' 出队
                    {reply, ok, State#state { queue = Q ++ [Args] }}
            end
    end;
handle_call({status}, _From, #state { queue = Q, worker = Worker } = State) ->
    {reply, {length(Q), Worker}, State};
handle_call(_, _From, State) ->
    {reply, unknown_call, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% worker 正常结束：如果 queue 非空，pop 第一个继续跑。
handle_info({'EXIT', Pid, normal}, #state { worker = Pid } = State) ->
    {noreply, start_next(State)};

%% worker 非正常退出：记录，然后照常出队下一项。
%% 以前这里 {stop, State}——既不是合法的 gen_server 返回值（调度器自己
%% 以 bad_return_value 死掉），也会把队列里已经答复过 ok 的请求全丢掉；
%% 而 do_merge 早已 catch 住 bitcask:merge 的错误，能走到这里的只有
%% worker 进程本身被 kill 之类的外部原因，与其它目录的请求无关。
handle_info({'EXIT', Pid, Reason}, #state { worker = Pid } = State) ->
    ?LOG_ERROR("Merge worker ~p exited: ~p\n", [Pid, Reason]),
    {noreply, start_next(State)};

%% 其它 'EXIT'（不是当前 worker 的——比如 worker 换代后的迟到消息）和
%% 未知消息一律忽略，别让调度器为它们崩。
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% supervisor shutdown 时强制干掉在跑的 worker。catch 是因为 worker
    %% 可能已经先于我们退出。
    catch exit(State#state.worker, shutdown),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================================================================
%% 内部：出队 / 去重合并
%% =========================================================================

%% 当前 worker 已退出：队列非空就 spawn 下一项，否则回到空闲。
start_next(#state { queue = [] } = State) ->
    State#state { worker = undefined };
start_next(#state { queue = [Args0|Q2] } = State) ->
    Args = tuple_to_list(Args0),
    WorkerPid = spawn_link(fun() -> do_merge(Args) end),
    State#state { queue = Q2, worker = WorkerPid }.

%% merge/3 第三参归一：二元组与裸列表都变成有序的 {Files, Expired}
%% （bitcask:merge/3 两种都认）；all 原样保留。
normalize_files({Files, Expired}) when is_list(Files), is_list(Expired) ->
    {lists:usort(Files), lists:usort(Expired)};
normalize_files(Files) when is_list(Files) ->
    {lists:usort(Files), []};
normalize_files(all) ->
    all.

%% 把同 Dir 的两次请求合并成一条。Opts 取 umerge 并集（两边入队时都已
%% usort）；如果两边都是 3 元组（带 {Files, Expired}），Files / Expired 也取
%% 并集；如果一边 2 元一边 3 元，保留 3 元那一份的 Files / Expired
%% （信息量更全）。
merge_items(New, Old) ->
    Dirname = element(1, New),
    OOpts = element(2, Old),
    NOpts = element(2, New),
    Opts = lists:umerge(OOpts, NOpts),
    case {size(New), size(Old)} of
        {3, 3} ->
            Files = merge_files(element(3, New),
                                element(3, Old)),
            {Dirname, Opts, Files};
        {2, 2} ->
            {Dirname, Opts};
        {2, 3} ->
            {Dirname, Opts, element(3, Old)};
        {3, 2} ->
           {Dirname, Opts, element(3, New)}
    end.

%% Files / Expired 都是已排序列表（入队前 normalize_files 过）。合并后再把
%% 已知 expired 的从待 merge 列表里减掉——已经要删了就没必要再合并它们。
%% 任一边是 all（让 cask 自己挑）就取 all：它覆盖任何显式列表。
merge_files(all, _Old) -> all;
merge_files(_New, all) -> all;
merge_files(New, Old) ->
    {NFiles, NExp} = New,
    {OFiles, OExp} = Old,
    Files0 = lists:umerge(NFiles, OFiles),
    Expired = lists:umerge(NExp, OExp),
    %% O9：两边都是有序去重列表，ordsets:subtract 是 O(n+m)
    %% 的归并减法；`--` 是 O(n*m)，大目录（数百文件）下白白平方。
    Files = ordsets:subtract(Files0, Expired),
    {Files, Expired}.

%% =========================================================================
%% 内部：worker 子进程入口
%% =========================================================================

%% 在 spawn 出来的子进程里跑：
%%   1. 检查当前是否在 merge 窗口内；
%%   2. 在窗口内的话调 bitcask:merge/N，并记录耗时；
%%   3. 不在窗口内直接返回（不报错——这是「按调度策略跳过」，正常）。
do_merge(Args) ->
    {_, {Hour, _, _}} = calendar:local_time(),
    case in_merge_window(Hour, merge_window()) of
        true ->
            Start = os:timestamp(),
            Result = (catch apply(bitcask, merge, Args)),
            ElapsedSecs = timer:now_diff(os:timestamp(), Start) / 1000000,
            %% 日志只报目录：以前 [_,_,Args3] = Args 在 2 元形态上必
            %% badmatch——merge/1,2 经调度器走一次就崩一次 worker。
            Dir = hd(Args),
            case Result of
                ok ->
                    ?LOG_INFO("Merged ~p in ~p seconds.\n",
                                          [Dir, ElapsedSecs]);
                {Error, Reason} when Error == error; Error == 'EXIT' ->
                    ?LOG_ERROR("Failed to merge ~p: ~p\n",
                                           [Dir, Reason]);
                Other ->
                    ?LOG_ERROR("Failed to merge ~p: ~p\n",
                                           [Dir, Other])
            end;
        false ->
            ok
    end.

%% 读取 application env 里的 merge_window 配置；非法值（既非 atom 也非
%% 合理 {Start, End}）兜底为 always 并 log 一条警告——保守起见宁可多 merge。
merge_window() ->
    case application:get_env(bitcask, merge_window) of
        {ok, always} ->
            always;
        {ok, never} ->
            never;
        {ok, {StartHour, EndHour}} when StartHour >= 0, StartHour =< 23,
                                        EndHour >= 0, EndHour =< 23 ->
            {StartHour, EndHour};
        Other ->
            ?LOG_ERROR("Invalid bitcask_merge window specified: ~p. "
                                   "Defaulting to 'always'.\n", [Other]),
            always
    end.

%% 当前小时是否落在窗口里。窗口允许跨午夜（Start > End），例如
%% {22, 4} 表示 22:00 到次日 04:00。
in_merge_window(_NowHour, always) ->
    true;
in_merge_window(_NowHour, never) ->
    false;
in_merge_window(NowHour, {Start, End}) when Start =< End ->
    (NowHour >= Start) and (NowHour =< End);
in_merge_window(NowHour, {Start, End}) when Start > End ->
    (NowHour >= Start) or (NowHour =< End).


%% =========================================================================
%% 单元测试
%% =========================================================================

-ifdef(TEST).

%% 原来是 EQC 的 prop_in_window（仓库早就没有 eqc 依赖，从没跑过）。输入空间
%% 只有 24³ = 13824 种，直接穷举：窗口覆盖的小时集合与 in_merge_window/2 的
%% 判断逐一比对（含跨午夜的窗口）。
in_window_exhaustive_test() ->
    [begin
         EndTime = (StartTime + WindowLen) rem 24,
         WindowHours = [H rem 24 || H <- lists:seq(StartTime, StartTime + WindowLen)],
         ?assertEqual({NowHour, StartTime, EndTime, lists:member(NowHour, WindowHours)},
                      {NowHour, StartTime, EndTime,
                       in_merge_window(NowHour, {StartTime, EndTime})})
     end || NowHour <- lists:seq(0, 23), WindowLen <- lists:seq(0, 23),
            StartTime <- lists:seq(0, 23)],
    ok.

-endif.
