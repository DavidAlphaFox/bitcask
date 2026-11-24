%% -------------------------------------------------------------------
%% bitcask_cond_batch_tests:
%%   libbitcask 8.0.0（S46）原子批前置条件在 NIF / 门面上的形态：
%%     - get_with_ord/2           带回 key 当前的 LSN
%%     - {put,K,V,Cond} / {remove,K,Cond} / {check,K,Cond}，Cond = absent | {ord,N}
%%     - 条件不成立 → {error, {conflict, OpIndex}}（从 1 起），整批零副作用
%%     - put_batch_atomic/3 的 return_ords；txn_commit 透传条件
%%     - 形态不认 → badarg
%%     - bitcask_txn:read_guarded/3：直通写插进来 → 事务冲突重跑，不丢更新
%% -------------------------------------------------------------------
-module(bitcask_cond_batch_tests).

-include_lib("eunit/include/eunit.hrl").

with_cask(Fun) ->
    bitcask_test_util:with_dir("bitcask_cond_batch_", fun(D) ->
        H = bitcask:open(D, [read_write]),
        try Fun(H) after bitcask:close(H) end
    end).

get_with_ord_test_() ->
    {"get_with_ord：值同 get/2；每次写入 LSN 变大；不存在 → not_found",
     fun() ->
        with_cask(fun(H) ->
            ?assertEqual(not_found, bitcask:get_with_ord(H, <<"k">>)),
            ok = bitcask:put(H, <<"k">>, <<"v1">>),
            {ok, <<"v1">>, O1} = bitcask:get_with_ord(H, <<"k">>),
            ok = bitcask:put(H, <<"k">>, <<"v2">>),
            {ok, <<"v2">>, O2} = bitcask:get_with_ord(H, <<"k">>),
            ?assert(O2 > O1),
            ok = bitcask:delete(H, <<"k">>),
            ?assertEqual(not_found, bitcask:get_with_ord(H, <<"k">>))
        end)
     end}.

ord_condition_test_() ->
    {"{ord, N}：对上了才写；过期的 N → {error, {conflict, I}}，同批其它 op 也不写",
     fun() ->
        with_cask(fun(H) ->
            ok = bitcask:put(H, <<"a">>, <<"1">>),
            {ok, _, Oa} = bitcask:get_with_ord(H, <<"a">>),
            ok = bitcask:put_batch_atomic(H, [{put, <<"a">>, <<"2">>, {ord, Oa}},
                                              {put, <<"b">>, <<"x">>}]),
            ?assertEqual({ok, <<"2">>}, bitcask:get(H, <<"a">>)),
            %% Oa 已过期
            ?assertEqual({error, {conflict, 2}},
                         bitcask:put_batch_atomic(H, [{put, <<"c">>, <<"no">>},
                                                      {put, <<"a">>, <<"3">>, {ord, Oa}}])),
            ?assertEqual({ok, <<"2">>}, bitcask:get(H, <<"a">>)),
            ?assertEqual(not_found, bitcask:get(H, <<"c">>)),
            %% remove 带条件
            {ok, _, Oa2} = bitcask:get_with_ord(H, <<"a">>),
            ?assertEqual({error, {conflict, 1}},
                         bitcask:put_batch_atomic(H, [{remove, <<"a">>, {ord, Oa}}])),
            ok = bitcask:put_batch_atomic(H, [{remove, <<"a">>, {ord, Oa2}}]),
            ?assertEqual(not_found, bitcask:get(H, <<"a">>))
        end)
     end}.

