%% -------------------------------------------------------------------
%%
%% bitcask_cpp_nifs: Erlang shim for the C++23 NIF (priv/bitcask_cpp.so).
%%
%% Public API matches bitcask_nifs 1:1 so individual call sites can flip
%% over without contract changes.
%%
%% Subsets implemented per milestone:
%%   M1: file_*_int / lock_*_int
%%   M2.4 (this): keydir_*_int family + housekeeping
%%
%% -------------------------------------------------------------------
-module(bitcask_cpp_nifs).

%% File I/O
-export([file_open/2,
         file_close/1,
         file_sync/1,
         file_pread/3,
         file_pwrite/3,
         file_read/2,
         file_write/2,
         file_position/2,
         file_seekbof/1,
         file_truncate/1]).

%% Lock
-export([lock_acquire/2,
         lock_release/1,
         lock_readdata/1,
         lock_writedata/2]).

%% KeyDir
-export([keydir_new/0, keydir_new/1,
         maybe_keydir_new/1,
         keydir_mark_ready/1,
         keydir_put/7, keydir_put/8, keydir_put/9, keydir_put/10,
         keydir_get/2, keydir_get/3,
         keydir_get_epoch/1,
         keydir_remove/2, keydir_remove/5,
         keydir_copy/1,
         keydir_itr/3,
         keydir_itr_next/1,
         keydir_itr_release/1,
         keydir_info/1,
         keydir_release/1,
         keydir_trim_fstats/2,
         increment_file_id/1, increment_file_id/2,
         update_fstats/8,
         set_pending_delete/2]).

-on_load(init/0).

-include("bitcask.hrl").

-spec init() -> ok | {error, any()}.
init() ->
    SoName =
        case code:priv_dir(bitcask) of
            {error, bad_name} ->
                case code:which(?MODULE) of
                    Filename when is_list(Filename) ->
                        filename:join([filename:dirname(Filename), "../priv", "bitcask_cpp"]);
                    _ ->
                        filename:join("../priv", "bitcask_cpp")
                end;
            Dir ->
                filename:join(Dir, "bitcask_cpp")
        end,
    erlang:load_nif(SoName, 0).

%% =============================================================================
%% File I/O wrappers — body replaced by NIF on load.
%% =============================================================================
file_open(_F, _O)        -> file_open_int(_F, _O).
file_close(_R)           -> file_close_int(_R).
file_sync(_R)            -> file_sync_int(_R).
file_pread(_R, _O, _S)   -> file_pread_int(_R, _O, _S).
file_pwrite(_R, _O, _B)  -> file_pwrite_int(_R, _O, _B).
file_read(_R, _S)        -> file_read_int(_R, _S).
file_write(_R, _B)       -> file_write_int(_R, _B).
file_position(_R, _L)    -> file_position_int(_R, _L).
file_seekbof(_R)         -> file_seekbof_int(_R).
file_truncate(_R)        -> file_truncate_int(_R).

file_open_int(_F, _O)        -> erlang:nif_error({error, not_loaded}).
file_close_int(_R)           -> erlang:nif_error({error, not_loaded}).
file_sync_int(_R)            -> erlang:nif_error({error, not_loaded}).
file_pread_int(_R, _O, _S)   -> erlang:nif_error({error, not_loaded}).
file_pwrite_int(_R, _O, _B)  -> erlang:nif_error({error, not_loaded}).
file_read_int(_R, _S)        -> erlang:nif_error({error, not_loaded}).
file_write_int(_R, _B)       -> erlang:nif_error({error, not_loaded}).
file_position_int(_R, _L)    -> erlang:nif_error({error, not_loaded}).
file_seekbof_int(_R)         -> erlang:nif_error({error, not_loaded}).
file_truncate_int(_R)        -> erlang:nif_error({error, not_loaded}).

%% =============================================================================
%% Lock wrappers
%% =============================================================================
lock_acquire(_F, _W)      -> lock_acquire_int(_F, _W).
lock_release(_R)          -> lock_release_int(_R).
lock_readdata(_R)         -> lock_readdata_int(_R).
lock_writedata(_R, _B)    -> lock_writedata_int(_R, _B).

lock_acquire_int(_F, _W)  -> erlang:nif_error({error, not_loaded}).
lock_release_int(_R)      -> erlang:nif_error({error, not_loaded}).
lock_readdata_int(_R)     -> erlang:nif_error({error, not_loaded}).
lock_writedata_int(_R, _B) -> erlang:nif_error({error, not_loaded}).

