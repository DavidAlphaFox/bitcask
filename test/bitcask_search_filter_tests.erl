%% -------------------------------------------------------------------
%% bitcask_search_filter_tests:
%%   V5 — Erlang term → MetaFilter NIF 解析 + 搜索 + 过滤 eunit 端到端。
%%
%%   覆盖:NIF 解析(list-of-cond / nested-map / 各 op)、search_text/4 过滤
%%   等价性、And 短路、Or 多支、In 列表匹配、Exists、undefined = no filter、
%%   坏 term → badarg。文档见 parse_filter_term(nif_helpers.cpp)与
%%   bitcask.erl 头部注释。
%%
%%   语料:与 cpp/tests/cask_docvalue_test.cpp::V5SearchTextWithMetaFilter 同款:
%%     d1  tech 2024  (machine learning algorithms)
%%     d2  sport 2023 (football world cup final)
%%     d3  tech 2023  (deep learning neural networks)
%%     d4  sport 2023 (basketball playoff game)
%%     d5  tech 2024  (cloud computing architecture)
%%     d6  sport 2023 (swimming competition results)
%%   搜索 "learning" 命中 d1 + d3(tech),d5 虽 tech 但不含 "learning"。
%% -------------------------------------------------------------------
-module(bitcask_search_filter_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IDX, [read_write, {analyzer, whitespace}]).
-define(VOPTS, [read_write, {analyzer, whitespace}, {vector_dim, 4}]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_filter_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% 给一份 doc 写入带 meta 的索引模式数据。Meta 必须是 NIF 编码过的 binary。
put_doc(R, Key, Text, Meta) ->
    ok = bitcask:put(R, Key, #{text => Text, meta => Meta}).

%% meta 编码快捷方式:bitcask:encode_meta/1 接受 map。
m(KV) -> bitcask:encode_meta(KV).

%% 语料(同上注释)。返回打开的 Ref。
open_corpus(D) ->
    R = bitcask:open(D, ?IDX),
    put_doc(R, <<"d1">>, <<"machine learning algorithms">>,
            m(#{<<"category">> => <<"tech">>, <<"year">> => 2024})),
    put_doc(R, <<"d2">>, <<"football world cup final">>,
            m(#{<<"category">> => <<"sport">>, <<"year">> => 2023})),
    put_doc(R, <<"d3">>, <<"deep learning neural networks">>,
            m(#{<<"category">> => <<"tech">>, <<"year">> => 2023})),
    put_doc(R, <<"d4">>, <<"basketball playoff game">>,
            m(#{<<"category">> => <<"sport">>, <<"year">> => 2023})),
    put_doc(R, <<"d5">>, <<"cloud computing architecture">>,
            m(#{<<"category">> => <<"tech">>, <<"year">> => 2024})),
    put_doc(R, <<"d6">>, <<"swimming competition results">>,
            m(#{<<"category">> => <<"sport">>, <<"year">> => 2023})),
    R.

%% ===================================================================
%% filter_eq:list 形态 = And,单条 eq 命中预期文档
%% ===================================================================

filter_eq_tech_test_() ->
    {"filter [eq category=tech] → 只命中 d1,d3",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = [#{key => <<"category">>, op => eq, value => <<"tech">>}],
            {ok, Hits} = bitcask:search_text(R, <<"learning">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"d1">>, <<"d3">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_gte:数值 Gt/Gte 走 compare_numeric,语义正确
%% ===================================================================

filter_gte_year_2024_test_() ->
    {"filter [gte year=2024] → 命中 d1(学习+2024)",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = [#{key => <<"year">>, op => gte, value => 2024}],
            {ok, Hits} = bitcask:search_text(R, <<"learning">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"d1">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_and:list 形态 = And(全部条件都需满足)
%% ===================================================================

filter_and_two_conditions_test_() ->
    {"filter [eq category=tech, gte year=2024] → d1(2024 tech 学习)",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = [#{key => <<"category">>, op => eq, value => <<"tech">>},
                 #{key => <<"year">>,     op => gte, value => 2024}],
            {ok, Hits} = bitcask:search_text(R, <<"learning">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"d1">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_or:map 形态 logic => or,children 也支持
%% ===================================================================

filter_or_top_level_test_() ->
    {"filter #{logic=>'or', conditions=>[...]} → 任一命中",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = #{logic => 'or',
                  conditions => [#{key => <<"category">>, op => eq,
                                   value => <<"sport">>}]},
            {ok, Hits} = bitcask:search_text(R, <<"learning">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            %% 语料里 sport 文档不含 "learning" — 走其它语料 query 验证
            {ok, Hits2} = bitcask:search_text(R, <<"final">>, 10, F),
            Keys2 = lists:sort([K || {K, _, _} <- Hits2]),
            ?assertEqual([], Keys),
            ?assertEqual([<<"d2">>], Keys2),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_in:op => in + values 列表
%% ===================================================================

filter_in_status_test_() ->
    {"filter #{op=>in, values=>[active,pending]} → In 语义(Eq 逐项)",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            put_doc(R, <<"a1">>, <<"hello active user">>,
                    m(#{<<"status">> => <<"active">>})),
            put_doc(R, <<"a2">>, <<"hello pending user">>,
                    m(#{<<"status">> => <<"pending">>})),
            put_doc(R, <<"a3">>, <<"hello closed user">>,
                    m(#{<<"status">> => <<"closed">>})),
            F = #{key => <<"status">>, op => in,
                  values => [<<"active">>, <<"pending">>]},
            {ok, Hits} = bitcask:search_text(R, <<"hello">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"a1">>, <<"a2">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_no_match:命中数为 0
%% ===================================================================

filter_no_match_returns_empty_test_() ->
    {"无匹配 filter → {ok, []}",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = [#{key => <<"category">>, op => eq, value => <<"music">>}],
            ?assertEqual({ok, []}, bitcask:search_text(R, <<"learning">>, 10, F)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_undefined:passing undefined → 行为等同无 filter
%% ===================================================================

filter_undefined_same_as_no_filter_test_() ->
    {"filter = undefined → 与 search_text/3 结果一致",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            {ok, Base} = bitcask:search_text(R, <<"learning">>, 10),
            {ok, WithUndef} = bitcask:search_text(R, <<"learning">>, 10, undefined),
            ?assertEqual([K || {K, _, _} <- Base],
                         [K || {K, _, _} <- WithUndef]),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% filter_invalid:坏 term → badarg
%% ===================================================================

filter_invalid_term_raises_badarg_test_() ->
    {"filter 形态错误 → badarg(atom 充当 key / list 嵌套 bad shape)",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            %% key 不是 binary
            ?assertError(badarg,
                bitcask:search_text(R, <<"learning">>, 10,
                    [#{key => category, op => eq, value => <<"tech">>}])),
            %% op 不识别
            ?assertError(badarg,
                bitcask:search_text(R, <<"learning">>, 10,
                    [#{key => <<"category">>, op => wat, value => <<"tech">>}])),
            %% In 缺 values
            ?assertError(badarg,
                bitcask:search_text(R, <<"learning">>, 10,
                    [#{key => <<"category">>, op => in}])),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% vector + filter(把 filter 路径打通到 search_vector/5)
%% ===================================================================

vector_with_eq_filter_test_() ->
    {"search_vector/5 + filter eq → 只命中同 group 的向量文档",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?VOPTS),
            Vec1 = << <<X:32/float-little>> || X <- [1.0, 0.0, 0.0, 0.0] >>,
            Vec2 = << <<X:32/float-little>> || X <- [0.0, 1.0, 0.0, 0.0] >>,
            Vec3 = << <<X:32/float-little>> || X <- [0.0, 0.0, 1.0, 0.0] >>,
            ok = bitcask:put(R, <<"v1">>,
                #{text => <<"x">>, vector => Vec1, meta => m(#{<<"g">> => <<"a">>})}),
            ok = bitcask:put(R, <<"v2">>,
                #{text => <<"x">>, vector => Vec2, meta => m(#{<<"g">> => <<"b">>})}),
            ok = bitcask:put(R, <<"v3">>,
                #{text => <<"x">>, vector => Vec3, meta => m(#{<<"g">> => <<"a">>})}),
            F = [#{key => <<"g">>, op => eq, value => <<"a">>}],
            {ok, Hits} = bitcask:search_vector(R, Vec1, 10, 0, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"v1">>, <<"v3">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% hybrid + filter(同时过滤 BM25 + HNSW 两路)
%% ===================================================================

hybrid_with_filter_test_() ->
    {"search_hybrid/5 + filter → RRF 融合前两路均需通过 filter",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?VOPTS),
            Vec = << <<X:32/float-little>> || X <- [1.0, 0.0, 0.0, 0.0] >>,
            ok = bitcask:put(R, <<"h1">>,
                #{text => <<"x x x">>, vector => Vec,
                  meta => m(#{<<"kind">> => <<"good">>})}),
            ok = bitcask:put(R, <<"h2">>,
                #{text => <<"x x y">>, vector => Vec,
                  meta => m(#{<<"kind">> => <<"bad">>})}),
            F = [#{key => <<"kind">>, op => eq, value => <<"good">>}],
            {ok, Hits} = bitcask:search_hybrid(R, <<"x">>, Vec, 10, F),
            Keys = [K || {K, _, _} <- Hits],
            ?assertEqual([<<"h1">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% nested filter:logic + children 树形嵌套
%% ===================================================================

nested_or_and_children_test_() ->
    {"filter #{logic=>'or', children=>[#{logic=>'and', ...}]} → 任一子树命中",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            F = #{logic => 'or',
                  children => [
                    #{logic => 'and',
                      conditions => [#{key => <<"category">>, op => eq,
                                       value => <<"tech">>},
                                    #{key => <<"year">>, op => gte,
                                       value => 2024}]},
                    #{logic => 'and',
                      conditions => [#{key => <<"category">>, op => eq,
                                       value => <<"sport">>},
                                    #{key => <<"year">>, op => eq,
                                       value => 2023}]}
                  ]},
            {ok, Hits} = bitcask:search_text(R, <<"learning">>, 10, F),
            Keys = lists:sort([K || {K, _, _} <- Hits]),
            ?assertEqual([<<"d1">>], Keys),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% encode_meta sanity:验证 NIF 自身能正确编码并被 search 端解码
%% ===================================================================

encode_meta_round_trip_test_() ->
    {"encode_meta([{b,1},{a,2}]) → 内部 sort 后可被正确 lookup",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            Bin = bitcask:encode_meta([{<<"b">>, 1}, {<<"a">>, 2}]),
            ok = bitcask:put(R, <<"k">>,
                #{text => <<"alpha beta">>, meta => Bin}),
            F = [#{key => <<"a">>, op => eq, value => 2},
                 #{key => <<"b">>, op => eq, value => 1}],
            {ok, Hits} = bitcask:search_text(R, <<"alpha">>, 10, F),
            ?assertEqual([<<"k">>], [K || {K, _, _} <- Hits]),
            bitcask:close(R)
        end)
    end}.
