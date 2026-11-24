#!/usr/bin/env escript
%%! -noshell
%%
%% Generate the byte sequence for the C++ HintFile cross-language golden
%% test. Encodes the same fields legacy bitcask_fileops would, then prints
%% them as hex to stdout. The output is pasted into
%% cpp/tests/data_file_test.cpp as kLegacyHintHex.

main(_) ->
    HintEntry = fun(Key, Tstamp, TombInt, Offset, TotalSz) ->
        KeySz = byte_size(Key),
        list_to_binary([
            <<Tstamp:32, KeySz:16, TotalSz:32, TombInt:1, Offset:63>>,
            Key
        ])
    end,
    R1 = HintEntry(<<"a">>,    100, 0, 0,    19),
    R2 = HintEntry(<<"bb">>,   101, 1, 19,   20),
    R3 = HintEntry(<<"cccc">>, 102, 0, 39,   22),
    Crc = erlang:crc32(<<R1/binary, R2/binary, R3/binary>>),
    %% MAXOFFSET_V2 = 0x7fffffffffffffff
    T = HintEntry(<<>>, 0, 0, 16#7fffffffffffffff, Crc),
    Full = <<R1/binary, R2/binary, R3/binary, T/binary>>,
    io:format("crc=~.16B size=~p~n", [Crc, byte_size(Full)]),
    [io:format("~2.16.0b", [B]) || <<B>> <= Full],
    io:format("~n", []).
