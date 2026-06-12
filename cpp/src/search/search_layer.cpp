#include "bitcask/search_layer.hpp"
#include "bitcask/text_utils.hpp"
#include "bitcask/codec.hpp"
#include "bitcask/highlighter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <limits>
#include <string>
#include <utility>

namespace bitcask::search {

SearchLayer::SearchLayer(const SearchLayerConfig& config)
    : config_(config)
    , index_()
    , analyzer_(text::AnalyzerFactory::create(config.analyzer_config))
    , cache_(config.cache_max_entries)
    , doc_texts_(config.doc_text_cache_max)
{
    // V3.3:向量配置存在时创建 HNSW。metric 映射:cosine 已在写入端
    // 归一化 → kDot;kDot → kDot;kL2 → kL2。
    if (config.vector_dim > 0) {
        vec::HnswConfig hc;
        hc.dim = config.vector_dim;
        hc.metric = config.vector_metric == meta::VectorMetric::kL2
                        ? vec::HnswMetric::kL2
                        : vec::HnswMetric::kDot;
        hnsw_ = std::make_unique<vec::HnswIndex>(hc);
    }
}

void SearchLayer::on_vector(std::uint64_t ord, std::span<const float> vec) {
    // 防御:无 HNSW 配置 / dim 不符的向量直接忽略(不崩)。正常路径
    // put_doc 已在写入端校验过 dim。
    if (!hnsw_ || vec.size() != config_.vector_dim) return;
    hnsw_->insert(ord, vec);
}

std::expected<std::vector<SearchHit>, std::string>
SearchLayer::search_vector(std::span<const float> query, std::size_t k,
                           std::size_t ef) const {
    if (!hnsw_) {
        return std::unexpected("no vector index configured");
    }
    if (query.size() != config_.vector_dim) {
        return std::unexpected("query vector dim mismatch");
    }
    // cosine:查询向量同样入口归一化(hnsw-design §1);零向量无方向,
    // 返回空结果(写入端零向量被拒,查询端宽容)。
    std::vector<float> qn;
    std::span<const float> q = query;
    if (config_.vector_metric == meta::VectorMetric::kCosineNormalized) {
        double sq = 0.0;
        for (float v : query) sq += static_cast<double>(v) * v;
        if (sq <= 0.0) return std::vector<SearchHit>{};
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        qn.reserve(query.size());
        for (float v : query) qn.push_back(v * inv);
        q = qn;
    }
    if (ef == 0) ef = std::max<std::size_t>(k, 64);

    std::function<bool(std::uint64_t)> live = [this](std::uint64_t ord) {
        return index_.is_live(ord);
    };
    auto raw = hnsw_->search(q, k, ef, &live);

    std::vector<SearchHit> hits;
    hits.reserve(raw.size());
    for (auto& h : raw) {
        auto ext_id = index_.ord_to_ext(h.ord);
        if (!ext_id) continue;
        hits.push_back(SearchHit{std::move(*ext_id), h.ord,
                                 static_cast<double>(h.score)});
    }
    return hits;
}

bm25::InvertedIndex& SearchLayer::field_index(std::string_view field) {
    // 双检:常态(字段已存在)只拿共享锁;首次出现的字段才升级独占建索引。
    {
        std::shared_lock lk(fields_mu_);
        auto it = fields_.find(field);
        if (it != fields_.end()) return *it->second;
    }
    std::unique_lock lk(fields_mu_);
    auto it = fields_.find(field);
    if (it == fields_.end()) {
        it = fields_.emplace(std::string(field),
                             std::make_unique<bm25::InvertedIndex>(config_.bm25_params, config_.index_positions)).first;
    }
    return *it->second;
}

const bm25::InvertedIndex* SearchLayer::field_index(std::string_view field) const {
    std::shared_lock lk(fields_mu_);
    auto it = fields_.find(field);
    return it == fields_.end() ? nullptr : it->second.get();
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
        field_index(kDefaultField).add_doc(ord, term_data);
    }
    doc_texts_.put(ord, std::string(text));
    // S9.2：只失效查询词与本文档词集有交集的缓存条目。
    cache_.invalidate_terms(changed_terms);
}

