# Cypher 三期设计：子查询、FOREACH、用户过程 / 函数、LOAD CSV、时间与空间类型

> ⚠️ 2026-11-24：FOREACH、`CALL { … }` 子查询（含 IN TRANSACTIONS）、`COUNT { … }` / `COLLECT { … }`、LOAD CSV 是 Neo4j 的扩展语法、
> 不在 openCypher 2024.3 文法里，已删（TASK.md O7）；本文这几节只作历史记录。用户过程 / 函数、时间与空间类型、`EXISTS { … }` 仍在。
>
> 状态：已实现（TASK.md Q7，未发版）；与设计的出入见第 9 节落地记录。前置：[`cypher-query-design-zh.md`](cypher-query-design-zh.md)（一期 / 二期与落地记录 15～21 节）、
> 使用说明 [`cypher-zh.md`](cypher-zh.md)。
>
> 一、二期之后剩下的 openCypher / Cypher 5 语法缺口就是这几项。它们不是同一类东西：FOREACH 与子查询是**执行模型**上的扩展
> （子流水线）；用户过程 / 函数是**扩展点**；LOAD CSV 是**数据源**；时间 / 空间是**值类型**（牵涉存储、比较、下推、索引）。
> 下面逐项给出语义、取舍、实现方案与风险，最后是分步计划。

## 1. 共同的基础：子流水线

二期已有三种「对每个输入行跑一段子计划」：`optional`（OPTIONAL MATCH）、`merge_pattern` 的查找、模式谓词 / 模式推导
（`bitcask_cypher_plan:sub_match/2` + `bitcask_cypher_exec:pattern_rows/5`）。三期的 FOREACH、`CALL {}`、`EXISTS {}` / `COUNT {}` /
`COLLECT {}` 都是同一模式的推广：

| 构造 | 子计划输入 | 子计划输出怎么用 | 能写吗 |
|---|---|---|---|
| `FOREACH (x IN l \| 更新子句)` | 行 + x | 丢弃，原行原样往下 | 只能写 |
| `CALL { … RETURN … }` | 导入的变量 | 每个结果行与原行拼接（可多行，0 行则原行消失） | 能 |
| `CALL { … }`（无 RETURN，单元子查询） | 导入的变量 | 丢弃，原行原样往下 | 必须是写 |
| `OPTIONAL CALL { … }` | 同上 | 0 行时原行保留、返回列为 null | 能 |
| `EXISTS { … }` | 外层变量 | 至少一行 → true | 不能 |
| `COUNT { … }` | 外层变量 | 行数 | 不能 |
| `COLLECT { … RETURN x }` | 外层变量 | 单列值的列表 | 不能 |

规划统一成：子句列表用 `bitcask_cypher_plan:clauses/4` 以「导入变量为已绑定」规划成一串算子，执行器以 `single(导入行)` 为输入跑它。
子计划在语句计划里是静态的（不像模式谓词那样在执行时按需规划），所以不需要查询内缓存。

## 2. FOREACH

- 语法：`FOREACH (x IN expr | 更新子句+)`，更新子句是 `CREATE` / `MERGE` / `SET` / `REMOVE` / `DELETE` / 嵌套 `FOREACH`。
- 语义（openCypher）：对每个输入行、列表的每个元素依次执行更新；不改变行；里面新引入的变量出不来；列表为 `null` 什么都不做。
  元素是 `null` 时照常绑定（`SET n.x = null` 就是删属性）。
- 语义检查：子作用域 = 外层作用域 + x（x 不能与外层重名）；里面只允许更新子句；FOREACH 本身算写子句（可以作为语句的最后一个子句）。
- 算子：`{foreach, X, ListExpr, Ops}`。执行时对每一行 `to_list` 跑完子流水线（写有副作用，必须物化），然后交出原行。
- 风险：无。写都在语句的同一个事务里（顶点上限照常计——缺省不限，见 `cypher_max_write_vertices`）。

## 3. CALL {} 子查询

- 语法：
  - `CALL { [WITH a, b] 子句… [RETURN …] }`（旧形式：开头的「只含变量引用」的 WITH 是导入子句）；
  - `CALL (a, b) { 子句… }` / `CALL (*) { … }`（Cypher 5 新形式，显式导入作用域）；
  - 前缀 `OPTIONAL`；后缀 `IN TRANSACTIONS [OF n ROW[S]]`（见 3.2）；
  - 子查询体可以是 `UNION`。
