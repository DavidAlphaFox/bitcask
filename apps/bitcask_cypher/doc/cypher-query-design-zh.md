# 图查询语言（Cypher 子集）设计

状态：**Q2-1～Q2-6 已实现（2026-11-23，未提交）**；第 14 节已按建议定稿。落地记录见第 15、16 节；使用说明见 `doc/cypher-zh.md` / `doc/cypher-en.md`。
修订（2026-11-23）：**图的增删改查只有一个模型**——顶点 id、标签、属性、标签索引都归图层（`graphdb`）管，图层 API 与 Cypher 语句是
同一套 CRUD 的两个入口（第 4、8.2、11 节）。原稿「Cypher 自带计数器、从 2^48 起把低位留给 API 手工 id」的做法作废。
来源：对照 LatticeDB（`~/workspace/latticedb`，嵌入式属性图数据库，查询语言是带向量 / 全文扩展的 Cypher 方言）评估
「它的增删改查语法能否在 bitcask 上实现并做成通用入口」。结论是可以做一个实用子集，按本稿的三层结构做。
关联：`src/graphdb.erl` / `graphdb_adj.erl`（图层）、`src/bitcask_query.erl` / `bitcask_query_index.erl`（现有结构化查询与二级索引）、
`src/bitcask_txn.erl`（事务）、`../../../doc/graph-adjacency-pack-design-zh.md`（图层盘上布局）。

## 1. 结论（先说推荐）

- **做 openCypher 的一个子集，加两个扩展操作符**：`<=>`（向量距离）与 `@@`（全文匹配）。对齐的是 openCypher 的通用语义，
  不是 LatticeDB 的特殊行为；两个扩展符号沿用它的写法（PostgreSQL 生态里 pgvector 与全文检索也是这两个符号，认知成本低）。
- **三层结构**：文本前端（词法 / 语法 → AST）→ 与语法无关的**查询计划**（Erlang 项）→ 一套执行器。
  现有的 `bitcask_query` 以后也可以编译到同一套计划上；Cypher 只是其中一种前端。
- **数据模型只有一个，归图层管**：顶点是 `n<vid>` 文档，**标签与属性存进文档的 meta**，边沿用图层第 2 版的邻接表；
  顶点 id 的分配、标签索引、属性编码都在 `graphdb` 里实现。图层 API 与 Cypher 是同一套 CRUD 的两个入口——
  API 建的顶点 Cypher 能按标签找到，Cypher 建的顶点 API 能按 id 读写，id 是同一个数。
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
| 顶点 id | `vid`，u64，**全库一个 id 空间** | 由图层统一分配（8.2）：API 的 `graphdb:create_vertex` 与 Cypher 的 `CREATE` 走同一个分配器；指定 id 写入（API 的 `put_vertex(H, Vid, …)`、`put_edge` 的端点）照常可用，分配器保证不发出已被占用的 id |
| 标签 | meta 里的保留键 `_labels`，字符串数组 | libbitcask 12.0.0 起 meta 支持字符串数组与 `contains` 过滤 |
| 标签索引 | 新家族 `<G> l <len:16> <label> <vid:64>`，值为空 | 由图层维护：凡经图层写顶点（API 或 Cypher）都与顶点同批增删索引项；`MATCH (n:Label)` 走它的前缀 range |
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
- **没有标签的顶点**是合法的（不带标签写入的顶点，或悬挂端点）：`MATCH (n)` 能匹配到，`labels(n)` 返回 `[]`。
  图层 API 同样能写标签与属性（第 11 节），不是只有 Cypher 才能建「完整」的顶点。
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
| `bitcask_cypher_plan` | 逻辑计划的定义与规划规则。**与 Cypher 无关**——节点是算子元组 |
| `bitcask_cypher_exec` | 执行器：每个算子一个 `open/next/close`，行是变量名 → 值的 map |
| `bitcask_cypher` | 对外入口：`q/2,3`、`prepare/2`、`explain/2`、`writes/1` |
| `graphdb`（扩展） | 图模型本身：顶点 id 分配器、标签与标签索引、顶点 / 边属性的 meta 编码。API 与 Cypher 执行器都调它，Cypher 不另存一份模型 |
| `graphdb_schema` | 属性 / 全文索引声明（二期的属性索引家族） |

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

### 8.2 顶点 id 分配（图层统一）

全库只有一个 id 空间、一个分配器，实现在 `graphdb`（不是 Cypher 层）。所有「新建顶点、不指定 id」的入口都走它：
API 的 `graphdb:create_vertex/2,3`（新增，返回 `{ok, Vid}`）与 Cypher 的 `CREATE (n …)`。指定 id 的写入照常可用，
id 就是顶点的地址——写一个已存在的 id 就是改那个顶点，这是 API 一贯的语义，Cypher 里用 `MATCH (n) WHERE id(n) = 42` 定位同样的顶点。

