# 更新日志（中文）

English version: [`CHANGELOG_EN.md`](CHANGELOG_EN.md)。
格式大致遵循 [Keep a Changelog](https://keepachangelog.com/)。

## [13.1.1] — 2026-11-24

升级 libbitcask **13.1.0 → 13.1.1**（上游 PATCH：S77、S78）。submodule 从 `02aa247` 切到 `8511c09`（tag `v13.1.1`）。上游库源码与
13.1.0 逐字节相同（`src` / `include` / `c_api` / `tools` / `cmake` 无差异），C API、C++ ABI（`SOVERSION` 13）、盘上格式与本库既有 API
均不变，NIF 不用改，重编即得；升级只为跟上上游 tag。本版同时修复 13.1.0 这个 tag 在下游 `git_subdir` 依赖下构建失败的问题
（见 Fixed）。本库 `bitcask` 与 `bitcask_cypher` 的 `vsn` 一起升到 13.1.1；`bitcask_cypher` 本身没有变化。

### Fixed

- **下游按 `git_subdir` 依赖时子模块初始化失败**（13.1.0 引入）：`apps/bitcask/third_party` 提交成了指向根目录 `third_party/` 的符号链接，
  而 hook 按 `apps/bitcask/third_party/libbitcask` 初始化子模块（git：pathspec 不匹配）；而且 rebar3 拉 git_subdir 依赖是只含 `apps/bitcask`
  的 sparse checkout，根目录的 `third_party/` 根本没检出、符号链接悬空。hook 现在按 `third_party/<子模块>` 的物理位置（`pwd -P`）算子模块
  路径，悬空时先把 `/third_party/` 加进 sparse 范围再初始化；符号链接与「子模块真的挪进 `apps/bitcask`」两种布局都能用。用临时仓库按
  litegate 的依赖写法从零构建验证过（拉子模块、编 NIF、编应用）。**按 `git_subdir` 依赖的下游请用 13.1.1 及之后**。

### Changed

- **（随 libbitcask 13.1.1）两个时序敏感的上游用例满载时假红**（S77，上游反馈
  `feedbacks/2026-11-23-two-timing-sensitive-tests-fail-under-full-load.md`）：
  `AtomicBatchVisibilityTest.HeadThenTailNeverShowsHalfBatch`、`OkiCompactionModelTest.ConcurrentLoaderNeverFallsBackToUnloaded`
  照核数并行（`-j 14`）时偶发失败，是用例对调度时序的假设偏紧，不是库的行为问题；读写交叠改由同步点与条件循环保证。
  只影响上游自己的测试——本库的 CMake 以 `BUILD_TESTING=OFF` 配置，不编也不跑上游测试。
- （随 libbitcask 13.1.1）上游 `check` 目标照核数并行：去掉 13.0.0 为绕开上面两个用例加的封顶 8。
- （随 libbitcask 13.1.1）**上游 README 拆分**（S78）：功能表、构建、文本编码、架构总览移到子模块的 `doc/` 下（`doc/features-zh.md`、
  `doc/build-zh.md` 等），README 只留概览与快速开始。查子模块里的文档时按新位置找。
- 上游的 range 免分配批视图（S75-3）**没有发**：实测收益 4%～12%，没到门槛，而且会改 `CaskRangeIter` 的对象布局；已从上游 main
  移回分支 `s75-3-range-batch-view`，留到下次 MAJOR。13.1.0 与 13.1.1 都不含它，C API 导出表没变。

## [13.1.0] — 2026-11-24

### Added

- **图查询语法参考**：`apps/bitcask_cypher/doc/cypher-syntax-zh.md` / `cypher-syntax-en.md`（openCypher 2024.3 语法与 bitcask 特有的
  图查询语法）；明细见 `apps/bitcask_cypher/CHANGELOG.md`。
- **图层：扩展值编解码挂点** `graphdb_model:register_value_codec/1`：引擎 meta 存不了的值（时间 / 空间值、NaN / Infinity）由上层
  注册编解码模块，核心只存「文本 + `_types` 类型标记」；没注册时这类属性按存储文本读出（数据照样兼容）。同类列表属性（整数 / 浮点 / 布尔）
  仍在核心。
- **属性索引**：`graphdb:create_index/3` / `drop_index/3` / `indexes/1` 声明 (标签, 属性) 索引，建在现有数据上、之后的写入同批维护
  （图层 API 与 Cypher 都算，与建索引并发的写不漏）；Cypher 的标签扫描起点执行时自动改走就绪的索引（等值、`IN`、大小比较），结果不变。
  2 万个顶点、命中 200 个的 `MATCH (n:L) WHERE n.k = 7` 11.6～11.7 ms → 0.46～0.49 ms。
- **关系 id 不复用**：Cypher 删掉的关系，其 id（`[src, etype, dst, rank]`）不会再分给新建的关系——删边时在新键
  `<<1,"_g:">> r <src> <etype> <dst>` 记下 rank 高水位（`graphdb:retire_rank_txn/5`、`rank_floor_txn/4`）。

- `bitcask_txn:transaction/3` 选项 `{read_locks, guard_only}`：带版本守卫的读（`read_guarded/3`、`read_doc_guarded/3`）以 `read` 模式读时
  不拿读锁，由提交时的守卫校验保证可串行化；写、`write` 模式读、不带守卫的 `read/2,3` 照旧加锁（与悲观事务混跑时隔离不变）；只读事务补一条
  只含校验的批。缺省 `locked`（行为不变）。Cypher 写语句缺省用 `guard_only`（`q/4` 的 `TxOpts` 可覆盖）。

- **图查询语言 `bitcask_cypher`（openCypher 子集）**：读——`MATCH`（多个模式、带标签 / 属性的节点、三种方向与多类型的关系、
  变长 `*n..m`、`shortestPath`）、`WHERE`、`WITH`、`UNWIND`、`RETURN`（`DISTINCT`、别名、`*`、聚合、`ORDER BY` / `SKIP` / `LIMIT`）；
  写——`CREATE` / `SET` / `REMOVE` / `DELETE` / `DETACH DELETE`，**一条语句一个事务**（读带锁与版本守卫、提交一条原子批、冲突自动重跑），
  也可以在 `graphdb:transaction/2` 里把事务传进来与图层事务 API 混用；检索——`v.text @@ '…'`（全文，`score(v)`）与
  `v.embedding <=> $q`（向量距离），`ORDER BY … <=> … LIMIT k` 与阈值两种形态走向量索引。`q/2,3,4`、`prepare/2`、`explain/2`、
  `writes/1`；结果 `#{columns, rows, stats}`；错误带阶段与行列。说明：`doc/cypher-zh.md` / `doc/cypher-en.md`；
  示例 `examples/cypher_demo.escript`；基准 `test/cypher_bench`。
- `bitcask_txn:read_doc_guarded/3`：事务里读出完整文档（KV 模式下 `read/3` 只回正文），同时登记版本守卫。
- **图的统一数据模型**（图层 API 与 Cypher 共用）：`graphdb:create_vertex/2,3`（自动分配 id）、`vertex/2`
  （`#{id, labels, properties}`）、`set_labels/3`、`remove_labels/3`、`vertices_by_label/2,3`；`put_vertex` 收
  `#{labels, props, text, vector}`；边属性可以传 map。顶点 id 全库一个空间，自动分配从 1 起，指定 id 的写入推高水位，分配器不会
  发出已被占用的 id；标签存在顶点 meta 的 `_labels`，标签索引与顶点同批维护。

- `bitcask:range_fold/5` 与 `range/3` 的 `{batch, N}` 选项（1..1024，默认 256）：每次 NIF 往返最多取 N 条。只要开头几条就 `throw`
  出来的调用方用小批。

### Changed

- **核心移进 `apps/bitcask`**：仓库改成 rebar3 umbrella（`apps/bitcask` 核心 + `apps/bitcask_cypher` 查询层）。C++ NIF 的构建链与子模块
  随核心一起搬，构建 hooks 在 `apps/bitcask/rebar.config`；CMake 构建目录仍是项目根的 `_build/cmake`。**下游依赖写法要改**：
  `{bitcask, {git_subdir, "https://github.com/DavidAlphaFox/bitcask.git", {tag, "<版本>"}, "apps/bitcask"}}`（rebar3 3.14+）。
- **Cypher 查询层拆为独立应用** `apps/bitcask_cypher/`（同一仓库，rebar3 同时编译两个应用）：模块 `bitcask_exec` / `bitcask_expr` /
  `bitcask_plan` / `bitcask_temporal` / `bitcask_tz` / `bitcask_ieee` 改名为 `bitcask_cypher_*`；配置项 `cypher_import_dir` /
  `cypher_max_write_vertices` / `tz_dir` / `tz_backzone` 改到 `bitcask_cypher` 应用名下；文档、测试、TCK 运行器随之搬走。
  核心不再依赖 Cypher；本仓库 13.1.0 中 `bitcask` 与 `bitcask_cypher` 均发布为 13.1.0。更新日志见 `apps/bitcask_cypher/CHANGELOG.md`。
- **事务**：注册与注销不再与锁服务往返、释放锁只发给要过锁的分片——空事务 6.0～6.2 → 2.2～2.4 µs，`put_edge_txn` 19.7 → 15.9 µs
  （同一轮对比同步注册）。

- **libbitcask 12.1.0 → 13.1.0**（跨上游 12.2.0 / 13.0.0；13.0.0 破坏 C++ ABI，本库从源码编，无影响；C API 与盘上格式不变）：
  - ⚠️ `range` / `range_fold` 的一致性变成**快照**：读开始那一刻的版本，迭代期间的写（含删除）不可见（此前被删的跳过、被改的交新值）；
    迭代期间被 merge 合并掉快照版本的 key 交出当前值。全表扫描与 range 都改成按索引里的位置映射读：扫描每行约 950 → 250～440 ns，
    range 重开后每行约 600～830 → 270～410 ns。
  - memdelta 落段挪到后台线程：单条写最大延迟 153 ms → 约 1.5 ms。读写打开的库第一次写到阈值时多起一条线程，`close` 时停。
  - 重开时的恢复重放不再把已进过索引的文档原文填回缓存：重开后高亮更常走冷路径，`cold => load`（缺省）照常出片段。
- `graphdb:put_vertex` 改为「读旧版本 → 带条件的原子批」（同批维护标签索引）：约 1.9 → 3.5 µs；与并发写同一顶点按版本串行。
  `put_edge` / `put_edges` 多一次 id 计数器的点读（约 +0.3 µs）。`put_vertex_txn` / `del_vertex_txn` / `del_vertex` 同时删除
  旧标签的索引项。`check_invariants` 多查标签索引与 id 水位。

- **小 frontier 的图遍历不再起进程并行展开**：BFS / k-hop / 最短路此前 frontier 超过 4 个顶点就切片、起进程并行展开；起进程和把邻居列表
  拷回调用方的开销在 frontier 上百时仍吃掉并行的收益。阈值改为 256。2 万顶点 / 10 万条边的幂律图上：`shortest_path` 278 → 152 µs
  （重开后 328 → 196 µs），两跳 `bfs` 23 → 13 µs，双向两跳 `bfs` 95 → 54 µs，四跳 `bfs` 381 → 341 µs；从 hub 出发触达 1.5 万个
  顶点的三层 BFS 在噪声范围内持平（9.5～10.9 ms）。结果与顺序不变。
- **`graphdb:edges_by_type/3` 带 `limit` 时只读、只解够用的那部分**：此前把每个顶点的出边组整组解完再截取，range 每批固定取 256 条
  记录；现在只解还差的条数，range 按 limit 取小批。同一张图重开后 limit 10 / 100：221 / 225 → 30 / 69 µs。结果是全量结果的前缀，
  与此前相同；limit ≥ 1000 或不带 limit 时没有变化。

### Fixed

- **图层：单字符关系类型名**（`:X`、`:Y`）从第二个起注册拿到错误的 id（0x6E0001xx），并覆盖了别的单字符类型的名字索引——之后
  `etype_id/2` / `etype_name/2` 查不到、Cypher 的 `type(r)` 返回乱码。已有库里受影响的类型需要重新注册。
- **事务：一次加锁同时闭合多个死锁环时只解开一个**：其余环要等 5 s 的兜底计时器（高争用的写语句会整批卡住几秒到几十秒，
  `status()` 里 `lock_wait_timeouts` 增长）。现在逐个解开经过请求者的全部环。见 `doc/txn-layer-design-zh.md` §13.8。

- **图层删边 / 删顶点、Cypher `DELETE` 之后重开丢数据或打不开**（随 libbitcask 13.1.0，上游 S69）：原子批里删除存在的 key 时批头声明的区间多算
  4 字节，恢复时批被判为不完整——12.0.3 及更早截断数据文件（删除与之后的写静默丢失），12.1.0 跳过这些删除、同一文件多于 64 个时打不开
  （`bad_crc`）。12.1.0 写出的这种库，新版本直接能打开、删除生效、文件不改；12.0.3 及更早已经截断掉的数据救不回来。
- **索引模式的图注册不了关系类型**：引擎在索引模式下回 `#{text, meta}`，`graphdb:etype_id/2` / `etype_name/2` / `register_etype/2`
  按 binary 匹配，一律 `{error, invalid_etype_record}`。改为取值的 text 段。
- `graphdb:put_edge_txn` / `put_vertex_txn` 推高 id 水位改在事务内进行：原先在事务外直接写计数器，同一事务若已分配过 id 就会让它对计数器的
  版本守卫失效、反复重跑到 `retry_limit`。

## [12.1.0] — 2026-11-23

升级 libbitcask **12.0.3 → 12.1.0**（上游 S66、S67），新增 `bitcask:vector_rank/3,4`。submodule 从 `d995557` 切到 `1caee1a`
（tag `12.1.0`）。既有 C API、C++ ABI（`SOVERSION` 12）、盘上格式与本库既有 API 均不变。

### Added

- **`bitcask:vector_rank(H, Query, Keys[, K])`**：在给定的一组 key 里按向量相似度精确排序，取前 K（缺省 10）。候选已经由别处给出时
  用它——图上的邻居、全文检索的命中、range 扫出来的一批 key。不经向量索引（结果不受 HNSW 召回影响，也不用等索引 flush），
  分数口径同 `search_vector`，返回 `{ok, [{Key, Ord, Score}]}`。不存在 / 已删 / 没有向量的 key 跳过，重复的只算一次。
  代价与候选数成正比（每个候选一次点读）。`Query` 可以是 `{text, Bin}`（自动 embed）。上游反馈：
  `feedbacks/2026-11-23-filtered-vector-search-incomplete-no-candidate-scoring.md`。

### Fixed

- **（随 libbitcask 12.1.0）数据文件中间的损坏不再让打开库时把文件截断**：索引从 data 重建时碰到一条读不出来的记录，此前一律当作
  「没写完的尾巴」把文件截到那里，后面已经落盘的记录全部被删，`open` 照样成功。现在只有上一个写者没有正常关闭时它正在写的
  文件才会被截断；其余文件一个字节不动，坏区跳过、从后面第一条完好的记录接着读（引擎打一条 warn 日志）。成员不全的原子批
  仍然整批不可见。上游反馈：`feedbacks/2026-11-23-recovery-truncates-synced-data-on-bad-record-header.md`。
- （随 libbitcask 12.1.0）读一条索引里有、盘上已坏的记录，统一报 `{error, bad_crc}`（此前坏在长度字段上时报成 I/O 错误）。

### Changed

- **（随 libbitcask 12.1.0）带 filter 的 `search_vector` 不再悄悄少给**（HNSW 引擎）：过滤很严时图遍历在预算耗尽后带着不足 K 条
  返回。现在退到精确扫描；图不超过 2^20 个节点时，返回不足 K 条就是满足 filter 的文档确实不足 K 篇。更大的图、以及
  IVF-RQ / DiskANN 引擎没有变。⚠️ 过滤全拒 / 极严的查询多一遍对全部节点的过滤求值。
- **（随 libbitcask 12.1.0）行落盘之后的点读提速**（上游 S66）：重开 / checkpoint 之后点读命中一次，上游基准 1 千 / 10 万 /
  40 万个 key 由 3.0 / 3.4 / 3.6 µs 降到 0.37 / 0.70 / 1.0 µs（本库未另测）。上游反馈：
  `feedbacks/2026-11-23-point-get-after-flush-scans-run-block-linearly.md`。
- ⚠️ **行为变化**：正常关闭过的库，数据文件尾部的残缺不再被截掉，而是留在原处、读的时候跳过。

## [12.0.3] — 2026-11-23

升级 libbitcask **12.0.2 → 12.0.3**（上游 S65），并入图层读写路径与 NIF 调度的内部优化。submodule 从 `ab9b51f` 切到 `d995557`
（tag `12.0.3`）。C API、既有 C++ ABI（`SOVERSION` 12）、盘上格式与本库 API 均不变，重编即得。

### Changed

- **（随 libbitcask 12.0.3）点读命中提速**：引擎内存里的点查索引换成平表，活跃文件的命中读走只读映射、不再每次一个系统调用
  （仅 Linux / FreeBSD）。128 字节的值命中一次（经 NIF）：库里 1 千 / 10 万 / 40 万个未落盘 key 由 1.29 / 1.84 / 2.00 µs 降到
  0.26 / 0.62 / 0.73 µs。带动 `graphdb:out_edges` 3.9 → 2.0 µs、`degree` 2.6 → 1.1 µs、`put_edge`（度数 5）12.6 → 7.9 µs，
  基准里逐条 / 批量装载 7.8 万 / 13.0 万 → 13.1 万 / 17.6 万边/秒。上游反馈：
  `feedbacks/2026-11-23-point-get-hit-cost-grows-with-unflushed-rows.md`。
  ⚠️ 活跃文件被点读过的页现在计入进程 RSS（文件页，可回收）；映射读遇到底层 I/O 错误是 SIGBUS 而不是 `{error, _}`——
  两点都与已封口文件既有的映射读相同。

- **邻接读直接在头 / 块的二进制上解**：只解要的方向和类型，别的组按字节数跳过，一遍出结果。`neighbors` 直接出对端 id，结果只来自
  一个组时不再逐个去重，`both` 只读一次头：20 万度 hub 的 `neighbors` 102 ms → 9.0 ms，低度数 `neighbors(both)` 7.5 → 4.2 µs；
  hub 全量 `out_edges` 57 → 43 ms。`degree` 只读各组的头、`edge` 在条目区 / 块目录上二分：20 万度 hub 上 18 → 4.8 µs、32 → 8.5 µs。
- **hub 的块目录不再每次解成列表**：定位块用二分，写回时目录没变原样复用，收尾只处理改过的块。20 万度 hub 上
  `put_edge` 255 → 64 µs、`del_edge` 240 → 52 µs。
- **批量加边在同一张条目表上接着上次的位置找**（批内已按 dst 排序，插入是升序的），查原值与写入合成一次定位：
  dst 乱序的 20 万度 hub 装载 3.5 s → 0.95 s；5 万条边指向同一顶点的装载 11.4 → 5.9 µs/边。
- `neighbors/3` 对同一对端的去重结果与顺序不变；BFS / 最短路的展开不再把同一组里同一对端的多条 rank 重复交给 visited 表，结果不变。
- **单条加 / 删边直接在条目区的二进制上改**：定宽（无属性）的条目表读进来不解码，二分定位后拼接，写回原样落盘——以前改一条边
  要把所在的块（约 500 条）整个解成列表再编回去。20 万度 hub 上 `put_edge` 56 → 29 µs、往 hub 的入边一侧加边 68 → 38 µs、
  `del_edge` 40 → 33 µs；度数 50 的顶点之间 `put_edge` 29.6 → 20.5 µs。度数 5 的图上没有变化。落盘字节与此前相同。
- `graphdb_analytics:materialize` 只解出边组、直接出对端 id：2 万顶点 / 20 万条边 214 → 168 ms。
- **小的原子批直接在普通调度器上跑**（`put_batch_atomic/2,3`）：op 不超过 16 条、value 合计不超过 64 KiB、没有 doc map、句柄没有
  sync 策略、且本句柄已经提交过原子批时，不再转 dirty IO 调度器；其余照旧。2 条小写入的批 4.8 → 3.1 µs，只含 `check` 的批
  2.4 → 0.7 µs；`graphdb:put_edge` 度数 5 的顶点之间 17.3 → 12.6 µs，逐条装载 61k → 78k 边/秒。语义不变。

## [12.0.2] — 2026-11-23

升级 libbitcask **12.0.1 → 12.0.2**（上游 S64），并修正图层 hub 路径的性能。submodule 从 `c364cd3` 切到 `ab9b51f`
（tag `12.0.2`）。C API、既有 C++ ABI（`SOVERSION` 12）、盘上格式与本库 API 均不变，重编即得。

### Fixed

- **（随 libbitcask 12.0.2）每次写之后的第一次 `range` / `range_fold` / 迭代不再整份重排未落盘的行**：此前引擎的排序视图缓存
  被任何一次写整体作废，下一次开迭代器把全部未落盘行拷一遍再排一遍，耗时随未落盘行数线性涨，拷贝期间点查与写也被挡住。
  现缓存增量维护。实测「写 1 条无关 key + 扫 1 行」：1 万 / 10 万 / 40 万未落盘行由 1.4 / 14.9 / 80.1 ms 降到 10 / 9 / 13 µs。
  受益的有 `bitcask:range*`、`bitcask_query` 的范围查询、`bitcask_txn:prefix_range`、图层的全库扫描（`materialize` /
  `edges_by_type` / `check_invariants`）。上游反馈：`feedbacks/2026-11-23-range-iter-after-write-resorts-memdelta.md`。

### Changed

- **`graphdb:del_vertex` 删 hub 顶点由 O(度数²) 降到线性**：每轮只读够一批邻居的那几个块，不再每轮把全部块读一遍。
  20 万邻居 450 s → 2.1 s；2 万邻居 1.11 s → 0.12 s。
- **分块顶点的邻接读按块目录逐块点读**，不再走前缀 range（`out_edges` / `in_edges` / `neighbors` / 遍历；事务读同一条路）。
  `limit` 只读用到的块：20 万度 hub 上 `#{limit => 10}` 1133 µs → 30 µs（range 一次往返按批搬块，limit 10 也要搬一批）。
  非 `consistent` 读仍是弱一致：读头之后被并发删掉 / 分裂的块按读到的样子返回；要原子快照用 `#{consistent => true}`。
- **`put_edges` / `del_edges` 默认按 (src, etype, dst, rank) 稳定排序**（原为只按 src）：同一个 src 的一批边落在相邻的块里。
  dst 乱序的 20 万度 hub 装载 15.3 s → 3.5 s。同一条边多次 upsert 仍是最后一次生效；`sort => false` 照旧保持输入顺序。
- **hub 上的点操作不再为全部块 key 建表**：20 万度 hub 的 `degree` 345 µs → 18 µs、`edge` 939 µs → 32 µs、
  `put_edge` 752 µs → 255 µs。
- 事务里读分块 hub 的全部出边 646 ms → 55 ms（去掉逐块 `++` 的重复拷贝）。

## [12.0.1] — 2026-11-20

升级 libbitcask **12.0.0 → 12.0.1**（上游 S63）。submodule 从 `62dd725` 切到 `c364cd3`
（tag `12.0.1`）。C API、既有 C++ ABI（`SOVERSION` 12）与盘上格式均不变，重编即得。

### Fixed

- **（随 libbitcask 12.0.1）原子批对并发读者整批可见**：12.0.0 及更早逐 key、按 key 字节序
  生效（同一顶点头先于块），读者可能读到「新头 + 旧块 / 缺块」。图层写会话此前只对改过的头
  设条件，基于半个批算出的写回会覆盖别人刚写的块；读到「目录有、盘上缺」的块时，自愈还会把
  刚建好的块写成空。上游现把整批先裁决、再在一个索引临界区发布，读者要么看到整批、要么一行
  都看不到；这是原子可见，不是快照隔离。上游反馈：`feedbacks/2026-11-20-atomic-batch-no-read-isolation.md`。
- **图层写会话显式校验整个读集**：前置条件除改过的头外，还覆盖读过的每个块（没改的发 `check`、
  缺失的用 `absent`）以及读过没改的顶点——即使有人绕过图层协议直写块，读-改-写也不会静默覆盖。
- **`out_edges` / `in_edges` 的 `#{consistent => true}` 在写锁下确认读集版本**：头与块逐个带版本
  点读后，用只含 `check` 的原子批校验仍是当前版本，不过则重读。代价：分块顶点的一致性读多一次
  拿写锁（不写盘）。

## [12.0.0] — 2026-11-20

升级 libbitcask **11.0.0 → 12.0.0**（跨上游 11.1.0 / 11.1.1 / 11.2.0 / 12.0.0）。submodule 从 `862d735` 切到 `62dd725`（`12.0.0`）。
⚠️ 上游 12.0.0 是 C++ ABI 破坏（`meta::MetaValue` 变体追加 `StringArray`，`SOVERSION` 11→12），NIF 已随之修改，须重编。
⚠️ 目录里一旦写入含字符串数组的 meta，`bitcask.meta` 懒升 v7，此后 libbitcask ≤ 11.2（本库 ≤ 11.x）打不开该目录（干净报错）；
不写数组的目录停在 v5 / v6，与旧版本互通不受影响。

### Added

- **meta 字符串数组**（随 libbitcask 12.0.0）：`encode_meta/1` 收 `[binary()]`（`[]` 为空数组，元素须全为 binary，
  charlist 报 `badarg`），`decode_meta/1` 解回 `[binary()]`（保持写入顺序）。
- **filter 新操作符 `contains` / `contains_any`**：`#{key => K, op => contains, value => Bin}`、
  `#{key => K, op => contains_any, values => [Bin, ...]}`。数组任一元素命中即过；存储值是单个 binary 时当作单元素集合。
  检索、向量检索、`range` 的 filter 都能用。既有 `eq` / `in` / 大小比较碰到数组为假、`neq` 为真（类型不匹配）。
- **`bitcask_query` where 新增 `{F, contains, Bin}` / `{F, contains_any, [Bin, ...]}`**，下推与 BEAM 侧求值同义；
  这两种条件不走二级索引。二级索引字段上存数组时整个数组为 `exists` 进索引。
- **`update_doc/3` 文档部分更新**（随 libbitcask 11.2.0）：`#{fields => #{F => Text | delete}, meta => #{K => V | delete}}`，
  只改给出的字段与 meta 键，正文、向量、过期时刻保留；引擎内原子读-改-写，返回 `{ok, Lsn}`；
  `{error, not_found}` / `{error, conflict}`（16 次重试仍冲突）。⚠️ 不省盘，新版本仍整条写、整篇重建索引。
- **`search_text_highlight/2..4` 带高亮的全文检索**（上游 S13-D3 / S53）：`{ok, [{Key, Ord, Score, [Snippet]}]}`；
  `HlOpts` 另收 `cold => load | skip`，缺省 `load`——重开后的大库里命中不在原文缓存时从存储读回正文补片段（上游缺省是 skip）。
- **`search_fields_highlight/2..5` 逐字段片段**（随 libbitcask 11.2.0）：`search_fields_attributed` 的结果再附
  `[{Field, [Snippet]}]`，每个字段只用属于它的查询词切，原文从存储读回（冷热一样）；`HlOpts` 可设标签、片段长度与段数。

### Fixed

- **带 `{analyzer, jieba}` 的 `merge/2,3` 让节点整个退出**：merge 的临时 merge_only 打开漏了 `open/2` 的缺省词典目录
  （`priv/dict`），`dict_path` 为空 ⇒ libbitcask ≤ 11.0.0 里 cppjieba abort。现 `open/2` 与 `merge/2,3` 共用同一段选项归一。
- **`dict_path` 给成字符串被静默忽略**：现在字符串按 UTF-8 转 binary；别的类型返回 `{error, {invalid_option, Msg}}`。
- （随 libbitcask 11.1.0）jieba 词典目录不对时 `open` / `merge` 返回 `{error, {invalid_option, Msg}}`（报文带缺失的文件），
  不再 abort；`needs_merge` 能看见本次打开之后产生的死数据。
- （随 libbitcask 11.1.1）**检索库经 `merge/2,3`（merge_only 旁车）的整次合并永久挂住**：11.1.0 起 `needs_merge` 不再漏报，
  `merge/2` 对检索库会真的进入合并并挂在收尾的读屏障上。现旁车按纯 KV 合并，不再改写写者的检索 checkpoint，写者下次打开归正。
- （随 libbitcask 11.1.1）跨进程旁车合并删掉输入文件后，开着的写者读被搬走的 key 报 I/O 错、迭代报 `fold location disappeared`；
  现写者第一次碰到时从 data 重建一次再重试（代价：每次跨进程合并后一次整库重建）。同节点旁车（`bitcask_merge_worker`）本不受影响。

## [11.0.0] — 2026-11-20

升级 libbitcask **10.0.0 → 11.0.0**（上游 S56；C++ ABI 破坏：`FieldSegmentView`
追加 `live`、`SealedSegment` 追加字段级打分状态，`SOVERSION` 10→11；C API 与
盘上格式零改动，既有数据直接可用）。submodule 从 `46da576`（`10.0.0`）切到上游
`862d735`（`11.0.0`）。NIF / Erlang 门面零改动，重编即得。⚠️ `search_fields`
的分数与排序是行为变化，无旧口径开关。

### Fixed（随 libbitcask 11.0.0）

- **`search_fields` 分数与 `search_text` 对不上、重开前后排序变化**：逐段本地
  N / df / sum_dl 改为每字段跨段聚合，刚写入与落盘后、字段查询与全文查询的
  分数一致。
- **命名字段打分的文档长度误用整篇总词数**：BM25 的 `dl` 改取该字段自身词数；
  `index_catch_all = false` 的默认字段长度口径一并归正。短字段不再因整篇长度
  被误罚。

## [10.0.0] — 2026-11-19

升级 libbitcask **9.0.0 → 10.0.0**（跨上游 9.1.0 / 10.0.0；C++ ABI 破坏：
`MetaConfig` / `MetaError` / `SearchLayerConfig` 追加成员，`SOVERSION` 9→10；
C API 纯加法、C ABI 兼容；`bitcask.meta` 新增可选 C2 尾段，盘上格式仍 v5/v6，
既有数据直接可用）。submodule 从 `d164744`（`9.0.0`）切到上游 `46da576`
（`10.0.0`）。NIF / Erlang 门面零改动，重编即得。

### Fixed（随 libbitcask 10.0.0）

- **ngram 分词的库高亮片段恒空**：`analyze_with_offsets` 返回真实字节偏移，
  缺省 ngram 库的热 / 冷路径不再静默返回空片段。
- **高亮器漏标多词与重叠 token**：片段内先按位置排序、合并重叠 / 相接区间
  再插标签；「quick … fox」两词都标，ngram「着色器」标成一整段。
- **打开旧版封段的检索库时新段写进进程当前目录**（9.1.0）：fallback 重建固定
  落在库目录的段集，不再污染进程 CWD；旧段与旁车排进延迟删除。

### Added（随 libbitcask 10.0.0）

- **`bitcask.meta` 记录分析器配置本身**（C2）：可写建库 / 升级时记录，旧库
  指纹相符时补记；`dict_path` 不记。上游 C / C++ 可按记录的分析器打开只读
  查看工具；本仓库既有 `{analyzer, ...}` 显式配置语义不变。
- **冷文档也给高亮片段**（9.1.0，上游 C API `BITCASK_HIGHLIGHT_LOAD_COLD`）；
  本仓库门面尚未开放该开关。

## [9.0.0] — 2026-11-19

升级 libbitcask **8.1.0 → 9.0.0**（上游 C++ ABI 破坏：`bm25::DocTable` 新增
`fill_eval_meta()` 虚函数，`SOVERSION` 8→9；C API 签名、C ABI、盘上格式零改动，
8.1.0 数据直接可用）。submodule 从 `13322bd`（`8.1.0`）切到上游 `d164744`
（`9.0.0`）。NIF / Erlang 门面零改动，重编即得。

### Fixed（随 libbitcask 9.0.0）

- **merge 后向量检索静默返回错结果**：HNSW `clone_live` 原来只做死邻过滤；
  死比一高，0 层出度塌缩甚至图被撕裂。现在按死比分两路——低死比做全面路径
  收缩，高死比做全量重连；收尾检查并修复 0 层强连通性。
- **向量检索带过滤时少返回**：live / meta filter 从结果侧过滤改为遍历期过滤，
  被拒节点仍参与导航、不进结果集，凑满 ef 个通过者才收敛；HNSW 与 DiskANN
  同语义，极低通过率有距离计算预算，避免扫全图。

### Changed（随 libbitcask 9.0.0）

- 带过滤的向量检索耗时约随通过率倒数增长；高死比 merge 的向量重建由毫秒级
  变为按活节点重建邻接，这是召回与正确性修复的代价。

## [8.1.0] — 2026-11-19

升级 libbitcask **8.0.0 → 8.1.0**（跨上游 8.0.1 / 8.0.2 / 8.1.0；C API 签名、C ABI、
盘上容器格式零改动，`SOVERSION` 保持 8）。submodule 从 `eade59e`（`8.0.0`）切到上游
`13322bd`（`8.1.0`）。NIF / Erlang 门面零改动，重编即得。

> ⚠️ **search 升级须知**：上游把默认字段哨兵改为 `<<1, "_bitcask:default">>`。由
> 8.0.x（或更早）写出的 search checkpoint / 已封存索引在 8.1.0 下不能无损沿用；
> 需重建 search 索引，或临时用旧版本读取。KV-only 数据不受影响。

### Changed（随 libbitcask 8.1.0）

- **默认字段哨兵改为 `<<1, "_bitcask:default">>`**：不可见首字节避免用户字段冲突，
  后缀可读。KV-only 与 C API 零改动；旧 search 数据中的默认字段持久化标识不自动迁移。
- Windows / MSVC 修复（随 8.0.1 / 8.0.2）：TBB finalize 使用 nothrow 双参重载；
  MSVC 显式启用 `/EHsc`，保证异常跨守卫时 RAII 正确展开。

### Fixed — 图层

- 分块邻接组读到「头目录里有、盘上没有」的块时，现在会把真空块修复随同一头
  条件批提交；`del_vertex` 的只读首扫触发的这类修复不再被跳过。该修复由随机
  并发不变式测试暴露。

## [8.0.0] — 2026-11-18

升级 libbitcask **7.0.3 → 8.0.0**（上游 MAJOR，S46 原子批条件写：C API 纯加法，C++
头面追加成员与带缺省值的形参——源码兼容、C++ ABI 变化，`SOVERSION` 7→8；盘上格式
零改动）。子模块从 `ce7ce13`（`7.0.3`）切到上游 `eade59e`（`8.0.0`）。借这项引擎能力
把图层换成 **布局第 1 版**（盘上破坏性变更，旧图库直接拒开，见下）。

> ⚠️ **升级须知**：用 6.5.0–7.0.3 的 `graphdb` 写过的目录，本版 `graphdb:open/2` 返回
> `{error, graph_layout_v1}`；若只有中间版写入的无前缀 `g` 配置，则返回
> `{error, graph_layout_unprefixed_v2}`。不用图层的 KV / 检索目录不受影响。

### Added（随 libbitcask 8.0.0）

- **原子批前置条件（乐观并发）**：`put_batch_atomic` / `txn_commit` 的 op 可带
  `Cond :: absent | {ord, N}`——`{put, K, V, Cond}`（V 可为 doc map）、
  `{remove, K, Cond}`、`{check, K, Cond}`（只校验不写）。条件在引擎写锁内、落盘前
  对照批前状态判断，任一不成立 → `{error, {conflict, OpIndex}}`（从 1 起），整批零
  副作用。形态不认一律 `badarg`。
- **`bitcask:get_with_ord/2`**：`{ok, Value, Ord}`，Ord 是 key 当前记录的 LSN（只在
  写入时改变，merge / 重开 / 索引重建都保留），作 `{ord, Ord}` 条件用。
- **`bitcask:put_batch_atomic/3`**：`[return_ords]` 时成功返回 `{ok, [Ord]}`（各 op
  落盘记录的 LSN，check 为 0）。
- **`bitcask_txn:read_guarded/3`**：读的同时登记版本，提交时写过的 key 把条件挂在
  op 上、只读过的 key 变成 check；直通写者插进来 → 事务冲突、按死锁同一路径重跑。
  经它读的 key 可以与直通写混用而不丢更新。
- NIF：`cask_get_ord/2`、`cask_put_batch_atomic/3`；`CaskError::kConditionFailed`
  无 op 下标时兜底为 `{error, condition_failed}`。

### Changed — 图层布局第 1 版（`doc/graph-adjacency-pack-design-zh.md`）

- **一个顶点两个 KV**：图层 key 统一使用 `<<1,"_g:">>` 全局前缀。`n<vid>`（顶点，
  不变）+ `a<vid>`（邻接表头：出 / 入边组、组内度数）。邻接表超过 `adj_inline_max`
  （默认 4 KiB）的 hub 把最大的组拆成块（`a<vid><dir><etype><o><r>`，单块 ≤
  `adj_chunk_max`）；超过 `props_inline_max`（默认 128 B）的边属性落 `p` 家族。
  `e` / `ei` / `et` / `deg` / `degi` 全部退役。
  key 数从「3 × 边数 + 计数键」降到「2 × 顶点数 + 块数」——基准里低度数图降 17×、
  平均度数 50 降 145×。
- **写边 = 两端头的条件写 + 冲突重试**（默认 8 次、指数抖动，`retries => N | infinity`
  可调，耗尽 `{error, conflict}`）：并发直通写不丢边、度数精确、两端对称，**不再有
  「单写者」约定**。代价是写放大：平均度数 50 时每边日志字节约 3×、单边写吞吐约
  0.36×（低度数时与 v1 同档）。
- **读**：取邻居 / 度数一次点查（一跳快 2–10×）；`out_edges` / `in_edges` 新增
  `consistent => true`（分块顶点读前读后比对头 LSN）。`edges_by_type` 改为扫 `a`
  家族（O(V + E)），并带上属性。`graphdb_analytics:materialize` 改读 `a` 家族。
- **事务式 API**：锁粒度改为顶点的邻接表头（不再用前缀锁），头经 `read_guarded`
  读——**直通写与事务写可以混用**。
- **布局版本**：`graphdb:open/2` 建库写 `g` 键（布局 1 + 分块参数，之后以它为准）；
  旧图库分别返回 `{error, graph_layout_v1}` / `{error, graph_layout_unprefixed_v2}`。

### Added — 图层

- `graphdb:put_edges/2,3`、`del_edges/2,3`（先按 src 稳定排序、再按顶点聚合切批，每批
  ≤ `batch_vids`（默认 256）个顶点、独立原子；`sort => false` 保持输入顺序。度数 50 的图
  批量装载 88.6k 边/秒，为 v1 的 1.05×；整图一批时 253k 边/秒）、
  `in_degree/2,3`、`del_vertex/3`（`retries`、`batch_neighbors => N | infinity`）、`akey/1`、`pkey/4`、`graph_config/1`、`check_invariants/1`（扫
  `a` / `p` 家族核对对称、度数、块目录、外置属性）。
- `test/graphdb_bench` 改为当前布局口径并带旧逐边布局参照（key 数、字节数）。

### Removed

- `graphdb:ekey/3,4`、`eikey/3,4`（旧 key codec）。旧计数器回退路径、前缀锁版的
  `out_edges_txn` / `del_vertex_txn` 随布局一起退役；不提供自动迁移工具。

## [7.0.3] — 2026-11-17

升级 libbitcask **7.0.2 → 7.0.3**（上游 PATCH：索引管线去全局顺序化，并修复大
`put_batch` 索引池死锁、`close()` 逃生门、checkpoint 覆盖水位高估与旧 OKI
BM25 分数漂移。C API 签名、盘上格式与 ABI 零改动，`SOVERSION` 保持 7；C++
公共头有结构性变化，NIF 必须与库同版重编）。子模块从 `76aa98d`（`7.0.2`）
切到上游 `ce7ce13`（`7.0.3`）。

### Changed（随 libbitcask 7.0.3）

- **索引管线改为 key + LSN 裁决、分片并发应用**：同 key 串行、不同 key 并行；
  reducer / reorder ring / map worker 池退役，恢复重放同样经分片执行器并行。
  搜索读屏障改等 LSN 连续完成前缀，checkpoint 在执行时刻取覆盖水位并独占保存。
- **内置文本、向量插件与恢复契约随上游更新**：旧格式 OKI 的 BM25 分数不再受
  全死段 stale 统计影响；向量插件改用 key + LSN 定位表判重，HNSW 旧检查点可
  继续读取，7.0.3 写出的乱序图可退回全量重建（不损坏数据）。

### Added

- **`bitcask:index_stale_dropped/1`**：透出上游 `StatusInfo` 新增的过期索引任务
  计数。正常并发覆盖写下非零是预期；仅当伴随 `index_errors/1` 增长时才需要
  关注索引应用错误。

## [7.0.2] — 2026-11-16

升级 libbitcask **7.0.1 → 7.0.2**（上游 PATCH：修复 Windows `atomic_rename`
共享冲突；MSVC 大端读取改用标准 `std::byteswap`。C API 签名、盘上格式与 ABI
零改动，`SOVERSION` 保持 7）。子模块从 `c7117df`（`7.0.1`）切到上游 `76aa98d`
（`7.0.2`）。

### Fixed（随 libbitcask 7.0.2）

- **Windows `atomic_rename` 不再被共享冲突打断**：目标文件仍被本库读句柄短暂
  打开或处于 delete-pending 时，`MoveFileExW(REPLACE_EXISTING)` 可能返回
  `ERROR_ACCESS_DENIED` / `ERROR_SHARING_VIOLATION`。现在对这两类瞬时冲突做
  约 0.5 s 上限的有界退避重试；其他错误仍立即失败。Linux / macOS 的
  `rename(2)` 语义不变。NIF / Erlang 门面零改动，重编即得。

## [7.0.1] — 2026-11-16

升级 libbitcask **7.0.0 → 7.0.1**（上游 PATCH：迭代器用过之后再写入时，
`flush_index` 不再永久阻塞；C API 签名、盘上格式与 ABI 零改动，`SOVERSION`
保持 7）。子模块从 `677cfca`（`7.0.0`）切到上游 `c7117df`（`7.0.1`）。

### Fixed（随 libbitcask 7.0.1）

- **迭代后写入不再卡住 `flush_index`**：开迭代器不再制造缺失的写序号空洞；
  其后首次写入不会把提交水位推过永远补不上的空洞，`flush_index` 可正常返回。
  已被卡住的库无需修复，重开即恢复。NIF / Erlang 门面零改动，重编即得。

## [7.0.0] — 2026-11-16

升级 libbitcask **6.9.1 → 7.0.0**（C++ ABI 破坏，`SOVERSION` 6→7；C API 既有签名
零增删改，盘上格式零改动）。本地嵌入后端同步升级 llama.cpp `b11434` → `v1.0.0`
（ggml `0.26` → `1.0.0`）。

### Changed（随 libbitcask 7.0.0）

- **OKI 分级后台归并与不可变读视图**：提交点只调度归并，支持两条归并道、
  背压与 close 宽限取消；run 集合与冻结内存段整体不可变发布。run bloom 从
  10 bits/7 哈希提高到 16 bits/11 哈希，`StatusInfo` 新增归并诊断字段。
- **NIF / Erlang 门面零改动**：核心 NIF 静态链接源码构建，不直接使用上述内部
  C++ 接口；重编即可获得新行为。

### Changed（随 llama.cpp v1.0.0）

- **本地嵌入后端升级**（opt-in）：`cpp/llama/nif_llama.cpp` 使用的公开嵌入、
  分词、backend 设备与日志接口仍然可用；NIF 源码零改动，构建配置选项不变。

## [6.9.1] — 2026-11-16

升级 libbitcask **6.9.0 → 6.9.1**（上游 PATCH：公共 C++ / C API、盘上格式与
ABI 零改动，`SOVERSION` 保持 6）。上游正式收录 6.9.0 后本仓库的
`merge_only` readiness 修复（`8de3319`），子模块从本地跟进提交 `50417f4`
切回上游 `66609a7`。

### Fixed（随 libbitcask 6.9.1）

- **`merge_only` 旁车 readiness 重建进入上游正式版**：`merge_only` 仍可在
  OKI 尚未 write-probe ready 时走 `IndexAuthority::rebuild_memory_from_data()`
  轻量重建；`bitcask:merge/N` 行为与 6.9.0 本地跟进版一致，NIF / Erlang
  代码零改动。

## [6.9.0] — 2026-11-15

升级 libbitcask **6.8.1 → 6.9.0**（上游 MINOR：公共 C++ / C API 既有签名与 ABI
零破坏，`SOVERSION` 保持 6；新错误码追加在枚举尾部）。OKI 成为查找 / 提交权威，
新库退役内存 KeyDir 与 `.hint` 写路径，健康 Level B v4 目录走 data-only recovery。
本仓库适配 `IndexRegistry`，并把上游新增的索引损坏硬错误透传为
**`{error, index_corrupt}`**。

### Added

- **`index_corrupt` 错误原子**：OKI 定位成功但读回 record 的 key / ord 不一致时，
  引擎显式拒绝；不再折叠成 `not_found`，也绝不返回别的 key 的 value。

### Changed（随 libbitcask 6.9.0）

- **OKI-only 权威与 data-only recovery**：`get` / 写路径 / range / merge relocation
  都走 `OkiState` / `IndexAuthority`；NIF 侧共享目录注册表由
  `KeyDirRegistry` 换成 `IndexRegistry`，多 Cask 同目录共享语义不变。
- **派生辅助布局收紧**：新库停写 `.hint` 与 `kv.keydir.ckpt`，BCOK v3 带 sparse
  block CRC、BCOM v4 保存提交点元数据；上游验证旧库可打开迁移，回退依赖 data
  唯一真相。既有 `keydir_cache_entries` 字段保留，继续充当恢复档位。

### Fixed

- **`merge_only` 旁车可完成首次 OKI readiness 重建**：上游 6.9.0 在
  `ensure_oki_for_write()` 中无条件拒绝 `merge_only`，导致 `bitcask:merge/N`
  打开旁车时误报 `{error, index_corrupt}`。本仓库子模块跟进 `50417f4`，对
  `merge_only` 放行 readiness 检查并走内存恢复档重建。

## [6.8.1] — 2026-11-14

升级 libbitcask **6.8.0 → 6.8.1**（上游 PATCH：纯内部内存结构变更）。全局 DocMap 改为
live-only store，热点覆盖写的内存随 live docs 而不是历史写入增长。C API / 公共头签名、
checkpoint sidecar 格式与盘上格式零改动；NIF / Erlang 代码零改动，重编即得。

### Changed（随 libbitcask 6.8.1）

- **DocMap live-only store**：覆盖写与删除在写路径同步淘汰旧 `ord` 的 live row、meta
  与 delta journal，不再等待 `compact_chunks()`。上游热点基准实测：1M 次覆盖写、
  1 个 live doc 的 RSS 净增 **0.0625 MiB**；低 churn live set 约
  **169.5–172.5 bytes/live doc**。BM25 主评分路径仍走段内 dense DocId，检索行为不变。

## [6.8.0] — 2026-11-14

升级 libbitcask **6.7.1 → 6.8.0**（上游 MINOR：纯增量）。C API 新增 `get_doc` 与
字段归属版 `search_fields`；既有 `get` / `search_fields` 布局与语义零改动，
`SOVERSION` 保持 6，盘上格式不变。本仓库把两个新能力开到 Erlang 门面：

### Added

- **`bitcask:get_doc/2`**：显式读取结构化文档并取回命名字段，返回
  `#{text, meta, vector, fields}`；`fields` 是 `#{binary() => binary()}`，
  `meta` / `vector` 缺省为 `undefined`。`get/2` 仍走原热路径，不解码 fields。
- **`bitcask:search_fields_attributed/2,3,4`**：`search_fields` 的命中归属版，
  返回 `[{Key, Ord, Score, [Field]}]`；分数与排序同 `search_fields`，默认字段
  记 `<<>>`，末参同样支持 meta filter。
- 新增 `bitcask_libbitcask_680_tests` 覆盖字段读回、命中归属、filter 与
  KV 模式的 `no_index` 语义。

## [6.7.3] — 2026-10-14

升级 libbitcask **6.7.0 → 6.7.1**（上游 PATCH：纯缺陷修复）。C API 零改动，`SOVERSION` 保持 6，
盘上格式不变；对 Erlang 调用方**无 API / 行为变化**，本仓库 Erlang / NIF 代码一行没改，重编即得。

### Fixed（随 libbitcask 6.7.1）

- **Windows 上 merge 之后 `close` 不删退休数据文件，盘上体积不降**（下游锦书经
  Keelson.Bitcask 1.0.6 在 Windows x64 上报回，上游 `feedbacks/2026-10-10-windows-merge-retired-files-not-deleted-on-close.md`）。
  根因：`Cask::close()` 的排水（`drain_retired_files()`）排在释放读句柄缓存之前——要删的
  文件仍被 mmap 映射占用，Windows 上 `DeleteFileW` 对被映射文件必然失败，失败路径把文件
  放回退休队列、析构时被静默丢弃。修复：排水挪到释放读句柄之后；排水后仍滞留队列的路径
  记一条错误日志（数量 + 原因），不再静默丢。Linux/glibc 上 `unlink` 对映射文件本就成功，
  行为不变。上游带回回归测试 `MergeThenCloseAfterSearchRemovesRetiredFiles`。

## [6.7.2] — 2026-10-08

升级 libbitcask **6.6.2 → 6.7.0**。上游这版只动 C API（纯加法），`SOVERSION` 保持 6，盘上格式不变；
NIF 不走 C API，对 Erlang 调用方**无 API / 行为变化**，重编即得；NIF 的 `on_unload` 接上了上游新增的拆线程步骤。

### Changed（随 libbitcask 6.7.0）

- 上游新增 C API `bitcask_shutdown`（拆除索引池 / Search 池 / TBB worker，供 FFM / P/Invoke / `dlopen`
  宿主卸载动态库）与错误码 `BITCASK_ERR_BUSY = 15`。BEAM 侧不经 C API。
- **NIF `on_unload` 照 `bitcask_shutdown` 的步骤拆线程**：删 PrivData（join 索引池，原本就有）后，再
  `release_search_arena` + `tbb::finalize`（nothrow，失败静默）。不直接调 `bitcask_shutdown`，因为它只看
  C API 自己的 registry。⚠️ 实测效果有限：跑过 TBB 并行段的 dirty 调度线程常驻（如候选 ≥ 2048 的短语检索、
  重开库恢复），`finalize` 返回失败，TBB worker 留着空转在 `libtbb.so` 里；Linux/glibc 上 `bitcask_cpp.so`
  本来就不会被真正卸载（libstdc++ 的 GNU_UNIQUE 符号让 glibc 把它标成 NODELETE）。新增
  `bitcask_nif_unload_tests`：peer 节点里 purge → 重载，验证索引池线程退出、重载后照常可用。
- 上游修复：`put_doc_common` 等 4 个 C API 内部助手不再以裸名导出到 `libbitcask.so` 动态符号表。
  本仓库静态链接核心库，不受影响。

## [6.7.1] — 2026-10-06

新增结构化查询 DSL（含分页、向量 / 混合检索、二级索引），升级 libbitcask **6.6.0 → 6.6.2**（C API / ABI 纯加法，`SOVERSION` 不变，盘上格式不变），另外本地嵌入后端的 llama.cpp 升到 `b11434`。
libbitcask 6.6.1 修的是我们报上去的 `feedbacks/2026-10-06-meta-filter-query-gaps.md` 五条；6.6.2 收下 `feedbacks/2026-10-06-atomic-batch-doc-meta.md`，原子批可以写带 meta 的文档。

### Fixed（随 libbitcask 6.6.1）

- **带 meta filter 的检索不再静默少返回**。旧行为是只多取一次 `max(K×4,64)` 个候选再后过滤：
  1000 篇里满足条件的有 100 篇，`search_text/4` 取 K=10 只返回 6 条。现在引擎会补取到 `K` 条，
  返回少于 `K` 条就说明满足条件的只有这么多。
- **同分命中排序稳定**。旧行为是 top-K 按 key 升序选、按 ord 降序输出，导致 K=5 和 K=1000 的
  结果互相矛盾。现在按 (段次序, 段内写入序) 稳定排序，小 K 的结果是大 K 结果的前缀。
  ⚠️ 可见变化：同分命中的先后顺序变了，大体上先写入的排在前面。

### Changed

- **本地嵌入后端升级 llama.cpp `b10859` → `b11434`**（opt-in，`BITCASK_WITH_LLAMA=1`；ggml 0.23 → 0.26）。
  NIF 源码不用改：用到的 51 个 llama/ggml 接口全都还在，没有被弃用的，注入的构建选项也都有效。
  构建仍是 14 个 CPU 变体，Vulkan 自动打开，没装 CUDA Toolkit 时 CUDA 自动关闭。
  Qwen3-Embedding-0.6B-Q8_0、8 vCPU 实测：
  - 短查询 33–35 → **22 ms**；
  - 约 280 token 的文档 890 → **720 ms**；
  - 语义自检差值 0.590，与升级前一致。

### Added

- **`search_phrase/4`、`search_fields/4`、`search_near/5`、`search_fuzzy/5`、`search_wildcard/4`**：
  末位加 meta `Filter` 参数（`undefined` 表示不过滤），语义和补取策略与 `search_text/4` 相同。
- **`range/3`、`range_fold/5` 新增选项**：
  - `{want_meta, true}`：`V` 改为 `#{text, meta}`，与 `get` 同形，text 和 meta 出自同一次读；
  - `{filter, F}`：在 C++ 侧逐条按 meta 筛选，不通过的条目连 value 都不拷贝。
- **`bitcask_query:q/2` 结构化查询 DSL**：一个查询里组合三类条件——key（`eq` / `prefix` / `range`）、
  全文（`match` / `phrase` / `fields` / `near` / `fuzzy` / `wildcard`）、meta 上的 `where`
  （`eq/neq/gt/gte/lt/lte/in/exists`，可用 `and`/`or` 嵌套）；另有 `limit` 与 `select`。
  规划器选一个索引驱动：有全文条件走倒排，只有 key 条件走 `range`，都没有就全表 `range`；
  两条路径都把 `where` 下推给引擎。不用 match spec 的原因：值要经过分词，全文条件只能交给倒排。
- **`bitcask_query:page/2,1` 分页**：返回 `{ok, Rows, Cont}`，没有下一页时 `Cont` 为 `done`。
  游标是不透明的 term，不占服务端资源。
  - key 驱动的游标是下一页起始 key；
  - 全文检索的游标是已消费的引擎命中数，依赖同分前缀稳定，翻页不重不漏；
  - 向量 / 混合 / `search_fields` 的游标按已返回的 key 去重，不会重复，但可能漏。
- **`bitcask_query` 支持向量与混合检索**：
  - `vector => VecBin | {text, Bin}`（`{text, Bin}` 整个查询只 embed 一次）；
  - 只给 `vector` 走 `search_vector`，可带 `ef`；
  - 和 `text => {match, Q}` 一起给走 `search_hybrid`；
  - `where` 照样下推，`key` 照样后过滤。
- **二级索引**：`bitcask_query:create_index/2`、`drop_index/2`、`indexes/1`，配合维护索引的写入接口
  `bitcask_query:put/3`、`delete/2`，以及 `explain/2`（查看规划结果）。
  - 只有 `where` 的查询会挑一个已建索引字段上的 eq / in / 大小比较 / exists 条件，转成索引键上的 range。
  - 值的编码保序且能自行判断结束位置，类型语义与引擎 MetaFilter 一致。
  - 每次写入是一个 `bitcask_txn` 事务：锁 key、读旧 meta，「文档 + 新索引项 + 删旧索引项」同一个提交批落盘
    （依赖 libbitcask 6.6.2）。读取时仍回表校验，挡住绕过 `bitcask_query:put/delete` 的写入留下的过期项。
    索引字段的写入必须走 `bitcask_query:put/delete`。
- **原子批 / 事务写结构化文档**（随 libbitcask 6.6.2 的 `kPutDoc`）：`put_batch_atomic/2`、`txn_commit/2,3,4`
  和 `bitcask_txn:write/3` 的 value 可以是 doc map（与 `put/3` 同形）。配了 embedder 时，批内文档自动 embed
  （一次 `embed_batch`，失败整批不写），与 `put_docs/2` 共用同一段代码；按位置配对，所以同一个 key 在批里出现多次也各拿各的向量
  （这也修掉了 `put_docs/2` 里同 key 多次、文本不同时共用一个向量的问题）。
- **`bitcask_txn:lock_key/3`**：只拿点锁、不读不写（同 `mnesia:lock`）。二级索引的写入靠它给 key 加锁。
  `read/2,3` 的 spec 改准：未缓冲的 key 直接返回 `bitcask:get` 的结果，在索引模式下是 map。
- **`bitcask:decode_meta/1`**：`encode_meta/1` 的反方向（新 NIF `cask_decode_meta`）。

### 文档

- meta filter 一节按 NIF 实际行为重写：8 种操作符、`Key` 只收 binary、`children` 只收 map、
  补上求值语义。几处示例原来写的是 `field =>`，NIF 只认 `key =>`，照抄会报 `badarg`，已改正。

## [6.7.0] — 2026-09-29

事务层修一个并发 bug，外加幂等键；随后一轮全项目审查修掉 12 处正确性
问题（NIF 生命周期 / 异常屏障、merge 调度器、fold 错误形态、graphdb 计数器、
embedder 池调度、CI），外加一轮性能优化与清理。libbitcask 仍是 6.6.0，盘上格式不变。

**为什么是 minor 而不是补丁版**——有三类可能影响调用方的变化：
- ⚠️ 最低 OTP 提到 **27**（stdlib `json`）；
- ⚠️ NIF 错误形态两处变化（`{error, error}` → `{error, invalid_option}`、
  `{error, unknown}` → `{error, io_error}`），见 Removed / 行为变化；
- ⚠️ 删除了几个无调用者的 NIF 与 `bitcask_embedder_openai` 的旧 API。

### Fixed

- **`bitcask_txn`：调用方在提交途中被 kill 时锁提前释放**。`txn_commit` 是 dirty
  NIF，kill 的 DOWN 立即送达、批却要等 NIF 跑完才落盘（实测 DOWN 约 100–177µs，
  4MB 批约 10ms），locker 按 DOWN 放锁，别的事务就能在落盘前拿到这些 key，读到
  旧值再覆盖，造成丢更新。现在提交时带一个**提交令牌**（NIF 资源）进 NIF：令牌
  析构只会发生在 NIF 返回后、或调用方在 dirty 队列排队时被 kill（NIF 永不执行）
  之后，析构时通知 locker。调用方死在提交途中，locker 只把事务标成孤儿、锁不放，
  等到令牌通知再清理。兜底：等不到通知就照常清理，记入 `status()` 新增的
  `orphan_timeouts`（应恒为 0）；等待上限是新 app env `{txn_orphan_timeout, Ms}`
  （默认 300000——到点放锁会重新打开丢更新窗口，只防锁永久泄漏，别调小）。
  开销：每个写事务多两次轻量 NIF 调用和一次 ETS 写；单 key + `no_sync` 的吞吐
  与修复前在噪声内持平（8 vCPU：P=1 47–59k、P=8 100–120k txn/s）。

- **NIF：`cask_close` 与在途调用 / 迭代器的生命周期**。以前 close 直接 delete
  Cask 对象——普通调度器上的 `get` 能与 dirty 的 close 并发（cask.hpp 契约里的
  UB），close 后仍活着的 fold 迭代器下一次 `next` 是 use-after-free。现在
  `CaskHandle` 带 `shared_mutex`：所有用 cask 的入口持 shared 锁，close 持 unique
  锁；close 只调 `Cask::close()` 不删对象，fold 迭代器句柄 keep 住父资源（与 range
  迭代器同款），close 后 `next` → `{error, closed}`。已 close 句柄上的普通调用仍
  是 badarg（行为不变）。
- **NIF：C++ 异常屏障**。之前 `cpp/nif/` 没有任何 `try/catch`，`bad_alloc` 或
  `std::system_error` 穿过 NIF 边界就是 `std::terminate` 整个节点。现在函数表里
  每个入口都套 `guarded<>`：`bad_alloc` → `{error, allocation_error}`，其它 →
  `{error, {exception, What}}`。顺带给调用方参数加上限：search 的 k / ef ≤ 10⁶，
  range 的 `prefetch` ≤ 65536、`prefetch_threads` ≤ 256（超出夹住，不再是一个
  INT_MAX 的 k 就 bad_alloc）。
- **NIF：`encode_meta` 把 `true` / `false` 编成 null**——"其它 atom 当 null"的分支
  排在布尔之前，布尔分支永远走不到，`eq true` 的 filter 永远空集。与 filter 解析
  共用一份 `parse_meta_value`（顺序正确的那份），删掉重复实现。
- **`bitcask_merge_worker` 一用就崩**：`do_merge` 在 merge 之后 `[_,_,Args3] = Args`，
  `merge/1,2` 的两参形态必 badmatch；worker 异常退出时 `handle_info` 返回
  `{stop, State}`——不是合法的 gen_server 返回值，调度器自己也跟着死、队列丢光。
  现在只记日志、继续出队；两参形态的 Opts 也 usort（`merge_items` 的 `umerge` 要求
  有序）；第三参接受 `{Files, Expired}`、裸 Files 列表、`all` 三种。
- **fold 家族对 NIF 裸原子 `case_clause`**：`fold/6`、`fold_keys/3,6`、`list_keys`、
  `stream_fold`、`cask_merge_dir` 只匹配 `{ok,_}`/`{error,_}`，NIF 返回裸
  `out_of_date` / `closed` / `mode_mismatch` 就崩——app 默认 `max_fold_puts = 0` 正是
  最容易撞上 `out_of_date` 的配置。统一走 `normalize_error/1`，返回
  `{error, out_of_date}` 等。五个收集器合并成一个 `with_fold_iter/5` 骨架。
- **`bitcask_stream` 读到 `done` 后不释放迭代器**，keydir 快照一直钉到 `stop/1`
  （很多消费者读完就不调 stop）；`stop` 之后再 `next` 永久挂起（stop 已 flush 掉
  monitor）。现在 `done` / 错误即释放；`next` 每次临时 monitor，producer 已退出
  → `done`。
- **`graphdb:del_vertex` 按 500 个 op 硬切块**，高度数顶点的边删除和邻居计数器落在
  不同批，中途失败计数器永久偏高、重跑不收敛。改成**按边切块**：每批 = 这批边的三个
  键 + 恰好这批边的计数器增量（基值在该批提交前才读），最后一批按前缀扫掉自身全部
  计数键 + 顶点键——每批自洽，重跑收敛。
- **`graphdb` 计数器把读错误当 key 不存在**：`bump/3` 对 `{error,_}` 和坏记录都回落到
  0 再提交，一次瞬时 IO 错误变成永久归零。现在读错误原样返回、整批不提交，坏记录
  → `{error, {invalid_counter, Key}}`；事务版同样中止。
- **`graphdb:register_etype` 无锁**：两个不同名字并发注册算出同一个 Next id，两种
  边类型静默合并。现在在 `bitcask_txn` 事务里持 `"t"` 前缀写锁做（同时罩住 `t<id>`
  与 `tn<name>`）。
- **`bitcask_txn` 选项坏值能打崩整个 locker 组**：`lock_wait_timeout` 不校验直接送进
  分片，`start_timer` badarg → 分片崩 → one_for_all 全组重启、所有在途事务
  `locker_restarted`，10 秒内几次就超过重启强度。现在门面校验（坏值 badarg），
  分片 `register` 再兜一层（不合法用默认）；`{timeout, 0}` 合法（立刻超时）。
  另：`try_wake` 丢弃过期等待者后没重新唤醒它挡着的人（要等 5s 兜底），补上。
- **Embedder 池选 worker 只看 `message_queue_len`**：gen_server 先取走请求再跑
  `handle_call`，正在做 forward 的 worker 队列也是 0，平局按名字排序 `_0` 永远赢——
  两路并发实际一路在干活。现在负载 = 在算(0/1，按 `current_function` 判) + 队列，
  平局随机。**`slots => K` 线程超订**：每个 worker 各拿 `可用核数-2` 个线程，8 vCPU
  上 4 槽 = 24 个 ggml 线程；现在池按 worker 数均分注入 `n_threads`。默认线程数的
  兜底从 `logical_processors`（容器里报宿主机核数）改为 `schedulers_online`。
- **CI 跑不过**：`erlang.yml` 调已删除的 `./rebar3`，矩阵 OTP 22–25 但
  `bitcask_embedder_util` 用的 stdlib `json` 是 27 才有，且那些镜像的 gcc 编不了
  C++23。改为 setup-beam + OTP 27 / 28；`minimum_otp_vsn` 提到 27。

### Changed（性能）

- **range / fold**：`range_loop` 批不满 256 即到尾，不再多打一次 dirty NIF 等 `done`
  （graphdb 每跳省约三分之一的 dirty 调用）；`fold/3`、`list_keys/1` 改走批量 NIF
  （128 条一批），不再逐条往返；`fold_keys/3,6`、`list_keys` 走新的
  `cask_fold_next_keys_batch/2`，不再把每个 value 拷成 binary 再丢掉（⚠️ 引擎侧
  `CaskIter::next()` 仍会读 value，省的是跨边界拷贝与 BEAM 垃圾；真正的 key-only
  迭代要上游开 API）。
- **NIF 调度**：`cask_fold_start`、`cask_fold_next_batch`、新的 keys batch 挂 dirty IO
  （前者要 open 每个 sealed 文件，后两者一次最多 1024 次 pread）。`cask_put` /
  `cask_delete` 按需转 dirty IO：cask 配了 `o_sync` / `{puts, N}`、value 是 map
  （`put_doc`）、或 value > 64 KiB；其余小值写仍在普通调度器上内联跑。
- **NIF 小项**：fold 每步不再整拷 `Entry`（含 value）；`make_ok` / `make_error` 用
  缓存的原子；binary 构造改 `enif_make_new_binary`（≤ 64 字节直接建 heap binary，少
  一次 malloc/free）；`make_search_hits` 分配失败不再静默丢命中，返回
  `{error, allocation_error}`。
- **`bitcask_txn_locker`**：本分片无人等待时 release 不做唤醒扫描；DOWN 按
  `mons` 表直查，不再全表 `match_object`；无前缀锁时 `overlapping` 不 `tab2list`；
  `held` 表按 `{TxnId, Shard}` 建键的 `duplicate_bag`，放锁一次 `ets:take`（按 TxnId
  建键的 bag 每次 insert / delete_object 都要扫链，大事务 O(L²)）；授予判定用短路的
  `blocked/4`；入队追加不重排。`bitcask_txn` 重跑退避改带上限的指数抖动
  （`min(10 bsl Attempt, 200)` ms），过了 deadline 不再白等一轮。实测（8 vCPU，
  `no_sync`，同时段对比）：50 key / 事务 P=1 2.5k → 3.4k txn/s、P=8 5.7k → 7.6k
  （约 +35%）；单 key 事务在噪声内持平（P=8 约 110k）。
- **`graphdb`**：`dedupe`、`bfs_layers` 去掉 `++` 二次方拼接；`expand` 按 dirty IO
  调度器数切片（不再一顶点一进程），单一总 deadline，失败时 kill + demonitor 全部
  worker（以前 DOWN 会漏进调用方信箱）；`do_range_take` 带计数器；`count_out` /
  `degree_txn` 走 `range_fold` 整数累加并补上 strict parse（首字节是 `$i` 的 vid 会把
  `ei` 家族的键数进去）。
- **`graphdb_analytics`**：PageRank 改沿反向 CSR 拉取，每轮 O(N+M)（原来每条边
  `setelement` 拷整个 N 元组）；`sssp` 用一张 map 取代 tuple + Seen；`materialize`
  一次 `usort` 取代逐边 `gb_sets`。
- **Embedder HTTP**：批量分块并发发送（`max_inflight`，默认 4，单一总 deadline）；
  `inets` / httpc 在 init 起一次，用独立 profile `bitcask_embedder`；`max_batch` 选项
  真正生效（以前文档有、代码忽略，恒为 64）；openai / anthropic 的重复代码并进
  `bitcask_embedder_util:http_init/4`，headers 在 init 构造一次。

### Removed / 行为变化

- **NIF 错误形态统一**（`fault_to_term_detailed` 并入 `fault_to_term`）：同一种故障
  从任何 NIF 出来形态都一样。⚠️ 变化：没有消息的 `invalid_option` 由
  `{error, error}` 变为 `{error, invalid_option}`；没有 errno 的 IO 故障由
  `{error, unknown}` 变为 `{error, io_error}`；analyzer 不匹配新增
  `{error, analyzer_mismatch}`。裸原子（`not_found`、`closed` 等）与
  `{error, write_locked}` 不变。
- **删除无调用者的 NIF**：`bitcask_cpp_nifs:cask_iterator/3`、`cask_iterator_next/1`、
  `cask_iterator_release/1`（早被 `stream/1` 与 fold 家族取代）、`cask_bool_search/3`、
  `cask_range_next/1`（用 `cask_range_next_batch/2`）。
- **删除 `bitcask_embedder_openai` 的旧 API** `embed/1,3`、`dim/0` 及其读的
  `embedder_url` / `embedder_model` / `embedder_dim` app env；`bitcask_embedder`
  behaviour 去掉旧回调 `embed/1`、`dim/0`。用 `bitcask_embedder:new/2` + ctx。
- 删除 rebar2 / Basho 时代遗留：`package/`、`.travis.yml`、PULSE / EQC 助手与
  Makefile 目标、`test/bcfold_*`。

### Added

- **`bitcask:put_docs/2`**：批量写文档并**一次** `embed_batch` 完成自动嵌入（以前
  `put/3` 逐条嵌入，`embed_batch` 在 `src/` 里没有调用者——设计稿里批量是索引吞吐的
  主要杠杆）。嵌入失败 → `{error, {embed_failed, _}}` 且不写任何一条；某条 put 失败
  → `{error, {Key, Reason}}`，之前的已写入（**非原子**）。
- **幂等键** `bitcask_txn:transaction/3` 选项 `{idem_key, K}`：同一个 K 至多提交
  一次，重来不跑 Fun、直接返回 `{atomic, 首次结果}`。标记（含结果）与数据同批原子
  提交；开跑前持标记写锁，同键并发调用串行。`idem_lookup/2`（不上锁自查）、
  `idem_purge/2,3`（按年龄清理标记：不上锁流式扫描只收过期 key，再按块
  `{chunk, N}` 加前缀锁核对删除，不整体装内存、不长时间挡住带键事务）。
  `{idem_result, false}` 不存 Fun 结果，重来返回 `{atomic, idem_replayed}`（结果大的
  事务用）。标记值定长头 `<<Ver:8, At:64, Result/binary>>`。`<<0, "bitcask_txn:idem:">>`
  前缀保留，事务内写它 → `error({bitcask_txn, reserved_key, K})`。设计
  `doc/txn-layer-design-zh.md` §4.5 / §4.5.1。
- NIF：`bitcask_cpp_nifs:cask_txn_commit/4`、`txn_commit_token/2`（令牌只存
  `{Pid, TxnId}`，析构时发 `{txn_committed, TxnId}`）、`txn_commit_token_disarm/1`；
  门面 `bitcask:txn_commit/4`（给 `bitcask_txn` 用，一般应用用不上）。
- 测试：`bitcask_txn_tests` +8（含 `{idem_result, false}`、按块 purge）。覆盖幂等语义、中止不留标记、保留前缀、8 进程同键
  恰好一次、purge；提交令牌的五种路径（disarm 不发、进程退出即发、坏参数、NIF 执行中
  被 kill、排队中被 kill 且整批不落）；以及在 NIF 执行中 kill 后重试，断言每轮恰好执行
  一次（让 DOWN 直接放锁时这一例稳定失败）。`commit_failed_test_` 改用引擎真实拒绝
  （`_txn:` 保留前缀），不再 mock。

## [6.6.0] — 2026-09-23

**跟随升级 libbitcask 6.5.0 → 6.6.0**（`f618e82` → `1a6d698`）。上游 C API 纯加法、
`SOVERSION` 保持 6；盘上格式仅 `bitcask.meta` 一处向后兼容的可选尾段（analyzer
指纹）。本仓库 NIF 只用到的 C++ 头（`cask.hpp` 等）签名无变化，适配仅为把两个新
旋钮开到 Erlang 门面。

### Added

- **`{segment_verify_crc, B}` open 选项**（仅索引模式）：透传 `SearchLayerConfig::
  mmap_verify_crc`。默认 `true`（开库逐节 CRC，6.6.0 起分块定位读、不再把整个
  `bm25_segments/` 扫进工作集）；`false` = 只验页脚 / 目录，信任盘上节内容，省掉
  开库整读段的 I/O。与 C API `bitcask_open_tuning_t::segment_verify_crc` 同源。
- **`bitcask:set_thread_limits/2` / `bitcask:thread_limits/0`**：进程级线程数上限
  （`IndexWorkers` = 索引池 map worker 数；`SearchSlots` = 批量查询 arena 槽数，
  非 0 时兼作 TBB worker 上限 `SearchSlots - 1`；0 = 缺省 `hardware_concurrency`）。
  首个索引模式库 open 即冻结：之后值不同 → `{error, {thread_limits_frozen,
  {IW, SS}}}`（带生效值），同值 → `ok`。NIF 入口 `bitcask_cpp_nifs:set_thread_limits/2`
  / `thread_limits/0`。⚠️ 容器 / 亲和性受限环境下 `hardware_concurrency` 可能报宿主机
  核数，此类环境应显式设置。
- **application env `{thread_limits, {IW, SS}}`**（默认 `undefined` = 不设）：
  `bitcask_app` 启动时（即首个 open 之前）应用；已冻结且值不同或形态不对 →
  application 起不来（`open/2` 返回 `{error, {bitcask_app_start_failed, _}}`），不
  静默失效。
- 测试：`test/bitcask_libbitcask_660_tests.erl`（`segment_verify_crc` 开关往返、
  线程上限冻结语义、badarg）。

### Changed（随库带入，Erlang 侧无 API 变更）

- 索引模式库开库常驻内存下降：BM25 段 CRC 校验改分块读、checkpoint 按目录逐段读
  （峰值 2× → 1× 文件大小）、docmap / keydir 快照流式载入；检索 key 常驻四份 → 两份
  （上游实测 1M × 20B key 开库堆 −110.5 MB / −19.5%）。
- 核心路径文件句柄一律 `O_CLOEXEC`：宿主 `os:cmd` / `open_port` 起的子进程不再继承
  库 fd。
- analyzer 配置指纹写入 `bitcask.meta` 可选尾段；以不同分词配置重开同一目录会
  `kWarn` 告警（仍开库）。旧目录未记录则不告警。
- `Index::ord_to_ext` 对已删 / 被覆盖的 ord 返回空：检索判活与物化 key 之间被并发
  删除 / 覆盖的命中（高亮、向量检索）现被丢弃，而非返回过期 key。

---

## [6.5.1] — 2026-09-21

**事务协调层落地**：在引擎原子批（A+D）之上补齐隔离性——纯 OTP 的 2PL +
死锁检测 + 事务重启，含前缀锁（无幻读范围扫描）、分片锁管理器与最年轻
优先的受害者选择；`graphdb` 据此获得计数精确的事务式 API。**引擎零改动、
零新依赖、无 ABI / 盘上格式变更**（libbitcask 保持 6.5.0）。设计
[`doc/txn-layer-design-zh.md`](doc/txn-layer-design-zh.md)。`rebar3 eunit` 235/235。

### Added

- **`bitcask_txn` 事务协调层（隔离性）**：在引擎原子批之上补齐 I——悲观 2PL
  点锁 + wait-for 图死锁检测 + 受害者自动重跑（`{retries, N}` 预算 + 1~10ms
  抖动退避），Mnesia 三件套的单节点版。写进调用进程 pdict 缓冲，提交时按
  key 升序展开成**一条** `txn_commit/3` 批（A+D 归引擎）；`index_fun` 把二级
  索引 op 并入同批并补写锁；`{timeout, Ms}` 跨重跑总预算；进程死亡 monitor
  自动清锁。**引擎零改动、零新依赖**：锁管理器 `bitcask_txn_locker` 是
  `bitcask_sup` 常驻 child。设计 [`doc/txn-layer-design-zh.md`](doc/txn-layer-design-zh.md)
  （§11 记录实现与设计稿的偏差）；`test/bitcask_txn_tests.erl` 18 例（锁矩阵、
  FIFO 防写饿死、双方/三方死锁、重启预算、死亡清理、缓冲语义、提交失败、
  timeout、index_fun、跨 cask、8 进程并发转账守恒）。
- **`graphdb` 事务式 API**：`transaction/2,3` + `put_edge_txn`/`del_edge_txn`/
  `edge_txn`/`degree_txn`/`put_vertex_txn`/`get_vertex_txn`。边键 + 反向键 +
  et + deg/degi 计数器全在锁下同批提交，并发对同一端点加边**计数精确**——
  消除了 6.5.0 里"deg/degi 只在单写者语义下精确"的限制。直通 `put_edge` 与
  `put_edge_txn` 不要混用于同一图（直通绕过锁）。`test/graphdb_txn_tests.erl`
  5 例（含 16 进程并发 hub 计数）。
- `bitcask_txn:read/3`：`Lock = write` 读前直接拿写锁（Mnesia `wlock_read`），
  读-改-写模式用它避免读锁升级型死锁。
- **前缀锁**（txn 设计 P2）：`bitcask_txn:lock_prefix/3` 罩住以 Prefix 开头的
  全部 key（含将来的）；`prefix_range/2,3` = 前缀锁 + `range` + 合并本事务
  缓冲——事务内范围扫描**无幻读**。锁表改 ordered_set，请求与重叠记录集比
  （跨记录 FIFO，前缀写等待者不被点锁请求饿死；持覆盖锁再要其下锁免费）；
  无前缀锁时点锁路径开销不变。graphdb 据此新增 `out_edges_txn`/
  `in_edges_txn`/`degree_txn/2`/`del_vertex_txn`（级联一批提交）；加边 vs
  删点随机交错的全图不变式测试。

- **锁管理器分片**（txn 设计 P3）：`bitcask_txn_locker_sup` 之下 N 个分片
  （env `{txn_locker_shards, N}`，默认 8），点锁按 `{CaskRef, Key}` 哈希、前缀锁
  每分片各拿一份；跨分片死锁检测（先写边再检，不漏报）；释放改异步 cast
  （同 mnesia_locker）、提交前校验直读 ETS。locker-only 微基准 26k txn/s 平线
  → P=16 50k+；`status()` 新增 `shards` / `lock_wait_timeouts`。分片崩溃全组
  重启，进行中事务 `{aborted, locker_restarted}`。
- **死锁受害者 = 环上最年轻的事务**（不再固定是请求者），年龄按一次
  `transaction/3` 调用算、重跑不变（同 Mnesia 重启保 Tid）：最老的永远不被
  牺牲，长事务不会被短事务反复打断。在别的分片上等的受害者经 cast 中止。
  `status()` 新增 `victims_other`。

### Fixed

- `graphdb:degree/3` 在 per-etype 计数键缺失（P3 前存量）时的回退原来数的是
  **全部** etype 的出边，现在只数该 etype。

---

## [6.5.0] — 2026-09-18

**图处理层落地**：以 libbitcask 为单一存储的 KV-per-key 图存储 + 内存分析层
（设计：[`doc/graph-layer-design-zh.md`](doc/graph-layer-design-zh.md) / 英文版，
P1–P5 全部实现）。随库升级 libbitcask submodule `598d080` → `f618e82`
（6.3.2 → **6.5.0**），含下游反馈三项的全部修复。无 ABI / 盘上格式变更
（libbitcask C API 纯加法、SOVERSION 保持 6；图层为纯 Erlang）。

### Added

- **`graphdb` 图存储层（KV per-key）**：k=顶点（`n<vid>` DocValue——BM25/向量
  检索对顶点内容免费生效）、边为定宽大端 key（`e`/`ei` 双向，经
  `put_batch_atomic` 原子双写，反向键永不悬挂）；邻接 = OKI 前缀 range
  （O(出度)）；`bfs`/`k_hop`/`shortest_path`（双向，frontier 一顶点一进程
  并行）；`deg`/`degi` 计数器与 `et` 按类型索引同批维护；`neighbors_where/4`
  属性过滤遍历；etype intern registry（open-time schema）。
- **`graphdb_analytics` 图 OLAP（设计 §7 物化层）**：`materialize/2` 把
  `e`/`et` 家族物化为内存二进制 CSR（出边 + 转置，重边去重）；`pagerank/2`
  （阻尼 + dangling 校正）、`connected_components/1`（最小标号传播）、
  `sssp/3`（无权 BFS 距离）。
- 一致性语义测试（扫描中途插入/删除的可见性不变量）与 `test/graphdb_bench`
  基准：稳态一跳 **~0.02 ms/op** @1 万顶点/5 万边（装载 ~76k edges/s）。

### Changed

- **libbitcask submodule `598d080` → `f618e82`（6.3.2 → 6.5.0）**：OKI
  memdelta **排序视图缓存**——拔掉「批量装载后 range 静默变慢 4200×」的性能
  悬崖（下游图基准实测：5 万边装载后一跳 110ms → **0.078ms**，与 flush 后
  持平）；`status()` 新增 `oki_delta_rows`/`oki_delta_bytes`（memdelta 体量
  可观测）；ord 溢出年数文档勘误（`5.8×10¹³ 年` 实为约 585 万年）。
  C API 纯加法、SOVERSION 保持 6、盘上格式零改动。
- embedder 池派发测试 `pool_dispatch_avoids_busy_worker` **采样合一**——
  pick 判定与其依据的邮箱快照同刻，消除全量套件并行负载下的偶发假红
  （上游 `feedbacks/2026-09-18-embedder-pool-dispatch-flaky-under-parallel-suite.md`）。

## [6.4.0] — 2026-09-08

本地嵌入后端的两个产品决定：**`slots => K` 并发槽位**（新配置）与
**设备选择只认独立 GPU**（随 llama.cpp b10859 的 IGPU 类型）。不涉及
libbitcask，无 ABI / 盘上格式变更。本仓库版本对齐 **6.4.0**。

### Added

- **`slots => K`（embedder application env 配置，6.4.0）**：K 个同配置的
  并发槽位。与 `instances`（设备拓扑，注入 `gpu_index`）不同，`slots`
  表达的是并发度——配置**原样透传**，K 个 worker = K 份权重 + K 个 context
  = K 路真正并发的 forward，请求经 `{embedder, Name}` 引用时由 proxy 按
  least-queue 透明分摊。失败策略沿用显式 `instances` 的意图声明语义：
  起不满就死。与 `instances` 同时给 → 启动期当场拒绝，不猜优先级。
  `slots => 1` 合法但无意义（等于多绕一层池）。实现完全复用既有池机制
  （`bitcask_embedder_pool` + proxy 的 qlen 挑选），核心 KV/检索零变化。
  ⚠️ 权重按份数涨（0.6B Q8 ≈ 0.7 GB/份）——llama_context 不可跨线程共享，
  "一份权重多 context" 需要另一套 NIF API，目前没有；并发的价格文档明说。
- `backend_info()` / `gpu_status()` 设备表的 `type` 从三档扩到五档：
  `cpu / gpu / **igpu** / accel / **meta**`（随上游枚举扩展；此前 iGPU 会
  落到 `unknown`，无从诊断）。

### Changed

- **设备选择只认独立 GPU，iGPU 不参与 GPU 加速**（随 llama.cpp b10859）。
  b10859 起 ggml 把 integrated GPU 从 `GPU` 拆成独立的 `IGPU` 设备类型，
  本仓库 `select_devices` 只认 `GPU` 类型——核显不再被当成加速卡，没有
  独立 GPU 时直接走 CPU。这是刻意取舍：嵌入负载小，iGPU 驱动质量与显存
  共享策略参差，负收益场景远多于正收益。诊断时核显以 `type => igpu`
  出现在设备表里但 `gpu_count` 不计——不是 bug，是产品语义。

### 验证

- `rebar3 eunit` **161/161**（新增 3 例：slots 池端到端、冲突拒绝、坏参数
  拒绝）；`rebar3 eunit --module=bitcask_llama_tests` **25/25**；
  xref / dialyzer 干净。
- iGPU 排除依赖真机核显才能端到端断言，本机（无 iGPU）验证的是枚举与
  `gpu_count` 语义；`== GGML_BACKEND_DEVICE_TYPE_GPU` 的过滤点已在源码
  注释钉死，防止将来被"简化"成 `!= CPU` 而静默回退。

---

## [6.3.2] — 2026-09-08

**升级 llama.cpp `b10257` → `b10859`**（本地嵌入后端，opt-in），并全路径
复核 **CPU 与 Vulkan 两档构建**。不涉及 libbitcask 升级——核心 KV/检索
（`bitcask_cpp.so`）零变化，无 ABI / 盘上格式变更。本仓库版本对齐 **6.3.2**。

### 变更

- submodule `third_party/llama.cpp` `22dc605`（tag `b10257`）→ `ca86fb2`
  （tag `b10859`），`.gitmodules` 的 `branch` 随动。约 600 个上游提交
  （推理内核、后端、Vulkan shader 流水线vulkan-shaders-gen 等常规演进）。
- **NIF 源码零改动**：`cpp/llama/nif_llama.cpp` 依赖的 llama.h / ggml-backend.h
  符号面（含较新的 `llama_model_n_embd_out` / `llama_get_memory` /
  `llama_memory_clear` / `llama_n_ctx_seq`）在 b10859 全部在位；根
  CMakeLists 注入的全部 `GGML_*` / `LLAMA_*` 选项（`GGML_BACKEND_DL` /
  `GGML_CPU_ALL_VARIANTS` / `LLAMA_BUILD_APP` 等）上游继续存在
  （`LLAMA_CURL` 被上游标废弃，仍接受，仅告警）；后端子目录布局
  （`ggml/src/ggml-vulkan` 等）与 `ggml_add_backend*` 函数族未变——
  cpp/llama 的递归 target 收集不受影响。
- ggml 版本号 0.18 → 0.23：**从旧 pin 原地升级的检出，`priv/` 会留下上一版
  的 `libggml-*.so.0.18.0` 残骸**（SONAME 链 `libggml-*.so → .so.0 →
  .so.0.<new>` 指向新文件，残骸无害但占空间）；`rebar3 clean` 一并清掉。

### 构建复核（b10859，三档全绿）

- **CPU**（`BITCASK_LLAMA_VULKAN=OFF`）：14 个 CPU 变体 + `bitcask_llama.so`，
  `build_info` 如实上报 `vulkan_built => false`，运行期
  `gpu_status` 报 `status => cpu_only_build`。
- **CPU + Vulkan**（默认 `BITCASK_LLAMA_VULKAN=AUTO`，本机三件套齐全时自动
  开）：`libggml-vulkan.so`（约 55 MB，含编译期生成的 SPIR-V shader）正常
  产出并落 `priv/`；`vulkaninfo` 可见设备时运行期枚举正常。
  ⚠️ 上游 b10859 沿用**只认 Discrete/Integrated GPU** 的枚举过滤——
  llvmpipe 这类 CPU 软件渲染的 Vulkan 设备默认被跳过（设
  `GGML_VK_VISIBLE_DEVICES` 可强制纳入，仅诊断用）。真机（独显/核显）
  不受影响。
- **Vulkan 运行期**：`GGML_VK_VISIBLE_DEVICES=0` 强制下 `gpu_status` 报
  `gpu_count=1`（`Vulkan0` / llvmpipe / backend => Vulkan），枚举、上报与
  设备选择路径全通。
- `rebar3 eunit --module=bitcask_llama_tests` **25/25**（含 tier-B 后端发现、
  GPU 上报真值、batch/pool 端到端）。

### 验证

- `BITCASK_WITH_LLAMA=1 rebar3 compile` 全量通过（Vulkan AUTO 开 + CUDA
  AUTO 关，本机无 Toolkit）；关掉 `BITCASK_WITH_LLAMA` 时核心
  `bitcask_cpp.so` 与 6.3.1 产物等价。
- ⚠️ 复核流程注意：`rebar3 eunit` **不带** `BITCASK_WITH_LLAMA=1` 会触发
  compile pre-hook 把缓存配置回 llama 关（设计如此：hook 以环境变量为准），
  之后再用裸 `cmake --build --target bitcask_llama` 会得到
  `No rule to make target`。测 llama 时全程带着环境变量跑。

---

## [6.3.1] — 2026-09-08

**升级 libbitcask 6.2.2 → 6.3.1**（跨上游 6.3.0 + 6.3.1 两版）：文本处理底座
从 utf8proc 整体迁到 **ICU**，外加一组 C API 增量。submodule `f002e58` →
`d3d7ac8`（tag `6.3.1`）。本仓库版本对齐 **6.3.1**。

> **对 Erlang 调用方零 API 变更，重编即得。** 上游 C API 与 C++ 公开头的
> 既有签名 / 枚举值 / 结构体布局零改动（新增皆为 additive，`SOVERSION`
> 保持 `6`），盘上格式不动、无迁移。本仓库的 Erlang / NIF 代码**一行没改**。
> ⚠️ 但**新增构建依赖 ICU**——全新环境/CI 需要 `libicu-dev`（见下）。

### 新增构建依赖：ICU（≥ 60）

- 上游把 NFKC_Casefold 归一化、Unicode 字符属性与文本编码转换
  （GB18030 / Big5 / Shift_JIS 等 → UTF-8）从 utf8proc 迁到 ICU（S38）。
  **默认走系统 ICU 开发包**（Debian/Ubuntu `libicu-dev`，Fedora
  `libicu-devel`，macOS `brew install icu4c`），找不到才回落 vendored
  `third_party/icu` 子模块。该子模块约 380 MB 且标了 `update = none`，
  `git submodule update --init --recursive` **有意跳过它**——要用 vendored
  需按上游 README 的 `-c submodule.third_party/icu.update=checkout` 显式拉。
- 本仓库两处随动：CI 工作流五个 job 的 apt 安装列表补 `libicu-dev`；
  `rebar.config` 头注释的嵌套子模块说明同步（utf8proc 例子已过时）。
- ⚠️ **索引可复现性**：分词结果 = NFKC_Casefold 表 = ICU 版本。系统 ICU
  随发行版漂移时，新写入的文档可能与老文档切成不同 term——召回悄悄变少
  且**没有任何显式症状**。需要钉死版本用
  `-DBITCASK_ICU_PROVIDER=vendored`（这正是 vendored 模式最实际的用途）。

### 随库带入（上游 6.3.0 / 6.3.1）

- **索引与 Unicode 版本绑定**：`bitcask.meta` 的保留字节 `[12]/[13]` 现记
  建索引时的 ICU / Unicode 主版本（`0` = 未记录；沿用「保留字节全零即
  默认」的零升级模式，meta 版本不动、无迁移）。重开时版本不一致经
  `CaskOptions::log_fn` 告警一条 `kWarn`，**只告警不拒开**。KV 模式目录
  （无文本分析）与 S38 之前建的目录恒为 0，比对自动跳过。
- **C API 纯增量（S39）**，Erlang 门面暂未开到（无 Erlang 侧 API 变更）：
  - `bitcask_put_doc_ex`：多字段文档写入（`bitcask_doc_field_t` /
    `bitcask_doc_input_ex_t`）——此前纯 C 调用方写不出能被
    `field:term` 检索的命名字段；
  - meta 编解码：`bitcask_meta_encode` / `bitcask_meta_blob_free` /
    `bitcask_meta_lookup` / `bitcask_meta_iter_*`——调用方不再需要照
    `meta_codec.hpp` 手拼 varint（编码器内部排序，重复 key 当场判非法，
    那个「Release 下顺序错了静默失配」的坑封在库内）；
  - 分页：`bitcask_search_text_ex`（filter + offset 全参超集）/
    `bitcask_search_phrase_ex` / `bitcask_bool_search_ex`——C++ 侧 S13-D10
    就有的 offset，C 侧此前三个函数全无；深分页成本线性（overfetch
    k+offset），不提供总命中数；
  - 高亮：`bitcask_search_text_highlight`（`bitcask_search_result_ex_t`）
    ——片段来自原文 LRU（默认 1024 条），未命中的冷文档降级为
    `highlights_count == 0` 的 hit，**结果集不因缓存容量缩水**。
- 6.3.1 本身只动一处 CMake 输出路径配置；6.3.0 带入 ICU 78.3 与
  「vendored 数据裁剪默认关」（ICU 78 已对裁剪清单里的部分内部 category
  报「不存在」，失效点在运行期——省 25 MB 不划算，取舍见上游 README）。

### 验证

- 全新 configure（删掉 `_build/cmake` 重来，系统 ICU 76.1，ICU 子模块
  未拉取）+ `rebar3 compile` 通过，NIF 源码零改动。
- `rebar3 eunit` **158/158**；`ctest`（BUILD_TESTING=ON）**769/769**
  （上游新增 19 个用例，含 `meta_unicode_version_test`）；xref / dialyzer
  干净。

---

## [6.2.2] — 2026-09-01

**升级 libbitcask 6.2.1 → 6.2.2**：纯可移植性 PATCH——把上游编译到 libc++
（FreeBSD 15 / macOS 的默认标准库）上。submodule `6e94f77` → `f002e58`
（tag `6.2.2`）。本仓库版本对齐 **6.2.2**。

> **对本仓库是零行为变化的重编。** C API 与 C++ 公开头的函数签名 / 枚举值 /
> 结构体布局零改动（`SOVERSION` 保持 `6`），盘上格式不动、无迁移。本仓库的
> Erlang / NIF 代码**一行没改**——上游动的四处都在 GCC/libstdc++ 下逐字
> 等价（见下）。

### 随库带入（上游 6.2.2）

- **`std::atomic<std::shared_ptr<T>>` 走可移植 shim**。新头
  `bitcask/detail/atomic_shared_ptr.hpp` 提供 `AtomicSharedPtr<T>`：标准库有
  P0718R2 偏特化（libstdc++）就 `using` 到 `std::atomic`，**逐字零开销、
  本仓库的构建产物与 6.2.1 等价**；没有（libc++ 至今未实现）则落到互斥量
  兜底实现。四处站点换了类型别名：`vector_plugin` 的 `hnsw_`、`text_plugin`
  的 building 槽、`oki_state` 的 `runs_snap_`、`sealed_segment_vector_plugin`
  的 `sealed_`/`window_`。
  ⚠️ 兜底特意不用 `std::atomic_load/store(shared_ptr*)` 那套自由函数——
  C++20 起 deprecated、C++26 移除，等于把一个已知会到期的依赖写进移植层。
- **`hnsw.cpp` 的 `adj_load` 去掉 `atomic_ref` 上的 `const`**：libstdc++ 接受
  `std::atomic_ref<const T>`，libc++ 不接受。被引用的对象本身从不是 const
  （`adj` 是 `NodeChunk` 堆分配的可变内存，写端 `adj_store` 就在改它），
  `const_cast` 不引入新的 UB，语义与改前逐字相同。
- **bundled oneTBB 的公开头改标 SYSTEM**：`find_package(TBB)` 那条本来就带
  SYSTEM 语义，`add_subdirectory` 源码构建的 `tbb` 目标却只有普通
  `INTERFACE_INCLUDE_DIRECTORIES`，于是 `oneapi/tbb/*.h` 里的 old-style cast
  全算进 `-Wold-style-cast` / `-Wsign-conversion`——开 `BITCASK_WERROR` 直接
  编不过。**本仓库走系统 TBB，不受影响**；受影响的是没有系统 TBB 可用的平台
  （FreeBSD / macOS / Windows）与 TSan 构建。
- 测试侧两条修复：`thread_pool_test` 的 `count_os_threads` 补 FreeBSD 实现
  （`sysctl(KERN_PROC_PID)`；FreeBSD 的 `/proc` 不是 linprocfs，没有 `task/`），
  以及 `IndexPool.TimeoutReturnsFalseAndDoesNotHang` 里一处真 use-after-scope
  ——`ReducerGate` 声明在 `pool` 之后 ⇒ 先于 reducer join 析构，改为
  `shared_ptr` 按值捕获。⚠️ 这条在 Linux 上一直是绿的：libstdc++ 对「解锁
  一把并不持有的 mutex」静默放过，libc++ 检查返回值直接 SIGILL。

### 验证

- 全新 configure（删掉 `_build/cmake` 重来）+ `cmake --build --target
  bitcask_cpp` 通过。
- `rebar3 eunit` **158/158**，xref / dialyzer 干净。

---

## [6.2.1] — 2026-08-14

**升级 libbitcask 6.1.0 → 6.2.1**（跨上游 6.2.0 + 6.2.1 两版）：Windows 移植、
I/O 稳健性收口，以及一个只动构建系统的 PATCH。submodule `056127b` → `6e94f77`
（tag `6.2.1`）。本仓库版本对齐 **6.2.1**。

> **对 Erlang 调用方零 API 变更，重编即得。** 上游 C API 与 C++ 公开头的
> 函数签名 / 枚举值 / 结构体布局全部零改动（`SOVERSION` 保持 `6`），盘上格式
> 不动、无迁移。

### 变更

- **删除 `third_party/*` 符号链接 workaround**（`CMakeLists.txt`）。此前上游用
  `CMAKE_SOURCE_DIR` 引用自己的 `third_party/` 依赖，被 `add_subdirectory`
  嵌入时那个变量指的是**本仓库根**，于是本仓库要把
  `third_party/libbitcask/third_party/*` 逐个链射到 `third_party/*` 才能配置
  成功。上游 6.2.1 全部改用 `PROJECT_SOURCE_DIR` / `PROJECT_BINARY_DIR`，路径
  自解析，那段 `file(CREATE_LINK)` 随之删除。
  ⚠️ 这件事**只能在上游修**：CMake 进入子目录作用域会重设 `CMAKE_SOURCE_DIR`，
  下游覆盖无效；唯一能改它的注入点（`CMAKE_PROJECT_<name>_INCLUDE`）会把上游的
  `PROJECT_IS_TOP_LEVEL` 判成真、污染下游构建目录。
  老检出里遗留的 `third_party/{utf8proc,cppjieba,...}` 符号链接无害，删掉即可
  （`.gitignore` 条目保留，免得残留变成未跟踪噪音）。
- **`bitcask.write.lock` / `bitcask.merge.lock` 内容多了第二行**（上游 6.2.0
  S37-5）：进程实例令牌，用来防「新进程复用了崩溃进程的 PID → 有效的 stale
  lock 永远回收不掉」。格式变为 `"<pid> <activefile>\n<token>\n"`，POSIX 后端
  恒为 `0`（无令牌可取），写出来只为两平台格式一致。
  ⚠️ 刻意加成第二行而不是扩第一行：两个解析器都只看首行，**新旧锁文件双向
  兼容**。本仓库只有 `bitcask_cpp_cask_gap_tests` 断言过行数，已随之更新。
- 新增 `third_party/zlib` 嵌套子模块（上游把 Windows 的 zlib 来源从 vcpkg 改为
  子模块）。**Linux / BSD / macOS 仍走系统 `find_package(ZLIB)`，不受影响**；
  `rebar.config` 的 pre_hook 本来就是 `--recursive`，会自动带上。

### 随库带入（上游 6.2.0，对本仓库是纯收益）

- **撕裂尾部（torn tail）覆盖**：写入偏移锚定到最后一个完整 record，崩溃 /
  掉电后尾部半条 record 不再被当成有效数据；「丢写导致字段 id 漂移」一并修复。
- **全库裸 POSIX 调用收进 `bitcask::io` seam**，Linux 行为零变化；最后一处长驻
  `FILE*` 退役，库边界只交换内核句柄。
- **SIMD 改运行期 CPU 探测**（CPUID/XGETBV + `BITCASK_SIMD_MAX` 钳制）并按 ISA
  分 TU——不再依赖构建机指令集，换机器不会 SIGILL。
- **解除 Windows 单文件 2 GiB 上限**、Win32 错误码不再污染 C API 的 `errno`
  字段、窄路径 UTF-8 双端对齐（均为 Windows 侧修复，Linux 无感）。
- 上游 CI 工具链 GCC 13 → 14，配套清掉新增告警。

### 验证

- 全新 configure（删掉 `_build/cmake` 重来）+ `cmake --build --target
  bitcask_cpp`：**无符号链接**也能解析到全部依赖；额外验了
  `-DBUILD_TESTING=ON` 的 configure（上游 6.2.1 第二个 commit 修的是
  tests/bench 子目录路径）。
- `rebar3 eunit` **158/158**。改测试前是 1 failed —— 就是上面那条锁文件行数
  断言，属于上游有意的格式演进，不是回归。

---

## [6.1.0] — 2026-08-06

**升级 libbitcask 6.0.0 → 6.1.0**：OKI 不可用按成因拆成两个错误码。
submodule `3480d0f` → `056127b`（tag `6.1.0`）。本仓库版本对齐 **6.1.0**。

> **纯增量，无迁移。** 上游把新枚举值**追加在 `CaskError` 尾部**，既有值不动
> → C API 数值映射不偏移，ABI 未破坏（`SOVERSION` 保持 `6`）。盘上格式零变更。

### 变更

- **`range/2,3` 与 `range_fold/5` 的「索引不可用」拆成两个错误码**，因为补救
  方式根本不同：

  | 返回 | 成因 | 怎么办 |
  |------|------|--------|
  | `{error, no_index}` | 索引在**本句柄上本就不建**：只读 / `merge_only` 打开一个从未建过 OKI 的目录 | 以 `read_write` 重开即自动建；或回落到 `fold` + 前缀过滤 |
  | `{error, index_rebuild_failed}`（**新增**） | 可写 open 时 OKI **试建而败**（IO / 环境问题，细节在 log 里） | 先修环境再重开重试 |

  ⚠️ 关键区别是 `index_rebuild_failed` 意味着**库里有数据、只是索引没建起来**。
  6.0.0 时两者共用 `no_index`，调用方按「没索引就回落到全表扫」处理是对的，
  但无从知道这次其实是环境坏了、值得告警。
- 新错误码在 NIF 侧直接给正规的 `{error, index_rebuild_failed}` 元组，**不跟随
  `no_index` 的裸 atom legacy 形态**——新码没有历史包袱，没必要传播那个疙瘩。
  两者经门面归一后都是 `{error, Reason}`，调用方可以写在同一个 `case` 里分流。

### 验证

- `rebar3 eunit` **158/158**（新增 `range_rebuild_failed_test_`）+ xref/dialyzer 干净。
- 新错误码是**真触发过**的，不是照着枚举写的映射：构造一个删掉 OKI、并在
  `kv.oki.manifest` 路径上放一个**目录**的库（manifest 是 OKI 唯一的 commit
  point，原子写 rename 到目录上必失败）→ 可写 open 时重建失败 → `range` 返回
  `{error, index_rebuild_failed}`，同时 `get` 照常（OKI 只是派生缓存）。

---

## [6.0.0] — 2026-08-06

**升级 libbitcask v5.0.0 → 6.0.0**（跨两个上游版本：5.1.0 + 6.0.0），并把这两版
新增的三块能力全部开到 Erlang 侧：**有序 range 查询**、**跨崩溃原子批**、
**多键事务**。submodule `third_party/libbitcask` 由 `aaac44c` 推进至
`3480d0f`（tag `6.0.0`）。本仓库版本同步对齐为 **6.0.0**。

> ### ⚠️ 升级前必读：存量目录需要一次离线迁移
>
> 上游 5.1.0 引入了 **hint 内嵌 ord 的 flag-day**：`bitcask.meta` v4 → **v5**。
> **本仓库 5.x 写出的所有目录，用 6.0.0 打开会被干净拒绝**（不会按新语义把旧
> 字节读坏）。迁移是**非破坏性**的，data 文件字节零改动（硬链接），只重生成
> hint + meta，幂等可重跑：
>
> ```sh
> _build/cmake/libbitcask-build/bitcask_migrate hintord <旧目录> <新目录>
> _build/cmake/libbitcask-build/bitcask_migrate detect  <目录>   # 先确认纪元
> ```
>
> 拒开时 `bitcask:open/2` 现在会**把迁移命令原样带回来**（见下面「变更」里的
> 错误 detail 透传）——升级前不必先读文档也能自救。
>
> 反过来不成立：**6.0.0 写出的目录不能被旧版打开**。升级请单向进行。

> ### 版本号语义
>
> 上游 6.0.0 是 **ABI 破坏**（`CaskOptions` / `bitcask_options_t` 新增
> `keydir_cache_entries` 字段 → 结构体布局变更，`SOVERSION` 5 → **6**）。
> 本仓库是**源码级**依赖（submodule + `add_subdirectory`），重编即可，
> 没有链接旧 `.so.5` 的问题。盘上格式：meta 纪元不动（v5，用原子批的目录
> 懒升 v6），新增的 BCOK v2 / BCOM v2-v3 / BCKS v4 全是**派生缓存演进**，
> 旧版遇到即弃用重建，不需要迁移。

### 新增

- **有序 range 查询**（上游 S33-5，OKI 有序 key 索引）：
  - `bitcask:range/2,3` — 按 key 字典序取回 `[Lo, Hi)` 的 `{Key, Value}` 列表。
    `Lo` 含、`Hi` 不含，两端都可以传 `undefined` 表示无界。
  - `bitcask:range_fold/5` — 流式版本，回调是
    `fun(Key, Value, Tstamp, Ord, Acc) -> Acc'`。
  - 代价 **O(range)** 而不是 O(全表) 过滤（上游实测 10 万 key、选择性 1/256：
    8.0 ms → **0.53 ms**）。
  - 选项 `{prefetch, N}`（N>1 时批量并发取值，只改取值时机，**输出序与内容
    不变**）与 `{prefetch_threads, N}`（0 = `min(在线核数, 4)`）。大窗口 + 冷值
    时收益明显，小窗口反被线程创建成本吃掉，故默认关。
  - ⚠️ 一致性是 **per-key 弱一致**（与 `parallel_scan` 同档）——迭代期间的并发
    写可能部分可见，**不是 `fold/3` 的快照语义**。要快照请继续用 `fold`。
  - 目录没有 OKI（只读打开一个从未写过的库 / 重建失败）→ `{error, no_index}`，
    调用方按需回落到 `fold` + 前缀过滤。
- **跨崩溃原子批** `bitcask:put_batch_atomic/2`（上游 S35）：
  `Ops :: [{put, Key, Value} | {remove, Key}]`。崩溃/掉电后**整批要么全可见
  要么全不可见**（盘上批头声明区间，恢复时区间不完整即整批截断）。允许批内
  同 key 多次（依序 apply = 批内 LWW），空批是 no-op。
  ⚠️ 原子性与持久性**正交**：没 fsync 就掉电仍可能整批丢失，但绝不半批。
- **多键事务** `bitcask:txn_commit/2,3`（上游 S34）：在原子批之上多一层校验
  ——批非空、key 非空、key 互不重复、不占用 `"_txn:"` 保留前缀；违反任一条
  返回 `{error, {invalid_option, Msg}}` 且**零副作用**。第三参是提交点 fsync
  策略：`sync_on_commit`（默认）| `no_sync`。
  ⚠️ **不提供隔离性（I）与 CAS**：事务中间态对并发读者可见；键集重叠的并发
  提交无定序保证，需应用层自行串行化。键集不相交则并发安全。
  ⚠️ 原子批与事务**首次调用会把目录 `bitcask.meta` 懒升级为 v6**，此后不能被
  早于上游 5.1.0 的读端打开。从不调这两个入口的目录停留在 v5。
- **`{keydir_cache_entries, N}` 打开选项**（上游 S36-4，keydir 磁盘驻留
  Level B）：`0`（默认）= 不限 = 现状全内存；`>0` = opt-in 热点缓存条目预算，
  keydir 降级为缓存，点查权威走 缓存 → memdelta → BCOK v2 run（内嵌 bloom +
  块 LRU，冷 get ≤2 次 pread）。上游 1 亿 `doc:` key 实测：常驻 11 GB →
  **加载峰值 1.14 GB / 重开 0.80 GB（-90%）**，热 get/put/merge 零回归。
  ⚠️ 首次在未带 Level B 戳的目录上开启会**全量重建 OKI**（open 慢一次）；
  `merge_only` 旁车与 Level B 目录**互斥**（open 直接拒）。
- 测试 `test/bitcask_range_txn_tests.erl`（19 例）覆盖上述三块的边界语义、
  错误翻译与资源生命周期。

### 变更

- **`bitcask:open/2` 的错误现在带得上原因**。libbitcask 有两类「只有消息、
  没有 errno/专用枚举」的故障——`kIo(errnum == 0)` 与 `kInvalidOption`，此前
  分别塌成 `{error, unknown}` 与 `{error, error}`，信息全丢。现在形态是
  `{error, {io_error | invalid_option, DetailBinary}}`。
  这正是上面那条迁移路径的关键：打开一个 v4 纪元目录，现在拿到的是
  ``{error, {io_error, <<"read meta failed: ord-less-hint era format (meta v4);
  run `bitcask_migrate hintord <src> <dst>` to migrate ...">>}}``。
  **其余故障形态一律不变**——尤其 `{error, write_locked}` 仍是裸 atom
  （`merge/3` 的 `merge_locked` 映射精确匹配它）。
- 继承上游 B4：**merge 的输入文件改「退休 + 延迟删除」**，不再当场 unlink。
  可见变化是 **merge 释放的磁盘空间延后一拍**（到下次 merge 开始 /
  `checkpoint()` 入口 / `close()`）。换来的是持旧 keydir 快照的在途读者不再有
  ENOENT 假失败窗口。崩溃残留的退休文件是普通 data 文件，恢复与后续 merge
  自愈收编。
- 继承上游修复：组提交成为 put 主路径后 **memdelta 阈值 flush 失联**——纯 KV
  长写负载（无 checkpoint 搭车点）memdelta 无界增长（上游实测 1000 万 put 时
  790 MB）。同时修 `close()` 在 `sync_every_n=0` 下全程零 fsync 的既有暴露。
- 继承上游 B1 收口：**checkpoint 跑赢未 fsync 数据**——keydir 快照 / ckpt 链
  水位 / OKI run 一律「引用 ≤ 持久」过滤，掉电后快照存活而数据蒸发的悬空条目
  （get 报 IO/CRC）就此消除。
- 继承上游 S33-6：`{max_read_handles, 0}`（自动档）的推导结果现在**夹在
  [64, 1024]**。此前只取 `RLIMIT_NOFILE` 的一半，容器/systemd 下 rlimit 常见
  5×10^5+，"取一半"等于没有上限。

### 移除

- 无。上游删除的 TxnCask 方案 B 意图重放（`recover` / `pending_txns`）本仓库
  从未暴露过，Erlang 侧无感。

### 验证

- `rebar3 compile`（链接 6.0.0）+ `rebar3 eunit` **157/157**（新增 19 例）。
- **迁移路径端到端实测**（构造一个合法的 meta v4 目录——改版本字节 + 重算
  meta CRC）：`open/2` 干净拒开并带回 `bitcask_migrate hintord` 命令原文 →
  `bitcask_migrate detect` 认出纪元并给出下一步 → `hintord` 迁移成功
  （112 条记录）→ 迁移后的目录正常打开，`get` / `range` 数据完好。
- 生命周期冒烟：`cask_close` 之后再用 range 迭代器 → `{error, closed}`
  （NIF 侧 keep 住父资源 + 逐次检查，不是段错误）。

---

## [5.1.0] — 2026-08-06

**本地嵌入后端（llama.cpp / ggml）+ 独立 embedder 进程。**

> 与此前每一个版本不同，本次**不涉及 libbitcask 升级**：submodule 仍为 v5.0.0，
> 无 ABI 变更、无盘上格式变更。不打开本后端时，构建产物与 5.0.0 **一字不差**
> ——不拉子模块、不加 CMake 开关、不多任何 target。

### 新增

- **本地嵌入后端**（`bitcask_embedder_llama` + `bitcask_llama_nifs`），在 BEAM
  进程内用 llama.cpp 直接算 embedding，不经 HTTP 端点。产物是**独立的第二个
  NIF** `priv/bitcask_llama.so` + 一组 vendored ggml/llama 共享库（含 14 个运行时
  按 CPU 微架构 `dlopen` 的变体）；核心 `bitcask_cpp.so` 不链接任何 ggml 符号。
  **默认不构建**，`BITCASK_WITH_LLAMA=1 rebar3 compile` 打开。
  新增 submodule `third_party/llama.cpp`（tag `b10257`）。
- **独立 embedder 进程** `bitcask_embedder_server`（gen_server）+
  `bitcask_embedder_proxy`（provider）。`open/2` 的 `{embedder, _}` 现在也接受
  进程引用（`pid()` / 注册名 / `{global,_}` / `{via,M,N}`）：**多个 cask 共用
  一份权重**，生命周期跟着进程走（`terminate/2` 释放）。可由 `bitcask_sup` 按
  新增的 application env `{embedder, #{name, provider, config}}` 启动；不配就
  不启动。
- **GPU 后端：CUDA（NVIDIA）+ Vulkan（AMD / Intel，也能跑 N 卡）**，各一个开关，
  语义一致：`BITCASK_LLAMA_CUDA` / `BITCASK_LLAMA_VULKAN` = `AUTO`（默认，探测到
  SDK 就编入）| `ON`（硬要求）| `OFF`。两个可以同时开。
  ⚠️ Vulkan 的 AUTO 必须把 loader / `glslc` / SPIRV-Headers **三个**都确认到位再
  开——ggml-vulkan 里那两个 `find_package` 都是 `REQUIRED`，只探到一个就打开会
  **直接把构建炸掉**，而 AUTO 的意义是"没有就安静地不编"。
  CUDA 运行时（cudart/cublas/cublasLt）默认随包平铺进 `priv/`
  （`BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME`）——服务器产品，体积不是约束，换掉的是
  "目标机缺 libcublas → ggml 静默跳过后端 → 降级纯 CPU"这一整类不报错的故障。
  CUDA 架构覆盖 Maxwell..Blackwell，不收窄成 native。
- **运行期由 Erlang 自己决策用哪个后端**，不需要按机器改配置、也不需要脚本：
  `model_load` 新增 `backend => auto`（默认）`| cuda | vulkan | cpu`，`auto` 按
  **CUDA > Vulkan > CPU** 挑第一个**真的有 GPU** 的后端族；`n_gpu_layers` 默认
  也是 `auto`（有 GPU 就全卸载，没有就 0）。未知取值报 `{error,{bad_backend,_}}`
  而不是静默当成默认值。
  ⚠️ **只选一族是正确性要求，不是策略**：CUDA 与 Vulkan 同时编进包里时，两者会
  **各自枚举同一张物理卡**（一张 4090 = `CUDA0` + `Vulkan0`）。
  `llama_model_params.devices` 为 NULL 时"使用全部可用设备"，llama 会把同一张卡
  当成两张去切分模型层——不报错，只是显存重复占用 + 莫名其妙的慢或 OOM。
- **多卡：默认只用一张，走数据并行**。新增 `gpu_index`（默认 `0`）与
  `split_mode`（默认 `none`）。
  ⚠️ llama 的 `split_mode` 默认是 `LAYER`（把层切到所有卡上）。对嵌入模型那是个
  反优化：0.6B 权重一张卡装得下，切开只多出跨卡传输，还把 N 张卡的并行浪费在
  **一条串行**的请求路径上。嵌入要的是数据并行——按 `backend_info/0` 的设备表开
  N 个 embedder 进程、各绑一张卡。`gpu_index` 越界报 `{error,{bad_gpu_index,_}}`，
  不静默退回 CPU（那会让整池 worker 挤在 CPU 上没人发现）。
- **批量 embed 入口** `bitcask_embedder:embed_batch/2`（`bitcask_embedder` 的
  **可选**回调 `embed_batch/2`；provider 没实现时框架自动退化成逐条 `embed/2`，
  结果形状一致，调用方不必知道 provider 支不支持）。llama 后端原生实现：一次
  decode 喂多条序列，池化后各出一个向量；`model_load` 加 `batch_size`（默认 1）。
  ⚠️ 返回**逐条**结果 `[{ok,Vec} | {error,Reason}]`，顺序与输入一一对应——一条
  坏文档不该让另外 63 条白算，整批失败会逼调用方丢掉整批或退化成逐条重试。
  ⚠️ **`n_ctx` 必须乘上 `batch_size`**：llama 的 `n_ctx` 是所有序列共享的总预算
  （`n_ctx_seq = n_ctx / n_seq_max`），不乘的话一开批量就把每条文本的可用长度
  **悄悄缩小 batch_size 倍**，原本放得下的文本开始报 `too_many_tokens`，而配置里
  的 `n_ctx` 一个字没变。代价是显存/内存按 batch_size 线性增长。
  ⚠️ 传多少条都行，C++ 侧按序列数与 token 总数两个上限**自动切块**——不切的话
  llama_decode 会拒绝整块并返回一个负值，而那个负值不会说是因为条数太多。
  池化时一批会被**拆开并行**打到各 worker（K 张卡各跑一次批量 decode），结果按
  原顺序拼回。
  **默认 `batch_size = 1`（不开）**：实测收益随文本变短而增大（短文本 7.0x、
  中文本 2.9x），但测量时机器上有别的满载进程，超订会放大批量摊薄的那部分开销，
  安静机器上倍数会小得多；长文本档没有可信数据。开之前在自己的硬件上量一遍。
- **HTTP 档的原生批量**：`openai` / `anthropic` 的 `embed_batch/2` 一次请求带一个
  数组，新增 `max_batch`（默认 64）切块（端点对数组长度与总 token 都有上限，超了
  是**整个请求**失败）。
  ⚠️ **响应按 `index` 字段归位，不按返回顺序 zip**——每个对象都带 `index`，而
  "data 与 input 同序"只是常见实现的行为、不是协议保证。按顺序 zip 的后果是
  **把向量配到别的文档上**：不报错、维度也对，只是检索结果从此不对且查不出来。
  index 不是 `0..N-1` 的排列时整批报错，不猜映射。
  ⚠️ 空串在客户端挡掉不发给端点——OpenAI 兼容端点对数组里的空串会让整个请求
  400，一条空文档废掉同批另外 63 条。
- **HTTP 档的请求/解析收进 `bitcask_embedder_util`**：openai 与 anthropic 的请求体、
  超时、响应解析此前**完全一样**（只有认证 header 不同），现在只剩一份。解析做成
  **纯函数并导出**，新增 `test/bitcask_embedder_util_tests.erl` 14 条不打网络的单测
  ——这段路径此前只有一个默认跳过的手动用例（要真实端点），等于没测过。
- **`instances => auto`**：由 provider 探测该用哪几张卡——取**ggml 枚举到的、且
  装得下模型的**（后者复用加载前那次粗检，顺带跳过别人正占着显存的卡）。
  一张可用的都没有 → 退化成**一个不绑卡的 instance**（纯 CPU），不报错——`auto`
  的语义是"有什么用什么"，没卡时仍该可用。
  ⚠️ **不去猜"该用哪几张卡"**：这个进程能看见哪几张本来就是运维侧的标准手段
  （`GGML_CUDA_DEVICES` / `CUDA_VISIBLE_DEVICES` / `GGML_VK_VISIBLE_DEVICES` /
  容器设备透传），不另造一套。
  ⚠️ **失败策略按写法不对称，这是有意的**：显式卡列表 = **全都必须起来**（写下
  卡号是意图声明，起不来就是配置与现实不符）；`auto` = **尽力而为**，起不来的
  跳过并记 warning，一个都没起来才算失败。
  ⚠️ 尽力而为必须配得上说得出来——新增 `bitcask_embedder_pool:status/1` 报
  `requested` / `started` / `missing`。8 张卡只起来 1 个时业务拿到的是 1/8 的吞吐
  而一切看起来正常，这个函数是那种情况唯一的线索。
  provider 没实现 `auto_instances/1`（HTTP 档根本没有卡的概念）时 `auto` 被
  **明确拒绝**，不悄悄退化成"起一个"。
- **`per_gpu => K`**（默认 1）：同一张卡开 K 个 context。⚠️ 一个 context 同时只
  服务一次前向，多开确实多几路并发，但它们抢同一批 SM、收益**不一定线性**，而
  显存按份数实打实地涨。**没有实测数据，所以是显式选项、不进默认路径。**
- **多卡数据并行池** `bitcask_embedder_pool`：N 个 embedder 进程，**一卡跑全部
  layer、一个 instance 占一卡**，N 个请求真并发。application env 加
  `instances => [0,1,2,3]`（或 `[[0,1],[2,3]]` 卡组，用于单卡装不下时）。
  ⚠️ **不是把 layer 切到多张卡上**：llama 的 `split_mode` 默认 `LAYER`，对嵌入
  模型是反优化——0.6B 一张卡装得下，切开只多出跨卡传输，而且**一个
  `llama_context` 同时只服务一次前向**，切完之后 N 张卡仍然只在处理 1 个请求。
  ⚠️ **协调者不在热路径上**：池是个 **supervisor**，不转发任何 `embed`。worker
  用稳定注册名注册，调用方（proxy）拿到名字列表后**直接打 worker**，中间零跳；
  让一个进程去 `gen_server:call` worker 的话，它自己就成了新的串行点。派发取
  消息队列最短的 worker（worker 串行，队列长度就是它欠的活）。
  ⚠️ 同一张卡出现在两个 instance 里会被拒绝（配置错；`per_gpu` 才是明确要求的复制）。
  ⚠️ **启动是串行的**（N 次模型加载，0.6B 实测 542 ms/次）。故意没做并行/懒加载
  ——那样 worker 的启动失败会绕过 supervisor 的启动期检查，而"配了 embedder 却
  起不来就让 application 死"这条策略正是靠启动期同步失败才成立的。
- **`split_mode` 提为显式配置项**（`none` | `layer` | `row`）+ `gpu_index` 支持
  **卡组**（`[0,1]`）。组内多于一张卡时 `split_mode` 缺省自动变 `layer`；
  ⚠️ `split_mode => none` 配多张卡是自相矛盾，当场拒绝而不是默默只用第一张。
- **装不下的提前粗检**：加载前比 GGUF 文件大小与组内可用显存，明显装不下时报
  `{error, {model_too_large, _}}` 并列出三条出路（部分卸载 `n_gpu_layers => N` /
  跨卡 `instances => [[0,1]]` / 换量化档）。
  ⚠️ 只是粗检，**绝不用它自动决定 `n_gpu_layers`**——llama 的实际占用还含 compute
  buffer 与 KV cache，算错的代价是静默少卸载几层。不做这一步的话，装不下的表现
  是 llama OOM → 回落 `ngl=0` → **整体退回纯 CPU**，90% 本来装得下的层白白挪回去。
- **构建期 / 运行期分离诊断**：构建期事实（编没编 CUDA / Vulkan、toolkit 版本、
  架构列表）烧进 `.so` 由 `build_info/0` 自报；运行期事实由 `backend_info/0` 给
  （设备表带 `type` / `backend` / 显存）；`gpu_status/0` 把两者对到一起产出
  `ok` / `cpu_only_build` / `no_gpu_device` / `backend_not_initialized`。
  只看运行期的话，"0 个 GPU"分不清是包里没编 GPU 后端（要重新构建）还是机器没
  驱动（要装驱动）。回落原因也**按请求的那一族**判——包里编了 Vulkan 没编 CUDA
  而你要 `cuda` 时，说"有 GPU 后端但没设备"是错的。
- **构建期 SDK 探测脚本** `scripts/detect-llama-backends.sh`：CMake 只会说
  "没找到"，它说**缺哪个包**并给出建议的构建命令（自动带上探到的
  `-DBITCASK_LLAMA_CUDA=ON` / `-DBITCASK_LLAMA_VULKAN=ON`）。
  ⚠️ 只是构建期工具——运行期的决策在 Erlang 侧完成，部署机上既不会有这个仓库也
  不会有 cmake。
- **`bitcask_embedder_util`**：把 `truncate_utf8` / `strip_partial` /
  `validate_dims` / `validate_limits` / `l2_normalize` / `mrl_truncate` 收成一份。
  此前 openai 与 anthropic 各有一份**逐字重复**的拷贝。
- 文档 `doc/local-embedding-zh.md` / `doc/local-embedding-en.md`。

### 变更

- ⚠️ **`bitcask:open/2` 不再吞掉 `application:start(bitcask)` 的失败**，改为返回
  `{error, {bitcask_app_start_failed, Reason}}`。从前那句 `catch
  application:start(bitcask)` 把返回值直接丢掉：配了 embedder 但模型路径写错时，
  application 起不来而 `open` 照常返回一个句柄，之后所有 `put #{text=>...}` 都
  没有向量，症状要等到检索结果不对才浮现，而那时候库已经写脏了。**这是有意的
  行为变更**：配置了嵌入模型就说明业务要用它，静默降级比当场死掉危险得多。
  （application 本来就能起来的部署不受影响。）
- `rebar.config` 的 submodule 初始化改为**路径限定**到
  `third_party/libbitcask`。裸的 `--init --recursive` 会把新增的
  `third_party/llama.cpp`（约 200 MB）拉给每一个使用者，包括绝大多数从不打开
  本后端的人。
- `backend_info/0` 的 devices 增加 `type`（`cpu`/`gpu`/`accel`），顶层增加
  `gpu_count`。
- application env 增加 `{embedder, undefined}`（默认不启动 embedder 进程）。
- `rebar.config` 增加 `{dialyzer, [{plt_extra_apps, [inets]}]}`，消掉
  `httpc:request/4` 的 "Unknown function" 警告。
  ⚠️ 用 `plt_extra_apps` 而**不是**把 `inets` 加进 `applications`：inets 只被
  HTTP 档的 embedder 用到，而绝大多数部署不配 embedder，不该为此把它变成
  bitcask 的启动依赖（用到时由 `application:ensure_all_started/1` 拉起）。
  这一项只让 dialyzer 看得见它，**运行期依赖不变**。

### 修复

- `.gitignore` 的 `priv/*.so` 匹配不到带 SONAME 后缀的产物
  （`libggml-base.so.0.18.0` 这类），补 `priv/*.so.*`——否则构建产物会被误提交。

### 实测（8 vCPU 容器，`Qwen3-Embedding-0.6B-Q8_0`，`n_ctx=512`）

查询（5 token）**33–35 ms**、文档（276 token）≈ 890 ms、模型加载 542 ms、
自检（近义 − 无关）0.59。

> ⚠️ `n_threads` 默认值必须用 `erlang:system_info(logical_processors_available)`
> 而不是 `logical_processors`：后者报**宿主机**核数、不认 CPU 亲和性掩码。实测
> 环境上两者分别是 8 和 128，按后者算出 126 线程比最优**慢 20 倍**，且没有任何
> 报错。

### 回归

- `rebar3 eunit` **138/138**（25 条本地嵌入 + 39 条 embedder 进程/池/批量 +
  14 条 HTTP 解析单测；NIF 未构建时相关用例优雅跳过），`rebar3 xref` 干净，
  `rebar3 dialyzer` **零警告**。
- **Vulkan 构建路径已实测**：开发机上有 Vulkan SDK（1.4.309），AUTO 探测到并
  编入，`priv/libggml-vulkan.so` 落地，运行期 `build_info` 自报
  `vulkan_built => true`。因为这台机器没有 GPU，`gpu_status/0` 给出的是
  `no_gpu_device` 而不是 `cpu_only_build`——**这正是构建期/运行期分离要区分的
  那两种情况，本次是用真实数据验证的，不是推理**。
- ⚠️ **CUDA 编译与真实 GPU 运行路径未实测**（开发机无 NVIDIA 驱动、无 toolkit，
  Vulkan 也只是编出来、没有卡可跑）：已验证的是两条 AUTO 探测分支、构建期宏注入
  与自报、无 GPU 时的诚实诊断、以及 `backend` / `gpu_index` / `split_mode` 的
  参数校验与错误路径。

---

## [5.0.0] — 2026-07-17

**升级到 libbitcask v5.0.0**：submodule 由 v4.1.0 升至 **v5.0.0**（64 位时间戳
flag-day：`tstamp` / `expiry_at` 全链路 `uint32_t` → `uint64_t`，Y2038 前瞻；
`SOVERSION` 4 → **5**，ABI + **盘上格式**双破坏）。本仓库版本同步对齐为 **5.0.0**。
NIF 已重新编译链接，eunit 64/64 通过，另做盘上格式逐字节验证与旧库门禁冒烟。

> 本次升级对 Erlang 调用方**无 API 变更**：`fold_keys` 等返回的 `tstamp` 本就是
> 任意精度整数，只是自此可承载 > 2^32（2106 年后）的秒值。`{expiry_secs, N}` /
> `{expiry_grace_time, N}` 选项上游仍为 u32（时长而非时刻），不受影响。

> ⚠️ **盘上格式不向后兼容**：`bitcask.meta` v3 → **v4** 门禁——v5.0.0 打开旧
> u32 纪元库（meta v1/v2/v3）时**干净拒开**（当前 NIF 映射为 `{error, unknown}`，
> 上游把门禁错误包成 `kIo`/errnum 0，详情字符串未透出）。旧库**不必重灌**：
> 上游统一迁移工具 `bitcask_migrate tstamp64 <src> <dst>` 提供非破坏性离线迁移
> （只读 src、只写 dst；`detect` 子命令可先探测纪元）。

> 上游已补 v4.1.0 tag，此前按 commit `66924e3` 固定的说明作废；本次起 submodule
> 恢复按 tag 引用（v5.0.0 = `aaac44c`）。

### 变更（继承自 libbitcask v5.0.0）

- **64 位时间戳全链路**：C/C++ API + 盘上 data record header（23B → **27B**）+
  DocValue（v3 → **v4**，ExpiryAt 段 u32 → u64）+ hint（`BCH3` → **`BCH4`**）+
  keydir 快照（BCKS v2 → **v3**）+ docmap sidecar 等全部 tstamp 载体同步扩宽。
- **修复 u32 求和 wrap**：`expiry_secs` 极大（如 `0xFFFFFFFF`）时
  `tstamp + expiry_secs` 在 u32 域回绕，导致**全库 key 误判过期**；现全部在
  u64 域运算。
- **`now_sec_default()` 返回 u64**：不再把 `tv_sec` 截断到 u32。

### NIF 适配（本仓库）

- `nif_cask_iter.cpp` ×2：迭代器返回 `tstamp` 由 `enif_make_uint`（32 位，u64
  传入会静默截断）改为 `enif_make_uint64`——`fold_keys` / `iterator_next` 的
  `#bitcask_entry.tstamp` 自此 2106 年后仍正确。其余触点为零：写路径均走默认
  tstamp（源码级无感），Erlang 侧整数无位宽。

### 回归

- `rebar3 compile`（链接 v5.0.0）+ `rebar3 eunit` **64/64**。
- 盘上格式逐字节抽查：data header 27B / tstamp u64 / DocValue Ver=4 /
  meta `BCME 04` / hint `BCH4` 全部为新纪元格式。
- 门禁冒烟：v4.1.0 写出的旧库以 v5.0.0 打开被干净拒绝，不会按新偏移读坏旧字节。

---

## [4.1.0] — 2026-07-15

**升级到 libbitcask v4.1.0**：submodule 由 v4.0.0 升至 **v4.1.0**（Phase 5/6 深度审计：
8 项修复 + 4 项重构）。`SOVERSION` 保持 **4**、ABI 未破坏、盘上格式不变；本仓库版本
同步对齐为 **4.1.0**。NIF 已重新编译链接，eunit 64/64 通过。

> 本次升级对 Erlang 调用方**无任何 API 变更**：无新增/废弃 `open/2` 选项，无行为变更。
> 收益全部来自 C++ 核心库的稳定性修复——调用方无需改动代码，重编即得。

> ⚠️ 上游 v4.1.0 只有 release commit、**未打 tag**，submodule 按 commit `66924e3`
> 固定（`git describe` = `v4.0.0-32-g66924e3`）。上游补 tag 后可改回 tag 引用。

### 修复（继承自 libbitcask v4.1.0）

以下均为 C++ 核心库内部修复，对应 Erlang 侧的可观测症状：

- **进程级永久挂死**（P6-MEM-1 + P6-DL-1）：`IndexPool::submit` 先递增 `in_flight`
  再入队，队列内部分配抛 `bad_alloc` 即泄漏计数 → `flush()` 谓词永假；叠加
  `unregister_lib` 的无超时 `flush()`，`close/1` 卸载路径可**永久挂死** VM 调度器。
  修复双向闭合：submit 补偿 `dec_in_flight` 后重抛（根因）+ 拆卸路径 flush 有界 30s
  （兜底）。
- **持久性——hnsw 原子写无 fsync**（P6-DUR-1）：`save` / `save_vec_payload` /
  `write_bcq8` 三处 rename 前无任何 sync，**崩溃后旧好文件已被覆盖成半截文件**
  （向量索引损坏 → 重开全量重建）。现补 `fflush` + `fdatasync` 且两个返回值都检查。
- **资源泄漏**：`RowChunks::ensure_slot` 槽泄漏（P6-MEM-2）、`MmapSegment::open`
  fd 泄漏（P6-MEM-3）、`OrdSkipGuard` 析构抛出触发 `std::terminate`（P5-MEM-1）。
- **checkpoint 水位不一致**：`last_ckpt_ord_` 三处漏更新（P5-MEM-2）。

### 内部（无 Erlang 侧可见影响）

- `file_util.hpp` 归并整读 ×6 + 原子写 ×9 站点，fsync 纪律 4 套收敛为 1 套（T21）。
- Analyzer 双出口归并 + 3 例对拍测试（T22）；死代码清理（T25、P5-DL-3）。
- 上游验收：ASan 644/644 + TSan 全量零告警。

---

## [4.0.0] — 2026-07-13

**升级到 libbitcask v4.0.0**：submodule 由 v3.1.0 升至 **v4.0.0**（S32 向量双引擎 +
S29-11-②④ AVX2 int8 内核 + 磁盘段 UB 审计；`SOVERSION` 3 → **4**，
`bitcask_options_t` 布局变更 ×2 = ABI 破坏，**源码级完全向后兼容**——NIF 重编即正确）。
NIF 已重新编译链接；本仓库版本同步对齐为 **4.0.0**。

> ⚠️ 升级本身对 Erlang 调用方**无破坏性 API 变更**：现有 `open/2` 选项与检索
> API 原样可用，未传新选项时行为不变（向量引擎默认仍为 HNSW）。

### 新增

- **`open/2` 选项 `{vector_engine, hnsw | ivfrq | diskann}`（向量模式）**：透传
  libbitcask v4.0.0 的向量双引擎（S32）。`hnsw`（默认，内存图，≤ 数 M 向量档）、
  `ivfrq`（IVF-RaBitQ 磁盘档，10M-100M 推荐，要求 cosine/dot 度量）、`diskann`
  （Vamana 图，**实验性**，真实语料验证前不建议生产）。建库一次性选定并持久化进
  `bitcask.meta`；重开不符 → `{error, mode_mismatch}`；运行期不可切换（离线工具
  `vec_engine_migrate` 只改 meta，首次 open 全量 fold 重建，可回滚）。
- **`open/2` 向量引擎调优选项**（`0` = 各自动默认，一般无需设置）：
  `{hnsw_m, N}` / `{hnsw_ef_construction, N}`（HNSW 图出度 / 建图 ef）、
  `{hnsw_build_nav_int8, B}`（S29-11-②：HNSW int8 混合精度建图导航，默认 `true`
  ——插入 +29%~75%、recall@10 零损失；`false` = 全 f32 回退闸）、
  `{vector_rebase_min_docs, N}`（S32-M1：向量 ckpt 崩溃恢复重放上界，全引擎，
  默认 262144）、`{vector_ivf_nlist, N}` / `{vector_ivf_nprobe, N}`（ivfrq 簇数 /
  查询探簇数）、`{vector_diskann_r, N}` / `{vector_diskann_l_build, N}`（diskann
  邻接容量 / 建图 beam 宽）。
- **`open/2` 选项 `{auto_checkpoint_min_docs, N}`（索引模式）**：透传
  `CaskOptions::auto_checkpoint_min_docs`（S14-1/S31.5）。自上次 checkpoint 的文档
  增量 ≥ N 即异步落 keydir 快照 + search ckpt，崩溃恢复重放窗口恒 ≤ N。默认
  65536；`0` = 关。
- **`search_vector` 的 `Ef` 参数按引擎解释**：HNSW = candidate list 大小；ivfrq =
  查询探簇数 nprobe；diskann = 查询 beam 宽。
- **`examples/` Wikipedia 检索库示例**：用真实 Wikipedia dump 构建「BM25 +
  向量 + 混合 RRF」检索库，`wiki_hnsw.escript` / `wiki_diskann.escript` 分别
  演示两种向量引擎（只差 `vector_engine` 一个选项，逻辑共享于
  `wiki_common.erl`）。数据提取方案移植自 wiser-cpp：SAX 流式解析（十几 GB
  dump 不进内存）+ wiki 标记两遍清洗 + key=标题/正文进 text/标题进 title
  字段；open 配 embedder 后 put 自动 embed 导语。embedding 端点经环境变量
  `WIKI_EMBED_URL`（必填）/ `WIKI_EMBED_MODEL` / `WIKI_EMBED_DIM` 配置，
  不写死在代码里。用法见 `examples/README.md`。

### 修正

- **`put` doc map 的 `fields` 文档更正（×3 处）**：NIF 实际要求 **map**
  （`#{字段名 => 文本}`，非 map → `badarg`），但 `bitcask.erl` 注释与中英
  API 文档均误写为 `[{Field, Text}]` proplist——该路径此前无测试/示例覆盖，
  首个真实调用方（examples）即踩中。三处文档已对齐实现。

### 变更

- **`third_party/libbitcask` 子模块**：v3.1.0 → **v4.0.0**（soname
  `libbitcask.so.3` → `libbitcask.so.4`；上游后续重打 v4.0.0 标签追加了一次
  文档同步，指针已跟进至 `e814e4d`，无代码/ABI 变更）。随库引入：IVF-RaBitQ-lite 引擎
  （100k/384d 查询 36.5µs、召回损失 ≤0.08pt）、DiskANN 引擎（实验性）、AVX2 int8
  点积内核（VNNI512→VNNI256→AVX2 分发，非 VNNI 机器全 int8 路径激活）、向量 ckpt
  崩溃恢复有界（最坏 ~4.2M 条 → ≤320K 条）、HNSW `.qc8` 码字 mmap 化 +
  `clone_live` payload 外溢（merge 重建堆峰值不再翻倍）、磁盘段结构边界校验修复
  （可信盘模式 OOB 读 UB）、IO 循环 EINTR 重试、`parallel_for` 异常安全。引擎细节见
  [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **NIF 内部**：`search_layer.hpp` 拆分随迁——`nif_options.cpp` / `nif_helpers.cpp`
  改 include `search_config.hpp`（libbitcask v4.0.0 已删除旧头）。
- **构建**：根 `CMakeLists.txt` 版本注释对齐 v4.0.0；`bitcask.app.src` `vsn`
  3.1.0 → 4.0.0。

## [3.1.0] — 2026-07-01

**升级到 libbitcask v3.1.0**：submodule 由 v3.0.0 升至 **v3.1.0**（S12 全库审计批次；
`SOVERSION` 保持 **3**、ABI 未破坏——向后兼容的功能新增）。NIF 已重新编译链接；
本仓库版本同步对齐为 **3.1.0**。

> ⚠️ **盘上格式前向不兼容**：libbitcask v3.1.0 把 `bitcask.meta` 升至 **v3**（加
> CRC32）。本版写出的库**不能被旧 3.0.0 打开**（旧读端只认 v2 → "unsupported meta
> version"）；**反向兼容**——本版能读旧库（v2 meta 兼容读、legacy field.schema 自动
> 原子升级为 FSCH v1）。升级请单向进行。

### 新增

- **`open/2` 选项 `{max_read_handles, unlimited}`**：透传 libbitcask v3.1.0 的
  `kUnlimitedReadHandles` 哨兵（显式不限、旧默认行为）。
- **`open/2` 选项 `{auto_compact_dead_ratio, R}`（索引模式）**：透传
  `SearchLayerConfig::auto_compact_dead_ratio`。`0.0`（默认）= 关；`R ∈ (0.0, 1.0]`
  = 开——reducer 线程内按 per-list 死占比自动 compaction，posting list 内存随 churn
  有界，不再依赖 merge 才回收（libbitcask S12-2）。仅索引模式（带 `{analyzer, _}`）
  生效。
- **错误原子 `closed`**：NIF 把 libbitcask 新增的 `CaskError::kClosed`（对已 close
  的 handle 发起调用，S12-5）映射为 `{error, closed}`，与通用 `{error, error}` 区分。

### 变更

- **`third_party/libbitcask` 子模块**：v3.0.0 → **v3.1.0**（`SOVERSION` 保持 3，
  soname `libbitcask.so.3` 不变；ABI 增量安全——新符号 + 枚举末尾加值）。随库引入：
  read 句柄默认上限（防 fd/mmap 无界）、reducer 线程内自动 compaction、field.schema
  加 FSCH v1 格式头 + CRC、`bitcask.meta` v2 → v3 加 CRC、C API 批量检索 ×3 +
  `parallel_scan` + `BITCASK_ERR_CLOSED`、`-Werror` 库构建护栏。引擎细节见
  [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **`{max_read_handles, N}` 语义变更（随 libbitcask v3.1.0）**：默认 `0` 由「不限」
  改为**按 `RLIMIT_NOFILE` 软上限自动推导**（约一半、下限 64）。小/中库行为不变；
  大库由 fd 耗尽 crash 改为 graceful 句柄淘汰。需旧「不限」行为改传 `unlimited`。
- **构建**：根 `CMakeLists.txt` 版本/格式注释对齐 v3.1.0；`bitcask.app.src`
  `vsn` 3.0.0 → 3.1.0。

## [3.0.0] — 2026-06-25

**升级到 libbitcask v3.0.0**：submodule 由 v1.1.0 升至 **v3.0.0**（libbitcask 自此
**三套版本号统一**——CHANGELOG = 库 `VERSION` = C API = `3.0.0`，`SOVERSION` 1 → 3）。
ABI 破坏性变更，NIF 已重新编译链接；本仓库版本同步对齐为 **3.0.0**。

> ⚠️ **破坏性 API 变更**：移除运行期 `bitcask:set_synonym_map/2`，同义词词典改为
> `open/2` 的 open-time 不可变选项 `{synonym_file, Path}`。调用方需迁移（详见下）。

### 变更（破坏性）

- **同义词词典：运行期 setter → open-time 不可变配置**（对齐 libbitcask v3.0.0：
  `Cask::set_synonym_map` / `bitcask_set_synonym_map` 已删除，新增
  `CaskOptions::synonym_map`）。
  - **移除** `bitcask:set_synonym_map/2`（及 NIF `cask_set_synonym_map/2`、atom
    `load_failed`）。
  - **新增** `open/2` 选项 `{synonym_file, Path}`：开库时一次性从文件加载，构造后
    **不可变** → 并发查询天然安全。`Path` 接受 string 或 binary（facade 自动转
    binary）；仅在索引模式（带 `{analyzer, _}`）生效；文件打不开则静默不展开
    （沿用「无效选项值静默跳过」语义，open 仍成功）。
  - **迁移**：`set_synonym_map(H, Path)` 运行期调用 → 改为 `open(Dir, [{analyzer,
    _}, {synonym_file, Path}, ...])`；运行期更换词典需重开库。

### 变更

- **`third_party/libbitcask` 子模块**：v1.1.0 → **v3.0.0**（`SOVERSION` 1 → 3，
  soname `libbitcask.so.1` → `libbitcask.so.3`；ABI 不兼容时链接器明确报错）。
  随库引入 v1.2.0 引擎能力：`Cask` handle 多线程安全（写路径内部串行化 +
  读/搜索并发 + `close()` fail-fast）、批量检索、异步索引 MapReduce 流水线、
  `parallel_scan` 全表并行扫描；meta 格式升至 v2（新增 `VecInmemInt8` 字节）。
  引擎细节见 [libbitcask CHANGELOG](third_party/libbitcask/CHANGELOG.md)。
- **构建**：根 `CMakeLists.txt` 版本/ABI 注释对齐 v3.0.0；`bitcask.app.src`
  `vsn` 2.2.0 → 3.0.0。

### 文档

- README（中/英）移除函数表 `set_synonym_map/2` 行；`open/2` 文档新增
  `{synonym_file, Path}` 选项说明；ROADMAP 增 libbitcask v3.0.0 升级条目。

## [2.2.0] — 2026-06-22

**libcask 独立库拆分**（[ROADMAP §2.2.0](ROADMAP.md) 计划落地）：C++ 核心（24 源
文件 + 45 头文件）提取为独立的 `libbitcask`（`libbitcask.a` 静态 / `libbitcask.so`
动态），NIF 仅保留胶水层。本仓库 `cpp/` 只剩 9 个 NIF 绑定 TU，单一
`priv/bitcask_cpp.so` 链接静态 libbitcask（保留 LTO）。第三方依赖
（cppjieba / googletest / benchmark / oneTBB / utf8proc / limonp /
unordered_dense）改为 libbitcask submodule vendored，符号链接委托至
`third_party/libbitcask/third_party/*`。

里程碑 L1–L9 全部完成（详见 [`TASK.md` §L](TASK.md)）；libbitcask 同步迭代到
**v1.1.0**（独立 C API + BCSC `search.ckpt` 容器 + HNSW V7 `search.vec` 外存 +
InvVersion=6 FOR/VByte + 三梯队性能微优化 + 生产正确性 C1–C5 修复）。

### 新增

- **`third_party/libbitcask` 子模块**（v1.0.0 → v1.1.0）：完整 C++ 引擎 + 稳定 C
  ABI（38 个 `extern "C"` 函数，`SOVERSION=1`）。`cmake -S third_party/libbitcask
  -B build` 独立可构建，`find_package(Bitcask)` 安装支持。
- **C++ 核心 → 独立库**（L1–L9）：`bitcask_cask` / `bitcask_keydir` / `bitcask_hnsw` /
  `bitcask_search` 等 11 个 STATIC 聚合为 `bitcask_static`（ar 合并 `.a`）+
  `bitcask_shared`（`.so` + C wrapper）；符号导出策略（`-fvisibility=hidden` +
  `__attribute__((visibility("default")))`）。
- **libbitcask v1.1.0 同步引入**：
  - **统一分段搜索 checkpoint `search.ckpt`（BCSC 容器）**：docmap / bm25.default
    / bm25.fields / hnsw 各为一段、**逐段独立 CRC** + 页脚目录 + `.prev` 代际回退
    （取代 `search.docmap.ckpt` / `search.vec.ckpt` / `search.bm25.*` 多文件）。
  - **HNSW V7 / BVH2 v2 外存化**：全精度 f32 向量独立 `search.vec` 文件（`BCVP`，
    只读 mmap + 每 4 KB 页 CRC32）；`search.ckpt` HNSW 段（magic `BVH2`,
    version 2）内嵌 int8 量化码字，省去开库重量化 pass。
  - **倒排盘上格式 v6（`InvVersion=6`）**：ord 改用 FOR（Frame-of-Reference）
    块压缩（128/块），tf/dl 改用 VByte varint（不再支持 v1–v5 载入）。
  - **三梯队性能微优化**（均经实测验证为安全微优化）：HNSW rerank、WAND 结果排序、
    qcodes 条件分配、FStats 缓存行对齐（梯队一）；KeyDir 换
    `ankerl::unordered_dense` 稠密扁平表、HNSW 邻接 bump-slab arena（梯队二）；
    `thread_local` scratch/encode 缓冲复用、serialize 缓冲复用、hint `pread_into`、
    向量软件预取、`-march=native` 开关（梯队三）。
  - **CI**：GitHub Actions matrix（Release + ASan/UBSan/TSan）；崩溃恢复回归测试
    （`fork + SIGKILL` 写入中 + `MergeFailurePreservesKeyDirVisibility`）。
  - **生产正确性 C1–C5 修复**（详见变更段）。
- **NIF 适配（v1.1.0 API）**：
  - 新增 atom `load_failed`；`set_synonym_map/2` 文件打不开现返回 `{error, load_failed}`
    （v1.1.0 起 `load_from_file` 为 `[[nodiscard]] bool`；旧实现会静默装上空词典）。
  - 新增 facade `bitcask:index_errors/1`（[同步透出 v1.1.0 IndexPool 异常计数](src/bitcask.erl)）。
- **构建系统**：根 `CMakeLists.txt` `add_subdirectory(third_party/libbitcask)` 引入
  全部 C++ target；`cpp/CMakeLists.txt` 仅定义 NIF 绑定（链接 `bitcask_cask`）。
  第三方依赖符号链接委托循环覆盖 7 个 vendored 库。
- **索引状态可观测性**：异步索引 worker 异常计数（`IndexErrors`）透出到
  `bitcask:status/1` NIF 元组（facade 通过新 `index_errors/1` 单独读取）——
  非零即索引可能漂移、搜索结果可能陈旧。

### 变更

- **`cpp/` 目录结构**：移除所有 C++ 核心源文件与头文件，仅保留 `cpp/nif/`（9 个
  NIF TU：`nif_main.cpp` / `nif_cask.cpp` / `nif_cask_iter.cpp` /
  `nif_cask_admin.cpp` / `nif_cask_meta.cpp` / `nif_helpers.cpp` /
  `nif_options.cpp` / `atoms.cpp` / `resources.cpp`）。
- **`cpp/include/` → `third_party/libbitcask/include/`**：所有 C++ 公共头文件移入
  libbitcask 库；NIF 通过 `bitcask/...` include 路径访问（CMake 自动添加）。
- **`cpp/c_api/` → `third_party/libbitcask/c_api/`**：38 个 `extern "C"` C API
  函数及对应头文件整体迁移；`nm -D libbitcask.so` 仅暴露 C ABI 符号。
- **第三方依赖 vendoring**：utf8proc / cppjieba / limonp / googletest / benchmark /
  oneTBB / unordered_dense 全部以 libbitcask submodule 形式 vendored，本仓库
  `third_party/` 仅保留符号链接指向 `third_party/libbitcask/third_party/*`。
- **KeyDir 分片锁**：`shared_mutex` → `std::mutex`（消写者偏好停车）；fstats 改
  无锁发布路径。分片数演进至 256（同 2.1.1，但实现层落地于 libbitcask）。
- **`set_synonym_map/2` 错误行为**：从「静默装上空词典」改为「返回 `{error,
  load_failed}`」（v1.1.0 `load_from_file` API 收紧的连带适配）。
- **`status/1` NIF 返回元组**：从 4 元组 `{KeyCount, KeyBytes, Epoch, Files}`
  扩为 5 元组，新增 `IndexErrors` 字段（facade 不外露，新
  `bitcask:index_errors/1` 单独读取）。

### 修复（随 libbitcask v1.1.0 同步引入）

- **C1 — merge 失败时 keydir 完全未动**（延后 apply）：失败后数据立即可见、无需
  重启走恢复路径。
- **C2 — merger 全 9 条错误路径补 cleanup**：部分输出文件不残留。
- **C3 — IndexPool worker 整体 try/catch 吞异常**（best-effort 丢弃 +
  `index_errors` 计数）：异常不再杀 worker、`pending_` 必递减 → `flush()` 不挂、
  索引不静默漂移。
- **C4 — IndexPool 析构 UB 修复**：`start()` 从未调用时 `joinable()` guard 跳过
  join；`stop()` 幂等（CAS 短路）。
- **C5 — `Cask::close()`（`noexcept`）整体 try/catch**：所有可抛操作
  （`save_search_ckpt` / `write_keydir_snapshot` / 分配 / 取锁）纳入兜底；
  catch 后的资源释放中唯一可抛的 `registry release` 也单独 try → 彻底消除
  `noexcept` 函数抛出导致 `std::terminate` 的风险。
- merge 输出无条件 fsync（成功返回 = 新文件已落盘）。

### 不兼容的变化

**无**。2.2.0 是纯结构性提取 + 性能/正确性增量，盘上格式字节序（meta v2 /
小端）与 2.1.1 兼容；旧目录可直接 open。唯一对外可见的 API 行为变化：

- `set_synonym_map/2` 在同义词文件无法打开时**改为返回 `{error, load_failed}`**，
  旧版本会静默装上空词典——依赖静默行为的代码需适配。
- `bitcask_cpp_nifs:cask_status/1` 返回元组从 4 元组**扩为 5 元组**（新增
  `IndexErrors` 字段）。未直接调用此 NIF 的纯 facade 用户不受影响。

---

## [2.1.1] — 2026-06-17

2.1.0 引入 C++23 引擎后的第一轮**系统级优化**——聚焦向量库的内存/磁盘墙、
读路径零拷贝、恢复持久化统一、以及全盘字节序规范化。428 GoogleTests 全绿。

### 新增

- **P5 — HNSW int8-only 内存模式**（opt-in `{vector_inmem_int8, true}`）：丢掉
  常驻 f32 `vecs`，建图/查询/精排全走 int8（查询侧也量化、VNNI int8×int8）。向量
  内存 **−80%（~5×）**，1M 向量 dim=2560 从 12.81 GB → 2.57 GB；代价 recall@10 约
  −3%（合成簇 1.0→0.965）。与 P3 落盘 int8 正交可组合。默认仍 f32+int8（召回优先）。
- **P6 — sealed 文件 mmap 只读路径**：sealed（封口不可变）data 文件 mmap 零拷贝读
  ——免 pread syscall、直接用 OS page cache、不双缓存。active 文件永远 pread。merge
  unlink 旧文件延迟 munmap（`shared_ptr<DataFile>` 引用计数，在途读者续命）。32 位
  禁用。`GetResultView` 持映射引用锚定生命。
- **P8 — HNSW merge rebuild 门控**：按死节点比例门控全量重建（同 P2 范式），死占比
  < 阈值跳过（`is_live` 过滤兜底），≥ 阈值才全量重建——节省向量库 merge 的主要 CPU。
- **P9 — read 句柄 fd 预算 LRU**（`{max_read_handles, N}`）：只读文件句柄按 LRU /
  数量上限淘汰，解决大库 fd 撞 ulimit 问题（与 P6「mmap 后 close fd」互补）。0=不限。
- **P10 — search_hybrid 两路并行**：BM25 与 HNSW 两路搜索丢线程池并行执行，hybrid
  查询延迟近减半。
- **P11 — merge I/O 顺序优化**：merge 读旧/写新文件加 `posix_fadvise(SEQUENTIAL/
  WILLNEED)` + 大缓冲，降低 IO stall。
- **P13 — open 时按需后台 merge**（`{merge_on_open, off|background}`）：open
  （read_write）后按 `needs_merge` 门控**后台**触发 merge，收拢小文件，不阻塞 open。
- **P14 — 恢复持久化统一**：
  - **P14a** checkpoint 命名重构（`.snap→.ckpt`、bm25 `.inv→.seg`/`.inv.wal→.wal`），
    契约 `{kv|search}.{组件}.{ckpt|seg|wal|manifest}` 文档化。
  - **P14b/P14e** 单文件分段 `search.ckpt`（逐段 CRC + 页脚目录 + 段级脏位复用 + 代际
    `.prev` 回退）+ 单趟尾部回放（认 data 文件为唯一 WAL，消 4-way 配对门悬崖、重用率
    从 0 起来）。写放大 2→1、搜索多文件→1、崩溃后不再全量 fold。
- **P15 — 全盘字节序统一（小端）+ 迁移工具**：
  - 全盘统一小端（mmap 读无 bswap、`static_assert` 守护）。
  - `bitcask.meta` version 1→2，旧 v1 大端目录 open 干净拒绝（fail-loud）。
  - `migrate_le` 离线迁移工具（data 重编码 + hint 重生成 + meta + field.schema + shadow
    翻转）；中英文档 [`doc/migrate-le.md`](doc/migrate-le.md) /
    [`doc/migrate-le-en.md`](doc/migrate-le-en.md)。
- **libcask 独立库拆分可行性评估**：见
  [`doc/libcask-extraction-zh.md`](doc/libcask-extraction-zh.md)。

### 变更

- checkpoint 文件后缀全面变更：keydir `.snap→.ckpt`、bm25 `.inv→.seg`/
  `.inv.wal→.wal`、搜索多文件 → 单个 `search.ckpt`。
- 磁盘格式字节序从混合（record/hint 大端、向量/snapshot 小端）统一为**全盘小端**。
  `bitcask.meta` version 从 1 升到 2。

### 不兼容的变化

1. **磁盘格式字节序**：全盘统一小端（meta v2）。旧 v1（大端）目录**不被读取**——
   需用 [`migrate_le`](doc/migrate-le.md) 工具迁移或从新目录重建。
2. **checkpoint 文件命名**：`.snap`/`.inv`/`.inv.wal` 后缀废弃，统一为
   `.ckpt`/`.seg`/`.wal` + `search.ckpt`。旧名不再读（可重建，升级后首次 open 一次
   全量 fold、close 落新名）。

### 备选项目 gate 结论

- **P7（派生值 compute cache）❌ 不做**：dequant derive 仅 mmap 访问的 1-1.3×，缓存
  收益微乎其微；highlight 非热路径（仅 `search_text_highlight` 触发），收益面太窄。
- **P12（meta_blobs_ 有界）❌ 不做**：1M ords 访问 200-300 ns（`shared_lock` + vector
  copy）、内存 ~280 MB——当前规模可接受；按需读盘会在搜索热路径引入毫秒级 I/O
  （比当前慢 10000×）。>10M ords 时再评估。

---

## [2.1.0] — 2026-06-15

引擎的一次彻底 **C++23 重写**（单一 NIF，`priv/bitcask_cpp.so`），把 bitcask 从
纯键值存储升级为 **KV + BM25 全文检索 + HNSW 向量检索** 引擎，并做了大量
SIMD/AVX 加速。核心 Erlang KV 接口（`get`/`put`/`delete`/`fold`/`merge`…）保留；
与 legacy 2.0.x 的差异见 **不兼容的变化**。

API 参考：[`doc/api-zh.md`](doc/api-zh.md)。

### 概述
- C++23 NIF 引擎；带类型记录磁盘格式（`kDoc`/`kTombstone` + 逐次写入序号 +
  可选 DocValue：text / fields / vector / meta）。
- BM25 全文检索；HNSW 近似最近邻向量检索；RRF 混合检索融合两路。
- 可插拔 embedder 框架，写入与查询自动 embed。
- 大量 AVX/AVX-512/VNNI SIMD 加速，运行时按 CPU 派发 + 标量兜底（见下方专节）。

### 新增
- **BM25 全文检索**：`search_text` / `search_phrase` / `search_fields`
  （`field:term^boost`）/ `search_near`（slop）/ `search_fuzzy`（编辑距离）/
  `search_wildcard`（`*` `?`）。同义词（`set_synonym_map/2`）、Porter 词干化、
  片段高亮。
- **分词器**：whitespace、CJK n-gram、jieba（CutForSearch + CJK 回退）；NFKC
  归一化、可选停用词、可配 n-gram 上下界 / 最小词长 / 词干化。
- **搜索引擎内核**：Block-Max WAND 早终止、k-way leapfrog 交集、扁平数组评分、
  选择性查询缓存（`SearchCache`）、文档原文 LRU、倒排 WAL + 快照恢复。
- **HNSW 向量检索**（`search_vector`）：分层图 + 启发式选边，`cosine` / `l2` /
  `dot` 度量，int8 量化（粗筛 + f32 精排），BCVS 快照持久化，merge 物理清死节点。
- **RRF 混合检索**（`search_hybrid`）：以 `Σ 1/(60+rank)` 融合 BM25 与 HNSW；
  支持单路退化。
- **Embedder 框架**（`bitcask_embedder`）：`new/2` 上下文 API，
  `openai` / `anthropic` / `{custom, Mod}` provider；`put #{text => ...}` 自动
  embed；`search_hybrid(H, Text)` / `search_hybrid(H, Text, auto, …)` 与
  `search_vector(H, {text, _}, …)` 自动 embed 查询；`bitcask:embed/2` 门面。
  可配 `max_input_bytes` / `timeout_ms` / `connect_timeout_ms`。
  **MRL（Matryoshka）**：`dim`（原生）与 `vector_dim`（截断落库）——二者不一致时
  请求带 `dimensions`，并校验响应维度。
- **结构化元数据 + 过滤**：`encode_meta/1`；`eq`/`gte`/`lte`/`in` 条件 +
  `and`/`or` + 嵌套，作用于 `search_text/4`、`search_vector/5`、`search_hybrid/5`。
- **P3 — 向量落盘 int8 量化**（opt-in `{vector_quantized, true}`）：向量按 per-vector
  对称 int8 码字落盘（磁盘 `~4×` 小），写入 `bitcask.meta` 并重开校验一致；
  `get`/恢复透明 dequant。默认仍 f32——合成 dim=2560 实测 recall@10=0.987 /
  @100=0.995（@10 跌 ~1.3%），故 int8 作磁盘受限部署的 opt-in。设计+测量见
  `doc/vector-ondisk-quant-design-zh.md`。
- **P4 — 单写者组提交**（`{sync_strategy, {puts, N}}`）：每 N 次写对 active data
  file fsync 一次（close/roll/sync 收尾 force-flush），介于 `none` 与逐条
  `o_sync` 之间。无跨线程锁。
- **流式迭代**：`stream/1` + `next/1` + `stop/1` + `with_stream/2`，及
  `stream_fold/3,4`。
- **双语文档**：API 参考（`doc/api-zh.md` / `doc/api-en.md`）、并发/锁全序、磁盘
  格式、HNSW 设计、SIMD 内幕等。
- **构建/测试**：CMake + rebar3 双入口；ASan/UBSan/TSan 预设；400+ GoogleTests。

### 性能——AVX / SIMD 指令集优化
所有内核都做**运行时 CPU 特性派发**（`AVX-512F → AVX2 → 标量`，适用处含 NEON），
单一二进制到处可跑、自动用最宽指令集，并始终保留标量兜底。

- **HNSW 距离内核**：dot / L2 的 AVX-512（4× `__m512` 累加器）与 AVX2+FMA 实现；
  `pick_kernel` 构造时一次性选定 ISA。
- **int8 量化（VNNI）**：基于 `dpbusd` 的 int8 距离内核做粗筛，再 f32 精排——在
  AVX-512-VNNI CPU 上大幅提速且保召回。
- **倒排交集**：u64 SIMD 交集（AVX-512 / AVX2）+ Inoue 块过滤，配合 galloping /
  标量自适应派发（ord 可窄化时用 u32）；AVX2 原型实测约 3.46× 于标量。
- **BM25 评分**：SIMD `tf_norm`（AVX2 8 路 / AVX-512 16 路）+ 统一
  `score_bow_topk` 内核；查询向量归一化 SIMD（双精度 dot + float scale）。
- **存活位 gather**：`fill_is_live` / `fill_doc_lens` AVX2 gather，ords 有序快路径
  （recency 类查询占主导）。
- **CRC32**：PCLMULQDQ 硬件加速（SSE4.2 + CLMUL），zlib 兜底。
- **模糊匹配**：Myers 位并行编辑距离（约 11× 于 DP 基线）。

### 性能——持久化与写路径
- **P1 — Hint 写缓冲**：hint record 攒进 64 KiB 内存缓冲，按阈值 / 文件 roll /
  close 才落盘，取代每 put 一次 `write(2)`——写路径 syscall 约减半。hint 可重建，
  崩溃丢缓冲尾巴只回退 `fold(data)`（安全语义不变）。
- **P2 — merge 不重分词**：merge 后不再全量重建 BM25 索引（原会重读+重分词所有
  live 文档）。posting 以稳定 `ord` 为键，`merge` 已通过 `on_relocate` 重映射定位、
  死文档由 `is_live` 过滤，故 merge 改为按阈值 `compact`（清死 posting，不读盘、
  不跑 NLP）。

### 变更
- `bitcask:open/2` 改用 `{embedder, {Provider, Cfg}}` 配置 embedder，并自动从
  embedder 的 `vector_dim` 推出集合维度（无需单独写 `{vector_dim, N}`）。
- KeyDir 分片为 256 片 + 写者闸门屏障（取代 stop-the-world 全屏障）；任意瞬间至多
  持 1 把分片锁。
- 索引更新走异步单写者 `IndexPool` worker；读/搜索无锁，与之并发。
- 统一架构：`Cask` 与原 `Collection` 合并为单一引擎，由 `{analyzer, ...}` 选择；
  每目录 `bitcask.meta` 记录模式。

### 修复
- **崩溃**：jieba 分词器因自注册在独立 TU 被静态链接器丢弃 → `create(Jieba)`
  返回 null → 首次带 text 的 `put` 段错误。注册移入工厂 TU；analyzer 构造失败时
  `open` 干净拒绝。
- **并发 / 内存**（读路径 vs 异步 worker 加固）：`meta_blob` 改返回拷贝而非逃逸
  span（UAF）；搜索缓存 `last_used` 统一经 `atomic_ref`；`InvertedIndex::save`
  安全遍历并发表；`max_indexed_ord_` 原子化；`IndexPool` 消费者 try/catch（避免
  `flush` 挂起 / `std::terminate`）；HNSW `load` 释放残留 chunk；重建/加载快照时
  清理 `ord_field_lens_`。
- **`{sync_strategy, {seconds, N}}`** 文档有声明但 C++ NIF 从未实现（静默等同
  `none`）；以已实现的 `{sync_strategy, {puts, N}}` 取代（P4）。
- **`bitcask:open/2` 模式不一致 `case_clause` 崩溃**：NIF 把部分故障（如
  `mode_mismatch`）以裸 atom 返回，`open/2` 未处理——现归一为 `{error, Reason}`。

### 不兼容的变化
1. **磁盘格式**：新的带类型记录格式（`kDoc`/`kTombstone` + 逐次写入序号、可选
   DocValue）。本引擎**不读** legacy 2.0.x 数据文件——请用全新目录。
2. **`open/2` 返回值**：现在是 `{CaskRef, EmbedderCtx}`（二元组），不再是裸
   `reference()`。整体不透明地传给所有 `bitcask:*` 调用即可（仍可用）；对裸
   reference 做模式匹配的代码需适配。
3. **移除 legacy 迭代 API**：`iterator/3` + `iterator_next/1` +
   `iterator_release/1` → 改用 `stream/1`+`next/1`+`stop/1` / `with_stream/2`，或
   `fold/3,6` / `fold_keys/3,6`。
4. **移除 `collection_*` API**：合并进单一引擎；用 `{analyzer, _}` 启用索引模式。
   `keydir_copy` / `deep_copy` 不再导出。
5. **构建 / 运行时**：构建 NIF 需 C++23 工具链与 oneTBB；Erlang/OTP ≥ 22
   （OpenAI 兼容 embedder 用 OTP 27+ 的 `json` 模块）。引擎产物为单一
   `priv/bitcask_cpp.so`。

---

## [2.0.3] 及更早
legacy Erlang/C bitcask。见 `2.0.3` 标签之前的 git 历史。