- 语义：
  - 子查询里只看得见导入的变量；`RETURN` 的列名不能与外层已有变量重名；子查询里的聚合按外层行各自计算（每行跑一次）。
  - 有 `RETURN`：每个外层行 × 子查询结果行。没有 `RETURN`（单元子查询）：必须含更新子句，外层行原样保留。
  - `OPTIONAL CALL`：子查询 0 行时保留外层行，返回列为 `null`。
- 实现：语义检查用新作用域分析子句（复用 `clauses/3`，初始作用域 = 导入变量及其种类）；`RETURN *` 展开；规划成
  `{subquery, Ops, Cols, Kind}`（`Kind` = `rows | unit | optional`）；`UNION` 体规划成 `{union, …}` 子流水线。执行：对每个外层行
  `run(single(导入行))`，结果行只取 `Cols` 拼回原行。

### 3.2 `CALL { … } IN TRANSACTIONS`

一条写语句是一个事务（Q8 起写多少顶点缺省不限，原先至多 4096 个）——大批量装载（典型是 `LOAD CSV`）仍宜分批提交。

- 语法：`CALL { … } IN TRANSACTIONS [OF n ROWS]`，缺省 1000 行一批。
- 语义：外层每积累 n 行，就把这一批交给子查询、在**一个独立事务**里执行并提交；整条语句**不再原子**（已提交的批不回滚）。
  错误：某批失败 → 语句报错停止，之前的批已提交（错误信息里带已提交的批数）。
- 约束（语义检查时报错）：只能在句柄上执行（不能在调用方事务里、不能开游标）；只能出现在语句顶层；`CALL {}` 之前的部分不能写
  （它们在事务外以只读方式执行）；不能嵌套。
- 实现：执行器在顶层看到 `{subquery_tx, Ops, Cols, Kind, N}` 时，外层流水线以直读方式跑（`io = direct`），每 n 行开一次
  `graphdb:transaction`，把这批行作为子流水线的输入跑完、提交。关系类型的预注册照常在语句开始前做。
- `bitcask_cypher:run/5` 现在按「有没有写子句」二选一（直读 / 整条事务）；新增第三种：外层直读 + 分批事务。

## 4. EXISTS {} / COUNT {} / COLLECT {}

- 语法：`EXISTS { 模式 [WHERE …] }` 或 `EXISTS { MATCH … [WHERE …] [RETURN …] }`；`COUNT { … }` 同样两种；`COLLECT { … RETURN x }`
  必须是完整子查询、`RETURN` 恰好一列。
- 语义：子查询里看得见全部外层变量（隐式导入），可以引入新变量（与模式谓词不同）；不能有写子句；`EXISTS` 不看 RETURN。
  外层变量为 null 时照常执行（模式匹配不出行 → false / 0 / []）。
- 词法 / 语法：`EXISTS` 已是关键字，`EXISTS {` 直接进语法；`COUNT` / `COLLECT` 不是关键字（`count()` / `collect()` 是聚合函数，
  `count {.x}` 可能是映射投影），由记号预处理在「`count` / `collect` + `{` + 子查询开头（`MATCH` / `OPTIONAL` / `WITH` /
  `UNWIND` / `CALL` / `(`）」时改写成 `COUNT_SUB` / `COLLECT_SUB`。
  记号预处理的模式区判断要能嵌套：子查询的 `{ … }` 里按子查询自己的子句切换模式，出了 `}` 恢复外层的模式（用栈）。
  `EXISTS { (a)-->(b) }` 的简写形式里，`{` 之后到 `WHERE` / `}` 之间是模式区。
- 实现：语义检查得到 `{subq_expr, exists | count | collect, Clauses, OuterRefs}`；规划在语义检查之后由 `bitcask_cypher_plan` 预先做好
  （表达式里携带子计划 `Ops`），执行器 `eval` 时以当前行跑：`EXISTS` 取 1 行即止，`COUNT` 计数，`COLLECT` 取列。

## 5. 用户过程与用户函数

- 注册接口（全节点范围，存在 `persistent_term`，注册 / 注销会让各进程的计划缓存失效——缓存键带注册表的版本号）：

  ```erlang
  bitcask_cypher:register_procedure(<<"my.neighbours">>, #{
      args    => [<<"id">>, {<<"depth">>, 1}],              %% 参数名，{名, 缺省值} 可省
      outputs => [<<"id">>, <<"name">>],
      mode    => read,                                       %% read | write
      fn      => fun(Ctx, [Id, Depth]) -> [#{<<"id">> => …, <<"name">> => …}] end}).
  bitcask_cypher:register_function(<<"my.slug">>, #{arity => 1, fn => fun(_Ctx, [S]) -> … end}).
  bitcask_cypher:unregister(<<"my.slug">>).
  ```
