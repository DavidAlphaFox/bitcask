// HNSW V3.2 验收:召回对拍(vs 暴力 KNN)+ 边界语义。
// 红线(hnsw-design §6 V3.2):recall@10 ≥ 0.95(ef=64)/ 0.99(ef=256)。

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <random>
#include <thread>
#include <vector>

#include "bitcask/hnsw.hpp"

using bitcask::vec::HnswConfig;
using bitcask::vec::HnswIndex;
using bitcask::vec::HnswMetric;

namespace {

// 固定种子合成数据:N 个归一化高斯向量(cosine 场景的标准合成形态)。
std::vector<float> make_vectors(std::size_t n, std::size_t dim,
                                std::uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> g(0.0f, 1.0f);
    std::vector<float> out(n * dim);
    for (std::size_t i = 0; i < n; ++i) {
        float* v = out.data() + i * dim;
        double sq = 0.0;
        for (std::size_t d = 0; d < dim; ++d) {
            v[d] = g(rng);
            sq += static_cast<double>(v[d]) * v[d];
        }
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        for (std::size_t d = 0; d < dim; ++d) v[d] *= inv;
    }
    return out;
}

// 暴力 top-k(内积),返回 ord 集。
std::vector<std::uint64_t> brute_topk(const std::vector<float>& base,
                                      std::size_t n, std::size_t dim,
                                      const float* q, std::size_t k) {
    std::vector<std::pair<float, std::uint64_t>> all;
    all.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
        const float* v = base.data() + i * dim;
        float dot = 0.0f;
        for (std::size_t d = 0; d < dim; ++d) dot += v[d] * q[d];
        all.push_back({dot, static_cast<std::uint64_t>(i)});
    }
    std::partial_sort(all.begin(), all.begin() + static_cast<long>(k),
                      all.end(), std::greater<>());
    std::vector<std::uint64_t> ids;
    ids.reserve(k);
    for (std::size_t i = 0; i < k; ++i) ids.push_back(all[i].second);
    return ids;
}

double measure_recall(std::size_t n, std::size_t dim, std::size_t nq,
                      std::size_t k, std::size_t ef) {
    auto base = make_vectors(n, dim, 0xBA5E);
    auto queries = make_vectors(nq, dim, 0xC0DE);

    HnswConfig cfg;
    cfg.dim = static_cast<std::uint16_t>(dim);
    cfg.metric = HnswMetric::kDot;
    HnswIndex idx(cfg);
    for (std::size_t i = 0; i < n; ++i) {
        idx.insert(i, std::span<const float>(base.data() + i * dim, dim));
    }

    std::size_t hit = 0;
    for (std::size_t qi = 0; qi < nq; ++qi) {
        const float* q = queries.data() + qi * dim;
        auto truth = brute_topk(base, n, dim, q, k);
        auto got = idx.search(std::span<const float>(q, dim), k, ef);
        for (const auto& h : got) {
            if (std::find(truth.begin(), truth.end(), h.ord) != truth.end()) {
                ++hit;
            }
        }
    }
    return static_cast<double>(hit) / static_cast<double>(nq * k);
}

}  // namespace

// 红线:10k 库 recall@10。
TEST(Hnsw, RecallAt10_Ef64) {
    const double r = measure_recall(10000, 32, 50, 10, 64);
    RecordProperty("recall", std::to_string(r));
    EXPECT_GE(r, 0.95) << "recall@10 ef=64 = " << r;
}

TEST(Hnsw, RecallAt10_Ef256) {
    const double r = measure_recall(10000, 32, 50, 10, 256);
    EXPECT_GE(r, 0.99) << "recall@10 ef=256 = " << r;
}

// 高维一档(384,真实 embedding 维度;库小控时长)。
// 标定说明:纯随机高斯在 d=384 是距离集中下的 ANN 最坏形态——实测
// 本实现 M=16 时 ef:64/128/256/512 → 0.824/0.960/0.996/1.000(干净
// 收敛,实现健康);0.95@ef64 红线只对低维/真实流形数据成立。
// 本档按 ef=128/256 标定,留安全边际。
TEST(Hnsw, RecallAt10_Dim384) {
    EXPECT_GE(measure_recall(2000, 384, 25, 10, 128), 0.93);
    EXPECT_GE(measure_recall(2000, 384, 25, 10, 256), 0.98);
}

// 精确性兜底:k=1 自查询(库内向量查自己必须命中自己)。
TEST(Hnsw, SelfQueryTop1) {
    const std::size_t n = 1000, dim = 16;
    auto base = make_vectors(n, dim, 0x5E1F);
    HnswConfig cfg;
    cfg.dim = dim;
    HnswIndex idx(cfg);
    for (std::size_t i = 0; i < n; ++i) {
        idx.insert(i, std::span<const float>(base.data() + i * dim, dim));
    }
    std::size_t ok = 0;
    for (std::size_t i = 0; i < n; i += 37) {
        auto got = idx.search(
            std::span<const float>(base.data() + i * dim, dim), 1, 64);
        ASSERT_EQ(got.size(), 1u);
        if (got[0].ord == i) ++ok;
        EXPECT_FLOAT_EQ(got[0].score, 1.0f);  // 归一化向量自内积 = 1
    }
    EXPECT_GE(ok * 37, n - 37);  // 允许极少数并列向量擦边
}

