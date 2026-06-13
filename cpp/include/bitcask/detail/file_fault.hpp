// 文件 I/O 错误类型——data_file 与 hint_file 共用。
//
// 提取为独立头是为了让 hint_file.hpp 不必 include 整个 data_file.hpp
// （DataFile 类及其全部实现细节）仅为了复用错误类型。

#pragma once

#include <cstdint>

#include "bitcask/io.hpp"

namespace bitcask::fileops {

enum class DataFileError {
    kIo,          // 包了一个 io::IoError；errnum 字段给出具体 errno
    kBadCrc,      // 读取 / fold 时 CRC 校验不通过
    kShortRead,   // record 中间 EOF（写到一半被 kill 之类）
    kTooLarge,    // key/value 超过 format 字段上限（uint16/uint32）
};

struct DataFileFault {
    DataFileError kind;
    int errnum = 0;  // 仅当 kind == kIo 有意义
};

/// IoError → DataFileFault 适配器。data_file.cpp 与 hint_file.cpp 共用。
inline DataFileFault io_fault(const io::IoError& e) noexcept {
    return DataFileFault{DataFileError::kIo, e.errnum};
}

}  // namespace bitcask::fileops
