// bitcask 高层门面：把 keydir、data file、hint file、scanner、merger 串起来，
// 整合成一个进程级 handle。专为 M3.4 的「粗粒度 NIF 暴露」设计——
// 一次 open / close / get / put / delete 就够，替代 legacy 那 30+ 个细粒度
// keydir_*_int / file_*_int 调用。
//
// === 线程模型 ===
//
// 一个 Cask 由单个 Erlang 进程持有 resource ref 拥有。底层 KeyDir 可能在
// 同目录的多个 Cask 之间共享（KeyDirRegistry 管 refcount）——多写者要求
// 调用方自己串行化（M5 的 cask_cpp 是「一个 Erlang 进程一个 Cask」模型，
// 因此 Cask 自身不做内部并发写控制）。
//
// 读路径无锁：keydir get + DataFile 的 pread 是 thread-safe 的，read_files_
// cache 由 read_cache_mu_ 保护。
//
// 写路径单线程：put / delete / sync / close_write_file 串行，由调用方
// （单 Erlang 进程）保证。merge 在 dirty IO 调度器上跑，跟 put 共享
// keydir 的 shared_mutex 做并发保护。

#pragma once

#include <cstdint>
#include <expected>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

#include "bitcask/data_file.hpp"
#include "bitcask/file_lock.hpp"
#include "bitcask/hint_file.hpp"
#include "bitcask/keydir.hpp"
#include "bitcask/keydir_registry.hpp"
#include "bitcask/merge_policy.hpp"
#include "bitcask/merger.hpp"
#include "bitcask/meta_file.hpp"
#include "bitcask/field_schema.hpp"
#include "bitcask/search_layer.hpp"
#include "bitcask/thread_pool.hpp"

namespace bitcask {

// --- 配置 --------------------------------------------------------------------
struct CaskOptions {
    bool          read_write       = false;
    std::uint64_t max_file_size    = 2ULL * 1024ULL * 1024ULL * 1024ULL;  // 2 GiB
    bool          o_sync           = false;
    bool          require_hint_crc = false;  // legacy 默认 false；M5 之后可能改 true
    // tstamp < (now - expiry_secs) 的 record 在 get/fold 中被过滤，
    // 同时进入「过期触发 merge」的候选。0 = 禁用。
    std::uint32_t expiry_secs      = 0;

    // merge_only 模式（M5.1 task 2）。true 时：
    //   - 拿 bitcask.merge.lock 而不是 bitcask.write.lock：原 writer 仍能
    //     正常运行（持有 write.lock），并发 merge 不冲突；
    //   - 不创建 active writer 文件——merger 自己生成新输出文件
    //     （keydir->increment_file_id()）；
    //   - open 时读 bitcask.write.lock，得知 live writer 当前 active file id，
    //     在 needs_merge 里把它从候选里排除（不能并别人正在写的文件）。
    //
    // 这是 bitcask:merge/N 在 cask_cpp 模式下的实现机制——周期性的
    // merge_worker 不会跟主 writer 互相阻塞。
    // 跟普通 read_write 模式互斥；merge_only 隐含 read_write 文件语义
    // （要写新文件），但不在该 Cask handle 上提供 put/delete API。
    bool          merge_only       = false;

    // remove() 写入哪种墓碑格式。读时三种 (v0/v1/v2) 都接受。
    //   0 → "bitcask_tombstone"            (17 B)  默认，最简单
    //   2 → "bitcask_tombstone2" + FileId  (22 B)  支持「shadow file_id 仍存在
    //                                              才允许 merge 时回收」的精细
    //                                              并发控制
    // (v1 在磁盘上跟 v2 同形不同前缀；legacy 用作中间态，cask 不写它，
    //  只读时识别。)
    std::uint8_t  tombstone_version = 0;

