#include "bitcask/intersect.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/inverted_wal.hpp"
#include "bitcask/myers.hpp"
#include "bitcask/wildcard_matcher.hpp"
#include "bitcask/bm25_kernels.hpp"

#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_reduce.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <queue>
#include <string>
#include <string_view>
#include <vector>

namespace bitcask::bm25 {

// ===========================================================================
// PostingList
// ===========================================================================

auto PostingList::find(std::uint64_t ord) const -> std::size_t {
    auto it = std::lower_bound(items.begin(), items.end(), ord,
                               [](const Posting& p, std::uint64_t o) {
                                   return p.ord < o;
                               });
    if (it != items.end() && it->ord == ord) {
        return static_cast<std::size_t>(it - items.begin());
    }
    return items.size();  // not found
}

bool PostingList::has(std::uint64_t ord) const {
    return find(ord) != items.size();
}

namespace {

// block_for_ord / block_upper_bound 的共享实现——PostingList 与
// FlatPostings（P1 查询快照）语义必须一致，逻辑只写一份。
const PostingBlock* block_for_ord_in(const std::vector<PostingBlock>& blocks,
                                     std::uint64_t ord) {
    if (blocks.empty()) return nullptr;
    auto it = std::lower_bound(blocks.begin(), blocks.end(), ord,
                               [](const PostingBlock& block, std::uint64_t o) {
                                   return block.end_ord < o;
                               });
    if (it != blocks.end() && it->base_ord <= ord) {
        return &(*it);
    }
    if (it != blocks.begin()) {
        --it;
        if (it->base_ord <= ord && it->end_ord >= ord) {
            return &(*it);
        }
    }
    return nullptr;
}

// min_dl:分母的 doc_len 下界。默认 1 = 最松 admissible(旧行为);
// v5 块级 impacts 传块内真实最小 dl,上界收紧 ~25%/词(§6.1)。
float upper_bound_from(std::uint32_t global_max_tf, float idf,
                       const Bm25Params& params, double avgdl,
                       std::uint32_t min_dl = 1) {
    float tf_norm = static_cast<float>(global_max_tf) * (params.k1 + 1.0f) /
                    (static_cast<float>(global_max_tf) + params.k1 *
                     (1.0f - params.b + params.b * static_cast<float>(min_dl) /
                      static_cast<float>(avgdl)));
    // BM25+：上界含 δ 下界项，与实际评分一致，避免 WAND 剪枝漏结果（S8.10）。
    return idf * (tf_norm + params.delta);
}

// search / search_wildcard / search_fuzzy 共用的查询词条目：term + 扁平快照。
// （wand/bool 的词条目更富——带 live/dls/cursor/idf——仍各自局部定义。）
struct ScoredTerm {
    std::string  term;
    FlatPostings fp;
};

// bag-of-words 评分 + top-k：三条路径（search 标量 / wildcard / fuzzy）此前
// 各自内联一份逐字相同的「批量 live/doc_len + 两阶段评分 parallel_reduce +
// 小顶堆 top-k」。提取单一实现，BM25 公式与「分数位级不变 / 无分支可向量化」
// 两条不变量只此一处（避免改公式时漏改某条低频路径致评分不一致）。
std::vector<SearchResult> score_bow_topk(
    const std::vector<ScoredTerm>& tps, std::size_t k,
    std::uint64_t N, std::uint64_t sum_dl,
    const Bm25Params& params, const LiveChecker& live_checker) {
    const double avgdl =
        N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // 并行 BM25 评分：parallel_reduce 按查询词分片，线程本地扁平
    // (ord, contrib) 数组累积。替代 unordered_map：每 posting 一次 hash
    // 节点分配 + reduce 阶段 O(n) hash 合并 → 向量追加 + 拼接,最终
    // sort + 按 ord 归并累加(同 ord 的浮点累加顺序与 hash 版同为
    // 分片相关,不引入新的不确定性)。
    using Hit = std::pair<std::uint64_t, float>;
    std::vector<Hit> hits = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, tps.size()),
        std::vector<Hit>{},
        [&](const tbb::blocked_range<std::size_t>& range,
            std::vector<Hit> local) {
            // 工作数组提到 term 循环外复用(原实现每 term 3 次分配)。
            std::vector<char> live;
            std::vector<std::uint32_t> dls;
            std::vector<float> contrib;
            for (std::size_t ti = range.begin(); ti < range.end(); ++ti) {
                const auto& fp = tps[ti].fp;
                const std::size_t n = fp.size();

                // P2.1：live/doc_len 批量取——一次虚调用（Index 侧一次锁）完成
                // 整列，评分浮点循环不再含虚调用，编译器可自动向量化。
                live.resize(n);
                live_checker.fill_is_live(fp.ords, live);
                std::size_t live_df = 0;
                for (std::size_t i = 0; i < n; ++i) {
                    live_df += static_cast<std::size_t>(live[i]);
                }
                if (live_df == 0) continue;

                auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

                dls.resize(n);
                live_checker.fill_doc_lens(fp.ords, dls);

                // 两阶段评分：① 纯数组浮点（可向量化；死点也算、结果不用，
                // 保持无分支），公式与逐 posting 版逐运算一致（分数位级不变）；
                // ② 标量 append 进线程本地扁平数组。
                contrib.resize(n);
                const float fidf = static_cast<float>(idf);
                const float inv_avgdl = 1.0f / static_cast<float>(avgdl);
                detail::bm25_score_dispatch(
                    fp.tfs.data(), dls.data(),
                    params.k1 + 1.0f,
                    params.k1 * (1.0f - params.b),
                    params.k1 * params.b,
                    params.delta,
                    fidf,
                    inv_avgdl,
                    contrib.data(),
                    n);
                local.reserve(local.size() + live_df);
                for (std::size_t i = 0; i < n; ++i) {
                    if (live[i]) local.emplace_back(fp.ords[i], contrib[i]);
                }
            }
            return local;
        },
        [](std::vector<Hit> a, std::vector<Hit> b) {
            if (a.size() < b.size()) a.swap(b);  // 总把小的拼进大的
            a.insert(a.end(), b.begin(), b.end());
            return a;
        });

    // 按 ord 排序 → 同 ord 连续成段 → 归并累加,边累加边喂 top-k 小顶堆。
    std::sort(hits.begin(), hits.end(),
              [](const Hit& x, const Hit& y) { return x.first < y.first; });

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;
    for (std::size_t i = 0; i < hits.size();) {
        const std::uint64_t ord = hits[i].first;
        float score = 0.0F;
        do {
            score += hits[i].second;
            ++i;
        } while (i < hits.size() && hits[i].first == ord);
        if (heap.size() < k) {
            heap.push({score, ord});
        } else if (score > heap.top().first) {
            heap.pop();
            heap.push({score, ord});
        }
    }
    std::vector<SearchResult> results;
    results.reserve(heap.size());
    while (!heap.empty()) {
        auto& [score, ord] = heap.top();
        results.push_back({ord, score});
        heap.pop();
    }
    std::reverse(results.begin(), results.end());  // 分数降序
    return results;
}

// 安全收集一个 shard 满足 pred 的 term key 快照（去重升序）。
// 这是遍历 tbb::concurrent_hash_map 的唯一安全原语，把一条实测复现过的
// 并发不变量集中到一处：遍历期间**不可** find（懒 rehash 节点搬迁致迭代器
// 重访/漏访）也**不可**裸读/改 slot 值（shared_ptr 可能被写者 CoW 替换、
// 裸读撕裂）——只读 key（节点 key 稳定）。调用方随后逐 key 经 accessor
// 取值/改值。sort+unique 兜住与单写者并发时 rehash 可能造成的重访去重。
template <typename Pred>
std::vector<std::string> collect_term_keys(
    const InvertedIndex::PostingMap& map, Pred pred) {
    std::vector<std::string> keys;
    for (auto it = map.begin(); it != map.end(); ++it) {
        if (pred(it->first)) keys.push_back(it->first);
    }
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    return keys;
}

// P2-min CoW：返回可安全原地修改的 PostingList。调用方必须持有该桶的写
// accessor。读者只能在桶读锁下取得 shared_ptr 引用（与写 accessor 互斥），
// 因此 use_count()==1 ⟺ 当前无 phrase/near 读者持引用 → 原地改安全；
// >1 则克隆替换，旧版本由读者的引用计数续命（对读者 immutable）。
// use_count() 是 relaxed load：观察到 1 后补 acquire fence，与读者析构
// shared_ptr 的 release 递减配对，确保读者的最后一次数据读 happens-before
// 写者的后续原地修改。
PostingList& mutable_pl(std::shared_ptr<PostingList>& sp) {
    if (!sp) {
        sp = std::make_shared<PostingList>();
    } else if (sp.use_count() > 1) {
        sp = std::make_shared<PostingList>(*sp);
    } else {
        std::atomic_thread_fence(std::memory_order_acquire);
    }
    return *sp;
}

}  // namespace

auto PostingList::block_for_ord(std::uint64_t ord) const -> const PostingBlock* {
    return block_for_ord_in(blocks, ord);
}

auto PostingList::block_upper_bound(float idf, const Bm25Params& params, double avgdl) const -> float {
    if (items.empty()) return 0.0f;
    // S10.9：直接读缓存的 global max_tf（note_appended 增量维护 / load 后重算），
    // 不再每次重扫全 items。
    return upper_bound_from(max_tf, idf, params, avgdl);
}

void PostingList::snapshot_flat(FlatPostings& out) const {
    out.ords.resize(items.size());
    out.tfs.resize(items.size());
    for (std::size_t i = 0; i < items.size(); ++i) {
        out.ords[i] = items[i].ord;
        out.tfs[i]  = items[i].tf;
    }
    out.blocks = blocks;
    out.max_tf = max_tf;
}

auto FlatPostings::block_for_ord(std::uint64_t ord) const -> const PostingBlock* {
    return block_for_ord_in(blocks, ord);
}

auto FlatPostings::block_upper_bound(float idf, const Bm25Params& params, double avgdl) const -> float {
    if (ords.empty()) return 0.0f;
    return upper_bound_from(max_tf, idf, params, avgdl);
}

// ===========================================================================
// InvertedIndex
// ===========================================================================

InvertedIndex::~InvertedIndex() = default;

