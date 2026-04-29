%% -------------------------------------------------------------------
%% bitcask_cpp_nifs_keydir_tests:
%%   Parity tests comparing the new C++ keydir NIF against the legacy C
%%   keydir NIF. Both modules expose the same API with the same record
%%   shapes, so identical inputs must yield identical outputs.
%%
%%   Note: each module owns its own NIF priv_data — i.e. their named-keydir
%%   registries are *separate*. So when we test keydir_new(Name) parity, the
%%   first acquire on each side returns {ok, Ref} independently. The point
%%   of these tests is to verify the *return contract*, not registry sharing.
%% -------------------------------------------------------------------
-module(bitcask_cpp_nifs_keydir_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("../include/bitcask.hrl").

-define(LEGACY, bitcask_nifs).
-define(CPP,    bitcask_cpp_nifs).

%% ===================================================================
%% Anonymous keydir
%% ===================================================================

keydir_new0_test_() ->
    {"keydir_new/0 returns {ok, Ref} on both", fun() ->
        {ok, R1} = ?LEGACY:keydir_new(),
        {ok, R2} = ?CPP:keydir_new(),
        ?assert(is_reference(R1)),
        ?assert(is_reference(R2)),
        ?LEGACY:keydir_release(R1),
        ?CPP:keydir_release(R2)
    end}.

keydir_get_missing_test_() ->
    {"get on empty keydir returns not_found on both", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ?assertEqual(not_found, M:keydir_get(R, <<"ghost">>)),
            M:keydir_release(R)
        end)
    end}.

keydir_put_get_round_trip_test_() ->
    {"put + get round-trip yields identical bitcask_entry", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>,  7,  1234,
                               999,  42,  100),
            E = M:keydir_get(R, <<"k">>),
            ?assertMatch(#bitcask_entry{}, E),
            ?assertEqual(<<"k">>, E#bitcask_entry.key),
            ?assertEqual(7, E#bitcask_entry.file_id),
            ?assertEqual(1234, E#bitcask_entry.total_sz),
            ?assertEqual(999, E#bitcask_entry.offset),
            ?assertEqual(42, E#bitcask_entry.tstamp),
            M:keydir_release(R)
        end)
    end}.

keydir_put_already_exists_on_cas_miss_test_() ->
    {"conditional put with wrong old_file_id returns already_exists", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>, 1, 50, 0, 1, 0),
            ?assertEqual(already_exists,
                         M:keydir_put(R, <<"k">>, 2, 50, 0, 2, 0,
                                       true,
                                       99,
                                       0)),
            M:keydir_release(R)
        end)
    end}.

keydir_put_replaces_with_same_old_file_offset_test_() ->
    {"CAS put with matching old_file_id+offset succeeds", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>, 1, 50, 0, 1, 0),
            ok = M:keydir_put(R, <<"k">>, 2, 60, 100, 5, 0,
                               true,
                               1,  0),
            E = M:keydir_get(R, <<"k">>),
            ?assertEqual(2, E#bitcask_entry.file_id),
            ?assertEqual(100, E#bitcask_entry.offset),
            M:keydir_release(R)
        end)
    end}.

keydir_remove_test_() ->
    {"unconditional remove deletes the key", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>, 1, 50, 0, 1, 0),
            ok = M:keydir_remove(R, <<"k">>),
            ?assertEqual(not_found, M:keydir_get(R, <<"k">>)),
            M:keydir_release(R)
        end)
    end}.

keydir_conditional_remove_test_() ->
    {"5-arg keydir_remove only removes on (Tstamp,FileId,Offset) match", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>, 5, 200, 1234, 7, 0),
            %% Wrong file_id -> already_exists, key untouched.
            ?assertEqual(already_exists,
                         M:keydir_remove(R, <<"k">>, 7, 99, 1234)),
            ?assertMatch(#bitcask_entry{}, M:keydir_get(R, <<"k">>)),
            %% Exact match -> removed.
            ?assertEqual(ok, M:keydir_remove(R, <<"k">>, 7, 5, 1234)),
            ?assertEqual(not_found, M:keydir_get(R, <<"k">>)),
            M:keydir_release(R)
        end)
    end}.

