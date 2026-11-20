%% -------------------------------------------------------------------
%% bitcask_jieba_merge_tests:
%%   下游反馈 feedbacks/2026-11-19-jieba-missing-dict-aborts-process.md（bosun）
%%   的 bitcask 侧：merge/2,3 的临时 merge_only 打开漏了 open/2 的缺省词典目录，
%%   带 {analyzer, jieba} 合并时 dict_path 为空 ⇒ libbitcask（≤ 11.0.0）里 cppjieba
%%   abort 整个 BEAM 节点；dict_path 给成字符串被 NIF 静默当成没给。
%%   现 open 与 merge 共用 normalize_text_opts/1。
%% -------------------------------------------------------------------
-module(bitcask_jieba_merge_tests).

-include_lib("eunit/include/eunit.hrl").

-define(JIEBA, [read_write, {analyzer, jieba}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_jieba_merge_", Fun).

key(I) -> <<"k", (integer_to_binary(I))/binary>>.
doc(I, Rev) ->
    unicode:characters_to_binary(io_lib:format("任务 ~b 第~b版 我来到北京邮电大学 lorem ipsum", [I, Rev])).

%% 建一个 jieba 检索库：每个 key 覆盖写若干遍（留下可合并的死数据），关库。
build(D) ->
    R = bitcask:open(D, ?JIEBA),
    ?assert(is_reference(element(1, R))),
    [ok = bitcask:put(R, key(I), doc(I, V)) || V <- lists:seq(1, 10), I <- lists:seq(1, 30)],
    ok = bitcask:close_write_file(R),
    ok = bitcask:close(R).

%% merge 的临时 merge_only 打开只带 {analyzer, jieba}（与建库同选项，不带 dict_path）
%% ⇒ 补上缺省 priv/dict，打开成功、进程还在。用 merge/3 + 空文件表：只走「打开 →
%% 关闭」，正是漏补 dict_path 的那一步。
%% 整次合并（检索库的 merge_only 旁车）见下面的 full_merge_* 用例（需 libbitcask ≥ 11.1.1）。
merge_open_without_dict_path_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            build(D),
            ?assertEqual(ok, bitcask:merge(D, [{analyzer, jieba}], [])),
            R = bitcask:open(D, ?JIEBA),
            {ok, Hits} = bitcask:search_text(R, <<"北京"/utf8>>, 50),
            ?assertEqual(30, length(Hits)),
            ok = bitcask:close(R)
        end)
    end}.

data_files(D) ->
    lists:sort(filelib:wildcard(filename:join(D, "*.bitcask.data"))).

text_of({ok, #{text := T}}) -> T.

scores(R, Q) ->
    {ok, Hits} = bitcask:search_text(R, Q, 100),
    lists:sort([{K, S} || {K, _, S} <- Hits]).

%% 检索库经 merge/2（merge_only 旁车，needs_merge 挑文件）整次合并：libbitcask
%% ≤ 11.1.0 永久挂住（M22-4；上游 S58 修于 11.1.1）。现返回 ok、封口文件被回收，
%% 写者重开后检索结果与分数逐一不变、值都是最新版本。
full_merge_search_library_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            build(D),
            R0 = bitcask:open(D, ?JIEBA),
            Before = scores(R0, <<"北京"/utf8>>),
            ?assertEqual(30, length(Before)),
            ok = bitcask:close(R0),
            Files0 = data_files(D),
            Self = self(),
            Pid = spawn(fun() -> Self ! {merged, bitcask:merge(D, [{analyzer, jieba}])} end),
            receive {merged, Res} -> ?assertEqual(ok, Res)
            after 60000 -> exit(Pid, kill), ?assert(false)   % 挂住
            end,
            ?assertNotEqual([], Files0 -- data_files(D)),          % 输入文件已回收
            R = bitcask:open(D, ?JIEBA),
            ?assertEqual(Before, scores(R, <<"北京"/utf8>>)),
            [?assertEqual(doc(I, 10), text_of(bitcask:get(R, key(I)))) || I <- lists:seq(1, 30)],
            ok = bitcask:close(R)
        end)
    end}.

