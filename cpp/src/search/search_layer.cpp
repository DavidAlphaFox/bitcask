#include "bitcask/search_layer.hpp"

#include <utility>

namespace bitcask::search {

SearchLayer::SearchLayer(const SearchLayerConfig& config)
    : config_(config)
    , index_()
    , inverted_(std::make_unique<bm25::InvertedIndex>(config.bm25_params))
    , analyzer_(text::AnalyzerFactory::create(config.analyzer_config))
{
}

void SearchLayer::on_write(std::string_view key, std::uint64_t ord,
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
}

std::optional<std::uint64_t> SearchLayer::on_delete(std::string_view key, std::uint64_t tomb_ord) {
    auto slot = index_.get(key);
    if (!slot) return std::nullopt;

    inverted_->remove_doc(slot->doc_len, {});
    index_.remove(key, tomb_ord);
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

    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) {
        terms.push_back(term);
    }

    auto results = inverted_->search(terms, k, index_);

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

    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) {
        terms.push_back(term);
    }

    auto results = inverted_->search_phrase(terms, k, index_);

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

    auto results = inverted_->bool_search(query_node, k, index_);
    if (results.empty()) return std::vector<SearchHit>{};

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

    index_.for_each_live([&](std::uint64_t ord,
                              const std::string& /*ext_id*/,
                              const index::DocSlot& slot) {
        auto text = doc_reader(slot.loc.file_id, slot.loc.offset, slot.loc.total_sz);
        if (!text) return;

        auto term_data = analyzer_->analyze_with_positions(*text);
        if (term_data.empty()) return;

        new_inv->add_doc(ord, term_data);
    });

    new_inv->finalize_all_postings();
    inverted_ = std::move(new_inv);
}

}  // namespace bitcask::search