%% =========================================================================
%% bitcask_txn
%%
%%   事务门面（doc/txn-layer-design-zh.md）：在引擎原子批之上补齐隔离性——
%%   悲观 2PL + 死锁检测 + 事务重启，Mnesia 三件套的单节点版。
%%
%%     {atomic, R} | {aborted, Why} =
%%         bitcask_txn:transaction(Handle, fun(Tx) ->
%%             {ok, A} = bitcask_txn:read(Tx, <<"a">>),
%%             ok = bitcask_txn:write(Tx, <<"a">>, bump(A)),
%%             ok = bitcask_txn:delete(Tx, <<"old">>),
%%             R
%%         end, [{retries, 10}, {timeout, 5000}]).
%%
%%   语义：
%%     * 可串行化：read 拿读锁、write/delete 拿写锁，锁到事务结束一次性放
%%       （严格 2PL）。引擎 get 直通读不上锁，与事务并发的行为未定义（§4.8）。
%%     * 写只进调用进程字典里的缓冲（同 mnesia_tm），提交时按 key 升序展开
%%       成一条 bitcask:txn_commit/3 批——A+D 由引擎保证。读自己的写：
%%       缓冲命中先于引擎 get。
%%     * 死锁 / 单锁等待超时 → 丢缓冲、新 TxnId、**原样重跑 Fun**，
%%       预算 {retries, N}（默认 10），耗尽 {aborted, {retry_limit, N}}；
%%       每次重跑前 1~10ms 随机退避，打散对称死锁的重启风暴。
%%     * {timeout, Ms} 是整个 transaction 调用的总预算（跨重启），到点
%%       {aborted, timeout}，**不重启**——超时是调用方的问题。
%%     * abort(Reason) → {aborted, Reason}，不重启。Fun 抛异常 →
%%       {aborted, {throw, V}} / {aborted, {Reason, Stack}}，锁照放。
%%     * 只读事务（缓冲为空）不碰引擎，直接 {atomic, R}。
%%
%%   ⚠️ **Fun 必须无副作用**：可能执行多次。禁止在 Fun 内做 I/O、发消息、
%%      改进程字典。Fun 在调用进程内执行，Tx 不能传给别的进程用（会
%%      error({bitcask_txn, not_owner})）。
%%   ⚠️ 不确定窗口：调用进程死于 txn_commit NIF 执行途中，批要么全成要么
%%      全不成，但没人拿到结果。重试前应用需自查（§4.5）。
%%   ⚠️ 不支持嵌套：Fun 内再调 transaction → {aborted, tx_nested}。
%%
%%   选项：
%%     {retries, N | infinity}        死锁重启预算，默认 10
%%     {timeout, Ms}                  总预算，默认 infinity
%%     {lock_wait_timeout, Ms}        单锁等待兜底，默认 5000，触发按死锁处理
%%     {sync, sync_on_commit|no_sync} 提交 fsync 策略，默认 sync_on_commit
%%     {index_fun, fun((Key, {put,V}|delete) -> [{put,K,V}|{remove,K}])}
%%                                    二级索引展开：对缓冲里每个 key 调一次，
%%                                    返回的额外 op 并入同一批原子提交。额外
%%                                    op 的 key 在提交前补写锁；与缓冲里的
%%                                    key 重合 → {aborted, {index_conflict, K}}。
%%
%%   锁的粒度是 {CaskRef, Key}：不同 cask 的同名 key 互不干扰。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_txn).

-export([transaction/2, transaction/3,
         read/2, read/3, write/3, delete/2, abort/1,
         handle/1]).

-define(ACTIVE,  '$bitcask_txn_active').      % pdict：嵌套检测
-define(ABORT,   bitcask_txn_abort).          % throw 标签：显式中止
-define(RESTART, bitcask_txn_restart).        % throw 标签：死锁 → 重跑
-define(TIMEOUT, bitcask_txn_timeout).        % throw 标签：过 deadline

-define(DEFAULT_RETRIES, 10).
-define(DEFAULT_LOCK_WAIT_TIMEOUT, 5000).

%% 事务上下文。不透明：调用方只把它原样传回 read/write/delete。
-record(bitcask_txn_ctx, {id        :: pos_integer(),
                          handle    :: term(),
                          ref       :: reference(),
                          index_fun :: undefined | fun((binary(), term()) -> list()),
                          sync      :: sync_on_commit | no_sync}).

-record(cfg, {retries   :: non_neg_integer() | infinity,
              deadline  :: integer() | infinity,
              lock_wait :: timeout(),
              sync      :: sync_on_commit | no_sync,
              index_fun :: undefined | fun()}).

%% =========================================================================
%% 门面
%% =========================================================================

-spec transaction(term(), fun((term()) -> term())) -> {atomic, term()} | {aborted, term()}.
transaction(Handle, Fun) ->
    transaction(Handle, Fun, []).

