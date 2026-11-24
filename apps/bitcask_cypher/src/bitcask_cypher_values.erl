%% =========================================================================
%% bitcask_cypher_values — 图层（graphdb_model）的扩展值编解码：Cypher 的时间 / 空间值与 NaN / Infinity
%%
%%   graphdb_model:register_value_codec/1 的回调模块。核心只存「文本 + `_types` 类型标记」，
%%   值的含义在这里：时间 / 空间值走 bitcask_cypher_temporal，浮点特殊值走 bitcask_cypher_ieee。
%%   bitcask_cypher 应用启动、以及每个入口（q / prepare / cursor …）第一次调用时注册（幂等）。
%% =========================================================================
-module(bitcask_cypher_values).

-export([ensure_registered/0, is_value/1, type_tag/1, to_text/1, from_text/2]).

-spec ensure_registered() -> ok.
ensure_registered() -> graphdb_model:register_value_codec(?MODULE).

is_value(V) when is_tuple(V) -> bitcask_cypher_temporal:is_value(V);
is_value(V) -> bitcask_cypher_ieee:is_special(V).

type_tag(V) when is_tuple(V) -> bitcask_cypher_temporal:type_tag(V);
type_tag(_) -> <<"float">>.

to_text(V) when is_tuple(V) -> bitcask_cypher_temporal:to_text(V);
to_text(V) -> bitcask_cypher_ieee:text(V).

from_text(<<"float">>, Text) -> bitcask_cypher_ieee:to_float(Text);
from_text(Tag, Text) -> bitcask_cypher_temporal:from_text(Tag, Text).
