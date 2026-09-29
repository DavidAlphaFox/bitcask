%% -------------------------------------------------------------------
%% bitcask_cpp_cask_gap_tests:
%%   Functional coverage for the cask_cpp backend — features the
%%   pre-M6 legacy suite exercised that need to keep working.
%% -------------------------------------------------------------------
-module(bitcask_cpp_cask_gap_tests).

-include_lib("eunit/include/eunit.hrl").
-include("bitcask.hrl").

-define(CASK, [read_write]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_cpp_gap_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% ===================================================================
%% expiry_secs (mirrors legacy expire_test2)
%% ===================================================================

expiry_secs_get_returns_not_found_test_() ->
    {timeout, 30,
     {"after expiry_secs elapses, get returns not_found", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{expiry_secs, 1} | ?CASK]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
            timer:sleep(1500),
            ?assertEqual(not_found, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}}.

expiry_secs_list_keys_skips_expired_test_() ->
    {timeout, 30,
     {"list_keys/fold skip expired entries", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{expiry_secs, 1} | ?CASK]),
            ok = bitcask:put(R, <<"old1">>, <<"v">>),
            ok = bitcask:put(R, <<"old2">>, <<"v">>),
            timer:sleep(1500),
            ok = bitcask:put(R, <<"new">>, <<"v">>),
            ?assertEqual([<<"new">>],
                         lists:sort(bitcask:list_keys(R))),
            bitcask:close(R)
        end)
    end}}.

%% ===================================================================
%% needs_merge / merge dispatch
%% ===================================================================

needs_merge_dispatch_test_() ->
    {"bitcask:needs_merge/1 routes through cask_needs_merge in cask mode",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            %% Empty cask never needs merging.
            ?assertEqual(false, bitcask:needs_merge(R)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% sync after empty open (legacy returns ok even with no writes)
%% ===================================================================

sync_after_empty_open_test_() ->
    {"sync on a fresh writer is a no-op without error", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            ?assertEqual(ok, bitcask:sync(R)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% Big value (64KiB) round-trip
%% ===================================================================

big_value_round_trip_test_() ->
    {timeout, 30,
     {"64 KiB value round-trips through cask_cpp", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            V = crypto:strong_rand_bytes(64 * 1024),
            ok = bitcask:put(R, <<"big">>, V),
            ?assertEqual({ok, V}, bitcask:get(R, <<"big">>)),
            bitcask:close(R)
        end)
    end}}.

%% ===================================================================
%% Many overwrites, then reopen, must see latest value
%% ===================================================================

reopen_after_many_overwrites_test_() ->
    {timeout, 30,
     {"close+reopen sees the latest value of a heavily-overwritten key",
      fun() ->
        with_dir(fun(D) ->
            R1 = bitcask:open(D, [{max_file_size, 200} | ?CASK]),
            lists:foreach(
              fun(I) ->
                  ok = bitcask:put(R1, <<"k">>, integer_to_binary(I))
              end, lists:seq(1, 50)),
            bitcask:close(R1),
            R2 = bitcask:open(D, ?CASK),
            ?assertEqual({ok, <<"50">>}, bitcask:get(R2, <<"k">>)),
            bitcask:close(R2)
        end)
    end}}.

%% ===================================================================
%% Delete-then-reopen-then-put cycle
%% ===================================================================

delete_reopen_put_cycle_test_() ->
    {"delete + reopen + put restores the key cleanly", fun() ->
        with_dir(fun(D) ->
            R1 = bitcask:open(D, ?CASK),
            ok = bitcask:put(R1, <<"k">>, <<"v1">>),
            ok = bitcask:delete(R1, <<"k">>),
            bitcask:close(R1),
            R2 = bitcask:open(D, ?CASK),
            ?assertEqual(not_found, bitcask:get(R2, <<"k">>)),
            ok = bitcask:put(R2, <<"k">>, <<"v2">>),
            ?assertEqual({ok, <<"v2">>}, bitcask:get(R2, <<"k">>)),
            bitcask:close(R2)
        end)
    end}.

%% ===================================================================
%% M5.1 Task 1: bitcask:merge/N facade in cask mode
%% ===================================================================

bitcask_merge_facade_offline_test_() ->
    {timeout, 30,
     {"bitcask:merge/2 dispatches through cask when no writer holds the dir",
      fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{max_file_size, 200},
                                 {frag_merge_trigger, 50},
                                 {frag_threshold, 50} | ?CASK]),
            [bitcask:put(R, <<"k">>, integer_to_binary(I))
             || I <- lists:seq(1, 50)],
            bitcask:close(R),

            FilesBefore = filelib:wildcard(filename:join(D, "*.bitcask.data")),
            ?assert(length(FilesBefore) >= 2),

            %% bitcask:merge/2 should run via cask backend (default mode).
            ?assertEqual(ok, bitcask:merge(D, [
                                                {frag_merge_trigger, 50},
                                                {frag_threshold, 50}])),

            FilesAfter = filelib:wildcard(filename:join(D, "*.bitcask.data")),
            ?assert(length(FilesAfter) < length(FilesBefore))
        end)
    end}}.

bitcask_merge_facade_writer_does_not_block_test_() ->
    {"M5.1 task 2: merger acquires merge.lock, NOT write.lock, so a "
     "writer holding write.lock does not block it",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                %% Writer holds write.lock. Merger uses merge.lock.
                %% Even with no fragmentation, merge runs and returns ok
                %% (no candidate files, but no lock conflict).
                ?assertEqual(ok, bitcask:merge(D, []))
            after
                bitcask:close(R)
            end
        end)
    end}.

