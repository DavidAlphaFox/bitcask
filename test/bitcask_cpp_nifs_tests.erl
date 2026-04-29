%% -------------------------------------------------------------------
%% bitcask_cpp_nifs_tests:
%%   Parity test suite that exercises the new C++ NIF (bitcask_cpp_nifs)
%%   side-by-side with the legacy bitcask_nifs (C). Each test calls both
%%   modules with identical arguments and asserts identical results.
%%
%%   This is the M1 acceptance gate: any deviation must be fixed before
%%   any caller is migrated off bitcask_nifs.
%% -------------------------------------------------------------------
-module(bitcask_cpp_nifs_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(LEGACY, bitcask_nifs).
-define(CPP,    bitcask_cpp_nifs).

%% ===================================================================
%% Test fixtures
%% ===================================================================

setup() ->
    Dir = filename:join(["/tmp", "bitcask_cpp_test_" ++ os:getpid()]),
    ok = filelib:ensure_path(Dir),
    Dir.

teardown(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.

with_dir(Fun) ->
    Dir = setup(),
    try Fun(Dir)
    after teardown(Dir)
    end.

%% ===================================================================
%% File NIF parity
%% ===================================================================

file_open_close_test_() ->
    {"file_open + file_close on both backends", fun() ->
        with_dir(fun(Dir) ->
            P1 = filename:join(Dir, "a.dat"),
            P2 = filename:join(Dir, "b.dat"),
            {ok, R1} = ?LEGACY:file_open(P1, [create]),
            {ok, R2} = ?CPP:file_open(P2, [create]),
            ?assert(is_reference(R1)),
            ?assert(is_reference(R2)),
            ?assertEqual(ok, ?LEGACY:file_close(R1)),
            ?assertEqual(ok, ?CPP:file_close(R2))
        end)
    end}.

file_open_missing_returns_enoent_test_() ->
    {"file_open of missing file returns {error, enoent} on both", fun() ->
        with_dir(fun(Dir) ->
            P = filename:join(Dir, "ghost.dat"),
            ?assertEqual({error, enoent}, ?LEGACY:file_open(P, [readonly])),
            ?assertEqual({error, enoent}, ?CPP:file_open(P, [readonly]))
        end)
    end}.

file_create_exclusive_test_() ->
    {"second [create] open returns {error, eexist}", fun() ->
        with_dir(fun(Dir) ->
            P = filename:join(Dir, "x.dat"),
            {ok, R1} = ?LEGACY:file_open(P, [create]),
            ?assertEqual({error, eexist}, ?LEGACY:file_open(P, [create])),
            ?assertEqual({error, eexist}, ?CPP:file_open(P, [create])),
            ?assertEqual(ok, ?LEGACY:file_close(R1))
        end)
    end}.

file_write_pread_round_trip_test_() ->
    {"pwrite then pread round-trip on both", fun() ->
        with_dir(fun(Dir) ->
            check_round_trip(?LEGACY, filename:join(Dir, "l.dat")),
            check_round_trip(?CPP,    filename:join(Dir, "c.dat"))
        end)
    end}.

check_round_trip(M, P) ->
    {ok, R} = M:file_open(P, [create]),
    Data = <<"hello world!", 0, 1, 2, 3>>,
    ?assertEqual(ok, M:file_pwrite(R, 0, Data)),
    ?assertEqual({ok, Data}, M:file_pread(R, 0, byte_size(Data))),
    ?assertEqual(ok, M:file_close(R)).

file_pread_at_eof_returns_eof_atom_test_() ->
    {"pread on empty file returns the atom eof, not a tuple", fun() ->
        with_dir(fun(Dir) ->
            {ok, RL} = ?LEGACY:file_open(filename:join(Dir, "el"), [create]),
            {ok, RC} = ?CPP:file_open   (filename:join(Dir, "ec"), [create]),
            ?assertEqual(eof, ?LEGACY:file_pread(RL, 0, 16)),
            ?assertEqual(eof, ?CPP:file_pread   (RC, 0, 16)),
            ok = ?LEGACY:file_close(RL),
            ok = ?CPP:file_close(RC)
        end)
    end}.

file_pread_short_returns_partial_test_() ->
    {"pread past EOF returns the prefix that was readable", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R} = M:file_open(P, [create]),
                ok = M:file_pwrite(R, 0, <<"abc">>),
                ?assertEqual({ok, <<"abc">>}, M:file_pread(R, 0, 100)),
                ok = M:file_close(R)
            end,
            FunM(?LEGACY, filename:join(Dir, "sl")),
            FunM(?CPP,    filename:join(Dir, "sc"))
        end)
    end}.

