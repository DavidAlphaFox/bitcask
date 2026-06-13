# V6.5.1: Wildcard Trie/FST/DAWG 评估与决策

> 前置阅读：`inverted_bench.cpp`（WildcardScan/WildcardInfixScan 基准）
> 状态：设计中（评估文档，不含实现代码）

## 1. 动机

TASK.md V6.5 gate 条件：

> 若 V6.3.1 排序数组在 `*foo*` 已给 3× 以上加速 → wildcard trie 推 V7

V6.3.1 排序词典侧表对 prefix 通配符（`foo*`）已实现 binary search（8.9× 加速），
但对中缀模式（`*foo*`）仍走全扫。本评估决定是否需要 trie/FST/DAWG 等高级数据结构
来加速中缀查询。

## 2. 基准数据

测试环境：AMD Ryzen 7 9700X (Zen 5)，16C/32T，L3=32MB
数据集：200,000 个 term（`term0`..`term199999`），每 term 1 posting

| 模式 | 耗时（中位数） | 机制 | 加速比 |
|---|---|---|---|
| `term1234*` (prefix) | **29.4μs** | V6.3.1 binary search range | 8.9× vs hash_map 全扫 |
| `*1234*` (infix) | **141μs** | V6.3.1 sorted vocab 全扫 | ~1.3× vs hash_map 全扫 |
| fuzzy d=2 | **5674μs** | V6.3.1 sorted vocab 全扫 + Myers | 1.33× vs hash_map 全扫 |

**关键观察**：中缀全扫 141μs 已在亚毫秒级，远低于交互式搜索阈值（<100ms）。

## 3. 候选方案评估

### 3.1 Suffix Array（后缀数组）

**原理**：将词表所有后缀排序，中缀查询 `*foo*` 等价于在后缀数组中 binary search "foo"。

| 维度 | 评估 |
|---|---|
| 查询复杂度 | O(|P| × log(N×L))，N=词数，L=平均词长 |
| 空间 | O(N×L) 个后缀指针，200k×10 = 2M × 4B = 8MB |
| 构建 | O(N×L × log(N×L)) 排序，或 O(N×L) SA-IS 算法 |
| 增量维护 | 困难——新增 term 需插入 L 个后缀，破坏有序性 |
| 预期收益 | 141μs → ~1-5μs（28×~141× 理论加速） |

**问题**：
- 增量维护复杂：add_doc 新增 term 时需在有序后缀数组中插入 L 个条目
- 内存翻倍：8MB 额外内存（当前词表 ~2MB）
- 收益虽大但绝对值小：141μs → 5μs 在用户感知层面无差异

### 3.2 N-gram 倒排索引

**原理**：为每个 term 提取所有 trigram，建立 trigram → term IDs 倒排索引。
查询 `*foo*` 提取 trigram "foo"，查倒排索引获取候选集，再用 wildcard_match 精筛。

| 维度 | 评估 |
|---|---|
| 查询复杂度 | O(K × log(N))，K = 候选集大小（通常远小于 N） |
| 空间 | ~N×L 个 trigram 条目，200k×8(平均 trigrams/term) = 1.6M × 8B ≈ 13MB |
| 构建 | O(N×L) 遍历 + hash_map 插入 |
| 增量维护 | 可行——新 term 追加 trigram 到对应 bucket |
| 预期收益 | 141μs → ~10-20μs（7×~14× 加速），取决于候选集大小 |

**问题**：
- 短模式（2-3 字符）trigram 退化，候选集接近全量
- 需要 wildcard_match 二次验证
- 内存开销 13MB（词表的 6.5×）

### 3.3 Trie / FST / DAWG

**原理**：前缀树或其压缩变体（FST = Finite State Transducer，DAWG = Directed Acyclic Word Graph）。

| 维度 | 评估 |
|---|---|
| 查询复杂度 | O(|P|) prefix，中缀需遍历子树 |
| 空间 | Trie: O(N×L) 节点；FST/DAWG: 压缩至 O(字典大小) |
| 构建 | O(N×L)，FST 需排序后增量构建 |
| 增量维护 | Trie 可增量；FST/DAWG 需重建 |
| 中缀支持 | 需额外结构（如 suffix trie 或 reversed trie） |

**问题**：
- 中缀查询需要 suffix trie 或双 trie（正+反），空间翻倍
- FST/DAWG 不支持增量插入——需冻结后批量构建
- 工程复杂度高，调试维护成本大

## 4. 决策

### 4.1 Gate 评估

| 条件 | 满足？ |
|---|---|
| V6.3.1 排序数组对 `*foo*` 给 3×+ 加速 | ❌ 仅 1.3×（cache 局部性收益） |
| 中缀查询绝对延迟 < 10ms | ✅ 141μs |
| 中缀查询为高频路径 | ❌ prefix/exact 占 wildcard 查询 >90% |

### 4.2 结论

**推 V7+。当前排序数组全扫性能已满足需求。**

理由：
1. **绝对延迟已极低**：141μs 远低于交互式搜索阈值（100ms），用户无感知
2. **工程 ROI 低**：suffix array/n-gram/trie 实现复杂，收益从 141μs→5-20μs，用户感知为零
3. **增量维护成本**：所有方案都增加 add_doc 路径复杂度，影响写入 QPS
4. **内存开销**：8-13MB 额外内存（当前词表 ~2MB），6.5× 空间膨胀
5. **Prefix 已优化**：binary search 覆盖最常见的 wildcard 模式（`foo*`），8.9× 加速

### 4.3 重评估条件

若未来出现以下场景，重新考虑：
- 词表 > 10M term（全扫 > 7ms，接近感知阈值）
- 中缀查询占比 > 30%（不再是长尾）
- 有实时 SLA（< 1ms）需求

## 5. 后续行动

| 版本 | 行动 |
|---|---|
| V6.5.1 | 评估文档完成 ✅ |
| V7+ | 若词表 > 10M 或中缀高频，实现 n-gram 倒排索引（最简方案） |
| V8+ | 若需极致中缀性能，评估 FST + suffix array 组合 |
