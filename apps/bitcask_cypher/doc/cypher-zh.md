# 图查询语言（Cypher 子集）使用说明

English: [`cypher-en.md`](cypher-en.md)。**语法参考**（openCypher 2024.3 语法与 bitcask 特有的语法）：[`cypher-syntax-zh.md`](cypher-syntax-zh.md)。
设计与取舍：[`cypher-query-design-zh.md`](cypher-query-design-zh.md)。

`bitcask_cypher` 在 `graphdb` 图层之上提供 openCypher（按 2024.3 文法对齐），外加 bitcask 特有的检索语法：`<=>`（向量距离）、`@@`（全文匹配）与检索函数。
它和图层 API（`graphdb:*`）是**同一套图 CRUD 的两个入口**：同一个数据模型、同一个顶点 id 空间、同一份标签索引——
用 API 建的顶点能用语句按标签查到，用语句建的顶点能用 API 按 id 读写。

## 1. 快速上手

```erlang
%% 全文检索需要索引模式（{analyzer, _}），向量检索需要 {vector_dim, N}；只做图查询两者都不用。
G = graphdb:open("/data/g", [read_write, {analyzer, whitespace}, {vector_dim, 3}]),

{ok, _} = bitcask_cypher:q(G,
    "CREATE (a:Person {name: 'ann', age: 31, text: 'graph databases', embedding: [1.0, 0.0, 0.0]})"
    "-[:KNOWS {since: 2020}]->(b:Person {name: 'bob', embedding: [0.0, 1.0, 0.0]})"),

{ok, #{columns := [<<"name">>, <<"friend">>], rows := Rows}} =
    bitcask_cypher:q(G, "MATCH (a:Person {name: $n})-[:KNOWS]->(b) RETURN a.name AS name, b.name AS friend",
                     #{n => <<"ann">>}),

%% 预编译：解析与规划只做一次
{ok, P} = bitcask_cypher:prepare(G, "MATCH (n:Person) WHERE n.age > $min RETURN n ORDER BY n.age DESC LIMIT 10"),
{ok, _} = bitcask_cypher:q(G, P, #{min => 18}).
```

完整的可运行例子：[`examples/cypher_demo.escript`](../examples/cypher_demo.escript)。

## 2. 接口

| 函数 | 说明 |
|---|---|
| `q(HandleOrTx, Query)` / `q(HandleOrTx, Query, Params)` | 执行一条语句。`Query` 是 binary / 字符串，或 `prepare/2` 的结果 |
| `q(Handle, Query, Params, TxOpts)` | 同上；`TxOpts` 传给写语句的事务（`retries` / `timeout` / `lock_wait_timeout` / `sync` / `read_locks`，缺省 `[{sync, no_sync}, {read_locks, guard_only}]`：读只靠版本守卫、不拿读锁，见 `bitcask_txn`） |
| `prepare(Handle, Query)` | 解析 + 语义检查 + 规划一次，返回可反复执行的句柄 |
| `explain(Handle, Query)` | `{ok, #{ops => [算子], columns => [列名]}}`：规划结果（见第 8 节） |
| `writes(Query \| Prepared)` | 是否含写子句 |
| `parse(Query)` | 只做解析与语义检查 |
| `cursor(Handle, Query[, Params[, Opts]])` | 只读查询开一个流式游标：`{ok, Cursor}`。`Opts`：`{idle_timeout, Ms}`（缺省 300000） |
| `fetch(Cursor, N)` | 取至多 `N` 行：`{ok, Rows, more \| done}`；`done` 之后游标自动关闭 |
| `columns(Cursor)` / `close(Cursor)` | 列名；关闭（幂等） |

**流式游标**：游标是一个独立进程，持有惰性流水线与查询内缓存，`fetch` 时才推进扫描 / 展开（`LIMIT` 之前的部分按需读）；排序、聚合、
`DISTINCT` 仍要看全部输入（第一次 `fetch` 时物化）。开游标的进程退出、或空闲超过 `idle_timeout`，游标自动关闭，之后 `fetch` →
`{error, #{message := <<"cursor_closed">>}}`。只能在句柄上开（不能在事务里），写语句不能开游标。

参数 `Params :: #{binary() | atom() => Value}`：值可以是整数、浮点、binary（字符串）、`true` / `false`、`null`（`undefined` 视同 `null`）、
列表、map、时间 / 空间值（第 11 节的元组）。查询里用 `$name` 引用；缺参数是编译期错误（`semantic` 阶段）。

**结果**：`{ok, #{columns := [binary()], rows := [[Value]], stats := map()}}`

- 标量按 Erlang 自然类型；字符串是 binary；`null` 是原子 `null`。
- 顶点 `#{id, labels, properties}`；边 `#{src, type, dst, rank, properties}`（`type` 是关系类型名，没注册名字的类型是整数）；
  路径 `#{nodes, relationships}`。
- 列名：有别名用别名，没有用投影项在查询里的**原样写法**（openCypher：`RETURN cOuNt( * )` 的列名就是 `cOuNt( * )`）。没有 `RETURN` 的语句 `columns`、`rows` 都是 `[]`。
- `stats`（只列非 0 的）：`nodes_created`、`nodes_deleted`、`relationships_created`、`relationships_deleted`、`properties_set`、
  `labels_added`、`labels_removed`；用到向量检索时另有 `vector_exhaustive`（第 6.2 节）。

**错误**：`{error, #{stage := parse | semantic | plan | exec, message := binary(), type => binary(), detail => binary(),
line => L, column => C}}`。`type` / `detail` 是 openCypher 的错误类型与细节代码（与 TCK 一致，模块 `bitcask_cypher_error`）：

