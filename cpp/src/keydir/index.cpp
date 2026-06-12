#include "bitcask/index.hpp"

#include <algorithm>

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#endif

namespace bitcask::index {

namespace {

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
// Tier-2 SIMD:fill_is_live 快路径 4 ords 一组,AVX2 vpgatherdq
// (_mm256_i64gather_epi64) 一次取 __m256i 索引(8 × 64-bit)但仅消费
// 低 4 个索引、返 4 × 64-bit 值(__m256i 高 128 bit 是无定义垃圾,绝不读)。
// 每轮 4 ords = 1 gather;低 lane 提取低字节写入 out。
// 注:LTO 模式下 _mm256_extract_epi64 会被拆成对 _mm256_extractf128_si256
// 的非立即数调用失败,故走 store + 数组索引(编译为 vmovq)。
__attribute__((target("avx2")))
__attribute__((noinline))
inline void fill_is_live_inbounds_avx2(const std::uint8_t* live_arr,
                                       const std::uint64_t* ords,
                                       char* out, std::size_t n) noexcept {
    std::size_t i = 0;
    alignas(32) std::uint64_t lanes[4];
    for (; i + 4 <= n; i += 4) {
        __m256i idx = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(ords + i));
        __m256i b = _mm256_i64gather_epi64(
            reinterpret_cast<const long long*>(live_arr), idx, 1);
        _mm256_store_si256(reinterpret_cast<__m256i*>(lanes), b);
        out[i + 0] = static_cast<char>(lanes[0] & 0xFF);
        out[i + 1] = static_cast<char>(lanes[1] & 0xFF);
        out[i + 2] = static_cast<char>(lanes[2] & 0xFF);
        out[i + 3] = static_cast<char>(lanes[3] & 0xFF);
    }
    for (; i < n; ++i) out[i] = static_cast<char>(live_arr[ords[i]]);
}
#endif

}

void Index::ensure_capacity_locked(std::uint64_t ord) {
    // ord 是数组下标，需要 size >= ord+1。
    const std::size_t want = static_cast<std::size_t>(ord) + 1;
    if (slots_.size() < want) {
        slots_.resize(want);
        ord2ext_.resize(want);
        live_.resize(want, false);
        doc_lens_.resize(want, 0);
    }
}

std::uint64_t Index::alloc_ord() {
    std::unique_lock lk(mutex_);
    return next_ord_++;
}

void Index::put_doc(std::string_view ext_id, std::uint64_t ord,
                    const DocSlot& slot) {
    std::unique_lock lk(mutex_);

    // 恢复路径用磁盘上的 ord 直接登记，需把分配器推到其后。
    next_ord_ = std::max(next_ord_, ord + 1);
    ensure_capacity_locked(ord);

    // update：ext_id 已存在 → 旧 ord 软删。
    if (auto it = ext2ord_.find(ext_id); it != ext2ord_.end()) {
        const std::uint64_t old_ord = it->second;
        if (old_ord < live_.size() && live_[old_ord]) {
            live_[old_ord] = false;  // 旧版本退出存活集；live_docs_ 不变（同一文档）
        }
        it->second = ord;
    } else {
        ext2ord_.emplace(std::string(ext_id), ord);
        ++live_docs_;
    }

    slots_[ord]    = slot;
    doc_lens_[ord] = slot.doc_len;  // P2.4：SoA 副本同步写
    ord2ext_[ord].assign(ext_id);
    live_[ord]     = true;
}

bool Index::remove(std::string_view ext_id, std::uint64_t tomb_ord) {
    std::unique_lock lk(mutex_);

    next_ord_ = std::max(next_ord_, tomb_ord + 1);

    auto it = ext2ord_.find(ext_id);
    if (it == ext2ord_.end()) {
        return false;  // 本就不存在（重复删 / 删未知 key）
    }
    const std::uint64_t cur_ord = it->second;
    if (cur_ord < live_.size() && live_[cur_ord]) {
        live_[cur_ord] = false;
    }
    ext2ord_.erase(it);
    --live_docs_;
    return true;
}

