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
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <sys/stat.h>
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

// 已注册的 GPU 设备数。
//
// ⚠️ 这个函数存在的理由是一个**真的会撒谎**的场景：纯 CPU 构建（或 CUDA 后端
//    没加载成功）时请求 n_gpu_layers=999，llama **不报错**——它没有 GPU 可用，
//    就默默地一层都不卸载。如果只按"请求值"报告，model_info 会说 999 层在
//    显存里，而实际是 0。那比不报告更糟。
//    所以 effective 要按"有没有 GPU 设备"算，不是按请求值。
int32_t gpu_device_count() {
    int32_t n = 0;
    const size_t total = ggml_backend_dev_count();
    for (size_t i = 0; i < total; i++) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        if (d && ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU) n++;
    }
    return n;
}

// 设备所属的后端族名："CUDA" / "Vulkan" / "CPU" …
const char* dev_backend_name(ggml_backend_dev_t d) {
    if (!d) return "";
    ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(d);
    const char* n = reg ? ggml_backend_reg_name(reg) : nullptr;
    return n ? n : "";
}

bool iequals(const char* a, const char* b) {
    if (!a || !b) return false;
    while (*a && *b) {
        if (std::tolower(static_cast<unsigned char>(*a)) !=
            std::tolower(static_cast<unsigned char>(*b))) return false;
        a++; b++;
    }
    return *a == *b;
}

// ---------------------------------------------------------------------------
// 运行期设备选择。
//
// ⚠️ **这是正确性要求，不只是策略。** CUDA 与 Vulkan 同时编进包里时，两个后端
//    会**各自枚举同一张物理卡** —— 一张 4090 会以 "CUDA0" 和 "Vulkan0" 两个
//    设备出现。llama 的 llama_model_params.devices 为 NULL 时"使用全部可用
//    设备"，于是它会把同一张卡当成两张去切分模型层。表现不是报错，是显存被
//    重复占用 + 莫名其妙的慢/OOM。
//    所以只要可能有多个 GPU 后端，就必须显式给一份设备清单。
//
// pref：
//   "auto"（默认）—— 按 CUDA > Vulkan 的顺序挑**第一个有 GPU 的后端族**，
//                    并只用那一族的设备。为什么是这个顺序：同一张 N 卡上
//                    CUDA 路径比 Vulkan 快且成熟；Vulkan 是给没有 CUDA 的卡
//                    （AMD / Intel）兜底的。
//   "cuda" / "vulkan" —— 只用指定族；该族没有设备就退回 CPU（并说明）。
//   "cpu"  —— 不用任何 GPU。
//
// indexes：在选中族内取哪几张卡（**卡组**）。空 = {0}（第一张）；{-1} = 全都要。
//           组内多于一张时才谈得上模型并行，由 split_mode 决定怎么切。
//
// ⚠️ **多卡默认只用一张，这是有意的。**
//    llama 的 split_mode 默认是 LAYER —— 把模型的层切分到所有传进去的设备上。
//    对**嵌入模型**那是个反优化：0.6B 权重一张卡装得下，切开之后每次前向都要
//    跨卡传输，而一次前向本来只有几十毫秒。更糟的是它把 N 张卡的并行能力浪费
//    在一条串行的请求路径上。
//    嵌入要的是**数据并行**：一卡一个 context，N 路并发。这正好对上本 NIF 的
//    结构（一句柄 = 一 context = 串行，N 句柄 = N 路并行）——上层按
//    backend_info 的设备表开 N 个句柄、各 pin 一张卡即可。
//    真需要模型并行（大模型单卡装不下）才把 gpu_index 设成 -1 并配 split_mode。
//
// 返回选中的设备（NULL 结尾由调用方补），并回填实际选中的族名。
std::vector<ggml_backend_dev_t> select_devices(const std::string& pref,
                                               const std::vector<int32_t>& indexes,
                                               std::string& chosen_family) {
    chosen_family.clear();
    std::vector<ggml_backend_dev_t> out;
    if (pref == "cpu") return out;

    const size_t total = ggml_backend_dev_count();

    auto collect = [&](const char* family) {
        std::vector<ggml_backend_dev_t> v;
        for (size_t i = 0; i < total; i++) {
            ggml_backend_dev_t d = ggml_backend_dev_get(i);
            if (!d) continue;
            if (ggml_backend_dev_type(d) != GGML_BACKEND_DEVICE_TYPE_GPU) continue;
            if (iequals(dev_backend_name(d), family)) v.push_back(d);
        }
        return v;
    };

    // 按 indexes 收窄。⚠️ 顺序按 indexes 给的来，不按枚举顺序——调用方写
    //    [2,0] 就是想让 2 号做 main_gpu，那是它的事。
    //    任一越界返回空清单，上层报 bad_gpu_index（不静默退 CPU：那会让整池
    //    worker 都挤在 CPU 上而没人发现）。
    auto narrow = [&](std::vector<ggml_backend_dev_t> v) -> std::vector<ggml_backend_dev_t> {
        if (indexes.size() == 1 && indexes[0] < 0) return v;   // {-1} = 全都要
        std::vector<ggml_backend_dev_t> picked;
        for (int32_t idx : indexes) {
            if (idx < 0 || static_cast<size_t>(idx) >= v.size()) return {};
            picked.push_back(v[static_cast<size_t>(idx)]);
        }
        return picked;
    };

    if (pref == "auto") {
        for (const char* fam : {"CUDA", "Vulkan"}) {
            std::vector<ggml_backend_dev_t> all = collect(fam);
            if (all.empty()) continue;
            chosen_family = fam;
            return narrow(std::move(all));
        }
        return out;  // 一个 GPU 都没有 → 空清单 → 纯 CPU
    }

    // 显式指定某一族。
    const char* fam = (pref == "cuda") ? "CUDA" : (pref == "vulkan") ? "Vulkan" : nullptr;
    if (!fam) return out;   // 未知偏好当成没有 GPU，由上层报错
    std::vector<ggml_backend_dev_t> all = collect(fam);
    if (all.empty()) return out;
    chosen_family = fam;
    return narrow(std::move(all));
}

