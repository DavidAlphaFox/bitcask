// HNSW V3.2 验收:召回对拍(vs 暴力 KNN)+ 边界语义。
// 红线(hnsw-design §6 V3.2):recall@10 ≥ 0.95(ef=64)/ 0.99(ef=256)。

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <random>
#include <thread>
#include <vector>

#include "bitcask/detail/int8_kernels.hpp"  // P3c：落盘 int8 量化召回测量
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

// P3c：落盘 int8 量化对召回的影响。brute-force f32 余弦 top-k 为真值，
// 对比「dequant-int8 库（模拟落盘 int8 读回）vs f32 query」的 top-k。
// 隔离量化误差对召回的影响（与 HNSW 近似性无关）。复用 vec::int8 的
// per-vector 对称量化（= 落盘码字的同一方案）。
double measure_quant_recall(std::size_t n, std::size_t dim,
                            std::size_t nq, std::size_t k) {
    auto base = make_vectors(n, dim, 0xBA5E);
    auto queries = make_vectors(nq, dim, 0xC0DE);

    std::vector<float> baseq(n * dim);  // dequant-int8 副本
    for (std::size_t i = 0; i < n; ++i) {
        auto qv = bitcask::vec::int8::quantize(base.data() + i * dim, dim);
        const float s = qv.scale / 127.0f;
        for (std::size_t d = 0; d < dim; ++d) {
            baseq[i * dim + d] = static_cast<float>(qv.codes[d]) * s;
        }
    }

    std::size_t hit = 0;
    for (std::size_t qi = 0; qi < nq; ++qi) {
        const float* q = queries.data() + qi * dim;
        auto truth = brute_topk(base, n, dim, q, k);
        auto got   = brute_topk(baseq, n, dim, q, k);
        for (auto id : got) {
            if (std::find(truth.begin(), truth.end(), id) != truth.end()) ++hit;
        }
    }
    return static_cast<double>(hit) / static_cast<double>(nq * k);
}

// 聚簇向量：nc 个随机单位中心，每点 = normalize(center + 噪声)。均匀随机高维
// 向量近乎正交、无有意义最近邻（HNSW 召回退化为噪声）；真实 embedding 有聚簇
// 结构，这里用聚簇合成逼近，让 top-k 有定义、召回可解释。
// 中心由 seed_centers 决定（base 与 queries 传同一个 → 同一聚簇空间）；
// 点由 seed_points 决定。spread 是「簇内扰动总范数」(已除 sqrt(dim)，避免高维下
// per-component 噪声 ×sqrt(dim) 淹没单位中心)。spread < 中心间距(~1.4) 才有簇结构。
std::vector<float> make_clustered(std::size_t n, std::size_t dim, std::size_t nc,
                                  float spread, std::uint64_t seed_centers,
                                  std::uint64_t seed_points) {
    auto unit = [dim](std::mt19937_64& rng, float* v) {
        std::normal_distribution<float> g(0.0f, 1.0f);
        double sq = 0.0;
        for (std::size_t d = 0; d < dim; ++d) { v[d] = g(rng); sq += double(v[d]) * v[d]; }
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        for (std::size_t d = 0; d < dim; ++d) v[d] *= inv;
    };
    std::mt19937_64 crng(seed_centers);
    std::vector<float> centers(nc * dim);
    for (std::size_t c = 0; c < nc; ++c) unit(crng, centers.data() + c * dim);

    const float sigma = spread / static_cast<float>(std::sqrt(double(dim)));
    std::mt19937_64 prng(seed_points);
    std::normal_distribution<float> g(0.0f, 1.0f);
    std::vector<float> out(n * dim);
    for (std::size_t i = 0; i < n; ++i) {
        const float* ctr = centers.data() + (i % nc) * dim;
        float* v = out.data() + i * dim;
        double sq = 0.0;
        for (std::size_t d = 0; d < dim; ++d) {
            v[d] = ctr[d] + sigma * g(prng);
            sq += double(v[d]) * v[d];
        }
        const auto inv = static_cast<float>(1.0 / std::sqrt(sq));
        for (std::size_t d = 0; d < dim; ++d) v[d] *= inv;
    }
    return out;
}

