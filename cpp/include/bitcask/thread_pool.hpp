// TBB 线程池封装：per-Cask 的 Index Pool + Search Pool。
//
// Index Pool（1 线程）：消费异步索引队列，执行分词 + Index 更新。
//   使用 std::thread 而非 TBB task_arena，避免 concurrency=1 时
//   主线程与 worker 争用同一 slot 导致 flush() 死锁。
// Search Pool（N 线程 unbounded）：执行 BM25 并行搜索（T6 阶段启用）。
//
// === 生命周期 ===
//   1. Cask::open() → 创建 IndexPool
//   2. put/delete → push IndexTask 到队列
//   3. Index Pool worker 异步消费（T3 阶段实现）
//   4. Cask::close() → stop() + join
//   5. NIF on_unload → tbb::finalize() 确保所有线程退出
//
// === 线程安全 ===
//   - IndexTaskQueue：基于 tbb::concurrent_bounded_queue，多生产者单消费者安全。
//   - stop()：设置原子标志后推入 sentinel，worker 线程安全退出。
//   - flush()：等待 pending_ 计数归零，保证所有已提交任务已被消费。

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <oneapi/tbb/concurrent_queue.h>  // concurrent_bounded_queue（oneTBB 已并入此头）
#include <oneapi/tbb/global_control.h>

#if defined(__SANITIZE_THREAD__) || \
    (defined(__has_feature) && __has_feature(thread_sanitizer))
extern "C" {
void __tsan_acquire(void* addr);
void __tsan_release(void* addr);
}
#endif

namespace bitcask {

// 索引操作类型。
enum class IndexOp : std::uint8_t {
    Add,         // 文档写入（分词 + put_doc + add_doc）
    Delete,      // 文档删除（remove_doc + index.remove）
    // V3.5:merge 后 HNSW 重建(物理清死)。由 worker 执行以维持 HNSW
    // 单写者约束——重建期间到达的 put 任务排在其后,由同一 worker 顺序
    // 消化,无写写并发;查询线程经 atomic 指针走旧图。
    RebuildHnsw,
    Sentinel,    // 停止信号，worker 收到后退出循环
};

// 索引任务：put/delete 路径提交到 Index Pool 的异步任务。
// key / text 必须拥有独立存储（非 string_view），因为原始数据在 put()
// 返回后可能被释放。两者合并进单个 buf（= key ⧺ text，key_len 划界），
// 一次分配替代原先 key/text 两个 string。
struct IndexTask {
    IndexOp              op;
    std::string          buf;          // key ⧺ text 合并存储
    std::uint64_t        ord       = 0;
    std::uint32_t        key_len   = 0;
    std::uint32_t        file_id   = 0;
    std::uint64_t        offset    = 0;
    std::uint32_t        total_sz  = 0;
    std::uint32_t        tstamp    = 0;
    std::uint32_t        doc_len   = 0; // token 总数（BM25 统计用）
    // S8.6 多字段：非空时走 on_write_fields；text 字段保留兼容单字段路径。
    std::vector<std::pair<std::string, std::string>> fields;
    // V3.3:Add 任务的文档向量(已归一化;空 = 无)。worker 转交
    // SearchLayer::on_vector → HNSW insert。
    std::vector<float> vec;
    // V5:文档结构化 meta blob(可为空)。worker 转交 Index::set_meta,
    // 与 put_doc 同 unique_lock 路径——filter 读取时 meta 与定位/live
    // 已原子一致。make() 不接管:caller 在构造后按需 assign。
    std::vector<std::byte> meta;

    [[nodiscard]] std::string_view key() const noexcept {
        return std::string_view(buf).substr(0, key_len);
    }
    [[nodiscard]] std::string_view text() const noexcept {
        return std::string_view(buf).substr(key_len);
    }

    // 唯一构造入口（Sentinel 除外）：key+text 一次分配进 buf。
    static IndexTask make(IndexOp op_, std::string_view key_,
                          std::uint64_t ord_, std::string_view text_,
                          std::uint32_t file_id_, std::uint64_t offset_,
                          std::uint32_t total_sz_, std::uint32_t tstamp_,
                          std::uint32_t doc_len_,
                          std::vector<std::pair<std::string, std::string>>
                              fields_ = {}) {
        IndexTask t;
        t.op = op_;
        t.buf.reserve(key_.size() + text_.size());
        t.buf.append(key_);
        t.buf.append(text_);
        t.key_len  = static_cast<std::uint32_t>(key_.size());
        t.ord      = ord_;
        t.file_id  = file_id_;
        t.offset   = offset_;
        t.total_sz = total_sz_;
        t.tstamp   = tstamp_;
        t.doc_len  = doc_len_;
        t.fields   = std::move(fields_);
        return t;
    }
};

// 索引任务队列：多生产者（put/delete 线程）→ 单消费者（Index Pool worker）。
// 背压通过 tbb::concurrent_bounded_queue 的 bounded capacity 实现。
class IndexTaskQueue {
public:
    explicit IndexTaskQueue(std::size_t capacity = 10240)
    {
        queue_.set_capacity(capacity);
    }

