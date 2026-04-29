#include "resources.hpp"

namespace bitcask::nif {

ErlNifResourceType* g_file_resource_type      = nullptr;
ErlNifResourceType* g_lock_resource_type      = nullptr;
ErlNifResourceType* g_keydir_resource_type    = nullptr;
ErlNifResourceType* g_cask_resource_type      = nullptr;
ErlNifResourceType* g_cask_iter_resource_type = nullptr;

void file_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<io::PosixFile*>(obj)->~PosixFile();
}

void lock_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<lock::FileLock*>(obj)->~FileLock();
}

void keydir_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    auto* h = static_cast<KeyDirHandle*>(obj);
    h->release_quiet();
    h->~KeyDirHandle();
}

void cask_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CaskHandle*>(obj)->~CaskHandle();
}

void cask_iter_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CaskIterHandle*>(obj)->~CaskIterHandle();
}

bool register_resources(ErlNifEnv* env) noexcept {
    constexpr ErlNifResourceFlags flags =
        static_cast<ErlNifResourceFlags>(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);

    g_file_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_file_resource",
        &file_resource_dtor, flags, nullptr);
    if (!g_file_resource_type) return false;

    g_lock_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_lock_resource",
        &lock_resource_dtor, flags, nullptr);
    if (!g_lock_resource_type) return false;

    g_keydir_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_keydir_resource",
        &keydir_resource_dtor, flags, nullptr);
    if (!g_keydir_resource_type) return false;

    g_cask_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_cask_resource",
        &cask_resource_dtor, flags, nullptr);
    if (!g_cask_resource_type) return false;

    g_cask_iter_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_cask_iter_resource",
        &cask_iter_resource_dtor, flags, nullptr);
    if (!g_cask_iter_resource_type) return false;

    return true;
}

}  // namespace bitcask::nif