    merge::PolicyOptions policy{};
    // Phase 4: enable_search 用于 meta 检查；search_config 用于 SearchLayer 创建。
    // search_config.has_value() 时才真正创建 SearchLayer。
    bool enable_search = false;
    std::optional<search::SearchLayerConfig> search_config;
};

// --- 错误码 ------------------------------------------------------------------
enum class CaskError {
    kIo,
    kBadCrc,
    kNotFound,            // get 不到 key
    kKeyTooLarge,
    kValueTooLarge,
    kAlreadyExists,       // CAS race
    kReadOnly,            // 写操作给到只读 cask
    kWriteLocked,         // 别人已经持有 write.lock / merge.lock
    kInvalidOption,
    kNoIndex,           // KV 模式下调用了 search 接口
    kModeMismatch,      // 文件模式与打开选项不匹配
    kAnalyzerMismatch,  // 分析器类型不匹配
};

struct CaskFault {
    CaskError kind;
    int errnum = 0;
    std::string detail;
};

struct GetResult {
    std::vector<std::byte> value;  // DocValue 解码后的 text 段（纯 binary）
    std::vector<std::byte> meta;   // DocValue 解码后的 meta 段（可为空）
    std::uint32_t tstamp = 0;
    std::uint64_t ord = 0;
};

struct TextSearchResult {
    std::vector<search::SearchHit> hits;
};

// put_doc 的输入结构：text 是必须的，meta 可选。
// S8.6：fields 非空时走多字段路径（编码进 DocValue v2 fields 段 + 多字段索引）。
struct DocInput {
    std::span<const std::byte> text;    // required（多字段时可空，作默认字段）
    std::span<const std::byte> meta;    // optional
    std::vector<std::pair<std::string, std::span<const std::byte>>> fields;  // S8.6
};

struct StatusInfo {
    std::uint64_t key_count = 0;
    std::uint64_t key_bytes = 0;
    std::uint64_t epoch     = 0;
    std::vector<merge::FileStatus> files;
};

class Cask;

// --- fold 迭代器 -------------------------------------------------------------
// 遍历 make_iter() 时刻的全部活跃 (key, value)。snapshot 语义靠
// KeyDir::IterHandle 提供；每条 entry 的 value 在 next() 时按需 pread。
// 设计上是「per-step 一次 NIF 调用」，方便上层在 BEAM scheduler 之间让出。
//
// === 线程模型 ===
// CaskIter 自身不持锁，方法非线程安全——同一对象只能由一个线程使用。
// 但不同 CaskIter 对象之间可在多线程并发使用同一个 parent Cask
// （读路径并行 + KeyDir::IterHandle 支持多 fold）。
class CaskIter {
public:
    explicit CaskIter(Cask* parent) noexcept : parent_(parent) {}
    ~CaskIter() noexcept;
    CaskIter(const CaskIter&) = delete;
    CaskIter& operator=(const CaskIter&) = delete;

    // see_tombstones：true 时被删除的 key 也会作为一条 entry 出现在
    // next() 里——is_tombstone=true，value 是墓碑标记字节
    // （对应 legacy fold/6 + fold_keys/6 的 SeeTombstones=true 行为）。
    // false（默认）下墓碑被静默跳过。
    //
    // 返回底层 keydir 的 StartIterResult：
    //   kOk         — 真的开始迭代了
    //   kOutOfDate  — pending 表 freshness 检查没过；caller 应稍后重试
    // CaskFault 留给真正的失败（比如 handle 已经在迭代）。
    // 线程安全: 否（修改自身字段）；同一 CaskIter 不可并发使用。
    [[nodiscard]] std::expected<keydir::StartIterResult, CaskFault>
    start(int maxage = -1, int maxputs = -1, std::uint32_t now_sec = 0,
          bool see_tombstones = false);

    // 取下一项；end-of-iteration 返回 nullopt。Entry 内部的 vector 拥有
    // 自己的存储，调用方持有期间可任意使用。
    struct Entry {
        std::vector<std::byte> key;
        std::vector<std::byte> value;
        std::uint32_t tstamp = 0;
        std::uint32_t file_id = 0;
        std::uint64_t offset = 0;
        std::uint32_t total_sz = 0;
        bool is_tombstone = false;
        std::uint64_t ord = 0;
    };
    // 线程安全: 否（推进 iter_ + 内部 pread）；同一对象不可并发使用。
    [[nodiscard]] std::expected<std::optional<Entry>, CaskFault> next();

