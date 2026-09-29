%% -------------------------------------------------------------------
%% bitcask_embedder_util:
%%   embedder provider 之间共享的逻辑。
%%
%%   两类 provider 的差别只在"向量从哪来"：
%%
%%     * **HTTP 档**（bitcask_embedder_openai / _anthropic）——无状态，配置就是
%%       几个字段，并发友好，不需要独立进程。
%%     * **内置档**（bitcask_embedder_llama）——有状态（几百 MB 权重 + 非线程
%%       安全的 context），装一次要复用，必须串行，走 bitcask_embedder_server。
%%
%%   除此之外的东西两边一模一样：输入怎么裁、维度怎么校验、MRL 怎么截。这些
%%   过去是**三份逐字重复的拷贝**（openai / anthropic / llama 各一份），
%%   收进这里。
%%
%%   ⚠️ 唯一的行为差异记在 mrl_truncate/3：HTTP 档的 MRL 是服务端做的
%%      （请求里带 dimensions），内置档没人代劳，只能在 Erlang 侧做。
%% -------------------------------------------------------------------
-module(bitcask_embedder_util).

-export([http_init/4,
         http_embed/2,
         http_embed_batch/2,
         run_chunks/4,
         chunks/2,
         ensure_httpc/0,
         parse_embedding/2,
         parse_embedding_batch/3,
         truncate_utf8/2,
         validate_dims/2,
         validate_limits/2,
         mrl_truncate/3,
         l2_normalize/1,
         floats/1,
         vec_bin/1]).

