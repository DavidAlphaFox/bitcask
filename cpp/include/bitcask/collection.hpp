// 向量库的进程级门面（Collection）。
//
// Collection 是 legacy Cask 的演化版（doc/vector-db-design-zh.md §5）：把
// Index（内存侧表）、DataFile（append-only typed record 日志）、FileLock、
// scanner 串成一个可 upsert/get/remove 的句柄。V1 范围——还没有 BM25/HNSW
// 检索，向量与文本存得进、取得回，但不能按内容搜。
//
// === 线程模型 ===
// 读路径（get）线程安全：Index shared_lock + DataFile::read 走 pread。
// 写路径（upsert/remove/sync/close）非线程安全：要求 caller 串行化
// （V1「单写者」模型，与 legacy Cask 一致）。

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
#include "bitcask/data_file.hpp"
#include "bitcask/file_lock.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"

namespace bitcask {

struct CollectionOptions {
    std::uint64_t max_file_size = 2ULL * 1024ULL * 1024ULL * 1024ULL;  // 2 GiB
    bool          o_sync        = false;
    text::AnalyzerConfig analyzer_config;   // 分词器配置（默认 Ngram bi/tri-gram）
    bm25::Bm25Params    bm25_params;        // BM25 参数（默认 k1=1.2, b=0.75）
};

enum class CollectionError {
    kIo,
    kBadCrc,
    kNotFound,
    kCorrupt,        // record 解码失败 / 索引与磁盘不一致
    kWriteLocked,    // 别人持有 write.lock
    kKeyTooLarge,
    kValueTooLarge,
};

struct CollectionFault {
    CollectionError kind;
    int             errnum = 0;
    std::string     detail;
};

// upsert 输入：三段皆可选。
struct DocInput {
    std::optional<std::span<const float>>     vector;
    std::optional<std::string_view>           text;
    std::optional<std::span<const std::byte>> meta;
};

// get 输出：解包后的文档。
struct Doc {
    bool                   has_vector = false;
    std::vector<float>     vector;
    bool                   has_text   = false;
    std::string            text;
    bool                   has_meta   = false;
    std::vector<std::byte> meta;
    std::uint32_t          tstamp     = 0;
};

// search_text 输出：匹配文档 + BM25 分数。
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

    // 打开（或新建）一个 collection 目录。拿 bitcask.write.lock，扫描已有
    // data 文件重建 Index（恢复，§8），新建一个 active 写文件。
    [[nodiscard]] static std::expected<std::unique_ptr<Collection>, CollectionFault>
    open(std::string_view dirname, const CollectionOptions& opts);

    void close() noexcept;

    // 写入/更新一条文档。返回分配的 ord。
    // 线程安全：否（写路径串行）。
    [[nodiscard]] std::expected<std::uint64_t, CollectionFault>
    upsert(std::string_view ext_id, const DocInput& doc,
           std::uint32_t tstamp = 0);

    // 读取一条文档。不存在返回 kNotFound。线程安全：是。
    [[nodiscard]] std::expected<Doc, CollectionFault>
    get(std::string_view ext_id);

    // 删除一条文档（写墓碑 + 软删）。返回原本是否存在。线程安全：否。
    [[nodiscard]] std::expected<bool, CollectionFault>
    remove(std::string_view ext_id, std::uint32_t tstamp = 0);

    // BM25 全文检索：query 切词 → 倒排查询 → top-k。
    // 线程安全：是（读路径）。
    [[nodiscard]] std::expected<std::vector<TextHit>, CollectionFault>
    search_text(std::string_view query, std::size_t k = 10);

    // fsync active 文件。线程安全：否。
    [[nodiscard]] std::expected<void, CollectionFault> sync();

    [[nodiscard]] index::IndexInfo info() const { return index_.info(); }
    [[nodiscard]] std::string_view dirname() const noexcept { return dirname_; }

private:
    [[nodiscard]] std::expected<void, CollectionFault> recover();
    [[nodiscard]] std::expected<void, CollectionFault>
    roll_active_if_needed(std::size_t about_to_write);
    [[nodiscard]] std::expected<void, CollectionFault> open_active(std::uint32_t file_id);
    [[nodiscard]] fileops::DataFile* read_file(std::uint32_t file_id);

    std::string                dirname_;
    CollectionOptions          opts_;
    index::Index               index_;
    std::unique_ptr<bm25::InvertedIndex> inverted_;
    std::unique_ptr<text::Analyzer> analyzer_;
    std::optional<lock::FileLock> write_lock_;

    std::unique_ptr<fileops::DataFile> active_;
    std::uint32_t                      active_file_id_ = 0;

    // 按 file_id 缓存的只读 DataFile 句柄（含 active 文件本身）。
    std::unordered_map<std::uint32_t, fileops::DataFile> read_files_;
};

}  // namespace bitcask
