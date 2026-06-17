// HNSW 实现(V3.3 单写者 + 多读者)。算法对应 Malkov & Yashunin 2016;
// 工程选择见 doc/hnsw-design-zh.md §2,并发协议见 §3 与 hnsw.hpp 文件头。

#include "bitcask/hnsw.hpp"
#include "bitcask/codec.hpp"
#include "hnsw_kernels.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <queue>
#include <string>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#endif

namespace bitcask::vec {

// V3.9:距离内核从匿名命名空间外移一份到 bitcask::vec::detail,只给
// cpp/bench/distance_bench.cpp 等 micro-bench 走 hnsw_kernels.hpp 直接调
// 用做对拍/计时。生产路径 pick_kernel() 仍用本 TU 内同函数(在匿名命名
// 空间里被强引用,链接器裁掉它们的具名符号时不会丢弃 —— 实际上 pick_kernel
// 返回函数指针强保)。算法、签名、target 属性不变,只换命名空间。

namespace detail {

// ---- 距离内核:返回值统一为"越小越近"的 distance ----
// kDot:dist = -dot(归一化向量下 = 余弦距离的单调变换);
// kL2 :dist = 平方欧氏。

float dot_scalar(const float* a, const float* b, std::size_t n) {
    float s = 0.0f;
    for (std::size_t i = 0; i < n; ++i) s += a[i] * b[i];
    return -s;
}

float l2_scalar(const float* a, const float* b, std::size_t n) {
    float s = 0.0f;
    for (std::size_t i = 0; i < n; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#define BITCASK_HNSW_SIMD 1

__attribute__((target("avx2,fma")))
float hsum256(__m256 v) {
    __m128 lo = _mm256_castps256_ps128(v);
    __m128 hi = _mm256_extractf128_ps(v, 1);
    lo = _mm_add_ps(lo, hi);
    lo = _mm_hadd_ps(lo, lo);
    lo = _mm_hadd_ps(lo, lo);
    return _mm_cvtss_f32(lo);
}

// V3.8:4 路独立累加器打破 FMA 依赖链。单累加器下每次 fmadd 依赖上一次
// 结果(FMA 延迟 ~4cyc → 1 FMA/4cyc);4 路交错把循环顶到加载口上限
// (2 加载/cyc = 1 FMA/cyc),内核理论余量 ~4×。384d=12 轮、2560d=80 轮
// 整除主循环;8 宽次级循环 + 标量尾兜任意 n。注:求和顺序改变,结果与
// 旧内核可有最后一两 ulp 漂移(测试容差均覆盖)。
__attribute__((target("avx2,fma")))
float dot_avx2(const float* a, const float* b, std::size_t n) {
    __m256 acc0 = _mm256_setzero_ps(), acc1 = _mm256_setzero_ps();
    __m256 acc2 = _mm256_setzero_ps(), acc3 = _mm256_setzero_ps();
    std::size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        acc0 = _mm256_fmadd_ps(_mm256_loadu_ps(a + i),
                               _mm256_loadu_ps(b + i), acc0);
        acc1 = _mm256_fmadd_ps(_mm256_loadu_ps(a + i + 8),
                               _mm256_loadu_ps(b + i + 8), acc1);
        acc2 = _mm256_fmadd_ps(_mm256_loadu_ps(a + i + 16),
                               _mm256_loadu_ps(b + i + 16), acc2);
        acc3 = _mm256_fmadd_ps(_mm256_loadu_ps(a + i + 24),
                               _mm256_loadu_ps(b + i + 24), acc3);
    }
    for (; i + 8 <= n; i += 8) {
        acc0 = _mm256_fmadd_ps(_mm256_loadu_ps(a + i),
                               _mm256_loadu_ps(b + i), acc0);
    }
    float s = hsum256(_mm256_add_ps(_mm256_add_ps(acc0, acc1),
                                    _mm256_add_ps(acc2, acc3)));
    for (; i < n; ++i) s += a[i] * b[i];
    return -s;
}

__attribute__((target("avx2,fma")))
float l2_avx2(const float* a, const float* b, std::size_t n) {
    __m256 acc0 = _mm256_setzero_ps(), acc1 = _mm256_setzero_ps();
    __m256 acc2 = _mm256_setzero_ps(), acc3 = _mm256_setzero_ps();
    std::size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        const __m256 d0 = _mm256_sub_ps(_mm256_loadu_ps(a + i),
                                        _mm256_loadu_ps(b + i));
        const __m256 d1 = _mm256_sub_ps(_mm256_loadu_ps(a + i + 8),
                                        _mm256_loadu_ps(b + i + 8));
        const __m256 d2 = _mm256_sub_ps(_mm256_loadu_ps(a + i + 16),
                                        _mm256_loadu_ps(b + i + 16));
        const __m256 d3 = _mm256_sub_ps(_mm256_loadu_ps(a + i + 24),
                                        _mm256_loadu_ps(b + i + 24));
        acc0 = _mm256_fmadd_ps(d0, d0, acc0);
        acc1 = _mm256_fmadd_ps(d1, d1, acc1);
        acc2 = _mm256_fmadd_ps(d2, d2, acc2);
        acc3 = _mm256_fmadd_ps(d3, d3, acc3);
    }
    for (; i + 8 <= n; i += 8) {
        const __m256 d = _mm256_sub_ps(_mm256_loadu_ps(a + i),
                                       _mm256_loadu_ps(b + i));
        acc0 = _mm256_fmadd_ps(d, d, acc0);
    }
    float s = hsum256(_mm256_add_ps(_mm256_add_ps(acc0, acc1),
                                    _mm256_add_ps(acc2, acc3)));
    for (; i < n; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}

// V3.9:AVX-512 距离内核。__m512 = 16 floats,主循环 stride = 64(4 路累加 ×
// 16),把 384d 缩到 6 轮、1536d 缩到 24 轮;在 Skylake-SP/Ice Lake 这类双
// FMA 单元上,主循环理论上限 ~2 FMA/cyc(2 加载 + 2 FMA / cyc),相对 AVX2
// 内核理论再翻倍。仅用 AVX512F 子集(无 BW/VL),最大化可移植。注意:
// 求和顺序随累加器宽度变宽,与 AVX2 末位 ulp 可能有数 ulp 漂移,正确性
// 检验见 cpp/bench/distance_bench.cpp。
__attribute__((target("avx512f")))
float hsum512(__m512 v) {
#if defined(__GNUC__) && (__GNUC__ >= 10)
    // GCC 10+/Clang 的 _mm512_reduce_add_ps:内部即树形归并,单指令。
    return _mm512_reduce_add_ps(v);
#else
    // 兼容旧编译器:手工两两归并(8 步加法 vs 横向 ~16 步)。
    __m256 lo = _mm512_castps512_ps256(v);
    __m256 hi = _mm512_extractf64x4_ps(v, 1);
    __m256 s256 = _mm256_add_ps(lo, hi);
    __m128 lo2 = _mm256_castps256_ps128(s256);
    __m128 hi2 = _mm256_extractf128_ps(s256, 1);
    __m128 s128 = _mm_add_ps(lo2, hi2);
    s128 = _mm_hadd_ps(s128, s128);
    s128 = _mm_hadd_ps(s128, s128);
    return _mm_cvtss_f32(s128);
#endif
}

__attribute__((target("avx512f")))
float dot_avx512(const float* a, const float* b, std::size_t n) {
    __m512 acc0 = _mm512_setzero_ps(), acc1 = _mm512_setzero_ps();
    __m512 acc2 = _mm512_setzero_ps(), acc3 = _mm512_setzero_ps();
    std::size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        acc0 = _mm512_fmadd_ps(_mm512_loadu_ps(a + i),
                               _mm512_loadu_ps(b + i), acc0);
        acc1 = _mm512_fmadd_ps(_mm512_loadu_ps(a + i + 16),
                               _mm512_loadu_ps(b + i + 16), acc1);
        acc2 = _mm512_fmadd_ps(_mm512_loadu_ps(a + i + 32),
                               _mm512_loadu_ps(b + i + 32), acc2);
        acc3 = _mm512_fmadd_ps(_mm512_loadu_ps(a + i + 48),
                               _mm512_loadu_ps(b + i + 48), acc3);
    }
    for (; i + 16 <= n; i += 16) {
        acc0 = _mm512_fmadd_ps(_mm512_loadu_ps(a + i),
                               _mm512_loadu_ps(b + i), acc0);
    }
    float s = hsum512(_mm512_add_ps(_mm512_add_ps(acc0, acc1),
                                    _mm512_add_ps(acc2, acc3)));
    for (; i < n; ++i) s += a[i] * b[i];
    return -s;
}

__attribute__((target("avx512f")))
float l2_avx512(const float* a, const float* b, std::size_t n) {
    __m512 acc0 = _mm512_setzero_ps(), acc1 = _mm512_setzero_ps();
    __m512 acc2 = _mm512_setzero_ps(), acc3 = _mm512_setzero_ps();
    std::size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        const __m512 d0 = _mm512_sub_ps(_mm512_loadu_ps(a + i),
                                        _mm512_loadu_ps(b + i));
        const __m512 d1 = _mm512_sub_ps(_mm512_loadu_ps(a + i + 16),
                                        _mm512_loadu_ps(b + i + 16));
        const __m512 d2 = _mm512_sub_ps(_mm512_loadu_ps(a + i + 32),
                                        _mm512_loadu_ps(b + i + 32));
        const __m512 d3 = _mm512_sub_ps(_mm512_loadu_ps(a + i + 48),
                                        _mm512_loadu_ps(b + i + 48));
        acc0 = _mm512_fmadd_ps(d0, d0, acc0);
        acc1 = _mm512_fmadd_ps(d1, d1, acc1);
        acc2 = _mm512_fmadd_ps(d2, d2, acc2);
        acc3 = _mm512_fmadd_ps(d3, d3, acc3);
    }
    for (; i + 16 <= n; i += 16) {
        const __m512 d = _mm512_sub_ps(_mm512_loadu_ps(a + i),
                                       _mm512_loadu_ps(b + i));
        acc0 = _mm512_fmadd_ps(d, d, acc0);
    }
    float s = hsum512(_mm512_add_ps(_mm512_add_ps(acc0, acc1),
                                    _mm512_add_ps(acc2, acc3)));
    for (; i < n; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}
#endif

}  // namespace detail

namespace {

// V3.8:候选向量软件预取。大图下每个候选是 ~1.5KB(384d)的冷 DRAM
// 取数,先扫一遍邻居把向量首 256B 拉向 L1,再进距离循环——取数与计算
// 重叠,后续行交给硬件流预取。非 x86 为空操作。
inline void prefetch_vec(const float* p) {
#ifdef BITCASK_HNSW_SIMD
    // V3.9:拉宽到 384B(96 floats)以覆盖 384d(1.5KB)前两 AVX-512 行 =
    // 128B;另加 256B 段为 384d 第 2-3 个 cache line 提前热身。AVX2 也
    // 受益(384d 头 64B×4 cache line 已覆盖)。
    const char* c = reinterpret_cast<const char*>(p);
    _mm_prefetch(c, _MM_HINT_T0);
    _mm_prefetch(c + 64, _MM_HINT_T0);
    _mm_prefetch(c + 128, _MM_HINT_T0);
    _mm_prefetch(c + 192, _MM_HINT_T0);
    _mm_prefetch(c + 256, _MM_HINT_T0);
    _mm_prefetch(c + 320, _MM_HINT_T0);
#else
    (void)p;
#endif
}

using DistFn = float (*)(const float*, const float*, std::size_t);

DistFn pick_kernel(HnswMetric metric) {
#ifdef BITCASK_HNSW_SIMD
    // V3.9:AVX-512F 优先(超集)。要求仅基础 AVX-512 Foundation,无 BW/VL,
    // 覆盖 Skylake-SP / Ice Lake / Zen4。运行时一次探测,零查询开销。
    static const bool kAvx512f = __builtin_cpu_supports("avx512f");
    if (kAvx512f) {
        return metric == HnswMetric::kDot ? detail::dot_avx512
                                          : detail::l2_avx512;
    }
    static const bool kAvx2 = __builtin_cpu_supports("avx2") &&
                              __builtin_cpu_supports("fma");
    if (kAvx2) {
        return metric == HnswMetric::kDot ? detail::dot_avx2
                                          : detail::l2_avx2;
    }
#endif
    return metric == HnswMetric::kDot ? detail::dot_scalar
                                      : detail::l2_scalar;
}

inline void cpu_pause() {
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
    __builtin_ia32_pause();
#endif
}

// per-node 自旋锁(1 字节,test-and-set + pause;临界区 ~百 ns)。
inline void lock_node(std::atomic<std::uint8_t>& l) {
    while (l.exchange(1, std::memory_order_acquire) != 0) {
        while (l.load(std::memory_order_relaxed) != 0) cpu_pause();
    }
}
inline void unlock_node(std::atomic<std::uint8_t>& l) {
    l.store(0, std::memory_order_release);
}

// ---- visited 标记:thread_local 版本化数组 ----
// 方案说明(V3.3,与任务书"取最简单且正确者"一致):每读者线程一份
// {marks, epoch, owner};owner 是 HnswIndex 的**全局自增实例 id**
// (非 this 指针——指针在 delete/new 后可复用,会让陈旧 marks 与新实例
// 的 epoch 假性匹配)。owner 切换时整组清零 + epoch 归零;同实例内
// epoch 自增免清零,回绕时整组清一次。多实例被同线程交替查询会触发
// 反复清零,正确性不受影响(本引擎单集合单图,常态零开销)。
struct VisitedTable {
    std::vector<std::uint32_t> marks;
    std::uint32_t epoch = 0;
    std::uint64_t owner = 0;
};
thread_local VisitedTable t_visited;

std::atomic<std::uint64_t> g_instance_seq{1};

}  // namespace

HnswIndex::NodeChunk::NodeChunk(std::size_t dim, bool inmem_int8)
    : vecs(inmem_int8 ? 0 : static_cast<std::size_t>(kChunkSize) * dim),
      ords(kChunkSize, 0),
      levels(kChunkSize, 0),
      adj(kChunkSize),
      locks(new std::atomic<std::uint8_t>[kChunkSize]),
      qcodes(static_cast<std::size_t>(kChunkSize) * dim),
      qscales(kChunkSize, 0.0f),
      qsums(kChunkSize, 0) {
    for (std::uint32_t i = 0; i < kChunkSize; ++i) {
        locks[i].store(0, std::memory_order_relaxed);
    }
}

HnswIndex::HnswIndex(const HnswConfig& cfg)
    : cfg_(cfg),
      dist_(pick_kernel(cfg.metric)),
      int8_dot_(int8::pick_int8_dot_kernel()),
      inv_log_m_(1.0 / std::log(static_cast<double>(cfg.M))),
      instance_id_(g_instance_seq.fetch_add(1, std::memory_order_relaxed)),
      rng_(cfg.seed) {
    assert(cfg_.dim > 0 && cfg_.M >= 2);
    // P5:int8-only 仅 kDot;距离=int8 重建内积。kL2 由上游 open 拒绝。
    assert(!(cfg_.inmem_int8 && cfg_.metric != HnswMetric::kDot) &&
           "inmem_int8 requires kDot metric");
    // int8-only 必须有可用 int8 dot——无 VNNI 时回退标量(否则建图/查询
    // 无 f32 可算)。默认 f32+int8 路径不变:int8_dot_ 为 null 时退 f32。
    if (cfg_.inmem_int8 && int8_dot_ == nullptr) {
        int8_dot_ = &int8::dot_scalar_raw;
    }
}

// P5:int8-only 无常驻 f32,从量化副本反量化到 thread_local 缓冲。
std::span<const float> HnswIndex::node_vec(std::uint32_t id) const {
    if (!cfg_.inmem_int8) {
        return {vec_of(id), cfg_.dim};
    }
    thread_local std::vector<float> buf;
    buf.resize(cfg_.dim);
    const std::int8_t* codes = qcodes_of(id);
    const float factor = qscale_of(id) / 127.0f;
    for (std::uint32_t i = 0; i < cfg_.dim; ++i) {
        buf[i] = static_cast<float>(codes[i]) * factor;
    }
    return {buf.data(), cfg_.dim};
}

HnswIndex::~HnswIndex() {
    for (auto& slot : chunks_) {
        delete slot.load(std::memory_order_relaxed);
    }
}

std::uint32_t HnswIndex::copy_neighbors(std::uint32_t id, std::uint32_t layer,
                                        std::uint32_t* out) const {
    NodeChunk* c = chunk_of(id);
    const std::uint32_t slot = id & kChunkMask;
    auto& lk = c->locks[slot];
    lock_node(lk);
    // adj 指针在节点发布(count release)前写入且永不搬迁;经 count
    // acquire 或本锁的 happens-before 链均可见。
    const std::uint32_t* a = c->adj[slot].data() + layer_off(layer);
    const std::uint32_t n = a[0];
    std::memcpy(out, a + 1, static_cast<std::size_t>(n) * sizeof(std::uint32_t));
    unlock_node(lk);
    return n;
}

std::uint32_t HnswIndex::greedy_closest(const float* q, std::uint32_t start,
                                        std::uint32_t layer, std::uint32_t n,
                                        std::uint32_t* scratch) const {
    std::uint32_t cur = start;
    float cur_d = dist_id(q, cur);
    bool improved = true;
    while (improved) {
        improved = false;
        const std::uint32_t cnt = copy_neighbors(cur, layer, scratch);
        for (std::uint32_t i = 0; i < cnt; ++i) {
            if (scratch[i] < n) prefetch_vec(vec_of(scratch[i]));
        }
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid >= n) continue;  // 本地 count 快照之外:尚未对我发布
            const float d = dist_id(q, nid);
            if (d < cur_d) {
                cur_d = d;
                cur = nid;
                improved = true;
            }
        }
    }
    return cur;
}

