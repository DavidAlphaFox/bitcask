// priv/bitcask_llama.so 入口 —— 本地嵌入 NIF。模块名必须与调用
// erlang:load_nif/2 的 Erlang 模块（bitcask_llama_nifs）一致。
//
// 这是**第二个** NIF，与 priv/bitcask_cpp.so 完全独立：不链接 libbitcask 的
// 任何 target，bitcask_cpp 也不链接 ggml。为什么分开见 cpp/llama/CMakeLists.txt
// 的头注释。产物布局（priv/ 下平铺 libggml-* / libllama*）同样在那里。
//
// === 线程模型 ===
//
// llama_context **不是线程安全的**（llama.h 里只有 Tokenization 一节写了
// "The API is thread-safe"，其余没写的都不是）。而 BEAM 会从任意调度线程并发
// 调进来。所以：
//
//   * 每个 model 资源自带一把 std::mutex，embed / tokenize_count 全程持有它。
//     同一个句柄上的并发调用**串行化**——这是正确性要求，不是限流策略。
//     要并行就开多个句柄（各自一份 llama_context，显存/内存也各一份）。
//   * 因此 embed 必须挂 ERL_NIF_DIRTY_JOB_CPU_BOUND：它既做几十到上千毫秒的
//     前向，又可能在锁上等另一次前向。放在普通调度线程上是直接把整个
//     BEAM 调度器焊死。
//   * model_load / model_close 挂 DIRTY_JOB_IO_BOUND（读几百 MB 到几 GB 权重）。
//   * 资源析构（model_res_dtor）由 BEAM 回收线程调用，时机不可预测。它会
//     llama_free + llama_model_free，对大模型是几十到几百毫秒的 munmap ——
//     ⚠️ **那段时间该回收线程是被占住的**。所以对外提供了显式 model_close/1，
//     Erlang 侧应当在用完时主动调，别把释放留给 GC。
//
// === ⚠️ 一个无法在这一层解决的风险 ===
//
// ggml 的 GGML_ASSERT 失败走的是 abort()。在 BEAM 里 abort 就是**整个 node
// 连同所有打开的 cask 一起没**，不是这个 NIF 返回一个错误。这里刻意**不**装
// SIGABRT/SIGSEGV handler：BEAM 自己装了一整套信号处理，抢它的会把崩溃现场
// 弄得更难读，而且救不回来。能做的只有把可预期的失败挡在 llama 之前（路径
// 不存在、pooling 为 NONE、token 数超 n_ctx 等，见下），剩下的属于"选择把
// 推理放进 VM 进程"这个决定本身的代价。
//
// === 三件"不做就静默出错"的事（前两条从 coxswain 的同类 shim 继承） ===
//
// (甲) **日志必须改道。** llama.cpp / ggml 默认把加载信息、张量统计一路打到
//      stderr。在 BEAM 里那会与 SASL/logger 的输出绞在一起，而且是刷屏级的。
//      所以 backend_init 的第一件事是 llama_log_set + ggml_log_set。默认吞掉
//      （只留最近一条 error 供 last_error/0 取），设 BITCASK_LLAMA_LOG=1 时
//      原样透到 stderr。
//
// (乙) **池化拿不到要报错，不能当成 0 向量。** 失败链（已对着本仓库 vendored
//      的那份源码核过）：
//        GGUF 没带 modules.json → 转换时不写 {arch}.pooling_type
//          → src/llama-model.cpp:1089  get_key(..., false) 非必需，保持 UNSPECIFIED
//          → src/llama-context.cpp:233-235  两边都 UNSPECIFIED → **静默退到 NONE**
//          → include/llama.h  NONE 下 llama_get_embeddings_seq() 返回 NULL
//      末端是 NULL，可检测——前提是我们真的检测。所以在 model_load 那一步就
//      拒绝 NONE 并给一条说得清的错（用户能修：显式配 last/cls/mean）。
//
// (丙) **向量长度用 n_embd_out，不是 n_embd。** 池化后的向量缓冲区是按
//      `hparams.n_embd_out()` 分配的——src/llama-context.cpp:1511-1515 的注释
//      原文就是 "use n_embd_out (not n_embd_inp) - the pooled embedding has the
//      model's ..."。带投影层的嵌入模型上两者不相等，用 n_embd 会**读过界**
//      或**少读一截**，而两种坏法都不报错，只是向量悄悄不对。

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <erl_nif.h>