| `type` | 常见的 `detail` |
|---|---|
| `SyntaxError` | 解析：`UnexpectedSyntax`、`InvalidNumberLiteral`、`IntegerOverflow`、`FloatingPointOverflow`、`InvalidUnicodeLiteral`、`InvalidUnicodeCharacter`、`InvalidRelationshipPattern`；语义：`UndefinedVariable`、`VariableAlreadyBound`、`VariableTypeConflict`、`InvalidArgumentType`、`InvalidAggregation`、`NestedAggregation`、`AmbiguousAggregationExpression`、`NoExpressionAlias`、`ColumnNameConflict`、`DifferentColumnsInUnion`、`InvalidClauseComposition`、`NoSingleRelationshipType`、`RequiresDirectedRelationship`、`CreatingVarLength`、`InvalidDelete`、`InvalidParameterUse`、`NonConstantExpression`、`NegativeIntegerArgument`、`InvalidNumberOfArguments`、`InvalidArgumentPassingMode`、`UnknownFunction`、`RelationshipUniquenessViolation`、`NoVariablesInScope` |
| `ParameterMissing` | `MissingParameter` |
| `ProcedureError` | `ProcedureNotFound`（过程自己出错只有类型） |
| `TypeError` | `InvalidArgumentType`、`InvalidArgumentValue`、`InvalidPropertyType`、`MapElementAccessByNonString`、`ListElementAccessByNonInteger` |
| `ArgumentError` | `InvalidArgumentType`、`InvalidArgumentValue`、`NumberOutOfRange` |
| `ArithmeticError` | `DivisionByZero`、`IntegerOverflow` |
| `EntityNotFound` | `DeletedEntityAccess` |
| `ConstraintVerificationFailed` | `DeleteConnectedNode` |
| `SemanticError` | `MergeReadOwnWrites`；只有类型的：功能未启用（索引模式）、写顶点数超上限、端点为 null 等 |

存储 / 文件 / 内部错误不归 openCypher 的类，没有 `type`。

## 3. 数据模型

| 概念 | 存储 | 图层 API |
|---|---|---|
| 顶点 id | u64，全库一个空间 | `create_vertex/2` 分配；`put_vertex(G, Vid, _)` 指定 |
| 标签 | 顶点文档 meta 的 `_labels`（字符串数组）+ 标签索引 | `set_labels/3`、`remove_labels/3`、`vertices_by_label/2,3` |
| 属性 | 顶点文档 meta 的其余键 | `put_vertex(G, Vid, #{labels, props, text, vector})`、`vertex/2` |
| 正文 | 顶点文档的 text 段；Cypher 里是属性 `text`，全文检索针对它 | 同上的 `text` |
| 向量 | 顶点文档的向量；Cypher 里是 `embedding` | 同上的 `vector` |
| 边 | 图层邻接表 (src, etype, dst, rank) | `put_edge/5`（`props` 可以传 map） |
| 关系类型 | 名字 ⇄ etype id 注册表 | `register_etype/2`；`CREATE` 用到的新类型自动注册 |

- 属性值可以是 null、布尔、整数（int64）、浮点、字符串、时间 / 空间值，以及元素类型一致的列表（`[1, 2]`、`['a']`、`[true]`、
  `[date(…)]`；整数与浮点混放不行）。map、嵌套列表报「不支持的属性类型」。
  下划线开头的属性名保留给实现（`_labels`、`_raw`）。
- **id**：自动分配从 1 开始；指定 id 写入（`put_vertex`、`put_edge` 的端点、`graphdb:transaction` 里的事务版）超过当前水位时把水位推上去，
  之后的自动分配不会撞号；分配器在批里核对 id 未被占用，永远不会覆盖已有数据。删掉的 id 不再发出。
- 只有邻接表、没有顶点文档的顶点（用 API 只写了边）也是顶点：没有标签、没有属性。旧的纯 binary 顶点文档的正文暴露为属性 `text`。
- 边属性：用 map 写的（API 的 `props => #{}` 或 Cypher）解出来是属性 map；旧的任意二进制属性整体暴露为 `_raw`（不能在 Cypher 里改）。

## 4. 语法

下表是支持情况一览；逐条的写法与 bitcask 特有的语法见 [`cypher-syntax-zh.md`](cypher-syntax-zh.md)。

| 子句 / 写法 | 支持 |
|---|---|
| `MATCH` 多个模式、`WHERE` | ✅ |
| 节点 `(v:A:B {k: e})`、`(v $props)`（参数作属性只能在 `CREATE` 里；`MATCH` / `MERGE` 里是 `InvalidParameterUse` 错误，同 openCypher） | ✅ |
| 关系 `-[r:T1\|T2 {k: e}]->`、`<-[]-`、`-[]-`、`-->`、`<--` | ✅ |
| 变长 `*`、`*n`、`*n..m`、`*..m`、`*n..`（不写上界就不限跳数；`*1..1` 的变量也是关系列表） | ✅ |
| `p = shortestPath((a)-[:T*..n]->(b))`、`p = allShortestPaths(…)`，`length(p)` / `nodes(p)` / `relationships(p)` | ✅ |
| 普通命名路径 `p = (a)-[r]->(b)<-[*1..3]-(c)` | ✅ |
| 标签表达式 `(n:A\|B)`（任一）、`(n:!A)`（没有）、`WHERE n:A\|B` | ✅ |
| `RETURN [DISTINCT]`、别名、`RETURN *` | ✅ |
| `WITH`（含聚合、`DISTINCT`、`ORDER BY` / `SKIP` / `LIMIT`、`WITH … WHERE`） | ✅ |
| `ORDER BY … [ASC\|DESC] [NULLS FIRST\|LAST]`、`SKIP`、`LIMIT`（字面量或参数） | ✅ |
| `UNWIND expr AS x` | ✅ |
| `CREATE` 节点、关系、链，`CREATE p = (…)` 命名路径 | ✅ |
| `SET n.p = e`、`SET n += {…}`、`SET n = {…}`、`SET n:L`；关系属性同样 | ✅ |
| `REMOVE n.p`、`REMOVE n:L` | ✅ |
| `DELETE`、`DETACH DELETE` | ✅ |
| `OPTIONAL MATCH`（含 `WHERE`） | ✅ |
| `MERGE` 节点、关系、整条模式（端点可未绑定、可多跳）、`MERGE p = (…)`，`ON CREATE SET …` / `ON MATCH SET …` | ✅ |
| `CALL db.labels()` / `db.relationshipTypes()` / `db.propertyKeys()`（无参时括号可省）`[YIELD x [AS y], … [WHERE …]]`；单独一条 CALL 可以 `YIELD *` | ✅ |
| `CALL ns.proc(参数…) [YIELD …]`（注册的用户过程，第 12 节） | ✅ |
| `CASE WHEN … THEN … [ELSE …] END`、`CASE expr WHEN v THEN … END` | ✅ |
| `… UNION …`、`… UNION ALL …` | ✅ |
| `EXISTS { … }` 子查询表达式 | ✅ |
| 路径搜索前缀 `p = ANY [k] / ALL SHORTEST / ANY SHORTEST / SHORTEST k / SHORTEST [k] GROUPS (…)`（按起点、终点分组按长度挑；`WHERE` 先过滤再挑） | ✅ |
| 元素模式里的 `WHERE`：`(n:L WHERE n.x > 1)`、`[r:T WHERE r.w > 1]`（不能用在变长关系上） | ✅ |
| 标签表达式：`:A\|B`、`:A&B`、`:!A`、`:%`（有任意标签）、括号、`IS A`；关系 `[r:T\|U]`、`[r IS !T]`；`WHERE n IS A` | ✅ |
| `RETURN` / `WITH ALL …`、`UNION DISTINCT`、`OFFSET n`（同 `SKIP`）、`CASE x WHEN 1, 2 THEN …`、`shortestPath(…)` 当表达式 | ✅ |
| `SET m.node.p = …`、`SET n['k'] = …`、`REMOVE n[k]`（目标是任意后缀表达式，键可以是表达式） | ✅ |
| 字面量与名字：`1_000`、`1.5f`、`INF` / `NAN`、`'it''s'`、`\U01F600`、Unicode 标识符、`` `a``b` ``、`$0` / `` $`x` ``；关键字可以当变量名 | ✅ |
| 量化路径：`(a) ((x)-[r:T]->(y)){1,3} (b)`、`+` / `*` / `{n}` / `{m,}` / `{,n}`、组里的标签 / 属性 / `WHERE`（每次重复各算一次）；`-[:T]->{1,2}`、`-->+`；不带量词的括号路径 `((a)-[r]->(b) WHERE …)`、`(p = …)`；相邻的节点模式 `(a) (b)` 是同一个节点。组里的变量在组外是列表。不能嵌套、组里不能有变长关系；表达式里的模式不支持 | ✅ |
| 时间 / 空间类型（第 11 节） | ✅ |
| Neo4j 的扩展语法：`FOREACH`、`CALL { … }` 子查询（含 `CALL (a) { … }`、`OPTIONAL CALL`、`IN TRANSACTIONS`）、`COUNT { … }` / `COLLECT { … }`、`LOAD CSV` | 不支持（openCypher 2024.3 文法里没有；已删） |

