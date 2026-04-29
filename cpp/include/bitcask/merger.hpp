// Bitcask merger: consolidate fragmented data files into one fresh data
// file (+ hint), then update the keydir to point at the new locations.
//
// M3.3 scope:
//   - Single output data file (no rollover when output exceeds max_file_size;
//     M3.4 will add it once Cask wires options end-to-end).
//   - No concurrent-write CAS handling (legacy uses tombstone-v2 markers
//     written back to the source files; deferred to M3.4).
//   - No locks (caller must already hold the merge lock).
//   - tombstone records in the source are SKIPPED (simple model).
//
// Even with these simplifications, a successful merge run:
//   1. Deduplicates: only keys whose keydir entry still points at the input
//      (file_id, offset) are copied through.
//   2. Writes a fresh hint file alongside the output data file.
//   3. CAS-updates the keydir to point each surviving key at the new
//      (output_file_id, new_offset) via keydir->put(..., old_file_id, old_offset).

#pragma once

#include <cstdint>
#include <expected>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "bitcask/keydir.hpp"

namespace bitcask::merge {

enum class MergeError {
    kInputOpenFailed,
    kOutputOpenFailed,
    kInputReadFailed,
    kOutputWriteFailed,
    kFinalizeFailed,
};

struct MergeFault {
    MergeError kind;
    int errnum = 0;
    std::string detail;  // optional path / context
};

struct MergeStats {
    std::string   output_data_path;
    std::string   output_hint_path;
    std::uint32_t output_file_id = 0;
    std::uint64_t records_seen   = 0;   // total records walked across inputs
    std::uint64_t records_kept   = 0;   // copied into output
    std::uint64_t records_stale  = 0;   // skipped: keydir points elsewhere
    std::uint64_t records_tombs  = 0;   // skipped: tombstone source record
    std::uint64_t bytes_written  = 0;
};

// Merges `input_data_paths` (must be data files, not hints) into a new
// data file + hint inside `output_dir`. The output's file_id is taken by
// calling keydir.increment_file_id() and is returned in `MergeStats`.
[[nodiscard]] std::expected<MergeStats, MergeFault>
run_merge(std::span<const std::string> input_data_paths,
          std::string_view output_dir,
          keydir::KeyDir& keydir,
          bool sync_output = false);

}  // namespace bitcask::merge
