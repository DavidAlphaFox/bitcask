// Bitcask hint file: parallel index for a data file. Each record is encoded
// by bitcask::codec::encode_hint_record (M0). The file ends with a sentinel
// record that carries a CRC of all preceding bytes — see codec::encode_hint_eof.

#pragma once

#include <cstdint>
#include <expected>
#include <functional>
#include <span>
#include <string>
#include <string_view>

#include "bitcask/codec.hpp"
#include "bitcask/data_file.hpp"  // reuse DataFileFault for now
#include "bitcask/io.hpp"

namespace bitcask::fileops {

class HintFile {
public:
    enum class Mode { kRead, kAppend, kCreate };

    HintFile() = default;
    ~HintFile() = default;

    HintFile(const HintFile&) = delete;
    HintFile& operator=(const HintFile&) = delete;
    HintFile(HintFile&&) noexcept = default;
    HintFile& operator=(HintFile&&) noexcept = default;

    [[nodiscard]] static std::expected<HintFile, DataFileFault>
    open(std::string_view path, Mode mode, bool sync = false);

    // ---- Writing ----

    // Append one hint record. Updates the running CRC.
    [[nodiscard]] std::expected<void, DataFileFault>
    write(std::uint32_t tstamp, std::uint32_t total_sz,
          std::uint64_t offset, bool tombstone,
          std::span<const std::byte> key);

    // Write the EOF sentinel carrying the running CRC. Idempotent at a per-
    // call level — calling twice writes two sentinels (the second wins on
    // read because the parser stops at the first match).
    [[nodiscard]] std::expected<void, DataFileFault> finalize();

    // ---- Reading ----

    // Iterate every hint record (skips the EOF sentinel). The DataFileFault
    // path returns kBadCrc if the trailer CRC mismatches.
    using FoldFn = std::function<void(const codec::HintRecord& rec)>;
    [[nodiscard]] std::expected<void, DataFileFault> fold(FoldFn fn);

    // Validate the trailer CRC over the whole file; returns false if missing
    // or mismatching. Used by has_valid_hintfile().
    [[nodiscard]] std::expected<bool, DataFileFault> validate_trailer();

    // ---- Introspection ----
    [[nodiscard]] std::string_view path() const noexcept { return path_; }
    [[nodiscard]] std::uint32_t    running_crc() const noexcept { return running_crc_; }

    void close() noexcept { file_.close_quiet(); }

private:
    HintFile(io::PosixFile&& f, std::string p, std::uint32_t crc, Mode m) noexcept
        : file_(std::move(f)), path_(std::move(p)), running_crc_(crc), mode_(m) {}

    io::PosixFile file_;
    std::string   path_;
    std::uint32_t running_crc_ = 0;
    Mode          mode_        = Mode::kRead;
};

}  // namespace bitcask::fileops
