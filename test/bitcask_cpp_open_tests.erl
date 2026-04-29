%% -------------------------------------------------------------------
%% bitcask_cpp_open_tests:
%%   End-to-end parity for bitcask:open/2 with the {nifs, cpp} flag.
%%
%%   Runs the same sequence of public bitcask:* operations against both
%%   the legacy NIF (default) and the C++ NIF (`{nifs, cpp}` flag) and
%%   asserts identical observable behaviour. This is the integration test
%%   that exercises real business-code paths through the new NIF.
%% -------------------------------------------------------------------
-module(bitcask_cpp_open_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/bitcask_cpp_open_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% Apply the same body to both back-ends, opening fresh dirs for each.
each_backend(Body) ->
    with_dir(fun(D1) ->
        Body(bitcask:open(D1, [read_write]))
    end),
    with_dir(fun(D2) ->
        Body(bitcask:open(D2, [read_write, {nifs, cpp}]))
    end).

%% ===================================================================
%% Smoke
%% ===================================================================

open_close_test_() ->
    {"open/close on both backends", fun() ->
        each_backend(fun(R) ->
            ?assert(is_reference(R)),
            ?assertEqual(ok, bitcask:close(R))
        end)
    end}.

put_get_round_trip_test_() ->
    {"put + get round-trip on both backends", fun() ->
        each_backend(fun(R) ->
            ?assertEqual(ok, bitcask:put(R, <<"k1">>, <<"hello">>)),
            ?assertEqual({ok, <<"hello">>}, bitcask:get(R, <<"k1">>)),
            bitcask:close(R)
        end)
    end}.

put_overwrite_test_() ->
    {"overwrite returns latest value", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"k">>, <<"v1">>),
            ok = bitcask:put(R, <<"k">>, <<"v2">>),
            ?assertEqual({ok, <<"v2">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

delete_test_() ->
    {"delete makes get return not_found", fun() ->
        each_backend(fun(R) ->
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ok = bitcask:delete(R, <<"k">>),
            ?assertEqual(not_found, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

get_missing_test_() ->
    {"get on absent key returns not_found", fun() ->
        each_backend(fun(R) ->
            ?assertEqual(not_found, bitcask:get(R, <<"never">>)),
            bitcask:close(R)
        end)
    end}.

list_keys_test_() ->
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

fold_test_() ->
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

reopen_persists_test_() ->
    {"close + reopen sees previously written values", fun() ->
        with_dir(fun(D) ->
            Backends = [legacy, cpp],
            lists:foreach(fun(Backend) ->
                Sub = filename:join(D, atom_to_list(Backend)),
                Opts = case Backend of
                           legacy -> [read_write];
                           cpp    -> [read_write, {nifs, cpp}]
                       end,
                R1 = bitcask:open(Sub, Opts),
                ok = bitcask:put(R1, <<"persist">>, <<"value">>),
                bitcask:close(R1),
                R2 = bitcask:open(Sub, Opts),
                ?assertEqual({ok, <<"value">>}, bitcask:get(R2, <<"persist">>)),
                bitcask:close(R2)
            end, Backends)
        end)
    end}.

binary_value_with_nul_test_() ->
    {"values containing NUL bytes round-trip cleanly", fun() ->
        each_backend(fun(R) ->
            V = <<0, 1, 2, 0, 255, 0>>,
            ok = bitcask:put(R, <<"k">>, V),
            ?assertEqual({ok, V}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

many_keys_test_() ->
    {"~1k keys round-trip without loss", fun() ->
        each_backend(fun(R) ->
            N = 1000,
            lists:foreach(
              fun(I) ->
                  K = integer_to_binary(I),
                  V = <<I:32, K/binary>>,
                  ok = bitcask:put(R, K, V)
              end, lists:seq(1, N)),
            lists:foreach(
              fun(I) ->
                  K = integer_to_binary(I),
                  V = <<I:32, K/binary>>,
                  ?assertEqual({ok, V}, bitcask:get(R, K))
              end, lists:seq(1, N)),
            bitcask:close(R)
        end)
    end}.
