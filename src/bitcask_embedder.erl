%% -------------------------------------------------------------------
%% bitcask_embedder:
%%   Embedder 框架门面 — 运行时构建上下文，支持多 provider。
%%
%%   V3.6 原始设计：behaviour + application env（静态全局配置）。
%%   当前版本：context-based API，运行时动态配置，多 provider。
%%
%%   用法：
%%       {ok, Ctx} = bitcask_embedder:new(openai, #{
%%           url   => "http://localhost:8080/v1/embeddings",
%%           model => <<"qwen3-embedding">>,
%%           dim        => 2560,           %% 模型原生维度
%%           vector_dim => 1024,           %% 可选 MRL 截断维度（≤dim；缺省=dim）
%%           max_input_bytes    => 32768,  %% 可选；默认 32768
%%           timeout_ms         => 30000,  %% 可选；默认 30000
%%           connect_timeout_ms => 5000    %% 可选；默认 5000
%%       }),
%%       {ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>),
%%       Dim       = bitcask_embedder:dim(Ctx),         %% 原生维度
%%       VDim      = bitcask_embedder:vector_dim(Ctx).  %% 落库维度
%%
%%   各内置 provider（openai/anthropic）通用可选项（均为正整数，缺省用默认
%%   值，非正整数 → {error,{bad_opt,Key}}）：
%%     dim — 模型原生输出维度（provider 默认：openai 2560 / anthropic 4096）。
%%     vector_dim（默认 = dim）— MRL 截断后的落库/检索维度，须 ≤ dim。与 dim
%%       不一致时 embed 请求带 dimensions=>vector_dim，由服务端按 MRL 截断+重归一。
%%     max_input_bytes（默认 32768）— embed 前对输入做字节级保守截断的上限。
%%       模型上下文有 token 上限，超长输入端点会报错/截断，故在客户端先按
%%       字节裁剩（UTF-8 下字节数 ≤ N ⟹ token 数 ≤ N）。
%%     timeout_ms（默认 30000）— 单次 embedding 请求的总超时（毫秒）。
%%     connect_timeout_ms（默认 5000）— 建连超时（毫秒）。
%%
%%   多 provider：
%%       bitcask_embedder:new(openai,    #{url => ..., model => ..., dim => ...})
%%       bitcask_embedder:new(anthropic, #{url => ..., model => ..., dim => ...})
%%       bitcask_embedder:new({custom, my_mod}, #{...})
%%
%%   自定义 provider：实现 init/1 + embed/2，通过 {custom, Module} 注册。
%%
%%   Vec 格式 = f32 LE 二进制（Dim×4 字节），与 NIF 跨界 / DocValue
%%   存储格式一致。
%% -------------------------------------------------------------------
-module(bitcask_embedder).

%% Framework API (new — context-based, runtime dynamic)
-export([new/2, embed/2, embed_batch/2, dim/1, vector_dim/1]).

-export_type([ctx/0]).

%% -------------------------------------------------------------------
%% Context type — 普通 map，无需 hrl，跨模块安全。
%%
%% MRL（Matryoshka Representation Learning）：
%%   dim        = 模型**原生**输出维度（模型真实产出的向量长度）。
%%   vector_dim = MRL 截断目标 = 实际落库 / HNSW 维度（≤ dim；缺省 = dim）。
%% 二者不一致时，embed 请求会带 dimensions=>vector_dim，让服务端按 MRL
%% 截断+重归一。落库/检索维度一律以 vector_dim 为准。
%% -------------------------------------------------------------------
-type ctx() :: #{
    module     := module(),       %% provider 实现模块
    dim        := pos_integer(),  %% 模型原生维度
    vector_dim => pos_integer(),  %% MRL 落库维度（缺省 = dim）
    config     := map()           %% provider-specific 配置（url/model/api_key...）
}.

%% -------------------------------------------------------------------
%% Provider behaviour — 自定义 provider 实现这两个回调。
%%
%% init/1:  接收用户 Opts map，返回 {ok, ctx()}。
%%          必须在返回的 ctx 中填入 module/dim/config 三个字段。
%% embed/2: 接收 ctx 的 config map + Text binary，返回 {ok, Vec} | {error,_}。
%%          注意：框架调用时只传 config 子 map，不是完整 ctx。
%% -------------------------------------------------------------------
-callback init(Opts :: map()) -> {ok, ctx()} | {error, term()}.
-callback embed(Config :: map(), Text :: binary()) -> {ok, Vec :: binary()} | {error, term()}.

%% embed_batch/2（**可选**）：一次编码多条。provider 没实现时框架自动退化成
%% 逐条调 embed/2，结果形状完全一致，所以调用方不必关心 provider 支不支持。
-callback embed_batch(Config :: map(), [binary()]) ->
    {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.

%% -------------------------------------------------------------------
%% Legacy behaviour (deprecated) — 旧式 embed/1 + dim/0。
%% 新代码请用 new/2 + embed/2 + dim/1。
%% 保留是为了平滑迁移现有 mock 和已部署的 callback 模块。
%% -------------------------------------------------------------------
-callback embed(Text :: binary()) -> {ok, Vec :: binary()} | {error, term()}.
-callback dim() -> pos_integer().

%% 旧回调设为 optional：新 provider 只需实现 init/1 + embed/2。
-optional_callbacks([dim/0, embed/1, embed_batch/2]).

%% -------------------------------------------------------------------
%% Framework: 构建 provider 上下文
%% -------------------------------------------------------------------
-spec new(Provider, Opts) -> {ok, ctx()} | {error, term()}
    when Provider :: openai | anthropic | {custom, module()},
         Opts    :: map().
new(openai, Opts) ->
    bitcask_embedder_openai:init(Opts);
new(anthropic, Opts) ->
    bitcask_embedder_anthropic:init(Opts);
new({custom, Module}, Opts) when is_atom(Module) ->
    Module:init(Opts).

%% -------------------------------------------------------------------
%% Framework: 使用上下文 embed
%% -------------------------------------------------------------------
-spec embed(ctx(), binary()) -> {ok, binary()} | {error, term()}.
embed(#{module := M, config := Cfg}, Text) when is_binary(Text) ->
    M:embed(Cfg, Text).

%% -------------------------------------------------------------------
%% Framework: 批量 embed
%%
%% 返回 {ok, [{ok,Vec} | {error,Reason}]} —— **逐条**结果，顺序与输入一一对应。
%% 一条失败不影响其它条：索引场景下整批失败会逼调用方丢掉整批或退化成逐条
%% 重试，两个都更差。
%%
%% provider 实现了 embed_batch/2 就用它（llama 后端一次 decode 喂多条，是索引
%% 侧的主要吞吐杠杆）；没实现就在这里退化成逐条 embed/2 —— 结果形状一致，
%% 调用方不必知道 provider 支不支持。
%% -------------------------------------------------------------------
-spec embed_batch(ctx(), [binary()]) ->
          {ok, [{ok, binary()} | {error, term()}]} | {error, term()}.
embed_batch(#{module := M, config := Cfg}, Texts) when is_list(Texts) ->
    _ = code:ensure_loaded(M),
    case erlang:function_exported(M, embed_batch, 2) of
        true  -> M:embed_batch(Cfg, Texts);
        false -> {ok, [M:embed(Cfg, T) || T <- Texts]}
    end.

%% -------------------------------------------------------------------
%% Framework: 取维度
%%   dim/1        — 模型原生维度。
%%   vector_dim/1 — 落库 / 检索维度（MRL 目标；缺省 = dim）。open 用它推出
%%                  集合的 {vector_dim, N}，put/查询的向量长度也以它为准。
%% -------------------------------------------------------------------
-spec dim(ctx()) -> pos_integer().
dim(#{dim := D}) -> D.

-spec vector_dim(ctx()) -> pos_integer().
vector_dim(#{vector_dim := V}) -> V;
vector_dim(#{dim := D})        -> D.
