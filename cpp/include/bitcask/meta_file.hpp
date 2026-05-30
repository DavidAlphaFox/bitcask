// bitcask.meta 文件管理：创建/读取 bitcask.meta 二进制格式。
//
// 格式（18 bytes）：
//   [0..3]   Magic     "BCME" (4 bytes)
//   [4]      Version   uint8 = 1
//   [5]      Mode      uint8 = 0(KV) or 1(Index)
//   [6..17]  Reserved  12 bytes zeros（future use）
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

// bitcask.meta 配置内容（当前仅含模式字段）
struct MetaConfig {
    Mode mode = Mode::kKV;
    // Phase 4 会加入 analyzer_type, bm25_params, dict_path 等
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