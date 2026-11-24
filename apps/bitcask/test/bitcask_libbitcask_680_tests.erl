%% -------------------------------------------------------------------
%% bitcask_libbitcask_680_tests:
%%   libbitcask 6.8.0 新增面的适配覆盖：
%%     - bitcask:get_doc/2：命名字段读回（field id 翻译回字段名）
%%     - bitcask:search_fields_attributed/2,3,4：命中归属 + meta filter
%% -------------------------------------------------------------------
-module(bitcask_libbitcask_680_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IDX, [read_write, {analyzer, whitespace}]).
-define(VIDX, ?IDX ++ [{vector_dim, 4}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_680_", Fun).

open_corpus(D) ->
    R = bitcask:open(D, ?VIDX),
    ok = bitcask:put(R, <<"d1">>,
                     #{text => <<"shared alpha">>,
                       fields => #{<<"title">> => <<"alpha title">>,
                                   <<"body">> => <<"alpha body">>},
                       meta => bitcask:encode_meta(#{<<"kind">> => <<"keep">>})}),
    ok = bitcask:put(R, <<"d2">>,
                     #{text => <<"shared beta">>,
                       fields => #{<<"body">> => <<"beta body">>},
                       meta => bitcask:encode_meta(#{<<"kind">> => <<"drop">>})}),
    R.

get_doc_roundtrip_test_() ->
    {"get_doc 读回 text/meta/vector/fields；get 仍保持原有精简结果",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            %% 已归一化，避免断言依赖写入端的向量归一化实现细节。
            Vec = <<0.5:32/float-little, 0.5:32/float-little,
                    0.5:32/float-little, 0.5:32/float-little>>,
            ok = bitcask:put(R, <<"d3">>,
                             #{text => <<"with vector">>,
                               fields => #{<<"tag">> => <<"red">>},
                               vector => Vec}),
            {ok, Doc1} = bitcask:get_doc(R, <<"d1">>),
            ?assertEqual(<<"shared alpha">>, maps:get(text, Doc1)),
            ?assertEqual(#{<<"kind">> => <<"keep">>},
                         bitcask:decode_meta(maps:get(meta, Doc1))),
            ?assertEqual(undefined, maps:get(vector, Doc1)),
            ?assertEqual(#{<<"title">> => <<"alpha title">>,
                           <<"body">> => <<"alpha body">>},
                         maps:get(fields, Doc1)),
            {ok, Doc3} = bitcask:get_doc(R, <<"d3">>),
            ?assertEqual(Vec, maps:get(vector, Doc3)),
            ?assertEqual(#{<<"tag">> => <<"red">>}, maps:get(fields, Doc3)),
            {ok, Plain} = bitcask:get(R, <<"d1">>),
            ?assertEqual(#{text => <<"shared alpha">>,
                           meta => maps:get(meta, Doc1)}, Plain),
            ?assertEqual(not_found, bitcask:get_doc(R, <<"missing">>)),
            bitcask:close(R)
        end)
    end}.

attributed_fields_test_() ->
    {"search_fields_attributed 附命中字段，且带 filter 时结果一致",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            {ok, Hits} = bitcask:search_fields_attributed(R, <<"title:alpha">>),
            ?assertMatch([{<<"d1">>, _, _, [<<"title">>]}], Hits),
            F = [#{key => <<"kind">>, op => eq, value => <<"keep">>}],
            {ok, Filtered} =
                bitcask:search_fields_attributed(R, <<"shared">>, 10, F),
            ?assertMatch([{<<"d1">>, _, _, [<<>>]}], Filtered),
            {ok, NoFilter} =
                bitcask:search_fields_attributed(R, <<"shared">>, 10),
            ?assertEqual(2, length(NoFilter)),
            bitcask:close(R)
        end)
    end}.

attributed_no_index_test_() ->
    {"KV 模式调用归属字段检索返回 no_index",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            ?assertEqual({error, no_index},
                         bitcask:search_fields_attributed(R, <<"x">>)),
            bitcask:close(R)
        end)
    end}.
