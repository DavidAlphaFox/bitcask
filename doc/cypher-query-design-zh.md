# 图查询语言（Cypher 子集）设计

状态：**设计稿，待拍板（暂记 Q2，2026-11-23）**。未改代码；第 14 节是待定项。
来源：对照 LatticeDB（`~/workspace/latticedb`，嵌入式属性图数据库，查询语言是带向量 / 全文扩展的 Cypher 方言）评估
「它的增删改查语法能否在 bitcask 上实现并做成通用入口」。结论是可以做一个实用子集，按本稿的三层结构做。
关联：`src/graphdb.erl` / `graphdb_adj.erl`（图层）、`src/bitcask_query.erl` / `bitcask_query_index.erl`（现有结构化查询与二级索引）、
`src/bitcask_txn.erl`（事务）、`doc/graph-adjacency-pack-design-zh.md`（图层盘上布局）。

## 1. 结论（先说推荐）

- **做 openCypher 的一个子集，加两个扩展操作符**：`<=>`（向量距离）与 `@@`（全文匹配）。对齐的是 openCypher 的通用语义，
  不是 LatticeDB 的特殊行为；两个扩展符号沿用它的写法（PostgreSQL 生态里 pgvector 与全文检索也是这两个符号，认知成本低）。
- **三层结构**：文本前端（词法 / 语法 → AST）→ 与语法无关的**查询计划**（Erlang 项）→ 一套执行器。
  现有的 `bitcask_query` 以后也可以编译到同一套计划上；Cypher 只是其中一种前端。
- **数据模型**：属性图映射到现有图层——顶点是 `n<vid>` 文档，**标签与属性存进文档的 meta**，边沿用图层第 2 版的邻接表；
  新增一个标签索引家族和一个顶点 id 计数器。**与现有图层 API 写入的数据互通**（同一套 key）。
- **范围**：先做 LatticeDB 的示例与各语言绑定的测试实际用到的那部分（第 5 节的「一期」列），外加变长路径与最短路
  （图层已有 BFS 与双向最短路）。子查询、`FOREACH`、`UNION`、列表推导等先不做。
- 不改盘上既有格式；新增的 key 家族写进图层的 `g` 版本记录。引擎侧有一个可选依赖（第 12 节）。

## 2. 背景：LatticeDB 的查询面与实际用法

它的解析器接受相当完整的 Cypher（`MATCH` / `OPTIONAL MATCH` / `WITH` / `UNWIND` / `UNION` / `CALL {}` / `FOREACH` /
`MERGE` / 变长路径 / `shortestPath` / 各种子查询与推导）。但有三点值得注意：

1. **它自己的示例做检索时不用 Cypher**，直接调编程接口（向量检索、全文检索、取邻居、读属性）。
2. 各语言绑定的测试里发出的 Cypher 集中在很窄的一组写法上：带标签与属性的 `MATCH … RETURN`、一两跳带类型的有向展开、
   `CREATE` 节点与边、`SET` / `DELETE`、`UNWIND $list`、`properties(n)`、一种向量写法、一种全文写法、带 `ORDER BY` / `LIMIT` 的聚合、参数。
3. 向量与全文操作符只有在「整个 WHERE 就是它」时才走索引；与别的条件 `AND` 在一起时退化成逐行过滤。
   它 README 首页那条「向量 AND 全文 AND 两跳」的查询实际是标签扫描 → 展开 → 过滤。

所以值得搬的是「一门用来表达多跳图模式和临时查询的语言」，而不是用它替代现有 API。

## 3. 目标与非目标

**目标**

- 用一条文本表达：按标签 / 属性找顶点、一到多跳的模式匹配、变长路径、最短路、带条件的增删改、聚合与排序分页，
  以及把向量 / 全文检索与图模式组合在一条查询里。
