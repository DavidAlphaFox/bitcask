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

-export([http_embed/4,
         http_embed_batch/4,
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

%% 单条。Headers 由 provider 给（Bearer / x-api-key）。
-spec http_embed(map(), binary(), [{string(), string()}], pos_integer()) ->
          {ok, binary()} | {error, term()}.
http_embed(Cfg, Text, Headers, DefaultMaxIn) ->
    MaxIn = maps:get(max_input_bytes, Cfg, DefaultMaxIn),
    Input = truncate_utf8(Text, MaxIn),
    {_Dim, VDim} = dims(Cfg),
    case post(Cfg, Headers, body(Cfg, Input)) of
        {ok, RespBody}  -> parse_embedding(RespBody, VDim);
        {error, _} = E  -> E
    end.

%% 批量：一次请求带一个数组。返回**逐条**结果，顺序与输入一一对应。
%%
%% ⚠️ 空串在这里就地挡掉，不发给端点 —— OpenAI 兼容端点对数组里的空串会**整个
%%    请求**报 400，一条空文档就把同批的另外 63 条一起废掉。
%%
%% ⚠️ 按 max_batch 切块：端点对数组长度与总 token 都有上限，超了是整个请求失败。
-spec http_embed_batch(map(), [binary()], [{string(), string()}], pos_integer()) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
http_embed_batch(_Cfg, [], _Headers, _DefaultMaxIn) ->
    {ok, []};
http_embed_batch(Cfg, Texts, Headers, DefaultMaxIn) ->
    MaxIn  = maps:get(max_input_bytes, Cfg, DefaultMaxIn),
    MaxBat = maps:get(max_batch, Cfg, 64),
    {_Dim, VDim} = dims(Cfg),
    Indexed = lists:zip(lists:seq(1, length(Texts)), Texts),
    %% 空串单独标记，不进 HTTP。
    {Send, Skip} = lists:partition(fun({_, T}) -> T =/= <<>> end, Indexed),
    Sent = lists:append(
             [do_batch_chunk(Cfg, Headers, VDim, MaxIn, Chunk)
              || Chunk <- chunks([{I, truncate_utf8(T, MaxIn)} || {I, T} <- Send], MaxBat)]),
    All = Sent ++ [{I, {error, empty_text}} || {I, _} <- Skip],
    {ok, [R || {_, R} <- lists:sort(All)]}.

do_batch_chunk(Cfg, Headers, VDim, _MaxIn, Chunk) ->
    Idxs   = [I || {I, _} <- Chunk],
    Inputs = [T || {_, T} <- Chunk],
    case post(Cfg, Headers, body(Cfg, Inputs)) of
        {error, _} = E ->
            %% ⚠️ 整块失败只让**这一块**的条目失败，别的块照跑。
            [{I, E} || I <- Idxs];
        {ok, RespBody} ->
            case parse_embedding_batch(RespBody, VDim, length(Inputs)) of
                {ok, Rs}       -> lists:zip(Idxs, Rs);
                {error, _} = E -> [{I, E} || I <- Idxs]
            end
    end.

chunks([], _N) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) ->
    {H, T} = lists:split(N, L),
    [H | chunks(T, N)].

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

post(Cfg, Headers, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    Url = maps:get(url, Cfg),
    Req = {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))},
    HttpOpts = [{timeout, maps:get(timeout_ms, Cfg, 30000)},
                {connect_timeout, maps:get(connect_timeout_ms, Cfg, 5000)}],
    case httpc:request(post, Req, HttpOpts, [{body_format, binary}]) of
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
