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
%%       每次重跑前 1~10ms 随机退避，打散对称死锁的重启风暴。死锁受害者是
%%       环上**最年轻**的事务，年龄按 transaction 调用算、重跑不变——最老
%%       的永远不会被牺牲，长事务不会被短事务反复打断。
%%     * {timeout, Ms} 是整个 transaction 调用的总预算（跨重启），到点
%%       {aborted, timeout}，**不重启**——超时是调用方的问题。
%%     * abort(Reason) → {aborted, Reason}，不重启。Fun 抛异常 →
%%       {aborted, {throw, V}} / {aborted, {Reason, Stack}}，锁照放。
%%     * 只读事务（缓冲为空）不碰引擎，直接 {atomic, R}。
%%
%%   ⚠️ **Fun 必须无副作用**：可能执行多次。禁止在 Fun 内做 I/O、发消息、
%%      改进程字典。Fun 在调用进程内执行，Tx 不能传给别的进程用（会
%%      error({bitcask_txn, not_owner})）。
%%   提交带一个提交令牌进 NIF（txn_commit/4）：调用进程在提交途中被 kill，
%%   locker 等令牌析构的通知再放锁——锁持到这批不会再动盘（§4.5）。
%%   ⚠️ 不确定窗口：调用进程死于提交途中，批要么全成要么全不成，但没人拿到
%%      结果。要安全重试就带 {idem_key, K}（见下）。
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
%%     {idem_key, binary()}           幂等键（§4.5.1）：同一个键的事务**至多提交
%%                                    一次**。开跑前拿标记键的写锁并查它：已存在
%%                                    → 不跑 Fun，直接 {atomic, 首次提交时的结果}；
%%                                    否则照常跑，标记（含 Fun 的结果）与数据同批
%%                                    原子提交——批在则标记在。只读事务带了键也写
%%                                    标记。标记永不自动过期：idem_purge/2,3 清理。
%%     {idem_result, boolean()}       默认 true：标记里存 Fun 的结果（term_to_binary，
%%                                    一直留到 purge——结果大的事务请关掉）。false
%%                                    → 不存，重来返回 {atomic, idem_replayed}。
%%
%%   ⚠️ 保留 key：以 <<0, "bitcask_txn:idem:">> 开头的 key 归幂等标记，事务内
%%      write/delete 它们 → error({bitcask_txn, reserved_key, K})。
%%
%%   前缀锁（P2）：lock_prefix(Tx, Prefix, read|write) 锁住以 Prefix 开头的
%%   全部 key（现有的和将来的）——事务内 range 扫描的幻读防护。
%%   prefix_range(Tx, Prefix) = 前缀读锁 + bitcask:range + 合并本事务缓冲
%%   （读自己的写），返回 [{Key, Val}] 按 key 升序。持有前缀锁后对其下 key 的
%%   read/write/delete 不再过 locker（本地判定覆盖）。
%%
%%   锁的粒度是 {CaskRef, Key}：不同 cask 的同名 key 互不干扰。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_txn).

-export([transaction/2, transaction/3,
         read/2, read/3, write/3, delete/2, abort/1,
         lock_key/3, lock_prefix/3, prefix_range/2, prefix_range/3,
         handle/1,
         idem_lookup/2, idem_purge/2, idem_purge/3]).

-define(ACTIVE,  '$bitcask_txn_active').      % pdict：嵌套检测
-define(ABORT,   bitcask_txn_abort).          % throw 标签：显式中止
-define(RESTART, bitcask_txn_restart).        % throw 标签：死锁 → 重跑
-define(TIMEOUT, bitcask_txn_timeout).        % throw 标签：过 deadline

-define(IDEM_PREFIX, <<0, "bitcask_txn:idem:">>).
%% 标记值：<<Ver:8, At:64/big, Result/binary>>。定长头让 purge 不用解码结果
%% 就能读时间戳；Result 为空 = 没存结果（{idem_result, false}）。
-define(IDEM_VER, 1).
-define(IDEM_PURGE_CHUNK, 1000).

