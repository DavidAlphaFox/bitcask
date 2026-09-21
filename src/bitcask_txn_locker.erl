%% =========================================================================
%% bitcask_txn_locker
%%
%%   事务协调层的锁管理器（doc/txn-layer-design-zh.md §3/§4）。全局单例
%%   gen_server，bitcask_sup 常驻 child，与 bitcask_merge_worker 同级。
%%   干四件事：
%%
%%     1. **锁表**：点锁（LockId = {CaskRef, Key}），read/write 两种模式，
%%        兼容矩阵见 §4.3。同一事务重入、读锁升级都在这里判。
%%     2. **等待队列**：FIFO；连续读段合并授予；新读请求若队列里已有写
%%        等待者必须排队尾（防写饿死）。
%%     3. **死锁检测**：入队即检——从请求者出发沿 wait-for 图 DFS，回到
%%        自己即死锁，请求者作为受害者被中止（它是最新的那条边，中止它
%%        必破环）。wait-for 边**不单独存表**，由锁表按需推导：等待者 W
%%        等 (a) 与它冲突的当前 holder，(b) 队列里排在它前面且与它冲突的
%%        请求者。推导式的图永远与锁表一致，没有"边表漏删"这一类 bug。
%%     4. **清理**：注册时 monitor 调用进程，DOWN 即释放它的全部持有/等待
%%        并级联唤醒；每个等待有兜底计时器（lock_wait_timeout / 事务
%%        deadline 取小），到点按死锁处理。
%%
%%   授予的时机只有两处：请求时（立即可授予）和某个 holder 释放后的
%%   wake/1。wake 从队首扫：队首可授予就授予并继续看下一个（读段合并），
%%   否则停——所以写请求授予后下一轮必停，读请求后面跟写也停。
%%
%%   死锁只在**入队**时检：授予不会造环（被授予者不再等任何人），
%%   删边（释放/死亡/中止）也不会。所以没有后台扫描线程。
%%
%%   为什么单实例：锁操作与检测需要一个全局串行点，Mnesia 的 mnesia_locker
%%   同样是单点且撑得住生产规模。分片留 P3。
%%
%%   ETS 表两张（protected、命名），status/0 直接读表不过 locker 进程：
%%     bitcask_txn_locks  #lock{}  按 LockId
%%     bitcask_txn_txns   #txn{}   按 TxnId
%%   全部写操作只发生在 locker 进程内。
%%
%%   API（全部由 bitcask_txn 门面调用，不面向用户）：
%%     register(Pid, Opts)             -> {ok, TxnId}
%%     acquire(TxnId, LockId, Mode)    -> ok | {error, deadlock | lock_wait_timeout
%%                                            | timeout | unknown_txn}
%%     check(TxnId)                    -> ok | {error, timeout | unknown_txn}
%%     release_all(TxnId)              -> ok          （幂等）
%%     status()                        -> map()
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_txn_locker).

-behaviour(gen_server).

-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-include_lib("pulse_otp/include/pulse_otp.hrl").
-endif.