#include "ggml-backend.h"
#include "ggml.h"
#include "llama.h"

namespace {

// ---------------------------------------------------------------------------
// atoms —— on_load 单线程初始化，之后只读。
// ---------------------------------------------------------------------------
ERL_NIF_TERM g_ok;
ERL_NIF_TERM g_error;
ERL_NIF_TERM g_true;
ERL_NIF_TERM g_false;

ErlNifResourceType* g_model_res_type = nullptr;

// ---------------------------------------------------------------------------
// 最近一条错误日志。
//
// ⚠️ 这里的并发是真的：log_sink 由 llama.cpp 从**任意线程**回调（包括它自己
//    那 n_threads 条工作线程），而 last_error/0 可能同时在别的调度线程上读。
//    两条线程并发读写同一个 std::string 是 UB，不只是"消息串了"。
//    所以：一把锁 + 读的一侧返回**拷贝**。只加锁不拷贝的话，返回的仍然是指向
//    共享缓冲的指针，锁一放就不作数了。
//
// ⚠️ 纪律：**绝不在持这把锁期间调用 llama/ggml 的任何函数**——它们会打日志，
//    日志回调会来拿同一把锁，当场自死锁。
// ---------------------------------------------------------------------------
std::mutex  g_err_mu;
std::string g_last_error;

bool log_passthrough() {
    static const bool on = (std::getenv("BITCASK_LLAMA_LOG") != nullptr);
    return on;
}

void log_sink(enum ggml_log_level level, const char* text, void* /*ud*/) {
    if (log_passthrough()) {
        std::fputs(text ? text : "", stderr);
        std::fflush(stderr);
    }
    if (level >= GGML_LOG_LEVEL_ERROR && text && *text) {
        std::lock_guard<std::mutex> lk(g_err_mu);
        g_last_error.assign(text);
        // llama 的日志按行分片送来，尾随换行留着没意义。
        while (!g_last_error.empty() &&
               (g_last_error.back() == '\n' || g_last_error.back() == '\r')) {
            g_last_error.pop_back();
        }
    }
}

void err_set(const std::string& s) {
    std::lock_guard<std::mutex> lk(g_err_mu);
    g_last_error = s;
}

void err_clear() {
    std::lock_guard<std::mutex> lk(g_err_mu);
    g_last_error.clear();
}

std::string err_get() {
    std::lock_guard<std::mutex> lk(g_err_mu);
    return g_last_error;  // 拷贝，见上面那段
}

// ---------------------------------------------------------------------------
// term 辅助
// ---------------------------------------------------------------------------
ERL_NIF_TERM mk_bin(ErlNifEnv* env, const std::string& s) {
    ERL_NIF_TERM t;
    unsigned char* p = enif_make_new_binary(env, s.size(), &t);
    if (!s.empty()) std::memcpy(p, s.data(), s.size());
    return t;
}

// {error, Tag}
ERL_NIF_TERM mk_err(ErlNifEnv* env, const char* tag) {
    return enif_make_tuple2(env, g_error, enif_make_atom(env, tag));
}

// {error, {Tag, <<"detail">>}} —— detail 缺省取 last_error（llama 打的那条）。
ERL_NIF_TERM mk_err_msg(ErlNifEnv* env, const char* tag, const std::string& msg) {
    return enif_make_tuple2(
        env, g_error,
        enif_make_tuple2(env, enif_make_atom(env, tag), mk_bin(env, msg)));
}

ERL_NIF_TERM mk_err_last(ErlNifEnv* env, const char* tag, const char* fallback) {
    std::string d = err_get();
    if (d.empty()) d = fallback;
    return mk_err_msg(env, tag, d);
}

// 取一个 binary 参数为 std::string（NUL-safe，不假设结尾）。
bool get_bin_str(ErlNifEnv* env, ERL_NIF_TERM t, std::string& out) {
    ErlNifBinary b;
    if (!enif_inspect_binary(env, t, &b)) return false;
    out.assign(reinterpret_cast<const char*>(b.data), b.size);
    return true;
}

bool get_bool(ErlNifEnv* env, ERL_NIF_TERM t, bool& out) {
    if (enif_is_identical(t, g_true))  { out = true;  return true; }
    if (enif_is_identical(t, g_false)) { out = false; return true; }
    (void) env;
    return false;
}

// f32 小端写出。
//
// 本仓库 P15 之后盘上一律小端，NIF 跨界的向量也是小端 f32（DocValue / HNSW
// 都按这个读）。x86/ARM 上这段是个纯 memcpy，编译器会把 if constexpr 整支
// 消掉；留着是为了大端机上**不是悄悄写出反的字节**。
void write_f32_le(unsigned char* dst, const float* src, size_t n) {
#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
    for (size_t i = 0; i < n; i++) {
        uint32_t u;
        std::memcpy(&u, &src[i], 4);
        dst[i * 4 + 0] = static_cast<unsigned char>( u        & 0xFFu);
        dst[i * 4 + 1] = static_cast<unsigned char>((u >>  8) & 0xFFu);
        dst[i * 4 + 2] = static_cast<unsigned char>((u >> 16) & 0xFFu);
        dst[i * 4 + 3] = static_cast<unsigned char>((u >> 24) & 0xFFu);
    }
#else
    std::memcpy(dst, src, n * 4);
#endif
}

// ---------------------------------------------------------------------------
// backend —— 进程内只初始化一次。
// ---------------------------------------------------------------------------
std::mutex g_backend_mu;
bool       g_backend_ready = false;

// ---------------------------------------------------------------------------
// model 资源
// ---------------------------------------------------------------------------
struct ModelRes {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    std::mutex     mu;  // 守 ctx：llama_context 非线程安全，见文件头线程模型

