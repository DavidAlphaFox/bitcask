#include "resources.hpp"

namespace bitcask::nif {

ErlNifResourceType* g_collection_resource_type = nullptr;

void collection_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CollectionHandle*>(obj)->~CollectionHandle();
}

bool register_resources(ErlNifEnv* env) noexcept {
    constexpr ErlNifResourceFlags flags =
        static_cast<ErlNifResourceFlags>(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);

    g_collection_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_collection_resource",
        &collection_resource_dtor, flags, nullptr);
    if (!g_collection_resource_type) return false;

    return true;
}

}  // namespace bitcask::nif