InvertedIndex::InvertedIndex(Bm25Params params, bool index_positions)
    : params_(params), index_positions_(index_positions) {}

auto InvertedIndex::shard_for(std::string_view term) -> Shard& {
    auto h = std::hash<std::string_view>{}(term);
    return shards_[h % kShardCount];
}

auto InvertedIndex::shard_for(std::string_view term) const -> const Shard& {
    auto h = std::hash<std::string_view>{}(term);
    return shards_[h % kShardCount];
}

// V6.3.1：懒重建排序词典侧表。Fast path 是 acquire-load dirty + shared_lock
// 读 vocab_（常驻基线数据规模下零分配）；dirty 时降级到 unique_lock 写锁下
// 从 shard.inverted 抽 key、sort+unique、装到新 shared_ptr 发布。释放锁前
// release-store false，与后续 add_doc 的 release-store true 形成 release/acquire
// 配对——读者之后 acquire-load 必看到 false → 进入 fast path 时 vocab_ 已含
// 该次 add_doc 新增的 key。
auto InvertedIndex::ensure_vocab(std::size_t shard_idx) const
    -> std::shared_ptr<const std::vector<std::string>> {
    auto& shard = shards_[shard_idx];

    if (!shard.vocab_dirty_.load(std::memory_order_acquire)) {
        std::shared_lock rlock(shard.vocab_mtx_);
        return shard.vocab_;
    }

    std::unique_lock wlock(shard.vocab_mtx_);
    // Double-check：持写锁时已 barrier 此前所有 release-store=true，relaxed
    // load 即可看到最新值；若已被并发线程重建则直接取现成快照。
    if (!shard.vocab_dirty_.load(std::memory_order_relaxed)) {
        return shard.vocab_;
    }

    std::vector<std::string> keys;
    keys.reserve(shard.inverted.size());
    for (auto it = shard.inverted.begin(); it != shard.inverted.end(); ++it) {
        keys.push_back(it->first);
    }
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());

    shard.vocab_ = std::make_shared<const std::vector<std::string>>(std::move(keys));
    shard.vocab_dirty_.store(false, std::memory_order_release);
    return shard.vocab_;
}

// ---- 写 ----

void InvertedIndex::add_doc(
    std::uint64_t ord,
    const TermPositions& term_data) {
    // 水位幂等：ord ≤ 已索引最大 ord ⟹ 该文档已在索引里（崩溃恢复时
    // replay_wal 重放快照已含的条目），整文档丢弃，避免 items 重复/乱序。
    // 正常追加 ord 单调递增 > 水位，一次比较即过（max_indexed_ord_ 初值 -1
    // 使首个文档 ord=0 也通过）。
    const std::uint64_t wm = max_indexed_ord_.load(std::memory_order_relaxed);
    if (wm != static_cast<std::uint64_t>(-1) && ord <= wm) {
        return;
    }
    max_indexed_ord_.store(ord, std::memory_order_relaxed);

    // v5 impacts:doc_len 先求和——posting 携带索引时 dl,封块算 min_dl。
    auto doc_len = std::uint32_t{0};
    for (auto& [term, data] : term_data) doc_len += data.first;

    for (auto& [term, data] : term_data) {
        auto& [tf, positions] = data;
        auto& shard = shard_for(term);
        PostingMap::accessor acc;
        const bool is_new_term = shard.inverted.insert(acc, term);  // true = 新 key
        PostingList& pl = mutable_pl(acc->second);  // P2-min：有 phrase 读者持引用时 CoW
        // S10.10：index_positions_=false 时不存 positions（省内存，短语/近邻失效）。
        if (index_positions_) {
            pl.items.push_back({ord, tf, doc_len, positions});
        } else {
            pl.items.push_back({ord, tf, doc_len, {}});
        }
        pl.note_appended();  // S10.6：增量封块，在线索引也吃 WAND 块跳跃
        // V6.3.1：仅当新 key 时标脏——旧 term 的 posting list 增删不影响已排序
        // 的 vocab_ 集合。无条件置 true 也能正确工作（只是浪费一次重建）。
        if (is_new_term) {
            shard.vocab_dirty_.store(true, std::memory_order_release);
        }
    }

    live_doc_count_.fetch_add(1, std::memory_order_relaxed);
    sum_doc_len_.fetch_add(doc_len, std::memory_order_relaxed);

    // TermPositions 与 WalTermPositions 是同一类型,直接传引用,
    // 不再为 WAL 深拷贝整个 term map(字符串 + positions 全量)。
    if (wal_) wal_->append_add_doc(ord, term_data);
}

void InvertedIndex::remove_doc(
    std::uint32_t doc_len,
    const std::unordered_map<std::string, std::uint32_t>& term_freqs) {
    // 写路径 V2 串行，guard 用 load + fetch_sub（reader 侧裸 load 已无 race）。
    if (live_doc_count_.load(std::memory_order_relaxed) > 0) {
        live_doc_count_.fetch_sub(1, std::memory_order_relaxed);
    }
    if (sum_doc_len_.load(std::memory_order_relaxed) >= doc_len) {
        sum_doc_len_.fetch_sub(doc_len, std::memory_order_relaxed);
    }

    if (wal_) wal_->append_remove_doc(doc_len, term_freqs);
}

// ---- 查询 ----

auto InvertedIndex::search(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    const Bm25Params& params = params_override ? *params_override : params_;
    // P1：accessor 下只拷扁平快照（ords/tfs），不再深拷整个 PostingList。
    // WAND 路由判定只需 posting 总量——在 accessor 下读 items.size() 即可，
    // 不必先 snapshot_flat（原实现对每 term 拷 ords/tfs/blocks 三个 vector，
    // 走 WAND 时整组作废、search_wand 再快照一遍，是触发条件最大的查询上的
    // 双倍拷贝）。标量路径才在确定后快照。
    std::size_t total_postings = 0;
    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            total_postings += acc->second->items.size();
        }
    }
    if (total_postings == 0) return {};
    if (total_postings >= kWandThreshold) {
        return search_wand(query_terms, k, live_checker, params);
    }

    // 标量路径：现在才快照。
    using TermPostings = ScoredTerm;  // 共用条目（term + 扁平快照）
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());
    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            TermPostings tp;
            tp.term = term;
            acc->second->snapshot_flat(tp.fp);
            tps.push_back(std::move(tp));
        }
    }
    if (tps.empty()) return {};

    // bag-of-words 评分 + top-k（共享 kernel score_bow_topk）。
    return score_bow_topk(tps, k,
                          live_doc_count_.load(std::memory_order_relaxed),
                          sum_doc_len_.load(std::memory_order_relaxed),
                          params, live_checker);
}

// ===========================================================================
// explain —— BM25 评分分项解释（S8.8）
// ===========================================================================

auto InvertedIndex::explain(
    const std::vector<std::string>& query_terms,
    std::uint64_t ord,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> ScoreExplanation {
    const Bm25Params& params = params_override ? *params_override : params_;

    ScoreExplanation out;
    out.terms.reserve(query_terms.size());

    const auto N = live_doc_count_.load(std::memory_order_relaxed);
    const auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    const double avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;
    const auto dl = live_checker.doc_len(ord);

    for (const auto& term : query_terms) {
        TermScore ts;
        ts.term = term;

        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (!shard.inverted.find(acc, term)) {
            // term 不在索引：df=0、各项 0，仍记录以示「未命中」。
            out.terms.push_back(std::move(ts));
            continue;
        }
        const PostingList& pl = *acc->second;

        // 与 search() 一致地算 live df（O3：直接读 items[].ord，免物化 ords）。
        std::size_t live_df = 0;
        for (std::size_t i = 0; i < pl.items.size(); ++i) {
            if (live_checker.is_live(pl.items[i].ord)) ++live_df;
        }
        ts.df = live_df;
        if (live_df == 0) { out.terms.push_back(std::move(ts)); continue; }

        ts.idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) /
                                (static_cast<double>(live_df) + 0.5));

        // 找该 ord 的 posting 取 tf（不在该文档则 tf=0，贡献 0）。
        auto idx = pl.find(ord);
        if (idx < pl.items.size()) {
            ts.tf = pl.items[idx].tf;
            ts.tf_norm = static_cast<float>(ts.tf) * (params.k1 + 1.0F) /
                         (static_cast<float>(ts.tf) + params.k1 *
                          (1.0F - params.b + params.b *
                           static_cast<float>(dl) / static_cast<float>(avgdl)));
            ts.contribution = static_cast<float>(ts.idf) * (ts.tf_norm + params.delta);
            out.total += ts.contribution;
        }
        out.terms.push_back(std::move(ts));
    }
    return out;
}

// ===========================================================================
// Block-Max WAND
// ===========================================================================

