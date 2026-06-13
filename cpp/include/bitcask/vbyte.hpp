// VByte 变长字节编码（Variable Byte Encoding / Varint）。
// Williams & Zobel 1999, "Compressing integers for fast file access".
// 每个字节低 7 位为数据，最高位为延续标记（1=最后一个字节，0=还有更多）。
//
// 编码示例：
//   encode(127) → [0xFF]           // 1 byte：127 < 128，最高位设 1 表示结束
//   encode(128) → [0x00, 0x01]     // 2 bytes：128 >= 128，先输出低 7 位 0x00，继续
//   encode(300) → [0xAC, 0x02]     // 2 bytes：300 = 44*7 + 0xAC(172)，44 = 0x01<<(7-1)
//
// 差值编码（Gap Encoding）：
//   对已排序的 ord 列表应用差分编码后再 VByte 压缩——相邻 ord 的差值通常远小于
//   绝对值，压缩率显著提升。
//   输入：sorted ords [3, 7, 15, 20]（升序）
//   差值：[3, 4, 8, 5]（第一个是绝对值，后续是相邻ord的差）
//   VByte([3, 4, 8, 5]) → 压缩字节序列

#pragma once

#include <cstdint>
#include <vector>
#include <cstddef>

namespace bitcask::codec {

// VByte 编码：将无符号整数压缩为变长字节序列，追加到 buf 末尾。
// val 必须为无符号整数。
inline void vbyte_encode(std::uint64_t val, std::vector<std::uint8_t>& buf) {
    while (val >= 128) {
        buf.push_back(static_cast<std::uint8_t>(val & 0x7F));
        val >>= 7;
    }
    buf.push_back(static_cast<std::uint8_t>(val | 0x80));
}

// VByte 解码：从 data[pos] 开始读取一个 VByte 编码的无符号整数。
// 返回 {解码值, 新位置}。
inline std::pair<std::uint64_t, std::size_t> vbyte_decode(const std::uint8_t* data, std::size_t pos) {
    std::uint64_t result = 0;
    std::uint64_t shift = 0;
    while (true) {
        auto byte = data[pos++];
        result |= static_cast<std::uint64_t>(byte & 0x7F) << shift;
        if (byte & 0x80) break;  // 最高位为 1 表示最后一个字节
        shift += 7;
    }
    return {result, pos};
}

// Gap 编码：对已排序的 ord 数组做差值编码后 VByte 压缩。
// 输入：sorted ords（升序）
// 输出：VByte 压缩的字节序列
inline std::vector<std::uint8_t> gap_encode(const std::vector<std::uint64_t>& ords) {
    std::vector<std::uint8_t> buf;
    if (ords.empty()) return buf;
    std::uint64_t prev = 0;
    for (auto ord : ords) {
        vbyte_encode(ord - prev, buf);
        prev = ord;
    }
    return buf;
}

// Gap 解码：从 VByte 压缩字节还原 ord 数组。
inline std::vector<std::uint64_t> gap_decode(const std::vector<std::uint8_t>& compressed) {
    std::vector<std::uint64_t> ords;
    if (compressed.empty()) return ords;
    std::size_t pos = 0;
    std::uint64_t prev = 0;
    while (pos < compressed.size()) {
        auto [delta, new_pos] = vbyte_decode(compressed.data(), pos);
        pos = new_pos;
        prev += delta;
        ords.push_back(prev);
    }
    return ords;
}

}  // namespace bitcask::codec