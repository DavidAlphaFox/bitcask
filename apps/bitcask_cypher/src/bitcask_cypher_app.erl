%% bitcask_cypher 应用：启动时把扩展值编解码注册给图层（graphdb_model）。没有常驻进程——
%% 用户过程 / 函数表在 persistent_term（bitcask_cypher_registry），查询在调用方进程里跑。
-module(bitcask_cypher_app).
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    ok = bitcask_cypher_values:ensure_registered(),
    supervisor:start_link({local, bitcask_cypher_sup}, ?MODULE, []).

stop(_State) -> ok.

init([]) -> {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, []}}.