- 名字必须带命名空间（`a.b`、`a.b.c`），不能与内置的 `db.*` / `fts.*` / `search.*` / 时间 / 空间函数冲突；大小写不敏感。
- `Ctx` = `#{handle => H, txn => Tx | undefined, params => Params}`。`read` 过程拿到的是句柄（在事务里是事务的 `bitcask_txn:handle/1`，
  不受 2PL 保护——过程要读事务里的数据请用 `graphdb:*_txn` 并传 `Tx`）；`write` 过程只能出现在写语句里（语句因此算写语句），
  必须用 `Tx` 写（`graphdb:*_txn`），否则写不进语句的事务。
- 值：参数是求值后的 Cypher 值——顶点 `{node, Id}`、关系 `{rel, …}`（不展开），标量 / 列表 / 映射原样；结果里的顶点也写 `{node, Id}`。
  过程的结果是 map 列表（键 = 输出名，缺的键为 null），也可以返回惰性的 `fun() -> done | {Row, Next}`。
- CALL 语法扩展：`CALL ns.name(参数…) [YIELD …]`（目前只能无参）；参数个数按注册信息检查（缺省值可省）。单独一条 CALL 返回全部输出列。
- 异常：过程抛出的错误变成执行错误 `procedure my.x failed: …`（语句事务回滚）。
- 不做：在 Cypher 里定义过程（Neo4j 也没有）；过程的输出类型声明。

## 6. LOAD CSV

- 语法：`LOAD CSV [WITH HEADERS] FROM url AS row [FIELDTERMINATOR 'c']`，url 是任意表达式（常量 / 参数）。
- 语义：无表头时 `row` 是字符串列表；有表头时是 map（表头 → 字符串）。**有表头时空字段与缺的列为 null**（属性设成 null 即不写，
  符合装载时的直觉），无表头时空字段是空串。值一律字符串，需要时用 `toInteger` / `toFloat` / `date()` 转。`linenumber()` / `file()` 两个函数给出当前行号与文件名。
- 安全：**缺省关闭**。只有在 `application:set_env(bitcask_cypher, cypher_import_dir, Dir)` 配置了导入目录时才能用；只接受 `file:///相对路径`
  （或纯相对路径），解析到导入目录之下（规范化后不能逃出目录，`..`、绝对路径、符号链接逃逸都拒绝）。不支持 http(s)（有 SSRF 风险，
  需要时调用方自己下载到导入目录）。
- 解析：RFC 4180——双引号包字段、`""` 转义、引号里可以有换行与分隔符；`\r\n` / `\n` 行尾；去掉 UTF-8 BOM；空行跳过。
  分隔符缺省 `,`，`FIELDTERMINATOR '\t'` 等单字节字符。按 64 KiB 块惰性读文件、惰性出行（不整读进内存）。
- 与写：每行的写在语句事务里——大文件要配 `CALL { … } IN TRANSACTIONS`（第 3.2 节），否则整个文件在一个事务里（Q8 前超过 4096 个顶点就报错，现在缺省不限）。
- 实现：子句 `{load_csv, Headers, UrlExpr, Var, Sep}` → 算子 `{load_csv, …}`，`flatmap` 每个输入行打开文件、惰性流出行；文件句柄在
  流结束或语句结束时关闭（打开的句柄登记在查询内缓存里，`run` 的 `after` 统一关）。

## 7. 时间与空间类型

### 7.1 类型与内部表示（也是对外的值形态）

| 类型 | Erlang 值 |
|---|---|
| `Date` | `{date, {Y, M, D}}` |
| `LocalTime` | `{localtime, NanosOfDay}` |
| `Time` | `{time, NanosOfDay, OffsetSeconds}` |
| `LocalDateTime` | `{localdatetime, {Y, M, D}, NanosOfDay}` |
| `DateTime` | `{datetime, {Y, M, D}, NanosOfDay, OffsetSeconds}`（本地日期时间 + 偏移） |
| `Duration` | `{duration, Months, Days, Seconds, Nanos}`（openCypher 的四分量，各自独立） |
| `Point` | `{point, Srid, X, Y}` / `{point, Srid, X, Y, Z}`（srid 7203 / 9157 笛卡尔，4326 / 4979 WGS-84） |

参数可以直接传这些元组；结果里也是这些元组（`bitcask_cypher:format_value/1` 转成 ISO 8601 / `point({…})` 文本）。