void SearchLayer::on_write_fields(
    std::string_view key, std::uint64_t ord,
    const std::vector<std::pair<std::string, std::string>>& fields,
    std::uint32_t file_id, std::uint64_t offset,
    std::uint32_t total_sz, std::uint32_t tstamp) {
    std::uint32_t total_doc_len = 0;
    auto& field_lens = ord_field_lens_[ord];
    field_lens.reserve(fields.size() + 1);

    const std::string default_field(kDefaultField);
    bool wrote_default = false;    // 是否已有字段直接写入默认字段

    // catch-all（S8.6 修复 + O5 合并优化）：把非默认字段词项合并进默认字段，
    // 使 search_text/phrase/near（只查默认字段）也能命中多字段文档。
    // O5：此前是拼接原文后整体重新分词（NFKC + 分词全部重跑一遍）；改为直接
    // 合并各字段的分词结果，position 按字段顺序平移 ca_pos_base。字段内
    // 相对位置不变（phrase/near 字段内语义不变）；跨字段间隔取「字段最大
    // position + 1」，与拼接版仅在字段尾部存在被丢短词时差极小的 slop。
    text::TermPositionsMap ca_data;
    std::uint32_t ca_pos_base = 0;
    std::uint32_t ca_len = 0;

    for (auto& [fname, ftext] : fields) {
        const std::string field = fname.empty() ? default_field : fname;
        auto term_data = analyzer_->analyze_with_positions(ftext);
        std::uint32_t flen = 0;
        for (auto& [_, data] : term_data) flen += data.first;
        if (!term_data.empty()) {
            field_index(field).add_doc(ord, term_data);
        }
        field_lens.push_back({field, flen});
        total_doc_len += flen;

        if (field == default_field) {
            wrote_default = true;
        } else if (!term_data.empty()) {
            std::uint32_t field_max_pos = 0;
            for (auto& [term, data] : term_data) {
                auto& [tf, positions] = data;
                auto& [ca_tf, ca_positions] = ca_data[term];
                ca_tf += tf;
                for (auto p : positions) {
                    ca_positions.push_back(p + ca_pos_base);
                    if (p > field_max_pos) field_max_pos = p;
                }
            }
            ca_len += flen;
            ca_pos_base += field_max_pos + 1;
        }
    }

    // 若已有字段直接写默认字段，则不重复合并（避免双写）。
    if (!wrote_default && !ca_data.empty()) {
        field_index(default_field).add_doc(ord, ca_data);
        field_lens.push_back({default_field, ca_len});
    }

    index_.put_doc(key, ord,
                   index::DocSlot{
                       index::DocLoc{file_id, offset, total_sz},
                       tstamp,
                       total_doc_len});
    // 高亮：默认字段原文（多字段高亮的精细化留待后续）。
    if (!fields.empty()) doc_texts_.put(ord, fields.front().second);
    cache_.invalidate();
}

