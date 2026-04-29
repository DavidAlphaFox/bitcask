// Erlang NIF resource type registration for C++ objects.
// Uses placement-new into the resource buffer; destructor invoked from the
// resource cleanup callback.

#pragma once

#include <memory>
#include <new>
#include <string>
#include <utility>

#include <erl_nif.h>

#include "bitcask/cask.hpp"
#include "bitcask/file_lock.hpp"
#include "bitcask/io.hpp"
#include "bitcask/keydir.hpp"
#include "bitcask/keydir_registry.hpp"

namespace bitcask::nif {

// Per-handle state held in a NIF resource. Mirrors legacy
// bitcask_keydir_handle: pairs a keydir reference with iteration state, and
// remembers the registry name so the resource dtor can release the refcount.
struct KeyDirHandle {
    std::shared_ptr<keydir::KeyDir> keydir;
    keydir::KeyDirRegistry* registry = nullptr;  // null if anonymous
    std::string name;                            // empty if anonymous
    std::unique_ptr<keydir::IterHandle> iter;    // null when not iterating

    // Legacy keydir_release / handle GC must be safe to call repeatedly.
    void release_quiet() noexcept {
        if (iter) { iter->release(); iter.reset(); }
        if (registry && !name.empty()) registry->release(name);
        registry = nullptr;
        name.clear();
        keydir.reset();
    }
};

extern ErlNifResourceType* g_file_resource_type;
extern ErlNifResourceType* g_lock_resource_type;
extern ErlNifResourceType* g_keydir_resource_type;
extern ErlNifResourceType* g_cask_resource_type;
extern ErlNifResourceType* g_cask_iter_resource_type;

// Wraps the C++ Cask object inside a NIF resource. Cask owns its KeyDir and
// active write/hint files; the destructor handles teardown.
struct CaskHandle {
    std::unique_ptr<Cask> cask;
};

struct CaskIterHandle {
    // Holds a non-owning pointer to the parent CaskHandle's resource via
    // an opaque reference; cleanup is the iterator's own duty.
    std::unique_ptr<CaskIter> iter;
};

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
void keydir_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_resource_dtor(ErlNifEnv* env, void* obj) noexcept;
void cask_iter_resource_dtor(ErlNifEnv* env, void* obj) noexcept;

}  // namespace bitcask::nif
