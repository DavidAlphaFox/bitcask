# 图查询语法参考

English: [`cypher-syntax-en.md`](cypher-syntax-en.md)。接口、数据模型、写语义、规划与性能见使用说明 [`cypher-zh.md`](cypher-zh.md)。

`bitcask_cypher` 的语法以 **openCypher 2024.3** 为准：仓库 `grammar/openCypher.bnf` 的 220 条逐产生式探测全部通过，同版 TCK（3880 个
场景，含错误类型与细节代码）全部通过。本文第一部分是 openCypher 的语法，第二部分是 **bitcask 特有的语法**（检索运算符、检索函数、
特殊属性、用户过程等）。

记法：`[ ]` 可省，`{ a | b }` 二选一，`…` 可重复；`大写` 是关键字（不区分大小写），`斜体`式的中文是要替换的部分。

---

# 第一部分：openCypher 语法

## 1. 语句

```
语句      ::= 查询 { UNION [ ALL | DISTINCT ] 查询 }… [ ; ]
          |  CALL 过程名 [ ( 参数, … ) ] [ YIELD { 列 [ AS 名 ], … | * } ]        -- 单独一条过程调用
查询      ::= 子句…                       -- 以 RETURN 结尾，或以写子句结尾（不返回行）
```

- `UNION` 去重（同 `UNION DISTINCT`），`UNION ALL` 保留重复；各段独立、列名（含顺序）相同；两者不能混用。
- 注释：`// 到行尾`、`/* … */`。

## 2. 读子句

| 子句 | 写法 |
|---|---|
| 匹配 | `MATCH 模式, … [ WHERE 条件 ]` |
| 可选匹配 | `OPTIONAL MATCH 模式, … [ WHERE 条件 ]`（匹配不上时保留输入行，新变量为 `null`） |
| 展开列表 | `UNWIND 表达式 AS 名` |
| 投影 / 串联 | `WITH [ DISTINCT \| ALL ] 投影项, … [ ORDER BY … ] [ SKIP \| OFFSET n ] [ LIMIT n ] [ WHERE 条件 ]` |
| 返回 | `RETURN [ DISTINCT \| ALL ] 投影项, … [ ORDER BY … ] [ SKIP \| OFFSET n ] [ LIMIT n ]` |
| 过程调用 | `CALL 过程名 [ ( 参数, … ) ] [ YIELD 列 [ AS 名 ], … [ WHERE 条件 ] ]` |

- 投影项：`表达式 [ AS 名 ]`，或 `*`（全部变量，可以再跟 `, 项…`）。没有别名时列名是表达式在查询里的原样写法。
- `ORDER BY 表达式 [ ASC | ASCENDING | DESC | DESCENDING ], …`；`SKIP` / `OFFSET` / `LIMIT` 的值是非负整数字面量、参数或常量表达式。
- 聚合是隐式分组：投影项里不含聚合的是分组键。
- 过程调用：查询中间要 `YIELD` 具体的列（`YIELD *` 只能用在单独一条 CALL 里）；单独一条 CALL 不带括号时从同名的查询参数取实参。

## 3. 写子句

| 子句 | 写法 |
|---|---|
| 创建 | `CREATE 模式, …`（关系要有向、恰好一个类型；可以 `CREATE p = (…)`） |
| 合并 | `MERGE 模式 [ ON CREATE SET 项, … ] [ ON MATCH SET 项, … ]` |
| 设置 | `SET 项, …`：`目标.属性 = 值`、`目标[键] = 值`、`变量 = {映射}`、`变量 += {映射}`、`变量:标签:…` |
| 删除属性 / 标签 | `REMOVE 项, …`：`目标.属性`、`目标[键]`、`变量:标签:…` |
| 删除 | `[ DETACH ] DELETE 表达式, …`（节点、关系或路径） |

- `SET` / `REMOVE` 的目标是任意后缀表达式：`n.p`、`(n).p`、`m.node.p`（`m.node` 是节点）、`n['p']`、`n[$k]`（键是字符串）。
- `CREATE (n $props)`：参数作属性映射只能在 `CREATE` 里。
- 写标签只能是普通名字，不能是标签表达式。

