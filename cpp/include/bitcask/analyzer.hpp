// 文本分词器抽象基类 + 抽象工厂。
//
// 定义 bitcask::text 命名空间下的 Analyzer 接口与 AnalyzerFactory。
// V2.1 提供 NgramAnalyzer（CJK bi/tri-gram + 拉丁空白切分），后续可插拔
// jieba / IK 等词典分词器——只需新增 Analyzer 子类并在工厂注册。
//
// 设计决策（doc/vector-db-design-zh.md §3.2 / §9）：
//   - n-gram 方案：中文为主，字符级 bi/tri-gram，不依赖分词器。
//   - 归一化管线：NFKC → CJK 检测 → n-gram / 空白切分 → 小写。
//   - 分词结果：term → tf（词频）映射，直接供 BM25 倒排消费。
//
// === 工厂使用 ===
//   auto a = AnalyzerFactory::create(AnalyzerConfig{
//       .type = AnalyzerType::Ngram,
//       .min_n = 2, .max_n = 3,
//   });
//   auto tfs = a->analyze("北京市朝阳区");

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>

namespace bitcask::text {

// 分词结果类型：term → 词频。
using TermFreqMap = std::unordered_map<std::string, std::uint32_t>;

// --------------------------------------------------------------------------
// 分词器类型枚举。
// 新增分词方案时在此添加枚举值 + 工厂分支 + 对应 Analyzer 子类。
// --------------------------------------------------------------------------
enum class AnalyzerType {
    Ngram,        // CJK 字符级 n-gram + 拉丁空白切分（默认，V2.1）
    Whitespace,   // 纯空白切分（调试 / 纯拉丁场景）
};

// --------------------------------------------------------------------------
// 分词器配置。
// 工厂根据 type 创建对应子类，其余字段按 type 解读（Ngram 用 min_n/max_n，
// 词典类以后加 dict_path 等）。
// --------------------------------------------------------------------------
struct AnalyzerConfig {
    AnalyzerType  type  = AnalyzerType::Ngram;
    std::uint32_t min_n = 2;   // n-gram 最小字符数（仅 Ngram 类型使用）
    std::uint32_t max_n = 3;   // n-gram 最大字符数（仅 Ngram 类型使用）
    // 后续可扩展：
    // std::string dict_path;   // 词典路径（jieba / IK 等）
    // std::vector<std::string> stop_words;  // 停用词表
};

// --------------------------------------------------------------------------
// 分词器抽象基类。
//
// 职责：将一段 UTF-8 文本拆成 {term → tf} 映射，供 BM25 倒排索引消费。
// 写入（upsert）和查询（search_text）走同一条 analyze 管线。
//
// 生命周期：Analyzer 实例由 AnalyzerFactory 创建，归 Collection 持有，
// 进程级单例（一个 collection 一个 analyzer）。
// --------------------------------------------------------------------------
class Analyzer {
public:
    virtual ~Analyzer() = default;

    // 对文本进行分词，返回 term → 词频映射。
    // 输入必须是合法 UTF-8；非法字节作为孤立字节处理（不崩溃）。
    // 线程安全：是（实现保证无可变共享状态）。
    [[nodiscard]] virtual auto analyze(std::string_view text) const
        -> TermFreqMap = 0;

    // 返回分词器类型标识（用于调试/序列化）。
    [[nodiscard]] virtual auto type() const noexcept -> AnalyzerType = 0;
};

// --------------------------------------------------------------------------
// 分词器抽象工厂。
//
// 根据配置创建对应 Analyzer 子类实例。新增分词方案时只需：
//   1. 在 AnalyzerType 增加枚举值
//   2. 编写新的 Analyzer 子类
//   3. 在 create() 增加分支
// --------------------------------------------------------------------------
class AnalyzerFactory {
public:
    // 根据配置创建分词器实例。配置不合法时返回 nullptr。
    [[nodiscard]] static auto create(const AnalyzerConfig& config)
        -> std::unique_ptr<Analyzer>;
};

}  // namespace bitcask::text
