# 能力与约束（中文）

English API: [`api-en.md`](api-en.md)。完整函数签名与参数见
[`api-zh.md`](api-zh.md)。本文只回答“能做什么、什么时候不能用、代价是什么”。

## 能力矩阵

| 领域 | 能力 | 打开方式 | 主要约束 |
|---|---|---|---|
| KV 存储 | `get` / `put` / `delete` / `sync` / `fold` / `list_keys` | 默认 KV 模式 | 每目录单写者；`fold` 是快照一致、代价 O(全表) |
| 有序范围 | `range` / `range_fold`，`[Lo, Hi)` 与前缀扫描 | 默认可写 open；依赖 OKI 索引 | 代价 O(range)；迭代期间并发写 per-key 弱一致，不是快照 |
| 原子批 | `put_batch_atomic` / `txn_commit`，可选前置条件 | 默认可用 | 首次使用会把目录 meta 升到 v6；原子可见不等于隔离 |
| 隔离事务 | `bitcask_txn`：2PL、死锁检测、自动重跑、幂等键、前缀锁 | 直接调用 | 事务函数可能重跑，必须无副作用 |
| BM25 | 全文、短语、多字段、近邻、模糊、通配符、meta filter、高亮 | open 加 `{analyzer, _}` | 未启用分析器时搜索返回 `{error, no_index}` |
| 向量检索 | 近似最近邻、meta filter、精确重排 | 索引模式 + embedder 或 `{vector_dim, N}` | 引擎与度量建库固定；磁盘档要求 cosine / dot |
| 混合检索 | BM25 与向量 RRF 融合 | 索引 + 向量路径 | 文本与向量两路都可用时效果最好；单路可退化 |
| Embedder | OpenAI 兼容 HTTP、可插拔 behaviour、本地 llama.cpp | `{embedder, _}` 或独立进程 | 本地后端默认不构建；换模型 / 维度需重建索引 |
| 图层 | 顶点、标签、边、度数、邻接读写、事务式边写 | `graphdb:open/2` | 图布局 v2；旧布局 fail-loud 拒开 |
| Cypher | openCypher 子集、参数、预编译、explain、游标 | `bitcask_cypher:q/2,3,4` | 写语句一个事务；向量 / 全文需相应模式 |
| 运维 | merge、needs_merge、status、过期、崩溃锁回收 | open 选项或显式 API | 活跃写入文件会被 merge 跳过 |

## 存储与一致性

- 盘上格式采用带类型记录（`kDoc` / `kTombstone`）和逐次写入序号（ordinal）。
- `fold` / `fold_keys` 提供快照一致的全表读取；`range` 是有序索引扫描，
  不是快照。
- 原子批对并发读者整批可见；批与批之间仍可能交错，需要用前置条件或事务层控制。
- `bitcask_txn` 在原子批之上提供悲观 2PL、死锁检测、自动重跑、幂等键和前缀锁；
  设计细节见 [`txn-layer-design-zh.md`](txn-layer-design-zh.md)。
- 过期记录对读取 API 不可见，merge 会按过期和碎片阈值回收空间。

## 文本与向量

- 分析器支持 `whitespace`、`ngram`、`jieba`。jieba 词典可用 `{dict_path, Path}`
  指定；同义词词典在 open 时通过 `{synonym_file, Path}` 固定。
- 向量引擎：`hnsw`（默认内存图）、`ivfrq`（磁盘档）、`diskann`（实验性）。
  引擎在首次写入前选定并持久化，重开不符返回 `{error, mode_mismatch}`。
- 度量支持 `cosine`、`dot`、`l2`；三者统一为“分数越大越相似”。磁盘引擎要求
  `cosine` 或 `dot`。
- HTTP embedder 无状态，可直接放在 open 选项里；本地 llama.cpp 后端有状态且
  默认不构建，详见 [`local-embedding-zh.md`](local-embedding-zh.md)。

## 图与 Cypher

- 图层把顶点属性、标签、正文和向量存成文档，邻接关系按源顶点打包；高度数
  顶点分块。
- 写边使用两端条件写与冲突重试，并发写不丢边；事务式 API 能把多条边 / 顶点
  变更同批提交。
- `bitcask_cypher` 与 `graphdb` API 共享同一 id 空间和数据模型：API 写入的数据
  可以被 Cypher 查询，Cypher 写入的数据也可以按 id 用 API 读写。
- 使用说明见 [`../apps/bitcask_cypher/doc/cypher-zh.md`](../apps/bitcask_cypher/doc/cypher-zh.md)。

## 构建能力

- 核心 NIF 由 C++23 与 libbitcask 构建生成；Erlang 侧只是薄门面。
- 常规构建需要 Erlang/OTP ≥ 27 与 ICU 开发包。
- CMake 可另开 GoogleTests、基准、ASan / TSan 构建树；Sanitizer 一次只能启用一种。
- llama.cpp 本地嵌入 NIF 通过 `BITCASK_WITH_LLAMA=1` 显式开启，默认关闭时产物
  与未引入该后端时一致。

## 常见限制

| 症状 / 约束 | 原因与处理 |
|---|---|
| `{error, write_locked}` | 目录已有活跃写者；先关闭旧句柄或换目录 |
| `{error, no_index}` | 搜索未启用分析器，或只读句柄没有 OKI；按需用索引模式 / 可写模式重开 |
| `{error, index_rebuild_failed}` | OKI 重建失败；数据仍在，修好 IO / 环境后重开重试 |
| `{error, mode_mismatch}` | 度量、向量引擎或分析器等建库固定选项与磁盘 meta 不一致 |
| `{error, {conflict, I}}` | 原子批前置条件不成立；整批零副作用，读取新版本后重试 |
| retry_limit / deadlock aborted | 事务层重跑耗尽或检测到死锁；检查事务函数副作用与锁顺序 |
| 旧版本无法打开新目录 | 部分特性会懒升级 `bitcask.meta`；先查看 CHANGELOG 中的盘上格式说明 |

## 相关文档

- 实用方法、运维与错误排查：[`USAGE.md`](USAGE.md)
- API 签名与返回值：[`api-zh.md`](api-zh.md)
- 图查询语言：[`../apps/bitcask_cypher/doc/cypher-zh.md`](../apps/bitcask_cypher/doc/cypher-zh.md)
- 本地嵌入与 GPU：[`local-embedding-zh.md`](local-embedding-zh.md)
- 事务设计：[`txn-layer-design-zh.md`](txn-layer-design-zh.md)
