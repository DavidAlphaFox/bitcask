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
// === 锁模型（§4） ===
//   写入按 term hash 分片，tbb::concurrent_hash_map 提供桶级锁。
//   查询（search）无锁读——concurrent_hash_map 支持并发迭代。
//   全局统计（live_doc_count_ / sum_doc_len_）用 atomic（S10.1，去锁）。
//
// === df 漂移 ===
//   V2 查询时过滤 live=0 的 ord，接受 df 轻微偏大。merge 时重算 df。

#pragma once

#include <oneapi/tbb/concurrent_hash_map.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "bitcask/fuzzy_matcher.hpp"
#include "bitcask/query.hpp"
#include "bitcask/vbyte.hpp"
#include "bitcask/inverted_wal.hpp"

namespace bitcask::bm25 {

// BM25 可调参数。
struct Bm25Params {
    float k1 = 1.2F;
    float b  = 0.75F;
    // BM25+ 的下界常数 δ（S8.10）：每个在文档中出现的 term 的 tf 归一化项加 δ，
    // 缓解标准 BM25 对长文档的过度惩罚（Lv & Zhai 2011）。
    // 默认 0 = 标准 BM25（向后兼容）。典型值 1.0。
    float delta = 0.0F;
};

// Posting 分块元数据（Block-Max WAND 跳跃索引）。
struct PostingBlock {
    std::uint64_t base_ord;
    std::uint64_t end_ord;
    std::uint32_t max_tf;
    std::size_t   start_idx;
    std::size_t   count;
};

// 一条 posting 记录：文档 ord + 该 term 在文档中的词频。
struct Posting {
    std::uint64_t ord;
    std::uint32_t tf;
    std::vector<std::uint32_t> positions;
};

// 一个 term 对应的 posting 列表，按 ord 升序排列。
// 同一个 ord 不会出现两次（add_doc 保证）。
struct PostingList {
    static constexpr std::size_t kBlockSize = 128;

    std::vector<Posting> items;

    // VByte 压缩 ord 存储（finalize 后使用）。
    std::vector<std::uint8_t> compressed_ords;
    bool finalized = false;

    // Block-Max WAND 跳跃索引（finalize 后计算）。
    std::vector<PostingBlock> blocks;

    // 全局最大 tf 缓存（S10.9）：block_upper_bound 此前每次重扫全 items 求最大 tf；
    // 改为增量维护（note_appended 追加时更新，load 后重算），查询直接读。
    std::uint32_t max_tf = 0;

    // 压缩所有 ord 为 VByte gap 编码，并计算块元数据。
    void finalize() {
        if (items.empty() || finalized) return;
        std::vector<std::uint64_t> ords;
        ords.reserve(items.size());
        for (auto& p : items) ords.push_back(p.ord);
        compressed_ords = codec::gap_encode(ords);
        finalized = true;

        // 计算 Block-Max WAND 元数据。S10.6：先 clear——增量封块（seal_full_blocks）
        // 可能已建若干满块，这里重建为含「部分尾块」的规范集（覆盖之），避免重复追加。
        blocks.clear();
        if (items.size() >= kBlockSize) {
            std::size_t n = items.size();
            std::size_t block_count = (n + kBlockSize - 1) / kBlockSize;
            blocks.reserve(block_count);
            for (std::size_t b = 0; b < block_count; ++b) {
                std::size_t start = b * kBlockSize;
                std::size_t end = std::min(start + kBlockSize, n);
                std::uint64_t base = items[start].ord;
                std::uint64_t last = items[end - 1].ord;
                std::uint32_t max_tf = 0;
                for (std::size_t i = start; i < end; ++i) {
                    if (items[i].tf > max_tf) max_tf = items[i].tf;
                }
                blocks.push_back({base, last, max_tf, start, end - start});
            }
        }
    }

    // 增量封块（S10.6）：把已攒满 kBlockSize 的整块封进 blocks，尾部不足一块不封。
    // ord 单调递增（alloc_ord 全局递增）→ 新 posting 必落在末尾，O(1) 摊还。
    // 不变量：增量阶段 blocks 仅含满块（count==kBlockSize）；部分尾块只由 finalize 产生。
    void seal_full_blocks() {
        std::size_t sealed = blocks.size() * kBlockSize;
        while (items.size() - sealed >= kBlockSize) {
            std::size_t start = sealed;
            std::size_t end = start + kBlockSize;
            std::uint32_t max_tf = 0;
            for (std::size_t i = start; i < end; ++i) {
                if (items[i].tf > max_tf) max_tf = items[i].tf;
            }
            blocks.push_back({items[start].ord, items[end - 1].ord, max_tf, start, kBlockSize});
            sealed += kBlockSize;
        }
    }