    int32_t n_embd_out  = 0;  // (丙)：向量长度用它，不是 n_embd
    int32_t n_embd      = 0;  // 只用于 model_info 展示，排查"两个维度不一样"用
    int32_t n_ctx       = 0;
    int32_t n_ctx_train = 0;
    int32_t pooling     = -1;
    bool    has_encoder = false;
    uint64_t size_bytes = 0;
    std::string desc;

    // 释放两个 llama 对象。调用方必须已持有 mu（或保证独占，如 dtor）。
    void free_locked() {
        if (ctx)   { llama_free(ctx);              ctx = nullptr; }
        if (model) { llama_model_free(model);      model = nullptr; }
    }
};

void model_res_dtor(ErlNifEnv* /*env*/, void* obj) {
    auto* r = static_cast<ModelRes*>(obj);
    // BEAM 保证最后一个 ref 已释放，这里独占；不必也不应加锁。
    r->free_locked();
    r->~ModelRes();
}

ModelRes* get_model(ErlNifEnv* env, ERL_NIF_TERM t) {
    void* p = nullptr;
    if (!enif_get_resource(env, t, g_model_res_type, &p)) return nullptr;
    return static_cast<ModelRes*>(p);
}

// ---------------------------------------------------------------------------
// 分词。llama.h 明写 Tokenization 一节 thread-safe，所以这段不需要 ctx 的锁；
// 但调用方（embed）本来就持着，无所谓。
//
// 两趟：第一趟给一个乐观容量，返回负值说明不够，取其绝对值再来一趟。
// ---------------------------------------------------------------------------
bool tokenize(const llama_model* model, const std::string& text,
              std::vector<llama_token>& out, std::string& err) {
    const llama_vocab* vocab = llama_model_get_vocab(model);
    if (!vocab) { err = "model has no vocab"; return false; }

    // UTF-8 下 token 数 ≤ 字节数，+8 给 BOS/EOS 之类的特殊 token 留余量。
    out.resize(text.size() + 8);
    int32_t n = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()),
                               out.data(), static_cast<int32_t>(out.size()),
                               /*add_special=*/true, /*parse_special=*/false);
    if (n < 0) {
        if (n == INT32_MIN) { err = "tokenization overflowed int32"; return false; }
        out.resize(static_cast<size_t>(-n));
        n = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()),
                           out.data(), static_cast<int32_t>(out.size()),
                           /*add_special=*/true, /*parse_special=*/false);
        if (n < 0) { err = "tokenization failed on retry"; return false; }
    }
    out.resize(static_cast<size_t>(n));
    return true;
}

