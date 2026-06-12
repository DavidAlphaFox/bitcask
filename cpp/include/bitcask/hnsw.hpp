// HNSW 近似最近邻索引(V3.3:单写者 + 多读者;设计 doc/hnsw-design-zh.md §3)。
//
// 边界(§1):只收向量不算向量;dim 库内恒定(构造时定);cosine 由上游
// 写入归一化 → 本模块只见 kDot/kL2 两种度量。
//
// === 结构(§2)===
//   - 内部节点 id:u32 插入序紧凑分配;ords 翻译回 ord。
//   - 存储分段 chunk(kChunkBits=16 → 65536 节点/chunk):chunk 内
//     vecs/ords/levels/adj 指针/per-node 自旋锁全部定容预分配,地址稳定。
//   - chunk 目录:定容 std::array<std::atomic<NodeChunk*>, kMaxChunks>,
//     写者安装(release)、读者 load(acquire)——绝不用会搬迁的 vector。
//   - 每节点邻接块 insert 时按层数一次性 new u32[] 零初始化,指针进
//     adj 后永不搬迁(arena 化留 V3.x)。层内布局 [count][ids...],
//     L0 容量 2M、上层 M。
//
// === 并发协议(V3.3,§3)===
//   单写者(IndexPool worker)+ 多读者(查询线程);**多写者不支持**
//   (insert 内有 debug assert 声明)。
//   - count_ 发布序:写满本节点数据(vec/ord/level/空邻接块)→
//     count_.store(id+1, release) → 再做连边。读者以自己 load 的 count
//     为可见边界;邻接里可能出现 >= 该边界的 id(发布后才追加的反向边),
//     读侧一律跳过——visited 数组按本地 count 定界即安全。
//   - per-node 自旋锁(1 字节):写者改某节点邻接(正向写入/反向追加/
//     超容收缩)持该节点锁;读者读某节点邻居前持同一把锁把 [count][ids]
//     拷到栈缓冲再放锁遍历。临界区 ~百 ns(收缩路径微秒级,可接受)。
//   - entry_point/max_level 合并单 atomic u64:高 32 位 = level+1
//     (0 表示空图),低 32 位 = id;insert 完整连边后才更新。search
//     开头先 load entry_meta_(acquire)再 load count_——entry 发布
//     happens-after count 发布,故 entry id 必 < 本地 count。
//   - visited 标记:thread_local 版本化数组(实现注释见 .cpp)。
//
// === 删除 ===
//   本模块不感知删除;上层经 live 过滤回调在结果侧滤死,死节点留作
//   图内路标,merge 重建时物理清除。

#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <random>
#include <span>
#include <vector>

namespace bitcask::vec {

enum class HnswMetric : std::uint8_t {
    kDot = 0,  // 内积相似度(cosine_normalized 上游已归一化)
    kL2  = 1,  // 平方欧氏距离
};

struct HnswConfig {
    std::uint16_t dim = 0;
    HnswMetric    metric = HnswMetric::kDot;
    std::uint32_t M = 16;                 // 上层邻居容量;L0 = 2M
    std::uint32_t ef_construction = 200;
    std::uint64_t seed = 0x5EEDF00D;      // 层数抽样种子(测试可复现)
};

class HnswIndex {
public:
    explicit HnswIndex(const HnswConfig& cfg);
    ~HnswIndex();

    HnswIndex(const HnswIndex&) = delete;
    HnswIndex& operator=(const HnswIndex&) = delete;

    // 插入(仅单写者线程)。前置:vec.size()==dim;ord 全局单调。
    // 水位幂等:ord <= max_inserted_ord_ 时丢弃(崩溃回放重叠区安全,
    // 与 InvertedIndex::add_doc 同协议)。
    void insert(std::uint64_t ord, std::span<const float> vec);

    struct Hit {
        std::uint64_t ord;
        float score;   // kDot:内积(越大越近);kL2:-平方距离(同向比较)
    };
    // 查询 top-k。线程安全(多读者,可与单写者 insert 并发)。
    // ef >= k(内部取 max);live 非空时结果侧过滤(死节点仍参与导航)。
    [[nodiscard]] std::vector<Hit> search(
        std::span<const float> query, std::size_t k, std::size_t ef,
        const std::function<bool(std::uint64_t)>* live = nullptr) const;

