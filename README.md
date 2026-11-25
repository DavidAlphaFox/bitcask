# Bitcask

[![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

[English](README_EN.md) · [API 参考](doc/api-zh.md) · [Cypher](apps/bitcask_cypher/doc/cypher-zh.md) · [能力与约束](doc/capabilities-zh.md) · [实用方法](doc/USAGE.md) · [更新日志](CHANGELOG.md)

Bitcask 是一个用 C++23 实现的日志结构键值存储引擎，通过 Erlang NIF 暴露 API。
核心支持 KV 读写、有序范围扫描、原子批与隔离事务；在同一引擎上可以启用 BM25
全文检索、向量近邻搜索和 RRF 混合检索。仓库内还提供 `graphdb` 图层与
`bitcask_cypher` 图查询语言。

架构上是单一 C++23 NIF（`apps/bitcask/cpp/`）加薄 Erlang 门面
（`apps/bitcask/src/bitcask.erl`）。所有业务调用经 `bitcask_cpp_nifs` 到
`apps/bitcask/priv/bitcask_cpp.so`。

## 快速导航

| 需要做什么 | 从这里开始 |
|---|---|
| 查函数签名、参数、返回值与错误 | [API 参考](doc/api-zh.md) |
| 查 openCypher 子集、参数、预编译、游标 | [Cypher 使用说明](apps/bitcask_cypher/doc/cypher-zh.md) |
| 查语法细节与 bitcask 扩展 | [Cypher 语法参考](apps/bitcask_cypher/doc/cypher-syntax-zh.md) |
| 了解能力边界、模式与常见限制 | [能力与约束](doc/capabilities-zh.md) |
| 复制常用操作、事务、合并、排错示例 | [实用方法](doc/USAGE.md) |
| 配置本地嵌入模型与 GPU | [本地嵌入指南](doc/local-embedding-zh.md) |
| 查历史变更、兼容性与迁移 | [CHANGELOG](CHANGELOG.md) / [ROADMAP](ROADMAP.md) |

## 安装与依赖

在其它 rebar3 项目里依赖核心应用：

```erlang
{deps, [{bitcask, {git_subdir, "https://github.com/DavidAlphaFox/bitcask.git",
                   {tag, "13.1.2"}, "apps/bitcask"}}]}.
```

rebar3 3.14 起支持 `git_subdir`。它会克隆本仓库，在 `apps/bitcask` 执行构建
hook，初始化子模块并用 CMake 编译 NIF。12.1.0 及更早版本仍使用普通
`{git, Url, {tag, ...}}` 依赖。

常规构建要求 Erlang/OTP ≥ 27 和 ICU 开发包：Debian/Ubuntu 安装 `libicu-dev`，
Fedora 安装 `libicu-devel`，macOS 可用 Homebrew 安装 `icu4c`。默认优先使用系统
ICU；找不到时回退到 vendored ICU。

## 构建

```sh
rebar3 compile          # 编译 Erlang 应用与 bitcask_cpp.so
rebar3 eunit            # Erlang / NIF 测试
rebar3 do xref, dialyzer
```

C++ 测试与基准使用独立 CMake 构建树：

```sh
cmake -S apps/bitcask -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure
```

Sanitizer 构建通过 `BITCASK_SANITIZE=address,undefined` 或
`BITCASK_SANITIZE=thread` 开启；ASan 与 TSan 一次只能启用一种。

基准构建使用 `CMAKE_BUILD_TYPE=Release` 和
`BITCASK_BUILD_BENCHMARKS=ON`。本地 llama.cpp 嵌入后端默认不构建：

```sh
BITCASK_WITH_LLAMA=1 rebar3 compile
```

它会额外生成 `apps/bitcask/priv/bitcask_llama.so`。配置、GPU 探测、性能与排错
见 [本地嵌入指南](doc/local-embedding-zh.md)。

## 快速上手

```sh
rebar3 shell
```

键值模式：

```erlang
R = bitcask:open("/tmp/db", [read_write]),
ok = bitcask:put(R, <<"hello">>, <<"world">>),
{ok, <<"world">>} = bitcask:get(R, <<"hello">>),
ok = bitcask:close(R).
```

BM25 检索：

```erlang
H = bitcask:open("/tmp/index", [read_write, {analyzer, whitespace}]),
ok = bitcask:put(H, <<"d1">>, <<"the quick brown fox">>),
ok = bitcask:put(H, <<"d2">>, <<"a lazy brown dog">>),
{ok, Hits} = bitcask:search_text(H, <<"brown">>),
ok = bitcask:close(H).
```

向量与混合检索、事务、范围查询、合并、过期和错误的完整示例见
[实用方法](doc/USAGE.md)。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `apps/bitcask/` | 核心 Erlang 门面、C++ NIF、测试、示例与子模块 |
| `apps/bitcask_cypher/` | openCypher 子集查询层，只依赖核心公开 API |
| `doc/` | API、能力、实用方法与设计文档 |
| `CHANGELOG.md` / `CHANGELOG_EN.md` | 版本历史与兼容性说明 |
| `ROADMAP.md` / `ROADMAP_EN.md` | 路线图 |

## 文档地图

### API

- [中文 API 参考](doc/api-zh.md)：生命周期、KV、迭代、事务、BM25、向量、meta、
  二级索引、embedder 与并发约束。
- [English API reference](doc/api-en.md)。

### Cypher

- [Cypher 使用说明](apps/bitcask_cypher/doc/cypher-zh.md)：快速上手、接口、
  数据模型、读写、检索、explain、时间 / 空间类型和限制。
- [Cypher 语法参考](apps/bitcask_cypher/doc/cypher-syntax-zh.md)：openCypher
  2024.3 对齐语法与 bitcask 扩展。

### 能力与约束

- [能力与约束](doc/capabilities-zh.md)：能力矩阵、一致性语义、文本 / 向量 /
  图 / Cypher 能力、构建能力与常见限制。

### 实用方法

- [使用指南](doc/USAGE.md)：常用读写、范围查询、原子批与事务、崩溃恢复、
  merge、过期、裸 NIF 调用和常见错误。
- [本地嵌入指南](doc/local-embedding-zh.md)：llama.cpp 后端、embedder 进程、
  CUDA / Vulkan 与诊断。
- [迁移工具](doc/migration.md)：旧目录迁移与特性状态。

## 许可证

Apache 2.0；详见 `LICENSE`。