关键字不区分大小写；属性名、标签、关系类型区分大小写，可以是关键字（`n.order`、`:Order`），也可以用反引号（`` n.`weird name` ``）。
注释 `//` 与 `/* */`。

**表达式**：字面量（整数（含十六进制 `0x1F`、八进制 `0o17`）、浮点、字符串、`true` / `false` / `null`、列表、map）；`= <> < <= > >=`
（可以连写：`1 < n.x <= 3` 即 `1 < n.x AND n.x <= 3`）；`AND OR XOR NOT`；`+ - * / % ^`；
`IN`；`IS [NOT] NULL`；`STARTS WITH` / `ENDS WITH` / `CONTAINS`；正则 `=~`（匹配整个字符串，Erlang `re` 语法，如 `(?i)` 不区分大小写）；
`n:Label` / `n:A|B` / `n:!A` 标签判断；下标 `list[i]`（负数从末尾数，越界 `null`）、`map['key']`、切片 `list[a..b]`（两端可省、可负）；
`v.embedding <=> q`；`v.text @@ 'query'`；
`CASE`（通用形式取第一个条件为 `true` 的分支；简单形式取第一个与主体 `=` 为真的分支；都不中取 `ELSE`，没有 `ELSE` 为 `null`；只求值命中的分支）；
列表推导 `[x IN list WHERE p | e]`（`WHERE`、`| e` 都可省）；量词 `all` / `any` / `none` / `single(x IN list WHERE p)`；
`reduce(acc = init, x IN list | e)`；映射投影 `n {.name, .*, k: e, v}`（顶点、关系、map 都可以）；`exists(n.prop)`（即 `IS NOT NULL`）；
**模式表达式**：模式谓词 `WHERE (a)-[:T]->(:L)`、`exists((a)--())`（以当前行为起点能否匹配上，布尔值）、模式推导
`[(a)-[r:T]->(b) WHERE … | b.name]`、`[p = (a)-[*]->() | length(p)]`（每个匹配投影成一个值）。模式谓词里只能引用已绑定的节点变量
（不能引入新变量、不能写关系变量；要拿新变量用 `OPTIONAL MATCH` 或模式推导）；外层变量为 `null` 时结果为 `null`。
模式只能当**谓词**用（openCypher）：`WHERE` 里（含其下的 `AND` / `OR` / `NOT`）、`exists(…)`、推导 / 量词的 `WHERE`、`CASE WHEN`；
放在投影或函数参数里（`RETURN (a)-->(b)`、`size((a)-->())`）是语法错误——要布尔值写 `exists((a)-->(b))`，要个数写
`size([(a)-->(b) | 1])`。模式在表达式里必须带关系（`(a)` 单独是带括号的表达式）；关系要以 `-[`、`--`、`<-[`、`<--` 开头，所以 `(a) - (b)`、`(x) < -1` 仍是运算，
`(a)--(b)`、`(a)-->(b)` 是模式（与空格无关）。

**函数**：`id`、`labels`、`type`、`properties`、`keys`、`coalesce`、`size`、`length`、`nodes`、`relationships`、`startNode`、`endNode`、
`toInteger`、`toFloat`、`toString`、`toBoolean`、`toLower`、`toUpper`、`abs`、`score`；
字符串：`substring(s, start[, len])`（从 0 起）、`replace`、`split`、`trim` / `ltrim` / `rtrim`、`left`、`right`、`reverse`；
列表：`head`、`tail`、`last`、`reverse`、`range(start, end[, step])`（含 end）。参数为 `null` 时结果 `null`。
数学：`ceil`、`floor`、`round`（结果为浮点）、`sign`、`rand()`、`sqrt`、`exp`、`log`、`log10`、`e()`、`pi()`；三角：`sin`、`cos`、`tan`、`cot`、
`asin`、`acos`、`atan`、`atan2(y, x)`、`degrees`、`radians`、`haversin`；`timestamp()`（毫秒）。没有实数结果的按 IEEE 754（同 Java /
Neo4j）：`sqrt(-1)`、`acos(2)` 得 `NaN`，`log(0)` 得 `-Infinity`，`exp(1000)` 得 `Infinity`；`isNaN(x)` 判断 NaN。
聚合：`count(*)`、`count(x)`、`count(DISTINCT x)`、`sum`、`avg`、`min`、`max`、`collect`、`percentileCont(x, p)`（线性插值）、
`percentileDisc(x, p)`（取最近的实际值）、`stDev`（样本）、`stDevP`（总体）；分组是隐式的（不含聚合的投影项就是分组键）。
推导 / 量词 / `reduce` 里引用局部变量的部分不能有聚合（列表部分可以：`reduce(t = 0, x IN collect(v) | t + x)`）。

