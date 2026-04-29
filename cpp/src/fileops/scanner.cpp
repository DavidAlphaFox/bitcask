#include "bitcask/scanner.hpp"

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
        return std::unexpected(ScanFault{ScanError::kCannotOpenDir, ec.value()});
    }

    std::vector<DataFileEntry> out;
    for (; it != fs::directory_iterator(); it.increment(ec)) {
        if (ec) break;  // stop on first error; partial results returned below
        if (!it->is_regular_file(ec) || ec) continue;

        const auto path_str = it->path().string();
        const auto filename = it->path().filename().string();
        auto tstamp = parse_data_tstamp(filename);
        if (!tstamp) continue;

        DataFileEntry e;
        e.tstamp    = *tstamp;
        e.data_path = path_str;
        e.hint_path = mk_hint_filename(path_str);

        std::error_code hec;
        e.has_hint  = fs::is_regular_file(e.hint_path, hec);
        out.push_back(std::move(e));
    }

    std::sort(out.begin(), out.end(),
              [](const DataFileEntry& a, const DataFileEntry& b) {
                  return a.tstamp < b.tstamp;
              });
    return out;
}

}  // namespace bitcask::fileops
