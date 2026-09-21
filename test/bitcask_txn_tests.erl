%% -------------------------------------------------------------------
%% bitcask_txn_tests:
%%   事务协调层（doc/txn-layer-design-zh.md §7）P1 覆盖：
%%     - 锁矩阵         兼容 / 重入 / 升级（locker 裸 API）
%%     - FIFO + 防写饿死 读者不准插到写等待者前面
%%     - 死锁           交叉加锁恰好一方受害并重跑成功；计数守恒
%%     - 重启预算       retries=0 → {aborted,{retry_limit,0}}
%%     - 死亡清理       持锁进程被 kill → 等待者放行
%%     - 缓冲语义       read-your-writes、delete 遮蔽、覆盖序、只读不提交
%%     - 提交失败       meck txn_commit → {aborted,{commit_failed,_}} 且锁清零
%%     - 真实 cask      多进程并发搬运计数器，总和守恒（mini-Jepsen）
%%     - 杂项           timeout / lock_wait_timeout / 嵌套 / index_fun /
%%                      跨 cask 同名 key 不冲突 / 非 owner 进程
%%
%%   ⚠️ 崩溃原子性归上游 C++ 测试，这里只测 BEAM 侧的锁与协议。
%% -------------------------------------------------------------------
-module(bitcask_txn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(L, bitcask_txn_locker).
-define(T, bitcask_txn).

%% 所有用例都要 locker 在跑；embedder 测试会 stop/start application，
%% 所以每个用例自己 ensure。
setup() ->
    catch application:load(bitcask),
    {ok, _} = application:ensure_all_started(bitcask),
    ok.

with_dir(Fun) ->
    setup(),
    Dir = "/tmp/bitcask_txn_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

open(D) -> bitcask:open(D, [read_write]).

%% 快速提交：测试里不需要每次 fsync。
-define(FAST, [{sync, no_sync}]).

int(Bin) -> binary_to_integer(Bin).
bin(Int) -> integer_to_binary(Int).

%% ---------- 锁测试用的"裸事务"进程 ----------
%%
%% 一个 agent 进程就是一个注册过的 TxnId，按指令去 acquire，把结果回报。
%% 阻塞中的 acquire 让 agent 自己挂在 gen_server:call 里，正好模拟真实事务。
%% release 之后事务就结束了（release_all 注销 TxnId），agent 自动以新 TxnId
%% 重新注册——测试里"同一个 agent"再 acquire 就是一个新事务。
%% agent monitor 测试进程：用例失败（进程 normal 退出，link 不传播）时
%% 也要跟着死，别把锁留给下一个用例。

agent_start() -> agent_start(#{}).

agent_start(Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
                         erlang:monitor(process, Parent),
                         agent_loop(Parent, undefined)
                     end),
    Pid ! {register, Opts},
    receive {Pid, {ok, TxnId}} -> {Pid, TxnId} end.

agent_loop(Parent, TxnId) ->
    receive
        {register, Opts} ->
            R = ?L:register(self(), Opts),
            Parent ! {self(), R},
            {ok, Id} = R,
            agent_loop(Parent, Id);
        {acquire, LockId, Mode} ->
            Parent ! {self(), {acquired, LockId, ?L:acquire(TxnId, LockId, Mode)}},
            agent_loop(Parent, TxnId);
        {release, Opts} ->
            ok = ?L:release_all(TxnId),
            {ok, Id} = ?L:register(self(), Opts),
            Parent ! {self(), released, ok},
            agent_loop(Parent, Id);
        stop ->
            ok = ?L:release_all(TxnId),
            Parent ! {self(), stopped};
        {'DOWN', _, process, Parent, _} ->
            ok
    end.

%% 锁的释放是异步的（cast），断言"锁表清零"要等一下：最多 1s，返回末次 status。
wait_clean() -> wait_clean(50).
wait_clean(0) -> ?L:status();
wait_clean(N) ->
    case ?L:status() of
        #{locks := 0, txns := 0, waiting := 0} = S -> S;
        _ -> timer:sleep(20), wait_clean(N - 1)
    end.

%% 发 acquire 指令；不等结果。
acq({Pid, _}, LockId, Mode) -> Pid ! {acquire, LockId, Mode}, ok.

%% 期望在 Ms 内收到 acquire 结果。
expect({Pid, _}, LockId, Ms) ->
    receive {Pid, {acquired, LockId, R}} -> R
    after Ms -> timeout
    end.

%% 期望 Ms 内**没有**结果（仍阻塞）。
blocked({Pid, _}, LockId) ->
    receive {Pid, {acquired, LockId, R}} -> {unexpected, R}
    after 150 -> blocked
    end.

rel(A) -> rel(A, #{}).

rel({Pid, _}, Opts) ->
    Pid ! {release, Opts},
    receive {Pid, released, ok} -> ok end.

%% 同步：agent 注销自己的事务后才回，之后看 status 不会撞上残留。
stop({Pid, _}) ->
    Pid ! stop,
    receive {Pid, stopped} -> ok end.

%% ===================================================================
%% 锁矩阵
%% ===================================================================

lock_matrix_test_() ->
    {"读读合并 / 读写互斥 / 写写互斥 / 重入 / 唯一 holder 升级",
     fun() ->
        setup(),
        K = {make_ref(), <<"k">>, point},
        A = agent_start(), B = agent_start(),
        %% read + read
        acq(A, K, read),  ?assertEqual(ok, expect(A, K, 500)),
        acq(B, K, read),  ?assertEqual(ok, expect(B, K, 500)),
        %% B 想升级：A 还持读 → 等
        acq(B, K, write), ?assertEqual(blocked, blocked(B, K)),
        rel(A),           ?assertEqual(ok, expect(B, K, 500)),
        %% B 持写：A 读要等
        acq(A, K, read),  ?assertEqual(blocked, blocked(A, K)),
        %% B 重入（写后读、写后写）立即 ok
        acq(B, K, read),  ?assertEqual(ok, expect(B, K, 500)),
        acq(B, K, write), ?assertEqual(ok, expect(B, K, 500)),
        rel(B),           ?assertEqual(ok, expect(A, K, 500)),
        %% A 唯一读 holder 升级 write：立即
        acq(A, K, write), ?assertEqual(ok, expect(A, K, 500)),
        %% B 写要等
        acq(B, K, write), ?assertEqual(blocked, blocked(B, K)),
        rel(A),           ?assertEqual(ok, expect(B, K, 500)),
        rel(B),
        ?assertMatch(#{locks := 0}, wait_clean()),
        stop(A), stop(B)
     end}.

%% ===================================================================
%% FIFO + 防写饿死
%% ===================================================================

fifo_no_writer_starvation_test_() ->
    {"读持有中来了写等待者，之后的读必须排在写后面",
     fun() ->
        setup(),
        K = {make_ref(), <<"k">>, point},
        R1 = agent_start(), W = agent_start(), R2 = agent_start(), R3 = agent_start(),
        acq(R1, K, read),  ?assertEqual(ok, expect(R1, K, 500)),
        acq(W, K, write),  ?assertEqual(blocked, blocked(W, K)),
        acq(R2, K, read),  ?assertEqual(blocked, blocked(R2, K)),   % 不准插队
        acq(R3, K, read),  ?assertEqual(blocked, blocked(R3, K)),
        rel(R1),
        ?assertEqual(ok, expect(W, K, 500)),                          % 写先
        ?assertEqual(blocked, blocked(R2, K)),
        rel(W),
        ?assertEqual(ok, expect(R2, K, 500)),                         % 读段合并
        ?assertEqual(ok, expect(R3, K, 500)),
        rel(R2), rel(R3),
        ?assertMatch(#{locks := 0}, wait_clean()),
        [stop(X) || X <- [R1, W, R2, R3]]
     end}.

%% ===================================================================
%% 死锁：locker 层直接检
%% ===================================================================

deadlock_detected_at_locker_test_() ->
    {"A:K1→K2，B:K2→K1：后闭环者拿 {error,deadlock}，另一方随后放行",
     fun() ->
        setup(),
        Ref = make_ref(),
        K1 = {Ref, <<"k1">>, point}, K2 = {Ref, <<"k2">>, point},
        A = agent_start(), B = agent_start(),
        acq(A, K1, write), ?assertEqual(ok, expect(A, K1, 500)),
        acq(B, K2, write), ?assertEqual(ok, expect(B, K2, 500)),
        acq(A, K2, write), ?assertEqual(blocked, blocked(A, K2)),
        #{deadlocks_total := D0} = ?L:status(),
        acq(B, K1, write), ?assertEqual({error, deadlock}, expect(B, K1, 500)),
        ?assertMatch(#{deadlocks_total := D1} when D1 =:= D0 + 1, ?L:status()),
        %% A 仍在等 K2；B 放锁后 A 拿到
        ?assertEqual(blocked, blocked(A, K2)),
        rel(B),
        ?assertEqual(ok, expect(A, K2, 500)),
        rel(A),
        ?assertMatch(#{locks := 0, waiting := 0}, wait_clean()),
        stop(A), stop(B)
     end}.

three_way_cycle_test_() ->
    {"三方环 A→B→C→A 也能检出（DFS 多跳）",
     fun() ->
        setup(),
        Ref = make_ref(),
        [K1, K2, K3] = [{Ref, K, point} || K <- [<<"1">>, <<"2">>, <<"3">>]],
        A = agent_start(), B = agent_start(), C = agent_start(),
        acq(A, K1, write), ok = expect(A, K1, 500),
        acq(B, K2, write), ok = expect(B, K2, 500),
        acq(C, K3, write), ok = expect(C, K3, 500),
        acq(A, K2, write), blocked = blocked(A, K2),
        acq(B, K3, write), blocked = blocked(B, K3),
        acq(C, K1, write), ?assertEqual({error, deadlock}, expect(C, K1, 500)),
        rel(C),
        ok = expect(B, K3, 500),
        rel(B),
        ok = expect(A, K2, 500),
        rel(A),
        ?assertMatch(#{locks := 0}, wait_clean()),
        [stop(X) || X <- [A, B, C]]
     end}.

%% ===================================================================
%% 死亡清理
%% ===================================================================

holder_death_releases_test_() ->
    {"持锁进程被 kill → 等待者放行；等待中被 kill → 出队不挡后面的人",
     fun() ->
        setup(),
        K = {make_ref(), <<"k">>, point},
        {PA, _} = A = agent_start(),
        B = agent_start(), C = agent_start(),
        process_flag(trap_exit, true),
        acq(A, K, write), ok = expect(A, K, 500),
        acq(B, K, write), blocked = blocked(B, K),
        acq(C, K, read),  blocked = blocked(C, K),
        %% 等待中的 B 死掉：C 仍被 A 挡着
        {PB, _} = B,
        exit(PB, kill), receive {'EXIT', PB, killed} -> ok end,
        ?assertEqual(blocked, blocked(C, K)),
        %% holder A 死掉：C 放行
        exit(PA, kill), receive {'EXIT', PA, killed} -> ok end,
        ?assertEqual(ok, expect(C, K, 500)),
        rel(C),
        process_flag(trap_exit, false),
        ?assertMatch(#{locks := 0, waiting := 0}, wait_clean()),
        stop(C)
     end}.

lock_wait_timeout_at_locker_test_() ->
    {"单锁等待兜底：到点 {error,lock_wait_timeout}，锁表不残留等待者",
     fun() ->
        setup(),
        K = {make_ref(), <<"k">>, point},
        A = agent_start(),
        B = agent_start(#{lock_wait_timeout => 100}),
        acq(A, K, write), ok = expect(A, K, 500),
        acq(B, K, write),
        ?assertEqual({error, lock_wait_timeout}, expect(B, K, 1000)),
        ?assertMatch(#{waiting := 0}, ?L:status()),
        rel(A), rel(B),
        stop(A), stop(B)
     end}.

%% ===================================================================
%% 门面：缓冲语义
%% ===================================================================

buffer_semantics_test_() ->
    {"read-your-writes / delete 遮蔽 / 覆盖序 / 提交后可见",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            ok = bitcask:put(R, <<"a">>, <<"1">>),
            ok = bitcask:put(R, <<"b">>, <<"2">>),
            Res = ?T:transaction(R, fun(Tx) ->
                ?assertEqual({ok, <<"1">>}, ?T:read(Tx, <<"a">>)),
                ok = ?T:write(Tx, <<"a">>, <<"10">>),
                ?assertEqual({ok, <<"10">>}, ?T:read(Tx, <<"a">>)),   % 读自己的写
                ok = ?T:write(Tx, <<"a">>, <<"11">>),                 % 覆盖：后者胜
                ok = ?T:delete(Tx, <<"b">>),
                ?assertEqual(not_found, ?T:read(Tx, <<"b">>)),         % delete 遮蔽
                ?assertEqual(not_found, ?T:read(Tx, <<"c">>)),
                ok = ?T:write(Tx, <<"c">>, <<"new">>),
                %% 事务中间态对直通读不可见（缓冲未提交）
                ?assertEqual({ok, <<"1">>}, bitcask:get(R, <<"a">>)),
                done
            end, ?FAST),
            ?assertEqual({atomic, done}, Res),
            ?assertEqual({ok, <<"11">>}, bitcask:get(R, <<"a">>)),
            ?assertEqual(not_found, bitcask:get(R, <<"b">>)),
            ?assertEqual({ok, <<"new">>}, bitcask:get(R, <<"c">>)),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}.

readonly_and_abort_test_() ->
    {"只读事务不碰引擎；abort/1 不写不重跑；Fun 异常 → {aborted,{R,Stack}}",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            ok = bitcask:put(R, <<"a">>, <<"1">>),
            ?assertEqual({atomic, {ok, <<"1">>}},
                         ?T:transaction(R, fun(Tx) -> ?T:read(Tx, <<"a">>) end)),
            ?assertEqual({aborted, nope},
                         ?T:transaction(R, fun(Tx) ->
                             ok = ?T:write(Tx, <<"a">>, <<"9">>),
                             ?T:abort(nope)
                         end)),
            ?assertEqual({ok, <<"1">>}, bitcask:get(R, <<"a">>)),
            ?assertMatch({aborted, {badarith, _}},
                         ?T:transaction(R, fun(Tx) ->
                             ok = ?T:write(Tx, <<"a">>, <<"9">>),
                             1 / 0
                         end)),
            ?assertEqual({aborted, {throw, oops}},
                         ?T:transaction(R, fun(_Tx) -> throw(oops) end)),
            ?assertEqual({ok, <<"1">>}, bitcask:get(R, <<"a">>)),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}.

nested_and_not_owner_test_() ->
    {"嵌套 → {aborted,tx_nested}；别的进程用 Tx → error not_owner",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            ?assertEqual({atomic, {aborted, tx_nested}},
                         ?T:transaction(R, fun(_Tx) ->
                             ?T:transaction(R, fun(_) -> inner end)
                         end)),
            %% 外层结束后再开事务不受影响（ACTIVE 标记已清）
            ?assertEqual({atomic, ok}, ?T:transaction(R, fun(_) -> ok end)),
            Res = ?T:transaction(R, fun(Tx) ->
                Parent = self(),
                spawn(fun() ->
                    Parent ! {other, catch ?T:read(Tx, <<"a">>)}
                end),
                receive {other, X} -> X end
            end),
            ?assertMatch({atomic, {'EXIT', {{bitcask_txn, not_owner}, _}}}, Res),
            bitcask:close(R)
        end)
     end}.

%% ===================================================================
%% 门面：死锁重跑 + 计数守恒
%% ===================================================================

%% 两阶段栅栏：前 N 个到达者互等；之后（重跑时）直接放行。
%% 测试专用——Fun 里带副作用是给死锁"制造确定性"的手段，不是使用示范。
barrier_start(N) ->
    spawn_link(fun() -> barrier_loop(N, []) end).

barrier_loop(0, _) ->
    receive {arrive, From} -> From ! go, barrier_loop(0, []) end;
barrier_loop(N, Waiting) ->
    receive
        {arrive, From} ->
            case [From | Waiting] of
                All when length(All) =:= N ->
                    [P ! go || P <- All], barrier_loop(0, []);
                All ->
                    barrier_loop(N, All)
            end
    end.

barrier_wait(B) -> B ! {arrive, self()}, receive go -> ok end.

transfer(Tx, From, To, Amount) ->
    {ok, F} = ?T:read(Tx, From),
    {ok, T} = ?T:read(Tx, To),
    ok = ?T:write(Tx, From, bin(int(F) - Amount)),
    ok = ?T:write(Tx, To, bin(int(T) + Amount)),
    ok.

deadlock_restart_conserves_test_() ->
    {"对称转账死锁：一方重跑，双方最终 atomic，总额守恒",
     {timeout, 30, fun() ->
        with_dir(fun(D) ->
            R = open(D),
            ok = bitcask:put(R, <<"x">>, <<"100">>),
            ok = bitcask:put(R, <<"y">>, <<"100">>),
            B = barrier_start(2),
            Parent = self(),
            #{deadlocks_total := D0} = ?L:status(),
            Spawn = fun(From, To) ->
                spawn_link(fun() ->
                    Res = ?T:transaction(R, fun(Tx) ->
                        {ok, F} = ?T:read(Tx, From),
                        ok = ?T:write(Tx, From, bin(int(F) - 10)),
                        barrier_wait(B),           % 双方都拿到第一把锁后再交叉
                        {ok, T} = ?T:read(Tx, To),
                        ok = ?T:write(Tx, To, bin(int(T) + 10)),
                        ok
                    end, ?FAST),
                    Parent ! {done, self(), Res}
                end)
            end,
            P1 = Spawn(<<"x">>, <<"y">>),
            P2 = Spawn(<<"y">>, <<"x">>),
            Results = [receive {done, P, Res} -> Res end || P <- [P1, P2]],
            ?assertEqual([{atomic, ok}, {atomic, ok}], Results),
            {ok, X} = bitcask:get(R, <<"x">>),
            {ok, Y} = bitcask:get(R, <<"y">>),
            ?assertEqual(200, int(X) + int(Y)),
            ?assertMatch(#{deadlocks_total := D1} when D1 > D0, ?L:status()),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}}.

retry_limit_test_() ->
    {"retries=0：死锁一次即 {aborted,{retry_limit,0}}，缓冲丢弃",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            ok = bitcask:put(R, <<"k1">>, <<"0">>),
            ok = bitcask:put(R, <<"k2">>, <<"0">>),
            {Ref, _} = R,
            %% A：裸事务持 k1，并在 B 拿到 k2 后去等 k2
            A = agent_start(),
            acq(A, {Ref, <<"k1">>, point}, write), ok = expect(A, {Ref, <<"k1">>, point}, 500),
            Res = ?T:transaction(R, fun(Tx) ->
                ok = ?T:write(Tx, <<"k2">>, <<"1">>),
                acq(A, {Ref, <<"k2">>, point}, write),
                blocked = blocked(A, {Ref, <<"k2">>, point}),
                ok = ?T:write(Tx, <<"k1">>, <<"1">>),   % 闭环 → 自己是受害者
                unreachable
            end, [{retries, 0} | ?FAST]),
            ?assertEqual({aborted, {retry_limit, 0}}, Res),
            ?assertEqual({ok, <<"0">>}, bitcask:get(R, <<"k2">>)),
            %% B 退出后 A 拿到 k2
            ?assertEqual(ok, expect(A, {Ref, <<"k2">>, point}, 500)),
            rel(A), stop(A),
            bitcask:close(R)
        end)
     end}.

lock_wait_timeout_restarts_test_() ->
    {"lock_wait_timeout 触发按死锁处理：重跑直到预算耗尽",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            {Ref, _} = R,
            A = agent_start(),
            acq(A, {Ref, <<"k">>, point}, write), ok = expect(A, {Ref, <<"k">>, point}, 500),
            Cnt = counters:new(1, []),
            Res = ?T:transaction(R, fun(Tx) ->
                counters:add(Cnt, 1, 1),
                ?T:write(Tx, <<"k">>, <<"v">>)
            end, [{retries, 2}, {lock_wait_timeout, 50} | ?FAST]),
            ?assertEqual({aborted, {retry_limit, 2}}, Res),
            ?assertEqual(3, counters:get(Cnt, 1)),    % 1 次 + 2 次重跑
            rel(A), stop(A),
            bitcask:close(R)
        end)
     end}.

timeout_test_() ->
    {"{timeout,Ms} 总预算：过点后的 read/write/commit 都 {aborted,timeout}，不重跑",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            Cnt = counters:new(1, []),
            Res = ?T:transaction(R, fun(Tx) ->
                counters:add(Cnt, 1, 1),
                timer:sleep(80),
                ?T:write(Tx, <<"k">>, <<"v">>)
            end, [{timeout, 30} | ?FAST]),
            ?assertEqual({aborted, timeout}, Res),
            ?assertEqual(1, counters:get(Cnt, 1)),
            ?assertEqual(not_found, bitcask:get(R, <<"k">>)),
            %% 等锁期间过 deadline 同样 timeout
            {Ref, _} = R,
            A = agent_start(),
            acq(A, {Ref, <<"k">>, point}, write), ok = expect(A, {Ref, <<"k">>, point}, 500),
            ?assertEqual({aborted, timeout},
                         ?T:transaction(R, fun(Tx) -> ?T:write(Tx, <<"k">>, <<"v">>) end,
                                        [{timeout, 50} | ?FAST])),
            rel(A), stop(A),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}.

%% ===================================================================
%% 门面：提交失败 / 持锁进程死亡
%% ===================================================================

commit_failed_test_() ->
    {"txn_commit 返回错误 → {aborted,{commit_failed,_}}，锁全放",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            meck:new(bitcask, [passthrough]),
            meck:expect(bitcask, txn_commit, fun(_, _, _) -> {error, io_error} end),
            try
                ?assertEqual({aborted, {commit_failed, io_error}},
                             ?T:transaction(R, fun(Tx) -> ?T:write(Tx, <<"k">>, <<"v">>) end)),
                ?assertMatch(#{locks := 0, txns := 0}, wait_clean())
            after
                meck:unload(bitcask)
            end,
            ?assertEqual(not_found, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
     end}.

txn_process_death_test_() ->
    {"事务进程在 Fun 中被 kill → 锁清理，等待的事务继续",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            Parent = self(),
            P1 = spawn(fun() ->
                ?T:transaction(R, fun(Tx) ->
                    ok = ?T:write(Tx, <<"k">>, <<"p1">>),
                    Parent ! {self(), holding},
                    receive never -> ok end
                end)
            end),
            receive {P1, holding} -> ok end,
            P2 = spawn_link(fun() ->
                Parent ! {self(), ?T:transaction(R, fun(Tx) ->
                                        ?T:write(Tx, <<"k">>, <<"p2">>)
                                    end, ?FAST)}
            end),
            receive {P2, _} -> ?assert(false) after 150 -> ok end,   % 确实在等
            exit(P1, kill),
            ?assertEqual({atomic, ok}, receive {P2, Res} -> Res after 2000 -> timeout end),
            ?assertEqual({ok, <<"p2">>}, bitcask:get(R, <<"k">>)),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}.

%% ===================================================================
%% index_fun / 跨 cask
%% ===================================================================

index_fun_test_() ->
    {"index_fun 的额外 op 与主数据同批原子提交；与缓冲 key 重合 → index_conflict",
     fun() ->
        with_dir(fun(D) ->
            R = open(D),
            IdxFun = fun(K, {put, V}) -> [{put, <<"idx:", V/binary>>, K}];
                        (K, delete)   -> [{remove, <<"idx_del:", K/binary>>}]
                     end,
            ?assertEqual({atomic, ok},
                         ?T:transaction(R, fun(Tx) -> ?T:write(Tx, <<"a">>, <<"v1">>) end,
                                        [{index_fun, IdxFun} | ?FAST])),
            ?assertEqual({ok, <<"a">>}, bitcask:get(R, <<"idx:v1">>)),
            ?assertEqual({aborted, {index_conflict, <<"idx:v1">>}},
                         ?T:transaction(R, fun(Tx) ->
                             ok = ?T:write(Tx, <<"idx:v1">>, <<"clobber">>),
                             ?T:write(Tx, <<"b">>, <<"v1">>)
                         end, [{index_fun, IdxFun} | ?FAST])),
            ?assertEqual(not_found, bitcask:get(R, <<"b">>)),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}.

cross_cask_no_conflict_test_() ->
    {"两个 cask 的同名 key 互不阻塞（LockId 带 cask ref）",
     fun() ->
        with_dir(fun(D1) ->
            with_dir(fun(D2) ->
                R1 = open(D1), R2 = open(D2),
                {Ref1, _} = R1,
                A = agent_start(),
                acq(A, {Ref1, <<"k">>, point}, write), ok = expect(A, {Ref1, <<"k">>, point}, 500),
                ?assertEqual({atomic, ok},
                             ?T:transaction(R2, fun(Tx) -> ?T:write(Tx, <<"k">>, <<"v">>) end,
                                            [{lock_wait_timeout, 200}, {retries, 0} | ?FAST])),
                rel(A), stop(A),
                bitcask:close(R1), bitcask:close(R2)
            end)
        end)
     end}.

%% ===================================================================
%% 真实 cask：并发搬运，总额守恒
%% ===================================================================

concurrent_transfers_conserve_test_() ->
    {"8 进程 × 40 次随机转账，10 个账户总额守恒，无锁泄漏",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = open(D),
            NAcc = 10, NProc = 8, NIter = 40, Init = 1000,
            Acc = fun(I) -> <<"acc", (bin(I))/binary>> end,
            [ok = bitcask:put(R, Acc(I), bin(Init)) || I <- lists:seq(1, NAcc)],
            Parent = self(),
            Pids = [spawn_link(fun() ->
                        rand:seed(exsss, {Seed, Seed, Seed}),
                        Rs = [begin
                                  From = Acc(rand:uniform(NAcc)),
                                  To   = Acc(rand:uniform(NAcc)),
                                  case From =:= To of
                                      true  -> {atomic, skip};
                                      false ->
                                          ?T:transaction(R, fun(Tx) ->
                                              transfer(Tx, From, To, rand:uniform(5))
                                          end, [{retries, infinity} | ?FAST])
                                  end
                              end || _ <- lists:seq(1, NIter)],
                        Parent ! {self(), Rs}
                    end) || Seed <- lists:seq(1, NProc)],
            All = lists:append([receive {P, Rs} -> Rs end || P <- Pids]),
            ?assertEqual([], [X || X <- All, element(1, X) =/= atomic]),
            Sum = lists:sum([int(element(2, bitcask:get(R, Acc(I)))) || I <- lists:seq(1, NAcc)]),
            ?assertEqual(NAcc * Init, Sum),
            ?assertMatch(#{locks := 0, txns := 0, waiting := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}}.

%% ===================================================================
%% 前缀锁（X1-6 / 设计 P2）
%% ===================================================================

prefix_lock_matrix_test_() ->
    {"前缀 vs 点：覆盖即冲突（双向）；不相干前缀互不挡；读读合并；扩展前缀冲突",
     fun() ->
        setup(),
        Ref = make_ref(),
        P  = {Ref, <<"ab">>, prefix},
        PL = {Ref, <<"abx">>, prefix},         % 更长的前缀（被 P 罩住，罩住 K1）
        Q  = {Ref, <<"b">>, prefix},           % 不相干
        K1 = {Ref, <<"abx">>, point},          % P 之下
        K2 = {Ref, <<"zz">>, point},           % P 之外
        A = agent_start(), B = agent_start(), C = agent_start(),
        %% 前缀写挡点写/点读，不挡外面的
        acq(A, P, write),  ok = expect(A, P, 500),
        acq(B, K1, write), ?assertEqual(blocked, blocked(B, K1)),
        acq(C, K2, read),  ok = expect(C, K2, 500),     % P 之外：无关
        rel(A),            ok = expect(B, K1, 500),
        %% 点写挡前缀读；不相干前缀不挡
        acq(A, P, read),   ?assertEqual(blocked, blocked(A, P)),
        acq(C, Q, write),  ok = expect(C, Q, 500),
        rel(B),            ok = expect(A, P, 500),
        rel(C),
        %% 前缀读 + 点读合并；点写等
        acq(B, K1, read),  ok = expect(B, K1, 500),
        acq(B, K1, write), ?assertEqual(blocked, blocked(B, K1)),
        rel(A),            ok = expect(B, K1, 500),
        %% 扩展前缀：PL 写 vs P 读
        acq(A, PL, write), ?assertEqual(blocked, blocked(A, PL)),   % B 持 K1 写在 PL 下
        rel(B),            ok = expect(A, PL, 500),
        acq(B, P, read),   ?assertEqual(blocked, blocked(B, P)),
        rel(A),            ok = expect(B, P, 500),
        rel(B),
        ?assertMatch(#{locks := 0, prefix_locks := 0, waiting := 0}, wait_clean()),
        stop(A), stop(B), stop(C)
     end}.

%% 找一把落在 Pred(Shard) 为真的分片上的点锁（前缀固定，枚举后缀）。
key_in_shard(Ref, Prefix, Pred) ->
    hd([K || I <- lists:seq(1, 1000),
             K <- [{Ref, <<Prefix/binary, I:16>>, point}],
             Pred(?L:shard_of(K))]).

prefix_writer_fairness_test_() ->
    {"前缀写等待者不被后来的点请求饿死（跨记录 FIFO；分片版只对已到达的分片成立）",
     fun() ->
        setup(),
        Ref = make_ref(),
        P = {Ref, <<"e">>, prefix},
        %% 前缀写按分片序推进：它卡在 K1 所在分片时，已持有编号更小的分片——
        %% K2 必须落在这样的分片上，后来的点请求才会排在它后面。
        N = ?L:shard_count(),
        K1 = key_in_shard(Ref, <<"e">>, fun(S) -> S =:= N end),
        K2 = key_in_shard(Ref, <<"e">>, fun(S) -> S < N orelse N =:= 1 end),
        H = agent_start(), W = agent_start(), L = agent_start(),
        acq(H, K1, write), ok = expect(H, K1, 500),
        acq(W, P, write),  ?assertEqual(blocked, blocked(W, P)),   % 等 H
        acq(L, K2, write), ?assertEqual(blocked, blocked(L, K2)),  % 空闲 key，但排在 W 后
        rel(H),
        ok = expect(W, P, 500),
        ?assertEqual(blocked, blocked(L, K2)),
        rel(W),
        ok = expect(L, K2, 500),
        rel(L),
        ?assertMatch(#{locks := 0, prefix_locks := 0}, wait_clean()),
        [stop(X) || X <- [H, W, L]]
     end}.

prefix_covered_is_free_test_() ->
    {"持前缀写锁后其下点锁免费：不建记录、不过 locker；死锁经前缀锁也能检出",
     fun() ->
        setup(),
        Ref = make_ref(),
        P = {Ref, <<"p">>, prefix},
        A = agent_start(), B = agent_start(),
        acq(A, P, write), ok = expect(A, P, 500),
        [begin acq(A, {Ref, <<"p", I>>, point}, write), ok = expect(A, {Ref, <<"p", I>>, point}, 500) end
         || I <- lists:seq(1, 20)],
        %% 前缀锁每个分片一条记录，点锁一条都没建
        N = ?L:shard_count(),
        ?assertMatch(#{locks := N, prefix_locks := N}, ?L:status()),
        %% 死锁：B 持 q 点锁等 P 下的 key；A 持 P 要 q
        acq(B, {Ref, <<"q">>, point}, write), ok = expect(B, {Ref, <<"q">>, point}, 500),
        acq(B, {Ref, <<"p9">>, point}, read), ?assertEqual(blocked, blocked(B, {Ref, <<"p9">>, point})),
        acq(A, {Ref, <<"q">>, point}, read),
        ?assertEqual({error, deadlock}, expect(A, {Ref, <<"q">>, point}, 500)),
        rel(A), ok = expect(B, {Ref, <<"p9">>, point}, 500),
        rel(B),
        ?assertMatch(#{locks := 0, prefix_locks := 0}, wait_clean()),
        stop(A), stop(B)
     end}.

prefix_range_phantom_test_() ->
    {"prefix_range：合并本事务缓冲；持前缀读锁期间并发插入被挡（无幻读）",
     {timeout, 30, fun() ->
        with_dir(fun(D) ->
            R = open(D),
            [ok = bitcask:put(R, <<"u:", I>>, <<I>>) || I <- lists:seq(1, 5)],
            ok = bitcask:put(R, <<"v:1">>, <<"other">>),
            Parent = self(),
            Scanner = spawn_link(fun() ->
                Res = ?T:transaction(R, fun(Tx) ->
                    First = ?T:prefix_range(Tx, <<"u:">>),
                    Parent ! {self(), scanned, length(First)},
                    receive go -> ok end,            % 测试专用同步（Fun 不会重跑）
                    ok = ?T:write(Tx, <<"u:", 7>>, <<"mine">>),
                    ok = ?T:delete(Tx, <<"u:", 1>>),
                    Second = ?T:prefix_range(Tx, <<"u:">>),
                    {length(First), Second}
                end, ?FAST),
                Parent ! {self(), Res}
            end),
            receive {Scanner, scanned, 5} -> ok end,
            %% 并发写者想插 u:9：前缀读锁在手，必须等
            spawn_link(fun() ->
                Parent ! {writer, ?T:transaction(R, fun(Tx) ->
                                       ?T:write(Tx, <<"u:", 9>>, <<"phantom">>)
                                   end, ?FAST)}
            end),
            receive {writer, _} -> ?assert(false) after 150 -> ok end,
            Scanner ! go,
            {atomic, {5, Second}} = receive {Scanner, Res} -> Res end,
            %% 缓冲合并：u:1 没了、u:7 有了、u:9 不可见
            ?assertEqual([<<"u:", I>> || I <- [2, 3, 4, 5, 7]], [K || {K, _} <- Second]),
            ?assertEqual(<<"mine">>, proplists:get_value(<<"u:", 7>>, Second)),
            ?assertEqual({atomic, ok}, receive {writer, W} -> W after 2000 -> timeout end),
            ?assertEqual({ok, <<"phantom">>}, bitcask:get(R, <<"u:", 9>>)),
            ?assertEqual(not_found, bitcask:get(R, <<"u:", 1>>)),
            ?assertMatch(#{locks := 0, prefix_locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}}.

%% ===================================================================
%% 分片（X1-7）
%% ===================================================================


cross_shard_deadlock_test_() ->
    {"两把锁明确落在不同分片：A:K1→K2，B:K2→K1 → 跨分片 DFS 检出",
     fun() ->
        setup(),
        N = ?L:shard_count(),
        ?assert(N >= 2),
        Ref = make_ref(),
        K1 = key_in_shard(Ref, <<"x">>, fun(S) -> S =:= 1 end),
        K2 = key_in_shard(Ref, <<"x">>, fun(S) -> S =:= N end),
        A = agent_start(), B = agent_start(),
        acq(A, K1, write), ok = expect(A, K1, 500),
        acq(B, K2, write), ok = expect(B, K2, 500),
        acq(A, K2, write), ?assertEqual(blocked, blocked(A, K2)),
        acq(B, K1, write), ?assertEqual({error, deadlock}, expect(B, K1, 500)),
        rel(B), ok = expect(A, K2, 500),
        rel(A),
        ?assertMatch(#{locks := 0, waiting := 0}, wait_clean()),
        stop(A), stop(B)
     end}.

death_cleanup_across_shards_test_() ->
    {"持有跨分片的 20 把点锁 + 1 把前缀锁的进程被 kill → 全部分片清零，等待者放行",
     fun() ->
        setup(),
        Ref = make_ref(),
        {PA, _} = A = agent_start(), B = agent_start(),
        process_flag(trap_exit, true),
        Ks = [{Ref, <<"d", I>>, point} || I <- lists:seq(1, 20)],
        [begin acq(A, K, write), ok = expect(A, K, 500) end || K <- Ks],
        acq(A, {Ref, <<"pre">>, prefix}, write), ok = expect(A, {Ref, <<"pre">>, prefix}, 500),
        ?assert(length(lists:usort([?L:shard_of(K) || K <- Ks])) > 1),
        acq(B, {Ref, <<"pre", 1>>, point}, write),
        ?assertEqual(blocked, blocked(B, {Ref, <<"pre", 1>>, point})),
        exit(PA, kill), receive {'EXIT', PA, killed} -> ok end,
        ?assertEqual(ok, expect(B, {Ref, <<"pre", 1>>, point}, 1000)),
        rel(B), stop(B),
        process_flag(trap_exit, false),
        ?assertMatch(#{locks := 0, prefix_locks := 0, txns := 0}, wait_clean())
     end}.

shard_crash_aborts_txn_test_() ->
    {"某个分片崩溃 → one_for_all 全部重启，进行中的事务下一步 {aborted, locker_restarted}",
     {timeout, 30, fun() ->
        with_dir(fun(D) ->
            R = open(D),
            Parent = self(),
            P = spawn_link(fun() ->
                Res = ?T:transaction(R, fun(Tx) ->
                    ok = ?T:write(Tx, <<"a">>, <<"1">>),
                    Parent ! {self(), holding},
                    receive go -> ok end,
                    ?T:write(Tx, <<"b">>, <<"2">>)          %% 新分片不认识这个事务
                end, ?FAST),
                Parent ! {self(), Res}
            end),
            receive {P, holding} -> ok end,
            Shard = whereis(bitcask_txn_locker_1),
            exit(Shard, kill),
            %% 等 supervisor 把整组拉起来
            ok = wait_for(fun() -> is_pid(whereis(bitcask_txn_locker_1))
                                   andalso whereis(bitcask_txn_locker_1) =/= Shard
                                   andalso ets:info(bitcask_txn_txns) =/= undefined end),
            P ! go,
            ?assertEqual({aborted, locker_restarted}, receive {P, Res} -> Res after 5000 -> timeout end),
            ?assertEqual(not_found, bitcask:get(R, <<"a">>)),
            %% 重启后照常工作
            ?assertEqual({atomic, ok}, ?T:transaction(R, fun(Tx) -> ?T:write(Tx, <<"c">>, <<"3">>) end, ?FAST)),
            ?assertMatch(#{locks := 0, txns := 0}, wait_clean()),
            bitcask:close(R)
        end)
     end}}.

wait_for(Pred) -> wait_for(Pred, 100).
wait_for(_Pred, 0) -> timeout;
wait_for(Pred, N) ->
    case catch Pred() of
        true -> ok;
        _    -> timer:sleep(20), wait_for(Pred, N - 1)
    end.
