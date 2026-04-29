// NIF priv_data structure.
// Owned by BEAM (via enif_priv_data); allocated in on_load and freed in
// on_unload. Holds the per-NIF-instance KeyDirRegistry.

#pragma once

#include <memory>

#include "bitcask/keydir_registry.hpp"

namespace bitcask::nif {

struct PrivData {
    keydir::KeyDirRegistry registry;
};

inline PrivData* priv(ErlNifEnv* env) noexcept {
    return static_cast<PrivData*>(enif_priv_data(env));
}

}  // namespace bitcask::nif