    // 线程安全: 否；幂等。同一对象的 start/next/release 串行调用。
    void release() noexcept;
    [[nodiscard]] bool is_iterating() const noexcept { return iter_ != nullptr; }

private:
    // S13：fold 启动时 pin 一份「目录下全部 data file」的只读句柄快照。
    // 并发 merge 在 fold 期间 unlink 旧文件时，已 open 的 fd 让 inode 在
    // Linux 上存活，next() 仍能从 pin 的句柄 pread——不会因文件被删而失败。
    // 不含 active write file（merge 从不合并它，交给 parent_->read_file）。
    void pin_files();

    Cask* parent_;
    std::unique_ptr<keydir::IterHandle> iter_;
    bool see_tombstones_ = false;
    std::unordered_map<std::uint32_t,
                       std::unique_ptr<fileops::DataFile>> pinned_files_;
};

// --- Cask ------------------------------------------------------------------
class Cask {
public:
    Cask() = default;
    ~Cask();
    Cask(const Cask&) = delete;
    Cask& operator=(const Cask&) = delete;

    // 打开一个 Cask。registry 非空时通过命名 keydir 跟同目录的其它 Cask
    // 共享 keydir（典型生产形态：每个 NIF 实例一个全局 registry）。
    // 线程安全: 是（每次调用产生独立的 Cask 对象）；registry 自身的并发
    // 由 KeyDirRegistry 内部锁保证。
    // 锁要求: 无。
    [[nodiscard]] static std::expected<std::unique_ptr<Cask>, CaskFault>
    open(std::string_view dirname, const CaskOptions& opts,
         keydir::KeyDirRegistry* registry = nullptr);

    // 离线升级：将 KV 模式目录升级为索引模式。
    // 前提条件：目录必须存在且当前为 KV 模式；目录必须处于离线状态（无活跃 writer）。
    // 流程：读取 bitcask.meta 验证 KV 模式 → 写入新 meta 标记为索引模式 →
    //       创建 SearchLayer → 扫描所有数据文件重建索引 → 返回只读索引模式 Cask。
    // 线程安全: 是（产生独立的 Cask 对象）。
    // 锁要求: 无（离线操作，不获取 write.lock 或 merge.lock）。
    [[nodiscard]] static std::expected<std::unique_ptr<Cask>, CaskFault>
    upgrade(std::string_view dirname, const search::SearchLayerConfig& search_config);

    // 线程安全: 否（修改对象状态、释放资源）；caller 保证关闭时刻没有
    // 其它线程仍在调用 get/put/remove/sync/iter。
    void close() noexcept;

    // 单 key 读：keydir.get → DataFile.read 一次 pread。kNotFound 用
    // {error, not_found} 表达，对应 NIF 的 atom not_found。
    // 线程安全: 是（读路径无锁；read_files_ cache 受 read_cache_mu_ 保护，
    // 底层 DataFile::read 用 pread 是 thread-safe 的）。
    // 锁要求: 无外部锁；内部按需取 read_cache_mu_ + keydir mutex。
    [[nodiscard]] std::expected<GetResult, CaskFault>
    get(std::span<const std::byte> key);

    // 写入。tstamp=0 表示用当前 wall-clock 秒。
    // 线程安全: 否（写路径要求「一个 Cask 同时只有一个写线程」——M5 通过
    // 「一个 Erlang 进程独占一个 Cask」实现，本类不提供互斥）。
    // 同一 Cask 与并发 merge_only 句柄安全（双方共享 keydir 的 shared_mutex
    // 保护）。
    // 锁要求: caller 串行化所有 put/remove/sync/close_write_file 调用。
    [[nodiscard]] std::expected<void, CaskFault>
    put(std::span<const std::byte> key,
        std::span<const std::byte> value,
        std::uint32_t tstamp = 0);

    // 软删除：写一条墓碑 record。空间在下一次 merge 时回收。
    // 线程安全: 否（同 put）。锁要求: caller 串行化所有写操作。
    [[nodiscard]] std::expected<void, CaskFault>
    remove(std::span<const std::byte> key, std::uint32_t tstamp = 0);