// int8-only 内存模式建模：在 build_db 上建图+搜索，真值始终用 f32 truth_db 的
// brute-force top-k。build_db=base → 现行 f32 精排模式召回；build_db=dequant-int8
// → int8-only 召回（所有数据都是 int8 精度，连「f32 精排」也只有 int8 精度）。
double hnsw_recall_vs_truth(const std::vector<float>& build_db,
                            const std::vector<float>& truth_db,
                            const std::vector<float>& queries,
                            std::size_t n, std::size_t dim,
                            std::size_t nq, std::size_t k, std::size_t ef) {
    HnswConfig cfg;
    cfg.dim = static_cast<std::uint16_t>(dim);
    cfg.metric = HnswMetric::kDot;
    HnswIndex idx(cfg);
    for (std::size_t i = 0; i < n; ++i) {
        idx.insert(i, std::span<const float>(build_db.data() + i * dim, dim));
    }
    std::size_t hit = 0;
    for (std::size_t qi = 0; qi < nq; ++qi) {
        const float* q = queries.data() + qi * dim;
        auto truth = brute_topk(truth_db, n, dim, q, k);
        auto got = idx.search(std::span<const float>(q, dim), k, ef);
        for (const auto& h : got) {
            if (std::find(truth.begin(), truth.end(), h.ord) != truth.end()) ++hit;
        }
    }
    return static_cast<double>(hit) / static_cast<double>(nq * k);
}

}  // namespace

// int8-only 内存模式实测：省多少内存 + 召回掉多少。
// 内存账是按 NodeChunk 字段精确推算（向量存储部分；邻接表两模式相同，不计入差值）。
TEST(VectorQuant, Int8OnlyMemoryAndRecall) {
    const std::size_t n = 3000, dim = 2560, nq = 40, k = 10, ef = 64, nc = 50;
    // 同一簇空间（中心 seed 相同）；base/queries 点不同（point seed 不同）。
    // spread=0.5：簇内总范数 0.5 < 中心间距 ~1.4 → 簇可分、top-k 有定义。
    auto base    = make_clustered(n,  dim, nc, 0.5f, /*centers*/0xCE57, /*points*/0xBA5E);
    auto queries = make_clustered(nq, dim, nc, 0.5f, /*centers*/0xCE57, /*points*/0xC0DE);
    std::vector<float> baseq(n * dim);  // dequant-int8 副本 = int8-only 存储
    for (std::size_t i = 0; i < n; ++i) {
        auto qv = bitcask::vec::int8::quantize(base.data() + i * dim, dim);
        const float s = qv.scale / 127.0f;
        for (std::size_t d = 0; d < dim; ++d) {
            baseq[i * dim + d] = static_cast<float>(qv.codes[d]) * s;
        }
    }
    const double r_f32  = hnsw_recall_vs_truth(base,  base, queries, n, dim, nq, k, ef);
    const double r_int8 = hnsw_recall_vs_truth(baseq, base, queries, n, dim, nq, k, ef);

    // 向量存储/向量字节：现行 dot 模式 = f32(4d) + int8(d) + scale(4) + sum(4)；
    // int8-only = int8(d) + scale(4) + sum(4)（丢掉常驻 f32 vecs）。
    const double cur = 5.0 * dim + 8.0;
    const double i8o = 1.0 * dim + 8.0;
    std::printf("[int8-only] recall@10 ef64: f32-rerank=%.4f  int8-only=%.4f  (Δ=%.4f)\n",
                r_f32, r_int8, r_f32 - r_int8);
    std::printf("[int8-only] vec mem/vector (dim=%zu): cur(f32+int8)=%.0fB  int8-only=%.0fB"
                "  → %.2fx, 省 %.1f%%\n",
                dim, cur, i8o, cur / i8o, 100.0 * (cur - i8o) / cur);
    std::printf("[int8-only] 1M 向量(仅向量存储): %.2f GB → %.2f GB\n",
                cur * 1e6 / 1e9, i8o * 1e6 / 1e9);
    RecordProperty("recall_f32", std::to_string(r_f32));
    RecordProperty("recall_int8only", std::to_string(r_int8));
    EXPECT_GT(r_int8, 0.90) << "int8-only recall@10 = " << r_int8;  // 实测 0.9675
}

