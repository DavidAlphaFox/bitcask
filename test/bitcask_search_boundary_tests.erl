%% -------------------------------------------------------------------
%% bitcask_search_boundary_tests:
%%   run_search 统一搜索骨架（S12.1）的边界条件覆盖。
%%   验证 NIF 层 run_search 对以下情况的处理与重构前一致：
%%     - no_index：KV 模式（open 不带 analyzer）调搜索 → {error, no_index}
%%     - k ≤ 0   ：get_positive_int 回落到默认 10，不崩、结果不变
%%     - 空 query / 无命中 → {ok, []}
%% -------------------------------------------------------------------
-module(bitcask_search_boundary_tests).

-include_lib("eunit/include/eunit.hrl").

%% 索引模式（带分词器）/ 纯 KV 模式 的 open 选项。
-define(IDX, [read_write, {analyzer, whitespace}]).
-define(KV,  [read_write]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_search_bnd_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% 在索引模式下写两篇都含 "brown" 的文档，返回 Ref。
open_indexed(D) ->
    R = bitcask:open(D, ?IDX),
    ok = bitcask:put(R, <<"d1">>, <<"the quick brown fox">>),
    ok = bitcask:put(R, <<"d2">>, <<"a lazy brown dog">>),
    R.

%% ===================================================================
%% no_index：KV 模式下所有搜索接口都返回 {error, no_index}
%% ===================================================================

no_index_returns_error_test_() ->
    {"KV 模式（无 analyzer）调用各搜索接口 → {error, no_index}",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?KV),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ?assertEqual({error, no_index}, bitcask:search_text(R, <<"x">>)),
            ?assertEqual({error, no_index}, bitcask:search_phrase(R, <<"x y">>)),
            ?assertEqual({error, no_index}, bitcask:search_fields(R, <<"f:x">>)),
            ?assertEqual({error, no_index}, bitcask:search_near(R, <<"x y">>, 1)),
            ?assertEqual({error, no_index}, bitcask:search_fuzzy(R, <<"x">>, 1)),
            ?assertEqual({error, no_index}, bitcask:search_wildcard(R, <<"x*">>)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% k ≤ 0：回落到默认 10，结果与显式 k=10 一致（不崩）
%% ===================================================================

k_zero_falls_back_to_default_test_() ->
    {"k=0 / k=-5 回落到默认 top-10，结果与 k=10 相同",
     fun() ->
        with_dir(fun(D) ->
            R = open_indexed(D),
            {ok, Base} = bitcask:search_text(R, <<"brown">>, 10),
            ?assertEqual(2, length(Base)),
            ?assertEqual({ok, Base}, bitcask:search_text(R, <<"brown">>, 0)),
            ?assertEqual({ok, Base}, bitcask:search_text(R, <<"brown">>, -5)),
            bitcask:close(R)
        end)
    end}.

%% near/fuzzy 的 4 参里 k 在末位，同样应回落（顺带覆盖非默认字段参数解析）。
k_zero_fallback_near_fuzzy_test_() ->
    {"near/fuzzy 的 k≤0 也回落到默认 10",
     fun() ->
        with_dir(fun(D) ->
            R = open_indexed(D),
            ?assertMatch({ok, _}, bitcask:search_near(R, <<"brown fox">>, 1, 0)),
            ?assertMatch({ok, [_|_]}, bitcask:search_fuzzy(R, <<"browne">>, 2, 0)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 空 query / 无命中 → {ok, []}（run_search 正常返回空，不报错不崩）
%% ===================================================================

empty_query_returns_empty_test_() ->
    {"空 binary query → {ok, []}",
     fun() ->
        with_dir(fun(D) ->
            R = open_indexed(D),
            ?assertEqual({ok, []}, bitcask:search_text(R, <<>>)),
            ?assertEqual({ok, []}, bitcask:search_wildcard(R, <<>>)),
            bitcask:close(R)
        end)
    end}.

no_match_returns_empty_test_() ->
    {"有索引但无命中 → {ok, []}",
     fun() ->
        with_dir(fun(D) ->
            R = open_indexed(D),
            ?assertEqual({ok, []}, bitcask:search_text(R, <<"zzz">>)),
            ?assertEqual({ok, []}, bitcask:search_wildcard(R, <<"zzz*">>)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 正向回归：每种搜索在索引模式下都能命中（确认 run_search 各闭包接线正确）
%% ===================================================================

each_search_kind_hits_test_() ->
    {"text/phrase/fuzzy/wildcard 在索引模式下命中预期文档",
     fun() ->
        with_dir(fun(D) ->
            R = open_indexed(D),
            {ok, T} = bitcask:search_text(R, <<"brown">>),
            ?assertEqual(2, length(T)),
            {ok, P} = bitcask:search_phrase(R, <<"quick brown">>),
            ?assertEqual([<<"d1">>], [K || {K, _, _} <- P]),
            {ok, F} = bitcask:search_fuzzy(R, <<"quikc">>, 2),
            ?assertEqual([<<"d1">>], [K || {K, _, _} <- F]),
            {ok, W} = bitcask:search_wildcard(R, <<"fox*">>),
            ?assertEqual([<<"d1">>], [K || {K, _, _} <- W]),
            bitcask:close(R)
        end)
    end}.