-spec transaction(term(), fun((term()) -> term()), list()) ->
          {atomic, term()} | {aborted, term()}.
transaction(Handle, Fun, Opts) when is_function(Fun, 1), is_list(Opts) ->
    Cfg = parse_opts(Opts),
    case get(?ACTIVE) of
        undefined ->
            put(?ACTIVE, true),
            try run_loop(Handle, Fun, Cfg, 0)
            after erase(?ACTIVE)
            end;
        _ ->
            {aborted, tx_nested}
    end.

parse_opts(Opts) ->
    Deadline = case proplists:get_value(timeout, Opts, infinity) of
                   infinity -> infinity;
                   Ms when is_integer(Ms), Ms > 0 ->
                       erlang:monotonic_time(millisecond) + Ms
               end,
    Retries = proplists:get_value(retries, Opts, ?DEFAULT_RETRIES),
    true = Retries =:= infinity orelse (is_integer(Retries) andalso Retries >= 0),
    Sync = proplists:get_value(sync, Opts, sync_on_commit),
    true = Sync =:= sync_on_commit orelse Sync =:= no_sync,
    IndexFun = proplists:get_value(index_fun, Opts, undefined),
    true = IndexFun =:= undefined orelse is_function(IndexFun, 2),
    #cfg{retries   = Retries,
         deadline  = Deadline,
         lock_wait = proplists:get_value(lock_wait_timeout, Opts,
                                         ?DEFAULT_LOCK_WAIT_TIMEOUT),
         sync      = Sync,
         index_fun = IndexFun}.

