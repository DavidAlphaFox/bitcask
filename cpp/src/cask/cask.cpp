#include "bitcask/cask.hpp"

#include <signal.h>     // ::kill for stale-lock detection
#include <unistd.h>     // ::getpid, ::unlink

#include <chrono>
#include <cstring>
#include <filesystem>
#include <thread>

#include "bitcask/format.hpp"
#include "bitcask/merger.hpp"
#include "bitcask/scanner.hpp"

namespace bitcask {

namespace {
namespace fs = std::filesystem;

CaskFault io_fault(int errnum, std::string detail = {}) {
    return CaskFault{CaskError::kIo, errnum, std::move(detail)};
}
CaskFault err(CaskError k, std::string detail = {}) {
    return CaskFault{k, 0, std::move(detail)};
}

std::uint32_t now_sec_default() {
    return static_cast<std::uint32_t>(
        std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::system_clock::now().time_since_epoch()).count());
}

std::span<const std::byte> str_to_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

std::string_view bytes_to_view(std::span<const std::byte> b) {
    return {reinterpret_cast<const char*>(b.data()), b.size()};
}

// 探测 OS 进程 pid 是否还活着。对应 legacy bitcask_lockops:os_pid_exists/1
// 用 `kill -0 <pid>` 的做法。kill(pid, 0)：
//   返回 0   — 信号能投递，进程在
//   -1 + ESRCH — 进程已死
//   -1 + EPERM — 进程在但我们无权 signal（保守地视为「活着」，
//                避免误删别人的 lock）
[[nodiscard]] bool process_alive(int pid) noexcept {
    if (pid <= 0) return false;
    if (::kill(pid, 0) == 0) return true;
    return errno != ESRCH;
}

// 锁文件内容格式（legacy 和我们都遵守）：
//   "<pid> <active_data_file_path>\n"
//   或者只有 "<pid>\n"（active 文件还没建好的时候）
// 这个函数从路径 basename 里抠出 tstamp/file_id，给 merger 在 needs_merge
// 时排除「writer 正在写的文件」用。返回 0 表示没路径或解不出来。
[[nodiscard]] std::uint32_t
parse_active_file_id_from_lock(std::span<const std::byte> bytes) noexcept {
    // Skip leading PID digits.
    std::size_t i = 0;
    while (i < bytes.size() && static_cast<char>(bytes[i]) >= '0' &&
                                static_cast<char>(bytes[i]) <= '9') {
        ++i;
    }
    if (i == bytes.size() || static_cast<char>(bytes[i]) != ' ') return 0;
    ++i;  // skip the space

    // Take the rest up to newline as the path.
    std::size_t end = i;
    while (end < bytes.size() && static_cast<char>(bytes[end]) != '\n') ++end;
    std::string path(reinterpret_cast<const char*>(bytes.data() + i), end - i);
    if (path.empty()) return 0;

    auto t = fileops::parse_data_tstamp(path);
    if (!t) return 0;
    return static_cast<std::uint32_t>(*t);
}

// Parse the leading positive integer from `bytes` (the lock-file payload
// is "<pid> <activefile>\n" — we only care about the pid).
[[nodiscard]] int parse_leading_pid(std::span<const std::byte> bytes) noexcept {
    int pid = 0;
    bool any_digit = false;
    for (auto byte : bytes) {
        char c = static_cast<char>(byte);
        if (c >= '0' && c <= '9') {
            pid = pid * 10 + (c - '0');
            any_digit = true;
            if (pid > (1 << 30)) return -1;  // overflow guard
        } else {
            break;
        }
    }
    return any_digit ? pid : -1;
}

// 如果锁文件里记录的 pid 已死，尝试删掉它，让 caller 重试 O_EXCL acquire。
// 对应 legacy bitcask_lockops:delete_stale_lock。
//
// 竞态窗口：从我们读 pid 到我们 unlink 之间，另一个 writer 可能写了新 lock；
// 我们会误删他的。legacy 也有同样的 race，实际暴露面极小——只发生在
// crash recovery 路径上，正常运行不会碰到。
[[nodiscard]] bool try_remove_stale_lock(const std::string& path) noexcept {
    auto rl = lock::FileLock::acquire(path, /*write*/ false);
    if (!rl) return false;  // file vanished or unreadable; the retry will surface the right error

    auto data = rl->read_data();
    bool dead = false;
    if (data) {
        const int pid = parse_leading_pid(
            std::span<const std::byte>(data->data(), data->size()));
        // pid == -1 means "no parseable PID" (e.g. legacy hadn't written
        // it yet, or the writer crashed mid-write). Treat as stale.
        if (pid == -1 || !process_alive(pid)) {
            dead = true;
        }
    } else {
        dead = true;  // can't read content; treat as stale
    }
    rl->release_quiet();  // closes fd; read locks don't unlink
    if (!dead) return false;
    return ::unlink(path.c_str()) == 0;
}

// 拿 bitcask.write.lock，自带 stale-lock 回收。先只写一行 pid；active
// data file 路径要等 ensure_active_writer 创建文件后才能补上。
// Cask::open 跟 close_write_file → 下一次 put 重新拿锁时都走这条路径。
[[nodiscard]] std::expected<lock::FileLock, CaskFault>
acquire_writer_lock(const std::string& dirname) {
    const auto lock_path = (fs::path(dirname) / "bitcask.write.lock").string();
    auto fl = lock::FileLock::acquire(lock_path, /*write*/ true);
    if (!fl && fl.error().errnum == EEXIST) {
        if (try_remove_stale_lock(lock_path)) {
            fl = lock::FileLock::acquire(lock_path, /*write*/ true);
        }
    }
    if (!fl) {
        if (fl.error().errnum == EEXIST) {
            return std::unexpected(err(CaskError::kWriteLocked, lock_path));
        }
        return std::unexpected(io_fault(fl.error().errnum, lock_path));
    }
    const std::string pid_line = std::to_string(::getpid()) + "\n";
    auto pid_bytes = std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(pid_line.data()),
        pid_line.size());
    (void)fl->write_data(pid_bytes);
    return std::move(*fl);
}

}  // namespace

// =============================================================================
// CaskIter：fold 迭代器实现
//
// 把 keydir::IterHandle 包一层，加上「按 file_id 拿 DataFile 句柄、
// 按 (offset, total_sz) pread 出 value」的能力。see_tombstones=true 时
// 墓碑也作为带 is_tombstone 标志的 Entry 上交。
// =============================================================================

CaskIter::~CaskIter() noexcept { release(); }

std::expected<keydir::StartIterResult, CaskFault>
CaskIter::start(int maxage, int maxputs, std::uint32_t now_sec,
                bool see_tombstones) {
    if (iter_ && iter_->is_iterating()) {
        return std::unexpected(err(CaskError::kIo, "iter already started"));
    }
    iter_ = parent_->keydir_->make_iter();
    auto r = iter_->start(now_sec, maxage, maxputs);
    see_tombstones_ = see_tombstones;
    return r;  // kOk or kOutOfDate (kAlreadyIterating handled above)
}

