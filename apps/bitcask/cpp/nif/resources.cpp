#include "resources.hpp"

namespace bitcask::nif {

ErlNifResourceType* g_cask_resource_type            = nullptr;
ErlNifResourceType* g_cask_iter_resource_type       = nullptr;
ErlNifResourceType* g_cask_range_iter_resource_type = nullptr;
ErlNifResourceType* g_txn_token_resource_type       = nullptr;

void cask_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CaskHandle*>(obj)->~CaskHandle();
}

void cask_iter_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CaskIterHandle*>(obj)->~CaskIterHandle();
}

void cask_range_iter_resource_dtor(ErlNifEnv* /*env*/, void* obj) noexcept {
    static_cast<CaskRangeIterHandle*>(obj)->~CaskRangeIterHandle();
}

// 析构回调的 env 是 callback environment，enif_send 可用（erl_nif 文档）。
void txn_token_resource_dtor(ErlNifEnv* env, void* obj) noexcept {
    auto* t = static_cast<TxnTokenHandle*>(obj);
    t->fire(env);
    t->~TxnTokenHandle();
}

bool register_resources(ErlNifEnv* env) noexcept {
    constexpr ErlNifResourceFlags flags =
        static_cast<ErlNifResourceFlags>(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);

    g_cask_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_cask_resource",
        &cask_resource_dtor, flags, nullptr);
    if (!g_cask_resource_type) return false;

    g_cask_iter_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_cask_iter_resource",
        &cask_iter_resource_dtor, flags, nullptr);
    if (!g_cask_iter_resource_type) return false;

    g_cask_range_iter_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_cask_range_iter_resource",
        &cask_range_iter_resource_dtor, flags, nullptr);
    if (!g_cask_range_iter_resource_type) return false;

    g_txn_token_resource_type = enif_open_resource_type(
        env, /*module_str*/ nullptr, "bitcask_cpp_txn_token_resource",
        &txn_token_resource_dtor, flags, nullptr);
    if (!g_txn_token_resource_type) return false;

    return true;
}

}  // namespace bitcask::nif