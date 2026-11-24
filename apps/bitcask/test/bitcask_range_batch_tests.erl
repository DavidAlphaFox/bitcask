%% range_fold 的 {batch, N} 选项。
-module(bitcask_range_batch_tests).
-include_lib("eunit/include/eunit.hrl").

with_dir(F) -> bitcask_test_util:with_dir("range_batch", F).

range_batch_option_test_() ->
    {"range_fold {batch, N}：任意批大小结果相同；越界 → badarg",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            [ok = bitcask:put(R, <<"r", I:16>>, <<I:16>>) || I <- lists:seq(1, 1500)],
            Collect = fun(Opts) ->
                              lists:reverse(bitcask:range_fold(R, {<<"r">>, <<"s">>}, Opts,
                                                               fun(K, _V, _T, _O, A) -> [K | A] end, []))
                      end,
            Ref = Collect([]),
            ?assertEqual(1500, length(Ref)),
            [?assertEqual({B, Ref}, {B, Collect([{batch, B}])}) || B <- [1, 7, 16, 255, 256, 1024]],
            ?assertError(badarg, Collect([{batch, 0}])),
            ?assertError(badarg, Collect([{batch, 1025}])),
            ?assertError(badarg, Collect([{batch, x}])),
            %% range/3 收 batch 也不影响结果
            ?assertEqual(length(Ref), length(bitcask:range(R, {<<"r">>, <<"s">>}, [{batch, 10}]))),
            bitcask:close(R)
        end)
     end}.