%% 写者开着、同一节点里旁车合并（bitcask_merge_worker 的用法）：旁车打开后写者继续写，
%% 合并照样返回；写者之后读到全部最新值、照常检索。
full_merge_with_live_writer_test_() ->
    {timeout, 120, fun() ->
        with_dir(fun(D) ->
            W = bitcask:open(D, ?JIEBA),
            [ok = bitcask:put(W, key(I), doc(I, V)) || V <- lists:seq(1, 10), I <- lists:seq(1, 30)],
            ok = bitcask:close_write_file(W),
            Self = self(),
            Pid = spawn(fun() -> Self ! {merged, bitcask:merge(D, [{analyzer, jieba}])} end),
            ok = bitcask:put(W, <<"live">>, <<"合并期间写入 北京"/utf8>>),
            receive {merged, Res} -> ?assertEqual(ok, Res)
            after 60000 -> exit(Pid, kill), ?assert(false)
            end,
            [?assertEqual(doc(I, 10), text_of(bitcask:get(W, key(I)))) || I <- lists:seq(1, 30)],
            {ok, Hits} = bitcask:search_text(W, <<"北京"/utf8>>, 100),
            ?assertEqual(31, length(Hits)),
            ok = bitcask:close(W),
            R = bitcask:open(D, ?JIEBA),
            {ok, Hits2} = bitcask:search_text(R, <<"北京"/utf8>>, 100),
            ?assertEqual(31, length(Hits2)),
            ok = bitcask:close(R)
        end)
    end}.

%% 词典目录确实不对 ⇒ open / merge 返回 {error, {invalid_option, Msg}}，报文带缺的
%% 文件路径；节点不退出（libbitcask ≥ 11.1.0）。
bad_dict_path_returns_error_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            {error, {invalid_option, Msg}} =
                bitcask:open(D, ?JIEBA ++ [{dict_path, <<"/nonexistent">>}]),
            ?assertNotEqual(nomatch, binary:match(Msg, <<"/nonexistent/jieba.dict.utf8">>)),
            build(D),
            ?assertMatch({error, {invalid_option, _}},
                         bitcask:merge(D, [{analyzer, jieba}, {dict_path, "/nonexistent"}], []))
        end)
    end}.

%% dict_path 给字符串（filename:join 的自然结果）与给 binary 等价。
dict_path_string_accepted_test_() ->
    {timeout, 60, fun() ->
        with_dir(fun(D) ->
            Dict = filename:join(code:priv_dir(bitcask), "dict"),
            ?assert(is_list(Dict)),
            R = bitcask:open(D, ?JIEBA ++ [{dict_path, Dict}]),
            ?assert(is_reference(element(1, R))),
            ok = bitcask:put(R, <<"a">>, <<"我来到北京邮电大学"/utf8>>),
            {ok, [_]} = bitcask:search_text(R, <<"邮电"/utf8>>, 10),
            ok = bitcask:close_write_file(R),
            ok = bitcask:close(R),
            ?assertEqual(ok, bitcask:merge(D, [{analyzer, jieba}, {dict_path, Dict}], []))
        end)
    end}.

%% 别的类型的 dict_path ⇒ {error, {invalid_option, _}}，不再静默当成没给。
dict_path_bad_type_rejected_test() ->
    with_dir(fun(D) ->
        %% 报的是类型错（门面），不是「词典找不到」（NIF 把非 binary 当成没给）。
        ?assertEqual({error, {invalid_option, <<"dict_path must be a binary or a string">>}},
                     bitcask:open(D, ?JIEBA ++ [{dict_path, 42}])),
        ?assertEqual({error, {invalid_option, <<"dict_path must be a binary or a string">>}},
                     bitcask:merge(D, [{analyzer, jieba}, {dict_path, {x}}]))
    end).
