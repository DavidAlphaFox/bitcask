# Local embedding backend (llama.cpp / ggml)

中文版见 [`local-embedding-zh.md`](local-embedding-zh.md)。

Computes embeddings inside the BEAM process, with no HTTP endpoint. The artifact
is a **second NIF**, `priv/bitcask_llama.so`, independent of the core
`priv/bitcask_cpp.so`.

**Not built by default.** With the flag off, this repository's build output is
byte-for-byte what it was before this backend existed: no submodule fetch, no
CMake flag, no extra target.

---

## 1. First decide whether you want it

This is not "swap `url` for `model_path`" — it is **a different tier**. Three
things up front:

| | HTTP endpoint (`bitcask_embedder_openai`) | Local (`bitcask_embedder_llama`) |
|---|---|---|
| Typical model | qwen3-embedding 4B/8B, 2560-dim | 0.6B, 1024-dim (what runs on CPU) |
| Query latency | network round trip + server | **35 ms** (measured, see below) |
| Indexing throughput | server-side concurrency | serial per handle, 276 tokens ≈ 890 ms |
| Blast radius | endpoint down ⇒ `{error,_}` | **ggml's abort() takes the whole node down** |
| Deployment | maintain a service | one .so + one GGUF file |

- **Switching tiers changes the stored dimension, which means a full index
  rebuild.** 1024 ≠ 2560; there is no smooth migration.
- **That blast-radius row is meant literally.** A failed `GGML_ASSERT` calls
  `abort()`, and inside the BEAM that is the entire node plus every open cask,
  gone. All the NIF layer can do is catch the predictable failures before llama
  sees them (path, pooling, token count); the rest is the inherent cost of the
  decision to put inference inside the VM process. If that is unacceptable, stay
  on the HTTP endpoint — it is process-isolated by construction.

The usual reasons to take it: you want low query latency, you don't want to
operate an extra service, or the deployment simply has no outbound network.

---

## 2. Build

```sh
BITCASK_WITH_LLAMA=1 rebar3 compile
```

Or straight from CMake:

```sh
cmake -S . -B _build/cmake -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release \
      -DBITCASK_WITH_LLAMA=ON
cmake --build _build/cmake --target bitcask_llama -j
```

The first run fetches the `third_party/llama.cpp` submodule (~200 MB, pinned to
tag `b10257`) and compiles all of it — minutes, not seconds. Incremental builds
after that are a no-op.

Once built, `priv/` gains a set of shared libraries:

```
priv/bitcask_llama.so          ← the NIF itself
priv/libggml-base.so*          ← ggml core (must be a shared library)
priv/libggml-cpu-{x64,sse42,sandybridge,ivybridge,haswell,piledriver,
                  skylakex,cannonlake,cascadelake,icelake,cooperlake,
                  zen4,alderlake,sapphirerapids}.so   ← 13 CPU variants
priv/libggml.so* priv/libllama.so*
```

**The 13 variants are `dlopen`ed at runtime by CPU microarchitecture**, not
picked at build time. Ship all of them — dropping one shows up as "users on that
one CPU tier silently have no local embedding", which you will never reproduce
on your side. `rebar3 clean` removes them along with everything else.

> ⚠️ `GGML_NATIVE` is forced to `OFF`. The default `ON` compiles for the
> **build machine's** instruction set, and the result on an older CPU is a
> `SIGILL` crash (inside the BEAM: the node is gone), not a slowdown.

---

## 3. Using it

### 3.0 Two tiers of embedder; only one needs a process

| | HTTP tier (`openai` / `anthropic`) | Built-in tier (`llama`) |
|---|---|---|
| State | stateless — the config is a few fields | hundreds of MB of weights + a non-thread-safe context |
| Concurrency | wants to be concurrent | has to be serial |
| How to use it | `{embedder, {openai, Cfg}}`, **no process to configure** | via a `bitcask_embedder_server` process |

The logic both tiers share (input truncation, dimension validation, MRL
truncate + renormalize) lives in `bitcask_embedder_util`, one copy for both.

### 3.1 The built-in tier: application env + `bitcask_sup`

