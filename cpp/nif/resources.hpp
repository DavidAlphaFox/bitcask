// Erlang NIF resource type registration for C++ objects.
// Uses placement-new into the resource buffer; destructor invoked from the
// resource cleanup callback.

#pragma once

#include <new>
#include <utility>

#include <erl_nif.h>

#include "bitcask/file_lock.hpp"
#include "bitcask/io.hpp"

namespace bitcask::nif {

extern ErlNifResourceType* g_file_resource_type;
extern ErlNifResourceType* g_lock_resource_type;

// Register both resource types. Returns false if any registration failed.
[[nodiscard]] bool register_resources(ErlNifEnv* env) noexcept;

// Allocate a resource holding T, placement-new constructed from `args`.
// Returns the term (and releases the local resource ref). On allocation
// failure returns 0 (and badarg has not been signaled — caller decides).
template <typename T, typename... Args>
ERL_NIF_TERM make_resource(ErlNifEnv* env, ErlNifResourceType* rt, Args&&... args) {
    void* mem = enif_alloc_resource(rt, sizeof(T));
    if (!mem) return 0;
    new (mem) T(std::forward<Args>(args)...);
    ERL_NIF_TERM term = enif_make_resource(env, mem);
    enif_release_resource(mem);  // BEAM owns the lifetime now
    return term;
}

// Cleanup callbacks (registered with enif_open_resource_type).
void file_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void lock_resource_dtor(ErlNifEnv* env, void* obj) noexcept;

}  // namespace bitcask::nif
