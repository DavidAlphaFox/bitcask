// Bitcask directory scanner.
//
// Walks a bitcask directory and returns the list of valid data files,
// sorted by tstamp ascending (legacy `data_file_tstamps`). Each entry
// also reports whether a matching .bitcask.hint file exists alongside.

#pragma once

#include <cstdint>
#include <expected>
#include <string>
#include <string_view>
#include <vector>

namespace bitcask::fileops {

struct DataFileEntry {
    std::uint64_t tstamp;
    std::string   data_path;
    bool          has_hint;
    std::string   hint_path;  // populated even when !has_hint, for caller use
};

enum class ScanError {
    kCannotOpenDir,
};

struct ScanFault {
    ScanError kind;
    int errnum = 0;
};

// Lists every "<tstamp>.bitcask.data" entry in `dirname`, sorted ascending
// by tstamp. Files that do not match the pattern are silently skipped.
// Sub-directories and symlinks are ignored.
[[nodiscard]] std::expected<std::vector<DataFileEntry>, ScanFault>
scan_dir(std::string_view dirname);

}  // namespace bitcask::fileops