absent_and_check_test_() ->
    {"absent：只创建一次；check：只校验不写；条件对照批前状态",
     fun() ->
        with_cask(fun(H) ->
            ok = bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"first">>, absent}]),
            ?assertEqual({error, {conflict, 1}},
                         bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"second">>, absent}])),
            ?assertEqual({ok, <<"first">>}, bitcask:get(H, <<"k">>)),
            {ok, _, Ok} = bitcask:get_with_ord(H, <<"k">>),
            ok = bitcask:put_batch_atomic(H, [{check, <<"k">>, {ord, Ok}},
                                              {check, <<"none">>, absent},
                                              {put, <<"other">>, <<"o">>}]),
            ?assertEqual(not_found, bitcask:get(H, <<"none">>)),
            ?assertEqual({error, {conflict, 1}},
                         bitcask:put_batch_atomic(H, [{check, <<"k">>, absent},
                                                      {put, <<"other">>, <<"p">>}])),
            ?assertEqual({ok, <<"o">>}, bitcask:get(H, <<"other">>)),
            %% 批内同 key 两次：第二个条件仍对照批前（不存在）
            ok = bitcask:put_batch_atomic(H, [{put, <<"n">>, <<"1">>, absent},
                                              {put, <<"n">>, <<"2">>, absent}]),
            ?assertEqual({ok, <<"2">>}, bitcask:get(H, <<"n">>))
        end)
     end}.

return_ords_test_() ->
    {"return_ords：成功带回各 op 的 LSN（check 为 0），可直接当下一轮条件；失败照常 conflict",
     fun() ->
        with_cask(fun(H) ->
            ok = bitcask:put(H, <<"c">>, <<"0">>),
            {ok, _, O0} = bitcask:get_with_ord(H, <<"c">>),
            {ok, [O1, 0]} = bitcask:put_batch_atomic(H, [{put, <<"c">>, <<"1">>, {ord, O0}},
                                                         {check, <<"z">>, absent}],
                                                     [return_ords]),
            {ok, <<"1">>, O1} = bitcask:get_with_ord(H, <<"c">>),
            {ok, [_]} = bitcask:put_batch_atomic(H, [{put, <<"c">>, <<"2">>, {ord, O1}}], [return_ords]),
            ?assertEqual({error, {conflict, 1}},
                         bitcask:put_batch_atomic(H, [{put, <<"c">>, <<"3">>, {ord, O1}}], [return_ords])),
            ?assertEqual({ok, []}, bitcask:put_batch_atomic(H, [], [return_ords])),
            ok = bitcask:put_batch_atomic(H, [{put, <<"d">>, <<"x">>}], [])
        end)
     end}.

txn_commit_conditions_test_() ->
    {"txn_commit 透传条件：冲突 → {error, {conflict, I}}，零副作用",
     fun() ->
        with_cask(fun(H) ->
            ok = bitcask:put(H, <<"a">>, <<"1">>),
            {ok, _, Oa} = bitcask:get_with_ord(H, <<"a">>),
            ok = bitcask:put(H, <<"a">>, <<"2">>),
            ?assertEqual({error, {conflict, 2}},
                         bitcask:txn_commit(H, [{put, <<"b">>, <<"x">>},
                                                {put, <<"a">>, <<"3">>, {ord, Oa}}])),
            ?assertEqual(not_found, bitcask:get(H, <<"b">>)),
            {ok, _, Oa2} = bitcask:get_with_ord(H, <<"a">>),
            ok = bitcask:txn_commit(H, [{put, <<"a">>, <<"3">>, {ord, Oa2}},
                                        {check, <<"c">>, absent}]),
            ?assertEqual({ok, <<"3">>}, bitcask:get(H, <<"a">>))
        end)
     end}.

bad_shapes_test_() ->
    {"形态不认 → badarg：未知 Cond、负 ord、check 不带条件、元数不符",
     fun() ->
        with_cask(fun(H) ->
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"v">>, bogus_cond}])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"v">>, {ord, -1}}])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{check, <<"k">>}])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{remove, <<"k">>, absent, x}])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"v">>}], [bogus])),
            ?assertEqual(not_found, bitcask:get(H, <<"k">>))
        end)
     end}.

