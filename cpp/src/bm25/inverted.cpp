#include "bitcask/inverted.hpp"

#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_reduce.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
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

auto PostingList::block_for_ord(std::uint64_t ord) const -> const PostingBlock* {
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

auto PostingList::block_upper_bound(float idf, const Bm25Params& params, double avgdl) const -> float {
    if (items.empty()) return 0.0f;
    std::uint32_t global_max_tf = 0;
    for (const auto& p : items) {
        if (p.tf > global_max_tf) global_max_tf = p.tf;
    }
    float tf_norm = static_cast<float>(global_max_tf) * (params.k1 + 1.0f) /
                    (static_cast<float>(global_max_tf) + params.k1 *
                     (1.0f - params.b + params.b * 1.0f / static_cast<float>(avgdl)));
    return idf * tf_norm;
}

// ===========================================================================
// InvertedIndex
// ===========================================================================

InvertedIndex::InvertedIndex(Bm25Params params)
    : params_(params) {}

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
        tbb::concurrent_hash_map<std::string, PostingList>::accessor acc;
        shard.inverted.insert(acc, term);
        acc->second.items.push_back({ord, tf, positions});
        doc_len += tf;
    }

    {
        std::unique_lock lock(stats_mutex_);
        ++live_doc_count_;
        sum_doc_len_ += doc_len;
    }
}

void InvertedIndex::remove_doc(
    std::uint32_t doc_len,
    const std::unordered_map<std::string, std::uint32_t>& /*term_freqs*/) {
    // V2: 不物理删除 posting 行，靠 search 时 live 过滤。
    // 只更新全局统计。
    std::unique_lock lock(stats_mutex_);
    if (live_doc_count_ > 0) --live_doc_count_;
    if (sum_doc_len_ >= doc_len) sum_doc_len_ -= doc_len;
}

// ---- 查询 ----

