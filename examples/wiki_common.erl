%% wiki_common — Wikipedia dump 摄取 + 建库/查询的共享实现，供
%% wiki_hnsw.escript / wiki_diskann.escript 两个示例调用（二者只差
%% vector_engine）。
%%
%% 数据提取方案移植自 wiser-cpp（~/workspace/wiser/wiser-cpp/src/）：
%%   wiki_ingest.cpp — expat SAX 流式解析 <page><title> / <revision><text>，
%%       max_count 截断。这里用 xmerl_sax_parser 等价实现：14GB dump 不进
%%       内存，到达 -m 上限即 throw 终止解析。
%%   wiki_markup.cpp — 两遍清洗：结构剥离（模板/表格/HTML 标签/命名空间
%%       链接/URL）+ 空白折叠与超长 ASCII run 丢弃（防 >1024B 词元把整段
%%       索引拖垮，见 wiser libbitcask.md）。这里用正则近似移植：
%%       innermost-out 迭代消 {{模板}}/{|表格|}，其余同源逐条对应。
%%   indexer.cpp — key = 标题；正文进 text（BM25 主体）；标题进 fields
%%       （title 字段限定检索，index_catch_all 下也并入默认字段）；周期
%%       sync + auto_checkpoint_min_docs=10000 同值透传。
%%
%% 与 wiser-cpp 的有意差异：
%%   - 多一路向量：open 配 embedder（qwen3-embedding，2560 维），put 自动
%%     embed 正文 → BM25 + HNSW/DiskANN 双模式检索（这是本示例的目的）。
%%   - 跳过重定向页与清洗后过短的正文——每篇文档一次 embedding HTTP 调用，
%%     空页不值得花。
%%   - 无 crash-resume 文件（示例保持单次构建；周期 sync 仍保留）。
-module(wiki_common).
-export([main/2]).
%% 亦可作为库复用：SAX 摄取（parse_dump/4：Sink 收 (Title, CleanBody, Acc)）
%% 与示例的 open 选项（open_opts/2）。
-export([parse_dump/4, open_opts/2]).

%% embedding 端点不写死在代码里（避免把特定部署的内网地址误当成示例的一
%% 部分）：WIKI_EMBED_URL 必填；model/dim 有默认值、可用环境变量覆盖。
-define(ENV_URL, "WIKI_EMBED_URL").
-define(ENV_MODEL, "WIKI_EMBED_MODEL").
-define(ENV_DIM, "WIKI_EMBED_DIM").
-define(EMBED_MODEL_DEFAULT, "qwen3-embedding").
-define(EMBED_DIM_DEFAULT, "2560").
%% 只 embed 文章前 2KB（约 680 汉字）：百科文章主题集中在导语，全文（可达
%% 数百 KB）喂给 4B embedding 模型一是慢（实测 ~200 token/s，默认 32KB 会超
%% 30s 超时）、二是稀释主题向量。BM25 一路不受影响（全文进倒排）。
-define(EMBED_MAX_INPUT, 2048).
-define(EMBED_TIMEOUT_MS, 120000).
-define(DEFAULT_MAX_DOCS, 500).
-define(MIN_BODY_BYTES, 32).     %% 清洗后短于此的页跳过（多为消歧义/空壳页）
-define(MAX_ASCII_RUN, 64).      %% wiser-cpp kMaxAsciiRun 同值
-define(SYNC_EVERY, 200).        %% wiser kFlushEveryDocs=2000；embedding 慢得多，缩小
-define(PROGRESS_EVERY, 20).

%% wiser-cpp is_whole_drop_tag / is_dropped_namespace 的同源清单。
-define(DROP_TAGS,
        "ref|math|gallery|timeline|table|tr|td|th|source|syntaxhighlight|"
        "code|pre|nowiki|score|mapframe|maplink|templatestyles|imagemap|"
        "poem|hiero|chem").
-define(DROP_NS,
        "category|file|image|media|template|help|wikipedia|portal|special|"
        "talk|user|mediawiki|module|draft|book|wikt|wiktionary|commons|"
        "分类|文件|模板|帮助|图像|媒体|主题|特殊|讨论|用户|模块|维基百科").

