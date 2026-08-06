%% -------------------------------------------------------------------
%% bitcask_range_txn_tests:
%%   libbitcask 6.0.0 升级新暴露的三块能力的覆盖：
%%     - range/2,3 + range_fold/5   OKI 有序范围查询（S33-5）
%%     - put_batch_atomic/2         引擎原子批（S35）
%%     - txn_commit/2,3             多键事务（S34）
%%   外加 keydir_cache_entries（S36-4，Level B）选项透传的冒烟。
%%
%%   ⚠️ 原子批/事务的**崩溃原子性**（掉电后不半批）在这一层测不了——那是
%%   上游 C++ 侧带故障注入的 atomic_batch_test 的职责。这里覆盖的是
%%   Erlang ↔ NIF 的边界：形态解析、错误翻译、可见性、资源生命周期。
%% -------------------------------------------------------------------
-module(bitcask_range_txn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KV, [read_write]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_range_txn_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

key(N) -> list_to_binary(io_lib:format("k~3..0b", [N])).

%% 写 k000..k099 的库。
open_seeded(D) -> open_seeded(D, ?KV).

open_seeded(D, Opts) ->
    R = bitcask:open(D, Opts),
    [ok = bitcask:put(R, key(N), <<"v">>) || N <- lists:seq(0, 99)],
    R.

keys_of(Entries) -> [K || {K, _V} <- Entries].

%% ===================================================================
%% range：边界语义
%% ===================================================================

range_bounds_test_() ->
    {"range [Lo,Hi)：Lo 含、Hi 不含；两端各自可无界",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            ?assertEqual([key(N) || N <- lists:seq(10, 14)],
                         keys_of(bitcask:range(R, {<<"k010">>, <<"k015">>}))),
            %% 上界无界
            ?assertEqual([key(N) || N <- lists:seq(95, 99)],
                         keys_of(bitcask:range(R, {<<"k095">>, undefined}))),
            %% 下界无界
            ?assertEqual([key(N) || N <- lists:seq(0, 2)],
                         keys_of(bitcask:range(R, {undefined, <<"k003">>}))),
            %% 全无界 = 全表，且已排序
            All = keys_of(bitcask:range(R, {undefined, undefined})),
            ?assertEqual(100, length(All)),
            ?assertEqual(lists:sort(All), All),
            bitcask:close(R)
        end)
    end}.

range_empty_and_inverted_test_() ->
    {"空区间 / Lo≥Hi → []（不报错）",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            ?assertEqual([], bitcask:range(R, {<<"k010">>, <<"k010">>})),
            ?assertEqual([], bitcask:range(R, {<<"k050">>, <<"k010">>})),
            ?assertEqual([], bitcask:range(R, {<<"zzz">>, undefined})),
            bitcask:close(R)
        end)
    end}.

range_reflects_writes_test_() ->
    {"range 看得到后续 put，也看得到 delete（弱一致，非快照）",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            ok = bitcask:put(R, <<"k0105">>, <<"new">>),
            ?assertEqual([<<"k010">>, <<"k0105">>, <<"k011">>],
                         keys_of(bitcask:range(R, {<<"k010">>, <<"k012">>}))),
            ok = bitcask:delete(R, <<"k010">>),
            ?assertEqual([<<"k0105">>, <<"k011">>],
                         keys_of(bitcask:range(R, {<<"k010">>, <<"k012">>}))),
            bitcask:close(R)
        end)
    end}.

range_prefetch_identical_test_() ->
    {"prefetch 只改取值时机：输出序与内容必须与惰性路径逐字节相同",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            Lazy = bitcask:range(R, {<<"k000">>, <<"k060">>}),
            ?assertEqual(Lazy, bitcask:range(R, {<<"k000">>, <<"k060">>},
                                             [{prefetch, 8}])),
            ?assertEqual(Lazy, bitcask:range(R, {<<"k000">>, <<"k060">>},
                                             [{prefetch, 8},
                                              {prefetch_threads, 2}])),
            bitcask:close(R)
        end)
    end}.

range_crosses_batch_boundary_test_() ->
    {"结果跨多次 next_batch（内部批 256）时不丢条目、不重复",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            N = 600,
            [ok = bitcask:put(R, key(I), <<"v">>) || I <- lists:seq(0, N - 1)],
            Keys = keys_of(bitcask:range(R, {undefined, undefined})),
            ?assertEqual(N, length(Keys)),
            ?assertEqual(N, length(lists:usort(Keys))),
            ?assertEqual(lists:sort(Keys), Keys),
            bitcask:close(R)
        end)
    end}.

range_fold_test_() ->
    {"range_fold/5 的回调拿到 {K,V,Tstamp,Ord}，累加与 range/2 等价",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            Acc = bitcask:range_fold(R, {<<"k000">>, <<"k050">>}, [],
                                     fun(K, V, T, O, A) -> [{K, V, T, O} | A] end,
                                     []),
            ?assertEqual(50, length(Acc)),
            %% Tstamp/Ord 都应该是真实值而不是 0 占位
            [{_K, _V, T, O} | _] = Acc,
            ?assert(T > 0),
            ?assert(O > 0),
            %% 反转后 key 序与 range/2 一致
            ?assertEqual(keys_of(bitcask:range(R, {<<"k000">>, <<"k050">>})),
                         [K || {K, _, _, _} <- lists:reverse(Acc)]),
            bitcask:close(R)
        end)
    end}.