```erlang
%% sys.config / app env
{bitcask, [
  {embedder, #{name     => my_embedder,
               provider => {custom, bitcask_embedder_llama},
               config   => #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
                             pooling    => last,
                             n_ctx      => 512}}}
]}.
```

```erlang
%% from then on every cask just names it
H1 = bitcask:open(Dir1, [read_write, {analyzer, whitespace}, {embedder, my_embedder}]),
H2 = bitcask:open(Dir2, [read_write, {analyzer, whitespace}, {embedder, my_embedder}]),

ok = bitcask:put(H1, <<"d1">>, #{text => <<"the cat sleeps on the mat">>}),
{ok, R} = bitcask:search_vector(H1, {text, <<"a kitten napping">>}, 3).
```

The collection dimension is still derived from the embedder's `vector_dim`; you
neither need nor should write `{vector_dim, N}`.

**No config, no child** — bitcask does not depend on an embedder. You can also
skip the app env entirely and `start_link/2` yourself, or use `child_spec/3` to
hang it in your own supervision tree.

> ⚠️ **If it is configured but fails to start (bad GGUF path, pooling resolving
> to NONE, …) the whole bitcask application fails to start. That is deliberate.**
> Configuring an embedding model means the workload needs it, and at that point
> "silently degrading to no embedding capability" is far more dangerous than
> dying: you only notice the former once the search results are wrong, and by
> then the store is already dirty (wrong dimension, wrong semantics).
>
> For the same reason `bitcask:open/2` no longer **swallows** an
> `application:start` failure. The old `catch application:start(bitcask)` ate it
> whole and then handed back a handle that looked fine. It now returns
> `{error, {bitcask_app_start_failed, Reason}}`.

**Why a local model has to go through the process** — three problems, one fix:

1. **One copy of the weights.** `{Provider, Cfg}` builds a fresh ctx per `open`,
   i.e. hundreds of MB of weights per cask.
2. **The lifecycle has an owner.** `bitcask:close/1` **closes the cask ref, not
   the embedder**. Under `{Provider, Cfg}` the model stays resident until that
   ctx term is garbage-collected, and releasing it then occupies the BEAM's
   resource-reclaim thread for tens to hundreds of milliseconds. In process form
   `terminate/2` releases it explicitly (`child_spec` allows 30 s of shutdown —
   `munmap`ing several GB of weights is not instantaneous).
3. **Serialization was required anyway.** `llama_context` is not thread-safe. A
   gen_server's single-process semantics *are* that constraint, and the queueing
   happens in the Erlang message queue rather than parking several dirty
   schedulers on a C mutex.

`{embedder, _}` accepts `pid()` / a registered name / `{global, _}` /
`{via, M, N}`. If the process is not running, `open` returns
`{error, {embedder_not_running, Ref}}`; if it dies at runtime, `put` gets
`{error, {embedder_not_running, _}}` and the **caller is not taken down with it**.

> ⚠️ **Do not put an HTTP provider in this process.** It is stateless and its
> requests are supposed to be concurrent; inside the process every embed lines up
> in a single chain and throughput is pinned to one process. For the HTTP tier
> just write `{embedder, {openai, Cfg}}` — no process to configure.

### 3.2 Configured directly at `bitcask:open` (single cask, lifecycle doesn't matter)

```erlang
H = bitcask:open(Dir, [read_write, {analyzer, whitespace},
      {embedder, {{custom, bitcask_embedder_llama},
                  #{model_path => <<"/models/Qwen3-Embedding-0.6B-Q8_0.gguf">>,
                    pooling    => last,
                    n_ctx      => 512}}}]).
```

⚠️ All three caveats above still apply: one copy of the weights per cask, and
`close/1` does not release it. Use §3.1 for multiple casks or a long-running
service.

### 3.3 Standalone (no cask)

```erlang
{ok, Ctx} = bitcask_embedder:new({custom, bitcask_embedder_llama},
                                 #{model_path => <<"/models/qwen3-emb.gguf">>,
                                   pooling => last, n_ctx => 512}),
{ok, Vec} = bitcask_embedder:embed(Ctx, <<"hello">>),   %% f32 little-endian binary
{ok, Info} = bitcask_embedder_llama:info(Ctx),
ok = bitcask_embedder_llama:close(Ctx).
```