-define(DEFAULT_RETRIES, 10).
-define(DEFAULT_LOCK_WAIT_TIMEOUT, 5000).

%% 事务上下文。不透明：调用方只把它原样传回 read/write/delete。
-record(bitcask_txn_ctx, {id        :: pos_integer(),
                          handle    :: term(),
                          ref       :: reference(),
                          index_fun :: undefined | fun((binary(), term()) -> list()),
                          sync      :: sync_on_commit | no_sync,
                          idem      :: undefined | binary(),    % 标记键（已加前缀）
                          idem_result :: boolean()}).

-record(cfg, {retries   :: non_neg_integer() | infinity,
              age       :: pos_integer(),          % 一次 transaction 调用一个，重跑不变
              deadline  :: integer() | infinity,
              lock_wait :: timeout(),
              sync      :: sync_on_commit | no_sync,
              index_fun :: undefined | fun(),
              idem      :: undefined | binary(),
              idem_result :: boolean()}).

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

%% 选项一律在门面校验，坏值当场 badarg——别把它们送进 locker：一个坏的
%% lock_wait_timeout 到了分片里 start_timer 就 badarg，分片崩、one_for_all 全组
%% 重启，所有在途事务 locker_restarted；10 秒内几次就超过重启强度，supervisor
%% 自己也没了。
parse_opts(Opts) ->
    Deadline = case proplists:get_value(timeout, Opts, infinity) of
                   infinity -> infinity;
                   Ms when is_integer(Ms), Ms >= 0 ->
                       erlang:monotonic_time(millisecond) + Ms;
                   BadT -> erlang:error({badarg, {timeout, BadT}})
               end,
    LockWait = case proplists:get_value(lock_wait_timeout, Opts, ?DEFAULT_LOCK_WAIT_TIMEOUT) of
                   infinity -> infinity;
                   LW when is_integer(LW), LW >= 0 -> LW;
                   BadLW -> erlang:error({badarg, {lock_wait_timeout, BadLW}})
               end,
    Retries = proplists:get_value(retries, Opts, ?DEFAULT_RETRIES),
    true = Retries =:= infinity orelse (is_integer(Retries) andalso Retries >= 0),
    Sync = proplists:get_value(sync, Opts, sync_on_commit),
    true = Sync =:= sync_on_commit orelse Sync =:= no_sync,
    IndexFun = proplists:get_value(index_fun, Opts, undefined),
    true = IndexFun =:= undefined orelse is_function(IndexFun, 2),
    Idem = case proplists:get_value(idem_key, Opts, undefined) of
               undefined -> undefined;
               IK when is_binary(IK) -> idem_marker(IK)
           end,
    IdemResult = proplists:get_value(idem_result, Opts, true),
    true = is_boolean(IdemResult),
    #cfg{retries   = Retries,
         age       = erlang:unique_integer([positive, monotonic]),
         deadline  = Deadline,
         lock_wait = LockWait,
         sync      = Sync,
         index_fun = IndexFun,
         idem      = Idem,
         idem_result = IdemResult}.

