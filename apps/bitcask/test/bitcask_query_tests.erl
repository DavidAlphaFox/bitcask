%% -------------------------------------------------------------------
%% bitcask_query_tests:
%%   bitcask_query DSL + bitcask:decode_meta/1。
%%
%%   重点：
%%     * where 的三条执行路径逐条一致——下推给检索（match / phrase）、下推给
%%       range 的 filter、{eq,K} 取出后在 BEAM 求值，命中集合必须相等。
%%     * libbitcask 6.6.1 的两处修复在这一层的回归（feedbacks/2026-10-06 原场景）：
%%       带 filter 的检索补取到 K；同分命中小 K 是大 K 的前缀。
%% -------------------------------------------------------------------
-module(bitcask_query_tests).

-include_lib("eunit/include/eunit.hrl").

%% 计数 embedder（provider 回调）：委托 bitcask_embedder_mock，顺带数调用次数，
%% 用来断言 {text, Bin} 查询翻页时只 embed 一次。
-export([init/1, embed/2]).

-define(IDX, [read_write, {analyzer, whitespace}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_query_", Fun).

m(KV) -> bitcask:encode_meta(KV).

keys({ok, Rows}) -> [K || #{key := K} <- Rows].

key(N) -> list_to_binary(io_lib:format("d~4..0b", [N])).

%% d0001..d1000，全部含 apple；每 10 篇一篇 tag=keep。
open_apples(D) ->
    R = bitcask:open(D, ?IDX),
    [ok = bitcask:put(R, key(N),
                      #{text => <<"apple pie">>,
                        meta => m(#{<<"tag">> => case N rem 10 of
                                                    0 -> <<"keep">>;
                                                    _ -> <<"drop">>
                                                end,
                                    <<"n">> => N})})
     || N <- lists:seq(1, 1000)],
    R.

%% 小语料：类型混杂、有缺字段、有 null、有不带 meta 的。
open_mixed(D) ->
    R = bitcask:open(D, ?IDX),
    Docs = [{<<"a1">>, #{<<"year">> => 2024, <<"cat">> => <<"db">>, <<"hot">> => true}},
            {<<"a2">>, #{<<"year">> => 2023, <<"cat">> => <<"kv">>, <<"hot">> => false}},
            {<<"a3">>, #{<<"year">> => 2024.0, <<"cat">> => <<"db">>}},
            {<<"a4">>, #{<<"year">> => 2022, <<"cat">> => undefined}},
            {<<"b1">>, #{<<"cat">> => <<"graph">>, <<"score">> => 0.5}},
            {<<"b2">>, none}],
    [ok = case Meta of
              none -> bitcask:put(R, K, #{text => <<"apple ", K/binary>>});
              _    -> bitcask:put(R, K, #{text => <<"apple ", K/binary>>, meta => m(Meta)})
          end || {K, Meta} <- Docs],
    R.

%% ===================================================================
%% decode_meta
%% ===================================================================

decode_meta_roundtrip_test() ->
    M = #{<<"i">> => -7, <<"f">> => 1.5, <<"s">> => <<"中文"/utf8>>,
          <<"t">> => true, <<"n">> => undefined, <<"big">> => 1 bsl 62},
    ?assertEqual(M, bitcask:decode_meta(bitcask:encode_meta(M))),
    ?assertEqual(#{}, bitcask:decode_meta(bitcask:encode_meta(#{}))).

decode_meta_badarg_test() ->
    ?assertError(badarg, bitcask:decode_meta(<<"not meta">>)),
    ?assertError(badarg, bitcask:decode_meta(<<>>)),
    ?assertError(badarg, bitcask:decode_meta(not_a_binary)).

%% ===================================================================
%% key 驱动
%% ===================================================================

key_paths_test_() ->
    {"eq / prefix / range / 全表：按 key 升序，limit 截断",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            ?assertEqual([<<"a3">>], keys(bitcask_query:q(R, #{key => {eq, <<"a3">>}}))),
            ?assertEqual([], keys(bitcask_query:q(R, #{key => {eq, <<"zz">>}}))),
            ?assertEqual([<<"a1">>, <<"a2">>, <<"a3">>, <<"a4">>],
                         keys(bitcask_query:q(R, #{key => {prefix, <<"a">>}}))),
            ?assertEqual([<<"a2">>, <<"a3">>],
                         keys(bitcask_query:q(R, #{key => {range, <<"a2">>, <<"a4">>}}))),
            ?assertEqual([<<"a1">>, <<"a2">>],
                         keys(bitcask_query:q(R, #{limit => 2}))),
            ?assertEqual(6, length(keys(bitcask_query:q(R, #{})))),
            bitcask:close(R)
        end)
    end}.

row_shape_test_() ->
    {"行形态：meta 解成 map，无 meta 为 undefined；select 裁剪；score 只在 text 驱动",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            {ok, [Row]} = bitcask_query:q(R, #{key => {eq, <<"a1">>}}),
            ?assertEqual(#{key => <<"a1">>, text => <<"apple a1">>,
                           meta => #{<<"year">> => 2024, <<"cat">> => <<"db">>,
                                     <<"hot">> => true}}, Row),
            {ok, [Row2]} = bitcask_query:q(R, #{key => {eq, <<"b2">>}}),
            ?assertEqual(undefined, maps:get(meta, Row2)),
            ?assertEqual({ok, [#{key => <<"a1">>}, #{key => <<"a2">>}]},
                         bitcask_query:q(R, #{key => {prefix, <<"a">>}, limit => 2,
                                              select => [key]})),
            {ok, [T | _]} = bitcask_query:q(R, #{text => {match, <<"a1">>}}),
            ?assertMatch(#{key := <<"a1">>, score := S} when is_float(S), T),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% where 语义
%% ===================================================================

where_cases() ->
    [{{<<"year">>, eq, 2024},         [<<"a1">>]},                 % 2024.0 是 float，不等
     {{<<"year">>, eq, 2024.0},       [<<"a3">>]},
     {{<<"year">>, gte, 2023},        [<<"a1">>, <<"a2">>]},       % float 不参与 int 比较
     {{<<"year">>, lt, 2024},         [<<"a2">>, <<"a4">>]},
     {{<<"cat">>, neq, <<"db">>},     [<<"a2">>, <<"a4">>, <<"b1">>]}, % b2 无 meta 过不了
     {{<<"cat">>, eq, undefined},     [<<"a4">>]},                 % null
     {{<<"hot">>, eq, undefined},     [<<"a3">>, <<"a4">>, <<"b1">>]}, % 缺字段读作 null
     {{<<"cat">>, exists},            [<<"a1">>, <<"a2">>, <<"a3">>, <<"b1">>]},
     {{<<"cat">>, in, [<<"kv">>, <<"graph">>]}, [<<"a2">>, <<"b1">>]},
     {{<<"hot">>, in, [undefined]},   []},                         % in 对缺字段恒假
     {{hot, eq, true},                [<<"a1">>]},                 % atom 字段名
     {{<<"score">>, gt, 0.25},        [<<"b1">>]},
     {[{<<"cat">>, eq, <<"db">>}, {<<"year">>, eq, 2024}], [<<"a1">>]},
     {{'or', [{<<"year">>, eq, 2022},
              {'and', [{<<"cat">>, eq, <<"db">>}, {<<"hot">>, exists}]}]},
      [<<"a1">>, <<"a4">>]}].

where_scan_test_() ->
    {"where 在扫描路径（range filter 下推）上的语义",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            [?assertEqual({W, Want}, {W, keys(bitcask_query:q(R, #{where => W}))})
             || {W, Want} <- where_cases()],
            bitcask:close(R)
        end)
    end}.

where_paths_agree_test_() ->
    {"同一组 where：检索下推（match/phrase）、range 下推、BEAM 求值（{eq,K}）命中相同",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            AllKeys = keys(bitcask_query:q(R, #{select => [key]})),
            Sort = fun(Q) -> lists:sort(keys(bitcask_query:q(R, Q))) end,
            [begin
                 Match  = Sort(#{text => {match, <<"apple">>}, where => W}),
                 Phrase = Sort(#{text => {phrase, <<"apple">>}, where => W}),
                 Range  = Sort(#{key => {prefix, <<>>}, where => W}),
                 Beam   = lists:sort(lists:append(
                            [keys(bitcask_query:q(R, #{key => {eq, K}, where => W}))
                             || K <- AllKeys])),
                 [?assertEqual({W, Path, Want}, {W, Path, Got})
                  || {Path, Got} <- [{match, Match}, {phrase, Phrase},
                                     {range, Range}, {beam, Beam}]]
             end || {W, Want} <- where_cases()],
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% text 驱动：补齐引擎的 filter 截断
%% ===================================================================

filtered_text_fills_limit_test_() ->
    {"满足 filter 的 100 篇：limit 10/50 给满，infinity 给全",
     {timeout, 120,
      fun() ->
        with_dir(fun(D) ->
            R = open_apples(D),
            W = {<<"tag">>, eq, <<"keep">>},
            %% libbitcask 6.6.1 回归：引擎直调也补取到 K（6.6.0 只给 6 条）。
            F = [#{key => <<"tag">>, op => eq, value => <<"keep">>}],
            {ok, Raw} = bitcask:search_text(R, <<"apple">>, 10, F),
            ?assertEqual(10, length(Raw)),
            {ok, RawP} = bitcask:search_phrase(R, <<"apple pie">>, 10, F),
            ?assertEqual(10, length(RawP)),
            [?assertEqual(L, length(keys(bitcask_query:q(
                                 R, #{text => {match, <<"apple">>}, where => W,
                                      limit => L}))))
             || L <- [1, 10, 50, 100]],
            All = keys(bitcask_query:q(R, #{text => {match, <<"apple">>}, where => W})),
            ?assertEqual(lists:sort([key(N) || N <- lists:seq(10, 1000, 10)]),
                         lists:sort(All)),
            %% limit 大于可满足数：给全 100，不报错
            ?assertEqual(100, length(keys(bitcask_query:q(
                                  R, #{text => {match, <<"apple">>}, where => W,
                                       limit => 500})))),
            bitcask:close(R)
        end)
      end}}.

text_with_key_filter_test_() ->
    {"text + key 条件：key 对命中后过滤，limit 照样补满",
     {timeout, 120,
      fun() ->
        with_dir(fun(D) ->
            R = open_apples(D),
            %% d09xx 共 100 篇（d0900..d0999）
            Ks = keys(bitcask_query:q(R, #{text => {match, <<"apple">>},
                                           key => {prefix, <<"d09">>},
                                           limit => 30})),
            ?assertEqual(30, length(Ks)),
            ?assert(lists:all(fun(<<"d09", _/binary>>) -> true; (_) -> false end, Ks)),
            ?assertEqual([<<"d0500">>],
                         keys(bitcask_query:q(R, #{text => {match, <<"apple">>},
                                                   key => {eq, <<"d0500">>}}))),
            bitcask:close(R)
        end)
      end}}.

tied_scores_prefix_stable_test_() ->
    {"同分命中：小 K 是大 K 的前缀（libbitcask 6.6.1 回归；6.6.0 下 K=5 与 K=1000 矛盾）",
     {timeout, 120,
      fun() ->
        with_dir(fun(D) ->
            R = open_apples(D),
            {ok, Big} = bitcask:search_text(R, <<"apple">>, 1000),
            [begin
                 {ok, Small} = bitcask:search_text(R, <<"apple">>, K),
                 ?assertEqual({K, lists:sublist(Big, K)}, {K, Small})
             end || K <- [1, 5, 64, 999]],
            bitcask:close(R)
        end)
      end}}.

range_meta_filter_test_() ->
    {"range：{want_meta,true} 带回 meta、{filter,F} 在引擎侧筛；坏 filter → badarg",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            {ok, MetaA1} = bitcask:get(R, <<"a1">>),
            [{<<"a1">>, V}] = bitcask:range(R, {<<"a1">>, <<"a2">>}, [{want_meta, true}]),
            ?assertEqual(MetaA1, V),
            [{<<"b2">>, #{meta := undefined}}] =
                bitcask:range(R, {<<"b2">>, undefined}, [{want_meta, true}]),
            ?assertEqual([<<"a1">>, <<"a3">>],
                         [K || {K, _} <- bitcask:range(
                                          R, {undefined, undefined},
                                          [{filter, [#{key => <<"cat">>, op => eq,
                                                       value => <<"db">>}]}])]),
            %% 不带 want_meta 时 value 仍是裸 text
            [{<<"a1">>, <<"apple a1">>}] =
                bitcask:range(R, {<<"a1">>, <<"a2">>},
                              [{filter, #{key => <<"cat">>, op => exists}}]),
            ?assertError(badarg, bitcask:range(R, {undefined, undefined},
                                               [{filter, [#{op => eq}]}])),
            bitcask:close(R)
        end)
    end}.

search_filter_arities_test_() ->
    {"phrase/fields/near/fuzzy/wildcard 的 Filter 版本：过滤生效，undefined = 不过滤",
     fun() ->
        with_dir(fun(D) ->
            R = open_mixed(D),
            F = [#{key => <<"cat">>, op => eq, value => <<"db">>}],
            Ks = fun({ok, Hits}) -> lists:sort([K || {K, _, _} <- Hits]) end,
            DB = [<<"a1">>, <<"a3">>],
            ?assertEqual(DB, Ks(bitcask:search_phrase(R, <<"apple">>, 10, F))),
            ?assertEqual(DB, Ks(bitcask:search_fields(R, <<"apple">>, 10, F))),
            ?assertEqual(DB, Ks(bitcask:search_near(R, <<"apple">>, 0, 10, F))),
            ?assertEqual(DB, Ks(bitcask:search_fuzzy(R, <<"aple">>, 1, 10, F))),
            ?assertEqual(DB, Ks(bitcask:search_wildcard(R, <<"app*">>, 10, F))),
            ?assertEqual(6, length(Ks(bitcask:search_phrase(R, <<"apple">>, 10, undefined)))),
            ?assertError(badarg, bitcask:search_phrase(R, <<"apple">>, 10, [bad])),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 分页
%% ===================================================================

%% 一页一页取到 done，返回 [[Row]]（每页一个列表）。
all_pages(H, Q) ->
    {ok, Rows, Cont} = bitcask_query:page(H, Q),
    drain(Cont, [Rows]).

drain(done, Acc) -> lists:reverse(Acc);
drain(Cont, Acc) ->
    {ok, Rows, Next} = bitcask_query:page(Cont),
    drain(Next, [Rows | Acc]).

page_keys(Pages) -> [[K || #{key := K} <- P] || P <- Pages].

page_range_test_() ->
    {"range 驱动分页：按 key 升序、不重不漏；整除时最后一页满且 Cont = done",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            [ok = bitcask:put(R, key(N), #{text => <<"x">>,
                                           meta => m(#{<<"n">> => N})})
             || N <- lists:seq(1, 10)],
            Ten = [key(N) || N <- lists:seq(1, 10)],
            P3 = page_keys(all_pages(R, #{key => {prefix, <<"d">>}, limit => 3})),
            ?assertEqual([3, 3, 3, 1], [length(P) || P <- P3]),
            ?assertEqual(Ten, lists:append(P3)),
            %% 整除：多取一条的 lookahead 让第二页直接给 done，不多一页空页
            {ok, A, C1} = bitcask_query:page(R, #{limit => 5}),
            {ok, B, done} = bitcask_query:page(C1),
            ?assertEqual(Ten, keys({ok, A ++ B})),
            ?assertEqual({ok, [], done}, bitcask_query:page(done)),
            %% where 下推照样分页
            Odd = page_keys(all_pages(R, #{where => {<<"n">>, in, [1, 3, 5, 7, 9]},
                                           limit => 2, select => [key]})),
            ?assertEqual([[key(1), key(3)], [key(5), key(7)], [key(9)]], Odd),
            %% 区间上界在分页时保持
            ?assertEqual([[key(2), key(3)], [key(4)]],
                         page_keys(all_pages(R, #{key => {range, key(2), key(5)},
                                                  limit => 2}))),
            bitcask:close(R)
        end)
    end}.

page_text_test_() ->
    {"全文驱动分页：拼起来等于一次取全（同分前缀稳定），带 key 条件也不重不漏",
     {timeout, 120,
      fun() ->
        with_dir(fun(D) ->
            R = open_apples(D),
            Q = #{text => {match, <<"apple">>}, where => {<<"tag">>, eq, <<"keep">>}},
            {ok, All} = bitcask_query:q(R, Q),
            Pages = page_keys(all_pages(R, Q#{limit => 30})),
            ?assertEqual([30, 30, 30, 10], [length(P) || P <- Pages]),
            ?assertEqual(keys({ok, All}), lists:append(Pages)),
            %% d09xx 共 100 篇，key 在 BEAM 侧后过滤
            KP = lists:append(page_keys(all_pages(
                   R, #{text => {match, <<"apple">>}, key => {prefix, <<"d09">>},
                        limit => 7, select => [key, score]}))),
            ?assertEqual(100, length(KP)),
            ?assertEqual(100, length(lists:usort(KP))),
            bitcask:close(R)
        end)
      end}}.

%% ===================================================================
%% 向量 / 混合
%% ===================================================================

-define(VOPTS, [read_write, {analyzer, whitespace}, {vector_dim, 4}]).

%% v1..v20：单位向量 [cos θ, sin θ, 0, 0]，θ 随 N 递增——查询 [1,0,0,0] 时
%% 相似度按 N 严格递减。偶数篇 tag=even。
open_vectors(D) ->
    R = bitcask:open(D, ?VOPTS),
    [ok = bitcask:put(R, vkey(N),
                      #{text   => <<"vec doc">>,
                        vector => unit(N),
                        meta   => m(#{<<"even">> => N rem 2 =:= 0})})
     || N <- lists:seq(1, 20)],
    R.

vkey(N) -> list_to_binary(io_lib:format("v~2..0b", [N])).

unit(N) ->
    T = N * 0.07,
    bitcask_embedder_mock:vec_bin([math:cos(T), math:sin(T), 0.0, 0.0]).

q0() -> bitcask_embedder_mock:vec_bin([1.0, 0.0, 0.0, 0.0]).

vector_query_test_() ->
    {"vector：按相似度降序、where 下推、key 后过滤、score 是相似度",
     fun() ->
        with_dir(fun(D) ->
            R = open_vectors(D),
            ?assertEqual([vkey(1), vkey(2), vkey(3)],
                         keys(bitcask_query:q(R, #{vector => q0(), limit => 3}))),
            ?assertEqual([vkey(2), vkey(4), vkey(6)],
                         keys(bitcask_query:q(R, #{vector => q0(), limit => 3,
                                                   where => {<<"even">>, eq, true}}))),
            ?assertEqual([vkey(10), vkey(11)],
                         keys(bitcask_query:q(R, #{vector => q0(), limit => 2,
                                                   key => {prefix, <<"v1">>}}))),
            {ok, [#{score := S1}, #{score := S2}]} =
                bitcask_query:q(R, #{vector => q0(), limit => 2, ef => 64,
                                     select => [score]}),
            ?assert(S1 >= S2),
            bitcask:close(R)
        end)
    end}.

vector_page_test_() ->
    {"vector 分页（近似游标）：按已返回 key 去重，不重复；小库上不漏",
     fun() ->
        with_dir(fun(D) ->
            R = open_vectors(D),
            Pages = page_keys(all_pages(R, #{vector => q0(), limit => 6})),
            Flat = lists:append(Pages),
            ?assertEqual(length(Flat), length(lists:usort(Flat))),
            ?assertEqual([vkey(N) || N <- lists:seq(1, 20)], Flat),
            bitcask:close(R)
        end)
    end}.

hybrid_query_test_() ->
    {"text {match,_} + vector = search_hybrid（RRF），where 下推；与直调一致",
     fun() ->
        with_dir(fun(D) ->
            R = open_vectors(D),
            ok = bitcask:put(R, <<"t1">>, #{text => <<"needle hay">>, vector => unit(19),
                                            meta => m(#{<<"even">> => false})}),
            {ok, Direct} = bitcask:search_hybrid(R, <<"needle">>, q0(), 5),
            ?assertEqual([K || {K, _, _} <- Direct],
                         keys(bitcask_query:q(R, #{text => {match, <<"needle">>},
                                                   vector => q0(), limit => 5}))),
            Hy = keys(bitcask_query:q(R, #{text => {match, <<"needle">>}, vector => q0(),
                                           where => {<<"even">>, eq, false}, limit => 5})),
            ?assert(lists:member(<<"t1">>, Hy)),
            ?assertEqual([], [K || K <- Hy, lists:member(K, [vkey(N) || N <- [2,4,6,8,10]])]),
            bitcask:close(R)
        end)
    end}.

%% 计数 provider 回调
init(_Cfg) ->
    {ok, #{module => ?MODULE, dim => 4, config => #{}}}.

embed(_Cfg, Text) ->
    counters:add(persistent_term:get({?MODULE, embeds}), 1, 1),
    bitcask_embedder_mock:embed(Text).

vector_text_embeds_once_test_() ->
    {"vector => {text, Bin}：自动 embed，且整个翻页过程只 embed 一次",
     fun() ->
        with_dir(fun(D) ->
            Cnt = counters:new(1, []),
            persistent_term:put({?MODULE, embeds}, Cnt),
            R = bitcask:open(D, [read_write, {analyzer, whitespace},
                                 {embedder, {{custom, ?MODULE}, #{}}}]),
            [ok = bitcask:put(R, vkey(N), #{text => <<"doc ", (vkey(N))/binary>>,
                                            vector => unit(N)})
             || N <- lists:seq(1, 12)],
            Before = counters:get(Cnt, 1),
            Pages = all_pages(R, #{vector => {text, <<"anything">>}, limit => 5}),
            ?assertEqual(12, length(lists:append(Pages))),
            ?assertEqual(1, counters:get(Cnt, 1) - Before),
            bitcask:close(R),
            persistent_term:erase({?MODULE, embeds})
        end)
    end}.

%% ===================================================================
%% 其它模式 / 错误
%% ===================================================================

kv_mode_test_() ->
    {"KV 模式：扫描可用、行无 meta、任何 where 都不命中；text → no_index",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            ok = bitcask:put(R, <<"k1">>, <<"v1">>),
            ok = bitcask:put(R, <<"k2">>, <<"v2">>),
            ?assertEqual({ok, [#{key => <<"k1">>, text => <<"v1">>, meta => undefined},
                               #{key => <<"k2">>, text => <<"v2">>, meta => undefined}]},
                         bitcask_query:q(R, #{})),
            ?assertEqual({ok, []}, bitcask_query:q(R, #{where => {<<"x">>, neq, 1}})),
            ?assertMatch({error, no_index},
                         bitcask_query:q(R, #{text => {match, <<"v1">>}})),
            bitcask:close(R)
        end)
    end}.

bad_query_test_() ->
    {"非法查询 → {error, {bad_query, _}}，不抛",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            Bad = [#{bogus => 1},
                   #{key => {prefix, "str"}},
                   #{text => {match, "str"}},
                   #{text => {near, <<"a">>, -1}},
                   #{limit => 0},
                   #{select => []},
                   #{select => [key, nope]},
                   #{where => {<<"f">>, like, <<"x">>}},
                   #{where => {<<"f">>, in, []}},
                   #{where => {'or', []}},
                   #{where => {<<"f">>, eq, an_atom}},
                   #{where => {<<"f">>, eq, 1 bsl 64}},
                   #{where => {"f", eq, 1}},
                   #{vector => <<1,2,3>>},
                   #{vector => {text, <<>>}},
                   #{text => {phrase, <<"a">>}, vector => <<0:32>>},
                   #{text => {match, <<"a">>}, vector => <<0:32>>, ef => 10},
                   #{ef => 10}],
            [?assertMatch({Q, {error, {bad_query, _}}}, {Q, bitcask_query:q(R, Q)})
             || Q <- Bad],
            ?assertMatch({error, {bad_query, _}}, bitcask_query:q(R, not_a_map)),
            ?assertMatch({error, {bad_query, {limit, required_for_page}}},
                         bitcask_query:page(R, #{})),
            ?assertMatch({error, {bad_cont, _}}, bitcask_query:page(garbage)),
            bitcask:close(R)
        end)
    end}.