void HnswIndex::search_layer(
    const float* q, std::uint32_t entry, std::size_t ef, std::uint32_t layer,
    std::uint32_t n, std::uint32_t* scratch,
    std::vector<std::pair<float, std::uint32_t>>& out) const {
    // visited:thread_local 版本化数组(方案见文件顶部注释)。
    auto& vt = t_visited;
    if (vt.owner != instance_id_) {
        vt.owner = instance_id_;
        vt.epoch = 0;
        std::fill(vt.marks.begin(), vt.marks.end(), 0);
    }
    if (vt.marks.size() < n) vt.marks.resize(n, 0);
    if (++vt.epoch == 0) {
        std::fill(vt.marks.begin(), vt.marks.end(), 0);
        vt.epoch = 1;
    }
    const std::uint32_t ep = vt.epoch;
    std::uint32_t* visited = vt.marks.data();

    using Cand = std::pair<float, std::uint32_t>;
    // 候选:小顶(最近优先);结果:大顶(便于踢最远)。
    std::priority_queue<Cand, std::vector<Cand>, std::greater<>> cands;
    std::priority_queue<Cand> top;

    const float d0 = dist_id(q, entry);
    cands.push({d0, entry});
    top.push({d0, entry});
    visited[entry] = ep;

    while (!cands.empty()) {
        const auto [d, id] = cands.top();
        if (d > top.top().first && top.size() >= ef) break;  // 收敛
        cands.pop();
        const std::uint32_t cnt = copy_neighbors(id, layer, scratch);
        // 预取与计算分两遍:未访问的在界邻居先把向量段拉过来。
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid < n && visited[nid] != ep) prefetch_vec(vec_of(nid));
        }
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid >= n) continue;  // 本地 count 快照之外(见 hpp 协议)
            if (visited[nid] == ep) continue;
            visited[nid] = ep;
            const float nd = dist_id(q, nid);
            if (top.size() < ef || nd < top.top().first) {
                cands.push({nd, nid});
                top.push({nd, nid});
                if (top.size() > ef) top.pop();
            }
        }
    }

    out.clear();
    out.resize(top.size());
    for (std::size_t i = top.size(); i-- > 0;) {
        out[i] = top.top();
        top.pop();
    }
}

