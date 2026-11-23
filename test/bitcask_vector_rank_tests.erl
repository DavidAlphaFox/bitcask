%% vector_rank：候选集内的精确向量排序（libbitcask 12.1.0）；
%% 以及 12.1.0 带过滤的向量检索回满。
-module(bitcask_vector_rank_tests).
-include_lib("eunit/include/eunit.hrl").

with_dir(F) -> bitcask_test_util:with_dir("vrank", F).

vec(L) -> << <<X:32/float-little>> || X <- L >>.

dot(A, B) -> lists:sum([X * Y || {X, Y} <- lists:zip(A, B)]).

norm(L) ->
    N = math:sqrt(dot(L, L)),
    [X / N || X <- L].

key(I) -> <<"d", (integer_to_binary(I))/binary>>.

%% 确定性的 4 维向量。
fl(I) -> [math:sin(I * 0.37) + 0.01, math:cos(I * 0.91), math:sin(I * 1.7), math:cos(I * 0.13)].

rank_among_candidates_test_() ->
    {"vector_rank：只在候选里排，分数与 search_vector 同口径；跳过不存在 / 无向量 / 已删 / 重复",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {analyzer, whitespace}, {vector_dim, 4}]),
            [ok = bitcask:put(R, key(I), #{text => <<"t">>, vector => vec(fl(I))})
             || I <- lists:seq(1, 200)],
            ok = bitcask:put(R, <<"plain">>, #{text => <<"no vector">>}),
            ok = bitcask:delete(R, key(7)),
            Q = [0.3, -0.7, 0.2, 0.9],
            Ids = [I || I <- lists:seq(1, 200, 3), I =/= 7],
            Cand = [key(I) || I <- lists:seq(1, 200, 3)]
                   ++ [<<"missing">>, <<"plain">>, key(7), key(1)],
            %% 缺省度量 cosine：存的是归一化向量，查询也归一化。
            QN = norm(Q),
            Expect = lists:sort(fun({_, A}, {_, B}) -> A >= B end,
                                [{key(I), dot(QN, norm(fl(I)))} || I <- Ids]),
            %% 不 flush 就能用。
            {ok, Top} = bitcask:vector_rank(R, vec(Q), Cand, 10),
            ?assertEqual(10, length(Top)),
            lists:foreach(
              fun({{K, _Ord, S}, {EK, ES}}) ->
                      ?assertEqual(EK, K),
                      ?assert(abs(S - ES) < 1.0e-5)
              end, lists:zip(Top, lists:sublist(Expect, 10))),
            {ok, All} = bitcask:vector_rank(R, vec(Q), Cand, 1000),
            ?assertEqual(length(Ids), length(All)),
            %% 缺省 K = 10。
            {ok, Def} = bitcask:vector_rank(R, vec(Q), Cand),
            ?assertEqual(Top, Def),
            %% 与 search_vector 同一篇文档的分数、ord 一致。
            {ok, [{TopK, TopOrd, TopS}]} = bitcask:search_vector(R, vec(Q), 1),
            {ok, [{TopK, TopOrd, S1}]} = bitcask:vector_rank(R, vec(Q), [TopK], 1),
            ?assert(abs(S1 - TopS) < 1.0e-4),
            %% 边界与错误。
            ?assertEqual({ok, []}, bitcask:vector_rank(R, vec(Q), [], 5)),
            ?assertEqual({ok, []}, bitcask:vector_rank(R, vec(Q), [<<"missing">>], 5)),
            ?assertMatch({error, _}, bitcask:vector_rank(R, vec([1.0, 2.0, 3.0]), Cand, 5)),
            ?assertError(badarg, bitcask:vector_rank(R, <<1, 2, 3>>, Cand, 5)),
            ?assertError(badarg, bitcask:vector_rank(R, vec(Q), [key(1), not_a_binary], 5)),
            ?assertError(badarg, bitcask:vector_rank(R, vec(Q), not_a_list, 5)),
            bitcask:close(R),
            %% 重开之后（行已落盘）结果相同。
            R2 = bitcask:open(D, [read_write, {analyzer, whitespace}, {vector_dim, 4}]),
            ?assertEqual({ok, Top}, bitcask:vector_rank(R2, vec(Q), Cand, 10)),
            bitcask:close(R2)
        end)
     end}.

no_vector_config_test_() ->
    {"没有向量配置的库：{error, _}，不崩",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertMatch({error, _},
                         bitcask:vector_rank(R, vec([1.0, 0.0, 0.0, 0.0]), [<<"k">>], 1)),
            bitcask:close(R)
        end)
     end}.

filtered_search_fills_k_test_() ->
    {"带 filter 的 search_vector：通过率 0.15%（2 万篇里 30 篇），K=10、Ef=16 也回满（12.1.0 之前只回零星几条）",
     {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {analyzer, whitespace}, {vector_dim, 4}]),
            N = 20000,
            Rare = fun(I) -> I rem 667 =:= 1 end,
            ok = bitcask:put_docs(
                   R, [{key(I),
                        #{text => <<"t">>, vector => vec(fl(I)),
                          meta => bitcask:encode_meta(
                                    #{<<"tag">> => case Rare(I) of
                                                       true  -> <<"rare">>;
                                                       false -> <<"common">>
                                                   end})}}
                       || I <- lists:seq(1, N)]),
            NRare = length([I || I <- lists:seq(1, N), Rare(I)]),
            ?assertEqual(30, NRare),
            F = #{key => <<"tag">>, op => eq, value => <<"rare">>},
            Q = [0.3, -0.7, 0.2, 0.9],
            {ok, Hits} = bitcask:search_vector(R, vec(Q), 10, 16, F),
            ?assertEqual(10, length(Hits)),
            %% 精确扫描的结果就是通过者里真正最近的 10 个：与 vector_rank 对同一批候选的结果一致。
            {ok, Truth} = bitcask:vector_rank(R, vec(Q), [key(I) || I <- lists:seq(1, N), Rare(I)], 10),
            ?assertEqual([K || {K, _, _} <- Truth], [K || {K, _, _} <- Hits]),
            %% K 大于通过者总数：全部返回。
            {ok, AllHits} = bitcask:search_vector(R, vec(Q), 100, 16, F),
            ?assertEqual(NRare, length(AllHits)),
            bitcask:close(R)
        end)
     end}}.