std::expected<std::optional<CaskIter::Entry>, CaskFault> CaskIter::next() {
    if (!iter_ || !iter_->is_iterating()) return std::optional<Entry>{};

    const auto expiry = parent_->opts_.expiry_secs;
    const auto now = (expiry > 0) ? now_sec_default() : 0;

    // 跳过过期 entry；墓碑的处理由 see_tombstones_ 决定：
    //   false（默认）— 墓碑直接跳过（legacy fold/3 行为）
    //   true         — 墓碑也作为带 is_tombstone=true 的 Entry 上交。
    //                  sibling 墓碑没有真实的磁盘 record，我们合成一条
    //                  v0 marker 当 value 上交，避免给出空 value 让 caller
    //                  困惑。
    while (true) {
        auto proxy = iter_->next(/*include_tombstones=*/ see_tombstones_);
        if (!proxy) return std::optional<Entry>{};

        if (expiry > 0 && proxy->tstamp + expiry <= now) {
            continue;  // expired; skip
        }

        // sibling 墓碑只活在 keydir 里（file_id 是 sentinel，磁盘上没
        // 对应 record）。跳过文件读，合成一条空 value 墓碑给 caller。
        if (proxy->is_tombstone) {
            Entry e;
            e.key.assign(reinterpret_cast<const std::byte*>(proxy->key.data()),
                          reinterpret_cast<const std::byte*>(proxy->key.data()) +
                          proxy->key.size());
            e.value.clear();
            e.value.shrink_to_fit();
            e.tstamp       = proxy->tstamp;
            e.file_id      = proxy->file_id;
            e.offset       = proxy->offset;
            e.total_sz     = proxy->total_sz;
            e.is_tombstone = true;
            e.ord          = proxy->ord;
            return std::optional<Entry>{std::move(e)};
        }

        auto* df = parent_->read_file(proxy->file_id);
        if (!df) {
            return std::unexpected(err(CaskError::kIo,
                "open read file_id=" + std::to_string(proxy->file_id)));
        }
        auto rec = df->read(proxy->offset, proxy->total_sz);
        if (!rec) {
            switch (rec.error().kind) {
                case fileops::DataFileError::kBadCrc:
                    return std::unexpected(err(CaskError::kBadCrc));
                case fileops::DataFileError::kIo:
                    return std::unexpected(io_fault(rec.error().errnum));
                default:
                    return std::unexpected(err(CaskError::kIo, "read"));
            }
        }
        // 即使 keydir 没把它标成墓碑，磁盘 record 自己也可能是墓碑——
        // keydir 指向的就是一条带墓碑类型的 value。这种「磁盘墓碑」要
        // 跟「sibling 墓碑」区分对待（前者有真实磁盘字节，后者纯内存）。
        const bool value_is_tomb = rec->type == format::RecordType::kTombstone;
        if (value_is_tomb && !see_tombstones_) continue;

        Entry e;
        e.key          = std::move(rec->key);
        // 磁盘上 kDoc value 是 DocValue 编码（text 段 = 原始 value），与
        // Cask::get 一致地解码取 text 段，避免把 doc 头/长度前缀漏给 caller。
        // 墓碑 record 不是 DocValue 编码，按原始字节上交（通常为空/marker）。
        if (value_is_tomb) {
            e.value = std::move(rec->value);
        } else {
            auto dv = codec::decode_doc_value(std::span<const std::byte>(rec->value));
            if (!dv) return std::unexpected(err(CaskError::kIo, "corrupt DocValue"));
            e.value.assign(dv->text.begin(), dv->text.end());
        }
        e.tstamp       = rec->tstamp;
        e.file_id      = proxy->file_id;
        e.offset       = proxy->offset;
        e.total_sz     = proxy->total_sz;
        e.is_tombstone = value_is_tomb;
        e.ord          = rec->ord;
        return std::optional<Entry>{std::move(e)};
    }
}

void CaskIter::release() noexcept {
    if (iter_) {
        iter_->release();
        iter_.reset();
    }
}

// =============================================================================
// Cask 主体实现
//
// open   ：拿锁 / 注册 keydir / 扫盘重建索引 / 准备 active writer
// upgrade：离线 KV→索引升级（不拿锁，只读扫盘重建索引）
// close  ：finalize active writer + hint trailer，释放锁，registry release
// get    ：keydir 查 → DataFile pread → 校验 → 返回 value
// put    ：append 到 active data file → 写 hint → 更新 keydir
// remove ：append 一条墓碑 record → 更新 keydir 标记为墓碑
// merge  ：跑 run_merge → 合并完后从 read_files_ 缓存里淘汰旧句柄、
//          然后 unlink 老文件
// =============================================================================

Cask::~Cask() { close(); }

// 离线升级：将 KV 模式目录转为索引模式。
// 不获取任何锁——要求目录处于离线状态（无活跃 writer/merger）。
// 步骤：验证 meta 是 KV → 覆写 meta 为 kIndex → 创建 SearchLayer →
//       新建 KeyDir + load_keydir_from_disk(search_layer) → mark_ready
// 返回的 Cask 是只读的（无 active writer），调用方可以 close 后
// 再用 open(dirname, {enable_search=true, read_write=true}) 正常使用。
std::expected<std::unique_ptr<Cask>, CaskFault>
Cask::upgrade(std::string_view dirname,
              const search::SearchLayerConfig& search_config) {
    if (!fs::exists(dirname)) {
        return std::unexpected(err(CaskError::kIo, "directory does not exist"));
    }

    if (!meta::meta_exists(std::string(dirname))) {
        return std::unexpected(err(CaskError::kModeMismatch,
                                    "no bitcask.meta found — not a valid bitcask directory"));
    }
    auto mc = meta::read_meta(std::string(dirname));
    if (!mc) {
        return std::unexpected(err(CaskError::kIo, "read meta failed"));
    }
    if (mc->mode == meta::Mode::kIndex) {
        return std::unexpected(err(CaskError::kModeMismatch,
                                    "directory is already in index mode"));
    }

    meta::MetaConfig new_mc;
    new_mc.mode = meta::Mode::kIndex;
    auto wr = meta::write_meta(std::string(dirname), new_mc);
    if (!wr) {
        return std::unexpected(err(CaskError::kIo, "write meta failed"));
    }

    auto cask = std::make_unique<Cask>();
    cask->dirname_ = std::string(dirname);
    cask->meta_config_ = new_mc;

    cask->search_ = std::make_unique<search::SearchLayer>(search_config);

    cask->keydir_ = std::make_shared<keydir::KeyDir>();
    if (auto r = cask->load_keydir_from_disk(cask->search_.get()); !r) {
        return std::unexpected(r.error());
    }
    cask->keydir_->mark_ready();

    return cask;
}