// P5a:真实 inmem_int8 模式(非模拟)——用 cfg.inmem_int8 建图 + 查询,
// 召回须接近模拟预期;并验证 BCVS save/load round-trip 后结果一致。
TEST(VectorQuant, Int8OnlyRealModeRecallAndRoundtrip) {
    const std::size_t n = 3000, dim = 768, nq = 40, k = 10, ef = 64, nc = 50;
    auto base    = make_clustered(n,  dim, nc, 0.5f, 0xCE57, 0xBA5E);
    auto queries = make_clustered(nq, dim, nc, 0.5f, 0xCE57, 0xC0DE);

    auto build = [&](bool inmem_int8) {
        HnswConfig cfg;
        cfg.dim = static_cast<std::uint16_t>(dim);
        cfg.metric = HnswMetric::kDot;
        cfg.inmem_int8 = inmem_int8;
        auto idx = std::make_unique<HnswIndex>(cfg);
        for (std::size_t i = 0; i < n; ++i) {
            idx->insert(i, std::span<const float>(base.data() + i * dim, dim));
        }
        return idx;
    };
    auto recall_of = [&](HnswIndex& idx) {
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
    };

    auto f32  = build(false);
    auto i8o  = build(true);
    const double r_f32 = recall_of(*f32);
    const double r_i8o = recall_of(*i8o);
    std::printf("[int8-only real] recall@10 ef64: f32=%.4f  inmem_int8=%.4f\n",
                r_f32, r_i8o);
    RecordProperty("recall_inmem_int8_real", std::to_string(r_i8o));
    // 真实 int8-only 还量化 query(模拟测试未含),召回略低于 0.9675;红线 0.85。
    EXPECT_GT(r_i8o, 0.85) << "real inmem_int8 recall@10 = " << r_i8o;

    // BCVS round-trip:save int8-only 图 → load 进新的 int8-only 图 → 结果一致。
    const auto path =
        (std::filesystem::temp_directory_path() / "bitcask_i8o_roundtrip.bcvs")
            .string();
    ASSERT_TRUE(i8o->save(path));
    HnswConfig cfg;
    cfg.dim = static_cast<std::uint16_t>(dim);
    cfg.metric = HnswMetric::kDot;
    cfg.inmem_int8 = true;
    HnswIndex reloaded(cfg);
    ASSERT_TRUE(reloaded.load(path));
    EXPECT_EQ(reloaded.size(), i8o->size());
    const double r_reload = recall_of(reloaded);
    EXPECT_NEAR(r_reload, r_i8o, 0.02)
        << "reload recall " << r_reload << " vs in-mem " << r_i8o;
    std::filesystem::remove(path);
}

// P5c：召回 gate（部署维度 dim=2560，与 qwen3-embedding 同维）。真实
// inmem_int8 模式（含 query 量化，区别于模拟版的 f32 query × dequant 库），
// 是定 opt-in 默认前的回归红线。
// 诚实边界：合成簇 ≠ 真实 qwen3 语料——本环境无 embedding 端点，用合成
// 数据作代理；真实语料召回须在部署侧（qwen3 endpoint）复测后才定推荐默认。
TEST(VectorQuant, Int8OnlyRecallGate_Dim2560) {
    const std::size_t n = 2000, dim = 2560, nq = 40, k = 10, ef = 64, nc = 50;
    auto base    = make_clustered(n,  dim, nc, 0.5f, 0xCE57, 0xBA5E);
    auto queries = make_clustered(nq, dim, nc, 0.5f, 0xCE57, 0xC0DE);

    HnswConfig cfg;
    cfg.dim = static_cast<std::uint16_t>(dim);
    cfg.metric = HnswMetric::kDot;
    cfg.inmem_int8 = true;
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
    const double r = static_cast<double>(hit) / static_cast<double>(nq * k);
    std::printf("[P5c gate] inmem_int8 real recall@10 ef64 (dim=2560, n=%zu) "
                "= %.4f\n", n, r);
    RecordProperty("recall_inmem_int8_dim2560", std::to_string(r));
    // 红线:真实 int8-only(含 query 量化)recall@10 ≥ 0.90。低于此说明实现
    // 回归或量化误差超预期,须查。合成簇实测见上方打印。
    EXPECT_GE(r, 0.90) << "inmem_int8 recall@10 (dim=2560) = " << r;
}

// P3c 召回测量（dim=2560，与部署 qwen3-embedding 同维）。阈值是回归红线，
// 设在实测值之下；实测数 + 决策见 doc/vector-ondisk-quant-design-zh.md §6。
TEST(VectorQuant, OnDiskInt8RecallAt10) {
    const double r = measure_quant_recall(2000, 2560, 30, 10);
    RecordProperty("recall_int8_at10", std::to_string(r));
    std::printf("[P3c] on-disk int8 recall@10 (dim=2560, n=2000) = %.4f\n", r);
    EXPECT_GE(r, 0.95) << "int8 recall@10 = " << r;
}

TEST(VectorQuant, OnDiskInt8RecallAt100) {
    const double r = measure_quant_recall(2000, 2560, 30, 100);
    RecordProperty("recall_int8_at100", std::to_string(r));
    std::printf("[P3c] on-disk int8 recall@100 (dim=2560, n=2000) = %.4f\n", r);
    EXPECT_GE(r, 0.95) << "int8 recall@100 = " << r;
}

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