// 选中族内的 GPU 总数（用于把"越界"与"没有卡"区分开）。
int32_t family_gpu_count(const std::string& pref) {
    const size_t total = ggml_backend_dev_count();
    int32_t best = 0;
    for (const char* fam : {"CUDA", "Vulkan"}) {
        if (pref == "cuda" && !iequals(fam, "CUDA")) continue;
        if (pref == "vulkan" && !iequals(fam, "Vulkan")) continue;
        int32_t n = 0;
        for (size_t i = 0; i < total; i++) {
            ggml_backend_dev_t d = ggml_backend_dev_get(i);
            if (d && ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU &&
                iequals(dev_backend_name(d), fam)) n++;
        }
        if (n > 0) return n;   // auto：第一个有卡的族
        best = best > n ? best : n;
    }
    return best;
}

#if defined(BITCASK_LLAMA_BUILD_CUDA) && BITCASK_LLAMA_BUILD_CUDA
constexpr bool kCudaBuilt = true;
#else
constexpr bool kCudaBuilt = false;
#endif
#if defined(BITCASK_LLAMA_BUILD_VULKAN) && BITCASK_LLAMA_BUILD_VULKAN
constexpr bool kVulkanBuilt = true;
#else
constexpr bool kVulkanBuilt = false;
#endif

// 没有可用 GPU 时的原因说明。
//
// ⚠️ **构建期事实在这里把两种原因分开**，不必并列着猜：包里没编这个后端要
//    重新构建（装驱动没用），编了却没设备要装驱动 / 透传设备（重编没用）。
//
// ⚠️ 显式指定某一族时必须**按那一族**判。包里编了 Vulkan 没编 CUDA，而调用方
//    要 cuda —— 说"有 GPU 后端但没设备"是错的，它要的那个后端压根不在包里。
std::string no_gpu_reason(const std::string& pref) {
    const bool want_cuda   = (pref == "cuda");
    const bool want_vulkan = (pref == "vulkan");

    if (want_cuda && !kCudaBuilt) {
        return "backend=cuda was requested but this build has no CUDA backend "
               "(BITCASK_LLAMA_CUDA=OFF at build time). Installing a driver will "
               "not help -- rebuild on a machine with a CUDA Toolkit, or use "
               "backend=auto.";
    }
    if (want_vulkan && !kVulkanBuilt) {
        return "backend=vulkan was requested but this build has no Vulkan "
               "backend (BITCASK_LLAMA_VULKAN=OFF at build time). Installing a "
               "driver will not help -- rebuild on a machine with a Vulkan SDK "
               "(glslc + SPIRV-Headers), or use backend=auto.";
    }
    if (!kCudaBuilt && !kVulkanBuilt) {
        return "this build has no GPU backend at all (BITCASK_LLAMA_CUDA=OFF and "
               "BITCASK_LLAMA_VULKAN=OFF). Installing a driver will not help -- "
               "it has to be rebuilt on a machine with a CUDA or Vulkan SDK.";
    }
    // 要的那个后端确实编进去了（或 auto 且至少编了一个），但运行期没有设备。
    std::string which = want_cuda ? "CUDA" : want_vulkan ? "Vulkan" : "GPU";
    return "this build has the " + which + " backend, but no matching GPU device "
           "was registered at runtime: no driver, a container without the devices "
           "passed through (docker --gpus all), or the backend .so could not "
           "resolve its dependencies -- ggml tolerates a failed backend dlopen, "
           "so it degrades silently. Rebuilding will not help.";
}

// ---------------------------------------------------------------------------
// model 资源
// ---------------------------------------------------------------------------
struct ModelRes {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    std::mutex     mu;  // 守 ctx：llama_context 非线程安全，见文件头线程模型

    int32_t n_embd_out  = 0;  // (丙)：向量长度用它，不是 n_embd
    int32_t n_embd      = 0;  // 只用于 model_info 展示，排查"两个维度不一样"用
    int32_t n_ctx       = 0;   // **每条序列**可用的上下文（= llama 的 n_ctx_seq）
    int32_t n_ctx_train = 0;
    int32_t batch_size  = 1;   // 一次 decode 最多几条序列（n_seq_max）
    int32_t n_batch     = 0;   // 一次 decode 最多几个 token（所有序列之和）
    int32_t pooling     = -1;
    bool    has_encoder = false;
    uint64_t size_bytes = 0;
    std::string desc;

