// V5:把 Erlang map / proplist 编码为 meta 二进制 blob。给 eunit / 业务层
// 提供轻量入口,避免调用方自己重新实现 meta_codec 的 VByte 格式。生产
// 路径下 put_doc 的 meta 字段仍由调用方自行编码(更高效、可控)。
//
// 接受形式:#{Key :: binary() => Value} 或 [{Key, Value}]。Value 类型映射:
// int -> int64, float -> double, binary -> string, true/false -> bool,
// undefined/其它 atom -> null。失败 → badarg。
//
// decode_meta 是反方向:blob → #{Key :: binary() => Value}。null -> undefined,
// bool -> true/false,int64 -> integer,double -> float,string -> binary。
// 查询层(bitcask_query)拿 get 回来的 meta 在 BEAM 侧求值 where 用。

#include <algorithm>
#include <cstring>
#include <span>
#include <string>
#include <type_traits>
#include <variant>
#include <vector>

#include "atoms.hpp"
#include "bitcask/meta_codec.hpp"
#include "nif_helpers.hpp"
#include "term_conv.hpp"

namespace bitcask::nif {
using namespace detail;

namespace {

// 把一项 (key_term, value_term) 解析为 MetaEntry。失败返回 false。
bool parse_meta_kv(ErlNifEnv* env, ERL_NIF_TERM key_term, ERL_NIF_TERM val_term,
                   bitcask::meta::MetaEntry& out) {
    ErlNifBinary kb{};
    if (!enif_inspect_binary(env, key_term, &kb)) return false;
    out.key.assign(reinterpret_cast<const char*>(kb.data), kb.size);
    if (!parse_meta_value(env, val_term, out.value, /*other_atoms_as_null=*/true)) return false;
    return true;
}

}  // namespace

ERL_NIF_TERM nif_cask_encode_meta(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    std::vector<bitcask::meta::MetaEntry> entries;

    if (enif_is_map(env, argv[0])) {
        ErlNifMapIterator iter;
        if (!enif_map_iterator_create(env, argv[0], &iter,
                                      ERL_NIF_MAP_ITERATOR_FIRST)) {
            return enif_make_badarg(env);
        }
        ERL_NIF_TERM k, v;
        while (enif_map_iterator_get_pair(env, &iter, &k, &v)) {
            bitcask::meta::MetaEntry e;
            if (!parse_meta_kv(env, k, v, e)) {
                enif_map_iterator_destroy(env, &iter);
                return enif_make_badarg(env);
            }
            entries.push_back(std::move(e));
            enif_map_iterator_next(env, &iter);
        }
        enif_map_iterator_destroy(env, &iter);
    } else if (enif_is_list(env, argv[0])) {
        ERL_NIF_TERM head, tail = argv[0];
        while (enif_get_list_cell(env, tail, &head, &tail)) {
            int arity = 0;
            const ERL_NIF_TERM* tarr = nullptr;
            if (!enif_get_tuple(env, head, &arity, &tarr) || arity != 2) {
                return enif_make_badarg(env);
            }
            bitcask::meta::MetaEntry e;
            if (!parse_meta_kv(env, tarr[0], tarr[1], e)) {
                return enif_make_badarg(env);
            }
            entries.push_back(std::move(e));
        }
    } else {
        return enif_make_badarg(env);
    }

    // encode_meta 不变式:keys 必须按字典序升序(否则二分查找失效)。
    std::sort(entries.begin(), entries.end(),
              [](const auto& a, const auto& b) { return a.key < b.key; });

    std::vector<std::byte> buf;
    bitcask::meta::encode_meta(buf, entries);

    ErlNifBinary out{};
    if (!enif_alloc_binary(buf.size(), &out)) {
        return enif_make_badarg(env);
    }
    if (!buf.empty()) {
        std::memcpy(out.data, buf.data(), buf.size());
    }
    return enif_make_binary(env, &out);
}

ERL_NIF_TERM nif_cask_decode_meta(ErlNifEnv* env, int /*argc*/,
                                   const ERL_NIF_TERM argv[]) {
    ErlNifBinary in{};
    if (!enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    auto r = bitcask::meta::decode_meta(std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(in.data), in.size));
    if (!r) return enif_make_badarg(env);

    ERL_NIF_TERM map = enif_make_new_map(env);
    for (const auto& e : *r) {
        ERL_NIF_TERM k = make_binary_checked(env, std::as_bytes(
            std::span<const char>(e.key.data(), e.key.size())));
        if (!k) return make_error(env, atoms().allocation_error);
        ERL_NIF_TERM v = std::visit(
            [env](const auto& x) -> ERL_NIF_TERM {
                using T = std::decay_t<decltype(x)>;
                if constexpr (std::is_same_v<T, std::monostate>) {
                    return atoms().undefined;
                } else if constexpr (std::is_same_v<T, bool>) {
                    return x ? atoms().atom_true : atoms().atom_false;
                } else if constexpr (std::is_same_v<T, std::int64_t>) {
                    return enif_make_int64(env, x);
                } else if constexpr (std::is_same_v<T, double>) {
                    return enif_make_double(env, x);
                } else {
                    return make_binary_checked(env, std::as_bytes(
                        std::span<const char>(x.data(), x.size())));
                }
            },
            e.value);
        if (!v) return make_error(env, atoms().allocation_error);
        enif_make_map_put(env, map, k, v, &map);
    }
    return map;
}

}  // namespace bitcask::nif
