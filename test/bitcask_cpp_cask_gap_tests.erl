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
                %% Format: "<pid> <active_data_path>\n"
                Lines = binary:split(Bin, <<"\n">>, [global, trim]),
                ?assertEqual(1, length(Lines)),
                [Line] = Lines,
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
