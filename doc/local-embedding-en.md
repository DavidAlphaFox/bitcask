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
                  zen4,alderlake,sapphirerapids}.so   ← 14 CPU variants (x86; ARM has its own set)
priv/libggml.so* priv/libllama.so*
```

**These variants are `dlopen`ed at runtime by CPU microarchitecture**, not
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

### 3.4 GPU (NVIDIA CUDA / Vulkan)

bitcask is a server-side product, so the trade-off is **performance first, size
is not a constraint**.

**Build time probes the SDK, run time probes the GPU** — these happen on
different machines, so they are done separately: the build box decides which
backends get compiled in, and on the target box Erlang decides **by itself**
which one to use. No script, no per-machine configuration.

#### Build time vs run time: ask them separately

These are two different questions, and they routinely happen on **different
machines**:

| | Asks | Answered by | On which machine |
|---|---|---|---|
| **Build time** | Is there a CUDA **SDK**? | `find_package(CUDAToolkit)` | the build box (often has no GPU) |
| **Run time** | Is there a matching **GPU**? | the devices ggml enumerates | the deployment box (often has no toolkit) |

The build-time answer is **baked into the .so** so the runtime can ask for it:

```erlang
{ok, B} = bitcask_llama_nifs:build_info().
%% #{cuda_built => true, cuda_version => <<"12.4">>,
%%   cuda_archs => <<"50-virtual,61-virtual,...,90-virtual">>}

{ok, R} = bitcask_llama_nifs:backend_info().
%% #{count => 2, gpu_count => 1, devices => [#{type => gpu, ...}, ...]}