concurrent_cas_counter_test_() ->
    {"8 进程 × 100 次 get_with_ord + {ord, N} 自增，冲突重试：总数精确",
     {timeout, 60, fun() ->
        with_cask(fun(H) ->
            ok = bitcask:put(H, <<"ctr">>, <<0:64>>),
            Parent = self(),
            Ps = [spawn_link(fun() ->
                      [cas_incr(H) || _ <- lists:seq(1, 100)],
                      Parent ! {self(), done}
                  end) || _ <- lists:seq(1, 8)],
            [receive {P, done} -> ok end || P <- Ps],
            ?assertEqual({ok, <<800:64>>}, bitcask:get(H, <<"ctr">>))
        end)
     end}}.

cas_incr(H) ->
    {ok, <<N:64>>, O} = bitcask:get_with_ord(H, <<"ctr">>),
    case bitcask:put_batch_atomic(H, [{put, <<"ctr">>, <<(N + 1):64>>, {ord, O}}]) of
        ok                     -> ok;
        {error, {conflict, 1}} -> cas_incr(H)
    end.

%% ===================================================================
%% bitcask_txn:read_guarded/3
%% ===================================================================

with_txn_cask(Fun) ->
    catch application:load(bitcask),
    {ok, _} = application:ensure_all_started(bitcask),
    with_cask(Fun).

read_guarded_restart_test_() ->
    {"read_guarded 之后直通写改了同一个 key → 提交冲突、事务重跑，读到新值（不覆盖直通写）",
     fun() ->
        with_txn_cask(fun(H) ->
            ok = bitcask:put(H, <<"k">>, <<1:64>>),
            Runs = counters:new(1, []),
            Res = bitcask_txn:transaction(H, fun(Tx) ->
                      counters:add(Runs, 1, 1),
                      {ok, <<N:64>>} = bitcask_txn:read_guarded(Tx, <<"k">>, write),
                      case counters:get(Runs, 1) of
                          1 -> ok = bitcask:put(H, <<"k">>, <<100:64>>);   %% 只在第一次插一脚
                          _ -> ok
                      end,
                      ok = bitcask_txn:write(Tx, <<"k">>, <<(N + 1):64>>),
                      N
                  end, [{sync, no_sync}]),
            ?assertEqual({atomic, 100}, Res),
            ?assertEqual(2, counters:get(Runs, 1)),
            ?assertEqual({ok, <<101:64>>}, bitcask:get(H, <<"k">>))
        end)
     end}.

read_guarded_check_test_() ->
    {"只读过的守卫 key 变成 check：被直通写改过 → 重跑；不存在的 key 守卫为 absent",
     fun() ->
        with_txn_cask(fun(H) ->
            Runs = counters:new(1, []),
            Res = bitcask_txn:transaction(H, fun(Tx) ->
                      counters:add(Runs, 1, 1),
                      R = bitcask_txn:read_guarded(Tx, <<"flag">>, read),
                      case counters:get(Runs, 1) of
                          1 -> ok = bitcask:put(H, <<"flag">>, <<"on">>);
                          _ -> ok
                      end,
                      ok = bitcask_txn:write(Tx, <<"out">>, term_to_binary(R)),
                      R
                  end, [{sync, no_sync}]),
            ?assertEqual({atomic, {ok, <<"on">>}}, Res),
            ?assertEqual(2, counters:get(Runs, 1)),
            ?assertEqual({ok, term_to_binary({ok, <<"on">>})}, bitcask:get(H, <<"out">>)),
            %% 普通 read/3 不守卫：同样插一脚，不重跑
            Runs2 = counters:new(1, []),
            {atomic, _} = bitcask_txn:transaction(H, fun(Tx) ->
                              counters:add(Runs2, 1, 1),
                              _ = bitcask_txn:read(Tx, <<"flag">>, read),
                              ok = bitcask:put(H, <<"flag">>, <<"off">>),
                              bitcask_txn:write(Tx, <<"out2">>, <<"x">>)
                          end, [{sync, no_sync}]),
            ?assertEqual(1, counters:get(Runs2, 1))
        end)
     end}.

