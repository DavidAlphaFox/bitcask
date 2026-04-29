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