{ok, S} = bitcask_llama_nifs:gpu_status().   %% the two, reconciled
%% #{status => ok | cpu_only_build | no_gpu_device | backend_not_initialized, ...}
```

> ⚠️ **Asking only about run time is not enough.** Faced with "0 GPU devices",
> without knowing whether this package was built with CUDA you cannot tell the
> two diagnoses apart — and they need completely different fixes:

| `status` | Meaning | Fix |
|---|---|---|
| `ok` | CUDA compiled in, GPU enumerated | — |
| `cpu_only_build` | the package has no CUDA at all | **rebuild** (installing a driver will not help) |
| `no_gpu_device` | CUDA is in the package, no GPU on this machine | install the driver / pass devices through with `--gpus all` / check `libggml-cuda.so`'s dependencies |
| `backend_not_initialized` | `ensure_backend/0` not called yet | call it |

The script is split along the same line — the two halves can run on different
machines:

```sh
scripts/detect-llama-backends.sh --build     # build box: is there an SDK
scripts/detect-llama-backends.sh --runtime   # deploy box: is there a GPU, and can this package use it
scripts/detect-llama-backends.sh             # both
```

#### Build time: probe the SDK, decide what to compile

One switch per GPU backend, same semantics, both defaulting to `AUTO` (compiled
in whenever the SDK is detected):

| Switch | SDK required | For |
|---|---|---|
| `BITCASK_LLAMA_CUDA=AUTO\|ON\|OFF` | CUDA Toolkit (nvcc + cublas dev package) | NVIDIA |
| `BITCASK_LLAMA_VULKAN=AUTO\|ON\|OFF` | Vulkan loader + `glslc` + SPIRV-Headers | AMD / Intel / also works on NVIDIA |

Both can be on at once. Use `ON` for release builds — `AUTO` **silently** produces
a CPU-only package on a machine without the SDK, and the two look identical.

> ⚠️ Vulkan's `AUTO` has to confirm **three** dependencies before enabling
> anything: ggml-vulkan's CMakeLists declares both
> `find_package(Vulkan COMPONENTS glslc REQUIRED)` and
> `find_package(SPIRV-Headers CONFIG REQUIRED)` as `REQUIRED`, so turning
> `GGML_VULKAN` on having found only one of them **fails the build outright** —
> and the entire point of AUTO is "quietly don't compile it if it isn't there".

`scripts/detect-llama-backends.sh` is a **build-time tool**: CMake only says "not
found", while the script says **which package is missing** and prints the build
command to use.

#### Run time: Erlang picks the backend itself

Once deployed on the target machine there is no script involved, and no
per-machine configuration:

```erlang
%% backend => auto is the default
{ok, M} = bitcask_llama_nifs:model_load(Path, #{pooling => last, n_ctx => 512}).
```

`auto` walks **CUDA > Vulkan > CPU** and takes the first backend family that
actually has a GPU. The order is not arbitrary: on the same NVIDIA card the CUDA
path is faster and more mature, and Vulkan is the fallback for cards without CUDA.
`n_gpu_layers` also defaults to auto (offload everything if there is a GPU,
otherwise 0).

You can force it: `backend => cuda | vulkan | cpu`. An unknown value returns
`{error, {bad_backend, _}}` rather than silently falling back to the default.

> ⚠️ **Picking exactly one family is a correctness requirement, not a policy.**
> With CUDA and Vulkan both compiled in, each backend **enumerates the same
> physical card** — one 4090 shows up as both `CUDA0` and `Vulkan0`. With
> `llama_model_params.devices` left NULL ("use all available devices") llama then
> splits the model's layers across what it thinks are two cards. That does not
> error; it double-books VRAM and produces mysterious slowness or OOM.

#### Multiple GPUs: all layers on one card, N instances (data parallelism)

**Multi-GPU load spreading does not happen automatically, on purpose.** llama's
`split_mode` defaults to `LAYER` — splitting the model's layers across every card
(model parallelism). For an **embedding model** that is a pessimization:

- 0.6B of weights fits on a single card, so splitting adds a cross-GPU transfer
  at every layer boundary, while a whole forward pass is only tens of ms;
- worse, **a single `llama_context` serves one forward at a time**, so after
  splitting, N cards are still working on 1 request — N cards' worth of compute
  used as one.

What you want is **data parallelism**: all layers on one card, N instances each
holding one card, N requests genuinely concurrent.

```
   request A → worker_0 → [card 0: all layers]
   request B → worker_1 → [card 1: all layers]     ← genuinely concurrent
   request C → worker_2 → [card 2: all layers]
```

Per-card VRAM is still **one** copy of the weights (each on its own card), not N
copies stacked on one card.

```erlang
{bitcask, [{embedder,
    #{name      => my_embedder,
      provider  => {custom, bitcask_embedder_llama},
      instances => [0, 1, 2, 3],     %% 4 cards, one instance each
      config    => #{model_path => <<"...gguf">>, pooling => last}}}]}.
```

`instances` accepts **only an explicit list of cards (or card groups)**:

| Form | Meaning |
|---|---|
| `[0, 1, 2, 3]` | 4 instances, one card each (model fits on one card — **preferred**) |
| `[[0,1], [2,3]]` | 2 instances, each spanning 2 cards (when it does not fit) |
| `[[0,1,2,3]]` | 1 instance across 4 cards (very large model; degenerates to no concurrency) |

The flat form is shorthand for "one card per group". A group larger than one card
switches `split_mode` to `layer` by default; override it explicitly in `config`.
⚠️ `split_mode => none` with several cards is self-contradictory and is rejected
outright (rather than quietly using only the first card).

> ⚠️ **There is deliberately no `auto`** (size the pool from the machine's card
> count): on a shared box other tenants use the GPUs too, and an embedded library
> should not claim every card by default. The deployment states which ones.
>
> ⚠️ The same card appearing in two instances is rejected — two copies of the
> weights fighting over one card's VRAM, whose only symptom is mysterious OOM or
> slowness.

**No coordinator on the hot path.** `bitcask_embedder_pool` is a **supervisor**
and forwards no `embed`: workers register under stable names (`my_embedder_0` /
`_1` / …) and callers **talk to a worker directly**. Routing through a process
that `gen_server:call`s the workers would make that process the new serialization
point, and the N workers would be pointless. Which worker: the one with the
shortest message queue (workers are serial, so queue length *is* the work owed).

> ⚠️ **Startup is sequential**: the supervisor starts children in order and each
> loads its model synchronously in `init`. N instances = N loads (542 ms measured
> for 0.6B, so ≈ 4.3 s for 8 cards; tens of seconds for an 8B model). This was
> deliberately *not* made parallel or lazy — that would let a worker's startup
> failure bypass the supervisor's start-time check, and the "a configured
> embedder that fails to start kills the application" policy depends on
> synchronous start-time failure. Capacity traded for determinism.

#### When it does not fit on one card

Three ways out, in order of preference:

1. **Partial offload (single card, preferred)** — give `n_gpu_layers => N` an
   explicit number: fit as many layers as you can and leave the rest on CPU.
   Getting 80% of the layers on the GPU usually captures most of the speedup.
2. **Model parallelism (across cards)** — `instances => [[0,1]]`, one instance
   spanning 2 cards. The cost is that this group serves one request at a time:
   concurrency traded for capacity.
3. **A smaller quantization** — Q8 → Q4 halves the VRAM. That is your call; the
   library does not make it for you.

A **coarse pre-check** runs before loading (GGUF file size vs the group's total
free VRAM) and reports early when it clearly will not fit:

```erlang
{error, {model_too_large, <<"GGUF is 8.2 GiB but the selected 1 GPU(s) have 5.6 GiB free. "
                            "Options: n_gpu_layers => N ... or split_mode => layer ...">>}}
```

> ⚠️ **It is only a coarse check, not a precise prediction, and it is never used
> to pick `n_gpu_layers` automatically.** llama's real footprint also includes the
> compute buffer and KV cache, both of which scale with `n_ctx` / `n_batch`. Its
> job is to stop you early when it obviously will not fit and point at the ways
> out — the real verdict is still llama's own attempt. Auto-computing N would risk
> silently offloading a few layers too few: another slowness nobody notices.
>
> Without this check, "does not fit" shows up as: llama OOMs → the fallback
> retries with `ngl=0` → **the whole model goes back to CPU**, throwing away the
> 90% of layers that would have fitted.

#### Two deployment facts

**(1) The CUDA runtime ships with the package.** `GGML_STATIC` conflicts with the
`BUILD_SHARED_LIBS=ON` we require (it adds a global `-static`), so
`libggml-cuda.so` links cudart / cublas / cublasLt **dynamically**. By default
`BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=ON` flattens those three into `priv/`, next to
their consumer, resolved via `$ORIGIN`.

> cuBLAS is genuinely large (hundreds of MB under CUDA 12), but what it buys is
> the elimination of a whole class of "fine on the build box, no GPU on the
> target" failures — and those failures **do not report anything**: ggml tolerates
> a failed backend `dlopen`, it just skips it, so you silently degrade to CPU.
> Size is not a constraint here; the trade is worth it. Turn it off with
> `-DBITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=OFF` (then the target machine must install
> a matching CUDA runtime itself).

**(2) The driver does not ship, and cannot.** `libcuda.so.1` comes from the NVIDIA
driver, must match the GPU, and can only be provided by the target machine. In a
container you also need the devices passed through (`docker --gpus all`), or the
driver libraries are present while the GPU is invisible.

#### CUDA architecture coverage

Because `GGML_NATIVE=OFF`, ggml compiles the whole line: `50/61/70/75/80-virtual`
+ `86/89-real` + `90-virtual` (+ Blackwell, depending on toolkit version),
covering Maxwell through Blackwell. Much larger artifacts, but "move to another
machine and there is no usable kernel" cannot happen — the right trade for a
server product. Narrow it yourself with e.g.
`-DCMAKE_CUDA_ARCHITECTURES=89-real`.

#### Using it

```erlang
{bitcask, [{embedder, #{name => my_embedder,
                        provider => {custom, bitcask_embedder_llama},
                        config => #{model_path => <<"/models/qwen3-emb.gguf">>,
                                    pooling    => last,
                                    n_ctx      => 512}}}]}.
```

`backend` and `n_gpu_layers` both default to auto — GPU if there is one, CPU
otherwise, **no config change per machine**.

#### ⚠️ Always check for a silent fallback after loading

```erlang
{ok, I} = bitcask_embedder_llama:info(Ctx),
maps:with([gpu_layers_requested, gpu_layers_effective,
           fell_back_to_cpu, gpu_fallback_reason], I).
```

When VRAM is insufficient the NIF **falls back to CPU rather than erroring**
(better slow than unusable), but the fallback is observable:

| Case | `gpu_layers_effective` | `fell_back_to_cpu` | Note |
|---|---|---|---|
| `backend => cpu` (explicitly CPU) | 0 | `false` | not a downgrade |
| auto, and this machine has no GPU | 0 | `false` | a **normal automatic decision**, not a fault; `gpu_fallback_reason` still explains why |
| GPU explicitly requested, package/machine has none | **0** | **`true`** | the reason is specific to **the family you asked for** |
| Requested, out of VRAM | **0** | **`true`** | carries llama's own words |
| Succeeded | = requested | `false` | `backend` = `CUDA`/`Vulkan`, `gpu_device` = device name |

> ⚠️ The reason is judged **against the family you asked for**: if the package has
> Vulkan but not CUDA and you asked for `cuda`, saying "has a GPU backend but no
> device" would be wrong — the backend you asked for simply is not in the package.
> The two need different fixes (rebuild vs install a driver).

> ⚠️ **`gpu_layers_effective` is computed from whether a GPU device exists, not
> from the requested value.** This is not pedantry: on a CPU-only build, asking
> for `n_gpu_layers=999` produces **no error** — with no GPU available llama
> quietly offloads nothing. Reporting the requested value would claim "999 layers
> in VRAM" when the truth is 0, which is worse than not reporting at all.
> `gpu_offload_reporting_is_truthful_test_` pins this invariant.

---

## 4. Options

| Option | Default | Meaning |
|---|---|---|
| `model_path` | — | Path to the GGUF. Mutually exclusive with `handle` |
| `handle` | — | Reuse an already-loaded handle (`close/1` won't close it — whoever opened it closes it) |
| `pooling` | `unspecified` | `last` \| `cls` \| `mean` \| `none` \| `rank`. See §5 |
| `n_ctx` | `2048` | **A performance knob**, see §6 |
| `n_threads` | `max(1, available cores - 2)` | See §6 |
| `backend` | `auto` | `auto` (CUDA > Vulkan > CPU) \| `cuda` \| `vulkan` \| `cpu`. See §3.4 |
| `gpu_index` | `0` | Which card to bind; also a group `[0,1]` or `all`. Multi-GPU: see §3.4 |
| `split_mode` | `none` | `none` \| `layer` \| `row`. Latter two only when a large model does not fit one card |
| `n_gpu_layers` | `auto` | Offload everything if there is a GPU, else 0. See §3.4 |
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
%% Build time: what this package was compiled with (machine-independent)
bitcask_llama_nifs:build_info().
%% Run time: what this machine actually enumerates
bitcask_llama_nifs:backend_info().
%% The two, reconciled into a diagnosis
bitcask_llama_nifs:gpu_status().

bitcask_llama_nifs:available().       %% false = not built / .so didn't load
bitcask_llama_nifs:load_status().     %% the raw load_nif reason
bitcask_llama_nifs:ensure_backend().  %% {ok, N}; N=0 means no variant matched this CPU
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
| GPU configured but still slow | Check `fell_back_to_cpu` / `gpu_fallback_reason` from `info/1`, see §3.4 |
| `gpu_status()` returns `cpu_only_build` | No CUDA in the package — **rebuild**; installing a driver will not help |
| `{error, {model_too_large, _}}` | Does not fit on one card — see the three ways out in §3.4 |
| `{error, {bad_opt, {instances, duplicate_gpu}}}` | The same card appears in two instances |
| `{error, {bad_gpu_index, _}}` | `gpu_index` exceeds this machine's card count — size the pool from `backend_info()`'s device list |
| `{error, {bad_backend, _}}` / `{error, {bad_split_mode, _}}` | Values are auto\|cuda\|vulkan\|cpu / none\|layer\|row |
| `gpu_status()` returns `no_gpu_device` | CUDA is in the package but no GPU here — driver / container passthrough / dependency resolution; run `scripts/detect-llama-backends.sh --runtime` |

## 8. Tests

Build-time SDK probe (run it on the **build box**; run time needs no script):

```sh
scripts/detect-llama-backends.sh
```

```sh
# (a) Degradation path — always runs, does not require building this backend
rebar3 eunit --module=bitcask_llama_tests

# (b)+(c) Actually load a model and run
BITCASK_WITH_LLAMA=1 BITCASK_TEST_GGUF=/models/Qwen3-Embedding-0.6B-Q8_0.gguf \
  rebar3 eunit --module=bitcask_llama_tests
```

The model path is not hardcoded and no weights are downloaded: a few hundred MB
of files are not a test dependency.