- 通用：不绑定某个业务的 key 约定；参数化；结果是普通 Erlang 项；能被上层（NIF 之外的任何语言绑定）原样转发。
- 语句级原子：一条写语句要么整体生效，要么不留痕迹。
- 与图层 API、`bitcask_query` 并存，可以混用。

**非目标**

- 不追求 openCypher 全集，也不追求与 LatticeDB / Neo4j 的结果逐字节一致（列名、整数与浮点的显示、错误文案）。
- 不做模式（schema）语句的文本形式（建索引走 API），不做 `EXPLAIN` 的文本形式（提供 `explain/2` 函数）。
- 不做跨语句事务的文本语法；需要多语句原子时用 `graphdb:transaction/2` 包住多次调用。
- 不做代价优化器；规划是固定规则（第 7 节）。

## 4. 数据模型映射

| 属性图概念 | 存储 | 说明 |
|---|---|---|
| 顶点 | `<G> n <vid:64>` 文档（现有） | `text` 段留给全文正文（见下），`meta` 放属性与标签，`vector` 放向量 |
| 顶点 id | `vid`，u64 | `CREATE` 时自动分配（计数器，见 8.2）；也可以写 `{id: 42}` 指定——与图层 API 自带 id 的用法兼容 |
| 标签 | meta 里的保留键 `_labels`，字符串数组 | libbitcask 12.0.0 起 meta 支持字符串数组与 `contains` 过滤 |
| 标签索引 | 新家族 `<G> l <len:16> <label> <vid:64>`，值为空 | 与顶点写入同批落盘；`MATCH (n:Label)` 走它的前缀 range |
| 属性 | meta 的其余键 | 类型即 meta 的类型：null / bool / 整数 / 浮点 / 字符串 / 字符串数组。**没有嵌套的列表与映射** |
| 向量 | 文档的向量（每个顶点一个，Cypher 里写作 `n.embedding`） | 与 LatticeDB 相同：每库一个向量索引、每顶点一个向量 |
| 全文 | 文档的命名字段；Cypher 里对 `n.<属性> @@ '…'` 做全文匹配 | 哪些属性进全文由建库 / 建索引时声明（API），未声明的属性只存 meta |
| 边 | 图层邻接表（现有）：(src, etype, dst, rank) | 关系类型名经 `register_etype` 映射到 etype id（现有） |
| 边的身份 | (src, etype, dst, rank) | 不引入单独的边 id；`id(r)` 返回这个四元组的编码 |
| 平行边 | `rank` | `CREATE` 两个顶点间的第二条同类型边时自动取下一个 rank |
| 边属性 | 边的属性二进制（现有），内容改用 meta 编码 | 类型同顶点属性；用旧 API 写入的任意二进制解不出来时，整体暴露为 `_raw` |
| 属性索引 | 二期：`<G> x <label> <prop> <EncVal> <vid>` | 编码沿用 `bitcask_query_index` 的保序编码 |

几条约定：

- **保留名**：以下划线开头的属性名（`_labels`、`_raw`）留给实现；`id`、`embedding` 是内置属性名。
- **没有标签的顶点**是合法的：用图层 API `put_vertex` 写的顶点就是这样，`MATCH (n)` 能匹配到，`labels(n)` 返回 `[]`。
- **顶点文档原本是纯 binary 的**（旧用法）：当作只有正文、没有属性的顶点，正文暴露为属性 `text`。
- **悬挂边**（端点没有 `n` 文档）：图层允许存在。模式匹配把这种端点当作「没有标签、没有属性」的顶点，`id()` 可取。
- **属性类型的缺口**（列表、映射、字节串）在一期直接报错「不支持的属性类型」，不做隐式序列化——免得存进去的东西过滤不了。

## 5. 语法子集

「一期」是先做的；「二期」在一期稳定后做；「不做」是目前没有计划。