## 4. 模式

```
模式      ::= [ 路径变量 = ] [ 路径搜索前缀 ] 路径项
路径项    ::= 元素 …                                 -- 节点、关系、量化关系、括号路径 / 量化组依次相接
```

### 4.1 节点

`( [ 变量 ] [ 标签 ] [ {属性: 值, …} | WHERE 条件 ] )`

- `()`、`(n)`、`(:Person)`、`(n:Person {name: 'ann'})`、`(n:Person WHERE n.age > 30)`。
- 相邻的两个节点模式是同一个节点：`(a) (b)` 里 `a` 与 `b` 绑定同一个节点。

### 4.2 关系

| 方向 | 写法（`[…]` 可省，省了就是任意关系） |
|---|---|
| 向右 | `-[…]->`、`-->` |
| 向左 | `<-[…]-`、`<--` |
| 任一方向 | `-[…]-`、`--`、`<-[…]->`、`<-->` |

`[ [ 变量 ] [ 类型 ] [ * 长度 ] [ {属性: 值, …} | WHERE 条件 ] ]`

- 类型：`:T`、`:T|U`、`:T|:U`（旧写法），或标签表达式（4.3）。
- 变长：`*`（1 跳起不限上界）、`*n`、`*n..m`、`*..m`、`*n..`、`*0..1`；变长关系的变量是关系列表。
- 变长关系上不能写 `WHERE`（写在模式后面）。

### 4.3 标签表达式

用在节点 / 关系模式的 `:` 或 `IS` 后面，以及 `WHERE n:… ` / `WHERE n IS …` 里：

| 写法 | 含义 |
|---|---|
| `:A`、`IS A` | 有标签 A（关系：类型是 A） |
| `:A:B` | 都有（旧写法） |
| `:A\|B` | 任一 |
| `:A&B` | 都有 |
| `:!A` | 没有 |
| `:%` | 有任意标签 |
| `:(A\|B)&!C` | 括号分组；`!` 优先于 `&` 优先于 `\|` |

### 4.4 括号路径与量化路径

```
括号路径  ::= ( [ 子路径变量 = ] 路径项 [ WHERE 条件 ] ) [ 量词 ]
量化关系  ::= 关系模式 量词
量词      ::= *  |  +  |  {n}  |  {m,n}  |  {m,}  |  {,n}       -- * = {0,}，+ = {1,}
```

- `(a:Person) ((x)-[r:KNOWS]->(y)){1,3} (b)`：组重复 1～3 次，相邻两次首尾相接，`a` 是第一次的 `x`，`b` 是最后一次的 `y`。
  组里的标签、属性、`WHERE` 每次重复都要满足；组里的变量在组外是列表（`[n IN x | n.name]`、`size(r)`）。
- `-[:KNOWS]->{1,3}`、`-->+`：量化关系（关系里没有 `WHERE` 时就是变长关系 `*1..3`）。
- 不带量词的 `((a)-[r]->(b) WHERE r.w > 1)` 等同把条件写进 `WHERE`；整条模式是 `(p = …)` 时等同 `p = …`。
- 限制：量化组不能嵌套；组里不能有变长关系；至少一条关系；子路径变量只能用在整条模式上；表达式里的模式不支持量化组。

### 4.5 路径搜索前缀

写在路径变量之后：`MATCH p = SHORTEST 2 (a)-[*]->(b)`。

| 前缀 | 按 (起点, 终点) 分组后挑 |
|---|---|
| `ALL [PATH\|PATHS]` | 全部（缺省） |
| `ANY [k] [PATH\|PATHS]` | 任意 k 条（缺省 1） |
| `ANY SHORTEST [PATH\|PATHS]` | 一条最短 |
| `ALL SHORTEST [PATH\|PATHS]` | 全部最短 |
| `SHORTEST k [PATH\|PATHS]` | 最短的 k 条 |
| `SHORTEST [k] [PATH\|PATHS] {GROUP\|GROUPS}` | 长度在最小的 k 种之内的全部 |