// ---------------------------------------------------------------------------
// NIF: backend_init(PrivDirBinary) -> {ok, NDevices} | {error, _}
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_backend_init(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    std::string dir;
    if (!get_bin_str(env, argv[0], dir)) return enif_make_badarg(env);

    std::lock_guard<std::mutex> lk(g_backend_mu);
    if (g_backend_ready) {
        return enif_make_tuple2(env, g_ok,
                                enif_make_uint64(env, ggml_backend_dev_count()));
    }

    // (甲) 先改道，再做任何会打日志的事。
    llama_log_set(log_sink, nullptr);
    ggml_log_set(log_sink, nullptr);
    err_clear();

    // ⚠️ 必须是 _from_path：它把默认搜索路径整个**替换**掉（不是追加），只搜
    //    我们给的这一个目录。裸的 ggml_backend_load_all() 按 exe 目录 / cwd /
    //    LD_LIBRARY_PATH 去猜——BEAM 的 exe 是 beam.smp、cwd 是用户的工作目录，
    //    两个都不是 priv/，必然猜不到。
    if (!dir.empty()) {
        ggml_backend_load_all_from_path(dir.c_str());
    } else {
        ggml_backend_load_all();
    }

    llama_backend_init();
    g_backend_ready = true;

    const size_t n = ggml_backend_dev_count();
    if (n == 0) {
        // 这条不是"慢一点"，是**完全没有后端**，下一步 model_load 必然失败。
        return mk_err_msg(env, "no_backend",
                          "no ggml backend loaded from " + dir +
                          " (no libggml-cpu-* variant matched this CPU, or the "
                          "variants were not built/installed into priv/)");
    }
    return enif_make_tuple2(env, g_ok, enif_make_uint64(env, n));
}

// ---------------------------------------------------------------------------
// NIF: backend_info() -> #{count => N, devices => [#{name, description}]}
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_backend_info(ErlNifEnv* env, int argc, const ERL_NIF_TERM[]) {
    if (argc != 0) return enif_make_badarg(env);
    {
        std::lock_guard<std::mutex> lk(g_backend_mu);
        if (!g_backend_ready) return mk_err(env, "backend_not_initialized");
    }

    const size_t n = ggml_backend_dev_count();
    std::vector<ERL_NIF_TERM> devs;
    devs.reserve(n);
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        const char* name = d ? ggml_backend_dev_name(d) : "";
        const char* desc = d ? ggml_backend_dev_description(d) : "";
        ERL_NIF_TERM keys[2] = {enif_make_atom(env, "name"),
                                enif_make_atom(env, "description")};
        ERL_NIF_TERM vals[2] = {mk_bin(env, name ? name : ""),
                                mk_bin(env, desc ? desc : "")};
        ERL_NIF_TERM m;
        if (!enif_make_map_from_arrays(env, keys, vals, 2, &m)) return enif_make_badarg(env);
        devs.push_back(m);
    }

    ERL_NIF_TERM keys[2] = {enif_make_atom(env, "count"),
                            enif_make_atom(env, "devices")};
    ERL_NIF_TERM vals[2] = {enif_make_uint64(env, n),
                            enif_make_list_from_array(env, devs.data(),
                                                      static_cast<unsigned>(devs.size()))};
    ERL_NIF_TERM m;
    if (!enif_make_map_from_arrays(env, keys, vals, 2, &m)) return enif_make_badarg(env);
    return enif_make_tuple2(env, g_ok, m);
}