- **高水位计数器** `<G> c`：值是「下一个可发的 id」，从 1 起（没有为谁预留的号段）。
- **分配**：在建顶点的那条原子批里「带版本条件读计数器 → 写回 计数器 + 本次新建的顶点数」，同时对每个发出的 id 带
  `n<vid>` 与 `a<vid>` 都不存在的条件。所以分配与创建同批原子，并发分配拿不到同一个 id；**分配器永远不会覆盖已有的顶点或邻接表**。
  条件不成立（被并发写占了）⇒ 整批重来，重读计数器。
- **指定 id 的写入推高水位**：`put_vertex(H, Vid, …)`、`put_edge` / `put_edges` 的端点在 `Vid ≥ 计数器` 时，写数据之前先用一条小原子批把计数器
  推到 `Vid + 1`（带版本条件；`put_edges` 整批只推一次，取最大的端点）。与数据写入不同批：数据写失败时水位偏高、id 空过去（本来就不回收），
  不会让分配器发出已占用的 id（分配还带存在性条件）。`Vid < 计数器` 时只多一次计数器的点读（约 0.2 µs）、不写，
  不会让计数器成为写热点。于是手工编号 1..N 装进来之后，下一次自动分配从 N+1 开始，不必一个个试探。
- **已有的库**（启用之前全靠手工 id）：计数器键在第一次自动分配时才建；在那之前指定 id 的写入不碰它。建的时候取 `n` / `a` 两个家族的最大 vid
  （vid 是定宽大端，在 vid 上二分，每个家族 64 次区间探测）加 1。计数器键本身就是「已初始化」的标志，不另写 `g` 记录。
- **不回收**：删掉的顶点的 id 不再发出（计数器只增不减）。计数器到 2^64 − 1 之后自动分配报 `{error, vid_exhausted}`，指定 id 写入不受影响。
- 事务里（`graphdb:transaction`）的分配同样经计数器，计数器键在事务里拿写锁；Cypher 写语句与 API 共用这一条路径。

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

图层 API 与 Cypher 是**同一套图 CRUD 的两个入口**：同一个数据模型、同一个 id 空间、同一份标签索引。能用语句做的增删改查，
API 都有对应的调用（反过来，批量装载、图算法这类 API 专长的事不必进语句）。

| 现有入口 | 关系 |
|---|---|
| `graphdb:*`（顶点、边、遍历、事务） | 同一套 key、同一个模型。补齐与语句对等的能力：`create_vertex(H, #{labels, props, text, vector})` 自动分配 id；`put_vertex` 收同样的 map（标签 / 属性 / 正文 / 向量）、按需维护标签索引；`set_labels` / `remove_labels`；`vertices_by_label`；边属性收 map（meta 编码），旧的任意二进制属性照收、在 Cypher 里暴露为 `_raw` |
| `graphdb_analytics` | 不变。Cypher 不做图算法；要 PageRank 之类仍然物化成 CSR |
| `bitcask_query` | 并存。它面向「文档集合」（key 前缀 + 全文 + meta），Cypher 面向「图」。三期考虑让两者共用执行器 |
| `bitcask_query_index`（meta 二级索引） | 属性索引（二期）复用它的保序编码，但放在图层自己的家族里、按标签划分 |
| 普通 KV / 文档 key | Cypher 只看图层家族（`<G>` 前缀）下的 key，碰不到应用自己的 key |

## 12. 依赖与缺口

| 依赖 | 状态 | 没有时怎么办 |
|---|---|---|
| 引擎「在给定候选里按向量排序」的入口 | ✅ libbitcask 12.1.0（`Cask::rank_by_vector`），本库 `bitcask:vector_rank/3,4` | — |
| 带过滤的向量检索回不满 k | ✅ 部分解决：libbitcask 12.1.0 的 HNSW 在图不超过 2^20 个节点时回满 | 更大的图、IVF-RQ / DiskANN 引擎：结果统计里标 `vector_exhaustive => false` |
| meta 没有嵌套类型 | 引擎现状 | 属性类型限制写进文档；真有需求时再评估（盘上格式 + ABI） |
| 标签索引、id 计数器、属性索引家族 | 本设计新增（图层 key，由 `graphdb` 维护） | — |
| 边属性的 meta 编码 | 本设计的约定（图层不解释边属性，无格式变更） | — |
| leex / yecc | OTP 自带 | — |

不需要在 `g` 记录里登记：id 计数器第一次自动分配时才建（起点 = 现有最大 vid + 1，见 8.2），标签索引项随带标签的写入出现。
读语句对没有标签索引的库照常工作（`label_scan` 对没有任何索引项的标签返回空）。**已有顶点不会自动获得标签**——标签只在写入时给。