mixed_cas_and_txn_counter_test_() ->
    {"4 个直通 CAS 进程 + 4 个 read_guarded 事务进程同时自增同一计数器：总数精确",
     {timeout, 60, fun() ->
        with_txn_cask(fun(H) ->
            ok = bitcask:put(H, <<"ctr">>, <<0:64>>),
            Parent = self(),
            Cas = [spawn_link(fun() ->
                       [cas_incr(H) || _ <- lists:seq(1, 100)],
                       Parent ! {self(), done}
                   end) || _ <- lists:seq(1, 4)],
            Txn = [spawn_link(fun() ->
                       [{atomic, ok} = bitcask_txn:transaction(H, fun(Tx) ->
                            {ok, <<N:64>>} = bitcask_txn:read_guarded(Tx, <<"ctr">>, write),
                            bitcask_txn:write(Tx, <<"ctr">>, <<(N + 1):64>>)
                        end, [{retries, infinity}, {sync, no_sync}]) || _ <- lists:seq(1, 100)],
                       Parent ! {self(), done}
                   end) || _ <- lists:seq(1, 4)],
            [receive {P, done} -> ok end || P <- Cas ++ Txn],
            ?assertEqual({ok, <<800:64>>}, bitcask:get(H, <<"ctr">>))
        end)
     end}}.

read_guarded_with_index_fun_test_() ->
    {"守卫过的 key 只由 index_fun 写：条件挂在 index op 上（不再与 check 撞成重复 key）",
     fun() ->
        with_txn_cask(fun(H) ->
            ok = bitcask:put(H, <<"idx">>, <<"0">>),
            IndexFun = fun(<<"doc">>, {put, _}) -> [{put, <<"idx">>, <<"1">>}];
                          (_, _) -> []
                       end,
            Runs = counters:new(1, []),
            Res = bitcask_txn:transaction(H, fun(Tx) ->
                      counters:add(Runs, 1, 1),
                      {ok, _} = bitcask_txn:read_guarded(Tx, <<"idx">>, read),
                      case counters:get(Runs, 1) of
                          1 -> ok = bitcask:put(H, <<"idx">>, <<"direct">>);
                          _ -> ok
                      end,
                      bitcask_txn:write(Tx, <<"doc">>, <<"d">>)
                  end, [{index_fun, IndexFun}, {sync, no_sync}]),
            ?assertEqual({atomic, ok}, Res),
            ?assertEqual(2, counters:get(Runs, 1)),          %% 直通写插一脚 → 重跑
            ?assertEqual({ok, <<"1">>}, bitcask:get(H, <<"idx">>))
        end)
     end}.

