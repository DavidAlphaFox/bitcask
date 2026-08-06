# ---------------------------------------------------------------------------
# bitcask_llama — 本地嵌入 NIF（priv/bitcask_llama.so）
#
# 只在根 CMakeLists 的 BITCASK_WITH_LLAMA=ON 时被 add_subdirectory 引入，
# 前提是顶层已经做过 add_subdirectory(third_party/llama.cpp)，即 llama /
# ggml-base / ggml-cpu-* 这些 target 已存在。选项在顶层设，不在这里。
#
# ─── 为什么是**第二个** .so，而不是并进 bitcask_cpp.so ────────────────────
#
# (甲) 依赖面。ggml 一带就是 ggml-base + 13 个 CPU 变体 + llama，几十 MB、
#      分钟级编译。核心 KV/检索 NIF 不该被它绑架——BITCASK_WITH_LLAMA=OFF 时
#      bitcask_cpp.so 与从前一字不差。
#
# (乙) 崩溃面。ggml 的 GGML_ASSERT 是 abort()，在 BEAM 里就是整个 node 连同
#      所有打开的 cask 一起没。分成两个 .so **不能**隔离这一点（同进程），但
#      至少让"谁把 node 干掉的"在 backtrace 里一眼可辨，也让不需要嵌入的部署
#      根本不加载这段代码。真要进程级隔离只能上 port，那是另一个决定。
#
# ─── 这个 target 比 bitcask_cpp 多出来的两件事 ───────────────────────────
#
# (丙) **它不是自包含的。** GGML_BACKEND_DL 要求 ggml-base 是**共享库**，运行时
#      dlopen 进来的变体要回头解析它的注册表符号。于是 priv/ 下会平铺出
#      libggml-base.so / libllama.so / libggml-cpu-*.so 一组，靠 $ORIGIN 找到
#      彼此。这是本仓库第一次出现「NIF 依赖同目录另一个动态库」。
#
#      平铺进 priv/ 而不是 priv/llama/ 的理由：shim 用
#      `ggml_backend_load_all_from_path(priv_dir)`，只搜那**一个**目录。
#      没有正确性风险——ggml 的变体发现是按文件名前缀 `libggml-<后端名>-`
#      匹配的（ggml/src/ggml-backend-reg.cpp），bitcask_cpp.so 永远匹配不上。
#      命名前缀也正好把归属分开：bitcask_* 是我们的，libggml-* / libllama* 是
#      vendored 的。
#
# (丁) **13 个变体没有任何 target 链接它们。** 它们是运行时按 CPU 微架构
#      dlopen 的，构建图上是孤儿。顶层用 EXCLUDE_FROM_ALL 引入 llama.cpp，
#      于是「没人依赖 = 不构建」——症状是构建全绿、跑起来
#      `ggml_backend_dev_count()` 返回 0，一路静默降级到没有嵌入能力。
#      所以下面显式 add_dependencies 把它们挂到 bitcask_llama 上。
#
#      ⚠️ 变体 target 的名字是 ggml 内部循环生成的（ggml_add_cpu_backend_variant，
#      x86 上 13 个，ARM 上另一套）。**别手写清单**——手写必漂，而漂掉的表现是
#      「少发了一个变体」，只有那一档 CPU 的用户会遇到，我们这边永远测不出来。
#      用 BUILDSYSTEM_TARGETS 枚举。
# ---------------------------------------------------------------------------

if(NOT TARGET llama)
    message(FATAL_ERROR
        "target `llama` not found. cpp/llama requires the top-level CMakeLists "
        "to have run add_subdirectory(third_party/llama.cpp) first.")
endif()

if(NOT Erlang_INCLUDE_DIR)
    message(FATAL_ERROR "BITCASK_WITH_LLAMA=ON 但没找到 Erlang 头文件；NIF 无法构建。")
endif()

add_library(bitcask_llama SHARED nif_llama.cpp)

target_include_directories(bitcask_llama PRIVATE ${Erlang_INCLUDE_DIR})

# llama 会传递带上 ggml / ggml-base。显式只列 llama：ggml 是它的实现细节，
# 而 shim 只调 llama.h 与 ggml-backend.h 里由 llama 传递过来的那份头。
target_link_libraries(bitcask_llama PRIVATE llama)

set_target_properties(bitcask_llama PROPERTIES
    # ⚠️ target 级 C++17（llama.cpp 自己要 17），不碰全局的 C++23。标准是
    #    target 级属性，不是全局的——这里设 17 不影响 bitcask_cpp。
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    POSITION_INDEPENDENT_CODE ON
    # 导出面收窄：NIF 只需要 nif_init 一个符号可见（ERL_NIF_INIT 自带
    # default visibility），其余全藏起来，免得与 bitcask_cpp.so 里同名的
    # libbitcask 符号在全局符号表里互相顶。
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    PREFIX ""
    SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
    OUTPUT_NAME "bitcask_llama")

