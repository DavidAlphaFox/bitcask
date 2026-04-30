%% -------------------------------------------------------------------
%%
%% bitcask: thin Erlang facade over the cask_cpp NIF.
%%
%% The Ref returned by open/2 is the cask resource handle. Every public
%% function below is a single dispatch into bitcask_cpp_nifs:cask_*.
%%
%% Iteration helpers (list_keys, fold, fold_keys) wrap a cask_fold_*
%% iterator and reshape its tuples into the legacy bitcask_entry record
%% so existing callers keep working.
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%%
%% =========================================================================
-module(bitcask).

-export([open/1, open/2,
         close/1,
         close_write_file/1,
         get/2,
         put/3,
         delete/2,
         sync/1,
         list_keys/1,
         fold_keys/3, fold_keys/6,
         fold/3, fold/6,
         iterator/3, iterator_next/1, iterator_release/1,
         merge/1, merge/2, merge/3,
         needs_merge/1,
         needs_merge/2,
         is_frozen/1,
         is_empty_estimate/1,
         status/1]).

-include("bitcask.hrl").

%% Whitelist of options the cask_cpp NIF understands. Anything else is
%% silently dropped (legacy did the same with unknown opts).
-define(CASK_PASSTHROUGH_OPTS, [
    expiry_secs, max_file_size,
    sync_strategy,
    tombstone_version,
    frag_merge_trigger, dead_bytes_merge_trigger,
    frag_threshold, dead_bytes_threshold,
    small_file_threshold, expiry_grace_time,
    max_merge_size
]).

%% =========================================================================
%% open / close
%% =========================================================================

open(Dirname) -> open(Dirname, []).

-spec open(Dirname::string(), Opts::[_]) -> reference() | {error, term()}.
open(Dirname, Opts) ->
    %% Defaults (open_timeout, max_file_size, sync_strategy, ...) live in
    %% the bitcask application env; make sure it is loaded once up front.
    catch application:load(bitcask),
    catch application:start(bitcask),
    Base = case proplists:get_bool(read_write, Opts) of
               true  -> [read_write];
               false -> []
           end,
    Extra = [{K, V} || K <- ?CASK_PASSTHROUGH_OPTS,
                       (V = opt_value(K, Opts)) =/= undefined],
    case bitcask_cpp_nifs:cask_open(Dirname, Base ++ Extra) of
        {ok, CaskRef}  -> CaskRef;
        {error, _} = E -> E
    end.

%% Resolve an option: explicit Opts > app env > undefined.
opt_value(Key, Opts) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(bitcask, Key) of
                {ok, V} -> V;
                _       -> undefined
            end;
        V -> V
    end.

close(Ref) ->
    bitcask_cpp_nifs:cask_close(Ref).

%% close_write_file/1 finalizes the active hint trailer, releases
%% bitcask.write.lock, and leaves the Ref usable: the next put/delete
%% reacquires the lock and creates a fresh active file.
close_write_file(Ref) ->
    bitcask_cpp_nifs:cask_close_write_file(Ref).

%% =========================================================================
%% Read / write
%% =========================================================================

get(Ref, Key) ->
    bitcask_cpp_nifs:cask_get(Ref, Key).

put(Ref, Key, tombstone) ->
    bitcask_cpp_nifs:cask_delete(Ref, Key);
put(Ref, Key, Value) ->
    bitcask_cpp_nifs:cask_put(Ref, Key, Value).

delete(Ref, Key) ->
    bitcask_cpp_nifs:cask_delete(Ref, Key).

sync(Ref) ->
    bitcask_cpp_nifs:cask_sync(Ref).

%% =========================================================================
%% Folds / list_keys (built on a single cask_fold_* iterator)
%% =========================================================================

list_keys(Ref) ->
    cask_fold_collect(Ref, fun(K, _V, Acc) -> [K | Acc] end, []).

fold_keys(Ref, Fun, Acc0) ->
    cask_fold_keys_collect(Ref, Fun, Acc0).

