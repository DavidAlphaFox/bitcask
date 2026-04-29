// Helpers for converting between Erlang NIF terms and bitcask C++ types.

#pragma once

#include <cstddef>
#include <cstring>
#include <span>
#include <string>
#include <vector>

#include <erl_nif.h>

namespace bitcask::nif {

// Materialize an Erlang string (latin1 list-of-int) into std::string.
// Returns false on failure (also sets badarg-style: caller decides).
inline bool get_latin1_string(ErlNifEnv* env, ERL_NIF_TERM term, std::string& out) {
    constexpr std::size_t kMax = 4096;  // matches legacy buffer
    char buf[kMax];
    const int n = enif_get_string(env, term, buf, sizeof(buf), ERL_NIF_LATIN1);
    if (n <= 0) return false;
    out.assign(buf, static_cast<std::size_t>(n - 1));  // n includes NUL
    return true;
}

// View into an ErlNifBinary as bytes. Lifetime is the binary's lifetime.
inline std::span<const std::byte> as_bytes(const ErlNifBinary& bin) noexcept {
    return {reinterpret_cast<const std::byte*>(bin.data), bin.size};
}

// Allocate an ErlNifBinary of `size`, copy `src` in, return the term.
// Returns the allocation_error tuple on OOM.
inline ERL_NIF_TERM make_binary_from_bytes(ErlNifEnv* env,
                                            std::span<const std::byte> src,
                                            ERL_NIF_TERM oom_term) {
    ErlNifBinary bin;
    if (!enif_alloc_binary(src.size(), &bin)) return oom_term;
    if (!src.empty()) std::memcpy(bin.data, src.data(), src.size());
    return enif_make_binary(env, &bin);
}

// Read a uint64 from an 8-byte native-endian binary term. Mirrors legacy
// enif_get_uint64_bin(): the Erlang side passes <<X:64/unsigned-native>>.
inline bool get_uint64_bin(ErlNifEnv* env, ERL_NIF_TERM term, std::uint64_t* out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return false;
    if (bin.size != sizeof(std::uint64_t)) return false;
    std::memcpy(out, bin.data, sizeof(std::uint64_t));
    return true;
}

// Write a uint64 as an 8-byte native-endian binary term. Mirrors legacy
// enif_make_uint64_bin().
inline ERL_NIF_TERM make_uint64_bin(ErlNifEnv* env, std::uint64_t value) {
    ErlNifBinary bin;
    enif_alloc_binary(sizeof(std::uint64_t), &bin);
    std::memcpy(bin.data, &value, sizeof(std::uint64_t));
    return enif_make_binary(env, &bin);
}

}  // namespace bitcask::nif
