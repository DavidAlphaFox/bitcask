%% =========================================================================
%% bitcask 模块
%%
%%   bitcask 数据库的对外门面（facade）。统一架构后所有 API 通过单一引擎
%%   提供：open 时传入 {analyzer, ...} 选项即可启用全文索引模式，之后
%%   put 写入的数据自动生成 BM25 索引，search_text/search_phrase 直接
%%   在同一个 Ref 上调用。
%%
%%   Erlang 层只做三件事：
%%     1. 选项归一化（opt_value/2 处理 Opts > app env > undefined 的优先级）；
%%     2. 把 bitcask_cpp_nifs:cask_iterator/cask_fold_* 返回的元组重新组装成
%%        历史外部接口里出现的 #bitcask_entry 记录，保持调用方的兼容性；
%%     3. 把 fold/6、fold_keys/6 里历史遗留的 µs/ms 单位换算成 cask_cpp 期望
%%        的「秒」（cask_max_age/1）和「次数」（cask_max_put/1）。
%%
%%   open/2 返回 {Ref, EmbedderCtx}：Ref 是 cask_cpp 资源句柄，EmbedderCtx
%%   是 open 时配置的 embedder context（undefined | map()）。BEAM 持有 Ref 的
%%   强引用；GC 时由 cask_resource_dtor 析构。close/1 会立刻释放底层 Cask（不等 GC）。
%%
%%   KV 模式（默认）：put(Ref, Key, BinaryValue)，不支持 search_*。
%%   索引模式：open 时带 {analyzer, ngram|whitespace|jieba}，put 可传
%%     binary 或 #{text => binary(), meta => binary()}，支持 search_text/phrase。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask).

-export([open/1, open/2,
         close/1,
         close_write_file/1,
         get/2,
         put/3,
         delete/2,
         sync/1,
         list_keys/1,
         fold_keys/3, fold_keys/6,
         fold/3, fold/6,
         stream_fold/3, stream_fold/4,
         stream/1, next/1, stop/1, with_stream/2,
         merge/1, merge/2, merge/3,
         needs_merge/1,
         needs_merge/2,
         is_frozen/1,
         is_empty_estimate/1,
         status/1,
           search_text/2, search_text/3, search_text/4,
           search_phrase/2, search_phrase/3,
           search_fields/2, search_fields/3,
           search_near/3, search_near/4,
           search_fuzzy/3, search_fuzzy/4,
           search_wildcard/2, search_wildcard/3,
           search_vector/2, search_vector/3, search_vector/4, search_vector/5,
           search_hybrid/3, search_hybrid/4, search_hybrid/5,
           encode_meta/1,
           set_synonym_map/2]).

-include("bitcask.hrl").

%% cask_cpp NIF 能识别的选项白名单。Opts 里其它键会被静默丢弃
%% （legacy 时代就是这个语义，新代码沿用以免破坏现有调用方）。
-define(CASK_PASSTHROUGH_OPTS, [
    expiry_secs, max_file_size,
    sync_strategy,
    tombstone_version,
    frag_merge_trigger, dead_bytes_merge_trigger,
    frag_threshold, dead_bytes_threshold,
    small_file_threshold, expiry_grace_time,
    max_merge_size,
    analyzer, dict_path, enable_stop_words,
    min_n, max_n, min_token_length, enable_stemming,
    vector_dim, vector_metric
]).

%% =========================================================================
%% open / close
%% =========================================================================

%% 默认无选项打开（只读模式）。
open(Dirname) -> open(Dirname, []).

