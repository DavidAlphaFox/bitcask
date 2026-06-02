// NIF term ↔ C++ 类型 的小工具集合。所有函数都 inline 到 header，
// 没有翻译单元；避免引入额外 .cpp 增加编译开销。
//
// === 线程模型 ===
// 全部函数都仅操作 caller 提供的 env / term / 局部缓冲，没有共享可变状态。
//   - 可重入 / 线程安全：是。
//   - 锁要求：无。
// 注意: 返回的 std::span<const std::byte> 生命周期跟 caller 的 ErlNifBinary
// 同步，caller 责任保证 binary 不被提前释放。

#pragma once

#include <cstddef>
#include <cstring>
#include <span>
#include <string>

#include <erl_nif.h>

namespace bitcask::nif {

// 把 Erlang 的「latin1 字符列表」（即字符串 list-of-int）拷贝成 std::string。
// 上限 4096 字节，跟 legacy NIF 的栈缓冲区一致；调用方一般是路径名/锁名，
// 远不到这个上限。失败返回 false（调用方决定要不要 badarg）。
inline bool get_latin1_string(ErlNifEnv* env, ERL_NIF_TERM term, std::string& out) {
    constexpr std::size_t kMax = 4096;
    char buf[kMax];
    const int n = enif_get_string(env, term, buf, sizeof(buf), ERL_NIF_LATIN1);
    if (n <= 0) return false;
    // enif_get_string 返回值包含末尾 NUL，所以这里减 1。
    out.assign(buf, static_cast<std::size_t>(n - 1));
    return true;
}

// 把 ErlNifBinary 当作 byte 视图来用；生命周期跟着 binary 走，
// 不要在 binary 析构后还持有这个 span。
inline std::span<const std::byte> as_bytes(const ErlNifBinary& bin) noexcept {
    return {reinterpret_cast<const std::byte*>(bin.data), bin.size};
}

// 把 ErlNifBinary 当作 string_view 来用；生命周期跟着 binary 走，
// 不要在 binary 析构后还持有这个 view。用于把 binary key/value 转成
// std::string_view，避免在 NIF 层面手动 reinterpret_cast。
inline std::string_view as_string_view(const ErlNifBinary& bin) noexcept {
    return {reinterpret_cast<const char*>(bin.data), bin.size};
}

// 从 Erlang list term 中提取 latin1 字符串列表到 std::vector<std::string>。
// 返回 true 表示全部成功；遇到无法解析的元素返回 false。
inline bool get_latin1_string_list(ErlNifEnv* env, ERL_NIF_TERM list,
                                    std::vector<std::string>& out) {
    ERL_NIF_TERM head, tail = list;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        std::string s;
        if (!get_latin1_string(env, head, s)) return false;
        out.push_back(std::move(s));
    }
    return true;
}

// 从 Erlang integer term 中解析 int 值，失败时返回 default_val。
inline int get_int_with_default(ErlNifEnv* env, ERL_NIF_TERM term,
                                 int default_val) noexcept {
    int v = default_val;
    if (enif_is_number(env, term)) {
        enif_get_int(env, term, &v);
    }
    return v;
}

// 解析「必须为正」的整数参数（如 top-k）：非数字或 ≤0 一律回落到 default_val。
inline int get_positive_int(ErlNifEnv* env, ERL_NIF_TERM term,
                            int default_val) noexcept {
    const int v = get_int_with_default(env, term, default_val);
    return v > 0 ? v : default_val;
}

// 解析「必须非负」的整数参数（如 slop / max_edit_distance）：负数回落到 default_val。
inline int get_nonneg_int(ErlNifEnv* env, ERL_NIF_TERM term,
                          int default_val) noexcept {
    const int v = get_int_with_default(env, term, default_val);
    return v >= 0 ? v : default_val;
}

// 从 8 字节 native-endian binary term 里读 uint64。Erlang 那边写
// <<X:64/unsigned-native>> 过来，这里 memcpy 反向解出来。
// 注意：endianness 跟运行平台一致——legacy NIF 一直这么做，跨架构传
// 数据本来也不能通过 native 二进制做，所以保留同样的契约。
inline bool get_uint64_bin(ErlNifEnv* env, ERL_NIF_TERM term, std::uint64_t* out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return false;
    if (bin.size != sizeof(std::uint64_t)) return false;
    std::memcpy(out, bin.data, sizeof(std::uint64_t));
    return true;
}

// uint64 → 8 字节 native-endian binary term。跟 get_uint64_bin/3 配对，
// Erlang 侧拿 <<X:64/unsigned-native>> 模式匹配出来。
// 分配失败返回 0（无效 term），调用方须检查。
inline ERL_NIF_TERM make_uint64_bin(ErlNifEnv* env, std::uint64_t value) {
    ErlNifBinary bin;
    if (!enif_alloc_binary(sizeof(std::uint64_t), &bin)) return 0;
    std::memcpy(bin.data, &value, sizeof(std::uint64_t));
    return enif_make_binary(env, &bin);
}

// 从 NIF term 中提取二进制数据。成功返回 true 并填充 bin；失败返回 false。
// 用于替代重复的 enif_inspect_binary + badarg 模式。
inline bool ensure_binary(ErlNifEnv* env, ERL_NIF_TERM term, ErlNifBinary& bin) noexcept {
    return enif_inspect_binary(env, term, &bin) != 0;
}

// 构造 {ok, Value} term。
inline ERL_NIF_TERM make_ok(ErlNifEnv* env, ERL_NIF_TERM value) noexcept {
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), value);
}

// 构造 {error, Reason} term。
inline ERL_NIF_TERM make_error(ErlNifEnv* env, ERL_NIF_TERM reason) noexcept {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), reason);
}

// 分配二进制并拷贝数据，失败时返回 0（无效 term）；调用方只需检查返回值是否为 0。
inline ERL_NIF_TERM make_binary_checked(ErlNifEnv* env, std::span<const std::byte> src) noexcept {
    ErlNifBinary bin;
    if (!enif_alloc_binary(src.size(), &bin)) return 0;
    if (!src.empty()) std::memcpy(bin.data, src.data(), src.size());
    return enif_make_binary(env, &bin);
}

}  // namespace bitcask::nif