// ---------------------------------------------------------------------------
// NIF: model_load(PathBin, Pooling, NThreads, NCtx, NGpuLayers)
//        -> {ok, Ref} | {error, _}
//
// Pooling: -1 = UNSPECIFIED（用 GGUF 里带的），0..4 见 llama_pooling_type。
// NThreads / NCtx / NGpuLayers: 0 或负数表示"用默认"。
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_model_load(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 5) return enif_make_badarg(env);
    {
        std::lock_guard<std::mutex> lk(g_backend_mu);
        if (!g_backend_ready) return mk_err(env, "backend_not_initialized");
    }

    std::string path;
    int pooling = -1, n_threads = 0, n_ctx_req = 0, n_gpu_layers = 0;
    if (!get_bin_str(env, argv[0], path))          return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &pooling))     return enif_make_badarg(env);
    if (!enif_get_int(env, argv[2], &n_threads))   return enif_make_badarg(env);
    if (!enif_get_int(env, argv[3], &n_ctx_req))   return enif_make_badarg(env);
    if (!enif_get_int(env, argv[4], &n_gpu_layers))return enif_make_badarg(env);
    if (path.empty()) return mk_err(env, "empty_path");

    err_clear();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;

    llama_model* model = llama_model_load_from_file(path.c_str(), mp);
    if (!model) {
        return mk_err_last(env, "model_load_failed",
                           ("failed to load GGUF: " + path).c_str());
    }

    // n_ctx 是一个**真的性能旋钮**，不只是长度上限：计算图按它分配，取
    // n_ctx_train（Qwen3-Embedding 是 32768）会让每次前向都按最坏情况算。
    // 调用方给多少用多少，但**向下钳到 n_ctx_train**——嵌入模型超出训练长度
    // 没有任何正确的语义，钳的结果由 model_info 的 n_ctx 报出来，可观测。
    const int32_t n_ctx_train = llama_model_n_ctx_train(model);
    int32_t use_ctx = (n_ctx_req > 0) ? n_ctx_req : n_ctx_train;
    if (n_ctx_train > 0 && use_ctx > n_ctx_train) use_ctx = n_ctx_train;
    if (use_ctx <= 0) {
        llama_model_free(model);
        return mk_err_msg(env, "bad_n_ctx",
                          "cannot determine a usable context size (n_ctx_train=" +
                          std::to_string(n_ctx_train) + ")");
    }

    llama_context_params cp = llama_context_default_params();
    cp.embeddings = true;  // 要向量，不要 logits
    cp.n_ctx      = static_cast<uint32_t>(use_ctx);
    // ⚠️ 一次只喂一条，n_batch/n_ubatch 必须容得下最长的那条，否则
    //    llama_encode/decode 会**拒绝整条 batch**（返回负值，不是截断）。
    cp.n_batch    = static_cast<uint32_t>(use_ctx);
    cp.n_ubatch   = static_cast<uint32_t>(use_ctx);
    cp.pooling_type = (pooling < 0) ? LLAMA_POOLING_TYPE_UNSPECIFIED
                                    : static_cast<enum llama_pooling_type>(pooling);
    if (n_threads > 0) {
        cp.n_threads       = n_threads;
        cp.n_threads_batch = n_threads;
    }

    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        // ⚠️ 必须把 model 收掉再返回——不收就是几百 MB 到几 GB 的泄漏，而且
        //    调用方重试时会再装一份。
        llama_model_free(model);
        return mk_err_last(env, "context_init_failed",
                           "llama_init_from_model returned NULL "
                           "(out of memory for the compute buffer?)");
    }

    // (乙) NONE 意味着不池化，llama_get_embeddings_seq 会返回 NULL。与其等到
    // 第一次嵌入拿到 NULL，不如**在加载这一步就拒绝**，并且把话说清楚：这几乎
    // 总是"GGUF 没带 pooling_type 且调用方也没配"造成的，而用户能修。
    if (llama_pooling_type(ctx) == LLAMA_POOLING_TYPE_NONE) {
        llama_free(ctx);
        llama_model_free(model);
        return mk_err_msg(
            env, "pooling_none",
            "pooling type is NONE: this GGUF carries no pooling_type and none "
            "was configured. Set it explicitly (last | cls | mean) -- "
            "Qwen3-Embedding needs `last`, BERT/BGE need `cls`, E5/GTE need `mean`.");
    }

    // (丙) 向量长度用 n_embd_out，不是 n_embd。必须是正数——否则后面按它分配
    // binary 就是 0 长度向量，而 0 长度向量在检索侧只是"永远排不上来"，不报错。
    //
    // ⚠️ 这个检查放在 enif_alloc_resource **之前**是有意的。放在之后就得在错误
    //    路径上手工收尾，而 enif_release_resource 在引用计数归零时**会调用析构
    //    回调**——手工 ~ModelRes() 之后再 release 就是在已析构的 mutex/string 上
    //    再析构一次。分配之前退出就没有这条路径。
    const int32_t n_embd_out = llama_model_n_embd_out(model);
    if (n_embd_out <= 0) {
        llama_free(ctx);
        llama_model_free(model);
        return mk_err_msg(env, "bad_embedding_dim",
                          "llama_model_n_embd_out returned " +
                          std::to_string(n_embd_out));
    }

    void* mem = enif_alloc_resource(g_model_res_type, sizeof(ModelRes));
    if (!mem) {
        llama_free(ctx);
        llama_model_free(model);
        return mk_err(env, "resource_alloc_failed");
    }
    auto* r = new (mem) ModelRes();
    r->model       = model;
    r->ctx         = ctx;
    r->n_embd_out  = n_embd_out;
    r->n_embd      = llama_model_n_embd(model);
    r->n_ctx       = use_ctx;
    r->n_ctx_train = n_ctx_train;
    r->pooling     = static_cast<int32_t>(llama_pooling_type(ctx));
    r->has_encoder = llama_model_has_encoder(model);
    r->size_bytes  = llama_model_size(model);
    {
        char buf[256] = {0};
        llama_model_desc(model, buf, sizeof buf);
        r->desc.assign(buf);
    }

    ERL_NIF_TERM term = enif_make_resource(env, mem);
    enif_release_resource(mem);
    return enif_make_tuple2(env, g_ok, term);
}