bitcask_merge_facade_explicit_files_test_() ->
    {timeout, 30,
     {"bitcask:merge/3 with explicit file list goes through cask",
      fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{max_file_size, 200} | ?CASK]),
            [bitcask:put(R, <<"k">>, integer_to_binary(I))
             || I <- lists:seq(1, 30)],
            bitcask:close(R),

            All = filelib:wildcard(filename:join(D, "*.bitcask.data")),
            %% Pass an explicit subset.
            ToMerge = lists:sublist(All, length(All) - 1),
            ?assertEqual(ok, bitcask:merge(D, [], ToMerge))
        end)
    end}}.

%% ===================================================================
%% M5.1 Task 2: writer + merger concurrent, two-lock model
%% ===================================================================

merge_runs_while_writer_holds_lock_test_() ->
    {timeout, 30,
     {"merger uses bitcask.merge.lock and runs concurrently with a writer "
      "holding bitcask.write.lock",
      fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{max_file_size, 200},
                                 {frag_merge_trigger, 50},
                                 {frag_threshold, 50} | ?CASK]),
            try
                %% Generate fragmentation. Writer keeps the lock the whole time.
                [bitcask:put(R, <<"k">>, integer_to_binary(I))
                 || I <- lists:seq(1, 50)],
                ?assert(length(filelib:wildcard(
                                  filename:join(D, "*.bitcask.data"))) >= 2),

                %% Writer is still open. Without two-lock model this would
                %% return {error, {merge_locked, _, _}}. With it, ok.
                Result = bitcask:merge(D, [
                                            {frag_merge_trigger, 50},
                                            {frag_threshold, 50}]),
                ?assertEqual(ok, Result),

                %% Writer's data still readable.
                ?assertEqual({ok, <<"50">>}, bitcask:get(R, <<"k">>)),

                %% Writer can keep writing — automatic rollover handles
                %% the merger having advanced biggest_file_id.
                ?assertEqual(ok, bitcask:put(R, <<"after">>, <<"survived">>)),
                ?assertEqual({ok, <<"survived">>}, bitcask:get(R, <<"after">>))
            after
                bitcask:close(R)
            end
        end)
    end}}.

write_lock_records_active_file_path_test_() ->
    {"write.lock content includes the active data-file path so mergers "
     "can identify which file to skip",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{max_file_size, 200} | ?CASK]),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                {ok, Bin} = file:read_file(filename:join(D, "bitcask.write.lock")),
                %% Format: "<pid> <active_data_path>\n<start_token>\n".
                %% The second line is libbitcask 6.2.0 (S37-5): a process
                %% instance token guarding against PID reuse in stale-lock
                %% detection. It is always "0" on POSIX (no token available)
                %% and is written purely to keep the format identical across
                %% platforms; parsers read only the first line.
                Lines = binary:split(Bin, <<"\n">>, [global, trim]),
                ?assertEqual(2, length(Lines)),
                [Line, TokenLine] = Lines,
                ?assert(TokenLine =/= <<>>),
                ?assertMatch({match, _}, re:run(TokenLine, "^[0-9]+$")),
                Parts = binary:split(Line, <<" ">>),
                ?assertEqual(2, length(Parts)),
                [_PidBin, Path] = Parts,
                ?assert(binary:longest_common_suffix([Path, <<".bitcask.data">>])
                        =:= byte_size(<<".bitcask.data">>))
            after
                bitcask:close(R)
            end
        end)
    end}.

%% ===================================================================
%% M5.1 Task 3: sync_strategy passthrough
%% ===================================================================

sync_strategy_o_sync_open_works_test_() ->
    {"open with {sync_strategy, o_sync} succeeds and round-trips", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{sync_strategy, o_sync} | ?CASK]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

sync_strategy_none_open_works_test_() ->
    {"open with {sync_strategy, none} (default semantics) round-trips",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{sync_strategy, none} | ?CASK]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

sync_strategy_seconds_open_works_test_() ->
    {"{sync_strategy, {seconds, N}} is accepted; auto-sync is caller's job "
     "(matches legacy semantics in bitcask.app.src)",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [{sync_strategy, {seconds, 5}} | ?CASK]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            %% Caller responsibility: explicit bitcask:sync/1.
            ?assertEqual(ok, bitcask:sync(R)),
            bitcask:close(R)
        end)
    end}.

sync_strategy_app_env_test_() ->
    {"{sync_strategy, _} read from application env when not in opts",
     fun() ->
        with_dir(fun(D) ->
            application:set_env(bitcask, sync_strategy, o_sync),
            try
                R = bitcask:open(D, ?CASK),
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
                bitcask:close(R)
            after
                application:unset_env(bitcask, sync_strategy)
            end
        end)
    end}.

second_concurrent_merger_blocked_by_merge_lock_test_() ->
    {timeout, 30,
     {"only one merger can run on a dir at a time (merge.lock is exclusive)",
      fun() ->
        with_dir(fun(D) ->
            %% Make some data so a merger has something to look at.
            R = bitcask:open(D, [{max_file_size, 200} | ?CASK]),
            [bitcask:put(R, <<"k">>, integer_to_binary(I))
             || I <- lists:seq(1, 30)],
            try
                %% First merger: open as merge_only directly to hold the
                %% lock for the duration of this test.
                {ok, M1} = bitcask_cpp_nifs:cask_open(D, [merge_only]),
                try
                    %% Second merger via facade should be rejected.
                    Result = bitcask:merge(D, []),
                    ?assertMatch({error, {merge_locked, _Msg, _Dir}}, Result)
                after
                    bitcask_cpp_nifs:cask_close(M1)
                end
            after
                bitcask:close(R)
            end
        end)
    end}}.

