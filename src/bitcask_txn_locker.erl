%% =========================================================================
%% bitcask_txn_locker
%%
%%   事务协调层的锁管理器（doc/txn-layer-design-zh.md §3/§4，前缀锁 §12，
%%   分片 §13）。N 个分片 gen_server（bitcask_txn_locker_sup 之下，
%%   one_for_all），点锁按 {CaskRef, Key} 哈希落到一个分片；干四件事：
%%
%%     1. **锁表**：两种粒度——点锁 {CaskRef, Key, point} 与前缀锁
%%        {CaskRef, Prefix, prefix}（覆盖以 Prefix 开头的全部 key，事务内
%%        range 扫描的幻读防护）。read/write 两种模式，兼容矩阵见 §4.3。
%%        **前缀锁在每个分片上各拿一份**（按分片序依次 acquire），于是任一
%%        分片判点锁时只看自己的表就够了——分片之间没有锁语义上的交互。
%%     2. **重叠冲突**：一个请求要和**所有重叠记录**上的 holder 比：自身、
%%        覆盖它的前缀记录（按现存前缀长度集合逐个查）、若它自己是前缀则
%%        还有它罩住的全部记录（ordered_set 一段顺序扫）。持有覆盖锁的事务
%%        再要被覆盖的锁**免费**（不建记录、不过锁表）。
%%     3. **死锁检测**：入队即检——从请求者出发沿 wait-for 图 DFS，回到
%%        自己即死锁。**受害者 = 环上最年轻的事务**（age 最大；age 在门面
%%        里一次 transaction 调用内跨重跑保持不变，同 Mnesia 重启保 Tid）：
%%        最老的事务永远不会被牺牲，所以长事务不会被源源不断的短事务反复
%%        打断——有进展保证。受害者是请求者就地回复 {error, deadlock}；在
%%        本分片等的直接出队回复；在别的分片等的 cast 过去中止（那边核对它
%%        仍在等同一把锁才动手，否则环已自行解开）。
%%        wait-for 边**不单独存表**，由锁表按需推导：等待者 W
%%        等 (a) 重叠记录上与它冲突的 holder，(b) 重叠记录上比它**早到**
%%        （全局 seq 更小）且与它冲突的等待者——后者就是 FIFO 公平 / 防写
%%        饿死，跨记录也成立。DFS 会跨分片：某事务在别的分片上等，就读那个
%%        分片的表（protected，谁都能读）。跨分片读到的是无锁快照——
%%        ⚠️ 正确性论证：每个分片都是**先写边（入队 + 写 waiting）再检**，
%%        两个分片并发各加一条边时，后开始检的那个必看见先写的那条，所以环
%%        至少被一方检出；过期快照最多造成**误报**（多重跑一次，安全）。
%%     4. **清理**：注册时**归属分片**（hash(TxnId)）monitor 调用进程，DOWN
%%        即向全部分片 cast drop（分片之间**只 cast 不 call**——两个分片互相
%%        call 就是分布式死锁），各分片放自己那份持有/等待；每个等待有兜底
%%        计时器（lock_wait_timeout / 事务 deadline 取小），到点按死锁处理。
%%
%%   正常路径的释放由**调用进程**驱动（release_all）：按 held 表分组，逐个
%%   分片 call，最后到归属分片注销——调用方不是分片，call 不会互锁。
%%
%%   授予的时机只有两处：请求时（立即可授予）和某条记录的 holder/等待者
%%   变动后的 wake_around/2：把该记录**重叠范围内**的全部等待者按 seq 依次
%%   重判，能授就授。
%%
%%   已持有某记录（任一重叠记录）的事务，等待者不挡它——这就是"唯一 holder
%%   升级越过队列"的推广：队列里的写在等它放读锁，不让它升级就是死锁。
%%
%%   死锁只在**入队**时检：授予不会造环（被授予者不再等任何人），
%%   删边（释放/死亡/中止）也不会。所以没有后台扫描线程。
%%
%%   为什么分片：单 locker 实测 ~20k txn/s 且 P=1..8 不随并发增长（每事务
%%   ~8 次 gen_server:call 全串行），而引擎自己 P=8 能到 44k——锁管理器成了
%%   天花板。分片数 application env {txn_locker_shards, N}，默认 8；
%%   ⚠️ 不按 schedulers_online 推：开发机 BEAM 看到的是宿主 128 核。
%%
%%   ETS：
%%     共享（tables 进程持有，public）：
%%       bitcask_txn_txns    #txn{}                 按 TxnId；waiting = {Shard, LockId}
%%       bitcask_txn_held    {TxnId, Shard, LockId} bag：事务持有的锁（释放时按分片分组）
%%       bitcask_txn_stats   {Key, Count}
%%     每分片（分片进程持有，protected；名字带下标）：
%%       bitcask_txn_locks_I #lock{}                ordered_set 按 LockId（前缀扫描要序）
%%       bitcask_txn_plens_I {Len, Count}           现存前缀锁的长度集合
%%   ⚠️ held 单独成表而不是 #txn{} 里的列表：ETS insert 是整条拷贝，列表
%%      放记录里意味着每拿一把新锁都把已持有的全部拷一遍——大事务
%%      （几百个 key）O(n²)，实测 100 边/事务比 1 边/事务还慢。
%%   无前缀锁时（plens 空）点锁路径的开销与纯点锁实现相同：只查自身一条。
%%
%%   API（全部由 bitcask_txn 门面调用，不面向用户）：
%%     register(Pid, Opts)             -> {ok, TxnId}
%%     acquire(TxnId, LockId, Mode)    -> ok | {error, deadlock | lock_wait_timeout
%%                                            | timeout | unknown_txn}
%%     check(TxnId)                    -> ok | {error, timeout | unknown_txn}   （直读 ETS）
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

