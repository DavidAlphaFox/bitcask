%% -------------------------------------------------------------------
%% bitcask_default_mode_tests:
%%   Verifies the default-NIF-mode policy.
%%   - Under -DTEST (this profile), default is pinned to `cask_cpp` so
%%     the eunit suite exercises the same code path as production.
%%   - Application env `default_nif_mode` overrides the compiled default
%%     for callers that want to test legacy or cpp explicitly.
%% -------------------------------------------------------------------
-module(bitcask_default_mode_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/bitcask_default_mode_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% Compiled default in TEST profile is now cask_cpp (matches production).
test_profile_default_is_cask_cpp_test_() ->
    {"in -DTEST profile, default_nif_mode = cask_cpp", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            ?assert(is_reference(R)),
            ?assertEqual(true, erlang:get(bitcask_use_cask)),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

%% application env override: switch the default to legacy at runtime.
override_default_to_legacy_test_() ->
    {"app env default_nif_mode=legacy routes default open to legacy path",
     fun() ->
        with_dir(fun(D) ->
            application:set_env(bitcask, default_nif_mode, legacy),
            try
                R = bitcask:open(D, [read_write]),
                ?assert(is_reference(R)),
                %% cask flag NOT set under legacy.
                ?assertEqual(undefined, erlang:get(bitcask_use_cask)),
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
                bitcask:close(R)
            after
                application:unset_env(bitcask, default_nif_mode)
            end
        end)
    end}.

override_default_to_cpp_test_() ->
    {"app env default_nif_mode=cpp routes default open to cpp NIF (fine-grained)",
     fun() ->
        with_dir(fun(D) ->
            application:set_env(bitcask, default_nif_mode, cpp),
            try
                R = bitcask:open(D, [read_write]),
                ?assert(is_reference(R)),
                ?assertEqual(undefined, erlang:get(bitcask_use_cask)),
                ?assertEqual(bitcask_cpp_nifs, erlang:get(bitcask_nif_mod)),
                ok = bitcask:put(R, <<"k">>, <<"v">>),
                ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
                bitcask:close(R)
            after
                application:unset_env(bitcask, default_nif_mode)
            end
        end)
    end}.

%% Callers can still pin a single open back to legacy via explicit option.
explicit_legacy_overrides_default_test_() ->
    {"explicit {nifs, legacy} option opts out of cask_cpp default", fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {nifs, legacy}]),
            ?assert(is_reference(R)),
            ?assertEqual(undefined, erlang:get(bitcask_use_cask)),
            ?assertEqual(undefined, erlang:get(bitcask_nif_mod)),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, bitcask:get(R, <<"k">>)),
            bitcask:close(R)
        end)
    end}.

%% Garbage value in app env should fall through to compiled default.
unknown_env_value_falls_through_test_() ->
    {"unknown app env value reverts to compiled default (cask_cpp in TEST)",
     fun() ->
        with_dir(fun(D) ->
            application:set_env(bitcask, default_nif_mode, garbage),
            try
                R = bitcask:open(D, [read_write]),
                ?assert(is_reference(R)),
                ?assertEqual(true, erlang:get(bitcask_use_cask)),
                bitcask:close(R)
            after
                application:unset_env(bitcask, default_nif_mode)
            end
        end)
    end}.