%% 在 Dirname 目录上开一个 Cask；返回的 Ref 是 cask_cpp 资源句柄。
%%
%%   Opts 关键项：
%%     read_write           — 写权限；竞争 bitcask.write.lock
%%     {expiry_secs, N}     — N 秒前的 entry 视作过期
%%     {max_file_size, N}   — 写满 N 字节切下一个 active data file
%%     {sync_strategy, X}   — none | o_sync | {seconds, N}
%%     {tombstone_version, V} — 1 或 2，控制墓碑编码（默认 2）
%%
%%   索引模式选项（传入即启用全文搜索）：
%%     {analyzer, Type}     — ngram | whitespace | jieba（必填）
%%     {dict_path, Path}    — jieba 分词词典路径（jieba 时必填）
%%     {enable_stop_words, true} — 启用停用词过滤
%%
%%   向量模式选项：
%%     {vector_dim, N}      — 向量维度（必填）
%%     {vector_metric, M}   — cosine | l2 | dot（默认 cosine）
%%     {embedder, Ctx}      — bitcask_embedder:ctx()，配置后 put
%%                            #{text => ...} 自动 embed 生成向量，
%%                            无需外部计算。显式传 vector 键时跳过。
%%
%%   索引模式的 put 可接受 binary 或 #{text => binary(), meta => binary()}。
%%   配置 embedder 后 put #{text => binary()} 会自动 embed。
%%   索引模式下调 search_text/search_phrase 进行 BM25 检索。
%%
%%   返回:
%%     {reference(), term()} — 成功：{CaskRef, EmbedderCtx}
%%     {error, Reason}      — 通常是 write_locked / enoent / mode_mismatch
-spec open(Dirname::string(), Opts::[_]) -> {reference(), term()} | {error, term()}.
open(Dirname, Opts) ->
    catch application:load(bitcask),
    catch application:start(bitcask),
    EmbedderCtx = proplists:get_value(embedder, Opts),
    Base = case proplists:get_bool(read_write, Opts) of
               true  -> [read_write];
               false -> []
           end,
    Extra0 = [{K, V} || K <- ?CASK_PASSTHROUGH_OPTS,
                        (V = opt_value(K, Opts)) =/= undefined],
    Extra = maybe_default_dict_path(Extra0),
    case bitcask_cpp_nifs:cask_open(Dirname, Base ++ Extra) of
        {ok, CaskRef}  -> {CaskRef, EmbedderCtx};
        {error, _} = E -> E
    end.

%% analyzer=jieba 且未显式指定 dict_path 时，默认指向 priv/dict
%% （构建时由 CMake 把 cppjieba 词典拷到此处）。其它分词器或已显式
%% 给了 dict_path 时原样返回。
maybe_default_dict_path(Opts) ->
    case proplists:get_value(analyzer, Opts) of
        jieba ->
            case proplists:is_defined(dict_path, Opts) of
                true  -> Opts;
                false ->
                    case code:priv_dir(bitcask) of
                        {error, _} -> Opts;
                        Dir ->
                            %% NIF 侧 dict_path 走 enif_inspect_binary，必须是 binary。
                            Path = filename:join(Dir, "dict"),
                            [{dict_path, list_to_binary(Path)} | Opts]
                    end
            end;
        _ -> Opts
    end.

%% 选项查询的统一入口：显式 Opts > application env > undefined。
opt_value(Key, Opts) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(bitcask, Key) of
                {ok, V} -> V;
                _       -> undefined
            end;
        V -> V
    end.

%% 从 handle tuple 提取原始 NIF reference。
ref({R, _Ctx}) -> R.

%% 关闭 Cask：刷盘、释放 write.lock、清空 keydir。Handle 之后不可再用。
close(Handle) ->
    bitcask_cpp_nifs:cask_close(ref(Handle)).

%% 把当前 active 数据文件的 hint trailer 写完整、释放 bitcask.write.lock，
%% 但 Ref 仍然可用：下一次 put/delete 会自动重新拿锁、新建 active file。
%% 这中间的窗口里别的进程可能抢占 writer 角色——这是 legacy 历史行为，
%% 调用方需要清楚后果。
close_write_file(Handle) ->
    bitcask_cpp_nifs:cask_close_write_file(ref(Handle)).

%% =========================================================================
%% 单 key 读写
%% =========================================================================

%% 读 Key。返回 {ok, Value} | not_found | {error, Reason}。
%% 过期或被墓碑覆盖的 entry 等同于 not_found。
get(Handle, Key) ->
    bitcask_cpp_nifs:cask_get(ref(Handle), Key).