// V4.2:int8 粗筛版 greedy_closest,与 f32 版同结构,只换 dist_id →
// dist_id_int8。粗筛阶段不要求数值精度,目的是把图遍历导到正确区域。
std::uint32_t HnswIndex::greedy_closest_int8(
    const std::int8_t* query_codes, float query_scale,
    std::int32_t query_sum, std::uint32_t start, std::uint32_t layer,
    std::uint32_t n, std::uint32_t* scratch) const {
    std::uint32_t cur = start;
    float cur_d = dist_id_int8(query_codes, query_scale, query_sum, cur);
    bool improved = true;
    while (improved) {
        improved = false;
        const std::uint32_t cnt = copy_neighbors(cur, layer, scratch);
        for (std::uint32_t i = 0; i < cnt; ++i) {
            if (scratch[i] < n) {
                const char* pc = reinterpret_cast<const char*>(qcodes_of(scratch[i]));
                _mm_prefetch(pc, _MM_HINT_T0);
                if (cfg_.dim > 64)  _mm_prefetch(pc + 64, _MM_HINT_T0);
                if (cfg_.dim > 128) _mm_prefetch(pc + 128, _MM_HINT_T0);
                if (cfg_.dim > 192) _mm_prefetch(pc + 192, _MM_HINT_T0);
                if (cfg_.dim > 256) _mm_prefetch(pc + 256, _MM_HINT_T0);
                if (cfg_.dim > 320) _mm_prefetch(pc + 320, _MM_HINT_T0);
            }
        }
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid >= n) continue;
            const float d = dist_id_int8(query_codes, query_scale, query_sum,
                                         nid);
            if (d < cur_d) {
                cur_d = d;
                cur = nid;
                improved = true;
            }
        }
    }
    return cur;
}