range_no_index_test_() ->
    {"只读打开一个从未写过的目录（无 OKI）→ {error, no_index}，不是 case_clause",
     fun() ->
        with_dir(fun(D) ->
            %% NIF 对 kNoIndex 返回**裸 atom**（legacy 契约），门面必须归一。
            %% 漏了这层归一时这里崩在 bitcask:range_fold/5 里。
            R = bitcask:open(D, []),
            ?assertEqual({error, no_index},
                         bitcask:range(R, {undefined, undefined})),
            ?assertEqual({error, no_index},
                         bitcask:range_fold(R, {undefined, undefined}, [],
                                            fun(_K, _V, _T, _O, A) -> A end, [])),
            bitcask:close(R)
        end)
    end}.

range_readonly_populated_test_() ->
    {"只读打开**有数据**的库 range 正常——no_index 只针对从未写过的空目录",
     fun() ->
        with_dir(fun(D) ->
            %% RW 会话把 OKI 落盘，RO 直接读得到，不需要（也无权）重建。
            RW = open_seeded(D),
            bitcask:close(RW),
            RO = bitcask:open(D, []),
            ?assertEqual([key(N) || N <- lists:seq(10, 14)],
                         keys_of(bitcask:range(RO, {<<"k010">>, <<"k015">>}))),
            ?assertEqual(100, length(bitcask:range(RO, {undefined, undefined}))),
            bitcask:close(RO)
        end)
    end}.

range_rebuild_failed_test_() ->
    {"OKI 试建而败 → {error, index_rebuild_failed}，与 no_index 区分（6.1.0）",
     fun() ->
        with_dir(fun(D) ->
            RW = open_seeded(D),
            bitcask:close(RW),
            %% 制造一次重建失败：删掉 OKI 让它想重建，同时在 manifest 路径上
            %% 放一个**目录**——manifest 是 OKI 的唯一 commit point，原子写
            %% rename 到目录上必失败。
            %% ⚠️ 这个 fixture 依赖上游的 OKI 文件名；名字变了本例会失败
            %%（而不是静默失效），那正是想要的信号。
            [file:delete(F) || F <- filelib:wildcard(D ++ "/kv.oki.seg-*")],
            file:delete(D ++ "/kv.oki.manifest"),
            ok = file:make_dir(D ++ "/kv.oki.manifest"),

            R = bitcask:open(D, [read_write]),
            %% KV 路径不受影响——OKI 只是派生缓存
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k042">>)),
            %% range 报「试建而败」，不是「本就不建」
            ?assertEqual({error, index_rebuild_failed},
                         bitcask:range(R, {undefined, undefined})),
            ?assertEqual({error, index_rebuild_failed},
                         bitcask:range_fold(R, {undefined, undefined}, [],
                                            fun(_K, _V, _T, _O, A) -> A end, [])),
            bitcask:close(R)
        end)
    end}.

range_after_close_test_() ->
    {"父 cask 已 close 后再 next → {error, closed}（而不是段错误）",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            {ok, It} = bitcask_cpp_nifs:cask_range_start(element(1, R), []),
            bitcask:close(R),
            ?assertEqual({error, closed}, bitcask_cpp_nifs:cask_range_next(It)),
            ?assertEqual({error, closed},
                         bitcask_cpp_nifs:cask_range_next_batch(It, 10)),
            %% release 幂等
            ?assertEqual(ok, bitcask_cpp_nifs:cask_range_release(It)),
            ?assertEqual(ok, bitcask_cpp_nifs:cask_range_release(It))
        end)
    end}.

%% ===================================================================
%% put_batch_atomic
%% ===================================================================

batch_put_remove_test_() ->
    {"原子批混合 put/remove，提交后整批可见",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ok = bitcask:put(R, <<"old">>, <<"x">>),
            ok = bitcask:put_batch_atomic(R, [{put, <<"a">>, <<"1">>},
                                              {put, <<"b">>, <<"2">>},
                                              {remove, <<"old">>}]),
            ?assertEqual({ok, <<"1">>}, bitcask:get(R, <<"a">>)),
            ?assertEqual({ok, <<"2">>}, bitcask:get(R, <<"b">>)),
            ?assertEqual(not_found, bitcask:get(R, <<"old">>)),
            bitcask:close(R)
        end)
    end}.

batch_intra_lww_test_() ->
    {"批内同 key 多次 = 依序 apply（批内 LWW）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ok = bitcask:put_batch_atomic(R, [{put, <<"k">>, <<"first">>},
                                              {put, <<"k">>, <<"second">>}]),
            ?assertEqual({ok, <<"second">>}, bitcask:get(R, <<"k">>)),
            %% put 后 remove 同 key → 最终不存在
            ok = bitcask:put_batch_atomic(R, [{put, <<"z">>, <<"v">>},
                                              {remove, <<"z">>}]),
            ?assertEqual(not_found, bitcask:get(R, <<"z">>)),
            bitcask:close(R)
        end)
    end}.

