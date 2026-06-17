// SearchLayer — Index + InvertedIndex + Analyzer 封装层。
//
// 将 BM25 集成逻辑抽取为可复用组件，供 Phase 4 集成使用。
// SearchLayer 是独立模块，不依赖 Collection/Cask/KeyDir 等上层组件。
//
// === 数据流 ===
//   写入：on_write(key, ord, text, ...) → analyze_with_positions → index_.put_doc + inverted_->add_doc
//   删除：on_delete(key) → index_.get → inverted_->remove_doc → index_.remove
//   查询：search_text(query, k) → analyzer_->analyze → inverted_->search → ord_to_ext → SearchHit
//
// === 约束(线程模型,C1 修订)===
//   - 生产形态:单写者(IndexPool worker 串行消费 on_write/on_delete)
//     + 多读者(查询线程)。曾声明"非线程安全,caller 串行化",与实际
//     使用不符——TSan 全插桩后实测修复了 fields_ map 并发 emplace/find
//     与 DocTextLru 并发 put/get 两处真竞态;现 fields_(shared_mutex)、
//     doc_texts_(内置 mutex)、cache_(shared_mutex)、index_/InvertedIndex
//     (自带锁/分片)在该模型下安全。**多写者仍未支持**。
//   - ord 唯一且单调分配，不复用
//   - analyzer_ 在构造时创建，失败则整个 SearchLayer 创建失败

#pragma once

#include <cstdint>
#include <expected>
#include <list>
#include <memory>
#include <optional>
#include <mutex>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include "bitcask/analyzer.hpp"
#include "bitcask/highlighter.hpp"
#include "bitcask/hnsw.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/meta_file.hpp"
#include "bitcask/meta_filter.hpp"  // V5：filter 表达树 + MetaOp/MetaCondition
#include "bitcask/search_cache.hpp"
#include "bitcask/synonym_map.hpp"

namespace bitcask::search {

// 默认字段名（S8.6）：旧单 text 文档 / 无字段限定查询都映射到此字段，
// 使新旧路径收敛。用不可见控制字符前缀避免与用户字段名冲突。
inline constexpr std::string_view kDefaultField = "\x01default";

// SearchLayer 配置。
struct SearchLayerConfig {
    text::AnalyzerConfig analyzer_config;
    bm25::Bm25Params     bm25_params;
    std::size_t          cache_max_entries = 256;  // 缓存最大条目数，0 禁用
    // 高亮原文 LRU 上限（S9.3）：只缓存最近写入/查询的文档原文，避免全文常驻。
    // 0 表示不缓存（高亮恒拿不到原文 → 降级为无片段），默认 1024 篇。
    std::size_t          doc_text_cache_max = 1024;
    // 是否索引词位置（S10.10）。默认 true。置 false 时倒排不存 positions，
    // 大幅省内存——代价：search_phrase / search_near 失效（无位置可匹配，返回空）。
    // 仅做 search_text/bool/fuzzy/wildcard 的部署可关闭。
    bool                 index_positions = true;
    // V3.3:向量配置(Cask::open 从 meta 透传)。dim>0 时构造 HnswIndex;
    // metric 映射:kCosineNormalized/kDot → HnswMetric::kDot(cosine 已在
    // 写入端归一化),kL2 → kL2。
    std::uint16_t        vector_dim = 0;
    meta::VectorMetric   vector_metric = meta::VectorMetric::kNone;
    // P5b:HNSW int8-only 内存模式(Cask::open 从 meta 透传)。仅 kDot。
    bool                 vector_inmem_int8 = false;
    // V6.2:WAL 批量刷新阈值。1 = 即时模式(默认,与旧版行为完全一致)。
    // >1 时积攒 entries 缓冲后单次 fwrite+fflush,减少 sync 调用次数。
    std::size_t          wal_batch_size = 1;
};

// 搜索结果条目。
struct SearchHit {
    std::string   key;   // 外部 key（由 caller 通过 index_.ord_to_ext 翻译）
    std::uint64_t ord;   // 文档 ord
    double        score; // BM25 分数
};

// 带高亮的搜索结果。
struct SearchHitEx {
    std::string              key;
    std::uint64_t            ord;
    double                   score;
    std::vector<Snippet>     highlights;
};

class SearchLayer {
public:
    // 构造 analyzer（可能因无效配置失败）。caller 应检查返回值。
    explicit SearchLayer(const SearchLayerConfig& config);

