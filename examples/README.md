# examples — Wikipedia 检索库示例（BM25 + 向量双模式）

用真实的 Wikipedia dump 构建「BM25 全文 + 向量近邻 + 混合 RRF」检索库的两个
示例，分别使用 v4.0.0 的两种向量引擎：

| 示例 | 引擎 | 定位 |
|------|------|------|
| `wiki_hnsw.escript` | `{vector_engine, hnsw}` | 内存图（默认档，≤ 数 M 向量） |
| `wiki_diskann.escript` | `{vector_engine, diskann}` | Vamana 盘上图（**实验性**） |

两个脚本只差 `vector_engine` 一个选项，全部逻辑在 `wiki_common.erl` 共享。

数据提取方案移植自 wiser-cpp（`~/workspace/wiser/wiser-cpp/src/`）：
SAX 流式解析 dump XML（expat → `xmerl_sax_parser`，十几 GB 的文件不进内存）、
wiki 标记两遍清洗（模板/表格/命名空间链接/URL 剥离 + 超长 ASCII run 防护，
`wiki_markup.cpp` 的正则近似移植）、key=标题 / 正文进 text / 标题进 title
字段（`indexer.cpp` 同款约定）。在此之上加了向量一路：open 配 embedder，
put 自动 embed 正文导语。

## 前置条件

1. **构建**：仓库根目录执行 `rebar3 compile`（产出
   `_build/default/lib/bitcask/ebin` 与 `priv/bitcask_cpp.so`）。
2. **embedding 服务**：任意 OpenAI 兼容的 `/v1/embeddings` 端点
   （vLLM / llama.cpp server / OpenAI 等均可）。
3. **Wikipedia dump**：`pages-articles` XML（从
   <https://dumps.wikimedia.org> 下载，如 `zhwiki-latest-pages-articles.xml`；
   `.bz2` 需先解压）。中文语料分词用 jieba（词典默认回退 `priv/dict`）。

## 环境变量

embedding 端点**不写死在代码里**，通过环境变量配置：

| 变量 | 必填 | 说明 |
|------|------|------|
| `WIKI_EMBED_URL` | **是** | OpenAI 兼容 `/v1/embeddings` 端点完整 URL |
| `WIKI_EMBED_MODEL` | 否 | 模型名，默认 `qwen3-embedding` |
| `WIKI_EMBED_DIM` | 否 | 向量维度，默认 `2560`；须与模型输出一致 |

```sh
export WIKI_EMBED_URL=http://<host>:<port>/v1/embeddings
# 换模型时同时指定名称与维度，例如：
# export WIKI_EMBED_MODEL=bge-m3
# export WIKI_EMBED_DIM=1024
```

注意：**同一个库从建库到查询必须用同一套 embedding 配置**——维度写进
`bitcask.meta`（不符拒开），且查询向量与入库向量必须出自同一模型才有意义。
三种查询模式都要求 `WIKI_EMBED_URL` 已设置（`bm25` 模式不发 embedding
请求，只是打开库需要维度信息）。

## 构建索引

```sh
cd examples

# BM25 + HNSW：扫描 dump 前 20000 个 <page>，建库到 /tmp/wikidb_hnsw
./wiki_hnsw.escript index -x /path/to/zhwiki-latest-pages-articles.xml \
                          -o /tmp/wikidb_hnsw -m 20000

# BM25 + DiskANN：同一份 dump，另一个目录
./wiki_diskann.escript index -x /path/to/zhwiki-latest-pages-articles.xml \
                             -o /tmp/wikidb_diskann -m 20000
```

- `-m N` 计的是扫过的 `<page>` 总数（缺省 500）；非主命名空间页（`<ns>≠0`，
  如 `Wikipedia:`/`Template:` 元页面）、重定向页、清洗后过短的页会被跳过，
  实际入库数 ≤ N（zhwiki 前 2 万页约七成是有效条目）。
- 每篇文档一次 embedding HTTP 调用，是建库耗时的主体；吞吐基本等于
  embedding 服务的推理速度。向量只 embed 清洗后正文的前 2KB（约 680 汉字）
  ——百科文章主题集中在导语，全文喂模型既慢又稀释主题向量；BM25 一路不受
  影响（全文进倒排）。
- 每 200 篇打一次进度并 sync 数据日志。

## 查询

```sh
# 混合检索（默认）：BM25 与向量两路做 RRF 融合
./wiki_hnsw.escript query /tmp/wikidb_hnsw "数学 几何"

# 纯向量语义近邻：无关键词重合也能命中
./wiki_hnsw.escript query /tmp/wikidb_hnsw "古代的哲学思想" --mode vector

# 纯 BM25 全文检索
./wiki_hnsw.escript query /tmp/wikidb_hnsw "文学 诗歌" --mode bm25

# DiskANN 库同理（脚本与库的引擎必须对应）
./wiki_diskann.escript query /tmp/wikidb_diskann "计算机如何存储信息" --mode vector
```

输出形如（对齐 wiser-cpp 的 query 输出；`score` 含义随模式：BM25 分、
余弦相似度、或 RRF 融合分）：

```
score: 0.5482  title: 哲学
    之死，由 雅克·路易·大卫 所繪（1787年） 哲學 是研究普遍、基本问题的領域…
Total 10 documents found (mode=vector, engine=hnsw).
```

构建尚未完成时也可以查询：bitcask 支持读写并发，只读打开基于已 sync
落盘的前缀重建索引。

## 注意

- **引擎在建库时固定**并持久化进 `bitcask.meta`：用 `wiki_hnsw.escript` 建的
  库不能用 `wiki_diskann.escript` 打开（`{error, mode_mismatch}`），反之亦然
  ——这正是 v4.0.0 `vector_engine` 的设计行为。离线切换用 libbitcask 的
  `vec_engine_migrate` 工具。
- 示例规模（数百到数万篇）达不到 `auto_checkpoint_min_docs=10000` 阈值时，
  reopen 走全量重放（jieba 重分词 + 从数据日志重读向量重建索引，**无**
  embedding 网络调用），数千篇秒级。
- `diskann` 为 v4.0.0 实验性引擎，要求 cosine/dot 度量（示例用默认 cosine）。
