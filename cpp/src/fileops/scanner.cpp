#include "bitcask/detail/scanner.hpp"

#include <algorithm>
#include <cerrno>
#include <filesystem>
#include <system_error>

#include "bitcask/data_file.hpp"

namespace bitcask::fileops {

namespace fs = std::filesystem;

std::expected<std::vector<DataFileEntry>, ScanFault>
scan_dir(std::string_view dirname) {
    std::error_code ec;
    fs::directory_iterator it(fs::path(dirname), ec);
    if (ec) {
        // 目录无法打开就报错——open 阶段就需要这个信息。后面的迭代错误
        // 都视作「能扫多少算多少」。
        return std::unexpected(ScanFault{ScanError::kCannotOpenDir, ec.value()});
    }

    std::vector<DataFileEntry> out;
    for (; it != fs::directory_iterator(); it.increment(ec)) {
        if (ec) break;  // 迭代器失效——返回已收集到的部分结果
        // 跳过：不是普通文件（symlink、目录、socket、device 节点）
        if (!it->is_regular_file(ec) || ec) continue;

        const auto path_str = it->path().string();
        const auto filename = it->path().filename().string();
        // 只接受 "<tstamp>.bitcask.data" 模式；锁文件、merge.txt 等返回 nullopt
        auto tstamp = parse_data_tstamp(filename);
        if (!tstamp) continue;

        DataFileEntry e;
        e.tstamp    = *tstamp;
        e.data_path = path_str;
        // hint_path 即使没文件也会算出来——caller 可能要用这个名字写新 hint
        e.hint_path = mk_hint_filename(path_str);

        std::error_code hec;
        e.has_hint  = fs::is_regular_file(e.hint_path, hec);
        out.push_back(std::move(e));
    }

    // 按 tstamp 升序排序：legacy data_file_tstamps 的契约。merge / open
    // 都依赖这个顺序（旧文件先处理，pending 写入文件最后处理）。
    std::sort(out.begin(), out.end(),
              [](const DataFileEntry& a, const DataFileEntry& b) {
                  return a.tstamp < b.tstamp;
              });
    return out;
}

}  // namespace bitcask::fileops
