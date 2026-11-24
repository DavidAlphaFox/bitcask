%% NIF 卸载（on_unload）回归：在独立的 peer 节点里 purge bitcask_cpp_nifs 再重载。
%%
%% on_unload 删 PrivData（join 索引池线程），再按 libbitcask 6.7.0 bitcask_shutdown
%% 的步骤 release_search_arena + tbb::finalize（nothrow）。放 peer 节点是因为
%% purge 会让本节点上其它测试的 NIF 全部失效。
%%
%% 只断言能断言的：卸载后索引池线程退出（线程数回到基线）、重载后照常可用。
%% ⚠️ 不断言 TBB worker 退出：跑过 TBB 并行段的 dirty 调度线程常驻，finalize
%% 多半失败（实测短语检索候选 ≥ 2048 后卸载，worker 留着）；Linux 上 .so 也不会
%% 真被 dlclose 掉（libstdc++ 的 GNU_UNIQUE 符号让 glibc 把它标成 NODELETE）。
-module(bitcask_nif_unload_tests).

-include_lib("eunit/include/eunit.hrl").

-export([threads/0, work/1, unload/0, reload/0]).

unload_reload_test_() ->
    {timeout, 120,
     {"purge bitcask_cpp_nifs：索引池线程退出、重载后照常读写检索",
      fun() ->
          bitcask_test_util:with_dir("nif_unload", fun(D) ->
              Paths = lists:usort([filename:dirname(code:which(M))
                                   || M <- [bitcask, ?MODULE, bitcask_test_util]]),
              {ok, Peer, _Node} = peer:start_link(
                  #{connection => standard_io,
                    args => lists:append([["-pa", P] || P <- Paths])}),
              try
                  T0 = peer:call(Peer, ?MODULE, threads, []),
                  ?assertEqual(3, peer:call(Peer, ?MODULE, work, [filename:join(D, "a")], 60000)),
                  ?assert(peer:call(Peer, ?MODULE, threads, []) > T0),
                  ok = peer:call(Peer, ?MODULE, unload, [], 30000),
                  ?assertEqual(T0, peer:call(Peer, ?MODULE, threads, [])),
                  ok = peer:call(Peer, ?MODULE, reload, []),
                  ?assertEqual(3, peer:call(Peer, ?MODULE, work, [filename:join(D, "b")], 60000))
              after
                  peer:stop(Peer)
              end
          end)
      end}}.

%% 以下在 peer 节点上跑。

threads() ->
    length(filelib:wildcard("/proc/" ++ os:getpid() ++ "/task/*")).

work(D) ->
    R = bitcask:open(D, [read_write, {analyzer, whitespace}]),
    ok = bitcask:put(R, <<"d1">>, #{text => <<"alpha beta">>}),
    ok = bitcask:put(R, <<"d2">>, #{text => <<"alpha gamma">>}),
    ok = bitcask:put(R, <<"d3">>, #{text => <<"alpha delta">>}),
    {ok, Hits} = bitcask:search_text(R, <<"alpha">>, 10),
    bitcask:close(R),
    length(Hits).

%% ERTS 等库的全部资源释放后才调 on_unload：先 GC 掉残留的资源引用。
unload() ->
    gc_all(),
    true = code:delete(bitcask_cpp_nifs),
    _ = code:purge(bitcask_cpp_nifs),
    gc_all(),
    wait_threads_settle(threads(), 50).

reload() ->
    {module, bitcask_cpp_nifs} = code:ensure_loaded(bitcask_cpp_nifs),
    ok.

gc_all() ->
    [erlang:garbage_collect(P) || P <- processes()],
    ok.

%% join 是同步的，但留点余量给线程从 /proc 消失。
wait_threads_settle(_, 0) -> ok;
wait_threads_settle(Prev, N) ->
    timer:sleep(20),
    case threads() of
        Prev -> ok;
        Now -> wait_threads_settle(Now, N - 1)
    end.
