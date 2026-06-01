#include "bitcask/search_layer.hpp"
#include "bitcask/text_utils.hpp"

#include <utility>

namespace bitcask::search {

SearchLayer::SearchLayer(const SearchLayerConfig& config)
    : config_(config)
    , index_()
    , inverted_(std::make_unique<bm25::InvertedIndex>(config.bm25_params))
    , analyzer_(text::AnalyzerFactory::create(config.analyzer_config))
    , cache_(config.cache_max_entries)
    , doc_texts_(config.doc_text_cache_max)
{
}

void SearchLayer::on_write(std::string_view key, std::uint64_t ord,
                           std::string_view text,
                           std::uint32_t file_id, std::uint64_t offset,
                           std::uint32_t total_sz, std::uint32_t tstamp) {
    auto term_data = analyzer_->analyze_with_positions(text);

    std::uint32_t doc_len = 0;
    std::vector<std::string> changed_terms;
    changed_terms.reserve(term_data.size());
    for (auto& [term, data] : term_data) {
        doc_len += data.first;
        changed_terms.push_back(term);
    }

    index_.put_doc(key, ord,
                   index::DocSlot{
                       index::DocLoc{file_id, offset, total_sz},
                       tstamp,
                       doc_len});

    if (!term_data.empty()) {
        inverted_->add_doc(ord, term_data);
    }
    doc_texts_.put(ord, std::string(text));
    // S9.2：只失效查询词与本文档词集有交集的缓存条目。
    cache_.invalidate_terms(changed_terms);
}

std::optional<std::uint64_t> SearchLayer::on_delete(std::string_view key, std::uint64_t tomb_ord) {
    auto slot = index_.get(key);
    if (!slot) return std::nullopt;

    // S9.2：取被删文档词集做选择性失效。原文 LRU 命中则精确 analyze；
    // miss（冷文档被挤出）则降级为整缓存失效（安全但粗粒度）。
    const std::string* text = doc_texts_.get(slot->ord);
    std::vector<std::string> changed_terms;
    if (text) {
        auto tf = analyzer_->analyze(*text);
        changed_terms.reserve(tf.size());
        for (auto& [term, _] : tf) changed_terms.push_back(term);
    }

    inverted_->remove_doc(slot->doc_len, {});
    index_.remove(key, tomb_ord);
    doc_texts_.erase(slot->ord);
    if (text) {
        cache_.invalidate_terms(changed_terms);
    } else {
        cache_.invalidate();
    }
    return tomb_ord;
}

void SearchLayer::on_relocate(std::string_view key, std::uint64_t ord,
                              std::uint32_t new_file_id, std::uint64_t new_offset,
                              std::uint32_t new_total_sz) {
    auto slot = index_.get(key);
    if (!slot) return;

    index_.put_doc(key, ord,
                   index::DocSlot{
                       index::DocLoc{new_file_id, new_offset, new_total_sz},
                       slot->tstamp,
                       slot->doc_len});
}

std::expected<std::vector<SearchHit>, std::string>
SearchLayer::search_text(std::string_view query, std::size_t k) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHit>{};

    auto cache_key = CacheKey::make("text", query, k);
    auto* cached = cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = *cached;
    } else {
        std::vector<std::string> terms;
        terms.reserve(term_freqs.size());
        for (auto& [term, _] : term_freqs) {
            terms.push_back(term);
        }

        results = inverted_->search(terms, k, index_);
        cache_.put(cache_key, results, terms);
    }

    std::vector<SearchHit> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index_.ord_to_ext(r.ord);
        if (!ext_id) continue;
        hits.push_back(SearchHit{std::move(*ext_id), r.ord, r.score});
    }
    return hits;
}

std::expected<std::vector<SearchHit>, std::string>
SearchLayer::search_phrase(std::string_view query, std::size_t k) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHit>{};

    auto cache_key = CacheKey::make("phrase", query, k);
    auto* cached = cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = *cached;
    } else {
        std::vector<std::string> terms;
        terms.reserve(term_freqs.size());
        for (auto& [term, _] : term_freqs) {
            terms.push_back(term);
        }

        results = inverted_->search_phrase(terms, k, index_);
        cache_.put(cache_key, results, terms);
    }

    std::vector<SearchHit> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index_.ord_to_ext(r.ord);
        if (!ext_id) continue;
        hits.push_back(SearchHit{std::move(*ext_id), r.ord, r.score});
    }
    return hits;
}