**语义**（openCypher）：

- 三值逻辑，`null` 传播；`WHERE` 只放行 `true`。
- 数值按值比较：`1 = 1.0` 为真，分组 / 去重时 1 与 1.0 是同一组。不同类型的 `=` 为假，`<` 一族为 `null`。
- 整数是 64 位：运算结果超出范围（`9223372036854775807 + 1`）是执行错误，超出范围的整数字面量是编译错误。整数相除取整
  （`5 / 2 = 2`），除以 0 报错。`^` 左结合（`2 ^ 3 ^ 2 = 64.0`）。字符串 `+` 是拼接，字符串与数值相加时数值先转成文本
  （`'a' + 1 = 'a1'`）。`toFloat('1e3')`、`toFloat('.5')` 这类科学计数法 / 省略整数部分的写法都认。
- 编译期类型检查（openCypher 的 `InvalidArgumentType`）：操作数静态看得出类型不对时直接报错，不等执行——布尔运算的非布尔
  操作数、算术里的字符串 / 布尔 / 列表、对标量取属性（`WITH 1 AS x RETURN x.p`）、`IN` 右边不是列表、`WHERE` 的值不是布尔、
  `labels()` / `type()` / `length()` 等的参数种类不对、`SKIP` / `LIMIT` 是小数或负数、`DELETE` 一个标量、把静态是标量的变量放进
  模式（`WITH true AS n MATCH (n)`）。静态类型未知的值（参数、`UNWIND` 的元素等）仍在执行时检查。
- `ORDER BY` 用全序：map < 顶点 < 边 < 列表 < 路径 < 字符串 < 布尔 < 数值，`null` 在升序最后、降序最前。
- 同一个 `MATCH` 里一条边不会被匹配两次；跨 `MATCH` 子句不受这个约束。
- `OPTIONAL MATCH`：对每个输入行匹配模式（`WHERE` 属于这个模式）；一行都匹配不上时保留输入行，本子句新引入的变量为 `null`。
  `null` 顶点展开不出行，对它的 `SET` / `DELETE` 什么都不做，用它 `CREATE` / `MERGE` 关系报错。
- `id(r)` 是 `[src, etype, dst, rank]`。
- 命名路径的值是 `{nodes, relationships}`；变长段的中间顶点由关系的端点推出。`allShortestPaths` 交出所有最短路（每条一行，至多 10 万条）。
- `ORDER BY` 缺省 `null` 在升序最后、降序最前；写了 `NULLS FIRST` / `NULLS LAST` 就与方向无关。
- 投影之后的 `ORDER BY` 与 `WITH … WHERE`：没有聚合、没有 `DISTINCT` 时，投影前的变量也看得见（`WITH a WHERE r IS NULL` 可以引用
  前面的 `r`）；有聚合或 `DISTINCT` 时只能用投影出来的列，但与投影项相同的**简单**表达式（变量、属性访问）和聚合会换成那一列
  （`RETURN a.name AS n, count(*) AS c ORDER BY a.name + 'x'`、`ORDER BY $k + count(*)` 都可以）。含聚合的投影项里，聚合之外的部分
  只能是简单的分组键或常量（`RETURN me.age + count(*)` 在没有单独投影 `me.age` 时是歧义聚合，报错）。
- `all` / `any` / `none` / `single`：谓词结果里有 `null` 时按三值逻辑推广（如 `all` 遇到 `false` 为 `false`，否则有 `null` 为 `null`）；
  空列表 `all` 为真、`any` 为假；列表为 `null` 时结果 `null`。`all` 等函数名、`reduce`、`exists` 在后面不跟 `(` 时仍可作变量名。
- `UNION`：每段独立（变量互不相干），每段都以 `RETURN` 结尾且列名（含顺序）相同；`UNION` 去重，`UNION ALL` 保留重复；同一条查询
  里两者不能混用。带写子句的各段在同一个事务里，任一段出错整条不写。
- `CREATE p = (…)` / `MERGE p = (…)`：建好 / 找到之后把整条模式绑到路径变量 `p`。`MERGE p = …` 按整条模式 MERGE。
- `CALL`：单独一条 `CALL p()` 返回过程的全部列（可写 `YIELD *`；不带括号的 `CALL p` 从同名的查询参数取实参）；后面还有子句时
  必须 `YIELD` 具体的列（`YIELD *` 只能用在单独一条 CALL 里）。没有输出列的过程（void）后面可以直接接别的子句，不改变行。
- `EXISTS { … }`：子查询看得见全部外层变量、可以引入新变量（与模式谓词不同），不能写；可以是完整的子句序列（`MATCH … WHERE …
  RETURN …`，可 `UNION`），也可以简写成「模式 [WHERE …]」（`EXISTS { (n)-->() }`），值是有没有行。`db.labels()` 列出至少有一个顶点的标签，
  `db.relationshipTypes()` 列出已注册的关系类型，`db.propertyKeys()` 扫一遍顶点文档列出属性名（大库上慢）。

## 5. 写

- **一条写语句是一个事务**：整条语句在一个 `bitcask_txn` 事务里执行——读的顶点 / 邻接表都带锁和版本守卫，写进缓冲，提交时一条原子批。
  与别的写者（语句或图层 API）冲突时事务层自动整条重跑（`TxOpts` 里的 `retries`，缺省同 `bitcask_txn`）。语句出错 → 什么都不写。
- **写在读之后**：写子句先把它之前的行全部算完再开始改。
- **加入调用方的事务**：在 `graphdb:transaction(G, fun(Tx) -> … end)` 里把 `Tx` 作为第一个参数传给 `q`，语句读得到同一事务之前的写，
  也可以和 `graphdb:*_txn` 混用；语句出错时整个事务中止，返回 `{aborted, {cypher, Error}}`。