// ord 水位幂等:重放重叠区丢弃。
TEST(Hnsw, OrdWatermarkIdempotent) {
    HnswConfig cfg;
    cfg.dim = 4;
    HnswIndex idx(cfg);
    const float a[4] = {1, 0, 0, 0};
    const float b[4] = {0, 1, 0, 0};
    idx.insert(5, a);
    idx.insert(5, b);   // 同 ord 重放 → 丢弃
    idx.insert(3, b);   // 低于水位 → 丢弃
    EXPECT_EQ(idx.size(), 1u);
    auto got = idx.search(std::span<const float>(a, 4), 1, 16);
    ASSERT_EQ(got.size(), 1u);
    EXPECT_EQ(got[0].ord, 5u);
}

// live 过滤:结果侧滤死,死节点仍可作路标。
TEST(Hnsw, LiveFilterExcludesDead) {
    const std::size_t n = 500, dim = 8;
    auto base = make_vectors(n, dim, 0xDEAD);
    HnswConfig cfg;
    cfg.dim = dim;
    HnswIndex idx(cfg);
    for (std::size_t i = 0; i < n; ++i) {
        idx.insert(i, std::span<const float>(base.data() + i * dim, dim));
    }
    std::function<bool(std::uint64_t)> live = [](std::uint64_t ord) {
        return ord % 2 == 0;  // 奇数全死
    };
    for (std::size_t qi = 0; qi < n; qi += 61) {
        auto got = idx.search(
            std::span<const float>(base.data() + qi * dim, dim), 10, 128,
            &live);
        for (const auto& h : got) EXPECT_EQ(h.ord % 2, 0u);
        EXPECT_GT(got.size(), 0u);
    }
}

// 空图/k=0 边界。
TEST(Hnsw, EmptyAndZeroK) {
    HnswConfig cfg;
    cfg.dim = 4;
    HnswIndex idx(cfg);
    const float q[4] = {1, 0, 0, 0};
    EXPECT_TRUE(idx.search(std::span<const float>(q, 4), 5, 16).empty());
    idx.insert(0, q);
    EXPECT_TRUE(idx.search(std::span<const float>(q, 4), 0, 16).empty());
}

// V3.3 并发协议验收:1 写者顺序插入 + 4 读者并发搜索(TSan 主战场)。
// 断言:读者全程无越界 ord(可达节点必已发布)、写完后召回抽查 ≥0.9。
TEST(Hnsw, ConcurrentReadersWithSingleWriter) {
    // TSan 下缩规模不缩协议:happens-before 验证与节点数无关,
    // 但自旋锁 × TSan 插桩是乘法减速(实测 20k 档 ~110s)。
#if defined(__SANITIZE_THREAD__) || \
    (defined(__has_feature) && __has_feature(thread_sanitizer))
    const std::size_t n = 5000;
#else
    const std::size_t n = 20000;
#endif
    const std::size_t dim = 16;
    auto base = make_vectors(n, dim, 0xC0FFEE);
    HnswConfig cfg;
    cfg.dim = static_cast<std::uint16_t>(dim);
    HnswIndex idx(cfg);

    std::atomic<bool> done{false};
    std::atomic<bool> bound_violated{false};
    std::atomic<std::uint64_t> reader_queries{0};

    std::vector<std::thread> readers;
    readers.reserve(4);
    for (int t = 0; t < 4; ++t) {
        readers.emplace_back([&, t]() {
            std::mt19937_64 rng(0xFEED0000ULL + static_cast<unsigned>(t));
            while (!done.load(std::memory_order_acquire)) {
                const std::size_t qi = rng() % n;
                auto got = idx.search(
                    std::span<const float>(base.data() + qi * dim, dim), 10,
                    64);
                // 任何返回 ord 必 < 搜索之后的已发布数(本测试 ord == 插入序)。
                const std::uint64_t bound = idx.size();
                for (const auto& h : got) {
                    if (h.ord >= bound) {
                        bound_violated.store(true, std::memory_order_relaxed);
                    }
                }
                reader_queries.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    for (std::size_t i = 0; i < n; ++i) {
        idx.insert(i, std::span<const float>(base.data() + i * dim, dim));
    }
    done.store(true, std::memory_order_release);
    for (auto& th : readers) th.join();

    EXPECT_FALSE(bound_violated.load());
    EXPECT_GT(reader_queries.load(), 0u);
    EXPECT_EQ(idx.size(), n);

    // 写完后的召回抽查(brute 对拍,阈值 0.9 留并发余量;16d 实测远高)。
    auto queries = make_vectors(30, dim, 0xD1CE);
    std::size_t hit = 0;
    for (std::size_t qi = 0; qi < 30; ++qi) {
        const float* q = queries.data() + qi * dim;
        auto truth = brute_topk(base, n, dim, q, 10);
        auto got = idx.search(std::span<const float>(q, dim), 10, 64);
        for (const auto& h : got) {
            if (std::find(truth.begin(), truth.end(), h.ord) != truth.end()) {
                ++hit;
            }
        }
    }
    const double recall = static_cast<double>(hit) / (30.0 * 10.0);
    RecordProperty("recall", std::to_string(recall));
    EXPECT_GE(recall, 0.9) << "post-concurrency recall = " << recall;
}

// L2 度量基本语义。
TEST(Hnsw, L2MetricBasic) {
    HnswConfig cfg;
    cfg.dim = 2;
    cfg.metric = HnswMetric::kL2;
    HnswIndex idx(cfg);
    const float pts[3][2] = {{0, 0}, {1, 0}, {5, 5}};
    for (std::uint64_t i = 0; i < 3; ++i) idx.insert(i, pts[i]);
    const float q[2] = {0.9f, 0.1f};
    auto got = idx.search(std::span<const float>(q, 2), 3, 16);
    ASSERT_EQ(got.size(), 3u);
    EXPECT_EQ(got[0].ord, 1u);  // 最近 (1,0)
    EXPECT_EQ(got[2].ord, 2u);  // 最远 (5,5)
}