// Cask 启动入口。流程：
//   1. ensure dir 存在
//   2. 拿锁：read_write 拿 bitcask.write.lock；merge_only 拿 bitcask.merge.lock；
//      只读模式不拿任何锁
//   3. 拿 keydir：通过 registry 共享 / 单独 new；首次创建的需要 load_keydir_from_disk
// 失败路径会回滚已分配的资源（unique_ptr 自带 RAII，锁也是 optional<FileLock> 自管）。
std::expected<std::unique_ptr<Cask>, CaskFault>
Cask::open(std::string_view dirname, const CaskOptions& opts,
            keydir::KeyDirRegistry* registry) {
    auto cask = std::make_unique<Cask>();
    cask->dirname_ = std::string(dirname);
    cask->opts_    = opts;

    // 目录不存在就建（mkdir -p 语义）。已存在不报错。
    std::error_code ec;
    fs::create_directories(cask->dirname_, ec);

    // 锁分配：
    //   - 普通 writer 拿 bitcask.write.lock；
    //   - merger 拿 bitcask.merge.lock（独立文件，跟 writer 不互斥，
    //     允许周期性 merge_worker 跟主 writer 并行）；
    //   - 只读 cask 不拿任何锁。
    // crash recovery 路径：两种锁都做 stale-lock 检查（看 pid 是否还活着）。
    // merger 额外读一下 write.lock，把 live writer 当前的 active file id 抠
    // 出来，下面 needs_merge 时排除掉——不能并别人正在写的文件。
    if (opts.read_write && !opts.merge_only) {
        auto fl = acquire_writer_lock(cask->dirname_);
        if (!fl) return std::unexpected(fl.error());
        cask->write_lock_ = std::move(*fl);
    } else if (opts.merge_only) {
        const auto lock_path =
            (fs::path(cask->dirname_) / "bitcask.merge.lock").string();
        auto fl = lock::FileLock::acquire(lock_path, /*write*/ true);
        if (!fl && fl.error().errnum == EEXIST) {
            if (try_remove_stale_lock(lock_path)) {
                fl = lock::FileLock::acquire(lock_path, /*write*/ true);
            }
        }
        if (!fl) {
            if (fl.error().errnum == EEXIST) {
                return std::unexpected(err(CaskError::kWriteLocked, lock_path));
            }
            return std::unexpected(io_fault(fl.error().errnum, lock_path));
        }
        const std::string pid_line = std::to_string(::getpid()) + "\n";
        auto pid_bytes = std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(pid_line.data()),
            pid_line.size());
        (void)fl->write_data(pid_bytes);
        cask->write_lock_ = std::move(*fl);

        // 拍 live writer 的 active file id 快照，给 needs_merge 用。
        // 竞态窗口：从我们读 write.lock 到 merger 真的选文件之间，writer
        // 可能 roll 过去了——这个 race 在 legacy 里也有（见
        // bitcask_lockops:read_activefile），后果最多是少并掉一个刚 roll 的
        // 文件，下一轮 merge 自然会处理。
        if (opts.merge_only) {
            const auto wlock_path =
                (fs::path(cask->dirname_) / "bitcask.write.lock").string();
            auto wl = lock::FileLock::acquire(wlock_path, /*write*/ false);
            if (wl) {
                if (auto data = wl->read_data()) {
                    cask->merger_writer_active_id_ =
                        parse_active_file_id_from_lock(
                            std::span<const std::byte>(data->data(), data->size()));
                }
                wl->release_quiet();
            }
            // If write.lock doesn't exist or can't be parsed, no active
            // writer is detected (id stays 0).
        }
    }

    // 检查/创建 bitcask.meta（必须在 SearchLayer 创建之前——决定是否需要索引模式）
    if (meta::meta_exists(cask->dirname_)) {
        auto mc = meta::read_meta(cask->dirname_);
        if (!mc) return std::unexpected(err(CaskError::kIo, "read meta failed"));
        if (opts.enable_search && mc->mode != meta::Mode::kIndex) {
            return std::unexpected(err(CaskError::kModeMismatch,
                "directory is KV mode, cannot open with search"));
        }
        if (!opts.enable_search && mc->mode == meta::Mode::kIndex) {
            return std::unexpected(err(CaskError::kModeMismatch,
                "directory is index mode, cannot open as KV"));
        }
        cask->meta_config_ = *mc;
    } else {
        meta::MetaConfig mc;
        mc.mode = opts.enable_search ? meta::Mode::kIndex : meta::Mode::kKV;
        auto wr = meta::write_meta(cask->dirname_, mc);
        if (!wr) return std::unexpected(err(CaskError::kIo, "write meta failed"));
        cask->meta_config_ = mc;
    }

    // 创建 SearchLayer + IndexPool（如果配置了 search_config）
    if (opts.search_config) {
        cask->search_ = std::make_unique<search::SearchLayer>(*opts.search_config);
        cask->index_pool_ = std::make_unique<IndexPool>(1, 10240);
        cask->index_pool_->start([&search = *cask->search_](const IndexTask& task) {
            if (task.op == IndexOp::Delete) {
                search.on_delete(task.key, task.ord);
            } else if (!task.fields.empty()) {
                search.on_write_fields(task.key, task.ord, task.fields,
                                       task.file_id, task.offset, task.total_sz, task.tstamp);
            } else {
                search.on_write(task.key, task.ord, task.text,
                                task.file_id, task.offset, task.total_sz, task.tstamp);
            }
            return true;
        });
    }

    // 拿 / 建 keydir。
    //
    // 走 registry：多个同目录的 Cask 共享同一个 keydir。
    //   - kCreated：我们是初始化者，扫盘建 keydir 后调 mark_ready
    //   - kReady：有其他 cask 已经初始化好了，直接拿来用
    //   - kNotReady：别人正在初始化，最多等 40 × 50 ms = 2 秒
    //
    // 不走 registry：每个 cask 独占一个 keydir（unit test 常见）。
    if (registry != nullptr) {
        cask->registry_    = registry;
        cask->keydir_name_ = std::string(dirname);
        auto a = registry->acquire(cask->keydir_name_);
        if (a.status == keydir::AcquireStatus::kNotReady) {
            for (int i = 0; i < 40; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                a = registry->acquire(cask->keydir_name_);
                if (a.status != keydir::AcquireStatus::kNotReady) break;
            }
            if (a.status == keydir::AcquireStatus::kNotReady) {
                return std::unexpected(err(CaskError::kIo,
                    "keydir not_ready after wait"));
            }
        }
        cask->keydir_ = a.keydir;
        if (a.status == keydir::AcquireStatus::kCreated) {
            if (auto r = cask->load_keydir_from_disk(cask->search_.get()); !r) return std::unexpected(r.error());
            cask->keydir_->mark_ready();
        }
    } else {
        cask->keydir_ = std::make_shared<keydir::KeyDir>();
        if (auto r = cask->load_keydir_from_disk(cask->search_.get()); !r) return std::unexpected(r.error());
        cask->keydir_->mark_ready();
    }
    return cask;
}

