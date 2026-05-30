#include "bitcask/inverted.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <queue>
#include <string>
#include <string_view>
#include <unordered_map>
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
        std::unique_lock lock(shard.mutex);
        auto& pl = shard.inverted[term];
        pl.items.push_back({ord, tf, positions});
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
        std::size_t live_df = 0;
        for (auto& posting : pl->items) {
            if (live_checker.is_live(posting.ord)) ++live_df;
        }
        if (live_df == 0) continue;
        auto idf = std::log(static_cast<double>(N + 1) / static_cast<double>(live_df + 1));

        for (auto& posting : pl->items) {
            if (!live_checker.is_live(posting.ord)) continue;

            auto dl = live_checker.doc_len(posting.ord);
            auto tf_norm = static_cast<float>(posting.tf) *
                           (params_.k1 + 1.0F) /
                           (static_cast<float>(posting.tf) + params_.k1 *
                            (1.0F - params_.b + params_.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[posting.ord] += static_cast<float>(idf) * tf_norm;
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

auto InvertedIndex::search_phrase(
    const std::vector<std::string>& query_terms,
    std::size_t k,
    const LiveChecker& live_checker) const -> std::vector<SearchResult> {
    if (query_terms.empty()) return {};

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
        if (it == shard.inverted.end()) return {};
        tps.push_back({term, &it->second});
    }

    auto N = live_doc_count_;
    auto sum_dl = sum_doc_len_;
    auto avgdl = N > 0 ? static_cast<double>(sum_dl) / static_cast<double>(N) : 1.0;

    std::unordered_map<std::uint64_t, float> scores;

    auto& first_pl = tps[0].pl;
    for (auto& posting : first_pl->items) {
        if (!live_checker.is_live(posting.ord)) continue;

        std::uint32_t phrase_tf = 0;
        for (auto start_pos : posting.positions) {
            bool match = true;
            for (std::size_t t = 1; t < tps.size(); ++t) {
                auto needed = static_cast<std::uint32_t>(start_pos + t);
                auto& other_pl = *tps[t].pl;
                auto idx = other_pl.find(posting.ord);
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
            for (auto& p : first_pl->items) {
                if (live_checker.is_live(p.ord)) ++live_df;
            }
            auto idf = std::log(static_cast<double>(N + 1) / static_cast<double>(live_df + 1));
            auto dl = live_checker.doc_len(posting.ord);
            auto tf_norm = static_cast<float>(phrase_tf) *
                           (params_.k1 + 1.0F) /
                           (static_cast<float>(phrase_tf) + params_.k1 *
                            (1.0F - params_.b + params_.b *
                             static_cast<float>(dl) / static_cast<float>(avgdl)));
            scores[posting.ord] += static_cast<float>(idf) * tf_norm;
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

auto InvertedIndex::df_live(std::string_view term, const LiveChecker& live_checker) const -> std::size_t {
    auto& shard = shard_for(term);
    std::shared_lock lock(shard.mutex);
    auto it = shard.inverted.find(std::string(term));
    if (it == shard.inverted.end()) return 0;
    std::size_t count = 0;
    for (auto& posting : it->second.items) {
        if (live_checker.is_live(posting.ord)) ++count;
    }
    return count;
}

// ---- 持久化 ----

static constexpr std::uint32_t kInvMagic   = 0x494E5632;
static constexpr std::uint32_t kInvVersion = 1;

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
        std::shared_lock lock(shard.mutex);
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
    if (magic != kInvMagic || ver != kInvVersion) {
        std::fclose(f); return false;
    }

    auto N = read_u32();
    auto sdl = read_u64();

    for (auto& shard : shards_) {
        std::unique_lock lock(shard.mutex);
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
