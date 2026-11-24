%% -------------------------------------------------------------------
%% bitcask_meta_array_tests:
%%   M23 — libbitcask 12.0.0（上游 S62）的 meta 字符串数组 + contains /
%%   contains_any 过滤在 Erlang 门面上的映射：
%%     * encode_meta/decode_meta：[binary()] ⇄ 字符串数组（类型标记 5）；
%%     * 引擎 filter：search_text / range 的 contains、contains_any，现有操作符
%%       碰到数组按类型不匹配；
%%     * bitcask_query：where 的 contains / contains_any，BEAM 侧求值与引擎下推
%%       逐条一致；二级索引字段上存数组不崩、exists 照样命中。
%% -------------------------------------------------------------------
-module(bitcask_meta_array_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IDX, [read_write, {analyzer, whitespace}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_meta_array_", Fun).

m(KV) -> bitcask:encode_meta(KV).

%% 语料：tags 是数组 / 单个 binary / 空数组 / 整数 / 缺失 / null。
%% 全部含词 "doc"，检索 "doc" 命中全部 7 篇。
corpus() ->
    [{<<"a">>, #{<<"tags">> => [<<"rust">>, <<"db">>], <<"zz">> => 1}},
     {<<"b">>, #{<<"tags">> => [<<"erlang">>], <<"zz">> => 2}},
     {<<"c">>, #{<<"tags">> => <<"db">>, <<"zz">> => 3}},
     {<<"d">>, #{<<"tags">> => [], <<"zz">> => 4}},
     {<<"e">>, #{<<"tags">> => 7, <<"zz">> => 5}},
     {<<"f">>, #{<<"zz">> => 6}},
     {<<"g">>, #{<<"tags">> => undefined, <<"zz">> => 7}}].

open_corpus(D) ->
    R = bitcask:open(D, ?IDX),
    [ok = bitcask:put(R, K, #{text => <<"doc ", K/binary>>, meta => m(M)})
     || {K, M} <- corpus()],
    R.

hits(R, F) ->
    {ok, Hits} = bitcask:search_text(R, <<"doc">>, 100, F),
    lists:sort([K || {K, _, _} <- Hits]).

range_keys(R, F) ->
    lists:sort([K || {K, _} <- bitcask:range(R, {undefined, undefined}, [{filter, F}])]).

%% ===================================================================
%% 编解码
%% ===================================================================

roundtrip_test() ->
    M = #{<<"a">> => 1, <<"tags">> => [<<"x">>, <<"y">>, <<"x">>, <<>>],
          <<"empty">> => [], <<"zz">> => <<"after">>, <<"n">> => undefined},
    D = bitcask:decode_meta(m(M)),
    ?assertEqual(M, D),
    %% 保持写入顺序（不排序、不去重）
    ?assertEqual([<<"x">>, <<"y">>, <<"x">>, <<>>], maps:get(<<"tags">>, D)),
    %% proplist 形态同样收
    ?assertEqual(#{<<"t">> => [<<"q">>]}, bitcask:decode_meta(m([{<<"t">>, [<<"q">>]}]))),
    %% 非 ASCII 元素原样往返
    U = [<<"北京"/utf8>>, <<0, 1, 255>>],
    ?assertEqual(#{<<"t">> => U}, bitcask:decode_meta(m(#{<<"t">> => U}))).

bad_array_rejected_test() ->
    %% charlist 不是数组（元素必须全是 binary）
    ?assertError(badarg, m(#{<<"t">> => "abc"})),
    ?assertError(badarg, m(#{<<"t">> => [<<"a">>, 1]})),
    ?assertError(badarg, m(#{<<"t">> => [<<"a">> | <<"b">>]})),
    ?assertError(badarg, m(#{<<"t">> => [[<<"a">>]]})).

%% ===================================================================
%% 引擎 filter
%% ===================================================================

engine_filter_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            C = fun(V) -> #{key => <<"tags">>, op => contains, value => V} end,
            CA = fun(Vs) -> #{key => <<"tags">>, op => contains_any, values => Vs} end,
            Cases =
                [%% 数组任一元素命中；单个 binary 当单元素集合
                 {C(<<"db">>), [<<"a">>, <<"c">>]},
                 {C(<<"erlang">>), [<<"b">>]},
                 {C(<<"nope">>), []},
                 %% 非 binary 字面值恒不命中（含存储值是整数 7 的 e）
                 {C(7), []},
                 {CA([<<"rust">>, <<"erlang">>]), [<<"a">>, <<"b">>]},
                 {CA([<<"nope">>, <<"db">>]), [<<"a">>, <<"c">>]},
                 %% 现有操作符碰到数组：eq/in 假，neq 真
                 {#{key => <<"tags">>, op => eq, value => <<"db">>}, [<<"c">>]},
                 {#{key => <<"tags">>, op => in, values => [<<"db">>, <<"erlang">>]}, [<<"c">>]},
                 {#{key => <<"tags">>, op => neq, value => <<"db">>},
                  [<<"a">>, <<"b">>, <<"d">>, <<"e">>, <<"f">>, <<"g">>]},
                 %% exists：数组（含空数组）为真，null / 缺失为假
                 {#{key => <<"tags">>, op => exists},
                  [<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>]},
                 %% 数组后面的 key 照常可读（新旧类型混排不错位）
                 {[C(<<"db">>), #{key => <<"zz">>, op => gte, value => 2}], [<<"c">>]},
                 {#{logic => 'or', conditions => [C(<<"rust">>), C(<<"erlang">>)]},
                  [<<"a">>, <<"b">>]}],
            [begin
                 ?assertEqual(Want, hits(R, F), F),
                 ?assertEqual(Want, range_keys(R, F), F)
             end || {F, Want} <- Cases],
            %% get 带回的 meta 解得开
            {ok, #{meta := MB}} = bitcask:get(R, <<"a">>),
            ?assertEqual([<<"rust">>, <<"db">>], maps:get(<<"tags">>, bitcask:decode_meta(MB))),
            ok = bitcask:close(R),
            %% 重开（v7 目录）后数据与过滤照旧
            R2 = bitcask:open(D, ?IDX),
            ?assertEqual([<<"a">>, <<"c">>], hits(R2, C(<<"db">>))),
            ok = bitcask:close(R2)
        end)
    end}.

bad_filter_shapes_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            %% contains_any 缺 values / 空列表；contains 缺 value
            [?assertError(badarg, bitcask:search_text(R, <<"doc">>, 10, F))
             || F <- [#{key => <<"tags">>, op => contains_any},
                      #{key => <<"tags">>, op => contains_any, values => []},
                      #{key => <<"tags">>, op => contains}]],
            ok = bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% bitcask_query
%% ===================================================================

query_where_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            Ws = [{<<"tags">>, contains, <<"db">>},
                  {<<"tags">>, contains_any, [<<"rust">>, <<"erlang">>]},
                  [{<<"tags">>, contains, <<"db">>}, {<<"zz">>, lt, 3}],
                  {'or', [{tags, contains, <<"erlang">>}, {<<"zz">>, eq, 5}]},
                  {<<"tags">>, eq, <<"db">>},
                  {<<"tags">>, neq, <<"db">>},
                  {<<"tags">>, exists}],
            Keys = [K || {K, _} <- corpus()],
            [begin
                 %% 引擎下推（range 驱动）
                 {ok, Rows} = bitcask_query:q(R, #{where => W, select => [key]}),
                 Pushed = [K || #{key := K} <- Rows],
                 %% BEAM 侧求值（{eq, K} 驱动逐篇判）
                 Beam = [K || K <- Keys,
                              {ok, [_]} <- [bitcask_query:q(R, #{key => {eq, K}, where => W,
                                                                select => [key]})]],
                 ?assertEqual(Beam, Pushed, W),
                 %% 检索驱动下推
                 {ok, TRows} = bitcask_query:q(R, #{text => {match, <<"doc">>}, where => W,
                                                    select => [key]}),
                 ?assertEqual(Beam, lists:sort([K || #{key := K} <- TRows]), W)
             end || W <- Ws],
            {ok, Rows1} = bitcask_query:q(R, #{where => {<<"tags">>, contains, <<"db">>}}),
            ?assertEqual([<<"a">>, <<"c">>], [K || #{key := K} <- Rows1]),
            %% 行里的 meta 带回数组
            [#{meta := #{<<"tags">> := [<<"rust">>, <<"db">>]}} | _] = Rows1,
            %% 非 binary 字面值 / 空列表 → bad_query
            [?assertMatch({error, {bad_query, _}}, bitcask_query:q(R, #{where => W}))
             || W <- [{<<"tags">>, contains, 1},
                      {<<"tags">>, contains_any, []},
                      {<<"tags">>, contains_any, [<<"a">>, 1]},
                      {<<"tags">>, eq, [<<"db">>]}]],
            ok = bitcask:close(R)
        end)
    end}.

%% 二级索引字段上存数组：bitcask_query:put 不崩；exists 走索引仍命中数组文档；
%% eq 走索引不会误中数组；contains 不选索引。
query_index_on_array_field_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask_query:create_index(R, <<"tags">>),
            [ok = bitcask_query:put(R, K, #{text => <<"doc ", K/binary>>, meta => m(M)})
             || {K, M} <- corpus()],
            %% 回填路径：另建一个索引字段时已有的数组值同样编得出来
            ok = bitcask_query:put(R, <<"h">>, #{text => <<"doc h">>,
                                                  meta => m(#{<<"tags">> => [<<"db">>]})}),
            Q = fun(W, Ix) ->
                        {ok, Rows} = bitcask_query:q(R, #{where => W, index => Ix, select => [key]}),
                        lists:sort([K || #{key := K} <- Rows])   % 索引驱动按 (值, 主键) 序
                end,
            [?assertEqual(Q(W, none), Q(W, auto), W)
             || W <- [{<<"tags">>, exists},
                      {<<"tags">>, eq, <<"db">>},
                      {<<"tags">>, in, [<<"db">>, <<"erlang">>]},
                      {<<"tags">>, contains, <<"db">>}]],
            ?assertEqual([<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>, <<"h">>],
                         Q({<<"tags">>, exists}, auto)),
            ?assertEqual([<<"c">>], Q({<<"tags">>, eq, <<"db">>}, auto)),
            ?assertMatch({ok, #{driver := index}},
                         bitcask_query:explain(R, #{where => {<<"tags">>, exists}})),
            ?assertMatch({ok, #{driver := range}},
                         bitcask_query:explain(R, #{where => {<<"tags">>, contains, <<"db">>}})),
            %% 改写数组值：旧索引项被删、新值可查
            ok = bitcask_query:put(R, <<"a">>, #{text => <<"doc a">>,
                                                  meta => m(#{<<"tags">> => [<<"go">>]})}),
            ?assertEqual([<<"a">>], Q({<<"tags">>, contains, <<"go">>}, auto)),
            ?assertEqual(Q({<<"tags">>, exists}, none), Q({<<"tags">>, exists}, auto)),
            %% 建索引时回填已有数组
            ok = bitcask_query:drop_index(R, <<"tags">>),
            ok = bitcask_query:create_index(R, <<"tags">>),
            ?assertEqual(Q({<<"tags">>, exists}, none), Q({<<"tags">>, exists}, auto)),
            ok = bitcask:close(R)
        end)
    end}.

index_encoding_self_delimiting_test() ->
    %% 数组编码自定界：entry/2 能从「编码 ++ PK」里切回 PK
    F = <<"tags">>,
    [begin
         Enc = bitcask_query_index:enc(V),
         IxKey = <<0, "bitcask_query:ix:", (byte_size(F)):16/big, F/binary, Enc/binary, "pk1">>,
         ?assertEqual({<<"pk1">>, Enc}, bitcask_query_index:entry(F, IxKey))
     end || V <- [[], [<<>>], [<<"a">>, <<0, 0>>, <<"b", 0>>], [<<1>>, <<0>>]]],
    %% 不同数组编码不同
    ?assertNotEqual(bitcask_query_index:enc([<<"ab">>]), bitcask_query_index:enc([<<"a">>, <<"b">>])),
    ?assertNotEqual(bitcask_query_index:enc([]), bitcask_query_index:enc([<<>>])).
