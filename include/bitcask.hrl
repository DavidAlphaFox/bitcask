%% 
-record(bitcask_entry, { key :: binary(),
                         file_id :: integer(),
                         total_sz :: integer(),
                         offset :: integer() | binary(), 
                         tstamp :: integer() }).


%% @type filestate().
-record(filestate, {mode :: 'read_only' | 'read_write',     % File mode: read_only, read_write
                    filename :: string(), % Filename
                    tstamp :: integer(),   % Tstamp portion of filename
                    fd :: port(),       % File handle
                    hintfd :: port() | undefined,   % File handle for hints
                    hintcrc=0 :: integer(),  % CRC-32 of current hint
                    ofs :: non_neg_integer(), % Current offset for writing
                    l_ofs=0 :: non_neg_integer(),  % Last offset written to data file
                    l_hbytes=0 :: non_neg_integer(),% Last # bytes written to hint file
                    l_hintcrc=0 :: non_neg_integer()}). % CRC-32 of current hint prior to last write

-record(file_status, { filename :: string(),
                      fragmented :: integer(),
                      dead_bytes :: integer(),
                      total_bytes :: integer(),
                      oldest_tstamp :: integer(),
                      newest_tstamp :: integer(),
                      expiration_epoch :: non_neg_integer() }).


-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

-define(TOMBSTONE_PREFIX, "bitcask_tombstone").
-define(TOMBSTONE0_STR, ?TOMBSTONE_PREFIX).
-define(TOMBSTONE0, <<?TOMBSTONE0_STR>>).
-define(TOMBSTONE1_STR, ?TOMBSTONE_PREFIX "1").
-define(TOMBSTONE1_BIN, <<?TOMBSTONE1_STR>>).
-define(TOMBSTONE2_STR, ?TOMBSTONE_PREFIX "2").
-define(TOMBSTONE2_BIN, <<?TOMBSTONE2_STR>>).
-define(TOMBSTONE0_SIZE, size(?TOMBSTONE0)).
% Size of tombstone + 32 bit file id
-define(TOMBSTONE1_SIZE, (size(?TOMBSTONE1_BIN)+4)).
-define(TOMBSTONE2_SIZE, (size(?TOMBSTONE2_BIN)+4)).
% Change this to the largest size a tombstone value can have if more added.
-define(MAX_TOMBSTONE_SIZE, ?TOMBSTONE2_SIZE).
% Notice that tombstone version 1 and 2 are the same size, so not tested below
-define(IS_TOMBSTONE_SIZE(S), (S == ?TOMBSTONE0_SIZE orelse S == ?TOMBSTONE1_SIZE)).

-define(OFFSETFIELD_V1,  64).
-define(TOMBSTONEFIELD_V2, 1).
-define(OFFSETFIELD_V2,   63).
-define(TSTAMPFIELD,  32).
-define(KEYSIZEFIELD, 16).
-define(TOTALSIZEFIELD, 32).
-define(VALSIZEFIELD, 32).
-define(CRCSIZEFIELD, 32).
-define(HEADER_SIZE,  14). % 4 + 4 + 2 + 4 bytes
-define(MAXKEYSIZE, 2#1111111111111111).
-define(MAXVALSIZE, 2#11111111111111111111111111111111).
-define(MAXOFFSET_V2, 16#7fffffffffffffff). % max 63-bit unsigned

%% for hintfile validation
-define(CHUNK_SIZE, 65535).
-define(MIN_CHUNK_SIZE, 1024).
-define(MAX_CHUNK_SIZE, 134217728).

-define(TEST_FILEPATH, "_build/test/log").

%% NIF dispatcher (M2.4 experimental flag).
%%
%% bitcask:open/2 may be called with the option `{nifs, cpp}` to route all
%% NIF calls through the new C++23 NIF module (`bitcask_cpp_nifs`). When
%% set, open/2 stores the chosen module name in the calling process's
%% process dictionary under the key `bitcask_nif_mod`. This macro reads
%% that key on every call site, falling back to the legacy `bitcask_nifs`.
%%
%% NB: a Ref returned from `bitcask:open` carries a NIF resource type that
%% MUST be operated on by the same NIF that created it — Erlang refs from
%% the cpp NIF are not usable by the legacy NIF and vice versa. Therefore
%% any process that handles a Ref must have its dispatcher set the same
%% way the opener did. For now the experimental flag is intended for
%% single-process usage; gen_server-driven flows (merge_worker / merge_delete)
%% will be wired explicitly in M4.
%% Wrap in a 0-arity fun so each macro expansion creates its own variable
%% scope; without this, two ?NIF: calls in the same function would conflict
%% on the variable bound by the inner case.
-define(NIF, ((fun() ->
                   case erlang:get(bitcask_nif_mod) of
                       undefined -> bitcask_nifs;
                       Mod0 -> Mod0
                   end
               end)())).