%% ===================================================================
%% fold_keys: cask path exposes real entry fields (M5.2 task 2)
%% ===================================================================

%% ===================================================================
%% Cross-mode bidirectional compat (M5.2 task 3)
%% On-disk format is byte-compatible: a dir written by one mode must be
%% readable by the other after close.
%% ===================================================================

%% cross-mode tests removed in M6 (legacy backend deleted)

%% ===================================================================
%% close_write_file/1 cask path: drops active writer + releases write lock,
%% next put transparently reacquires.
%% ===================================================================

close_write_file_releases_lock_test_() ->
    {"close_write_file/1 releases bitcask.write.lock — the lock file "
     "is unlinked from the filesystem after release",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"a">>, <<"1">>),
                LockPath = filename:join(D, "bitcask.write.lock"),
                ?assert(filelib:is_regular(LockPath)),
                ok = bitcask:close_write_file(R),
                %% Cask's release_quiet unlinks write locks; a peer
                %% process would now find no lock file and acquire fresh.
                ?assertNot(filelib:is_regular(LockPath))
            after bitcask:close(R) end
        end)
     end}.

close_write_file_then_put_reopens_active_test_() ->
    {"After close_write_file/1 the Ref is still usable; next put/2 "
     "reacquires the lock and creates a new active file",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k1">>, <<"v1">>),
                ok = bitcask:close_write_file(R),
                %% This put must succeed and land in a NEW data file
                %% (not the closed-out one). Both keys must be readable.
                ok = bitcask:put(R, <<"k2">>, <<"v2">>),
                ?assertEqual({ok, <<"v1">>}, bitcask:get(R, <<"k1">>)),
                ?assertEqual({ok, <<"v2">>}, bitcask:get(R, <<"k2">>)),
                %% At least 2 .data files after the rollover.
                {ok, Files} = file:list_dir(D),
                DataFiles =
                    [F || F <- Files,
                          lists:suffix(".bitcask.data", F)],
                ?assert(length(DataFiles) >= 2)
            after bitcask:close(R) end
        end)
     end}.

close_write_file_idempotent_test_() ->
    {"close_write_file/1 called twice in a row is harmless (second call "
     "finds no active writer to close, but neither errors)",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                ok = bitcask:close_write_file(R),
                ok = bitcask:close_write_file(R),
                ok = bitcask:put(R, <<"k2">>, <<"v2">>),
                ?assertEqual({ok, <<"v2">>}, bitcask:get(R, <<"k2">>))
            after bitcask:close(R) end
        end)
     end}.

close_write_file_on_readonly_returns_error_test_() ->
    {"close_write_file/1 on a read-only cask returns {error, _}",
     fun() ->
        with_dir(fun(D) ->
            %% Make sure the dir exists with at least one file so a
            %% read-only open succeeds.
            Rw = bitcask:open(D, ?CASK),
            ok = bitcask:put(Rw, <<"k">>, <<"v">>),
            ok = bitcask:close(Rw),

            R = bitcask:open(D, []),  % read-only
            try
                ?assertMatch({error, _}, bitcask:close_write_file(R))
            after bitcask:close(R) end
        end)
     end}.

%% ===================================================================
%% stream/1 + next/1 + stop/1 + with_stream/2
%% (替代旧的 iterator/3 + iterator_next/1 + iterator_release/1)
%% ===================================================================

stream_walks_all_keys_test_() ->
    {"stream + next 把所有活 key 走一遍后返回 done",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"a">>, <<"1">>),
                ok = bitcask:put(R, <<"b">>, <<"2">>),
                ok = bitcask:put(R, <<"c">>, <<"3">>),
                {ok, S} = bitcask:stream(R),
                Pairs = drain_stream(S, []),
                ok = bitcask:stop(S),
                Sorted = lists:sort(Pairs),
                ?assertEqual([{<<"a">>, <<"1">>},
                              {<<"b">>, <<"2">>},
                              {<<"c">>, <<"3">>}], Sorted)
            after bitcask:close(R) end
        end)
     end}.

stream_next_after_done_is_idempotent_test_() ->
    {"done 之后再 next 仍返回 done，不报错",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                {ok, S} = bitcask:stream(R),
                {ok, <<"k">>, <<"v">>} = bitcask:next(S),
                ?assertEqual(done, bitcask:next(S)),
                ?assertEqual(done, bitcask:next(S)),  %% 再调一次还是 done
                ?assertEqual(done, bitcask:next(S)),
                ok = bitcask:stop(S)
            after bitcask:close(R) end
        end)
     end}.

stream_early_stop_test_() ->
    {"消费者中途 stop，producer 立刻清理；之后还能开新 stream",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                [ok = bitcask:put(R, integer_to_binary(I), <<"v">>)
                 || I <- lists:seq(1, 50)],
                {ok, S1} = bitcask:stream(R),
                {ok, _, _} = bitcask:next(S1),
                {ok, _, _} = bitcask:next(S1),
                ?assertEqual(ok, bitcask:stop(S1)),    %% 提前结束
                ?assertEqual(ok, bitcask:stop(S1)),    %% 幂等
                %% 同 Ref 上能立刻开第二个 stream
                {ok, S2} = bitcask:stream(R),
                Cnt = count_stream(S2, 0),
                ok = bitcask:stop(S2),
                ?assertEqual(50, Cnt)
            after bitcask:close(R) end
        end)
     end}.