| 语法 | 一期 | 二期 | 不做 |
|---|---|---|---|
| `MATCH` 多个模式、`WHERE` | ✅ | | |
| 节点模式 `(v:A:B {k: e})` | ✅ | 标签表达式 `:A\|B`、`:!A` | |
| 关系模式 `-[r:T1\|T2 {k: e}]->`，三种方向 | ✅ | | |
| 变长 `*`、`*n`、`*n..m` | ✅（给默认上限，见 7.4） | | 量化路径模式 |
| 命名路径 `p = (…)`、`length` / `nodes` / `relationships` | | ✅ | |
| `shortestPath((a)-[:T*]->(b))` | ✅ | `allShortestPaths` | |
| `OPTIONAL MATCH` | | ✅ | |
| `RETURN [DISTINCT]`、别名、`RETURN *` | ✅ | | |
| `WITH`（含聚合）、`WITH … WHERE` | ✅ | | |
| `ORDER BY`、`SKIP`、`LIMIT` | ✅ | `NULLS FIRST/LAST` | |
| `UNWIND expr AS x` | ✅ | | |
| `CREATE` 节点、边、链 | ✅ | | |
| `SET n.p = e`、`SET n:L`、`SET n += {…}`、`SET n = {…}` | ✅ | | |
| `REMOVE n.p`、`REMOVE n:L` | ✅ | | |
| `DELETE`、`DETACH DELETE` | ✅ | | |
| `MERGE`（单个节点或单条边）、`ON CREATE SET` / `ON MATCH SET` | | ✅ | |
| `UNION [ALL]`、`CALL { … }`、`FOREACH`、`EXISTS { }` 等子查询 | | | ✅ |
| 列表推导、`reduce`、量词 | | | ✅ |
| `CALL db.labels()` 等内置过程 | | ✅（做成函数也可） | 用户过程 |
| 参数 `$name` | ✅ | | |
| 注释 `//` | ✅ | | |
| 模式语句、`EXPLAIN` / `PROFILE`、`LOAD CSV` | | | ✅（走 API） |

**表达式（一期）**

- 字面量：整数、浮点、字符串、`true` / `false` / `null`、列表（仅用于 `IN`、`UNWIND`、向量字面量）、映射（仅用于属性映射）。
- 比较 `= <> < <= > >=`，逻辑 `AND OR NOT`，算术 `+ - * / %`，`IN`，`IS [NOT] NULL`，`STARTS WITH` / `ENDS WITH` / `CONTAINS`。
- 函数：`id`、`labels`、`type`、`properties`、`coalesce`、`size`、`toInteger` / `toFloat` / `toString`、`toLower` / `toUpper`、`score`。
- 聚合：`count`（含 `count(*)`、`count(DISTINCT x)`）、`sum`、`avg`、`min`、`max`、`collect`。分组是隐式的。
- 二期：`CASE`、正则 `=~`、字符串函数（`substring` / `replace` / `split` / `trim`）、`head` / `tail` / `last` / `range`。

**空值语义**按 openCypher 的三值逻辑；`SET n.p = null` 等于删除该属性。

## 6. 架构

```
文本 ──► 词法 / 语法 ──► AST ──► 语义检查 ──► 逻辑计划 ──► 执行器 ──► 行
         （leex / yecc）          （变量、类型、   （Erlang 项，    （拉取式算子）
                                   读写分类）      与语法无关）
```

新增模块（暂名）：

| 模块 | 职责 |
|---|---|
| `bitcask_cypher_lexer.xrl` / `bitcask_cypher_parser.yrl` | 词法与语法（OTP 自带的 leex / yecc，rebar3 直接编译，不引入依赖） |
| `bitcask_cypher_sema` | 变量绑定、聚合位置、读 / 写分类、保留名与类型检查，产出带位置的错误 |
| `bitcask_plan` | 逻辑计划的定义与规划规则。**与 Cypher 无关**——节点是算子元组 |
| `bitcask_exec` | 执行器：每个算子一个 `open/next/close`，行是变量名 → 值的 map |
| `bitcask_cypher` | 对外入口：`q/2,3`、`prepare/2`、`explain/2`、`writes/1` |
| `graphdb_schema` | 标签索引、id 计数器、属性 / 全文索引声明（都是图层 key 家族上的读写） |

