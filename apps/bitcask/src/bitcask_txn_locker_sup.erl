%% =========================================================================
%% bitcask_txn_locker_sup
%%
%%   事务锁管理器的分片 supervisor（bitcask_txn_locker 模块头 §"为什么分片"）。
%%   child：一个共享表持有者 + N 个分片，N 来自 application env
%%   {txn_locker_shards, N}（默认 8）。
%%
%%   one_for_all：分片之间的状态（共享 txns/held 表、跨分片的等待关系）
%%   没有独立重启的可能——任何一个死了，全部重来，锁表清零。持锁的事务
%%   下一次 acquire / check 会拿到 unknown_txn → 门面 {aborted, locker_restarted}。
%%
%%   ⚠️ 分片数不按 schedulers_online 推：开发机 BEAM 看到宿主 128 核。
%%   前缀锁要在每个分片上各拿一份（N 次 call），分片数别配得太大。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_txn_locker_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(DEFAULT_SHARDS, 8).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    N = case application:get_env(bitcask, txn_locker_shards) of
            {ok, S} when is_integer(S), S >= 1 -> S;
            undefined -> ?DEFAULT_SHARDS;
            {ok, Bad} -> erlang:error({bad_txn_locker_shards, Bad})
        end,
    Tables = {bitcask_txn_locker_tables,
              {bitcask_txn_locker, start_link, [{tables, N}]},
              permanent, 5000, worker, [bitcask_txn_locker]},
    Shards = [{{bitcask_txn_locker, I},
               {bitcask_txn_locker, start_link, [{shard, I}]},
               permanent, 5000, worker, [bitcask_txn_locker]}
              || I <- lists:seq(1, N)],
    {ok, {{one_for_all, 5, 10}, [Tables | Shards]}}.