    // GPU 卸载的实际结果。⚠️ requested 与 effective 不一样时上层要**说出来**：
    // 悄悄回落 CPU 的表现是"我明明有卡，怎么还是这么慢"，屏幕上没有任何线索。
    int32_t     gpu_layers_requested = 0;
    int32_t     gpu_layers_effective = 0;
    bool        fell_back_to_cpu     = false;
    std::string gpu_fallback_reason;
    std::string backend_requested;   // auto | cuda | vulkan | cpu
    std::string backend_chosen;      // 实际选中的族："CUDA" / "Vulkan" / ""(=CPU)
    std::string gpu_device;          // 实际绑定的设备名（"CUDA0" …），CPU 时为空
    int32_t     gpu_index_used = -1;

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
// NIF: build_info() -> #{cuda_built, cuda_version, cuda_archs}
//
// **构建期事实**，与这台机器无关 —— 这个 .so 是带着 CUDA 编出来的吗、用的哪个
// toolkit、覆盖了哪些架构。由 cpp/llama/CMakeLists.txt 在编译期烧进来。
//
// ⚠️ 这是"构建期 / 运行期分开"里的构建期一半。没有它，运行期看到 0 个 GPU
//    设备时分不清是包里没编、还是这台机器没卡 —— 而两者要修的东西完全不同。
//    另一半是 backend_info()（运行期真正枚举到了什么）。
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_build_info(ErlNifEnv* env, int argc, const ERL_NIF_TERM[]) {
    if (argc != 0) return enif_make_badarg(env);

#if defined(BITCASK_LLAMA_BUILD_CUDA) && BITCASK_LLAMA_BUILD_CUDA
    const bool  cuda_built = true;
    const char* cuda_ver   = BITCASK_LLAMA_CUDA_VERSION;
    const char* cuda_archs = BITCASK_LLAMA_CUDA_ARCHS;
#else
    const bool  cuda_built = false;
    const char* cuda_ver   = "";
    const char* cuda_archs = "";
#endif
#if defined(BITCASK_LLAMA_BUILD_VULKAN) && BITCASK_LLAMA_BUILD_VULKAN
    const bool vulkan_built = true;
#else
    const bool vulkan_built = false;
#endif

    const char* kn[] = {"cuda_built", "cuda_version", "cuda_archs", "vulkan_built"};
    ERL_NIF_TERM keys[4];
    for (int i = 0; i < 4; i++) keys[i] = enif_make_atom(env, kn[i]);
    ERL_NIF_TERM vals[4] = {
        cuda_built ? g_true : g_false,
        mk_bin(env, cuda_ver),
        mk_bin(env, cuda_archs),
        vulkan_built ? g_true : g_false,
    };
    ERL_NIF_TERM m;
    if (!enif_make_map_from_arrays(env, keys, vals, 4, &m)) return enif_make_badarg(env);
    return enif_make_tuple2(env, g_ok, m);
}

// ---------------------------------------------------------------------------
// NIF: backend_info() -> #{count => N, devices => [#{name, description, type}]}
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
        // 设备类型让 Erlang 侧能直接数出 GPU 数，不必再过一次 NIF。
        // ⚠️ b10859 起 ggml 把 integrated GPU 拆成独立的 IGPU 类型（此前一律
        //    GPU）——设备选择只认 discrete GPU（见 select_devices 的
        //    `== GGML_BACKEND_DEVICE_TYPE_GPU`），iGPU 在这里必须以自己的
        //    类型现形，否则「为什么我的核显没被用上」无从诊断。
        const char* type = "unknown";
        if (d) {
            switch (ggml_backend_dev_type(d)) {
                case GGML_BACKEND_DEVICE_TYPE_CPU:   type = "cpu";   break;
                case GGML_BACKEND_DEVICE_TYPE_GPU:   type = "gpu";   break;
                case GGML_BACKEND_DEVICE_TYPE_IGPU:  type = "igpu";  break;
                case GGML_BACKEND_DEVICE_TYPE_ACCEL: type = "accel"; break;
                case GGML_BACKEND_DEVICE_TYPE_META:  type = "meta";  break;
                default: break;
            }
        }
        // 后端族名让 Erlang 侧能分清同一张物理卡的 CUDA / Vulkan 两个视图。
        size_t mem_free = 0, mem_total = 0;
        if (d) ggml_backend_dev_memory(d, &mem_free, &mem_total);
        ERL_NIF_TERM keys[6] = {enif_make_atom(env, "name"),
                                enif_make_atom(env, "description"),
                                enif_make_atom(env, "type"),
                                enif_make_atom(env, "backend"),
                                enif_make_atom(env, "memory_free"),
                                enif_make_atom(env, "memory_total")};
        ERL_NIF_TERM vals[6] = {mk_bin(env, name ? name : ""),
                                mk_bin(env, desc ? desc : ""),
                                enif_make_atom(env, type),
                                mk_bin(env, dev_backend_name(d)),
                                enif_make_uint64(env, mem_free),
                                enif_make_uint64(env, mem_total)};
        ERL_NIF_TERM m;
        if (!enif_make_map_from_arrays(env, keys, vals, 6, &m)) return enif_make_badarg(env);
        devs.push_back(m);
    }

    ERL_NIF_TERM keys[3] = {enif_make_atom(env, "count"),
                            enif_make_atom(env, "gpu_count"),
                            enif_make_atom(env, "devices")};
    ERL_NIF_TERM vals[3] = {enif_make_uint64(env, n),
                            enif_make_int(env, gpu_device_count()),
                            enif_make_list_from_array(env, devs.data(),
                                                      static_cast<unsigned>(devs.size()))};
    ERL_NIF_TERM m;
    if (!enif_make_map_from_arrays(env, keys, vals, 3, &m)) return enif_make_badarg(env);
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
    if (argc != 9) return enif_make_badarg(env);
    {
        std::lock_guard<std::mutex> lk(g_backend_mu);
        if (!g_backend_ready) return mk_err(env, "backend_not_initialized");
    }

    std::string path, backend_pref, split_pref;
    int pooling = -1, n_threads = 0, n_ctx_req = 0, n_gpu_layers = 0, batch_size = 1;
    std::vector<int32_t> gpu_indexes;
    if (!get_bin_str(env, argv[0], path))          return enif_make_badarg(env);
    if (!enif_get_int(env, argv[1], &pooling))     return enif_make_badarg(env);
    if (!enif_get_int(env, argv[2], &n_threads))   return enif_make_badarg(env);
    if (!enif_get_int(env, argv[3], &n_ctx_req))   return enif_make_badarg(env);
    if (!enif_get_int(env, argv[4], &n_gpu_layers))return enif_make_badarg(env);
    if (!get_bin_str(env, argv[5], backend_pref))  return enif_make_badarg(env);
    {   // argv[6]：卡组（int 列表）。空列表 = {0}。
        ERL_NIF_TERM list = argv[6], head, tail;
        while (enif_get_list_cell(env, list, &head, &tail)) {
            int v = 0;
            if (!enif_get_int(env, head, &v)) return enif_make_badarg(env);
            gpu_indexes.push_back(v);
            list = tail;
        }
        if (!enif_is_empty_list(env, list)) return enif_make_badarg(env);
        if (gpu_indexes.empty()) gpu_indexes.push_back(0);
    }
    if (!get_bin_str(env, argv[7], split_pref))    return enif_make_badarg(env);
    if (!enif_get_int(env, argv[8], &batch_size))  return enif_make_badarg(env);
    if (batch_size < 1) batch_size = 1;
    if (path.empty()) return mk_err(env, "empty_path");
    if (backend_pref.empty()) backend_pref = "auto";
    if (backend_pref != "auto" && backend_pref != "cuda" &&
        backend_pref != "vulkan" && backend_pref != "cpu") {
        return mk_err_msg(env, "bad_backend",
                          "backend must be auto | cuda | vulkan | cpu, got: " + backend_pref);
    }

    err_clear();

    // ------------------------------------------------------------------
    // 运行期决策：这台机器上用哪个后端。
    //
    // ⚠️ 显式给设备清单是**正确性要求**：CUDA 与 Vulkan 同时编进包里时，两者
    //    各自枚举同一张物理卡，devices=NULL 会让 llama 把它当成两张去切分。
    //    详见 select_devices() 上面那段。
    // ------------------------------------------------------------------
    if (split_pref.empty()) split_pref = "none";
    if (split_pref != "none" && split_pref != "layer" && split_pref != "row") {
        return mk_err_msg(env, "bad_split_mode",
                          "split_mode must be none | layer | row, got: " + split_pref);
    }
    // ⚠️ split_mode=none 是**单卡**语义，给了多张卡是自相矛盾的配置——当场拒绝，
    //    不要默默只用第一张（那会让"我配了 4 张卡"变成一句空话）。
    if (split_pref == "none" && gpu_indexes.size() > 1) {
        return mk_err_msg(env, "bad_split_mode",
                          "split_mode=none is single-GPU but " +
                          std::to_string(gpu_indexes.size()) +
                          " GPUs were given; use split_mode=layer|row for model "
                          "parallelism, or one GPU per instance for data parallelism");
    }

    std::string chosen_family;
    std::vector<ggml_backend_dev_t> devs =
        select_devices(backend_pref, gpu_indexes, chosen_family);

    // ------------------------------------------------------------------
    // 装不下的**提前粗检**。
    //
    // 不做这一步的话，"模型比显存大"的表现是：llama OOM → 我们的回落重试
    // ngl=0 → **整体退回纯 CPU**。而 90% 的层本来装得下，只因最后 10% 放不下
    // 就把整个模型挪回 CPU，中间那一大截被跳过了。
    //
    // ⚠️ **这只是粗检，不是精确预测，也绝不用它去自动决定 n_gpu_layers。**
    //    llama 的实际占用还包括 compute buffer 与 KV cache，都随 n_ctx /
    //    n_batch 变。这里比的是 GGUF 文件大小 vs 组内可用显存之和 —— 只在
    //    「明显装不下」时提前拦住并指出两条出路。真正的判据仍然是 llama 自己
    //    那次尝试（算错的代价是静默地少卸载几层，又是一种没人发现的慢）。
    // ------------------------------------------------------------------
    if (!devs.empty() && n_gpu_layers != 0) {
        struct stat st {};
        if (::stat(path.c_str(), &st) == 0 && st.st_size > 0) {
            uint64_t free_sum = 0;
            for (ggml_backend_dev_t d : devs) {
                size_t f = 0, t = 0;
                ggml_backend_dev_memory(d, &f, &t);
                free_sum += f;
            }
            const uint64_t need = static_cast<uint64_t>(st.st_size);
            if (free_sum > 0 && need > free_sum) {
                char buf[512];
                std::snprintf(buf, sizeof buf,
                    "GGUF is %.1f GiB but the selected %zu GPU(s) have %.1f GiB free. "
                    "Options: n_gpu_layers => N (partial offload, keep the rest on CPU), "
                    "or split_mode => layer across more GPUs, or a smaller quantization. "
                    "Set n_gpu_layers => 0 to force CPU and silence this.",
                    need / 1073741824.0, devs.size(), free_sum / 1073741824.0);
                return mk_err_msg(env, "model_too_large", buf);
            }
        }
    }

    // ⚠️ 把"卡不够"与"根本没有卡"分开：前者是配置错（写了 3 号卡但只有 2 张），
    //    静默退回 CPU 会让整池 worker 都挤在 CPU 上而没人发现。
    if (devs.empty() && backend_pref != "cpu") {
        const int32_t have = family_gpu_count(backend_pref);
        bool asked_specific = !(gpu_indexes.size() == 1 &&
                                (gpu_indexes[0] == 0 || gpu_indexes[0] < 0));
        if (have > 0 && asked_specific) {
            std::string want;
            for (size_t i = 0; i < gpu_indexes.size(); i++) {
                if (i) want += ",";
                want += std::to_string(gpu_indexes[i]);
            }
            return mk_err_msg(env, "bad_gpu_index",
                              "gpu_indexes=[" + want + "] but only " +
                              std::to_string(have) +
                              " GPU(s) available for backend=" + backend_pref);
        }
    }

    // n_gpu_layers < 0 表示"auto"：有 GPU 就全卸载（llama 里负值 = 所有层），
    // 没 GPU 就 0。这样调用方不必先问一遍有没有卡再决定传什么。
    //
    // ⚠️ **原始请求值要留一份**：下面会按实际有没有设备改写 n_gpu_layers，
    //    而 model_info 报的 gpu_layers_requested 必须是**调用方要的那个数**。
    //    用改写后的值去报，"我请求了 999"就变成"我请求了 0"——上报又开始撒谎了。
    const int32_t n_gpu_layers_req = n_gpu_layers;
    const bool auto_layers = (n_gpu_layers < 0);
    if (auto_layers) n_gpu_layers = devs.empty() ? 0 : -1;
    if (devs.empty()) n_gpu_layers = 0;   // 没设备就别声称要卸载

    // llama 要 NULL 结尾的清单；空清单传 nullptr（= 纯 CPU，因为 n_gpu_layers=0）。
    std::vector<ggml_backend_dev_t> dev_list;
    if (!devs.empty()) {
        dev_list = devs;
        dev_list.push_back(nullptr);
    }

    // ------------------------------------------------------------------
    // 装载 + 建上下文，一次尝试。
    //
    // ⚠️ **GPU 回落必须把"建上下文"也圈进去。** 最常见的显存不足是倒在
    //    llama_init_from_model 的 compute buffer 上，那时候权重早就装进显存了
    //    ——只对 llama_model_load_from_file 做回落，等于对这条最常见的路完全
    //    没有回落。
    // ------------------------------------------------------------------
    struct Loaded {
        llama_model*   model  = nullptr;
        llama_context* ctx    = nullptr;
        int32_t        n_ctx  = 0;
        int32_t        n_ctx_train = 0;
    };

    auto try_load = [&](int32_t ngl) -> Loaded {
        Loaded out;
        llama_model_params mp = llama_model_default_params();
        mp.n_gpu_layers = ngl;
        // ngl==0 的那一遍（回落）不要带设备清单，否则 llama 仍会为这些设备
        // 建 buffer。
        mp.devices = (ngl != 0 && !dev_list.empty()) ? dev_list.data() : nullptr;
        // 默认单卡（NONE）：嵌入模型切层跨卡是反优化，见 select_devices()。
        mp.split_mode = (split_pref == "layer") ? LLAMA_SPLIT_MODE_LAYER
                      : (split_pref == "row")   ? LLAMA_SPLIT_MODE_ROW
                                                : LLAMA_SPLIT_MODE_NONE;

        llama_model* m = llama_model_load_from_file(path.c_str(), mp);
        if (!m) return out;

        // n_ctx 是一个**真的性能旋钮**，不只是长度上限：计算图按它分配，取
        // n_ctx_train（Qwen3-Embedding 是 32768）会让每次前向都按最坏情况算。
        // 调用方给多少用多少，但**向下钳到 n_ctx_train**——嵌入模型超出训练
        // 长度没有任何正确的语义，钳的结果由 model_info 的 n_ctx 报出来。
        const int32_t n_ctx_train = llama_model_n_ctx_train(m);
        int32_t use_ctx = (n_ctx_req > 0) ? n_ctx_req : n_ctx_train;
        if (n_ctx_train > 0 && use_ctx > n_ctx_train) use_ctx = n_ctx_train;
        if (use_ctx <= 0) { llama_model_free(m); return out; }

        llama_context_params cp = llama_context_default_params();
        cp.embeddings = true;  // 要向量，不要 logits
        // ⚠️ **llama 的 n_ctx 是所有序列共享的总预算**：kv_unified=false（默认）
        //    时 n_ctx_seq = n_ctx / n_seq_max（llama-context.cpp:290）。
        //    我们的 n_ctx 语义是「每条文本的上下文」，所以这里必须乘上
        //    batch_size —— 不乘的话，一开批量就把每条文本的可用长度悄悄缩小
        //    batch_size 倍，原本放得下的文本开始报 too_many_tokens，而配置里
        //    的 n_ctx 一个字没变。
        cp.n_seq_max  = static_cast<uint32_t>(batch_size);
        cp.n_ctx      = static_cast<uint32_t>(use_ctx) * static_cast<uint32_t>(batch_size);
        // ⚠️ n_batch/n_ubatch 必须容得下**一次 decode 的全部 token**（批量时是
        //    所有序列之和），否则 llama_encode/decode 会拒绝整条 batch
        //    （返回负值，不是截断）。
        cp.n_batch    = cp.n_ctx;
        cp.n_ubatch   = cp.n_ctx;
        cp.pooling_type = (pooling < 0) ? LLAMA_POOLING_TYPE_UNSPECIFIED
                                        : static_cast<enum llama_pooling_type>(pooling);
        if (n_threads > 0) {
            cp.n_threads       = n_threads;
            cp.n_threads_batch = n_threads;
        }

        llama_context* c = llama_init_from_model(m, cp);
        if (!c) {
            // ⚠️ 必须把 model 收掉再返回——不收的话回落那一遍会再装一份权重，
            //    而第一份还占着显存，回落本身把显存又吃满一次。
            llama_model_free(m);
            return out;
        }
        out.model = m; out.ctx = c; out.n_ctx = use_ctx; out.n_ctx_train = n_ctx_train;
        return out;
    };

    bool        fell_back = false;
    std::string gpu_err;
    Loaded got = try_load(n_gpu_layers);
    if (!got.ctx && n_gpu_layers != 0) {
        // GPU 那次的错误留着——回落之后它是用户唯一能看到的"为什么没用上卡"。
        gpu_err = err_get();
        if (gpu_err.empty()) gpu_err = "GPU load failed (no reason reported)";
        err_clear();
        got = try_load(0);
        if (got.ctx) {
            fell_back = true;
        } else if (err_get().empty()) {
            err_set(gpu_err);
        }
    }
    if (!got.ctx) {
        return mk_err_last(env, "model_load_failed",
                           ("failed to load GGUF: " + path).c_str());
    }

    llama_model*   model       = got.model;
    llama_context* ctx         = got.ctx;
    const int32_t  use_ctx     = got.n_ctx;
    const int32_t  n_ctx_train = got.n_ctx_train;

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
    // ⚠️ 记 llama **实际**给出的每序列上下文，不是我们要的那个：n_ctx_seq 会被
    //    向下按 256 对齐（llama-context.cpp:291），报出来的必须是真值。
    r->n_ctx       = static_cast<int32_t>(llama_n_ctx_seq(ctx));
    r->n_ctx_train = n_ctx_train;
    r->batch_size  = static_cast<int32_t>(llama_n_seq_max(ctx));
    r->n_batch     = static_cast<int32_t>(llama_n_batch(ctx));
    r->pooling     = static_cast<int32_t>(llama_pooling_type(ctx));
    r->has_encoder = llama_model_has_encoder(model);
    r->size_bytes  = llama_model_size(model);
    // ⚠️ effective 按**实际选中的设备**算，不是按请求值 —— 没有 GPU 时 llama
    //    对 n_gpu_layers=999 不报错，只是默默不卸载。
    const int32_t n_gpu_dev = static_cast<int32_t>(devs.size());
    r->backend_requested = backend_pref;
    r->backend_chosen    = (n_gpu_dev > 0 && !fell_back) ? chosen_family : std::string();
    if (n_gpu_dev > 0 && !fell_back) {
        r->gpu_index_used = gpu_indexes.empty() ? 0 : gpu_indexes[0];
        // 组内所有设备名，逗号分隔——模型并行时"到底占了哪几张卡"必须可查。
        for (size_t i = 0; i < devs.size(); i++) {
            const char* dn = ggml_backend_dev_name(devs[i]);
            if (i) r->gpu_device += ",";
            r->gpu_device += dn ? dn : "";
        }
    }
    r->gpu_layers_requested = n_gpu_layers_req;
    if (backend_pref == "cpu") {
        r->gpu_layers_effective = 0;
        r->fell_back_to_cpu     = false;   // 明确要 CPU，不算回落
    } else if (n_gpu_layers_req == 0 && n_gpu_dev == 0) {
        r->gpu_layers_effective = 0;
        r->fell_back_to_cpu     = false;   // 本来就没要 GPU，不算回落
    } else if (auto_layers && n_gpu_dev == 0) {
        // auto 且这台机器没有可用 GPU —— 这是**正常的自动决策结果**，不是故障，
        // 所以不标 fell_back，但把原因留下，便于回答"为什么没用上卡"。
        r->gpu_layers_effective = 0;
        r->fell_back_to_cpu     = false;
        r->gpu_fallback_reason  = no_gpu_reason(backend_pref);
    } else if (n_gpu_dev == 0) {
        r->gpu_layers_effective = 0;
        r->fell_back_to_cpu     = true;
        r->gpu_fallback_reason = no_gpu_reason(backend_pref);
    } else if (fell_back) {
        r->gpu_layers_effective = 0;
        r->fell_back_to_cpu     = true;
        r->gpu_fallback_reason  = gpu_err;
    } else {
        r->gpu_layers_effective = n_gpu_layers;
        r->fell_back_to_cpu     = false;
    }
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

    // gpu_layers_requested / _effective / fell_back_to_cpu / gpu_fallback_reason：
    // ⚠️ 这四个是给"我明明有卡，怎么还是这么慢"用的。悄悄回落 CPU 的表现就是
    //    一切正常、只是慢十倍，屏幕上没有任何线索——除非上层去问这四个。
    const char* kn[] = {"dim", "n_embd", "n_ctx", "n_ctx_train",
                        "pooling_type", "has_encoder", "size_bytes", "description",
                        "gpu_layers_requested", "gpu_layers_effective",
                        "fell_back_to_cpu", "gpu_fallback_reason",
                        "backend_requested", "backend",
                        "gpu_index", "gpu_device",
                        "batch_size", "n_batch"};
    constexpr int kN = 18;
    ERL_NIF_TERM keys[kN];
    for (int i = 0; i < kN; i++) keys[i] = enif_make_atom(env, kn[i]);
    ERL_NIF_TERM vals[kN] = {
        enif_make_int(env, r->n_embd_out),
        enif_make_int(env, r->n_embd),
        enif_make_int(env, r->n_ctx),
        enif_make_int(env, r->n_ctx_train),
        enif_make_int(env, r->pooling),
        r->has_encoder ? g_true : g_false,
        enif_make_uint64(env, r->size_bytes),
        mk_bin(env, r->desc),
        enif_make_int(env, r->gpu_layers_requested),
        enif_make_int(env, r->gpu_layers_effective),
        r->fell_back_to_cpu ? g_true : g_false,
        mk_bin(env, r->gpu_fallback_reason),
        mk_bin(env, r->backend_requested),
        // 实际跑在哪个后端上："CUDA" / "Vulkan" / ""（= CPU）
        mk_bin(env, r->backend_chosen),
        enif_make_int(env, r->gpu_index_used),
        mk_bin(env, r->gpu_device),
        enif_make_int(env, r->batch_size),
        enif_make_int(env, r->n_batch),
    };
    ERL_NIF_TERM m;
    if (!enif_make_map_from_arrays(env, keys, vals, kN, &m)) return enif_make_badarg(env);
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
// NIF: embed_batch(Ref, [TextBin], Normalize, Truncate)
//        -> {ok, [{ok, Vec} | {error, Reason}]} | {error, Reason}
//
// 一次 decode 喂多条序列，池化后每条各出一个向量。索引侧的吞吐杠杆：单条路径
// 每次前向只喂一条，GPU/SIMD 的并行度大半闲着。
//
// === 返回形状：**逐条**结果，不是一个整体 ===
//
// 外层 {ok, _} 表示"这一批跑完了"，内层每条各自 {ok,Vec} / {error,Reason}。
// ⚠️ 一条坏文档不该让另外 63 条白算 —— 索引场景下整批失败意味着调用方要么
//    丢掉整批，要么退化成一条一条重试，两个都比逐条结果差。
//    顺序与输入严格一一对应（调用方靠下标对回自己的 key）。
//
// === 分块 ===
//
// 调用方可以一次丢进任意多条，这里按两个上限自动切块：
//   * 序列数 <= batch_size（llama 的 n_seq_max，建 context 时定死）
//   * token 总数 <= n_batch（超了 llama_decode 会**拒绝整块**，返回负值）
// ⚠️ 切块是必须的，不是优化：把 1000 条一次塞进去只会拿到一个负返回值，而那
//    个负值不会告诉你是因为太多。
// ---------------------------------------------------------------------------
ERL_NIF_TERM nif_embed_batch(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 4) return enif_make_badarg(env);
    ModelRes* r = get_model(env, argv[0]);
    if (!r) return enif_make_badarg(env);
    bool normalize = true, truncate = false;
    if (!get_bool(env, argv[2], normalize)) return enif_make_badarg(env);
    if (!get_bool(env, argv[3], truncate))  return enif_make_badarg(env);

    std::vector<std::string> texts;
    {
        ERL_NIF_TERM list = argv[1], head, tail;
        while (enif_get_list_cell(env, list, &head, &tail)) {
            std::string t;
            if (!get_bin_str(env, head, t)) return enif_make_badarg(env);
            texts.push_back(std::move(t));
            list = tail;
        }
        if (!enif_is_empty_list(env, list)) return enif_make_badarg(env);
    }
    if (texts.empty()) return enif_make_tuple2(env, g_ok, enif_make_list(env, 0));

    std::lock_guard<std::mutex> lk(r->mu);
    if (!r->ctx) return mk_err(env, "closed");

    const size_t n = texts.size();
    const size_t dim = static_cast<size_t>(r->n_embd_out);

    // 每条的结果先占位，最后按原顺序组表。
    std::vector<ERL_NIF_TERM> results(n);
    std::vector<bool>         done(n, false);

    // 先全部分词：哪些条根本进不了批（空、超长）在这里就定下来。
    std::vector<std::vector<llama_token>> toks(n);
    for (size_t i = 0; i < n; i++) {
        if (texts[i].empty()) {
            results[i] = mk_err(env, "empty_text"); done[i] = true; continue;
        }
        std::string terr;
        if (!tokenize(r->model, texts[i], toks[i], terr)) {
            results[i] = mk_err_msg(env, "tokenize_failed", terr); done[i] = true; continue;
        }
        if (toks[i].empty()) {
            results[i] = mk_err(env, "empty_token_sequence"); done[i] = true; continue;
        }
        const int32_t nt = static_cast<int32_t>(toks[i].size());
        if (nt > r->n_ctx) {
            if (!truncate) {
                results[i] = enif_make_tuple2(
                    env, g_error,
                    enif_make_tuple3(env, enif_make_atom(env, "too_many_tokens"),
                                     enif_make_int(env, nt),
                                     enif_make_int(env, r->n_ctx)));
                done[i] = true; continue;
            }
            toks[i].resize(static_cast<size_t>(r->n_ctx));
        }
    }

    // 贪心切块，逐块 decode。
    size_t i = 0;
    while (i < n) {
        std::vector<size_t> slot_of;   // 本块内 slot -> 原下标
        int32_t tok_total = 0;
        while (i < n && static_cast<int32_t>(slot_of.size()) < r->batch_size) {
            if (done[i]) { i++; continue; }
            const int32_t nt = static_cast<int32_t>(toks[i].size());
            // 放不下就先结这一块（但空块时必须放行，否则死循环）。
            if (!slot_of.empty() && r->n_batch > 0 && tok_total + nt > r->n_batch) break;
            tok_total += nt;
            slot_of.push_back(i);
            i++;
        }
        if (slot_of.empty()) continue;

        // 每块都是独立的一批，不能让上一块的状态留下来。
        llama_memory_clear(llama_get_memory(r->ctx), true);

        llama_batch batch = llama_batch_init(tok_total, 0, 1);
        if (!batch.token || !batch.pos || !batch.n_seq_id || !batch.seq_id || !batch.logits) {
            llama_batch_free(batch);
            return mk_err(env, "batch_alloc_failed");
        }
        int32_t p = 0;
        for (size_t slot = 0; slot < slot_of.size(); slot++) {
            const auto& tv = toks[slot_of[slot]];
            for (size_t k = 0; k < tv.size(); k++) {
                batch.token[p]     = tv[k];
                batch.pos[p]       = static_cast<llama_pos>(k);   // 每条序列各自从 0 开始
                batch.n_seq_id[p]  = 1;
                batch.seq_id[p][0] = static_cast<llama_seq_id>(slot);
                batch.logits[p]    = 1;   // 池化要每个位置都参与
                p++;
            }
        }
        batch.n_tokens = p;

        err_clear();
        const int32_t rc = r->has_encoder ? llama_encode(r->ctx, batch)
                                          : llama_decode(r->ctx, batch);
        llama_batch_free(batch);

        if (rc != 0) {
            // ⚠️ 整块失败只让**这一块**的条目失败，别的块照跑 —— 与逐条结果
            //    同一个理由。
            std::string d = err_get();
            if (d.empty()) {
                d = std::string(r->has_encoder ? "llama_encode" : "llama_decode") +
                    " returned " + std::to_string(rc);
            }
            for (size_t slot : slot_of) {
                results[slot] = mk_err_msg(env, "forward_failed", d);
                done[slot] = true;
            }
            continue;
        }

        for (size_t slot = 0; slot < slot_of.size(); slot++) {
            const size_t idx = slot_of[slot];
            const float* emb = llama_get_embeddings_seq(r->ctx, static_cast<llama_seq_id>(slot));
            if (!emb) {
                results[idx] = mk_err_msg(env, "no_embedding",
                                          "llama_get_embeddings_seq returned NULL for seq " +
                                          std::to_string(slot));
                done[idx] = true; continue;
            }
            std::vector<float> vec(dim);
            if (normalize) {
                double ss = 0.0;
                for (size_t k = 0; k < dim; k++) ss += static_cast<double>(emb[k]) * emb[k];
                if (!(ss > 0.0)) {
                    results[idx] = mk_err(env, "zero_norm"); done[idx] = true; continue;
                }
                const float inv = static_cast<float>(1.0 / std::sqrt(ss));
                for (size_t k = 0; k < dim; k++) vec[k] = emb[k] * inv;
            } else {
                std::memcpy(vec.data(), emb, dim * sizeof(float));
            }
            ERL_NIF_TERM out;
            unsigned char* dst = enif_make_new_binary(env, dim * 4, &out);
            write_f32_le(dst, vec.data(), dim);
            results[idx] = enif_make_tuple2(env, g_ok, out);
            done[idx] = true;
        }
    }

    return enif_make_tuple2(
        env, g_ok,
        enif_make_list_from_array(env, results.data(), static_cast<unsigned>(n)));
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
    {"build_info",     0, nif_build_info,     0},
    {"model_load",     9, nif_model_load,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"model_info",     1, nif_model_info,     0},
    {"model_close",    1, nif_model_close,    ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"tokenize_count", 2, nif_tokenize_count, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"embed",          4, nif_embed,          ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"embed_batch",    4, nif_embed_batch,    ERL_NIF_DIRTY_JOB_CPU_BOUND},
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