// ---------------------------------------------------------------------------
// NIF: model_info(Ref) -> {ok, Map} | {error, _}
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_model_info(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    ModelRes* r = get_model(env, argv[0]);
    if (!r) return enif_make_badarg(env);

    std::lock_guard<std::mutex> lk(r->mu);
    if (!r->ctx) return mk_err(env, "closed");

    const char* kn[] = {"dim", "n_embd", "n_ctx", "n_ctx_train",
                        "pooling_type", "has_encoder", "size_bytes", "description"};
    ERL_NIF_TERM keys[8];
    for (int i = 0; i < 8; i++) keys[i] = enif_make_atom(env, kn[i]);
    ERL_NIF_TERM vals[8] = {
        enif_make_int(env, r->n_embd_out),
        enif_make_int(env, r->n_embd),
        enif_make_int(env, r->n_ctx),
        enif_make_int(env, r->n_ctx_train),
        enif_make_int(env, r->pooling),
        r->has_encoder ? g_true : g_false,
        enif_make_uint64(env, r->size_bytes),
        mk_bin(env, r->desc),
    };
    ERL_NIF_TERM m;
    if (!enif_make_map_from_arrays(env, keys, vals, 8, &m)) return enif_make_badarg(env);
    return enif_make_tuple2(env, g_ok, m);
}

// ---------------------------------------------------------------------------
// NIF: model_close(Ref) -> ok
//
// 幂等。见文件头：把释放留给 GC 会占住 BEAM 的回收线程几十到几百毫秒，
// 所以对外提供显式关闭，Erlang 侧应当主动调。
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_model_close(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    ModelRes* r = get_model(env, argv[0]);
    if (!r) return enif_make_badarg(env);

    // ⚠️ 持锁释放：另一条线程可能正在这个 ctx 上跑前向。拿到锁就说明它做完了。
    std::lock_guard<std::mutex> lk(r->mu);
    r->free_locked();
    return g_ok;
}