    // 禁止拷贝（Index 内部含共享状态）。
    SearchLayer(const SearchLayer&) = delete;
    SearchLayer& operator=(const SearchLayer&) = delete;

    // analyzer 是否构造成功。analyzer_config 无效 / 分词器未注册 /
    // 词典加载失败时为 false——caller（Cask::open）必须检查并拒绝打开，
    // 否则首次带 text 的 put 会解空指针段错误。
    [[nodiscard]] bool has_analyzer() const noexcept { return analyzer_ != nullptr; }

    // ---- 文档写入：建立索引 ----
    // key: 外部 key, ord: 文档序号, text: 文档文本,
    // file_id/offset/total_sz: 存储定位, tstamp: 时间戳
    void on_write(std::string_view key, std::uint64_t ord,
                  std::string_view text,
                  std::uint32_t file_id, std::uint64_t offset,
                  std::uint32_t total_sz, std::uint32_t tstamp);

    // ---- 多字段写入（S8.6）----
    // fields: (字段名, 文本) 列表，每字段独立分词建索引。空字段名映射到默认字段。
    void on_write_fields(std::string_view key, std::uint64_t ord,
                         const std::vector<std::pair<std::string, std::string>>& fields,
                         std::uint32_t file_id, std::uint64_t offset,
                         std::uint32_t total_sz, std::uint32_t tstamp);

    // ---- 文档删除：移除索引 ----
    // key: 要删除的 key
    // tomb_ord: 墓碑 record 的 ord（用于 index_.remove）
    // 返回被删除文档的 ord（用于 caller 跟踪）；key 不存在返回 nullopt。
    std::optional<std::uint64_t> on_delete(std::string_view key, std::uint64_t tomb_ord);

    // ---- merge 后重定位：ord 不变，只更新存储定位 ----
    void on_relocate(std::string_view key, std::uint64_t ord,
                     std::uint32_t new_file_id, std::uint64_t new_offset,
                     std::uint32_t new_total_sz);

    // ---- 搜索（词袋模式）----
    // params_override 非空时按查询覆盖默认 BM25 k1/b（S8.5）。
    // V5:filter 非空时从倒排 overfetch K'=max(k×4, 64) 再过滤截断到 k;
    // 因为 BM25 评分的得分排序在 filter 之前,需要更多候选弥补过滤损耗。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_text(std::string_view query, std::size_t k,
                const bm25::Bm25Params* params_override = nullptr,
                const meta::MetaFilter* filter = nullptr) const;

