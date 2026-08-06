%% -------------------------------------------------------------------
%% bitcask_cpp_nifs:
%%   priv/bitcask_cpp.so 的 Erlang 入口模块。on_load 时通过
%%   erlang:load_nif/2 把所有 cask_* 函数的实现替换成 C++ NIF。加载前
%%   每个函数体都是 erlang:nif_error 占位（提示 .so 没装好）。
%%
%%   只暴露 cask_* 粗粒度 API；M6 之前那批 file_* / lock_* / keydir_*
%%   细粒度包装已随 legacy 一起删掉，对应的 C++ NIF 入口也已下线。
%% -------------------------------------------------------------------
-module(bitcask_cpp_nifs).

-export([cask_open/2,
         cask_close/1,
         cask_get/2,
         cask_put/3,
         cask_delete/2,
         cask_sync/1,
         cask_close_write_file/1,
         cask_search_text/3,
         cask_search_text/4,
         cask_search_phrase/3,
         cask_bool_search/3,
         cask_search_fields/3,
         cask_search_near/4,
         cask_search_fuzzy/4,
         cask_search_wildcard/3,
         cask_search_vector/4,
         cask_search_vector/5,
         cask_search_hybrid/4,
         cask_search_hybrid/5,
         cask_encode_meta/1,
         cask_fold_start/3,
         cask_fold_start/4,
         cask_fold_next/1,
         cask_fold_next_full/1,
         cask_fold_next_batch/2,
         cask_fold_release/1,
         cask_iterator/3,
         cask_iterator_next/1,
         cask_iterator_release/1,
         cask_is_empty/1,
         cask_is_frozen/1,
         cask_status/1,
         cask_needs_merge/1,
         cask_merge/2,
         %% v5.1.0 S33-5：OKI 有序 range 迭代器
         cask_range_start/2,
         cask_range_next/1,
         cask_range_next_batch/2,
         cask_range_release/1,
         %% v5.1.0 S34/S35：引擎原子批 + 多键事务
         cask_put_batch_atomic/2,
         cask_txn_commit/3]).

-on_load(init/0).

-spec init() -> ok | {error, any()}.
init() ->
    SoName =
        case code:priv_dir(bitcask) of
            {error, bad_name} ->
                case code:which(?MODULE) of
                    Filename when is_list(Filename) ->
                        filename:join([filename:dirname(Filename), "../priv", "bitcask_cpp"]);
                    _ ->
                        filename:join("../priv", "bitcask_cpp")
                end;
            Dir ->
                filename:join(Dir, "bitcask_cpp")
        end,
    erlang:load_nif(SoName, 0).