You can also load the model yourself and hand the handle to several ctxs or
processes (a handle passed in via `handle =>` is `owned = false`, so `close/1`
will **not** touch it — only one loaded from `model_path =>` is its to close):

```erlang
{ok, _} = bitcask_llama_nifs:ensure_backend(),
{ok, M} = bitcask_llama_nifs:model_load(
            <<"/models/qwen3-emb.gguf">>, #{pooling => last, n_ctx => 512}),
{ok, Pid} = bitcask_embedder_server:start_link(
              #{provider => {custom, bitcask_embedder_llama},
                config   => #{handle => M}}),
%% ... when you are done
ok = bitcask_embedder_server:stop(Pid),
ok = bitcask_llama_nifs:model_close(M).   %% whoever opened it closes it
```

---

## 4. Options

| Option | Default | Meaning |
|---|---|---|
| `model_path` | — | Path to the GGUF. Mutually exclusive with `handle` |
| `handle` | — | Reuse an already-loaded handle (`close/1` won't close it — whoever opened it closes it) |
| `pooling` | `unspecified` | `last` \| `cls` \| `mean` \| `none` \| `rank`. See §5 |
| `n_ctx` | `2048` | **A performance knob**, see §6 |
| `n_threads` | `max(1, available cores - 2)` | See §6 |
| `n_gpu_layers` | `0` | This repo does not build GPU backends by default |
| `dim` | — | If given, checked against the model's actual dimension; mismatch is an error |
| `vector_dim` | `= dim` | MRL truncation dimension (≤ dim); truncate + renormalize on the Erlang side |
| `max_input_bytes` | `32768` | Conservative byte-level truncation before embedding (first gate) |
| `truncate` | `false` | When the token count exceeds `n_ctx`: `false` errors, `true` truncates |
| `normalize` | `true` | L2 normalize (after which cosine = dot product) |

---

## 5. Three places this fails silently (all guarded in code — but know why)

### (a) The wrong pooling type

When `pooling` resolves to `NONE`, `llama_get_embeddings_seq()` returns NULL.
The failure chain:

```
GGUF ships without modules.json → conversion doesn't write {arch}.pooling_type
  → llama-model.cpp:1089   non-required key, stays UNSPECIFIED
  → llama-context.cpp:233-235  both sides UNSPECIFIED → silently falls back to NONE
  → llama_get_embeddings_seq() returns NULL
```

The NIF **rejects NONE at load time** with an error you can act on. But note:

> ⚠️ **Configuring the *wrong* one (a GGUF carrying a bad value) is not
> detectable by that chain.** The load succeeds, the embedding succeeds, the
> vector length is right — only the semantics are wrong. The only test that
> catches it is the self-check probe, `self_check_semantics_test_` in
> `test/bitcask_llama_tests.erl`: a near-synonym pair must score distinctly
> higher than an unrelated pair. **Run that case whenever you change models.**

The mapping: Qwen3-Embedding needs `last`, BERT/BGE need `cls`, E5/GTE need
`mean`. Official GGUF repos usually carry the right value; **community
requantized uploads frequently carry none at all**.

### (b) Vector length comes from `n_embd_out`, not `n_embd`

The pooled buffer is sized by `hparams.n_embd_out()` — the comment at
`llama-context.cpp:1511` says it outright: "use n_embd_out (not n_embd_inp)".
On embedding models with a projection layer the two differ, and using `n_embd`
either reads past the end or reads short — **neither failure reports anything**.
`model_info` reports both `dim` (= n_embd_out, the one that gets stored) and
`n_embd`, so a mismatch is visible at a glance.

### (c) There is no "silently truncate" option

When the token count exceeds `n_ctx` the default is
`{error, {too_many_tokens, NTok, NCtx}}`. Only an explicit `truncate => true`
truncates. Silent truncation lets the caller believe the whole passage was
embedded, and that is one of the hardest-to-trace sources of "retrieval quality
mysteriously got worse".

By the same reasoning a zero-norm vector returns `{error, zero_norm}` rather
than an all-zero vector — NaN and zero vectors raise no error under cosine, they
just make that entry rank last forever.

---

## 6. Performance: two knobs, one of them a cliff

Measured on an 8 vCPU container (128-core host), `Qwen3-Embedding-0.6B-Q8_0`,
`n_ctx=512`.

### `n_threads` — oversubscription is a cliff, not a gradient

| n_threads | Query (5 tokens) | Document (276 tokens) |
|---|---|---|
| 1 | 122.9 ms | 3709 ms |
| 4 | 36.1 ms | 1028 ms |
| **6** | **33.4 ms** | **936 ms** |
| 12 | 186.0 ms | 1635 ms |
| 64 | 363.0 ms | 1212 ms |
| 126 | 665.0 ms | 1675 ms |

> ⚠️ **The default uses `erlang:system_info(logical_processors_available)`, not
> `logical_processors`.** The latter reports the **host's** core count and does
> not respect the CPU affinity mask (taskset / cpuset / containers). On this
> machine the two read 8 and 128 — deriving 126 threads from the latter is
> **20× slower** than optimal, with no error anywhere, just "why is local
> embedding so slow".
>
> Affinity does not cover a cgroup CPU **quota** (the `cpu.max` kind that
> throttles by time slice). If you really run under a quota, set `n_threads`
> explicitly; don't expect the default to guess right.

### `n_ctx` — it is not just a length limit

The compute graph is allocated from `n_ctx`, so taking the model's
`n_ctx_train` (32768 for Qwen3-Embedding) makes every forward pass pay for the
worst case:

| n_ctx | Query (5 tokens) |
|---|---|
| 512 | 35.2 ms |
| 2048 | 38.2 ms |
| 8192 | 57.1 ms |

Set it slightly above your chunk length. The NIF clamps down to `n_ctx_train`
(exceeding the trained length has no correct semantics for an embedding model);
the value actually in effect is reported as `n_ctx` by `model_info`.

### Concurrency

**One handle = one `llama_context` = serial.** `llama_context` is not
thread-safe; the C++ side uses a mutex for correctness, so concurrent `embed`
calls on the same handle queue up. To go parallel, open multiple handles — at
the cost of one copy of the weights each.

`embed` is registered as `ERL_NIF_DIRTY_JOB_CPU_BOUND`, so it never blocks a
normal scheduler thread.

---

## 7. Troubleshooting

```erlang
bitcask_llama_nifs:available().       %% false = not built / .so didn't load
bitcask_llama_nifs:load_status().     %% the raw load_nif reason
bitcask_llama_nifs:ensure_backend().  %% {ok, N}; N=0 means no variant matched this CPU
bitcask_llama_nifs:backend_info().    %% which backend it is running on
bitcask_llama_nifs:last_error().      %% last error logged by llama/ggml
```

`BITCASK_LLAMA_LOG=1` passes llama/ggml logs straight through to stderr (by
default they are all swallowed, keeping only the most recent error for
`last_error/0`).

| Symptom | Cause |
|---|---|
| `{error, {llama_nif_unavailable, _, _}}` | Not built with `BITCASK_WITH_LLAMA` |
| `ensure_backend` returns `{ok, 0}` | No `libggml-cpu-*` in `priv/` matches this CPU |
| `{error, {pooling_none, _}}` | GGUF carries no `pooling_type`; set `pooling` explicitly |
| `{error, {model_not_found, _}}` | Bad path (caught on the Erlang side, never reached llama) |
| `{error, {dim_mismatch, _}}` | Configured `dim` disagrees with the model's actual dimension |
| `{error, closed}` | The handle was already `close/1`d |
| Local embedding an order of magnitude slow | `n_threads` oversubscribed, see §6 |

## 8. Tests

```sh
# (a) Degradation path — always runs, does not require building this backend
rebar3 eunit --module=bitcask_llama_tests

# (b)+(c) Actually load a model and run
BITCASK_WITH_LLAMA=1 BITCASK_TEST_GGUF=/models/Qwen3-Embedding-0.6B-Q8_0.gguf \
  rebar3 eunit --module=bitcask_llama_tests
```

The model path is not hardcoded and no weights are downloaded: a few hundred MB
of files are not a test dependency.
