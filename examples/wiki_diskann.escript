#!/usr/bin/env escript
%% wiki_diskann — 用 zhwiki dump 构建 BM25 + DiskANN（Vamana 盘上图向量引擎，
%% v4.0.0 实验性）检索库的示例。数据提取方案移植自 wiser-cpp；共享实现在
%% wiki_common.erl，本文件只绑定 vector_engine=diskann。用法见
%% examples/README.md。
%%
%% ⚠️ diskann 在 libbitcask v4.0.0 定级为实验性（真实语料验证前不建议生产），
%% 本示例正是它的一个真实语料验证场景。要求 cosine/dot 度量（默认 cosine 即可）。

main(Args) ->
    load_common(),
    wiki_common:main(diskann, Args).

%% escript 间无法共享代码：把 bitcask 的 ebin 加进 code path，再运行时
%% 编译加载同目录的 wiki_common.erl（wiki_hnsw.escript 同款 bootstrap）。
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