    // add_doc 追加一条 posting 后调用（S10.6）：让在线索引也具备 WAND 块跳跃。
    void note_appended() {
        // S10.9：增量维护全局 max_tf（新 posting 必在末尾）。
        if (!items.empty() && items.back().tf > max_tf) max_tf = items.back().tf;
        // 之前 finalize 过：压缩 ord 失效，decompress_ords 退回 items 源（保证正确）。
        if (finalized) {
            finalized = false;
            compressed_ords.clear();
        }
        // finalize 可能留下不满的尾块；增量封块要求 blocks 仅含满块，先弹掉它。
        if (!blocks.empty() && blocks.back().count < kBlockSize) {
            blocks.pop_back();
        }
        seal_full_blocks();
    }

    // 死点压实（S10.11）：删除 is_live(ord)==false 的 posting，重建派生态。
    // items 原本按 ord 升序，过滤保序 → 压实后仍有序。返回是否实际删了。
    // 分数无关：live_df/idf/avgdl 都只数 live，压实只是不再扫死点。
    template <typename IsLive>
    bool compact(const IsLive& is_live) {
        std::vector<Posting> kept;
        kept.reserve(items.size());
        for (auto& p : items) {
            if (is_live(p.ord)) kept.push_back(std::move(p));
        }
        if (kept.size() == items.size()) return false;  // 无死点，不动
        items = std::move(kept);
        // 重建派生态（compressed_ords/finalized/blocks/max_tf）。
        compressed_ords.clear();
        finalized = false;
        blocks.clear();
        max_tf = 0;
        for (auto& p : items) {
            if (p.tf > max_tf) max_tf = p.tf;
        }
        seal_full_blocks();  // 仅封满块（与增量一致，尾部留给后续 finalize）
        return true;
    }

    // 返回 ord 数组。items[].ord 恒为事实来源（load 已回填，见 inverted.cpp
    // load 的 comp==1 分支），直接复制即可，不必走 VByte 解码（O3：原 finalized
    // 路径每次查询都全量 gap_decode，纯浪费）。compressed_ords 只服务落盘格式。
    [[nodiscard]] std::vector<std::uint64_t> decompress_ords() const {
        std::vector<std::uint64_t> ords;
        ords.reserve(items.size());
        for (auto& p : items) ords.push_back(p.ord);
        return ords;
    }

    // 按 ord 查找（二分，用于 add_doc 去重 / remove_doc 定位）。
    [[nodiscard]] auto find(std::uint64_t ord) const -> std::size_t;
    [[nodiscard]] bool has(std::uint64_t ord) const;

    // 返回包含指定 ord 的块（binary search）。
    [[nodiscard]] auto block_for_ord(std::uint64_t ord) const -> const PostingBlock*;

    // 计算该 posting list 的全局上界分数（用于 WAND剪枝）。
    [[nodiscard]] auto block_upper_bound(float idf, const Bm25Params& params, double avgdl) const -> float;
};

using TermPositions = std::unordered_map<std::string, std::pair<std::uint32_t, std::vector<std::uint32_t>>>;

// 搜索结果条目。
struct SearchResult {
    std::uint64_t ord;
    float         score;
};

// BM25 评分解释的单 term 分项（S8.8）。
struct TermScore {
    std::string   term;
    std::size_t   df        = 0;   // live document frequency
    double        idf       = 0.0; // log(1 + (N - df + 0.5)/(df + 0.5))
    std::uint32_t tf        = 0;   // 该 term 在目标文档中的词频（不在文档则 0）
    float         tf_norm   = 0.0F;// tf 长度归一化项
    float         contribution = 0.0F; // idf * tf_norm，该 term 对总分的贡献
};

// explain() 的返回：各 term 分项 + 总分。
struct ScoreExplanation {
    std::vector<TermScore> terms;
    float                  total = 0.0F;
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
    ~InvertedIndex();
    // index_positions=false 时不存 positions（S10.10，省内存，短语/近邻失效）。
    explicit InvertedIndex(Bm25Params params, bool index_positions = true);