    // 写入结构化文档（text + 选填 meta）。用于索引模式。
    // 线程安全: 否（同 put）。
    [[nodiscard]] std::expected<void, CaskFault>
    put_doc(std::span<const std::byte> key, const DocInput& doc,
            std::uint32_t tstamp = 0);

    // BM25 文本搜索（词袋模式）。
    // 线程安全: 否（search_ 非线程安全）。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_text(std::string_view query, std::size_t k = 10);

    // BM25 文本搜索（短语模式）。
    // 线程安全: 否（search_ 非线程安全）。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_phrase(std::string_view query, std::size_t k = 10);

    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    bool_search(std::string_view query, std::size_t k = 10);

    // BM25 多字段搜索（S8.6）：支持 `field:term^boost` 语法，跨字段加权合并。
    // 无字段限定的词等价于默认字段词袋搜索。线程安全: 否。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_fields(std::string_view query, std::size_t k = 10);

    // BM25 近邻搜索（S8.7）：term 按序出现且相邻间隙 ≤ slop。slop=0 即短语。
    // 线程安全: 否。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_near(std::string_view query, std::uint32_t slop, std::size_t k = 10);

    // S8.3：BM25 模糊搜索（Levenshtein 编辑距离匹配）。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_fuzzy(std::string_view query, std::size_t k, std::uint32_t max_edit_distance);

    // S8.4：BM25 通配符搜索（* / ? 模式匹配）。
    [[nodiscard]] std::expected<TextSearchResult, CaskFault>
    search_wildcard(std::string_view pattern, std::size_t k);

    // S8.2：设置同义词词典（查询时自动展开同义词）。
    void set_synonym_map(std::unique_ptr<text::SynonymMap> map);

    // 访问内部 SearchLayer（用于 NIF 层）。
    [[nodiscard]] bool has_search() const { return search_ != nullptr; }
    [[nodiscard]] search::SearchLayer* search() { return search_.get(); }

    void flush_index() {
        if (index_pool_) index_pool_->flush();
    }

    // fsync active data file。o_sync 模式下退化为 no-op。
    // 线程安全: 否（操作 active_data_，与 put/remove 互斥）；caller 串行化。
    [[nodiscard]] std::expected<void, CaskFault> sync();

    // 强制关 active write file：finalize hint trailer、丢掉 active data/hint
    // 句柄、释放 bitcask.write.lock。Cask 仍可用——下次 put/delete 自动
    // 重新拿锁、新建 active file（对应 legacy bitcask:close_write_file 语义）。
    // 只读 / merge_only 句柄返回 kReadOnly。
    // 线程安全: 否（操作 active_*）；caller 串行化所有写操作。
    [[nodiscard]] std::expected<void, CaskFault> close_write_file();

    // 线程安全: 是（只读 keydir + opts 快照）；不需任何锁。
    [[nodiscard]] StatusInfo status();
    // O(1) 估算「keydir 是否为空」。写过 key 后即使删光也不会再回 true。
    // 线程安全: 是（仅读 keydir info）；不需任何锁。
    [[nodiscard]] bool is_empty_estimate();
    // keydir 是否被某个 fold/iterator pin 住（影响 pending 表合并时机）。
    // 线程安全: 是（仅读 keydir info）；不需任何锁。
    [[nodiscard]] bool is_frozen();

    // 包装 decide()：返回是否需要 merge + 候选文件列表。
    struct NeedsMerge {
        bool needs;
        std::vector<std::string> files;
        std::vector<std::string> expired_files;
    };
    // 线程安全: 是（读 keydir info 拿快照 + 纯函数策略）；不需外部锁。
    [[nodiscard]] NeedsMerge needs_merge(std::uint32_t now_sec = 0);

