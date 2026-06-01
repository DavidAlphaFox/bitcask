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
// === 约束 ===
//   - 非线程安全：caller 负责并发控制
//   - ord 唯一且单调分配，不复用
//   - analyzer_ 在构造时创建，失败则整个 SearchLayer 创建失败

#pragma once

#include <cstdint>
#include <list>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <expected>
#include <vector>
#include "bitcask/analyzer.hpp"
#include "bitcask/highlighter.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/search_cache.hpp"

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
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_text(std::string_view query, std::size_t k,
                const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 搜索（短语模式）----
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_phrase(std::string_view query, std::size_t k,
                  const bm25::Bm25Params* params_override = nullptr) const;

    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    bool_search(std::string_view query, std::size_t k,
                const bm25::Bm25Params* params_override = nullptr) const;

    // ---- 多字段搜索（S8.6）----
    // 解析 `field:term^boost` 语法：有字段限定的词查对应字段索引，无限定的词
    // 查默认字段；各词得分 × boost，同一文档跨字段累加；返回 top-k。
    // 不含字段语法时等价于在默认字段做词袋搜索。
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_fields(std::string_view query, std::size_t k,
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

    // ---- 恢复：从磁盘 record 重放活文档 ----
    // 恢复文档到索引（全量 analyze + add_doc）。
    void recover_doc(std::string_view key, std::uint64_t ord,
                     std::string_view text,
                     std::uint32_t file_id, std::uint64_t offset,
                     std::uint32_t total_sz, std::uint32_t tstamp);

    // ---- 恢复：从磁盘 record 重放墓碑 ----
    void recover_tomb(std::string_view key, std::uint64_t ord);

    // ---- 快照持久化 ----
    [[nodiscard]] std::expected<void, std::string> save_snapshot(std::string_view path) const;

    // ---- 快照加载 ----
    [[nodiscard]] std::expected<bool, std::string> load_snapshot(std::string_view path);

    // 从磁盘重建倒排索引：遍历 Index 中所有 live 文档，通过 doc_reader 回调读取文本，
    // 重新分词并构建全新的 InvertedIndex，原子替换旧的。
    // doc_reader(file_id, offset, total_sz) → 返回文档文本，失败返回 std::nullopt。
    using DocReader = std::function<std::optional<std::string>(
        std::uint32_t, std::uint64_t, std::uint32_t)>;
    void rebuild_index(DocReader doc_reader);

    // ---- 访问内部组件（Phase 4 集成用）----
    [[nodiscard]] index::Index&       index()       { return index_; }
    [[nodiscard]] const index::Index& index() const { return index_; }

private:
    // 高亮原文 LRU（S9.3）：ord → 原文，带容量上限。只为高亮路径服务；
    // 冷文档被挤出后高亮降级为无片段，不影响 BM25 检索本身。
    // 非线程安全——与 SearchLayer 整体一致，由 caller 串行化。
    class DocTextLru {
    public:
        explicit DocTextLru(std::size_t cap) : cap_(cap) {}

        void put(std::uint64_t ord, std::string text) {
            if (cap_ == 0) return;
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

        // 命中返回原文指针并提升为最近使用；未命中返回 nullptr。
        const std::string* get(std::uint64_t ord) {
            auto it = map_.find(ord);
            if (it == map_.end()) return nullptr;
            lru_.splice(lru_.begin(), lru_, it->second);
            return &it->second->second;
        }

        void erase(std::uint64_t ord) {
            auto it = map_.find(ord);
            if (it == map_.end()) return;
            lru_.erase(it->second);
            map_.erase(it);
        }

        void clear() {
            lru_.clear();
            map_.clear();
        }

    private:
        std::size_t cap_;
        std::list<std::pair<std::uint64_t, std::string>> lru_;  // front=最近
        std::unordered_map<std::uint64_t,
            std::list<std::pair<std::uint64_t, std::string>>::iterator> map_;
    };

    // 取或建某字段的 InvertedIndex（S8.6 阶段2）。
    bm25::InvertedIndex& field_index(std::string_view field);
    // 取某字段的 InvertedIndex（只读，不存在返回 nullptr）。
    const bm25::InvertedIndex* field_index(std::string_view field) const;

    SearchLayerConfig  config_;
    index::Index      index_;
    // S8.6：每字段一个 InvertedIndex（字段间 avgdl/idf 隔离）。
    // 旧单 text 文档与无字段限定查询都走 kDefaultField。
    std::unordered_map<std::string, std::unique_ptr<bm25::InvertedIndex>> fields_;
    // R3：ord → (字段名 → 该字段 doc_len)，供 on_delete 按字段精确扣减统计。
    // 仅多字段路径填充；单 text 路径用 index_ 的 doc_len 即可（默认字段）。
    std::unordered_map<std::uint64_t,
                       std::vector<std::pair<std::string, std::uint32_t>>> ord_field_lens_;
    std::unique_ptr<text::Analyzer>      analyzer_;
    mutable SearchCache cache_;
    mutable DocTextLru  doc_texts_;   // mutable：const 查询路径里 get() 会提升 LRU 顺序
};

}  // namespace bitcask::search