## 13. 分期

| 期 | 内容 | 验收 |
|---|---|---|
| **Q2-1** | 词法 / 语法 / AST / 语义检查；`writes/1`、带位置的错误 | 第 5 节一期语法逐条有正反用例；非法输入报出行列 |
| **Q2-2** | 统一数据模型（在 `graphdb` 里）：id 分配器与高水位、标签与标签索引、顶点 / 边属性的 meta 编码；对应的 API（`create_vertex`、带标签 / 属性的 `put_vertex`、`set_labels`、`vertices_by_label`） | API 与语句混写后 `check_invariants` 通过（含标签索引与 `_labels` 一致、计数器不低于任何已用 vid）；指定 id 装载后自动分配不撞号；并发分配不重号 |
| **Q2-3** | 计划与执行器（读）：取点、展开、过滤、投影、聚合、排序分页、`UNWIND`、变长、最短路 | 一组「同一查询 vs 用图层 API 手写」的对照用例；`explain` 输出稳定 |
| **Q2-4** | 写：`CREATE` / `SET` / `REMOVE` / `DELETE` / `DETACH DELETE`；语句原子性与冲突重跑 | 并发写用例（多进程同一 hub）；语句中途失败不留痕迹；事务内多语句 |
| **Q2-5** | `<=>` 与 `@@`：两种走索引的形态 + 与图模式的组合；`score()` | 与直接调 `search_vector` / 全文检索的结果一致；组合查询对照暴力计算 |
| **Q2-6** | 文档（中英）、示例、基准（单点查询、两跳、装载） | 基准写进设计稿落地记录 |
| 二期 | `OPTIONAL MATCH`、`MERGE`、命名路径、属性索引、`CASE` / 正则 / 字符串函数、流式游标、全文与混合检索的函数形式 | — |
| 三期 | `bitcask_query` 编译到同一套计划 | — |

## 14. 待定项

| # | 问题 | 建议 |
|---|---|---|
| 1 | 模块与入口命名（`bitcask_cypher` 还是放在 `graphdb` 名下） | `bitcask_cypher`（对外），计划与执行器用 `bitcask_cypher_plan` / `bitcask_cypher_exec`，为三期留位置 |
| 2 | 顶点 / 边在结果里的形态 | 返回带标签与属性的 map（第 10 节）；只要 id 时写 `id(n)` |
| 3 | ~~自动分配的 id 从哪起步~~ | **已定（2026-11-23）**：id 统一由图层分配，从 1 起，指定 id 写入推高水位（8.2）；不再按号段区分 API 与语句 |
| 3a | 指定 id 的写入要不要推高水位（每次多一次计数器点读，约 0.2 µs；`put_edges` 整批一次） | 要。否则手工装载 1..N 之后自动分配要逐个试探 N 次 |
| 4 | 数值比较：`1 = 1.0` 为真（openCypher）还是假（引擎 meta 过滤现状） | 语言层按 openCypher 为真；下推到引擎时把一个等值条件拆成整数与浮点两个分支的 `or` |
| 5 | 变长路径的默认上限 | 10 跳，可用 `*..n` 显式放宽 |
| 6 | 一条写语句涉及的顶点上限 | Q8 起缺省不限，应用环境 `cypher_max_write_vertices` 可设上限（原 4096） |
| 7 | 全文查询串用 LatticeDB 的最小写法，还是直接暴露引擎现有的查询形态 | 查询串用最小写法；引擎特有的形态走函数（二期） |
| 8 | 一期是否包含 `MERGE` 与 `OPTIONAL MATCH` | 不包含（LatticeDB 绑定的测试也基本不用），放二期 |
| 9 | 属性里出现列表 / 映射时 | 一期报错；不做隐式序列化 |

## 15. 落地记录（Q2-1～Q2-3，2026-11-23）

**模块**

