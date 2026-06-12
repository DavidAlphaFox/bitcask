// T2.7 单元测试：IndexPool + IndexTaskQueue + TbbLifetime

#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/thread_pool.hpp"

namespace {

using bitcask::IndexOp;
using bitcask::IndexPool;
using bitcask::IndexTask;
using bitcask::IndexTaskQueue;
using bitcask::TbbLifetime;

TEST(IndexPool, SubmitAndProcess) {
    IndexPool pool(1, 10240);
    std::atomic<std::size_t> count{0};

    pool.start([&](const IndexTask& task) {
        if (task.op != IndexOp::Sentinel) {
            ++count;
        }
        return true;
    });

    constexpr std::size_t kTasks = 100;
    for (std::size_t i = 0; i < kTasks; ++i) {
        pool.submit(IndexTask::make(IndexOp::Add, std::to_string(i), i, "text", 1, 0, 0, 0, 0));
    }

    pool.flush();
    EXPECT_EQ(count.load(), kTasks);
    pool.stop();
}

TEST(IndexPool, StopIsIdempotent) {
    IndexPool pool(1, 10240);
    pool.start([](const IndexTask&) { return true; });
    pool.stop();
    pool.stop();
}

TEST(IndexPool, DrainWithoutStart) {
    IndexPool pool(1, 10240);
    pool.stop();
}

TEST(IndexPool, SentinelStopsWorker) {
    IndexPool pool(1, 10240);
    std::atomic<bool> invoked{false};

    pool.start([&](const IndexTask& task) {
        if (task.op == IndexOp::Sentinel) return false;
        invoked = true;
        return true;
    });

    pool.queue().push(IndexTask{IndexOp::Sentinel});
    pool.stop();

    EXPECT_FALSE(invoked);
}

TEST(IndexTaskQueue, BoundedCapacity) {
    IndexTaskQueue queue(5);
    for (int i = 0; i < 5; ++i) {
        queue.push(IndexTask::make(IndexOp::Add, std::to_string(i), 0, "text", 0, 0, 0, 0, 0));
    }
    EXPECT_EQ(queue.size(), 5);
}

TEST(IndexTaskQueue, TaskOrderingFIFO) {
    IndexTaskQueue queue(1024);
    constexpr std::size_t kCount = 200;
    for (std::size_t i = 0; i < kCount; ++i) {
        queue.push(IndexTask::make(IndexOp::Add, std::to_string(i), i, "text", 0, 0, 0, 0, 0));
    }

    std::vector<std::uint64_t> received;
    received.reserve(kCount);
    for (std::size_t i = 0; i < kCount; ++i) {
        auto task = queue.pop();
        received.push_back(task.ord);
    }
    for (std::size_t i = 0; i < kCount; ++i) {
        EXPECT_EQ(received[i], i);
    }
}

TEST(TbbLifetime, AcquireRelease) {
    TbbLifetime lifetime;
    EXPECT_FALSE(lifetime.is_acquired());

    lifetime.acquire();
    EXPECT_TRUE(lifetime.is_acquired());

    lifetime.release();
    EXPECT_FALSE(lifetime.is_acquired());
}

TEST(CaskCompilation, IndexPoolAccessor) {
    static_assert(sizeof(IndexPool) > 0, "IndexPool must be complete type");
    static_assert(sizeof(TbbLifetime) > 0, "TbbLifetime must be complete type");
}

}  // namespace