auto InvertedIndex::search_wand(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker,
    const Bm25Params& params) const -> std::vector<SearchResult> {
    struct TermPostings {
        std::string term;
        FlatPostings fp;   // P1：扁平快照，ords/tfs 兼任 DAAT 游标数组
        std::vector<char> live;          // P2.1：与 ords 平行，批量取一次
        std::vector<std::uint32_t> dls;  // P2.1：同上（DAAT 每 pivot 免锁免虚调用）
        std::size_t cursor = 0;
        float idf = 0.0f;
        float list_upper_bound = 0.0f;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            TermPostings tp;
            tp.term = term;
            acc->second->snapshot_flat(tp.fp);
            tps.push_back(std::move(tp));
        }
    }
    if (tps.empty()) return {};

    auto N = live_doc_count_.load(std::memory_order_relaxed);
    auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // 计算每个 term 的 IDF 和上界分数。
    // P2.1：live/doc_len 批量取一次（Index 侧各一次锁）存进 tp——
    // DAAT 循环每 pivot 的 is_live/doc_len 改读数组，全程零虚调用零锁。
    for (auto& tp : tps) {
        tp.live.resize(tp.fp.size());
        live_checker.fill_is_live(tp.fp.ords, tp.live);
        tp.dls.resize(tp.fp.size());
        live_checker.fill_doc_lens(tp.fp.ords, tp.dls);
        std::size_t live_df = 0;
        for (std::size_t i = 0; i < tp.live.size(); ++i) {
            live_df += static_cast<std::size_t>(tp.live[i]);
        }
        if (live_df == 0) {
            tp.idf = 0.0f;
            tp.list_upper_bound = 0.0f;
            continue;
        }
        tp.idf = static_cast<float>(std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) /
                                             (static_cast<double>(live_df) + 0.5)));
        tp.list_upper_bound = tp.fp.block_upper_bound(tp.idf, params, avgdl);
    }

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;
    float threshold = 0.0f;

    // S10.5：每轮只排序索引数组，避免 std::sort 整体搬运含多个 vector 的
    // TermPostings（P1 后为 fp 的 ords/tfs/blocks）。
    // order[i] 给出按当前 ord 升序的第 i 个 term 在 tps 中的下标。
    std::vector<std::size_t> order(tps.size());
    for (std::size_t i = 0; i < tps.size(); ++i) order[i] = i;

    while (true) {
        // 按当前 ord 升序排列（保留原比较器语义：耗尽的 term 排前面，会被下方 continue 跳过）。
        std::sort(order.begin(), order.end(),
                  [&tps](std::size_t a, std::size_t b) {
                      const auto& ta = tps[a];
                      const auto& tb = tps[b];
                      bool a_ex = ta.cursor >= ta.fp.ords.size();
                      bool b_ex = tb.cursor >= tb.fp.ords.size();
                      if (a_ex && b_ex) return false;
                      if (a_ex) return true;
                      if (b_ex) return false;
                      return ta.fp.ords[ta.cursor] < tb.fp.ords[tb.cursor];
                  });

        std::size_t pivot_pos = 0;  // pivot 在排序序列 order 中的位置
        float acc_score = 0.0f;
        bool pivot_found = false;

        for (std::size_t i = 0; i < order.size(); ++i) {
            auto& tp = tps[order[i]];
            if (tp.cursor >= tp.fp.ords.size()) continue;
            acc_score += tp.list_upper_bound;
            if (acc_score >= threshold) {
                pivot_pos = i;
                pivot_found = true;
                break;
            }
        }
        if (!pivot_found) break;

        auto& pivot_tp = tps[order[pivot_pos]];
        auto pivot_ord = pivot_tp.fp.ords[pivot_tp.cursor];

        // A1:非耗尽词的列表上界总和——块跳跃判定的保守"其余词"上界
        // (含 pivot 之后 cursor 恰为 pivot_ord 的词,admissible)。
        float total_ub = 0.0f;
        for (auto& t : tps) {
            if (t.cursor < t.fp.ords.size()) total_ub += t.list_upper_bound;
        }

        bool any_skipped = false;
        for (std::size_t i = 0; i <= pivot_pos; ++i) {
            auto& tp = tps[order[i]];
            if (tp.cursor >= tp.fp.ords.size()) continue;
            if (tp.fp.ords[tp.cursor] != pivot_ord) continue;

            const auto* block = tp.fp.block_for_ord(pivot_ord);
            if (block != nullptr) {
                // A1:块上界接 v5 impacts(max_tf + min_dl),替代 dl=1
                // 假设——与 bool MUST 路径同源收紧 ~25%/词(§6.2)。
                // (保持内联表达式,与原代码逐运算一致;此循环每 pivot
                // 每词执行一次,在热路径上。)
                float block_tf_norm =
                    static_cast<float>(block->max_tf) * (params.k1 + 1.0f) /
                    (static_cast<float>(block->max_tf) + params.k1 *
                     (1.0f - params.b +
                      params.b * static_cast<float>(block->min_dl) /
                          static_cast<float>(avgdl)));
                float block_upper = tp.idf * (block_tf_norm + params.delta);
                // A1 修复:原公式 threshold - heap.top() 在 threshold ==
                // heap.top()(下方 θ 更新同源)时恒 ≈1e-6,块跳跃从未
                // 触发过(死代码)。正确判定:本词块上界 + 其余词列表
                // 上界之和 ≤ θ ⟹ pivot 不可能严格超过 θ,整块跳过。
                // 注意不能加绝对 epsilon(如 1e-6):idf 极小时(df≈N)
                // 分数量级 ~1e-4,绝对容差变成巨大相对容差,会把
                // 真 top-k 所在块当"平分"误跳——只认 <=(位级平分才跳,
                // top-k 是严格优于语义,平分块挤不掉现有结果)。
                if (heap.size() >= k &&
                    block_upper <=
                        threshold - (total_ub - tp.list_upper_bound)) {
                    // 跳过到下一个块边界。
                    std::size_t next_start = block->start_idx + block->count;
                    if (next_start >= tp.fp.ords.size()) {
                        tp.cursor = tp.fp.ords.size();
                    } else {
                        tp.cursor = next_start;
                    }
                    any_skipped = true;
                }
            }
        }
        if (any_skipped) continue;

        // 所有 term 在 pivot_ord 处都值得关注，计算实际分数。
        // P2.1：live/dl 读 pivot term 的批量数组（任意在 pivot_ord 处的 term
        // 给出同一 ord 的同一答案，取 pivot_tp 自己游标位置的即可）。
        if (pivot_tp.live[pivot_tp.cursor]) {
            float score = 0.0f;
            // S10.8：dl 只依赖 pivot_ord，提到 term 循环外取一次（原先每个匹配 term 重取）。
            auto dl = pivot_tp.dls[pivot_tp.cursor];
            for (std::size_t i = 0; i < tps.size(); ++i) {
                if (tps[i].cursor >= tps[i].fp.ords.size()) continue;
                if (tps[i].fp.ords[tps[i].cursor] != pivot_ord) continue;

                auto tf_norm = static_cast<float>(tps[i].fp.tfs[tps[i].cursor]) *
                               (params.k1 + 1.0f) /
                               (static_cast<float>(tps[i].fp.tfs[tps[i].cursor]) + params.k1 *
                                (1.0f - params.b + params.b *
                                 static_cast<float>(dl) / static_cast<float>(avgdl)));
                score += tps[i].idf * (tf_norm + params.delta);
            }

            if (score >= threshold) {
                if (heap.size() < k) {
                    heap.push({score, pivot_ord});
                } else if (score > heap.top().first) {
                    heap.pop();
                    heap.push({score, pivot_ord});
                }
                if (heap.size() >= k) {
                    threshold = heap.top().first;
                }
            }
        }

        // 推进所有 cursor <= pivot_ord 的 term。
        for (std::size_t i = 0; i < tps.size(); ++i) {
            while (tps[i].cursor < tps[i].fp.ords.size() && tps[i].fp.ords[tps[i].cursor] <= pivot_ord) {
                ++tps[i].cursor;
            }
        }

        bool any_exhausted = false;
        for (auto& tp : tps) {
            if (tp.cursor >= tp.fp.ords.size()) any_exhausted = true;
        }
        if (any_exhausted) {
            bool all_exhausted = true;
            for (auto& tp : tps) {
                if (tp.cursor < tp.fp.ords.size()) {
                    all_exhausted = false;
                    break;
                }
            }
            if (all_exhausted) break;
        }
    }

    std::vector<SearchResult> results;
    results.reserve(heap.size());
    while (!heap.empty()) {
        auto& [score, ord] = heap.top();
        results.push_back({ord, score});
        heap.pop();
    }
    std::reverse(results.begin(), results.end());
    return results;
}