| 模块 | 内容 |
|---|---|
| `graphdb_model`（新） | id 高水位 `<G> c`（`<<N:72/big>>`，装得下 2^64）与分配器、`max_vid`（在 vid 上二分，每家族 64 次区间探测）、标签索引 `<G> l…`、顶点 / 边属性的 meta 编码与校验 |
| `graphdb`（扩展） | `create_vertex/2,3`、`vertex/2`、`set_labels/3`、`remove_labels/3`、`vertices_by_label/2,3`；`put_vertex` 收模型 map、同批维护标签索引、推高水位；`put_edge` / `put_edges` / `put_edge_txn` / `put_vertex_txn` 推高水位；`del_vertex` / `del_vertex_txn` / `put_vertex_txn` 删旧标签的索引项；边属性收 map；`check_invariants` 多查标签索引一致与水位 |
| `bitcask_cypher_lexer.xrl` / `bitcask_cypher_parser.yrl` | 第 5 节一期语法全部（含写子句、`<=>` / `@@`）；`STARTS WITH` 等合成一个记号；关键字可作属性名 / 标签 / 关系类型（保留原文） |
| `bitcask_cypher_sema` | 作用域、关系变量唯一、聚合位置与嵌套、子句顺序、WITH 别名、ORDER BY 在聚合 / DISTINCT 之后只能用投影列、变长缺省 1..10、列名 |
| `bitcask_cypher_plan` | 第 7 节规则：已绑定 > `id()` 条件 > 标签扫描 > 全量扫描；逐跳展开、另一端已绑定时展开到；合取项变量齐全即过滤；最短路最后展开 |
| `bitcask_cypher_exec` / `bitcask_cypher_expr` | 惰性流水线（`LIMIT` 提前停扫）；查询内缓存顶点 / 边属性 / 类型名；openCypher 三值逻辑、全序排序、隐式分组；单一类型的有向 `shortestPath` 走图层双向 BFS，其余走执行器的 BFS |
| `bitcask_cypher` | `q/2,3`、`prepare/2`、`explain/2`、`writes/1`、`parse/1`；错误带阶段与行列 |

**验证**：`graphdb_model_tests`（12：分配、水位推高、计数器初始化、vid 两端极值与 `vid_exhausted`、绕过图层占号时越过、16 进程并发建 800 个顶点不重号、标签替换 / 增删 / 删顶点时索引同步、边属性 map、校验、不变式能查出索引与水位损坏）；
`bitcask_cypher_tests`（95：一期语法逐条正例 49 条；31 条非法输入逐条核对阶段 / 行列 / 文案；执行用例对照图层 API 手算——展开、展开到、关系唯一性、变长、最短路、WHERE 语义、聚合、DISTINCT / 排序 / 分页、UNWIND / WITH、函数、参数、`explain` 的起点选择、`LIMIT 1` 在 2000 个顶点上只取一批、随机图两跳计数）。全量 eunit 514/514，`rebar3 as prod compile` 零警告，xref / dialyzer 干净。

**实测**（本机，2 万顶点图之外的小基准；单位 µs）：

| 操作 | 改前 | 改后 |
|---|---|---|
| `put_vertex`（binary） | 1.8～2.1 | 3.4～3.9（多读一次旧标签、走带条件的原子批） |
| `put_edge`（度数 1） | 6.0～6.1 | 6.3～6.8（多读一次 id 计数器） |
| `create_vertex`（标签 + 属性） | — | 10.6～14.6 |
| 一跳：`graphdb:out_edges` / Cypher 预编译 / Cypher 文本 | 0.9 / — / — | 0.9 / 3.7～3.8 / 13.2～13.6 |
| 5000 个同标签顶点：`vertices_by_label` / `RETURN count(*)` / 带属性过滤 | — | 3.6 ms / 6.2 ms / 22.5～23.0 ms |

**没做 / 已知的缺口**

- **条件下推到引擎的 meta 过滤（7.3）没做**：属性条件都在 Erlang 里逐行求值，带属性过滤的扫描每个顶点一次 `get_doc` + 解 meta（上表约 4.5 µs/顶点）。
- `create_vertex` / 带 meta 的 `put_vertex` 偏慢：原子批里有 doc map 时一律转 dirty IO 调度器（G13 的规则），小的 doc map 批可以就地跑。
- `q/2,3` 只收句柄，还不收事务（第 8.4 节，随 Q2-4）；事务批只装 binary，事务里写带标签的顶点要等事务层支持 doc map。
- 一期语法之外的（列表下标、列表推导、`CASE` 等）报语法错误；`OPTIONAL MATCH` / `MERGE` / `allShortestPaths` / 命名的普通路径报「二期」。
- 写子句（Q2-4）、`<=>` / `@@` / `score()`（Q2-5）能解析、能检查，规划 / 执行时报「尚未实现」。

## 16. 落地记录（Q2-4～Q2-6，2026-11-23）

**写（Q2-4）**

- 实现方式与第 8.1 节的差别：没有自己拼「一次图层写会话 = 一条带条件的原子批」，而是**整条语句在一个 `bitcask_txn` 事务里执行**。
  读到的顶点 / 邻接表头都经事务读（锁 + 版本守卫，`bitcask_txn:read_doc_guarded/3` 新增：读出带 meta 的完整文档），写进缓冲，提交是一条原子批；
  冲突 / 死锁由事务层整条重跑。效果与 8.1 相同且更强：**MATCH 部分读到的东西也在读集里**（8.1 只对写到的实体带条件）。代价是事务的固定开销
  （单条 `CREATE` 约 220 µs、`SET` 约 50 µs，见第 9 节的基准）。语句可以加入调用方的事务（8.4），出错时整个事务中止 `{aborted, {cypher, E}}`。
