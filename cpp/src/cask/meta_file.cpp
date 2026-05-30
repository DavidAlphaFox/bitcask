#include "bitcask/meta_file.hpp"

#include <cstring>
#include <filesystem>
#include <fstream>

namespace bitcask::meta {

namespace {

// bitcask.meta binary format constants
inline constexpr std::size_t kMetaMagicSize = 4;
inline constexpr std::size_t kMetaVersionOffset = 4;
inline constexpr std::size_t kMetaModeOffset = 5;
inline constexpr std::size_t kMetaReservedSize = 12;
inline constexpr std::size_t kMetaFileSize = kMetaMagicSize + 1 + 1 + kMetaReservedSize;  // 18 bytes

inline constexpr std::uint8_t kMetaVersion = 1;
inline constexpr char kMetaMagic[kMetaMagicSize + 1] = "BCME";

}  // namespace

bool meta_exists(std::string_view dirname) {
    const auto path = std::filesystem::path(dirname) / "bitcask.meta";
    return std::filesystem::exists(path);
}

std::expected<MetaConfig, MetaError> read_meta(std::string_view dirname) {
    const auto path = std::filesystem::path(dirname) / "bitcask.meta";
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return std::unexpected(MetaError{errno, "cannot open bitcask.meta"});
    }

    char header[kMetaFileSize];
    f.read(header, static_cast<std::streamsize>(kMetaFileSize));
    if (!f || f.gcount() != static_cast<std::streamsize>(kMetaFileSize)) {
        return std::unexpected(MetaError{EIO, "read meta file truncated"});
    }

    if (std::memcmp(header, kMetaMagic, kMetaMagicSize) != 0) {
        return std::unexpected(MetaError{0, "bad magic"});
    }

    const std::uint8_t ver = static_cast<std::uint8_t>(header[kMetaVersionOffset]);
    if (ver != kMetaVersion) {
        return std::unexpected(MetaError{0, "unsupported meta version"});
    }

    const std::uint8_t mode_val = static_cast<std::uint8_t>(header[kMetaModeOffset]);
    MetaConfig cfg;
    if (mode_val == 0) {
        cfg.mode = Mode::kKV;
    } else if (mode_val == 1) {
        cfg.mode = Mode::kIndex;
    } else {
        return std::unexpected(MetaError{0, "unknown mode"});
    }
    return cfg;
}

std::expected<void, MetaError> write_meta(std::string_view dirname, const MetaConfig& config) {
    const auto path = std::filesystem::path(dirname) / "bitcask.meta";
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) {
        return std::unexpected(MetaError{errno, "cannot create bitcask.meta"});
    }

    char header[kMetaFileSize] = {0};
    std::memcpy(header, kMetaMagic, kMetaMagicSize);
    header[kMetaVersionOffset] = static_cast<char>(kMetaVersion);
    header[kMetaModeOffset] = static_cast<char>(
        config.mode == Mode::kKV ? 0 : 1);

    f.write(header, static_cast<std::streamsize>(kMetaFileSize));
    if (!f) {
        return std::unexpected(MetaError{errno, "write meta file failed"});
    }
    return {};
}

}  // namespace bitcask::meta