%% bitcask_entry: shape returned by iterator_next/1 and fold_keys
%% callbacks. file_id / total_sz / offset / tstamp come straight from the
%% cask_cpp NIF; offset is sometimes handed back as a 64-bit big-endian
%% binary (legacy on-wire shape — bitcask_cpp_nifs:keydir_get unpacks it).
-record(bitcask_entry, { key      :: binary(),
                         file_id  :: integer(),
                         total_sz :: integer(),
                         offset   :: integer() | binary(),
                         tstamp   :: integer() }).