**逻辑计划的算子（一期）**

| 类别 | 算子 |
|---|---|
| 取点 | `node_by_id`、`label_scan`、`all_nodes_scan`、`fts_seek`、`vector_seek`（二期：`prop_index_seek` / `prop_index_range`） |
| 展开 | `expand`（一跳，可指定类型与方向；端点已绑定时是「展开到」）、`var_expand`、`shortest_path` |
| 关系代数 | `filter`、`project`、`aggregate`、`distinct`、`sort`、`top_k`、`skip`、`limit`、`unwind`、`cross`（嵌套循环） |
| 向量 / 全文 | `vector_rank`（对输入行里的顶点按向量距离排序 / 截断）、`fts_filter` |
| 写 | `create_node`、`create_edge`、`set_props`、`set_labels`、`remove_props`、`remove_labels`、`delete_node`、`delete_edge`、`detach_delete` |
| 屏障 | `materialize`（写算子之前把读做完，见 8.1） |

`bitcask_query` 现有的三类条件（key / text / where）以后可以编译成 `fts_seek` / `vector_seek` / range 扫描 + `filter` 的组合，
共用执行器；这是三期的事，一期不动它。

## 7. 规划规则

没有统计信息，规则固定，可用 `explain/2` 查看结果。

### 7.1 起点选择

一个 MATCH 里每个连通的模式选一个起点，优先级：

1. `id(n) = …` / `id(n) IN […]` / 内联 `{id: …}` → `node_by_id`
2. 该变量上有 `@@` 条件且是整个 WHERE 的合取项 → `fts_seek`
3. 整个 WHERE 就是该变量的一个 `<=>` 条件 → `vector_seek`
4. （二期）有属性索引可用的等值 / 范围条件 → 属性索引
5. 有标签 → `label_scan`（多个标签取任意一个扫，其余做过滤）
6. 都没有 → `all_nodes_scan`（扫 `n` 家族；对大图会很慢，`explain` 里标出）

多个候选时，按模式书写顺序取第一个优先级最高的。

### 7.2 展开与连接

- 从起点沿模式向两边逐跳 `expand`；另一端已绑定时用「展开到」（查一条边是否存在：图层的 `edge/5` 点查）。
- 互不连通的模式用 `cross`。不做哈希连接，不做连接重排。
- 同一个 MATCH 内一条边不匹配两次（openCypher 的关系唯一性）。

### 7.3 条件下推

- 只涉及单个顶点属性的合取项：能翻译成 meta 过滤的（等值、范围、`IN`、`IS NULL`、字符串数组 `contains`）下推到取点算子；
  其余在 `filter` 里用 Erlang 求值。求值语义与引擎 meta 过滤对齐（整数与浮点不互等这一点会写进文档——见 14 节待定项 4）。
- 展开得到的顶点需要读属性时才读 `n` 文档；只用到 `id` 的不读。

### 7.4 变长路径

- `var_expand` 用图层现有的按层展开；路径内一条边不重复。
- **不写上限时给默认上限**（建议 10 跳），超出要显式写 `*..n`；LatticeDB 没有上限，深图上一条查询能跑到内存耗尽。
- `shortestPath` 直接用图层的双向 BFS。

### 7.5 排序与分页

`ORDER BY … LIMIT k` 合并成 `top_k`；`ORDER BY` 的表达式与 `vector_seek` / `fts_seek` 的天然顺序一致时不再排序。

## 8. 写语义

### 8.1 语句原子性与读写隔离

