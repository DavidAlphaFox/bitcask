// SearchLayer — Index + InvertedIndex + Analyzer 封装层。
//
// 将 Collection 的 BM25 集成逻辑抽取为可复用组件，供 Phase 4 集成使用。
// SearchLayer 是独立模块，不依赖 Collection/Cask/KeyDir 等上层组件。
//
// === 数据流 ===
//   写入：on_write(key, ord, text, ...) → analyze_with_positions → index_.put_doc + inverted_->add_doc
//   删除：on_delete(key) → index_.get → inverted_->remove_doc → index_.remove
//   查询：search_text(query, k) → analyzer_->analyze → inverted_->search → ord_to_ext → SearchHit
//
// === 约束 ===
//   - 非线程安全：caller 负责并发控制（V1 由 Collection 单写者保证）
//   - ord 唯一且单调分配，不复用
//   - analyzer_ 在构造时创建，失败则整个 SearchLayer 创建失败

#pragma once

#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <expected>
#include <vector>
#include "bitcask/analyzer.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"

namespace bitcask::search {

// SearchLayer 配置。
struct SearchLayerConfig {
    text::AnalyzerConfig analyzer_config;
    bm25::Bm25Params     bm25_params;
};

// 搜索结果条目。
struct SearchHit {
    std::string   key;   // 外部 key（由 caller 通过 index_.ord_to_ext 翻译）
    std::uint64_t ord;   // 文档 ord
    double        score; // BM25 分数
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
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_text(std::string_view query, std::size_t k) const;

    // ---- 搜索（短语模式）----
    [[nodiscard]] std::expected<std::vector<SearchHit>, std::string>
    search_phrase(std::string_view query, std::size_t k) const;

    // ---- 恢复：从磁盘 record 重放活文档 ----
    // 与 Collection::recover 逻辑相同（全量 analyze + add_doc）。
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

    // ---- 访问内部组件（Phase 4 集成用）----
    [[nodiscard]] index::Index&       index()       { return index_; }
    [[nodiscard]] const index::Index& index() const { return index_; }

private:
    SearchLayerConfig  config_;
    index::Index      index_;
    std::unique_ptr<bm25::InvertedIndex> inverted_;
    std::unique_ptr<text::Analyzer>      analyzer_;
};

}  // namespace bitcask::search