    // 在指定文件上跑 merge。files 为空时先调 needs_merge。caller 自己负责
    // 外部调度 / 锁——这个方法只是把 run_merge 包了一层。
    // 线程安全: 是（前提是只在 merge_only 模式下被调用，调用方持
    // bitcask.merge.lock；read_write Cask 上的并发 merge() 与 put/remove 不
    // 兼容——上层应避免）。
    // 锁要求: caller 须保证同一 dirname 上同时仅一次 merge 在跑。
    [[nodiscard]] std::expected<merge::MergeStats, CaskFault>
    merge(std::vector<std::string> files = {}, std::uint32_t now_sec = 0);

    // 线程安全: 是；不需任何锁。返回的 CaskIter 自身非线程安全。
    [[nodiscard]] std::unique_ptr<CaskIter> make_iter() {
        return std::make_unique<CaskIter>(this);
    }

    [[nodiscard]] std::string_view dirname() const noexcept { return dirname_; }
    [[nodiscard]] keydir::KeyDir&  keydir()  noexcept { return *keydir_; }
    [[nodiscard]] const CaskOptions& options() const noexcept { return opts_; }

private:
    friend class CaskIter;

    std::string dirname_;
    CaskOptions opts_;

    // 字段名 ↔ id 注册表（#1）：put_doc 把多字段名 intern 成 id 写进 DocValue。
    // open/upgrade 时加载 <dir>/field.schema。
    FieldSchema field_schema_;

    // keydir（多个 Cask 可能通过 registry 共享同一个）
    std::shared_ptr<keydir::KeyDir> keydir_;
    keydir::KeyDirRegistry* registry_ = nullptr;
    std::string keydir_name_;

    // 当前 active write file。只读 / merge_only 时为 nullptr。
    std::unique_ptr<fileops::DataFile> active_data_;
    std::unique_ptr<fileops::HintFile> active_hint_;
    std::uint32_t active_file_id_ = 0;

    // 按 file_id 缓存的 DataFile 读句柄。read 路径懒打开。
    // 多读者并发，read_cache_mu_ 保护 unordered_map 本身；DataFile 内部
    // 的 pread 是 thread-safe 的。
    std::mutex read_cache_mu_;
    std::unordered_map<std::uint32_t,
                        std::unique_ptr<fileops::DataFile>> read_files_;

    // 目录锁。read_write 模式下是 bitcask.write.lock（live writer 持有），
    // merge_only 模式下是 bitcask.merge.lock（merger 跟 writer 并行）。
    std::optional<lock::FileLock> write_lock_;

    // merge_only 模式下，open 时从 write.lock 里读出来的「live writer 的
    // active file id」。needs_merge 用它把 live writer 正在写的文件从候选
    // 里排除——不能并别人正在写的文件。
    // 0 表示「没探测到 live writer」（保守：不额外排除）。
    std::uint32_t merger_writer_active_id_ = 0;

    // bitcask.meta 配置（open 时读写）
    meta::MetaConfig meta_config_{};

    // SearchLayer 实例（enable_search 时创建）
    std::unique_ptr<search::SearchLayer> search_;

    // T2.4: Index Pool（搜索模式开启时创建，用于 T3 异步索引）
    std::unique_ptr<IndexPool> index_pool_;

    // T3: 提交索引任务到 IndexPool，带背压控制。
    // 队列超过 80% 水位（8192/10240）时自旋等待。
    void submit_index_task(IndexTask task);

public:
    // 访问 IndexPool（用于 T3 阶段启动 worker）
    [[nodiscard]] IndexPool* index_pool() { return index_pool_.get(); }

    // 内部辅助
    [[nodiscard]] std::expected<void, CaskFault> load_keydir_from_disk(search::SearchLayer* search_layer);
    [[nodiscard]] std::expected<void, CaskFault> ensure_active_writer();
    [[nodiscard]] std::expected<void, CaskFault> roll_active_if_needed(std::size_t about_to_write);
    // 无条件 finalize 当前 active writer 并开新一轮（新 file_id）。
    // put() 在 keydir.biggest_file_id 被并发 merger 顶过去时调用——
    // 必须放弃当前文件，让出 file_id 单调递增的不变量。
    [[nodiscard]] std::expected<void, CaskFault> roll_active();
    [[nodiscard]] fileops::DataFile* read_file(std::uint32_t file_id);
};

}  // namespace bitcask
