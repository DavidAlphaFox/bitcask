%% -------------------------------------------------------------------
%% bitcask_doc_ops_tests:
%%   M23 — libbitcask 11.2.0（S60 / S61，随 12.0.0 接入）：
%%     * bitcask:update_doc/3：文档部分更新（字段 / meta 设置与删除，正文、
%%       向量原样保留，返回新 LSN，并发不丢更新，错误形态）；
%%     * bitcask:search_fields_highlight/2..5：归属命中 + 逐字段片段。
%% -------------------------------------------------------------------
-module(bitcask_doc_ops_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IDX, [read_write, {analyzer, whitespace}]).
-define(VIDX, ?IDX ++ [{vector_dim, 4}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_doc_ops_", Fun).

m(KV) -> bitcask:encode_meta(KV).

vec() ->
    << <<X:32/float-little>> || X <- [0.5, 0.5, 0.5, 0.5] >>.

keys(Hits) -> lists:sort([element(1, H) || H <- Hits]).

%% ===================================================================
%% update_doc
%% ===================================================================

update_doc_basic_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?VIDX),
            ok = bitcask:put(R, <<"d1">>,
                             #{text => <<"body text stays">>,
                               fields => #{<<"title">> => <<"old title">>,
                                           <<"tag">> => <<"red">>},
                               meta => m(#{<<"n">> => 1, <<"gone">> => true}),
                               vector => vec()}),
            {ok, Lsn} = bitcask:update_doc(R, <<"d1">>,
                #{fields => #{<<"title">> => <<"new title">>,
                              <<"tag">> => delete,
                              <<"extra">> => <<"added later">>},
                  meta => #{<<"n">> => 2, <<"gone">> => delete,
                            <<"tags">> => [<<"a">>, <<"b">>], <<"nul">> => undefined}}),
            {ok, _V, Ord} = bitcask:get_with_ord(R, <<"d1">>),
            ?assertEqual(Ord, Lsn),
            {ok, Doc} = bitcask:get_doc(R, <<"d1">>),
            ?assertEqual(<<"body text stays">>, maps:get(text, Doc)),
            ?assertEqual(vec(), maps:get(vector, Doc)),
            ?assertEqual(#{<<"title">> => <<"new title">>, <<"extra">> => <<"added later">>},
                         maps:get(fields, Doc)),
            ?assertEqual(#{<<"n">> => 2, <<"tags">> => [<<"a">>, <<"b">>], <<"nul">> => undefined},
                         bitcask:decode_meta(maps:get(meta, Doc))),
            %% 索引跟着新版本走：新字段词可查、旧字段词查不到；正文照旧
            ?assertMatch({ok, [{<<"d1">>, _, _}]}, bitcask:search_fields(R, <<"title:new">>)),
            ?assertEqual({ok, []}, bitcask:search_fields(R, <<"title:old">>)),
            ?assertEqual({ok, []}, bitcask:search_fields(R, <<"tag:red">>)),
            ?assertMatch({ok, [{<<"d1">>, _, _}]}, bitcask:search_text(R, <<"stays">>)),
            ?assertMatch({ok, [{<<"d1">>, _, _}]},
                         bitcask:search_text(R, <<"stays">>, 10,
                                             #{key => <<"tags">>, op => contains, value => <<"b">>})),
            %% 空补丁也写一版（LSN 前进），内容不变
            {ok, Lsn2} = bitcask:update_doc(R, <<"d1">>, #{}),
            ?assert(Lsn2 > Lsn),
            {ok, Doc2} = bitcask:get_doc(R, <<"d1">>),
            ?assertEqual(Doc, Doc2),
            ok = bitcask:close(R),
            %% 重开不变
            R2 = bitcask:open(D, ?VIDX),
            {ok, Doc3} = bitcask:get_doc(R2, <<"d1">>),
            ?assertEqual(Doc, Doc3),
            ok = bitcask:close(R2)
        end)
    end}.

update_doc_errors_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask:put(R, <<"d1">>, #{text => <<"x">>}),
            ?assertEqual({error, not_found},
                         bitcask:update_doc(R, <<"missing">>, #{meta => #{<<"a">> => 1}})),
            ok = bitcask:delete(R, <<"d1">>),
            ?assertEqual({error, not_found}, bitcask:update_doc(R, <<"d1">>, #{})),
            ok = bitcask:put(R, <<"d2">>, #{text => <<"y">>}),
            %% 形态错 → badarg
            [?assertError(badarg, bitcask:update_doc(R, <<"d2">>, P))
             || P <- [#{bogus => 1},
                      #{fields => [{<<"t">>, <<"v">>}]},
                      #{fields => #{t => <<"v">>}},
                      #{fields => #{<<"t">> => 1}},
                      #{meta => #{<<"k">> => delte}},          % 拼错的 delete 不当 null
                      #{meta => #{<<"k">> => "chars"}},
                      #{meta => #{k => 1}}]],
            %% 引擎校验：空字段名 → invalid_option
            ?assertMatch({error, {invalid_option, _}},
                         bitcask:update_doc(R, <<"d2">>, #{fields => #{<<>> => <<"v">>}})),
            ok = bitcask:close(R)
        end)
    end}.

%% 8 个进程各自往同一篇文档上加自己的 meta 键：引擎内原子读-改-写，不丢更新。
update_doc_concurrent_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask:put(R, <<"doc">>, #{text => <<"shared">>, meta => m(#{<<"base">> => 0})}),
            Self = self(),
            N = 8, Per = 10,
            Upd = fun Upd(K) ->
                          case bitcask:update_doc(R, <<"doc">>, #{meta => #{K => 1}}) of
                              {ok, _}           -> ok;
                              {error, conflict} -> Upd(K)          % 调用方再试
                          end
                  end,
            [spawn_link(fun() ->
                            [Upd(<<"p", (integer_to_binary(P))/binary, "_",
                                   (integer_to_binary(I))/binary>>) || I <- lists:seq(1, Per)],
                            Self ! {done, P}
                        end) || P <- lists:seq(1, N)],
            [receive {done, P} -> ok after 60000 -> ?assert(false) end || P <- lists:seq(1, N)],
            {ok, #{meta := MB}} = bitcask:get(R, <<"doc">>),
            ?assertEqual(1 + N * Per, map_size(bitcask:decode_meta(MB))),
            ok = bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% search_fields_highlight
%% ===================================================================

open_hl_corpus(D) ->
    R = bitcask:open(D, ?IDX),
    ok = bitcask:put(R, <<"d1">>,
                     #{text => <<"plain body about rust and memory">>,
                       fields => #{<<"title">> => <<"rust memory safety">>,
                                   <<"body">> => <<"memory layout explained in rust">>},
                       meta => m(#{<<"kind">> => <<"keep">>})}),
    ok = bitcask:put(R, <<"d2">>,
                     #{text => <<"other text">>,
                       fields => #{<<"title">> => <<"rust tooling">>},
                       meta => m(#{<<"kind">> => <<"drop">>})}),
    R.

highlight_per_field_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hl_corpus(D),
            {ok, Hits} = bitcask:search_fields_highlight(R, <<"title:rust body:memory">>),
            %% 命中、排序、命中字段与 attributed 一致
            {ok, Attr} = bitcask:search_fields_attributed(R, <<"title:rust body:memory">>),
            ?assertEqual(Attr, [{K, O, S, F} || {K, O, S, F, _} <- Hits]),
            {_, _, _, _, Groups1} = lists:keyfind(<<"d1">>, 1, Hits),
            [T1] = proplists:get_value(<<"title">>, Groups1),
            [B1] = proplists:get_value(<<"body">>, Groups1),
            %% title 片段只标 rust，body 片段只标 memory
            ?assertNotEqual(nomatch, binary:match(T1, <<"<em>rust</em>">>)),
            ?assertEqual(nomatch, binary:match(T1, <<"<em>memory</em>">>)),
            ?assertNotEqual(nomatch, binary:match(B1, <<"<em>memory</em>">>)),
            ?assertEqual(nomatch, binary:match(B1, <<"<em>rust</em>">>)),
            %% 片段组与命中字段同序
            {_, _, _, Fields1, _} = lists:keyfind(<<"d1">>, 1, Hits),
            ?assertEqual([F || F <- Fields1, lists:keymember(F, 1, Groups1)],
                         [F || {F, _} <- Groups1]),
            ok = bitcask:close(R)
        end)
    end}.

highlight_options_filter_default_field_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hl_corpus(D),
            Keep = #{key => <<"kind">>, op => eq, value => <<"keep">>},
            {ok, Hits} = bitcask:search_fields_highlight(
                           R, <<"title:rust">>, 10, Keep,
                           #{pre_tag => <<"[">>, post_tag => <<"]">>, max_fragments => 1}),
            ?assertEqual([<<"d1">>], keys(Hits)),
            [{_, _, _, [<<"title">>], [{<<"title">>, [T]}]}] = Hits,
            ?assertNotEqual(nomatch, binary:match(T, <<"[rust]">>)),
            %% 无字段限定 = 默认字段（<<>>），片段取正文
            {ok, Hits2} = bitcask:search_fields_highlight(R, <<"plain">>),
            ?assertMatch([{<<"d1">>, _, _, [<<>>], [{<<>>, [_ | _]}]}], Hits2),
            [{_, _, _, _, [{<<>>, [P | _]}]}] = Hits2,
            ?assertNotEqual(nomatch, binary:match(P, <<"<em>plain</em>">>)),
            %% 冷读：重开后（本进程没写过这些文档）照样给片段
            ok = bitcask:close(R),
            R2 = bitcask:open(D, ?IDX),
            ?assertEqual({ok, Hits2}, bitcask:search_fields_highlight(R2, <<"plain">>)),
            %% 坏选项 / 坏 filter → badarg
            [?assertError(badarg, bitcask:search_fields_highlight(R2, <<"plain">>, 10, undefined, O))
             || O <- [#{bogus => 1}, #{pre_tag => "x"}, #{fragment_size => 0},
                      #{max_fragments => -1}]],
            ?assertError(badarg, bitcask:search_fields_highlight(R2, <<"plain">>, 10, #{op => wat})),
            ok = bitcask:close(R2)
        end)
    end}.

highlight_kv_mode_test() ->
    with_dir(fun(D) ->
        R = bitcask:open(D, [read_write]),
        ?assertEqual({error, no_index}, bitcask:search_fields_highlight(R, <<"x">>)),
        ok = bitcask:close(R)
    end).

%% ===================================================================
%% search_text_highlight
%% ===================================================================

text_highlight_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            R = open_hl_corpus(D),
            {ok, Hits} = bitcask:search_text_highlight(R, <<"rust">>),
            %% 命中与排序同 search_text
            {ok, Plain} = bitcask:search_text(R, <<"rust">>, 10),
            ?assertEqual(Plain, [{K, O, S} || {K, O, S, _} <- Hits]),
            {_, _, _, [S1 | _]} = lists:keyfind(<<"d1">>, 1, Hits),
            ?assertNotEqual(nomatch, binary:match(S1, <<"<em>rust</em>">>)),
            %% 自定义标签、段数
            {ok, [{<<"d1">>, _, _, [T]}]} =
                bitcask:search_text_highlight(R, <<"plain">>, 10,
                                              #{pre_tag => <<"[">>, post_tag => <<"]">>,
                                                max_fragments => 1}),
            ?assertNotEqual(nomatch, binary:match(T, <<"[plain]">>)),
            ok = bitcask:close(R),
            R2 = bitcask:open(D, ?IDX),
            %% 重开后：libbitcask 13.0.0（S73）起，重放已进过索引的文档不再把原文填回缓存，
            %% 小库重开也可能是冷的 ⇒ skip 命中照常、片段有无不定；load 读回正文，一定有片段。
            ?assertMatch({ok, [{<<"d1">>, _, _, _}]},
                         bitcask:search_text_highlight(R2, <<"plain">>, 10, #{cold => skip})),
            ?assertMatch({ok, [{<<"d1">>, _, _, [_ | _]}]},
                         bitcask:search_text_highlight(R2, <<"plain">>, 10, #{cold => load})),
            %% 坏选项 → badarg（cold 只在这里收；search_fields_highlight 不收）
            [?assertError(badarg, bitcask:search_text_highlight(R2, <<"plain">>, 10, O))
             || O <- [#{cold => maybe_later}, #{bogus => 1}, #{fragment_size => 0}]],
            ?assertError(badarg, bitcask:search_fields_highlight(R2, <<"plain">>, 10, undefined,
                                                                 #{cold => load})),
            ok = bitcask:close(R2)
        end)
    end}.

%% 冷文档：「冷」要靠规模（同上游 search_highlight_cold_test）——先写目标文档、再写 1500 篇
%% 填充，目标落进封好的段，重开直接载段不重放 ⇒ 原文缓存里没有它。缺省 cold => load 读回
%% 正文补片段；skip 片段为空；load 读回的不回填缓存（再 skip 仍空）。
text_highlight_cold_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask:put(R, <<"d1">>, #{text => <<"the quick brown fox jumps">>}),
            ok = bitcask:put(R, <<"f3">>, #{fields => #{<<"title">> => <<"a fox in the title">>}}),
            [ok = bitcask:put(R, <<"filler", (integer_to_binary(I))/binary>>,
                              #{text => <<"filler lorem ipsum ", (integer_to_binary(I))/binary>>})
             || I <- lists:seq(1, 1500)],
            ok = bitcask:close(R),
            R2 = bitcask:open(D, ?IDX),
            Snips = fun(Opts) ->
                            {ok, Hits} = bitcask:search_text_highlight(R2, <<"fox">>, 10, Opts),
                            lists:sort([{K, S} || {K, _, _, S} <- Hits])
                    end,
            ?assertEqual([{<<"d1">>, []}, {<<"f3">>, []}], Snips(#{cold => skip})),
            [{<<"d1">>, [D1 | _]}, {<<"f3">>, [F3 | _]}] = Snips(#{}),        % 缺省 load
            ?assertNotEqual(nomatch, binary:match(D1, <<"<em>fox</em>">>)),
            ?assertNotEqual(nomatch, binary:match(F3, <<"<em>fox</em>">>)),  % 正文空 ⇒ 命名字段
            ?assertEqual([{<<"d1">>, []}, {<<"f3">>, []}], Snips(#{cold => skip})),
            ok = bitcask:close(R2)
        end)
    end}.

text_highlight_kv_mode_test() ->
    with_dir(fun(D) ->
        R = bitcask:open(D, [read_write]),
        ?assertEqual({error, no_index}, bitcask:search_text_highlight(R, <<"x">>)),
        ok = bitcask:close(R)
    end).
