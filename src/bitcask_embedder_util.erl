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

-export([truncate_utf8/2,
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