- 写算子：`create`（`graphdb_model:txn_allocate/2` 事务内分配 id；平行边取下一个 rank）、`set` / `remove`（`txn_update_vertex/3` 读改写，
  `text` / `embedding` 落到正文 / 向量；关系属性经 `put_edge_txn` 同 rank 覆盖）、`delete`（先关系后顶点；不带 DETACH 时有边报错）。
  写子句之前的行全部物化（`materialize`）。一条语句写多少顶点缺省不限（待定项 6；原 4096）。
- 关系类型在语句开始前注册（事务不能嵌套；调用方事务里另起一个进程注册）——语句失败时类型仍留着，与 `register_etype` 的幂等语义一致。
- 顺带修掉的两处：
  - 事务里的「指定 id 推高水位」改在事务内做（`txn_bump_watermark/2`）。原先 `put_edge_txn` / `put_vertex_txn` 在事务外直接写计数器，
    同一事务若已分配过 id（对计数器带着守卫）就会守卫失效、事务反复重跑到 `retry_limit`——Cypher 的 `CREATE (a)-[:T]->(b)` 一定撞上。
  - `graphdb` 的关系类型注册表在**索引模式**下读不出来（引擎回 `#{text, meta}`，`etype_id` / `etype_name` / `register_etype` 按 binary
    匹配 ⇒ `invalid_etype_record`）：原有缺陷，索引模式的图从来注册不了关系类型。

**检索（Q2-5）**

- `<=>` 的值定为**引擎相似度分数的相反数**（cosine / dot：负内积；L2：平方距离），不另算「1 − cos」：Erlang 侧拿不到库的度量配置，
  而这样定义与 `search_vector` / `vector_rank` 的排序完全一致。
- 起点：`vector_topk`（第 9.1 节的 `ORDER BY … LIMIT` 形态，跨子句识别 MATCH 后紧跟的 RETURN / WITH）、`vector_range`（阈值形态）、
  `fts_seek`（`@@` 合取项）。第一个标签作为 `_labels contains` 下推给引擎。top-k 在过滤后不够 k 个时检索范围逐步扩大到 64 倍，
  仍不够时 `stats` 标 `vector_exhaustive => false`。候选来自图模式时用 `bitcask:vector_rank/4` 一次精确算完（排序前批量预取）。
- `@@` 只支持 `n.text`（第 9.2 节「声明过全文的属性」这一档没做：命名字段的声明与查询映射放到以后）；查询串的最小写法在 Erlang 里
  用引擎的 `search_text` / `search_phrase` / `search_wildcard` / `search_fuzzy` 取全部命中再做集合运算，`score()` 是各正向子句分数之和。
- 检索总是读引擎：写语句里看不到同一事务尚未提交的写（文档已写明）。

**文档、示例、基准（Q2-6）**：`doc/cypher-zh.md` / `doc/cypher-en.md`；`examples/cypher_demo.escript`；`test/cypher_bench`（数字见使用说明第 9 节）。

**验证**：`bitcask_cypher_write_tests`（14：建点建边与 API 核对、共享 id 空间、SET / REMOVE 各形态与类型校验、DELETE / DETACH DELETE 与原子性、
语句出错不留痕迹（含计数器）、4096 上限、8 进程并发 `SET c.n = c.n + 1` 不丢更新、并发 CREATE 不重号、事务内多语句与中止、全文各写法对照引擎、
向量 top-k / 阈值 / 图模式排序对照 `vector_rank`）；`bitcask_cypher_tests` 新增 4 条反例。全量 eunit 528/528，`prod` 编译、xref、dialyzer 干净。

**上游缺陷（基准里发现，已反馈 libbitcask）**：原子批里删除存在的 key（`tombstone_version = 2`，bitcask 默认）时，批头声明的区间多算了
4 字节 shadow 而成员没写出来，恢复时批被判为不完整——12.0.3 及更早从那里截断数据文件（静默丢数据），12.1.0 跳过这些删除、同一文件多于
64 个时 `open` 返回 `bad_crc`。图层删边 / 删顶点与 Cypher `DELETE` 都走这条路；索引模式的库正常关闭后重开就会撞上。
见 libbitcask `feedbacks/2026-11-23-atomic-batch-remove-span-overcounts-tombstone-shadow.md`；本库这一侧绕不过去。


## 17. 落地记录（G15：条件下推、计划缓存、写语句开销，13.1.0 之后）