// ---------------------------------------------------------------------------
// NIF: tokenize_count(Ref, TextBin) -> {ok, N} | {error, _}
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_tokenize_count(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) return enif_make_badarg(env);
    ModelRes* r = get_model(env, argv[0]);
    if (!r) return enif_make_badarg(env);
    std::string text;
    if (!get_bin_str(env, argv[1], text)) return enif_make_badarg(env);

    std::lock_guard<std::mutex> lk(r->mu);
    if (!r->model) return mk_err(env, "closed");

    std::vector<llama_token> toks;
    std::string err;
    if (!tokenize(r->model, text, toks, err)) return mk_err_msg(env, "tokenize_failed", err);
    return enif_make_tuple2(env, g_ok, enif_make_int(env, static_cast<int>(toks.size())));
}

// ---------------------------------------------------------------------------
// NIF: embed(Ref, TextBin, Normalize::boolean(), Truncate::boolean())
//        -> {ok, Vec} | {ok, Vec, {truncated, NTok, NCtx}} | {error, _}
//
// Vec = f32 LE binary，长度 dim*4，与 DocValue / HNSW 跨界格式一致。
//
// Truncate=false 时 token 数超 n_ctx 直接报错，**不静默截断**：静默截断会让
// 调用方以为整段都被嵌入了，而那正是"检索质量莫名其妙变差"的一个来源。
// Truncate=true 时截断并在返回值里**说出来**（三元组），调用方能记日志。
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_embed(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 4) return enif_make_badarg(env);
    ModelRes* r = get_model(env, argv[0]);
    if (!r) return enif_make_badarg(env);
    std::string text;
    if (!get_bin_str(env, argv[1], text)) return enif_make_badarg(env);
    bool normalize = true, truncate = false;
    if (!get_bool(env, argv[2], normalize)) return enif_make_badarg(env);
    if (!get_bool(env, argv[3], truncate))  return enif_make_badarg(env);

    // 空输入没有"正确的向量"可给。别返回零向量——见下面零范数那段的同一个理由。
    if (text.empty()) return mk_err(env, "empty_text");

    std::lock_guard<std::mutex> lk(r->mu);
    if (!r->ctx) return mk_err(env, "closed");

    std::vector<llama_token> toks;
    std::string terr;
    if (!tokenize(r->model, text, toks, terr)) return mk_err_msg(env, "tokenize_failed", terr);
    if (toks.empty()) return mk_err(env, "empty_token_sequence");

    const int32_t n_tok_orig = static_cast<int32_t>(toks.size());
    bool did_truncate = false;
    if (n_tok_orig > r->n_ctx) {
        if (!truncate) {
            return enif_make_tuple2(
                env, g_error,
                enif_make_tuple3(env, enif_make_atom(env, "too_many_tokens"),
                                 enif_make_int(env, n_tok_orig),
                                 enif_make_int(env, r->n_ctx)));
        }
        toks.resize(static_cast<size_t>(r->n_ctx));
        did_truncate = true;
    }

    // 每次嵌入都是独立的一条，不能让上一次的状态留下来。
    llama_memory_clear(llama_get_memory(r->ctx), true);

    const int32_t n = static_cast<int32_t>(toks.size());
    llama_batch batch = llama_batch_init(n, 0, 1);
    if (!batch.token || !batch.pos || !batch.n_seq_id || !batch.seq_id || !batch.logits) {
        // llama_batch_init 自己不查 malloc 的返回值，所以这条基本只在极端 OOM
        // 下成立。free 掉已经分到的那几块再走——llama_batch_free 对 NULL 是安全的。
        llama_batch_free(batch);
        return mk_err(env, "batch_alloc_failed");
    }
    for (int32_t i = 0; i < n; i++) {
        batch.token[i]     = toks[static_cast<size_t>(i)];
        batch.pos[i]       = i;
        batch.n_seq_id[i]  = 1;
        batch.seq_id[i][0] = 0;
        // 池化模型要每个位置都参与输出，具体怎么归约由 pooling_type 决定。
        batch.logits[i]    = 1;
    }
    batch.n_tokens = n;

    err_clear();
    const int32_t rc = r->has_encoder ? llama_encode(r->ctx, batch)
                                      : llama_decode(r->ctx, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        std::string d = err_get();
        if (d.empty()) {
            d = std::string(r->has_encoder ? "llama_encode" : "llama_decode") +
                " returned " + std::to_string(rc);
        }
        return mk_err_msg(env, "forward_failed", d);
    }

    // (乙) 这里的 NULL 是那条失败链的末端。加载时已经拒过 NONE，走到这里还
    // 拿到 NULL 说明是别的原因，同样不能当成零向量交回去。
    const float* emb = llama_get_embeddings_seq(r->ctx, 0);
    if (!emb) {
        return mk_err_msg(env, "no_embedding",
                          "llama_get_embeddings_seq returned NULL (pooling "
                          "disabled, or the model produced no sequence embedding)");
    }

    const size_t dim = static_cast<size_t>(r->n_embd_out);
    std::vector<float> vec(dim);
    if (normalize) {
        double ss = 0.0;
        for (size_t i = 0; i < dim; i++) ss += static_cast<double>(emb[i]) * emb[i];
        // 全零向量除以零得到 NaN，而 NaN 在余弦里不报错、只是让这一条永远排不
        // 上来——又一个静默坏法。这里当成错误报出去，让调用方知道这条没嵌上。
        if (!(ss > 0.0)) return mk_err(env, "zero_norm");
        const float inv = static_cast<float>(1.0 / std::sqrt(ss));
        for (size_t i = 0; i < dim; i++) vec[i] = emb[i] * inv;
    } else {
        std::memcpy(vec.data(), emb, dim * sizeof(float));
    }

    ERL_NIF_TERM out;
    unsigned char* p = enif_make_new_binary(env, dim * 4, &out);
    write_f32_le(p, vec.data(), dim);

    if (did_truncate) {
        return enif_make_tuple3(
            env, g_ok, out,
            enif_make_tuple3(env, enif_make_atom(env, "truncated"),
                             enif_make_int(env, n_tok_orig),
                             enif_make_int(env, r->n_ctx)));
    }
    return enif_make_tuple2(env, g_ok, out);
}