%% 重启循环。Attempt 是已重跑次数；Attempt < Retries 才准再来一次。
run_loop(Handle, Fun, #cfg{retries = Retries, deadline = Deadline} = Cfg, Attempt) ->
    case run_once(Handle, Fun, Cfg) of
        {restart, _Why} when Retries =:= infinity; Attempt < Retries ->
            case past_deadline(Deadline) of
                true ->
                    %% 预算已耗尽：别再睡、再注册、再拿锁只为拿回一个 timeout。
                    {aborted, timeout};
                false ->
                    %% 退避带上限的指数抖动：热点 key 上一群事务同步重跑，
                    %% 平抖动 1~10ms 打不散，越退越开才能错开。
                    timer:sleep(rand:uniform(min(10 bsl Attempt, 200))),
                    run_loop(Handle, Fun, Cfg, Attempt + 1)
            end;
        {restart, _Why} ->
            {aborted, {retry_limit, Retries}};
        Result ->
            Result
    end.

past_deadline(infinity) -> false;
past_deadline(D)        -> erlang:monotonic_time(millisecond) >= D.

%% 单次尝试：注册 → 跑 Fun → 提交。所有出口都 release_all（幂等）。
run_once(Handle, Fun, Cfg) ->
    %% age 跨重跑不变：死锁时牺牲环上最年轻的，重跑的事务不会因为换了
    %% TxnId 又变成"最年轻"而被反复牺牲（同 Mnesia 重启保 Tid）。
    {ok, TxnId} = bitcask_txn_locker:register(
                    self(), #{deadline => Cfg#cfg.deadline,
                              lock_wait_timeout => Cfg#cfg.lock_wait,
                              age => Cfg#cfg.age}),
    Tx = #bitcask_txn_ctx{id = TxnId, handle = Handle,
                          ref = handle_ref(Handle),
                          index_fun = Cfg#cfg.index_fun,
                          sync = Cfg#cfg.sync,
                          idem = Cfg#cfg.idem,
                          idem_result = Cfg#cfg.idem_result},
    BufKey = buf_key(TxnId),
    put(BufKey, #{}),
    put(locks_key(TxnId), {#{}, #{}}),        % {点锁 Key => Mode, 前缀锁 Prefix => Mode}
    try
        case idem_seen(Tx) of
            {ok, Prev} ->
                release(TxnId),
                {atomic, Prev};
            none ->
                commit(Tx, Fun(Tx))
        end
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

-spec read(term(), binary()) -> {ok, binary() | map()} | not_found | {error, term()}.
read(Tx, Key) ->
    read(Tx, Key, read).

%% read/3 的 Lock = write：读之前直接拿**写**锁（Mnesia 的 wlock_read）。
%% 读-改-写模式必须用它：两个事务都先读锁再升级，就是一个确定的死锁
%% （各自等对方放读锁）——能跑对（检测 + 重跑），但纯属浪费。
%% 未缓冲的 key 直通 bitcask:get——索引模式下值是 #{text, meta}。
-spec read(term(), binary(), read | write) ->
          {ok, binary() | map()} | not_found | {error, term()}.
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
    not_reserved(Key),
    lock(Tx, Key, write),
    put(buf_key(TxnId), Buf#{Key => {put, Val}}),
    ok.

-spec delete(term(), binary()) -> ok.
delete(#bitcask_txn_ctx{id = TxnId} = Tx, Key) when is_binary(Key) ->
    Buf = buffer(Tx),
    not_reserved(Key),
    lock(Tx, Key, write),
    put(buf_key(TxnId), Buf#{Key => delete}),
    ok.

-spec abort(term()) -> no_return().
abort(Reason) ->
    throw({?ABORT, Reason}).

%% 点锁：只拿锁、不读不写（mnesia:lock 的点锁形态）。给「锁下直接操作引擎」
%% 的调用方用——比如 bitcask_query 的索引维护：文档带 meta 进不了提交批，只能
%% 锁住 key 后直接写引擎。
-spec lock_key(term(), binary(), read | write) -> ok.
lock_key(#bitcask_txn_ctx{} = Tx, Key, Mode)
  when is_binary(Key), (Mode =:= read orelse Mode =:= write) ->
    _ = buffer(Tx),                % owner 检查
    lock(Tx, Key, Mode),
    ok.

%% 前缀锁：罩住以 Prefix 开头的全部 key（现有的与将来的）。
-spec lock_prefix(term(), binary(), read | write) -> ok.
lock_prefix(#bitcask_txn_ctx{} = Tx, Prefix, Mode)
  when is_binary(Prefix), (Mode =:= read orelse Mode =:= write) ->
    _ = buffer(Tx),                % owner 检查
    lock_prefix_(Tx, Prefix, Mode).

%% 前缀扫描：前缀锁（默认 read；Opts 里 {lock, write} 给"扫了就删"的场景）
%% + bitcask:range [Prefix, succ(Prefix)) + 合并本事务缓冲里前缀下的
%% put/delete。返回 [{Key, Val}] 按 key 升序；引擎错误原样 {error, R}。
-spec prefix_range(term(), binary()) -> [{binary(), binary()}] | {error, term()}.
prefix_range(Tx, Prefix) ->
    prefix_range(Tx, Prefix, []).

-spec prefix_range(term(), binary(), list()) -> [{binary(), binary()}] | {error, term()}.
prefix_range(#bitcask_txn_ctx{handle = Handle} = Tx, Prefix, Opts)
  when is_binary(Prefix), is_list(Opts) ->
    Buf = buffer(Tx),
    lock_prefix_(Tx, Prefix, proplists:get_value(lock, Opts, read)),
    case bitcask:range(Handle, {Prefix, bitcask:prefix_succ(Prefix)}) of
        {error, _} = E -> E;
        Rows ->
            Size = byte_size(Prefix),
            Mine = [KV || {<<P:Size/binary, _/binary>>, _} = KV <- maps:to_list(Buf),
                          P =:= Prefix],
            case Mine of
                [] -> Rows;
                _  ->
                    Merged = lists:foldl(
                               fun({K, {put, V}}, M) -> M#{K => V};
                                  ({K, delete}, M)   -> maps:remove(K, M)
                               end, maps:from_list(Rows), Mine),
                    lists:sort(maps:to_list(Merged))
            end
    end.


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
%% 准确——重入（读后写同一 key、计数器 RMW）、被已持前缀锁覆盖的 key，
%% 都不必再过一次 locker。实测 put_edge_txn 每边省 2~3 次 gen_server:call。
lock(#bitcask_txn_ctx{id = TxnId, ref = Ref}, Key, Mode) ->
    LK = locks_key(TxnId),
    {Points, Prefixes} = Held = get(LK),
    case covers(maps:find(Key, Points), Mode)
         orelse prefix_covers(Key, Mode, Prefixes) of
        true  -> ok;
        false ->
            acquire(TxnId, {Ref, Key, point}, Mode),
            put(LK, setelement(1, Held, Points#{Key => Mode})),
            ok
    end.

lock_prefix_(#bitcask_txn_ctx{id = TxnId, ref = Ref}, Prefix, Mode) ->
    LK = locks_key(TxnId),
    {_Points, Prefixes} = Held = get(LK),
    case prefix_covers(Prefix, Mode, Prefixes) of
        true  -> ok;
        false ->
            acquire(TxnId, {Ref, Prefix, prefix}, Mode),
            put(LK, setelement(2, Held, Prefixes#{Prefix => Mode})),
            ok
    end.

covers({ok, write}, _)    -> true;
covers({ok, read}, read)  -> true;
covers(_, _)              -> false.

%% 已持有的前缀锁里有没有一把罩住 Bin（含相等）且模式够用的。
prefix_covers(_Bin, _Mode, Prefixes) when map_size(Prefixes) =:= 0 ->
    false;                                   % 没持前缀锁（绝大多数事务）：不建列表
prefix_covers(Bin, Mode, Prefixes) ->
    Size = byte_size(Bin),
    lists:any(fun({P, PM}) ->
                      PS = byte_size(P),
                      PS =< Size andalso binary_part(Bin, 0, PS) =:= P
                          andalso covers({ok, PM}, Mode)
              end, maps:to_list(Prefixes)).

acquire(TxnId, LockId, Mode) ->
    case bitcask_txn_locker:acquire(TxnId, LockId, Mode) of
        ok                         -> ok;
        {error, deadlock}          -> throw({?RESTART, deadlock});
        {error, lock_wait_timeout} -> throw({?RESTART, lock_wait_timeout});
        {error, timeout}           -> throw(?TIMEOUT);
        {error, unknown_txn}       -> throw({?ABORT, locker_restarted})
    end.

%% =========================================================================
%% 提交
%% =========================================================================

%% 仍在 try 里调用：这里抛出的 RESTART/TIMEOUT/ABORT 走同一套 catch。
commit(#bitcask_txn_ctx{id = TxnId, idem = Idem} = Tx, Result) ->
    Buf = buffer(Tx),
    case map_size(Buf) =:= 0 andalso Idem =:= undefined of
        true ->
            %% 只读：没什么好提交的，也不必打扰引擎（空批本来就被拒）。
            release(TxnId),
            {atomic, Result};
        false ->
            Sorted = lists:sort(maps:to_list(Buf)),
            Main = [case Op of
                        {put, V} -> {put, K, V};
                        delete   -> {remove, K}
                    end || {K, Op} <- Sorted],
            Extra = index_ops(Tx, Sorted, Buf),
            case commit_notified(Tx, Main ++ Extra ++ idem_ops(Tx, Result)) of
                ok              -> {atomic, Result};
                {error, Reason} -> {aborted, {commit_failed, Reason}}
            end
    end.

%% 带一个提交令牌进 NIF：调用方死在提交途中，locker 不按 DOWN 放锁，而是
%% 等令牌析构的通知——锁一直持到这批不会再动盘（见 bitcask_txn_locker:
%% begin_commit/1）。顺序有讲究：**先建令牌再标 inflight**（inflight 的记录
%% 必有令牌兜着），NIF 返回后**先 release 再 disarm**（release 之前被 kill，
%% 令牌还 armed，通知照来）。
commit_notified(#bitcask_txn_ctx{id = TxnId, handle = Handle, sync = Sync}, Ops) ->
    case bitcask_txn_locker:notify_target(TxnId) of
        {ok, Shard} ->
            Token = bitcask_cpp_nifs:txn_commit_token(Shard, TxnId),
            case bitcask_txn_locker:begin_commit(TxnId) of
                ok ->
                    R = bitcask:txn_commit(Handle, Ops, Sync, Token),
                    release(TxnId),
                    ok = bitcask_cpp_nifs:txn_commit_token_disarm(Token),
                    R;
                {error, timeout}     -> throw(?TIMEOUT);
                {error, unknown_txn} -> throw({?ABORT, locker_restarted})
            end;
        {error, unknown_txn} ->
            throw({?ABORT, locker_restarted})
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

%% =========================================================================
%% 幂等键（§4.5.1）
%% =========================================================================

idem_marker(IdemKey) -> <<?IDEM_PREFIX/binary, IdemKey/binary>>.

not_reserved(<<0, "bitcask_txn:idem:", _/binary>> = Key) ->
    erlang:error({bitcask_txn, reserved_key, Key});
not_reserved(_) ->
    ok.

%% 开跑前：拿标记键写锁并查。写锁持到事务结束——同一个幂等键的并发调用
%% 在这里串行，后到者一定看得见先到者的标记（或先到者已中止、标记不存在）。
%% 死锁重跑会重新走一遍，照样正确。
idem_seen(#bitcask_txn_ctx{idem = undefined}) ->
    none;
idem_seen(#bitcask_txn_ctx{handle = Handle, idem = Marker} = Tx) ->
    lock(Tx, Marker, write),
    case bitcask:get(Handle, Marker) of
        {ok, Bin}      -> {ok, idem_result(Bin)};
        not_found      -> none;
        {error, R}     -> throw({?ABORT, {idem_read_failed, R}})
    end.

idem_ops(#bitcask_txn_ctx{idem = undefined}, _Result) ->
    [];
idem_ops(#bitcask_txn_ctx{idem = Marker, idem_result = Store}, Result) ->
    Payload = case Store of
                  true  -> term_to_binary(Result);
                  false -> <<>>
              end,
    [{put, Marker, <<?IDEM_VER:8, (os:system_time(second)):64, Payload/binary>>}].

idem_result(<<?IDEM_VER:8, _At:64>>)                 -> idem_replayed;
idem_result(<<?IDEM_VER:8, _At:64, Payload/binary>>) -> binary_to_term(Payload).

idem_at(<<?IDEM_VER:8, At:64, _/binary>>) -> At.

%% 查某个幂等键是否已提交（不上锁的直读——应用自查用）。
-spec idem_lookup(term(), binary()) -> {ok, term()} | not_found | {error, term()}.
idem_lookup(Handle, IdemKey) when is_binary(IdemKey) ->
    case bitcask:get(Handle, idem_marker(IdemKey)) of
        {ok, Bin} -> {ok, idem_result(Bin)};
        Other     -> Other
    end.

%% 删掉提交时间不晚于 MaxAgeSec 秒前的标记（0 = 全删），返回删掉的条数。
%% MaxAgeSec 要大于应用的最长重试周期——删掉之后同一个键再来就会重新执行。
%%
%% 两段式，为了规模：
%%   1. 不上锁 range_fold 扫标记前缀，只解定长头、只收过期的 **key**——不把
%%      所有标记的值（里面是 Fun 结果）装进内存。
%%   2. 按块删（{chunk, N}，默认 1000）：每块一个事务，持标记前缀写锁 → 逐 key
%%      重读核对时间戳仍过期（扫描与加锁之间可能被别的 purge 删掉又被同键的新
%%      事务重写）→ 同批删除。块之间不持锁，带幂等键的事务只在每块提交那一小
%%      会儿被挡；块间新写的标记必然比 cutoff 新，不会被误删。
-spec idem_purge(term(), non_neg_integer()) -> {ok, non_neg_integer()} | {error, term()}.
idem_purge(Handle, MaxAgeSec) ->
    idem_purge(Handle, MaxAgeSec, []).

-spec idem_purge(term(), non_neg_integer(), list()) -> {ok, non_neg_integer()} | {error, term()}.
idem_purge(Handle, MaxAgeSec, Opts) when is_integer(MaxAgeSec), MaxAgeSec >= 0, is_list(Opts) ->
    Cutoff = os:system_time(second) - MaxAgeSec,
    Chunk = proplists:get_value(chunk, Opts, ?IDEM_PURGE_CHUNK),
    true = is_integer(Chunk) andalso Chunk > 0,
    Range = {?IDEM_PREFIX, bitcask:prefix_succ(?IDEM_PREFIX)},
    case bitcask:range_fold(Handle, Range, [],
                            fun(K, V, _T, _O, Acc) ->
                                    case idem_at(V) =< Cutoff of
                                        true  -> [K | Acc];
                                        false -> Acc
                                    end
                            end, []) of
        {error, _} = E -> E;
        Old            -> idem_purge_chunks(Handle, Cutoff, chunks(Old, Chunk), 0)
    end.

idem_purge_chunks(_Handle, _Cutoff, [], N) ->
    {ok, N};
idem_purge_chunks(Handle, Cutoff, [Keys | Rest], N) ->
    Res = transaction(
            Handle,
            fun(#bitcask_txn_ctx{id = TxnId} = Tx) ->
                    ok = lock_prefix_(Tx, ?IDEM_PREFIX, write),
                    Dead = [K || K <- Keys,
                                 case bitcask:get(Handle, K) of
                                     {ok, V} -> idem_at(V) =< Cutoff;
                                     _       -> false
                                 end],
                    %% 绕过 delete/2 的保留 key 检查，直接进缓冲；前缀写锁已罩住。
                    BK = buf_key(TxnId),
                    put(BK, maps:merge(get(BK), maps:from_list([{K, delete} || K <- Dead]))),
                    length(Dead)
            end, [{sync, sync_on_commit}]),
    case Res of
        {atomic, M}    -> idem_purge_chunks(Handle, Cutoff, Rest, N + M);
        {aborted, Why} -> {error, Why}
    end.

chunks([], _N) -> [];
chunks(L, N)  -> chunks(L, N, N, [], []).

chunks([], _N, _Left, Cur, Acc)   -> lists:reverse([lists:reverse(Cur) | Acc]);
chunks(L, N, 0, Cur, Acc)         -> chunks(L, N, N, [], [lists:reverse(Cur) | Acc]);
chunks([X | T], N, Left, Cur, Acc) -> chunks(T, N, Left - 1, [X | Cur], Acc).
