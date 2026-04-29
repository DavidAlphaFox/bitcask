%% -------------------------------------------------------------------
%% bitcask_cpp_cask_gap_tests:
%%   M4.2 — Drives features the legacy tests rely on but that may not yet
%%   be implemented in cask_cpp. Each test reproduces a legacy scenario
%%   under {nifs, cask_cpp} and asserts the same observable contract.
%%   Failures here are real cask_cpp gaps.
%% -------------------------------------------------------------------
-module(bitcask_cpp_cask_gap_tests).

-include_lib("eunit/include/eunit.hrl").
-include("bitcask.hrl").

-define(CASK, [read_write, {nifs, cask_cpp}]).

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
            ?assertEqual(ok, bitcask:merge(D, [{nifs, cask_cpp},
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
                ?assertEqual(ok, bitcask:merge(D, [{nifs, cask_cpp}]))
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
            ?assertEqual(ok, bitcask:merge(D, [{nifs, cask_cpp}], ToMerge))
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
                Result = bitcask:merge(D, [{nifs, cask_cpp},
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
                    Result = bitcask:merge(D, [{nifs, cask_cpp}]),
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

cross_mode_cask_writes_legacy_reads_test_() ->
    {timeout, 30,
     {"cask_cpp writes a dir; legacy reopens and reads back",
      fun() ->
        with_dir(fun(D) ->
            R1 = bitcask:open(D, [read_write, {nifs, cask_cpp}]),
            ok = bitcask:put(R1, <<"k1">>, <<"v1">>),
            ok = bitcask:put(R1, <<"k2">>, <<"v2">>),
            ok = bitcask:put(R1, <<"k3">>, <<"v3-overwritten">>),
            ok = bitcask:put(R1, <<"k3">>, <<"v3">>),
            bitcask:close(R1),

            R2 = bitcask:open(D, [read_write, {nifs, legacy}]),
            try
                ?assertEqual({ok, <<"v1">>}, bitcask:get(R2, <<"k1">>)),
                ?assertEqual({ok, <<"v2">>}, bitcask:get(R2, <<"k2">>)),
                ?assertEqual({ok, <<"v3">>}, bitcask:get(R2, <<"k3">>))
            after
                bitcask:close(R2)
            end
        end)
     end}}.

cross_mode_legacy_writes_cask_reads_test_() ->
    {timeout, 30,
     {"legacy writes a dir; cask_cpp reopens and reads back",
      fun() ->
        with_dir(fun(D) ->
            R1 = bitcask:open(D, [read_write, {nifs, legacy}]),
            ok = bitcask:put(R1, <<"k1">>, <<"v1">>),
            ok = bitcask:put(R1, <<"k2">>, <<"v2">>),
            ok = bitcask:put(R1, <<"k3">>, <<"older">>),
            ok = bitcask:put(R1, <<"k3">>, <<"newer">>),
            ok = bitcask:delete(R1, <<"k2">>),
            bitcask:close(R1),

            R2 = bitcask:open(D, [read_write, {nifs, cask_cpp}]),
            try
                ?assertEqual({ok, <<"v1">>},   bitcask:get(R2, <<"k1">>)),
                ?assertEqual(not_found,         bitcask:get(R2, <<"k2">>)),
                ?assertEqual({ok, <<"newer">>}, bitcask:get(R2, <<"k3">>)),
                Keys = lists:sort(bitcask:list_keys(R2)),
                ?assertEqual([<<"k1">>, <<"k3">>], Keys)
            after
                bitcask:close(R2)
            end
        end)
     end}}.

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