%% 重启循环。Attempt 是已重跑次数；Attempt < Retries 才准再来一次。
run_loop(Handle, Fun, #cfg{retries = Retries} = Cfg, Attempt) ->
    case run_once(Handle, Fun, Cfg) of
        {restart, _Why} when Retries =:= infinity; Attempt < Retries ->
            timer:sleep(rand:uniform(10)),
            run_loop(Handle, Fun, Cfg, Attempt + 1);
        {restart, _Why} ->
            {aborted, {retry_limit, Retries}};
        Result ->
            Result
    end.

%% 单次尝试：注册 → 跑 Fun → 提交。所有出口都 release_all（幂等）。
run_once(Handle, Fun, Cfg) ->
    {ok, TxnId} = bitcask_txn_locker:register(
                    self(), #{deadline => Cfg#cfg.deadline,
                              lock_wait_timeout => Cfg#cfg.lock_wait}),
    Tx = #bitcask_txn_ctx{id = TxnId, handle = Handle,
                          ref = handle_ref(Handle),
                          index_fun = Cfg#cfg.index_fun,
                          sync = Cfg#cfg.sync},
    BufKey = buf_key(TxnId),
    put(BufKey, #{}),
    put(locks_key(TxnId), #{}),
    try
        Result = Fun(Tx),
        commit(Tx, Result)
    catch
        throw:{?ABORT, Reason} ->
            release(TxnId), {aborted, Reason};
        throw:{?RESTART, Why} ->
            release(TxnId), {restart, Why};
        throw:?TIMEOUT ->
            release(TxnId), {aborted, timeout};
        throw:Value ->
            release(TxnId), {aborted, {throw, Value}};
        Class:Reason:Stack when Class =:= error; Class =:= exit ->
            release(TxnId), {aborted, {Reason, Stack}}
    after
        erase(BufKey),
        erase(locks_key(TxnId))
    end.

release(TxnId) ->
    ok = bitcask_txn_locker:release_all(TxnId).

%% Handle = bitcask:open/2 返回的 {Ref, Ctx}；Ref 是 NIF 资源引用，作锁的
%% cask 维度。形态不认就当场 badarg，别让一个错句柄悄悄拿到锁。
handle_ref({Ref, _Ctx}) when is_reference(Ref) -> Ref;
handle_ref(Bad) -> erlang:error({badarg, Bad}).

buf_key(TxnId)   -> {?MODULE, TxnId}.
locks_key(TxnId) -> {?MODULE, locks, TxnId}.

%% =========================================================================
%% 事务内 API
%% =========================================================================

-spec read(term(), binary()) -> {ok, binary()} | not_found | {error, term()}.
read(Tx, Key) ->
    read(Tx, Key, read).

%% read/3 的 Lock = write：读之前直接拿**写**锁（Mnesia 的 wlock_read）。
%% 读-改-写模式必须用它：两个事务都先读锁再升级，就是一个确定的死锁
%% （各自等对方放读锁）——能跑对（检测 + 重跑），但纯属浪费。
-spec read(term(), binary(), read | write) -> {ok, binary()} | not_found | {error, term()}.
read(#bitcask_txn_ctx{handle = Handle} = Tx, Key, Lock)
  when is_binary(Key), (Lock =:= read orelse Lock =:= write) ->
    Buf = buffer(Tx),              % 先做 owner 检查，再去拿锁
    lock(Tx, Key, Lock),
    case maps:find(Key, Buf) of
        {ok, {put, Val}} -> {ok, Val};
        {ok, delete}     -> not_found;
        error            -> bitcask:get(Handle, Key)
    end.

-spec write(term(), binary(), binary()) -> ok.
write(#bitcask_txn_ctx{id = TxnId} = Tx, Key, Val) when is_binary(Key), is_binary(Val) ->
    Buf = buffer(Tx),
    lock(Tx, Key, write),
    put(buf_key(TxnId), Buf#{Key => {put, Val}}),
    ok.

-spec delete(term(), binary()) -> ok.
delete(#bitcask_txn_ctx{id = TxnId} = Tx, Key) when is_binary(Key) ->
    Buf = buffer(Tx),
    lock(Tx, Key, write),
    put(buf_key(TxnId), Buf#{Key => delete}),
    ok.

-spec abort(term()) -> no_return().
abort(Reason) ->
    throw({?ABORT, Reason}).

%% 事务绑定的 cask 句柄。给上层（graphdb）在事务内做**不上锁**的辅助读
%% （如计数键缺失时的按需扫描）用；经它做的读写不受 2PL 保护。
-spec handle(term()) -> term().
handle(#bitcask_txn_ctx{handle = Handle}) -> Handle.

%% 缓冲只在调用进程的 pdict 里——别的进程拿着 Tx 来调，这里就是 undefined。
buffer(#bitcask_txn_ctx{id = TxnId}) ->
    case get(buf_key(TxnId)) of
        undefined -> erlang:error({bitcask_txn, not_owner});
        Buf       -> Buf
    end.

%% 本地记着已持有的锁（pdict）：2PL 到事务结束才放锁，所以这份缓存永远
%% 准确——重入（读后写同一 key、计数器 RMW）不必再过一次 locker。
%% 实测 put_edge_txn 每边省 2~3 次 gen_server:call。
lock(#bitcask_txn_ctx{id = TxnId, ref = Ref}, Key, Mode) ->
    LK = locks_key(TxnId),
    Held = get(LK),
    case maps:find(Key, Held) of
        {ok, write}                  -> ok;
        {ok, read} when Mode =:= read -> ok;
        _ ->
            case bitcask_txn_locker:acquire(TxnId, {Ref, Key}, Mode) of
                ok ->
                    put(LK, Held#{Key => Mode}),
                    ok;
                {error, deadlock}          -> throw({?RESTART, deadlock});
                {error, lock_wait_timeout} -> throw({?RESTART, lock_wait_timeout});
                {error, timeout}           -> throw(?TIMEOUT);
                {error, unknown_txn}       -> throw({?ABORT, locker_restarted})
            end
    end.

%% =========================================================================
%% 提交
%% =========================================================================

%% 仍在 try 里调用：这里抛出的 RESTART/TIMEOUT/ABORT 走同一套 catch。
commit(#bitcask_txn_ctx{id = TxnId, handle = Handle, sync = Sync} = Tx, Result) ->
    Buf = buffer(Tx),
    case map_size(Buf) of
        0 ->
            %% 只读：没什么好提交的，也不必打扰引擎（空批本来就被拒）。
            release(TxnId),
            {atomic, Result};
        _ ->
            Sorted = lists:sort(maps:to_list(Buf)),
            Main = [case Op of
                        {put, V} -> {put, K, V};
                        delete   -> {remove, K}
                    end || {K, Op} <- Sorted],
            Extra = index_ops(Tx, Sorted, Buf),
            case bitcask_txn_locker:check(TxnId) of
                {error, timeout}     -> throw(?TIMEOUT);
                {error, unknown_txn} -> throw({?ABORT, locker_restarted});
                ok ->
                    case bitcask:txn_commit(Handle, Main ++ Extra, Sync) of
                        ok ->
                            release(TxnId),
                            {atomic, Result};
                        {error, Reason} ->
                            release(TxnId),
                            {aborted, {commit_failed, Reason}}
                    end
            end
    end.

%% 二级索引展开。额外 op 的 key 在提交前补写锁（仍属 2PL 的增长段，
%% 可能因此死锁 → 照常重跑）。
index_ops(#bitcask_txn_ctx{index_fun = undefined}, _Sorted, _Buf) ->
    [];
index_ops(#bitcask_txn_ctx{index_fun = F} = Tx, Sorted, Buf) ->
    Extra = lists:append([F(K, Op) || {K, Op} <- Sorted]),
    lists:foreach(
      fun(ExtraOp) ->
              K = extra_key(ExtraOp),
              case maps:is_key(K, Buf) of
                  true  -> throw({?ABORT, {index_conflict, K}});
                  false -> lock(Tx, K, write)
              end
      end, Extra),
    Extra.

extra_key({put, K, _V}) when is_binary(K) -> K;
extra_key({remove, K})  when is_binary(K) -> K;
extra_key(Bad) -> throw({?ABORT, {bad_index_op, Bad}}).
