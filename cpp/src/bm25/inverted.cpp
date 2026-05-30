#include "bitcask/inverted.hpp"

#include <algorithm>
#include <cmath>
#include <queue>
#include <string>
#include <string_view>
#include <unordered_map>

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
    const std::unordered_map<std::string, std::uint32_t>& term_freqs) {
    auto doc_len = std::uint32_t{0};
    for (auto& [term, tf] : term_freqs) {
        auto& shard = shard_for(term);
        std::unique_lock lock(shard.mutex);
        auto& pl = shard.inverted[term];
        pl.items.push_back({ord, tf});
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
    // 收集每个 query term 的 posting list（shared_lock 各分片）。
    struct TermPostings {
        std::string term;
        const PostingList* pl;
    };
    std::vector<TermPostings> tps;
    tps.reserve(query_terms.size());

    for (auto& term : query_terms) {
        auto& shard = shard_for(term);
        std::shared_lock lock(shard.mutex);
        auto it = shard.inverted.find(term);
        if (it != shard.inverted.end()) {
            tps.push_back({term, &it->second});
        }
    }

    if (tps.empty()) return {};

    // 读取全局统计（shared_lock）。
    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    // DAAT: 逐 posting 累加 BM25 分数，按 ord 聚合。
    std::unordered_map<std::uint64_t, float> scores;
    for (auto& [term, pl] : tps) {
        auto df = static_cast<std::uint64_t>(pl->items.size());
        if (df == 0) continue;
        auto idf = std::log(static_cast<double>(N + 1) / static_cast<double>(df + 1));

        for (auto& [ord, tf] : pl->items) {
            if (!live_checker.is_live(ord)) continue;

            auto dl = live_checker.doc_len(ord);
            auto tf_norm = static_cast<float>(tf) *
                           (params_.k1 + 1.0F) /
                           (static_cast<float>(tf) + params_.k1 *
                            (1.0F - params_.b + params_.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[ord] += static_cast<float>(idf) * tf_norm;
        }
    }

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
    std::shared_lock lock(shard.mutex);
    auto it = shard.inverted.find(std::string(term));
    if (it == shard.inverted.end()) return 0;
    return it->second.items.size();
}

}  // namespace bitcask::bm25