batch_empty_is_noop_test_() ->
    {"空批是 no-op（不碰 meta 纪元、不报错）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ?assertEqual(ok, bitcask:put_batch_atomic(R, [])),
            bitcask:close(R)
        end)
    end}.

batch_survives_reopen_test_() ->
    {"原子批写入的数据在 close + reopen 后仍在（走的是正常恢复路径）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ok = bitcask:put_batch_atomic(R, [{put, <<"p">>, <<"persisted">>}]),
            bitcask:close(R),
            R2 = bitcask:open(D, ?KV),
            ?assertEqual({ok, <<"persisted">>}, bitcask:get(R2, <<"p">>)),
            bitcask:close(R2)
        end)
    end}.

batch_bad_shape_test_() ->
    {"批里任何一条形态不认 → badarg（绝不静默丢弃）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            Bad = [[{bogus, <<"k">>}],                    % 不认的标签
                   [{put, <<"k">>}],                      % put 元数不对
                   [{remove, <<"k">>, <<"v">>}],          % remove 元数不对
                   [{put, <<"k">>, <<"v">>}, bare_atom],  % 非元组元素
                   [{put, "not_a_binary", <<"v">>}],      % key 不是 binary
                   [{put, <<"k">>, not_a_binary}],        % value 不是 binary
                   [{put, <<"k">>, <<"v">>} | improper]], % 改进列表（尾巴不是 []）
            [?assertError(badarg, bitcask:put_batch_atomic(R, Ops)) || Ops <- Bad],
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% txn_commit
%% ===================================================================

txn_commit_test_() ->
    {"事务提交：默认 sync_on_commit，也接受 no_sync",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ok = bitcask:put(R, <<"drop">>, <<"x">>),
            ok = bitcask:txn_commit(R, [{put, <<"t1">>, <<"a">>},
                                        {remove, <<"drop">>}]),
            ?assertEqual({ok, <<"a">>}, bitcask:get(R, <<"t1">>)),
            ?assertEqual(not_found, bitcask:get(R, <<"drop">>)),
            ok = bitcask:txn_commit(R, [{put, <<"t2">>, <<"b">>}], no_sync),
            ?assertEqual({ok, <<"b">>}, bitcask:get(R, <<"t2">>)),
            bitcask:close(R)
        end)
    end}.

txn_validation_test_() ->
    {"事务校验失败 → {error, {invalid_option, Msg}} 且零副作用",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            %% 空批
            ?assertMatch({error, {invalid_option, _}}, bitcask:txn_commit(R, [])),
            %% 重复 key
            Dup = bitcask:txn_commit(R, [{put, <<"d">>, <<"1">>},
                                         {put, <<"d">>, <<"2">>}]),
            ?assertMatch({error, {invalid_option, _}}, Dup),
            ?assertEqual(not_found, bitcask:get(R, <<"d">>)),
            %% 空 key
            ?assertMatch({error, {invalid_option, _}},
                         bitcask:txn_commit(R, [{put, <<>>, <<"v">>}])),
            %% "_txn:" 保留前缀
            Reserved = bitcask:txn_commit(R, [{put, <<"_txn:x">>, <<"v">>}]),
            ?assertMatch({error, {invalid_option, _}}, Reserved),
            ?assertEqual(not_found, bitcask:get(R, <<"_txn:x">>)),
            bitcask:close(R)
        end)
    end}.

txn_bad_sync_policy_test_() ->
    {"未知 sync 策略 → function_clause（在 Erlang 层就挡掉）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ?assertError(function_clause,
                         bitcask:txn_commit(R, [{put, <<"k">>, <<"v">>}], bogus)),
            bitcask:close(R)
        end)
    end}.

txn_visible_to_range_test_() ->
    {"事务写入的 key 立刻进 OKI，range 查得到",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            ok = bitcask:txn_commit(R, [{put, <<"k0125">>, <<"txn">>},
                                        {remove, <<"k013">>}]),
            ?assertEqual([<<"k012">>, <<"k0125">>, <<"k014">>],
                         keys_of(bitcask:range(R, {<<"k012">>, <<"k015">>}))),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% keydir_cache_entries（S36-4 Level B）
%% ===================================================================

keydir_cache_entries_test_() ->
    {"{keydir_cache_entries, N} 透传后读写与 range 全部照常（逐出态下走组合视图）",
     fun() ->
        with_dir(fun(D) ->
            R = open_seeded(D),
            bitcask:close(R),
            %% 预算远小于 key 数 → 必然进入逐出态
            R2 = bitcask:open(D, [read_write, {keydir_cache_entries, 8}]),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R2, <<"k042">>)),
            ok = bitcask:put(R2, <<"k100">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R2, <<"k100">>)),
            ?assertEqual(101, length(bitcask:range(R2, {undefined, undefined}))),
            %% fold 在逐出态下也要能完整枚举
            Folded = bitcask:fold(R2, fun(_K, _V, A) -> A + 1 end, 0),
            ?assertEqual(101, Folded),
            bitcask:close(R2)
        end)
    end}.