keydir_get_epoch_increases_test_() ->
    {"keydir_get_epoch increments on each mutation", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            E0 = M:keydir_get_epoch(R),
            ok = M:keydir_put(R, <<"a">>, 1, 50, 0, 1, 0),
            E1 = M:keydir_get_epoch(R),
            ?assert(E1 > E0),
            M:keydir_release(R)
        end)
    end}.

keydir_increment_file_id_test_() ->
    {"increment_file_id/1 returns monotonically increasing ids", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            {ok, A} = M:increment_file_id(R),
            {ok, B} = M:increment_file_id(R),
            ?assertEqual(B, A + 1),
            {ok, C} = M:increment_file_id(R, A + 100),
            ?assertEqual(A + 100, C),
            M:keydir_release(R)
        end)
    end}.

keydir_info_shape_test_() ->
    {"keydir_info returns the legacy 5-tuple shape", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"a">>, 1, 50, 0, 1, 0),
            ok = M:keydir_put(R, <<"b">>, 1, 75, 50, 2, 0),
            {KCount, KBytes, FStats, IterInfo, Epoch} = M:keydir_info(R),
            ?assertEqual(2, KCount),
            ?assertEqual(2, KBytes),
            ?assert(is_list(FStats)),
            ?assertEqual(1, length(FStats)),
            [{FileId, LiveK, TotalK, LiveB, TotalB, _, _, _}] = FStats,
            ?assertEqual(1, FileId),
            ?assertEqual(2, LiveK),
            ?assertEqual(2, TotalK),
            ?assertEqual(125, LiveB),
            ?assertEqual(125, TotalB),
            ?assertEqual({0, 0, false, undefined}, IterInfo),
            ?assert(Epoch >= 2),
            M:keydir_release(R)
        end)
    end}.

keydir_copy_test_() ->
    {"keydir_copy returns a usable snapshot Ref", fun() ->
        %% NOTE: legacy bitcask_nifs has a long-standing bug where
        %% keydir_copy memsets the SOURCE handle instead of the new one
        %% (c_src/bitcask_nifs.c around the keydir_copy alloc). After copy,
        %% the source handle is unusable. We therefore only assert what the
        %% legacy can correctly do: that the COPY contains the snapshotted
        %% data, and we don't touch the source again.
        check_each(fun(M) ->
            {ok, R1} = M:keydir_new(),
            ok = M:keydir_put(R1, <<"k">>, 1, 50, 0, 1, 0),
            {ok, R2} = M:keydir_copy(R1),
            ?assertMatch(#bitcask_entry{}, M:keydir_get(R2, <<"k">>)),
            M:keydir_release(R2)
        end)
    end}.

%% C++-only: verify the legacy bug is fixed in our impl.
keydir_copy_source_still_usable_cpp_only_test_() ->
    {"after keydir_copy, source handle remains usable in cpp impl", fun() ->
        {ok, R1} = ?CPP:keydir_new(),
        ok = ?CPP:keydir_put(R1, <<"k">>, 1, 50, 0, 1, 0),
        {ok, R2} = ?CPP:keydir_copy(R1),
        %% Both handles independent and usable.
        ?assertMatch(#bitcask_entry{}, ?CPP:keydir_get(R1, <<"k">>)),
        ?assertMatch(#bitcask_entry{}, ?CPP:keydir_get(R2, <<"k">>)),
        ok = ?CPP:keydir_remove(R1, <<"k">>),
        ?assertEqual(not_found, ?CPP:keydir_get(R1, <<"k">>)),
        ?assertMatch(#bitcask_entry{}, ?CPP:keydir_get(R2, <<"k">>)),
        ?CPP:keydir_release(R1),
        ?CPP:keydir_release(R2)
    end}.

%% ===================================================================
%% Iterator
%% ===================================================================

keydir_itr_basic_test_() ->
    {"itr_int → itr_next_int → itr_release sees all live keys", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"a">>, 1, 50, 0,   1, 0),
            ok = M:keydir_put(R, <<"b">>, 1, 50, 50,  2, 0),
            ok = M:keydir_put(R, <<"c">>, 1, 50, 100, 3, 0),
            ?assertEqual(ok, M:keydir_itr(R, -1, -1)),
            Keys = drain_iter(M, R, []),
            ?assertEqual([<<"a">>, <<"b">>, <<"c">>], lists:sort(Keys)),
            ?assertEqual(ok, M:keydir_itr_release(R)),
            M:keydir_release(R)
        end)
    end}.

keydir_itr_in_process_error_test_() ->
    {"second itr on same handle returns iteration_in_process", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ?assertEqual(ok, M:keydir_itr(R, -1, -1)),
            ?assertEqual({error, iteration_in_process},
                         M:keydir_itr(R, -1, -1)),
            ok = M:keydir_itr_release(R),
            M:keydir_release(R)
        end)
    end}.

keydir_itr_release_without_start_test_() ->
    {"itr_release without itr returns iteration_not_started error", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ?assertEqual({error, iteration_not_started},
                         M:keydir_itr_release(R)),
            M:keydir_release(R)
        end)
    end}.