    // ---- 搜索（短语模式）----
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_phrase(std::string_view query, std::size_t k,
                  const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 搜索（近邻模式，S8.7）----
    // term 按 query 词序出现且相邻间隙 ≤ slop。slop=0 等价短语。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_near(std::string_view query, std::uint32_t slop, std::size_t k,
                const bm25::Bm25Params* params_override = nullptr) const;

    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    bool_search(std::string_view query, std::size_t k,
                const bm25::Bm25Params* params_override = nullptr) const;

    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_fuzzy(std::string_view query, std::size_t k, std::uint32_t max_edit_distance,
                 const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 多字段搜索（S8.6）----
    // 解析 `field:term^boost` 语法：有字段限定的词查对应字段索引，无限定的词
    // 查默认字段；各词得分 × boost，同一文档跨字段累加；返回 top-k。
    // 不含字段语法时等价于在默认字段做词袋搜索。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_fields(std::string_view query, std::size_t k,
                  const bm25::Bm25Params* params_override = nullptr) const;

    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_wildcard(std::string_view pattern, std::size_t k,
                    const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 评分解释（S8.8，调试/调优）----
    // 解释 query 对外部 key 文档的 BM25 评分分项。key 不存在返回 nullopt。
    [[nodiscard]] std::optional<bm25::ScoreExplanation>
    explain(std::string_view query, std::string_view key,
            const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 搜索（带高亮）----
    [[nodiscard]] std::expected<std::vector<SearchHitEx>, std::string>
    search_text_highlight(std::string_view query, std::size_t k,
                          const HighlightOptions& opts = {}) const;

    void set_synonym_map(std::unique_ptr<text::SynonymMap> map);

    // ---- V3.3:向量写入(IndexPool worker 线程,单写者)----
    // hnsw_ 存在且 vec.size()==配置 dim 才 insert;不符直接忽略(防御,
    // 不崩)。水位幂等由 HnswIndex 保证(回放重叠区安全)。
    void on_vector(std::uint64_t ord, std::span<const float> vec);

    // ---- HNSW 大小 + merge 重建 ----
    // 图节点数(含软删死节点;测试/观测用)。无向量配置 = 0。
    [[nodiscard]] std::size_t hnsw_size() const;
    // merge 重建(物理清除死节点)。**只能由 IndexPool worker 执行**
    // (与 on_vector 同线程 → 维持 HNSW 单写者约束):新建同 config 图,
    // 遍历旧图节点,跳过 !index_.is_live(ord),重插活节点,完毕原子换
    // 指针。重建期间查询走旧图(含死节点,结果语义不变);换入后旧图由
    // 在途读者的 shared_ptr 引用计数续命。
    void rebuild_hnsw();

    // ---- V3.3:向量查询(线程安全)----
    // cosine 配置时内部归一化查询向量(零向量返回空);ef=0 → max(k,64)。
    // 结果经 index_.is_live 过滤死文档,翻译为 SearchHit{key,ord,score}。
    // V5:filter 非空时与 is_live 组合为 HNSW live callback — 拒节点从
    // 图遍历源头就不入候选集,无需 overfetch。结果可能少于 k(filter
    // 通过率低时),符合「filter 收紧 live」语义。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_vector(std::span<const float> query, std::size_t k,
                  std::size_t ef = 0,
                  const meta::MetaFilter* filter = nullptr) const;

    // ---- V3.6:RRF 混合检索(hnsw-design §4)----
    // 两路各取 K' = max(k×4, 64):BM25 词袋走 search_text 内核,向量走
    // search_vector 内核(查询归一化/live 过滤/ord 翻译全部复用)。融合:
    //   score(doc) = Σ_路 1/(60 + rank_路),rank 从 1 起;
    // 单路出现的文档照常只累加该路项,无需分数归一化。**确定性平局序**:
    // RRF 分相等 → ord 小者在前。text_query 空 → 纯向量(BM25 路空);
    // vec_query 空 → 纯文本(RRF 重打分);两路都空 → 错误。vec 维度
    // 不符 → 错误(经 search_vector)。返回 score = RRF 分。
    // V5:filter 同时作用于两条路(text 路 overfetch 后过滤;vec 路
    // 折进 HNSW live callback);只有同时通过两路 filter 的文档进 RRF 融合。
    // 线程安全:同两条内核(text 路同 search_text,vec 路同 search_vector)。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_hybrid(std::string_view text_query,
                  std::span<const float> vec_query, std::size_t k,
                  const meta::MetaFilter* filter = nullptr) const;

    // ---- 恢复：从磁盘 record 重放活文档 ----
    // 恢复文档到索引（全量 analyze + add_doc）。
    // V3.3:vector 非空时顺路重建 HNSW(on_vector;水位幂等保证重放安全)。
    void recover_doc(std::string_view key, std::uint64_t ord,
                     std::string_view text,
                     std::uint32_t file_id, std::uint64_t offset,
                     std::uint32_t total_sz, std::uint32_t tstamp,
                     std::span<const float> vector = {});

