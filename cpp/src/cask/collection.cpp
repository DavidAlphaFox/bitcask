#include "bitcask/collection.hpp"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <thread>
#include <utility>

#include "bitcask/codec.hpp"
#include "bitcask/format.hpp"
#include "bitcask/ngram_analyzer.hpp"
#include "bitcask/scanner.hpp"

namespace bitcask {

namespace {
namespace fs = std::filesystem;

CollectionFault io_fault(int errnum, std::string detail = {}) {
    return CollectionFault{CollectionError::kIo, errnum, std::move(detail)};
}
CollectionFault err(CollectionError k, std::string detail = {}) {
    return CollectionFault{k, 0, std::move(detail)};
}

std::uint32_t now_sec() {
    return static_cast<std::uint32_t>(
        std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
}

std::span<const std::byte> str_to_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}
std::string_view bytes_to_view(std::span<const std::byte> b) {
    return {reinterpret_cast<const char*>(b.data()), b.size()};
}

CollectionFault df_fault(const fileops::DataFileFault& f) {
    switch (f.kind) {
        case fileops::DataFileError::kBadCrc:    return err(CollectionError::kBadCrc);
        case fileops::DataFileError::kIo:        return io_fault(f.errnum);
        case fileops::DataFileError::kShortRead: return err(CollectionError::kCorrupt, "short read");
        case fileops::DataFileError::kTooLarge:  return err(CollectionError::kValueTooLarge);
    }
    return err(CollectionError::kIo);
}

}  // namespace

Collection::~Collection() { close(); }

std::expected<std::unique_ptr<Collection>, CollectionFault>
Collection::open(std::string_view dirname, const CollectionOptions& opts,
                 CollectionRegistry* registry) {
    auto self = std::make_unique<Collection>();
    self->dirname_ = std::string(dirname);
    self->opts_    = opts;

    if (registry != nullptr) {
        self->registry_      = registry;
        self->registry_name_ = std::string(dirname);

        auto a = registry->acquire(dirname);
        if (a.status == CollectionAcquireStatus::kNotReady) {
            for (int i = 0; i < 40; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                a = registry->acquire(dirname);
                if (a.status != CollectionAcquireStatus::kNotReady) break;
            }
            if (a.status == CollectionAcquireStatus::kNotReady) {
                return std::unexpected(err(CollectionError::kIo,
                    "collection shared data not_ready after wait"));
            }
        }

        self->shared_ = a.data;

        if (a.status == CollectionAcquireStatus::kCreated) {
            self->shared_->inverted = std::make_unique<bm25::InvertedIndex>(opts.bm25_params);
            self->shared_->analyzer = text::AnalyzerFactory::create(opts.analyzer_config);
            if (!self->shared_->analyzer) {
                registry->release(dirname);
                return std::unexpected(err(CollectionError::kCorrupt, "invalid analyzer config"));
            }
        }
    } else {
        auto data = std::make_shared<CollectionSharedData>();
        data->inverted = std::make_unique<bm25::InvertedIndex>(opts.bm25_params);
        data->analyzer = text::AnalyzerFactory::create(opts.analyzer_config);
        if (!data->analyzer) {
            return std::unexpected(err(CollectionError::kCorrupt, "invalid analyzer config"));
        }
        self->shared_ = data;
    }

    std::error_code ec;
    fs::create_directories(dirname, ec);
    if (ec) return std::unexpected(io_fault(ec.value(), "create_directories"));

    if (opts.read_write) {
        const auto lock_path = (fs::path(dirname) / "bitcask.write.lock").string();
        auto lk = lock::FileLock::acquire(lock_path, true);
        if (!lk) {
            if (registry) registry->release(dirname);
            if (lk.error().errnum == EEXIST) {
                return std::unexpected(err(CollectionError::kWriteLocked));
            }
            return std::unexpected(io_fault(lk.error().errnum, "acquire write.lock"));
        }
        self->write_lock_ = std::move(*lk);
    }

    if (registry != nullptr && registry->query(dirname).status == CollectionAcquireStatus::kReady) {
        // 已有初始化者完成恢复，跳过 recover。
    } else {
        if (auto r = self->recover(); !r) {
            if (registry) registry->release(dirname);
            return std::unexpected(r.error());
        }
        self->shared_->mark_ready();
    }

    return self;
}

void Collection::close() noexcept {
    active_.reset();
    read_files_.clear();
    if (write_lock_) {
        write_lock_->release_quiet();
        write_lock_.reset();
    }
    if (registry_ && !registry_name_.empty()) {
        registry_->release(registry_name_);
        registry_name_.clear();
    }
}

std::expected<void, CollectionFault> Collection::recover() {
    auto entries = fileops::scan_dir(dirname_);
    if (!entries) {
        return std::unexpected(io_fault(entries.error().errnum, "scan_dir"));
    }

    auto& index     = shared_->index;
    auto& inverted  = shared_->inverted;
    auto& analyzer  = shared_->analyzer;

    auto snapshot_path = std::string(dirname_) + "/bm25_snapshot.inv";
    bool has_snapshot = inverted->load(snapshot_path);

    std::uint32_t max_file_id = 0;
    for (const auto& e : *entries) {
        const auto file_id = static_cast<std::uint32_t>(e.tstamp);
        max_file_id = std::max(max_file_id, file_id);

        auto df = fileops::DataFile::open(e.data_path, fileops::DataFile::Mode::kRead);
        if (!df) return std::unexpected(df_fault(df.error()));

        auto fold = df->fold(
            [&](const codec::DataRecordView& v, std::uint64_t offset,
                std::uint32_t total) {
                const std::string_view ext_id = bytes_to_view(v.key);
                if (v.type == format::RecordType::kTombstone) {
                    index.remove(ext_id, v.ord);
                } else {
                    std::uint32_t doc_len = 0;

                    if (!has_snapshot) {
                        text::TermPositionsMap term_data;
                        auto dv = codec::decode_doc_value(v.value);
                        if (dv && dv->has_text) {
                            auto text_sv = std::string_view(
                                reinterpret_cast<const char*>(dv->text.data()),
                                dv->text.size());
                            term_data = analyzer->analyze_with_positions(text_sv);
                            for (auto& [_, data] : term_data) doc_len += data.first;
                        }

                        index.put_doc(ext_id, v.ord,
                                       index::DocSlot{
                                           index::DocLoc{file_id, offset, total},
                                           v.tstamp, doc_len});

                        if (!term_data.empty()) {
                            inverted->add_doc(v.ord, term_data);
                        }
                    } else {
                        auto dv = codec::decode_doc_value(v.value);
                        if (dv && dv->has_text) {
                            auto text_sv = std::string_view(
                                reinterpret_cast<const char*>(dv->text.data()),
                                dv->text.size());
                            auto tfs = analyzer->analyze(text_sv);
                            for (auto& [_, tf] : tfs) doc_len += tf;
                        }
                        index.put_doc(ext_id, v.ord,
                                       index::DocSlot{
                                           index::DocLoc{file_id, offset, total},
                                           v.tstamp, doc_len});
                    }
                }
            });
        if (!fold) return std::unexpected(df_fault(fold.error()));
    }

    if (opts_.read_write) {
        return open_active(max_file_id + 1);
    }
    return {};
}

std::expected<void, CollectionFault> Collection::open_active(std::uint32_t file_id) {
    const auto path = fileops::mk_data_filename(dirname_, file_id);
    auto df = fileops::DataFile::open(path, fileops::DataFile::Mode::kCreate,
                                       opts_.o_sync);
    if (!df) return std::unexpected(df_fault(df.error()));
    active_         = std::make_unique<fileops::DataFile>(std::move(*df));
    active_file_id_ = file_id;
    return {};
}

std::expected<void, CollectionFault>
Collection::roll_active_if_needed(std::size_t about_to_write) {
    if (!active_) return open_active(active_file_id_ + 1);
    if (active_->size() > 0 &&
        active_->size() + about_to_write > opts_.max_file_size) {
        const std::uint32_t next = active_file_id_ + 1;
        active_.reset();
        return open_active(next);
    }
    return {};
}

fileops::DataFile* Collection::read_file(std::uint32_t file_id) {
    if (auto it = read_files_.find(file_id); it != read_files_.end()) {
        return &it->second;
    }
    auto df = fileops::DataFile::open(fileops::mk_data_filename(dirname_, file_id),
                                       fileops::DataFile::Mode::kRead);
    if (!df) return nullptr;
    auto [it, _] = read_files_.emplace(file_id, std::move(*df));
    return &it->second;
}

std::expected<std::uint64_t, CollectionFault>
Collection::upsert(std::string_view ext_id, const DocInput& doc,
                   std::uint32_t tstamp) {
    if (!opts_.read_write) {
        return std::unexpected(err(CollectionError::kReadOnly));
    }
    if (ext_id.size() > format::kMaxKeySize) {
        return std::unexpected(err(CollectionError::kKeyTooLarge));
    }

    auto& index    = shared_->index;
    auto& inverted = shared_->inverted;
    auto& analyzer = shared_->analyzer;

    codec::DocValueParts parts;
    if (doc.vector) parts.vector = *doc.vector;
    if (doc.text)   parts.text   = str_to_bytes(*doc.text);
    if (doc.meta)   parts.meta   = *doc.meta;
    std::vector<std::byte> val;
    codec::encode_doc_value(val, parts);
    if (val.size() > format::kMaxValueSize) {
        return std::unexpected(err(CollectionError::kValueTooLarge));
    }

    if (auto r = roll_active_if_needed(format::kHeaderSize + ext_id.size() + val.size());
        !r) {
        return std::unexpected(r.error());
    }

    const std::uint32_t ts  = tstamp ? tstamp : now_sec();
    const std::uint64_t ord = index.alloc_ord();
    auto w = active_->write(format::RecordType::kDoc, ts, ord,
                            str_to_bytes(ext_id), val);
    if (!w) return std::unexpected(df_fault(w.error()));

    std::uint32_t doc_len = 0;
    text::TermPositionsMap term_data;
    if (doc.text) {
        term_data = analyzer->analyze_with_positions(*doc.text);
        for (auto& [_, data] : term_data) doc_len += data.first;
    }

    index.put_doc(ext_id, ord,
                   index::DocSlot{index::DocLoc{active_file_id_, w->offset,
                                                w->total_size},
                                  ts, doc_len});

    if (!term_data.empty()) {
        inverted->add_doc(ord, term_data);
    }
    return ord;
}

std::expected<Doc, CollectionFault> Collection::get(std::string_view ext_id) {
    auto slot = shared_->index.get(ext_id);
    if (!slot) return std::unexpected(err(CollectionError::kNotFound));

    auto* df = read_file(slot->loc.file_id);
    if (!df) return std::unexpected(err(CollectionError::kIo, "open data file for read"));

    auto rec = df->read(slot->loc.offset, slot->loc.total_sz);
    if (!rec) return std::unexpected(df_fault(rec.error()));
    if (rec->type != format::RecordType::kDoc) {
        return std::unexpected(err(CollectionError::kCorrupt, "expected kDoc"));
    }

    auto dv = codec::decode_doc_value(rec->value);
    if (!dv) return std::unexpected(err(CollectionError::kCorrupt, "decode_doc_value"));

    Doc out;
    out.tstamp = rec->tstamp;
    if (dv->has_vector) {
        out.has_vector = true;
        out.vector.resize(dv->dim);
        if (dv->dim) {
            std::memcpy(out.vector.data(), dv->vector_raw.data(),
                        static_cast<std::size_t>(dv->dim) * sizeof(float));
        }
    }
    if (dv->has_text) {
        out.has_text = true;
        out.text.assign(reinterpret_cast<const char*>(dv->text.data()),
                        dv->text.size());
    }
    if (dv->has_meta) {
        out.has_meta = true;
        out.meta.assign(dv->meta.begin(), dv->meta.end());
    }
    return out;
}

std::expected<bool, CollectionFault>
Collection::remove(std::string_view ext_id, std::uint32_t tstamp) {
    if (!opts_.read_write) {
        return std::unexpected(err(CollectionError::kReadOnly));
    }

    auto& index    = shared_->index;
    auto& inverted = shared_->inverted;

    if (!index.get(ext_id)) {
        return false;
    }
    if (auto r = roll_active_if_needed(format::kHeaderSize + ext_id.size()); !r) {
        return std::unexpected(r.error());
    }
    const std::uint32_t ts  = tstamp ? tstamp : now_sec();
    const std::uint64_t ord = index.alloc_ord();
    auto w = active_->write(format::RecordType::kTombstone, ts, ord,
                            str_to_bytes(ext_id), {});
    if (!w) return std::unexpected(df_fault(w.error()));

    auto slot = index.get(ext_id);
    if (slot && slot->doc_len > 0) {
        text::TermFreqMap empty;
        inverted->remove_doc(slot->doc_len, empty);
    }
    return index.remove(ext_id, ord);
}

std::expected<std::vector<TextHit>, CollectionFault>
Collection::search_text(std::string_view query, std::size_t k) {
    auto& index    = shared_->index;
    auto& inverted = shared_->inverted;
    auto& analyzer = shared_->analyzer;

    auto term_freqs = analyzer->analyze(query);
    if (term_freqs.empty()) return std::vector<TextHit>{};

    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) {
        terms.push_back(term);
    }

