// bitcask.meta 文件管理：创建/读取 bitcask.meta 二进制格式。
//
// 格式（18 bytes）：
//   [0..3]   Magic     "BCME" (4 bytes)
//   [4]      Version   uint8 = 1
//   [5]      Mode      uint8 = 0(KV) or 1(Index)
//   [6]      VecMetric uint8 (V3.1)
//   [7..8]   VecDim    uint16 LE (V3.1)
//   [9]      VecQuant  uint8 = 0/1（P3b：向量落盘 int8 量化；旧文件全零=否）
//   [10..17] Reserved  8 bytes zeros（future use）
//
// === 线程模型 ===
// 所有函数均为纯函数：线程安全、可重入、无锁。

#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <expected>

namespace bitcask::meta {

// 运行模式：KV 纯存储 或 索引模式（BM25 搜索）
enum class Mode : std::uint8_t {
    kKV = 0,       // 纯 KV 模式
    kIndex = 1,    // 索引模式（BM25 搜索）
};

// V3.1:向量距离度量。kNone = 本集合无向量(旧 meta 的保留区全零
// 自然解码为此值,无需版本升级)。
enum class VectorMetric : std::uint8_t {
    kNone = 0,
    kCosineNormalized = 1,   // 写入时归一化,查询用内积(默认推荐)
    kL2 = 2,
    kDot = 3,
};

// bitcask.meta 配置内容。
// V3.1:vector 配置占用原保留区 [6]=metric、[7..8]=dim(LE u16)——
// 库内 dim 恒定、初始化显式配置、重开校验(hnsw-design §1)。
struct MetaConfig {
    Mode mode = Mode::kKV;
    VectorMetric vector_metric = VectorMetric::kNone;
    std::uint16_t vector_dim = 0;   // 0 = 无向量
    bool vector_quantized = false;  // P3b：向量落盘 int8 量化（仅 vector_dim>0 有意义）
    bool vector_inmem_int8 = false; // P5b：HNSW int8-only 内存模式（仅 vector_dim>0 + kDot）
};

// meta 文件操作错误
struct MetaError {
    int errnum = 0;
    std::string message;
};

// 检查 meta 文件是否存在
[[nodiscard]] bool meta_exists(std::string_view dirname);

// 读取 meta 文件
//   - 文件不存在返回错误
//   - magic 不对返回错误
//   - version 非 1 返回错误
//   - 成功返回 MetaConfig
[[nodiscard]] std::expected<MetaConfig, MetaError> read_meta(std::string_view dirname);

// 写入 meta 文件
//   - 创建/覆盖 dirname/bitcask.meta
//   - 成功返回空，失败返回错误
[[nodiscard]] std::expected<void, MetaError> write_meta(std::string_view dirname, const MetaConfig& config);

}  // namespace bitcask::meta