// === 算法参考文献 ===
// BM25 排序函数：Robertson & Sparck Jones 1976, "Relevance weighting of search terms".
//   IDF（Lucene 标准公式）：log(1 + (N - df + 0.5) / (df + 0.5))
//   TF 归一化：tf * (k1+1) / (tf + k1 * (1 - b + b * dl/avgdl))
//
// BM25+ 扩展（δ 参数）：Lv & Zhai 2011, "Lower-bounding term frequencies".
//   在 TF 归一化项上加 δ = 1.0，缓解标准 BM25 对长文档的过度惩罚。
//
// Block-Max WAND： Ding & Suel 2011, "Faster Top-k Document Retrieval Using Block-Max Indexes".
//   在每个 posting 块维护 max_tf，用上界剪枝跳过无望文档。
//
// Document-at-a-time（DAAT）评分：标准 IR 评估模型，对每个文档累加所有查询词的 BM25 分。
//
// === BM25 倒排索引（内存工作副本）。

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
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "bitcask/fuzzy_matcher.hpp"
#include "bitcask/live_checker.hpp"
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
    // v5 impacts:块内最小 doc_len(索引时值;文档 dl 不可变)。
    // 分数上界用 min_dl 替代 dl=1 假设,消除 ~25%/词 的固有松弛
    // (B1 实测剪枝不触发的根因,doc/kway-blockmax-bmw-zh.md §6.1)。
    // 1 = 旧快照/dl 未知时的 admissible 回退(等价旧行为)。
    std::uint32_t min_dl = 1;
    std::size_t   start_idx;
    std::size_t   count;
};

// 一条 posting 记录：文档 ord + 该 term 在文档中的词频。
struct Posting {
    std::uint64_t ord;
    std::uint32_t tf;
    // 索引时 doc_len(v5 impacts;落在原 4B padding 槽,内存零增量)。
    // 0 = 未知(旧快照载入)——封块求 min 时跳过,全 0 回退 min_dl=1。
    std::uint32_t dl = 0;
    std::vector<std::uint32_t> positions;
};

struct FlatPostings;  // 前向声明（定义在 PostingList 之后）

// 一个 term 对应的 posting 列表，按 ord 严格升序排列、同一 ord 不重复。
// 该不变量由 InvertedIndex::add_doc 的水位幂等保护（max_indexed_ord_）维持，
// 是 find 二分 / note_appended 封块 / intersect_u64 求交的共同前提。
struct PostingList {
    static constexpr std::size_t kBlockSize = 128;

    std::vector<Posting> items;

    // Block-Max WAND 跳跃索引（增量 seal_full_blocks + finalize 补尾块）。
    // 注：O3 后 items[].ord 恒为 ord 的唯一事实来源；VByte 压缩只在落盘格式
    // 里现场编码（save），内存不再常驻压缩副本。
    std::vector<PostingBlock> blocks;

    // 全局最大 tf 缓存（S10.9）：block_upper_bound 此前每次重扫全 items 求最大 tf；
    // 改为增量维护（note_appended 追加时更新，load 后重算），查询直接读。
    std::uint32_t max_tf = 0;