- `CREATE (a)-[:T]->(b)`：两点之间已有同类型的边时新边取下一个 `rank`；删掉的关系的 id 不会再分给新关系（Cypher 删边时记下这对
  顶点的 rank 高水位，新建从它往上找；经图层 API `del_edge` 删的不记）。新的关系类型在语句开始前注册（语句失败也留着）。
- `CREATE` 里引用已绑定的节点只是连到它，不能再写标签 / 属性（用 `SET`）。
- `SET x.p = null` / `REMOVE x.p` 删除属性；`SET n = {…}` 替换全部属性与正文（标签、向量不动，除非 map 里给了 `embedding`）；
  对 `null` 的 `SET` 什么都不做。`n.text`、`n.embedding` 写的是正文与向量。
- `DELETE n`：顶点还有边就报错（用 `DETACH DELETE`）。同一条语句里 `DELETE r, n` 先删关系再删顶点。
- `MERGE`：对每个输入行按模式找，找到几个就出几行（各自套 `ON MATCH SET`），一个都没有就按模式建一个（套 `ON CREATE SET`）。
  - 整条模式：`MERGE (a:X {k: 1})-[:T]->(b:Y {k: 2})`、多跳、起点已绑定终点未绑定都可以。**整条匹配不上就整条建**——端点单独已经
    存在也会新建（openCypher 语义）；只想连到已有的端点，先 `MATCH` / `MERGE` 端点，再 `MERGE` 两端已绑定的关系。
  - 节点：`MERGE (v:A:B {k: e})` 要求标签全有、属性逐个相等（`1` 与 `1.0` 相等）；没写标签就在全部顶点里找。属性值不能是 `null`，
    也不能按 `embedding` 匹配；变量不能是已绑定的。
  - 关系：`MERGE (a)-[r:T {k: e}]->(b)`，两端必须是已绑定的节点（不能再写标签 / 属性），有向、一个类型、不是变长。找 a、b 之间
    这个类型、属性相符的边；`(b)<-[:T]-(a)` 与 `(a)-[:T]->(b)` 是同一条。
  - 并发：按标签找的那一步拿标签索引的前缀读锁，两条并发的 `MERGE` 不会各建一个（冲突的一方重跑后看见对方建的）。没有标签的节点
    `MERGE` 锁的是全部顶点，并发高时请写上标签。
- 一条写语句写多少顶点默认不限（整条语句是一个事务、提交一条原子批；写得多时自动调大执行进程的堆，耗时随写入量近似线性：
  一条语句建 10 万条关系 + 20 万个顶点约 11 s）。应用环境 `{bitcask_cypher, [{cypher_max_write_vertices, N}]}` 可以设上限，超过报错。
  大批量装载建议拆成多条语句分批提交（事务小、失败重跑代价小），或用 `graphdb:put_edges/2` 一类批量 API。

## 6. 检索

### 6.1 全文 `@@`

`WHERE n.text @@ 'query'` 对顶点正文做全文匹配（库需要以索引模式打开）。查询串的写法：

| 写法 | 含义 |
|---|---|
| `graph vector` | 两个词都要出现 |
| `graph OR vector` | 任一个（`OR` 大写，比并列结合得紧：`a OR b c` = (a 或 b) 且 c） |
| `-cooking` | 排除 |
| `"graph database"` | 短语 |
| `graph*` | 前缀 |
| `graphs~` | 模糊（编辑距离 1） |

- `score(n)`：BM25 分；多个词时是各个词的分数之和（`OR` 取较大的）。没经过全文匹配的行是 `null`。
- 整个 `WHERE` 里有这个合取项时它就是起点（先检索、再展开 / 过滤）；用在展开得到的顶点上时是逐行过滤（同一个查询串只检索一次）。
- 只支持 `n.text`；检索读引擎，看不到同一事务里还没提交的写。

### 6.2 向量 `<=>`

`v.embedding <=> q`：`q` 是数值列表或 f32 小端 binary；值是**引擎相似度分数的相反数**，越小越近——cosine / dot 度量下是负的内积，
L2 下是平方距离。顶点没有向量时为 `null`。走向量索引的两种形态：

- `MATCH (n[:L] …) [WHERE …] RETURN … ORDER BY n.embedding <=> $q LIMIT k`（不聚合、不 DISTINCT）：向量 top-k 检索作起点。
  其余条件在检索结果上判断，不够 k 个时自动扩大检索范围；扩到上限仍不够时 `stats` 里 `vector_exhaustive => false`。
- `WHERE n.embedding <=> $q < t`（或 `<=`）：按阈值取候选。

第一个标签作为 meta 过滤下推给引擎。别的写法（候选来自图模式，如 `MATCH (a)-[:R]->(b) … ORDER BY b.embedding <=> $q`）
对候选做精确计算（一次 `bitcask:vector_rank/4`）。需要库配置 `{vector_dim, N}`。

### 6.3 函数形式（全文的其它检索形态、混合检索）

| 函数 | 引擎接口 |
|---|---|
| `fts.phrase(n.text, '短语')` | `search_phrase` |
| `fts.near(n.text, 'a b', 距离)` | `search_near`（词之间至多隔几个词） |
| `fts.wildcard(n.text, 'gr*h')` | `search_wildcard` |
| `fts.fuzzy(n.text, '词'[, 编辑距离])` | `search_fuzzy`（缺省 1，至多 2） |
| `fts.fields(n, 'title:x body:y')` | `search_fields`（命名字段的查询写法） |
| `search.hybrid(n, '文本', $向量[, k])` | `search_hybrid`（全文 + 向量的 RRF 融合，取前 k，缺省 10） |

用法同 `@@`：作为 `WHERE` 的合取项时是起点（`explain` 里是 `search_seek`），按分数从高到低出行，`score(n)` 是引擎给的分数；出现在别处时
按顶点判断是否命中（命中集合一次查询内按参数缓存）。参数为 `null` → 不命中。

## 7. 与图层 API 混用

```erlang
{ok, V} = graphdb:create_vertex(G, #{labels => [<<"Doc">>], props => #{title => <<"x">>}}),
{ok, #{rows := [[<<"x">>]]}} = bitcask_cypher:q(G, "MATCH (d:Doc) WHERE id(d) = $v RETURN d.title", #{v => V}),
ok = graphdb:put_edge(G, V, T, 42, #{props => #{w => 0.5}}),       %% 语句里 r.w = 0.5
{atomic, _} = graphdb:transaction(G, fun(Tx) ->
    {ok, _} = bitcask_cypher:q(Tx, "MATCH (d:Doc) SET d.seen = true"),
    graphdb:put_edge_txn(Tx, V, T, 43)
end).
```

