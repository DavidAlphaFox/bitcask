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

%% Legacy helpers re-exported for callers in other modules
%% (bitcask_fileops, bitcask_merge_delete) that hard-coded bitcask:fn.
-export([get_opt/2,
         get_filestate/2,
         is_tombstone/1,
         has_pending_delete_bit/1]).

-include("bitcask.hrl").

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

close_write_file(Ref) ->
    %% Only meaningful in legacy mode; cask manages active writer internally.
    case is_cask() of
        true  -> ok;
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
    %% No cask path here — the {MaxAge, MaxPut, SeeTombstones} contract is
    %% legacy-specific. cask_cpp callers should use fold_keys/3.
    bitcask_legacy:fold_keys(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP).

fold(Ref, Fun, Acc0) ->
    case is_cask() of
        true  -> cask_fold_collect(Ref, Fun, Acc0);
        false -> bitcask_legacy:fold(Ref, Fun, Acc0)
    end.

fold(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    bitcask_legacy:fold(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP).

%% Legacy-only iterator API (cask uses cask_fold_*).
iterator(Ref, MaxAge, MaxPuts) -> bitcask_legacy:iterator(Ref, MaxAge, MaxPuts).
iterator_next(Ref)             -> bitcask_legacy:iterator_next(Ref).
iterator_release(Ref)          -> bitcask_legacy:iterator_release(Ref).

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
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp} ->
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            cask_fold_keys_loop(IterRef, Fun, Fun(E, Acc));
        {error, _} = Err -> Err
    end.

%% Helpers required by other modules (bitcask_fileops, bitcask_merge_delete).
%% In legacy mode they reach into bc_state internals; we delegate.
get_opt(Key, Opts)            -> bitcask_legacy:get_opt(Key, Opts).
get_filestate(FileId, State)  -> bitcask_legacy:get_filestate(FileId, State).
is_tombstone(Value)           -> bitcask_legacy:is_tombstone(Value).
has_pending_delete_bit(F)     -> bitcask_legacy:has_pending_delete_bit(F).