%% =========================================================================
%% CLI
%% =========================================================================

main(Engine, ["index" | Rest]) ->
    case parse_index_args(Rest, #{max => ?DEFAULT_MAX_DOCS}) of
        #{dump := Dump, db := Db, max := Max} ->
            build(Engine, Dump, Db, Max);
        _ ->
            usage(Engine), halt(2)
    end;
main(Engine, ["query", Db, Text | Rest]) ->
    Mode = case Rest of
               ["--mode", M | _] -> list_to_atom(M);
               _ -> hybrid
           end,
    case lists:member(Mode, [bm25, vector, hybrid]) of
        true  -> query(Engine, Db, unicode:characters_to_binary(Text), Mode);
        false -> usage(Engine), halt(2)
    end;
main(Engine, _) ->
    usage(Engine), halt(2).

parse_index_args(["-x", Dump | Rest], Acc) ->
    parse_index_args(Rest, Acc#{dump => Dump});
parse_index_args(["-o", Db | Rest], Acc) ->
    parse_index_args(Rest, Acc#{db => Db});
parse_index_args(["-m", N | Rest], Acc) ->
    parse_index_args(Rest, Acc#{max => list_to_integer(N)});
parse_index_args([], Acc) ->
    Acc;
parse_index_args(_, _) ->
    error.

usage(Engine) ->
    io:format(
      "usage: wiki_~p.escript <command> [options]~n"
      "~n"
      "commands:~n"
      "  index -x <dump.xml> -o <db> [-m N]     从 Wikipedia dump 建库"
      "（默认 N=~p）~n"
      "  query <db> <text> [--mode bm25|vector|hybrid]   查询（默认 hybrid）~n"
      "~n"
      "环境变量（详见 examples/README.md）：~n"
      "  ~s   （必填）OpenAI 兼容 /v1/embeddings 端点~n"
      "  ~s （可选）模型名，默认 ~s~n"
      "  ~s   （可选）向量维度，默认 ~s~n",
      [Engine, ?DEFAULT_MAX_DOCS,
       ?ENV_URL, ?ENV_MODEL, ?EMBED_MODEL_DEFAULT, ?ENV_DIM,
       ?EMBED_DIM_DEFAULT]).

%% =========================================================================
%% open 选项 —— 两个示例唯一的差异点是 Engine（hnsw | diskann）
%% =========================================================================

%% 三种查询模式都需要 embedder 配置（bm25 不发 embedding 请求，但重开库
%% 时向量维度须与磁盘 meta 一致，维度由 embedder 提供），故 URL 恒必填。
embed_url() ->
    case os:getenv(?ENV_URL) of
        false ->
            io:format("环境变量 ~s 未设置。请指向一个 OpenAI 兼容的 "
                      "/v1/embeddings 端点，例如：~n"
                      "  export ~s=http://<host>:<port>/v1/embeddings~n",
                      [?ENV_URL, ?ENV_URL]),
            halt(2);
        Url ->
            Url
    end.

embed_model() ->
    list_to_binary(env_or(?ENV_MODEL, ?EMBED_MODEL_DEFAULT)).

embed_dim() ->
    list_to_integer(env_or(?ENV_DIM, ?EMBED_DIM_DEFAULT)).

env_or(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V     -> V
    end.

open_opts(Engine, ReadWrite) ->
    Base = [{analyzer, jieba},           %% zhwiki → jieba 分词（词典默认 priv/dict）
            {vector_engine, Engine},
            {embedder, {openai, #{url             => embed_url(),
                                  model           => embed_model(),
                                  dim             => embed_dim(),
                                  max_input_bytes => ?EMBED_MAX_INPUT,
                                  timeout_ms      => ?EMBED_TIMEOUT_MS}}},
            %% wiser cask_config.hpp kIndexAutoCkptMinDocs 同值：示例规模
            %% （数百篇）达不到阈值时 reopen 走全量重放（jieba 重分词 +
            %% 从数据日志重读向量，无 embedding 网络调用），秒级可接受。
            {auto_checkpoint_min_docs, 10000}],
    case ReadWrite of
        true  -> [read_write | Base];
        false -> Base
    end.

%% =========================================================================
%% index：SAX 流式摄取 → 清洗 → put（BM25 索引 + 自动 embed 向量）
%% =========================================================================

build(Engine, Dump, Db, Max) ->
    io:format("engine=~p  dump=~ts  db=~ts  max=~p~nembedding: ~s (~s, ~p 维)~n",
              [Engine, Dump, Db, Max, embed_url(), embed_model(), embed_dim()]),
    case bitcask:open(Db, open_opts(Engine, true)) of
        {error, Reason} ->
            io:format("cannot open ~ts: ~p~n", [Db, Reason]),
            halt(1);
        H ->
            T0 = erlang:monotonic_time(millisecond),
            Sink = fun(Title, Body, {N, Failed}) ->
                       sink_doc(H, Title, Body, N, Failed)
                   end,
            {Added, Failed} = parse_dump(Dump, Max, Sink, {0, 0}),
            ok = bitcask:sync(H),
            ok = bitcask:close(H),
            Secs = (erlang:monotonic_time(millisecond) - T0) / 1000,
            io:format("index done: ~p docs indexed, ~p failed, ~.1fs "
                      "(engine=~p)~n", [Added, Failed, Secs, Engine])
    end.

sink_doc(H, Title, Body, N, Failed) ->
    %% fields 是 map（NIF 方案 C：#{字段名 => 文本}，key/value 均 binary）。
    case bitcask:put(H, Title, #{text => Body,
                                 fields => #{<<"title">> => Title}}) of
        ok ->
            N1 = N + 1,
            N1 rem ?PROGRESS_EVERY =:= 0 andalso
                io:format("  indexed ~p docs (last: ~ts)~n", [N1, Title]),
            %% 数据日志落盘点（对应 wiser IndexingSink::flush 的 sync；
            %% resume 标记本示例不做）。
            N1 rem ?SYNC_EVERY =:= 0 andalso (ok = bitcask:sync(H)),
            {N1, Failed};
        {error, E} ->
            %% 多为 embedding 端点抖动；跳过该篇继续（与「无效则跳过」的
            %% 选项语义一致），最后汇总失败数。
            io:format("  put failed (~ts): ~p~n", [Title, E]),
            {N, Failed + 1}
    end.

%% -------------------------------------------------------------------------
%% SAX 状态机 —— 移植 wiser-cpp wiki_ingest.cpp 的 wikipedia_status
%% -------------------------------------------------------------------------

-record(w, {status = doc,     %% doc|page|title|ns|id|rev|text
            title = [],       %% iolist 累积（characters 可能分片到达）
            ns = [],          %% <ns> 命名空间号；"0" = 主命名空间（条目）
            body = [],
            n = 0,            %% 扫过的 <page> 数（含跳过；-m 计这个）
            max = -1,         %% 达到即终止（-1 = 不限）
            sink,             %% fun(Title, Body, Acc) -> Acc'
            sacc}).           %% sink 累积器

%% 到达 -m 上限时 event fun 以 erlang:error({wiki_done, W}) 终止解析：
%% 本 OTP 的 xmerl_sax_parser 会把 event fun 的 error 转成
%% {fatal_error, Reason} 返回值（throw 反而会被包装成解析器内部状态、
%% 以 function_clause 崩掉），这是 SAX 中途停止的唯一干净路径。
parse_dump(Dump, Max, Sink, Acc0) ->
    W0 = #w{max = Max, sink = Sink, sacc = Acc0},
    case xmerl_sax_parser:file(Dump, [{event_fun, fun sax_event/3},
                                      {event_state, W0}]) of
        {ok, #w{sacc = Acc}, _Rest} ->
            Acc;
        {fatal_error, {wiki_done, #w{sacc = Acc}}} ->
            Acc;
        {fatal_error, Reason} ->
            io:format("dump parse aborted: ~p~n", [Reason]),
            Acc0;
        {Tag, _Location, Reason, _EndTags, #w{sacc = Acc}} ->
            io:format("dump parse aborted (~p): ~p~n", [Tag, Reason]),
            Acc
    end.

sax_event({startElement, _, Name, _, _}, _Loc, W) ->
    start_el(Name, W);
sax_event({endElement, _, Name, _}, _Loc, W) ->
    end_el(Name, W);
sax_event({characters, S}, _Loc, #w{status = title, title = T} = W) ->
    W#w{title = [T, S]};
sax_event({characters, S}, _Loc, #w{status = ns, ns = N} = W) ->
    W#w{ns = [N, S]};
sax_event({characters, S}, _Loc, #w{status = text, body = B} = W) ->
    W#w{body = [B, S]};
sax_event(_Event, _Loc, W) ->
    W.

start_el("page", #w{status = doc} = W)      -> W#w{status = page, ns = []};
start_el("title", #w{status = page} = W)    -> W#w{status = title, title = []};
start_el("ns", #w{status = page} = W)       -> W#w{status = ns, ns = []};
start_el("id", #w{status = page} = W)       -> W#w{status = id};
start_el("revision", #w{status = page} = W) -> W#w{status = rev};
start_el("text", #w{status = rev} = W)      -> W#w{status = text, body = []};
start_el(_, W)                              -> W.

end_el("page", #w{status = page} = W)       -> W#w{status = doc};
end_el("title", #w{status = title} = W)     -> W#w{status = page};
end_el("ns", #w{status = ns} = W)           -> W#w{status = page};
end_el("id", #w{status = id} = W)           -> W#w{status = page};
end_el("revision", #w{status = rev} = W)    -> W#w{status = page};
end_el("text", #w{status = text} = W0) ->
    W1 = emit_page(W0#w{status = rev}),
    W2 = W1#w{n = W1#w.n + 1},
    case W2#w.max >= 0 andalso W2#w.n >= W2#w.max of
        true  -> erlang:error({wiki_done, W2});
        false -> W2
    end;
end_el(_, W) ->
    W.

%% 一篇 <page> 解析完成：清洗正文并交给 sink。跳过非主命名空间页（ns≠0：
%% Wikipedia:/Help:/Template: 等元页面，早期 page id 区大量巨型删除纪录
%% 档案）、重定向页、清洗后过短的页（见文件头「有意差异」——每篇一次
%% embedding 调用，垃圾页不值得花）。
emit_page(#w{title = TAcc, ns = NsAcc, body = BAcc,
             sink = Sink, sacc = SAcc} = W) ->
    Ns = string:trim(unicode:characters_to_binary(NsAcc)),
    Raw = unicode:characters_to_binary(BAcc),
    case Ns =/= <<"0">> orelse is_redirect(Raw) of
        true ->
            W;
        false ->
            Title = unicode:characters_to_binary(TAcc),
            Body = strip_wiki_markup(Raw),
            case byte_size(Body) < ?MIN_BODY_BYTES of
                true  -> W;
                false -> W#w{sacc = Sink(Title, Body, SAcc)}
            end
    end.

is_redirect(Raw) ->
    re:run(Raw, "^\\s*#(redirect|重定向)",
           [caseless, unicode, {capture, none}]) =:= match.

%% -------------------------------------------------------------------------
%% wiki 标记清洗 —— wiser-cpp wiki_markup.cpp 的正则近似移植。
%% 遍序：注释 → 整体丢弃标签 → 模板/表格 → 链接 → URL → 引号 → 残余标签
%% → 标记标点 → 折叠与超长 run 防护（与 strip_structure/collapse_and_guard
%% 两遍对应）。
%% -------------------------------------------------------------------------

strip_wiki_markup(Raw) ->
    B1 = re_sub(Raw, "(?s)<!--.*?-->"),
    B2 = re_sub(B1, "(?si)<(" ?DROP_TAGS ")\\b[^>]*?>.*?</\\1\\s*>"),
    B3 = strip_braces(B2, 12),
    B4 = re:replace(B3, "\\[\\[\\s*:?\\s*(?:" ?DROP_NS ")\\s*:[^\\]]*\\]\\]",
                    " ", [global, caseless, unicode, {return, binary}]),
    B5 = re:replace(B4, "\\[\\[[^\\[\\]|]*\\|([^\\[\\]]*?)\\]\\]", " \\1 ",
                    [global, unicode, {return, binary}]),
    B6 = re:replace(B5, "\\[\\[([^\\[\\]]*?)\\]\\]", " \\1 ",
                    [global, unicode, {return, binary}]),
    B7 = re_sub(B6, "(?i)(?:https?|ftp)://[^\\s\\]|<>}]+"),
    B8 = re_sub(B7, "(?i)\\bwww\\.[^\\s\\]|<>}]+"),
    B9 = re_sub(B8, "''+"),
    B10 = re_sub(B9, "(?s)</?[a-zA-Z][^>]*>"),
    B11 = re_sub(B10, "[{}\\[\\]|=*#<>]"),
    collapse_and_guard(B11).

re_sub(Bin, Pattern) ->
    re:replace(Bin, Pattern, " ", [global, unicode, {return, binary}]).

%% {{模板}} / {|表格|}：正则不识别嵌套，由内向外迭代消除；轮次封顶后残余
%% 花括号由标记标点遍归一为空格（wiser-cpp 用单遍花括号深度计数，此处等价）。
strip_braces(Bin, 0) ->
    Bin;
strip_braces(Bin, Round) ->
    Pattern = "\\{\\{[^{}]*\\}\\}|\\{\\|[^{}]*\\|\\}",
    case re:run(Bin, Pattern, [{capture, none}]) of
        nomatch -> Bin;
        match   -> strip_braces(re_sub(Bin, Pattern), Round - 1)
    end.

%% 折叠空白 + 丢弃 >64B 的纯 ASCII run（URL/标识符残渣才会到这个长度；
%% CJK 是多字节、永不计入，中文文本不受影响）——wiser-cpp collapse_and_guard。
collapse_and_guard(Bin) ->
    Toks = binary:split(Bin, [<<" ">>, <<"\t">>, <<"\n">>, <<"\r">>,
                              <<"\f">>, <<"\v">>], [global, trim_all]),
    Keep = [T || T <- Toks,
                 not (byte_size(T) > ?MAX_ASCII_RUN andalso all_ascii(T))],
    iolist_to_binary(lists:join(<<" ">>, Keep)).

all_ascii(<<C, Rest/binary>>) when C < 16#80 -> all_ascii(Rest);
all_ascii(<<>>)                              -> true;
all_ascii(_)                                 -> false.

%% =========================================================================
%% query：BM25 / 向量 / 混合三种模式（引擎须与建库一致，否则 mode_mismatch）
%% =========================================================================

query(Engine, Db, Text, Mode) ->
    case bitcask:open(Db, open_opts(Engine, false)) of
        {error, Reason} ->
            io:format("cannot open ~ts: ~p~n", [Db, Reason]),
            halt(1);
        H ->
            Res = case Mode of
                      bm25   -> bitcask:search_text(H, Text, 10);
                      vector -> bitcask:search_vector(H, {text, Text}, 10);
                      hybrid -> bitcask:search_hybrid(H, Text)
                  end,
            case Res of
                {ok, Hits} ->
                    [print_hit(H, Hit) || Hit <- Hits],
                    io:format("Total ~p documents found (mode=~p, engine=~p).~n",
                              [length(Hits), Mode, Engine]);
                {error, E} ->
                    io:format("query failed: ~p~n", [E])
            end,
            ok = bitcask:close(H)
    end.

%% key 即标题（indexer.cpp 同款约定）；get 取回存储的正文做摘要预览
%% （doc 记录的 get 返回 #{text => 正文, meta => ...} map）。
print_hit(H, {Key, _Ord, Score}) ->
    io:format("score: ~.4f  title: ~ts~n", [Score * 1.0, Key]),
    case bitcask:get(H, Key) of
        {ok, #{text := Body}} when is_binary(Body) ->
            io:format("    ~ts~n", [string:slice(Body, 0, 80)]);
        _ ->
            ok
    end.