- **7.3 节的条件下推做了**，形态与这里原设想不同：不把等值条件拆成整数与浮点两个分支交给引擎「代替」Erlang 过滤，而是把可下推的条件
  **放宽**成必要条件交给引擎（数值两种写法都查、跨类型大小比较含等号、字符串大小比较 / `IS NULL` / 列表值不下推），Erlang 侧的过滤原样
  保留——引擎只负责少读，语义上不可能多出或少掉行。对照用例：每个谓词 P 拿 `WHERE P` 与 `WHERE NOT (NOT (P))`（不匹配任何下推形态）比。
- 标签扫描不改成「扫全部顶点 + 标签过滤」（标签稀疏时会退化成扫全库）：仍按标签索引分块，块内 id 够密才对这段 id 做一次带 filter 的 range，
  文档随同读回；稀疏的块逐个读。没有下推条件、但后面要用到顶点属性的扫描（`fetch`）也走这条批量读的路。
- 第 8.1 节「一次写会话 = 一条带条件的原子批」仍然没有做成绕过事务的形态：Cypher 写若不拿写锁，对图层的悲观事务（`put_edge_txn` 等用加
  写锁、不带守卫的读）就成了直通写，可能丢更新。改为在事务里去掉多余的读锁（`{read_locks, guard_only}`：带守卫的读模式读不拿锁，提交时
  校验守卫），写锁照旧。
- 计划按查询文本缓存（调用进程的进程字典，128 条）；`id(v)` 起点紧跟一跳展开时不单独查存在。
- 数字见 TASK.md G15 与使用说明第 9 节。

## 18. 落地记录（二期第一批：OPTIONAL MATCH、MERGE、CASE）

- **OPTIONAL MATCH**：语义检查输出 `{optional_match, …}`；规划成子流水线 `{optional, [Op], NewVars}`——对每个输入行跑一遍（`WHERE` 在
  子流水线里），没有结果时交出原行、本子句新引入的变量为 `null`。起点规则与普通 MATCH 相同（已绑定的变量优先），向量 top-k 提示不用于
  可选匹配。下游对 `null` 的处理沿用已有规则：展开不出行、`SET` / `DELETE` 跳过、`CREATE` / `MERGE` 关系报错。标签扫描的「要不要取
  文档」判断会看子流水线之后的外层算子。
- **MERGE**（第 5 节表里的「单个节点或单条边」）：`{merge_node, V, Labels, Props, OnCreate, OnMatch}`、
  `{merge_rel, From, R, Type, Props, Dir, To, OnCreate, OnMatch}`。执行全复用已有算子：在事务里对当前行跑「标签扫描（无标签时全量扫描）
  + node_check」或「展开到 + rel_check」，有结果逐行套 `ON MATCH SET`，没有就走 `create_node` / `create_rel` 再套 `ON CREATE SET`。
  按标签找经 `bitcask_txn:prefix_range` 拿标签索引的前缀读锁（`{read_locks, guard_only}` 不影响前缀锁），所以并发的同一个 `MERGE`
  串行化、不重复创建（8 进程 × 10 次的用例只建一个）。属性值为 `null`、按 `embedding` 匹配、两端未绑定 / 带标签、无向 / 多类型 /
  变长都在语义检查或执行时报错。没做：端点也要 MERGE 的整条模式（`MERGE (a:X)-[:T]->(b:Y)`）。
- **CASE**：通用与简单两种形式；词法新增 `CASE WHEN THEN ELSE END`（也能当属性名 / 标签用）。只求值命中的分支；简单形式用 `=` 的
  三值语义比较（`1` 与 `1.0` 相等、`null` 不等于任何值）。聚合的查找与替换按「主体、各 WHEN/THEN、ELSE」的同一顺序编号，所以
  `sum(CASE … END)` 与 `CASE WHEN count(*) > 1 …` 都成立。
- 验证：`optional_match_test`、`case_expr_test`、`merge_node_test`、`merge_rel_test`、`merge_concurrent_test_`，以及语法 / 语义正反例。

## 19. 落地记录（二期其余）

- **普通命名路径**：语义检查输出 `{named_chain, P, Chain}`；规划在模式展开完后加 `{build_path, P, Start, [{RelVar, NodeVar}]}`，从起点
  依次接上每段关系（变长段是一串关系），下一顶点取关系的另一端；某段为 `null`（OPTIONAL MATCH）时路径为 `null`。引用路径变量的
  `WHERE` 条件排在拼路径之后。CREATE / MERGE 里不允许命名路径。
- **allShortestPaths**：`{all_shortest_paths, …}`，执行器按层 BFS 记录每个顶点在最短距离上的全部前驱，到达终点的那一层走完就停，
  再回溯出全部路径（上限 10 万条，超过报错）；不走图层的双向 BFS。
