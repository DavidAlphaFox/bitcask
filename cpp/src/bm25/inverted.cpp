#include "bitcask/inverted.hpp"
#include "bitcask/inverted_wal.hpp"
#include "bitcask/myers.hpp"
#include "bitcask/wildcard_matcher.hpp"

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

float upper_bound_from(std::uint32_t global_max_tf, float idf,
                       const Bm25Params& params, double avgdl) {
    float tf_norm = static_cast<float>(global_max_tf) * (params.k1 + 1.0f) /
                    (static_cast<float>(global_max_tf) + params.k1 *
                     (1.0f - params.b + params.b * 1.0f / static_cast<float>(avgdl)));
    // BM25+：上界含 δ 下界项，与实际评分一致，避免 WAND 剪枝漏结果（S8.10）。
    return idf * (tf_norm + params.delta);
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

// ---- 写 ----

void InvertedIndex::add_doc(
    std::uint64_t ord,
    const TermPositions& term_data) {
    auto doc_len = std::uint32_t{0};
    for (auto& [term, data] : term_data) {
        auto& [tf, positions] = data;
        auto& shard = shard_for(term);
        PostingMap::accessor acc;
        shard.inverted.insert(acc, term);
        PostingList& pl = mutable_pl(acc->second);  // P2-min：有 phrase 读者持引用时 CoW
        // S10.10：index_positions_=false 时不存 positions（省内存，短语/近邻失效）。
        if (index_positions_) {
            pl.items.push_back({ord, tf, positions});
        } else {
            pl.items.push_back({ord, tf, {}});
        }
        pl.note_appended();  // S10.6：增量封块，在线索引也吃 WAND 块跳跃
        doc_len += tf;
    }

    live_doc_count_.fetch_add(1, std::memory_order_relaxed);
    sum_doc_len_.fetch_add(doc_len, std::memory_order_relaxed);

    if (wal_) wal_->append_add_doc(ord, WalTermPositions(term_data.begin(), term_data.end()));
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
    struct TermPostings {
        std::string term;
        FlatPostings fp;
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

    // 检查是否启用 WAND 路径（posting 总量足够大时才值得）。
    std::size_t total_postings = 0;
    for (auto& tp : tps) total_postings += tp.fp.size();
    if (total_postings >= kWandThreshold) {
        return search_wand(query_terms, k, live_checker, params);
    }

    // 读取全局统计（atomic load，S10.1 去锁）。
    auto N = live_doc_count_.load(std::memory_order_relaxed);
    auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // 并行 BM25 评分：parallel_reduce 按查询词分片，线程本地 map 无锁累加。
    using ScoreMap = std::unordered_map<std::uint64_t, float>;

    ScoreMap scores = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, tps.size()),
        ScoreMap{},
        [&](const tbb::blocked_range<std::size_t>& range, ScoreMap local) {
            for (std::size_t ti = range.begin(); ti < range.end(); ++ti) {
                auto& fp = tps[ti].fp;
                const std::size_t n = fp.size();

                // P2.1：live/doc_len 批量取——一次虚调用（Index 侧一次锁）完成
                // 整列，评分浮点循环不再含虚调用，编译器可自动向量化。
                std::vector<char> live(n);
                live_checker.fill_is_live(fp.ords, live);
                std::size_t live_df = 0;
                for (std::size_t i = 0; i < n; ++i) {
                    live_df += static_cast<std::size_t>(live[i]);
                }
                if (live_df == 0) continue;

                auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

                std::vector<std::uint32_t> dls(n);
                live_checker.fill_doc_lens(fp.ords, dls);

                // 两阶段评分：① 纯数组浮点（可向量化；死点也算、结果不用，
                // 保持无分支），公式与原逐 posting 版逐运算一致（分数位级不变）；
                // ② 标量 scatter 进线程本地 map（hash 写无法向量化）。
                std::vector<float> contrib(n);
                const float fidf = static_cast<float>(idf);
                for (std::size_t i = 0; i < n; ++i) {
                    auto tf_norm = static_cast<float>(fp.tfs[i]) *
                                   (params.k1 + 1.0F) /
                                   (static_cast<float>(fp.tfs[i]) + params.k1 *
                                    (1.0F - params.b + params.b *
                                     static_cast<float>(dls[i]) / static_cast<float>(avgdl)));
                    contrib[i] = fidf * (tf_norm + params.delta);
                }
                for (std::size_t i = 0; i < n; ++i) {
                    if (live[i]) local[fp.ords[i]] += contrib[i];
                }
            }
            return local;
        },
        [](ScoreMap a, const ScoreMap& b) {
            for (auto& [doc, score] : b) {
                a[doc] += score;
            }
            return a;
        }
    );

    // top-k 堆。
    using Entry = std::pair<float, std::uint64_t>;  // (score, ord)，按 score 小顶
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
    // 按分数降序。
    std::reverse(results.begin(), results.end());
    return results;
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

        bool any_skipped = false;
        for (std::size_t i = 0; i <= pivot_pos; ++i) {
            auto& tp = tps[order[i]];
            if (tp.cursor >= tp.fp.ords.size()) continue;
            if (tp.fp.ords[tp.cursor] != pivot_ord) continue;

            const auto* block = tp.fp.block_for_ord(pivot_ord);
            if (block != nullptr) {
                float block_tf_norm = static_cast<float>(block->max_tf) * (params.k1 + 1.0f) /
                                      (static_cast<float>(block->max_tf) + params.k1 *
                                       (1.0f - params.b + params.b * 1.0f / static_cast<float>(avgdl)));
                float block_upper = tp.idf * (block_tf_norm + params.delta);
                float remaining_needed = threshold;
                if (!heap.empty()) remaining_needed = threshold - heap.top().first + 1e-6f;
                if (block_upper < remaining_needed) {
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

    struct TermPostings {
        std::string term;
        FlatPostings fp;  // P1：扁平快照
    };

    // S10.4：并行扫词表匹配 pattern。按 shard 下标分区，每个 shard 至多被一个任务
    // 遍历（互不重叠），与既有「查询无锁读」模型一致（拷贝 plist 不持桶锁）。
    std::vector<TermPostings> tps = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, kShardCount),
        std::vector<TermPostings>{},
        [&](const tbb::blocked_range<std::size_t>& range, std::vector<TermPostings> local) {
            for (std::size_t s = range.begin(); s < range.end(); ++s) {
                // P2-min 两阶段：遍历只收集匹配的 key——遍历中调 find 会触发
                // concurrent_hash_map 的懒 rehash 节点搬迁，迭代器会重复访问
                // 同一节点（实测复现）。值统一在遍历结束后经 const_accessor 读
                //（slot 上的 shared_ptr 可能被写者 CoW 替换，裸读会撕裂）。
                std::vector<std::string> matched;
                for (auto it = shards_[s].inverted.begin();
                     it != shards_[s].inverted.end(); ++it) {
                    if (wildcard_match(pattern, it->first)) {
                        matched.push_back(it->first);
                    }
                }
                std::sort(matched.begin(), matched.end());
                matched.erase(std::unique(matched.begin(), matched.end()), matched.end());
                for (auto& term : matched) {
                    PostingMap::const_accessor acc;
                    if (!shards_[s].inverted.find(acc, term)) continue;
                    TermPostings tp;
                    tp.term = term;
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

    auto N = live_doc_count_.load(std::memory_order_relaxed);
    auto sum_dl = sum_doc_len_.load(std::memory_order_relaxed);
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    using ScoreMap = std::unordered_map<std::uint64_t, float>;

    ScoreMap scores = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, tps.size()),
        ScoreMap{},
        [&](const tbb::blocked_range<std::size_t>& range, ScoreMap local) {
            for (std::size_t ti = range.begin(); ti < range.end(); ++ti) {
                auto& fp = tps[ti].fp;
                const std::size_t n = fp.size();

                // P2.1：批量取 live/doc_len + 两阶段评分（同 search()，
                // ①纯浮点可向量化 ②标量 scatter；公式逐运算一致）。
                std::vector<char> live(n);
                live_checker.fill_is_live(fp.ords, live);
                std::size_t live_df = 0;
                for (std::size_t i = 0; i < n; ++i) {
                    live_df += static_cast<std::size_t>(live[i]);
                }
                if (live_df == 0) continue;

                auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

                std::vector<std::uint32_t> dls(n);
                live_checker.fill_doc_lens(fp.ords, dls);

                std::vector<float> contrib(n);
                const float fidf = static_cast<float>(idf);
                for (std::size_t i = 0; i < n; ++i) {
                    auto tf_norm = static_cast<float>(fp.tfs[i]) *
                                   (params.k1 + 1.0F) /
                                   (static_cast<float>(fp.tfs[i]) + params.k1 *
                                    (1.0F - params.b + params.b *
                                     static_cast<float>(dls[i]) / static_cast<float>(avgdl)));
                    contrib[i] = fidf * (tf_norm + params.delta);
                }
                for (std::size_t i = 0; i < n; ++i) {
                    if (live[i]) local[fp.ords[i]] += contrib[i];
                }
            }
            return local;
        },
        [](ScoreMap a, const ScoreMap& b) {
            for (auto& [doc, score] : b) {
                a[doc] += score;
            }
            return a;
        }
    );

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
        std::vector<char> live;  // P2.1：live 批量取一次，5 个使用阶段复用
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

    // P2.1：每个 term 的 live 批量取一次（此前 must_not/交集/should/idf/评分
    // 五个阶段各自逐 posting 重扫 is_live——既重复又每次一锁）。
    auto fill_live = [&](std::vector<TermPostings>& v) {
        for (auto& tp : v) {
            tp.live.resize(tp.fp.size());
            live_checker.fill_is_live(tp.fp.ords, tp.live);
        }
    };
    fill_live(must_tps);
    fill_live(should_tps);
    fill_live(must_not_tps);

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

        std::vector<std::uint64_t> intersection;
        // O4：按 posting 数升序处理 MUST——最短 list 先进交集，accumulator 尽早
        // 缩小，后续 set_intersection 都在小集合上做；交集一旦为空提前退出。
        // 交集与处理顺序无关，结果集语义不变（must_tps 本体不重排，评分用）。
        std::vector<std::size_t> must_order(must_tps.size());
        for (std::size_t i = 0; i < must_order.size(); ++i) must_order[i] = i;
        std::sort(must_order.begin(), must_order.end(),
                  [&](std::size_t a, std::size_t b) {
                      return must_tps[a].fp.size() <
                             must_tps[b].fp.size();
                  });
        bool first_must = true;
        for (auto mi : must_order) {
            auto& tp = must_tps[mi];
            if (!first_must && intersection.empty()) break;
            std::vector<std::uint64_t> ords;
            for (std::size_t i = 0; i < tp.fp.size(); ++i) {
                if (tp.live[i]) {
                    ords.push_back(tp.fp.ords[i]);
                }
            }
            std::sort(ords.begin(), ords.end());
            ords.erase(std::unique(ords.begin(), ords.end()), ords.end());

            if (first_must) {
                intersection = std::move(ords);
                first_must = false;
            } else {
                std::vector<std::uint64_t> tmp;
                tmp.reserve(std::min(intersection.size(), ords.size()));
                std::set_intersection(intersection.begin(), intersection.end(),
                                      ords.begin(), ords.end(),
                                      std::back_inserter(tmp));
                intersection = std::move(tmp);
            }
        }
        candidates = std::move(intersection);
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

    struct ScoreAcc {
        std::unordered_map<std::uint64_t, float> scores;
    };

    ScoreAcc acc;
    for (auto ord : candidates) {
        acc.scores[ord] = 0.0f;
    }

    for (auto& tp : all_tps) {
        auto idf_it = term_idf.find(tp.term);
        if (idf_it == term_idf.end()) continue;
        auto idf = idf_it->second;

        for (std::size_t i = 0; i < tp.fp.size(); ++i) {
            auto posting_ord = tp.fp.ords[i];
            if (!tp.live[i]) continue;
            auto it = acc.scores.find(posting_ord);
            if (it == acc.scores.end()) continue;

            auto dl = live_checker.doc_len(posting_ord);
            auto tf_norm = static_cast<float>(tp.fp.tfs[i]) *
                           (params.k1 + 1.0F) /
                           (static_cast<float>(tp.fp.tfs[i]) + params.k1 *
                            (1.0F - params.b + params.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            it->second += idf * (tf_norm + params.delta);
        }
    }

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;

    for (auto& [ord, score] : acc.scores) {
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

auto InvertedIndex::search_fuzzy(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    std::uint32_t max_edit_distance,
    const LiveChecker& live_checker,
    const Bm25Params* params_override) const -> std::vector<SearchResult> {
    if (query_terms.empty()) return {};
    const Bm25Params& params = params_override ? *params_override : params_;

    struct TermPostings {
        std::string term;
        FlatPostings fp;  // P1：扁平快照
    };
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
        // P2-min 两阶段：遍历只做匹配收集 key——遍历中调 find 会触发懒 rehash
        // 节点搬迁，迭代器重复访问同一节点（破坏 S10.2 的去重，实测复现）。
        std::vector<std::string> matched;
        for (auto it = shard.inverted.begin(); it != shard.inverted.end(); ++it) {
            const auto& term = it->first;
            for (std::size_t qi = 0; qi < query_terms.size(); ++qi) {
                auto& query_term = query_terms[qi];
                auto len_diff = term.size() > query_term.size()
                                    ? term.size() - query_term.size()
                                    : query_term.size() - term.size();
                if (len_diff > max_edit_distance) continue;
                if (matchers[qi].within(term, max_edit_distance)) {
                    matched.push_back(term);
                    break;
                }
            }
        }
        std::sort(matched.begin(), matched.end());
        matched.erase(std::unique(matched.begin(), matched.end()), matched.end());
        for (auto& term : matched) {
            // 值经 const_accessor 读（slot 的 shared_ptr 可能被 CoW 替换）。
            PostingMap::const_accessor acc;
            if (!shard.inverted.find(acc, term)) continue;
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

    using ScoreMap = std::unordered_map<std::uint64_t, float>;

    ScoreMap scores = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, tps.size()),
        ScoreMap{},
        [&](const tbb::blocked_range<std::size_t>& range, ScoreMap local) {
            for (std::size_t ti = range.begin(); ti < range.end(); ++ti) {
                auto& fp = tps[ti].fp;
                const std::size_t n = fp.size();

                // P2.1：批量取 live/doc_len + 两阶段评分（同 search()，
                // ①纯浮点可向量化 ②标量 scatter；公式逐运算一致）。
                std::vector<char> live(n);
                live_checker.fill_is_live(fp.ords, live);
                std::size_t live_df = 0;
                for (std::size_t i = 0; i < n; ++i) {
                    live_df += static_cast<std::size_t>(live[i]);
                }
                if (live_df == 0) continue;

                auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

                std::vector<std::uint32_t> dls(n);
                live_checker.fill_doc_lens(fp.ords, dls);

                std::vector<float> contrib(n);
                const float fidf = static_cast<float>(idf);
                for (std::size_t i = 0; i < n; ++i) {
                    auto tf_norm = static_cast<float>(fp.tfs[i]) *
                                   (params.k1 + 1.0F) /
                                   (static_cast<float>(fp.tfs[i]) + params.k1 *
                                    (1.0F - params.b + params.b *
                                     static_cast<float>(dls[i]) / static_cast<float>(avgdl)));
                    contrib[i] = fidf * (tf_norm + params.delta);
                }
                for (std::size_t i = 0; i < n; ++i) {
                    if (live[i]) local[fp.ords[i]] += contrib[i];
                }
            }
            return local;
        },
        [](ScoreMap a, const ScoreMap& b) {
            for (auto& [doc, score] : b) {
                a[doc] += score;
            }
            return a;
        }
    );

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
    // P2-min：与 compact 同模式——先快照 key，再逐 key 持写 accessor 经
    // mutable_pl 修改（迭代器裸改在共享模型下会绕过 CoW 协议）。
    for (auto& shard : shards_) {
        std::vector<std::string> keys;
        for (auto it = shard.inverted.begin(); it != shard.inverted.end(); ++it) {
            keys.push_back(it->first);
        }
        for (auto& key : keys) {
            PostingMap::accessor acc;
            if (!shard.inverted.find(acc, key)) continue;
            mutable_pl(acc->second).finalize();
        }
    }
}

auto InvertedIndex::compact(const LiveChecker& live_checker, double dead_ratio_threshold)
    -> std::size_t {
    std::size_t compacted = 0;
    for (auto& shard : shards_) {
        // 先快照 key 列表（迭代不改 map 结构），再逐 key 持写 accessor 压实：
        // 写锁与并发查询的 const_accessor 互斥，保证查询不读到半压实状态。
        std::vector<std::string> keys;
        for (auto it = shard.inverted.begin(); it != shard.inverted.end(); ++it) {
            keys.push_back(it->first);
        }
        for (auto& key : keys) {
            PostingMap::accessor acc;
            if (!shard.inverted.find(acc, key)) continue;
            const PostingList& pl = *acc->second;
            if (pl.items.empty()) continue;

            std::size_t dead = 0;
            for (auto& p : pl.items) {
                if (!live_checker.is_live(p.ord)) ++dead;
            }
            if (dead == 0) continue;
            double ratio = static_cast<double>(dead) / static_cast<double>(pl.items.size());
            if (ratio < dead_ratio_threshold) continue;

            if (mutable_pl(acc->second).compact(
                    [&](std::uint64_t ord) { return live_checker.is_live(ord); })) {
                ++compacted;
            }
        }
    }
    return compacted;
}

// ---- 持久化 ----

static constexpr std::uint32_t kInvMagic   = 0x494E5632;
// v4：positions 落盘改用 gap+VByte 压缩（内存仍是 vector<uint32_t>，短语查询不变）。
//     v1/2/3 旧快照按原始 uint32 数组读，向后兼容。
static constexpr std::uint32_t kInvVersion = 4;

auto InvertedIndex::save(std::string_view path) const -> bool {
    auto* f = std::fopen(std::string(path).c_str(), "wb");
    if (!f) return false;

    std::uint32_t N = static_cast<std::uint32_t>(live_doc_count_.load(std::memory_order_relaxed));
    std::uint64_t sdl = sum_doc_len_.load(std::memory_order_relaxed);

    auto write_u32 = [&](std::uint32_t v) { return std::fwrite(&v, 4, 1, f) == 1; };
    auto write_u64 = [&](std::uint64_t v) { return std::fwrite(&v, 8, 1, f) == 1; };

    // v4：positions 以 gap+VByte 压缩落盘。格式 = u32 原始个数 + u32 压缩字节数
    // + 压缩字节流。个数用于 load 时 reserve；压缩字节流由 gap_decode 还原。
    auto write_positions = [&](const std::vector<std::uint32_t>& positions) -> bool {
        if (!write_u32(static_cast<std::uint32_t>(positions.size()))) return false;
        std::vector<std::uint64_t> tmp(positions.begin(), positions.end());
        auto comp = codec::gap_encode(tmp);
        if (!write_u32(static_cast<std::uint32_t>(comp.size()))) return false;
        if (!comp.empty() && std::fwrite(comp.data(), 1, comp.size(), f) != comp.size()) {
            return false;
        }
        return true;
    };

    bool ok = write_u32(kInvMagic) && write_u32(kInvVersion)
              && write_u32(N) && write_u64(sdl);
    if (!ok) { std::fclose(f); return false; }

    for (auto& shard : shards_) {
        std::uint32_t term_count = static_cast<std::uint32_t>(shard.inverted.size());
        ok = write_u32(term_count);
        if (!ok) { std::fclose(f); return false; }

        for (auto& [term, plsp] : shard.inverted) {
            const PostingList& pl = *plsp;
            auto tlen = static_cast<std::uint32_t>(term.size());
            ok = write_u32(tlen);
            if (!ok) { std::fclose(f); return false; }
            if (std::fwrite(term.data(), 1, tlen, f) != tlen) {
                std::fclose(f); return false;
            }

            auto pc = static_cast<std::uint32_t>(pl.items.size());
            ok = write_u32(pc);
            if (!ok) { std::fclose(f); return false; }

            if (pl.finalized && !pl.compressed_ords.empty()) {
                // VByte gap 编码格式（version=2/3）
                std::uint8_t comp = 1;
                ok = write_u32(comp);
                if (!ok) { std::fclose(f); return false; }
                auto csize = static_cast<std::uint32_t>(pl.compressed_ords.size());
                ok = write_u32(csize);
                if (!ok) { std::fclose(f); return false; }
                if (std::fwrite(pl.compressed_ords.data(), 1, csize, f) != csize) {
                    std::fclose(f); return false;
                }
                for (auto& posting : pl.items) {
                    ok = write_u32(posting.tf);
                    if (!ok) { std::fclose(f); return false; }
                    if (!write_positions(posting.positions)) {
                        std::fclose(f); return false;
                    }
                }
                // Block-Max WAND 元数据（version=3）
                std::uint32_t block_count = static_cast<std::uint32_t>(pl.blocks.size());
                ok = write_u32(block_count);
                if (!ok) { std::fclose(f); return false; }
                for (auto& blk : pl.blocks) {
                    ok = write_u64(blk.base_ord) && write_u64(blk.end_ord)
                         && write_u32(blk.max_tf) && write_u32(static_cast<std::uint32_t>(blk.start_idx))
                         && write_u32(static_cast<std::uint32_t>(blk.count));
                    if (!ok) { std::fclose(f); return false; }
                }
            } else {
                // 原始格式（version=1 或未压缩）
                std::uint8_t comp = 0;
                ok = write_u32(comp);
                if (!ok) { std::fclose(f); return false; }
                for (auto& posting : pl.items) {
                    ok = write_u64(posting.ord) && write_u32(posting.tf);
                    if (!ok) { std::fclose(f); return false; }
                    if (!write_positions(posting.positions)) {
                        std::fclose(f); return false;
                    }
                }
            }
        }
    }

    std::fclose(f);
    return true;
}

auto InvertedIndex::load(std::string_view path) -> bool {
    auto* f = std::fopen(std::string(path).c_str(), "rb");
    if (!f) return false;

    auto read_u32 = [&]() -> std::uint32_t {
        std::uint32_t v;
        if (std::fread(&v, 4, 1, f) != 1) return 0xFFFFFFFF;
        return v;
    };
    auto read_u64 = [&]() -> std::uint64_t {
        std::uint64_t v;
        if (std::fread(&v, 8, 1, f) != 1) return 0xFFFFFFFFFFFFFFFF;
        return v;
    };

    auto magic = read_u32();
    auto ver = read_u32();

    // positions 读取：v4 走 gap+VByte 压缩格式（count + comp_size + 字节流），
    // v1/2/3 走原始 uint32 数组。失败返回 false。
    auto read_positions = [&](std::vector<std::uint32_t>& out) -> bool {
        auto posc = read_u32();
        if (posc == 0xFFFFFFFF) return false;
        if (ver >= 4) {
            auto csize = read_u32();
            if (csize == 0xFFFFFFFF) return false;
            std::vector<std::uint8_t> comp(csize);
            if (csize > 0 && std::fread(comp.data(), 1, csize, f) != csize) return false;
            auto vals = codec::gap_decode(comp);
            if (vals.size() != posc) return false;  // 个数自洽校验
            out.resize(posc);
            for (std::uint32_t i = 0; i < posc; ++i) {
                out[i] = static_cast<std::uint32_t>(vals[i]);
            }
        } else {
            out.resize(posc);
            if (posc > 0 && std::fread(out.data(), 4, posc, f) != posc) return false;
        }
        return true;
    };
    if (magic != kInvMagic) {
        std::fclose(f); return false;
    }
    // 接受 1..kInvVersion 的所有版本（向后兼容）。S9.4 升到 v4 时此处漏列 v3，
    // 导致 v3 快照被拒——改为范围检查，避免再漏。
    if (ver < 1 || ver > kInvVersion) {
        std::fclose(f); return false;
    }

    auto N = read_u32();
    auto sdl = read_u64();

    for (auto& shard : shards_) {
        auto term_count = read_u32();
        if (term_count == 0xFFFFFFFF) { std::fclose(f); return false; }

        for (std::uint32_t t = 0; t < term_count; ++t) {
            auto tlen = read_u32();
            if (tlen == 0xFFFFFFFF || tlen > 1024) { std::fclose(f); return false; }

            std::string term(tlen, '\0');
            if (std::fread(term.data(), 1, tlen, f) != tlen) {
                std::fclose(f); return false;
            }

            auto pc = read_u32();
            if (pc == 0xFFFFFFFF) { std::fclose(f); return false; }

            PostingList pl;
            pl.items.resize(pc);

            if (ver >= 2) {
                auto comp = read_u32();
                if (comp == 0xFFFFFFFF) { std::fclose(f); return false; }
                if (comp == 1) {
                    pl.finalized = true;
                    auto csize = read_u32();
                    if (csize == 0xFFFFFFFF) { std::fclose(f); return false; }
                    pl.compressed_ords.resize(csize);
                    if (csize > 0) {
                        if (std::fread(pl.compressed_ords.data(), 1, csize, f) != csize) {
                            std::fclose(f); return false;
                        }
                    }
                    // 回填 items[].ord：内存路径（find/note_appended/compact/
                    // live_doc_count 及查询热循环）都以 items[].ord 为事实来源，
                    // compressed_ords 只是落盘副本。漏回填会让 load 后的 ord 全 0，
                    // 后续对既有 term 的 add_doc（note_appended 使压缩失效）即丢失
                    // 全部旧 posting 的 ord。
                    {
                        auto ords = codec::gap_decode(pl.compressed_ords);
                        if (ords.size() != pc) { std::fclose(f); return false; }
                        for (std::uint32_t p = 0; p < pc; ++p) {
                            pl.items[p].ord = ords[p];
                        }
                    }
                    for (std::uint32_t p = 0; p < pc; ++p) {
                        pl.items[p].tf = read_u32();
                        if (!read_positions(pl.items[p].positions)) {
                            std::fclose(f); return false;
                        }
                    }
                    if (ver >= 3) {
                        auto block_count = read_u32();
                        if (block_count == 0xFFFFFFFF) { std::fclose(f); return false; }
                        pl.blocks.resize(block_count);
                        for (std::uint32_t b = 0; b < block_count; ++b) {
                            pl.blocks[b].base_ord = read_u64();
                            pl.blocks[b].end_ord = read_u64();
                            pl.blocks[b].max_tf = read_u32();
                            pl.blocks[b].start_idx = read_u32();
                            pl.blocks[b].count = read_u32();
                        }
                    }
                } else {
                    for (std::uint32_t p = 0; p < pc; ++p) {
                        pl.items[p].ord = read_u64();
                        pl.items[p].tf = read_u32();
                        if (!read_positions(pl.items[p].positions)) {
                            std::fclose(f); return false;
                        }
                    }
                }
            } else {
                for (std::uint32_t p = 0; p < pc; ++p) {
                    pl.items[p].ord = read_u64();
                    pl.items[p].tf = read_u32();
                    if (!read_positions(pl.items[p].positions)) {
                        std::fclose(f); return false;
                    }
                }
            }
            // S10.9：load 后重算缓存的 global max_tf（落盘格式不含此字段，派生量）。
            for (auto& p : pl.items) {
                if (p.tf > pl.max_tf) pl.max_tf = p.tf;
            }
            shard.inverted.emplace(std::move(term), std::make_shared<PostingList>(std::move(pl)));
        }
    }

    live_doc_count_.store(N, std::memory_order_relaxed);
    sum_doc_len_.store(sdl, std::memory_order_relaxed);

    std::fclose(f);
    return true;
}

void InvertedIndex::enable_wal(std::string_view path) {
    wal_path_ = path;
    wal_ = std::make_unique<InvertedWal>(path);
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
