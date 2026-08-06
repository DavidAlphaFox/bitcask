# ---------------------------------------------------------------------------
# bitcask_llama — 本地嵌入 NIF（priv/bitcask_llama.so）
#
# 只在根 CMakeLists 的 BITCASK_WITH_LLAMA=ON 时被 add_subdirectory 引入，
# 前提是顶层已经做过 add_subdirectory(third_party/llama.cpp)，即 llama /
# ggml-base / ggml-cpu-* 这些 target 已存在。选项在顶层设，不在这里。
#
# ─── 为什么是**第二个** .so，而不是并进 bitcask_cpp.so ────────────────────
#
# (甲) 依赖面。ggml 一带就是 ggml-base + 十几个 CPU 变体 + llama，几十 MB、
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
# (丁) **那些变体没有任何 target 链接它们。** 它们是运行时按 CPU 微架构
#      dlopen 的，构建图上是孤儿。顶层用 EXCLUDE_FROM_ALL 引入 llama.cpp，
#      于是「没人依赖 = 不构建」——症状是构建全绿、跑起来
#      `ggml_backend_dev_count()` 返回 0，一路静默降级到没有嵌入能力。
#      所以下面显式 add_dependencies 把它们挂到 bitcask_llama 上。
#
#      ⚠️ 变体 target 的名字是 ggml 内部循环生成的（ggml_add_cpu_backend_variant，
#      x86 上 14 个，ARM 上另一套；数目会随上游变）。**别手写清单**——手写必漂，
#      而漂掉的表现是
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

# ---------------------------------------------------------------------------
# 把**构建期事实**烧进 .so，运行期能自报家门。
#
# 为什么必须有这个：构建期和运行期问的是两件不同的事 ——
#   构建期：这台机器有没有 SDK？（决定编不编 CUDA 进去）
#   运行期：这台机器有没有对应的卡？（决定用不用得上）
# 两者可以在完全不同的机器上。没有这份自述的话，运行期看到"0 个 GPU 设备"
# 时**分不清**是包里没编 CUDA、还是包编了但这台机器没驱动/没卡 —— 而这两种
# 情况要修的东西完全不同（重新构建 vs 装驱动）。上一版的错误信息只能把两种
# 可能并列着猜，那不叫诊断。
# ---------------------------------------------------------------------------
if(BITCASK_LLAMA_CUDA_ENABLED)
    # 架构列表由 ggml 在它自己的目录作用域里定，这里从 target 属性上取
    # ——直接读 CMAKE_CUDA_ARCHITECTURES 在本作用域是空的。
    set(_cuda_archs "")
    if(TARGET ggml-cuda)
        get_target_property(_cuda_archs ggml-cuda CUDA_ARCHITECTURES)
    endif()
    if(NOT _cuda_archs)
        set(_cuda_archs "unknown")
    endif()
    string(REPLACE ";" "," _cuda_archs "${_cuda_archs}")
    target_compile_definitions(bitcask_llama PRIVATE
        BITCASK_LLAMA_BUILD_CUDA=1
        BITCASK_LLAMA_CUDA_VERSION="${CUDAToolkit_VERSION}"
        BITCASK_LLAMA_CUDA_ARCHS="${_cuda_archs}")
    message(STATUS "bitcask_llama: CUDA archs = ${_cuda_archs}")
else()
    target_compile_definitions(bitcask_llama PRIVATE BITCASK_LLAMA_BUILD_CUDA=0)
endif()

if(BITCASK_LLAMA_VULKAN_ENABLED)
    target_compile_definitions(bitcask_llama PRIVATE BITCASK_LLAMA_BUILD_VULKAN=1)
else()
    target_compile_definitions(bitcask_llama PRIVATE BITCASK_LLAMA_BUILD_VULKAN=0)
endif()

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

# ⚠️ 开了 CUDA 却没找到 ggml-cuda target —— **当场炸**。
#    这正是上面那段注释描述的静默失败：没有这一条的话，症状是构建全绿、
#    libggml-cuda.so 落在 llama.cpp 自己的 bin/ 里（或者根本没建），而 shim 只
#    搜 priv/ —— GPU 后端会静静地不存在，用户看到的只是"我明明有卡，怎么还是
#    这么慢"。`ggml-cuda` 属于 ggml/src/ggml-cuda 子目录，靠上面的递归收集拿到。
if(BITCASK_LLAMA_CUDA_ENABLED AND NOT "ggml-cuda" IN_LIST _llama_vendor_targets)
    message(FATAL_ERROR
        "CUDA 已启用（找到了 CUDA Toolkit）但没在 third_party/llama.cpp 里找到 "
        "ggml-cuda target。上游把后端目录布局改了？不修的话发布出去的包里没有 "
        "GPU 后端，而所有测试都是绿的。")