fold_keys(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    cask_fold_keys6_collect(Ref, Fun, Acc0,
                            cask_max_age(MaxAge), cask_max_put(MaxPut),
                            SeeTombstonesP).

fold(Ref, Fun, Acc0) ->
    cask_fold_collect(Ref, Fun, Acc0).

fold(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    cask_fold6_collect(Ref, Fun, Acc0,
                       cask_max_age(MaxAge), cask_max_put(MaxPut),
                       SeeTombstonesP).

%% =========================================================================
%% Stateful iterator (one active per Ref).
%%   iterator/3       -> ok | out_of_date | {error, iteration_in_process}
%%   iterator_next/1  -> #bitcask_entry{} | not_found | {error, ...}
%%   iterator_release/1
%% =========================================================================

iterator(Ref, MaxAge, MaxPuts) ->
    case bitcask_cpp_nifs:cask_iterator(
           Ref, cask_max_age(MaxAge), cask_max_put(MaxPuts)) of
        ok             -> ok;
        out_of_date    -> out_of_date;
        {error, _} = E -> E
    end.

iterator_next(Ref) ->
    case bitcask_cpp_nifs:cask_iterator_next(Ref) of
        not_found    -> not_found;
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp} ->
            #bitcask_entry{key = K, file_id = FileId,
                           total_sz = TotalSz, offset = Offset,
                           tstamp = Tstamp};
        {error, _} = E -> E
    end.

iterator_release(Ref) ->
    bitcask_cpp_nifs:cask_iterator_release(Ref).

%% =========================================================================
%% Directory-level merge
%%
%% bitcask:merge/1,2,3 opens a temporary Cask in read_write mode and
%% drives the merge through cask_merge. {merge_only, true} makes the
%% merger acquire bitcask.merge.lock instead of bitcask.write.lock so a
%% live writer can keep running concurrently. If a peer already holds
%% merge.lock, returns {error, {merge_locked, ...}}.
%%
%% A process that already holds an open writer Ref should drive the
%% merge directly to avoid the temporary open:
%%
%%     {true, {Files, _}} = bitcask:needs_merge(R),
%%     bitcask_cpp_nifs:cask_merge(R, Files).
%% =========================================================================

merge(Dirname) -> merge(Dirname, []).

merge(Dirname, Opts) ->
    cask_merge_dir(Dirname, Opts, all).

merge(Dirname, Opts, FilesToMerge) ->
    cask_merge_dir(Dirname, Opts, FilesToMerge).

cask_merge_dir(Dirname, Opts, FilesArg) ->
    OpenOpts = [merge_only | cask_open_opts(Opts)],
    case bitcask_cpp_nifs:cask_open(Dirname, OpenOpts) of
        {ok, R} ->
            try cask_merge_run(R, FilesArg)
            after bitcask_cpp_nifs:cask_close(R)
            end;
        {error, write_locked} ->
            {error, {merge_locked,
                     "another merger is already running on this dir",
                     Dirname}};
        {error, _} = E ->
            E
    end.

cask_merge_run(R, all) ->
    case bitcask_cpp_nifs:cask_needs_merge(R) of
        false                   -> ok;
        {true, Files, _Expired} -> cask_merge_call(R, Files)
    end;
cask_merge_run(R, {Files, _Expired}) when is_list(Files) ->
    cask_merge_call(R, Files);
cask_merge_run(R, Files) when is_list(Files) ->
    cask_merge_call(R, Files).

cask_merge_call(_R, []) -> ok;
cask_merge_call(R, Files) ->
    case bitcask_cpp_nifs:cask_merge(R, Files) of
        {ok, _Stats}   -> ok;
        {error, _} = E -> E
    end.

cask_open_opts(Opts) ->
    Base = [read_write],
    Extra = [{K, V} || K <- ?CASK_PASSTHROUGH_OPTS,
                       (V = opt_value(K, Opts)) =/= undefined],
    Base ++ Extra.