-export([start_link/1, shard_count/0, shard_of/1,
         register/2, acquire/3, check/1, release_all/1,
         status/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TXNS,  bitcask_txn_txns).
-define(HELD,  bitcask_txn_held).
-define(STATS, bitcask_txn_stats).
-define(PT,    {?MODULE, shards}).          % persistent_term: {N, ShardNames, Tabs}

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

%% 事务：waiting 是它当前阻塞在哪个分片的哪把锁上（推导 wait-for 边用），
%% 同一时刻最多等一把。持有的锁在 ?HELD 表里（见模块头）。
-record(txn, {id       :: txn_id(),
              pid      :: pid(),
              mon      :: reference(),
              age      :: pos_integer(),             % 越小越老；重跑不变
              deadline :: integer() | infinity,      % erlang:monotonic_time(ms)
              lock_wait_timeout :: timeout(),
              waiting  = undefined :: undefined | {pos_integer(), lock_id()}}).

%% 一个分片的表句柄；persistent_term 里按下标存一份，跨分片 DFS 用。
-record(tabs, {idx :: pos_integer(), locks :: atom(), plens :: atom()}).

-record(state, {tabs    :: #tabs{},
                waiting = #{} :: #{txn_id() => lock_id()}}).   % 在本分片等的事务

%% =========================================================================
%% 启动
%% =========================================================================

%% {tables, N}：共享表持有者，并把分片拓扑写进 persistent_term；
%% {shard, I}：第 I 个分片。都由 bitcask_txn_locker_sup 拉起（tables 在前）。
start_link({tables, N}) when is_integer(N), N >= 1 ->
    gen_server:start_link({local, bitcask_txn_locker_tables}, ?MODULE, {tables, N}, []);
start_link({shard, I}) when is_integer(I), I >= 1 ->
    gen_server:start_link({local, shard_name(I)}, ?MODULE, {shard, I}, []).

shard_name(I) -> list_to_atom("bitcask_txn_locker_" ++ integer_to_list(I)).

shard_tabs(I) ->
    #tabs{idx   = I,
          locks = list_to_atom("bitcask_txn_locks_" ++ integer_to_list(I)),
          plens = list_to_atom("bitcask_txn_plens_" ++ integer_to_list(I))}.

-spec shard_count() -> pos_integer().
shard_count() -> element(1, persistent_term:get(?PT)).

shard(I)  -> element(I, element(2, persistent_term:get(?PT))).
tabs(I)   -> element(I, element(3, persistent_term:get(?PT))).

%% 点锁按 {Ref, Key} 哈希；事务归属按 TxnId 哈希。
shard_of_key(Ref, Bin) -> erlang:phash2({Ref, Bin}, shard_count()) + 1.
home_of(TxnId)         -> erlang:phash2(TxnId, shard_count()) + 1.

%% 一把点锁落在哪个分片（观测 / 测试用；前缀锁在每个分片都有，返回 all）。
-spec shard_of(lock_id()) -> pos_integer() | all.
shard_of({Ref, Bin, point})  -> shard_of_key(Ref, Bin);
shard_of({_, _, prefix})     -> all.

%% =========================================================================
%% API
%% =========================================================================

%% Opts :: #{deadline => integer() | infinity,      %% monotonic ms，缺省 infinity
%%           lock_wait_timeout => timeout(),         %% 缺省 5000
%%           age => pos_integer()}                   %% 缺省 = 新的单调整数（最年轻）；
%%                                                   %% 重跑时传首次的值，年龄不变
-spec register(pid(), map()) -> {ok, txn_id()}.
register(Pid, Opts) when is_pid(Pid), is_map(Opts) ->
    TxnId = erlang:unique_integer([positive, monotonic]),
    gen_server:call(shard(home_of(TxnId)), {register, TxnId, Pid, Opts}, infinity).

%% 阻塞直到授予或失败。超时全在 locker 侧管（兜底计时器），所以这里 infinity。
%% 前缀锁：按分片序逐个拿；中途失败就返回（已拿到的份留给 release_all 收）。
%% ⚠️ 跨分片的 FIFO 只在**已到达**的分片上成立：前缀写在分片 s 上等时，
%%    还没到的分片 > s 上的点请求照常授予。它每到一个分片都会排进那里的
%%    队列、后来者挡不住它，所以有进展保证，只是不是全局先来先得。
-spec acquire(txn_id(), lock_id(), mode()) ->
          ok | {error, deadlock | lock_wait_timeout | timeout | unknown_txn}.
acquire(TxnId, {Ref, Bin, point} = LockId, Mode)
  when is_reference(Ref), is_binary(Bin), (Mode =:= read orelse Mode =:= write) ->
    gen_server:call(shard(shard_of_key(Ref, Bin)), {acquire, TxnId, LockId, Mode}, infinity);
acquire(TxnId, {Ref, Bin, prefix} = LockId, Mode)
  when is_reference(Ref), is_binary(Bin), (Mode =:= read orelse Mode =:= write) ->
    acquire_on(1, shard_count(), TxnId, LockId, Mode).

acquire_on(I, N, _TxnId, _LockId, _Mode) when I > N ->
    ok;
acquire_on(I, N, TxnId, LockId, Mode) ->
    case gen_server:call(shard(I), {acquire, TxnId, LockId, Mode}, infinity) of
        ok    -> acquire_on(I + 1, N, TxnId, LockId, Mode);
        Error -> Error
    end.

%% 提交前校验：事务还活着、没过 deadline。直读共享表，不过任何分片。
-spec check(txn_id()) -> ok | {error, timeout | unknown_txn}.
check(TxnId) ->
    case ets:lookup(?TXNS, TxnId) of
        []  -> {error, unknown_txn};
        [T] -> case expired(T) of
                   true  -> {error, timeout};
                   false -> ok
               end
    end.

%% 释放事务的全部锁并注销（幂等）。调用方就是事务进程，所以它此刻不在任何
%% 分片上等；按 held 表分组向各分片 **cast** 放锁（同 mnesia_locker 的
%% release_tid：异步），最后 call 归属分片 demonitor + 删记录。
%% 异步的代价：返回后锁可能还挂几十微秒，等待者稍晚放行、status() 里
%% 短暂可见——正确性不受影响（严格 2PL 只要求提交后才放）。同步的代价是
%% 每个触及的分片一次 call，多 key 事务里比拿锁本身还贵。
-spec release_all(txn_id()) -> ok.
release_all(TxnId) ->
    Shards = lists:usort([S || {_, S, _} <- ets:match_object(?HELD, {TxnId, '_', '_'})]),
    [gen_server:cast(shard(S), {release, TxnId}) || S <- Shards],
    gen_server:call(shard(home_of(TxnId)), {unregister, TxnId}, infinity).

%% 直接读 ETS，不过分片进程——观测不挡锁操作。
-spec status() -> #{txns => non_neg_integer(), waiting => non_neg_integer(),
                    locks => non_neg_integer(), prefix_locks => non_neg_integer(),
                    deadlocks_total => non_neg_integer(), victims_other => non_neg_integer(),
                    lock_wait_timeouts => non_neg_integer(), shards => pos_integer()}.