## 8. 规划与 `explain`

没有统计信息，规则固定。每个连通的模式选一个起点：已绑定的变量 > `id(v) = …` / `id(v) IN …` > `@@` 合取项 > 向量（上面两种形态）>
有标签（标签索引扫描）> 全量扫描（`n` 文档 ∪ 邻接表头；大图上慢，`explain` 里能看到 `all_nodes_scan`）。从起点沿模式逐跳展开，
另一端已绑定时「展开到」；`WHERE` 拆成合取项，变量一齐就过滤。执行是惰性的：`LIMIT` 前的扫描凑够行数就停。

**条件下推**：起点是标签扫描或全量扫描时，节点上其余的标签、内联属性，以及 `WHERE` 里「属性 比较 常量 / 参数」的条件（`=`、`<`、`<=`、`>`、
`>=`、`IN`、`IS NOT NULL`）交给引擎的 meta 过滤。交给引擎的是放宽过的必要条件（`1` 与 `1.0` 两种写法都查、跨类型的大小比较含等号；字符串
大小比较、`IS NULL`、两边都是变量的条件、`text` / `embedding` 不下推），原有过滤照样在 Erlang 里做——下推只负责少读，结果不变。标签扫描按
256 个顶点一块，id 分布够密时整块用一次 range 连文档一起读回，后面的属性访问不再逐个读顶点。`explain` 里带下推的扫描是
`{label_scan, V, 标签, #{push => 条件, fetch => 是否取文档}}`、`{all_nodes_scan, V, 条件}`。

`id(v) = …` 起点后面紧跟从 v 出发的一跳展开时（`{node_by_id, V, E, nocheck}`），不单独检查顶点存在：没有边的顶点在展开时自然没有行。

**属性索引**：`graphdb:create_index(G, 标签, 属性)` 声明一个 (标签, 属性) 索引，立刻从现有数据建好，之后所有改顶点的写入（图层 API 与
Cypher、直通写与事务）同批维护；`graphdb:drop_index/3` 删掉，`graphdb:indexes/1` 列出（`building` / `ready`）。只索引标量值；`text` /
`embedding` 不能建。标签扫描的起点在执行时看下推条件里有没有可用的就绪索引——有就改走索引（等值 > `IN` > 大小比较；数值的整数与浮点
两种写法都查），原有过滤照常，结果不变。计划与数据无关，所以 `explain` 里仍显示 `label_scan`。2 万个顶点、某个值约 200 个时，
`MATCH (n:L) WHERE n.k = 7` 约 11.7 ms → 约 0.5 ms。事务里（写语句、或在调用方事务里跑的语句）的标签扫描同样会改走就绪的属性索引，
这时锁的是该值（大小比较时是该属性）的索引前缀，比锁整个标签窄（2000 个顶点上写语句 `MATCH (c:C {k: 1}) SET …` 6.7 ms →
约 0.14 ms）；没有可用的索引时仍是带前缀读锁（防幻读）地扫标签索引，不下推条件。

同一段查询文本的解析与规划结果按文本缓存在调用进程里（至多 128 条），文本查询与 `prepare/2` 之后再执行几乎一样快。

`explain` 返回的算子：`node_by_id`、`label_scan`、`all_nodes_scan`、`fts_seek`、`vector_topk`、`vector_range`、`node_check`、`expand`、
`var_expand`、`rel_check`、`shortest_path`、`all_shortest_paths`、`build_path`、`optional`、`search_seek`、`call_proc`、`filter`、`unwind`、
`project`、`aggregate`、`distinct`、`sort`、`skip`、`limit`、`select`、`create`、`set`、`remove`、`delete`、`merge_node`、`merge_rel`、
`merge_pattern`、`qpp_expand`（量化路径）、`tag_rows` / `path_select` / `drop_vars`（路径搜索前缀）。

## 9. 性能

`test/cypher_bench`（2 万顶点 / 10 万边，幂律分布，带标签、属性、正文、8 维向量；本机，单位 µs/次）：

| 操作 | 新写入 | 重开后 |
|---|---|---|
| 一跳：`graphdb:out_edges` / Cypher 预编译 / Cypher 文本 | 2.0 / 5.0 / 5.1 | 2.1 / 5.4 / 5.7 |
| 两跳计数（预编译） | 18.2 | 20.1 |
| 一跳 + 邻居属性过滤 | 15.2 | 16.0 |
| `shortestPath`（预编译）/ `graphdb:shortest_path` | 184 / 154 | 252 / 221 |
| 向量 top-10（`ORDER BY <=> LIMIT`）/ `bitcask:search_vector` | 52 / 21 | 49 / 20 |
| 邻居按向量排序（图 + `<=>`） | 23.4 | 24.0 |
| 全文 `@@`（取全部命中，每次查询） | 3758 | 3663 |
| 全部 `Person` 标签扫描 + 属性过滤 / 按属性分组计数（每次查询） | 19 ms / 59 ms | 14 ms / 55 ms |

| 写 | µs/次 |
|---|---|
| `graphdb:create_vertex`（带正文与向量） | 37 |
| `CREATE` 一个顶点（一条语句，带正文与向量） | 182 |
| `UNWIND $rows CREATE`（每条 1000 个，折合每个顶点） | 45 |
| `graphdb:put_edges`（折合每条边） | 13 |
| `SET` 一个属性（一条语句） | 37 |
| `CREATE` 一条关系（两端已存在） / `graphdb:put_edge` | 66 / 32 |
| `DETACH DELETE` 一个顶点 | 300 |

写语句有事务的固定开销（写锁、守卫、提交；读不拿锁），单条写比图层 API 慢一到两倍；批量写用 `UNWIND` 或图层的批量 API。

## 10. 已知限制