std::optional<std::uint64_t> SearchLayer::on_delete(std::string_view key, std::uint64_t tomb_ord) {
    auto slot = index_.get(key);
    if (!slot) return std::nullopt;

    // S9.2：取被删文档词集做选择性失效。原文 LRU 命中则精确 analyze；
    // miss（冷文档被挤出）则降级为整缓存失效（安全但粗粒度）。
    auto text = doc_texts_.get(slot->ord);  // 拷贝(C1:并发安全,见 DocTextLru)
    std::vector<std::string> changed_terms;
    if (text) {
        auto tf = analyzer_->analyze(*text);
        changed_terms.reserve(tf.size());
        for (auto& [term, _] : tf) changed_terms.push_back(term);
    }

    // 删除该文档在各字段的统计。多字段路径用 ord_field_lens_ 精确扣减各字段
    // doc_len（R3）；单 text 路径无此表，按默认字段用 slot->doc_len。
    if (auto it = ord_field_lens_.find(slot->ord); it != ord_field_lens_.end()) {
        for (auto& [field, flen] : it->second) {
            field_index(field).remove_doc(flen, {});
        }
        ord_field_lens_.erase(it);
    } else {
        std::shared_lock lk(fields_mu_);  // 只读 map 结构;remove_doc 自带并发
        for (auto& [_, inv] : fields_) {
            inv->remove_doc(slot->doc_len, {});
        }
    }
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
SearchLayer::search_text(std::string_view query, std::size_t k,
                         const bm25::Bm25Params* params_override) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHit>{};

    auto cache_key = CacheKey::make("text", query, k);
    auto cached = params_override
                      ? std::optional<std::vector<bm25::SearchResult>>{}
                      : cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = std::move(*cached);
    } else {
        std::vector<std::string> terms;
        terms.reserve(term_freqs.size());
        for (auto& [term, _] : term_freqs) {
            terms.push_back(term);
        }
        if (synonym_map_) {
            terms = synonym_map_->expand_terms(terms);
        }

        const auto* inv = field_index(kDefaultField);
        if (inv) results = inv->search(terms, k, index_, params_override);
        if (!params_override) cache_.put(cache_key, results, terms);
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
SearchLayer::search_phrase(std::string_view query, std::size_t k,
                           const bm25::Bm25Params* params_override) const {
    // S9.28：短语匹配依赖查询词序。analyze() 返回的 map 无序，不能直接取 terms；
    // 用 analyze_with_positions 按 position 还原 query 词序（与 search_near 一致）。
    auto tpm = analyzer_->analyze_with_positions(query);
    if (tpm.empty()) return std::vector<SearchHit>{};

    auto cache_key = CacheKey::make("phrase", query, k);
    auto cached = params_override
                      ? std::optional<std::vector<bm25::SearchResult>>{}
                      : cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = std::move(*cached);
    } else {
        std::vector<std::pair<std::uint32_t, std::string>> ordered;  // (position, term)
        for (auto& [term, data] : tpm) {
            for (auto pos : data.second) ordered.push_back({pos, term});
        }
        std::sort(ordered.begin(), ordered.end());
        std::vector<std::string> terms;
        terms.reserve(ordered.size());
        for (auto& [_, term] : ordered) terms.push_back(term);

        const auto* inv = field_index(kDefaultField);
        if (inv) results = inv->search_phrase(terms, k, index_, params_override);
        if (!params_override) cache_.put(cache_key, results, terms);
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
SearchLayer::search_near(std::string_view query, std::uint32_t slop, std::size_t k,
                         const bm25::Bm25Params* params_override) const {
    // 近邻依赖查询词序：用 analyze_with_positions 取每词 position，按 position 排序，
    // 还原 query 中的词序（analyze 返回的 map 无序，不能直接用）。
    auto tpm = analyzer_->analyze_with_positions(query);
    if (tpm.empty()) return std::vector<SearchHit>{};

    std::vector<std::pair<std::uint32_t, std::string>> ordered;  // (position, term)
    for (auto& [term, data] : tpm) {
        for (auto pos : data.second) ordered.push_back({pos, term});
    }
    std::sort(ordered.begin(), ordered.end());
    std::vector<std::string> terms;
    terms.reserve(ordered.size());
    for (auto& [_, term] : ordered) terms.push_back(term);

    std::vector<bm25::SearchResult> results;
    const auto* inv = field_index(kDefaultField);
    if (inv) results = inv->search_near(terms, k, slop, index_, params_override);

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
SearchLayer::search_fuzzy(std::string_view query, std::size_t k, std::uint32_t max_edit_distance,
                          const bm25::Bm25Params* params_override) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHit>{};

    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) {
        terms.push_back(term);
    }

    std::vector<bm25::SearchResult> results;
    const auto* inv = field_index(kDefaultField);
    if (inv) results = inv->search_fuzzy(terms, k, max_edit_distance, index_, params_override);

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
SearchLayer::bool_search(std::string_view query, std::size_t k,
                         const bm25::Bm25Params* params_override) const {
    auto query_node = bitcask::bm25::parse_query(query);
    if (query_node.term.empty() && query_node.children.empty()) {
        return std::vector<SearchHit>{};
    }

    auto cache_key = CacheKey::make("bool", query, k);
    auto cached = params_override
                      ? std::optional<std::vector<bm25::SearchResult>>{}
                      : cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = std::move(*cached);
    } else {
        const auto* inv = field_index(kDefaultField);
        if (inv) results = inv->bool_search(query_node, k, index_, params_override);
        if (!params_override && !results.empty()) {
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

std::optional<bm25::ScoreExplanation>
SearchLayer::explain(std::string_view query, std::string_view key,
                     const bm25::Bm25Params* params_override) const {
    auto slot = index_.get(key);
    if (!slot) return std::nullopt;

    auto term_freqs = analyzer_->analyze(query);
    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) terms.push_back(term);

    const auto* inv = field_index(kDefaultField);
    if (!inv) return bm25::ScoreExplanation{};
    return inv->explain(terms, slot->ord, index_, params_override);
}

std::expected<std::vector<SearchHit>, std::string>
SearchLayer::search_wildcard(std::string_view pattern, std::size_t k,
                             const bm25::Bm25Params* params_override) const {
    std::vector<bm25::SearchResult> results;
    const auto* inv = field_index(kDefaultField);
    if (inv) results = inv->search_wildcard(std::string(pattern), k, index_, params_override);

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
SearchLayer::search_fields(std::string_view query, std::size_t k,
                           const bm25::Bm25Params* params_override) const {
    auto qnode = bitcask::bm25::parse_query(query);

    std::vector<const bm25::QueryNode*> leaves;
    std::function<void(const bm25::QueryNode&)> walk = [&](const bm25::QueryNode& n) {
        if (!n.term.empty()) { leaves.push_back(&n); return; }
        for (auto& c : n.children) walk(c);
    };
    walk(qnode);
    if (leaves.empty()) return std::vector<SearchHit>{};

    struct FieldQuery { std::vector<std::string> terms; float boost; };
    std::unordered_map<std::string, std::vector<std::pair<std::string,float>>> by_field;
    for (auto* leaf : leaves) {
        std::string field = leaf->field.empty() ? std::string(kDefaultField) : leaf->field;
        auto tf = analyzer_->analyze(leaf->term);
        for (auto& [norm_term, _] : tf) {
            by_field[field].push_back({norm_term, leaf->boost});
        }
    }

    std::unordered_map<std::uint64_t, double> acc;
    for (auto& [field, term_boosts] : by_field) {
        const auto* inv = field_index(field);
        if (!inv) continue;
        std::vector<std::string> terms;
        terms.reserve(term_boosts.size());
        for (auto& [t, _] : term_boosts) terms.push_back(t);
        if (synonym_map_) {
            terms = synonym_map_->expand_terms(terms);
        }
        for (auto& [t, boost] : term_boosts) {
            auto expanded = synonym_map_ ? synonym_map_->expand(t) : std::vector<std::string>{t};
            for (auto& et : expanded) {
                auto res = inv->search({et}, k, index_, params_override);
                for (auto& r : res) acc[r.ord] += static_cast<double>(r.score) * boost;
            }
        }
    }

    std::vector<std::pair<std::uint64_t,double>> ranked(acc.begin(), acc.end());
    std::partial_sort(ranked.begin(),
                      ranked.begin() + std::min(k, ranked.size()),
                      ranked.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
    if (ranked.size() > k) ranked.resize(k);

    std::vector<SearchHit> hits;
    hits.reserve(ranked.size());
    for (auto& [ord, score] : ranked) {
        auto ext_id = index_.ord_to_ext(ord);
        if (!ext_id) continue;
        hits.push_back(SearchHit{std::move(*ext_id), ord, score});
    }
    return hits;
}

void SearchLayer::recover_doc(std::string_view key, std::uint64_t ord,
                              std::string_view text,
                              std::uint32_t file_id, std::uint64_t offset,
                              std::uint32_t total_sz, std::uint32_t tstamp,
                              std::span<const float> vector) {
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
        field_index(kDefaultField).add_doc(ord, term_data);
    }
    doc_texts_.put(ord, std::string(text));
    cache_.invalidate();
    // V3.3:向量段顺路重建 HNSW(水位幂等 → 重放重叠区安全)。
    if (!vector.empty()) on_vector(ord, vector);
}

void SearchLayer::set_synonym_map(std::unique_ptr<text::SynonymMap> map) {
    synonym_map_ = std::move(map);
    cache_.invalidate();
}

void SearchLayer::recover_tomb(std::string_view key, std::uint64_t ord) {
    index_.remove(key, ord);
}

// S8.6：多字段快照 = manifest（字段名清单）+ 每字段一个 `<path>.f<N>.inv`。
// manifest 文本行：第一行字段数，之后每行一个字段名。字段名→序号即行号。
std::uint64_t SearchLayer::indexed_ord_floor() const {
    std::shared_lock lk(fields_mu_);
    if (fields_.empty()) return static_cast<std::uint64_t>(-1);
    std::uint64_t floor = std::numeric_limits<std::uint64_t>::max() - 1;
    for (auto& [_, inv] : fields_) {
        const auto wm = inv->max_indexed_ord();
        if (wm == static_cast<std::uint64_t>(-1)) {
            return static_cast<std::uint64_t>(-1);  // 有空字段:无覆盖保证
        }
        floor = std::min(floor, wm);
    }
    return floor;
}


namespace {
constexpr std::uint32_t kSidecarMagic   = 0x42434953;  // "BCIS"
constexpr std::uint32_t kSidecarVersion = 1;
void sc_put32(std::vector<std::uint8_t>& b, std::uint32_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 4);
}
void sc_put64(std::vector<std::uint8_t>& b, std::uint64_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 8);
}
}  // namespace

bool SearchLayer::save_index_sidecar(std::string_view path,
                                     std::uint64_t covers_next_ord) const {
    std::vector<std::uint8_t> buf;
    sc_put32(buf, kSidecarMagic);
    sc_put32(buf, kSidecarVersion);
    sc_put64(buf, covers_next_ord);
    // 行数占位,回填。
    const std::size_t cnt_pos = buf.size();
    sc_put64(buf, 0);
    std::uint64_t rows = 0;
    bool ok = true;
    index_.for_each_live([&](std::uint64_t ord, const std::string& ext,
                             const index::DocSlot& slot) {
        if (ext.size() > 0xFFFF) { ok = false; return; }
        sc_put64(buf, ord);
        const auto klen = static_cast<std::uint16_t>(ext.size());
        const auto* kp = reinterpret_cast<const std::uint8_t*>(&klen);
        buf.insert(buf.end(), kp, kp + 2);
        const auto* kd = reinterpret_cast<const std::uint8_t*>(ext.data());
        buf.insert(buf.end(), kd, kd + ext.size());
        sc_put32(buf, slot.loc.file_id);
        sc_put64(buf, slot.loc.offset);
        sc_put32(buf, slot.loc.total_sz);
        sc_put32(buf, slot.tstamp);
        sc_put32(buf, slot.doc_len);
        ++rows;
    });
    if (!ok) return false;
    std::memcpy(buf.data() + cnt_pos, &rows, 8);
    const std::uint32_t crc = bitcask::codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + 8), buf.size() - 8));
    sc_put32(buf, crc);

    const std::string fp(path);
    const std::string tmp = fp + ".tmp";
    std::FILE* f = std::fopen(tmp.c_str(), "wb");
    if (!f) return false;
    const bool wrote = std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!wrote || std::rename(tmp.c_str(), fp.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    return true;
}