auto InvertedIndex::search_phrase_impl(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    std::uint32_t slop,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    if (query_terms.empty()) return {};
    const Bm25Params& params = params_override ? *params_override : params_;

    // P2-min：持 shared_ptr 引用零拷贝读（原先深拷贝整列表含全部 positions）。
    // 安全性：写者对同 term 追加时经 mutable_pl 做 CoW（见 use_count 协议），
    // 本读者持有的对象自取得引用起不再被修改。
    struct TermPostings {
        std::string term;
        std::shared_ptr<const PostingList> pl;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (!shard.inverted.find(acc, term)) return {};
        tps.push_back({term, acc->second});
    }

    auto N = live_doc_count_.load(std::memory_order_relaxed);
    auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    std::unordered_map<std::uint64_t, float> scores;

    auto& first_pl = *tps[0].pl;

    // live_df 只依赖 first term 的 posting list（与具体候选 doc 无关），
    // 提到循环外算一次，避免每个匹配 doc 重算 O(D)（S9.7）。
    // P2.1：first term 的 live 批量取一次（Index 侧一次锁），主循环复用。
    std::vector<std::uint64_t> first_ords(first_pl.items.size());
    for (std::size_t j = 0; j < first_pl.items.size(); ++j) {
        first_ords[j] = first_pl.items[j].ord;
    }
    std::vector<char> first_live(first_ords.size());
    live_checker.fill_is_live(first_ords, first_live);
    std::size_t live_df = 0;
    for (std::size_t j = 0; j < first_live.size(); ++j) {
        live_df += static_cast<std::size_t>(first_live[j]);
    }
    auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

    for (std::size_t i = 0; i < first_pl.items.size(); ++i) {
        auto& posting = first_pl.items[i];
        auto posting_ord = posting.ord;
        if (!first_live[i]) continue;

        // 把「在其余 term 的 posting list 里定位本 doc」提到 start_pos 循环外：
        // idx 对固定 (doc, term) 不变，原先每个 start_pos 都重查一次 O(log D)（S9.7）。
        // 任一 other term 在本 doc 不存在 → 整 doc 不可能成短语，直接跳过。
        bool doc_has_all_terms = true;
        std::vector<const std::vector<std::uint32_t>*> other_pos(tps.size(), nullptr);
        for (std::size_t t = 1; t < tps.size(); ++t) {
            auto& other_pl = *tps[t].pl;
            auto idx = other_pl.find(posting_ord);
            if (idx >= other_pl.items.size()) { doc_has_all_terms = false; break; }
            other_pos[t] = &other_pl.items[idx].positions;
        }
        if (!doc_has_all_terms) continue;

        std::uint32_t phrase_tf = 0;
        for (auto start_pos : posting.positions) {
            // 有序匹配：term t 必须在 (prev, prev+1+slop] 内出现（slop=0 即精确相邻）。
            bool match = true;
            std::uint32_t prev = start_pos;
            for (std::size_t t = 1; t < tps.size(); ++t) {
                const auto& pos_list = *other_pos[t];
                const std::uint32_t lo = prev + 1;
                const std::uint32_t hi = prev + 1 + slop;  // 闭区间上界
                // 找 >= lo 的第一个 position。
                auto it = std::lower_bound(pos_list.begin(), pos_list.end(), lo);
                if (it == pos_list.end() || *it > hi) { match = false; break; }
                prev = *it;  // 推进到该 term 的匹配位置（贪心取最早，保证后续窗口最大）
            }
            if (match) ++phrase_tf;
        }

        if (phrase_tf > 0) {
            auto dl = live_checker.doc_len(posting_ord);
            auto tf_norm = static_cast<float>(phrase_tf) *
                           (params.k1 + 1.0F) /
                           (static_cast<float>(phrase_tf) + params.k1 *
                            (1.0F - params.b + params.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[posting_ord] += static_cast<float>(idf) * (tf_norm + params.delta);
        }
    }

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;
    for (auto& [ord, score] : scores) {
        if (heap.size() < k) {
            heap.push({score, ord});
        } else if (score > heap.top().first) {
            heap.pop();
            heap.push({score, ord});
        }
    }

    std::vector<SearchResult> results;
    results.reserve(heap.size());
    while (!heap.empty()) {
        auto& [score, ord] = heap.top();
        results.push_back({ord, score});
        heap.pop();
    }
    std::reverse(results.begin(), results.end());
    return results;
}

auto InvertedIndex::search_phrase(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    return search_phrase_impl(query_terms, k, /*slop=*/0, live_checker, params_override);
}

auto InvertedIndex::search_near(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    std::uint32_t slop,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    return search_phrase_impl(query_terms, k, slop, live_checker, params_override);
}

auto InvertedIndex::search_wildcard(
    const std::string& pattern,
    std::size_t k,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    const Bm25Params& params = params_override ? *params_override : params_;

    using TermPostings = ScoredTerm;  // 共用条目（term + 扁平快照）

    // P2.5：最长字面量预过滤——不含该子串的词必不匹配，免跑回溯匹配器
    // （string_view::find 底层是 SIMD 化的 memchr/memcmp）。
    const std::string_view lit = longest_literal(pattern);

    // V6.3.1：模式有「首段字面量」（首字符非通配符）→ 从该段起跑 binary search
    // 划出候选区间，再在区间内走最长字面量 + wildcard_match 精筛。中缀/后缀
    // 模式（pattern[0]=='*'）走全扫——排序数组虽 cache 友好但 binary search 失效。
    std::string prefix;
    if (!pattern.empty() && pattern[0] != '*') {
        for (char c : pattern) {
            if (c == '*' || c == '?') break;
            prefix.push_back(c);
        }
    }
    // upper_bound 端点用 prefix 的「下一个串」：末字节 +1 即可（例如 "te" → "tf"）。
    // empty prefix 表示走全扫分支。
    std::string prefix_upper;
    if (!prefix.empty()) {
        prefix_upper = prefix;
        prefix_upper.back() = static_cast<char>(static_cast<unsigned char>(prefix_upper.back()) + 1);
    }

    // S10.4：并行扫词表匹配 pattern。按 shard 下标分区，每个 shard 至多被一个任务
    // 遍历（互不重叠），与既有「查询无锁读」模型一致（拷贝 plist 不持桶锁）。
    // V6.3.1：每 shard 取排序 vocab_ 替代 hash_map 全扫 + sort——读路径吃
    // shared_lock（fast path）零分配，binary search 区间再经 lit + wildcard_match
    // 二次过滤。
    std::vector<TermPostings> tps = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, kShardCount),
        std::vector<TermPostings>{},
        [&](const tbb::blocked_range<std::size_t>& range, std::vector<TermPostings> local) {
            for (std::size_t s = range.begin(); s < range.end(); ++s) {
                auto vocab = ensure_vocab(s);
                const auto& v = *vocab;

                // 候选区间：prefix 模式用 [lower_bound(prefix), upper_bound(prefix_upper))，
                // 其它模式（无 prefix）用全 vocab。
                auto begin = v.begin();
                auto end   = v.end();
                if (!prefix.empty()) {
                    begin = std::lower_bound(v.begin(), v.end(), prefix);
                    end   = std::upper_bound(v.begin(), v.end(), prefix_upper);
                }

                // 两阶段：先在排序区间内跑 lit 预过滤 + wildcard_match 收 key；
                // 再逐 key 经 const_accessor 取值（并发不变量见 collect_term_keys）。
                for (auto it = begin; it != end; ++it) {
                    const std::string& t = *it;
                    if (!lit.empty() && t.find(lit) == std::string::npos) continue;
                    if (!wildcard_match(pattern, t)) continue;
                    PostingMap::const_accessor acc;
                    if (!shards_[s].inverted.find(acc, t)) continue;
                    TermPostings tp;
                    tp.term = t;
                    acc->second->snapshot_flat(tp.fp);
                    local.push_back(std::move(tp));
                }
            }
            return local;
        },
        [](std::vector<TermPostings> a, const std::vector<TermPostings>& b) {
            a.insert(a.end(), b.begin(), b.end());
            return a;
        });

    if (tps.empty()) return {};

    // bag-of-words 评分 + top-k（共享 kernel score_bow_topk）。
    return score_bow_topk(tps, k,
                          live_doc_count_.load(std::memory_order_relaxed),
                          sum_doc_len_.load(std::memory_order_relaxed),
                          params, live_checker);
}

