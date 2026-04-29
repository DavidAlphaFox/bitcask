%% -------------------------------------------------------------------
%%
%% bitcask: facade dispatching between three NIF implementations.
%%
%%   Mode `cask_cpp` (production default):
%%       coarse-grained C++ NIF — open/get/put/delete/fold are single
%%       cask_* calls into bitcask_cpp_nifs. The Ref returned from open IS
%%       the cask resource handle. Hot-path code lives in cpp/.
%%
%%   Mode `cpp`:
%%       new C++ NIF, but talked to via the original fine-grained
%%       keydir_*_int / file_*_int interface. The legacy bitcask_legacy
%%       implementation is reused; only the underlying NIF .so changes.
%%
%%   Mode `legacy`:
%%       original C NIF (priv/bitcask.so), original implementation.
%%
%% A user may select a mode explicitly via the {nifs, M} option to open/2.
%% Without the option, default_nif_mode/0 chooses one (TEST profile = legacy
%% to keep historical white-box tests working; production = cask_cpp).
%%
%% =========================================================================
%%
%% Copyright (c) 2010 Basho Technologies, Inc. All Rights Reserved.
%% Apache License, Version 2.0 — see LICENSE.
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

%% Helpers other modules in this app reach through `bitcask:` directly
%% (bitcask_fileops, bitcask_merge_delete). Until those modules are
%% retired with the rest of legacy, keep these here as the canonical
%% definitions — the bodies live in this file, not delegated to
%% bitcask_legacy.
-export([get_opt/2,
         is_tombstone/1,
         has_pending_delete_bit/1]).

-include("bitcask.hrl").
-include_lib("kernel/include/file.hrl").

%% =========================================================================
%% open/close — the only places that actually pick a mode.
%% =========================================================================

open(Dirname) -> open(Dirname, []).

-spec open(Dirname::string(), Opts::[_]) -> reference() | {error, term()}.
open(Dirname, Opts) ->
    %% Both legacy and cask paths read defaults from the bitcask application
    %% env (open_timeout, max_file_size, ...), so start the app once up front.
    catch application:load(bitcask),
    catch application:start(bitcask),
    Mode = proplists:get_value(nifs, Opts, default_nif_mode()),
    case Mode of
        cask_cpp ->
            erlang:put(bitcask_use_cask, true),
            erlang:erase(bitcask_nif_mod),
            return_cask_open(Dirname, Opts);
        cpp ->
            erlang:put(bitcask_nif_mod, bitcask_cpp_nifs),
            erlang:erase(bitcask_use_cask),
            bitcask_legacy:open(Dirname, Opts);
        legacy ->
            erlang:erase(bitcask_nif_mod),
            erlang:erase(bitcask_use_cask),
            bitcask_legacy:open(Dirname, Opts);
        _ ->
            erlang:erase(bitcask_nif_mod),
            erlang:erase(bitcask_use_cask),
            bitcask_legacy:open(Dirname, Opts)
    end.

%% Default-mode policy: production = cask_cpp; -DTEST = legacy. Settable
%% via application:set_env(bitcask, default_nif_mode, M).
default_nif_mode() ->
    case application:get_env(bitcask, default_nif_mode) of
        {ok, M} when M =:= legacy; M =:= cpp; M =:= cask_cpp -> M;
        _                                                    -> default_nif_mode_compiled()
    end.

-ifdef(TEST).
default_nif_mode_compiled() -> legacy.
-else.
default_nif_mode_compiled() -> cask_cpp.
-endif.

%% Cask-cpp-only entry: the Ref returned IS the cask resource handle.
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

return_cask_open(Dirname, Opts) ->
    Base = case proplists:get_bool(read_write, Opts) of
               true  -> [read_write];
               false -> []
           end,
    %% Translate any passthrough opt that's set in Opts; if missing in Opts,
    %% fall back to the bitcask application env (so legacy `init_keydir`-style
    %% configuration via app config still tunes the cask path).
    Extra = [{K, opt_value(K, Opts)} ||
                K <- ?CASK_PASSTHROUGH_OPTS,
                opt_value(K, Opts) =/= undefined],
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

%% =========================================================================
%% Public API dispatchers — each public function chooses the path based on
%% whether the open above set bitcask_use_cask=true in this process.
%% =========================================================================

close(Ref) ->
    case is_cask() of
        true  ->
            erlang:erase(bitcask_use_cask),
            bitcask_cpp_nifs:cask_close(Ref);
        false ->
            bitcask_legacy:close(Ref)
    end.

%% close_write_file/1 finalizes the active hint trailer, releases
%% bitcask.write.lock, and leaves the Ref usable: the next put/delete
%% reacquires the lock and creates a fresh active file. Mirrors legacy
%% semantics — the lock briefly leaves your hands, so a peer process can
%% open the dir for writing in the gap.
close_write_file(Ref) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_close_write_file(Ref);
        false -> bitcask_legacy:close_write_file(Ref)
    end.

get(Ref, Key) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_get(Ref, Key);
        false -> bitcask_legacy:get(Ref, Key)
    end.