status() ->
    N = shard_count(),
    Waiting = ets:select_count(?TXNS, [{#txn{waiting = '$1', _ = '_'},
                                        [{'=/=', '$1', undefined}], [true]}]),
    Locks  = lists:sum([ets:info((tabs(I))#tabs.locks, size) || I <- lists:seq(1, N)]),
    Prefix = lists:sum([C || I <- lists:seq(1, N),
                             {_Len, C} <- ets:tab2list((tabs(I))#tabs.plens)]),
    Stat = fun(K) -> case ets:lookup(?STATS, K) of [{_, V}] -> V; [] -> 0 end end,
    #{txns                => ets:info(?TXNS, size),
      waiting             => Waiting,
      locks               => Locks,
      prefix_locks        => Prefix,
      deadlocks_total     => Stat(deadlocks),
      victims_other       => Stat(victims_other),   % 受害者不是请求者的次数
      lock_wait_timeouts  => Stat(lock_wait_timeouts),
      shards              => N}.

%% =========================================================================
%% gen_server 回调
%% =========================================================================

init({tables, N}) ->
    _ = ets:new(?TXNS,  [named_table, set, public, {keypos, #txn.id},
                         {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(?HELD,  [named_table, bag, public,
                         {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(?STATS, [named_table, set, public, {write_concurrency, true}]),
    Names = list_to_tuple([shard_name(I) || I <- lists:seq(1, N)]),
    Tabs  = list_to_tuple([shard_tabs(I) || I <- lists:seq(1, N)]),
    persistent_term:put(?PT, {N, Names, Tabs}),
    {ok, tables};

init({shard, I}) ->
    #tabs{locks = Locks, plens = Plens} = Tabs = shard_tabs(I),
    _ = ets:new(Locks, [named_table, ordered_set, protected, {keypos, #lock.id}]),
    _ = ets:new(Plens, [named_table, set, protected]),
    {ok, #state{tabs = Tabs}}.

handle_call(_Req, _From, tables) ->
    {reply, {error, bad_request}, tables};

handle_call({register, TxnId, Pid, Opts}, _From, S) ->
    Mon = erlang:monitor(process, Pid),
    T = #txn{id = TxnId, pid = Pid, mon = Mon,
             age = maps:get(age, Opts, erlang:unique_integer([positive, monotonic])),
             deadline = maps:get(deadline, Opts, infinity),
             lock_wait_timeout = maps:get(lock_wait_timeout, Opts,
                                          ?DEFAULT_LOCK_WAIT_TIMEOUT)},
    true = ets:insert(?TXNS, T),
    {reply, {ok, TxnId}, S};

handle_call({unregister, TxnId}, _From, S) ->
    case ets:lookup(?TXNS, TxnId) of
        [] -> ok;
        [T] ->
            erlang:demonitor(T#txn.mon, [flush]),
            true = ets:delete(?TXNS, TxnId)
    end,
    {reply, ok, S};

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

handle_call(_Req, _From, S) ->
    {reply, {error, bad_request}, S}.

%% 正常释放：放掉本分片上它持有的锁。
handle_cast({release, TxnId}, #state{} = S) ->
    {noreply, release_held(TxnId, S)};

%% 事务死亡的级联清理：本分片上它等的出队、持的全放。
handle_cast({drop, TxnId}, #state{} = S) ->
    {noreply, drop_local(TxnId, S)};

%% 别的分片检出死锁、选中在本分片等的事务当受害者。它得仍在等同一把锁
%% 才动手——否则那个环已经（被授予/超时/死亡）解开了。
handle_cast({abort_waiter, TxnId, LockId}, #state{} = S) ->
    case maps:find(TxnId, S#state.waiting) of
        {ok, LockId} -> {noreply, abort_waiter(TxnId, LockId, S)};
        _            -> {noreply, S}
    end;

handle_cast(_Msg, S) ->
    {noreply, S}.

%% 调用进程死了（只有归属分片会收到）：通知全部分片各自清理，再删记录。
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #state{} = S) ->
    case ets:match_object(?TXNS, #txn{mon = Mon, _ = '_'}) of
        [#txn{id = TxnId}] ->
            N = shard_count(),
            Me = (S#state.tabs)#tabs.idx,
            [gen_server:cast(shard(I), {drop, TxnId}) || I <- lists:seq(1, N), I =/= Me],
            S1 = drop_local(TxnId, S),
            true = ets:delete(?TXNS, TxnId),
            {noreply, S1};
        [] ->
            {noreply, S}
    end;

%% 等待兜底计时器到点。计时器引用必须与队列里那条一致，否则是过期消息
%% （已授予/已出队后残留的），直接忽略。
handle_info({timeout, TRef, {lock_wait, TxnId, LockId}}, #state{tabs = Tabs} = S) ->
    case maps:find(TxnId, S#state.waiting) of
        {ok, LockId} ->
            case take_waiter(Tabs, LockId, TxnId) of
                {ok, #waiter{timer = TRef, from = From}} ->
                    Reply = case ets:lookup(?TXNS, TxnId) of
                                [T] -> case expired(T) of
                                           true  -> {error, timeout};
                                           false ->
                                               %% 正常路径死锁检测必达；这里计数是为了
                                               %% 让"检测漏了"在 status 里可见。
                                               _ = ets:update_counter(?STATS, lock_wait_timeouts, 1,
                                                                      {lock_wait_timeouts, 0}),
                                               {error, lock_wait_timeout}
                                       end;
                                []  -> {error, unknown_txn}
                            end,
                    gen_server:reply(From, Reply),
                    {noreply, wake_around(LockId, set_waiting(TxnId, undefined, S))};
                {ok, W} ->
                    %% 引用不符：把它放回去（take 已经拿走了）。理论上不会发生——
                    %% waiting 与队列条目总是同步维护——防御而已。
                    requeue(Tabs, LockId, W),
                    {noreply, S};
                error ->
                    {noreply, S}
            end;
        _ ->
            {noreply, S}
    end;

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% =========================================================================
%% 加锁
%% =========================================================================

do_acquire(#txn{id = TxnId} = T, LockId, Mode, From, #state{tabs = Tabs} = S) ->
    Recs = overlapping(Tabs, LockId),
    case covered(TxnId, Mode, Recs) of
        true ->
            %% 已持有覆盖它的锁（同一记录重入，或持有罩住它的前缀锁）：
            %% 免费，不建记录。
            {reply, ok, S};
        false ->
            Seq = erlang:unique_integer([positive, monotonic]),
            case blockers(TxnId, Mode, Seq, Recs) of
                [] ->
                    grant(Tabs, TxnId, LockId, Mode),
                    {reply, ok, S};
                _ ->
                    Timer = start_wait_timer(T, LockId),
                    W = #waiter{txn = TxnId, mode = Mode, from = From,
                                timer = Timer, seq = Seq},
                    %% 先写边（入队 + waiting），再检——跨分片检测的正确性
                    %% 依赖这个顺序（模块头第 3 条）。
                    requeue(Tabs, LockId, W),
                    S1 = set_waiting(TxnId, LockId, S),
                    case find_cycle(TxnId) of
                        false ->
                            {noreply, S1};
                        Cycle ->
                            _ = ets:update_counter(?STATS, deadlocks, 1, {deadlocks, 0}),
                            case youngest(Cycle) of
                                TxnId ->
                                    %% 受害者 = 请求者。出队、取消计时器、回复；它身后可能
                                    %% 有人因此变得可授予，wake。
                                    {ok, W1} = take_waiter(Tabs, LockId, TxnId),
                                    cancel_timer(W1#waiter.timer),
                                    S2 = wake_around(LockId, set_waiting(TxnId, undefined, S1)),
                                    {reply, {error, deadlock}, S2};
                                Victim ->
                                    %% 别人当受害者：请求者留在队里等，受害者出局后
                                    %% 它自然被唤醒（受害者要么是它等的锁上的先到
                                    %% 等待者，要么持着它等的锁、重跑前会放掉）。
                                    _ = ets:update_counter(?STATS, victims_other, 1,
                                                           {victims_other, 0}),
                                    {noreply, abort_victim(Victim, S1)}
                            end
                    end
            end
    end.

%% 本分片的 waiting 映射 + 共享表里的 waiting 字段一起维护。
set_waiting(TxnId, undefined, #state{waiting = W} = S) ->
    _ = ets:update_element(?TXNS, TxnId, {#txn.waiting, undefined}),
    S#state{waiting = maps:remove(TxnId, W)};
set_waiting(TxnId, LockId, #state{tabs = #tabs{idx = I}, waiting = W} = S) ->
    _ = ets:update_element(?TXNS, TxnId, {#txn.waiting, {I, LockId}}),
    S#state{waiting = W#{TxnId => LockId}}.

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
grant(#tabs{idx = I} = Tabs, TxnId, LockId, Mode) ->
    #lock{holders = H} = L = get_lock(Tabs, LockId),
    {NewMode, First} =
        case maps:find(TxnId, H) of
            {ok, write} -> {write, false};
            {ok, read}  -> {Mode, false};
            error       -> {Mode, true}
        end,
    put_lock(Tabs, L#lock{holders = H#{TxnId => NewMode}}),
    case First of
        true  -> true = ets:insert(?HELD, {TxnId, I, LockId});
        false -> ok
    end.

%% =========================================================================
%% 重叠记录：自身 + 覆盖它的前缀记录 +（自己是前缀时）它罩住的全部记录
%% =========================================================================

overlapping(#tabs{locks = Locks, plens = Plens}, {Ref, Bin, Kind} = LockId) ->
    Size = byte_size(Bin),
    Lens = [Len || {Len, _} <- ets:tab2list(Plens),
                   Len < Size orelse (Len =:= Size andalso Kind =:= point)],
    Covering = lists:append([ets:lookup(Locks, {Ref, binary_part(Bin, 0, Len), prefix})
                             || Len <- Lens]),
    Under = case Kind of
                point  -> ets:lookup(Locks, LockId);
                prefix -> scan_under(Locks, Ref, Bin, ets:next(Locks, {Ref, Bin, 0}), [])
            end,
    Covering ++ Under.

%% ordered_set 里从 {Ref, Bin, 0} 往后走：数字 < 原子，所以 {Ref,Bin,point} /
%% {Ref,Bin,prefix} 都在它之后；直到第二元素不再以 Bin 开头为止。
scan_under(Locks, Ref, Bin, {Ref, B, _} = K, Acc) when byte_size(B) >= byte_size(Bin) ->
    Size = byte_size(Bin),
    case B of
        <<Bin:Size/binary, _/binary>> ->
            scan_under(Locks, Ref, Bin, ets:next(Locks, K), ets:lookup(Locks, K) ++ Acc);
        _ ->
            Acc
    end;
scan_under(_Locks, _Ref, _Bin, _K, Acc) ->
    Acc.

%% =========================================================================
%% 死锁检测：从 Start 出发沿推导边 DFS，再碰到 Start 即有环（可跨分片读表）
%% 返回环上的事务列表（含 Start），无环 false。
%% =========================================================================

find_cycle(Start) ->
    case dfs(Start, [Start], #{Start => true}, Start) of
        {cycle, Path} -> Path;
        _Seen         -> false
    end.

%% 带路径的 DFS：Path 是从 Start 到当前节点的栈，碰到 Start 时它就是环。
dfs(N, Path, Seen, Start) ->
    dfs_edges(blockers_of(N), Path, Seen, Start).

dfs_edges([], _Path, Seen, _Start) ->
    Seen;
dfs_edges([Start | _], Path, _Seen, Start) ->
    {cycle, Path};
dfs_edges([B | Rest], Path, Seen, Start) ->
    case maps:is_key(B, Seen) of
        true ->
            dfs_edges(Rest, Path, Seen, Start);
        false ->
            case dfs(B, [B | Path], Seen#{B => true}, Start) of
                {cycle, _} = C -> C;
                Seen1          -> dfs_edges(Rest, Path, Seen1, Start)
            end
    end.

%% 环上 age 最大（最年轻）的事务。记录已没了的（刚死/刚注销）当作最老，不选。
youngest(Cycle) ->
    {_, V} = lists:max([{case ets:lookup(?TXNS, X) of
                             [#txn{age = A}] -> A;
                             []              -> 0
                         end, X} || X <- Cycle]),
    V.

%% 中止一个不是请求者的受害者：它在本分片等就地处理，否则 cast 给它等的分片。
abort_victim(Victim, #state{tabs = #tabs{idx = Me}} = S) ->
    case ets:lookup(?TXNS, Victim) of
        [#txn{waiting = {Me, LockId}}] ->
            abort_waiter(Victim, LockId, S);
        [#txn{waiting = {Shard, LockId}}] ->
            gen_server:cast(shard(Shard), {abort_waiter, Victim, LockId}),
            S;
        _ ->
            S
    end.

%% 把在本分片等 LockId 的 TxnId 出队并回复 {error, deadlock}。
abort_waiter(TxnId, LockId, #state{tabs = Tabs} = S) ->
    case take_waiter(Tabs, LockId, TxnId) of
        {ok, W} ->
            cancel_timer(W#waiter.timer),
            gen_server:reply(W#waiter.from, {error, deadlock}),
            wake_around(LockId, set_waiting(TxnId, undefined, S));
        error ->
            S
    end.

%% N 在等谁：不在等 → []；否则到它等的那个分片的表里按等待条目重算 blockers。
blockers_of(N) ->
    case ets:lookup(?TXNS, N) of
        [#txn{waiting = {Shard, LockId}}] ->
            Tabs = tabs(Shard),
            case find_waiter(Tabs, LockId, N) of
                #waiter{mode = Mode, seq = Seq} ->
                    blockers(N, Mode, Seq, overlapping(Tabs, LockId));
                false ->
                    []
            end;
        _ ->
            []
    end.

find_waiter(#tabs{locks = Locks}, LockId, TxnId) ->
    case ets:lookup(Locks, LockId) of
        [#lock{queue = Q}] -> lists:keyfind(TxnId, #waiter.txn, Q);
        []                 -> false
    end.

%% =========================================================================
%% 释放 / 唤醒
%% =========================================================================

%% 事务在本分片的全部痕迹：等待出队、持有释放。
drop_local(TxnId, #state{tabs = Tabs, waiting = W} = S) ->
    S1 = case maps:find(TxnId, W) of
             {ok, LockId} ->
                 case take_waiter(Tabs, LockId, TxnId) of
                     {ok, Wt} ->
                         cancel_timer(Wt#waiter.timer),
                         %% 调用方已经死了——回复只是为了不泄漏 From。
                         catch gen_server:reply(Wt#waiter.from, {error, unknown_txn}),
                         wake_around(LockId, S#state{waiting = maps:remove(TxnId, W)});
                     error ->
                         S#state{waiting = maps:remove(TxnId, W)}
                 end;
             error ->
                 S
         end,
    release_held(TxnId, S1).

%% 放掉 TxnId 在本分片持有的全部锁。
release_held(TxnId, #state{tabs = #tabs{idx = I}} = S) ->
    Held = ets:match_object(?HELD, {TxnId, I, '_'}),
    lists:foldl(fun({_, _, LockId} = Obj, Acc) ->
                        true = ets:delete_object(?HELD, Obj),
                        release_one(LockId, TxnId, Acc)
                end, S, Held).

release_one(LockId, TxnId, #state{tabs = #tabs{locks = Locks} = Tabs} = S) ->
    case ets:lookup(Locks, LockId) of
        [] -> S;
        [#lock{holders = H} = L] ->
            put_lock(Tabs, L#lock{holders = maps:remove(TxnId, H)}),
            wake_around(LockId, S)
    end.

%% LockId 附近的状态变了：把重叠范围内的全部等待者按 seq 依次重判。
%% 每授予一个都会改变后面人的判定，所以逐个重算（等待者通常个位数）。
wake_around(LockId, #state{tabs = Tabs} = S) ->
    Ws = lists:sort(fun(#waiter{seq = A}, #waiter{seq = B}) -> A =< B end,
                    lists:append([Q || #lock{queue = Q} <- overlapping(Tabs, LockId)])),
    lists:foldl(fun try_wake/2, S, Ws).

try_wake(#waiter{txn = TxnId, mode = Mode, seq = Seq, timer = Timer, from = From},
         #state{tabs = #tabs{idx = I} = Tabs} = S) ->
    case ets:lookup(?TXNS, TxnId) of
        [#txn{waiting = {I, LockId}} = T] ->
            case expired(T) of
                true ->
                    {ok, _} = take_waiter(Tabs, LockId, TxnId),
                    cancel_timer(Timer),
                    gen_server:reply(From, {error, timeout}),
                    set_waiting(TxnId, undefined, S);
                false ->
                    case blockers(TxnId, Mode, Seq, overlapping(Tabs, LockId)) of
                        [] ->
                            {ok, _} = take_waiter(Tabs, LockId, TxnId),
                            cancel_timer(Timer),
                            grant(Tabs, TxnId, LockId, Mode),
                            gen_server:reply(From, ok),
                            set_waiting(TxnId, undefined, S);
                        _ ->
                            S
                    end
            end;
        _ ->
            S
    end.

%% =========================================================================
%% 锁记录读写（含空记录 GC 与前缀长度集合维护）
%% =========================================================================

get_lock(#tabs{locks = Locks}, LockId) ->
    case ets:lookup(Locks, LockId) of
        []  -> #lock{id = LockId};
        [L] -> L
    end.

%% 写回记录：空了就删（前缀记录同步维护 plens）。
put_lock(#tabs{locks = Locks, plens = Plens}, #lock{id = Id, holders = H, queue = []})
  when map_size(H) =:= 0 ->
    case ets:member(Locks, Id) of
        true  -> true = ets:delete(Locks, Id), plen_dec(Plens, Id);
        false -> ok
    end;
put_lock(#tabs{locks = Locks, plens = Plens}, #lock{id = Id} = L) ->
    case ets:member(Locks, Id) of
        true  -> ok;
        false -> plen_inc(Plens, Id)
    end,
    true = ets:insert(Locks, L).

plen_inc(Plens, {_, Bin, prefix}) ->
    _ = ets:update_counter(Plens, byte_size(Bin), 1, {byte_size(Bin), 0}), ok;
plen_inc(_, _) -> ok.

plen_dec(Plens, {_, Bin, prefix}) ->
    case ets:update_counter(Plens, byte_size(Bin), -1) of
        0 -> true = ets:delete(Plens, byte_size(Bin)), ok;
        _ -> ok
    end;
plen_dec(_, _) -> ok.

%% 把 TxnId 的等待条目从锁队列里摘出来。
take_waiter(#tabs{locks = Locks} = Tabs, LockId, TxnId) ->
    case ets:lookup(Locks, LockId) of
        [] -> error;
        [#lock{queue = Q} = L] ->
            case lists:keytake(TxnId, #waiter.txn, Q) of
                false -> error;
                {value, W, Rest} ->
                    put_lock(Tabs, L#lock{queue = Rest}),
                    {ok, W}
            end
    end.

%% 入队（队列按 seq 升序）。
requeue(Tabs, LockId, W) ->
    L = get_lock(Tabs, LockId),
    Q = lists:sort(fun(#waiter{seq = A}, #waiter{seq = B}) -> A =< B end,
                   [W | L#lock.queue]),
    put_lock(Tabs, L#lock{queue = Q}).

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