    // ---- 恢复：从磁盘 record 重放墓碑 ----
    void recover_tomb(std::string_view key, std::uint64_t ord);

    // P14e:docmap 序列化到/自字节缓冲(供 search.ckpt 分段)。
    // serialize 返回 false 仅当某 ext 超 64KiB;
    // deserialize 校验失败返回 nullopt,成功返回 covers。
    [[nodiscard]] bool serialize_docmap(std::vector<std::uint8_t>& out,
                                        std::uint64_t covers_next_ord) const;
    [[nodiscard]] std::optional<std::uint64_t>
    deserialize_docmap(std::span<const std::uint8_t> bytes);

    // ---- P14e:统一分段 search.ckpt 持久化 ----
    // save_search_ckpt: 序列化所有索引段（docmap/bm25.default/bm25.fields/
    // hnsw）写入单个 search.ckpt，并做 .prev 代际回退。watermark = 保存时
    // 的 next_ord（覆盖上界）。caller 须先排干 IndexPool（写者静止点）。
    // 返回 false = 序列化或写入失败（best-effort，caller 不阻断）。
    [[nodiscard]] bool save_search_ckpt(std::string_view path,
                                        std::uint64_t watermark);

    // load_search_ckpt 结果。
    struct CkptLoadResult {
        bool loaded         = false;  // search.ckpt（或 .prev）结构完整
        std::uint64_t watermark = 0;   // 快照覆盖的 next_ord 上界
        bool all_segments_ok = false;  // 全段 CRC 通过 → 可走快路径
    };
    // 读 search.ckpt → 逐段校验 CRC → 分发到各反序列化器。
    // 结构损坏 → 尝试 .prev；都失败 → loaded=false（全量 fold 兜底）。
    // 段 CRC 失败 → 该段内存为空（fold 时重建），其余段照常载入。
    [[nodiscard]] CkptLoadResult load_search_ckpt(std::string_view path);

    // 从磁盘重建倒排索引：遍历 Index 中所有 live 文档，通过 doc_reader 回调读取文本，
    // 重新分词并构建全新的 InvertedIndex，原子替换旧的。
    // doc_reader(file_id, offset, total_sz) → 返回文档文本，失败返回 std::nullopt。
    using DocReader = std::function<std::optional<std::string>(
        std::uint32_t, std::uint64_t, std::uint32_t)>;
    void rebuild_index(DocReader doc_reader);

    // 死点压实（S10.11）：对各字段倒排里死点占比 ≥ threshold 的 posting list，
    // 用 index_（LiveChecker）重建只留 live ord，回收高 churn 累积的死点。
    // 比 rebuild_index 轻（不重读磁盘、不重新分词）；分数无关。返回压实的 list 数。
    std::size_t compact(double dead_ratio_threshold = 0.5);

    std::uint64_t compact_index_chunks() { return index_.compact_chunks(); }

    // ---- 访问内部组件（Phase 4 集成用）----
    [[nodiscard]] index::Index&       index()       { return index_; }
    [[nodiscard]] const index::Index& index() const { return index_; }

    // V4:Index 概要(totlive / total_ords),Cask::needs_merge 据此算
    // dead_doc_rate。无索引时 = IndexInfo 零值。
    [[nodiscard]] index::IndexInfo index_info() const { return index_.info(); }

private:
    // 高亮原文 LRU（S9.3）：ord → 原文，带容量上限。只为高亮路径服务；
    // 冷文档被挤出后高亮降级为无片段，不影响 BM25 检索本身。
    // C1:内置 mutex——IndexPool 工作线程 put 与查询线程 get(高亮)并发,
    // TSan 降噪后实测捕获竞态;原"caller 串行化"假设与生产线程模型不符。
    // get 返回拷贝而非内部指针:旧接口指针在锁外可被并发淘汰释放(UAF 窗口)。
    class DocTextLru {
    public:
        explicit DocTextLru(std::size_t cap) : cap_(cap) {}