%% =============================================================================
%% cask_* 粗粒度 API：每个函数都是单次 NIF 调用，由 priv/bitcask_cpp.so 实现。
%% 所有耗时操作（cask_open / cask_sync / cask_close_write_file / cask_merge）
%% 在 C++ 端注册为 ERL_NIF_DIRTY_JOB_IO_BOUND，落到 dirty 调度器，避免阻塞
%% BEAM 主调度线程。
%% =============================================================================
cask_open(_Dir, _Opts)        -> erlang:nif_error({error, not_loaded}).
cask_close(_Ref)              -> erlang:nif_error({error, not_loaded}).
cask_get(_Ref, _Key)          -> erlang:nif_error({error, not_loaded}).
cask_put(_Ref, _Key, _Val)    -> erlang:nif_error({error, not_loaded}).
cask_delete(_Ref, _Key)       -> erlang:nif_error({error, not_loaded}).
cask_sync(_Ref)               -> erlang:nif_error({error, not_loaded}).
cask_close_write_file(_Ref)   -> erlang:nif_error({error, not_loaded}).
cask_search_text(_Ref, _Q, _K)   -> erlang:nif_error({error, not_loaded}).
%% V5:Search + metadata filter. Filter term = list-of-cond / map(见 parse_filter_term 注释)。
%% undefined 视为「无 filter」;其它 term 解析失败 → badarg。
cask_search_text(_Ref, _Q, _K, _Filter)   -> erlang:nif_error({error, not_loaded}).
cask_search_phrase(_Ref, _Q, _K) -> erlang:nif_error({error, not_loaded}).
cask_bool_search(_Ref, _Q, _K)   -> erlang:nif_error({error, not_loaded}).
cask_search_fields(_Ref, _Q, _K) -> erlang:nif_error({error, not_loaded}).
cask_search_near(_Ref, _Q, _Slop, _K) -> erlang:nif_error({error, not_loaded}).
cask_search_fuzzy(_Ref, _Q, _MaxEdit, _K) -> erlang:nif_error({error, not_loaded}).
cask_search_wildcard(_Ref, _Pattern, _K) -> erlang:nif_error({error, not_loaded}).
%% V3.6:VecBin = f32 LE 二进制(Dim×4 字节),<< <<X:32/float-little>> || X <- L >>。
%% size 非 4 倍数 → badarg;维度不符 → {error, _}。Ef=0 → 引擎默认 max(K,64)。
cask_search_vector(_Ref, _VecBin, _K, _Ef) -> erlang:nif_error({error, not_loaded}).
%% V5:HNSW 向量检索 + metadata filter(undefined 视为无 filter)。
cask_search_vector(_Ref, _VecBin, _K, _Ef, _Filter) -> erlang:nif_error({error, not_loaded}).
%% V3.6:RRF 混合检索。TextBin/VecBin 允许其一为 <<>>(单路退化),都空 → {error, _}。
cask_search_hybrid(_Ref, _TextBin, _VecBin, _K) -> erlang:nif_error({error, not_loaded}).
%% V5:RRF 混合检索 + metadata filter(undefined 视为无 filter)。
cask_search_hybrid(_Ref, _TextBin, _VecBin, _K, _Filter) -> erlang:nif_error({error, not_loaded}).
%% V5:把 [{Key, Value} | ...] proplist 编码为 meta blob(Value 类型:
%% int/float/binary/true|false/undefined → int64/f64/string/bool/null)。
%% 给 eunit 测试用 — 生产路径下 put_doc 的 meta 是由业务自行编码的。
cask_encode_meta(_Entries) -> erlang:nif_error({error, not_loaded}).
cask_fold_start(_R, _MA, _MP) -> erlang:nif_error({error, not_loaded}).
cask_fold_start(_R, _MA, _MP, _SeeTomb) -> erlang:nif_error({error, not_loaded}).
cask_fold_next(_IterRef)      -> erlang:nif_error({error, not_loaded}).
cask_fold_next_full(_IterRef) -> erlang:nif_error({error, not_loaded}).
-spec cask_fold_next_batch(reference(), pos_integer()) ->
    {ok, [{binary(), binary()}]} | done | {error, term()}.
cask_fold_next_batch(_IterRef, _BatchSize) -> erlang:nif_error({error, not_loaded}).
cask_fold_release(_IterRef)   -> erlang:nif_error({error, not_loaded}).
cask_iterator(_R, _MA, _MP)   -> erlang:nif_error({error, not_loaded}).
cask_iterator_next(_R)        -> erlang:nif_error({error, not_loaded}).
cask_iterator_release(_R)     -> erlang:nif_error({error, not_loaded}).
cask_is_empty(_Ref)           -> erlang:nif_error({error, not_loaded}).
cask_is_frozen(_Ref)          -> erlang:nif_error({error, not_loaded}).
cask_status(_Ref)             -> erlang:nif_error({error, not_loaded}).
cask_needs_merge(_Ref)        -> erlang:nif_error({error, not_loaded}).
cask_merge(_Ref, _Files)      -> erlang:nif_error({error, not_loaded}).

