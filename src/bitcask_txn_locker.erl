%% =========================================================================
%% bitcask_txn_locker
%%
%%   事务协调层的锁管理器（doc/txn-layer-design-zh.md §3/§4，P2 前缀锁
%%   见 §12）。全局单例 gen_server，bitcask_sup 常驻 child，与
%%   bitcask_merge_worker 同级。干四件事：
%%
%%     1. **锁表**：两种粒度——点锁 {CaskRef, Key, point} 与前缀锁
%%        {CaskRef, Prefix, prefix}（覆盖以 Prefix 开头的全部 key，事务内
%%        range 扫描的幻读防护）。read/write 两种模式，兼容矩阵见 §4.3。
%%     2. **重叠冲突**：一个请求要和**所有重叠记录**上的 holder 比：自身、
%%        覆盖它的前缀记录（按现存前缀长度集合逐个查）、若它自己是前缀则
%%        还有它罩住的全部记录（ordered_set 一段顺序扫）。持有覆盖锁的事务
%%        再要被覆盖的锁**免费**（不建记录、不过锁表）。
%%     3. **死锁检测**：入队即检——从请求者出发沿 wait-for 图 DFS，回到
%%        自己即死锁，请求者作为受害者被中止（它是最新的那条边，中止它
%%        必破环）。wait-for 边**不单独存表**，由锁表按需推导：等待者 W
%%        等 (a) 重叠记录上与它冲突的 holder，(b) 重叠记录上比它**早到**
%%        （全局 seq 更小）且与它冲突的等待者——后者就是 FIFO 公平 / 防写
%%        饿死，跨记录也成立（前缀写等待者不会被源源不断的点锁请求饿死）。
%%        推导式的图永远与锁表一致，没有"边表漏删"这一类 bug。
%%     4. **清理**：注册时 monitor 调用进程，DOWN 即释放它的全部持有/等待
%%        并级联唤醒；每个等待有兜底计时器（lock_wait_timeout / 事务
%%        deadline 取小），到点按死锁处理。
%%
%%   授予的时机只有两处：请求时（立即可授予）和某条记录的 holder/等待者
%%   变动后的 wake_around/1：把该记录**重叠范围内**的全部等待者按 seq 依次
%%   重判，能授就授。
%%
%%   已持有某记录（任一重叠记录）的事务，等待者不挡它——这就是"唯一 holder
%%   升级越过队列"的推广：队列里的写在等它放读锁，不让它升级就是死锁。
%%
%%   死锁只在**入队**时检：授予不会造环（被授予者不再等任何人），
%%   删边（释放/死亡/中止）也不会。所以没有后台扫描线程。
%%
%%   为什么单实例：锁操作与检测需要一个全局串行点，Mnesia 的 mnesia_locker
%%   同样是单点且撑得住生产规模。分片留 P3。
%%
%%   ETS 表四张（protected、命名），status/0 直接读表不过 locker 进程：
%%     bitcask_txn_locks   #lock{}          ordered_set 按 LockId（前缀扫描要序）
%%     bitcask_txn_txns    #txn{}           按 TxnId
%%     bitcask_txn_held    {TxnId, LockId}  bag：事务持有的锁（释放时用）
%%     bitcask_txn_plens   {Len, Count}     现存前缀锁的长度集合（点请求只查这几个长度）
%%   全部写操作只发生在 locker 进程内。
%%   ⚠️ held 单独成表而不是 #txn{} 里的列表：ETS insert 是整条拷贝，列表
%%      放记录里意味着每拿一把新锁都把已持有的全部拷一遍——大事务
%%      （几百个 key）O(n²)，实测 100 边/事务比 1 边/事务还慢。
%%   无前缀锁时（plens 空）点锁路径的开销与纯点锁实现相同：只查自身一条。
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
-define(HELD,  bitcask_txn_held).
-define(PLENS, bitcask_txn_plens).

%% 单锁等待兜底上限（ms）。正常路径死锁检测必达，这只是防御。
-define(DEFAULT_LOCK_WAIT_TIMEOUT, 5000).

-type txn_id() :: pos_integer().
-type lock_id() :: {reference(), binary(), point | prefix}.
-type mode()    :: read | write.