    [[nodiscard]] std::size_t size() const noexcept {
        return count_.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool empty() const noexcept { return size() == 0; }
    [[nodiscard]] std::uint64_t max_inserted_ord() const noexcept {
        return max_inserted_ord_.load(std::memory_order_relaxed);
    }
    [[nodiscard]] const HnswConfig& config() const noexcept { return cfg_; }

private:
    static constexpr std::uint32_t kChunkBits = 16;
    static constexpr std::uint32_t kChunkSize = 1u << kChunkBits;
    static constexpr std::uint32_t kChunkMask = kChunkSize - 1;
    static constexpr std::size_t   kMaxChunks = 1024;  // 上限 64M 节点

    // 节点分段存储:全部成员构造时定容,生命周期内地址稳定。
    struct NodeChunk {
        std::vector<float>          vecs;    // kChunkSize * dim
        std::vector<std::uint64_t>  ords;
        std::vector<std::uint8_t>   levels;
        std::vector<std::uint32_t*> adj;     // 每节点邻接块首指针,永不搬迁
        std::unique_ptr<std::atomic<std::uint8_t>[]> locks;  // per-node 自旋

        explicit NodeChunk(std::size_t dim);
        ~NodeChunk();
        NodeChunk(const NodeChunk&) = delete;
        NodeChunk& operator=(const NodeChunk&) = delete;
    };

    using DistFn = float (*)(const float*, const float*, std::size_t);

    [[nodiscard]] NodeChunk* chunk_of(std::uint32_t id) const {
        return chunks_[id >> kChunkBits].load(std::memory_order_acquire);
    }
    [[nodiscard]] const float* vec_of(std::uint32_t id) const {
        const NodeChunk* c = chunk_of(id);
        return c->vecs.data() +
               static_cast<std::size_t>(id & kChunkMask) * cfg_.dim;
    }
    [[nodiscard]] std::uint64_t ord_of(std::uint32_t id) const {
        return chunk_of(id)->ords[id & kChunkMask];
    }
    [[nodiscard]] std::uint32_t layer_cap(std::uint32_t layer) const {
        return layer == 0 ? cfg_.M * 2 : cfg_.M;
    }
    // 邻接块内某层的起始偏移(L0: 1+2M 槽,上层各 1+M 槽)。
    [[nodiscard]] std::size_t layer_off(std::uint32_t layer) const {
        return layer == 0
                   ? 0
                   : (1 + cfg_.M * 2) +
                         static_cast<std::size_t>(layer - 1) * (1 + cfg_.M);
    }

    [[nodiscard]] float dist_id(const float* q, std::uint32_t id) const {
        return dist_(q, vec_of(id), cfg_.dim);
    }

    // 读者协议:持 id 的自旋锁把 layer 层邻居拷入 out(容量 ≥ 2M),
    // 返回个数。
    std::uint32_t copy_neighbors(std::uint32_t id, std::uint32_t layer,
                                 std::uint32_t* out) const;

    // 贪心单步:在 layer 上从 start 走到局部最优。n = 调用方的 count 快照
    // (邻接里 >= n 的 id 一律跳过);scratch 为邻居拷贝缓冲(容量 ≥ 2M)。
    [[nodiscard]] std::uint32_t greedy_closest(const float* q,
                                               std::uint32_t start,
                                               std::uint32_t layer,
                                               std::uint32_t n,
                                               std::uint32_t* scratch) const;

    // 标准 search-layer:返回 ≤ef 个 (dist,id),按 dist 升序。
    void search_layer(const float* q, std::uint32_t entry, std::size_t ef,
                      std::uint32_t layer, std::uint32_t n,
                      std::uint32_t* scratch,
                      std::vector<std::pair<float, std::uint32_t>>& out) const;

    // 邻居选择启发式(HNSW 论文 Algorithm 4):候选若离 query 比离任一
    // 已选邻居更近才保留——避免聚簇数据上邻居全挤在同一方向。
    void select_neighbors(
        const float* q,
        std::vector<std::pair<float, std::uint32_t>>& cands,
        std::uint32_t m) const;

    HnswConfig cfg_;
    DistFn dist_;                       // 构造时按 metric+ISA 分发一次
    double inv_log_m_;                  // mL = 1/ln(M)
    std::uint64_t instance_id_;         // thread_local visited 的实例区分键

    // chunk 目录:定容,写者安装、读者 load。
    std::array<std::atomic<NodeChunk*>, kMaxChunks> chunks_{};
    std::atomic<std::uint32_t> count_{0};        // 发布水位(节点数)
    // 高 32 位 = max_level+1(0 表示空图),低 32 位 = entry id。
    std::atomic<std::uint64_t> entry_meta_{0};
    std::atomic<std::uint64_t> max_inserted_ord_{
        static_cast<std::uint64_t>(-1)};
    std::mt19937_64 rng_;               // 仅写者使用

    // 单写者声明用守卫(assert 仅 debug 生效;成员无条件存在,避免
    // NDEBUG 不一致的 TU 间布局分歧)。
    std::atomic<bool> writer_active_{false};
};

}  // namespace bitcask::vec