%% -------------------------------------------------------------------
%% truncate_utf8/2 — 字节级保守截断。
%%
%% 模型上下文有 token 上限，超长输入端点会报错/截断，所以在客户端先按字节
%% 裁剩（UTF-8 下字节数 ≤ N ⟹ token 数 ≤ N，保守安全），并回退尾部 UTF-8
%% 续延字节避免截出非法编码。
%% -------------------------------------------------------------------
-spec truncate_utf8(binary(), pos_integer()) -> binary().
truncate_utf8(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate_utf8(Bin, Max) -> strip_partial(binary:part(Bin, 0, Max), 3).

%% 最多回退 3 个字节（UTF-8 一个码点最长 4 字节，首字节 + 3 个续延）。
%% 按字节判定，不构造中间 binary。
strip_partial(<<>>, _) -> <<>>;
strip_partial(Bin, N) ->
    Sz = byte_size(Bin),
    case binary:at(Bin, Sz - 1) of
        B when B band 16#C0 =:= 16#80, N > 0 ->
            strip_partial(binary:part(Bin, 0, Sz - 1), N - 1);
        B when B >= 16#C0 ->
            binary:part(Bin, 0, Sz - 1);
        _ -> Bin
    end.

%% -------------------------------------------------------------------
%% validate_dims/2 — 校验 dim（模型原生维度）与 vector_dim（MRL 落库维度）。
%% vector_dim 缺省 = dim，必须为正整数且 ≤ dim（MRL 只能截短，不能扩展）。
%% -------------------------------------------------------------------
-spec validate_dims(map(), pos_integer()) ->
          {ok, pos_integer(), pos_integer()} | {error, term()}.
validate_dims(Opts, DefaultDim) ->
    Dim  = maps:get(dim, Opts, DefaultDim),
    VDim = maps:get(vector_dim, Opts, Dim),
    if
        not (is_integer(Dim) andalso Dim > 0)   -> {error, {bad_opt, dim}};
        not (is_integer(VDim) andalso VDim > 0) -> {error, {bad_opt, vector_dim}};
        VDim > Dim -> {error, {vector_dim_exceeds_dim, VDim, Dim}};
        true -> {ok, Dim, VDim}
    end.

%% -------------------------------------------------------------------
%% validate_limits/2 — 校验一组正整数可选项。
%% Specs = [{Key, Default}]；返回 {ok, #{Key => Val}}（缺省填默认值）
%% 或 {error, {bad_opt, Key}}。
%% -------------------------------------------------------------------
-spec validate_limits(map(), [{atom(), pos_integer()}]) ->
          {ok, map()} | {error, {bad_opt, atom()}}.
validate_limits(Opts, Specs) ->
    lists:foldl(
        fun({Key, Def}, {ok, Acc}) ->
                case maps:get(Key, Opts, Def) of
                    V when is_integer(V), V > 0 -> {ok, Acc#{Key => V}};
                    _ -> {error, {bad_opt, Key}}
                end;
           (_, {error, _} = E) -> E
        end, {ok, #{}}, Specs).

%% -------------------------------------------------------------------
%% mrl_truncate/3 — 在 Erlang 侧做 MRL：取前 VDim 个 f32，重新 L2 归一化。
%%
%% ⚠️ **截断之后必须重新归一化。** 截断前的向量是在 Dim 维上单位长度的，砍掉
%%    尾部之后模长 < 1 且**每条不一样**——直接拿去点积当余弦用，比较的就不再是
%%    夹角，长文本会系统性地排在后面。
%%
%% ⚠️ 只有**内置档**需要这个。HTTP 档在请求里带 dimensions，由服务端按 MRL
%%    截断 + 重归一，不要在这边再截一次（会把已经归一好的又切一刀）。
%%
%% Normalize=false 时只截不归一——调用方明确说了不要归一化就别替它做主。
%% -------------------------------------------------------------------
-spec mrl_truncate(binary(), pos_integer(), boolean()) -> binary().
mrl_truncate(Vec, VDim, Normalize) ->
    case byte_size(Vec) =< VDim * 4 of
        true  -> Vec;
        false ->
            Head = binary:part(Vec, 0, VDim * 4),
            case Normalize of
                false -> Head;
                true  -> l2_normalize(Head)
            end
    end.

%% -------------------------------------------------------------------
%% l2_normalize/1 — f32 小端向量的 L2 归一化。归一之后余弦 = 点积。
%% -------------------------------------------------------------------
-spec l2_normalize(binary()) -> binary().
l2_normalize(Bin) ->
    Fs = floats(Bin),
    Sum = lists:foldl(fun(F, Acc) -> Acc + F * F end, 0.0, Fs),
    case Sum > 0.0 of
        false ->
            %% 零向量归一化会得到 NaN，而 NaN 在余弦里不报错、只是让这一条永远
            %% 排不上来。原样返回，让上层看到的是一个可辨认的零向量。
            Bin;
        true ->
            Inv = 1.0 / math:sqrt(Sum),
            << <<(F * Inv):32/float-little>> || F <- Fs >>
    end.

%% f32 小端 binary ⇄ float list。跨界格式锚点（DocValue / HNSW 都按这个读）。
-spec floats(binary()) -> [float()].
floats(Bin) -> [F || <<F:32/float-little>> <= Bin].

-spec vec_bin([number()]) -> binary().
vec_bin(Floats) -> << <<(float(X)):32/float-little>> || X <- Floats >>.

%% ===================================================================
%% HTTP 档共用的请求 / 解析
%%
%% openai 与 anthropic 两个 provider 的请求体、超时处理、响应解析**完全一样**，
%% 只有认证 header 不同。所以这里收口，provider 只负责把自己的 Headers 传进来。
%% （这正是本模块存在的理由：那两处此前已有过一轮逐字重复。）
%% ===================================================================

%% -------------------------------------------------------------------
%% http_init/4 — HTTP 档 provider 的 init/1 共用实现。
%%
%% openai / anthropic 两个模块的 init、validate_limits、embed、embed_batch
%% 此前逐字相同，只差默认维度与认证 header 的拼法——那两样由参数给：
%%   DefaultDim  — 模型原生维度缺省值
%%   HeadersFun  — fun(ApiKey | undefined) -> [{Name, Value}]，在这里调**一次**，
%%                 结果存进 config（headers），每次请求不再重拼。
%% 校验过的上限一起并进 config：
%%   max_input_bytes（默认 32768）、timeout_ms（30000）、connect_timeout_ms
%%   （5000）、max_batch（64，⚠️ 以前文档写了却没进 config，util 永远用 64）、
%%   max_inflight（4，批量请求的并发块数上限）。都必须是正整数——
%%   max_batch = 0 会让切块死循环。
%% 顺带把 httpc 起好（ensure_httpc/0），请求路径上不再每次
%% application:ensure_all_started。
%% -------------------------------------------------------------------
-define(DEFAULT_MAX_INPUT_BYTES, 32768).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_BATCH, 64).
-define(DEFAULT_MAX_INFLIGHT, 4).
%% 并发块的总兜底：每轮（max_inflight 块并行）最多花一个请求超时，轮数 ×
%% 单请求超时再加这个余量。
-define(INFLIGHT_DEADLINE_MARGIN_MS, 5000).

-spec http_init(module(), map(), pos_integer(),
                fun((undefined | binary() | string()) -> [{string(), string()}])) ->
          {ok, bitcask_embedder:ctx()} | {error, term()}.
http_init(Module, Opts, DefaultDim, HeadersFun) ->
    case {maps:get(url, Opts, undefined), maps:get(model, Opts, undefined)} of
        {undefined, _} -> {error, {missing_opt, url}};
        {_, undefined} -> {error, {missing_opt, model}};
        {Url, Model} ->
            case validate_dims(Opts, DefaultDim) of
                {ok, Dim, VDim} ->
                    case validate_limits(Opts, limit_specs()) of
                        {ok, Limits} ->
                            ApiKey = maps:get(api_key, Opts, undefined),
                            ensure_httpc(),
                            Base = #{
                                url        => Url,
                                model      => to_bin(Model),
                                api_key    => ApiKey,
                                headers    => HeadersFun(ApiKey),
                                dim        => Dim,    %% 供 embed 决定是否发 dimensions
                                vector_dim => VDim
                            },
                            {ok, #{
                                module     => Module,
                                dim        => Dim,
                                vector_dim => VDim,
                                config     => maps:merge(Base, Limits)
                            }};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end
    end.

limit_specs() ->
    [{max_input_bytes,    ?DEFAULT_MAX_INPUT_BYTES},
     {timeout_ms,         ?DEFAULT_TIMEOUT_MS},
     {connect_timeout_ms, ?DEFAULT_CONNECT_TIMEOUT_MS},
     {max_batch,          ?DEFAULT_MAX_BATCH},
     {max_inflight,       ?DEFAULT_MAX_INFLIGHT}].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

%% -------------------------------------------------------------------
%% ensure_httpc/0 — 起 inets + 一个专用 httpc profile（bitcask_embedder）。
%%
%% 以前每个请求都 application:ensure_all_started(inets)：那是一次进
%% application controller 的 call，串行且不便宜。现在 init 时起好，请求路径
%% 只做一次 whereis。
%% 专用 profile 的理由：默认 profile 的 max_sessions = 2、max_keep_alive_length
%% = 5，并发 embed 会在同一条 keep-alive 连接后面排队。
%% 幂等：两个 provider 并发 init 时后到的拿到 already_started，照常 ok。
%% -------------------------------------------------------------------
-define(HTTPC_PROFILE, bitcask_embedder).
-define(HTTPC_PROFILE_NAME, httpc_bitcask_embedder).   %% inets 给 profile 进程起的名

-spec ensure_httpc() -> ok.
ensure_httpc() ->
    case whereis(?HTTPC_PROFILE_NAME) of
        undefined ->
            {ok, _} = application:ensure_all_started(inets),
            case inets:start(httpc, [{profile, ?HTTPC_PROFILE}]) of
                {ok, _} ->
                    ok = httpc:set_options([{max_sessions, 16},
                                            {max_keep_alive_length, 64},
                                            {keep_alive_timeout, 60000}],
                                           ?HTTPC_PROFILE);
                {error, {already_started, _}} ->
                    ok
            end;
        _ ->
            ok
    end.

%% 单条。Headers 与上限都在 init 时进了 config；旧式（deprecated）调用只给
%% url/model 的，这里按缺省补。
-spec http_embed(map(), binary()) -> {ok, binary()} | {error, term()}.
http_embed(Cfg, Text) ->
    MaxIn = maps:get(max_input_bytes, Cfg, ?DEFAULT_MAX_INPUT_BYTES),
    Input = truncate_utf8(Text, MaxIn),
    {_Dim, VDim} = dims(Cfg),
    case post(Cfg, body(Cfg, Input)) of
        {ok, RespBody}  -> parse_embedding(RespBody, VDim);
        {error, _} = E  -> E
    end.

%% 批量：一次请求带一个数组。返回**逐条**结果，顺序与输入一一对应。
%%
%% ⚠️ 空串在这里就地挡掉，不发给端点 —— OpenAI 兼容端点对数组里的空串会**整个
%%    请求**报 400，一条空文档就把同批的另外 63 条一起废掉。
%%
%% ⚠️ 按 max_batch 切块：端点对数组长度与总 token 都有上限，超了是整个请求失败。
%%    块**并发**发出（run_chunks/4，同时在途 ≤ max_inflight）——以前是一块接
%%    一块串行，1000 条 = 16 次往返排着走，HTTP 档号称并发友好却只有一路在飞。
-spec http_embed_batch(map(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
http_embed_batch(_Cfg, []) ->
    {ok, []};
http_embed_batch(Cfg, Texts) ->
    MaxIn    = maps:get(max_input_bytes, Cfg, ?DEFAULT_MAX_INPUT_BYTES),
    MaxBat   = maps:get(max_batch, Cfg, ?DEFAULT_MAX_BATCH),
    Inflight = maps:get(max_inflight, Cfg, ?DEFAULT_MAX_INFLIGHT),
    {_Dim, VDim} = dims(Cfg),
    Indexed = lists:zip(lists:seq(1, length(Texts)), Texts),
    %% 空串单独标记，不进 HTTP。
    {Send, Skip} = lists:partition(fun({_, T}) -> T =/= <<>> end, Indexed),
    Chunks = chunks([{I, truncate_utf8(T, MaxIn)} || {I, T} <- Send], MaxBat),
    PerChunkMs = maps:get(timeout_ms, Cfg, ?DEFAULT_TIMEOUT_MS)
               + maps:get(connect_timeout_ms, Cfg, ?DEFAULT_CONNECT_TIMEOUT_MS),
    Rounds = (length(Chunks) + Inflight - 1) div max(1, Inflight),
    Deadline = Rounds * PerChunkMs + ?INFLIGHT_DEADLINE_MARGIN_MS,
    Results = run_chunks(Chunks, Inflight, Deadline,
                         fun(Chunk) -> do_batch_chunk(Cfg, VDim, Chunk) end),
    Sent = lists:append(
             [case R of
                  {ok, Pairs}    -> Pairs;
                  %% 工作进程崩了 / 整体超时：这一块的条目都报同一个错。
                  {error, _} = E -> [{I, E} || {I, _} <- Chunk]
              end || {Chunk, R} <- lists:zip(Chunks, Results)]),
    All = Sent ++ [{I, {error, empty_text}} || {I, _} <- Skip],
    {ok, [R || {_, R} <- lists:sort(All)]}.

do_batch_chunk(Cfg, VDim, Chunk) ->
    Idxs   = [I || {I, _} <- Chunk],
    Inputs = [T || {_, T} <- Chunk],
    case post(Cfg, body(Cfg, Inputs)) of
        {error, _} = E ->
            %% ⚠️ 整块失败只让**这一块**的条目失败，别的块照跑。
            [{I, E} || I <- Idxs];
        {ok, RespBody} ->
            case parse_embedding_batch(RespBody, VDim, length(Inputs)) of
                {ok, Rs}       -> lists:zip(Idxs, Rs);
                {error, _} = E -> [{I, E} || I <- Idxs]
            end
    end.

%% -------------------------------------------------------------------
%% run_chunks/4 — 有界并发地对每块跑 Fun，结果按块的原顺序返回。
%%
%% 每块一个 spawn_monitor 进程，同时在途 ≤ MaxInflight；一个总 DeadlineMs
%% 罩住全部块。返回 [{ok, Fun(Chunk)} | {error, Reason}]，与 Chunks 等长同序。
%% 失败路径：
%%   * 某个工作进程崩 → 那一块 {error, {chunk_crashed, Reason}}，其它块照跑；
%%   * 到 deadline → 仍在飞的全部 kill + demonitor(flush)，各记
%%     {error, {chunk_timeout, DeadlineMs}}，尚未发出的也不再发。
%% 收尾一律 flush 掉迟到的 {Tag, _, _} 回复，别留在调用方信箱里。
%% 纯并发骨架，不含 HTTP，导出给测试直接钉住并发上限与顺序。
%% -------------------------------------------------------------------
-spec run_chunks([term()], pos_integer(), pos_integer(), fun((term()) -> term())) ->
          [{ok, term()} | {error, term()}].
run_chunks([], _MaxInflight, _DeadlineMs, _Fun) ->
    [];
run_chunks(Chunks, MaxInflight, DeadlineMs, Fun) when is_integer(MaxInflight), MaxInflight >= 1 ->
    Tag = make_ref(),
    Parent = self(),
    Deadline = erlang:monotonic_time(millisecond) + DeadlineMs,
    Indexed = lists:zip(lists:seq(1, length(Chunks)), Chunks),
    Res = run_loop(Indexed, #{}, #{}, MaxInflight, Deadline, DeadlineMs, Tag, Parent, Fun),
    flush_tag(Tag),
    [maps:get(I, Res) || I <- lists:seq(1, length(Chunks))].

%% Pending: 未发出的 [{I, Chunk}]；Live: #{Pid => {I, Mon}}；Res: #{I => Result}。
run_loop([], Live, Res, _Max, _Deadline, _DeadlineMs, _Tag, _Parent, _Fun) when map_size(Live) =:= 0 ->
    Res;
run_loop(Pending, Live, Res, Max, Deadline, DeadlineMs, Tag, Parent, Fun) when map_size(Live) < Max, Pending =/= [] ->
    [{I, Chunk} | Rest] = Pending,
    {Pid, Mon} = spawn_monitor(fun() -> Parent ! {Tag, self(), Fun(Chunk)} end),
    run_loop(Rest, Live#{Pid => {I, Mon}}, Res, Max, Deadline, DeadlineMs, Tag, Parent, Fun);
run_loop(Pending, Live, Res, Max, Deadline, DeadlineMs, Tag, Parent, Fun) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    receive
        {Tag, Pid, R} when is_map_key(Pid, Live) ->
            {{I, Mon}, Live2} = maps:take(Pid, Live),
            erlang:demonitor(Mon, [flush]),
            run_loop(Pending, Live2, Res#{I => {ok, R}}, Max, Deadline, DeadlineMs, Tag, Parent, Fun);
        {'DOWN', Mon, process, Pid, Reason} when is_map_key(Pid, Live) ->
            {{I, Mon}, Live2} = maps:take(Pid, Live),
            %% 正常退出但回复还没到（消息比 DOWN 先发，同一发送者有序，所以
            %% 实际上回复一定已在信箱里）——再收一次；其它原因就是崩了。
            R = case Reason of
                    normal ->
                        receive {Tag, Pid, R0} -> {ok, R0}
                        after 0 -> {error, {chunk_crashed, normal}}
                        end;
                    _ -> {error, {chunk_crashed, Reason}}
                end,
            run_loop(Pending, Live2, Res#{I => R}, Max, Deadline, DeadlineMs, Tag, Parent, Fun)
    after max(0, Left) ->
        %% 总 deadline 到：在飞的全杀，没发的也不发了。
        Err = {error, {chunk_timeout, DeadlineMs}},
        Res1 = maps:fold(fun(Pid, {I, Mon}, Acc) ->
                                 erlang:demonitor(Mon, [flush]),
                                 exit(Pid, kill),
                                 Acc#{I => Err}
                         end, Res, Live),
        lists:foldl(fun({I, _}, Acc) -> Acc#{I => Err} end, Res1, Pending)
    end.

flush_tag(Tag) ->
    receive {Tag, _, _} -> flush_tag(Tag)
    after 0 -> ok
    end.

%% 按 N 切块。⚠️ 别在 guard 里 length(L)：那是每块一次 O(剩余长度)，整体 O(n²)。
-spec chunks([term()], pos_integer()) -> [[term()]].
chunks([], _N) -> [];
chunks(L, N) when is_integer(N), N >= 1 -> chunks(L, N, N, [], []).

chunks([], _N, _Left, Cur, Acc)    -> lists:reverse([lists:reverse(Cur) | Acc]);
chunks(L, N, 0, Cur, Acc)          -> chunks(L, N, N, [], [lists:reverse(Cur) | Acc]);
chunks([X | T], N, Left, Cur, Acc) -> chunks(T, N, Left - 1, [X | Cur], Acc).

dims(Cfg) ->
    Dim  = maps:get(dim, Cfg, undefined),
    {Dim, maps:get(vector_dim, Cfg, Dim)}.

%% MRL：vector_dim ≠ dim 时发 dimensions，让服务端按 MRL 截断+重归一。
body(Cfg, Input) ->
    Model = maps:get(model, Cfg),
    {Dim, VDim} = dims(Cfg),
    B = #{<<"model">> => Model, <<"input">> => Input},
    case is_integer(VDim) andalso VDim =/= Dim of
        true  -> B#{<<"dimensions">> => VDim};
        false -> B
    end.

post(Cfg, Body) ->
    ensure_httpc(),                                  %% 一次 whereis，init 已起好
    Url = maps:get(url, Cfg),
    Headers = maps:get(headers, Cfg, []),
    Req = {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
    HttpOpts = [{timeout, maps:get(timeout_ms, Cfg, ?DEFAULT_TIMEOUT_MS)},
                {connect_timeout, maps:get(connect_timeout_ms, Cfg, ?DEFAULT_CONNECT_TIMEOUT_MS)}],
    case httpc:request(post, Req, HttpOpts, [{body_format, binary}], ?HTTPC_PROFILE) of
        {ok, {{_, 200, _}, _H, RespBody}}     -> {ok, RespBody};
        {ok, {{_, Code, Reason}, _H, RespBody}} -> {error, {http_status, Code, Reason, RespBody}};
        {error, Reason}                       -> {error, {http_error, Reason}}
    end.

%% -------------------------------------------------------------------
%% parse_embedding/2 — 单条响应。
%% Expect = 期望维度（vector_dim）；长度不符 → {error,{dim_mismatch,Got,Expect}}
%% （服务端不支持 dimensions、忽略了 MRL 截断时在此暴露，而非静默写错维度）。
%%
%% 纯函数、导出，便于不打网络地单测。
%% -------------------------------------------------------------------
-spec parse_embedding(binary(), pos_integer() | undefined) ->
          {ok, binary()} | {error, term()}.
parse_embedding(RespBody, Expect) ->
    try json:decode(RespBody) of
        #{<<"data">> := [#{<<"embedding">> := Floats} | _]} when is_list(Floats) ->
            to_vec(Floats, Expect);
        Other ->
            {error, {unexpected_response, Other}}
    catch
        _:Reason -> {error, {bad_json, Reason}}
    end.

%% -------------------------------------------------------------------
%% parse_embedding_batch/3 — 数组响应，返回**逐条**结果。
%%
%% ⚠️ **必须按 `index` 字段归位，不能按返回顺序 zip。** OpenAI 兼容响应的每个
%%    对象都带 `index`，而"data 与 input 同序"只是常见实现的行为、不是协议保证
%%    （vLLM / TEI / llama.cpp server 各家不同，并发实现尤其容易乱序）。按顺序
%%    zip 的后果是**把向量配到别的文档上**——不报错、维度也对，只是检索结果
%%    从此不对，而且查不出来。
%%
%% 端点确实不给 index 时（有实现省略）退回按位置对应，但要求条数严格相等。
%% -------------------------------------------------------------------
-spec parse_embedding_batch(binary(), pos_integer() | undefined, non_neg_integer()) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
parse_embedding_batch(RespBody, Expect, N) ->
    try json:decode(RespBody) of
        #{<<"data">> := Items} when is_list(Items) ->
            case length(Items) of
                N -> place(Items, Expect, N);
                G -> {error, {batch_size_mismatch, G, N}}
            end;
        Other ->
            {error, {unexpected_response, Other}}
    catch
        _:Reason -> {error, {bad_json, Reason}}
    end.

place(Items, Expect, N) ->
    Idxs = [maps:get(<<"index">>, It, undefined) || It <- Items],
    case lists:all(fun(I) -> is_integer(I) end, Idxs) of
        true ->
            %% index 必须恰好是 0..N-1 的一个排列；不是就宁可整批报错，也不要
            %% 猜一个映射（猜错就是静默配错向量）。
            case lists:sort(Idxs) =:= lists:seq(0, N - 1) of
                true ->
                    Sorted = [It || {_, It} <- lists:sort(lists:zip(Idxs, Items))],
                    {ok, [item_vec(It, Expect) || It <- Sorted]};
                false ->
                    {error, {bad_index_set, lists:sort(Idxs)}}
            end;
        false ->
            %% 没有 index：只能按位置对应。条数已在上面核过。
            {ok, [item_vec(It, Expect) || It <- Items]}
    end.

item_vec(#{<<"embedding">> := Floats}, Expect) when is_list(Floats) ->
    to_vec(Floats, Expect);
item_vec(Other, _Expect) ->
    {error, {unexpected_item, Other}}.

to_vec(Floats, Expect) ->
    Got = length(Floats),
    case Expect =:= undefined orelse Got =:= Expect of
        true  -> {ok, << <<(float(X)):32/float-little>> || X <- Floats >>};
        false -> {error, {dim_mismatch, Got, Expect}}
    end.