std::expected<std::vector<SearchHit>, std::string>
SearchLayer::bool_search(std::string_view query, std::size_t k) const {
    auto query_node = bitcask::bm25::parse_query(query);
    if (query_node.term.empty() && query_node.children.empty()) {
        return std::vector<SearchHit>{};
    }

    auto cache_key = CacheKey::make("bool", query, k);
    auto* cached = cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = *cached;
    } else {
        results = inverted_->bool_search(query_node, k, index_);
        if (!results.empty()) {
            // 收集 MUST/SHOULD/MUST_NOT 全部叶子词，作为该缓存条目的词集。
            std::vector<std::string> must, should, must_not;
            bm25::collect_terms(query_node, must, should, must_not);
            std::vector<std::string> terms = std::move(must);
            terms.insert(terms.end(), should.begin(), should.end());
            terms.insert(terms.end(), must_not.begin(), must_not.end());
            cache_.put(cache_key, results, std::move(terms));
        }
    }

    std::vector<SearchHit> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index_.ord_to_ext(r.ord);
        if (!ext_id) continue;
        hits.push_back(SearchHit{std::move(*ext_id), r.ord, r.score});
    }
    return hits;
}

void SearchLayer::recover_doc(std::string_view key, std::uint64_t ord,
                              std::string_view text,
                              std::uint32_t file_id, std::uint64_t offset,
                              std::uint32_t total_sz, std::uint32_t tstamp) {
    auto term_data = analyzer_->analyze_with_positions(text);

    std::uint32_t doc_len = 0;
    for (auto& [_, data] : term_data) {
        doc_len += data.first;
    }

    index_.put_doc(key, ord,
                   index::DocSlot{
                       index::DocLoc{file_id, offset, total_sz},
                       tstamp,
                       doc_len});

    if (!term_data.empty()) {
        inverted_->add_doc(ord, term_data);
    }
    doc_texts_.put(ord, std::string(text));
    cache_.invalidate();
}

void SearchLayer::recover_tomb(std::string_view key, std::uint64_t ord) {
    index_.remove(key, ord);
}

std::expected<void, std::string> SearchLayer::save_snapshot(std::string_view path) const {
    if (!inverted_->save(std::string(path))) {
        return std::unexpected(std::string("failed to save snapshot to ") + std::string(path));
    }
    return {};
}

std::expected<bool, std::string> SearchLayer::load_snapshot(std::string_view path) {
    if (!inverted_->load(std::string(path))) {
        return std::unexpected(std::string("failed to load snapshot from ") + std::string(path));
    }
    return true;
}

void SearchLayer::rebuild_index(DocReader doc_reader) {
    auto new_inv = std::make_unique<bm25::InvertedIndex>(config_.bm25_params);
    doc_texts_.clear();

    index_.for_each_live([&](std::uint64_t ord,
                              const std::string& /*ext_id*/,
                              const index::DocSlot& slot) {
        auto text = doc_reader(slot.loc.file_id, slot.loc.offset, slot.loc.total_sz);
        if (!text) return;

        auto term_data = analyzer_->analyze_with_positions(*text);
        if (term_data.empty()) return;

        new_inv->add_doc(ord, term_data);
        doc_texts_.put(ord, *text);
    });

    new_inv->finalize_all_postings();
    inverted_ = std::move(new_inv);
    cache_.invalidate();
}

std::expected<std::vector<SearchHitEx>, std::string>
SearchLayer::search_text_highlight(std::string_view query, std::size_t k,
                                   const HighlightOptions& opts) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHitEx>{};

    auto cache_key = CacheKey::make("highlight", query, k);
    auto* cached = cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = *cached;
    } else {
        std::vector<std::string> terms;
        terms.reserve(term_freqs.size());
        for (auto& [term, _] : term_freqs) {
            terms.push_back(term);
        }

        results = inverted_->search(terms, k, index_);
        cache_.put(cache_key, results, terms);
    }

    std::vector<SearchHitEx> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index_.ord_to_ext(r.ord);
        if (!ext_id) continue;

        // S9.3：原文 LRU 命中才生成高亮片段；冷文档被挤出（miss）时降级为
        // 无片段的 hit，而非整条丢弃——保证结果集不因 LRU 容量而缩水。
        const std::string* doc_text = doc_texts_.get(r.ord);
        std::vector<Snippet> snippets;
        if (doc_text) {
            // S9.19：analyze_with_offsets 产出的 byte offset 相对「归一化文本」，
            // 故 highlight 也必须在归一化文本上切片，否则非规范文本（全角/组合
            // 字符等）会因坐标系不一致切出乱码。NFKC 幂等，传 norm 再归一化无害。
            std::string norm = text::detail::nfkc_fold(*doc_text);
            auto token_offsets = analyzer_->analyze_with_offsets(norm);
            std::unordered_map<std::string, std::vector<text::TokenInfo>> query_token_offsets;
            for (auto& [term, _] : term_freqs) {
                auto it_token = token_offsets.find(term);
                if (it_token != token_offsets.end()) {
                    query_token_offsets[term] = it_token->second;
                }
            }
            auto hl_result = highlight(norm, query_token_offsets, opts);
            snippets = std::move(hl_result.snippets);
        }

        hits.push_back(SearchHitEx{
            std::move(*ext_id),
            r.ord,
            r.score,
            std::move(snippets)
        });
    }
    return hits;
}

}  // namespace bitcask::search