// bitcask 目录扫描器。
//
// 遍历一个 bitcask 目录，列出全部合法的 data file，按 tstamp 升序返回
// （等价于 legacy 的 data_file_tstamps）。每条 entry 同时给出对应的
// .bitcask.hint 路径以及它是否真实存在——caller 用 has_hint 决定走
// 「hint 加速重建」还是「扫整个 data file 重建 keydir」。
//
// === 线程模型 ===
// 唯一对外函数 scan_dir：只读 opendir/stat，无共享状态。
//   - 可重入 / 线程安全：是（OS 层 opendir 在 POSIX 下保证 readdir 在
//     不同 DIR* 上并发安全；Linux 实现为 thread-safe）。
//   - 锁要求：无。

#pragma once

#include <cstdint>
#include <expected>
#include <string>
#include <string_view>
#include <vector>

namespace bitcask::fileops {

// 一条扫描结果。hint_path 即使在 has_hint=false 时也会算出来，方便
// caller 直接用它去落 hint 文件。
struct DataFileEntry {
    std::uint64_t tstamp;
    std::string   data_path;
    bool          has_hint;
    std::string   hint_path;
};

enum class ScanError {
    kCannotOpenDir,  // opendir 失败：目录不存在 / 权限不足 / ...
};

struct ScanFault {
    ScanError kind;
    int errnum = 0;
};

// 列出 dirname 下全部 "<tstamp>.bitcask.data" 文件，按 tstamp 升序。
// 不匹配模式的文件直接跳过（包括 lock 文件、.merge 临时文件等）。
// 子目录、symlink 都忽略——bitcask 目录扁平结构，不应该出现这些。
[[nodiscard]] std::expected<std::vector<DataFileEntry>, ScanFault>
scan_dir(std::string_view dirname);

}  // namespace bitcask::fileops