// 收尾顺序很关键：
//   1. finalize active hint（写 trailer + running CRC，否则 hint 文件
//      下次 open 时会被判失效，回退到全量 fold(data) 重建 keydir）；
//   2. 关 active data；
//   3. 清 read cache（关掉缓存的 fd，避免泄漏）；
//   4. registry release（refcount -1，归零时 keydir 真正销毁）；
//   5. 释放 write/merge lock。
// 失败全部静默——close 路径上的错误没有合理的恢复动作，硬抛会让 Erlang
// 进程意外崩溃。
void Cask::close() noexcept {
    if (active_hint_) {
        (void)active_hint_->finalize();
        active_hint_.reset();
    }
    if (active_data_) {
        active_data_.reset();
    }
    {
        std::scoped_lock lk(read_cache_mu_);
        read_files_.clear();
    }
    if (registry_ && !keydir_name_.empty()) {
        registry_->release(keydir_name_);
        registry_ = nullptr;
        keydir_name_.clear();
    }
    keydir_.reset();
    if (index_pool_) {
        index_pool_->stop();
        index_pool_.reset();
    }
    search_.reset();
    if (write_lock_) {
        write_lock_->release_quiet();
        write_lock_.reset();
    }
}

// T3: 提交索引任务到 IndexPool，带背压控制。
// 队列超过 80% 水位（8192/10240）时自旋等待，让 put 路径减速以避免内存溢出。
void Cask::submit_index_task(IndexTask task) {
    if (!index_pool_) return;
    index_pool_->submit(std::move(task));
}

// ---- open 时重建 keydir ----------------------------------------------------
// 优先 fold(hint_file)，hint 缺失或 trailer CRC 校验不过时回退到 fold(data_file)
// 重建。fold 顺序按 tstamp 升序——保证后写入的 entry 覆盖前面的。
// search_layer 为空时跳过 SearchLayer 的恢复。
std::expected<void, CaskFault> Cask::load_keydir_from_disk(search::SearchLayer* search_layer) {
    auto entries = fileops::scan_dir(dirname_);
    if (!entries) return std::unexpected(io_fault(entries.error().errnum, dirname_));

    // 按 tstamp 升序遍历每个 data file。fold 顺序是关键：后写入的 entry
    // 必须覆盖前面的，否则 keydir 重建出来会跟实际「最新值」不一致。
    for (const auto& e : *entries) {
        // 把 keydir 的 biggest_file_id 推到至少这个文件的 id——保证后续
        // 分配新 file_id 时不会跟磁盘上已有的文件冲突。
        keydir_->increment_file_id_at_least(static_cast<std::uint32_t>(e.tstamp));

        // 优先走 hint 文件加速路径（不读 value，省掉绝大部分 I/O）。
        // hint 缺失或 trailer CRC 不通过则 fallback 到 fold(data) 全量重建。
        // SearchLayer 恢复需要读 value（text 段），有 search_layer 时跳过 hint。
        bool used_hint = false;
        if (e.has_hint && !search_layer) {
            auto hf = fileops::HintFile::open(e.hint_path,
                                                fileops::HintFile::Mode::kRead);
            if (hf) {
                auto v = hf->validate_trailer();
                if (v && *v) {
                    auto fr = hf->fold([&](const auto& rec) {
                        if (rec.tombstone) {
                            // 墓碑 hint 必须执行——否则前一个 file 里的同 key
                            // 活 entry 会被错误保留。
                            keydir_->remove(bytes_to_view(rec.key), rec.tstamp);
                            return;
                        }
                        keydir_->put(bytes_to_view(rec.key),
                                     static_cast<std::uint32_t>(e.tstamp), rec.total_sz, rec.offset,
                                     rec.tstamp, /*now*/ 0,
                                     /*newest*/ false, 0, 0, /*ord*/ 0);
                    });
                    if (fr) used_hint = true;
                }
            }
        }
        if (used_hint) continue;

        // Fallback：fold 整个 data file。tolerate_crc_errors=true 让单条
        // 损坏的 record 跳过而不是中断整个文件加载——legacy 也是这语义。
        // out_last_valid_end 用于后续 torn-write 修复。
        auto df = fileops::DataFile::open(e.data_path,
                                           fileops::DataFile::Mode::kRead);
        if (!df) {
            return std::unexpected(io_fault(df.error().errnum, e.data_path));
        }
        std::uint64_t last_valid_end = 0;
        auto fr = df->fold(
            [&](const codec::DataRecordView& view, std::uint64_t offset,
                std::uint32_t total_size) {
                if (view.type == format::RecordType::kTombstone) {
                    keydir_->remove(bytes_to_view(view.key), view.tstamp);
                    if (search_layer) {
                        search_layer->recover_tomb(bytes_to_view(view.key), view.ord);
                    }
                    return;
                }
                keydir_->put(bytes_to_view(view.key), static_cast<std::uint32_t>(e.tstamp),
                             total_size, offset, view.tstamp, /*now*/ 0,
                             /*newest*/ false, 0, 0, view.ord);
                keydir_->advance_ord(view.ord);
                if (search_layer) {
                    auto dv = codec::decode_doc_value(std::span<const std::byte>(view.value));
                    if (dv && !dv->text.empty()) {
                        std::string_view text_sv(
                            reinterpret_cast<const char*>(dv->text.data()),
                            dv->text.size());
                        search_layer->recover_doc(bytes_to_view(view.key), view.ord,
                                                  text_sv, static_cast<std::uint32_t>(e.tstamp),
                                                  offset, total_size, view.tstamp);
                    }
                }
            }, /*tolerate_crc_errors*/ true,
            /*out_last_valid_end*/ &last_valid_end);
        if (!fr) {
            return std::unexpected(err(CaskError::kBadCrc, e.data_path));
        }
        const std::uint64_t actual_size = df->size();
        df->close();

        // Torn-write 恢复：fold 已经跳过了文件尾部的损坏字节（可能是
        // 前一次 writer 写到一半 crash 留下的），如果我们是正经的 writer
        // 就把这些字节 truncate 掉——既释放磁盘，也避免后续 fstats 计算
        // 把坏字节当成「合法死 record」算到 total_bytes 里。
        // merge_only 不能这么干：它没有 write.lock，万一别的 writer 还在
        // 同一个文件后面追写，这里 truncate 会切掉别人的数据。
        if (opts_.read_write && !opts_.merge_only &&
            last_valid_end < actual_size) {
            auto wdf = fileops::DataFile::open(
                e.data_path, fileops::DataFile::Mode::kAppend);
            if (wdf) {
                (void)wdf->truncate_to(last_valid_end);  // best-effort
            }
        }
    }
    return {};
}

