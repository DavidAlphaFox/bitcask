#!/usr/bin/env escript
%% wiki_hnsw — 用 zhwiki dump 构建 BM25 + HNSW（内存图向量引擎，默认档）
%% 检索库的示例。数据提取方案移植自 wiser-cpp；共享实现在 wiki_common.erl，
%% 本文件只绑定 vector_engine=hnsw。用法见 examples/README.md。

main(Args) ->
    load_common(),
    wiki_common:main(hnsw, Args).

%% escript 间无法共享代码：把 bitcask 的 ebin 加进 code path，再运行时
%% 编译加载同目录的 wiki_common.erl（wiki_diskann.escript 同款 bootstrap）。
load_common() ->
    Dir = filename:dirname(filename:absname(escript:script_name())),
    Ebin = filename:join([Dir, "..", "_build", "default", "lib",
                          "bitcask", "ebin"]),
    case code:add_pathz(Ebin) of
        true -> ok;
        _ ->
            io:format("bitcask 未构建：先在仓库根目录跑 `rebar3 compile`~n"),
            halt(1)
    end,
    Src = filename:join(Dir, "wiki_common.erl"),
    {ok, Mod, Bin} = compile:file(Src, [binary, report]),
    {module, Mod} = code:load_binary(Mod, Src, Bin),
    ok.
