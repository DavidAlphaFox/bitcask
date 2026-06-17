// v1(大端 legacy)→ v2(小端 flag-day)目录迁移。
//
// 背景：flag-day 把盘格式从大端切到小端（见 doc/format-zh.md 字节序说明 +
// recovery-unified-checkpoint-design）。本工具把旧大端目录**离线**转换成新
// 小端目录,供新代码直接 open。
//
// 迁移哪些（非破坏性：只读 src、只写 dst）：
//   - <id>.bitcask.data ：逐 record 解大端头 → 用小端 codec 重新编码（CRC 重算）；
//                         同步**重生成** <id>.bitcask.hint（从迁移后的 data 派生）。
//   - bitcask.meta      ：version 1→2，VecDim u16 大端→小端（单字节字段照搬）。
//   - field.schema      ：每条 [NameLen:u16] 大端→小端。
// 跳过（新库首开由 fold 自动重建，无需迁移）：kv.keydir.ckpt、search.*（ckpt/
//   seg/wal/manifest）、旧 hint（已重生成）、锁文件。

#pragma once

#include <cstdint>
#include <expected>
#include <string>
#include <string_view>

namespace bitcask::migrate {

struct MigrateStats {
    std::uint64_t data_files = 0;       // 迁移的 data 文件数
    std::uint64_t records = 0;          // 迁移的 record 总数（含墓碑）
    std::uint64_t tombstones = 0;       // 其中墓碑数
    std::uint64_t skipped_bad_crc = 0;  // CRC 校验失败被跳过的 record 数
    bool meta_migrated = false;
    bool field_schema_migrated = false;
};

// 把 src_dir（v1 大端）迁移到 dst_dir（v2 小端）。dst_dir 不存在则创建。
// 失败返回错误串（src 非 bitcask 目录 / meta 已是 v2 / I/O 错误等）。
[[nodiscard]] std::expected<MigrateStats, std::string>
migrate_be_to_le(std::string_view src_dir, std::string_view dst_dir);

}  // namespace bitcask::migrate