keydir_itr_snapshot_isolation_test_() ->
    {"writes during fold are invisible to the iterator", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"a">>, 1, 50, 0, 1, 0),
            ok = M:keydir_put(R, <<"b">>, 1, 50, 50, 2, 0),
            ?assertEqual(ok, M:keydir_itr(R, -1, -1)),
            %% Insert a new key after fold started.
            ok = M:keydir_put(R, <<"z">>, 1, 50, 200, 9, 0),
            Keys = drain_iter(M, R, []),
            ?assertEqual([<<"a">>, <<"b">>], lists:sort(Keys)),
            ok = M:keydir_itr_release(R),
            ?assertMatch(#bitcask_entry{}, M:keydir_get(R, <<"z">>)),
            M:keydir_release(R)
        end)
    end}.

%% ===================================================================
%% fstats / pending delete / trim
%% ===================================================================

keydir_set_pending_delete_test_() ->
    {"set_pending_delete sets expiration_epoch in fstats", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"a">>, 3, 100, 0, 1, 0),
            ok = M:set_pending_delete(R, 3),
            {_, _, FStats, _, _} = M:keydir_info(R),
            [{3, _, _, _, _, _, _, ExpEpoch}] = FStats,
            ?assert(ExpEpoch < 16#ffffffffffffffff),
            M:keydir_release(R)
        end)
    end}.

keydir_trim_fstats_test_() ->
    {"trim_fstats removes the listed file_ids and counts missing", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"a">>, 1, 50, 0, 1, 0),
            ok = M:keydir_put(R, <<"b">>, 2, 50, 0, 1, 0),
            {ok, Missing} = M:keydir_trim_fstats(R, [1, 2, 99]),
            ?assertEqual(1, Missing),
            {_, _, FStats, _, _} = M:keydir_info(R),
            ?assertEqual([], FStats),
            M:keydir_release(R)
        end)
    end}.

keydir_update_fstats_test_() ->
    {"update_fstats applies signed deltas in place", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:update_fstats(R,  5,  100,
                                  3,  5,
                                  30,  50,
                                  1),
            {_, _, FStats, _, _} = M:keydir_info(R),
            [{5, 3, 5, 30, 50, _, _, _}] = FStats,
            M:keydir_release(R)
        end)
    end}.

%% ===================================================================
%% Resource cleanup
%% ===================================================================

keydir_release_idempotent_test_() ->
    {"explicit keydir_release followed by GC cleanup is safe", fun() ->
        check_each(fun(M) ->
            {ok, R} = M:keydir_new(),
            ok = M:keydir_put(R, <<"k">>, 1, 50, 0, 1, 0),
            ok = M:keydir_release(R),
            %% Drop binding; GC eventually runs the resource dtor — must not
            %% crash even though release_quiet has already torn things down.
            erase(),
            erlang:garbage_collect(),
            timer:sleep(50)
        end)
    end}.

%% ===================================================================
%% Helpers
%% ===================================================================

check_each(Fun) ->
    Fun(?LEGACY),
    Fun(?CPP).

drain_iter(M, R, Acc) ->
    case M:keydir_itr_next(R) of
        not_found -> Acc;
        E when is_record(E, bitcask_entry) ->
            drain_iter(M, R, [E#bitcask_entry.key | Acc])
    end.