// ---- active writer 管理 ----------------------------------------------------
// ensure_active_writer：第一次写入或 close_write_file 之后调用，
// 创建新的 data + hint 文件、把路径补到 write.lock 内容里。
// roll_active_if_needed：写之前判断是否会撑爆 max_file_size，是的话切下一个。
// roll_active：无条件切——给 put 在 keydir.biggest_file_id 被并发 merger
// 顶过去时使用。
std::expected<void, CaskFault> Cask::ensure_active_writer() {
    if (active_data_) return {};
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (opts_.merge_only) {
        // merger 从不打开自己的 active writer——merge::run_merge 自己用
        // keydir->increment_file_id() 分配输出文件。
        return std::unexpected(err(CaskError::kReadOnly,
                                     "merge_only mode: no active writer"));
    }

    // close_write_file 之前可能已经把 write.lock 释放了；这里如果发现
    // 锁不在就重新拿。stale-lock 回收逻辑跟 open 一样——上次崩溃的 writer
    // 留下的锁会被探测到并回收。
    if (!write_lock_) {
        auto fl = acquire_writer_lock(dirname_);
        if (!fl) return std::unexpected(fl.error());
        write_lock_ = std::move(*fl);
    }

    active_file_id_ = keydir_->increment_file_id();
    auto data_path = fileops::mk_data_filename(dirname_, active_file_id_);
    auto hint_path = fileops::mk_hint_filename(data_path);

    auto df = fileops::DataFile::open(data_path,
                                       fileops::DataFile::Mode::kCreate,
                                       opts_.o_sync);
    if (!df) return std::unexpected(io_fault(df.error().errnum, data_path));
    auto hf = fileops::HintFile::open(hint_path,
                                       fileops::HintFile::Mode::kCreate,
                                       opts_.o_sync);
    if (!hf) return std::unexpected(io_fault(hf.error().errnum, hint_path));
    active_data_ = std::make_unique<fileops::DataFile>(std::move(*df));
    active_hint_ = std::make_unique<fileops::HintFile>(std::move(*hf));

    // 把新 active file 路径记到 write.lock 里：merger（merge_only=true）
    // 通过读 write.lock 知道我们正在写哪个 file_id，从 needs_merge 候选里
    // 排除它。格式跟 legacy 一致："<pid> <active_data_path>\n"。
    if (write_lock_) {
        const std::string line = std::to_string(::getpid()) + " " +
                                  data_path + "\n";
        auto bytes = std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(line.data()), line.size());
        (void)write_lock_->write_data(bytes);  // best-effort：失败不阻断
    }
    return {};
}

// 写入前的预检：要么没 active writer（首次写入或 close_write_file 之后），
// 要么 active 写满了——两种情况都需要建一个新文件。
std::expected<void, CaskFault>
Cask::roll_active_if_needed(std::size_t about_to_write) {
    if (!active_data_) return ensure_active_writer();
    if (active_data_->size() + about_to_write <= opts_.max_file_size) return {};
    return roll_active();
}

// 无条件 roll：先把 hint trailer finalize（保证下次 open 能用 hint 加速），
// 然后丢掉 active data/hint 句柄，新建一个新 file_id 的 active writer。
// put 在 keydir.biggest_file_id 被并发 merger 顶过去时也走这条路径。
std::expected<void, CaskFault> Cask::roll_active() {
    if (active_hint_) {
        if (auto r = active_hint_->finalize(); !r) {
            return std::unexpected(io_fault(r.error().errnum,
                                             std::string(active_hint_->path())));
        }
    }
    active_data_.reset();
    active_hint_.reset();
    return ensure_active_writer();
}

std::expected<void, CaskFault> Cask::close_write_file() {
    if (!opts_.read_write) {
        return std::unexpected(err(CaskError::kReadOnly,
                                     "close_write_file: read-only cask"));
    }
    if (opts_.merge_only) {
        return std::unexpected(err(CaskError::kReadOnly,
                                     "close_write_file: merge_only handle"));
    }
    // 先 finalize hint trailer 再丢句柄——否则下次 open 这个目录时
    // hint 校验失败，会被迫 fold 整个 data 文件重建 keydir，
    // 大目录上代价非常高。
    if (active_hint_) {
        if (auto r = active_hint_->finalize(); !r) {
            return std::unexpected(io_fault(r.error().errnum,
                                             std::string(active_hint_->path())));
        }
    }
    active_data_.reset();
    active_hint_.reset();
    active_file_id_ = 0;
    if (write_lock_) {
        write_lock_->release_quiet();
        write_lock_.reset();
    }
    // 之后的 put/delete 进 ensure_active_writer 会发现 write_lock_ 是空，
    // 自动重新拿锁、创建新 active 文件——不需要在这里多设状态。
    return {};
}

// ---- 按 file_id 缓存的 read 句柄 -------------------------------------------
// get / fold 频繁通过 file_id 拿 DataFile 来 pread。每次都 open 太重，
// 这里维护一个 unordered_map 做 lazy open；read_cache_mu_ 保护 map 本身，
// DataFile::read 内部 thread-safe 所以多读者并发没问题。
// merge 完成后会从这个 cache 里淘汰被合掉的旧 file_id。
// 按 file_id 拿一个 DataFile 读句柄。优先：
//   1. 缓存 hit
//   2. 当前 active writer 自身（避免重复 open）
//   3. 新 open 一个只读句柄并加入缓存
// 失败返回 nullptr——caller 用 errno 包装。
fileops::DataFile* Cask::read_file(std::uint32_t file_id) {
    std::scoped_lock lk(read_cache_mu_);
    auto it = read_files_.find(file_id);
    if (it != read_files_.end()) return it->second.get();

    // active writer 也能给自己当 reader 用——pread 不影响 append 写入位置。
    if (active_data_ && file_id == active_file_id_) {
        return active_data_.get();
    }

    auto path = fileops::mk_data_filename(dirname_, file_id);
    auto df = fileops::DataFile::open(path, fileops::DataFile::Mode::kRead);
    if (!df) return nullptr;
    auto* raw = df.value().path().data();  // touch to suppress unused
    (void)raw;
    auto up = std::make_unique<fileops::DataFile>(std::move(*df));
    auto* p = up.get();
    read_files_.emplace(file_id, std::move(up));
    return p;
}

// ---- get / put / delete ----------------------------------------------------
// 写路径有个微妙之处：put 之前要判断 keydir.biggest_file_id() 是不是已经
// 超过自己的 active_file_id_——如果超了，说明并发 merger 抢先把 file_id
// 推进了；这时必须 roll_active() 切到一个比 biggest 更大的新 file_id，
// 不然 keydir.put 时新 entry 会被认为「比当前 entry 旧」而拒绝。