auto InvertedIndex::bool_search(
    const QueryNode& query,
    std::size_t k,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    const Bm25Params& params = params_override ? *params_override : params_;
    std::vector<std::string> must_terms;
    std::vector<std::string> should_terms;
    std::vector<std::string> must_not_terms;
    collect_terms(query, must_terms, should_terms, must_not_terms);

    struct TermPostings {
        std::string term;
        FlatPostings fp;  // P1：扁平快照（S9.6 的 ords 缓存由 fp.ords 取代）
        bool is_must;
        std::vector<char> live;          // P2.1：live 批量取一次，多阶段复用
        std::vector<std::uint32_t> dls;  // P2.1：doc_len 批量取一次，评分循环复用
    };
    // 收集一个 term 的 posting 到 dst（accessor 下拷扁平快照）。
    auto collect = [&](const std::string& term, bool is_must,
                       std::vector<TermPostings>& dst) {
        auto& shard = shard_for(term);
        PostingMap::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            TermPostings tp;
            tp.term = term;
            acc->second->snapshot_flat(tp.fp);
            tp.is_must = is_must;
            dst.push_back(std::move(tp));
        }
    };

    std::vector<TermPostings> must_tps;
    must_tps.reserve(must_terms.size());
    for (auto& term : must_terms) collect(term, true, must_tps);

    std::vector<TermPostings> should_tps;
    should_tps.reserve(should_terms.size());
    for (auto& term : should_terms) collect(term, false, should_tps);

    std::vector<TermPostings> must_not_tps;
    must_not_tps.reserve(must_not_terms.size());
    for (auto& term : must_not_terms) collect(term, false, must_not_tps);

    // ── B1:must-only 合取 Block-Max 剪枝(设计:doc/kway-blockmax-bmw-zh.md §6)
    // top-k 驱动:K1 leapfrog 对齐候选;堆满后用块级分数上界跳过注定
    // 不竞争的整块;live/doc_len 按 128-ord 块懒取(每块一次虚调用+一次锁,
    // 未触达的块零成本)。idf 基于 df(无删除时与原路径位级一致,见 §6)。
    if (!must_terms.empty() && should_terms.empty() && must_not_terms.empty() &&
        k > 0) {
        if (must_tps.size() != must_terms.size()) return {};  // 缺词 → 空集

        const auto N = live_doc_count_.load(std::memory_order_relaxed);
        const auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
        const double avgdl =
            N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;
        constexpr std::size_t B = PostingList::kBlockSize;

        struct BmwCur {
            TermPostings* tp;
            std::size_t i = 0;               // posting 游标
            float idf = 0.0F;
            std::vector<char> block_filled;  // live/dls 是否已按块填充
            std::vector<float> block_ub;     // 块分数上界缓存
            std::vector<char> ub_done;
        };
        const std::size_t nterms = must_tps.size();
        std::vector<BmwCur> curs(nterms);
        {
            std::vector<std::size_t> order(nterms);
            for (std::size_t i = 0; i < nterms; ++i) order[i] = i;
            std::sort(order.begin(), order.end(),
                      [&](std::size_t a, std::size_t b2) {
                          return must_tps[a].fp.size() <
                                 must_tps[b2].fp.size();
                      });
            for (std::size_t s = 0; s < nterms; ++s) {
                auto& c = curs[s];
                c.tp = &must_tps[order[s]];
                const auto& fp = c.tp->fp;
                if (fp.empty()) return {};
                const auto df = static_cast<double>(fp.size());
                c.idf = static_cast<float>(std::log(
                    1.0 + (static_cast<double>(N) - df + 0.5) / (df + 0.5)));
                const std::size_t nblk = (fp.size() + B - 1) / B;
                c.tp->live.resize(fp.size());
                c.tp->dls.resize(fp.size());
                c.block_filled.assign(nblk, 0);
                c.block_ub.assign(nblk, 0.0F);
                c.ub_done.assign(nblk, 0);
            }
        }

        auto advance = [](BmwCur& c, std::uint64_t target) {
            const auto* o = c.tp->fp.ords.data();
            const std::size_t n = c.tp->fp.size();
            std::size_t lo = c.i;
            if (lo >= n || o[lo] >= target) return;
            std::size_t step = 1;
            std::size_t hi = lo + 1;
            while (hi < n && o[hi] < target) {
                lo = hi;
                hi += step;
                step <<= 1;
            }
            if (hi > n) hi = n;
            c.i = static_cast<std::size_t>(
                std::lower_bound(o + lo + 1, o + hi, target) - o);
        };

        // 懒填充:游标所在块的 live/doc_len 一次批量取(P2.1 的接口,
        // 块粒度复用)。
        auto ensure_block = [&](BmwCur& c) {
            const std::size_t b = c.i / B;
            if (c.block_filled[b]) return;
            auto& fp = c.tp->fp;
            const std::size_t start = b * B;
            const std::size_t cnt = std::min(B, fp.size() - start);
            live_checker.fill_is_live(
                std::span<const std::uint64_t>(fp.ords.data() + start, cnt),
                std::span<char>(c.tp->live.data() + start, cnt));
            live_checker.fill_doc_lens(
                std::span<const std::uint64_t>(fp.ords.data() + start, cnt),
                std::span<std::uint32_t>(c.tp->dls.data() + start, cnt));
            c.block_filled[b] = 1;
        };

        auto block_ub = [&](BmwCur& c) -> float {
            const std::size_t b = c.i / B;
            if (!c.ub_done[b]) {
                const auto& fp = c.tp->fp;
                // 尾块未 seal 无块元数据 → 列表级 max_tf + dl=1 退化(admissible)。
                const bool sealed = b < fp.blocks.size();
                const std::uint32_t mtf = sealed ? fp.blocks[b].max_tf
                                                 : fp.max_tf;
                const std::uint32_t mdl = sealed ? fp.blocks[b].min_dl : 1;
                c.block_ub[b] =
                    upper_bound_from(mtf, c.idf, params, avgdl, mdl);
                c.ub_done[b] = 1;
            }
            return c.block_ub[b];
        };

        auto block_end = [](const BmwCur& c) -> std::uint64_t {
            const std::size_t b = c.i / B;
            const auto& fp = c.tp->fp;
            return b < fp.blocks.size() ? fp.blocks[b].end_ord
                                        : fp.ords.back();
        };

        using Entry = std::pair<float, std::uint64_t>;
        std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;

        bool exhausted = false;
        while (!exhausted && curs[0].i < curs[0].tp->fp.size()) {
            const std::uint64_t v = curs[0].tp->fp.ords[curs[0].i];
            std::size_t j = 1;
            for (; j < nterms; ++j) {
                advance(curs[j], v);
                if (curs[j].i == curs[j].tp->fp.size()) {
                    exhausted = true;
                    break;
                }
                if (curs[j].tp->fp.ords[curs[j].i] != v) break;
            }
            if (exhausted) break;
            if (j < nterms) {
                // 被第 j 列表挡住:驱动游标跳到挡路值。
                advance(curs[0], curs[j].tp->fp.ords[curs[j].i]);
                continue;
            }

            if (heap.size() == k) {
                float ub = 0.0F;
                for (auto& c : curs) ub += block_ub(c);
                if (ub <= heap.top().first) {
                    // 当前各块的上界之和够不到 θ:整段跳过,不查 live
                    // 不评分。跳到各块末尾的最小值 +1。
                    std::uint64_t next = block_end(curs[0]);
                    for (std::size_t m = 1; m < nterms; ++m) {
                        next = std::min(next, block_end(curs[m]));
                    }
                    advance(curs[0], next + 1);
                    continue;
                }
            }

            bool all_live = true;
            for (auto& c : curs) {
                ensure_block(c);
                if (!c.tp->live[c.i]) {
                    all_live = false;
                    break;
                }
            }
            if (all_live) {
                float score = 0.0F;
                for (auto& c : curs) {
                    // 公式与原 must 评分循环逐运算一致(分数位级不变约定)。
                    auto tf_norm =
                        static_cast<float>(c.tp->fp.tfs[c.i]) *
                        (params.k1 + 1.0F) /
                        (static_cast<float>(c.tp->fp.tfs[c.i]) +
                         params.k1 *
                             (1.0F - params.b +
                              params.b *
                                  static_cast<float>(c.tp->dls[c.i]) /
                                  static_cast<float>(avgdl)));
                    score += c.idf * (tf_norm + params.delta);
                }
                if (heap.size() < k) {
                    heap.push({score, v});
                } else if (score > heap.top().first) {
                    heap.pop();
                    heap.push({score, v});
                }
            }
            ++curs[0].i;
        }

        std::vector<SearchResult> results;
        results.reserve(heap.size());
        while (!heap.empty()) {
            auto& [score, ord] = heap.top();
            results.push_back({ord, score});
            heap.pop();
        }
        std::reverse(results.begin(), results.end());
        return results;
    }

    // P2.1：每个 term 的 live 批量取一次（此前 must_not/交集/should/idf/评分
    // 五个阶段各自逐 posting 重扫 is_live——既重复又每次一锁）。
    // must/should 进评分循环，需 doc_len 批量（with_dls）；must_not 只用 live
    // 建排除集，免去 doc_len 取数。
    auto fill_live = [&](std::vector<TermPostings>& v, bool with_dls) {
        for (auto& tp : v) {
            tp.live.resize(tp.fp.size());
            live_checker.fill_is_live(tp.fp.ords, tp.live);
            if (with_dls) {
                tp.dls.resize(tp.fp.size());
                live_checker.fill_doc_lens(tp.fp.ords, tp.dls);
            }
        }
    };
    fill_live(must_tps, /*with_dls=*/true);
    fill_live(should_tps, /*with_dls=*/true);
    fill_live(must_not_tps, /*with_dls=*/false);

    std::vector<std::uint64_t> must_not_ords;
    for (auto& tp : must_not_tps) {
        for (std::size_t i = 0; i < tp.fp.size(); ++i) {
            if (tp.live[i]) {
                must_not_ords.push_back(tp.fp.ords[i]);
            }
        }
    }
    std::sort(must_not_ords.begin(), must_not_ords.end());
    must_not_ords.erase(std::unique(must_not_ords.begin(), must_not_ords.end()), must_not_ords.end());

    if (must_tps.empty() && should_tps.empty()) return {};

    std::vector<std::uint64_t> candidates;

    if (!must_tps.empty()) {
        bool all_terms_found = true;
        for (auto& term : must_terms) {
            auto& shard = shard_for(term);
            PostingMap::const_accessor acc;
            if (!shard.inverted.find(acc, term)) {
                all_terms_found = false;
                break;
            }
        }

        if (!all_terms_found) {
            return {};
        }

        // O4：按 posting 数升序处理 MUST——最短 list 先进交集，accumulator 尽早
        // 缩小；交集一旦为空提前退出。交集与处理顺序无关，结果集语义不变
        // （must_tps 本体不重排，评分用）。
        std::vector<std::size_t> must_order(must_tps.size());
        for (std::size_t i = 0; i < must_order.size(); ++i) must_order[i] = i;
        std::sort(must_order.begin(), must_order.end(),
                  [&](std::size_t a, std::size_t b) {
                      return must_tps[a].fp.size() <
                             must_tps[b].fp.size();
                  });

        // K1:k-way leapfrog 交集(替代 pairwise:k-1 轮中间 vector 物化
        // + 每轮 live 过滤拷贝)。k 个游标在各 posting 数组上同时推进,
        // 最短列表驱动,其余 galloping advance——大小不对称时天然亚线性。
        // 结果谓词与 pairwise 等价:ord ∈ 结果 ⟺ 出现在全部 MUST 列表
        // 且各列表 live 标志全真。这里定下的 advance(target) 形态就是
        // 后续块级元数据 / BMW 的游标接口(doc/kway-blockmax-bmw-zh.md)。
        auto run_must_intersect = [&] {
            std::vector<std::uint64_t> acc;
            const std::size_t k = must_order.size();

            // 单词退化:live 过滤直拷(与旧实现首词分支等价)。
            if (k == 1) {
                auto& tp = must_tps[must_order[0]];
                acc.reserve(tp.fp.size());
                for (std::size_t i = 0; i < tp.fp.size(); ++i) {
                    if (tp.live[i]) acc.push_back(tp.fp.ords[i]);
                }
                return acc;
            }

            // k==2 走 SIMD pairwise(intersect_u64:旋转内核 + galloping
            // 分发)。实测两热词形态 leapfrog 比 SIMD 慢 ~10-13%
            // (BoolMustHot 4096:44.3→50.3μs),两次 live 过滤拷贝的代价
            // 小于 SIMD 对标量的优势;k≥3 才轮到 leapfrog(收益来自
            // 消除 k-1 轮物化 + 多列表互相 gallop)。
            if (k == 2) {
                std::vector<std::uint64_t> a;
                std::vector<std::uint64_t> b;
                auto fill = [&](const TermPostings& tp,
                                std::vector<std::uint64_t>& dst) {
                    dst.reserve(tp.fp.size());
                    for (std::size_t i = 0; i < tp.fp.size(); ++i) {
                        if (tp.live[i]) dst.push_back(tp.fp.ords[i]);
                    }
                };
                fill(must_tps[must_order[0]], a);
                fill(must_tps[must_order[1]], b);
                intersect_u64(a, b, acc);
                return acc;
            }

            struct Cur {
                const std::uint64_t* ords;
                const char* live;
                std::size_t n;
                std::size_t i = 0;
            };
            std::vector<Cur> curs;
            curs.reserve(k);
            for (auto mi : must_order) {
                auto& tp = must_tps[mi];
                if (tp.fp.size() == 0) return acc;  // 任一列表空 → 交集空
                curs.push_back(Cur{tp.fp.ords.data(), tp.live.data(),
                                   tp.fp.size(), 0});
            }
            acc.reserve(curs[0].n);  // 上界 = 最短列表长度

            // advance:游标推到首个 ords[i] >= target 处(galloping +
            // 二分收尾)。游标只前进不回退——target 跨轮单调不减。
            auto advance = [](Cur& c, std::uint64_t target) {
                std::size_t lo = c.i;
                if (lo >= c.n || c.ords[lo] >= target) return;
                std::size_t step = 1;
                std::size_t hi = lo + 1;
                while (hi < c.n && c.ords[hi] < target) {
                    lo = hi;
                    hi += step;
                    step <<= 1;
                }
                if (hi > c.n) hi = c.n;
                // ords[lo] < target 已知,二分区间 (lo, hi)。
                c.i = static_cast<std::size_t>(
                    std::lower_bound(c.ords + lo + 1, c.ords + hi, target) -
                    c.ords);
            };

            while (curs[0].i < curs[0].n) {
                const std::uint64_t v = curs[0].ords[curs[0].i];
                std::size_t j = 1;
                for (; j < k; ++j) {
                    advance(curs[j], v);
                    if (curs[j].i == curs[j].n) return acc;  // 耗尽 → 结束
                    if (curs[j].ords[curs[j].i] != v) break; // 被挡住
                }
                if (j == k) {
                    // 全列表命中:liveness 全检后输出。
                    bool all_live = true;
                    for (std::size_t m = 0; m < k; ++m) {
                        if (!curs[m].live[curs[m].i]) {
                            all_live = false;
                            break;
                        }
                    }
                    if (all_live) acc.push_back(v);
                    ++curs[0].i;
                } else {
                    // 驱动游标直接跳到挡路值,跳过中间注定不在交集的区段。
                    advance(curs[0], curs[j].ords[curs[j].i]);
                }
            }
            return acc;
        };

        candidates = run_must_intersect();
    } else if (!should_tps.empty()) {
        for (auto& tp : should_tps) {
            for (std::size_t i = 0; i < tp.fp.size(); ++i) {
                if (tp.live[i]) {
                    candidates.push_back(tp.fp.ords[i]);
                }
            }
        }
        std::sort(candidates.begin(), candidates.end());
        candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());
    } else {
        return {};
    }

    // 注意：SHOULD 词在 MUST 非空时只参与打分（见下方评分循环），不扩大候选集。
    // 候选集已由上面确定（MUST → 交集；纯 SHOULD → 并集），此处不再追加 SHOULD ords，
    // 否则「只含 should、不含 must」的文档会错误进入结果（违反 MUST 语义）。

    std::vector<std::uint64_t> filtered;
    filtered.reserve(candidates.size());
    for (auto ord : candidates) {
        if (!std::binary_search(must_not_ords.begin(), must_not_ords.end(), ord)) {
            filtered.push_back(ord);
        }
    }
    candidates = std::move(filtered);

    if (candidates.empty()) return {};

    auto N = live_doc_count_.load(std::memory_order_relaxed);
    auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    std::vector<TermPostings> all_tps;
    all_tps.insert(all_tps.end(), must_tps.begin(), must_tps.end());
    all_tps.insert(all_tps.end(), should_tps.begin(), should_tps.end());

    std::sort(all_tps.begin(), all_tps.end(), [](const auto& a, const auto& b) {
        return a.term < b.term;
    });
    all_tps.erase(std::unique(all_tps.begin(), all_tps.end(), [](const auto& a, const auto& b) {
        return a.term == b.term;
    }), all_tps.end());

    std::unordered_map<std::string, float> term_idf;
    for (auto& tp : all_tps) {
        std::size_t live_df = 0;
        for (std::size_t i = 0; i < tp.fp.size(); ++i) {
            live_df += static_cast<std::size_t>(tp.live[i]);
        }
        if (live_df == 0) continue;
        auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) /
                          (static_cast<double>(live_df) + 0.5));
        term_idf[tp.term] = static_cast<float>(idf);
    }

    // 候选集与 posting ords 都是升序去重——评分用「平行分数数组 +
    // 每词双指针归并」O(|posting| + |candidates|)。替代原先的
    // unordered_map 播种:per-candidate 一次 hash 节点分配(实测
    // BoolMust 每查询 ~2 万次 malloc 即来源于此)+ 每 posting 一次
    // hash find,全部消除。
    std::vector<float> scores(candidates.size(), 0.0F);

    for (auto& tp : all_tps) {
        auto idf_it = term_idf.find(tp.term);
        if (idf_it == term_idf.end()) continue;
        auto idf = idf_it->second;

        std::size_t ci = 0;
        for (std::size_t i = 0;
             i < tp.fp.size() && ci < candidates.size(); ++i) {
            const auto posting_ord = tp.fp.ords[i];
            while (ci < candidates.size() && candidates[ci] < posting_ord) {
                ++ci;
            }
            if (ci == candidates.size()) break;
            if (candidates[ci] != posting_ord) continue;
            if (!tp.live[i]) continue;

            // P2.1：doc_len 读批量数组 tp.dls（此前逐 posting 一把 Index
            // shared_lock + 虚调用，大候选集下锁风暴；与其它路径对齐）。
            auto dl = tp.dls[i];
            auto tf_norm = static_cast<float>(tp.fp.tfs[i]) *
                           (params.k1 + 1.0F) /
                           (static_cast<float>(tp.fp.tfs[i]) + params.k1 *
                            (1.0F - params.b + params.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[ci] += idf * (tf_norm + params.delta);
        }
    }

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;

    for (std::size_t i = 0; i < candidates.size(); ++i) {
        const float score = scores[i];
        if (heap.size() < k) {
            heap.push({score, candidates[i]});
        } else if (score > heap.top().first) {
            heap.pop();
            heap.push({score, candidates[i]});
        }
    }

    std::vector<SearchResult> results;
    results.reserve(heap.size());
    while (!heap.empty()) {
        auto& [score, ord] = heap.top();
        results.push_back({ord, score});
        heap.pop();
    }
    std::reverse(results.begin(), results.end());
    return results;
}

auto InvertedIndex::search_fuzzy(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    std::uint32_t max_edit_distance,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    if (query_terms.empty()) return {};
    const Bm25Params& params = params_override ? *params_override : params_;

    using TermPostings = ScoredTerm;  // 共用条目（term + 扁平快照）
    std::vector<TermPostings> tps;

    // 翻转循环：vocab term 放外层、query term 放内层 + break。
    // ① S10.2：每个 vocab term 至多入 tps 一次——原先 query 多词模糊命中同一 term
    //    会重复 push，导致该 posting list 被评分两遍、IDF 贡献翻倍。
    // ② S10.3：跑 O(n·m) levenshtein 前先按字节长度差剪枝——编辑距离 ≥ |长度差|，
    //    故长度差 > max_edit 时必不匹配，省掉绝大多数 DP（levenshtein 按字节算，用字节长度）。
    // P2.3：每个查询词建一次 Myers matcher（Peq 表摊销于全词典扫描）。
    // 经典 DP O(n·m) + 每次调用两个 vector 堆分配 → 位并行 O(n)、零分配，
    // 原理见 doc/myers-bitparallel-zh.md，对拍见 fuzzy_test.cpp。
    std::vector<MyersMatcher> matchers;
    matchers.reserve(query_terms.size());
    for (auto& q : query_terms) matchers.emplace_back(q);

    for (auto& shard : shards_) {
        // V6.3.1：用排序 vocab_ 替代 collect_term_keys 的 hash_map 全扫 + sort。
        // 模糊匹配编辑距离不保 lexicographic 序 → 不能 binary search，只能线性
        // 扫；但排序 vector 比 hash_map 节点 cache 友好得多（连续 string 数组
        // 顺次访问，无链表间接跳转），且 O(N log N) sort 折到「首次搜索后惰性」
        // 一次摊销。
        auto vocab = ensure_vocab(static_cast<std::size_t>(&shard - shards_.data()));
        for (const auto& term : *vocab) {
            bool hit = false;
            for (std::size_t qi = 0; qi < query_terms.size(); ++qi) {
                auto& query_term = query_terms[qi];
                auto len_diff = term.size() > query_term.size()
                                    ? term.size() - query_term.size()
                                    : query_term.size() - term.size();
                if (len_diff > max_edit_distance) continue;
                if (matchers[qi].within(term, max_edit_distance)) {
                    hit = true;
                    break;
                }
            }
            if (!hit) continue;
            PostingMap::const_accessor acc;
            if (!shard.inverted.find(acc, term)) continue;
            TermPostings tp;
            tp.term = term;
            acc->second->snapshot_flat(tp.fp);
            tps.push_back(std::move(tp));
        }
    }

    if (tps.empty()) return {};

    // bag-of-words 评分 + top-k（共享 kernel score_bow_topk）。
    return score_bow_topk(tps, k,
                          live_doc_count_.load(std::memory_order_relaxed),
                          sum_doc_len_.load(std::memory_order_relaxed),
                          params, live_checker);
}

// ---- 统计 ----

auto InvertedIndex::live_doc_count() const -> std::uint64_t {
    return live_doc_count_.load(std::memory_order_relaxed);
}

auto InvertedIndex::sum_doc_len() const -> std::uint64_t {
    return sum_doc_len_.load(std::memory_order_relaxed);
}

auto InvertedIndex::avg_doc_len() const -> double {
    auto n = live_doc_count_.load(std::memory_order_relaxed);
    if (n == 0) return 0.0;
    return static_cast<double>(sum_doc_len_.load(std::memory_order_relaxed)) / static_cast<double>(n);
}

auto InvertedIndex::df(std::string_view term) const -> std::size_t {
    auto& shard = shard_for(term);
    PostingMap::const_accessor acc;
    if (!shard.inverted.find(acc, std::string(term))) return 0;
    return acc->second->items.size();
}

auto InvertedIndex::df_live(std::string_view term, const LiveChecker& live_checker) const -> std::size_t {
    auto& shard = shard_for(term);
    PostingMap::const_accessor acc;
    if (!shard.inverted.find(acc, std::string(term))) return 0;
    std::size_t count = 0;
    for (auto& posting : acc->second->items) {
        if (live_checker.is_live(posting.ord)) ++count;
    }
    return count;
}

void InvertedIndex::finalize_all_postings() {
    // 先快照全部 key，再逐 key 持写 accessor 经 mutable_pl 修改（迭代器裸改
    // 会绕过 CoW 协议；并发不变量见 collect_term_keys）。
    for (auto& shard : shards_) {
        auto keys = collect_term_keys(shard.inverted,
                                      [](const std::string&) { return true; });
        for (auto& key : keys) {
            PostingMap::accessor acc;
            if (!shard.inverted.find(acc, key)) continue;
            mutable_pl(acc->second).finalize();
        }
        // V6.3.1：finalize 不改 key 集合，但 conservative 标脏——下次搜索重建
        // vocab_ 即可（rebuild 廉价，N log N 一遍）。
        shard.vocab_dirty_.store(true, std::memory_order_release);
    }
}

auto InvertedIndex::compact(const LiveChecker& live_checker, double dead_ratio_threshold)
    -> std::size_t {
    std::size_t compacted = 0;
    for (auto& shard : shards_) {
        // 先快照 key 列表，再逐 key 持写 accessor 压实：写锁与并发查询的
        // const_accessor 互斥，保证查询不读到半压实状态（不变量见
        // collect_term_keys）。
        auto keys = collect_term_keys(shard.inverted,
                                      [](const std::string&) { return true; });
        std::vector<std::uint64_t> ords_buf;
        std::vector<char> live_buf;
        for (auto& key : keys) {
            PostingMap::accessor acc;
            if (!shard.inverted.find(acc, key)) continue;
            const PostingList& pl = *acc->second;
            if (pl.items.empty()) continue;

            // P2.4：live 批量取一次——此前死点统计与压实各自逐 posting
            // 一次带锁虚调用（大列表 = 数十万次锁）。
            ords_buf.resize(pl.items.size());
            for (std::size_t i = 0; i < pl.items.size(); ++i) {
                ords_buf[i] = pl.items[i].ord;
            }
            live_buf.resize(ords_buf.size());
            live_checker.fill_is_live(ords_buf, live_buf);

            std::size_t dead = 0;
            for (std::size_t i = 0; i < live_buf.size(); ++i) {
                dead += static_cast<std::size_t>(!live_buf[i]);
            }
            if (dead == 0) continue;
            double ratio = static_cast<double>(dead) / static_cast<double>(pl.items.size());
            if (ratio < dead_ratio_threshold) continue;

            // mutable_pl 可能因 phrase 读者持引用而克隆——克隆保序保内容，
            // live_buf 与 items 的下标对齐不受影响。
            if (mutable_pl(acc->second).compact_flags(live_buf)) {
                ++compacted;
            }
        }
        // V6.3.1：compact 不删 key（保留空 posting list 是有意设计——避免与
        // 写者抢桶锁），但保守标脏便于下次搜索重建 vocab_。
        shard.vocab_dirty_.store(true, std::memory_order_release);
    }
    return compacted;
}

// ---- 持久化 ----

static constexpr std::uint32_t kInvMagic   = 0x494E5632;
// v6：ord 改用 FOR(Frame-of-Reference) 块压缩（128/块），TFs/dls 改用 VByte varint
//     整组编码；不再支持 v1..v5（旧快照需先经外部工具迁移或不加载）。
static constexpr std::uint32_t kInvVersion = 6;

// load() 反序列化上限：防止损坏或恶意文件触发 OOM。
static constexpr std::uint32_t kMaxPostingsPerTerm     = 1u << 24;  // ~16M
static constexpr std::uint32_t kMaxPositionsPerPosting = 1u << 20;  // ~1M
static constexpr std::uint32_t kMaxBlocksPerTerm       = 1u << 17;  // ~131k

// FOR (Frame of Reference) 块压缩：对一块已排序 ord 序列，按 (frame, bits, packed)
// 三元组编码。frame = 块内最小 ord（升序故 = 第一条），delta[i] = ords[i] - frame；
// bits = ceil(log2(max_delta+1))（max_delta=0 时 bits=0，无 packed 字节）。
// 解码：delta[i] = unpack(packed, i, bits); ords[i] = frame + delta[i]。
namespace {

// 把一个 uint64 值的低 bits 位塞入 dst 的第 bit_pos 位起，返回新 bit_pos。
// 大端序：值的高位先写；单字节内 0 位 = 最高位。
inline std::size_t for_pack_u64(std::uint64_t v, std::uint8_t bits,
                               std::uint8_t* dst, std::size_t bit_pos) {
    for (int b = static_cast<int>(bits) - 1; b >= 0; --b) {
        std::size_t i = bit_pos >> 3;
        std::size_t off = bit_pos & 7;
        std::uint8_t bit = static_cast<std::uint8_t>((v >> b) & 1);
        dst[i] |= static_cast<std::uint8_t>(bit << (7 - off));
        ++bit_pos;
    }
    return bit_pos;
}

// 从 src 第 bit_pos 起读 bits 位，组装为 uint64（值的高位在前）。
inline std::uint64_t for_unpack_u64(const std::uint8_t* src, std::size_t bit_pos,
                                    std::uint8_t bits) {
    std::uint64_t v = 0;
    for (std::uint8_t b = 0; b < bits; ++b) {
        std::size_t i = bit_pos >> 3;
        std::size_t off = bit_pos & 7;
        std::uint8_t bit = static_cast<std::uint8_t>((src[i] >> (7 - off)) & 1);
        v = (v << 1) | bit;
        ++bit_pos;
    }
    return v;
}

inline void for_encode_block(const std::uint64_t* ords, std::size_t count,
                             std::uint64_t& frame, std::uint8_t& bits,
                             std::vector<std::uint8_t>& packed) {
    frame = ords[0];
    if (count == 1) {
        bits = 0;
        packed.clear();
        return;
    }
    std::uint64_t max_delta = ords[count - 1] - frame;
    if (max_delta == 0) {
        bits = 0;
        packed.clear();
        return;
    }
    // ceil(log2(max_delta+1))
    std::uint8_t need = 0;
    std::uint64_t m = max_delta;
    while (m > 0) { ++need; m >>= 1; }
    bits = need;
    std::size_t total_bits = static_cast<std::size_t>(bits) * count;
    std::size_t total_bytes = (total_bits + 7) >> 3;
    packed.assign(total_bytes, 0);
    std::size_t pos = 0;
    for (std::size_t i = 0; i < count; ++i) {
        pos = for_pack_u64(ords[i] - frame, bits, packed.data(), pos);
    }
}

inline void for_decode_block(std::uint64_t frame, std::uint8_t bits,
                             const std::uint8_t* packed,
                             std::size_t count, std::uint64_t* out) {
    if (bits == 0) {
        for (std::size_t i = 0; i < count; ++i) out[i] = frame;
        return;
    }
    std::size_t pos = 0;
    for (std::size_t i = 0; i < count; ++i) {
        out[i] = frame + for_unpack_u64(packed, pos, bits);
        pos += bits;
    }
}

}  // namespace

void InvertedIndex::serialize(std::vector<std::byte>& out) const {
    // P14e:I/O 改为追加缓冲(原生小端,字节与旧 FILE 版完全一致);追加不会
    // 失败,故去掉所有 ok/fclose 错误样板。并发安全遍历(collect_term_keys +
    // const_accessor 快照)逐字保留。
    std::uint32_t N = static_cast<std::uint32_t>(live_doc_count_.load(std::memory_order_relaxed));
    std::uint64_t sdl = sum_doc_len_.load(std::memory_order_relaxed);

    auto put = [&](const void* p, std::size_t n) {
        const auto* b = reinterpret_cast<const std::byte*>(p);
        out.insert(out.end(), b, b + n);
    };
    auto write_u32 = [&](std::uint32_t v) { put(&v, 4); };
    auto write_u64 = [&](std::uint64_t v) { put(&v, 8); };
    auto write_u8  = [&](std::uint8_t  v) { put(&v, 1); };

    // positions：沿用 v4+ 的 gap+VByte 压缩（u32 原始个数 + u32 压缩字节数 + 字节流）。
    auto write_positions = [&](const std::vector<std::uint32_t>& positions) {
        write_u32(static_cast<std::uint32_t>(positions.size()));
        std::vector<std::uint64_t> tmp(positions.begin(), positions.end());
        auto comp = codec::gap_encode(tmp);
        write_u32(static_cast<std::uint32_t>(comp.size()));
        if (!comp.empty()) put(comp.data(), comp.size());
    };

    write_u32(kInvMagic);
    write_u32(kInvVersion);
    write_u32(N);
    write_u64(sdl);

    constexpr std::size_t kBlock = PostingList::kBlockSize;

    for (auto& shard : shards_) {
        // 安全遍历:先快照 key,再逐 key 经 const_accessor 取 shared_ptr。
        // save 在 merge 线程跑,与 put→worker 的 add_doc 并发——裸遍历
        // concurrent_hash_map 会因懒 rehash 重访/漏访,裸读 plsp 还会撞上
        // CoW 替换/撕裂(不变量集中见 collect_term_keys)。const_accessor 持
        // shared_ptr 期间数据 immutable(写者见 use_count>1 则克隆)。
        auto keys = collect_term_keys(shard.inverted,
                                      [](const std::string&) { return true; });
        std::vector<std::pair<const std::string*, std::shared_ptr<PostingList>>> snap;
        snap.reserve(keys.size());
        for (const auto& key : keys) {
            PostingMap::const_accessor acc;
            if (shard.inverted.find(acc, key)) {
                snap.emplace_back(&key, acc->second);
            }
        }

        write_u32(static_cast<std::uint32_t>(snap.size()));

        for (auto& [termp, plsp] : snap) {
            const std::string& term = *termp;
            const PostingList& pl = *plsp;
            auto tlen = static_cast<std::uint32_t>(term.size());
            write_u32(tlen);
            put(term.data(), tlen);

            auto pc = static_cast<std::uint32_t>(pl.items.size());
            write_u32(pc);

            // v6：ord 改用 FOR 块压缩（128/块）。
            std::size_t ord_block_count = (pc + kBlock - 1) / kBlock;
            write_u32(static_cast<std::uint32_t>(ord_block_count));
            for (std::size_t b = 0; b < ord_block_count; ++b) {
                std::size_t start = b * kBlock;
                std::size_t cnt = std::min(kBlock, static_cast<std::size_t>(pc) - start);
                std::uint64_t frame;
                std::uint8_t  bits;
                std::vector<std::uint8_t> packed;
                std::vector<std::uint64_t> ords_view(cnt);
                for (std::size_t i = 0; i < cnt; ++i) {
                    ords_view[i] = pl.items[start + i].ord;
                }
                for_encode_block(ords_view.data(), cnt, frame, bits, packed);
                auto packed_len = static_cast<std::uint32_t>(packed.size());
                write_u64(frame);
                write_u8(bits);
                write_u32(packed_len);
                if (packed_len > 0) put(packed.data(), packed_len);
            }

            // v6：TFs/dls 改用 VByte varint 整组编码（每个 tf 通常 1-10，占 1B）。
            // 逐项 tf=0 也合法，VByte 对 0 仍编 1B（0x80），正确。
            {
                std::vector<std::uint8_t> tf_buf;
                tf_buf.reserve(pc);
                for (auto& posting : pl.items) {
                    codec::vbyte_encode(posting.tf, tf_buf);
                }
                write_u32(static_cast<std::uint32_t>(tf_buf.size()));
                if (!tf_buf.empty()) put(tf_buf.data(), tf_buf.size());
            }
            {
                std::vector<std::uint8_t> dl_buf;
                dl_buf.reserve(pc);
                for (auto& posting : pl.items) {
                    codec::vbyte_encode(posting.dl, dl_buf);
                }
                write_u32(static_cast<std::uint32_t>(dl_buf.size()));
                if (!dl_buf.empty()) put(dl_buf.data(), dl_buf.size());
            }

            // positions：保持 v4+ 的逐 posting gap+VByte 格式不变。
            for (auto& posting : pl.items) {
                write_positions(posting.positions);
            }

            // Block-Max WAND 元数据：保持 v5 结构。
            write_u32(static_cast<std::uint32_t>(pl.blocks.size()));
            for (auto& blk : pl.blocks) {
                write_u64(blk.base_ord);
                write_u64(blk.end_ord);
                write_u32(blk.max_tf);
                write_u32(blk.min_dl);
                write_u32(static_cast<std::uint32_t>(blk.start_idx));
                write_u32(static_cast<std::uint32_t>(blk.count));
            }
        }
    }
}

auto InvertedIndex::save(std::string_view path) const -> bool {
    std::vector<std::byte> buf;
    serialize(buf);
    auto* f = std::fopen(std::string(path).c_str(), "wb");
    if (!f) return false;
    const bool wrote =
        buf.empty() || std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    return wrote;
}

auto InvertedIndex::load(std::string_view path) -> bool {
    auto* f = std::fopen(std::string(path).c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long fsz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<std::byte> buf;
    bool rd = (fsz >= 0);
    if (rd) {
        buf.resize(static_cast<std::size_t>(fsz));
        rd = buf.empty() ||
             std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    }
    std::fclose(f);
    if (!rd) return false;
    return deserialize(buf);
}

auto InvertedIndex::deserialize(std::span<const std::byte> bytes) -> bool {
    // P14e:从字节缓冲反序列化,游标带界检查;读越界返回哨兵(同旧 fread 短读
    // 语义,下游既有哨兵判定捕获)。原生小端,字节与 save() 一致。
    const std::byte* d = bytes.data();
    const std::size_t n = bytes.size();
    std::size_t pos = 0;
    auto read_u32 = [&]() -> std::uint32_t {
        if (pos + 4 > n) return 0xFFFFFFFF;
        std::uint32_t v; std::memcpy(&v, d + pos, 4); pos += 4; return v;
    };
    auto read_u64 = [&]() -> std::uint64_t {
        if (pos + 8 > n) return 0xFFFFFFFFFFFFFFFF;
        std::uint64_t v; std::memcpy(&v, d + pos, 8); pos += 8; return v;
    };
    auto read_u8 = [&]() -> std::uint8_t {
        if (pos + 1 > n) return 0xFF;
        std::uint8_t v = static_cast<std::uint8_t>(d[pos]); pos += 1; return v;
    };
    // 读 len 字节进 dst;越界返回 false(同旧 fread 短读失败)。
    auto read_bytes = [&](void* dst, std::size_t len) -> bool {
        if (pos + len > n) return false;
        if (len > 0) std::memcpy(dst, d + pos, len);
        pos += len;
        return true;
    };

    auto magic = read_u32();
    auto ver = read_u32();
    if (magic != kInvMagic) {
        return false;
    }
    // v6 不再兼容 v1..v5：项目规则「不考虑向后兼容性」，旧快照直接拒绝。
    if (ver != kInvVersion) {
        return false;
    }

    auto N = read_u32();
    auto sdl = read_u64();

    constexpr std::size_t kBlock = PostingList::kBlockSize;

    for (auto& shard : shards_) {
        auto term_count = read_u32();
        if (term_count == 0xFFFFFFFF) { return false; }

        for (std::uint32_t t = 0; t < term_count; ++t) {
            auto tlen = read_u32();
            if (tlen == 0xFFFFFFFF || tlen > 1024) { return false; }

            std::string term(tlen, '\0');
            if (!read_bytes(term.data(), tlen)) return false;

            auto pc = read_u32();
            if (pc == 0xFFFFFFFF || pc > kMaxPostingsPerTerm) {
                return false;
            }

            PostingList pl;
            pl.items.resize(pc);

            // v6：ord 走 FOR 块压缩。
            auto ord_block_count = read_u32();
            if (ord_block_count == 0xFFFFFFFF) { return false; }
            if (ord_block_count != ((pc + kBlock - 1) / kBlock)) {
                return false;
            }
            for (std::uint32_t b = 0; b < ord_block_count; ++b) {
                auto frame = read_u64();
                auto bits  = read_u8();
                auto packed_len = read_u32();
                if (frame == 0xFFFFFFFFFFFFFFFF || packed_len == 0xFFFFFFFF) {
                    return false;
                }
                std::size_t start = static_cast<std::size_t>(b) * kBlock;
                std::size_t cnt = std::min(kBlock, static_cast<std::size_t>(pc) - start);
                std::vector<std::uint8_t> packed(packed_len);
                if (packed_len > 0 && !read_bytes(packed.data(), packed_len)) {
                    return false;
                }
                std::vector<std::uint64_t> ords_buf(cnt);
                for_decode_block(frame, bits, packed.data(), cnt, ords_buf.data());
                for (std::size_t i = 0; i < cnt; ++i) {
                    pl.items[start + i].ord = ords_buf[i];
                }
            }

            // v6：TFs 整组 VByte 解码。
            {
                auto tf_csize = read_u32();
                if (tf_csize == 0xFFFFFFFF) { return false; }
                std::vector<std::uint8_t> tf_buf(tf_csize);
                if (tf_csize > 0 && !read_bytes(tf_buf.data(), tf_csize)) {
                    return false;
                }
                std::size_t pos = 0;
                for (std::uint32_t p = 0; p < pc; ++p) {
                    auto [val, np] = codec::vbyte_decode(tf_buf.data(), pos);
                    pl.items[p].tf = static_cast<std::uint32_t>(val);
                    pos = np;
                }
                if (pos != tf_csize) { return false; }
            }

            // v6：dls 整组 VByte 解码。
            {
                auto dl_csize = read_u32();
                if (dl_csize == 0xFFFFFFFF) { return false; }
                std::vector<std::uint8_t> dl_buf(dl_csize);
                if (dl_csize > 0 && !read_bytes(dl_buf.data(), dl_csize)) {
                    return false;
                }
                std::size_t pos = 0;
                for (std::uint32_t p = 0; p < pc; ++p) {
                    auto [val, np] = codec::vbyte_decode(dl_buf.data(), pos);
                    pl.items[p].dl = static_cast<std::uint32_t>(val);
                    pos = np;
                }
                if (pos != dl_csize) { return false; }
            }

            // positions：与 v4+ 同——每 posting (u32 个数 + u32 压缩字节数 + 字节流)。
            for (std::uint32_t p = 0; p < pc; ++p) {
                auto posc = read_u32();
                if (posc == 0xFFFFFFFF || posc > kMaxPositionsPerPosting) {
                    return false;
                }
                auto csize = read_u32();
                if (csize == 0xFFFFFFFF) { return false; }
                std::vector<std::uint8_t> comp(csize);
                if (csize > 0 && !read_bytes(comp.data(), csize)) {
                    return false;
                }
                auto vals = codec::gap_decode(comp);
                if (vals.size() != posc) { return false; }
                pl.items[p].positions.resize(posc);
                for (std::uint32_t i = 0; i < posc; ++i) {
                    pl.items[p].positions[i] = static_cast<std::uint32_t>(vals[i]);
                }
            }

            // Block-Max WAND 元数据：保持 v5 结构。
            auto block_count = read_u32();
            if (block_count == 0xFFFFFFFF || block_count > kMaxBlocksPerTerm) {
                return false;
            }
            pl.blocks.resize(block_count);
            for (std::uint32_t b = 0; b < block_count; ++b) {
                pl.blocks[b].base_ord = read_u64();
                pl.blocks[b].end_ord = read_u64();
                pl.blocks[b].max_tf = read_u32();
                pl.blocks[b].min_dl = read_u32();
                pl.blocks[b].start_idx = read_u32();
                pl.blocks[b].count = read_u32();
            }

            // S10.9：load 后重算缓存的 global max_tf（落盘格式不含此字段，派生量）。
            // 同时重建 add_doc 水位 = 全局最大 ord（落盘亦不含，派生量）；
            // 用 -1 哨兵区分「未索引任何」与「ord=0」。
            for (auto& p : pl.items) {
                if (p.tf > pl.max_tf) pl.max_tf = p.tf;
                // load 单线程,relaxed 足够。
                const std::uint64_t wm = max_indexed_ord_.load(std::memory_order_relaxed);
                if (wm == static_cast<std::uint64_t>(-1) || p.ord > wm) {
                    max_indexed_ord_.store(p.ord, std::memory_order_relaxed);
                }
            }
            shard.inverted.emplace(std::move(term), std::make_shared<PostingList>(std::move(pl)));
        }
    }

    live_doc_count_.store(N, std::memory_order_relaxed);
    sum_doc_len_.store(sdl, std::memory_order_relaxed);

    // V6.3.1：load 期间各 shard 走 emplace 填入；shards_ 默认构造的 vocab_dirty_
    // 已为 true，但保险起见显式置一次，覆盖将来构造路径变更。
    for (auto& shard : shards_) {
        shard.vocab_dirty_.store(true, std::memory_order_release);
    }

    return true;
}

void InvertedIndex::enable_wal(std::string_view path, std::size_t batch_size) {
    wal_path_ = path;
    wal_ = std::make_unique<InvertedWal>(path, batch_size);
}

void InvertedIndex::disable_wal() {
    if (wal_) {
        wal_->truncate();
        wal_.reset();
    }
}

void InvertedIndex::truncate_wal() {
    if (wal_) wal_->truncate();
}

int InvertedIndex::replay_wal() {
    if (!wal_) return 0;
    // 重放时临时移交 WAL 所有权，避免 add_doc → wal_->append 的递归写入死循环。
    auto saved = std::move(wal_);
    int count = saved->replay(*this);
    wal_ = std::move(saved);
    // 重放完成后截断 WAL（条目已进入内存索引，不再需要）。
    if (count >= 0) wal_->truncate();
    return count;
}

}  // namespace bitcask::bm25
