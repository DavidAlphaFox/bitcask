// BM25 倒排索引（内存工作副本）。
//
// InvertedIndex 维护 term → PostingList[(ord, tf)] 的内存映射，
// 以及 BM25 所需的全局统计（N / sum_doc_len / avgdl）。
//
// === 数据流 ===
//   写入：analyzer 切词 → add_doc(ord, term_freqs) → 每个 term 追加 posting
//   删除：remove_doc(ord, term_freqs) → posting 标记删除（V2 靠 live 过滤）
//   查询：search(terms, k, live_checker) → DAAT 累加 BM25 → top-k 堆
//
// === 锁模型（§4）===
//   写入按 term hash 分片上 shared_mutex：写入只锁命中分片，不阻塞其他 term。
//   查询（search）持所有分片的 shared_lock（读）——并发写入不阻塞查询。
//
// === df 漂移 ===
//   V2 查询时过滤 live=0 的 ord，接受 df 轻微偏大。merge 时重算 df。

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bitcask::bm25 {

// 一条 posting 记录：文档 ord + 该 term 在文档中的词频。
struct Posting {
    std::uint64_t ord;
    std::uint32_t tf;
    std::vector<std::uint32_t> positions;
};

// 一个 term 对应的 posting 列表，按 ord 升序排列。
// 同一个 ord 不会出现两次（add_doc 保证）。
struct PostingList {
    std::vector<Posting> items;

    // 按 ord 查找（二分，用于 add_doc 去重 / remove_doc 定位）。
    [[nodiscard]] auto find(std::uint64_t ord) const -> std::size_t;
    [[nodiscard]] bool has(std::uint64_t ord) const;
};

// BM25 可调参数。
struct Bm25Params {
    float k1 = 1.2F;
    float b  = 0.75F;
};

using TermPositions = std::unordered_map<std::string, std::pair<std::uint32_t, std::vector<std::uint32_t>>>;

// 搜索结果条目。
struct SearchResult {
    std::uint64_t ord;
    float         score;
};

// live 文档检查器接口（由 Index 侧表提供）。
// search() 调用它跳过已删除的 ord。
class LiveChecker {
public:
    virtual ~LiveChecker() = default;
    [[nodiscard]] virtual bool is_live(std::uint64_t ord) const = 0;
    [[nodiscard]] virtual std::uint32_t doc_len(std::uint64_t ord) const = 0;
};

// 倒排索引。
class InvertedIndex {
public:
    InvertedIndex() = default;
    explicit InvertedIndex(Bm25Params params);

    // ---- 写 ----

    // 添加一篇文档的 posting。term_freqs 来自 analyzer。
    // 线程安全：按 term hash 分片锁。
    void add_doc(std::uint64_t ord, const TermPositions& term_data);

    // 删除一篇文档的 posting。V2 实际不删除 posting 行（靠 live 过滤），
    // 但减少 live_doc_count_ / sum_doc_len_ 以保持统计准确。
    void remove_doc(std::uint32_t doc_len,
                    const std::unordered_map<std::string, std::uint32_t>& term_freqs);

    // ---- 查询 ----

    // BM25 搜索：对 query terms 做 DAAT 累加，返回 top-k 结果。
    // live_checker 用于跳过已删文档并获取 doc_len。
    // 线程安全：持所有分片 shared_lock。
    [[nodiscard]] auto search(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        const LiveChecker& live_checker) const -> std::vector<SearchResult>;

    [[nodiscard]] auto search_phrase(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        const LiveChecker& live_checker) const -> std::vector<SearchResult>;

    auto save(std::string_view path) const -> bool;
    auto load(std::string_view path) -> bool;

    // ---- 统计 ----
    [[nodiscard]] auto live_doc_count() const -> std::uint64_t;
    [[nodiscard]] auto sum_doc_len() const -> std::uint64_t;
    [[nodiscard]] auto avg_doc_len() const -> double;

    // 调试：返回 term 的 df（posting list 长度，含死点）。
    [[nodiscard]] auto df(std::string_view term) const -> std::size_t;
    [[nodiscard]] auto df_live(std::string_view term, const LiveChecker& live_checker) const -> std::size_t;

private:
    static constexpr std::size_t kShardCount = 16;

    struct Shard {
        mutable std::shared_mutex mutex;
        std::unordered_map<std::string, PostingList> inverted;
    };

    std::array<Shard, kShardCount> shards_;
    Bm25Params params_;

    // 全局统计（用原子或独立 mutex 保护；V2 写路径串行，简单用 mutable）。
    mutable std::shared_mutex stats_mutex_;
    std::uint64_t live_doc_count_ = 0;
    std::uint64_t sum_doc_len_   = 0;

    [[nodiscard]] Shard& shard_for(std::string_view term);
    [[nodiscard]] const Shard& shard_for(std::string_view term) const;
};

}  // namespace bitcask::bm25
