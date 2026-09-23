%% -------------------------------------------------------------------
%% bitcask_libbitcask_660_tests:
%%   libbitcask 6.6.0 新增面的适配覆盖：
%%     - {segment_verify_crc, B} open 选项透传（BM25 段开库 CRC 开关）
%%     - bitcask:set_thread_limits/2 / thread_limits/0（进程级线程上限）
%%
%%   线程上限是**进程级、首个索引模式库 open 即冻结、不可逆**的。eunit 在同
%%   一个 VM 里跑全部模块，本模块跑到时多半早已冻结，所以这里只断言与顺序
%%   无关的性质：先强制冻结，再验「同值幂等 / 异值报 frozen 且带生效值」。
%% -------------------------------------------------------------------
-module(bitcask_libbitcask_660_tests).

-include_lib("eunit/include/eunit.hrl").

with_dir(Fun) ->
    Dir = "/tmp/bitcask_660_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

hits(R, Q) ->
    {ok, Hits} = bitcask:search_text(R, Q),
    lists:sort([K || {K, _Ord, _Score} <- Hits]).

segment_verify_crc_roundtrip_test_() ->
    {"{segment_verify_crc, false|true} 开库、写入、重开检索结果一致",
     fun() ->
        with_dir(fun(D) ->
            Opts = [read_write, {analyzer, whitespace}],
            R0 = bitcask:open(D, [{segment_verify_crc, false} | Opts]),
            ok = bitcask:put(R0, <<"d1">>, <<"the quick brown fox">>),
            ok = bitcask:put(R0, <<"d2">>, <<"a lazy brown dog">>),
            ok = bitcask:sync(R0),
            ?assertEqual([<<"d1">>, <<"d2">>], hits(R0, <<"brown">>)),
            bitcask:close(R0),
            lists:foreach(
              fun(B) ->
                  R = bitcask:open(D, [{segment_verify_crc, B} | Opts]),
                  ?assertEqual([<<"d1">>, <<"d2">>], hits(R, <<"brown">>)),
                  ?assertEqual([<<"d1">>], hits(R, <<"fox">>)),
                  bitcask:close(R)
              end, [false, true])
        end)
    end}.

thread_limits_freeze_semantics_test_() ->
    {"首个索引模式库 open 后冻结：同值 ok，异值 {error, {thread_limits_frozen, 生效值}}",
     fun() ->
        with_dir(fun(D) ->
            %% 强制冻结（若本 VM 之前没开过索引模式库）。
            R = bitcask:open(D, [read_write, {analyzer, whitespace}]),
            bitcask:close(R),
            {IW, SS} = Cur = bitcask:thread_limits(),
            ?assert(is_integer(IW) andalso IW >= 0),
            ?assert(is_integer(SS) andalso SS >= 0),
            ?assertEqual(ok, bitcask:set_thread_limits(IW, SS)),
            ?assertEqual({error, {thread_limits_frozen, Cur}},
                         bitcask:set_thread_limits(IW + 1, SS)),
            ?assertEqual({error, {thread_limits_frozen, Cur}},
                         bitcask:set_thread_limits(IW, SS + 1)),
            ?assertEqual(Cur, bitcask:thread_limits())
        end)
    end}.

thread_limits_badarg_test() ->
    ?assertError(badarg, bitcask:set_thread_limits(-1, 0)),
    ?assertError(badarg, bitcask:set_thread_limits(0, foo)).