**命名时区不支持**：Erlang 标准库没有 IANA 时区库，`datetime({timezone: 'Europe/Berlin'})` / `'…[Europe/Berlin]'` 报错；只支持 `Z`
与 `±hh:mm` 固定偏移。（要支持就得引入时区数据库依赖——作为以后的可选项。）

### 7.2 函数与运算

- 构造：`date()`、`localtime()`、`time()`、`localdatetime()`、`datetime()`（当前时间，一条语句内取同一个时刻——statement 时钟），
  `date('2024-05-01')`、`date({year: 2024, month: 5, day: 1})`（也支持 `week`/`dayOfWeek`、`ordinalDay`、`quarter` 形式的常用子集：
  年月日、年周日、年序日），其余类型同理；`datetime({epochSeconds: …})` / `datetime({epochMillis: …})`；从别的时间值转换
  （`date(dt)`、`datetime({date: d, time: t})`）。
- `duration('P1Y2M3DT4H5M6.5S')`、`duration({days: 3, hours: 4})`、`duration.between(a, b)`、`duration.inMonths/inDays/inSeconds(a, b)`。
- `x.truncate`：`date.truncate('month', d)` 等（unit：millennium … second / millisecond / microsecond 的常用子集）。
- 访问：`.year .quarter .month .week .weekYear .day .ordinalDay .dayOfWeek .dayOfQuarter .hour .minute .second .millisecond
  .microsecond .nanosecond .timezone .offset .offsetMinutes .offsetSeconds .epochSeconds .epochMillis`（按类型可用的子集）；
  Duration：`.years .quarters .months .weeks .days .hours .minutes .seconds .milliseconds .microseconds .nanoseconds` 及
  `.monthsOfYear` 等；Point：`.x .y .z .longitude .latitude .height .srid .crs`。
- 运算：时间 ± Duration（先月后日再秒，月末按 openCypher 截到月底）；Duration ± Duration；Duration × / ÷ 数；比较：同类型可比，
  DateTime / Time 按时刻比；不同类型 `=` 为 false、`<` 为 null。Duration 只有 `=`，没有大小（openCypher 规定）。
- 空间：`point({x, y[, z][, crs]})`、`point({longitude, latitude[, height]})`、`point.distance(a, b)`（别名 `distance`；笛卡尔欧氏距离，
  WGS-84 用大圆距离、米）、`point.withinBBox(p, lowerLeft, upperRight)`。点只能比较相等。
- `ORDER BY` 全序位置（Neo4j 5）：… 路径 < Point < DateTime < LocalDateTime < Date < Time < LocalTime < Duration < 字符串 …
- 分组 / 去重：按值（DateTime 按时刻 + 偏移都相同才算同一个）。

### 7.3 存储

引擎 meta 只能存数值、字符串、布尔与字符串数组。时间 / 空间值存成规范文本（ISO 8601；点存 `srid;x;y[;z]`），另在保留键
`_types`（字符串数组，元素 `属性名 \t 类型`）里记下哪些属性是什么类型；读出时还原成元组，`_types` 不出现在属性里。边属性同样。

- 图层 API（`graphdb:create_vertex` 等）也接受这些元组（`graphdb_model:check_value/2` 放行、编码时写 `_types`），读出同样还原——两边互通。
- 下推：值是时间 / 空间的条件不下推给引擎（`scalar/1` 为假），只靠 Erlang 过滤——结果正确，只是不加速；属性索引同理不用。
  （以后可以把 Date / LocalDateTime 这类字典序即时间序的类型按文本下推。）
- 时间值的列表不能存（与数值列表一样，meta 不支持），报错。

### 7.4 风险

- 文本存储 + `_types` 是本库的约定，直接读引擎 meta 的旧代码会看到字符串与 `_types` 键（`_` 开头本来就是保留前缀）。
- 时间运算的边界（闰年、月末、负 Duration、纳秒进位）多，测试按 openCypher TCK 的典型用例写。

## 8. 分步计划（TASK.md Q7）

| 步骤 | 内容 |
|---|---|
| Q7-1 | FOREACH |
| Q7-2 | `CALL {}` 子查询（导入 WITH / `CALL (vars)`、单元子查询、OPTIONAL CALL、UNION 体） |
| Q7-3 | `EXISTS {}` / `COUNT {}` / `COLLECT {}`；记号预处理的嵌套模式区 |
| Q7-4 | 用户过程 / 函数注册；CALL 带参数 |
| Q7-5 | LOAD CSV（导入目录、RFC 4180、惰性读）、`linenumber()` / `file()`；`CALL {} IN TRANSACTIONS` |
| Q7-6 | 时间 / 空间类型：值、函数、运算、比较 / 排序、存储（`_types`）、图层 API 互通 |
| Q7-7 | 回归、文档（`cypher-{zh,en}.md`）、TASK / CHANGELOG |

