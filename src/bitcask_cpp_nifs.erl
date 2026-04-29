%% -------------------------------------------------------------------
%%
%% bitcask_cpp_nifs: Erlang shim for the C++23 NIF (priv/bitcask_cpp.so).
%%
%% M1 phase: implements the file_*_int / lock_*_int subset.
%% Public API matches bitcask_nifs 1:1 so individual call sites can flip
%% over without contract changes.
%%
%% -------------------------------------------------------------------
-module(bitcask_cpp_nifs).

-export([file_open/2,
         file_close/1,
         file_sync/1,
         file_pread/3,
         file_pwrite/3,
         file_read/2,
         file_write/2,
         file_position/2,
         file_seekbof/1,
         file_truncate/1,
         lock_acquire/2,
         lock_release/1,
         lock_readdata/1,
         lock_writedata/2]).

-on_load(init/0).

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

%% Public wrappers — body replaced by NIF on load.
file_open(_Filename, _Opts)        -> file_open_int(_Filename, _Opts).
file_close(_Ref)                   -> file_close_int(_Ref).
file_sync(_Ref)                    -> file_sync_int(_Ref).
file_pread(_Ref, _Offset, _Size)   -> file_pread_int(_Ref, _Offset, _Size).
file_pwrite(_Ref, _Offset, _Bytes) -> file_pwrite_int(_Ref, _Offset, _Bytes).
file_read(_Ref, _Size)             -> file_read_int(_Ref, _Size).
file_write(_Ref, _Bytes)           -> file_write_int(_Ref, _Bytes).
file_position(_Ref, _Loc)          -> file_position_int(_Ref, _Loc).
file_seekbof(_Ref)                 -> file_seekbof_int(_Ref).
file_truncate(_Ref)                -> file_truncate_int(_Ref).
lock_acquire(_File, _IsWrite)      -> lock_acquire_int(_File, _IsWrite).
lock_release(_Ref)                 -> lock_release_int(_Ref).
lock_readdata(_Ref)                -> lock_readdata_int(_Ref).
lock_writedata(_Ref, _Bin)         -> lock_writedata_int(_Ref, _Bin).

%% NIF-implemented stubs.
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
lock_acquire_int(_F, _W)     -> erlang:nif_error({error, not_loaded}).
lock_release_int(_R)         -> erlang:nif_error({error, not_loaded}).
lock_readdata_int(_R)        -> erlang:nif_error({error, not_loaded}).
lock_writedata_int(_R, _B)   -> erlang:nif_error({error, not_loaded}).