- 一条写语句 = 一次图层写会话 = **一条带条件的原子批**。语句里读过的头、块、顶点都带版本条件（图层已有的读集校验），
  别的写者插进来 ⇒ 整批被拒 ⇒ **整条语句从头重跑**（默认 8 次，指数退避，同 `put_edge`）。
- 写算子之前有 `materialize`：先把 MATCH 部分全部算完，再开始改——避免「边改边读到自己刚写的东西」。
- 一条语句涉及的顶点数有上限（建议 4096，可调）；超出报错并提示用 `UNWIND` 分批。大批量装载仍然推荐 `graphdb:put_edges/2`。
- 语句内的写在返回前落盘（同其它写入口的持久性策略）。

### 8.2 顶点 id 分配

计数器存在 `<G> c`。`CREATE` 语句在同一个原子批里「带版本条件读计数器 → 写回 计数器 + 本语句新建的顶点数」，
所以 id 分配与顶点创建同批原子、并发语句不会拿到同一个 id，也不需要进程内缓存。
用图层 API 自带 id 写入的顶点不经过计数器；计数器只保证自己发出去的 id 不重复，
所以**混用时由调用方保证手工 id 不落在计数器范围内**（建议计数器从 2^48 起步，把低位留给手工 id）。

### 8.3 各写子句

| 子句 | 落到 |
|---|---|
| `CREATE (n:L {…})` | 分配 id；写 `n` 文档（meta = 属性 + `_labels`）；每个标签写一条标签索引项 |
| `CREATE (a)-[:T {…}]->(b)` | `register_etype`（已注册则只读）；图层写会话加一条边；属性按 meta 编码 |
| `SET n.p = e` / `+=` / `=` | 读出 meta、改、写回（同批）；被全文声明覆盖的属性同步更新命名字段 |
| `SET n:L` / `REMOVE n:L` | 改 `_labels`，同批增删标签索引项 |
| `SET n.embedding = [...]` / `$vec` | 写文档的向量；`null` 即移除 |
| `DELETE r` | 图层删边 |
| `DELETE n` | 顶点还有边 ⇒ 报错；否则删 `n` 文档与标签索引项 |
| `DETACH DELETE n` | 图层的级联删顶点（事务版，单批）+ 标签索引项 |

没有唯一性约束。`MERGE`（二期）是「按给定标签 + 属性找，找不到就建」，在一条语句的原子批内完成，
并发的两条相同 `MERGE` 由读集条件保证不会各建一个。

### 8.4 与事务的关系

- `bitcask_cypher:q/2` 自成一条语句。
- `graphdb:transaction(H, fun(Tx) -> bitcask_cypher:q(Tx, …), … end)`：多条语句共用一个事务，提交时一起落盘；
  语句内的读走事务的锁与缓冲。事务里不做语句级重跑（冲突由事务层统一重跑）。

## 9. 向量与全文

### 9.1 `<=>`

- `n.embedding <=> $q` 的值是库配置的度量下的距离（越小越近）。右边是参数（f32 二进制或数值列表）或数值列表字面量。
- 走索引的两种形态（整个 WHERE 只有它时）：
  - `WHERE n.embedding <=> $q < t` —— 阈值形式；
  - `ORDER BY n.embedding <=> $q LIMIT k` —— 最近 k 个。
- **与图模式组合**：MATCH 先产出候选顶点，再按向量排序 / 截断（`vector_rank`）。候选集由图给出时不走图遍历，逐个精确计算。
  一期在 BEAM 里做（读回候选的向量算距离，候选上千时每条查询毫秒级）；引擎提供「在给定候选里排序」的入口后换成引擎做（第 12 节）。
- **与别的属性条件组合**：能下推成 meta 过滤的条件随向量检索一起下推；引擎在过滤很严时可能回不满（同第 12 节的反馈），
  这时结果不足 k 条，`explain` 与返回的统计里标出「可能未穷尽」。

### 9.2 `@@`