每步单独可用、单独测，顺序按依赖：FOREACH / CALL {} 先把子流水线的规划做成通用的；LOAD CSV 依赖 IN TRANSACTIONS 才实用；
时间类型最独立但改动面最大，放最后。

## 9. 落地记录

- **子流水线**：FOREACH / `CALL {}` 的子计划在语句规划时静态做好（`{foreach, X, E, Ops}`、`{subquery, Kind, Imports, Ops, Cols}`、
  `{subquery_tx, …, N}`）；`EXISTS` / `COUNT` / `COLLECT` 与模式谓词一样在执行时按需规划（`bitcask_cypher_plan:sub_query/2`），计划按
  {子句, 外层变量} 在查询内缓存——表达式在语义检查之后才知道引用了哪些外层变量（`mentions/2` 按名字找，多算无害）。
  `bitcask_cypher_plan:all_ops/1` 递归列出子流水线里的算子（关系类型预注册、判断有没有写）。`union` 算子改成对每个输入行跑各段（顶层输入
  是一个空行，行为不变），子查询的 UNION 体因此拿得到导入变量。
- **FOREACH**：变量的种类是 `value`，语义检查的 `must_be/4` 现在对 `value` 放行（`UNWIND ns AS n SET n.x = 1` 这类以前也被拒），
  由执行时检查（`cannot set a property of …`）。
- **CALL {}**：旧形式的导入 WITH 只认「只有变量、不改名、没有 WHERE / ORDER / SKIP / LIMIT」；返回列名用投影名，含 `.`、`(`、空格的视为
  没起别名而报错。子查询里有写时先物化外层输入（写在读之后）。
- **记号预处理**：`count` / `collect` + `{` + 子查询开头 → `COUNT_SUB` / `COLLECT_SUB`；模式区判断改成带栈的（子查询的 `{` 压栈、配对的
  `}` 弹出），`CALL (…) {` 的识别看已输出的记号。语法冲突：`Expect 2`（`EXISTS {` 与映射投影、FOREACH 里标签表达式的 `|`），原来列表
  推导那一个在加了这些规则后不再出现。
- **IN TRANSACTIONS**：`bitcask_cypher_exec:run_batched/4` + `bitcask_cypher:batched_statement/4`。每批的事务函数可能被事务层重跑，开头把统计恢复到
  这批开始时、清掉顶点缓存与写计数；提交后再清一次顶点缓存。它之后的子句在事务外对全部批的结果行执行。错误信息带已提交的批数。
- **用户过程 / 函数**：`bitcask_cypher_registry`（persistent_term），计划缓存键带注册表 generation（进程字典里存 `{Gen, Map}`）。带命名空间的
  函数调用不再限于 `fts.*` / `search.*`：语法上任何 `a.b(…)` 都是调用，未知名字变成**语义错误**（原来是语法错误）。CALL 支持多段名字与参数；
  内置 `db.*` 仍只算一次，用户过程按行调用。写过程判断写语句是看注册表（`is_write/1`）。
- **LOAD CSV**：`csv_record/5` 是可重入的解析——缓冲不够一条记录就返回 `more`、读下一块后从记录开头重来；打开的文件登记在进程字典，
  `with_run/1` 结束时统一关（`LIMIT` 提前结束也不漏）；游标进程退出时文件随进程关闭。`linenumber()` / `file()` 经行里的隐藏键传递
  （投影之后为 null）。
- **时间 / 空间**：`bitcask_cypher_temporal`。`=` / `<` / 排序 / 属性访问 / `+ - * /` 遇到元组交给它；构造函数与 `ns.f` 形式的函数在
  `bitcask_cypher_expr:call/3`；语句时钟 `bitcask_cypher_exec:statement_now/0`（查询内缓存）。存储在 `graphdb_model`：`check_value/2` 放行、
  `encode_meta_props/2` / `encode_edge_props/1` 写文本 + `_types`、`safe_decode_meta/1` 统一还原（图层的读都经过它）。没做：`truncate` 的第三个
  参数、`date.statement()` 等时钟变体、命名时区。
- 顺带：写语句 / 调用方事务里的标签扫描在有就绪属性索引时改读索引条目（TASK G16）。
- 验证：`test/bitcask_cypher_phase3_tests.erl`（8 组）+ 各处回归；eunit 604/604（连跑 2 遍），`rebar3 as prod compile`、xref、dialyzer 干净。