- **标签表达式**：`A`、`A|B`（`{any, [A, B]}`）、`!A`（`{'not', A}`），节点模式与 `WHERE n:…` 都能写；写标签（CREATE / MERGE / SET /
  REMOVE）只能是普通标签。起点只用普通标签做标签扫描；`A|B` 下推成引擎的 `_labels contains_any`，`!A` 不下推。
- **NULLS FIRST / LAST**：排序方向扩成 `{asc | desc, first | last}`，`null` 的位置与方向无关。`FIRST` / `LAST` 不是关键字（`last()` 仍是函数），
  在语法动作里校验。
- **`=~`**：匹配整个字符串（`^(?:P)$`），Erlang `re` 语法，编译结果按模式缓存在进程字典；模式不合法是执行错误。
- **函数**：`substring` / `replace` / `split` / `trim` / `ltrim` / `rtrim` / `left` / `right` / `reverse` / `head` / `tail` / `last` / `range`；
  按码点计长度；多参数函数任一参数为 `null` 得 `null`。
- **下标与切片**：`{index, E, I}`（列表按整数、映射 / 顶点 / 关系按字符串键）、`{slice, E, From, To}`。
- **CALL**：`db.labels()`（在标签索引里按前缀跳着取不同的标签）、`db.relationshipTypes()`（关系类型注册表）、`db.propertyKeys()`（扫顶点
  文档的 meta 键）；`YIELD x [AS y], … [WHERE …]`；单独一条 `CALL` 自动返回全部列。不做用户过程与 `CALL {}`。
- **整条模式的 MERGE**：`{merge_pattern, Find, Chain, OnCreate, OnMatch}`——查找用与 MATCH 相同的规划（子流水线），找不到就 `create_chain`
  整条建出来（openCypher 语义：端点单独存在也会新建）。单个节点、两端已绑定的单条关系仍走第 18 节的专用路径。
- 验证：`named_path_and_all_shortest_test`、`label_expr_and_ordering_test`（含 `A|B` 的下推等价对照）、`phase2_functions_test`、
  `procedures_test`、`merge_pattern_test`；语法正例 12 条、语义反例 9 条。设计稿第 5 节二期的项至此都已实现。

## 20. 落地记录（流式游标、检索的函数形式、属性索引）

- **流式游标**：`bitcask_cypher:cursor/2,3,4` 开一个独立进程，持有 `bitcask_cypher_exec:open_stream/3` 建的惰性流水线与查询内缓存；
  `fetch(Cursor, N)` 用 `next_rows/2` 往前推 N 行（多看一步判断 `done`）。游标进程 monitor 开它的进程，空闲超过 `idle_timeout`
  （缺省 5 分钟）或流完自动结束；只读语句、只能在句柄上开。排序 / 聚合 / DISTINCT 是阻塞算子，第一次 `fetch` 时物化。
- **检索的函数形式**：`fts.phrase / near / wildcard / fuzzy / fields`、`search.hybrid` 对应引擎的同名检索接口。作为 `WHERE` 合取项时
  `fts_pin` 把起点换成 `{search_seek, V, Name, Args}`（按分数出行，`score(n)` 可用）；出现在别处时按顶点判断，命中集合按
  {函数, 参数} 在一次查询内缓存（`search_set`）。
- **属性索引**：声明存在 `s` 前缀（`graphdb_model:skey/0`，值是 `{Cond, Decls}`，状态 `building` / `ready`），条目在 `x` 前缀
  （`xkey(Label, Prop, 值编码, Vid)`，值编码保序、整数与浮点分开编码）。`create_index/3` 先声明 `building`——此后所有写入就开始维护
  ——再分块回填（每块校验顶点的 ord，与并发写不冲突），最后置 `ready`；`drop_index/3` 删声明与条目。写路径（`txn_update_vertex`、
  `put_vertex_once`、`create_vertex`、`modify_labels_once`、`vertex_removal`、`drop_labels_txn`）经 `index_ops/4` 同批维护，并对声明
  加一个只校验不加锁的守卫（`bitcask_txn:peek_guarded/2`），所以与「建索引」并发的写不会漏条目。执行时 `index_seek/4` 从下推条件里
  挑可用的就绪索引（等值 > `IN` > 范围），声明在一次查询内缓存（`?SCHEMA`）。`check_invariants` 加了 `index_problems`。
- 验证：`cursor_test`、`search_functions_test`、`property_index_test_`、`property_index_concurrent_build_test_`。

## 21. 落地记录（openCypher 语法对齐）

对照 openCypher 9 的语法补齐三组；之后仍不做：`CALL {}` / `EXISTS {}` / `COUNT {}` 子查询、`FOREACH`、用户过程、`LOAD CSV`、
时间 / 空间类型、模式语句（索引 / 约束 DDL，属性索引用 `graphdb:create_index/3`）。