    [[nodiscard]] bool index_positions() const { return index_positions_; }

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
    // params_override 非空时覆盖默认 Bm25Params（查询期 k1/b 调参，S8.5）；
    // 为空则用构造时的 params_。WAND 上界估算也用同一组参数，保证剪枝正确。
    [[nodiscard]] auto search(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    [[nodiscard]] auto search_phrase(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    // 近邻搜索（S8.7）：term 按查询顺序出现，相邻 term 间隙 ≤ slop。
    // slop=0 等价于 search_phrase（严格相邻）。复用 positions。
    [[nodiscard]] auto search_near(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        std::uint32_t slop,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    [[nodiscard]] auto bool_search(
        const QueryNode& query,
        std::size_t k,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    [[nodiscard]] auto search_fuzzy(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        std::uint32_t max_edit_distance,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    [[nodiscard]] auto search_wildcard(
        const std::string& pattern,
        std::size_t k,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> std::vector<SearchResult>;

    // 解释 query_terms 对文档 ord 的 BM25 评分（S8.8，调试/调优用）。
    // 用与 search() 完全相同的 idf/tf_norm 公式，逐 term 给出分项。
    // 与 search 一致：参数可被 params_override 覆盖。
    [[nodiscard]] auto explain(
        const std::vector<std::string>& query_terms,
        std::uint64_t ord,
        const LiveChecker& live_checker,
        const Bm25Params* params_override = nullptr) const -> ScoreExplanation;

    auto save(std::string_view path) const -> bool;
    auto load(std::string_view path) -> bool;

    // ---- 统计 ----
    [[nodiscard]] auto live_doc_count() const -> std::uint64_t;
    [[nodiscard]] auto sum_doc_len() const -> std::uint64_t;
    [[nodiscard]] auto avg_doc_len() const -> double;

    // 调试：返回 term 的 df（posting list 长度，含死点）。
    [[nodiscard]] auto df(std::string_view term) const -> std::size_t;
    [[nodiscard]] auto df_live(std::string_view term, const LiveChecker& live_checker) const -> std::size_t;

    // 压缩所有 posting list 的 ord 为 VByte gap 编码。
    void finalize_all_postings();

    // 死点压实（S10.11）：对死点占比 ≥ dead_ratio_threshold 的 posting list，
    // 用 live_checker 重建只留 live ord。高 churn 下死 ord 长期累积、每查询都扫，
    // 此操作回收之。非查询热路径（持每 key 写锁，与查询互斥）；分数无关。
    // 返回被压实的 posting list 数。
    auto compact(const LiveChecker& live_checker, double dead_ratio_threshold = 0.5)
        -> std::size_t;

    // WAL 支持（S8.9）：启用后 add_doc/remove_doc 自动追加到 WAL 文件。
    void enable_wal(std::string_view path);
    void disable_wal();
    void truncate_wal();
    bool has_wal() const { return wal_ != nullptr; }
    int replay_wal();

    // 内部分片结构（公开用于测试）。
    struct Shard {
        tbb::concurrent_hash_map<std::string, PostingList> inverted;
    };

    // 获取内部 shard（用于测试）。
    [[nodiscard]] auto shard_for(std::string_view term) -> Shard&;
    [[nodiscard]] auto shard_for(std::string_view term) const -> const Shard&;

private:
    static constexpr std::size_t kShardCount = 64;
    static constexpr std::size_t kWandThreshold = 1024;

    std::array<Shard, kShardCount> shards_;
    Bm25Params params_;
    bool index_positions_ = true;  // S10.10：false 时 add_doc 丢弃 positions

    // 全局统计（S10.1）：改用 atomic 去掉 stats_mutex_。
    // 此前 search()/explain()/wand 等查询路径裸读这两个字段而写路径持锁，
    // 并发查询+写=data race（UB）。atomic 既消 race 又免锁（写路径 V2 串行，
    // remove_doc 的 guard 用 load+fetch_sub 即可）。
    std::atomic<std::uint64_t> live_doc_count_{0};
    std::atomic<std::uint64_t> sum_doc_len_{0};

    // WAL（S8.9）。
    std::unique_ptr<InvertedWal> wal_;
    std::string wal_path_;

    // Block-Max WAND 算法。
    auto search_wand(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        const LiveChecker& live_checker,
        const Bm25Params& params) const -> std::vector<SearchResult>;

    // search_phrase / search_near 的共同实现（S8.7）：slop=0 为严格短语，
    // slop>0 允许相邻 term 间隙 ≤ slop（有序近邻）。
    auto search_phrase_impl(
        const std::vector<std::string>& query_terms,
        std::size_t k,
        std::uint32_t slop,
        const LiveChecker& live_checker,
        const Bm25Params* params_override) const -> std::vector<SearchResult>;
};

}  // namespace bitcask::bm25
