// 进程内全局的命名 KeyDir 注册表。
//
// 对应 legacy 的 bitcask_priv_data.global_keydirs + global_biggest_file_id。
// 同一个名字（一般是 bitcask 目录的绝对路径）多次 acquire 会共享同一个底层
// KeyDir，靠 refcount 管理生命周期；refcount 归零时把 biggest_file_id + 1
// 存进 saved_biggest_file_id_，保证后续重新 acquire 同名 keydir 时，
// 新分配的 file_id 不会跟历史文件冲突（避免 keydir 表里把旧 id 当新 id）。
//
// 初始化协议（关键，调用方必须遵守）：
//   - 第一个 acquire 同一个 name 的人拿到 status = kCreated 和一个全新的、
//     is_ready() == false 的 KeyDir。这个人是「初始化者」，必须在 keydir
//     被填充完成后（一般是 open 时扫完全部 data file 后）调
//     kd->mark_ready()。
//   - 在 mark_ready() 之前，其它 acquire 同名 keydir 的请求会拿到
//     status = kNotReady 和 nullptr——legacy 行为，调用方需要重试 / 等待。
//   - mark_ready() 之后，所有后续 acquire 拿到 status = kReady 和共享指针，
//     refcount 加 1。
//
// release(name) 必须配对调 acquire 时用过的 name；refcount 归零后从注册表
// 删除该项，同时把当时的 biggest_file_id + 1 持久化到 saved_biggest_file_id_。
//
// === 线程模型 ===
// 整个注册表受一把 std::mutex mutex_ 保护；所有 public 方法均「线程安全 /
// 可重入」——多线程并发 acquire/release/query 同名或不同名 keydir 都安全。
// 不要从 KeyDir 持锁的回调里反向调本注册表（会出现锁顺序倒置；目前没人
// 这么做，注释作约束声明）。

#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

#include "bitcask/keydir.hpp"

namespace bitcask::keydir {

enum class AcquireStatus {
    kCreated,    // 全新创建；caller 是初始化者，建索引完毕后必须 mark_ready()
    kReady,      // 已存在且就绪；refcount 已自增
    kNotReady,   // 名字存在但尚未 mark_ready（或不存在）；caller 应重试 / 等待
};

struct AcquireResult {
    AcquireStatus status;
    std::shared_ptr<KeyDir> keydir;  // status == kNotReady 时为 nullptr
};

class KeyDirRegistry {
public:
    KeyDirRegistry() = default;
    ~KeyDirRegistry() = default;

    KeyDirRegistry(const KeyDirRegistry&) = delete;
    KeyDirRegistry& operator=(const KeyDirRegistry&) = delete;

    // 获取或新建一个命名 KeyDir。语义见文件头注释的初始化协议。
    // 线程安全: 是。锁: 内部 std::lock_guard(mutex_)。
    [[nodiscard]] AcquireResult acquire(std::string_view name);

    // 不创建只查询：返回 kReady 或 kNotReady（后者既包含「名字不存在」
    // 也包含「存在但未 ready」两种情况，调用方一般无需区分）。
    // 线程安全: 是。锁: 内部 std::lock_guard(mutex_)。
    [[nodiscard]] AcquireResult query(std::string_view name) const;

    // 释放 acquire 拿到的 keydir。refcount 减一；归零则：
    //   1) 从 entries_ 移除该项；
    //   2) 把当时的 biggest_file_id + 1 存到 saved_biggest_file_id_，
    //      保证后续重新 acquire 不会复用旧 file_id。
    // name 必须跟 acquire 时一致。
    // 线程安全: 是。锁: 内部 std::lock_guard(mutex_)。
    void release(std::string_view name);

    // 测试 / 内省工具。
    // 线程安全: 是。锁: 内部 std::lock_guard(mutex_)。
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] std::optional<std::uint32_t>
    saved_biggest_file_id(std::string_view name) const;

private:
    struct Slot {
        std::shared_ptr<KeyDir> keydir;
        std::uint32_t refcount = 0;
    };
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Slot> entries_;
    // refcount=0 后保留的「最大 file_id 已用过的下一个值」；
    // 重新 acquire 时让 KeyDir 从这里恢复 file_id 计数器。
    std::unordered_map<std::string, std::uint32_t> saved_biggest_file_id_;
};

}  // namespace bitcask::keydir
