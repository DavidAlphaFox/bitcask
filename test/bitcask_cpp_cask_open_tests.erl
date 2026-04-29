%% -------------------------------------------------------------------
%% bitcask_cpp_cask_open_tests:
%%   End-to-end parity for bitcask:open/2 with the {nifs, cask_cpp} flag.
%%
%%   This is the M3.5 acceptance test:
%%   identical sequences of bitcask:* operations on a fresh dir, comparing
%%   the legacy back-end against the coarse-grained cask_cpp NIF path.
%% -------------------------------------------------------------------
-module(bitcask_cpp_cask_open_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/bitcask_cpp_cask_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% Run the body once for legacy, once for cask_cpp.
each_backend(Body) ->
    with_dir(fun(D1) -> Body(bitcask:open(D1, [read_write])) end),
    with_dir(fun(D2) -> Body(bitcask:open(D2, [read_write, {nifs, cask_cpp}])) end).

%% ===================================================================
%% Smoke
%% ===================================================================

open_close_cask_test_() ->
    {"open/close on cask_cpp returns a usable resource", fun() ->
        each_backend(fun(R) ->
            ?assert(is_reference(R)),
            ?assertEqual(ok, bitcask:close(R))
        end)
    end}.

put_get_round_trip_cask_test_() ->
    {"put + get round-trip on both backends", fun() ->
        each_backend(fun(R) ->
            ?assertEqual(ok, bitcask:put(R, <<"k1">>, <<"hello">>)),
            ?assertEqual({ok, <<"hello">>}, bitcask:get(R, <<"k1">>)),
            bitcask:close(R)
        end)
    end}.

put_overwrite_cask_test_() ->
    {"overwrite returns latest value", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"k">>, <<"v1">>),
            ok = bitcask:put(R, <<"k">>, <<"v2">>),
            ?assertEqual({ok, <<"v2">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

delete_cask_test_() ->
    {"delete makes get return not_found", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ok = bitcask:delete(R, <<"k">>),
            ?assertEqual(not_found, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

get_missing_cask_test_() ->
    {"get on absent key returns not_found", fun() ->
        each_backend(fun(R) ->
            ?assertEqual(not_found, bitcask:get(R, <<"never">>)),
            bitcask:close(R)
        end)
    end}.

list_keys_cask_test_() ->
    {"list_keys returns all live keys", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"a">>, <<"1">>),
            ok = bitcask:put(R, <<"b">>, <<"2">>),
            ok = bitcask:put(R, <<"c">>, <<"3">>),
            ok = bitcask:delete(R, <<"b">>),
            Keys = lists:sort(bitcask:list_keys(R)),
            ?assertEqual([<<"a">>, <<"c">>], Keys),
            bitcask:close(R)
        end)
    end}.

fold_cask_test_() ->
    {"fold visits every live key with its value", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"a">>, <<"1">>),
            ok = bitcask:put(R, <<"b">>, <<"2">>),
            ok = bitcask:put(R, <<"c">>, <<"3">>),
            Acc = bitcask:fold(R,
                               fun(K, V, A) -> [{K, V} | A] end,
                               []),
            ?assertEqual([{<<"a">>, <<"1">>},
                          {<<"b">>, <<"2">>},
                          {<<"c">>, <<"3">>}],
                         lists:sort(Acc)),
            bitcask:close(R)
        end)
    end}.

reopen_persists_cask_test_() ->
    {"close + reopen sees previously written values", fun() ->
        with_dir(fun(D) ->
            Backends = [legacy, cask_cpp],
            lists:foreach(fun(Backend) ->
                Sub = filename:join(D, atom_to_list(Backend)),
                Opts = case Backend of
                           legacy   -> [read_write];
                           cask_cpp -> [read_write, {nifs, cask_cpp}]
                       end,
                R1 = bitcask:open(Sub, Opts),
                ok = bitcask:put(R1, <<"persist">>, <<"value">>),
                bitcask:close(R1),
                R2 = bitcask:open(Sub, Opts),
                ?assertEqual({ok, <<"value">>},
                             bitcask:get(R2, <<"persist">>)),
                bitcask:close(R2)
            end, Backends)
        end)
    end}.

binary_value_with_nul_cask_test_() ->
    {"values containing NUL bytes round-trip cleanly", fun() ->
        each_backend(fun(R) ->
            V = <<0, 1, 2, 0, 255, 0>>,
            ok = bitcask:put(R, <<"k">>, V),
            ?assertEqual({ok, V}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

many_keys_cask_test_() ->
    {timeout, 30,
     {"~500 keys round-trip without loss", fun() ->
        each_backend(fun(R) ->
            N = 500,
            lists:foreach(
              fun(I) ->
                  K = integer_to_binary(I),
                  V = <<I:32, K/binary>>,
                  ?assertEqual(ok, bitcask:put(R, K, V))
              end, lists:seq(1, N)),
            lists:foreach(
              fun(I) ->
                  K = integer_to_binary(I),
                  V = <<I:32, K/binary>>,
                  ?assertEqual({ok, V}, bitcask:get(R, K))
              end, lists:seq(1, N)),
            ?assertEqual(N, length(bitcask:list_keys(R))),
            bitcask:close(R)
        end)
    end}}.

status_shape_cask_test_() ->
    {"status returns the legacy 2-tuple shape on both backends", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"a">>, <<"1">>),
            ok = bitcask:put(R, <<"b">>, <<"2">>),
            {KCount, Files} = bitcask:status(R),
            ?assertEqual(2, KCount),
            ?assert(is_list(Files)),
            bitcask:close(R)
        end)
    end}.

is_empty_estimate_cask_test_() ->
    {"is_empty_estimate flips after first put", fun() ->
        each_backend(fun(R) ->
            ?assertEqual(true, bitcask:is_empty_estimate(R)),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual(false, bitcask:is_empty_estimate(R)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% Cask-specific: write lock exclusivity at the bitcask: layer
%% ===================================================================

cask_write_lock_blocks_second_writer_test_() ->
    {"cask_cpp: second open with read_write fails while first holds the lock",
     fun() ->
        with_dir(fun(D) ->
            R1 = bitcask:open(D, [read_write, {nifs, cask_cpp}]),
            ?assert(is_reference(R1)),
            R2 = bitcask:open(D, [read_write, {nifs, cask_cpp}]),
            ?assertMatch({error, _}, R2),
            bitcask:close(R1)
        end)
    end}.