        void put(std::uint64_t ord, std::string text) {
            if (cap_ == 0) return;
            std::lock_guard<std::mutex> lk(mu_);
            if (auto it = map_.find(ord); it != map_.end()) {
                it->second->second = std::move(text);
                lru_.splice(lru_.begin(), lru_, it->second);
                return;
            }
            lru_.emplace_front(ord, std::move(text));
            map_[ord] = lru_.begin();
            while (lru_.size() > cap_) {
                map_.erase(lru_.back().first);
                lru_.pop_back();
            }
        }

        // 命中返回原文拷贝并提升为最近使用；未命中返回 nullopt。
        std::optional<std::string> get(std::uint64_t ord) {
            std::lock_guard<std::mutex> lk(mu_);
            auto it = map_.find(ord);
            if (it == map_.end()) return std::nullopt;
            lru_.splice(lru_.begin(), lru_, it->second);
            return it->second->second;
        }

        void erase(std::uint64_t ord) {
            std::lock_guard<std::mutex> lk(mu_);
            auto it = map_.find(ord);
            if (it == map_.end()) return;
            lru_.erase(it->second);
            map_.erase(it);
        }

        void clear() {
            std::lock_guard<std::mutex> lk(mu_);
            lru_.clear();
            map_.clear();
        }

    private:
        std::size_t cap_;
        std::list<std::pair<std::uint64_t, std::string>> lru_;  // front=最近
        std::unordered_map<std::uint64_t,
            std::list<std::pair<std::uint64_t, std::string>>::iterator> map_;
        std::mutex mu_;
    };

    // 取或建某字段的 InvertedIndex（S8.6 阶段2）。
    bm25::InvertedIndex& field_index(std::string_view field);
    // 取某字段的 InvertedIndex（只读，不存在返回 nullptr）。
    const bm25::InvertedIndex* field_index(std::string_view field) const;

    SearchLayerConfig  config_;
    index::Index      index_;
    // S8.6：每字段一个 InvertedIndex（字段间 avgdl/idf 隔离）。
    // 旧单 text 文档与无字段限定查询都走 kDefaultField。
    // O8：透明 hash——field_index 查找直接吃 string_view，免临时 string。
    // C1:fields_mu_ 保护 map 结构——IndexPool 工作线程首次写入新字段会
    // emplace,与查询线程的 find 并发(TSan 降噪后实测捕获的真竞态)。
    // InvertedIndex 本体地址稳定(unique_ptr)且内部自带分片并发,
    // 锁只管 map;引用/指针可出锁使用。
    mutable std::shared_mutex fields_mu_;
    std::unordered_map<std::string, std::unique_ptr<bm25::InvertedIndex>,
                       StringHash, std::equal_to<>> fields_;
    // R3：ord → (字段名 → 该字段 doc_len)，供 on_delete 按字段精确扣减统计。
    // 仅多字段路径填充；单 text 路径用 index_ 的 doc_len 即可（默认字段）。
    std::unordered_map<std::uint64_t,
                       std::vector<std::pair<std::string, std::uint32_t>>> ord_field_lens_;
    std::unique_ptr<text::Analyzer>      analyzer_;
    // V3.3:HNSW 向量索引(config.vector_dim>0 时创建)。单写者
    // (IndexPool worker 的 on_vector/recover_doc/rebuild_hnsw)+ 多读者
    // (search_vector)并发安全,协议见 hnsw.hpp。
    // V3.5:atomic<shared_ptr>——merge 重建以"新图旁路构建 + 原子换指针"
    // 实现,读者每次操作开头 load 一次快照指针,旧图由引用计数续命;
    // 写路径(worker 单线程)同样经 load 取图。指针仅在构造与
    // rebuild_hnsw 的换入点变更。
    std::atomic<std::shared_ptr<vec::HnswIndex>> hnsw_;
    mutable SearchCache cache_;
    mutable DocTextLru  doc_texts_;
    std::unique_ptr<text::SynonymMap> synonym_map_;
};

}  // namespace bitcask::search