with_stream_releases_on_normal_return_test_() ->
    {"with_stream 在 Fun 正常返回后自动 stop",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                Result = bitcask:with_stream(R, fun(S) ->
                    {ok, K, V} = bitcask:next(S),
                    {K, V}
                end),
                ?assertEqual({<<"k">>, <<"v">>}, Result)
            after bitcask:close(R) end
        end)
     end}.

with_stream_releases_on_exception_test_() ->
    {"with_stream 在 Fun 抛异常时也会 stop 流",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                ?assertError(boom,
                    bitcask:with_stream(R, fun(_S) -> erlang:error(boom) end)),
                %% 流应该已经清理，能开新的
                {ok, S} = bitcask:stream(R),
                ok = bitcask:stop(S)
            after bitcask:close(R) end
        end)
     end}.

stream_concurrent_streams_dont_interfere_test_() ->
    {"同 Ref 上同时开两个 stream，互不干扰",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                [ok = bitcask:put(R, integer_to_binary(I), <<"v">>)
                 || I <- lists:seq(1, 10)],
                {ok, S1} = bitcask:stream(R),
                {ok, S2} = bitcask:stream(R),
                A = lists:sort([K || {K, _} <- drain_stream(S1, [])]),
                B = lists:sort([K || {K, _} <- drain_stream(S2, [])]),
                ?assertEqual(A, B),
                ?assertEqual(10, length(A)),
                ok = bitcask:stop(S1),
                ok = bitcask:stop(S2)
            after bitcask:close(R) end
        end)
     end}.

stream_consumer_crash_releases_iter_test_() ->
    {"消费者进程崩溃 → producer monitor 触发 → 自动 release iter",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                Self = self(),
                {Pid, MRef} = spawn_monitor(fun() ->
                    {ok, S} = bitcask:stream(R),
                    {bitcask_stream, ProducerPid, _} = S,
                    Self ! {producer, ProducerPid},
                    %% 拉一条然后故意 crash，不 stop
                    {ok, _, _} = bitcask:next(S),
                    erlang:error(simulated_crash)
                end),
                ProducerPid =
                    receive {producer, P} -> P after 1000 -> error(timeout) end,
                receive
                    {'DOWN', MRef, process, Pid, _} -> ok
                after 2000 -> error(consumer_didnt_die)
                end,
                %% 等 producer 通过 monitor 自己退出
                ProdMon = erlang:monitor(process, ProducerPid),
                receive
                    {'DOWN', ProdMon, process, ProducerPid, _} -> ok
                after 2000 -> error(producer_didnt_die)
                end,
                %% iter 应该已 release——能开新 stream 验证
                {ok, S2} = bitcask:stream(R),
                ok = bitcask:stop(S2)
            after bitcask:close(R) end
        end)
     end}.

drain_stream(S, Acc) ->
    case bitcask:next(S) of
        done -> Acc;
        {ok, K, V} -> drain_stream(S, [{K, V} | Acc]);
        Other -> erlang:error({unexpected_next, Other})
    end.

count_stream(S, N) ->
    case bitcask:next(S) of
        done -> N;
        {ok, _, _} -> count_stream(S, N + 1);
        Other -> erlang:error({unexpected_next, Other})
    end.

%% ===================================================================
%% fold/6 + fold_keys/6 cask path (M6 prep — replaces legacy fall-through)
%% ===================================================================

fold_keys6_no_see_tombstones_test_() ->
    {"fold_keys/6 with SeeTombstones=false: live keys only, deletes hidden",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"a">>, <<"v1">>),
                ok = bitcask:put(R, <<"b">>, <<"v2">>),
                ok = bitcask:put(R, <<"c">>, <<"v3">>),
                ok = bitcask:delete(R, <<"b">>),
                Keys = lists:sort(
                    bitcask:fold_keys(
                      R,
                      fun(E, A) -> [E#bitcask_entry.key | A] end,
                      [], -1, -1, false)),
                ?assertEqual([<<"a">>, <<"c">>], Keys)
            after bitcask:close(R) end
        end)
     end}.