std::optional<std::uint64_t>
SearchLayer::load_index_sidecar(std::string_view path) {
    std::FILE* f = std::fopen(std::string(path).c_str(), "rb");
    if (!f) return std::nullopt;
    std::fseek(f, 0, SEEK_END);
    const long fsz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (fsz < 28) { std::fclose(f); return std::nullopt; }
    std::vector<std::uint8_t> buf(static_cast<std::size_t>(fsz));
    const bool rd = std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!rd) return std::nullopt;

    auto rd32 = [&](std::size_t off) {
        std::uint32_t v; std::memcpy(&v, buf.data() + off, 4); return v;
    };
    if (rd32(0) != kSidecarMagic || rd32(4) != kSidecarVersion) {
        return std::nullopt;
    }
    std::uint32_t stored_crc = 0;
    std::memcpy(&stored_crc, buf.data() + buf.size() - 4, 4);
    const std::uint32_t crc = bitcask::codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + 8), buf.size() - 12));
    if (crc != stored_crc) return std::nullopt;

    const std::uint8_t* p = buf.data() + 8;
    const std::uint8_t* end = buf.data() + buf.size() - 4;
    auto need = [&](std::size_t n) {
        return static_cast<std::size_t>(end - p) >= n;
    };
    std::uint64_t covers = 0, rows = 0;
    std::memcpy(&covers, p, 8); p += 8;
    std::memcpy(&rows, p, 8); p += 8;
    if (rows > (1ull << 40)) return std::nullopt;
    for (std::uint64_t i = 0; i < rows; ++i) {
        if (!need(10)) return std::nullopt;
        std::uint64_t ord; std::memcpy(&ord, p, 8); p += 8;
        std::uint16_t klen; std::memcpy(&klen, p, 2); p += 2;
        if (!need(static_cast<std::size_t>(klen) + 20)) return std::nullopt;
        std::string ext(reinterpret_cast<const char*>(p), klen); p += klen;
        index::DocSlot slot;
        std::memcpy(&slot.loc.file_id, p, 4); p += 4;
        std::memcpy(&slot.loc.offset, p, 8); p += 8;
        std::memcpy(&slot.loc.total_sz, p, 4); p += 4;
        std::memcpy(&slot.tstamp, p, 4); p += 4;
        std::memcpy(&slot.doc_len, p, 4); p += 4;
        index_.put_doc(ext, ord, slot);  // 重建 ext2ord/live/doc_lens/水位
    }
    if (p != end) return std::nullopt;
    return covers;
}

