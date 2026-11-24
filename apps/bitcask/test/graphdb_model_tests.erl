%% 图的统一数据模型（doc/cypher-query-design-zh.md 第 4、8.2、11 节）：
%% id 分配与高水位、标签与标签索引、属性编码。
-module(graphdb_model_tests).
-include_lib("eunit/include/eunit.hrl").

-define(G, graphdb).
-define(VMAX, 16#FFFFFFFFFFFFFFFF).

%% 值编解码挂点的测试用回调（graphdb_model:register_value_codec/1）：{money, Cents} ↔ "12.34"
-export([is_value/1, type_tag/1, to_text/1, from_text/2]).
is_value({money, C}) -> is_integer(C);
is_value(_) -> false.
type_tag(_) -> <<"money">>.
to_text({money, C}) -> iolist_to_binary(io_lib:format("~b.~2..0b", [C div 100, C rem 100])).
from_text(<<"money">>, T) -> [A, B] = binary:split(T, <<".">>), {money, binary_to_integer(A) * 100 + binary_to_integer(B)}.

with_graph(F) ->
    bitcask_test_util:with_dir("graphdb_model_",
                               fun(D) ->
                                       R = ?G:open(D, [read_write]),
                                       try F(R) after ?G:close(R) end
                               end).

ok_inv(R) -> ?assertMatch({ok, _}, ?G:check_invariants(R)).

create_and_read_test() ->
    with_graph(fun(R) ->
        {ok, 1} = ?G:create_vertex(R, #{labels => [<<"Person">>, 'Admin'],
                                        props => #{name => <<"ann">>, age => 31, score => 1.5,
                                                   active => true, tags => [<<"a">>, <<"b">>],
                                                   gone => null}}),
        {ok, 2} = ?G:create_vertex(R, #{labels => [<<"Person">>]}),
        {ok, 3} = ?G:create_vertex(R, <<"plain body">>),
        {ok, 4} = ?G:create_vertex(R, #{}),
        ?assertEqual({ok, #{id => 1, labels => [<<"Person">>, <<"Admin">>],
                            properties => #{<<"name">> => <<"ann">>, <<"age">> => 31,
                                            <<"score">> => 1.5, <<"active">> => true,
                                            <<"tags">> => [<<"a">>, <<"b">>]}}},
                     ?G:vertex(R, 1)),
        ?assertEqual({ok, #{id => 3, labels => [], properties => #{<<"text">> => <<"plain body">>}}},
                     ?G:vertex(R, 3)),
        ?assertEqual({ok, #{id => 4, labels => [], properties => #{}}}, ?G:vertex(R, 4)),
        ?assertEqual({error, not_found}, ?G:vertex(R, 99)),
        ?assertEqual({ok, [1, 2]}, ?G:vertices_by_label(R, <<"Person">>)),
        ?assertEqual({ok, [1]}, ?G:vertices_by_label(R, 'Admin')),
        ?assertEqual({ok, [2]}, ?G:vertices_by_label(R, <<"Person">>, #{'after' => 1})),
        ?assertEqual({ok, [1]}, ?G:vertices_by_label(R, <<"Person">>, #{limit => 1})),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"Nobody">>)),
        %% 旧接口照常：get_vertex 读出引擎值
        ?assertEqual({ok, <<"plain body">>}, ?G:get_vertex(R, 3)),
        ok_inv(R)
    end).

explicit_ids_raise_watermark_test() ->
    with_graph(fun(R) ->
        {ok, 1} = ?G:create_vertex(R, #{}),                %% 建计数器
        ok = ?G:put_vertex(R, 100, <<"x">>),
        ?assertEqual({ok, 101}, ?G:create_vertex(R, #{})),
        ok = ?G:put_edge(R, 500, 7, 600),
        ?assertEqual({ok, 601}, ?G:create_vertex(R, #{})),
        ok = ?G:put_edges(R, [{2, 7, 3}, {1000, 7, 4}]),
        ?assertEqual({ok, 1001}, ?G:create_vertex(R, #{})),
        %% 低于水位的指定 id 不动水位
        ok = ?G:put_vertex(R, 50, <<"y">>),
        ?assertEqual({ok, 1002}, ?G:create_vertex(R, #{})),
        {atomic, ok} = ?G:transaction(R, fun(Tx) -> ?G:put_edge_txn(Tx, 2000, 7, 1) end),
        ?assertEqual({ok, 2001}, ?G:create_vertex(R, #{})),
        {atomic, ok} = ?G:transaction(R, fun(Tx) -> ?G:put_vertex_txn(Tx, 3000, <<"t">>) end),
        ?assertEqual({ok, 3001}, ?G:create_vertex(R, #{})),
        ok_inv(R)
    end).

counter_initialized_from_existing_ids_test() ->
    with_graph(fun(R) ->
        %% 从未自动分配过：指定 id 的写入不建计数器
        ok = ?G:put_vertex(R, 50, <<"v">>),
        ok = ?G:put_edge(R, 70, 7, 80),
        ok = ?G:put_edge(R, 3, 7, 4),
        ?assertEqual(absent, graphdb_model:read_counter(R)),
        ?assertEqual({ok, 80}, graphdb_model:max_vid(R)),
        ?assertEqual({ok, 81}, ?G:create_vertex(R, #{})),
        ?assertMatch({ok, 82, _}, graphdb_model:read_counter(R)),
        ok_inv(R)
    end).

max_vid_extremes_test() ->
    with_graph(fun(R) ->
        ?assertEqual({ok, none}, graphdb_model:max_vid(R)),
        ok = ?G:put_vertex(R, 0, <<"zero">>),
        ?assertEqual({ok, 0}, graphdb_model:max_vid(R)),
        ok = ?G:put_edge(R, 1, 7, ?VMAX),
        ?assertEqual({ok, ?VMAX}, graphdb_model:max_vid(R)),
        %% 计数器推到 2^64（9 字节编码装得下）后自动分配报 vid_exhausted
        ?assertEqual({error, vid_exhausted}, ?G:create_vertex(R, #{})),
        ok = ?G:put_vertex(R, 5, <<"still fine">>),
        ok_inv(R)
    end).

allocator_skips_occupied_ids_test() ->
    with_graph(fun(R) ->
        {ok, 1} = ?G:create_vertex(R, #{}),                %% 计数器 = 2
        %% 绕过图层直接占用 2（n 文档）与 3（邻接表头）——没推水位
        ok = bitcask:put(R, ?G:nkey(2), <<"raw">>),
        ok = bitcask:put(R, ?G:akey(3), <<1, 0, 0>>),
        ?assertEqual({ok, 4}, ?G:create_vertex(R, #{labels => [<<"L">>]})),
        ?assertEqual({ok, <<"raw">>}, ?G:get_vertex(R, 2)),
        ?assertEqual({ok, [4]}, ?G:vertices_by_label(R, <<"L">>))
    end).

concurrent_create_vertex_test_() ->
    {"16 个进程各建 50 个顶点：800 个 id 互不相同、连续，标签索引完整",
     {timeout, 120, fun() ->
        with_graph(fun(R) ->
            Me = self(),
            Pids = [spawn_link(fun() ->
                                   Ids = [begin {ok, V} = ?G:create_vertex(R, #{labels => [<<"C">>]},
                                                                           #{retries => infinity}),
                                                V end || _ <- lists:seq(1, 50)],
                                   Me ! {self(), Ids}
                               end) || _ <- lists:seq(1, 16)],
            All = lists:append([receive {P, Ids} -> Ids end || P <- Pids]),
            ?assertEqual(800, length(lists:usort(All))),
            ?assertEqual(lists:seq(1, 800), lists:sort(All)),
            ?assertEqual({ok, lists:seq(1, 800)}, ?G:vertices_by_label(R, <<"C">>)),
            ok_inv(R)
        end)
     end}}.

put_vertex_replaces_labels_test() ->
    with_graph(fun(R) ->
        ok = ?G:put_vertex(R, 10, #{labels => [<<"A">>, <<"B">>], props => #{k => 1}}),
        ?assertEqual({ok, [10]}, ?G:vertices_by_label(R, <<"A">>)),
        ok = ?G:put_vertex(R, 10, #{labels => [<<"B">>, <<"C">>], text => <<"body">>}),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"A">>)),
        ?assertEqual({ok, [10]}, ?G:vertices_by_label(R, <<"C">>)),
        ?assertEqual({ok, #{id => 10, labels => [<<"B">>, <<"C">>],
                            properties => #{<<"text">> => <<"body">>}}}, ?G:vertex(R, 10)),
        %% 引擎文档 map 的 meta 里带 `_labels` 也算标签
        ok = ?G:put_vertex(R, 11, #{text => <<>>,
                                    meta => bitcask:encode_meta(#{<<"_labels">> => [<<"A">>]})}),
        ?assertEqual({ok, [11]}, ?G:vertices_by_label(R, <<"A">>)),
        %% binary 覆盖：标签没了，索引项同批删掉
        ok = ?G:put_vertex(R, 10, <<"bare">>),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"B">>)),
        ?assertEqual({ok, #{id => 10, labels => [], properties => #{<<"text">> => <<"bare">>}}},
                     ?G:vertex(R, 10)),
        ok_inv(R)
    end).

set_remove_labels_test() ->
    with_graph(fun(R) ->
        {ok, V} = ?G:create_vertex(R, #{labels => [<<"A">>], props => #{n => 1}, text => <<"t">>}),
        ok = ?G:set_labels(R, V, [<<"B">>, <<"A">>]),
        ?assertEqual({ok, #{id => V, labels => [<<"A">>, <<"B">>],
                            properties => #{<<"n">> => 1, <<"text">> => <<"t">>}}}, ?G:vertex(R, V)),
        ok = ?G:remove_labels(R, V, [<<"A">>, <<"Z">>]),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"A">>)),
        ?assertEqual({ok, [V]}, ?G:vertices_by_label(R, <<"B">>)),
        ok = ?G:remove_labels(R, V, [<<"B">>]),
        ?assertMatch({ok, #{labels := [], properties := #{<<"n">> := 1}}}, ?G:vertex(R, V)),
        %% 悬挂端点（只有邻接表）：set_labels 给它建文档；不存在的顶点 → not_found
        ok = ?G:put_edge(R, 40, 7, 41),
        ok = ?G:set_labels(R, 41, [<<"D">>]),
        ?assertEqual({ok, #{id => 41, labels => [<<"D">>], properties => #{}}}, ?G:vertex(R, 41)),
        ?assertEqual({ok, #{id => 40, labels => [], properties => #{}}}, ?G:vertex(R, 40)),
        ?assertEqual({error, not_found}, ?G:set_labels(R, 999, [<<"D">>])),
        ok_inv(R)
    end).

delete_removes_label_index_test() ->
    with_graph(fun(R) ->
        {ok, A} = ?G:create_vertex(R, #{labels => [<<"P">>]}),
        {ok, B} = ?G:create_vertex(R, #{labels => [<<"P">>, <<"Q">>]}),
        {ok, C} = ?G:create_vertex(R, #{labels => [<<"Q">>]}),
        ok = ?G:put_edge(R, A, 7, B),
        ok = ?G:del_vertex(R, B),
        ?assertEqual({ok, [A]}, ?G:vertices_by_label(R, <<"P">>)),
        ?assertEqual({ok, [C]}, ?G:vertices_by_label(R, <<"Q">>)),
        {atomic, ok} = ?G:transaction(R, fun(Tx) -> ?G:del_vertex_txn(Tx, C) end),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"Q">>)),
        {atomic, ok} = ?G:transaction(R, fun(Tx) -> ?G:put_vertex_txn(Tx, A, <<"bare">>) end),
        ?assertEqual({ok, []}, ?G:vertices_by_label(R, <<"P">>)),
        ok_inv(R)
    end).

edge_props_map_test() ->
    with_graph(fun(R) ->
        ok = ?G:put_edge(R, 1, 7, 2, #{props => #{weight => 0.5, since => 2020}}),
        ok = ?G:put_edges(R, [{1, 7, 3, #{props => #{w => 1}}}, {1, 7, 4}]),
        ok = ?G:put_edge(R, 1, 7, 5, #{props => <<"legacy:1">>}),
        {ok, #{props := P2}} = ?G:edge(R, 1, 7, 2),
        ?assertEqual(#{<<"weight">> => 0.5, <<"since">> => 2020}, graphdb_model:decode_edge_props(P2)),
        {ok, #{props := P3}} = ?G:edge(R, 1, 7, 3),
        ?assertEqual(#{<<"w">> => 1}, graphdb_model:decode_edge_props(P3)),
        {ok, #{props := P4}} = ?G:edge(R, 1, 7, 4),
        ?assertEqual(#{}, graphdb_model:decode_edge_props(P4)),
        {ok, #{props := P5}} = ?G:edge(R, 1, 7, 5),
        ?assertEqual(#{<<"_raw">> => <<"legacy:1">>}, graphdb_model:decode_edge_props(P5))
    end).

validation_test() ->
    with_graph(fun(R) ->
        ?assertError({badarg, {reserved_property, <<"_x">>}},
                     ?G:create_vertex(R, #{props => #{<<"_x">> => 1}})),
        ?assertError({badarg, {unsupported_property_type, <<"m">>}},
                     ?G:create_vertex(R, #{props => #{m => #{a => 1}}})),
        %% 列表要元素同一种类型（[1, 2] 这类同类型列表可以存，见 opencypher_value_semantics_test）
        ?assertError({badarg, {unsupported_property_type, <<"l">>}},
                     ?G:create_vertex(R, #{props => #{l => [1, <<"a">>]}})),
        ?assertError({badarg, {label, <<>>}}, ?G:create_vertex(R, #{labels => [<<>>]})),
        ?assertError({badarg, {labels, x}}, ?G:create_vertex(R, #{labels => x})),
        ?assertError({badarg, {unsupported_property_type, <<"m">>}},
                     ?G:put_edge(R, 1, 7, 2, #{props => #{m => {1}}})),
        %% 什么都没写进去
        ?assertEqual(absent, graphdb_model:read_counter(R))
    end).

invariants_detect_model_damage_test() ->
    with_graph(fun(R) ->
        {ok, V} = ?G:create_vertex(R, #{labels => [<<"A">>]}),
        ok_inv(R),
        ok = bitcask:put(R, graphdb_model:lkey(<<"Ghost">>, V), <<>>),
        ?assertMatch({error, [{label_index_mismatch, [], [{<<"Ghost">>, V}]}]}, ?G:check_invariants(R)),
        ok = bitcask:delete(R, graphdb_model:lkey(<<"Ghost">>, V)),
        ok = bitcask:delete(R, graphdb_model:lkey(<<"A">>, V)),
        ?assertMatch({error, [{label_index_mismatch, [{<<"A">>, V}], []}]}, ?G:check_invariants(R)),
        ok = bitcask:put(R, graphdb_model:lkey(<<"A">>, V), <<>>),
        ok = bitcask:put(R, graphdb_model:ckey(), <<V:72/big>>),
        ?assertMatch({error, [{vid_counter_low, V, V}]}, ?G:check_invariants(R))
    end).

%% 扩展值编解码挂点：核心只存「文本 + `_types`」，值的含义由上层注册（bitcask_cypher 注册时间 / 空间值）
value_codec_test() ->
    Prev = graphdb_model:value_codec(),
    try
        with_graph(fun(R) ->
            graphdb_model:unregister_value_codec(),
            %% 没注册：扩展值写不进去
            ?assertError({badarg, {unsupported_property_type, <<"price">>}},
                         ?G:create_vertex(R, #{props => #{price => {money, 1234}}})),
            %% 注册后：单值与同类列表都能存能读
            ok = graphdb_model:register_value_codec(?MODULE),
            {ok, V} = ?G:create_vertex(R, #{props => #{price => {money, 1234}, hist => [{money, 5}, {money, 700}]}}),
            ?assertMatch({ok, #{properties := #{<<"price">> := {money, 1234}, <<"hist">> := [{money, 5}, {money, 700}]}}},
                         ?G:vertex(R, V)),
            %% 撤掉注册：按存储文本读出（数据照样兼容）
            graphdb_model:unregister_value_codec(),
            ?assertMatch({ok, #{properties := #{<<"price">> := <<"12.34">>, <<"hist">> := [<<"0.05">>, <<"7.00">>]}}},
                         ?G:vertex(R, V))
        end)
    after
        case Prev of
            undefined -> graphdb_model:unregister_value_codec();
            M -> graphdb_model:register_value_codec(M)
        end
    end.