- **第 1 组：表达式**
  - 词法：`ALL ANY NONE SINGLE REDUCE EXISTS UNION` 成为关键字；`0x…` / `0o…` 整数。函数式关键字（前六个）在语法里另有 `soft_kw`
    规则，不跟 `(` 时仍是变量名（`MATCH (all) RETURN all`）。
  - 列表推导 `{list_comp, X, L, Where, Proj}`、量词 `{quant, all|any|none|single, X, L, Pred}`、`{reduce, Acc, Init, X, L, E}`：语义检查用
    `with_locals/2` 把局部变量盖在当前作用域上；`expr_vars` 不把局部变量算作外部引用；执行时局部变量直接绑进行 map。`[x IN …` 与
    「第一个元素是 `x IN …` 的列表字面量」在 LALR 里是一个移进 / 归约冲突，按 openCypher 取推导，语法文件 `Expect 1.` 锁住冲突数。
  - 引用局部变量的部分不能有聚合（报错）；列表 / 初值部分可以有，`walk_aggs` / `repl` 只进这两部分。
  - 映射投影 `{map_proj, Var, Items}`：`.p`、`.*`、`k: e`、`v`（变量名作键），顶点 / 关系取的属性与 `properties()` 相同，map 直接用。
  - 链式比较：比较运算改成 `Left` 结合，语法动作 `cmp/3` 在左边已是比较时改写成 `AND`（中间项求两次，没有副作用）。
  - `exists(n.prop)` → `{exists, E}`，即 `IS NOT NULL`；参数不是属性也不是模式 → 语义错误。
  - 函数：数学 / 三角 / `timestamp()`；没有实数结果的返回 `null`。聚合：`percentileCont` / `percentileDisc`（两个参数：执行器的
    `step/4` 把 `{pct, 值, 百分位}` 交给 `agg_step`）、`stDev` / `stDevP`。
- **第 2 组：模式表达式**
  - 表达式里的 `(a)-[…]->(b)` 开头与带括号的表达式在 LALR 里分不开，所以在 `bitcask_cypher` 做记号预处理 `mark_patterns/1`：只在
    表达式区（`WHERE` / `RETURN` / `WITH` / `SET` 等之后，`MATCH` / `CREATE` / `MERGE` 之后到下一个子句关键字之间不算；`ON CREATE` /
    `ON MATCH` 的 `CREATE` / `MATCH` 不切换）找「节点 (关系 节点)+」，前后插入 `PATTERN` / `PATTERN_END`。关系必须以 `-[`、`--`、`<-[`、
    `<--` 开头，所以 `(a) - (b)`、`(x) < -1` 不受影响。
  - 语法：`atom -> PATTERN chain PATTERN_END`（模式谓词）、`'[' PATTERN … PATTERN_END [WHERE e] '|' e ']'` 与 `[p = PATTERN …]`（模式推导）。
  - 语义：模式谓词里命名的节点必须已绑定、不能有关系变量；模式推导可引入局部变量。子模式经 `match_part` 检查后，匿名变量改成带唯一
    编号的名字（`rename_anon`），免得与外层同号的匿名变量撞上；规范化结果带上外层变量清单 `Outer`。
  - 执行：`bitcask_cypher_plan:sub_match/2` 把子模式规划成以 `Outer` 为已绑定变量的子流水线（与 MATCH 同一个规划器），计划按 {子模式, Outer}
    在一次查询内缓存（`?SUBPLANS`）；`bitcask_cypher_exec:pattern_rows/5` 以当前行为输入跑它，谓词取 1 行即止，推导取全部。外层变量为 `null`
    → 结果 `null`。
- **第 3 组：语句**
  - `UNION` / `UNION ALL`：语法 `query_body` 产生 `{union, [{first, 子句}, {Mode, 子句, Loc}…]}`；语义检查每段独立分析、都要以 `RETURN`
    结尾、不能混用两种；规划每段单独 `clauses/4`，列名（含顺序）必须一致，产生单个算子 `{union, Mode, [Ops], Cols}`，执行器惰性地依次
    接上各段的子流水线，`UNION` 再按列去重。写语句的各段在同一个事务里；关系类型注册会进各段收集。
  - `CREATE p = …` / `MERGE p = …`：语义检查输出 `{named_chain, P, Chain}`，规划在 `create` / `merge_pattern` 之后加 `build_path`。
    `MERGE p = …` 一律走整条模式的 MERGE。
  - `CALL proc`（省括号）、`YIELD *`（展开成全部输出列；单独一条时同不带 YIELD）。
- 验证：`opencypher_expressions_test`、`pattern_expressions_test`、`union_and_call_test`、`named_write_paths_test`；语义反例 9 条（原
  「CREATE 不允许命名路径」一条换掉）。