%% =============================================================================
%% KeyDir wrappers
%%
%% put/get encode/decode the offset as <<Off:64/unsigned-native>>, matching
%% the legacy bitcask_nifs API. Callers pass/receive plain integers.
%% =============================================================================

keydir_new()                          -> erlang:nif_error({error, not_loaded}).
keydir_new(_Name)                     -> erlang:nif_error({error, not_loaded}).
maybe_keydir_new(_Name)               -> erlang:nif_error({error, not_loaded}).
keydir_mark_ready(_Ref)               -> erlang:nif_error({error, not_loaded}).

keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec) ->
    keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, false).
keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, NewestPutB) ->
    keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, NewestPutB, 0, 0).
keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, OldFileId, OldOffset) ->
    keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, false,
               OldFileId, OldOffset).
keydir_put(Ref, Key, FileId, TotalSz, Offset, Tstamp, NowSec, NewestPutB,
           OldFileId, OldOffset) ->
    keydir_put_int(Ref, Key, FileId, TotalSz,
                   <<Offset:64/unsigned-native>>,
                   Tstamp, NowSec,
                   if NewestPutB -> 1; true -> 0 end,
                   OldFileId,
                   <<OldOffset:64/unsigned-native>>).

keydir_put_int(_Ref, _Key, _FileId, _TotalSz, _Offset, _Tstamp, _NowSec,
               _NewestPutI, _OldFileId, _OldOffset) ->
    erlang:nif_error({error, not_loaded}).

keydir_get(Ref, Key) ->
    keydir_get(Ref, Key, 16#ffffffffffffffff).
keydir_get(Ref, Key, Epoch) ->
    case keydir_get_int(Ref, Key, Epoch) of
        E when is_record(E, bitcask_entry) ->
            <<Off:64/unsigned-native>> = E#bitcask_entry.offset,
            E#bitcask_entry{offset = Off};
        Other ->
            Other
    end.

keydir_get_int(_Ref, _Key, _Epoch) -> erlang:nif_error({error, not_loaded}).
keydir_get_epoch(_Ref)             -> erlang:nif_error({error, not_loaded}).

keydir_remove(Ref, Key) ->
    %% Legacy default: use current epoch seconds as remove_time.
    keydir_remove(Ref, Key, erlang:system_time(seconds)).

%% 3-arg keydir_remove is the NIF.
keydir_remove(_Ref, _Key, _RemoveTime) -> erlang:nif_error({error, not_loaded}).

%% 5-arg keydir_remove (conditional CAS): wraps a 6-arg NIF (`keydir_remove_int`).
keydir_remove(Ref, Key, Tstamp, FileId, Offset) ->
    keydir_remove_int(Ref, Key, Tstamp, FileId,
                      <<Offset:64/unsigned-native>>,
                      erlang:system_time(seconds)).

keydir_remove_int(_R, _K, _T, _F, _O, _Rt) -> erlang:nif_error({error, not_loaded}).

keydir_copy(_Ref) -> erlang:nif_error({error, not_loaded}).

keydir_itr(Ref, MaxAge, MaxPuts) ->
    Ts = erlang:system_time(seconds),
    keydir_itr_int(Ref, Ts, MaxAge, MaxPuts).

keydir_itr_int(_R, _Ts, _MaxAge, _MaxPuts) -> erlang:nif_error({error, not_loaded}).

keydir_itr_next(Ref) ->
    case keydir_itr_next_int(Ref) of
        E when is_record(E, bitcask_entry) ->
            <<Off:64/unsigned-native>> = E#bitcask_entry.offset,
            E#bitcask_entry{offset = Off};
        Other ->
            Other
    end.
keydir_itr_next_int(_Ref) -> erlang:nif_error({error, not_loaded}).
keydir_itr_release(_Ref)  -> erlang:nif_error({error, not_loaded}).

keydir_info(_Ref)              -> erlang:nif_error({error, not_loaded}).
keydir_release(_Ref)           -> erlang:nif_error({error, not_loaded}).
keydir_trim_fstats(_Ref, _Ids) -> erlang:nif_error({error, not_loaded}).

increment_file_id(_Ref)         -> erlang:nif_error({error, not_loaded}).
increment_file_id(_Ref, _Cond)  -> erlang:nif_error({error, not_loaded}).

update_fstats(_Ref, _FileId, _Tstamp, _Live, _Total, _LiveB, _TotalB, _SC) ->
    erlang:nif_error({error, not_loaded}).
set_pending_delete(_Ref, _FileId) -> erlang:nif_error({error, not_loaded}).