// V4.2:int8 粗筛版 search_layer,与 f32 版同结构。预取仍对 f32 向量
// 段发(冷拉后段距离不需要重读——int8 阶段之后才是 f32 重排)。
void HnswIndex::search_layer_int8(
    const std::int8_t* query_codes, float query_scale, std::int32_t query_sum,
    std::uint32_t entry, std::size_t ef, std::uint32_t layer, std::uint32_t n,
    std::uint32_t* scratch,
    std::vector<std::pair<float, std::uint32_t>>& out) const {
    auto& vt = t_visited;
    if (vt.owner != instance_id_) {
        vt.owner = instance_id_;
        vt.epoch = 0;
        std::fill(vt.marks.begin(), vt.marks.end(), 0);
    }
    if (vt.marks.size() < n) vt.marks.resize(n, 0);
    if (++vt.epoch == 0) {
        std::fill(vt.marks.begin(), vt.marks.end(), 0);
        vt.epoch = 1;
    }
    const std::uint32_t ep = vt.epoch;
    std::uint32_t* visited = vt.marks.data();

    using Cand = std::pair<float, std::uint32_t>;
    std::priority_queue<Cand, std::vector<Cand>, std::greater<>> cands;
    std::priority_queue<Cand> top;

    const float d0 = dist_id_int8(query_codes, query_scale, query_sum, entry);
    cands.push({d0, entry});
    top.push({d0, entry});
    visited[entry] = ep;

    while (!cands.empty()) {
        const auto [d, id] = cands.top();
        if (d > top.top().first && top.size() >= ef) break;
        cands.pop();
        const std::uint32_t cnt = copy_neighbors(id, layer, scratch);
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid < n && visited[nid] != ep) {
                const char* pc = reinterpret_cast<const char*>(qcodes_of(nid));
                _mm_prefetch(pc, _MM_HINT_T0);
                if (cfg_.dim > 64)  _mm_prefetch(pc + 64, _MM_HINT_T0);
                if (cfg_.dim > 128) _mm_prefetch(pc + 128, _MM_HINT_T0);
                if (cfg_.dim > 192) _mm_prefetch(pc + 192, _MM_HINT_T0);
                if (cfg_.dim > 256) _mm_prefetch(pc + 256, _MM_HINT_T0);
                if (cfg_.dim > 320) _mm_prefetch(pc + 320, _MM_HINT_T0);
            }
        }
        for (std::uint32_t i = 0; i < cnt; ++i) {
            const std::uint32_t nid = scratch[i];
            if (nid >= n) continue;
            if (visited[nid] == ep) continue;
            visited[nid] = ep;
            const float nd = dist_id_int8(query_codes, query_scale, query_sum,
                                          nid);
            if (top.size() < ef || nd < top.top().first) {
                cands.push({nd, nid});
                top.push({nd, nid});
                if (top.size() > ef) top.pop();
            }
        }
    }

    out.clear();
    out.resize(top.size());
    for (std::size_t i = top.size(); i-- > 0;) {
        out[i] = top.top();
        top.pop();
    }
}

void HnswIndex::select_neighbors(
    const float* q, std::vector<std::pair<float, std::uint32_t>>& cands,
    std::uint32_t m) const {
    (void)q;  // cands 的 dist 已按 q 预计算;参数留作语义自注释
    // Algorithm 4 简化版:cands 按 dist 升序;候选与已选集逐一比较,
    // 离 query 更近于离任何已选者才保留——分散方向,聚簇数据下保召回。
    if (cands.size() <= m) return;
    std::vector<std::pair<float, std::uint32_t>> picked;
    picked.reserve(m);
    for (const auto& [d, id] : cands) {
        if (picked.size() >= m) break;
        bool ok = true;
        const float* v = vec_of(id);
        for (const auto& [pd, pid] : picked) {
            if (dist_(v, vec_of(pid), cfg_.dim) < d) {  // 离已选者比离 query 还近
                ok = false;
                break;
            }
        }
        if (ok) picked.push_back({d, id});
    }
    // 不足 m 时用剩余最近者补齐(论文 keepPruned 变体)。
    if (picked.size() < m) {
        for (const auto& c : cands) {
            if (picked.size() >= m) break;
            if (std::find_if(picked.begin(), picked.end(), [&](auto& p) {
                    return p.second == c.second;
                }) == picked.end()) {
                picked.push_back(c);
            }
        }
    }
    cands = std::move(picked);
}

// P5:int8-only 版 select_neighbors。与 f32 版同启发式(Algorithm 4),
// 只把候选-已选距离换成 dist_id_int8_node(两节点皆有量化副本,无 f32)。
void HnswIndex::select_neighbors_int8(
    std::vector<std::pair<float, std::uint32_t>>& cands, std::uint32_t m) const {
    if (cands.size() <= m) return;
    std::vector<std::pair<float, std::uint32_t>> picked;
    picked.reserve(m);
    for (const auto& [d, id] : cands) {
        if (picked.size() >= m) break;
        bool ok = true;
        for (const auto& [pd, pid] : picked) {
            if (dist_id_int8_node(id, pid) < d) {  // 离已选者比离 query 还近
                ok = false;
                break;
            }
        }
        if (ok) picked.push_back({d, id});
    }
    if (picked.size() < m) {
        for (const auto& c : cands) {
            if (picked.size() >= m) break;
            if (std::find_if(picked.begin(), picked.end(), [&](auto& p) {
                    return p.second == c.second;
                }) == picked.end()) {
                picked.push_back(c);
            }
        }
    }
    cands = std::move(picked);
}

