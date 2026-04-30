// NIF term ↔ C++ 类型 的小工具集合。所有函数都 inline 到 header，
// 没有翻译单元；避免引入额外 .cpp 增加编译开销。

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

// 分配 size 字节的 ErlNifBinary，把 src 拷进去后返回 term。
// 分配失败时返回调用方提供的 oom_term（一般是 atom allocation_error 或
// {error, allocation_error} 元组）。
inline ERL_NIF_TERM make_binary_from_bytes(ErlNifEnv* env,
                                            std::span<const std::byte> src,
                                            ERL_NIF_TERM oom_term) {
    ErlNifBinary bin;
    if (!enif_alloc_binary(src.size(), &bin)) return oom_term;
    if (!src.empty()) std::memcpy(bin.data, src.data(), src.size());
    return enif_make_binary(env, &bin);
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
inline ERL_NIF_TERM make_uint64_bin(ErlNifEnv* env, std::uint64_t value) {
    ErlNifBinary bin;
    enif_alloc_binary(sizeof(std::uint64_t), &bin);
    std::memcpy(bin.data, &value, sizeof(std::uint64_t));
    return enif_make_binary(env, &bin);
}

}  // namespace bitcask::nif