put(Ref, Key, Value) ->
    case is_cask() of
        true  ->
            case Value of
                tombstone -> bitcask_cpp_nifs:cask_delete(Ref, Key);
                _         -> bitcask_cpp_nifs:cask_put(Ref, Key, Value)
            end;
        false ->
            bitcask_legacy:put(Ref, Key, Value)
    end.

delete(Ref, Key) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_delete(Ref, Key);
        false -> bitcask_legacy:delete(Ref, Key)
    end.

sync(Ref) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_sync(Ref);
        false -> bitcask_legacy:sync(Ref)
    end.

list_keys(Ref) ->
    case is_cask() of
        true ->
            cask_fold_collect(Ref, fun(K, _V, Acc) -> [K | Acc] end, []);
        false ->
            bitcask_legacy:list_keys(Ref)
    end.

fold_keys(Ref, Fun, Acc0) ->
    case is_cask() of
        true ->
            cask_fold_keys_collect(Ref, Fun, Acc0);
        false ->
            bitcask_legacy:fold_keys(Ref, Fun, Acc0)
    end.

fold_keys(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case is_cask() of
        true ->
            cask_fold_keys6_collect(Ref, Fun, Acc0,
                                     cask_max_age(MaxAge), cask_max_put(MaxPut),
                                     SeeTombstonesP);
        false ->
            bitcask_legacy:fold_keys(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP)
    end.

fold(Ref, Fun, Acc0) ->
    case is_cask() of
        true  -> cask_fold_collect(Ref, Fun, Acc0);
        false -> bitcask_legacy:fold(Ref, Fun, Acc0)
    end.

fold(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case is_cask() of
        true ->
            cask_fold6_collect(Ref, Fun, Acc0,
                                cask_max_age(MaxAge), cask_max_put(MaxPut),
                                SeeTombstonesP);
        false ->
            bitcask_legacy:fold(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP)
    end.

%% Stateful iterator. Both legacy and cask back this with on-handle state
%% (one active iterator per Ref). Returns:
%%   ok | out_of_date | {error, iteration_in_process}
iterator(Ref, MaxAge, MaxPuts) ->
    case is_cask() of
        true ->
            case bitcask_cpp_nifs:cask_iterator(
                   Ref, cask_max_age(MaxAge), cask_max_put(MaxPuts)) of
                ok           -> ok;
                out_of_date  -> out_of_date;
                {error, _} = E -> E
            end;
        false ->
            bitcask_legacy:iterator(Ref, MaxAge, MaxPuts)
    end.

%% Returns #bitcask_entry{} | not_found | {error, iteration_not_started}
iterator_next(Ref) ->
    case is_cask() of
        true ->
            case bitcask_cpp_nifs:cask_iterator_next(Ref) of
                not_found    -> not_found;
                {ok, K, _V, FileId, Offset, TotalSz, Tstamp} ->
                    #bitcask_entry{key = K, file_id = FileId,
                                   total_sz = TotalSz, offset = Offset,
                                   tstamp = Tstamp};
                {error, _} = E -> E
            end;
        false ->
            bitcask_legacy:iterator_next(Ref)
    end.

iterator_release(Ref) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_iterator_release(Ref);
        false -> bitcask_legacy:iterator_release(Ref)
    end.

%% Directory-level merge dispatcher.
%%
%% In cask_cpp mode (M5.1), bitcask:merge/1,2,3 opens a temporary Cask in
%% read_write mode and drives the merge through cask_merge. This requires
%% no other writer to be holding the directory's write.lock. If a live
%% writer exists (single-process workflow where the same Erlang process
%% has an open Ref), the caller should instead use the open Ref directly:
%%
%%     {true, {Files, _}} = bitcask:needs_merge(R),
%%     bitcask_cpp_nifs:cask_merge(R, Files).
%%
%% In legacy/cpp modes, the long-standing behaviour is preserved:
%% bitcask_legacy:merge acquires merge.lock and coordinates with a
%% separately-held write.lock through the legacy keydir registry.
merge(Dirname) -> merge(Dirname, []).

merge(Dirname, Opts) ->
    case merge_mode(Opts) of
        cask_cpp -> cask_merge_dir(Dirname, Opts, all);
        _        -> bitcask_legacy:merge(Dirname, Opts)
    end.

merge(Dirname, Opts, FilesToMerge) ->
    case merge_mode(Opts) of
        cask_cpp -> cask_merge_dir(Dirname, Opts, FilesToMerge);
        _        -> bitcask_legacy:merge(Dirname, Opts, FilesToMerge)
    end.

%% Picks the merge backend based on opts (explicit > app env > default).
merge_mode(Opts) ->
    proplists:get_value(nifs, Opts, default_nif_mode()).

%% all | [string()] | {[string()], [string()]} (legacy-shaped pair)
%%
%% Uses {merge_only, true} so a live writer (which holds bitcask.write.lock)
%% can keep running concurrently — the merger acquires bitcask.merge.lock
%% on a separate file.
cask_merge_dir(Dirname, Opts, FilesArg) ->
    OpenOpts = [merge_only | cask_open_opts(Opts)],
    case bitcask_cpp_nifs:cask_open(Dirname, OpenOpts) of
        {ok, R} ->
            try cask_merge_run(R, FilesArg)
            after bitcask_cpp_nifs:cask_close(R)
            end;
        {error, write_locked} ->
            %% Another merger already holds bitcask.merge.lock — this is
            %% a real concurrency conflict, not the writer's lock.
            {error, {merge_locked,
                     "another merger is already running on this dir",
                     Dirname}};
        {error, _} = E ->
            E
    end.

cask_merge_run(R, all) ->
    case bitcask_cpp_nifs:cask_needs_merge(R) of
        false                  -> ok;
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

%% Build the cask_open option list given a legacy-style opts proplist.
cask_open_opts(Opts) ->
    Base = [read_write],
    Extra = [{K, opt_value(K, Opts)} ||
                K <- ?CASK_PASSTHROUGH_OPTS,
                opt_value(K, Opts) =/= undefined],
    Base ++ Extra.

needs_merge(Ref) -> needs_merge(Ref, []).

needs_merge(Ref, Opts) ->
    case is_cask() of
        true ->
            case bitcask_cpp_nifs:cask_needs_merge(Ref) of
                false                     -> false;
                {true, Files, Expired}    -> {true, {Files, Expired}}
            end;
        false ->
            bitcask_legacy:needs_merge(Ref, Opts)
    end.

is_frozen(Ref) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_is_frozen(Ref);
        false -> bitcask_legacy:is_frozen(Ref)
    end.

is_empty_estimate(Ref) ->
    case is_cask() of
        true  -> bitcask_cpp_nifs:cask_is_empty(Ref);
        false -> bitcask_legacy:is_empty_estimate(Ref)
    end.

status(Ref) ->
    case is_cask() of
        true ->
            {KCount, _KBytes, _Epoch, Files} = bitcask_cpp_nifs:cask_status(Ref),
            {KCount, Files};
        false ->
            bitcask_legacy:status(Ref)
    end.

%% =========================================================================
%% Internal helpers + re-exports
%% =========================================================================

is_cask() ->
    erlang:get(bitcask_use_cask) =:= true.

%% Walk a cask iterator, applying Fun(K, V, Acc) — used by list_keys, fold,
%% fold_keys when in cask mode.
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

%% fold_keys variant: rebuilds a #bitcask_entry from cask iterator entries
%% so callers see the same shape as legacy (file_id / offset / total_sz / tstamp
%% are real, not zero-filled stubs).
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
            %% fold_keys/3 default: tombstones are filtered upstream
            %% (see_tombstones=false), so _IsTomb is always false here.
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            cask_fold_keys_loop(IterRef, Fun, Fun(E, Acc));
        {error, _} = Err -> Err
    end.

%% fold_keys/6 cask branch. SeeTombstonesP=true surfaces tombstones via
%% callback shape `{tombstone, BCEntry}`; otherwise filter them.
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
                       true                     -> Acc;  % shouldn't reach
                       false                    -> Fun(E, Acc)
                   end,
            cask_fold_keys6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% fold/6 cask branch. Callback contract follows legacy:
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
                       true                     -> Acc;  % shouldn't reach
                       false                    -> Fun(K, V, Acc)
                   end,
            cask_fold6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% Convert legacy MaxAge (microseconds) / MaxPut to cask iter units.
%% Legacy fold/6 takes MaxAge already-converted-to-µs (`* 1000` from the ms
%% app env); cask iter wants seconds with -1 meaning "no limit".
cask_max_age(undefined) -> -1;
cask_max_age(N) when is_integer(N), N < 0 -> -1;
cask_max_age(N) when is_integer(N) -> N div 1000000.

cask_max_put(undefined) -> -1;
cask_max_put(N) when is_integer(N), N < 0 -> -1;
cask_max_put(N) when is_integer(N) -> N.

%% Helpers shared with bitcask_fileops / bitcask_merge_delete. These are
%% byte-level identical to the bodies that lived in bitcask_legacy until
%% M6 prep moved them here so the cask path no longer depends on legacy.

%% Resolve Opts proplist > app env > undefined.
get_opt(Key, Opts) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(bitcask, Key) of
                {ok, Value} -> Value;
                undefined   -> undefined
            end;
        Value -> Value
    end.

%% A "tombstone value" is any binary whose first 17 bytes are
%% "bitcask_tombstone" — covers v0/v1/v2 in one check (bitcask.hrl).
is_tombstone(<<?TOMBSTONE_PREFIX, _Rest/binary>>) -> true;
is_tombstone(_)                                   -> false.

%% setuid bit on the data file marks it for deferred deletion. Read with
%% bitcask_fileops:read_file_info so we don't bypass its compatibility
%% wrapper around prim_file:read_file_info.
has_pending_delete_bit(File) ->
    try
        {ok, FI} = bitcask_fileops:read_file_info(File),
        FI#file_info.mode band 8#4001 /= 0
    catch _:_ ->
        false
    end.