void HnswIndex::insert(std::uint64_t ord, std::span<const float> vec) {
    assert(vec.size() == cfg_.dim);
    // 单写者声明:多写者不支持(全引擎统一约束,设计 §3/§7)。
    const bool was_active = writer_active_.exchange(true);
    assert(!was_active && "HnswIndex::insert: single writer only");
    (void)was_active;
    struct Guard {
        std::atomic<bool>& f;
        ~Guard() { f.store(false); }
    } guard{writer_active_};
    // 水位幂等(回放重叠区;ord 引擎全局单调)。
    const std::uint64_t prev = max_inserted_ord_.load(std::memory_order_relaxed);
    if (prev != static_cast<std::uint64_t>(-1) && ord <= prev) return;
    max_inserted_ord_.store(ord, std::memory_order_relaxed);

    const std::uint32_t id = count_.load(std::memory_order_relaxed);
    const std::uint32_t ci = id >> kChunkBits;
    assert(ci < kMaxChunks && "HnswIndex capacity exceeded (kMaxChunks)");
    NodeChunk* c = chunks_[ci].load(std::memory_order_relaxed);
    if (c == nullptr) {
        c = new NodeChunk(cfg_.dim, cfg_.inmem_int8);
        chunks_[ci].store(c, std::memory_order_release);
    }
    const std::uint32_t slot = id & kChunkMask;

    // 层数:floor(-ln(U) * mL),截断防极端。
    double u = std::uniform_real_distribution<double>(0.0, 1.0)(rng_);
    if (u < 1e-12) u = 1e-12;
    auto level = static_cast<std::uint32_t>(-std::log(u) * inv_log_m_);
    if (level > 31) level = 31;

    // 1) 写满本节点数据:vec/ord/level + 零初始化邻接块。
    // P5:int8-only 不存常驻 f32(vecs 容量 0),只落量化副本——建图/查询
    // 全程 int8。默认 f32+int8 路径不变:存 f32,VNNI 在时附带量化副本粗筛。
    if (cfg_.inmem_int8) {
        auto qv = int8::quantize(vec.data(), cfg_.dim);
        std::memcpy(c->qcodes.data() +
                        static_cast<std::size_t>(slot) * cfg_.dim,
                    qv.codes.data(),
                    static_cast<std::size_t>(cfg_.dim) * sizeof(std::int8_t));
        c->qscales[slot] = qv.scale;
        c->qsums[slot]   = qv.sum_codes;
    } else {
        std::memcpy(c->vecs.data() + static_cast<std::size_t>(slot) * cfg_.dim,
                    vec.data(),
                    static_cast<std::size_t>(cfg_.dim) * sizeof(float));
        // V4.2:同步落 int8 量化副本。int8 路径存在时(VNNI)下游 search 用
        // 4× 缩的带宽 + VNNI 加速;int8_dot_ == nullptr 时这段不被读,浪费
        // 一些内存但功能不变(仅 kDot 有意义,kL2 见 search 路径判断)。
        if (int8_dot_ != nullptr && cfg_.metric == HnswMetric::kDot) {
            auto qv = int8::quantize(vec.data(), cfg_.dim);
            std::memcpy(c->qcodes.data() +
                            static_cast<std::size_t>(slot) * cfg_.dim,
                        qv.codes.data(),
                        static_cast<std::size_t>(cfg_.dim) * sizeof(std::int8_t));
            c->qscales[slot] = qv.scale;
            c->qsums[slot]   = qv.sum_codes;
        }
    }
    c->ords[slot] = ord;
    c->levels[slot] = static_cast<std::uint8_t>(level);
    const std::size_t slots =
        (1 + cfg_.M * 2) + static_cast<std::size_t>(level) * (1 + cfg_.M);
    c->adj[slot].resize(slots);  // 定容,.data() 地址此后永不搬迁

    // 2) 发布:此后读者可见本节点(邻接为空 → 图内不可达,无害)。
    count_.store(id + 1, std::memory_order_release);

    // entry_meta_ 仅写者改,relaxed 自读即可。
    const std::uint64_t em = entry_meta_.load(std::memory_order_relaxed);
    if (em == 0) {  // 首节点
        entry_meta_.store((static_cast<std::uint64_t>(level + 1) << 32) | id,
                          std::memory_order_release);
        return;
    }
    const auto max_level = static_cast<std::int32_t>(em >> 32) - 1;
    auto cur = static_cast<std::uint32_t>(em & 0xFFFFFFFFu);

    // 写者侧搜索的可见边界 = id(自身排除:防低层把自己选成自己邻居)。
    const std::uint32_t n_bound = id;
    std::vector<std::uint32_t> scratch(1 + cfg_.M * 2);

    // P5:int8-only 用本节点量化副本作建图 query(无常驻 f32);默认用 f32。
    const bool i8 = cfg_.inmem_int8;
    const float* q =
        i8 ? nullptr
           : c->vecs.data() + static_cast<std::size_t>(slot) * cfg_.dim;
    const std::int8_t* qc = i8 ? qcodes_of(id) : nullptr;
    const float        qs = i8 ? qscale_of(id) : 0.0f;
    const std::int32_t qsum = i8 ? qsum_of(id) : 0;

    // 上层贪心下降到 level+1。
    for (std::int32_t l = max_level;
         l > static_cast<std::int32_t>(level); --l) {
        cur = i8 ? greedy_closest_int8(qc, qs, qsum, cur,
                                       static_cast<std::uint32_t>(l), n_bound,
                                       scratch.data())
                 : greedy_closest(q, cur, static_cast<std::uint32_t>(l), n_bound,
                                  scratch.data());
    }

    // 3) level..0:efConstruction 搜索 + 启发式选边 + 双向连边 + 邻居收缩。
    std::vector<std::pair<float, std::uint32_t>> found;
    for (std::int32_t l = std::min<std::int32_t>(
             static_cast<std::int32_t>(level), max_level);
         l >= 0; --l) {
        const auto lay = static_cast<std::uint32_t>(l);
        if (i8) {
            search_layer_int8(qc, qs, qsum, cur, cfg_.ef_construction, lay,
                              n_bound, scratch.data(), found);
        } else {
            search_layer(q, cur, cfg_.ef_construction, lay, n_bound,
                         scratch.data(), found);
        }
        cur = found.front().second;  // 下层入口 = 本层最近

        auto picked = found;
        if (i8) select_neighbors_int8(picked, cfg_.M);
        else    select_neighbors(q, picked, cfg_.M);  // L0 也选 M,容量 2M 留收缩余量

        // 正向边:本节点已发布,读者可能在拷它的邻居 → 持自身锁写。
        {
            auto& my_lk = c->locks[slot];
            lock_node(my_lk);
            std::uint32_t* my = c->adj[slot].data() + layer_off(lay);
            for (const auto& [d, nid] : picked) {
                my[++my[0]] = nid;
            }
            unlock_node(my_lk);
        }

        // 反向边 + 超容收缩:逐邻居持其锁改其邻接。
        for (const auto& [d, nid] : picked) {
            NodeChunk* nc = chunk_of(nid);
            const std::uint32_t nslot = nid & kChunkMask;
            auto& nlk = nc->locks[nslot];
            lock_node(nlk);
            std::uint32_t* nb = nc->adj[nslot].data() + layer_off(lay);
            const std::uint32_t cap = layer_cap(lay);
            if (nb[0] < cap) {
                nb[++nb[0]] = id;
            } else {
                // 收缩:旧邻居 + 新候选并集,以 nid 为查询点重选 cap 条。
                // 持锁做距离计算(微秒级临界区):读者只在 copy_neighbors
                // 短暂争同一把锁,实测可接受;arena/锁外预选留 V3.x。
                std::vector<std::pair<float, std::uint32_t>> pool;
                pool.reserve(cap + 1);
                if (i8) {
                    for (std::uint32_t i = 1; i <= nb[0]; ++i) {
                        pool.push_back({dist_id_int8_node(nid, nb[i]), nb[i]});
                    }
                    pool.push_back({dist_id_int8_node(nid, id), id});
                } else {
                    const float* nv = vec_of(nid);
                    for (std::uint32_t i = 1; i <= nb[0]; ++i) {
                        pool.push_back({dist_id(nv, nb[i]), nb[i]});
                    }
                    pool.push_back({dist_id(nv, id), id});
                }
                std::sort(pool.begin(), pool.end());
                if (i8) select_neighbors_int8(pool, cap);
                else    select_neighbors(vec_of(nid), pool, cap);
                nb[0] = static_cast<std::uint32_t>(pool.size());
                for (std::uint32_t i = 0; i < pool.size(); ++i) {
                    nb[i + 1] = pool[i].second;
                }
            }
            unlock_node(nlk);
        }
    }

    // 4) 层提升:完整连边后才更新 entry(读者拿到的恒为可达入口)。
    if (static_cast<std::int32_t>(level) > max_level) {
        entry_meta_.store((static_cast<std::uint64_t>(level + 1) << 32) | id,
                          std::memory_order_release);
    }
}