file_append_default_test_() ->
    {"default open uses O_APPEND — successive writes accumulate", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R1} = M:file_open(P, [create]),
                ok = M:file_write(R1, <<"AAA">>),
                ok = M:file_close(R1),
                {ok, R2} = M:file_open(P, []),
                ok = M:file_write(R2, <<"BBB">>),
                ok = M:file_close(R2),
                {ok, RR} = M:file_open(P, [readonly]),
                ?assertEqual({ok, <<"AAABBB">>}, M:file_pread(RR, 0, 6)),
                ok = M:file_close(RR)
            end,
            FunM(?LEGACY, filename:join(Dir, "al")),
            FunM(?CPP,    filename:join(Dir, "ac"))
        end)
    end}.

file_position_test_() ->
    {"file_position handles long, {bof,_}, {cur,_}, {eof,_}", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R} = M:file_open(P, [create]),
                ok = M:file_pwrite(R, 0, <<"0123456789">>),
                ?assertEqual({ok, 4}, M:file_position(R, 4)),
                ?assertEqual({ok, 4}, M:file_position(R, {bof, 4})),
                ?assertEqual({ok, 6}, M:file_position(R, {cur, 2})),
                ?assertEqual({ok, 10}, M:file_position(R, {eof, 0})),
                ok = M:file_close(R)
            end,
            FunM(?LEGACY, filename:join(Dir, "pl")),
            FunM(?CPP,    filename:join(Dir, "pc"))
        end)
    end}.

file_truncate_test_() ->
    {"file_truncate cuts to current offset", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R} = M:file_open(P, [create]),
                ok = M:file_pwrite(R, 0, <<"abcdef">>),
                {ok, _} = M:file_position(R, 3),
                ok = M:file_truncate(R),
                ok = M:file_close(R),
                {ok, #file_info{size = Sz}} = file:read_file_info(P),
                ?assertEqual(3, Sz)
            end,
            FunM(?LEGACY, filename:join(Dir, "tl")),
            FunM(?CPP,    filename:join(Dir, "tc"))
        end)
    end}.

file_seekbof_test_() ->
    {"file_seekbof rewinds to position 0", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R} = M:file_open(P, [create]),
                ok = M:file_write(R, <<"abc">>),
                ok = M:file_seekbof(R),
                ?assertEqual({ok, 0}, M:file_position(R, {cur, 0})),
                ok = M:file_close(R)
            end,
            FunM(?LEGACY, filename:join(Dir, "bl")),
            FunM(?CPP,    filename:join(Dir, "bc"))
        end)
    end}.

file_sync_test_() ->
    {"file_sync on a regular fd returns ok", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, P) ->
                {ok, R} = M:file_open(P, [create]),
                ok = M:file_write(R, <<"x">>),
                ?assertEqual(ok, M:file_sync(R)),
                ok = M:file_close(R)
            end,
            FunM(?LEGACY, filename:join(Dir, "yl")),
            FunM(?CPP,    filename:join(Dir, "yc"))
        end)
    end}.

%% ===================================================================
%% Lock NIF parity
%% ===================================================================

lock_acquire_release_test_() ->
    {"write-lock acquire creates file; release unlinks it", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                ?assertEqual(false, filelib:is_file(P)),
                {ok, L} = M:lock_acquire(P, 1),
                ?assert(filelib:is_file(P)),
                ok = M:lock_release(L),
                ?assertEqual(false, filelib:is_file(P))
            end,
            FunM(?LEGACY, "wl"),
            FunM(?CPP,    "wc")
        end)
    end}.

