# bitcask_cypher 任务

Cypher（openCypher）查询层，建在 bitcask 图层（`graphdb` / `graphdb_model`）的公开接口上。原在 bitcask 主应用里，2026-11-24 拆为
同一仓库里的独立应用（见根目录 `TASK.md` C0）；下面是拆分前的明细，编号照旧。路径都相对本应用目录（`doc/`、`test/` …）；
TCK 运行器在仓库根目录跑：`apps/bitcask_cypher/test/tck/fetch.sh`、`escript apps/bitcask_cypher/test/tck/tck.escript`。

当前方向：语法与语义对齐 openCypher 2024.3（仓库 `grammar/openCypher.bnf` 与同版 TCK）。

---

## O — 按 openCypher 2024.3 文法对齐（未发版）

按文法（ISO WG3 BNF，377 个产生式）逐个候选写探测语句（`/tmp` 下的探测脚本，220 条文法探测 + 19 条扩展探测），起点 70 条不过；
分六批补，每批跑探测、TCK（严格比对）、测试。回归 `test/bitcask_cypher_oc2024_tests.erl`。结果：220 条文法探测全过（只剩一条故意写错
的对照 `CALL test.echo()` 报参数个数错），TCK 3880 / 3880。

| 编号 | 任务 | 状态 |
|---|---|---|
| **O1** | 词法与名字：数字下划线（`1_000`、`0x_1F`）、浮点后缀 `f` / `d`、`INF` / `INFINITY` / `NAN` 字面量、`'it''s'` 连写引号、`` \` `` 与 `\U` 六位转义、反引号名字里的 ``` `` ```、Unicode 标识符（XID_START / XID_CONTINUE，用 `re` 的 Unicode 属性核对；全角破折号仍是 `InvalidUnicodeCharacter`）、参数 `$0` / `` $`x` ``；关键字都可当变量名（记号预处理按上下文把「不可能是关键字」的关键字换成名字：AS 之后、节点 / 关系模式里、路径变量、声明过的名字再出现）。 | ✅ |
| **O2** | 子句与表达式：单独一条 `CALL … YIELD a` 不带 RETURN、`UNION DISTINCT`、`RETURN ALL` / `WITH ALL`、`OFFSET`（SKIP 同义）、`SET` / `REMOVE` 的目标是任意后缀表达式（`m.node.p`、`n['k']`、`(n).p`）、简单 `CASE x WHEN 1, 2 THEN`、`shortestPath(…)` / `allShortestPaths(…)` 当表达式（改写成内部的 COLLECT 子查询）；修 `EXISTS { … UNION … }` 崩溃（各段没有 RETURN 时列为空）。 | ✅ |
| **O3** | 元素模式里的 WHERE：`(n:L WHERE …)`、`[r:T WHERE …]`，解析时抽出与子句 WHERE 做 AND（MATCH / OPTIONAL MATCH、`EXISTS { 模式 }`、模式推导）；变长关系上的 WHERE、CREATE / MERGE 里的报错。 | ✅ |
| **O4** | 标签表达式：`IS` 形式、`&`、`%`、括号、`!` 嵌套，节点 / 关系模式与 WHERE 里（`n IS A`、`r:T&!U`）；标签项改成递归（`{any, …}` / `{all, …}` / `{'not', …}` / `wildcard`），关系的复杂表达式按类型名过滤；旧写法 `:A:B`、`:T|:U` 照旧。语法冲突 2 → 4（同一个「`|` 接标签还是分隔符」的歧义出现在三层里，照旧取标签）。 | ✅ |
| **O5** | 路径搜索前缀：`ALL` / `ANY [k]` / `ALL SHORTEST` / `ANY SHORTEST` / `SHORTEST k` / `SHORTEST [k] GROUP(S)`（`PATH` / `PATHS` 可写，k 可以是参数）。单条变长关系上的 ANY / ALL SHORTEST 走最短路 BFS；别的给输入行打标记、照常匹配、全部条件过滤后按 (标记, 起点, 终点) 分组按长度挑（WHERE 先过滤再挑，同 Neo4j）。 | ✅ |
| **O6** | 量化路径：路径项改成元素序列（节点、关系、量化关系、括号路径 / 量化组），解析后由 `norm_path` 规范成链：相邻节点模式是同一个节点（合并不了就插一条 `-[*0..0]-`）、组两端缺的节点补匿名节点。`((x)-[r]->(y)){m,n}` / `+` / `*` / `{n}` / `{m,}` / `{,n}`：新算子 `qpp_expand` 从左端按组体深度优先逐次展开（组里的标签 / 属性 / WHERE 每次重复各算一次，关系在整条路径里不重复），规划器把量化组当成连接两端的「边」参与分量规划，从右端展开时用倒过来的组体、结果列表翻回模式顺序；组里的具名变量在组外是列表；隐藏的关系列表变量让路径变量照常能建。`-[r:T]->{1,2}`、`-->+`（关系里没有 WHERE）改写成变长关系；带 WHERE 的量化关系改成单关系的量化组。不带量词的 `((a)-[r]->(b) WHERE …)` 展开，`(p = …)` 整条时等同 `p = …`。限制：量化组不能嵌套、组里不能有变长关系、至少一条关系；子路径变量只能用在整条模式上；表达式里的模式（模式谓词、模式推导）不支持量化组。 | ✅ |
| **O8** | 文档：新增语法参考 `doc/cypher-syntax-zh.md` / `cypher-syntax-en.md`——第一部分 openCypher 2024.3 语法（语句、读写子句、模式含标签表达式 / 量化路径 / 路径搜索前缀、表达式与优先级、函数、不支持的写法），第二部分 bitcask 特有的语法（`@@` 与查询串、`<=>`、`fts.*` / `search.hybrid`、`text` / `embedding`、用户过程 / 函数、`db.*` 内置过程、与 openCypher 不同的地方）；使用说明开头与第 4 节链过去，`explain` 算子表补上 `qpp_expand` 等；README 的文档表加上。 | ✅ |
| **O7** | 删除 Neo4j 的扩展语法（不在 2024.3 文法里）：`FOREACH`、`CALL { … }` 子查询（含 `CALL (a) { … }`、`CALL (*)`、`OPTIONAL CALL`、`IN TRANSACTIONS` 分批提交）、`COUNT { … }` / `COLLECT { … }`、`LOAD CSV`（含 `linenumber()` / `file()`、配置项 `cypher_import_dir`）。语法、预处理、语义、规划、执行、测试、文档一并删；内部的 COLLECT 子查询机制留着（shortestPath 表达式用）。保留 bitcask 自己的 `@@` / `<=>` / `score()` / `fts.*` / `search.*` 与用户过程 / 函数。保留但不算 Neo4j 专有的：`ORDER BY … NULLS FIRST / LAST`（SQL / GQL）、语句末尾的 `;`、MERGE 的多个 `ON … SET`（TCK 用到）。删前的完整代码备份在 `~/workspace/bitcask-backups/bitcask-cypher-before-oc9-20261124.tar.gz`。 | ✅ |

---

## Q8 — Cypher：按 openCypher TCK 对齐（未发版）

> 运行器 `test/tck/`（`fetch.sh` 拉 openCypher 2024.3 场景集到 `_build/tck/`，`tck.escript` 跑）；用法与结果见 `doc/cypher-{zh,en}.md` 第 14 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q8-1** | 值语义四项：同类型列表属性（`[1, 2]`、`[true]`、`[date(…)]`，`_types` 记 `list:<类型>`）；64 位整数溢出（运算 / `sum` / `abs` / 字面量）；`toFloat('1e3')` 等数值文本；字符串 + 数值拼接。 | ✅ |
| **Q8-2** | TCK 运行器：Gherkin（Outline / Examples / 文档串 / 表格转义）、命名图、参数、`there exists a procedure`（注册用户过程，串行跑）、结果比对（整数 / 浮点区分、节点 / 关系 / 路径、时间按文本、列表忽略顺序）、副作用按前后图状态的差、错误按阶段。 | ✅ |
| **Q8-3** | 时间：带基础值的映射构造按表示法取分量（周 / 季度 / 序数 / 日历）、6 位紧凑日期、秒为 0 时只写到分、小数 Duration 的折算（月 → 整天 + 秒）、Date ± Duration 只取整天、`truncate` 的覆盖映射（timezone 只换标签）、新 timezone 先换算、亚秒分量覆盖、`date.statement()` / `transaction()` / `realtime()`、`±hh:mm:ss` 偏移、`P2012-02-02T…` 备用格式、`toString(时间值)`。 | ✅ |
| **Q8-4** | 语义检查对齐：编译期类型错误（布尔 / 算术操作数、对标量取属性、`IN` 右边、`WHERE` 根、图函数参数、`SKIP` / `LIMIT`、`DELETE` 标量、标量变量进模式）；歧义聚合；`count(rand())`；`CREATE (a)` 绑定节点；`DELETE n:L`；`YIELD *` 只在单独 CALL；模式只能当谓词；`WITH … WHERE` / `ORDER BY` 的可见性与投影项替换（只限简单表达式与聚合）；缺参数是编译期错误；过程隐式参数、void 过程、参数类型声明。 | ✅ |
| **Q8-5** | 语法 / 执行对齐：列名取投影项原文；`^` 左结合；链式比较不跨括号；`.1` 浮点；`SET (n).p`；浮点字面量溢出与非法字符是语法错误；值变量当节点（运行时检查）；已绑定关系 / 关系列表在模式里复用；反向变长范围为空；无向 MERGE；`WITH *` 无变量；`r:T` 判断关系类型；`range` 反向步长；删除后的实体不能读属性 / 标签；`*` 不限跳数；`*1..1` 是列表；反向展开的变长关系列表翻回模式方向；推导局部变量在规范化时也在作用域里。 | ✅ |
| **Q8-7** | 命名时区（新模块 `bitcask_tz`）：读本机 zoneinfo（`bitcask.tz_dir` > `TZDIR` > `/usr/share/zoneinfo`）的 TZif v1/v2+，最后一次转换之后按文件尾的 POSIX 规则；带时区名的 DateTime `{datetime, D, Ns, Off, Zone}`，输出 `…+02:00[Europe/Stockholm]`；重叠段按给出的偏移 / 较早偏移、空隙往后挪；换时区保持时刻（先在原时区用全部分量构造再换算）；加减 Duration 月 / 天走本地日历、秒走时刻；`duration.between` 把没有偏移的一边放进对方时区；存取（文本 + `_types`）。回归 `named_time_zones_test_`（没有 zoneinfo 时跳过）。TCK 时间部分 87.4% → 99.5%。 | ✅ |
| **Q8-8** | NaN / Infinity（新模块 `bitcask_ieee`）：原子 `'NaN'` / `'Infinity'` / `'-Infinity'` 作对外形态；浮点算术按 IEEE 754（溢出、浮点除以 0、`^` 按 Java `Math.pow`；整数运算不变，整数除以 0 仍报错）；比较（NaN 不等、不可比→false，跨类型→null）；排序 -∞ < 有限 < +∞ < NaN < null；数学函数（sqrt / log / exp / asin / acos / cot 等原来得 null 的改成 NaN / ±∞）；新函数 `isNaN`；`toString` / `toFloat` / `toInteger`；sum / avg / min / max；参数；存取（文本 + `_types` 的 `float` 标记，列表元素也行）。回归 `nan_infinity_test`。TCK 99.5% → 99.8%。 | ✅ |
| **Q8-9** | 负年份：`bitcask_temporal` 自带前推公历（Hinnant 的 days_from_civil / civil_from_days，替掉只收 Y >= 0 的 `calendar`），年份范围 ±999999999；文本负年份 `-0001`、超 4 位正年份 `+10000`（java.time）；周日期 / 序数日期 / 星期 / 截断都走它；0..3000 年逐周与 `calendar` 对照一致。Duration 乘除：按精确分数（浮点取最短十进制）逐级折算（月→天按 146097/4800、天→秒），纳秒向零截断（同 Neo4j 的 `approximate`），不再四舍五入多出 1 纳秒。回归 `negative_years_test`、`duration_scaling_test`。TCK 99.8% → 99.9%。 | ✅ |
| **Q8-10** | 关系 id 不复用：图层新键族 `<<1,"_g:">> r <src> <etype> <dst>` 记这对顶点下一条新边至少用的 rank（`graphdb:retire_rank_txn/5` 在 Cypher 删边时推到 rank + 1，`rank_floor_txn/4` 用不拿锁的版本守卫读）；`CREATE` / `MERGE` 从下限往上找空 rank，同一条语句里先删后建、以后的语句里删了再建，都拿不到删掉的 id。只有删过边的顶点对才有这个键；经图层 API `del_edge` 删的不记。建 2000 条关系的耗时与不读下限时在噪声内。回归 `rel_id_no_reuse_test`。TCK 3877 → 3878。 | ✅ |
| **Q8-11** | 放开单条写语句的 4096 顶点上限：缺省不限，应用环境 `bitcask.cypher_max_write_vertices = N` 可设上限。大事务的超线性耗时来自 GC（事务缓冲 / 锁表 / 守卫都在执行进程堆上，OTP 大堆每次只长约 20%，反复全量 GC）：一条语句写到 4096 个顶点起、每翻一番把 `min_heap_size` 提到当前堆的两倍，语句结束（`with_run` 顶层）恢复。一条语句建 N 条关系（2N 个顶点）：N = 5 万 15.0 s → 5.6 s、10 万 34.1 s → 11.5 s（分 100 条语句 8.1 s），近似线性。TCK 结果汇总改为两位小数。回归 `write_vertex_cap_test` 改为验证不限 + 可配上限 + 堆参数恢复。TCK 3878 → 3879。 | ✅ |
| **Q8-12** | 被 IANA 合并的时区：本机 zoneinfo 是带 backzone 编的（Debian），`Europe/Stockholm` 等保留各自 1970 年以前的数据；IANA 缺省编法与 Java / Neo4j（TCK 按它）把它们编成链接。`bitcask_tz` 内置 142 个名字 → 合并目标的表（tzdata 2026b：backward 的 Link 名 ∩ backzone 里定义的名字），缺省读目标的文件、显示名照旧；应用环境 `tz_backzone = true` 照用本机文件。回归在 `named_time_zones_test_` 里两种模式各验一次。TCK 3879 → **3880（100%）**。 | ✅ |
| **Q8-13** | 错误类型与细节代码：新模块 `bitcask_cypher_error`，错误 map 加 `type` / `detail`（openCypher 的 error type / detail code）；抛错处把消息包成 `{cypher_code, Type, Detail, Msg}`，各接住处展开（解析没包的归 `SyntaxError` / `UnexpectedSyntax`）。语义 / 规划全部归类（`fail/4`）；执行 / 时间 / 时区 / 过程注册按类型错 `TypeError`、取值错 `ArgumentError`、算术 `ArithmeticError`、子句组合 `InvalidClauseComposition` 等归类，存储 / 文件 / 内部错误不归类。按 TCK 细化：路径变量与 YIELD 别名重复绑定 = `VariableAlreadyBound`、节点 / 关系当另一种用 = `VariableTypeConflict`；ORDER BY 混用分组键表达式与聚合 = `AmbiguousAggregationExpression`、用没投影的变量 = `UndefinedVariable`；WITH 未起别名的聚合 = `NoExpressionAlias`；下标错细分 `MapElementAccessByNonString` / `ListElementAccessByNonInteger`；词法：数字后紧跟字母 = `InvalidNumberLiteral`（当映射键用 = `UnexpectedSyntax`）、空的反引号标识符可用、非 ASCII 怪字符 = `InvalidUnicodeCharacter`；变长部分的语法错 = `InvalidRelationshipPattern`。行为变化：`MATCH (n $p)` 改为 `InvalidParameterUse`（同 openCypher；`CREATE (n $p)` 照旧）。TCK 运行器改为严格比对类型与细节（`*` 通配；`--phase-only` 旧判定）。回归 `error_codes_test`。严格判定下 TCK 3198 → **3880（100%）**。 | ✅ |
| **Q8-6** | 顺带修图层：单字符关系类型名的名字索引 key 被当成 id key，第二个起的单字符类型拿到 0x6E0001xx 的 id、并覆盖了别的类型的名字索引（`graphdb_tests:etype_registry_one_char_names_test_`）。 | ✅ |

结果：TCK 2024.3 共 3880 个场景，**全部 3880 个通过（100%）**；起点 2792（72.0%）。错误场景比阶段、错误类型与细节代码（Q8-13 起）。
行为变化（测试已同步）：`YIELD *` 不能用在查询中间、`RETURN (a)-->(b)`
这类模式投影是错误、`*3..1` / 无向 MERGE 合法、未知命名空间函数与缺参数改为编译期错误、时刻文本省略零秒。

---

## Q7 — Cypher 三期：子查询、FOREACH、用户过程 / 函数、LOAD CSV、时间与空间类型（未发版）

> 设计：[`doc/cypher-phase3-design-zh.md`](doc/cypher-phase3-design-zh.md)（第 9 节落地记录）。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q7-1** | `FOREACH (x IN list \| 更新子句…)`（可嵌套、可 MERGE）；`UNWIND` / `FOREACH` 的元素变量可以被 `SET` 等使用（执行时检查类型）。 | ✅ |
| **Q7-2** | `[OPTIONAL] CALL { … }` / `CALL (a, b) { … }` / `CALL (*) { … }` 子查询：旧形式导入 WITH、单元子查询（只写）、UNION 体。 | ✅ |
| **Q7-3** | `EXISTS { … }` / `COUNT { … }` / `COLLECT { … }`（完整子查询或「模式 [WHERE]」简写，可 UNION）；记号预处理的模式区改成带栈的。 | ✅ |
| **Q7-4** | 用户过程 / 函数：`bitcask_cypher:register_procedure/2`、`register_function/2`、`unregister/1`、`registered/0`（新模块 `bitcask_cypher_registry`）；`CALL ns.proc(参数)`、`ns.f(…)`；写过程；计划缓存随注册表作废。 | ✅ |
| **Q7-5** | `LOAD CSV [WITH HEADERS] FROM … AS row [FIELDTERMINATOR …]`（应用环境 `cypher_import_dir` 才开、只读导入目录、RFC 4180、按块惰性读）、`linenumber()` / `file()`；`CALL { … } IN TRANSACTIONS [OF n ROWS]` 分批提交。 | ✅ |
| **Q7-6** | 时间 / 空间类型（新模块 `bitcask_temporal`）：Date / LocalTime / Time / LocalDateTime / DateTime / Duration / Point，构造、访问、运算、比较 / 排序、`duration.between`、`truncate`、`point.distance` / `withinBBox`、语句时钟；存储（文本 + `_types`），与图层 API 互通。 | ✅ |
| **Q7-7** | 回归：`test/bitcask_cypher_phase3_tests.erl`（8 组）；`plan_cache_test` 按新缓存形态更新；`search_functions_test` 里未知命名空间改为语义错误。文档：`doc/cypher-{zh,en}.md` 第 4、5、10 节与新的 11～13 节。 | ✅ |

不做：`IN TRANSACTIONS … ON ERROR` / `REPORT STATUS`、在 Cypher 里定义过程、命名时区、`LOAD CSV` 读网络地址、`truncate` 的覆盖映射、
`date.statement()` 等时钟变体。验证：eunit 604/604（连跑 2 遍），`rebar3 as prod compile`、xref、dialyzer 干净。

---

## G16 — 写语句里的标签扫描走属性索引（未发版）

| 步骤 | 内容 | 状态 |
|------|------|------|
| **G16-1** | 写语句 / 调用方事务里的标签扫描：有就绪的属性索引、条件可用（等值 > `IN` > 大小比较）时改读索引条目——点值锁它自己的索引前缀、大小比较锁该属性的前缀（`bitcask_txn:prefix_range/3` 新选项 `{within, {Lo, Hi}}`：锁整个前缀、只读一段）；索引声明经守卫读（并发建 / 删索引让语句重跑）。2000 个顶点上 `MATCH (c:C {k: 1}) SET …` 6.7 ms → 0.13～0.17 ms。 | ✅ |
| **G16-2** | 回归：`txn_label_scan_index_test`（走 / 不走索引结果一致，调用方事务里看得见之前的写）、`txn_label_scan_phantom_test_`（8 进程 × 5 次「数一遍再建一个」，有 / 无索引都可串行化）。 | ✅ |
| **G16-3** | 试过前缀锁的「并行 try_acquire 快路径」（同时向全部分片试拿、拿不到的再按序排队）：同一轮对比没有收益（无争用时逐个分片 call 本来就便宜），已回退。 | — |
| **G16-4** | 锁服务死锁漏检（原有问题）：一次入队可能同时闭合多个环，原实现只解第一个，其余环的成员早已入队检过（当时无环），只能等 5 s 兜底计时器——高争用的「数一遍再建一个」每轮 0～20 次 `lock_wait_timeouts`、卡 5～35 s。改为 `resolve_cycles/3` 循环解开经过请求者的全部环（已选受害者在后续搜索里视为已移除）。同一场景 8 轮 0 次、每轮 0.02～0.06 s；回归 `multi_cycle_requester_test_`（旧实现下失败）。定位过程见 `../../doc/txn-layer-design-zh.md` §13.8。G15-5 那次偶发失败已证实同源（异步注册恢复后全量 8 次全过）。 | ✅ |

---

## Q6 — Cypher：对齐 openCypher 语法（未发版）

> 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md) 落地记录第 21 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q6-1** | 表达式：列表推导 `[x IN l WHERE p \| e]`、量词 `all` / `any` / `none` / `single`、`reduce`、映射投影 `n {.p, .*, k: e, v}`、链式比较 `a < b <= c`、`exists(n.prop)`；十六进制 / 八进制整数；函数 `ceil` `floor` `round` `sign` `rand` `sqrt` `exp` `log` `log10` `e` `pi` `sin` `cos` `tan` `cot` `asin` `acos` `atan` `atan2` `degrees` `radians` `haversin` `timestamp`；聚合 `percentileCont` / `percentileDisc` / `stDev` / `stDevP`。`ALL ANY NONE SINGLE REDUCE EXISTS UNION` 成为关键字（前六个不跟 `(` 时仍可作变量名）。 | ✅ |
| **Q6-2** | 模式表达式：模式谓词 `WHERE (a)-[:T]->(:L)`、`exists((a)--())`、模式推导 `[(a)-[r]->(b) WHERE … \| e]` / `[p = (a)-->() \| …]`。`bitcask_cypher` 的记号预处理在表达式区标出模式；子模式用 MATCH 的规划器规划成子流水线（查询内缓存）。 | ✅ |
| **Q6-3** | 语句：`UNION` / `UNION ALL`（列名一致、不能混用，写语句各段同一事务）；`CREATE p = …` / `MERGE p = …`；`CALL db.labels` 省括号、`YIELD *`。 | ✅ |
| **Q6-4** | 回归：`opencypher_expressions_test`、`pattern_expressions_test`、`union_and_call_test`、`named_write_paths_test`；语义反例 9 条（原「CREATE 不允许命名路径」换掉）。文档：`doc/cypher-{zh,en}.md` 第 4 节。 | ✅ |

仍不做：`CALL {}` / `EXISTS {}` / `COUNT {}` 子查询、`FOREACH`、用户过程、`LOAD CSV`、时间 / 空间类型、索引 / 约束 DDL（属性索引用
`graphdb:create_index/3`）。验证：eunit 593/593（连跑 3 遍），`rebar3 as prod compile`、xref、dialyzer 干净。

---

## Q5 — Cypher：流式游标、检索的函数形式、属性索引（未发版）

> 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md) 落地记录第 20 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q5-1** | 流式游标 `bitcask_cypher:cursor/2,3,4`、`fetch/2`、`columns/1`、`close/1`：独立进程持有惰性流水线，按需推进；开游标的进程退出或空闲超时（缺省 5 分钟）自动关闭；只读、只在句柄上开。 | ✅ |
| **Q5-2** | 检索的函数形式：`fts.phrase` / `near` / `wildcard` / `fuzzy` / `fields`、`search.hybrid`；作为 WHERE 合取项是起点（`search_seek`，`score(n)` 可用），别处按顶点判断。 | ✅ |
| **Q5-3** | 属性索引：`graphdb:create_index/3`（声明 building → 分块回填 → ready）、`drop_index/3`、`indexes/1`；所有改顶点的写入同批维护（声明加只校验的守卫，与建索引并发不漏）；标签扫描起点执行时改走就绪索引（等值 > `IN` > 范围）；`check_invariants` 查索引一致。 | ✅ |
| **Q5-4** | 回归：`cursor_test`、`search_functions_test`、`property_index_test_`、`property_index_concurrent_build_test_`。文档：`doc/cypher-{zh,en}.md` 第 2、6.3、8 节。 | ✅ |

---

## Q4 — Cypher 二期其余（未发版）

> 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md) 第 5 节二期、落地记录第 19 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q4-1** | 普通命名路径 `p = (a)-[r]->(b)…`（含变长段、OPTIONAL MATCH 时为 null）、`allShortestPaths`。 | ✅ |
| **Q4-2** | 标签表达式 `:A\|B`、`:!A`（模式与 WHERE）；`A\|B` 下推为 `contains_any`。 | ✅ |
| **Q4-3** | `ORDER BY … NULLS FIRST / LAST`；正则 `=~`；下标 `x[i]` / `m['k']`、切片 `x[a..b]`。 | ✅ |
| **Q4-4** | 函数 `substring` / `replace` / `split` / `trim` / `ltrim` / `rtrim` / `left` / `right` / `reverse` / `head` / `tail` / `last` / `range`。 | ✅ |
| **Q4-5** | `CALL db.labels()` / `db.relationshipTypes()` / `db.propertyKeys()`，`YIELD … [WHERE …]`，单独一条 CALL 返回全部列。 | ✅ |
| **Q4-6** | 整条模式的 MERGE（端点未绑定、多跳；整条匹配不上就整条建）。 | ✅ |
| **Q4-7** | 回归 5 组 + 语法正例 / 语义反例；原「命名路径 / allShortestPaths 报二期」与两条 MERGE 反例换掉。文档：`doc/cypher-{zh,en}.md`。 | ✅ |

设计稿第 5 节列的二期项全部完成。仍不做（设计上的非目标）：`UNION`、`CALL {}`、`FOREACH`、`EXISTS {}`、列表推导、`reduce`、量词、
用户过程、模式语句、`LOAD CSV`、文本形式的 `EXPLAIN`。验证：eunit 577/577，`rebar3 as prod compile`、xref、dialyzer 干净。

---

## Q3 — Cypher 二期第一批：OPTIONAL MATCH、MERGE、CASE（未发版）

> 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md) 第 5 节二期、落地记录第 18 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q3-1** | `OPTIONAL MATCH`：子流水线 `{optional, [Op], NewVars}`，无结果时交出原行、新变量为 null；可接 MATCH / 写子句；可在调用方事务里用。 | ✅ |
| **Q3-2** | `MERGE` 单个节点 / 两端已绑定的单条有向关系，`ON CREATE SET` / `ON MATCH SET`（可多个、任意顺序）；查找复用标签扫描 + node_check / 展开到 + rel_check，创建复用 CREATE；前缀读锁保证并发不重复创建；关系类型在语句前注册。 | ✅ |
| **Q3-3** | `CASE`：通用 / 简单两种形式，只求值命中的分支；聚合可以在 CASE 里，CASE 也可以引用聚合结果。 | ✅ |
| **Q3-4** | 回归：`optional_match_test`、`case_expr_test`、`merge_node_test`、`merge_rel_test`、`merge_concurrent_test_`（8 进程 × 10 次 MERGE 同一节点 → 1 个）；语法正例 10 条、语义反例 8 条；原来「OPTIONAL MATCH / MERGE 报二期」的两条反例换掉。 | ✅ |
| **Q3-5** | 文档：`doc/cypher-{zh,en}.md` 语法表、表达式、语义、写一节；示例 `examples/cypher_demo.escript` 加三步。 | ✅ |

还没做（二期其余）：`allShortestPaths`、普通命名路径、标签表达式 `:A|B`、`NULLS FIRST/LAST`、正则 `=~`、字符串函数、`head` / `tail` /
`last` / `range`、列表下标、`db.labels()` 等、端点也要 MERGE 的整条模式。验证：eunit 555/555，`rebar3 as prod compile`、xref、dialyzer 干净。

---

## G15 — 图 / Cypher：条件下推、计划缓存、写语句与事务锁开销（未发版）

> 来源：13.1.0 之后的图层 / Cypher 分析（cypher_bench：2 万顶点 / 10 万边，索引模式）。按顺序做 1～5。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **G15-1** | 条件下推（设计稿 7.3 节）：起点是标签扫描 / 全量扫描时，其余标签、内联属性、WHERE 里只涉及该变量与常量 / 参数的 `= < <= > >=`、`IN`、`IS NOT NULL` 收进算子（`{label_scan, V, L, #{push, fetch}}`、`{all_nodes_scan, V, Push}`）；执行器把它们**放宽**成引擎 meta filter 的必要条件（整数与浮点两边都查、跨类型大小比较含等号、字符串不比大小、null / 列表不下推），原有过滤全部保留——结果不变。标签扫描按 256 个 vid 一块：够密（跨度 ≤ 4 倍个数）就对这段 vid 做一次带 filter 的 range，文档随同读回进顶点缓存，不再逐个 `get_doc`；稀疏的块照旧逐个读。`graphdb_model:doc_info/1` meta 只解码一次。 | ✅ |
| **G15-2** | 写语句的读锁：`bitcask_txn` 新选项 `{read_locks, guard_only}`——带守卫的 read 模式读不拿读锁（提交时守卫校验；写、write 模式读、不带守卫的读照旧加锁，与图层悲观事务混跑隔离不变；只读事务补一条只含校验的批）。Cypher 写语句缺省用它；`txn_probe` 探邻接表头改用读模式。原计划「简单写语句绕过事务」会让 Cypher 写对图层悲观事务（`put_edge_txn` 等用加写锁不带守卫的读）变成直通写、可能丢更新，没做。 | ✅ |
| **G15-3** | `bitcask_cypher` 按查询文本缓存解析 + 规划结果（调用进程的进程字典，至多 128 条）；`bitcask_cypher_sema:collect_params` 改累加器遍历。 | ✅ |
| **G15-4** | 执行器：查询内缓存用到时才建、顶层查询不再逐个保存恢复；`id(v)` 起点紧跟从 v 出发的一跳展开时不单独查存在（`{node_by_id, V, E, nocheck}`）。 | ✅ |
| **G15-5** | 锁服务：`release_all` 只给要过锁的分片发 release（调用方进程里记），不再逐分片 `ets:member`。`register` 不往返（调用方直写共享表 + cast 归属分片 monitor）、注销改 cast：第一次这样改后 `graphdb_txn_tests` 的并发死锁用例偶发失败（全量跑 3～4 次挂 1 次，靠兜底计时器脱困）、一度回退；根因是 G16-4 的「一次入队闭合多个环只解一个」，修复后恢复异步——全量连跑 8 次、两个事务测试模块连跑 10 次全过。同一轮对比同步注册：空事务 4.9～5.1 → 2.2～2.4 µs、`put_edge_txn` 19.7 → 15.9 µs、按 id 的 Cypher `SET` 22.7～23.5 → 20.2～20.4 µs。 | ✅ |
| **G15-6** | 回归：`pushdown_matches_unpushed_test_`（KV / 索引两种模式，26 个谓词 × 标签扫描 / 全量扫描，对照 `NOT (NOT (P))`；内联属性、多标签；批量取回的文档与逐个读一致；聚合一致）、`plan_cache_test`、`start_without_existence_check_test`、`guard_only_read_only_txn_revalidates_test`、`guard_only_skips_read_locks_test`；`explain` 用例按新算子形态更新。 | ✅ |
| **G15-7** | 顺带：`doc/cypher-*.md` 第 10 节的上游缺陷警告删除（13.1.0 已修）；`test/cypher_bench` 的过时注释。 | ✅ |

实测（cypher_bench，同机，改前 → 改后）：

| 项 | 改前 | 改后 |
|---|---|---|
| 一跳：Cypher 预编译 / 文本 | 7.1～7.6 / 19～21 µs | 5.0～5.7 / 5.1～6.0 µs |
| 两跳计数（预编译） | 22～27 µs | 18～21 µs |
| 一跳 + 邻居属性过滤 | 18～21 µs | 15～16 µs |
| 标签扫描 + 属性过滤（2 万个 Person，每次查询） | 64～80 ms | 14～19 ms |
| 按属性分组计数（每次查询） | 67～77 ms | 55～59 ms |
| 邻居按向量排序 | 28～30 µs | 23～24 µs |
| `SET` 一个属性 / `CREATE` 一条关系 | 44～50 / 84 µs | 37 / 66～70 µs |
| 空事务（`bitcask_txn`） | 6.6 µs | 2.2 µs |

KV 模式小图（3000 顶点，预编译）：`CREATE` 46 → 33 µs、`SET` 26 → 20、`CREATE` 关系 56 → 40、`DETACH DELETE` 67 → 62。

没做 / 剩下的：
- 聚合类扫描剩下的是执行器每行约 1.4 µs 的 Erlang 开销（流水线、缓存查找、求值），要压就得改执行器结构。
- 每把锁仍是一次锁服务往返（约 5 µs，含分片处理释放）；绕开分片进程的 ETS 快路径要和死锁检测、公平排队、前缀锁一起重新论证，没做。
- `DETACH DELETE`（约 300 µs，索引模式）没动。
- 验证：eunit 534/534，`rebar3 as prod compile`、xref、dialyzer 干净。

---

## Q2 — 图查询语言（Cypher 子集）与统一数据模型（13.1.0）

> 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md)（第 14 节按建议定稿；id 统一由图层分配，从 1 起，指定 id 写入推高水位）。
> 落地记录在设计稿第 15 节。

| 步骤 | 内容 | 状态 |
|------|------|------|
| **Q2-1** | 词法 / 语法 / AST / 语义检查（leex / yecc，`bitcask_cypher_lexer.xrl`、`bitcask_cypher_parser.yrl`、`bitcask_cypher_sema`）；`writes/1`；错误带阶段与行列。一期语法 49 条正例、31 条反例逐条核对。 | ✅ |
| **Q2-2** | 统一数据模型（`graphdb_model` + `graphdb` 扩展）：id 分配器与高水位、标签与标签索引、顶点 / 边属性 meta 编码；`create_vertex` / `vertex` / `set_labels` / `remove_labels` / `vertices_by_label`；写路径同批维护索引、推高水位；`check_invariants` 查索引一致与水位。`graphdb_model_tests` 12 条。 | ✅ |
| **Q2-3** | 读查询的计划与执行（`bitcask_plan`、`bitcask_exec`、`bitcask_expr`、入口 `bitcask_cypher`）：取点、展开 / 展开到、变长、最短路、过滤、投影、隐式分组聚合、DISTINCT、排序分页、UNWIND、WITH；`explain` / `prepare`。`bitcask_cypher_tests` 95 条（执行用例对照图层 API 手算）。 | ✅ |
| **Q2-4** | 写子句：`CREATE` / `SET` / `REMOVE` / `DELETE` / `DETACH DELETE`。整条语句在一个 `bitcask_txn` 事务里（读带锁和守卫、提交一条原子批、冲突整条重跑）；`q` 收调用方的事务（出错整个事务中止）；`q/4` 传事务选项；4096 顶点上限；新增 `bitcask_txn:read_doc_guarded/3`、`graphdb_model:txn_allocate/2` / `txn_update_vertex/3` / `txn_bump_watermark/2`。顺带修：事务里推高水位改在事务内（原先 `CREATE (a)-[:T]->(b)` 会重跑到 `retry_limit`）；索引模式下关系类型注册表读不出（`invalid_etype_record`，原有缺陷）。 | ✅ |
| **Q2-5** | `@@`（只支持 `n.text`；最小查询写法：并列 / `OR` / `-` / 短语 / 前缀 / 模糊；`score()`）、`<=>`（= 引擎相似度分数的相反数）；起点 `fts_seek` / `vector_topk` / `vector_range`，第一个标签下推为 meta 过滤，top-k 不够时扩大检索并标 `vector_exhaustive`；图模式候选用 `vector_rank` 精确排序。 | ✅ |
| **Q2-6** | 使用说明 `doc/cypher-zh.md` / `doc/cypher-en.md`；`examples/cypher_demo.escript`；基准 `test/cypher_bench`；README（中英）索引。 | ✅ |

后续可做：属性条件下推到引擎的 meta 过滤（7.3，未做；按属性过滤的扫描约 4 µs/顶点）；小的 doc map 原子批就地跑（`create_vertex` 里大半是转 dirty 调度器）；`@@` 对命名字段（第 9.2 节「声明过全文的属性」）；`OPTIONAL MATCH` / `MERGE` 等二期语法。

⚠️ 上游阻塞：libbitcask ≤ 12.1.0 原子批删除的批头区间多算 4 字节（已反馈 `feedbacks/2026-11-23-atomic-batch-remove-span-overcounts-tombstone-shadow.md`）——索引模式的图在删除后重开会 `bad_crc`（12.1.0）或丢数据（≤ 12.0.3）。`test/cypher_bench` 因此把写放在重开之后。

注意（对图层 API 调用方可见的变化）：`put_vertex` 由一次 `put` 变成「读旧版本与标签 → 带条件的原子批」（约 1.9 → 3.5 µs），与并发写同一顶点按版本串行；`put_edge` / `put_edges` 多一次 id 计数器的点读（计数器建了之后，vid 超过水位时多一条小批）；`put_vertex_txn` / `del_vertex_txn` 会同事务删除旧标签的索引项。

---

