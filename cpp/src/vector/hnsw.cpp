// HNSW 实现(V3.3 单写者 + 多读者)。算法对应 Malkov & Yashunin 2016;
// 工程选择见 doc/hnsw-design-zh.md §2,并发协议见 §3 与 hnsw.hpp 文件头。

#include "bitcask/hnsw.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <queue>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#endif

namespace bitcask::vec {

namespace {

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

__attribute__((target("avx2,fma")))
float dot_avx2(const float* a, const float* b, std::size_t n) {
    __m256 acc = _mm256_setzero_ps();
    std::size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        acc = _mm256_fmadd_ps(_mm256_loadu_ps(a + i),
                              _mm256_loadu_ps(b + i), acc);
    }
    float s = hsum256(acc);
    for (; i < n; ++i) s += a[i] * b[i];
    return -s;
}

__attribute__((target("avx2,fma")))
float l2_avx2(const float* a, const float* b, std::size_t n) {
    __m256 acc = _mm256_setzero_ps();
    std::size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        const __m256 d = _mm256_sub_ps(_mm256_loadu_ps(a + i),
                                       _mm256_loadu_ps(b + i));
        acc = _mm256_fmadd_ps(d, d, acc);
    }
    float s = hsum256(acc);
    for (; i < n; ++i) {
        const float d = a[i] - b[i];
        s += d * d;
    }
    return s;
}
#endif

using DistFn = float (*)(const float*, const float*, std::size_t);

DistFn pick_kernel(HnswMetric metric) {
#ifdef BITCASK_HNSW_SIMD
    static const bool kAvx2 = __builtin_cpu_supports("avx2") &&
                              __builtin_cpu_supports("fma");
    if (kAvx2) {
        return metric == HnswMetric::kDot ? dot_avx2 : l2_avx2;
    }
#endif
    return metric == HnswMetric::kDot ? dot_scalar : l2_scalar;
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

HnswIndex::NodeChunk::NodeChunk(std::size_t dim)
    : vecs(static_cast<std::size_t>(kChunkSize) * dim),
      ords(kChunkSize, 0),
      levels(kChunkSize, 0),
      adj(kChunkSize, nullptr),
      locks(new std::atomic<std::uint8_t>[kChunkSize]) {
    for (std::uint32_t i = 0; i < kChunkSize; ++i) {
        locks[i].store(0, std::memory_order_relaxed);
    }
}

HnswIndex::NodeChunk::~NodeChunk() {
    for (std::uint32_t* p : adj) delete[] p;
}

HnswIndex::HnswIndex(const HnswConfig& cfg)
    : cfg_(cfg),
      dist_(pick_kernel(cfg.metric)),
      inv_log_m_(1.0 / std::log(static_cast<double>(cfg.M))),
      instance_id_(g_instance_seq.fetch_add(1, std::memory_order_relaxed)),
      rng_(cfg.seed) {
    assert(cfg_.dim > 0 && cfg_.M >= 2);
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
    const std::uint32_t* a = c->adj[slot] + layer_off(layer);
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
        c = new NodeChunk(cfg_.dim);
        chunks_[ci].store(c, std::memory_order_release);
    }
    const std::uint32_t slot = id & kChunkMask;

    // 层数:floor(-ln(U) * mL),截断防极端。
    double u = std::uniform_real_distribution<double>(0.0, 1.0)(rng_);
    if (u < 1e-12) u = 1e-12;
    auto level = static_cast<std::uint32_t>(-std::log(u) * inv_log_m_);
    if (level > 31) level = 31;

    // 1) 写满本节点数据:vec/ord/level + 零初始化邻接块。
    std::memcpy(c->vecs.data() + static_cast<std::size_t>(slot) * cfg_.dim,
                vec.data(), static_cast<std::size_t>(cfg_.dim) * sizeof(float));
    c->ords[slot] = ord;
    c->levels[slot] = static_cast<std::uint8_t>(level);
    const std::size_t slots =
        (1 + cfg_.M * 2) + static_cast<std::size_t>(level) * (1 + cfg_.M);
    c->adj[slot] = new std::uint32_t[slots]();  // 零初始化,指针永不搬迁

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
    const float* q =
        c->vecs.data() + static_cast<std::size_t>(slot) * cfg_.dim;

    // 上层贪心下降到 level+1。
    for (std::int32_t l = max_level;
         l > static_cast<std::int32_t>(level); --l) {
        cur = greedy_closest(q, cur, static_cast<std::uint32_t>(l), n_bound,
                             scratch.data());
    }

    // 3) level..0:efConstruction 搜索 + 启发式选边 + 双向连边 + 邻居收缩。
    std::vector<std::pair<float, std::uint32_t>> found;
    for (std::int32_t l = std::min<std::int32_t>(
             static_cast<std::int32_t>(level), max_level);
         l >= 0; --l) {
        const auto lay = static_cast<std::uint32_t>(l);
        search_layer(q, cur, cfg_.ef_construction, lay, n_bound,
                     scratch.data(), found);
        cur = found.front().second;  // 下层入口 = 本层最近

        auto picked = found;
        select_neighbors(q, picked, cfg_.M);  // L0 也选 M 条,容量 2M 留收缩余量

        // 正向边:本节点已发布,读者可能在拷它的邻居 → 持自身锁写。
        {
            auto& my_lk = c->locks[slot];
            lock_node(my_lk);
            std::uint32_t* my = c->adj[slot] + layer_off(lay);
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
            std::uint32_t* nb = nc->adj[nslot] + layer_off(lay);
            const std::uint32_t cap = layer_cap(lay);
            if (nb[0] < cap) {
                nb[++nb[0]] = id;
            } else {
                // 收缩:旧邻居 + 新候选并集,以 nid 为查询点重选 cap 条。
                // 持锁做距离计算(微秒级临界区):读者只在 copy_neighbors
                // 短暂争同一把锁,实测可接受;arena/锁外预选留 V3.x。
                const float* nv = vec_of(nid);
                std::vector<std::pair<float, std::uint32_t>> pool;
                pool.reserve(cap + 1);
                for (std::uint32_t i = 1; i <= nb[0]; ++i) {
                    pool.push_back({dist_id(nv, nb[i]), nb[i]});
                }
                pool.push_back({dist_id(nv, id), id});
                std::sort(pool.begin(), pool.end());
                select_neighbors(nv, pool, cap);
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
    for (std::int32_t l = max_level; l > 0; --l) {
        cur = greedy_closest(q, cur, static_cast<std::uint32_t>(l), n,
                             scratch.data());
    }
    std::vector<std::pair<float, std::uint32_t>> found;
    search_layer(q, cur, ef, 0, n, scratch.data(), found);

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

}  // namespace bitcask::vec