std::expected<void, std::string> SearchLayer::save_snapshot(std::string_view path) const {
    const std::string base(path);
    snapshot_path_ = base;
    std::ofstream mf(base + ".manifest", std::ios::binary);
    if (!mf) return std::unexpected("failed to open manifest for " + base);
    std::shared_lock fields_lk(fields_mu_);  // 快照期间禁止新字段插入
    mf << fields_.size() << '\n';
    std::size_t idx = 0;
    for (auto& [field, inv] : fields_) {
        mf << field << '\n';   // 字段名（可能含控制字符前缀，按行存）
        if (!inv->save(base + ".f" + std::to_string(idx) + ".inv")) {
            return std::unexpected("failed to save field snapshot " + field);
        }
        inv->truncate_wal();
        ++idx;
    }
    if (!mf.good()) return std::unexpected("failed to write manifest for " + base);
    return {};
}

std::expected<bool, std::string> SearchLayer::load_snapshot(std::string_view path) {
    const std::string base(path);
    snapshot_path_ = base;
    std::ifstream mf(base + ".manifest", std::ios::binary);
    if (mf) {
        std::size_t count = 0;
        mf >> count;
        mf.get();  // 吃掉换行
        std::unique_lock fields_lk(fields_mu_);
        fields_.clear();
        for (std::size_t i = 0; i < count; ++i) {
            std::string field;
            if (!std::getline(mf, field)) {
                return std::unexpected("manifest truncated for " + base);
            }
            auto inv = std::make_unique<bm25::InvertedIndex>(config_.bm25_params, config_.index_positions);
            if (!inv->load(base + ".f" + std::to_string(i) + ".inv")) {
                return std::unexpected("failed to load field snapshot " + field);
            }
            // S8.9：加载快照后如 WAL 文件存在，启用并重放。
            auto wal_path = base + ".f" + std::to_string(i) + ".inv.wal";
            if (std::ifstream(wal_path).good()) {
                inv->enable_wal(wal_path);
                inv->replay_wal();
            }
            fields_.emplace(std::move(field), std::move(inv));
        }
        return true;
    }
    // 回退：无 manifest 时尝试旧单文件格式 → 映射到默认字段（向后兼容）。
    auto inv_fallback = std::make_unique<bm25::InvertedIndex>(config_.bm25_params, config_.index_positions);
    if (!inv_fallback->load(base)) {
        return std::unexpected(std::string("failed to load snapshot from ") + base);
    }
    fields_.clear();
    fields_.emplace(std::string(kDefaultField), std::move(inv_fallback));
    return true;
}

