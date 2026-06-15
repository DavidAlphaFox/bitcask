%% -------------------------------------------------------------------
%% bitcask_vector_tests:
%%   V3.6 — 向量/混合检索的 NIF 端到端 eunit（mock embedder，不打真实端点）。
%%     - put(#{text, vector}) → search_vector：HNSW 近邻序
%%     - put → search_hybrid：RRF 融合真值（与 C++ V36HybridRrfFusion 同
%%       语料：d1/d3 精确平局 → ord 序；d4 仅向量路）
%%     - 单路退化（Text=<<>> / VecBin=<<>>）
%%     - 错误路径：size%4≠0 → badarg；维度不符/无向量配置/双空 → {error,_}
%%   语料向量经 bitcask_embedder_mock（behaviour 实现）产出，证 embed →
%%   put → hybrid 全链路。openai 模块的网络路径默认 skip（见文末手动用例）。
%% -------------------------------------------------------------------
-module(bitcask_vector_tests).

-include_lib("eunit/include/eunit.hrl").

-define(VOPTS, [read_write, {analyzer, whitespace}, {vector_dim, 4}]).
-define(IDX,   [read_write, {analyzer, whitespace}]).

with_dir(Fun) ->
    Dir = "/tmp/bitcask_vector_" ++ os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after os:cmd("rm -rf " ++ Dir)
    end.

%% 语料（与 C++ V36HybridRrfFusion 一致；向量出自 mock embedder）：
%%   key  text(BM25 rank)  vec               (vec rank, cos vs (1,0,0,0))
%%   d1   "x x x"  rank1   (0.6,0.8,0,0)     rank3, 0.6
%%   d2   "x x y"  rank2   (0.8,0.6,0,0)     rank2, 0.8
%%   d3   "x y y"  rank3   (1,0,0,0)         rank1, 1.0
%%   d4   "z z z"  无命中   (0,0,0,1)         rank4, 0.0（仅向量路）
open_corpus(Dir) ->
    R = bitcask:open(Dir, ?VOPTS),
    lists:foreach(
      fun({K, T}) ->
          {ok, V} = bitcask_embedder_mock:embed(T),
          ok = bitcask:put(R, K, #{text => T, vector => V})
      end,
      [{<<"d1">>, <<"x x x">>},
       {<<"d2">>, <<"x x y">>},
       {<<"d3">>, <<"x y y">>},
       {<<"d4">>, <<"z z z">>}]),
    R.

qvec() ->
    {ok, Q} = bitcask_embedder_mock:embed(<<"x">>),
    Q.

rrf(Rank) -> 1.0 / (60.0 + Rank).

%% ===================================================================
%% put(带 vector)→ search_vector：近邻序 + 相似度分
%% ===================================================================

put_then_search_vector_test_() ->
    {"embed → put → search_vector 端到端:HNSW 近邻序 d3,d2,d1,d4",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            {ok, Hits} = bitcask:search_vector(R, qvec(), 4),
            ?assertEqual([<<"d3">>, <<"d2">>, <<"d1">>, <<"d4">>],
                         [K || {K, _, _} <- Hits]),
            [{_, _, S1}, {_, _, S2}, {_, _, S3}, {_, _, S4}] = Hits,
            ?assert(abs(S1 - 1.0) < 1.0e-5),
            ?assert(abs(S2 - 0.8) < 1.0e-5),
            ?assert(abs(S3 - 0.6) < 1.0e-5),
            ?assert(abs(S4 - 0.0) < 1.0e-5),
            %% Ef 显式传递路径（cask_search_vector/4 末参）。
            {ok, Hits2} = bitcask:search_vector(R, qvec(), 4, 128),
            ?assertEqual([K || {K, _, _} <- Hits],
                         [K || {K, _, _} <- Hits2]),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% search_hybrid：RRF 真值（含精确平局的 ord 序 + 单路文档）
%% ===================================================================

hybrid_rrf_fusion_test_() ->
    {"RRF 真值:d1=d3=1/61+1/63(平局,ord 序)> d2=2/62 > d4=1/64",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            {ok, Hits} = bitcask:search_hybrid(R, <<"x">>, qvec(), 10),
            ?assertEqual([<<"d1">>, <<"d3">>, <<"d2">>, <<"d4">>],
                         [K || {K, _, _} <- Hits]),
            [{_, O1, S1}, {_, O3, S3}, {_, _, S2}, {_, _, S4}] = Hits,
            ?assertEqual(rrf(1) + rrf(3), S1),   %% 浮点逐位相等(可交换和)
            ?assertEqual(S1, S3),                %% 精确平局
            ?assert(O1 < O3),                    %% 平局 → ord 小者在前
            ?assertEqual(rrf(2) + rrf(2), S2),
            ?assertEqual(rrf(4), S4),
            %% k 截断:top-2 = 平局对。
            {ok, Top2} = bitcask:search_hybrid(R, <<"x">>, qvec(), 2),
            ?assertEqual([<<"d1">>, <<"d3">>], [K || {K, _, _} <- Top2]),
            bitcask:close(R)
        end)
    end}.

hybrid_single_leg_test_() ->
    {"单路退化:Text=<<>> → 纯向量序;VecBin=<<>> → 纯文本序",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            {ok, Vh} = bitcask:search_hybrid(R, <<>>, qvec(), 10),
            ?assertEqual([<<"d3">>, <<"d2">>, <<"d1">>, <<"d4">>],
                         [K || {K, _, _} <- Vh]),
            ?assertEqual([rrf(1), rrf(2), rrf(3), rrf(4)],
                         [S || {_, _, S} <- Vh]),
            {ok, Th} = bitcask:search_hybrid(R, <<"x">>, <<>>, 10),
            ?assertEqual([<<"d1">>, <<"d2">>, <<"d3">>],
                         [K || {K, _, _} <- Th]),
            ?assertEqual([rrf(1), rrf(2), rrf(3)],
                         [S || {_, _, S} <- Th]),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 错误路径：坏 binary 尺寸 / 维度不符 / 无向量配置 / 双空
%% ===================================================================

bad_vector_binary_test_() ->
    {"size%4≠0 → badarg(put 与查询两侧);维度不符 → {error,_}",
     fun() ->
        with_dir(fun(D) ->
            R = open_corpus(D),
            %% 查询侧:7 字节不是 f32 数组。
            ?assertError(badarg,
                bitcask:search_vector(R, <<1, 2, 3, 4, 5, 6, 7>>, 4)),
            ?assertError(badarg,
                bitcask:search_hybrid(R, <<"x">>, <<1, 2, 3>>, 4)),
            %% put 侧:坏 vector 不得落盘。
            ?assertError(badarg,
                bitcask:put(R, <<"bad">>, #{text => <<"t">>,
                                            vector => <<0, 0, 0>>})),
            ?assertEqual(not_found, bitcask:get(R, <<"bad">>)),
            %% 维度不符(2 floats vs dim=4)→ {error,_}(引擎校验,不崩)。
            Two = bitcask_embedder_mock:vec_bin([1.0, 0.0]),
            ?assertMatch({error, _}, bitcask:search_vector(R, Two, 4)),
            ?assertMatch({error, _}, bitcask:search_hybrid(R, <<"x">>, Two, 4)),
            ?assertMatch({error, _},
                bitcask:put(R, <<"d9">>, #{text => <<"t">>, vector => Two})),
            bitcask:close(R)
        end)
    end}.

%% 新流程：open 用 {embedder,{Provider,Cfg}} 内部 new + 自动取 vector_dim；
%% put #{text} 自动 embed；search_hybrid/2 与 search_vector({text,_}) 自动 embed
%% 查询；bitcask:embed/2 门面。
embedder_open_auto_embed_test_() ->
    {"open 配 embedder 自动建 ctx+取 vector_dim；put/查询/embed 全自动",
     fun() ->
        with_dir(fun(D) ->
            EOpts = [read_write, {analyzer, whitespace},
                     {embedder, {{custom, bitcask_embedder_mock}, #{}}}],
            R = bitcask:open(D, EOpts),
            %% 句柄携带 ctx；vector_dim 由 embedder 推出（mock dim=4），无需显式。
            ?assertMatch({_Ref, #{module := bitcask_embedder_mock}}, R),
            %% put 只给 text → 自动 embed 入库。
            ok = bitcask:put(R, <<"d1">>, #{text => <<"x y y">>}),
            ok = bitcask:put(R, <<"d4">>, #{text => <<"z z z">>}),
            %% embed 门面。
            ?assertMatch({ok, Q} when is_binary(Q), bitcask:embed(R, <<"x">>)),
            %% search_hybrid 省略向量 → 自动 embed（文本两路）。
            ?assertMatch({ok, [{<<"d1">>, _, _} | _]},
                         bitcask:search_hybrid(R, <<"x">>)),
            ?assertMatch({ok, [{<<"d1">>, _, _} | _]},
                         bitcask:search_hybrid(R, <<"x">>, auto, 5)),
            %% search_vector 传 {text,_} → 自动 embed 查询。
            ?assertMatch({ok, [{<<"d1">>, _, _} | _]},
                         bitcask:search_vector(R, {text, <<"x x x">>})),
            bitcask:close(R)
        end),
        %% 无 embedder 的集合调 embed/2 → {error, no_embedder}。
        with_dir(fun(D) ->
            R = bitcask:open(D, ?IDX),
            ?assertEqual({error, no_embedder}, bitcask:embed(R, <<"x">>)),
            bitcask:close(R)
        end)
    end}.

%% embedder 选项只接受新形 {Provider, Cfg}；传旧式预建 ctx（map）应拒绝。
embedder_rejects_prebuilt_ctx_test_() ->
    {"open 的 embedder 只支持 {Provider,Cfg}，预建 ctx map 被拒",
     fun() ->
        with_dir(fun(D) ->
            {ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_mock}, #{}),
            R = bitcask:open(D, [read_write, {analyzer, whitespace},
                                 {embedder, Ctx}]),
            ?assertMatch({error, {bad_embedder, _}}, R)
        end)
    end}.

hybrid_requires_vector_config_test_() ->
    {"无向量配置集合调 hybrid/search_vector → {error,_};双空 → {error,_}",
     fun() ->
        with_dir(fun(D) ->
            %% 纯索引模式(无 vector_dim)。
            R = bitcask:open(D, ?IDX),
            ok = bitcask:put(R, <<"k">>, <<"x x x">>),
            Q = qvec(),
            ?assertMatch({error, _}, bitcask:search_vector(R, Q, 4)),
            ?assertMatch({error, _}, bitcask:search_hybrid(R, <<"x">>, Q, 4)),
            bitcask:close(R)
        end),
        with_dir(fun(D) ->
            %% 向量集合:两路都空才报错。
            R = open_corpus(D),
            ?assertMatch({error, _}, bitcask:search_hybrid(R, <<>>, <<>>, 4)),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 重开持久性：向量集合 close → reopen 后 hybrid 仍可用
%% ===================================================================

hybrid_survives_reopen_test_() ->
    {"close + reopen(hnsw.snap 快路径)后 hybrid 排序不变",
     fun() ->
        with_dir(fun(D) ->
            R0 = open_corpus(D),
            ok = bitcask:close(R0),
            R = bitcask:open(D, ?VOPTS),
            {ok, Hits} = bitcask:search_hybrid(R, <<"x">>, qvec(), 10),
            ?assertEqual([<<"d1">>, <<"d3">>, <<"d2">>, <<"d4">>],
                         [K || {K, _, _} <- Hits]),
            bitcask:close(R)
        end)
    end}.

%% ===================================================================
%% 手动用例：真实 embedding 端点（默认 skip，不进门禁）
%%
%% 开关:export BITCASK_EMBEDDER_LIVE=1 且端点可达时手动跑:
%%   BITCASK_EMBEDDER_LIVE=1 rebar3 as test eunit --module=bitcask_vector_tests
%% 端点配置走 bitcask_embedder:new(openai, #{...}) 构建上下文
%% (URL/Model 改成实际部署;默认值即 hnsw-design §2.1 的部署目标)。
%% ===================================================================

openai_live_test_() ->
    case os:getenv("BITCASK_EMBEDDER_LIVE") of
        "1" ->
            {timeout, 120,
             {"真实端点 embed → put → hybrid(手动)",
              fun() ->
                 Url = case os:getenv("BITCASK_EMBEDDER_URL") of
                           false -> "http://192.168.186.1:8080/v1/embeddings";
                           U -> U
                       end,
                 Model = <<"qwen3-embedding">>,
                 {ok, Ctx} = bitcask_embedder:new(openai, #{
                     url   => Url,
                     model => Model
                 }),
                 {ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello world">>),
                 Dim = byte_size(Vec) div 4,
                 ?assertEqual(0, byte_size(Vec) rem 4),
                 ?assert(Dim > 0),
                 with_dir(fun(D) ->
                     R = bitcask:open(D, [read_write, {analyzer, whitespace},
                                          {vector_dim, Dim}]),
                     ok = bitcask:put(R, <<"h">>,
                                      #{text => <<"hello world">>,
                                        vector => Vec}),
                     {ok, Hits} = bitcask:search_hybrid(R, <<"hello">>, Vec, 5),
                     ?assertMatch([{<<"h">>, _, _} | _], Hits),
                     bitcask:close(R)
                 end)
              end}};
        _ ->
            []  %% 默认 skip:门禁不依赖在线端点
    end.