auto InvertedIndex::search(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker) const -> std::vector<SearchResult> {
    struct TermPostings {
        std::string term;
        PostingList pl_copy;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            tps.push_back({term, acc->second});
        }
    }

    if (tps.empty()) return {};

    // 检查是否启用 WAND 路径（posting 总量足够大时才值得）。
    std::size_t total_postings = 0;
    for (auto& tp : tps) total_postings += tp.pl_copy.items.size();
    if (total_postings >= kWandThreshold) {
        return search_wand(query_terms, k, live_checker);
    }

    // 读取全局统计（shared_lock）。
    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // 并行 BM25 评分：parallel_reduce 按查询词分片，线程本地 map 无锁累加。
    using ScoreMap = std::unordered_map<std::uint64_t, float>;

    ScoreMap scores = tbb::parallel_reduce(
        tbb::blocked_range<std::size_t>(0, tps.size()),
        ScoreMap{},
        [&](const tbb::blocked_range<std::size_t>& range, ScoreMap local) {
            for (std::size_t ti = range.begin(); ti < range.end(); ++ti) {
                auto& pl_copy = tps[ti].pl_copy;
                auto ords = pl_copy.decompress_ords();

                // 计算该词的 live df。
                std::size_t live_df = 0;
                for (std::size_t i = 0; i < pl_copy.items.size(); ++i) {
                    if (live_checker.is_live(ords[i])) ++live_df;
                }
                if (live_df == 0) continue;

                auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));

                // 逐 posting 累加 BM25 分数到线程本地 map。
                for (std::size_t i = 0; i < pl_copy.items.size(); ++i) {
                    auto& posting = pl_copy.items[i];
                    auto ord = ords[i];
                    if (!live_checker.is_live(ord)) continue;

                    auto dl = live_checker.doc_len(ord);
                    auto tf_norm = static_cast<float>(posting.tf) *
                                   (params_.k1 + 1.0F) /
                                   (static_cast<float>(posting.tf) + params_.k1 *
                                    (1.0F - params_.b + params_.b *
                                     static_cast<float>(dl) / static_cast<float>(avgdl)));
                    local[ord] += static_cast<float>(idf) * tf_norm;
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
// Block-Max WAND
// ===========================================================================

auto InvertedIndex::search_wand(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker) const -> std::vector<SearchResult> {
    struct TermPostings {
        std::string term;
        PostingList pl_copy;
        std::vector<std::uint64_t> ords;
        std::size_t cursor = 0;
        float idf = 0.0f;
        float list_upper_bound = 0.0f;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            TermPostings tp;
            tp.term = term;
            tp.pl_copy = acc->second;
            tp.ords = tp.pl_copy.decompress_ords();
            tps.push_back(std::move(tp));
        }
    }
    if (tps.empty()) return {};

    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // 计算每个 term 的 IDF 和上界分数。
    for (auto& tp : tps) {
        std::size_t live_df = 0;
        for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
            if (live_checker.is_live(tp.ords[i])) ++live_df;
        }
        if (live_df == 0) {
            tp.idf = 0.0f;
            tp.list_upper_bound = 0.0f;
            continue;
        }
        tp.idf = static_cast<float>(std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) /
                                             (static_cast<double>(live_df) + 0.5)));
        tp.list_upper_bound = tp.pl_copy.block_upper_bound(tp.idf, params_, avgdl);
    }

    using Entry = std::pair<float, std::uint64_t>;
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> heap;
    float threshold = 0.0f;

    while (true) {
        // 按当前 ord 升序排列。
        std::sort(tps.begin(), tps.end(),
                  [](const TermPostings& a, const TermPostings& b) {
                      if (a.cursor >= a.ords.size() && b.cursor >= b.ords.size()) return false;
                      if (a.cursor >= a.ords.size()) return true;
                      if (b.cursor >= b.ords.size()) return false;
                      return a.ords[a.cursor] < b.ords[b.cursor];
                  });

        std::size_t pivot_idx = 0;
        float acc_score = 0.0f;
        bool pivot_found = false;

        for (std::size_t i = 0; i < tps.size(); ++i) {
            if (tps[i].cursor >= tps[i].ords.size()) continue;
            acc_score += tps[i].list_upper_bound;
            if (acc_score >= threshold) {
                pivot_idx = i;
                pivot_found = true;
                break;
            }
        }
        if (!pivot_found) break;

        auto pivot_ord = tps[pivot_idx].ords[tps[pivot_idx].cursor];

        bool any_skipped = false;
        for (std::size_t i = 0; i <= pivot_idx; ++i) {
            if (tps[i].cursor >= tps[i].ords.size()) continue;
            if (tps[i].ords[tps[i].cursor] != pivot_ord) continue;

            const auto* block = tps[i].pl_copy.block_for_ord(pivot_ord);
            if (block != nullptr) {
                float block_tf_norm = static_cast<float>(block->max_tf) * (params_.k1 + 1.0f) /
                                      (static_cast<float>(block->max_tf) + params_.k1 *
                                       (1.0f - params_.b + params_.b * 1.0f / static_cast<float>(avgdl)));
                float block_upper = tps[i].idf * block_tf_norm;
                float remaining_needed = threshold;
                if (!heap.empty()) remaining_needed = threshold - heap.top().first + 1e-6f;
                if (block_upper < remaining_needed) {
                    // 跳过到下一个块边界。
                    std::size_t next_start = block->start_idx + block->count;
                    if (next_start >= tps[i].ords.size()) {
                        tps[i].cursor = tps[i].ords.size();
                    } else {
                        tps[i].cursor = next_start;
                    }
                    any_skipped = true;
                }
            }
        }
        if (any_skipped) continue;

        // 所有 term 在 pivot_ord 处都值得关注，计算实际分数。
        if (live_checker.is_live(pivot_ord)) {
            float score = 0.0f;
            for (std::size_t i = 0; i < tps.size(); ++i) {
                if (tps[i].cursor >= tps[i].ords.size()) continue;
                if (tps[i].ords[tps[i].cursor] != pivot_ord) continue;

                auto dl = live_checker.doc_len(pivot_ord);
                auto tf_norm = static_cast<float>(tps[i].pl_copy.items[tps[i].cursor].tf) *
                               (params_.k1 + 1.0f) /
                               (static_cast<float>(tps[i].pl_copy.items[tps[i].cursor].tf) + params_.k1 *
                                (1.0f - params_.b + params_.b *
                                 static_cast<float>(dl) / static_cast<float>(avgdl)));
                score += tps[i].idf * tf_norm;
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
            while (tps[i].cursor < tps[i].ords.size() && tps[i].ords[tps[i].cursor] <= pivot_ord) {
                ++tps[i].cursor;
            }
        }

        bool any_exhausted = false;
        for (auto& tp : tps) {
            if (tp.cursor >= tp.ords.size()) any_exhausted = true;
        }
        if (any_exhausted) {
            bool all_exhausted = true;
            for (auto& tp : tps) {
                if (tp.cursor < tp.ords.size()) {
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

auto InvertedIndex::search_phrase(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker) const -> std::vector<SearchResult> {
    if (query_terms.empty()) return {};

    struct TermPostings {
        std::string term;
        PostingList pl_copy;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (!shard.inverted.find(acc, term)) return {};
        tps.push_back({term, acc->second});
    }

    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    std::unordered_map<std::uint64_t, float> scores;

    auto& first_pl = tps[0].pl_copy;
    auto first_ords = first_pl.decompress_ords();
    for (std::size_t i = 0; i < first_pl.items.size(); ++i) {
        auto& posting = first_pl.items[i];
        auto posting_ord = first_ords[i];
        if (!live_checker.is_live(posting_ord)) continue;

        std::uint32_t phrase_tf = 0;
        for (auto start_pos : posting.positions) {
            bool match = true;
            for (std::size_t t = 1; t < tps.size(); ++t) {
                auto needed = static_cast<std::uint32_t>(start_pos + t);
                auto& other_pl = tps[t].pl_copy;
                auto idx = other_pl.find(posting_ord);
                if (idx >= other_pl.items.size()) { match = false; break; }
                auto& pos_list = other_pl.items[idx].positions;
                if (!std::binary_search(pos_list.begin(), pos_list.end(), needed)) {
                    match = false;
                    break;
                }
            }
            if (match) ++phrase_tf;
        }

        if (phrase_tf > 0) {
            std::size_t live_df = 0;
            for (std::size_t j = 0; j < first_pl.items.size(); ++j) {
                if (live_checker.is_live(first_ords[j])) ++live_df;
            }
            auto idf = std::log(1.0 + (static_cast<double>(N) - static_cast<double>(live_df) + 0.5) / (static_cast<double>(live_df) + 0.5));
            auto dl = live_checker.doc_len(posting_ord);
            auto tf_norm = static_cast<float>(phrase_tf) *
                           (params_.k1 + 1.0F) /
                           (static_cast<float>(phrase_tf) + params_.k1 *
                            (1.0F - params_.b + params_.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[posting_ord] += static_cast<float>(idf) * tf_norm;
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

auto InvertedIndex::bool_search(
    const QueryNode& query,
    std::size_t k,
    const LiveChecker& live_checker) const -> std::vector<SearchResult> {
    std::vector<std::string> must_terms;
    std::vector<std::string> should_terms;
    std::vector<std::string> must_not_terms;
    collect_terms(query, must_terms, should_terms, must_not_terms);

    struct TermPostings {
        std::string term;
        PostingList pl_copy;
        bool is_must;
    };
    std::vector<TermPostings> must_tps;
    must_tps.reserve(must_terms.size());
    for (auto& term : must_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            must_tps.push_back({term, acc->second, true});
        }
    }

    std::vector<TermPostings> should_tps;
    should_tps.reserve(should_terms.size());
    for (auto& term : should_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            should_tps.push_back({term, acc->second, false});
        }
    }

    std::vector<TermPostings> must_not_tps;
    must_not_tps.reserve(must_not_terms.size());
    for (auto& term : must_not_terms) {
        auto& shard = shard_for(term);
        tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
        if (shard.inverted.find(acc, term)) {
            must_not_tps.push_back({term, acc->second, false});
        }
    }

    std::vector<std::uint64_t> must_not_ords;
    for (auto& tp : must_not_tps) {
        auto ords = tp.pl_copy.decompress_ords();
        for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
            if (live_checker.is_live(ords[i])) {
                must_not_ords.push_back(ords[i]);
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
            tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
            if (!shard.inverted.find(acc, term)) {
                all_terms_found = false;
                break;
            }
        }

        if (!all_terms_found) {
            return {};
        }

        std::vector<std::uint64_t> intersection;
        bool first_must = true;
        for (auto& tp : must_tps) {
            std::vector<std::uint64_t> ords;
            auto decompressed = tp.pl_copy.decompress_ords();
            for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
                if (live_checker.is_live(decompressed[i])) {
                    ords.push_back(decompressed[i]);
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
            auto decompressed = tp.pl_copy.decompress_ords();
            for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
                if (live_checker.is_live(decompressed[i])) {
                    candidates.push_back(decompressed[i]);
                }
            }
        }
        std::sort(candidates.begin(), candidates.end());
        candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());
    } else {
        return {};
    }

    for (auto& tp : should_tps) {
        auto decompressed = tp.pl_copy.decompress_ords();
        for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
            if (live_checker.is_live(decompressed[i])) {
                candidates.push_back(decompressed[i]);
            }
        }
    }
    std::sort(candidates.begin(), candidates.end());
    candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());

    std::vector<std::uint64_t> filtered;
    filtered.reserve(candidates.size());
    for (auto ord : candidates) {
        if (!std::binary_search(must_not_ords.begin(), must_not_ords.end(), ord)) {
            filtered.push_back(ord);
        }
    }
    candidates = std::move(filtered);

    if (candidates.empty()) return {};

    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
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
        auto decompressed = tp.pl_copy.decompress_ords();
        for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
            if (live_checker.is_live(decompressed[i])) ++live_df;
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
        auto decompressed = tp.pl_copy.decompress_ords();

        for (std::size_t i = 0; i < tp.pl_copy.items.size(); ++i) {
            auto posting_ord = decompressed[i];
            if (!live_checker.is_live(posting_ord)) continue;
            auto it = acc.scores.find(posting_ord);
            if (it == acc.scores.end()) continue;

            auto dl = live_checker.doc_len(posting_ord);
            auto tf_norm = static_cast<float>(tp.pl_copy.items[i].tf) *
                           (params_.k1 + 1.0F) /
                           (static_cast<float>(tp.pl_copy.items[i].tf) + params_.k1 *
                            (1.0F - params_.b + params_.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            it->second += idf * tf_norm;
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

// ---- 统计 ----

auto InvertedIndex::live_doc_count() const -> std::uint64_t {
    std::shared_lock lock(stats_mutex_);
    return live_doc_count_;
}

auto InvertedIndex::sum_doc_len() const -> std::uint64_t {
    std::shared_lock lock(stats_mutex_);
    return sum_doc_len_;
}

auto InvertedIndex::avg_doc_len() const -> double {
    std::shared_lock lock(stats_mutex_);
    if (live_doc_count_ == 0) return 0.0;
    return static_cast<double>(sum_doc_len_) / static_cast<double>(live_doc_count_);
}

auto InvertedIndex::df(std::string_view term) const -> std::size_t {
    auto& shard = shard_for(term);
    tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
    if (!shard.inverted.find(acc, std::string(term))) return 0;
    return acc->second.items.size();
}

auto InvertedIndex::df_live(std::string_view term, const LiveChecker& live_checker) const -> std::size_t {
    auto& shard = shard_for(term);
    tbb::concurrent_hash_map<std::string, PostingList>::const_accessor acc;
    if (!shard.inverted.find(acc, std::string(term))) return 0;
    std::size_t count = 0;
    for (auto& posting : acc->second.items) {
        if (live_checker.is_live(posting.ord)) ++count;
    }
    return count;
}

void InvertedIndex::finalize_all_postings() {
    for (auto& shard : shards_) {
        for (auto it = shard.inverted.begin(); it != shard.inverted.end(); ++it) {
            it->second.finalize();
        }
    }
}

// ---- 持久化 ----

static constexpr std::uint32_t kInvMagic   = 0x494E5632;
static constexpr std::uint32_t kInvVersion = 3;

auto InvertedIndex::save(std::string_view path) const -> bool {
    auto* f = std::fopen(std::string(path).c_str(), "wb");
    if (!f) return false;

    std::shared_lock stats_lock(stats_mutex_);
    std::uint32_t N = static_cast<std::uint32_t>(live_doc_count_);
    std::uint64_t sdl = sum_doc_len_;

    auto write_u32 = [&](std::uint32_t v) { return std::fwrite(&v, 4, 1, f) == 1; };
    auto write_u64 = [&](std::uint64_t v) { return std::fwrite(&v, 8, 1, f) == 1; };

    bool ok = write_u32(kInvMagic) && write_u32(kInvVersion)
              && write_u32(N) && write_u64(sdl);
    if (!ok) { std::fclose(f); return false; }

    for (auto& shard : shards_) {
        std::uint32_t term_count = static_cast<std::uint32_t>(shard.inverted.size());
        ok = write_u32(term_count);
        if (!ok) { std::fclose(f); return false; }

        for (auto& [term, pl] : shard.inverted) {
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
                    auto posc = static_cast<std::uint32_t>(posting.positions.size());
                    ok = write_u32(posc);
                    if (!ok) { std::fclose(f); return false; }
                    if (posc > 0) {
                        if (std::fwrite(posting.positions.data(), 4, posc, f) != posc) {
                            std::fclose(f); return false;
                        }
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

                    auto posc = static_cast<std::uint32_t>(posting.positions.size());
                    ok = write_u32(posc);
                    if (!ok) { std::fclose(f); return false; }
                    if (posc > 0) {
                        if (std::fwrite(posting.positions.data(), 4, posc, f) != posc) {
                            std::fclose(f); return false;
                        }
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
    if (magic != kInvMagic) {
        std::fclose(f); return false;
    }
    if (ver != kInvVersion && ver != 2 && ver != 1) {
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

            if (ver == 2 || ver == 3) {
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
                    for (std::uint32_t p = 0; p < pc; ++p) {
                        pl.items[p].tf = read_u32();
                        auto posc = read_u32();
                        if (posc == 0xFFFFFFFF) { std::fclose(f); return false; }
                        pl.items[p].positions.resize(posc);
                        if (posc > 0) {
                            if (std::fread(pl.items[p].positions.data(), 4, posc, f) != posc) {
                                std::fclose(f); return false;
                            }
                        }
                    }
                    if (ver == 3) {
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
                        auto posc = read_u32();
                        if (posc == 0xFFFFFFFF) { std::fclose(f); return false; }
                        pl.items[p].positions.resize(posc);
                        if (posc > 0) {
                            if (std::fread(pl.items[p].positions.data(), 4, posc, f) != posc) {
                                std::fclose(f); return false;
                            }
                        }
                    }
                }
            } else {
                for (std::uint32_t p = 0; p < pc; ++p) {
                    pl.items[p].ord = read_u64();
                    pl.items[p].tf = read_u32();
                    auto posc = read_u32();
                    if (posc == 0xFFFFFFFF) { std::fclose(f); return false; }
                    pl.items[p].positions.resize(posc);
                    if (posc > 0) {
                        if (std::fread(pl.items[p].positions.data(), 4, posc, f) != posc) {
                            std::fclose(f); return false;
                        }
                    }
                }
            }
            shard.inverted.emplace(std::move(term), std::move(pl));
        }
    }

    {
        std::unique_lock lock(stats_mutex_);
        live_doc_count_ = N;
        sum_doc_len_ = sdl;
    }

    std::fclose(f);
    return true;
}

}  // namespace bitcask::bm25
