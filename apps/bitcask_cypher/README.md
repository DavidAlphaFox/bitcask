# bitcask_cypher

Cypher（openCypher）查询层，建在 bitcask 图层（`graphdb` / `graphdb_model`）的公开接口上。与 bitcask 在同一仓库，是独立的 OTP 应用
（依赖 `kernel`、`stdlib`、`bitcask`）；bitcask 本身不依赖它。

- 使用说明：[`doc/cypher-zh.md`](doc/cypher-zh.md) / [`doc/cypher-en.md`](doc/cypher-en.md)
- 语法参考（openCypher 2024.3 语法 + bitcask 特有的语法）：[`doc/cypher-syntax-zh.md`](doc/cypher-syntax-zh.md) / [`doc/cypher-syntax-en.md`](doc/cypher-syntax-en.md)
- 设计：[`doc/cypher-query-design-zh.md`](doc/cypher-query-design-zh.md)、[`doc/cypher-phase3-design-zh.md`](doc/cypher-phase3-design-zh.md)
- 任务与更新日志：[`TASK.md`](TASK.md)、[`CHANGELOG.md`](CHANGELOG.md) / [`CHANGELOG_EN.md`](CHANGELOG_EN.md)
- 示例：`escript apps/bitcask_cypher/examples/cypher_demo.escript`（在仓库根目录跑）

```erlang
{ok, _} = application:ensure_all_started(bitcask_cypher),
G = graphdb:open("/tmp/g", [read_write]),
{ok, #{rows := Rows}} = bitcask_cypher:q(G, "MATCH (a:Person)-[:KNOWS]->(b) RETURN b.name").
```

## 构建与测试（仓库根目录）

```sh
rebar3 compile                                      # 同时编译 bitcask 与 bitcask_cypher
rebar3 eunit                                        # 两个应用的测试
apps/bitcask_cypher/test/tck/fetch.sh               # 拉 openCypher TCK 场景集到 _build/tck/
escript apps/bitcask_cypher/test/tck/tck.escript    # 跑 TCK，报告在 _build/tck/report.txt
```

## 配置（应用环境 `bitcask_cypher`）

| 键 | 缺省 | 含义 |
|---|---|---|
| `cypher_max_write_vertices` | `undefined` | 一条写语句最多写多少个顶点；未设 = 不限 |
| `tz_dir` | `undefined` | 命名时区的 zoneinfo 目录；未设 = 环境变量 `TZDIR` > `/usr/share/zoneinfo`（Windows 上要配） |
| `tz_backzone` | `false` | `true` = 被 IANA 合并的时区照用本机（带 backzone 编的）zoneinfo |

## 与图层的约定

- 一个 id 空间、一份标签索引、一种属性编码（`graphdb_model`），图层 API 与 Cypher 混用。
- 引擎 meta 存不了的值（时间 / 空间值、NaN / Infinity）由本应用的 `bitcask_cypher_values` 经
  `graphdb_model:register_value_codec/1` 注册编解码（应用启动、以及各入口第一次调用时）；没注册时图层按存储文本读出。
