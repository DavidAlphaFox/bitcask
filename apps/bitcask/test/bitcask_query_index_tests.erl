%% -------------------------------------------------------------------
%% bitcask_query_index_tests:
%%   bitcask_query 的二级索引。
%%
%%   主判据：同一组 where，走索引（index => auto）与不走（index => none，
%%   全表 range + 引擎 filter）命中集合必须相等——后者已与引擎 MetaFilter、
%%   BEAM 求值对照过（bitcask_query_tests）。再加：编码保序、写入维护、
%%   过期项读校验、并发写同 key、分页、保留前缀不外泄。
%% -------------------------------------------------------------------
-module(bitcask_query_index_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IDX, [read_write, {analyzer, whitespace}]).

with_dir(Fun) -> bitcask_test_util:with_dir("bitcask_qidx_", Fun).

m(KV) -> bitcask:encode_meta(KV).

keys({ok, Rows}) -> [K || #{key := K} <- Rows].

sorted(Q) -> lists:sort(keys(Q)).

enc(V) -> bitcask_query_index:enc(V).

%% ===================================================================
%% 编码保序
%% ===================================================================

enc_order_test_() ->
    [{"integer：编码序 = 数值序（含两端极值）",
      fun() ->
         Is = [-(1 bsl 63), -(1 bsl 40), -2, -1, 0, 1, 2, 255, 256, 1 bsl 40, (1 bsl 63) - 1],
         ?assertEqual(Is, lists:sort(fun(A, B) -> enc(A) =< enc(B) end, lists:reverse(Is)))
      end},
     {"float：编码序 = 数值序；-0.0 与 0.0 同码",
      fun() ->
         Fs = [-1.0e300, -2.5, -1.0, -1.0e-300, 0.0, 1.0e-300, 1.0, 2.5, 1.0e300],
         ?assertEqual(Fs, lists:sort(fun(A, B) -> enc(A) =< enc(B) end, lists:reverse(Fs))),
         ?assertEqual(enc(0.0), enc(-0.0))
      end},
     {"binary：编码序 = 字节序；含 0 字节、前缀关系也对；自定界",
      fun() ->
         Bs = [<<>>, <<0>>, <<0, 0>>, <<0, 1>>, <<1>>, <<"a">>, <<"a", 0>>, <<"ab">>, <<255>>],
         ?assertEqual(Bs, lists:sort(fun(A, B) -> enc(A) =< enc(B) end, lists:reverse(Bs))),
         %% 自定界：任何一个的编码都不是另一个的前缀
         [?assertNot({A, B, binary:longest_common_prefix([enc(A), enc(B)]) =:= byte_size(enc(A))}
                     =:= {A, B, true})
          || A <- Bs, B <- Bs, A =/= B]
      end},
     {"类型之间互不相交：bool < int < float < binary",
      fun() ->
         ?assert(enc(true) < enc(-(1 bsl 63))),
         ?assert(enc((1 bsl 63) - 1) < enc(-1.0e300)),
         ?assert(enc(1.0e300) < enc(<<>>))
      end}].

%% ===================================================================
%% 语料
%% ===================================================================

%% 类型混杂、边界值、缺字段、null、无 meta、字符串含 0 字节。
docs() ->
    [{<<"k01">>, #{<<"n">> => -5,   <<"s">> => <<"apple">>,   <<"b">> => true}},
     {<<"k02">>, #{<<"n">> => 0,    <<"s">> => <<"app">>,     <<"b">> => false}},
     {<<"k03">>, #{<<"n">> => 7,    <<"s">> => <<"a", 0, "x">>}},
     {<<"k04">>, #{<<"n">> => 7.0,  <<"s">> => <<"banana">>}},
     {<<"k05">>, #{<<"n">> => -0.0, <<"s">> => undefined}},
     {<<"k06">>, #{<<"n">> => 1 bsl 62}},
     {<<"k07">>, #{<<"n">> => 2.5,  <<"b">> => true}},
     {<<"k08">>, #{<<"s">> => <<"apple">>}},
     {<<"k09">>, none},
     {<<"k10">>, #{<<"n">> => 7,    <<"s">> => <<>>}}].

open_corpus(D) ->
    R = bitcask:open(D, ?IDX),
    [ok = case M of
              none -> bitcask_query:put(R, K, #{text => <<"t ", K/binary>>});
              _    -> bitcask_query:put(R, K, #{text => <<"t ", K/binary>>, meta => m(M)})
          end || {K, M} <- docs()],
    R.

where_cases() ->
    [{<<"n">>, eq, 7},
     {<<"n">>, eq, 7.0},
     {<<"n">>, eq, 0.0},                       % 命中 -0.0
     {<<"n">>, eq, 0},
     {<<"n">>, in, [7, -5, 99, undefined]},
     {<<"n">>, gt, 0},
     {<<"n">>, gte, 7},
     {<<"n">>, lt, 0},
     {<<"n">>, lte, 2.5},
     {<<"n">>, gt, -1.0},
     {<<"n">>, gt, <<"x">>},                   % 非数值比较：恒假
     {<<"n">>, exists},
     {<<"s">>, eq, <<"apple">>},
     {<<"s">>, eq, <<"a", 0, "x">>},
     {<<"s">>, eq, <<>>},
     {<<"s">>, in, [<<"app">>, <<"banana">>]},
     {<<"s">>, exists},
     {<<"s">>, eq, undefined},                 % 不走索引（命中缺字段）
     {<<"b">>, eq, true},
     [{<<"n">>, eq, 7}, {<<"s">>, exists}],
     [{<<"n">>, gte, 0}, {<<"s">>, neq, <<"banana">>}],
     {'or', [{<<"n">>, eq, 7}]},
     {'or', [{<<"n">>, eq, 7}, {<<"s">>, eq, <<"apple">>}]}].   % 不走索引

%% ===================================================================
%% 主判据：走索引 ≡ 不走索引
%% ===================================================================

index_agrees_with_scan_test_() ->
    {"同一组 where：index => auto（走索引）与 index => none 命中相同",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            Before = [{W, sorted(bitcask_query:q(R, #{where => W}))} || W <- where_cases()],
            ok = bitcask_query:create_index(R, <<"n">>),
            ok = bitcask_query:create_index(R, s),         % atom 字段名
            ok = bitcask_query:create_index(R, <<"b">>),
            ?assertEqual([{<<"b">>, ready}, {<<"n">>, ready}, {<<"s">>, ready}],
                         lists:sort(bitcask_query:indexes(R))),
            [begin
                 Ix   = sorted(bitcask_query:q(R, #{where => W})),
                 Scan = sorted(bitcask_query:q(R, #{where => W, index => none})),
                 ?assertEqual({W, Want}, {W, Ix}),
                 ?assertEqual({W, Want}, {W, Scan})
             end || {W, Want} <- Before],
            %% 选用情况
            Drv = fun(W) -> {ok, E} = bitcask_query:explain(R, #{where => W}), E end,
            ?assertMatch(#{driver := index, field := <<"n">>}, Drv({<<"n">>, eq, 7})),
            ?assertMatch(#{driver := index, field := <<"s">>},
                         Drv([{<<"n">>, gt, 0}, {<<"s">>, eq, <<"apple">>}])),   % eq 优先
            ?assertMatch(#{driver := range}, Drv({<<"s">>, eq, undefined})),
            ?assertMatch(#{driver := range},
                         Drv({'or', [{<<"n">>, eq, 7}, {<<"s">>, eq, <<"x">>}]})),
            ?assertMatch(#{driver := range}, Drv({<<"zzz">>, eq, 1})),          % 无索引
            ?assertMatch(#{driver := range},
                         (fun() -> {ok, E} = bitcask_query:explain(
                                                R, #{where => {<<"n">>, eq, 7},
                                                     index => none}), E end)()),
            bitcask:close(R)
        end)
    end}.

index_order_and_paging_test_() ->
    {"走索引：按 (值, 主键) 升序；分页拼起来等于一次取全",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            ok = bitcask_query:create_index(R, <<"n">>),
            {ok, Rows} = bitcask_query:q(R, #{where => {<<"n">>, exists}}),
            %% int 段：-5, 0, 7(k03), 7(k10), 2^62；float 段：-0.0, 2.5, 7.0
            ?assertEqual([<<"k01">>, <<"k02">>, <<"k03">>, <<"k10">>, <<"k06">>,
                          <<"k05">>, <<"k07">>, <<"k04">>],
                         [K || #{key := K} <- Rows]),
            Pages = drain(bitcask_query:page(R, #{where => {<<"n">>, exists}, limit => 3})),
            ?assertEqual([3, 3, 2], [length(P) || P <- Pages]),
            ?assertEqual(Rows, lists:append(Pages)),
            %% in：多段区间跨页
            InPages = drain(bitcask_query:page(R, #{where => {<<"n">>, in, [7, -5, 2.5]},
                                                    limit => 2, select => [key]})),
            ?assertEqual([[<<"k01">>, <<"k03">>], [<<"k10">>, <<"k07">>]],
                         [[K || #{key := K} <- P] || P <- InPages]),
            bitcask:close(R)
        end)
    end}.

drain({ok, Rows, done}) -> [Rows];
drain({ok, Rows, Cont}) -> [Rows | drain(bitcask_query:page(Cont))].

%% ===================================================================
%% 维护
%% ===================================================================

ix_entries(R) ->
    [K || {K, _} <- bitcask:range(R, {<<0, "bitcask_query:ix:">>,
                                       bitcask:prefix_succ(<<0, "bitcask_query:ix:">>)})].

maintenance_test_() ->
    {"put 改值 → 旧项删、新项加；delete → 项删；drop → 项与定义全清；保留前缀不外泄",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask_query:create_index(R, <<"c">>),
            P = fun(K, C) -> bitcask_query:put(R, K, #{text => <<"x">>,
                                                       meta => m(#{<<"c">> => C})}) end,
            Eq = fun(C) -> keys(bitcask_query:q(R, #{where => {<<"c">>, eq, C}})) end,
            ok = P(<<"a">>, <<"red">>),
            ok = P(<<"b">>, <<"red">>),
            ?assertEqual([<<"a">>, <<"b">>], Eq(<<"red">>)),
            ok = P(<<"a">>, <<"blue">>),
            ?assertEqual([<<"b">>], Eq(<<"red">>)),
            ?assertEqual([<<"a">>], Eq(<<"blue">>)),
            ?assertEqual(2, length(ix_entries(R))),                 % 旧项确实删了
            ok = bitcask_query:put(R, <<"a">>, #{text => <<"no meta now">>}),
            ?assertEqual([], Eq(<<"blue">>)),
            ?assertEqual(1, length(ix_entries(R))),
            ok = bitcask_query:delete(R, <<"b">>),
            ?assertEqual([], Eq(<<"red">>)),
            ?assertEqual(0, length(ix_entries(R))),
            %% 全表查询看不到定义 / 索引项
            ok = P(<<"c">>, <<"red">>),
            ?assertEqual([<<"a">>, <<"c">>], keys(bitcask_query:q(R, #{}))),
            ?assertEqual({error, {bad_query, {reserved_key, <<0, "bitcask_query:x">>}}},
                         bitcask_query:put(R, <<0, "bitcask_query:x">>, <<"v">>)),
            ok = bitcask_query:drop_index(R, <<"c">>),
            ?assertEqual([], bitcask_query:indexes(R)),
            ?assertEqual([], ix_entries(R)),
            ?assertEqual([<<"c">>], Eq(<<"red">>)),                 % 回落全表，照样对
            bitcask:close(R)
        end)
    end}.

stale_entry_test_() ->
    {"绕过 bitcask_query:put 改 meta：旧值的过期项被读校验挡掉；重建后新值可查",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask_query:create_index(R, <<"c">>),
            ok = bitcask_query:put(R, <<"a">>, #{text => <<"x">>, meta => m(#{<<"c">> => 1})}),
            ok = bitcask:put(R, <<"a">>, #{text => <<"x">>, meta => m(#{<<"c">> => 2})}),
            Eq = fun(C) -> keys(bitcask_query:q(R, #{where => {<<"c">>, eq, C}})) end,
            ?assertEqual([], Eq(1)),                % 过期项：不产出行
            ?assertEqual([], Eq(2)),                % 文档写的限制：新值缺项
            ?assertEqual([], keys(bitcask_query:q(R, #{where => {<<"c">>, gte, 1}}))), % 同理
            ?assertEqual([<<"a">>], keys(bitcask_query:q(R, #{where => {<<"c">>, eq, 2},
                                                              index => none}))),
            ok = bitcask_query:drop_index(R, <<"c">>),
            ok = bitcask_query:create_index(R, <<"c">>),
            ?assertEqual([<<"a">>], Eq(2)),
            bitcask:close(R)
        end)
    end}.

backfill_test_() ->
    {"对已有数据建索引：回填存量；KV 模式建索引不报错、无索引项",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            [ok = bitcask:put(R, <<"d", (integer_to_binary(N))/binary>>,
                              #{text => <<"x">>, meta => m(#{<<"g">> => N rem 3})})
             || N <- lists:seq(1, 2500)],                  % 跨回填分块（1000）
            ok = bitcask_query:create_index(R, <<"g">>),
            ok = bitcask_query:create_index(R, <<"g">>),   % 幂等
            ?assertEqual(2500, length(ix_entries(R))),
            ?assertEqual(833, length(keys(bitcask_query:q(R, #{where => {<<"g">>, eq, 0}})))),
            bitcask:close(R)
        end),
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write]),
            ok = bitcask:put(R, <<"k">>, <<"v">>),
            ok = bitcask_query:create_index(R, <<"g">>),
            ok = bitcask_query:put(R, <<"k2">>, <<"v2">>),
            ?assertEqual([], ix_entries(R)),
            ?assertEqual([<<"k">>, <<"k2">>], keys(bitcask_query:q(R, #{}))),
            bitcask:close(R)
        end)
    end}.

concurrent_same_key_test_() ->
    {"16 个进程并发改同一个 key 的索引字段：最终恰好一条索引项，且指向最终值",
     {timeout, 120,
      fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ok = bitcask_query:create_index(R, <<"v">>),
            Self = self(),
            Pids = [spawn_link(fun() ->
                                       [ok = bitcask_query:put(
                                               R, <<"hot">>,
                                               #{text => <<"x">>,
                                                 meta => m(#{<<"v">> => I * 100 + J})})
                                        || J <- lists:seq(1, 30)],
                                       Self ! {done, self()}
                               end) || I <- lists:seq(1, 16)],
            [receive {done, P} -> ok end || P <- Pids],
            {ok, #{meta := MB}} = bitcask:get(R, <<"hot">>),
            #{<<"v">> := Final} = bitcask:decode_meta(MB),
            ?assertEqual(1, length(ix_entries(R))),
            ?assertEqual([<<"hot">>],
                         keys(bitcask_query:q(R, #{where => {<<"v">>, eq, Final}}))),
            ?assertEqual([<<"hot">>],
                         keys(bitcask_query:q(R, #{where => {<<"v">>, exists}}))),
            bitcask:close(R)
        end)
      end}}.

auto_embed_through_index_test_() ->
    {"有索引时经 bitcask_query:put 写 #{text}：照样自动 embed（走提交批），索引项同批",
     fun() ->
        with_dir(fun(D) ->
            R = bitcask:open(D, [read_write, {analyzer, whitespace},
                                 {embedder, {{custom, bitcask_embedder_mock}, #{}}}]),
            ok = bitcask_query:create_index(R, <<"c">>),
            ok = bitcask_query:put(R, <<"a">>, #{text => <<"alpha">>,
                                                 meta => m(#{<<"c">> => 1})}),
            {ok, Q} = bitcask:embed(R, <<"alpha">>),
            ?assertMatch({ok, [{<<"a">>, _, _} | _]}, bitcask:search_vector(R, Q, 1)),
            ?assertEqual([<<"a">>], keys(bitcask_query:q(R, #{where => {<<"c">>, eq, 1}}))),
            ?assertEqual(1, length(ix_entries(R))),
            bitcask:close(R)
        end)
    end}.

