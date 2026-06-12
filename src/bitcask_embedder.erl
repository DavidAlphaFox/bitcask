%% -------------------------------------------------------------------
%% bitcask_embedder:
%%   V3.6 — 外部 embedding 服务的 behaviour 抽象（hnsw-design §1：
%%   「向量进、近邻出」，引擎只收向量不算向量；推理依赖留在 Erlang 层）。
%%
%%   实现模块负责把文本变成定维向量；引擎侧（put 的 doc map vector 键 /
%%   bitcask:search_vector / bitcask:search_hybrid）只认 f32 LE 二进制。
%%
%%   Vec 格式 = f32 LE 二进制（Dim×4 字节），与 NIF 跨界 / DocValue
%%   存储格式一致，Erlang 侧构造：
%%       << <<X:32/float-little>> || X <- Floats >>
%%
%%   参考实现：bitcask_embedder_openai（OpenAI 兼容 /v1/embeddings 协议）。
%%   测试请用确定性 mock（test/bitcask_embedder_mock），不要打真实端点。
%% -------------------------------------------------------------------
-module(bitcask_embedder).

-callback embed(Text :: binary()) -> {ok, Vec :: binary()} | {error, term()}.

%% 可选：实现模块声明自己的输出维度（须等于集合 open 时的 vector_dim）。
-callback dim() -> pos_integer().

-optional_callbacks([dim/0]).