- `n.prop @@ '查询串'`：`prop` 必须是声明过全文的属性，且变量带标签（用来定位声明）。
- 查询串的写法取 LatticeDB 那套最小集合，翻译成引擎的布尔检索：并列的词全部必须出现、大写 `OR`、`-词` 排除、`"短语"`、`前缀*`、`词~` 模糊。
  引擎自己的检索形态（近邻、通配、多字段）通过函数形式暴露（二期：`fts.near(n.prop, '…', 3)` 一类），不塞进查询串。
- `score(n)` 返回该行的 BM25 分；没有经过全文检索的行为 `null`。`ORDER BY score(n) DESC LIMIT k` 直接用检索的天然顺序。
- 分词由库的 analyzer 决定（建库时定，meta 里有记录），Cypher 层不另设。

### 9.3 混合

`WHERE n.text @@ '…' AND n.embedding <=> $q < t`：一期按「全文取点 → 向量过滤」执行（与 LatticeDB 相同）。
引擎的混合检索（RRF）通过函数形式暴露，放二期。

## 10. 对外接口与结果

```erlang
bitcask_cypher:q(HandleOrTx, Query)                    -> {ok, Result} | {error, Error}.
bitcask_cypher:q(HandleOrTx, Query, Params)            -> 同上；Params :: #{binary() | atom() => Value}
bitcask_cypher:prepare(Handle, Query)                  -> {ok, Prepared} | {error, Error}.   %% 解析 + 语义检查一次，多次执行
bitcask_cypher:explain(Handle, Query)                  -> {ok, PlanTerm} | {error, Error}.
bitcask_cypher:writes(Query | Prepared)                -> boolean().

Result :: #{columns := [binary()],
            rows    := [[Value]],
            stats   := #{nodes_created => N, edges_created => N, props_set => N, …,
                         vector_exhaustive => boolean()}}
Error  :: #{stage := parse | semantic | plan | exec, message := binary(),
            line => L, column => C}
```

- **值的形态**：标量按 Erlang 自然类型；字符串是 binary；向量是 f32 小端 binary；
  **顶点**返回 `#{id, labels, properties}`、**边**返回 `#{src, type, dst, rank, properties}`——
  不像 LatticeDB 那样只回一个整数 id（那样客户端每个顶点还得再查一次）。只要 id 的写 `RETURN id(n)`。
- 列名：有别名用别名，没有别名用源文本（同 openCypher 的常见实现；文档会建议总是写别名）。
- 结果一次性物化。分页用 `SKIP` / `LIMIT`；流式游标放二期（执行器本身是拉取式的，接口上加一个 `cursor` 即可）。
- 解析结果按查询文本缓存在调用方持有的 `Prepared` 里；不做进程外的全局缓存。

## 11. 与现有接口的关系

| 现有入口 | 关系 |
|---|---|
| `graphdb:*`（顶点、边、遍历、事务） | 同一套 key，随意混用。用它写的顶点没有标签；用它写的边属性若不是 meta 编码则暴露为 `_raw` |
| `graphdb_analytics` | 不变。Cypher 不做图算法；要 PageRank 之类仍然物化成 CSR |
| `bitcask_query` | 并存。它面向「文档集合」（key 前缀 + 全文 + meta），Cypher 面向「图」。三期考虑让两者共用执行器 |
| `bitcask_query_index`（meta 二级索引） | 属性索引（二期）复用它的保序编码，但放在图层自己的家族里、按标签划分 |
| 普通 KV / 文档 key | Cypher 只看图层家族（`<G>` 前缀）下的 key，碰不到应用自己的 key |

## 12. 依赖与缺口

