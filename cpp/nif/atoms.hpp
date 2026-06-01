// 缓存的 atom 集合，跨多个 NIF 翻译文件复用。on_load 时一次性 enif_make_atom
// 全部建好，避免每次 NIF 调用都重新创建 atom。
//
// === 线程模型 ===
// atoms() 返回静态单例，仅在 on_load 阶段被 init() 写入；之后所有 NIF
// 入口仅读取——「单写多读」且写入早于任何读取，是 race-free 的常见模式。
//   - atoms().init(env)：仅 on_load 单线程调用一次。
//   - atoms() / errno_*: 可重入、线程安全、无锁。

#pragma once

#include <erl_nif.h>

namespace bitcask::nif {

// 所有 NIF 入口可能用到的 atom 都集中在这里。新增 atom 时记得：
//   1. 在结构体里加字段；
//   2. 在 atoms.cpp 的 init() 里赋值；
//   3. 在 Erlang 侧确认这个 atom 的拼写一致。
struct Atoms {
    ERL_NIF_TERM ok;
    ERL_NIF_TERM error;
    ERL_NIF_TERM allocation_error;

    // 当前 cask_* / collection_* NIF 使用的 atom
    ERL_NIF_TERM o_sync;
    ERL_NIF_TERM not_found;
    ERL_NIF_TERM already_exists;
    ERL_NIF_TERM out_of_date;
    ERL_NIF_TERM iteration_in_process;
    ERL_NIF_TERM iteration_not_started;
    ERL_NIF_TERM atom_true;
    ERL_NIF_TERM atom_false;
    ERL_NIF_TERM undefined;
    ERL_NIF_TERM done;
    ERL_NIF_TERM read_write;
    ERL_NIF_TERM merge_only;
    ERL_NIF_TERM max_file_size;
    ERL_NIF_TERM expiry_secs;
    ERL_NIF_TERM sync_strategy;
    ERL_NIF_TERM tombstone_version;
    ERL_NIF_TERM key_too_large;
    ERL_NIF_TERM value_too_large;
    ERL_NIF_TERM read_only;
    ERL_NIF_TERM write_locked;
    ERL_NIF_TERM bad_crc;
    ERL_NIF_TERM no_index;
    ERL_NIF_TERM mode_mismatch;

    // 合并策略阈值
    ERL_NIF_TERM frag_merge_trigger;
    ERL_NIF_TERM dead_bytes_merge_trigger;
    ERL_NIF_TERM frag_threshold;
    ERL_NIF_TERM dead_bytes_threshold;
    ERL_NIF_TERM small_file_threshold;
    ERL_NIF_TERM expiry_grace_time;
    ERL_NIF_TERM max_merge_size;

    // 索引模式选项
    ERL_NIF_TERM analyzer;
    ERL_NIF_TERM jieba;
    ERL_NIF_TERM ngram;
    ERL_NIF_TERM whitespace;
    ERL_NIF_TERM dict_path;
    ERL_NIF_TERM enable_stop_words;
    ERL_NIF_TERM min_n;
    ERL_NIF_TERM max_n;
    ERL_NIF_TERM min_token_length;
    ERL_NIF_TERM enable_stemming;

    // 线程安全: 否（写入静态状态）；仅 on_load 调用一次。
    void init(ErlNifEnv* env) noexcept;
};

// NIF 实例级别的 atom 单例（每个 .so 加载一次）。
// 线程安全: 是（仅读静态对象）。
Atoms& atoms() noexcept;

// 把 errno 翻译成对应的 Erlang atom（enoent / eaccess / ...），
// 直接复用 erts 提供的 erl_errno_id 表，与 Erlang 侧 file 模块的错误形态一致。
// 线程安全: 是；不需任何锁。
ERL_NIF_TERM errno_atom(ErlNifEnv* env, int errnum) noexcept;

// 构造 {error, ErrnoAtom}，业务最常见的错误返回形态。
// 线程安全: 是；不需任何锁。
ERL_NIF_TERM errno_error_tuple(ErlNifEnv* env, int errnum) noexcept;

// 构造 {error, {Tag, ErrnoAtom}}，给需要带上下文标签的错误用
//（例如 {error, {pread_error, eio}}）。
// 线程安全: 是；不需任何锁。
ERL_NIF_TERM tagged_errno_error_tuple(ErlNifEnv* env,
                                      ERL_NIF_TERM tag,
                                      int errnum) noexcept;

}  // namespace bitcask::nif