    // 计算块元数据（含部分尾块）。幂等：重复调用重算同一结果。
    void finalize() {
        if (items.empty()) return;

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
                std::uint32_t min_dl = 0xFFFFFFFF;
                for (std::size_t i = start; i < end; ++i) {
                    if (items[i].tf > max_tf) max_tf = items[i].tf;
                    if (items[i].dl > 0 && items[i].dl < min_dl) {
                        min_dl = items[i].dl;
                    }
                }
                if (min_dl == 0xFFFFFFFF) min_dl = 1;  // dl 全未知 → 回退
                blocks.push_back({base, last, max_tf, min_dl, start, end - start});
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
            std::uint32_t min_dl = 0xFFFFFFFF;
            for (std::size_t i = start; i < end; ++i) {
                if (items[i].tf > max_tf) max_tf = items[i].tf;
                if (items[i].dl > 0 && items[i].dl < min_dl) {
                    min_dl = items[i].dl;
                }
            }
            if (min_dl == 0xFFFFFFFF) min_dl = 1;
            blocks.push_back({items[start].ord, items[end - 1].ord, max_tf,
                              min_dl, start, kBlockSize});
            sealed += kBlockSize;
        }
    }

    // add_doc 追加一条 posting 后调用（S10.6）：让在线索引也具备 WAND 块跳跃。
    void note_appended() {
        // S10.9：增量维护全局 max_tf（新 posting 必在末尾）。
        if (!items.empty() && items.back().tf > max_tf) max_tf = items.back().tf;
        // finalize 可能留下不满的尾块；增量封块要求 blocks 仅含满块，先弹掉它。
        if (!blocks.empty() && blocks.back().count < kBlockSize) {
            blocks.pop_back();
        }
        seal_full_blocks();
    }

    // 死点压实（S10.11）：删除 live 标志为 0 的 posting，重建派生态。
    // items 原本按 ord 升序，过滤保序 → 压实后仍有序。返回是否实际删了。
    // 分数无关：live_df/idf/avgdl 都只数 live，压实只是不再扫死点。
    // P2.4：flags 版本——live 与 items 按下标对齐（批量 fill_is_live 产物，
    // 免每 posting 一次带锁虚调用）。
    bool compact_flags(std::span<const char> live) {
        std::vector<Posting> kept;
        kept.reserve(items.size());
        for (std::size_t i = 0; i < items.size(); ++i) {
            if (live[i]) kept.push_back(std::move(items[i]));
        }
        if (kept.size() == items.size()) return false;  // 无死点，不动
        items = std::move(kept);
        // 重建派生态（blocks/max_tf）。
        blocks.clear();
        max_tf = 0;
        for (auto& p : items) {
            if (p.tf > max_tf) max_tf = p.tf;
        }
        seal_full_blocks();  // 仅封满块（与增量一致，尾部留给后续 finalize）
        return true;
    }

    // 按 ord 查找（二分，用于 add_doc 去重 / remove_doc 定位）。
    [[nodiscard]] auto find(std::uint64_t ord) const -> std::size_t;
    [[nodiscard]] bool has(std::uint64_t ord) const;

    // 返回包含指定 ord 的块（binary search）。
    [[nodiscard]] auto block_for_ord(std::uint64_t ord) const -> const PostingBlock*;

    // 计算该 posting list 的全局上界分数（用于 WAND剪枝）。
    [[nodiscard]] auto block_upper_bound(float idf, const Bm25Params& params, double avgdl) const -> float;

    // P1：在 caller 持桶锁（accessor）期间拷出查询评分所需的扁平快照。
    // 只拷 (ord, tf) 双数组 + WAND 元数据——positions 评分用不到，不拷。
    // 相比整列表深拷贝：分配 N+1 次 → 2 次，拷贝 ~40B+positions 堆块 → 12B/posting。
    void snapshot_flat(FlatPostings& out) const;
};

// P1：查询路径的 PostingList 扁平快照（见 doc/posting-zero-copy-design-zh.md）。
// 6 条查询路径中 5 条只需要 (ord, tf)（search/wand/bool/fuzzy/wildcard），
// 由本结构承载；phrase/near 需要 positions，仍走 PostingList 深拷贝。
struct FlatPostings {
    std::vector<std::uint64_t> ords;    // 与 tfs 平行，按 ord 升序
    std::vector<std::uint32_t> tfs;
    std::vector<PostingBlock>  blocks;  // WAND 跳跃索引（量 = N/128，浅拷）
    std::uint32_t              max_tf = 0;

    [[nodiscard]] std::size_t size() const noexcept { return ords.size(); }
    [[nodiscard]] bool empty() const noexcept { return ords.empty(); }

