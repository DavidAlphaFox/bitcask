#pragma once

#include <cstdint>
#include <expected>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "bitcask/analyzer.hpp"
#include "bitcask/collection_registry.hpp"
#include "bitcask/data_file.hpp"
#include "bitcask/file_lock.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"

namespace bitcask {

struct CollectionOptions {
    std::uint64_t max_file_size = 2ULL * 1024ULL * 1024ULL * 1024ULL;  // 2 GiB
    bool          o_sync        = false;
    bool          read_write    = true;
    text::AnalyzerConfig analyzer_config;
    bm25::Bm25Params    bm25_params;
};

enum class CollectionError {
    kIo,
    kBadCrc,
    kNotFound,
    kCorrupt,
    kWriteLocked,
    kKeyTooLarge,
    kValueTooLarge,
    kReadOnly,
};

struct CollectionFault {
    CollectionError kind;
    int             errnum = 0;
    std::string     detail;
};

struct DocInput {
    std::optional<std::span<const float>>     vector;
    std::optional<std::string_view>           text;
    std::optional<std::span<const std::byte>> meta;
};

struct Doc {
    bool                   has_vector = false;
    std::vector<float>     vector;
    bool                   has_text   = false;
    std::string            text;
    bool                   has_meta   = false;
    std::vector<std::byte> meta;
    std::uint32_t          tstamp     = 0;
};

struct TextHit {
    std::string ext_id;
    float       score;
};

class Collection {
public:
    Collection() = default;
    ~Collection();
    Collection(const Collection&) = delete;
    Collection& operator=(const Collection&) = delete;

    [[nodiscard]] static std::expected<std::unique_ptr<Collection>, CollectionFault>
    open(std::string_view dirname, const CollectionOptions& opts,
         CollectionRegistry* registry = nullptr);

    void close() noexcept;

    [[nodiscard]] std::expected<std::uint64_t, CollectionFault>
    upsert(std::string_view ext_id, const DocInput& doc,
           std::uint32_t tstamp = 0);

    [[nodiscard]] std::expected<Doc, CollectionFault>
    get(std::string_view ext_id);

    [[nodiscard]] std::expected<bool, CollectionFault>
    remove(std::string_view ext_id, std::uint32_t tstamp = 0);

    [[nodiscard]] std::expected<std::vector<TextHit>, CollectionFault>
    search_text(std::string_view query, std::size_t k = 10);

    [[nodiscard]] std::expected<std::vector<TextHit>, CollectionFault>
    search_phrase(std::string_view query, std::size_t k = 10);

    [[nodiscard]] std::expected<void, CollectionFault> sync();

    [[nodiscard]] index::IndexInfo info() const { return shared_->index.info(); }
    [[nodiscard]] std::string_view dirname() const noexcept { return dirname_; }

private:
    [[nodiscard]] std::expected<void, CollectionFault> recover();
    [[nodiscard]] std::expected<void, CollectionFault>
    roll_active_if_needed(std::size_t about_to_write);
    [[nodiscard]] std::expected<void, CollectionFault> open_active(std::uint32_t file_id);
    [[nodiscard]] fileops::DataFile* read_file(std::uint32_t file_id);

    std::string         dirname_;
    CollectionOptions   opts_;

    std::shared_ptr<CollectionSharedData> shared_;

    std::optional<lock::FileLock> write_lock_;

    std::unique_ptr<fileops::DataFile> active_;
    std::uint32_t                      active_file_id_ = 0;

    std::unordered_map<std::uint32_t, fileops::DataFile> read_files_;

    CollectionRegistry* registry_ = nullptr;
    std::string         registry_name_;
};

}  // namespace bitcask