- 没有统计信息，起点按固定规则选；聚合类的全量扫描（不能下推条件时）每行仍有约 1.4 µs 的执行器开销。
- 写语句里的全文 / 向量检索读引擎，看不到同一事务里还没提交的写。
- 时间：年份范围 ±999999999（前推公历，含 0 年与负年份：`date('-0044-03-15')`；文本里负年份至少 4 位、超过 4 位的正年份带 `+`，
  同 java.time）。Duration 乘除按精确分数算、纳秒向零截断（同 Neo4j）。命名时区用本机的 zoneinfo：极早的历史偏移取决于
  系统 tzdata 的版本。被 IANA 合并掉的时区（`Europe/Stockholm` 并入 `Europe/Berlin` 等 142 个）缺省按合并目标的数据算，同 IANA 的
  缺省编法与 Java / Neo4j——Debian 等带 backzone 编的 zoneinfo 里它们保留各自 1970 年以前的数据，要用那份数据设应用环境
  `tz_backzone = true`（1970 年以后两者一致）。没有 zoneinfo 的机器（Windows）上要配置 `tz_dir`，否则只能用固定偏移。
- **NaN / Infinity**：Erlang 的浮点表示不了，结果与参数里用原子 `'NaN'`、`'Infinity'`、`'-Infinity'` 表示。浮点运算按 IEEE 754：
  溢出得无穷（`1e308 * 10`）、浮点除以 0 得无穷或 NaN（`1.0 / 0`、`0.0 / 0.0`；整数除以整数 0 仍是错误）。NaN 不等于任何值（包括自己），
  和数值比大小全为 `false`、和别的类型比为 `null`；排序时 `-Infinity` < 有限数 < `Infinity` < `NaN` < `null`。`toString` 得 `'NaN'` /
  `'Infinity'` / `'-Infinity'`，`toFloat` 认这三种写法，`toInteger` 得 `null`。可以存成属性（文本 + `_types`），列表里也行。
- 值是时间 / 空间的条件不下推给引擎、不走属性索引（结果正确，只是不加速）。

## 11. 时间与空间类型

| 类型 | 构造 | 结果里的 Erlang 值 |
|---|---|---|
| `Date` | `date()`、`date('2024-05-01')`、`date({year: 2024, month: 5, day: 1})` | `{date, {Y, M, D}}` |
| `LocalTime` | `localtime()`、`localtime('12:30:15.5')`、`localtime({hour: 12, minute: 30})` | `{localtime, 当日纳秒}` |
| `Time` | `time()`、`time('12:30+01:00')`、`time({hour: 12, timezone: '+01:00'})` | `{time, 当日纳秒, 偏移秒}` |
| `LocalDateTime` | `localdatetime()`、`localdatetime('2024-05-01T12:30')` | `{localdatetime, {Y, M, D}, 当日纳秒}` |
| `DateTime` | `datetime()`、`datetime('2024-05-01T12:30Z')`、`datetime('2024-05-01T12:30[Europe/Berlin]')`、`datetime({epochSeconds: 0})`、`datetime.fromepochmillis(ms)` | `{datetime, {Y, M, D}, 当日纳秒, 偏移秒}`；命名时区 `{datetime, {Y, M, D}, 当日纳秒, 偏移秒, 时区名}` |
| `Duration` | `duration('P1Y2M3DT4H5M6.5S')`、`duration({days: 3, hours: 4})`、`duration.between(a, b)` | `{duration, 月, 天, 秒, 纳秒}` |
| `Point` | `point({x: 1, y: 2[, z: 3]})`、`point({longitude: 13.4, latitude: 52.5[, height: 30]})` | `{point, Srid, X, Y[, Z]}` |

- 字符串形态：ISO 8601——日期 `2024-05-01` / `20240501` / `2024-05` / `2024` / 周日期 `2024-W18-3` / 序数日期 `2024-122`；时刻 `HH:MM[:SS[.f]]`
  或紧凑写法，后跟 `Z` / `±hh:mm`。映射形态：日期用 `year` + `month` / `day`、`week` / `dayOfWeek`、`ordinalDay`、`quarter` /
  `dayOfQuarter`；时刻用 `hour` / `minute` / `second` / `millisecond` / `microsecond` / `nanosecond`；`timezone`；`date` / `time` /
  `datetime` 键给一个时间值作为基础、其余键覆盖——没给的分量按所用的表示法从基础值取（`{date: d, week: 2}` 保留 `d` 的周年与
  星期几，`{date: d, quarter: 3}` 保留季内第几天），只给 `nanosecond` 时保留基础值的毫秒 / 微秒位；基础值带偏移又给了新 `timezone`
  时先换算到新时区（同一时刻）再套其它分量。从别的时间值转换：`date(dt)`、`localtime(dt)`、`datetime(localdatetime)`（偏移取 UTC）。
  Duration 还认 `P2012-02-02T14:37:21.545` 这种备用格式。
- **时区**：固定偏移（`Z`、`+01:00`、`+01:00:30`）或 IANA 时区名（`Europe/Stockholm`、`'…T12:00[Europe/Stockholm]'`、
  `{timezone: 'Europe/Stockholm'}`）。时区数据读本机的 zoneinfo：应用环境 `bitcask_cypher.tz_dir` > 环境变量 `TZDIR` >
  `/usr/share/zoneinfo`（TZif 文件；最后一次转换之后的年份按文件尾的 POSIX 规则算），按时区名缓存。带时区名的 DateTime 记着时区，
  输出 `2024-05-01T12:00+02:00[Europe/Stockholm]`，`.timezone` 是时区名、`.offset` 是当时的偏移；偏移按日期解析——落在秋季回拨的
  重叠段时，字符串里写了偏移就用它、否则取较早（夏令时）的那个；落在春季拨快的空隙里时把时刻往后挪空隙那么长（同 java.time）。
  加减 Duration：月 / 天在本地日历上加（偏移重新解析），秒部分加在时刻上。`duration.between` 一边带时区名、一边没有偏移时，没有偏移
  的那边按同一时区解释（夏令时切换那天 00:00 到 04:00 是 5 小时）。Time 不带时区名：`time({…, timezone: 'Europe/Stockholm'})` 按今天
  （或给出的日期）在这个时区的偏移。
- 输出的文本形态与 Neo4j / openCypher 一致：秒与小数都是 0 时只写到分（`12:00`、`2024-05-01T08:30Z`），否则写到秒、小数去尾零。
- 无参的 `date()` / `datetime()` 等取**语句时钟**（UTC）：一条语句里多次调用得到同一个时刻。`date.statement()` /
  `date.transaction()` 同样是语句时钟，`date.realtime()` 是真实的当前时刻（其它类型同理；可以带一个偏移参数）。