fold_keys6_see_tombstones_test_() ->
    {"fold_keys/6 with SeeTombstones=true: deletes during fold show up "
     "as {tombstone, BCEntry}",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"a">>, <<"v1">>),
                ok = bitcask:put(R, <<"b">>, <<"v2">>),
                %% Use the keydir registry: a separate fold-handle that
                %% sees the tombstone written through the same Cask.
                %% We rely on the cask fold seeing in-keydir tombstones
                %% from the same handle.
                Acc = bitcask:fold_keys(
                        R,
                        fun(E, A) when is_record(E, bitcask_entry) ->
                                [{live, E#bitcask_entry.key} | A];
                           ({tombstone, E}, A) ->
                                [{tomb, E#bitcask_entry.key} | A]
                        end,
                        [], -1, -1, true),
                Live = lists:sort([K || {live, K} <- Acc]),
                ?assertEqual([<<"a">>, <<"b">>], Live),
                %% No tombstones because nothing was deleted before the
                %% fold; this asserts the SeeTombstones=true path doesn't
                %% spuriously fabricate them.
                ?assertEqual([], [K || {tomb, K} <- Acc])
            after bitcask:close(R) end
        end)
     end}.

fold6_callback_shape_test_() ->
    {"fold/6 cask branch hands callbacks (K, V, Acc) for live and "
     "({tombstone, K}, V, Acc) for tombstones when SeeTombstones=true",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k1">>, <<"v1">>),
                ok = bitcask:put(R, <<"k2">>, <<"v2">>),
                %% SeeTombstones=false should match fold/3 result.
                Acc1 = bitcask:fold(
                         R,
                         fun(K, V, A) -> [{K, V} | A] end,
                         [], -1, -1, false),
                ?assertEqual([{<<"k1">>, <<"v1">>}, {<<"k2">>, <<"v2">>}],
                             lists:sort(Acc1)),
                %% SeeTombstones=true should also see the same live pairs
                %% (no tombstones present yet).
                Acc2 = bitcask:fold(
                         R,
                         fun(K, V, A) when is_binary(K) -> [{live, K, V} | A];
                            ({tombstone, K}, V, A)     -> [{tomb, K, V} | A]
                         end,
                         [], -1, -1, true),
                Live = lists:sort([{K, V} || {live, K, V} <- Acc2]),
                ?assertEqual([{<<"k1">>, <<"v1">>}, {<<"k2">>, <<"v2">>}], Live)
            after bitcask:close(R) end
        end)
     end}.

fold_keys6_max_age_negative_disables_test_() ->
    {"MaxAge=-1 / MaxPut=-1 disables freshness check (matches legacy "
     "convention) and the fold completes normally",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"x">>, <<"y">>),
                Acc = bitcask:fold_keys(
                        R,
                        fun(E, A) -> [E#bitcask_entry.key | A] end,
                        [], -1, -1, false),
                ?assertEqual([<<"x">>], Acc)
            after bitcask:close(R) end
        end)
     end}.

%% ===================================================================
%% is_frozen reflects iterator state (M5.2 task 5)
%% ===================================================================

is_frozen_returns_real_state_test_() ->
    {"is_frozen/1 in cask mode tracks the keydir's iter-frozen state, "
     "not a hardcoded false",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                %% No iter active → not frozen.
                ?assertEqual(false, bitcask:is_frozen(R)),
                %% Start a fold; it freezes the pending hash for snapshot.
                %% The fold iterator releases when it returns.
                _ = bitcask:fold_keys(R, fun(_E, A) -> A end, []),
                %% After fold completes, frozen drops back to false.
                ?assertEqual(false, bitcask:is_frozen(R))
            after
                bitcask:close(R)
            end
        end)
     end}.

fold_keys_populates_real_entry_fields_test_() ->
    {"fold_keys/3 in cask mode hands callbacks a #bitcask_entry with real "
     "file_id/offset/total_sz/tstamp (not zero stubs)",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            ok = bitcask:put(R, <<"alpha">>, <<"vvvv">>),
            ok = bitcask:put(R, <<"beta">>,  <<"wwwww">>),
            try
                Acc = bitcask:fold_keys(
                        R,
                        fun(E, A) -> [E | A] end,
                        []),
                ?assertEqual(2, length(Acc)),
                lists:foreach(
                  fun(E) ->
                      ?assert(is_record(E, bitcask_entry)),
                      %% file_id == active data file's tstamp (>0)
                      ?assert(E#bitcask_entry.file_id  > 0),
                      %% total_sz includes the 14-B header
                      ?assert(E#bitcask_entry.total_sz >= 14),
                      %% writer stamps current time
                      ?assert(E#bitcask_entry.tstamp   > 0),
                      ?assert(E#bitcask_entry.offset  >= 0)
                  end, Acc)
            after
                bitcask:close(R)
            end
        end)
    end}.

%% ===================================================================
%% fold 启动失败的裸 atom 归一（A5）
%%   另一个 fold 在跑 + 期间有写入 → pending 表存在；再开一个带
%%   MaxPut=0 的 fold，NIF 返回裸 out_of_date。以前 fold/6 / fold_keys/6
%%   只匹配 {ok,_}/{error,_}，这里直接 case_clause。
%% ===================================================================

fold6_out_of_date_is_error_tuple_test_() ->
    {"fold/6 + fold_keys/6 撞上 out_of_date 返回 {error, out_of_date}，不崩",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k1">>, <<"v1">>),
                {ok, S} = bitcask:stream(R),          % 挂一个 fold 在跑
                ok = bitcask:put(R, <<"k2">>, <<"v2">>), % fold 期间写 → pending
                Cnt = fun(_K, _V, A) -> A + 1 end,
                ?assertEqual({error, out_of_date},
                             bitcask:fold(R, Cnt, 0, -1, 0, false)),
                ?assertEqual({error, out_of_date},
                             bitcask:fold_keys(R, fun(_E, A) -> A + 1 end, 0, -1, 0, false)),
                %% 不限就照常能开（复用现有 freeze）
                ?assert(is_integer(bitcask:fold(R, Cnt, 0, -1, -1, false))),
                ok = bitcask:stop(S)
            after bitcask:close(R) end
        end)
     end}.

%% ===================================================================
%% stream 读完即释放迭代器；stop 之后 next 不挂（A6）
%% ===================================================================

stream_releases_iter_on_done_without_stop_test_() ->
    {"读到 done 后迭代器立刻释放（is_frozen 回 false），不必等 stop",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                {ok, S} = bitcask:stream(R),
                %% fold 期间写入 → pending 表建立 → is_frozen 为 true；
                %% 最后一个迭代器 release 时 pending 合并回主表、frozen 归 false
                ok = bitcask:put(R, <<"k2">>, <<"v2">>),
                ?assertEqual(true, bitcask:is_frozen(R)),
                {ok, <<"k">>, <<"v">>} = bitcask:next(S),
                ?assertEqual(done, bitcask:next(S)),
                %% 没调 stop——以前这里 producer 还在 drain_loop 里钉着迭代器
                ?assertEqual(false, bitcask:is_frozen(R)),
                ?assertEqual({ok, <<"v2">>}, bitcask:get(R, <<"k2">>)),
                ?assertEqual(done, bitcask:next(S)),
                ok = bitcask:stop(S)
            after bitcask:close(R) end
        end)
     end}.

stream_next_after_stop_returns_done_test_() ->
    {"stop 之后再 next 返回 done（以前永久挂起：stop 已 flush 掉 monitor）",
     {timeout, 10, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                {ok, S} = bitcask:stream(R),
                ok = bitcask:stop(S),
                %% 等 producer 真退出，覆盖 noproc 路径
                {bitcask_stream, Pid, _} = S,
                Mon = erlang:monitor(process, Pid),
                receive {'DOWN', Mon, process, Pid, _} -> ok
                after 2000 -> error(producer_didnt_exit) end,
                ?assertEqual(done, bitcask:next(S)),
                ?assertEqual(done, bitcask:next(S)),
                %% 信箱里不残留 DOWN
                %% 只看 stream 自己的消息：eunit 同一进程跑整模块，信箱里可能有
                %% 别的用例留下的 {'EXIT', _, normal}（trap_exit 打开过）。
                {messages, Msgs} = process_info(self(), messages),
                ?assertEqual([], [M || M <- Msgs, is_tuple(M), tuple_size(M) >= 1,
                                        is_atom(element(1, M)),
                                        lists:prefix("bitcask_stream", atom_to_list(element(1, M)))])
            after bitcask:close(R) end
        end)
     end}}.