    auto results = inverted->search(terms, k, index);

    std::vector<TextHit> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index.ord_to_ext(r.ord);
        if (!ext_id) continue;
        hits.push_back(TextHit{std::move(*ext_id), r.score});
    }
    return hits;
}

std::expected<std::vector<TextHit>, CollectionFault>
Collection::search_phrase(std::string_view query, std::size_t k) {
    auto& index    = shared_->index;
    auto& inverted = shared_->inverted;
    auto& analyzer = shared_->analyzer;

    auto term_freqs = analyzer->analyze(query);
    if (term_freqs.empty()) return std::vector<TextHit>{};

    std::vector<std::string> terms;
    terms.reserve(term_freqs.size());
    for (auto& [term, _] : term_freqs) {
        terms.push_back(term);
    }

    auto results = inverted->search_phrase(terms, k, index);

    std::vector<TextHit> hits;
    hits.reserve(results.size());
    for (auto& r : results) {
        auto ext_id = index.ord_to_ext(r.ord);
        if (!ext_id) continue;
        hits.push_back(TextHit{std::move(*ext_id), r.score});
    }
    return hits;
}

std::expected<void, CollectionFault> Collection::sync() {
    if (!active_) return {};
    auto s = active_->sync();
    if (!s) return std::unexpected(df_fault(s.error()));

    auto snapshot_path = std::string(dirname_) + "/bm25_snapshot.inv";
    shared_->inverted->save(snapshot_path);
    return {};
}

}  // namespace bitcask
