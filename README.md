# Bitcask — A Log-Structured Hash Table for Fast Key/Value Data

[![CI](https://github.com/basho/bitcask/workflows/CI/badge.svg)](https://github.com/basho/bitcask/actions)

This repo holds two coexisting implementations:

- **legacy** — the original Erlang + C NIF (`src/bitcask_legacy.erl`,
  `c_src/bitcask_nifs.c`). Untouched at the byte level.
- **cask_cpp** — a C++23 NIF (`cpp/`) plus a thin Erlang facade
  (`src/bitcask.erl`). On-disk format is byte-compatible with legacy.

Production builds default to `cask_cpp`. The TEST profile defaults to
`legacy` so the existing white-box test suite runs unchanged. Pick
explicitly with `bitcask:open(Dir, [{nifs, cask_cpp}])` or
`{nifs, legacy}`. See `doc/migration.md` for the full opt-in path.

## Build

The repo has two parallel build entry points; both work standalone.

### rebar3 (Erlang side, builds both NIFs)

```sh
./rebar3 compile        # full build, including legacy priv/bitcask.so
./rebar3 as test eunit  # 90+ Erlang tests (legacy mode by default)
./rebar3 do xref, dialyzer
```

`rebar3 compile` also triggers the `cmake` step that produces
`priv/bitcask_cpp.so` (the C++ NIF). Erlang ≥ 22.0 required.

### CMake (C++ side, tests + benchmarks)

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=ON
cmake --build _build/cmake -j
ctest --test-dir _build/cmake --output-on-failure   # ~167 GoogleTests
```

Sanitizers (one at a time — ASan and TSan are mutually exclusive):

```sh
cmake -S . -B _build/asan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=address,undefined -DBUILD_TESTING=ON
cmake -S . -B _build/tsan -DCMAKE_BUILD_TYPE=Debug \
    -DBITCASK_SANITIZE=thread -DBUILD_TESTING=ON
```

Benchmarks (release only):

```sh
cmake -S . -B _build/bench -DCMAKE_BUILD_TYPE=Release \
    -DBITCASK_BUILD_BENCHMARKS=ON -DBUILD_TESTING=OFF
cmake --build _build/bench -j
_build/bench/cpp/bench/bitcask_bench
```

## Quick example

```erlang
1> R = bitcask:open("/tmp/db", [read_write, {nifs, cask_cpp}]).
#Ref<0.1234.5678>
2> bitcask:put(R, <<"k">>, <<"hello">>).
ok
3> bitcask:get(R, <<"k">>).
{ok, <<"hello">>}
4> bitcask:close(R).
ok
```

## Documentation

| File                    | What it covers                                  |
|-------------------------|-------------------------------------------------|
| `doc/USAGE.md`          | Tutorial: opening, merging, configuring         |
| `doc/format.md`         | On-disk byte-level spec (records, hints, locks) |
| `doc/cpp-arch.md`       | C++ module layout, locking, build entry points  |
| `doc/migration.md`      | Moving from legacy to cask_cpp                  |
| `TASK.md`               | Project roadmap (M0 → M5.5, partial M6)         |

## Project status

`cask_cpp` covers all P0/P1 features through M5.4. Two corners still go
through legacy (see `doc/migration.md`):

- `iterator/3` family
- `fold/6` and `fold_keys/6` with the `MaxAge`/`MaxPut`/`SeeTombstones`
  triple

Legacy code is kept around for these corners and for the white-box test
suite. M6 will collapse it.

## License

Apache 2.0; see `LICENSE`.