void SearchLayer::rebuild_index(DocReader doc_reader) {
    // 阶段2a：仍按默认字段重建（多字段从 DocValue 取字段在阶段4打通）。
    auto new_inv = std::make_unique<bm25::InvertedIndex>(config_.bm25_params, config_.index_positions);
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

    const std::string default_field(kDefaultField);
    auto it = fields_.find(default_field);
    bool had_wal = (it != fields_.end()) && it->second->has_wal();

    fields_.clear();
    fields_.emplace(default_field, std::move(new_inv));

    if (had_wal && !snapshot_path_.empty()) {
        fields_[default_field]->enable_wal(snapshot_path_ + ".f0.inv.wal");
    }

    cache_.invalidate();
}

std::size_t SearchLayer::compact(double dead_ratio_threshold) {
    std::size_t total = 0;
    for (auto& [field, inv] : fields_) {
        total += inv->compact(index_, dead_ratio_threshold);
    }
    if (total > 0) cache_.invalidate();  // posting 行变了，缓存可能含陈旧结果
    return total;
}

std::expected<std::vector<SearchHitEx>, std::string>
SearchLayer::search_text_highlight(std::string_view query, std::size_t k,
                                   const HighlightOptions& opts) const {
    auto term_freqs = analyzer_->analyze(query);
    if (term_freqs.empty()) return std::vector<SearchHitEx>{};

    auto cache_key = CacheKey::make("highlight", query, k);
    auto cached = cache_.get(cache_key);

    std::vector<bm25::SearchResult> results;
    if (cached) {
        results = std::move(*cached);
    } else {
        std::vector<std::string> terms;
        terms.reserve(term_freqs.size());
        for (auto& [term, _] : term_freqs) {
            terms.push_back(term);
        }

        const auto* inv = field_index(kDefaultField);
        if (inv) results = inv->search(terms, k, index_);
        cache_.put(cache_key, results, terms);
    }

    std::vector<SearchHitEx> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index_.ord_to_ext(r.ord);
        if (!ext_id) continue;

        // S9.3：原文 LRU 命中才生成高亮片段；冷文档被挤出（miss）时降级为
        // 无片段的 hit，而非整条丢弃——保证结果集不因 LRU 容量而缩水。
        auto doc_text = doc_texts_.get(r.ord);  // 拷贝(C1)
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