// ---------------------------------------------------------------------------
// NIF: last_error() -> binary()
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_last_error(ErlNifEnv* env, int argc, const ERL_NIF_TERM[]) {
    if (argc != 0) return enif_make_badarg(env);
    return mk_bin(env, err_get());
}

// ---------------------------------------------------------------------------
// 注册表
//
// flag=ERL_NIF_DIRTY_JOB_CPU_BOUND：前向，几十到上千毫秒，且可能在 model 的
//   互斥量上等另一次前向。
// flag=ERL_NIF_DIRTY_JOB_IO_BOUND：读权重 / 释放权重。
// flag=0：纯读内存的查询，<1ms。
// ---------------------------------------------------------------------------
ErlNifFunc kNifFuncs[] = {
    {"backend_init",   1, nif_backend_init,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"backend_info",   0, nif_backend_info,   0},
    {"model_load",     5, nif_model_load,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"model_info",     1, nif_model_info,     0},
    {"model_close",    1, nif_model_close,    ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"tokenize_count", 2, nif_tokenize_count, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"embed",          4, nif_embed,          ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"last_error",     0, nif_last_error,     0},
};

int on_load(ErlNifEnv* env, void** /*priv_data*/, ERL_NIF_TERM /*load_info*/) {
    g_ok    = enif_make_atom(env, "ok");
    g_error = enif_make_atom(env, "error");
    g_true  = enif_make_atom(env, "true");
    g_false = enif_make_atom(env, "false");

    g_model_res_type = enif_open_resource_type(
        env, nullptr, "bitcask_llama_model", model_res_dtor,
        ERL_NIF_RT_CREATE, nullptr);
    if (!g_model_res_type) return -1;
    return 0;
}

int on_upgrade(ErlNifEnv* env, void** priv_data, void** /*old*/, ERL_NIF_TERM load_info) {
    return on_load(env, priv_data, load_info);
}

}  // namespace

// ⚠️ 刻意**不**在 unload 里调 llama_backend_free()：.so 卸载时可能还有资源没被
//    GC 掉（BEAM 不保证 unload 前跑完所有资源析构），先拆后端就是 use-after-free。
//    进程退出会把这些一起收走。
ERL_NIF_INIT(bitcask_llama_nifs, kNifFuncs, on_load, nullptr, on_upgrade, nullptr)
