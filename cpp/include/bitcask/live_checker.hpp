// LiveChecker — 倒排索引查询时过滤已死 ord 的回调接口。
//
// Index (bitcask::index) 实现此接口，InvertedIndex::search 通过它跳过
// 已软删的文档。提取为独立头是为了让 index.hpp 不必 include 整个
// inverted.hpp（BM25 内部实现）仅为了继承一个接口。
//
// ⚠️ v5 不变量:doc_len(ord) 必须等于该文档 add_doc 时的 Σtf
// (SearchLayer 两者同源自同一次分词,天然成立)。块级分数上界用
// 索引时 min_dl 收紧——若自定义实现返回比索引时更小的 doc_len,
// 上界不再 admissible,BMW 剪枝可能漏掉真 top-k(测试用 checker
// 必须按此约定构造)。

#pragma once

#include <cstdint>
#include <span>

namespace bitcask::bm25 {

class LiveChecker {
public:
    virtual ~LiveChecker() = default;
    [[nodiscard]] virtual bool is_live(std::uint64_t ord) const = 0;
    [[nodiscard]] virtual std::uint32_t doc_len(std::uint64_t ord) const = 0;

    // P2.1 批量接口。评分循环逐 posting 各调一次 is_live/doc_len 有两重代价：
    // ① 虚调用阻断编译器对评分浮点循环的自动向量化（实测 LTO 后二进制
    //    packed float 指令为 0）；
    // ② Index 实现每次调用拿一次 shared_lock——10 万 posting 的热词一次
    //    查询 = 约 20 万次锁操作。
    // 批量版本一次虚调用 + （实现侧）一次锁完成整个数组。默认实现退化为
    // 逐个调用，外部实现者无需改动；Index 覆写为持锁数组直读。
    // 要求 out.size() == ords.size()。
    virtual void fill_is_live(std::span<const std::uint64_t> ords,
                              std::span<char> out) const {
        for (std::size_t i = 0; i < ords.size(); ++i) {
            out[i] = static_cast<char>(is_live(ords[i]));
        }
    }
    virtual void fill_doc_lens(std::span<const std::uint64_t> ords,
                               std::span<std::uint32_t> out) const {
        for (std::size_t i = 0; i < ords.size(); ++i) {
            out[i] = doc_len(ords[i]);
        }
    }
};

}  // namespace bitcask::bm25