%% -----------------------------------------------------------------------
%% v5.1.0 S33-5：OKI 有序 range 迭代器
%%
%% 按 key 字典序遍历 [Lo, Hi)，代价 O(range) 而非 O(全表)。一致性是
%% **per-key 弱一致**（与 parallel_scan 同档，不是 fold 的快照语义）——
%% 迭代期间的并发写可能部分可见。需要快照请用 fold。
%%
%% 迭代器的合法期不能超过父 Ref：C++ 侧取值要回调父 Cask 的读路径。
%% NIF 已经 keep 住父资源、并在每次 next 前检查是否已 cask_close，所以
%% 越界使用得到的是 {error, closed} 而不是段错误——但仍应当先用完再关。
%%
%% Opts :: [{lo, binary()} | {hi, binary()} |
%%          {prefetch, non_neg_integer()} | {prefetch_threads, non_neg_integer()}]
%% 目录没有 OKI（只读打开一个从未写过的库 / 重建失败）→ {error, no_index}。
%% -----------------------------------------------------------------------
%% ⚠️ **失败可能是裸 atom，不一定是 `{error, _}`。** `fault_to_term` 对
%% `no_index` / `closed` / `mode_mismatch` / `not_found` / `already_exists`
%% 返回裸 atom（legacy 契约）。最常撞上的是 `no_index`——只读打开一个从未
%% 写过的目录没有 OKI。门面 `bitcask:range/2,3` 会归一成 `{error, Reason}`；
%% 直接用本模块的调用方必须自己处理这两种形态。
-spec cask_range_start(reference(), list()) ->
    {ok, reference()} | {error, term()} | atom().
cask_range_start(_Ref, _Opts)  -> erlang:nif_error({error, not_loaded}).
-spec cask_range_next(reference()) ->
    {ok, binary(), binary(), non_neg_integer(), non_neg_integer()}
    | done | {error, term()} | atom().
cask_range_next(_IterRef)      -> erlang:nif_error({error, not_loaded}).
%% 批未满即到尾——返回列表比 BatchSize 短就该停。
-spec cask_range_next_batch(reference(), pos_integer()) ->
    {ok, [{binary(), binary(), non_neg_integer(), non_neg_integer()}]}
    | done | {error, term()} | atom().
cask_range_next_batch(_IterRef, _BatchSize) -> erlang:nif_error({error, not_loaded}).
-spec cask_range_release(reference()) -> ok.
cask_range_release(_IterRef)   -> erlang:nif_error({error, not_loaded}).

%% -----------------------------------------------------------------------
%% v5.1.0 S34/S35：引擎原子批 + 多键事务
%%
%% Ops :: [{put, Key :: binary(), Value :: binary()} | {remove, Key :: binary()}]
%%
%% 崩溃/掉电后整批要么全可见要么全不可见（盘上批头声明区间，恢复时区间
%% 不完整即整批截断）。原子性与持久性正交：没 fsync 就掉电仍可能整批丢失，
%% 但绝不半批。
%%
%% ⚠️ 首次调用把目录 bitcask.meta 懒升级为 v6，此后**不能被早于 5.1.0 的
%% 读端打开**。从不调用的目录停留 v5，与旧读端双向互开。
%%
%% cask_put_batch_atomic：裸批。允许批内同 key 多次（依序 apply = 批内 LWW），
%%                        空批是 no-op（不碰 meta 纪元）。
%% cask_txn_commit：TxnCask.commit，多一层校验（非空 / key 非空 / key 互不
%%                  重复 / 不占用 "_txn:" 保留前缀）+ 提交点 fsync 策略。
%%                  不提供隔离性与 CAS——中间态对并发读者可见，键集重叠的
%%                  并发 commit 需应用层串行化。
%% -----------------------------------------------------------------------
%% 失败形态同上：可能是 `{error, _}`，也可能是裸 atom（如 `closed`）。
-spec cask_put_batch_atomic(reference(), list()) -> ok | {error, term()} | atom().
cask_put_batch_atomic(_Ref, _Ops) -> erlang:nif_error({error, not_loaded}).
-spec cask_txn_commit(reference(), list(), sync_on_commit | no_sync) ->
    ok | {error, term()} | atom().
cask_txn_commit(_Ref, _Ops, _Sync) -> erlang:nif_error({error, not_loaded}).