std::vector<HnswIndex::Hit> HnswIndex::search(
    std::span<const float> query, std::size_t k, std::size_t ef,
    const std::function<bool(std::uint64_t)>* live) const {
    std::vector<Hit> hits;
    if (k == 0) return hits;
    assert(query.size() == cfg_.dim);

    // 一致快照:先 entry_meta_(acquire)再 count_(acquire)。entry 的
    // 发布 happens-after 其 count 发布 → 看到新 entry 必看到 count > id。
    const std::uint64_t em = entry_meta_.load(std::memory_order_acquire);
    if (em == 0) return hits;  // 空图
    const std::uint32_t n = count_.load(std::memory_order_acquire);
    const auto max_level = static_cast<std::int32_t>(em >> 32) - 1;
    auto cur = static_cast<std::uint32_t>(em & 0xFFFFFFFFu);
    if (ef < k) ef = k;

    std::vector<std::uint32_t> scratch(1 + cfg_.M * 2);
    const float* q = query.data();

    // V4.2:int8 粗筛 + f32 精排。int8 路径只在 VNNI 存在 + kDot 度量下
    // 启用。粗筛用与 f32 相同的 ef(无扩展),以 int8 VNNI 距离遍历图;
    // 精排仅对 top k*3 候选做 f32 距离(固定开销 ~30 次距离计算),保证
    // 召回与纯 f32 一致。
    // P5:int8-only 强制 int8 路径(无 f32 可算,且 dim<64 也得走)。默认
    // 路径仍按 VNNI+kDot+dim≥64 才启 int8 粗筛,否则纯 f32。
    const bool use_int8 =
        cfg_.inmem_int8 ||
        ((int8_dot_ != nullptr) && (cfg_.metric == HnswMetric::kDot) &&
         (cfg_.dim >= 64));

    std::vector<std::pair<float, std::uint32_t>> found;
    if (use_int8) {
        const int8::QVector qq = int8::quantize(q, cfg_.dim);
        for (std::int32_t l = max_level; l > 0; --l) {
            cur = greedy_closest_int8(qq.codes.data(), qq.scale, qq.sum_codes,
                                      cur, static_cast<std::uint32_t>(l), n,
                                      scratch.data());
        }
        search_layer_int8(qq.codes.data(), qq.scale, qq.sum_codes,
                          cur, ef, 0, n, scratch.data(), found);
        // int8-only:无 f32 可精排,found 已按 int8 距离升序,直接取。
        // 默认 f32+int8:对 top k*3 做 f32 精排,召回对齐纯 f32。
        if (!cfg_.inmem_int8) {
            const std::size_t rerank_n = std::min(found.size(), k * 3);
            std::partial_sort(found.begin(), found.begin() + rerank_n,
                              found.end(),
                              [this, q](const auto& a, const auto& b) {
                                  return dist_id(q, a.second) <
                                         dist_id(q, b.second);
                              });
            found.resize(rerank_n);
            for (auto& [d, id] : found) d = dist_id(q, id);
        }
    } else {
        for (std::int32_t l = max_level; l > 0; --l) {
            cur = greedy_closest(q, cur, static_cast<std::uint32_t>(l), n,
                                 scratch.data());
        }
        search_layer(q, cur, ef, 0, n, scratch.data(), found);
    }

    hits.reserve(k);
    for (const auto& [d, id] : found) {
        const std::uint64_t ord = ord_of(id);
        if (live != nullptr && *live && !(*live)(ord)) continue;  // 结果侧滤死
        // score 语义:kDot 返回内积本身(d = -dot);kL2 返回 -距离。
        hits.push_back({ord, -d});  // kDot:-(-dot)=内积;kL2:-平方距离
        if (hits.size() >= k) break;
    }
    return hits;
}

// ---- V3.5:BCVS v1 快照(协议注释见 hnsw.hpp;格式见设计 §5)----
//
// payload 布局(LE):
//   dim u16 | metric u8 | M u32 | ef_construction u32 | seed u64
//   count u32 | entry_meta u64 | max_inserted_ord u64
//   count 个节点(节点 id 即写出顺序 0..count-1,邻接 id 引用该编号):
//     ord u64 | level u8 | vec f32×dim | (level+1) 层: cnt u32 | cnt×u32 id

namespace {

constexpr std::uint32_t kBcvsMagic   = 0x42435653;  // "BCVS"
constexpr std::uint32_t kBcvsVersion = 1;

void vs_put16(std::vector<std::uint8_t>& b, std::uint16_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 2);
}
void vs_put32(std::vector<std::uint8_t>& b, std::uint32_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 4);
}
void vs_put64(std::vector<std::uint8_t>& b, std::uint64_t v) {
    const auto* p = reinterpret_cast<const std::uint8_t*>(&v);
    b.insert(b.end(), p, p + 8);
}

}  // namespace

