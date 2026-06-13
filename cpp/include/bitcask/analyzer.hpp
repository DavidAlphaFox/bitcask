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
#include <vector>

namespace bitcask::text {

// 分词结果类型：term → 词频。
using TermFreqMap = std::unordered_map<std::string, std::uint32_t>;
using TermPositionsMap = std::unordered_map<std::string, std::pair<std::uint32_t, std::vector<std::uint32_t>>>;

// 分词结果：包含位置和字节偏移。
struct TokenInfo {
    std::uint32_t position;    // 词在文本中的位置序号（从 0 开始）
    std::uint32_t start_byte;   // token 在原文中的起始字节偏移
    std::uint32_t end_byte;    // token 在原文中的结束字节偏移（不含）
};

// analyze_with_offsets 返回每个 token 的详细信息。
// 返回值：unordered_map<term, vector<TokenInfo>>
using TermTokenMap = std::unordered_map<std::string, std::vector<TokenInfo>>;

// --------------------------------------------------------------------------
// 分词器类型枚举。
// 新增分词方案时在此添加枚举值 + 工厂分支 + 对应 Analyzer 子类。
// --------------------------------------------------------------------------
enum class AnalyzerType {
    Ngram,        // CJK 字符级 n-gram + 拉丁空白切分（默认，V2.1）
    Whitespace,   // 纯空白切分（调试 / 纯拉丁场景）
    Jieba,        // jieba 词典分词 + CutForSearch + CJK 回退 n-gram（V2.10）
};

// --------------------------------------------------------------------------
// 分词器配置。
// 工厂根据 type 创建对应子类，其余字段按 type 解读（Ngram 用 min_n/max_n，
// 词典类以后加 dict_path 等）。
// --------------------------------------------------------------------------
struct AnalyzerConfig {
    AnalyzerType  type  = AnalyzerType::Ngram;
    std::uint32_t min_n = 2;
    std::uint32_t max_n = 3;
    bool enable_stop_words = false;                  // 启用停用词过滤
    std::vector<std::string> stop_words;             // 自定义停用词表（空则用内置默认）
    std::string dict_path;                           // jieba 词典目录；必须有效，由调用方（Erlang facade 默认填 priv/dict）保证
    // 拉丁整词的最小 codepoint 长度（S9.8）：短于此的拉丁 token 被丢弃。
    // 仅作用于拉丁/空白切分的整词路径，CJK 的 n-gram 不受影响。
    // 默认 1 = 不过滤（向后兼容）。索引与查询两侧一致生效。
    std::uint32_t min_token_length = 1;
    // 英文词干提取（S8.1）：对各分词结果做 Porter 词干化处理。"running" → "run"。默认关闭。
    bool enable_stemming = false;
};

// --------------------------------------------------------------------------
// 分词器抽象基类。
//
// 职责：将一段 UTF-8 文本拆成 {term → tf} 映射，供 BM25 倒排索引消费。
// 写入（upsert）和查询（search_text）走同一条 analyze 管线。
//
// 生命周期：Analyzer 实例由 AnalyzerFactory 创建，进程级单例。
// --------------------------------------------------------------------------
class Analyzer {
public:
    virtual ~Analyzer() = default;

    // Template Method：默认实现从 analyze_with_positions 派生 TermFreqMap。
    // 子类只需实现 analyze_with_positions，无需重复 analyze() 的转换逻辑。
    // （StemmingAnalyzer 覆写此方法以加入词干化。）
    [[nodiscard]] virtual auto analyze(std::string_view text) const
        -> TermFreqMap;

    [[nodiscard]] virtual auto analyze_with_positions(std::string_view text) const
        -> TermPositionsMap = 0;

    [[nodiscard]] virtual auto analyze_with_offsets(std::string_view text) const
        -> TermTokenMap;

    [[nodiscard]] virtual auto type() const noexcept -> AnalyzerType = 0;
};

// --------------------------------------------------------------------------
// 分词器抽象工厂（注册表模式）。
//
// 新增分词方案时只需：
//   1. 在 AnalyzerType 增加枚举值
//   2. 编写新的 Analyzer 子类
//   3. 在子类的 .cpp 中调 AnalyzerFactory::register_creator 注册
// 无需修改工厂本身——对扩展开放，对修改关闭（OCP）。
// --------------------------------------------------------------------------
// 创建器签名：根据 AnalyzerConfig 构造一个 Analyzer 实例。
using AnalyzerCreator = std::unique_ptr<Analyzer>(*)(const AnalyzerConfig&);

class AnalyzerFactory {
public:
    // 注册创建器。各子类在自身 .cpp 的 static init 期间调用。
    static void register_creator(AnalyzerType type, AnalyzerCreator creator);

    // 根据配置创建分词器实例。配置不合法时返回 nullptr。
    [[nodiscard]] static auto create(const AnalyzerConfig& config)
        -> std::unique_ptr<Analyzer>;
};

}  // namespace bitcask::text