std::optional<DocSlot> Index::get(std::string_view ext_id) const {
    std::shared_lock lk(mutex_);
    auto it = ext2ord_.find(ext_id);
    if (it == ext2ord_.end()) {
        return std::nullopt;
    }
    const std::uint64_t ord = it->second;
    // ext2ord 指向的 ord 必然存活（删除时已 erase），这里直接返回 slot。
    DocSlot s = slots_[ord];
    s.ord = ord;   // 让 caller（如 SearchLayer::on_delete）拿到 ord，无需另查
    return s;
}

std::optional<std::string> Index::ord_to_ext(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    if (ord >= ord2ext_.size()) {
        return std::nullopt;
    }
    return ord2ext_[ord];
}

bool Index::is_live(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    return ord < live_.size() && live_[ord];
}

std::uint32_t Index::doc_len(std::uint64_t ord) const {
    std::shared_lock lk(mutex_);
    if (ord >= doc_lens_.size()) return 0;
    return doc_lens_[ord];
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2")))
#endif
void Index::fill_is_live(std::span<const std::uint64_t> ords,
                         std::span<char> out) const {
    std::shared_lock lk(mutex_);
    const std::size_t bound = live_.size();
    // 快路径:FlatPostings ords 升序去重 → ords.back() < bound ⟺ 全在界,
    // 单次比较省掉 per-element 分支。占绝大多数查询(recents)。
    if (!ords.empty() && ords.back() < bound) {
        const auto* live_arr = live_.data();
        const auto* ords_arr = ords.data();
        char* out_arr = out.data();
        const std::size_t n = ords.size();
        std::size_t i = 0;
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
        if (__builtin_cpu_supports("avx2")) {
            fill_is_live_inbounds_avx2(live_arr, ords_arr, out_arr, n);
            return;
        }
#endif
        for (; i < n; ++i) out_arr[i] = static_cast<char>(live_arr[ords_arr[i]]);
        return;
    }
    // 慢路径:含越界或ds → per-element 越界检查。
    for (std::size_t i = 0; i < ords.size(); ++i) {
        out[i] = static_cast<char>(ords[i] < bound && live_[ords[i]]);
    }
}

#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2")))
#endif
void Index::fill_doc_lens(std::span<const std::uint64_t> ords,
                          std::span<std::uint32_t> out) const {
    std::shared_lock lk(mutex_);
    // P2.4：读 SoA 紧凑数组（gather 的 cache 流量 ↓8x，见 index.hpp 注释）。
    const std::size_t bound = doc_lens_.size();
    // 同 fill_is_live:ords 升序去重 → ords.back() < bound 全在界。
    if (!ords.empty() && ords.back() < bound) {
        const auto* dls_arr = doc_lens_.data();
        const auto* ords_arr = ords.data();
        auto* out_arr = out.data();
        const std::size_t n = ords.size();
        std::size_t i = 0;
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
        // AVX2 vpgatherqd(_mm256_i64gather_epi32) 一次取 8 个 64-bit 索引
        // 但仅消费低 4 个、返 4 个 32-bit 值(__m128i)。每轮 4 ords 一次
        // gather;高 4 索引通过 lane shift 喂下一轮。
        if (__builtin_cpu_supports("avx2")) {
            for (; i + 4 <= n; i += 4) {
                __m256i idx = _mm256_loadu_si256(
                    reinterpret_cast<const __m256i*>(ords_arr + i));
                __m128i v = _mm256_i64gather_epi32(
                    reinterpret_cast<const int*>(dls_arr), idx, 4);
                _mm_storeu_si128(
                    reinterpret_cast<__m128i*>(out_arr + i), v);
            }
        }
#endif
        for (; i < n; ++i) out_arr[i] = dls_arr[ords_arr[i]];
        return;
    }
    for (std::size_t i = 0; i < ords.size(); ++i) {
        out[i] = ords[i] < bound ? doc_lens_[ords[i]] : 0;
    }
}

IndexInfo Index::info() const {
    std::shared_lock lk(mutex_);
    return IndexInfo{
        .live_docs  = live_docs_,
        .total_ords = next_ord_,
        .next_ord   = next_ord_,
    };
}

}  // namespace bitcask::index