| 依赖 | 状态 | 没有时怎么办 |
|---|---|---|
| 引擎「在给定候选里按向量排序」的入口 | 已提上游反馈 `libbitcask/feedbacks/2026-11-23-filtered-vector-search-incomplete-no-candidate-scoring.md` | 一期在 BEAM 里读回向量自己算（候选多时慢）；接口不变，之后替换实现 |
| 带过滤的向量检索回不满 k | 同上一条反馈 | 结果统计里标 `vector_exhaustive => false` |
| meta 没有嵌套类型 | 引擎现状 | 属性类型限制写进文档；真有需求时再评估（盘上格式 + ABI） |
| 标签索引、id 计数器、属性索引家族 | 本设计新增（图层 key） | — |
| 边属性的 meta 编码 | 本设计的约定（图层不解释边属性，无格式变更） | — |
| leex / yecc | OTP 自带 | — |

图层的 `g` 记录需要记下「本库启用了 Cypher 模式（有标签索引与计数器）」：没启用的库第一次执行写语句时初始化（写计数器起点）；
读语句对没有标签索引的库照常工作（`label_scan` 对没有任何索引项的标签返回空）。**已有顶点不会自动获得标签**。

## 13. 分期

| 期 | 内容 | 验收 |
|---|---|---|
| **Q2-1** | 词法 / 语法 / AST / 语义检查；`writes/1`、带位置的错误 | 第 5 节一期语法逐条有正反用例；非法输入报出行列 |
| **Q2-2** | 数据模型：`graphdb_schema`（标签索引、计数器）、顶点 meta 约定、边属性编码 | 与图层 API 混写后 `check_invariants` 通过；标签索引与 `_labels` 一致性检查 |
| **Q2-3** | 计划与执行器（读）：取点、展开、过滤、投影、聚合、排序分页、`UNWIND`、变长、最短路 | 一组「同一查询 vs 用图层 API 手写」的对照用例；`explain` 输出稳定 |
| **Q2-4** | 写：`CREATE` / `SET` / `REMOVE` / `DELETE` / `DETACH DELETE`；语句原子性与冲突重跑 | 并发写用例（多进程同一 hub）；语句中途失败不留痕迹；事务内多语句 |
| **Q2-5** | `<=>` 与 `@@`：两种走索引的形态 + 与图模式的组合；`score()` | 与直接调 `search_vector` / 全文检索的结果一致；组合查询对照暴力计算 |
| **Q2-6** | 文档（中英）、示例、基准（单点查询、两跳、装载） | 基准写进设计稿落地记录 |
| 二期 | `OPTIONAL MATCH`、`MERGE`、命名路径、属性索引、`CASE` / 正则 / 字符串函数、流式游标、全文与混合检索的函数形式 | — |
| 三期 | `bitcask_query` 编译到同一套计划 | — |

## 14. 待定项

| # | 问题 | 建议 |
|---|---|---|
| 1 | 模块与入口命名（`bitcask_cypher` 还是放在 `graphdb` 名下） | `bitcask_cypher`（对外），计划与执行器用 `bitcask_plan` / `bitcask_exec`，为三期留位置 |
| 2 | 顶点 / 边在结果里的形态 | 返回带标签与属性的 map（第 10 节）；只要 id 时写 `id(n)` |
| 3 | 自动分配的 id 从哪起步 | 2^48，把低位留给图层 API 的手工 id |
| 4 | 数值比较：`1 = 1.0` 为真（openCypher）还是假（引擎 meta 过滤现状） | 语言层按 openCypher 为真；下推到引擎时把一个等值条件拆成整数与浮点两个分支的 `or` |
| 5 | 变长路径的默认上限 | 10 跳，可用 `*..n` 显式放宽 |
| 6 | 一条写语句涉及的顶点上限 | 4096，可调 |
| 7 | 全文查询串用 LatticeDB 的最小写法，还是直接暴露引擎现有的查询形态 | 查询串用最小写法；引擎特有的形态走函数（二期） |
| 8 | 一期是否包含 `MERGE` 与 `OPTIONAL MATCH` | 不包含（LatticeDB 绑定的测试也基本不用），放二期 |
| 9 | 属性里出现列表 / 映射时 | 一期报错；不做隐式序列化 |
