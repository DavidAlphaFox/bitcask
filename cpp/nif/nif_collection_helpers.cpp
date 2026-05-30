#include <string>

#include "atoms.hpp"
#include "nif_helpers.hpp"
#include "resources.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
namespace detail {

CollectionHandle* collection_handle(ErlNifEnv* env, ERL_NIF_TERM term) noexcept {
    void* obj = nullptr;
    if (!enif_get_resource(env, term, g_collection_resource_type, &obj)) return nullptr;
    return static_cast<CollectionHandle*>(obj);
}

ERL_NIF_TERM collection_fault_to_term(ErlNifEnv* env, const CollectionFault& f) noexcept {
    ERL_NIF_TERM tag;
    switch (f.kind) {
        case CollectionError::kIo:             tag = errno_atom(env, f.errnum); break;
        case CollectionError::kBadCrc:         tag = atoms().bad_crc; break;
        case CollectionError::kNotFound:       return atoms().not_found;
        case CollectionError::kCorrupt:        tag = atoms().error; break;
        case CollectionError::kWriteLocked:    tag = atoms().write_locked; break;
        case CollectionError::kKeyTooLarge:    tag = atoms().key_too_large; break;
        case CollectionError::kValueTooLarge:  tag = atoms().value_too_large; break;
        default:                               tag = atoms().error; break;
    }
    return enif_make_tuple2(env, atoms().error, tag);
}

ERL_NIF_TERM make_string_list(ErlNifEnv* env,
                               const std::vector<std::string>& v) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (auto it = v.rbegin(); it != v.rend(); ++it) {
        list = enif_make_list_cell(env,
            enif_make_string(env, it->c_str(), ERL_NIF_LATIN1), list);
    }
    return list;
}

}  // namespace detail
}  // namespace bitcask::nif