%% =========================================================================
%% Small queries
%% =========================================================================

needs_merge(Ref) -> needs_merge(Ref, []).

needs_merge(Ref, _Opts) ->
    case bitcask_cpp_nifs:cask_needs_merge(Ref) of
        false                  -> false;
        {true, Files, Expired} -> {true, {Files, Expired}}
    end.

is_frozen(Ref) ->
    bitcask_cpp_nifs:cask_is_frozen(Ref).

is_empty_estimate(Ref) ->
    bitcask_cpp_nifs:cask_is_empty(Ref).

status(Ref) ->
    {KCount, _KBytes, _Epoch, Files} = bitcask_cpp_nifs:cask_status(Ref),
    {KCount, Files}.

%% =========================================================================
%% Internal: cask iterator collectors + arg conversion
%% =========================================================================

%% Walk a cask iterator, applying Fun(K, V, Acc).
cask_fold_collect(Ref, Fun, Acc0) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1) of
        {ok, IterRef} ->
            try cask_fold_loop(IterRef, Fun, Acc0)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_loop(IterRef, Fun, Acc) ->
    case bitcask_cpp_nifs:cask_fold_next(IterRef) of
        done            -> Acc;
        {ok, K, V}      -> cask_fold_loop(IterRef, Fun, Fun(K, V, Acc));
        {error, _} = E  -> E
    end.

%% fold_keys/3: walks the iterator, hands callbacks a fully-populated
%% #bitcask_entry (file_id / offset / total_sz / tstamp from the cask
%% entry, not zero stubs).
cask_fold_keys_collect(Ref, Fun, Acc0) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1) of
        {ok, IterRef} ->
            try cask_fold_keys_loop(IterRef, Fun, Acc0)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_keys_loop(IterRef, Fun, Acc) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp, _IsTomb} ->
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            cask_fold_keys_loop(IterRef, Fun, Fun(E, Acc));
        {error, _} = Err -> Err
    end.

%% fold_keys/6. SeeTombstonesP=true surfaces tombstones via
%% callback shape `{tombstone, BCEntry}`.
cask_fold_keys6_collect(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, MaxAge, MaxPut, SeeTombstonesP) of
        {ok, IterRef} ->
            try cask_fold_keys6_loop(IterRef, Fun, Acc0, SeeTombstonesP)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_keys6_loop(IterRef, Fun, Acc, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp, IsTomb} ->
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            Acc2 = case IsTomb of
                       true when SeeTombstonesP -> Fun({tombstone, E}, Acc);
                       true                     -> Acc;
                       false                    -> Fun(E, Acc)
                   end,
            cask_fold_keys6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% fold/6 callback contract:
%%   normal:        Fun(K, V, Acc)
%%   tombstone:     Fun({tombstone, K}, V, Acc)  (only when SeeTombstonesP=true)
cask_fold6_collect(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, MaxAge, MaxPut, SeeTombstonesP) of
        {ok, IterRef} ->
            try cask_fold6_loop(IterRef, Fun, Acc0, SeeTombstonesP)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold6_loop(IterRef, Fun, Acc, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, V, _Fid, _Off, _Sz, _Ts, IsTomb} ->
            Acc2 = case IsTomb of
                       true when SeeTombstonesP -> Fun({tombstone, K}, V, Acc);
                       true                     -> Acc;
                       false                    -> Fun(K, V, Acc)
                   end,
            cask_fold6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% Legacy fold/6 takes MaxAge already-converted-to-µs (`* 1000` from the ms
%% app env); cask iter wants seconds with -1 meaning "no limit".
cask_max_age(undefined) -> -1;
cask_max_age(N) when is_integer(N), N < 0 -> -1;
cask_max_age(N) when is_integer(N) -> N div 1000000.

cask_max_put(undefined) -> -1;
cask_max_put(N) when is_integer(N), N < 0 -> -1;
cask_max_put(N) when is_integer(N) -> N.
