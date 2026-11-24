// malloc 计数 shim:LD_PRELOAD 后拦截分配族,driver 经 dlsym 读计数。
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

static atomic_ulong g_count;

unsigned long alloc_shim_count(void) {
    return atomic_load_explicit(&g_count, memory_order_relaxed);
}

static void* (*real_malloc)(size_t);
static void* (*real_calloc)(size_t, size_t);
static void* (*real_realloc)(void*, size_t);
static void (*real_free)(void*);
static int (*real_posix_memalign)(void**, size_t, size_t);
static void* (*real_aligned_alloc)(size_t, size_t);

// dlsym 自身会 calloc——bootstrap 期间从静态池里发。
static char boot_buf[65536];
static size_t boot_off;
static __thread int initing;

static void init_real(void) {
    initing = 1;
    real_malloc = (void* (*)(size_t))dlsym(RTLD_NEXT, "malloc");
    real_calloc = (void* (*)(size_t, size_t))dlsym(RTLD_NEXT, "calloc");
    real_realloc = (void* (*)(void*, size_t))dlsym(RTLD_NEXT, "realloc");
    real_free = (void (*)(void*))dlsym(RTLD_NEXT, "free");
    real_posix_memalign =
        (int (*)(void**, size_t, size_t))dlsym(RTLD_NEXT, "posix_memalign");
    real_aligned_alloc =
        (void* (*)(size_t, size_t))dlsym(RTLD_NEXT, "aligned_alloc");
    initing = 0;
}

static void* boot_alloc(size_t n) {
    void* p = boot_buf + boot_off;
    boot_off += (n + 15) & ~(size_t)15;
    return p;
}

static int is_boot(void* p) {
    return (char*)p >= boot_buf && (char*)p < boot_buf + sizeof(boot_buf);
}

void* malloc(size_t n) {
    if (!real_malloc) {
        if (initing) return boot_alloc(n);
        init_real();
    }
    atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    return real_malloc(n);
}

void* calloc(size_t a, size_t b) {
    if (!real_calloc) {
        if (initing) {
            void* p = boot_alloc(a * b);
            memset(p, 0, a * b);
            return p;
        }
        init_real();
    }
    atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    return real_calloc(a, b);
}

void* realloc(void* p, size_t n) {
    if (!real_realloc) init_real();
    atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    if (p && is_boot(p)) {
        void* q = real_malloc(n);
        memcpy(q, p, n);
        return q;
    }
    return real_realloc(p, n);
}

void free(void* p) {
    if (!p || is_boot(p)) return;
    if (!real_free) init_real();
    real_free(p);
}

int posix_memalign(void** out, size_t align, size_t n) {
    if (!real_posix_memalign) init_real();
    atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    return real_posix_memalign(out, align, n);
}

void* aligned_alloc(size_t align, size_t n) {
    if (!real_aligned_alloc) init_real();
    atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
    return real_aligned_alloc(align, n);
}