if(DEFINED BITCASK_PRIV_DIR)
    set_target_properties(bitcask_llama PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}")
endif()

# (丙)：shim 与它依赖的 libggml-base.so / libllama.so 平铺在同一个目录，
# $ORIGIN 一条就够。没有这条的话，构建树里因为 CMake 自动塞了绝对路径 rpath
# 反而是好的，**只有装到别处之后才坏**——是最难发现的那一类。
if(NOT WIN32 AND NOT APPLE)
    set_property(TARGET bitcask_llama APPEND PROPERTY BUILD_RPATH "$ORIGIN")
    set_property(TARGET bitcask_llama APPEND PROPERTY INSTALL_RPATH "$ORIGIN")
endif()

# ---------------------------------------------------------------------------
# 把 vendored 的 ggml / llama 产物也平铺进 priv/
#
# 这些 target 属于 third_party/llama.cpp 的目录作用域，默认输出到它自己的 bin/。
# set_target_properties 对任意已存在的 target 都有效，不要求同目录。
#
# ⚠️ **必须递归下去**：`BUILDSYSTEM_TARGETS` 是**按目录**的，不递归。而 ggml 的
#    每个非 CPU 后端都走 `ggml_add_backend()` → `add_subdirectory(ggml-<name>)`，
#    于是 `ggml-vulkan` 这类 target 属于 `ggml/src/ggml-vulkan`，**不在**
#    `ggml/src` 那一层。只扫一层的话它不会被搬进 priv/，而 shim 用的是
#    `ggml_backend_load_all_from_path(priv_dir)`（只搜那一个目录）——
#    **表现是构建全绿、非 CPU 后端静静地不存在**。CPU 变体一直是对的纯属巧合：
#    它们由 `ggml_add_cpu_backend_variant()` 在 `ggml/src` 那一层直接造出来。
# ---------------------------------------------------------------------------

function(_bitcask_collect_targets_recursive out_var dir)
    set(_acc "")
    get_property(_ts DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
    list(APPEND _acc ${_ts})
    get_property(_subs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
    foreach(_sub IN LISTS _subs)
        _bitcask_collect_targets_recursive(_sub_acc "${_sub}")
        list(APPEND _acc ${_sub_acc})
    endforeach()
    set(${out_var} "${_acc}" PARENT_SCOPE)
endfunction()

set(_llama_vendor_dirs
    "${CMAKE_SOURCE_DIR}/third_party/llama.cpp/ggml/src"  # ggml / ggml-base / ggml-cpu-* / 各后端子目录
    "${CMAKE_SOURCE_DIR}/third_party/llama.cpp/src")      # llama

set(_llama_vendor_targets "")
foreach(_dir IN LISTS _llama_vendor_dirs)
    _bitcask_collect_targets_recursive(_ts "${_dir}")
    list(APPEND _llama_vendor_targets ${_ts})
endforeach()

if(NOT _llama_vendor_targets)
    message(FATAL_ERROR
        "no ggml/llama build targets found under third_party/llama.cpp. The "
        "upstream layout changed (expected ggml/src and src to declare the "
        "targets); the CPU-variant flattening below would silently ship nothing.")
endif()

set(_llama_runtime_targets "")
foreach(_t IN LISTS _llama_vendor_targets)
    get_target_property(_type ${_t} TYPE)
    # INTERFACE / UTILITY 上设输出目录是错误；OBJECT 库（ggml 的 *-feats）设了
    # 无害但也无意义——它们被链进变体里，不单独落盘。
    if(_type STREQUAL "SHARED_LIBRARY" OR _type STREQUAL "MODULE_LIBRARY")
        set_target_properties(${_t} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}"
            RUNTIME_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}"
            ARCHIVE_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}")
        if(NOT WIN32 AND NOT APPLE)
            set_property(TARGET ${_t} APPEND PROPERTY BUILD_RPATH "$ORIGIN")
            set_property(TARGET ${_t} APPEND PROPERTY INSTALL_RPATH "$ORIGIN")
        endif()
        list(APPEND _llama_runtime_targets ${_t})
    endif()
endforeach()

# (丁)：把运行时才 dlopen 的变体挂进构建图。没有这一步，EXCLUDE_FROM_ALL 会让
# 它们一个都不构建，而失败是静默的（0 个后端 → 降级 → 没有嵌入能力）。
if(NOT _llama_runtime_targets)
    message(FATAL_ERROR
        "ggml/llama 的 target 一个共享库都没有——BUILD_SHARED_LIBS 没生效？"
        "GGML_BACKEND_DL 要求 ggml-base 是共享库，这样下去运行时会 0 个后端。")
endif()
add_dependencies(bitcask_llama ${_llama_runtime_targets})

list(LENGTH _llama_runtime_targets _llama_n)
message(STATUS "bitcask_llama: ${_llama_n} vendored ggml/llama shared libs -> priv/")