%% ===================================================================
%% merge 调度器（A4）：merge/1,2,3 经 bitcask_merge_worker 走一遍都不崩
%%   以前 do_merge 的 [_,_,Args3] = Args 在 2 元形态上必 badmatch，worker
%%   异常退出后 handle_info 又返回非法的 {stop, State}，调度器一起死。
%% ===================================================================

merge_worker_survives_all_arities_test_() ->
    {"merge/1,2,3 经调度器执行，worker 与调度器都活着，队列清空",
     {timeout, 30, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),           % 顺带把 application 起来
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ok = bitcask:close(R),
            Sched = whereis(bitcask_merge_worker),
            ?assert(is_pid(Sched)),
            application:set_env(bitcask, merge_window, always),
            ok = bitcask_merge_worker:merge(D),
            wait_idle(),
            ok = bitcask_merge_worker:merge(D, [{frag_threshold, 1}]),
            wait_idle(),
            ok = bitcask_merge_worker:merge(D, [], []),          % 裸列表
            wait_idle(),
            ok = bitcask_merge_worker:merge(D, [], {[], []}),    % legacy 二元组
            wait_idle(),
            ?assertEqual(Sched, whereis(bitcask_merge_worker)),
            ?assertEqual({0, undefined}, bitcask_merge_worker:status())
        end)
     end}}.

merge_worker_dedupes_and_survives_worker_crash_test_() ->
    {"同目录请求在队列里合并（2 元 + 3 元、列表 + 二元组）；worker 被 kill 后调度器继续出队",
     {timeout, 30, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            ok = bitcask:close(R),
            Sched = whereis(bitcask_merge_worker),
            application:set_env(bitcask, merge_window, always),
            Self = self(),
            meck:new(bitcask, [passthrough]),
            try
                %% merge/2 卡住不返回 → worker 占着，后续请求只能排队
                meck:expect(bitcask, merge, fun(_Dir, _Opts) ->
                                                    receive release -> ok
                                                    after 10000 -> ok end
                                            end),
                meck:expect(bitcask, merge, fun(Dir, Opts, Files) ->
                                                    Self ! {merged3, Dir, Opts, Files},
                                                    ok
                                            end),
                ok = bitcask_merge_worker:merge(D ++ "_busy"),
                {0, W} = bitcask_merge_worker:status(),
                ?assert(is_pid(W)),
                %% 同 Dir 的 2 元、3 元裸列表、3 元二元组 → 合并成一条
                ok = bitcask_merge_worker:merge(D, [{b, 2}, {a, 1}]),
                ok = bitcask_merge_worker:merge(D, [{a, 1}], ["f1"]),
                ok = bitcask_merge_worker:merge(D, [{c, 3}], {["f2"], ["f1"]}),
                ?assertEqual({1, W}, bitcask_merge_worker:status()),
                %% worker 崩溃（不是 normal）→ 调度器不能死，要接着出队
                exit(W, kill),
                receive
                    {merged3, Dir3, Opts3, Files3} ->
                        ?assertEqual(D, Dir3),
                        ?assertEqual([{a, 1}, {b, 2}, {c, 3}], Opts3),
                        %% f1 已 expired，从待合并列表里减掉
                        ?assertEqual({["f2"], ["f1"]}, Files3)
                after 5000 -> error(queued_merge_never_ran)
                end,
                wait_idle(),
                ?assertEqual(Sched, whereis(bitcask_merge_worker)),
                ?assertEqual({0, undefined}, bitcask_merge_worker:status())
            after
                meck:unload(bitcask)
            end
        end)
     end}}.

