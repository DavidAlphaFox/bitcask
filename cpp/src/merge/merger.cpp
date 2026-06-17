#include "bitcask/merger.hpp"

#include <cstring>

#include "bitcask/data_file.hpp"
#include "bitcask/format.hpp"
#include "bitcask/hint_file.hpp"
#include "bitcask/search_layer.hpp"

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
          bool sync_output,
          search::SearchLayer* search_layer) {
    MergeStats stats;
    // 给输出文件分配新 file_id；这一步必须在 open 前完成，
    // 文件名直接拼成 "<id>.bitcask.data" / "<id>.bitcask.hint"。
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

    // 按顺序遍历每个输入文件。对每条 record 都问 keydir：「这个 key 当前
    // 最新的 entry 是不是还指向 (in_file_id, offset)？」是的话就是活的，
    // 复制到输出；否则跳过（已经被新 put 或 delete 覆盖了）。
    for (const auto& path : input_data_paths) {
        const auto in_tstamp = fileops::parse_data_tstamp(path);
        if (!in_tstamp) continue;
        const std::uint32_t in_file_id =
            static_cast<std::uint32_t>(*in_tstamp);

        // P6:merge 输入纯 fold,不 mmap(避免对大库逐文件全映射)。
        auto in_data = fileops::DataFile::open(path,
                                                fileops::DataFile::Mode::kRead,
                                                /*sync*/ false,
                                                /*mmap_enabled*/ false);
        if (!in_data) {
            return std::unexpected(io_fault(MergeError::kInputOpenFailed,
                                             in_data.error().errnum, path));
        }

        std::expected<void, MergeFault> error;
        auto fold_res = in_data->fold(
            [&](const codec::DataRecordView& view,
                std::uint64_t offset,
                std::uint32_t total_size) {
                if (error.has_value() == false) return;  // 之前 fold 中已出错，停止处理
                stats.records_seen += 1;

                // 墓碑：本简化版直接跳过。legacy 在 v2 模式下会回写一条
                // 「shadow file_id」标记到源文件——cask 层 (M3.4+) 自己处理
                // 这部分细节，merger 不再操心。
                if (view.type == format::RecordType::kTombstone) {
                    stats.records_tombs += 1;
                    return;
                }

                // 活性检查：keydir 当前最新指向必须正好是 (in_file_id, offset)
                // 才算这条 record 是活的。否则它已经被新写入覆盖了，merge
                // 不要再保留——直接 records_stale +1 跳过。
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

                // 复制到输出：先写新 data file，再写新 hint file，
                // 最后 CAS 更新 keydir 指向新位置。
                auto w = out_data->write(format::RecordType::kDoc,
                                          view.tstamp, view.ord,
                                          view.key, view.value);
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

                // CAS 更新 keydir。带上 old_file_id + old_offset：如果在
                // 我们写 data/hint 的中途有别的 writer 把 key 又改了，
                // CAS 会失败——data file 里那条 record 留着但成了 dead，
                // 下一次 merge 自然会清。
                // newest_put=true 让 keydir 接受 new entry 不管 biggest_file_id
                // 的当前值（输出 file_id 就是新的 biggest）。
                auto pr = keydir.put(
                    key_sv,
                    stats.output_file_id, w->total_size, w->offset,
                    view.tstamp, /*now_sec*/ 0,
                    /*newest_put*/ true,
                    /*old_file_id*/ in_file_id,
                    /*old_offset*/  offset,
                    /*ord*/ view.ord);
                (void)pr;  // 并发 put 时 CAS 失败是合法情况，不阻断 merge

                // 通知 SearchLayer：文档 ord 不变，存储定位更新到新文件。
                if (search_layer) {
                    search_layer->on_relocate(key_sv, view.ord,
                                              stats.output_file_id,
                                              w->offset, w->total_size);
                }

                stats.records_kept += 1;
                stats.bytes_written += total_size;
                (void)total_size;  // 已在 w->total_size 里记过
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