%% 原子批按轻重分流（轻批直接在普通调度器上跑，其余转 dirty IO；nif_cask_batch.cpp）。
%% 分流只影响在哪个调度器上执行；这里把分流边界两侧各种形态都走一遍，结果必须一样。
batch_scheduling_paths_test_() ->
    {"原子批轻 / 重两条路径结果一致：冷句柄第一批、只含 check 的批、16 / 17 条、"
     "value 合计跨 64 KiB、doc map、冲突与 return_ords、带 sync 策略的句柄",
     {timeout, 60, fun() ->
        with_cask(fun(H) ->
            %% 冷句柄上只含 check 的批（不写盘、不升 meta）
            ?assertEqual(ok, bitcask:put_batch_atomic(H, [{check, <<"a">>, absent}])),
            ?assertEqual({error, {conflict, 2}},
                         bitcask:put_batch_atomic(H, [{check, <<"a">>, absent},
                                                      {check, <<"a">>, {ord, 7}}])),
            %% 冷句柄第一条带写入的批（懒升 meta）
            {ok, [O1, OB]} = bitcask:put_batch_atomic(H, [{put, <<"a">>, <<"1">>, absent},
                                                          {put, <<"b">>, <<"1">>}], [return_ords]),
            ?assertEqual({ok, <<"1">>, OB}, bitcask:get_with_ord(H, <<"b">>)),
            ?assertEqual({ok, <<"1">>, O1}, bitcask:get_with_ord(H, <<"a">>)),
            %% 之后的小批：条件成立 / 不成立、remove、check
            {ok, [O2, 0]} = bitcask:put_batch_atomic(H, [{put, <<"a">>, <<"2">>, {ord, O1}},
                                                         {check, <<"b">>, {ord, OB}}],
                                                     [return_ords]),
            ?assert(O2 > O1),
            ?assertEqual({error, {conflict, 1}},
                         bitcask:put_batch_atomic(H, [{put, <<"a">>, <<"x">>, {ord, O1}},
                                                      {put, <<"c">>, <<"x">>}])),
            ?assertEqual(not_found, bitcask:get(H, <<"c">>)),
            ?assertEqual(ok, bitcask:put_batch_atomic(H, [{remove, <<"b">>, {ord, OB}}])),
            ?assertEqual(not_found, bitcask:get(H, <<"b">>)),
            ?assertEqual(ok, bitcask:put_batch_atomic(H, [])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{put, <<"k">>}])),
            ?assertError(badarg, bitcask:put_batch_atomic(H, [{put, <<"k">>, <<"v">>} | tail])),
            %% 16 条（轻）与 17 条（重）
            [begin
                 Ops = [{put, <<"n", N:8, I:8>>, <<I>>} || I <- lists:seq(1, N)],
                 {ok, Ords} = bitcask:put_batch_atomic(H, Ops, [return_ords]),
                 ?assertEqual(N, length(Ords)),
                 [?assertEqual({ok, <<I>>, lists:nth(I, Ords)},
                               bitcask:get_with_ord(H, <<"n", N:8, I:8>>)) || I <- lists:seq(1, N)]
             end || N <- [16, 17]],
            %% value 合计 64 KiB 整（轻）与多 1 字节（重）
            V32 = binary:copy(<<"v">>, 32 * 1024),
            ?assertEqual(ok, bitcask:put_batch_atomic(H, [{put, <<"s1">>, V32}, {put, <<"s2">>, V32}])),
            ?assertEqual(ok, bitcask:put_batch_atomic(H, [{put, <<"s3">>, V32},
                                                          {put, <<"s4">>, <<V32/binary, "!">>}])),
            ?assertEqual({ok, V32}, bitcask:get(H, <<"s2">>)),
            ?assertEqual({ok, <<V32/binary, "!">>}, bitcask:get(H, <<"s4">>)),
            %% 16 进程并发小批对同一计数器做条件自增：不丢更新（轻批在各调度器上直接跑）
            ok = bitcask:put(H, <<"cnt">>, <<0:32>>),
            Self = self(),
            Pids = [spawn_link(fun() ->
                        [inc(H) || _ <- lists:seq(1, 200)],
                        Self ! {done, self()}
                    end) || _ <- lists:seq(1, 16)],
            [receive {done, P} -> ok after 30000 -> error(timeout) end || P <- Pids],
            ?assertEqual({ok, <<3200:32>>}, bitcask:get(H, <<"cnt">>))
        end),
        %% 带 sync 策略的句柄：一律走 dirty，结果相同
        bitcask_test_util:with_dir("bitcask_cond_batch_sync_", fun(D) ->
            H = bitcask:open(D, [read_write, {sync_strategy, o_sync}]),
            try
                ?assertEqual(ok, bitcask:put_batch_atomic(H, [{put, <<"a">>, <<"1">>, absent}])),
                ?assertEqual(ok, bitcask:put_batch_atomic(H, [{put, <<"b">>, <<"2">>, absent}])),
                ?assertEqual({error, {conflict, 1}},
                             bitcask:put_batch_atomic(H, [{put, <<"b">>, <<"3">>, absent}])),
                ?assertEqual({ok, <<"2">>}, bitcask:get(H, <<"b">>))
            after bitcask:close(H) end
        end)
     end}}.

inc(H) ->
    {ok, <<N:32>>, Ord} = bitcask:get_with_ord(H, <<"cnt">>),
    case bitcask:put_batch_atomic(H, [{put, <<"cnt">>, <<(N + 1):32>>, {ord, Ord}}]) of
        ok                     -> ok;
        {error, {conflict, 1}} -> inc(H)
    end.