`k` 是整数字面量或参数。`WHERE` 先过滤再挑（同 Neo4j）。旧写法 `shortestPath((a)-[*]-(b))` / `allShortestPaths(…)` 也认，
也可以当表达式用（`RETURN length(shortestPath((a)-[*]-(b)))`）。

## 5. 表达式

### 5.1 字面量

| 类别 | 写法 |
|---|---|
| 整数 | `42`、`-7`、`1_000_000`、`0x1F`、`0X_1f`、`0o17`（64 位，超出范围是编译错误） |
| 浮点 | `1.5`、`.5`、`1e3`、`1.5e-3`、`1_0.5`、后缀 `1.5f` / `2.5d`；`INF`、`INFINITY`、`-INF`、`NAN` |
| 字符串 | `'…'` 或 `"…"`；转义 `\\ \' \" \` \t \b \n \r \f \uXXXX \UXXXXXX`；连写两个引号表示一个（`'it''s'`） |
| 其它 | `true` / `false`、`null`、列表 `[1, 'a', null]`、映射 `{k: 1, name: 'a'}`（键也可以用反引号名字） |

### 5.2 名字与参数

- 名字：字母或 `_` 开头（Unicode 字母也行：`ñ`、`名字`），或用反引号 `` `任意文本` ``（`` `a``b` `` 表示 ``a`b``）。
- 关键字不保留：可以作变量名（`AS order`、`MATCH (match)`）、属性名、标签、映射键。
- 参数：`$name`、`$0`、`` $`带 空格` ``。

### 5.3 运算符（优先级从低到高）

| 优先级 | 运算符 |
|---|---|
| 1 | `OR` |
| 2 | `XOR` |
| 3 | `AND` |
| 4 | `NOT` |
| 5 | `=` `<>` `<` `<=` `>` `>=` `=~`（可连写：`1 < x <= 3`） |
| 6 | `IN`、`STARTS WITH`、`ENDS WITH`、`CONTAINS`、`IS [NOT] NULL` |
| 7 | `+` `-` |
| 8 | `*` `/` `%` |
| 9 | `^`（左结合） |
| 10 | 一元 `+` `-` |
| 11 | `.属性`、`[下标]`、`[a..b]` 切片 |

- 标签判断 `n:A`、`n IS A`（第 4.3 节的标签表达式）是原子级，比所有运算符绑得紧：`n IS A = true` 即 `(n IS A) = true`。
- `=~` 匹配整个字符串（Erlang `re` 语法，`(?i)` 不区分大小写）。下标负数从末尾数、越界为 `null`；切片两端可省、可负。

### 5.4 其它表达式

| 名称 | 写法 |
|---|---|
| CASE | `CASE WHEN 条件 THEN 值 … [ELSE 值] END`；`CASE 表达式 WHEN 值 [, 值…] THEN 值 … [ELSE 值] END` |
| 列表推导 | `[x IN 列表 [WHERE 条件] [\| 表达式]]` |
| 模式推导 | `[ [p =] 模式 [WHERE 条件] \| 表达式 ]` |
| 量词函数 | `all / any / none / single(x IN 列表 WHERE 条件)` |
| reduce | `reduce(acc = 初值, x IN 列表 \| 表达式)` |
| 映射投影 | `n {.name, .*, k: 表达式, 变量}` |
| 子查询 | `EXISTS { 子句… }`、`EXISTS { 模式 [WHERE 条件] }` |
| 模式谓词 | `WHERE (a)-[:T]->(:L)`、`exists((a)--())`（只能当谓词用） |
| 存在判断 | `exists(n.prop)`（即 `IS NOT NULL`） |
| 计数 | `count(*)` |

## 6. 函数

| 类别 | 函数 |
|---|---|
| 图 | `id`、`labels`、`type`、`properties`、`keys`、`nodes`、`relationships`、`startNode`、`endNode`、`length` |
| 通用 | `coalesce`、`size`、`head`、`tail`、`last`、`reverse`、`range(start, end[, step])`、`timestamp()` |
| 转换 | `toInteger`、`toFloat`、`toString`、`toBoolean` |
| 字符串 | `toLower`、`toUpper`、`trim`、`ltrim`、`rtrim`、`substring(s, start[, len])`、`replace`、`split`、`left`、`right` |
| 数学 | `abs`、`ceil`、`floor`、`round`、`sign`、`rand()`、`sqrt`、`exp`、`log`、`log10`、`e()`、`pi()`、`isNaN` |
| 三角 | `sin`、`cos`、`tan`、`cot`、`asin`、`acos`、`atan`、`atan2(y, x)`、`degrees`、`radians`、`haversin` |
| 聚合 | `count`、`sum`、`avg`、`min`、`max`、`collect`、`percentileCont`、`percentileDisc`、`stDev`、`stDevP`（都可以 `DISTINCT`） |
| 时间 | `date`、`time`、`localtime`、`datetime`、`localdatetime`、`duration` 及其 `.truncate`、`.statement`、`.transaction`、`.realtime`、`datetime.fromEpoch`、`datetime.fromEpochMillis`、`duration.between`、`duration.inMonths` / `inDays` / `inSeconds`（见 [`cypher-zh.md`](cypher-zh.md) 第 11 节） |

函数名不区分大小写；带命名空间的写成 `ns.f(…)`。

## 7. 不支持的写法

- Neo4j 的扩展语法（不在 openCypher 2024.3 文法里）：`FOREACH`、`CALL { … }` 子查询（含 `CALL (a) { … }`、`OPTIONAL CALL`、
  `IN TRANSACTIONS`）、`COUNT { … }` / `COLLECT { … }`、`LOAD CSV`。
- 也不支持：`||` 字符串拼接（用 `+`）、`filter()` / `extract()`（用列表推导）、Unicode 箭头 / 全角破折号、在 `RETURN` 里直接返回模式
  （用模式推导或 `exists(…)`）、`WITH … WHERE … ORDER BY`（`WHERE` 要写在 `ORDER BY` / `SKIP` / `LIMIT` 之后）。

---

# 第二部分：bitcask 特有的语法

这些写法 openCypher 文法里没有，是 bitcask 为自己的检索能力与数据模型加的；在别的 openCypher 实现上不能用。

## 8. 全文匹配 `@@`

```cypher
MATCH (n:Doc) WHERE n.text @@ 'graph OR vector -cooking' RETURN n.title, score(n) ORDER BY score(n) DESC
```

- `n.text @@ 查询串`：对顶点正文做全文匹配（库要以索引模式打开，`{analyzer, _}`）。只支持 `n.text`。
- 查询串：`a b`（都要）、`a OR b`（任一，`OR` 大写，比并列结合得紧）、`-a`（排除）、`"短语"`、`前缀*`、`模糊~`（编辑距离 1）。
- `score(n)`：BM25 分（多个词时求和，`OR` 取较大的）；没经过全文匹配的行是 `null`。
- 优先级同比较运算符（第 5.3 节第 5 级）。作为 `WHERE` 的合取项时它是起点（先检索再展开）。

## 9. 向量距离 `<=>`

```cypher
MATCH (n:Doc) RETURN n.title ORDER BY n.embedding <=> $q LIMIT 10
MATCH (n:Doc) WHERE n.embedding <=> $q < 0.3 RETURN n
```

- `n.embedding <=> 向量`：向量是数值列表或 f32 小端 binary；值是引擎相似度分数的相反数（越小越近：cosine / dot 是负的内积，L2 是平方距离）。
  顶点没有向量时为 `null`。库要配置 `{vector_dim, N}`。
- 优先级在 `IN` 一级与 `+ -` 之间。`ORDER BY … <=> … LIMIT k` 与 `WHERE … <=> … < t` 两种形态走向量索引，别的写法逐个精确计算。

## 10. 检索函数

| 函数 | 含义 |
|---|---|
| `fts.phrase(n.text, '短语')` | 短语 |
| `fts.near(n.text, 'a b', 距离)` | 邻近（词之间至多隔几个词） |
| `fts.wildcard(n.text, 'gr*h')` | 通配 |
| `fts.fuzzy(n.text, '词'[, 编辑距离])` | 模糊（缺省 1，至多 2） |
| `fts.fields(n, 'title:x body:y')` | 命名字段查询 |
| `search.hybrid(n, '文本', $向量[, k])` | 全文 + 向量 RRF 融合，取前 k（缺省 10） |

作为 `WHERE` 的合取项时是起点，按分数从高到低出行，`score(n)` 是引擎给的分数；用在别处时判断顶点是否命中。

## 11. 特殊属性 `text` 与 `embedding`

- `n.text`：顶点的正文（全文检索针对它）。`n.embedding`：顶点的向量。读写都按属性写法：`CREATE (n {text: '…', embedding: [1.0, 0.0]})`、
  `SET n.text = '…'`、`SET n.embedding = null`（删除向量）。
- 它们不在属性元数据里：不下推给引擎过滤、不能建属性索引、`MERGE` 不能按 `embedding` 匹配；`SET n = {…}` 会清掉正文（向量不动，除非映射里给了 `embedding`）。
- 下划线开头的属性名保留给实现（`_labels`、`_types`、`_raw`）。

## 12. 用户过程与用户函数

在 Erlang 里注册，查询里按带命名空间的名字调用：

```erlang
ok = bitcask_cypher:register_procedure(<<"my.range">>, #{args => [<<"n">>, {<<"step">>, 1}], outputs => [<<"i">>],
                                                         fn => fun(_Ctx, [N, S]) -> [#{i => I} || I <- lists:seq(1, N, S)] end}),
ok = bitcask_cypher:register_function(<<"my.slug">>, #{arity => 1, fn => fun(_Ctx, [S]) -> slug(S) end}).
```

```cypher
CALL my.range(3)
UNWIND [2, 3] AS n CALL my.range(n) YIELD i RETURN n, sum(i)
RETURN my.slug('Hello World')
```

名字必须带命名空间（`a.b`、`a.b.c`），不能用内置的命名空间（`db`、`fts`、`search`、`date`、`time`、`localtime`、`datetime`、
`localdatetime`、`duration`、`point`）。参数类型、读写模式、返回流等见 [`cypher-zh.md`](cypher-zh.md) 第 12 节。

## 13. 内置过程

| 过程 | 输出 |
|---|---|
| `CALL db.labels()` | `label`：至少有一个顶点的标签 |
| `CALL db.relationshipTypes()` | `relationshipType`：已注册的关系类型 |
| `CALL db.propertyKeys()` | `propertyKey`：顶点文档里出现过的属性名（扫一遍，大库上慢） |

无参时括号可省。

## 14. 其它与 openCypher 不同的地方

| 写法 / 行为 | 说明 |
|---|---|
| `ORDER BY … NULLS FIRST` / `NULLS LAST` | 与方向无关地把 `null` 放前 / 放后（来自 SQL / GQL，openCypher 文法里没有） |
| 语句末尾的 `;` | 可写可不写 |
| `MERGE … ON CREATE SET … ON MATCH SET … ON CREATE SET …` | 可以写多个动作、任意顺序（文法只允许一个，TCK 用到多个） |
| `point({…})`、`point.distance`、`distance`、`point.withinBBox` | 空间类型（来自 Neo4j；见 [`cypher-zh.md`](cypher-zh.md) 第 11 节） |
| `id(n)` / `id(r)` | 顶点 id 是 u64；关系 id 是 `[起点, 类型 id, 终点, rank]`（删掉的关系 id 不复用） |
| NaN / Infinity | 结果与参数里是原子 `'NaN'` / `'Infinity'` / `'-Infinity'`（Erlang 浮点表示不了） |
| 时间 / 空间值 | 结果里是元组（`{date, {Y, M, D}}` 等），存储为文本 + `_types` 标记 |
| 错误 | `#{stage, message, type, detail, line, column}`，`type` / `detail` 是 openCypher 的错误类型与细节代码 |