%% 等待队列元素。from 是挂起的 gen_server:call；timer 是兜底计时器
%% （无上限时为 undefined）；seq 全局单调，决定跨记录的先来后到。
-record(waiter, {txn   :: txn_id(),
                 mode  :: mode(),
                 from  :: gen_server:from(),
                 timer :: undefined | reference(),
                 seq   :: pos_integer()}).

%% 锁：holders 是当前授予集合（多读者 或 单写者）；queue 按 seq 升序。
%% holders 与 queue 同时为空的记录会被删掉，不留垃圾。
-record(lock, {id      :: lock_id(),
               holders = #{} :: #{txn_id() => mode()},
               queue   = []  :: [#waiter{}]}).

%% 事务：waiting 是它当前阻塞在哪把锁上（推导 wait-for 边用），同一时刻
%% 最多等一把。持有的锁在 ?HELD 表里（见模块头）。
-record(txn, {id       :: txn_id(),
              pid      :: pid(),
              mon      :: reference(),
              deadline :: integer() | infinity,      % erlang:monotonic_time(ms)
              lock_wait_timeout :: timeout(),
              waiting  = undefined :: undefined | lock_id()}).

-record(state, {deadlocks = 0 :: non_neg_integer(),
                seq       = 0 :: non_neg_integer()}).

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
acquire(TxnId, {Ref, Bin, Kind} = LockId, Mode)
  when is_reference(Ref), is_binary(Bin),
       (Kind =:= point orelse Kind =:= prefix),
       (Mode =:= read orelse Mode =:= write) ->
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
                    locks => non_neg_integer(), prefix_locks => non_neg_integer(),
                    deadlocks_total => non_neg_integer()}.
status() ->
    Waiting = ets:select_count(?TXNS, [{#txn{waiting = '$1', _ = '_'},
                                        [{'=/=', '$1', undefined}], [true]}]),
    Prefix = lists:sum([C || {_Len, C} <- ets:tab2list(?PLENS)]),
    #{txns            => ets:info(?TXNS, size),
      waiting         => Waiting,
      locks           => ets:info(?LOCKS, size),
      prefix_locks    => Prefix,
      deadlocks_total => gen_server:call(?MODULE, deadlocks, infinity)}.

%% =========================================================================
%% gen_server 回调
%% =========================================================================

init([]) ->
    _ = ets:new(?LOCKS, [named_table, ordered_set, protected, {keypos, #lock.id}]),
    _ = ets:new(?TXNS,  [named_table, set, protected, {keypos, #txn.id}]),
    _ = ets:new(?HELD,  [named_table, bag, protected]),
    _ = ets:new(?PLENS, [named_table, set, protected]),
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
                    wake_around(LockId);
                {ok, W} ->
                    %% 引用不符：把它放回去（take 已经拿走了）。理论上不会发生——
                    %% waiting 与队列条目总是同步维护——防御而已。
                    requeue(LockId, W);
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
    Recs = overlapping(LockId),
    case covered(TxnId, Mode, Recs) of
        true ->
            %% 已持有覆盖它的锁（同一记录重入，或持有罩住它的前缀锁）：
            %% 免费，不建记录。
            {reply, ok, S};
        false ->
            Seq = S#state.seq + 1,
            S1 = S#state{seq = Seq},
            case blockers(TxnId, Mode, Seq, Recs) of
                [] ->
                    grant(TxnId, LockId, Mode),
                    {reply, ok, S1};
                _ ->
                    Timer = start_wait_timer(T, LockId),
                    W = #waiter{txn = TxnId, mode = Mode, from = From,
                                timer = Timer, seq = Seq},
                    requeue(LockId, W),
                    true = ets:insert(?TXNS, T#txn{waiting = LockId}),
                    case has_cycle(TxnId) of
                        false ->
                            {noreply, S1};
                        true ->
                            %% 受害者 = 请求者。出队、取消计时器、回复；它身后可能
                            %% 有人因此变得可授予，wake。
                            {ok, W1} = take_waiter(LockId, TxnId),
                            cancel_timer(W1#waiter.timer),
                            true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                            wake_around(LockId),
                            {reply, {error, deadlock},
                             S1#state{deadlocks = S1#state.deadlocks + 1}}
                    end
            end
    end.

%% 已持有的锁是否已经覆盖这次请求：write 覆盖一切，read 只覆盖 read。
covered(TxnId, Mode, Recs) ->
    lists:any(fun(#lock{holders = H}) ->
                      case maps:find(TxnId, H) of
                          {ok, write} -> true;
                          {ok, read}  -> Mode =:= read;
                          error       -> false
                      end
              end, Recs).

%% 挡住 (TxnId, Mode, Seq) 的事务：重叠记录上冲突的 holder ∪（自己不是任一
%% 重叠记录的 holder 时）比自己早到且冲突的等待者。空 = 可授予。
blockers(TxnId, Mode, Seq, Recs) ->
    IsHolder = lists:any(fun(#lock{holders = H}) -> maps:is_key(TxnId, H) end, Recs),
    Hs = [X || #lock{holders = H} <- Recs,
               {X, XM} <- maps:to_list(H),
               X =/= TxnId, conflicts(Mode, XM)],
    Ws = case IsHolder of
             true  -> [];
             false -> [X || #lock{queue = Q} <- Recs,
                            #waiter{txn = X, mode = XM, seq = XS} <- Q,
                            X =/= TxnId, XS < Seq, conflicts(Mode, XM)]
         end,
    lists:usort(Hs ++ Ws).

conflicts(read, read) -> false;
conflicts(_, _)       -> true.

%% 授予：更新 holders（read 升 write 只升不降），首次持有记进 ?HELD。
grant(TxnId, LockId, Mode) ->
    #lock{holders = H} = L = get_lock(LockId),
    {NewMode, First} =
        case maps:find(TxnId, H) of
            {ok, write} -> {write, false};
            {ok, read}  -> {Mode, false};
            error       -> {Mode, true}
        end,
    put_lock(L#lock{holders = H#{TxnId => NewMode}}),
    case First of
        true  -> true = ets:insert(?HELD, {TxnId, LockId});
        false -> ok
    end.

%% =========================================================================
%% 重叠记录：自身 + 覆盖它的前缀记录 +（自己是前缀时）它罩住的全部记录
%% =========================================================================

overlapping({Ref, Bin, Kind} = LockId) ->
    Size = byte_size(Bin),
    Lens = [Len || {Len, _} <- ets:tab2list(?PLENS),
                   Len < Size orelse (Len =:= Size andalso Kind =:= point)],
    Covering = lists:append([ets:lookup(?LOCKS, {Ref, binary_part(Bin, 0, Len), prefix})
                             || Len <- Lens]),
    Under = case Kind of
                point  -> ets:lookup(?LOCKS, LockId);
                prefix -> scan_under(Ref, Bin, ets:next(?LOCKS, {Ref, Bin, 0}), [])
            end,
    Covering ++ Under.

%% ordered_set 里从 {Ref, Bin, 0} 往后走：数字 < 原子，所以 {Ref,Bin,point} /
%% {Ref,Bin,prefix} 都在它之后；直到第二元素不再以 Bin 开头为止。
scan_under(Ref, Bin, {Ref, B, _} = K, Acc) when byte_size(B) >= byte_size(Bin) ->
    Size = byte_size(Bin),
    case B of
        <<Bin:Size/binary, _/binary>> ->
            scan_under(Ref, Bin, ets:next(?LOCKS, K), ets:lookup(?LOCKS, K) ++ Acc);
        _ ->
            Acc
    end;
scan_under(_Ref, _Bin, _K, Acc) ->
    Acc.

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

%% N 在等谁：不在等 → []；否则按它的等待条目重算 blockers。
blockers_of(N) ->
    case ets:lookup(?TXNS, N) of
        [#txn{waiting = LockId}] when LockId =/= undefined ->
            case find_waiter(LockId, N) of
                #waiter{mode = Mode, seq = Seq} ->
                    blockers(N, Mode, Seq, overlapping(LockId));
                false ->
                    []
            end;
        _ ->
            []
    end.

find_waiter(LockId, TxnId) ->
    case ets:lookup(?LOCKS, LockId) of
        [#lock{queue = Q}] -> lists:keyfind(TxnId, #waiter.txn, Q);
        []                 -> false
    end.

%% =========================================================================
%% 释放 / 唤醒
%% =========================================================================

%% 事务彻底退出：出队（若在等）、放全部持有锁并逐把 wake、删记录。
drop_txn(#txn{id = TxnId, waiting = Waiting}) ->
    case Waiting of
        undefined -> ok;
        LockId ->
            case take_waiter(LockId, TxnId) of
                {ok, W} ->
                    cancel_timer(W#waiter.timer),
                    %% 调用方要么已经死了（DOWN），要么就是它自己在调 release_all
                    %% （那它不可能同时挂在 acquire 里）——回复只是为了不泄漏 From。
                    catch gen_server:reply(W#waiter.from, {error, unknown_txn}),
                    wake_around(LockId);
                error -> ok
            end
    end,
    lists:foreach(fun({_, LockId}) -> release_one(LockId, TxnId) end,
                  ets:take(?HELD, TxnId)),
    true = ets:delete(?TXNS, TxnId),
    ok.

release_one(LockId, TxnId) ->
    case ets:lookup(?LOCKS, LockId) of
        [] -> ok;
        [#lock{holders = H} = L] ->
            put_lock(L#lock{holders = maps:remove(TxnId, H)}),
            wake_around(LockId)
    end.

%% LockId 附近的状态变了：把重叠范围内的全部等待者按 seq 依次重判。
%% 每授予一个都会改变后面人的判定，所以逐个重算（等待者通常个位数）。
wake_around(LockId) ->
    Ws = lists:sort(fun(#waiter{seq = A}, #waiter{seq = B}) -> A =< B end,
                    lists:append([Q || #lock{queue = Q} <- overlapping(LockId)])),
    lists:foreach(fun(W) -> try_wake(W) end, Ws).

try_wake(#waiter{txn = TxnId, mode = Mode, seq = Seq, timer = Timer, from = From}) ->
    case ets:lookup(?TXNS, TxnId) of
        [#txn{waiting = LockId} = T] when LockId =/= undefined ->
            case expired(T) of
                true ->
                    {ok, _} = take_waiter(LockId, TxnId),
                    cancel_timer(Timer),
                    true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                    gen_server:reply(From, {error, timeout});
                false ->
                    case blockers(TxnId, Mode, Seq, overlapping(LockId)) of
                        [] ->
                            {ok, _} = take_waiter(LockId, TxnId),
                            cancel_timer(Timer),
                            true = ets:insert(?TXNS, T#txn{waiting = undefined}),
                            grant(TxnId, LockId, Mode),
                            gen_server:reply(From, ok);
                        _ ->
                            ok
                    end
            end;
        _ ->
            ok
    end.

%% =========================================================================
%% 锁记录读写（含空记录 GC 与前缀长度集合维护）
%% =========================================================================

get_lock(LockId) ->
    case ets:lookup(?LOCKS, LockId) of
        []  -> #lock{id = LockId};
        [L] -> L
    end.

%% 写回记录：空了就删（前缀记录同步维护 ?PLENS）。
put_lock(#lock{id = Id, holders = H, queue = []}) when map_size(H) =:= 0 ->
    case ets:member(?LOCKS, Id) of
        true  -> true = ets:delete(?LOCKS, Id), plen_dec(Id);
        false -> ok
    end;
put_lock(#lock{id = Id} = L) ->
    case ets:member(?LOCKS, Id) of
        true  -> ok;
        false -> plen_inc(Id)
    end,
    true = ets:insert(?LOCKS, L).

plen_inc({_, Bin, prefix}) ->
    _ = ets:update_counter(?PLENS, byte_size(Bin), 1, {byte_size(Bin), 0}), ok;
plen_inc(_) -> ok.

plen_dec({_, Bin, prefix}) ->
    case ets:update_counter(?PLENS, byte_size(Bin), -1) of
        0 -> true = ets:delete(?PLENS, byte_size(Bin)), ok;
        _ -> ok
    end;
plen_dec(_) -> ok.

%% 把 TxnId 的等待条目从锁队列里摘出来。
take_waiter(LockId, TxnId) ->
    case ets:lookup(?LOCKS, LockId) of
        [] -> error;
        [#lock{queue = Q} = L] ->
            case lists:keytake(TxnId, #waiter.txn, Q) of
                false -> error;
                {value, W, Rest} ->
                    put_lock(L#lock{queue = Rest}),
                    {ok, W}
            end
    end.

%% 入队（队列按 seq 升序）。
requeue(LockId, W) ->
    L = get_lock(LockId),
    Q = lists:sort(fun(#waiter{seq = A}, #waiter{seq = B}) -> A =< B end,
                   [W | L#lock.queue]),
    put_lock(L#lock{queue = Q}).

%% =========================================================================
%% 小工具
%% =========================================================================

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
