// migrate_le — 把 v1 大端 bitcask 目录离线迁移成 v2 小端目录。
//
//   用法:  migrate_le <src_dir> <dst_dir>
//
// 非破坏性:只读 src、只写 dst。迁移 data（重编码 + 重生成 hint）、meta、
// field.schema;ckpt/seg/wal 等可重建文件不迁移（新库首开自动重建）。
// 详见 bitcask/migrate.hpp 与 doc/format-zh.md。

#include <cstdio>
#include <string>

#include "bitcask/migrate.hpp"

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr,
                     "usage: %s <src_dir> <dst_dir>\n"
                     "  migrate a v1 big-endian bitcask dir to v2 "
                     "little-endian (non-destructive: src read-only)\n",
                     argv[0]);
        return 2;
    }
    auto r = bitcask::migrate::migrate_be_to_le(argv[1], argv[2]);
    if (!r) {
        std::fprintf(stderr, "migrate failed: %s\n", r.error().c_str());
        return 1;
    }
    const auto& s = *r;
    std::printf("migrated %s -> %s\n", argv[1], argv[2]);
    std::printf("  data files     : %llu\n",
                static_cast<unsigned long long>(s.data_files));
    std::printf("  records        : %llu (tombstones %llu)\n",
                static_cast<unsigned long long>(s.records),
                static_cast<unsigned long long>(s.tombstones));
    std::printf("  skipped badcrc : %llu\n",
                static_cast<unsigned long long>(s.skipped_bad_crc));
    std::printf("  meta migrated  : %s\n", s.meta_migrated ? "yes" : "no");
    std::printf("  field.schema   : %s\n",
                s.field_schema_migrated ? "yes" : "(none)");
    if (s.skipped_bad_crc > 0) {
        std::fprintf(stderr,
                     "WARNING: %llu records failed CRC and were skipped "
                     "(source corruption?)\n",
                     static_cast<unsigned long long>(s.skipped_bad_crc));
    }
    return 0;
}
