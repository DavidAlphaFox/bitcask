#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

#include "bitcask/analyzer.hpp"
#include "bitcask/index.hpp"
#include "bitcask/inverted.hpp"

namespace bitcask {

struct CollectionOptions;

struct CollectionSharedData {
    index::Index index;
    std::unique_ptr<bm25::InvertedIndex> inverted;
    std::unique_ptr<text::Analyzer> analyzer;

    mutable std::mutex ready_mu;
    bool ready = false;

    void mark_ready() {
        std::lock_guard lk(ready_mu);
        ready = true;
    }
    [[nodiscard]] bool is_ready() const {
        std::lock_guard lk(ready_mu);
        return ready;
    }
};

enum class CollectionAcquireStatus {
    kCreated,
    kReady,
    kNotReady,
};

struct CollectionAcquireResult {
    CollectionAcquireStatus status;
    std::shared_ptr<CollectionSharedData> data;
};

class CollectionRegistry {
public:
    CollectionRegistry() = default;
    ~CollectionRegistry() = default;
    CollectionRegistry(const CollectionRegistry&) = delete;
    CollectionRegistry& operator=(const CollectionRegistry&) = delete;

    [[nodiscard]] CollectionAcquireResult acquire(std::string_view name);
    [[nodiscard]] CollectionAcquireResult query(std::string_view name) const;
    void release(std::string_view name);
    [[nodiscard]] std::size_t size() const noexcept;

private:
    struct Slot {
        std::shared_ptr<CollectionSharedData> data;
        std::uint32_t refcount = 0;
    };
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Slot> entries_;
};

}  // namespace bitcask
