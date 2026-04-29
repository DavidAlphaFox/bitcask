%% -------------------------------------------------------------------
%% bitcask_cpp_cask_gap_tests:
%%   M4.2 — Drives features the legacy tests rely on but that may not yet
%%   be implemented in cask_cpp. Each test reproduces a legacy scenario
%%   under {nifs, cask_cpp} and asserts the same observable contract.
%%   Failures here are real cask_cpp gaps.
%% -------------------------------------------------------------------
-module(bitcask_cpp_cask_gap_tests).

-include_lib("eunit/include/eunit.hrl").

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
