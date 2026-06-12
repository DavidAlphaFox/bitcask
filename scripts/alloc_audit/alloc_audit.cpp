// 内存优化验收驱动:各热路径跑 N 次操作,经 LD_PRELOAD shim 计数 malloc,
// 输出 per-op 分配次数。对 HEAD(基线)与工作树(优化后)各编译一份对比。
#include <dlfcn.h>
#include <unistd.h>

#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <random>
#include <string>
#include <vector>

#include "bitcask/cask.hpp"
#include "bitcask/data_file.hpp"
#include "bitcask/intersect.hpp"
#include "bitcask/inverted.hpp"
#include "bitcask/query.hpp"

namespace fs = std::filesystem;
using namespace bitcask;

static std::uint64_t snap() {
    using F = unsigned long (*)();
    static F f = reinterpret_cast<F>(dlsym(RTLD_DEFAULT, "alloc_shim_count"));
    return f ? f() : 0;
}

static std::span<const std::byte> as_bytes(const std::string& s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

struct AlwaysLive final : bm25::LiveChecker {
    bool is_live(std::uint64_t) const override { return true; }
    std::uint32_t doc_len(std::uint64_t) const override { return 3; }
};

int main() {
    const std::string root =
        "/tmp/alloc_audit_" + std::to_string(::getpid());
    fs::create_directories(root);

    // ---- PUT / GET 热路径 -------------------------------------------------
    {
        CaskOptions o;
        o.read_write = true;
        auto c = Cask::open(root + "/cask", o);
        if (!c) { std::printf("cask open failed\n"); return 1; }
        auto& cask = **c;

        constexpr int kKeyspace = 1024;
        std::vector<std::string> keys;
        for (int i = 0; i < kKeyspace; ++i) keys.push_back("k" + std::to_string(i));
        const std::string value(128, 'v');
        for (auto& k : keys) (void)cask.put(as_bytes(k), as_bytes(value));

        std::mt19937 rng(0xCAFE);
        std::uniform_int_distribution<int> dist(0, kKeyspace - 1);

        constexpr int N = 10000;
        auto c0 = snap();
        for (int i = 0; i < N; ++i) {
            auto& k = keys[static_cast<std::size_t>(dist(rng))];
            auto r = cask.put(as_bytes(k), as_bytes(value));
            if (!r) return 1;
        }
        auto c1 = snap();
        for (int i = 0; i < N; ++i) {
            auto& k = keys[static_cast<std::size_t>(dist(rng))];
            auto r = cask.get(as_bytes(k));
            if (!r) return 1;
        }
        auto c2 = snap();
        std::printf("put_per_op   %.2f\n", double(c1 - c0) / N);
        std::printf("get_per_op   %.2f\n", double(c2 - c1) / N);
        cask.close();
    }

    // ---- 扫盘 fold(keydir 重建路径)--------------------------------------
    {
        auto df = fileops::DataFile::open(root + "/fold.data",
                                          fileops::DataFile::Mode::kCreate);
        if (!df) { std::printf("datafile open failed\n"); return 1; }
        const std::string value(64, 'v');
        constexpr int M = 20000;
        for (int i = 0; i < M; ++i) {
            const std::string key = "key" + std::to_string(i);
            auto w = df->write(format::RecordType::kDoc, 1000,
                               static_cast<std::uint64_t>(i),
                               as_bytes(key), as_bytes(value));
            if (!w) return 1;
        }
        auto c0 = snap();
        std::size_t seen = 0;
        auto r = df->fold(
            [&](const codec::DataRecordView&, std::uint64_t, std::uint32_t) {
                ++seen;
            },
            false, nullptr);
        auto c1 = snap();
        if (!r || seen != M) { std::printf("fold failed\n"); return 1; }
        std::printf("fold_per_rec %.4f\n", double(c1 - c0) / M);
    }

    // ---- intersect_u64 内核 ----------------------------------------------
    {
        constexpr std::size_t n = 100000;
        std::vector<std::uint64_t> a(n), b(n);
        for (std::size_t i = 0; i < n; ++i) { a[i] = 2 * i; b[i] = 3 * i; }

        constexpr int Q = 1000;
        std::vector<std::uint64_t> out;
        auto c0 = snap();
        for (int i = 0; i < Q; ++i) bm25::intersect_u64(a, b, out);
        auto c1 = snap();
        for (int i = 0; i < Q; ++i) {
            std::vector<std::uint64_t> fresh;
            bm25::intersect_u64(a, b, fresh);
        }
        auto c2 = snap();
        std::printf("intersect_reused_per_op %.4f\n", double(c1 - c0) / Q);
        std::printf("intersect_fresh_per_op  %.4f\n", double(c2 - c1) / Q);
    }

    // ---- BoolMust 查询(两热词交集 + 评分)--------------------------------
    {
        bm25::InvertedIndex idx;
        constexpr int D = 20000;
        for (int i = 0; i < D; ++i) {
            bm25::TermPositions tp;
            tp["hot"]  = {1, {0}};
            tp["warm"] = {1, {1}};
            tp["u" + std::to_string(i)] = {1, {2}};
            idx.add_doc(static_cast<std::uint64_t>(i), tp);
        }
        AlwaysLive lc;
        auto q = bm25::QueryNode::must_all({bm25::QueryNode::must_term("hot"),
                                            bm25::QueryNode::must_term("warm")});
        // 预热(快照惰性构建等一次性成本不计入)。
        (void)idx.bool_search(q, 10, lc);

        constexpr int Q = 100;
        auto c0 = snap();
        for (int i = 0; i < Q; ++i) {
            auto r = idx.bool_search(q, 10, lc);
            if (r.size() != 10) return 1;
        }
        auto c1 = snap();
        std::printf("boolmust_per_query %.1f\n", double(c1 - c0) / Q);
    }

    std::error_code ec;
    fs::remove_all(root, ec);
    return 0;
}