    // C1:tbb 队列内部以 fence 同步,TSan 不建模独立 fence——producer
    // 构造的任务 payload 与 consumer 的读取会被误报 data race(任务
    // 字符串上的假阳性族)。用 TSan 标注 API 把移交的 happens-before
    // 显式告知 runtime;非 TSan 构建为空操作。
    void push(IndexTask task) {
        annotate_release();
        queue_.push(std::move(task));
    }

    IndexTask pop() {
        IndexTask task;
        queue_.pop(task);
        annotate_acquire();
        return task;
    }

    bool try_pop(IndexTask& task) {
        if (!queue_.try_pop(task)) return false;
        annotate_acquire();
        return true;
    }

    std::size_t size() const { return queue_.size(); }

private:
#if defined(__SANITIZE_THREAD__) || \
    (defined(__has_feature) && __has_feature(thread_sanitizer))
    void annotate_release() { __tsan_release(&queue_); }
    void annotate_acquire() { __tsan_acquire(&queue_); }
#else
    void annotate_release() {}
    void annotate_acquire() {}
#endif

    tbb::concurrent_bounded_queue<IndexTask> queue_;
};

// per-Cask 的索引线程管理器。
// 使用独立 std::thread 消费任务队列。
// T6 阶段会增加 Search Pool（基于 TBB task_arena）。
class IndexPool {
public:
    explicit IndexPool(int concurrency = 1, std::size_t queue_capacity = 10240)
        : stopped_(false)
        , pending_(0)
        , queue_(queue_capacity)
    {
        (void)concurrency;
    }

    ~IndexPool() { stop(); }

    IndexPool(const IndexPool&) = delete;
    IndexPool& operator=(const IndexPool&) = delete;

    void submit(IndexTask task) {
        if (stopped_.load(std::memory_order_acquire)) return;
        pending_.fetch_add(1, std::memory_order_relaxed);
        queue_.push(std::move(task));
    }

    template <typename Consumer>
    void start(Consumer&& consumer) {
        worker_ = std::thread([this, c = std::forward<Consumer>(consumer)]() mutable {
            worker_loop(std::move(c));
        });
    }

    void stop() {
        bool expected = false;
        if (!stopped_.compare_exchange_strong(expected, true,
                                               std::memory_order_acq_rel)) {
            return;
        }
        queue_.push(IndexTask{IndexOp::Sentinel});
        if (worker_.joinable()) worker_.join();
    }

    // 等待所有已提交任务被 worker 消费完毕。
    void flush() {
        while (pending_.load(std::memory_order_acquire) > 0) {
            std::this_thread::yield();
        }
    }

    bool is_stopped() const {
        return stopped_.load(std::memory_order_acquire);
    }

    IndexTaskQueue&       queue()       { return queue_; }
    const IndexTaskQueue& queue() const { return queue_; }

private:
    template <typename Consumer>
    void worker_loop(Consumer&& consumer) {
        while (!stopped_.load(std::memory_order_acquire)) {
            auto task = queue_.pop();
            if (task.op == IndexOp::Sentinel) {
                IndexTask remaining;
                while (queue_.try_pop(remaining)) {
                    if (remaining.op == IndexOp::Sentinel) continue;
                    consumer(remaining);
                    pending_.fetch_sub(1, std::memory_order_release);
                }
                break;
            }
            consumer(task);
            pending_.fetch_sub(1, std::memory_order_release);
        }
    }

    std::thread worker_;
    std::atomic<bool> stopped_{false};
    std::atomic<std::size_t> pending_{0};
    IndexTaskQueue   queue_;
};

// TBB 生命周期管理（NIF on_load / on_unload 用）。
// 必须在 on_load 中调用 acquire()，on_unload 中调用 release()。
// 确保 tbb::finalize() 在 .so 卸载前完成，避免 worker 线程持有已卸载的代码。
class TbbLifetime {
public:
    void acquire() {
        handle_.emplace(tbb::attach{});
    }

    void release() {
        if (handle_) {
            tbb::finalize(*handle_);
            handle_.reset();
        }
    }

    bool is_acquired() const { return handle_.has_value(); }

private:
    std::optional<tbb::task_scheduler_handle> handle_;
};

}  // namespace bitcask