-export([start_link/0,
         register/2, acquire/3, check/1, release_all/1,
         status/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LOCKS, bitcask_txn_locks).
-define(TXNS,  bitcask_txn_txns).

%% 单锁等待兜底上限（ms）。正常路径死锁检测必达，这只是防御。
-define(DEFAULT_LOCK_WAIT_TIMEOUT, 5000).

-type txn_id() :: pos_integer().
-type lock_id() :: term().
-type mode()    :: read | write.

%% 等待队列元素。from 是挂起的 gen_server:call；timer 是兜底计时器
%% （无上限时为 undefined）。
-record(waiter, {txn   :: txn_id(),
                 mode  :: mode(),
                 from  :: gen_server:from(),
                 timer :: undefined | reference()}).

%% 锁：holders 是当前授予集合（多读者 或 单写者）；queue FIFO。
%% holders 与 queue 同时为空的锁会被删掉，不留垃圾。
-record(lock, {id      :: lock_id(),
               holders = #{} :: #{txn_id() => mode()},
               queue   = []  :: [#waiter{}]}).

%% 事务：held 是它持有的锁（释放时用，不必扫全表）；waiting 是它当前
%% 阻塞在哪把锁上（推导 wait-for 边用），同一时刻最多等一把。
-record(txn, {id       :: txn_id(),
              pid      :: pid(),
              mon      :: reference(),
              deadline :: integer() | infinity,      % erlang:monotonic_time(ms)
              lock_wait_timeout :: timeout(),
              held     = [] :: [lock_id()],
              waiting  = undefined :: undefined | lock_id()}).

-record(state, {deadlocks = 0 :: non_neg_integer()}).

%% =========================================================================
%% API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Opts :: #{deadline => integer() | infinity,      %% monotonic ms，缺省 infinity
%%           lock_wait_timeout => timeout()}         %% 缺省 5000
-spec register(pid(), map()) -> {ok, txn_id()}.
register(Pid, Opts) when is_pid(Pid), is_map(Opts) ->
    gen_server:call(?MODULE, {register, Pid, Opts}, infinity).

%% 阻塞直到授予或失败。超时全在 locker 侧管（兜底计时器），所以这里 infinity。
-spec acquire(txn_id(), lock_id(), mode()) ->
          ok | {error, deadlock | lock_wait_timeout | timeout | unknown_txn}.
acquire(TxnId, LockId, Mode) when Mode =:= read; Mode =:= write ->
    gen_server:call(?MODULE, {acquire, TxnId, LockId, Mode}, infinity).

%% 提交前校验：事务还活着、没过 deadline。
-spec check(txn_id()) -> ok | {error, timeout | unknown_txn}.
check(TxnId) ->
    gen_server:call(?MODULE, {check, TxnId}, infinity).

%% 释放事务的全部锁并注销。未知事务直接 ok（幂等，门面的 after 段可以放心调）。
-spec release_all(txn_id()) -> ok.
release_all(TxnId) ->
    gen_server:call(?MODULE, {release_all, TxnId}, infinity).

%% 直接读 ETS，不过 locker 进程——观测不挡锁操作。
-spec status() -> #{txns => non_neg_integer(), waiting => non_neg_integer(),
                    locks => non_neg_integer(), deadlocks_total => non_neg_integer()}.
status() ->
    Waiting = ets:select_count(?TXNS, [{#txn{waiting = '$1', _ = '_'},
                                        [{'=/=', '$1', undefined}], [true]}]),
    #{txns            => ets:info(?TXNS, size),
      waiting         => Waiting,
      locks           => ets:info(?LOCKS, size),
      deadlocks_total => gen_server:call(?MODULE, deadlocks, infinity)}.

%% =========================================================================
%% gen_server 回调
%% =========================================================================

init([]) ->
    _ = ets:new(?LOCKS, [named_table, set, protected, {keypos, #lock.id}]),
    _ = ets:new(?TXNS,  [named_table, set, protected, {keypos, #txn.id}]),
    {ok, #state{}}.

handle_call({register, Pid, Opts}, _From, S) ->
    TxnId = erlang:unique_integer([positive]),
    Mon = erlang:monitor(process, Pid),
    T = #txn{id = TxnId, pid = Pid, mon = Mon,
             deadline = maps:get(deadline, Opts, infinity),
             lock_wait_timeout = maps:get(lock_wait_timeout, Opts,
                                          ?DEFAULT_LOCK_WAIT_TIMEOUT)},
    true = ets:insert(?TXNS, T),
    {reply, {ok, TxnId}, S};

handle_call({acquire, TxnId, LockId, Mode}, From, S) ->
    case ets:lookup(?TXNS, TxnId) of
        [] ->
            {reply, {error, unknown_txn}, S};
        [T] ->
            case expired(T) of
                true  -> {reply, {error, timeout}, S};
                false -> do_acquire(T, LockId, Mode, From, S)
            end
    end;

handle_call({check, TxnId}, _From, S) ->
    Reply = case ets:lookup(?TXNS, TxnId) of
                []  -> {error, unknown_txn};
                [T] -> case expired(T) of
                           true  -> {error, timeout};
                           false -> ok
                       end
            end,
    {reply, Reply, S};

handle_call({release_all, TxnId}, _From, S) ->
    case ets:lookup(?TXNS, TxnId) of
        [] ->
            ok;
        [T] ->
            erlang:demonitor(T#txn.mon, [flush]),
            drop_txn(T)
    end,
    {reply, ok, S};

handle_call(deadlocks, _From, S) ->
    {reply, S#state.deadlocks, S};

handle_call(_Req, _From, S) ->
    {reply, {error, bad_request}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

%% 调用进程死了：它持有的全放、等待的出队、级联唤醒。
handle_info({'DOWN', Mon, process, _Pid, _Reason}, S) ->
    case ets:match_object(?TXNS, #txn{mon = Mon, _ = '_'}) of
        [T] -> drop_txn(T);
        []  -> ok
    end,
    {noreply, S};

%% 等待兜底计时器到点。计时器引用必须与队列里那条一致，否则是过期消息
%% （已授予/已出队后残留的），直接忽略。
handle_info({timeout, TRef, {lock_wait, TxnId, LockId}}, S) ->
    case ets:lookup(?TXNS, TxnId) of
        [#txn{waiting = LockId} = T] ->
            case take_waiter(LockId, TxnId) of
                {ok, #waiter{timer = TRef, from = From}} ->
                    Reply = case expired(T) of
                                true  -> {error, timeout};
                                false -> {error, lock_wait_timeout}
                            end,
                    gen_server:reply(From, Reply),
                    true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                    wake(LockId);
                {ok, W} ->
                    %% 引用不符：把它放回去（take 已经拿走了）。理论上不会发生——
                    %% waiting 与队列条目总是同步维护——防御而已。
                    requeue_front(LockId, W);
                error ->
                    ok
            end;
        _ ->
            ok
    end,
    {noreply, S};

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% =========================================================================
%% 加锁
%% =========================================================================

do_acquire(#txn{id = TxnId} = T, LockId, Mode, From, S) ->
    L = get_lock(LockId),
    case grantable_now(TxnId, Mode, L) of
        true ->
            grant(T, L, Mode),
            {reply, ok, S};
        false ->
            Timer = start_wait_timer(T, LockId),
            W = #waiter{txn = TxnId, mode = Mode, from = From, timer = Timer},
            true = ets:insert(?LOCKS, L#lock{queue = L#lock.queue ++ [W]}),
            true = ets:insert(?TXNS, T#txn{waiting = LockId}),
            case has_cycle(TxnId) of
                false ->
                    {noreply, S};
                true ->
                    %% 受害者 = 请求者。出队、取消计时器、回复；它身后可能
                    %% 有人因此变得可授予（例如它是插在读者前面的写），wake。
                    {ok, W1} = take_waiter(LockId, TxnId),
                    cancel_timer(W1#waiter.timer),
                    true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                    wake(LockId),
                    {reply, {error, deadlock},
                     S#state{deadlocks = S#state.deadlocks + 1}}
            end
    end.

%% 请求时可否立即授予：
%%   - 已持 write               → 任何请求都重入
%%   - 已持 read，请求 read     → 重入
%%   - 已持 read，请求 write    → 自己是唯一 holder 才能升级（越过队列：
%%                                队列里的写在等自己，不让它升级就是死锁）
%%   - 未持有                   → 队列必须为空（防写饿死：读也不准插队）
%%                                且与现有 holders 兼容
grantable_now(TxnId, Mode, #lock{holders = H, queue = Q}) ->
    case maps:find(TxnId, H) of
        {ok, _}  -> grantable(TxnId, Mode, H);
        error    -> Q =:= [] andalso grantable(TxnId, Mode, H)
    end.

%% 忽略队列的兼容判断（队首唤醒时用；请求时套在队列条件之后）。
grantable(TxnId, Mode, H) ->
    case maps:find(TxnId, H) of
        {ok, write}             -> true;
        {ok, read}              -> Mode =:= read orelse map_size(H) =:= 1;
        error when Mode =:= read  -> not has_writer(H);
        error when Mode =:= write -> map_size(H) =:= 0
    end.

has_writer(H) ->
    lists:member(write, maps:values(H)).

%% 授予：更新 holders（read 升 write 只升不降），首次持有记进 held。
grant(#txn{id = TxnId} = T, #lock{holders = H} = L, Mode) ->
    {NewMode, First} =
        case maps:find(TxnId, H) of
            {ok, write} -> {write, false};
            {ok, read}  -> {Mode, false};
            error       -> {Mode, true}
        end,
    true = ets:insert(?LOCKS, L#lock{holders = H#{TxnId => NewMode}}),
    case First of
        true  -> true = ets:insert(?TXNS, T#txn{held = [L#lock.id | T#txn.held]});
        false -> ok
    end.

%% =========================================================================
%% 死锁检测：从 Start 出发沿推导边 DFS，再碰到 Start 即有环
%% =========================================================================

has_cycle(Start) ->
    search([Start], #{Start => true}, Start).

search([], _Seen, _Start) ->
    false;
search([N | Rest], Seen, Start) ->
    Bs = blockers_of(N),
    case lists:member(Start, Bs) of
        true ->
            true;
        false ->
            New = [B || B <- Bs, not maps:is_key(B, Seen)],
            Seen1 = lists:foldl(fun(B, Acc) -> Acc#{B => true} end, Seen, New),
            search(New ++ Rest, Seen1, Start)
    end.

%% N 在等谁：不在等 → []；否则 = 冲突 holder ∪ 队列里排它前面的冲突请求者。
blockers_of(N) ->
    case ets:lookup(?TXNS, N) of
        [#txn{waiting = undefined}] -> [];
        [#txn{waiting = LockId}] ->
            case ets:lookup(?LOCKS, LockId) of
                [] -> [];
                [#lock{holders = H, queue = Q}] ->
                    case lists:keyfind(N, #waiter.txn, Q) of
                        false -> [];
                        #waiter{mode = Mode} ->
                            Ahead = lists:takewhile(
                                      fun(#waiter{txn = X}) -> X =/= N end, Q),
                            [X || {X, XM} <- maps:to_list(H),
                                  X =/= N, conflicts(Mode, XM)]
                            ++ [X || #waiter{txn = X, mode = XM} <- Ahead,
                                     conflicts(Mode, XM)]
                    end
            end;
        [] -> []
    end.

conflicts(read, read) -> false;
conflicts(_, _)       -> true.

%% =========================================================================
%% 释放 / 唤醒
%% =========================================================================

%% 事务彻底退出：出队（若在等）、放全部持有锁并逐把 wake、删记录。
drop_txn(#txn{id = TxnId, held = Held, waiting = Waiting}) ->
    case Waiting of
        undefined -> ok;
        LockId ->
            case take_waiter(LockId, TxnId) of
                {ok, W} ->
                    cancel_timer(W#waiter.timer),
                    %% 调用方要么已经死了（DOWN），要么就是它自己在调 release_all
                    %% （那它不可能同时挂在 acquire 里）——回复只是为了不泄漏 From。
                    catch gen_server:reply(W#waiter.from, {error, unknown_txn}),
                    wake(LockId);
                error -> ok
            end
    end,
    lists:foreach(fun(LockId) -> release_one(LockId, TxnId) end, Held),
    true = ets:delete(?TXNS, TxnId),
    ok.

release_one(LockId, TxnId) ->
    case ets:lookup(?LOCKS, LockId) of
        [] -> ok;
        [#lock{holders = H} = L] ->
            true = ets:insert(?LOCKS, L#lock{holders = maps:remove(TxnId, H)}),
            wake(LockId)
    end.

%% 从队首扫可授予段：授予一个看下一个，不可授予即停；无 holder 无等待就删锁。
wake(LockId) ->
    case ets:lookup(?LOCKS, LockId) of
        [] -> ok;
        [#lock{holders = H, queue = []}] when map_size(H) =:= 0 ->
            true = ets:delete(?LOCKS, LockId), ok;
        [#lock{queue = []}] -> ok;
        [#lock{holders = H, queue = [#waiter{txn = TxnId, mode = Mode} = W | Rest]} = L] ->
            case ets:lookup(?TXNS, TxnId) of
                [] ->
                    %% 不该出现（drop_txn 会先出队），防御：丢掉这条继续。
                    true = ets:insert(?LOCKS, L#lock{queue = Rest}),
                    wake(LockId);
                [T] ->
                    case expired(T) of
                        true ->
                            cancel_timer(W#waiter.timer),
                            gen_server:reply(W#waiter.from, {error, timeout}),
                            true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                            true = ets:insert(?LOCKS, L#lock{queue = Rest}),
                            wake(LockId);
                        false ->
                            case grantable(TxnId, Mode, H) of
                                true ->
                                    cancel_timer(W#waiter.timer),
                                    true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                                    %% grant 读的是 ETS 里的 txn 记录，先把 waiting 清掉再授予
                                    [T1] = ets:lookup(?TXNS, TxnId),
                                    grant(T1, L#lock{queue = Rest}, Mode),
                                    gen_server:reply(W#waiter.from, ok),
                                    wake(LockId);
                                false ->
                                    ok
                            end
                    end
            end
    end.

%% =========================================================================
%% 小工具
%% =========================================================================

get_lock(LockId) ->
    case ets:lookup(?LOCKS, LockId) of
        []  -> #lock{id = LockId};
        [L] -> L
    end.

%% 把 TxnId 的等待条目从锁队列里摘出来。
take_waiter(LockId, TxnId) ->
    case ets:lookup(?LOCKS, LockId) of
        [] -> error;
        [#lock{queue = Q} = L] ->
            case lists:keytake(TxnId, #waiter.txn, Q) of
                false -> error;
                {value, W, Rest} ->
                    true = ets:insert(?LOCKS, L#lock{queue = Rest}),
                    {ok, W}
            end
    end.

requeue_front(LockId, W) ->
    L = get_lock(LockId),
    true = ets:insert(?LOCKS, L#lock{queue = [W | L#lock.queue]}).

expired(#txn{deadline = infinity}) -> false;
expired(#txn{deadline = D})        -> erlang:monotonic_time(millisecond) >= D.

%% 等待兜底：lock_wait_timeout 与 deadline 剩余量取小；两者都无界则不设。
start_wait_timer(#txn{id = TxnId, deadline = D, lock_wait_timeout = LWT}, LockId) ->
    Remaining = case D of
                    infinity -> infinity;
                    _ -> max(0, D - erlang:monotonic_time(millisecond))
                end,
    case min_timeout(LWT, Remaining) of
        infinity -> undefined;
        Ms -> erlang:start_timer(Ms, self(), {lock_wait, TxnId, LockId})
    end.

min_timeout(infinity, B) -> B;
min_timeout(A, infinity) -> A;
min_timeout(A, B)        -> min(A, B).

cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    %% 可能已经发出（在信箱里）——留给 handle_info 按引用匹配后忽略。
    ok.
