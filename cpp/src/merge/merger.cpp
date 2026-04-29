#include "bitcask/merger.hpp"

#include <cstring>

#include "bitcask/data_file.hpp"
#include "bitcask/format.hpp"
#include "bitcask/hint_file.hpp"

namespace bitcask::merge {

namespace {

MergeFault io_fault(MergeError kind, int errnum, std::string detail = {}) {
    return MergeFault{kind, errnum, std::move(detail)};
}

}  // namespace

std::expected<MergeStats, MergeFault>
run_merge(std::span<const std::string> input_data_paths,
          std::string_view output_dir,
          keydir::KeyDir& keydir,
          bool sync_output) {
    MergeStats stats;
    stats.output_file_id = keydir.increment_file_id();
    stats.output_data_path =
        fileops::mk_data_filename(output_dir, stats.output_file_id);
    stats.output_hint_path = fileops::mk_hint_filename(stats.output_data_path);

    auto out_data = fileops::DataFile::open(stats.output_data_path,
                                             fileops::DataFile::Mode::kCreate,
                                             sync_output);
    if (!out_data) {
        return std::unexpected(io_fault(MergeError::kOutputOpenFailed,
                                         out_data.error().errnum,
                                         stats.output_data_path));
    }
    auto out_hint = fileops::HintFile::open(stats.output_hint_path,
                                             fileops::HintFile::Mode::kCreate,
                                             sync_output);
    if (!out_hint) {
        return std::unexpected(io_fault(MergeError::kOutputOpenFailed,
                                         out_hint.error().errnum,
                                         stats.output_hint_path));
    }

    // Walk every input file in order. For each record, ask the keydir whether
    // the latest entry for that key still points to (input_file_id, offset);
    // if so it's live and worth carrying over.
    for (const auto& path : input_data_paths) {
        const auto in_tstamp = fileops::parse_data_tstamp(path);
        if (!in_tstamp) continue;
        const std::uint32_t in_file_id =
            static_cast<std::uint32_t>(*in_tstamp);

        auto in_data = fileops::DataFile::open(path,
                                                fileops::DataFile::Mode::kRead);
        if (!in_data) {
            return std::unexpected(io_fault(MergeError::kInputOpenFailed,
                                             in_data.error().errnum, path));
        }

        std::expected<void, MergeFault> error;
        auto fold_res = in_data->fold(
            [&](const codec::DataRecordView& view,
                std::uint64_t offset,
                std::uint32_t total_size) {
                if (error.has_value() == false) return;  // already failed
                stats.records_seen += 1;

                // Tombstone? Skip in this simple merger (legacy emits a v2
                // marker; we'll add that in M3.4).
                std::string_view value_sv(
                    reinterpret_cast<const char*>(view.value.data()),
                    view.value.size());
                if (format::is_tombstone_value(value_sv)) {
                    stats.records_tombs += 1;
                    return;
                }

                // Liveness check: keydir.get must point exactly at (file_id, off).
                std::string_view key_sv(
                    reinterpret_cast<const char*>(view.key.data()),
                    view.key.size());
                auto current = keydir.get(key_sv);
                if (!current ||
                    current->file_id != in_file_id ||
                    current->offset  != offset) {
                    stats.records_stale += 1;
                    return;
                }

                // Carry over: write to output, update keydir CAS.
                auto w = out_data->write(view.tstamp, view.key, view.value);
                if (!w) {
                    error = std::unexpected(io_fault(
                        MergeError::kOutputWriteFailed, 0,
                        stats.output_data_path));
                    return;
                }
                auto h = out_hint->write(view.tstamp, w->total_size,
                                          w->offset, /*tomb*/ false, view.key);
                if (!h) {
                    error = std::unexpected(io_fault(
                        MergeError::kOutputWriteFailed, 0,
                        stats.output_hint_path));
                    return;
                }

                // CAS-update keydir. Pass old_file_id + old_offset so a
                // concurrent put doesn't get clobbered. `newest_put = true`
                // so the new entry's file_id is accepted regardless of
                // biggest_file_id (it IS the new biggest).
                auto pr = keydir.put(
                    key_sv,
                    stats.output_file_id, w->total_size, w->offset,
                    view.tstamp, /*now_sec*/ 0,
                    /*newest_put*/ true,
                    /*old_file_id*/ in_file_id,
                    /*old_offset*/  offset);
                (void)pr;  // CAS may legitimately fail under concurrent write; record stays in output.

                stats.records_kept += 1;
                stats.bytes_written += total_size;
                (void)total_size;  // already accounted via w->total_size
            },
            /*tolerate_crc_errors*/ true);
        if (!error) return std::unexpected(error.error());
        if (!fold_res) {
            return std::unexpected(io_fault(MergeError::kInputReadFailed,
                                             fold_res.error().errnum,
                                             path));
        }
    }

    if (auto f = out_hint->finalize(); !f) {
        return std::unexpected(io_fault(MergeError::kFinalizeFailed,
                                         f.error().errnum,
                                         stats.output_hint_path));
    }
    if (sync_output) {
        if (auto s = out_data->sync(); !s) {
            return std::unexpected(io_fault(MergeError::kFinalizeFailed,
                                             s.error().errnum,
                                             stats.output_data_path));
        }
    }
    return stats;
}

}  // namespace bitcask::merge
