# bitcask_cypher 更新日志（中文）

English version: [`CHANGELOG_EN.md`](CHANGELOG_EN.md)。格式大致遵循 [Keep a Changelog](https://keepachangelog.com/)。

Cypher 查询层原在 bitcask 主应用里（13.1.0 起），现拆为独立应用 `bitcask_cypher`；拆分前的条目照录如下。

## [13.1.0] — 2026-11-24

### Removed

- **Neo4j 的扩展语法**（不在 openCypher 2024.3 文法里，TASK.md O7）：`FOREACH`、`CALL { … }` 子查询（含 `CALL (a) { … }`、`OPTIONAL CALL`、
  `IN TRANSACTIONS` 分批提交）、`COUNT { … }` / `COLLECT { … }`、`LOAD CSV`（含 `linenumber()` / `file()` 与配置项 `cypher_import_dir`）。
  这些写法现在是语法错误；`EXISTS { … }`、bitcask 自己的 `@@` / `<=>` / 检索函数、用户过程 / 函数不受影响。

### Added

- **语法参考文档** `doc/cypher-syntax-zh.md` / `doc/cypher-syntax-en.md`：openCypher 2024.3 语法（子句、模式、标签表达式、量化路径、
  路径搜索前缀、表达式与优先级、函数、不支持的写法）与 bitcask 特有的语法（`@@`、`<=>`、检索函数、`text` / `embedding`、用户过程、
  内置过程、与 openCypher 不同的地方）。
- **按 openCypher 2024.3 文法对齐**（TASK.md O1～O6）：数字下划线、浮点后缀、`INF` / `NAN` 字面量、连写引号与 `\U` 转义、Unicode 标识符、
  `$0` 参数、关键字当变量名；`UNION DISTINCT`、`RETURN ALL`、`OFFSET`、`SET m.node.p` / `SET n['k']`、`CASE x WHEN 1, 2`、
  `shortestPath(…)` 当表达式；元素模式里的 `WHERE`；标签表达式 `IS` / `&` / `%` / 括号；路径搜索前缀 `ANY` / `SHORTEST k` /
  `ALL SHORTEST` / `SHORTEST k GROUPS` 等；量化路径 `((x)-[r]->(y)){1,3}` / `+` / `*`、量化关系 `-[:T]->{1,2}`、不带量词的括号路径与
  子路径变量、相邻节点模式（TASK.md O6）。

- **Cypher 二期第一批**：`OPTIONAL MATCH`（匹配不上时保留输入行、新变量为 `null`）；`MERGE` 单个节点或两端已绑定的单条关系，带
  `ON CREATE SET` / `ON MATCH SET`（并发的同一个 `MERGE` 不会重复创建）；`CASE` 表达式（通用与简单两种形式）。`CASE` / `WHEN` /
  `THEN` / `ELSE` / `END` 成为关键字（仍可作属性名、标签用）。见 `doc/cypher-zh.md` 第 4、5 节。
- **Cypher 二期其余**：普通命名路径与 `allShortestPaths`；标签表达式 `:A|B` / `:!A`；`ORDER BY … NULLS FIRST / LAST`；正则 `=~`；下标与切片；
  字符串函数（`substring`、`replace`、`split`、`trim` 等）与列表函数（`head`、`tail`、`last`、`range`）；`CALL db.labels()` /
  `db.relationshipTypes()` / `db.propertyKeys()`（`YIELD … WHERE`）；整条模式的 `MERGE`（端点未绑定、多跳）。`NULLS` / `CALL` /
  `YIELD` 成为关键字。设计稿第 5 节的二期项至此全部实现。
- **Cypher 流式游标**：`bitcask_cypher:cursor/2,3,4` + `fetch/2` / `columns/1` / `close/1`，只读查询按需分批取行（`LIMIT` 之前的扫描 /
  展开不必一次做完）；开游标的进程退出或空闲超时自动关闭。
- **Cypher 检索的函数形式**：`fts.phrase` / `fts.near` / `fts.wildcard` / `fts.fuzzy` / `fts.fields`、`search.hybrid`（全文 + 向量 RRF），
  作为 `WHERE` 条件时是起点并可用 `score(n)`。
- **Cypher 对齐 openCypher 语法**：列表推导、量词 `all` / `any` / `none` / `single`、`reduce`、映射投影、链式比较（`1 < x <= 3`）、
  `exists(n.prop)`、十六进制 / 八进制整数；模式谓词（`WHERE (a)-[:T]->()`）、`exists((a)--())`、模式推导（`[(a)-->(b) | b.name]`）；
  `UNION` / `UNION ALL`；`CREATE p = …` / `MERGE p = …`；`CALL db.labels` 省括号、`YIELD *`；数学 / 三角函数（`sqrt`、`log`、`sin`、`atan2`
  等）、`timestamp()`、聚合 `percentileCont` / `percentileDisc` / `stDev` / `stDevP`。`ALL` / `ANY` / `NONE` / `SINGLE` / `REDUCE` /
  `EXISTS` / `UNION` 成为关键字（仍可作属性名、标签；前六个不跟 `(` 时仍可作变量名）。见 `doc/cypher-zh.md` 第 4 节。
- **Cypher 三期**（`doc/cypher-phase3-design-zh.md`）：`FOREACH`；`CALL { … }` 子查询（`CALL (a, b) { … }` / `CALL (*)`、`OPTIONAL CALL`、
  只写的单元子查询、UNION 体）与 `CALL { … } IN TRANSACTIONS [OF n ROWS]` 分批提交（大批量装载不再受一条语句 4096 个顶点的限制；
  整条语句不再原子）；`EXISTS { … }` / `COUNT { … }` / `COLLECT { … }` 子查询表达式；用户过程与用户函数（`bitcask_cypher:register_procedure/2`、
  `register_function/2`、`unregister/1`、`registered/0`，`CALL ns.proc(参数)`、`ns.f(…)`）；`LOAD CSV`（要配置应用环境
  `cypher_import_dir`，只读该目录之下的文件）与 `linenumber()` / `file()`；时间与空间类型 Date / LocalTime / Time / LocalDateTime /
  DateTime / Duration / Point（构造、访问、运算、比较排序、`duration.between`、`truncate`、`point.distance`、`point.withinBBox`），可以作为
  顶点 / 关系属性存取，图层 API 同样接受与返回（只支持固定偏移，不支持命名时区）。`FOREACH` / `TRANSACTIONS` / `LOAD` / `CSV` / `FROM`
  成为关键字（仍可作属性名、标签）。见 `doc/cypher-zh.md` 第 4、5、11～13 节。
- **openCypher TCK 运行器** `test/tck/`：`fetch.sh` 拉 openCypher 场景集（缺省 2024.3），`escript apps/bitcask_cypher/test/tck/tck.escript` 跑并出报告
  （`doc/cypher-zh.md` 第 14 节）。当前 3880 个场景全部通过。
- **错误类型与细节代码**：错误 map 新增 `type` / `detail`（openCypher 的 error type / detail code，如 `SyntaxError` /
  `VariableAlreadyBound`、`TypeError` / `InvalidArgumentValue`；新模块 `bitcask_cypher_error`），与 openCypher TCK 全部对上；TCK 运行器
  改为严格比对（`--phase-only` 只比阶段）。**行为变化**：`MATCH (n $p)` 用参数作模式属性改为错误（`InvalidParameterUse`，
  同 openCypher；`CREATE (n $p)` 照旧，`MERGE (n $p)` 本来就不行）。
- **被合并的时区按 IANA 缺省编法解析**：`Europe/Stockholm` 等 142 个被 IANA 合并掉的时区缺省用合并目标的数据（同 Java / Neo4j；
  只影响 1970 年以前）；带 backzone 编的 zoneinfo 要用它们自己的数据时设应用环境 `tz_backzone = true`。
- **单条写语句不再限 4096 个顶点**：缺省不限，应用环境 `cypher_max_write_vertices` 可设上限（超过报错，信息里带配置名）。
  大写语句自动调大执行进程的堆（每翻一番提到两倍，语句结束恢复），耗时近似线性：一条语句建 10 万条关系 34 s → 11.5 s。
- **负年份**：日期支持 0 年与负年份，范围 ±999999999（前推公历，文本写法同 java.time：`-0044-03-15`、`+10000-01-01`）。
- **Duration 乘除**：按精确分数算、纳秒向零截断（同 Neo4j），`d / 2` 不再多出 1 纳秒。
- **NaN / Infinity**：浮点按 IEEE 754，用原子 `'NaN'` / `'Infinity'` / `'-Infinity'` 表示（新模块 `bitcask_ieee`）。浮点溢出、浮点除以 0
  不再报错；NaN 的比较与排序同 openCypher；新函数 `isNaN`；可以存取。**行为变化**：`sqrt(-1)`、`log(0)`、`acos(2)` 等原来得
  `null`，现在得 `NaN` / `±Infinity`；`1.0 / 0` 原来是执行错误。
- **命名时区**：`datetime('…[Europe/Stockholm]')`、`{timezone: 'Europe/Stockholm'}` 等，时区数据读本机 zoneinfo（应用环境 `tz_dir` >
  `TZDIR` > `/usr/share/zoneinfo`；新模块 `bitcask_tz`）。带时区名的 DateTime 记着时区（`{datetime, D, Ns, Off, Zone}`），偏移按日期与
  夏令时规则解析，可以存取。
- **Cypher 值类型**：同类型列表可以作为属性存取（`[1, 2]`、`[true]`、`[date(…)]`；图层 API 同样）；`date.statement()` /
  `transaction()` / `realtime()` 等时钟函数、`truncate` 的覆盖映射、Duration 的 `P2012-02-02T…` 备用格式；用户过程的参数类型声明与
  没有输出列的过程；单独一条 `CALL p` 的隐式参数。

### Changed

- **Cypher 按 openCypher TCK 对齐**（行为变化，见 `doc/cypher-zh.md` 第 4、10、11 节）：整数是 64 位，溢出报错；字符串 + 数值拼接；
  `^` 左结合；列名取投影项在查询里的原样写法；编译期类型检查（布尔 / 算术操作数、对标量取属性、`IN`、`WHERE`、图函数参数、
  `SKIP` / `LIMIT`、`DELETE`）；`WITH … WHERE` / `ORDER BY` 可以引用投影前的变量（无聚合时）或与投影项相同的简单表达式；歧义聚合
  报错；模式只能当谓词用（`RETURN (a)-->(b)` 是错误，写 `exists(…)` / `COUNT { … }`）；`YIELD *` 只能用在单独一条 CALL；不写上界的
  `*` 不限跳数（原来缺省 10 跳）；`*3..1` 合法（匹配不到）；MERGE 可以写无向关系；缺参数是编译期错误；时刻文本秒为 0 时只写到分
  （`12:00`）；带基础值的时间映射按表示法取分量、新 `timezone` 先换算。
- **Cypher：属性条件下推给引擎**：起点是标签扫描 / 全量扫描时，其余标签、内联属性与 WHERE 里「属性 比较 常量 / 参数」的条件（`=`、`<`、`<=`、
  `>`、`>=`、`IN`、`IS NOT NULL`）交给引擎的 meta 过滤（放宽成必要条件，原过滤保留，结果不变）；标签扫描按块用一次 range 连文档一起读回，
  不再逐个读顶点。2 万顶点上「标签 + 属性过滤」64～80 → 14～19 ms，按属性分组计数 67～77 → 55～59 ms。`explain` 里带下推的扫描算子多一个
  参数（`{label_scan, V, L, #{push, fetch}}`、`{all_nodes_scan, V, Push}`）。
- **Cypher：按查询文本缓存计划**（调用进程内，至多 128 条）：文本查询与预编译几乎一样快（一跳 19 → 5 µs）。
- **Cypher：执行器开销**：预编译一跳 7.1～7.6 → 5.0～5.7 µs、两跳计数 22～27 → 18～21 µs（查询内缓存按需建；`id(v)` 起点紧跟一跳展开时
  不单独查顶点存在）。
- **Cypher 写语句更轻**：读只靠版本守卫、不拿读锁（见下）。同一轮对比原来的加锁读：KV 模式按标签 + 属性找再 `SET` 98～99 → 90 µs、
  `CREATE` 节点 42～46 → 36～41 µs；索引模式 `SET` 114～128 → 101～104 µs。语句级原子与冲突重跑不变。
- **Cypher：写语句里的标签扫描走属性索引**：写语句 / 调用方事务里有就绪的属性索引可用时读索引条目，锁的是该值（大小比较时是该属性）的
  索引前缀而不是整个标签——2000 个顶点上 `MATCH (c:C {k: 1}) SET …` 6.7 → 0.13～0.17 ms。
  `bitcask_txn:prefix_range/3` 新选项 `{within, {Lo, Hi}}`（锁整个前缀、只读其中一段）。
- **Cypher：未知的带命名空间函数**（`foo.bar(…)`）从语法错误改为语义错误 `unknown function`（任何 `ns.f(…)` 现在都按函数调用解析，以接用户函数）。
  `UNWIND` / `FOREACH` 的元素变量现在可以直接 `SET` / `REMOVE` / `DELETE`（类型在执行时检查，原来在语义检查时就被拒）。

### Fixed

- **Cypher**：从模式终点一侧反向展开的变长关系，关系列表的顺序反了；`*1..1` 的变量不是列表；模式推导里引用列表推导的局部变量时
  没有绑定；链式比较的改写跨过了括号（`(a AND (b > c)) = …`）；`range(0, 1, -1)` 返回 `[0]`；浮点字面量溢出、全角字符让词法分析崩溃。