    // 与 PostingList 同名方法语义一致（共享实现，见 inverted.cpp）。
    [[nodiscard]] auto block_for_ord(std::uint64_t ord) const -> const PostingBlock*;
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
//
// 倒排索引。
class InvertedIndex {
public:
    InvertedIndex() = default;
    ~InvertedIndex();
    // index_positions=false 时不存 positions（S10.10，省内存，短语/近邻失效）。
    explicit InvertedIndex(Bm25Params params, bool index_positions = true);

    [[nodiscard]] bool index_positions() const { return index_positions_; }
    // A4-P2:已索引最大 ord 水位(u64(-1)=尚无文档)。快照成对性门用。
    [[nodiscard]] std::uint64_t max_indexed_ord() const {
        return max_indexed_ord_.load(std::memory_order_relaxed);
    }

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
    // P14e:序列化到字节缓冲(供 search.ckpt 分段嵌入)。盘字节与 save() 一致
    // (自带 INV 框架、原生小端)。serialize 仅追加缓冲、不会失败。
    void serialize(std::vector<std::byte>& out) const;
    // 从字节缓冲反序列化(search.ckpt 段)。语义同 load:任何越界/校验违例
    // 整体拒绝返回 false。
    [[nodiscard]] auto deserialize(std::span<const std::byte> bytes) -> bool;

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
    // V6.2：batch_size>1 时积攒 entries 缓冲后批量 fwrite+fflush。
    void enable_wal(std::string_view path, std::size_t batch_size = 1);
    void disable_wal();
    void truncate_wal();
    bool has_wal() const { return wal_ != nullptr; }
    int replay_wal();

    // 内部分片结构（公开用于测试）。
    // P2-min：map 值为 shared_ptr<PostingList>（CoW 发布，见 inverted.cpp
    // mutable_pl）。phrase/near 读者持引用零拷贝读；写者 use_count==1 时
    // 原地改（常态），>1（有 phrase 读者在持）才克隆替换。
    using PostingMap = tbb::concurrent_hash_map<std::string, std::shared_ptr<PostingList>>;
    struct Shard {
        PostingMap inverted;

        // V6.3.1：排序词典侧表——替代每次查询时的 hash_map 全扫 + sort。
        // vocab_dirty_ 由 add_doc 置 true（release）；首次搜索检测到 dirty 时
        // 在 vocab_mtx_ 写锁下重建 vocab_、清 dirty。
        // 非脏路径：shared_lock 读 vocab_ → 无重建开销。
        // shard.inverted 与 vocab_ 的不一致窗口由 vocab_dirty_ 兜住：
        //   写者 add_doc 后 release-store true；
        //   读者 ensure_vocab 入口 acquire-load，true 才付写锁重建。
        mutable std::shared_mutex vocab_mtx_;
        mutable std::shared_ptr<const std::vector<std::string>> vocab_;
        mutable std::atomic<bool> vocab_dirty_{true};
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

    // 已索引文档的最大 ord 水位（add_doc 幂等保护）。ord 由引擎单调分配、
    // add_doc 调用序保持单调（IndexPool 单消费者 + 恢复按 ord 序回放），故
    // 正常追加恒满足 ord > 水位。崩溃恢复时 save/truncate_wal 非原子窗口会让
    // load 后的 replay_wal 重放已在快照里的 (ord, term)；用水位把 ord ≤ 水位的
    // 重放整文档丢弃，保证 PostingList::items 严格升序无重复（intersect_u64 /
    // find 二分 / note_appended 封块都依赖该不变量）。-1 = 尚未索引任何文档。
    // atomic:worker 线程写,搜索线程经 max_indexed_ord() 读,跨线程访问。
    std::atomic<std::uint64_t> max_indexed_ord_{static_cast<std::uint64_t>(-1)};

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

    // V6.3.1：确保指定 shard 的排序词典可用。脏则重建（写锁），否则直接返回快照（读锁）。
    auto ensure_vocab(std::size_t shard_idx) const
        -> std::shared_ptr<const std::vector<std::string>>;
};

}  // namespace bitcask::bm25
