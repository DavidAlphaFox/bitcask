// HNSW 近似最近邻索引(V3.3:单写者 + 多读者;设计 doc/hnsw-design-zh.md §3)。
//
// === 算法参考文献 ===
// Malkov, Yashunin, "Efficient and robust approximate nearest neighbor search using
//   Hierarchical Navigable Small World graphs", arXiv:1603.09320, 2016; TPAMI 2018.
//   关键参数：M（邻居容量，上层 M，L0 层 2M），ef_construction（构建时搜索宽度），
//   mL = 1/ln(M)（层生成概率参数，控制图的高度与宽度 tradeoff）。
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
#include <string_view>
#include <vector>

#include "bitcask/detail/int8_kernels.hpp"

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
    // P5:int8-only 内存模式。true → NodeChunk 不存常驻 f32(vecs 容量 0),
    // 建图/查询全程 int8,向量内存 ~−80%。仅 kDot(int8 距离=重建内积);
    // kL2 不支持(上游 open 接线拒绝)。设计 doc/hnsw-int8-only-design-zh.md。
    bool          inmem_int8 = false;
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

    // ---- V3.5:重建用只读访问(merge 物理清死,SearchLayer::rebuild_hnsw)----
    // 前置:id < size()(已发布节点)。vec 的底层存储地址稳定(chunk 定容)。
    [[nodiscard]] std::uint64_t node_ord(std::uint32_t id) const {
        return ord_of(id);
    }
    // P5:int8-only 下无常驻 f32,反量化到 thread_local 缓冲返回(仅
    // rebuild_hnsw 单写者即时消费,下次调用前已被 insert 拷走)。
    [[nodiscard]] std::span<const float> node_vec(std::uint32_t id) const;

    // ---- V3.5:快照持久化(BCVS v1,设计 doc/hnsw-design-zh.md §5)----
    // 外壳与 BCKS/BCIS 同款:[magic "BCVS"][ver u32=1][payload][crc32(payload)],
    // tmp+rename 原子落盘。payload 存完整图(向量+邻接+entry)——重插的
    // 距离计算才是开库慢的大头,只存向量等于没省。
    //
    // save:线程安全(遵守读者协议:entry/count acquire 快照 + per-node 锁
    // 拷邻接,≥ 快照水位的邻居 id 一律滤掉)。落盘的 max_inserted_ord 取
    // **已保存节点的最大 ord**(= ord_of(n-1)),而非 max_inserted_ord_ 原子
    // ——后者在写者 mid-insert 时可能领先于 count 发布,照抄会让重开后的
    // 水位幂等错杀该文档的尾部回放。静止点(close/merge flush 后)两者相等。
    [[nodiscard]] bool save(std::string_view path) const;
    // P14e:序列化到字节缓冲(供 search.ckpt 分段嵌入);返回 false 同 save
    // 的"活跃 fold/不一致"放弃。盘字节与 save() 完全一致(自带 BCVS 框架)。
    [[nodiscard]] bool serialize(std::vector<std::uint8_t>& out) const;
    // load:仅 open 期单线程调用(空图上,不可与任何读写并发)。校验:
    // config(dim/metric/M)一致、邻居/entry id < count、level/cnt 不超容、
    // ord 严格递增、邻居层数覆盖(layer-l 表只允许 level ≥ l 的节点,防
    // copy_neighbors 越块读)——任何违例**整体拒绝**返回 false(本实例
    // 报废,调用方弃之换全量 fold;绝不半载示人)。
    [[nodiscard]] bool load(std::string_view path);
    // P14e:从字节缓冲反序列化(search.ckpt 段)。语义同 load:仅空图调用,
    // 任何校验违例整体拒绝返回 false。
    [[nodiscard]] bool deserialize(std::span<const std::uint8_t> bytes);

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
        // 每节点邻接块:内层 vector 构造时 resize(slots) 定容,此后 .data()
        // 地址永不搬迁,供并发读者经 count_ acquire 安全读取。
        std::vector<std::vector<std::uint32_t>> adj;
        std::unique_ptr<std::atomic<std::uint8_t>[]> locks;  // per-node 自旋

        // V4.2:int8 量化副本(对称量化,scale = max |v[i]|)。codes 是紧
        // 排 int8,scale/sum_codes 是每向量一个标量;load/insert 时写入,
        // 读者两阶段检索的粗筛直接读这段,4× 带宽缩减 + VNNI 指令提速。
        std::vector<std::int8_t>    qcodes;  // kChunkSize * dim
        std::vector<float>          qscales; // kChunkSize
        std::vector<std::int32_t>   qsums;   // kChunkSize(VNNI 偏置补偿)

        // P5:inmem_int8 时 vecs 容量 0(不存常驻 f32),只分配量化副本。
        NodeChunk(std::size_t dim, bool inmem_int8);
        ~NodeChunk() = default;
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
    // V4.2:量化副本访问器。两阶段检索的 int8 粗筛用,与 f32 路径并行
    // 而不互相干扰;QVector 的 sum_codes 由 quantize() 预算好供 VNNI 偏置
    // 补偿。
    [[nodiscard]] const std::int8_t* qcodes_of(std::uint32_t id) const {
        const NodeChunk* c = chunk_of(id);
        return c->qcodes.data() +
               static_cast<std::size_t>(id & kChunkMask) * cfg_.dim;
    }
    [[nodiscard]] float qscale_of(std::uint32_t id) const {
        return chunk_of(id)->qscales[id & kChunkMask];
    }
    [[nodiscard]] std::int32_t qsum_of(std::uint32_t id) const {
        return chunk_of(id)->qsums[id & kChunkMask];
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

    // V4.2:int8 粗筛距离。与 f32 路径同"越小越近"约定(VNNI 内核返回
    // 正的重建内积,kDot 语义下取负)。查询侧 codes/scale/sum 由调用方
    // 预算好(quantize() 一次性),db 侧三个标量由 qcodes_of/qscale_of/
    // qsum_of 读取。
    [[nodiscard]] float dist_id_int8(const std::int8_t* query_codes,
                                     float query_scale,
                                     [[maybe_unused]] std::int32_t query_sum,
                                     std::uint32_t id) const {
        const float d = int8_dot_(
            query_codes, qcodes_of(id),
            qsum_of(id), query_scale, qscale_of(id), cfg_.dim);
        return -d;
    }

    // P5:两个已存节点间的 int8 距离(int8-only 建图选边/收缩用,无 f32)。
    // 与 dist_id_int8 同约定"越小越近"(kDot:取重建内积的负)。
    [[nodiscard]] float dist_id_int8_node(std::uint32_t a,
                                          std::uint32_t b) const {
        const float d = int8_dot_(qcodes_of(a), qcodes_of(b), qsum_of(b),
                                  qscale_of(a), qscale_of(b), cfg_.dim);
        return -d;
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

    // V4.2:int8 粗筛版贪心下降,供两阶段 search() 在上层调用。
    [[nodiscard]] std::uint32_t greedy_closest_int8(
        const std::int8_t* query_codes, float query_scale,
        std::int32_t query_sum, std::uint32_t start, std::uint32_t layer,
        std::uint32_t n, std::uint32_t* scratch) const;

    // 标准 search-layer:返回 ≤ef 个 (dist,id),按 dist 升序。
    void search_layer(const float* q, std::uint32_t entry, std::size_t ef,
                      std::uint32_t layer, std::uint32_t n,
                      std::uint32_t* scratch,
                      std::vector<std::pair<float, std::uint32_t>>& out) const;

    // V4.2:int8 粗筛版 search-layer,与 f32 版同结构,只换距离函数。
    void search_layer_int8(const std::int8_t* query_codes, float query_scale,
                           std::int32_t query_sum, std::uint32_t entry,
                           std::size_t ef, std::uint32_t layer, std::uint32_t n,
                           std::uint32_t* scratch,
                           std::vector<std::pair<float, std::uint32_t>>& out) const;

    // 邻居选择启发式(HNSW 论文 Algorithm 4):候选若离 query 比离任一
    // 已选邻居更近才保留——避免聚簇数据上邻居全挤在同一方向。
    void select_neighbors(
        const float* q,
        std::vector<std::pair<float, std::uint32_t>>& cands,
        std::uint32_t m) const;

    // P5:int8-only 版选边启发式。候选 dist(到 query)已预算在 pair 里;
    // 候选-已选比较走 dist_id_int8_node(两节点皆有量化副本)。
    void select_neighbors_int8(
        std::vector<std::pair<float, std::uint32_t>>& cands,
        std::uint32_t m) const;

    HnswConfig cfg_;
    DistFn dist_;                       // 构造时按 metric+ISA 分发一次
    int8::Int8DotFn int8_dot_;          // V4.2:int8 粗筛内核;无 VNNI 时 nullptr
    double inv_log_m_;                  // mL = 1/ln(M)
    std::uint64_t instance_id_;         // thread_local visited 的实例区分键

    // chunk 目录:定容,写者 store-release 安装、读者 load-acquire 读取。
    // 必须保持裸指针 + atomic<NodeChunk*>:这是无锁发布协议的核心——
    // shared_ptr 的原子引用计数开销不可接受(每次 search 都 load)。
    // 析构由 ~HnswIndex() 单线程 delete,此时无并发读者。
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