wait_idle() -> wait_idle(200).
wait_idle(0) -> error({merge_worker_still_busy, bitcask_merge_worker:status()});
wait_idle(N) ->
    case bitcask_merge_worker:status() of
        {0, undefined} -> ok;
        _ -> timer:sleep(20), wait_idle(N - 1)
    end.

%% ===================================================================
%% 6.6.1 回归:cask_close 与迭代器 / 在途调用的生命周期(NIF 层)
%% ===================================================================

%% 以前 cask_close 直接 delete 掉 Cask 对象,fold 迭代器持的是裸 parent 指针,
%% close 之后 next 就是 use-after-free。现在对象活到资源析构,close 后的
%% next → {error, closed},release 照常 ok。
fold_iter_survives_close_test_() ->
    {"close 之后 fold 迭代器 next → {error, closed},release → ok;stream 同",
     fun() ->
        with_dir(fun(D) ->
            {Ref, _} = R = bitcask:open(D, ?CASK),
            [ok = bitcask:put(R, <<"k", (integer_to_binary(I))/binary>>, <<"v">>)
             || I <- lists:seq(1, 50)],
            {ok, It} = bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1, false),
            ?assertMatch({ok, _, _}, bitcask_cpp_nifs:cask_fold_next(It)),
            {ok, S} = bitcask:stream(R),
            ?assertMatch({ok, _, _}, bitcask:next(S)),
            ok = bitcask:close(R),
            ?assertEqual({error, closed}, bitcask_cpp_nifs:cask_fold_next(It)),
            ?assertEqual({error, closed}, bitcask_cpp_nifs:cask_fold_next_batch(It, 8)),
            ?assertEqual(ok, bitcask_cpp_nifs:cask_fold_release(It)),
            ?assertEqual({error, closed}, bitcask:next(S)),
            ok = bitcask:stop(S),
            %% 已 close 的句柄:普通调用照旧 badarg(与以前一致),close 幂等
            ?assertError(badarg, bitcask:get(R, <<"k1">>)),
            ?assertEqual(ok, bitcask:close(R)),
            %% 迭代器句柄和 cask 句柄都丢掉后 GC 不崩(析构顺序:iter 先于 cask)
            erlang:garbage_collect(),
            ok
        end)
    end}.

%% 一群进程在普通调度器上 get,同时 dirty 调度器上 close:以前是 UB(cask.hpp
%% 契约要求 close 时无在途调用),现在 close 拿 unique 锁排在在途调用之后。
%% 断言只能是"不崩 + 结果形态合法"。
concurrent_get_vs_close_test_() ->
    {"并发 get 与 close:节点不崩,每个结果都是 {ok,_} | not_found | badarg",
     {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            [ok = bitcask:put(R, <<I:32>>, <<"v">>) || I <- lists:seq(1, 200)],
            Me = self(),
            Readers = [spawn_link(fun() ->
                          Bad = lists:foldl(
                                  fun(I, Acc) ->
                                          try bitcask:get(R, <<(I rem 200 + 1):32>>) of
                                              {ok, _}   -> Acc;
                                              not_found -> Acc;
                                              Other     -> [Other | Acc]
                                          catch error:badarg -> Acc
                                          end
                                  end, [], lists:seq(1, 20000)),
                          Me ! {self(), Bad}
                      end) || _ <- lists:seq(1, 8)],
            timer:sleep(20),
            ok = bitcask:close(R),
            Bads = lists:append([receive {P, B} -> B end || P <- Readers]),
            ?assertEqual([], Bads)
        end)
     end}}.