// 单 key 读：keydir 查 → DataFile 读 → 校验 → 返回 value。
// 三层过滤：
//   1. keydir 不存在 → kNotFound
//   2. 过期（tstamp + expiry_secs <= now）→ kNotFound
//      （不在这里主动删——这是写操作，留给 merge 异步 GC）
//   3. 磁盘 record 是墓碑 value → kNotFound
//      （keydir 里的墓碑已经在第 1 步被过滤；这层兜住「磁盘墓碑但 keydir
//       还没合并掉」的窗口）
std::expected<GetResult, CaskFault>
Cask::get(std::span<const std::byte> key) {
    auto entry = keydir_->get(bytes_to_view(key));
    if (!entry) return std::unexpected(err(CaskError::kNotFound));

    if (opts_.expiry_secs > 0) {
        const auto now = now_sec_default();
        if (entry->tstamp + opts_.expiry_secs <= now) {
            return std::unexpected(err(CaskError::kNotFound));
        }
    }

    auto* df = read_file(entry->file_id);
    if (!df) return std::unexpected(err(CaskError::kIo,
        "open file_id=" + std::to_string(entry->file_id)));

    auto rec = df->read(entry->offset, entry->total_sz);
    if (!rec) {
        switch (rec.error().kind) {
            case fileops::DataFileError::kBadCrc:
                return std::unexpected(err(CaskError::kBadCrc));
            case fileops::DataFileError::kIo:
                return std::unexpected(io_fault(rec.error().errnum));
            default:
                return std::unexpected(err(CaskError::kIo));
        }
    }
    // 磁盘墓碑：record type 为 kTombstone。语义上仍然是「最新写入」
    // （记录上的 tstamp 比之前的活 entry 大），但表示删除。在 cask
    // 层透明过滤掉。
    if (rec->type == format::RecordType::kTombstone) {
        return std::unexpected(err(CaskError::kNotFound));
    }
    // 解码 DocValue，取 text 段（即原始 value）
    auto dv = codec::decode_doc_value(std::span<const std::byte>(rec->value));
    if (!dv) {
        return std::unexpected(err(CaskError::kIo, "corrupt DocValue"));
    }
    return GetResult{
        std::vector<std::byte>(dv->text.begin(), dv->text.end()),
        std::vector<std::byte>(dv->meta.begin(), dv->meta.end()),
        rec->tstamp,
        rec->ord
    };
}

// put 流程：
//   1. 校验权限 + key/value 大小
//   2. 必要时 roll active 文件（写满 / 没建过 / 被 merger 抢 file_id）
//   3. 写 data + hint
//   4. 更新 keydir
//   5. keydir 拒绝（merge race）→ 再 roll 一次重试一次；二次失败上报
    std::expected<void, CaskFault>
Cask::put(std::span<const std::byte> key,
          std::span<const std::byte> value,
          std::uint32_t tstamp) {
    if (!opts_.read_write || opts_.merge_only) {
        return std::unexpected(err(CaskError::kReadOnly));
    }
    if (key.size()   > format::kMaxKeySize)   return std::unexpected(err(CaskError::kKeyTooLarge));
    if (value.size() > format::kMaxValueSize) return std::unexpected(err(CaskError::kValueTooLarge));

    if (tstamp == 0) tstamp = now_sec_default();
    const std::size_t about = format::kHeaderSize + key.size() + value.size();
    if (auto r = roll_active_if_needed(about); !r) return std::unexpected(r.error());

    // M5.1 task 2 关键 race：并发 merger 可能已经把 keydir.biggest_file_id
    // 推过了我们的 active_file_id_。如果直接写，keydir 的 merge-race 检测
    // (file_id < biggest_file_id_) 会返回 kAlreadyExists，put 就被静默丢了。
    // 提前主动 roll 一次保证 active_file_id_ >= biggest，避免 silent drop。
    if (active_data_ && active_file_id_ < keydir_->biggest_file_id()) {
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
    }

    // 分配 ord + 编码 DocValue（text 段 = 原始 value）
    const std::uint64_t ord = keydir_->alloc_ord();
    std::vector<std::byte> encoded;
    encoded.reserve(value.size() + 16);
    codec::DocValueParts parts;
    parts.text = value;
    codec::encode_doc_value(encoded, parts);

    auto w = active_data_->write(format::RecordType::kDoc, tstamp,
                                  ord, key,
                                  std::span<const std::byte>(encoded));
    if (!w) return std::unexpected(io_fault(w.error().errnum,
                                             std::string(active_data_->path())));
    auto h = active_hint_->write(tstamp, w->total_size, w->offset,
                                  /*tomb*/ false, key);
    if (!h) return std::unexpected(io_fault(h.error().errnum,
                                             std::string(active_hint_->path())));

auto pr = keydir_->put(bytes_to_view(key), active_file_id_,
                            w->total_size, w->offset, tstamp,
                            /*now*/ 0, /*newest*/ true, 0, 0, ord);
    if (pr == keydir::PutResult::kAlreadyExists) {
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
        const std::uint64_t ord2 = keydir_->alloc_ord();
        std::vector<std::byte> enc2;
        enc2.reserve(value.size() + 16);
        codec::DocValueParts parts2;
        parts2.text = value;
        codec::encode_doc_value(enc2, parts2);
        auto w2 = active_data_->write(format::RecordType::kDoc, tstamp,
                                        ord2, key,
                                        std::span<const std::byte>(enc2));
        if (!w2) return std::unexpected(io_fault(w2.error().errnum));
        auto h2 = active_hint_->write(tstamp, w2->total_size, w2->offset,
                                        /*tomb*/ false, key);
        if (!h2) return std::unexpected(io_fault(h2.error().errnum));
        auto pr2 = keydir_->put(bytes_to_view(key), active_file_id_,
                                  w2->total_size, w2->offset, tstamp,
                                  0, true, 0, 0, ord2);
        if (pr2 == keydir::PutResult::kAlreadyExists) {
            return std::unexpected(err(CaskError::kAlreadyExists));
        }
        submit_index_task(IndexTask{
            IndexOp::Add,
            std::string(bytes_to_view(key)),
            ord2,
            std::string(reinterpret_cast<const char*>(value.data()), value.size()),
            active_file_id_, w2->offset, w2->total_size, tstamp, 0
        });
    } else {
        submit_index_task(IndexTask{
            IndexOp::Add,
            std::string(bytes_to_view(key)),
            ord,
            std::string(reinterpret_cast<const char*>(value.data()), value.size()),
            active_file_id_, w->offset, w->total_size, tstamp, 0
        });
    }
    return {};
}

