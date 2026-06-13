#ifndef BITCASK_TESTS_TEST_SUPPORT_HPP
#define BITCASK_TESTS_TEST_SUPPORT_HPP

#include <gtest/gtest.h>
#include <cstdint>
#include <vector>

#include "bitcask/inverted.hpp"

namespace bitcask::bm25 {

class FakeLiveChecker : public LiveChecker {
public:
    std::unordered_map<std::uint64_t, std::uint32_t> doc_lens;

    [[nodiscard]] bool is_live(std::uint64_t ord) const override {
        return doc_lens.count(ord) > 0;
    }
    [[nodiscard]] std::uint32_t doc_len(std::uint64_t ord) const override {
        auto it = doc_lens.find(ord);
        return it != doc_lens.end() ? it->second : 0;
    }
};

inline auto tp(std::uint32_t tf, std::vector<std::uint32_t> positions = {})
    -> std::pair<std::uint32_t, std::vector<std::uint32_t>> {
    return {tf, std::move(positions)};
}

}

#endif