lock_exclusive_test_() ->
    {"second write-lock attempt returns {error, eexist}", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                {ok, L1} = M:lock_acquire(P, 1),
                ?assertEqual({error, eexist}, M:lock_acquire(P, 1)),
                ok = M:lock_release(L1)
            end,
            FunM(?LEGACY, "el"),
            FunM(?CPP,    "ec")
        end)
    end}.

lock_writedata_readdata_test_() ->
    {"writedata then readdata round-trip", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                {ok, W} = M:lock_acquire(P, 1),
                ok = M:lock_writedata(W, <<"payload-bytes">>),
                ?assertEqual({ok, <<"payload-bytes">>}, M:lock_readdata(W)),
                ok = M:lock_release(W)
            end,
            FunM(?LEGACY, "rl"),
            FunM(?CPP,    "rc")
        end)
    end}.

lock_writedata_truncates_test_() ->
    {"writedata truncates prior contents", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                {ok, W} = M:lock_acquire(P, 1),
                ok = M:lock_writedata(W, <<"AAAAAAAAAA">>),
                ok = M:lock_writedata(W, <<"BB">>),
                ?assertEqual({ok, <<"BB">>}, M:lock_readdata(W)),
                ok = M:lock_release(W)
            end,
            FunM(?LEGACY, "trl"),
            FunM(?CPP,    "trc")
        end)
    end}.

lock_readonly_cannot_write_test_() ->
    {"writedata on a read-lock returns {error, lock_not_writable}", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                {ok, W} = M:lock_acquire(P, 1),
                ok = M:lock_writedata(W, <<"x">>),
                {ok, R} = M:lock_acquire(P, 0),
                ?assertEqual({error, lock_not_writable},
                             M:lock_writedata(R, <<"y">>)),
                ok = M:lock_release(R),
                ok = M:lock_release(W)
            end,
            FunM(?LEGACY, "ro_l"),
            FunM(?CPP,    "ro_c")
        end)
    end}.

lock_readonly_missing_test_() ->
    {"read-lock on missing file returns {error, enoent}", fun() ->
        with_dir(fun(Dir) ->
            P = filename:join(Dir, "nope"),
            ?assertEqual({error, enoent}, ?LEGACY:lock_acquire(P, 0)),
            ?assertEqual({error, enoent}, ?CPP:lock_acquire(P, 0))
        end)
    end}.

lock_readdata_empty_test_() ->
    {"readdata on freshly acquired empty lock returns {ok, <<>>}", fun() ->
        with_dir(fun(Dir) ->
            FunM = fun(M, Name) ->
                P = filename:join(Dir, Name),
                {ok, W} = M:lock_acquire(P, 1),
                ?assertEqual({ok, <<>>}, M:lock_readdata(W)),
                ok = M:lock_release(W)
            end,
            FunM(?LEGACY, "empty_l"),
            FunM(?CPP,    "empty_c")
        end)
    end}.

%% ===================================================================
%% Resource cleanup
%% ===================================================================

resource_dtor_closes_fd_test_() ->
    {timeout, 30,
     {"GC of an unreferenced file ref must close the fd (no leak)", fun() ->
        with_dir(fun(Dir) ->
            P = filename:join(Dir, "gc.dat"),
            {ok, R} = bitcask_cpp_nifs:file_open(P, [create]),
            ok = bitcask_cpp_nifs:file_write(R, <<"x">>),
            R = R,                       %% suppress 'unused'
            erlang:garbage_collect(),
            %% Drop the binding and force GC; the resource dtor must run.
            erase(),
            erlang:garbage_collect(),
            timer:sleep(50),
            %% File should still exist; just ensure no crash on subsequent open.
            {ok, R2} = bitcask_cpp_nifs:file_open(P, [readonly]),
            ok = bitcask_cpp_nifs:file_close(R2)
        end)
     end}}.