// 软删除 = 写一条墓碑 record。
//
// 墓碑 encoding (v2 backward compat):
//   v0: empty value (RecordType::kTombstone carries the meaning)
//   v2: 4-byte big-endian shadow file_id (tells merger "I exist because of
//       an entry in file_id N; if that entry is gone, I'm meaningless").
//       If key not in keydir or file_id==0, fall back to v0.
std::expected<void, CaskFault>
Cask::remove(std::span<const std::byte> key, std::uint32_t tstamp) {
    if (!opts_.read_write) return std::unexpected(err(CaskError::kReadOnly));
    if (tstamp == 0) tstamp = now_sec_default();

    std::span<const std::byte> tomb_value;
    std::uint8_t shadow_be[4] = {0};
    if (opts_.tombstone_version == 2) {
        if (auto entry = keydir_->get(bytes_to_view(key))) {
            if (entry->file_id != 0) {
                shadow_be[0] = static_cast<std::uint8_t>((entry->file_id >> 24) & 0xFF);
                shadow_be[1] = static_cast<std::uint8_t>((entry->file_id >> 16) & 0xFF);
                shadow_be[2] = static_cast<std::uint8_t>((entry->file_id >>  8) & 0xFF);
                shadow_be[3] = static_cast<std::uint8_t>( entry->file_id        & 0xFF);
                tomb_value = std::span<const std::byte>(
                    reinterpret_cast<const std::byte*>(shadow_be),
                    sizeof(shadow_be));
            }
        }
    }
    if (tomb_value.empty()) {
        tomb_value = std::span<const std::byte>{};
    }

    const std::size_t about =
        format::kHeaderSize + key.size() + tomb_value.size();
    if (auto r = roll_active_if_needed(about); !r) return std::unexpected(r.error());

    const std::uint64_t ord = keydir_->alloc_ord();
    auto w = active_data_->write(format::RecordType::kTombstone, tstamp,
                                  ord, key, tomb_value);
    if (!w) return std::unexpected(io_fault(w.error().errnum));
    // hint 文件也要追一条墓碑——下次 open fold(hint) 重建时才能正确删 key。
    auto h = active_hint_->write(tstamp, w->total_size, w->offset,
                                  /*tomb*/ true, key);
    if (!h) return std::unexpected(io_fault(h.error().errnum));
    keydir_->remove(bytes_to_view(key), tstamp);
    if (index_pool_) {
        submit_index_task(IndexTask{
            IndexOp::Delete,
            std::string(bytes_to_view(key)),
            ord, {}, 0, 0, 0, tstamp, 0
        });
    } else if (search_) {
        search_->on_delete(bytes_to_view(key), ord);
    }
    return {};
}

// put_doc：写入结构化文档（text + 选填 meta）。用于索引模式。
// 逻辑跟 put 类似，但 DocValue 编码包含 text 和 meta 两段。
std::expected<void, CaskFault>
Cask::put_doc(std::span<const std::byte> key, const DocInput& doc,
              std::uint32_t tstamp) {
    if (!opts_.read_write || opts_.merge_only) {
        return std::unexpected(err(CaskError::kReadOnly));
    }
    if (key.size() > format::kMaxKeySize) {
        return std::unexpected(err(CaskError::kKeyTooLarge));
    }
    if (doc.text.size() > format::kMaxValueSize) {
        return std::unexpected(err(CaskError::kValueTooLarge));
    }

    if (tstamp == 0) tstamp = now_sec_default();
    const std::size_t about =
        format::kHeaderSize + key.size() + doc.text.size() + doc.meta.size();
    if (auto r = roll_active_if_needed(about); !r) {
        return std::unexpected(r.error());
    }

    // S8.6：把 DocInput 的多字段填进 DocValueParts.fields（name→span）。
    auto fill_parts = [&doc](codec::DocValueParts& p) {
        for (auto& [name, val] : doc.fields) {
            p.fields.push_back({
                std::span<const std::byte>(reinterpret_cast<const std::byte*>(name.data()),
                                           name.size()),
                val});
        }
    };
    // S8.6：把多字段拷成 IndexTask.fields（name→text string，异步路径需独立存储）。
    auto task_fields = [&doc]() {
        std::vector<std::pair<std::string, std::string>> fs;
        fs.reserve(doc.fields.size());
        for (auto& [name, val] : doc.fields) {
            fs.push_back({name,
                std::string(reinterpret_cast<const char*>(val.data()), val.size())});
        }
        return fs;
    };

    if (active_data_ && active_file_id_ < keydir_->biggest_file_id()) {
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
    }

    const std::uint64_t ord = keydir_->alloc_ord();
    std::vector<std::byte> encoded;
    encoded.reserve(doc.text.size() + doc.meta.size() + 16);
    codec::DocValueParts parts;
    parts.text = doc.text;
    if (!doc.meta.empty()) {
        parts.meta = doc.meta;
    }
    fill_parts(parts);
    codec::encode_doc_value(encoded, parts);

    auto w = active_data_->write(format::RecordType::kDoc, tstamp,
                                  ord, key,
                                  std::span<const std::byte>(encoded));
    if (!w) return std::unexpected(io_fault(w.error().errnum,
                                             std::string(active_data_->path())));
    auto h = active_hint_->write(tstamp, w->total_size, w->offset,
                                  /*tomb*/ false, key);
    if (!h) return std::unexpected(io_fault(h.error().errnum,
                                             std::string(active_hint_->path())));

    auto pr = keydir_->put(bytes_to_view(key), active_file_id_,
                            w->total_size, w->offset, tstamp,
                            /*now*/ 0, /*newest*/ true, 0, 0, ord);
    if (pr == keydir::PutResult::kAlreadyExists) {
        if (auto r = roll_active(); !r) return std::unexpected(r.error());
        const std::uint64_t ord2 = keydir_->alloc_ord();
        std::vector<std::byte> enc2;
        enc2.reserve(doc.text.size() + doc.meta.size() + 16);
        codec::DocValueParts parts2;
        parts2.text = doc.text;
        if (!doc.meta.empty()) {
            parts2.meta = doc.meta;
        }
        fill_parts(parts2);
        codec::encode_doc_value(enc2, parts2);
        auto w2 = active_data_->write(format::RecordType::kDoc, tstamp,
                                        ord2, key,
                                        std::span<const std::byte>(enc2));
        if (!w2) return std::unexpected(io_fault(w2.error().errnum));
        auto h2 = active_hint_->write(tstamp, w2->total_size, w2->offset,
                                        /*tomb*/ false, key);
        if (!h2) return std::unexpected(io_fault(h2.error().errnum));
        auto pr2 = keydir_->put(bytes_to_view(key), active_file_id_,
                                  w2->total_size, w2->offset, tstamp,
                                  0, true, 0, 0, ord2);
        if (pr2 == keydir::PutResult::kAlreadyExists) {
            return std::unexpected(err(CaskError::kAlreadyExists));
        }
        submit_index_task(IndexTask{
            IndexOp::Add,
            std::string(bytes_to_view(key)),
            ord2,
            std::string(reinterpret_cast<const char*>(doc.text.data()), doc.text.size()),
            active_file_id_, w2->offset, w2->total_size, tstamp, 0,
            task_fields()
        });
    } else {
        submit_index_task(IndexTask{
            IndexOp::Add,
            std::string(bytes_to_view(key)),
            ord,
            std::string(reinterpret_cast<const char*>(doc.text.data()), doc.text.size()),
            active_file_id_, w->offset, w->total_size, tstamp, 0,
            task_fields()
        });
    }
    return {};
}