bool HnswIndex::serialize(std::vector<std::uint8_t>& buf) const {
    // 读者协议快照:entry 先于 count(同 search;entry 发布 happens-after
    // 其 count 发布)。n 之后追加的节点/反向边一律不进本快照。
    const std::uint64_t em = entry_meta_.load(std::memory_order_acquire);
    const std::uint32_t n  = count_.load(std::memory_order_acquire);
    // entry 必 < n(发布序保证);防御性兜底:不一致就放弃本次快照。
    if (em != 0 && static_cast<std::uint32_t>(em & 0xFFFFFFFFu) >= n) {
        return false;
    }

    buf.clear();
    buf.reserve(64 + static_cast<std::size_t>(n) *
                         (16 + static_cast<std::size_t>(cfg_.dim) * 4 +
                          (1 + cfg_.M * 2) * 4));
    vs_put32(buf, kBcvsMagic);
    vs_put32(buf, kBcvsVersion);
    vs_put16(buf, cfg_.dim);
    buf.push_back(static_cast<std::uint8_t>(cfg_.metric));
    vs_put32(buf, cfg_.M);
    vs_put32(buf, cfg_.ef_construction);
    vs_put64(buf, cfg_.seed);
    vs_put32(buf, n);
    vs_put64(buf, em);
    // 落盘水位 = 已保存节点的最大 ord(见 hpp:不抄 max_inserted_ord_ 原子,
    // 防 mid-insert 领先 count 的窗口;ord 按插入序单调 → 尾节点即最大)。
    vs_put64(buf, n > 0 ? ord_of(n - 1) : static_cast<std::uint64_t>(-1));

    std::vector<std::uint32_t> scratch(1 + cfg_.M * 2);
    for (std::uint32_t id = 0; id < n; ++id) {
        const NodeChunk* c = chunk_of(id);
        const std::uint32_t slot = id & kChunkMask;
        vs_put64(buf, c->ords[slot]);
        const std::uint8_t level = c->levels[slot];
        buf.push_back(level);
        // P5:BCVS v1 盘上恒存 f32(格式不变)。int8-only 无常驻 f32 →
        // 从量化副本反量化写出;load 再量化回。盘上存 int8 的优化留 P5b。
        if (cfg_.inmem_int8) {
            const std::int8_t* codes =
                c->qcodes.data() + static_cast<std::size_t>(slot) * cfg_.dim;
            const float factor = c->qscales[slot] / 127.0f;
            for (std::uint32_t d = 0; d < cfg_.dim; ++d) {
                const float fv = static_cast<float>(codes[d]) * factor;
                const auto* fp = reinterpret_cast<const std::uint8_t*>(&fv);
                buf.insert(buf.end(), fp, fp + sizeof(float));
            }
        } else {
            const auto* v = reinterpret_cast<const std::uint8_t*>(
                c->vecs.data() + static_cast<std::size_t>(slot) * cfg_.dim);
            buf.insert(buf.end(), v,
                       v + static_cast<std::size_t>(cfg_.dim) * sizeof(float));
        }
        for (std::uint32_t l = 0; l <= level; ++l) {
            // 持节点锁拷邻接(与并发写者互斥);≥ n 的邻居(快照水位外的
            // 反向边)滤掉,保证文件内不变量 id < count。
            const std::uint32_t cnt = copy_neighbors(id, l, scratch.data());
            std::uint32_t kept = 0;
            for (std::uint32_t i = 0; i < cnt; ++i) {
                if (scratch[i] < n) ++kept;
            }
            vs_put32(buf, kept);
            for (std::uint32_t i = 0; i < cnt; ++i) {
                if (scratch[i] < n) vs_put32(buf, scratch[i]);
            }
        }
    }

    const std::uint32_t crc = bitcask::codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + 8), buf.size() - 8));
    vs_put32(buf, crc);
    return true;
}