endif()
if(BITCASK_LLAMA_VULKAN_ENABLED AND NOT "ggml-vulkan" IN_LIST _llama_vendor_targets)
    message(FATAL_ERROR
        "Vulkan 已启用但没在 third_party/llama.cpp 里找到 ggml-vulkan target。"
        "同上：`ggml-vulkan` 属于 ggml/src/ggml-vulkan 子目录，靠上面的递归收集"
        "拿到；漏了的话包里没有 Vulkan 后端而所有测试都是绿的。")
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

# ---------------------------------------------------------------------------
# CUDA 运行时库也平铺进 priv/
#
# 为什么要做这件事：GGML_STATIC 与 BUILD_SHARED_LIBS=ON 冲突（根 CMakeLists 里
# 论证过），所以 libggml-cuda.so 是**动态**链 cudart / cublas / cublasLt 的。
# 不带上它们的话，部署到一台只装了驱动、没装 CUDA Toolkit 的机器上，表现是
# dlopen libggml-cuda.so 失败 —— 而 ggml 对后端加载失败是**容忍**的（
# ggml-backend-reg.cpp 里 dlopen 失败只是跳过），于是**静默降级成纯 CPU**。
# 又一次"我明明有卡怎么还这么慢"。
#
# bitcask 是服务器产品，取舍是性能优先、体积不是约束 —— cuBLAS 确实很大
# （CUDA 12 下几百 MB），但换掉的是一整类"在构建机上好好的、到目标机就没
# GPU"的故障。要关掉设 -DBITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=OFF（那样目标机
# 必须自己装匹配版本的 CUDA 运行时）。
#
# ⚠️ 只带**运行时**，不带驱动：libcuda.so.1 来自 NVIDIA 驱动，必须由目标机的
#    驱动提供，版本还得与 GPU 匹配 —— 那个不能也不该由我们分发。
# ---------------------------------------------------------------------------
option(BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME
       "Copy the CUDA runtime libs (cudart/cublas/cublasLt) next to the NIF in priv/" ON)

if(BITCASK_LLAMA_CUDA_ENABLED AND BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME)
    set(_cuda_runtime_files "")
    foreach(_cu IN ITEMS CUDA::cudart CUDA::cublas CUDA::cublasLt)
        if(TARGET ${_cu})
            get_target_property(_loc ${_cu} IMPORTED_LOCATION)
            if(NOT _loc)
                # 多配置导入目标（Release/Debug）时 IMPORTED_LOCATION 是空的。
                get_target_property(_cfgs ${_cu} IMPORTED_CONFIGURATIONS)
                foreach(_cfg IN LISTS _cfgs)
                    get_target_property(_loc ${_cu} IMPORTED_LOCATION_${_cfg})
                    if(_loc)
                        break()
                    endif()
                endforeach()
            endif()
            if(_loc AND EXISTS "${_loc}")
                # ⚠️ 要把 SONAME 链也带上：CMake 给的是 libcublas.so（开发符号
                #    链接），而 libggml-cuda.so 的 DT_NEEDED 记的是
                #    libcublas.so.12。只拷前者的话运行时照样找不到。
                #    GET_RUNTIME_DEPENDENCIES 太重，这里按实际文件 + 其 realpath
                #    一起拷，两个名字都落地。
                get_filename_component(_real "${_loc}" REALPATH)
                list(APPEND _cuda_runtime_files "${_loc}")
                if(NOT _real STREQUAL _loc)
                    list(APPEND _cuda_runtime_files "${_real}")
                endif()
                # SONAME（libX.so.12）是 DT_NEEDED 里的那个名字，单独找一遍。
                get_filename_component(_dir "${_real}" DIRECTORY)
                get_filename_component(_base "${_loc}" NAME)
                file(GLOB _soname_links "${_dir}/${_base}.[0-9]*")
                list(APPEND _cuda_runtime_files ${_soname_links})
            endif()
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _cuda_runtime_files)

    if(_cuda_runtime_files)
        # copy_if_different：每次 rebar3 compile 都重拷几百 MB 是不能接受的。
        add_custom_command(TARGET bitcask_llama POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    ${_cuda_runtime_files} "${BITCASK_PRIV_DIR}"
            COMMENT "bitcask_llama: 拷 CUDA 运行时库到 priv/"
            VERBATIM)
        install(FILES ${_cuda_runtime_files} DESTINATION "priv")
        list(LENGTH _cuda_runtime_files _cuda_n)
        message(STATUS "bitcask_llama: ${_cuda_n} CUDA runtime files -> priv/")
    else()
        message(WARNING
            "BITCASK_LLAMA_CUDA_BUNDLE_RUNTIME=ON 但没能从 CUDAToolkit 的导入目标 "
            "解析出 cudart/cublas/cublasLt 的路径。目标机上缺这几个 .so 时，"
            "libggml-cuda.so 会 dlopen 失败，而 ggml 容忍加载失败 —— 表现是"
            "**静默降级成纯 CPU**，不是报错。")
    endif()
endif()