%% 写 Key。put(_, _, tombstone) 是历史接口，等价于 delete。
%%
%% 自动 embed：当 open 时配置了 {embedder, Ctx}，且 put 的 Value 是
%% #{text => Text}（有 text 无 vector），会自动调用 embedder 生成向量，
%% 然后以 #{text => Text, vector => Vec} 写入。显式提供 vector 时跳过。
put(Handle, Key, tombstone) ->
    bitcask_cpp_nifs:cask_delete(ref(Handle), Key);
put({Ref, Ctx}, Key, #{text := Text} = Doc) when is_binary(Text) ->
    case Ctx of
        undefined ->
            bitcask_cpp_nifs:cask_put(Ref, Key, Doc);
        _ when not is_map_key(vector, Doc) ->
            case bitcask_embedder:embed(Ctx, Text) of
                {ok, Vec} ->
                    bitcask_cpp_nifs:cask_put(Ref, Key, Doc#{vector => Vec});
                {error, _} = E ->
                    E
            end;
        _ ->
            bitcask_cpp_nifs:cask_put(Ref, Key, Doc)
    end;
put(Handle, Key, Value) ->
    bitcask_cpp_nifs:cask_put(ref(Handle), Key, Value).

%% 软删除：写一个墓碑 entry。空间在下一次 merge 时回收。
delete(Handle, Key) ->
    bitcask_cpp_nifs:cask_delete(ref(Handle), Key).

%% fsync 当前 active data file（hintfile 不强制 fsync——hint 丢了
%% 可以从 data file 重建）。{sync_strategy, o_sync} 模式下 put 已经
%% O_SYNC 写入，sync 退化为 no-op。
sync(Handle) ->
    bitcask_cpp_nifs:cask_sync(ref(Handle)).

%% =========================================================================
%% 折叠 / 列举
%%
%% 这一族函数全部建立在单条 cask_fold_* 迭代器之上：
%%   cask_fold_start    — 开始迭代（拿快照）
%%   cask_fold_next     — 取下一项（K, V）
%%   cask_fold_next_full— 取下一项（K, V, FileId, Offset, Sz, Tstamp, IsTomb）
%%   cask_fold_release  — 释放迭代器
%%
%% 迭代是基于 keydir 的快照，不会看见迭代开始之后的写入；底层用 epoch
%% 实现，参见 cpp/src/keydir/keydir.cpp。
%% =========================================================================

%% 列出全部活跃 key，顺序未定义。墓碑被过滤。
list_keys(Handle) ->
    cask_fold_collect(ref(Handle), fun(K, _V, Acc) -> [K | Acc] end, []).

%% fold_keys/3：回调签名 fun(#bitcask_entry{}, Acc) -> Acc'
fold_keys(Handle, Fun, Acc0) ->
    cask_fold_keys_collect(ref(Handle), Fun, Acc0).

%% fold_keys/6：兼容 legacy 6 参版本。
%%   MaxAge          — 微秒；负数表示无上限
%%   MaxPut          — 这次 fold 期间允许的写入次数上限；超了则拒绝
%%   SeeTombstonesP  — true 时墓碑以 {tombstone, BCEntry} 的形式上交回调
fold_keys(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    cask_fold_keys6_collect(ref(Handle), Fun, Acc0,
                            cask_max_age(MaxAge), cask_max_put(MaxPut),
                            SeeTombstonesP).

%% fold/3：回调签名 fun(K, V, Acc) -> Acc'
fold(Handle, Fun, Acc0) ->
    cask_fold_collect(ref(Handle), Fun, Acc0).

%% fold/6：MaxAge / MaxPut 含义同 fold_keys/6；SeeTombstones=true 时墓碑
%% 以 {tombstone, K} 的 key 形态上交，V 是墓碑值（通常是空 binary）。
fold(Handle, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    cask_fold6_collect(ref(Handle), Fun, Acc0,
                       cask_max_age(MaxAge), cask_max_put(MaxPut),
                       SeeTombstonesP).

%% =========================================================================
%% 流式迭代（替代旧的 iterator/3 + iterator_next/1 + iterator_release/1）
%%
%%   stream(Ref)         开一个 producer 进程，返回 StreamRef
%%   next(StreamRef)     拉一条；{ok, K, V} | done | {error, _}
%%   stop(StreamRef)     显式结束；幂等
%%   with_stream(Ref, F) 作用域包装，自动 stop
%%
%% 同 Ref 上可以同时开多个 stream（每个 producer 持独立 IterRef）。
%% Producer 在消费者崩溃时通过 monitor 自动清理 cask_fold_release。
%% 实现细节见 bitcask_stream 模块。
%% =========================================================================

stream(Handle) -> bitcask_stream:stream(ref(Handle)).

next(S) -> bitcask_stream:next(S).

stop(S) -> bitcask_stream:stop(S).

with_stream(Handle, Fun) -> bitcask_stream:with_stream(ref(Handle), Fun).

%% =========================================================================
%% 目录级 merge
%%
%% bitcask:merge/N 在 Dirname 上临时打开一个 read_write Cask，跑一次合并
%% 然后关闭。关键参数 {merge_only, true}：让合并器去拿 bitcask.merge.lock
%% 而不是 bitcask.write.lock，于是「正在写」的 writer 不会被合并阻塞。
%% 但如果有别的 merger 已经持有 merge.lock，会返回
%%   {error, {merge_locked, Reason, Dirname}}.
%%
%% 注：如果调用方手里已经有一个 writer Ref，绕开这个临时 open 更高效——
%% 直接调底层 NIF：
%%
%%     {true, {Files, _}} = bitcask:needs_merge(R),
%%     bitcask_cpp_nifs:cask_merge(R, Files).
%% =========================================================================

merge(Dirname) -> merge(Dirname, []).

%% merge/2：扫描整个目录，由 cask 自己根据阈值挑要合并的文件。
merge(Dirname, Opts) ->
    cask_merge_dir(Dirname, Opts, all).

%% merge/3：调用方给定要合并的文件列表（绝对路径）。
%% Files 也支持 legacy 形态 {Files, Expired} 二元组——expired 部分忽略。
merge(Dirname, Opts, FilesToMerge) ->
    cask_merge_dir(Dirname, Opts, FilesToMerge).

cask_merge_dir(Dirname, Opts, FilesArg) ->
    OpenOpts = [merge_only | cask_open_opts(Opts)],
    case bitcask_cpp_nifs:cask_open(Dirname, OpenOpts) of
        {ok, R} ->
            try cask_merge_run(R, FilesArg)
            after bitcask_cpp_nifs:cask_close(R)
            end;
        {error, write_locked} ->
            %% 这条路径目前用 write_locked 作为「拿不到 merge.lock」的
            %% 信号——legacy 沿用的 atom 名，没改是为了不破坏现有匹配。
            {error, {merge_locked,
                     "another merger is already running on this dir",
                     Dirname}};
        {error, _} = E ->
            E
    end.

%% all：让 cask_needs_merge 决定该并哪些文件
%% {Files, _Expired}：legacy 形态二元组，第二个元素被丢弃
%% [Files]：调用方指定的文件名列表
cask_merge_run(R, all) ->
    case bitcask_cpp_nifs:cask_needs_merge(R) of
        false                   -> ok;
        {true, Files, _Expired} -> cask_merge_call(R, Files)
    end;
cask_merge_run(R, {Files, _Expired}) when is_list(Files) ->
    cask_merge_call(R, Files);
cask_merge_run(R, Files) when is_list(Files) ->
    cask_merge_call(R, Files).

%% 空列表早退；非空才进 NIF。
cask_merge_call(_R, []) -> ok;
cask_merge_call(R, Files) ->
    case bitcask_cpp_nifs:cask_merge(R, Files) of
        {ok, _Stats}   -> ok;
        {error, _} = E -> E
    end.

%% 给「临时 merge open」用的选项构造：强制 read_write，再带上调用方给的
%% 阈值（frag_threshold 之类，用来决定要并什么）。
cask_open_opts(Opts) ->
    Base = [read_write],
    Extra = [{K, V} || K <- ?CASK_PASSTHROUGH_OPTS,
                       (V = opt_value(K, Opts)) =/= undefined],
    Base ++ Extra.

%% =========================================================================
%% 杂项查询
%% =========================================================================

needs_merge(Handle) -> needs_merge(Handle, []).

%% Opts 在新接口里没有任何作用——保留参数仅为兼容旧调用点。返回值跟
%% legacy 一样保留 {true, {Files, Expired}} 的二元组，方便 needs_merge 的
%% 结果直接喂给 merge/3。
needs_merge(Handle, _Opts) ->
    case bitcask_cpp_nifs:cask_needs_merge(ref(Handle)) of
        false                  -> false;
        {true, Files, Expired} -> {true, {Files, Expired}}
    end.

%% keydir 是否处于 frozen 状态（fold 在跑）。
is_frozen(Handle) ->
    bitcask_cpp_nifs:cask_is_frozen(ref(Handle)).

%% O(1) 估算：keydir 是否为空。打开过空目录之后会返回 true；写过任何 key
%% 之后立刻 false（即使 key 又被删，估算仍认为非空——这是可以接受的近似）。
is_empty_estimate(Handle) ->
    bitcask_cpp_nifs:cask_is_empty(ref(Handle)).

%% 返回 {KeyCount, FilesInfo}，跟 legacy 形状一致。底层 NIF 还会返回
%% KBytes 和 Epoch，这两个值 facade 层不外露——历史接口就只有 2 元组。
status(Handle) ->
    {KCount, _KBytes, _Epoch, Files} = bitcask_cpp_nifs:cask_status(ref(Handle)),
    {KCount, Files}.

%% =========================================================================
%% 内部：cask 迭代器收集器 + 单位换算
%% =========================================================================

%% 通用「打开迭代器 → 循环收集 → 兜底释放」骨架。Fun 是
%% fun(K, V, Acc) -> Acc'。任何 NIF 错误会原样返回（不抛异常）。
cask_fold_collect(Ref, Fun, Acc0) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1) of
        {ok, IterRef} ->
            try cask_fold_loop(IterRef, Fun, Acc0)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_loop(IterRef, Fun, Acc) ->
    case bitcask_cpp_nifs:cask_fold_next(IterRef) of
        done            -> Acc;
        {ok, K, V}      -> cask_fold_loop(IterRef, Fun, Fun(K, V, Acc));
        {error, _} = E  -> E
    end.

%% fold_keys/3 用：每条记录都重新组装一个 #bitcask_entry，把 file_id /
%% offset / total_sz / tstamp 全部填上真实值（不像有些后端会塞 0 占位）。
%% 因为是 fold_keys/3，see_tombstones 默认 false，墓碑在 NIF 那边就过滤掉了，
%% 所以这里收到的 IsTomb 一定是 false，匹配时把它丢弃。
cask_fold_keys_collect(Ref, Fun, Acc0) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, -1, -1) of
        {ok, IterRef} ->
            try cask_fold_keys_loop(IterRef, Fun, Acc0)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_keys_loop(IterRef, Fun, Acc) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp, _IsTomb} ->
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            cask_fold_keys_loop(IterRef, Fun, Fun(E, Acc));
        {error, _} = Err -> Err
    end.

%% fold_keys/6 走完整 cask_fold_start/4——把 see_tombstones 标志传给 NIF，
%% 这样遍历时 NIF 也会把墓碑送上来。SeeTombstonesP=true 时墓碑包成
%% {tombstone, BCEntry} 给回调；false 时理论上这一支不会走到，留空兜底。
cask_fold_keys6_collect(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, MaxAge, MaxPut, SeeTombstonesP) of
        {ok, IterRef} ->
            try cask_fold_keys6_loop(IterRef, Fun, Acc0, SeeTombstonesP)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold_keys6_loop(IterRef, Fun, Acc, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, _V, FileId, Offset, TotalSz, Tstamp, IsTomb} ->
            E = #bitcask_entry{key = K, file_id = FileId,
                               total_sz = TotalSz, offset = Offset,
                               tstamp = Tstamp},
            Acc2 = case IsTomb of
                       true when SeeTombstonesP -> Fun({tombstone, E}, Acc);
                       true                     -> Acc;
                       false                    -> Fun(E, Acc)
                   end,
            cask_fold_keys6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% fold/6 的回调形态有点特殊：
%%   普通 entry：Fun(K, V, Acc)
%%   墓碑（仅当 SeeTombstones=true）：Fun({tombstone, K}, V, Acc)
%% 这是 legacy 留下来的契约，不要改——下游可能在模式匹配 {tombstone, _}。
cask_fold6_collect(Ref, Fun, Acc0, MaxAge, MaxPut, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_start(Ref, MaxAge, MaxPut, SeeTombstonesP) of
        {ok, IterRef} ->
            try cask_fold6_loop(IterRef, Fun, Acc0, SeeTombstonesP)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

cask_fold6_loop(IterRef, Fun, Acc, SeeTombstonesP) ->
    case bitcask_cpp_nifs:cask_fold_next_full(IterRef) of
        done -> Acc;
        {ok, K, V, _Fid, _Off, _Sz, _Ts, IsTomb} ->
            Acc2 = case IsTomb of
                       true when SeeTombstonesP -> Fun({tombstone, K}, V, Acc);
                       true                     -> Acc;
                       false                    -> Fun(K, V, Acc)
                   end,
            cask_fold6_loop(IterRef, Fun, Acc2, SeeTombstonesP);
        {error, _} = Err -> Err
    end.

%% stream_fold/3,4 — 批量迭代版 fold，每批 N 条减少 NIF 调用开销。
%% 默认批量大小=32。回调签名 fun(K, V, Acc) -> Acc'。
stream_fold(Handle, Fun, Acc0) ->
    stream_fold(Handle, Fun, Acc0, 32).

stream_fold(Handle, Fun, Acc0, BatchSize) when is_integer(BatchSize), BatchSize > 0 ->
    case bitcask_cpp_nifs:cask_fold_start(ref(Handle), -1, -1) of
        {ok, IterRef} ->
            try stream_fold_loop(IterRef, Fun, Acc0, BatchSize)
            after bitcask_cpp_nifs:cask_fold_release(IterRef)
            end;
        {error, _} = E -> E
    end.

stream_fold_loop(IterRef, Fun, Acc, BatchSize) ->
    case bitcask_cpp_nifs:cask_fold_next_batch(IterRef, BatchSize) of
        done -> Acc;
        {ok, Pairs} ->
            Acc2 = lists:foldl(fun({K, V}, A) -> Fun(K, V, A) end, Acc, Pairs),
            stream_fold_loop(IterRef, Fun, Acc2, BatchSize);
        {error, _} = E -> E
    end.

%% 单位换算：legacy fold/6 接收的 MaxAge 是「微秒」（来自 bitcask.app.src
%% 里 max_fold_age 配置项乘以 1000 之后的结果），cask 迭代器要的是「秒」，
%% -1 表示不限。MaxPut 没有单位变化，只把 undefined / 负数归一到 -1。
cask_max_age(undefined) -> -1;
cask_max_age(N) when is_integer(N), N < 0 -> -1;
cask_max_age(N) when is_integer(N) -> N div 1000000.

cask_max_put(undefined) -> -1;
cask_max_put(N) when is_integer(N), N < 0 -> -1;
cask_max_put(N) when is_integer(N) -> N.

%% =========================================================================
%% 全文搜索（BM25）
%%
%% 必须在索引模式（open 时带 {analyzer, ...} 选项）打开的 Ref 上调用。
%% KV 模式下调这些接口会返回 {error, no_index}。
%% =========================================================================

%% 词袋模式搜索，默认返回前 10 条。
search_text(Handle, Query) ->
    search_text(Handle, Query, 10).

search_text(Handle, Query, K) ->
    bitcask_cpp_nifs:cask_search_text(ref(Handle), Query, K).

search_text(Handle, Query, K, Filter) ->
    bitcask_cpp_nifs:cask_search_text(ref(Handle), Query, K, Filter).

%% 短语模式搜索，默认返回前 10 条。
search_phrase(Handle, Query) ->
    search_phrase(Handle, Query, 10).

search_phrase(Handle, Query, K) ->
    bitcask_cpp_nifs:cask_search_phrase(ref(Handle), Query, K).

%% 多字段搜索（S8.6）：支持 `field:term^boost` 语法，跨字段加权合并。
%% 无字段限定的词等价于默认字段词袋搜索。
search_fields(Handle, Query) ->
    search_fields(Handle, Query, 10).

search_fields(Handle, Query, K) ->
    bitcask_cpp_nifs:cask_search_fields(ref(Handle), Query, K).

%% 近邻搜索（S8.7）：term 按 Query 词序出现且相邻间隙 ≤ Slop。Slop=0 即短语。
search_near(Handle, Query, Slop) ->
    search_near(Handle, Query, Slop, 10).

search_near(Handle, Query, Slop, K) ->
    bitcask_cpp_nifs:cask_search_near(ref(Handle), Query, Slop, K).

%% 模糊搜索（S8.3）：Levenshtein 编辑距离匹配。
search_fuzzy(Handle, Query, MaxEdit) ->
    search_fuzzy(Handle, Query, MaxEdit, 10).

search_fuzzy(Handle, Query, MaxEdit, K) ->
    bitcask_cpp_nifs:cask_search_fuzzy(ref(Handle), Query, MaxEdit, K).

%% 通配符搜索（S8.4）：支持 * 和 ? 通配符。
search_wildcard(Handle, Pattern) ->
    search_wildcard(Handle, Pattern, 10).

search_wildcard(Handle, Pattern, K) ->
    bitcask_cpp_nifs:cask_search_wildcard(ref(Handle), Pattern, K).

%% =========================================================================
%% 向量 / 混合检索（V3.6）
%%
%% 必须在向量集合（open 时带 {vector_dim, N}，且为索引模式）上调用。
%% VecBin = f32 LE 二进制（Dim×4 字节），与 put 的 doc map vector 键同格式：
%%   << <<X:32/float-little>> || X <- Floats >>
%% embedding 由调用方提供（bitcask_embedder behaviour），引擎只收向量。
%% =========================================================================

%% HNSW 近邻检索。Ef=0 → 引擎默认 max(K, 64)。
search_vector(Handle, VecBin) ->
    search_vector(Handle, VecBin, 10).

search_vector(Handle, VecBin, K) ->
    search_vector(Handle, VecBin, K, 0).

search_vector(Handle, VecBin, K, Ef) ->
    bitcask_cpp_nifs:cask_search_vector(ref(Handle), VecBin, K, Ef).

search_vector(Handle, VecBin, K, Ef, Filter) ->
    bitcask_cpp_nifs:cask_search_vector(ref(Handle), VecBin, K, Ef, Filter).

%% RRF 混合检索：BM25 与向量两路各取 K'=max(K×4,64)，按 1/(60+rank) 融合，
%% 平局 ord 小者在前。TextQuery/VecBin 允许其一为 <<>>（单路退化），
%% 两路都空 → {error, _}。返回 {ok, [{Key, Ord, RrfScore}]}。
search_hybrid(Handle, TextQuery, VecBin) ->
    search_hybrid(Handle, TextQuery, VecBin, 10).

search_hybrid(Handle, TextQuery, VecBin, K) ->
    bitcask_cpp_nifs:cask_search_hybrid(ref(Handle), TextQuery, VecBin, K).

search_hybrid(Handle, TextQuery, VecBin, K, Filter) ->
    bitcask_cpp_nifs:cask_search_hybrid(ref(Handle), TextQuery, VecBin, K, Filter).

%% 设置同义词词典（S8.2）：从文件加载，查询时自动展开。
set_synonym_map(Handle, FilePath) ->
    bitcask_cpp_nifs:cask_set_synonym_map(ref(Handle), FilePath).

%% V5:把 map 或 proplist 编码成 put_doc 可用的 meta 二进制 blob。给
%% 业务方 / 测试一个轻量入口,生产路径下通常自己编码更高效。Value 类型:
%% integer -> int64, float -> double, binary -> string, true|false -> bool,
%% undefined -> null。失败 → badarg。
encode_meta(Entries) ->
    bitcask_cpp_nifs:cask_encode_meta(Entries).
