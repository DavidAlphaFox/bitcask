// M0 stub NIF: validates the cmake → erl_nif.h → priv/*.so toolchain.
// Exports a single ping/0 function so the module is loadable and observable.
// Replaced incrementally starting in M1.

#include <erl_nif.h>

namespace {

ERL_NIF_TERM ping(ErlNifEnv* env, int /*argc*/, const ERL_NIF_TERM* /*argv*/) {
    return enif_make_atom(env, "pong");
}

int on_load(ErlNifEnv* /*env*/, void** /*priv_data*/, ERL_NIF_TERM /*load_info*/) {
    return 0;
}

ErlNifFunc nif_funcs[] = {
    {"ping", 0, ping, 0},
};

}  // namespace

ERL_NIF_INIT(bitcask_stub, nif_funcs, on_load, nullptr, nullptr, nullptr)
