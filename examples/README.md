# examples — Wikipedia 检索库示例（BM25 + 向量双模式）

用真实的 Wikipedia dump 构建「BM25 全文 + 向量近邻 + 混合 RRF」检索库的两个
示例，分别使用 v4.0.0 的两种向量引擎：

| 示例 | 引擎 | 定位 |
|------|------|------|
| `wiki_hnsw.escript` | `{vector_engine, hnsw}` | 内存图（默认档，≤ 数 M 向量） |
| `wiki_diskann.escript` | `{vector_engine, diskann}` | Vamana 盘上图（**实验性**） |

两个脚本只差 `vector_engine` 一个选项，全部逻辑在 `wiki_common.erl` 共享。

数据提取方案移植自 wiser-cpp（`~/workspace/wiser/wiser-cpp/src/`）：
SAX 流式解析 dump XML（expat → `xmerl_sax_parser`，14GB 文件不进内存）、
wiki 标记两遍清洗（模板/表格/命名空间链接/URL 剥离 + 超长 ASCII run 防护，
`wiki_markup.cpp` 的正则近似移植）、key=标题 / 正文进 text / 标题进 title
字段（`indexer.cpp` 同款约定）。在此之上加了向量一路：open 配 embedder，
put 自动 embed 正文。

## 前置条件

1. **构建**：仓库根目录 `rebar3 compile`（产出 `_build/default/lib/bitcask/ebin`
   与 `priv/bitcask_cpp.so`）。
2. **embedding 服务**：OpenAI 兼容 `/v1/embeddings` 端点，默认
   `http://192.168.186.1:8080/v1/embeddings`（qwen3-embedding，2560 维，已
   L2 归一化），用环境变量 `WIKI_EMBED_URL` 覆盖。
3. **Wikipedia dump**：`pages-articles` XML（如
   `zhwiki-latest-pages-articles.xml`）。中文语料，分词用 jieba
   （词典默认回退 `priv/dict`）。

## 用法

```sh
cd examples

# 建库：BM25 + HNSW（默认取前 500 篇有效文章；embedding 是主要耗时）
./wiki_hnsw.escript index -x /home/david/workspace/data/zhwiki-latest-pages-articles.xml \
                          -o /tmp/wikidb_hnsw -m 200

# 建库：BM25 + DiskANN（同一份 dump，另一个目录）
./wiki_diskann.escript index -x /home/david/workspace/data/zhwiki-latest-pages-articles.xml \
                             -o /tmp/wikidb_diskann -m 200

# 查询：三种模式（默认 hybrid = BM25 + 向量 RRF 融合）
./wiki_hnsw.escript query /tmp/wikidb_hnsw "数学 几何"                 # hybrid
./wiki_hnsw.escript query /tmp/wikidb_hnsw "古代哲学思想" --mode vector  # 纯向量语义
./wiki_hnsw.escript query /tmp/wikidb_hnsw "欧洲 历史" --mode bm25       # 纯 BM25
./wiki_diskann.escript query /tmp/wikidb_diskann "宇宙的起源" --mode vector
```

输出形如（对齐 wiser-cpp 的 query 输出）：

```
score: 0.0325  title: 数学
    数学 是研究数量 结构 变化以及空间等概念的一门学科 …
Total 10 documents found (mode=hybrid, engine=hnsw).
```

## 注意

- **引擎在建库时固定**并持久化进 `bitcask.meta`：用 `wiki_hnsw.escript` 建的库
  不能用 `wiki_diskann.escript` 打开（`{error, mode_mismatch}`），反之亦然——
  这正是 v4.0.0 `vector_engine` 的设计行为。离线切换用 libbitcask 的
  `vec_engine_migrate` 工具。
- `-m N` 计数的是 dump 中扫过的 `<page>` 总数；非主命名空间页（`<ns>≠0`，
  如 `Wikipedia:`/`Template:` 元页面）、重定向页、清洗后过短的页会被跳过
  （不值得花 embedding 调用），故实际入库数 ≤ N。
- 每篇文档一次 embedding HTTP 调用，是建库耗时的主体（BM25/向量索引本身
  在这个量级可忽略）。向量只 embed 清洗后正文的前 2KB（约 680 汉字）——
  百科文章主题集中在导语，全文喂 4B 模型既慢又稀释主题向量；BM25 一路
  不受影响（全文进倒排）。
- 示例规模（数百篇）达不到 `auto_checkpoint_min_docs=10000` 阈值，reopen 走
  全量重放（jieba 重分词 + 从数据日志重读向量重建图，无网络调用），秒级。
- `diskann` 为 v4.0.0 实验性引擎，且要求 cosine/dot 度量（示例用默认 cosine）。