// search_text：BM25 词袋模式搜索。
std::expected<TextSearchResult, CaskFault>
Cask::search_text(std::string_view query, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_text(query, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// search_phrase：BM25 短语模式搜索。
std::expected<TextSearchResult, CaskFault>
Cask::search_phrase(std::string_view query, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_phrase(query, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// search_fields：BM25 多字段搜索（S8.6），支持 field:term^boost。
std::expected<TextSearchResult, CaskFault>
Cask::search_fields(std::string_view query, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_fields(query, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// search_near：BM25 近邻搜索（S8.7）。
std::expected<TextSearchResult, CaskFault>
Cask::search_near(std::string_view query, std::uint32_t slop, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_near(query, slop, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// bool_search：BM25 布尔搜索（AND/OR/NOT）。
std::expected<TextSearchResult, CaskFault>
Cask::bool_search(std::string_view query, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->bool_search(query, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// S8.3：模糊搜索（Levenshtein 编辑距离匹配）。
std::expected<TextSearchResult, CaskFault>
Cask::search_fuzzy(std::string_view query, std::size_t k, std::uint32_t max_edit_distance) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_fuzzy(query, k, max_edit_distance);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// S8.4：通配符搜索（* / ? 模式匹配）。
std::expected<TextSearchResult, CaskFault>
Cask::search_wildcard(std::string_view pattern, std::size_t k) {
    if (!search_) return std::unexpected(err(CaskError::kNoIndex));
    flush_index();
    auto hits = search_->search_wildcard(pattern, k);
    if (!hits) return std::unexpected(err(CaskError::kIo, hits.error()));
    return TextSearchResult{std::move(*hits)};
}

// S8.2：设置同义词词典。
void Cask::set_synonym_map(std::unique_ptr<text::SynonymMap> map) {
    if (search_) search_->set_synonym_map(std::move(map));
}

std::expected<void, CaskFault> Cask::sync() {
    if (active_data_) {
        if (auto r = active_data_->sync(); !r) {
            return std::unexpected(io_fault(r.error().errnum));
        }
    }
    return {};
}

// ---- status / fold / merge 包装 --------------------------------------------
// merge 这里是同步阻塞的——上层（NIF 注册了 ERL_NIF_DIRTY_JOB_IO_BOUND）
// 把它放到 dirty 调度器，所以不会卡住 BEAM 主调度。merge 完成后：
//   1. 从 fstats 里把已合并的 file_id 删掉（trim_fstats）
//   2. 从 read_files_ 缓存淘汰对应句柄（防止 fd 泄漏）
//   3. unlink 旧 data + hint 文件（节省磁盘）

StatusInfo Cask::status() {
    StatusInfo s;
    auto info = keydir_->info();
    s.key_count = info.key_count;
    s.key_bytes = info.key_bytes;
    s.epoch     = info.epoch;
    s.files.reserve(info.fstats.size());
    for (const auto& f : info.fstats) {
        s.files.push_back(merge::summarize(dirname_, f));
    }
    return s;
}

bool Cask::is_empty_estimate() {
    return keydir_->info().key_count == 0;
}

bool Cask::is_frozen() {
    return keydir_->info().iter_info.frozen;
}

// 包装 merge::decide。关键工作是「排除不该被合的 active file」：
//   - 普通 writer 模式：排除自己的 active_file_id_（不能合自己正在写的）
//   - merge_only 模式：排除 open 时从 write.lock 抠出来的「live writer 当
//     前 active id」；为了应对「writer 在我们 snapshot 之后 roll 过去」，
//     防御性地排除所有 file_id >= snapshot 的文件。代价是少并几个文件，
//     下一轮 merge 自然处理。
Cask::NeedsMerge Cask::needs_merge(std::uint32_t now_sec) {
    auto info = keydir_->info();
    const std::uint32_t exclude_id =
        opts_.merge_only ? merger_writer_active_id_ : active_file_id_;
    std::vector<merge::FileStatus> summary;
    summary.reserve(info.fstats.size());
    for (const auto& f : info.fstats) {
        if (opts_.merge_only) {
            if (exclude_id != 0 && f.file_id >= exclude_id) continue;
        } else {
            if (f.file_id == active_file_id_) continue;
        }
        summary.push_back(merge::summarize(dirname_, f));
    }
    auto d = merge::decide(summary, opts_.policy, now_sec);
    NeedsMerge n;
    n.needs = d.needs_merge;
    for (const auto& f : d.files)         n.files.push_back(f.filename);
    for (const auto& f : d.expired_files) n.expired_files.push_back(f.filename);
    return n;
}

// 合并执行。files 为空时先 needs_merge 决定要并什么；非空就直接用
// caller 给的列表。流程：
//   1. run_merge 实际复制活的 record 到新文件
//   2. 从 read_files_ 缓存里淘汰被合掉的 fd（必须在 unlink 之前关，
//      否则在某些平台上文件会通过 /proc/self/fd 短暂残留）
//   3. unlink 旧 data + hint 文件
//   4. trim_fstats 把旧 fstats 条目清掉
std::expected<merge::MergeStats, CaskFault>
Cask::merge(std::vector<std::string> files, std::uint32_t now_sec) {
    if (files.empty()) {
        auto n = needs_merge(now_sec);
        if (!n.needs) {
            // 不需要 merge——返回空 stats。
            return merge::MergeStats{};
        }
        files = std::move(n.files);
    }
    auto r = merge::run_merge(files, dirname_, *keydir_, opts_.o_sync, search_.get());
    if (!r) {
        return std::unexpected(err(CaskError::kIo, r.error().detail));
    }

    if (search_) {
        if (index_pool_) index_pool_->flush();

        search_->rebuild_index(
            [this](std::uint32_t fid, std::uint64_t off, std::uint32_t sz)
                -> std::optional<std::string> {
                auto* df = read_file(fid);
                if (!df) return std::nullopt;
                auto rec = df->read(off, sz);
                if (!rec) return std::nullopt;
                auto dv = codec::decode_doc_value(
                    std::span<const std::byte>(rec->value.data(), rec->value.size()));
                if (!dv || !dv->has_text) return std::nullopt;
                return std::string(reinterpret_cast<const char*>(dv->text.data()), dv->text.size());
            });

        auto snap = dirname_ + "/bm25_snapshot.inv";
        search_->save_snapshot(snap);
    }

    // 关键顺序：先关 fd 再 unlink。
    {
        std::scoped_lock lk(read_cache_mu_);
        for (const auto& path : files) {
            if (auto t = fileops::parse_data_tstamp(path)) {
                read_files_.erase(static_cast<std::uint32_t>(*t));
            }
        }
    }

    // After run_merge, every live record from `files` has been CAS-rewritten
    // into the new merge file, and stale records were already pointing
    // elsewhere. So nothing in the keydir references these inputs anymore —
    // safe to unlink the .data + .hint pair and drop the fstats entry.
    //
    // Failures here are best-effort: the keydir is already consistent. A
    // residual file just wastes disk until the next process tries the same.
    std::vector<std::uint32_t> trimmed_ids;
    trimmed_ids.reserve(files.size());
    for (const auto& path : files) {
        std::error_code ec;
        std::filesystem::remove(path, ec);
        std::filesystem::remove(fileops::mk_hint_filename(path), ec);
        if (auto t = fileops::parse_data_tstamp(path)) {
            trimmed_ids.push_back(static_cast<std::uint32_t>(*t));
        }
    }
    if (!trimmed_ids.empty()) {
        (void)keydir_->trim_fstats(trimmed_ids);
    }
    return *r;
}

}  // namespace bitcask