bool HnswIndex::save(std::string_view path) const {
    std::vector<std::uint8_t> buf;
    if (!serialize(buf)) return false;
    const std::string fp(path);
    const std::string tmp = fp + ".tmp";
    std::FILE* f = std::fopen(tmp.c_str(), "wb");
    if (!f) return false;
    const bool wrote = std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!wrote || std::rename(tmp.c_str(), fp.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    return true;
}

bool HnswIndex::load(std::string_view path) {
    std::FILE* f = std::fopen(std::string(path).c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long fsz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (fsz < 0) { std::fclose(f); return false; }
    std::vector<std::uint8_t> buf(static_cast<std::size_t>(fsz));
    const bool rd = std::fread(buf.data(), 1, buf.size(), f) == buf.size();
    std::fclose(f);
    if (!rd) return false;
    return deserialize(buf);
}

bool HnswIndex::deserialize(std::span<const std::uint8_t> buf) {
    // open 期单线程(本实例尚未发布给任何读者)——成员虽是 atomic,直填
    // relaxed 即可;对外可见性由调用方的发布点(shared_ptr atomic store /
    // count_ release)建立。
    assert(count_.load(std::memory_order_relaxed) == 0 &&
           "HnswIndex::deserialize: 仅限空图(open 期)调用");

    // 防御性释放残留 chunk:契约要求空图调用,但失败后在同一实例重试,
    // 下方分配循环会覆盖旧 chunk 指针而泄漏(assert 在 release 被编译掉)。
    for (auto& slot : chunks_) {
        delete slot.exchange(nullptr, std::memory_order_relaxed);
    }

    // 最小:magic+ver+header(39)+crc。
    if (buf.size() < 51) return false;

    auto rd32at = [&](std::size_t off) {
        std::uint32_t v;
        std::memcpy(&v, buf.data() + off, 4);
        return v;
    };
    if (rd32at(0) != kBcvsMagic || rd32at(4) != kBcvsVersion) return false;
    std::uint32_t stored_crc = 0;
    std::memcpy(&stored_crc, buf.data() + buf.size() - 4, 4);
    const std::uint32_t crc = bitcask::codec::crc32(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(buf.data() + 8), buf.size() - 12));
    if (crc != stored_crc) return false;

    const std::uint8_t* p   = buf.data() + 8;
    const std::uint8_t* end = buf.data() + buf.size() - 4;
    auto need = [&](std::size_t nb) {
        return static_cast<std::size_t>(end - p) >= nb;
    };

    std::uint16_t dim;
    std::memcpy(&dim, p, 2); p += 2;
    const std::uint8_t metric = *p++;
    std::uint32_t m, efc;
    std::memcpy(&m, p, 4); p += 4;
    std::memcpy(&efc, p, 4); p += 4;
    p += 8;  // seed:信息留档,不参与校验(层数随机性不影响图有效性)
    (void)efc;
    // config 一致性:dim/metric/M 决定布局与距离语义,任一不符整体拒绝。
    if (dim != cfg_.dim || metric != static_cast<std::uint8_t>(cfg_.metric) ||
        m != cfg_.M) {
        return false;
    }

    std::uint32_t cnt = 0;
    std::uint64_t em = 0, max_ord = 0;
    std::memcpy(&cnt, p, 4); p += 4;
    std::memcpy(&em, p, 8); p += 8;
    std::memcpy(&max_ord, p, 8); p += 8;
    if (cnt > kMaxChunks * static_cast<std::uint64_t>(kChunkSize)) return false;
    if (cnt == 0) {
        // 空图:entry 必须也为空,水位必须为 -1。
        if (em != 0 || max_ord != static_cast<std::uint64_t>(-1) || p != end) {
            return false;
        }
        return true;
    }
    const auto entry_id    = static_cast<std::uint32_t>(em & 0xFFFFFFFFu);
    const auto entry_level = static_cast<std::int64_t>(em >> 32) - 1;
    if (em == 0 || entry_id >= cnt || entry_level < 0 || entry_level > 31) {
        return false;
    }

    const std::size_t vec_bytes =
        static_cast<std::size_t>(cfg_.dim) * sizeof(float);
    // P5:int8-only 读盘 f32 → 量化进 qcodes 的对齐暂存(逐节点复用)。
    std::vector<float> tmpvec;
    if (cfg_.inmem_int8) tmpvec.resize(cfg_.dim);
    std::uint64_t prev_ord = 0;
    bool have_prev = false;
    for (std::uint32_t id = 0; id < cnt; ++id) {
        const std::uint32_t ci = id >> kChunkBits;
        NodeChunk* c = chunks_[ci].load(std::memory_order_relaxed);
        if (c == nullptr) {
            c = new NodeChunk(cfg_.dim, cfg_.inmem_int8);
            chunks_[ci].store(c, std::memory_order_relaxed);
        }
        const std::uint32_t slot = id & kChunkMask;

        if (!need(9 + vec_bytes)) return false;
        std::uint64_t ord;
        std::memcpy(&ord, p, 8); p += 8;
        // ord 严格递增是写者不变量(插入序分配),也是水位幂等的前提。
        if (have_prev && ord <= prev_ord) return false;
        prev_ord = ord;
        have_prev = true;
        const std::uint8_t level = *p++;
        if (level > 31) return false;
        if (cfg_.inmem_int8) {
            // 无常驻 f32:读 f32(memcpy 防未对齐)→ 量化进 qcodes。
            std::memcpy(tmpvec.data(), p, vec_bytes);
            auto qv = int8::quantize(tmpvec.data(), cfg_.dim);
            std::memcpy(c->qcodes.data() +
                            static_cast<std::size_t>(slot) * cfg_.dim,
                        qv.codes.data(),
                        static_cast<std::size_t>(cfg_.dim) * sizeof(std::int8_t));
            c->qscales[slot] = qv.scale;
            c->qsums[slot]   = qv.sum_codes;
        } else {
            std::memcpy(c->vecs.data() +
                            static_cast<std::size_t>(slot) * cfg_.dim,
                        p, vec_bytes);
        }
        p += vec_bytes;
        c->ords[slot]   = ord;
        c->levels[slot] = level;
        const std::size_t slots =
            (1 + cfg_.M * 2) + static_cast<std::size_t>(level) * (1 + cfg_.M);
        c->adj[slot].resize(slots);
        auto* adj = c->adj[slot].data();
        for (std::uint32_t l = 0; l <= level; ++l) {
            if (!need(4)) return false;
            std::uint32_t nb_cnt;
            std::memcpy(&nb_cnt, p, 4); p += 4;
            if (nb_cnt > layer_cap(l)) return false;
            if (!need(static_cast<std::size_t>(nb_cnt) * 4)) return false;
            std::uint32_t* row = adj + layer_off(l);
            row[0] = nb_cnt;
            for (std::uint32_t i = 0; i < nb_cnt; ++i) {
                std::uint32_t nid;
                std::memcpy(&nid, p, 4); p += 4;
                if (nid >= cnt || nid == id) return false;
                row[i + 1] = nid;
            }
        }
    }
    if (p != end) return false;
    // 水位与尾节点 ord 必一致(save 即按此落盘;不符 = 文件不自洽)。
    if (max_ord != prev_ord) return false;

    // 第二遍:邻居层数覆盖校验——layer-l 表只允许 level ≥ l 的节点,
    // 否则 copy_neighbors(nid, l) 会越过其邻接块(内存安全,非仅逻辑)。
    // 顺带校验 entry 的 level 与 entry_meta 一致。
    auto level_of = [&](std::uint32_t id) -> std::uint8_t {
        return chunks_[id >> kChunkBits]
            .load(std::memory_order_relaxed)
            ->levels[id & kChunkMask];
    };
    if (level_of(entry_id) != static_cast<std::uint8_t>(entry_level)) {
        return false;
    }
    for (std::uint32_t id = 0; id < cnt; ++id) {
        const NodeChunk* c = chunk_of(id);
        const std::uint32_t slot = id & kChunkMask;
        const std::uint32_t* adj = c->adj[slot].data();
        for (std::uint32_t l = 0; l <= c->levels[slot]; ++l) {
            const std::uint32_t* row = adj + layer_off(l);
            for (std::uint32_t i = 1; i <= row[0]; ++i) {
                if (level_of(row[i]) < l) return false;
            }
        }
    }

    max_inserted_ord_.store(max_ord, std::memory_order_relaxed);
    entry_meta_.store(em, std::memory_order_relaxed);
    // V4.2:从 f32 副本重算 int8 量化。BCVS v1 不持久化量化副本——量化是
    // 确定的(f32 输入 → 同一组 int8 codes),重算开销与全图加载同阶,免去
    // 格式升级/兼容成本。仅 kDot + VNNI 路径需要;kL2/无 VNNI 跳过。
    // P5:int8-only 已在读盘循环内量化(无常驻 f32 可重读),此处跳过。
    if (!cfg_.inmem_int8 && int8_dot_ != nullptr &&
        cfg_.metric == HnswMetric::kDot && cnt > 0) {
        for (std::uint32_t id = 0; id < cnt; ++id) {
            NodeChunk* c = chunks_[id >> kChunkBits].load(
                std::memory_order_relaxed);
            const std::uint32_t slot = id & kChunkMask;
            const float* v = c->vecs.data() +
                             static_cast<std::size_t>(slot) * cfg_.dim;
            auto qv = int8::quantize(v, cfg_.dim);
            std::memcpy(c->qcodes.data() +
                            static_cast<std::size_t>(slot) * cfg_.dim,
                        qv.codes.data(),
                        static_cast<std::size_t>(cfg_.dim) * sizeof(std::int8_t));
            c->qscales[slot] = qv.scale;
            c->qsums[slot]   = qv.sum_codes;
        }
    }
    count_.store(cnt, std::memory_order_release);
    return true;
}

}  // namespace bitcask::vec