%% 参数上限:以前一个 INT_MAX 的 k 会让引擎 bad_alloc → std::terminate 整个
%% 节点;现在 k / ef 夹到 kMaxTopK,prefetch 夹到 65536 / 256。
huge_search_and_prefetch_params_are_clamped_test_() ->
    {"k = INT_MAX / prefetch = 2^40 → 正常返回而不是崩溃",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {analyzer, whitespace}, {vector_dim, 4}]),
            Vec = << <<X:32/float-little>> || X <- [1.0, 0.0, 0.0, 0.0] >>,
            ok = bitcask:put(R, <<"v1">>, #{text => <<"x">>, vector => Vec}),
            ?assertMatch({ok, [_]}, bitcask:search_vector(R, Vec, 2147483647, 2147483647)),
            ?assertMatch({ok, [_]}, bitcask:search_text(R, <<"x">>, 2147483647)),
            [ok = bitcask:put(R, <<"k", I:8>>, <<"v">>) || I <- lists:seq(1, 20)],
            Rows = bitcask:range(R, {<<"k">>, <<"l">>},
                                 [{prefetch, 1 bsl 40}, {prefetch_threads, 1 bsl 40}]),
            ?assertEqual(20, length(Rows)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 6.6.1 B 档：fold 家族走批量 / 只要 key 的 NIF；put 按策略转 dirty
%% ===================================================================

%% list_keys / fold_keys/3 / fold_keys/6 改走 cask_fold_next_keys_batch，
%% fold/3 改走 cask_fold_next_batch：与 fold/6（单条 next_full）逐项对账，
%% 含批边界（300 > 2×128）与墓碑两种可见性。
fold_family_agrees_with_fold6_test_() ->
    {"list_keys / fold/3 / fold_keys/3,6 与 fold/6 结果一致（含墓碑、跨批）",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?CASK),
            try
                [ok = bitcask:put(R, <<"k", I:16>>, <<"v", I:16>>) || I <- lists:seq(1, 300)],
                [ok = bitcask:delete(R, <<"k", I:16>>) || I <- lists:seq(1, 300, 7)],
                Live6 = lists:sort(bitcask:fold(R, fun(K, V, A) when is_binary(K) -> [{K, V} | A];
                                                    ({tombstone, _}, _, A) -> A
                                                 end, [], -1, -1, false)),
                ?assertEqual(257, length(Live6)),          % 300 - 43 个删除
                ?assertEqual([K || {K, _} <- Live6], lists:sort(bitcask:list_keys(R))),
                ?assertEqual(Live6, lists:sort(bitcask:fold(R, fun(K, V, A) -> [{K, V} | A] end, []))),
                ?assertEqual([K || {K, _} <- Live6],
                             lists:sort(bitcask:fold_keys(R, fun(E, A) -> [E#bitcask_entry.key | A] end, []))),
                %% fold_keys/3 的 entry 字段与 fold_keys/6(false) 一致
                Ent3 = lists:sort(bitcask:fold_keys(R, fun(E, A) -> [E | A] end, [])),
                Ent6 = lists:sort(bitcask:fold_keys(R, fun(E, A) -> [E | A] end, [], -1, -1, false)),
                ?assertEqual(Ent6, Ent3),
                ?assertMatch(#bitcask_entry{file_id = F, total_sz = S} when F >= 0 andalso S > 0, hd(Ent3)),
                %% 墓碑：fold_keys/6(true) 与 fold/6(true) 看到同一批 {tombstone, _}
                Tomb6 = lists:sort(bitcask:fold(R, fun({tombstone, K}, _V, A) -> [K | A];
                                                    (_, _, A) -> A
                                                 end, [], -1, -1, true)),
                TombK = lists:sort(bitcask:fold_keys(R, fun({tombstone, E}, A) -> [E#bitcask_entry.key | A];
                                                        (_, A) -> A
                                                     end, [], -1, -1, true)),
                ?assertEqual(Tomb6, TombK),
                LiveK = lists:sort(bitcask:fold_keys(R, fun(#bitcask_entry{key = K}, A) -> [K | A];
                                                        (_, A) -> A
                                                     end, [], -1, -1, true)),
                ?assertEqual([K || {K, _} <- Live6], LiveK)
            after bitcask:close(R) end
        end)
     end}.

%% put / delete 在有 sync 策略、值是 map、值 > 64 KiB 时经 enif_schedule_nif 转到
%% dirty IO 调度器再做；结果与直接跑完全一样，这里只验证每条路径都能走通。
put_reschedule_paths_test_() ->
    {"o_sync / {puts,N} / 100 KiB 值 / map 值：put 与 delete 照常工作",
     fun() ->
        with_dir(fun(D) ->
            Big = binary:copy(<<"x">>, 100 * 1024),
            R1 = bitcask:open(D, [{sync_strategy, o_sync} | ?CASK]),
            ok = bitcask:put(R1, <<"a">>, <<"1">>),
            ok = bitcask:put(R1, <<"big">>, Big),
            ?assertEqual({ok, <<"1">>}, bitcask:get(R1, <<"a">>)),
            ?assertEqual({ok, Big}, bitcask:get(R1, <<"big">>)),
            ok = bitcask:delete(R1, <<"a">>),
            ?assertEqual(not_found, bitcask:get(R1, <<"a">>)),
            ?assertError(badarg, bitcask:put(R1, <<"b">>, not_a_binary)),
            bitcask:close(R1),
            R2 = bitcask:open(D, [{sync_strategy, {puts, 3}} | ?CASK]),
            [ok = bitcask:put(R2, <<I:8>>, <<"v">>) || I <- lists:seq(1, 10)],
            ok = bitcask:delete(R2, <<3:8>>),
            ?assertEqual(not_found, bitcask:get(R2, <<3:8>>)),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R2, <<10:8>>)),
            ?assertEqual({ok, Big}, bitcask:get(R2, <<"big">>)),      % o_sync 时写的
            bitcask:close(R2),
            %% 无策略 + 小值：inline 路径；100 KiB：dirty 路径。两者读回一致。
            R3 = bitcask:open(D, ?CASK),
            ok = bitcask:put(R3, <<"small">>, <<"s">>),
            ok = bitcask:put(R3, <<"big2">>, Big),
            ?assertEqual({ok, <<"s">>}, bitcask:get(R3, <<"small">>)),
            ?assertEqual({ok, Big}, bitcask:get(R3, <<"big2">>)),
            bitcask:close(R3)
        end)
     end}.

%% map 值走 put_doc（索引模式），同样是 dirty 路径；顺带 k > 语料的搜索返回全部
%% 命中（make_search_hits 分配失败现在是报错而不是悄悄丢 hit——这里只能验证
%% 正常路径的完整性）。
put_doc_reschedule_and_search_k_over_corpus_test_() ->
    {"map 值 put（dirty 路径）+ search_text k=1000 返回全部 3 条",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {analyzer, whitespace}]),
            ok = bitcask:put(R, <<"d1">>, #{text => <<"alpha beta">>}),
            ok = bitcask:put(R, <<"d2">>, #{text => <<"alpha gamma">>}),
            ok = bitcask:put(R, <<"d3">>, #{text => <<"alpha delta">>}),
            {ok, Hits} = bitcask:search_text(R, <<"alpha">>, 1000),
            ?assertEqual([<<"d1">>, <<"d2">>, <<"d3">>], lists:sort([K || {K, _, _} <- Hits])),
            ?assertMatch({ok, #{text := <<"alpha beta">>}}, bitcask:get(R, <<"d1">>)),
            bitcask:close(R)
        end)
     end}.