- 访问：`.year .quarter .month .week .weekYear .day .ordinalDay .dayOfWeek .dayOfQuarter .hour .minute .second .millisecond
  .microsecond .nanosecond .timezone .offset .offsetMinutes .offsetSeconds .epochSeconds .epochMillis`（按类型）；Duration：`.years
  .quarters .months .weeks .days .hours .minutes .seconds .milliseconds .microseconds .nanoseconds` 与 `.monthsOfYear .daysOfWeek
  .minutesOfHour .secondsOfMinute .millisecondsOfSecond` 等；Point：`.x .y .z .longitude .latitude .height .srid .crs`。
- 运算：时间 ± Duration（先加月——日期截到月底，再加天，再加秒，满一天进位；没有日期的类型只加秒部分，按一天取模）；Duration ± Duration；
  Duration × / ÷ 数（小数的月按 30.436875 天、小数的天按 86400 秒往下折）。`duration.between(a, b)` 给出月 + 天 + 秒，
  `duration.inMonths` / `inDays` / `inSeconds` 只取一种单位。`date.truncate('month', d[, 覆盖映射])` 等（单位 `millennium` …
  `microsecond`；覆盖映射里的 `timezone` 只换标签，不换算时刻）。Date ± Duration 时 Duration 的秒分量只取整天数（向零取整）。
- 比较：同类型才可比，`DateTime` / `Time` 按时刻（不同偏移的同一时刻相等）；`Duration` 与 `Point` 只有相等（`P1D` ≠ `PT24H`）；
  不同类型 `=` 为假、`<` 为 `null`。`ORDER BY` 全序里的位置：路径 < Point < DateTime < LocalDateTime < Date < Time < LocalTime <
  Duration < 字符串。
- 空间：`point.distance(a, b)`（也写 `distance`）——笛卡尔是欧氏距离，WGS-84 是大圆距离（米，3D 再计入高度差），坐标系不同为
  `null`；`point.withinBBox(p, 左下, 右上)`（WGS-84 下左下经度大于右上时按跨日界线处理）。
- 存储：可以作为顶点 / 关系属性存（也可以是同一种时间 / 空间值的列表）；读回来类型不变。图层 API（`graphdb:create_vertex/2` 等）同样接受与返回这些元组。
  落盘时存成规范文本，保留键 `_types` 记类型（`_` 开头的键本来就是保留的，不出现在属性里）。
- 参数可以直接传这些元组；`bitcask_cypher_temporal:format/1` 把值转成 ISO 8601 / `point({…})` 文本。

## 12. 用户过程与用户函数

在 Erlang 里注册（全节点范围；注册 / 注销后各进程的计划缓存自动作废）：

```erlang
ok = bitcask_cypher:register_procedure(<<"my.range">>, #{
         args    => [<<"n">>, {<<"step">>, 1}],          %% {名, 缺省值} 的参数可省，必须排在后面
         outputs => [<<"i">>, <<"sq">>],
         mode    => read,                                 %% read | write
         fn      => fun(_Ctx, [N, Step]) -> [#{i => I, sq => I * I} || I <- lists:seq(1, N, Step)] end}),
ok = bitcask_cypher:register_function(<<"my.slug">>, #{arity => 1, fn => fun(_Ctx, [S]) -> slug(S) end}),
bitcask_cypher:registered(),          %% #{procedures => [...], functions => [...]}
ok = bitcask_cypher:unregister(<<"my.slug">>).
```

```cypher
CALL my.range(3)                                      // 单独一条：返回全部输出列
UNWIND [2, 3] AS n CALL my.range(n) YIELD i, sq RETURN n, sum(sq)
RETURN my.slug('Hello World')
```

- 参数也可以写成 `#{name => <<"n">>, type => integer | float | number | string | boolean | any, default => D}`：声明了类型的参数
  在编译期按字面量检查（`CALL my.range('x')` 是类型错误）。`outputs => []` 是没有输出列的过程：单独调用没有列也没有行，在查询中间
  调用不用 `YIELD`、不改变行。
- 名字必须带命名空间（`a.b`、`a.b.c`），大小写不敏感，不能用内置的命名空间（`db`、`fts`、`search`、`date`、`time`、`localtime`、`datetime`、
  `localdatetime`、`duration`、`point`）。
- `fn(Ctx, Args)`：`Ctx = #{handle => H, txn => Tx | undefined, params => 参数}`。参数是求值后的 Cypher 值——顶点是 `{node, Id}`，标量 /
  列表 / 映射原样，时间值是第 11 节的元组。过程返回 map 列表（键是输出名，binary 或 atom 都行，缺的为 `null`），也可以返回惰性流
  `fun() -> done | {Row, Next}`；函数返回一个值。参数为 `null` 时用户函数照样被调用（自己决定怎么处理）。
- `read` 过程拿到的句柄在事务里是事务的底层句柄，经它的读写**不受 2PL 保护**；要读写语句的事务请用 `graphdb:*_txn(Tx, …)`。`write`
  过程让语句成为写语句（在一个事务里执行、出错整条回滚），写必须经 `Tx`。
- 过程 / 函数抛出的错误变成执行错误（`procedure my.x failed: …`）；事务层的冲突重跑信号会原样透传。

## 13. openCypher TCK

仓库带一个 openCypher 官方一致性测试集（TCK，Gherkin 场景）的运行器：

```sh
apps/bitcask_cypher/test/tck/fetch.sh                 # 拉 openCypher 2024.3 的场景集到 _build/tck/（不进仓库）
rebar3 compile
escript apps/bitcask_cypher/test/tck/tck.escript      # [--filter 子串] [--jobs N]；报告写到 _build/tck/report.txt
```

每个场景在一个新建的图上执行，比对结果（区分整数与浮点；节点 / 关系 / 路径按标签、类型、属性、方向比；时间值按 TCK 的文本形态比）、
副作用（执行前后图状态的差：节点、关系、标签名集合、属性三元组）与错误。期望报错的场景要阶段（编译期 = 解析 / 语义 /
规划，运行期 = 执行）、错误类型与细节代码（`SyntaxError: VariableAlreadyBound` 等）都对上；`--phase-only` 只比阶段（旧判定）。

当前结果（2024.3，3880 个场景）：**全部 3880 个通过（100%）**，695 个错误场景的类型与细节代码全部对上。

