cmake_minimum_required(VERSION 3.20)
project(bitcask CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
find_package(Erlang REQUIRED)

# Output the NIF .so directly into priv/.
set(BITCASK_PRIV_DIR "${CMAKE_SOURCE_DIR}/priv")
file(MAKE_DIRECTORY "${BITCASK_PRIV_DIR}")

# ---------------------------------------------------------------------------
# libbitcask — git submodule at third_party/libbitcask (6.0.0, commit 3480d0f)。
# 提供 C++ 核心库全部 target（bitcask_cask, bitcask_keydir, ...）。
#
# libbitcask 的 CMakeLists.txt 用 CMAKE_SOURCE_DIR 引用 third_party/
# 依赖路径。在 add_subdirectory 上下文中 CMAKE_SOURCE_DIR 指向本项目根目录，
# 所以需要把 libbitcask/third_party/* 链射到本项目的 third_party/* 下。
# v1.1.0 新增 unordered_dense（KeyDir 稠密扁平表）依赖。
# v3.0.0：破坏性 ABI 变更（SOVERSION 1→3），同义词词典改为 open-time 不可变
# 配置（CaskOptions::synonym_map），运行期 set_synonym_map 已删除。
# v3.1.0：向后兼容功能新增（SOVERSION 保持 3、ABI 未破坏）——read 句柄默认上限
# （max_read_handles=0 改为按 RLIMIT_NOFILE 自动推导，unlimited 显式不限）、reducer
# 线程内自动 compaction（auto_compact_dead_ratio）、CaskError::kClosed。
# v4.0.0：破坏性 ABI 变更（SOVERSION 3→4，bitcask_options_t 布局变更；源码级
# 向后兼容，重编即可）——向量双引擎 vector_engine（hnsw 默认 / ivfrq 磁盘档 /
# diskann 实验性，建库选定持久化进 meta，不符 → mode_mismatch）、AVX2 int8
# 内核 + HNSW 混合精度建图导航（hnsw_build_nav_int8，默认开）、向量 ckpt
# 崩溃恢复有界（vector_rebase_min_docs）、search_layer.hpp 拆分为
# search_config.hpp（NIF include 已随迁）。
# ⚠️ 盘上格式：bitcask.meta 升至 v3（加 CRC），本版写出的库不能被 3.0.0 打开（反向
# 兼容旧库读）。升级请单向进行。
# v4.1.0：纯修复 + 内部重构（SOVERSION 保持 4、ABI 未破坏、盘上格式不变）——
# Phase 5/6 深度审计：IndexPool::submit 计数泄漏 + unregister_lib 无界 flush
# 导致的进程级挂死、RowChunks/MmapSegment 分配抛出泄漏、hnsw 三处原子写
# rename 前补 fdatasync（此前无 sync，崩溃即半截文件）。公开 API 零变更，
# NIF 无需改动（仅被移除的 meta_codec::detail::vbyte_* / to_codepoints_reuse
# 等内部符号，NIF 全未引用）。
# v5.0.0：64 位时间戳 flag-day（SOVERSION 4→5，ABI + 盘上格式双破坏）。
# 6.0.0：一次跨上游 5.1.0 + 6.0.0 两版。ABI 破坏（CaskOptions 新增
# keydir_cache_entries → 结构体布局变更，SOVERSION 5→6），但本仓库是源码级
# 依赖（add_subdirectory），重编即可，不存在链接旧 .so.5 的问题。
# 新增可用的公开 API：Cask::make_range_iter / CaskRangeIter（OKI 有序范围
# 查询）、Cask::put_batch_atomic（引擎原子批）、TxnCask（多键事务）——三者
# 都已在 cpp/nif/nif_cask_range.cpp 与 nif_cask_batch.cpp 里开到 Erlang 侧。
# ⚠️ 盘上格式：上游 5.1.0 的 hint 内嵌 ord flag-day 把 bitcask.meta v4 → v5，
# **本仓库 5.x 写出的目录必须先离线迁移**才能被本版打开：
#     _build/cmake/libbitcask-build/bitcask_migrate hintord <src> <dst>
# 非破坏性（data 硬链接、字节零改动，只重生成 hint + meta），幂等可重跑。
# 6.0.0 自身新增的 BCOK v2 / BCOM v2-v3 / BCKS v4 都是派生缓存演进，旧版遇到
# 即弃用重建，不需要迁移。

# ---------------------------------------------------------------------------
foreach(_dep utf8proc cppjieba limonp googletest benchmark oneTBB unordered_dense)
    set(_src "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libbitcask/third_party/${_dep}")
    set(_dst "${CMAKE_CURRENT_SOURCE_DIR}/third_party/${_dep}")
    if(EXISTS "${_src}" AND NOT EXISTS "${_dst}")
        file(CREATE_LINK "${_src}" "${_dst}" SYMBOLIC)
    endif()
endforeach()

add_subdirectory("${CMAKE_SOURCE_DIR}/third_party/libbitcask"
                 "${CMAKE_BINARY_DIR}/libbitcask-build")

# ---------------------------------------------------------------------------
# llama.cpp — 本地嵌入后端，git submodule at third_party/llama.cpp（tag b10257）。
#
# **默认关**。打开：cmake -DBITCASK_WITH_LLAMA=ON。理由不是保守，是成本：
# 打开之后 priv/ 下会多出 ggml-base + 13 个 CPU 变体 + llama 一组共享库，首次
# 全量编译是分钟级。核心 NIF（priv/bitcask_cpp.so）与它**完全无关**，不链接
# 任何 ggml 符号——关掉这个开关时本仓库的构建与从前一字不差。
#
# 产物是**独立的第二个 NIF**：priv/bitcask_llama.so ← cpp/llama/。
# 布局与调用约定见 cpp/llama/CMakeLists.txt 与 nif_llama.cpp 的头注释。
# ---------------------------------------------------------------------------
option(BITCASK_WITH_LLAMA "Build the local llama.cpp embedding NIF (priv/bitcask_llama.so)" OFF)

if(BITCASK_WITH_LLAMA)
    if(NOT EXISTS "${CMAKE_SOURCE_DIR}/third_party/llama.cpp/CMakeLists.txt")
        message(FATAL_ERROR
            "BITCASK_WITH_LLAMA=ON 但 third_party/llama.cpp 是空的。先拉子模块：\n"
            "  git submodule update --init third_party/llama.cpp")
    endif()

    # ⚠️ 这三个开关是**一组**，缺一个就没有意义（ggml 自己也会检查：
    #    ALL_VARIANTS 没有 BACKEND_DL 是 FATAL_ERROR）：
    #      GGML_NATIVE=OFF + GGML_BACKEND_DL=ON + GGML_CPU_ALL_VARIANTS=ON
    #    GGML_NATIVE 默认 ON，会按**构建机**的指令集编译，产物在老 CPU 上是
    #    SIGILL 当场崩，不是降速——而 BEAM 里一个 SIGILL 就是整个 node 没了。
    set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
    set(GGML_BACKEND_DL        ON  CACHE BOOL "" FORCE)
    set(GGML_CPU_ALL_VARIANTS  ON  CACHE BOOL "" FORCE)

    # ⚠️ BUILD_SHARED_LIBS 是**必须**的，不是偏好：GGML_BACKEND_DL 要求
    #    ggml-base 是共享库，运行时 dlopen 进来的变体要回头解析它的注册表符号。
    set(BUILD_SHARED_LIBS      ON  CACHE BOOL "" FORCE)

    # 只要推理内核。COMMON 是 Jinja 模板那一层（chat/tool 方言），嵌入用不上；
    # 关掉省掉 arg/download/console/sampling 一整串。
    # ⚠️ 前两个默认值会破坏离线构建：LLAMA_USE_PREBUILT_UI 会在构建期从 HF
    #    Bucket **下载** Web UI，LLAMA_OPENSSL 会 find_package(OpenSSL)。
    set(LLAMA_BUILD_COMMON     OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS      OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER     OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_APP        OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_UI         OFF CACHE BOOL "" FORCE)
    set(LLAMA_USE_PREBUILT_UI  OFF CACHE BOOL "" FORCE)
    set(LLAMA_OPENSSL          OFF CACHE BOOL "" FORCE)
    set(LLAMA_CURL             OFF CACHE BOOL "" FORCE)

    # -----------------------------------------------------------------------
    # GPU 后端：CUDA（NVIDIA）
    #
    # BITCASK_LLAMA_CUDA = AUTO（默认）| ON | OFF
    #   AUTO — 找得到 CUDA Toolkit 就开，找不到就静静地只用 CPU（但会打一条
    #          STATUS 说明，别让"没用上卡"变成无声的事）。
    #   ON   — 硬要求，找不到 Toolkit 直接 FATAL_ERROR。CI / 发布构建用这个：
    #          AUTO 在缺 toolkit 的机器上会**悄悄**产出一个纯 CPU 的包，而那种
    #          包与 GPU 包长得一模一样。
    #   OFF  — 不编。
    #
    # bitcask 是跑在服务器上的产品，取舍是**性能优先，体积不是约束**，所以：
    #   * 默认 AUTO 而不是 OFF——有卡就用上；
    #   * CUDA 架构列表用 ggml 的默认值（GGML_NATIVE=OFF 时它给的是
    #     50/61/70/75/80-virtual + 86/89-real + 90-virtual + Blackwell，覆盖
    #     Maxwell 到 Blackwell 的一整条线），不收窄成 native。产物大得多，但
    #     "换一台机器就 SIGILL / 没有可用 kernel"这类事不会发生。
    #     要收窄自己设 -DCMAKE_CUDA_ARCHITECTURES=89-real 之类。
    #
    # ⚠️ **GGML_STATIC 不能用**（试过）：它在 ggml/src/CMakeLists.txt:116 加的是
    #    全局 `add_link_options(-static)`，与我们必须开的 BUILD_SHARED_LIBS=ON
    #    直接冲突。所以 libggml-cuda.so 是**动态**链 cudart / cublas /
    #    cublasLt 的，目标机上必须有这三个 .so —— 见 cpp/llama/CMakeLists.txt
    #    里把它们平铺进 priv/ 的那一段。
    # -----------------------------------------------------------------------
    set(BITCASK_LLAMA_CUDA "AUTO" CACHE STRING
        "CUDA backend for the local embedder: AUTO | ON | OFF")
    set_property(CACHE BITCASK_LLAMA_CUDA PROPERTY STRINGS AUTO ON OFF)
    string(TOUPPER "${BITCASK_LLAMA_CUDA}" _bitcask_cuda_mode)

    if(_bitcask_cuda_mode STREQUAL "AUTO" OR _bitcask_cuda_mode STREQUAL "ON")
        # 自己先找一遍，**不要**等 ggml 那边 find_package 失败——它那条路的表现
        # 是"GGML_CUDA=ON 但 ggml-cuda target 根本没建出来"，构建全绿、跑起来
        # 没有 GPU 后端，正是本文件到处在防的那种静默失败。
        find_package(CUDAToolkit QUIET)
        if(CUDAToolkit_FOUND)
            set(GGML_CUDA ON CACHE BOOL "" FORCE)
            set(BITCASK_LLAMA_CUDA_ENABLED ON)
            message(STATUS
                "bitcask_llama: CUDA backend ON (CUDA Toolkit ${CUDAToolkit_VERSION} "
                "at ${CUDAToolkit_LIBRARY_ROOT})")
        elseif(_bitcask_cuda_mode STREQUAL "ON")
            message(FATAL_ERROR
                "BITCASK_LLAMA_CUDA=ON 但找不到 CUDA Toolkit。\n"
                "装上 toolkit（nvcc + cublas 开发包），或者设 "
                "-DBITCASK_LLAMA_CUDA=OFF / AUTO。\n"
                "先跑 scripts/detect-llama-backends.sh 看这台机器缺什么。")
        else()
            message(STATUS
                "bitcask_llama: CUDA backend OFF (AUTO: no CUDA Toolkit found). "
                "CPU only -- run scripts/detect-llama-backends.sh to see why.")
        endif()
    endif()

    # -----------------------------------------------------------------------
    # GPU 后端：Vulkan（非 NVIDIA 卡的路，AMD / Intel / 以及 NVIDIA 也能跑）
    #
    # BITCASK_LLAMA_VULKAN = AUTO（默认）| ON | OFF，语义与 CUDA 那组一致。
    #
    # ⚠️ **AUTO 必须把两个依赖都确认到位再开。** ggml-vulkan 的 CMakeLists 里
    #    那两句都是 REQUIRED：
    #        find_package(Vulkan COMPONENTS glslc REQUIRED)
    #        find_package(SPIRV-Headers CONFIG REQUIRED)
    #    只探到其中一个就把 GGML_VULKAN 打开的话，AUTO 会**直接把构建炸掉**
    #    ——而 AUTO 的全部意义就是"没有就安静地不编"。
    #
    # 与 CUDA 同时开是允许的，而且是有意义的（一台机器可能既有 N 卡又有核显）。
    # ⚠️ 但两个后端会**各自枚举同一张物理卡**，运行期必须显式选设备，不能让
    #    llama 按 devices=NULL 把同一张卡当成两张去切分 —— 见
    #    cpp/llama/nif_llama.cpp 的 select_devices()。
    # -----------------------------------------------------------------------
    set(BITCASK_LLAMA_VULKAN "AUTO" CACHE STRING
        "Vulkan backend for the local embedder: AUTO | ON | OFF")
    set_property(CACHE BITCASK_LLAMA_VULKAN PROPERTY STRINGS AUTO ON OFF)
    string(TOUPPER "${BITCASK_LLAMA_VULKAN}" _bitcask_vk_mode)

    if(_bitcask_vk_mode STREQUAL "AUTO" OR _bitcask_vk_mode STREQUAL "ON")
        if(DEFINED ENV{VULKAN_SDK})
            list(APPEND CMAKE_PREFIX_PATH "$ENV{VULKAN_SDK}")
        endif()
        find_package(Vulkan QUIET COMPONENTS glslc)
        find_package(SPIRV-Headers QUIET CONFIG)

        set(_vk_missing "")
        if(NOT Vulkan_FOUND)
            list(APPEND _vk_missing "Vulkan loader/headers")
        endif()
        if(NOT Vulkan_glslc_FOUND)
            list(APPEND _vk_missing "glslc (shaderc)")
        endif()
        if(NOT SPIRV-Headers_FOUND)
            list(APPEND _vk_missing "SPIRV-Headers")
        endif()

        if(NOT _vk_missing)
            set(GGML_VULKAN ON CACHE BOOL "" FORCE)
            set(BITCASK_LLAMA_VULKAN_ENABLED ON)
            message(STATUS "bitcask_llama: Vulkan backend ON (glslc at ${Vulkan_GLSLC_EXECUTABLE})")
        elseif(_bitcask_vk_mode STREQUAL "ON")
            string(REPLACE ";" ", " _vk_missing_str "${_vk_missing}")
            message(FATAL_ERROR
                "BITCASK_LLAMA_VULKAN=ON 但缺：${_vk_missing_str}\n"
                "装 Vulkan SDK（或发行版的 vulkan-headers / shaderc /"
                " spirv-headers 开发包），或设 -DBITCASK_LLAMA_VULKAN=OFF / AUTO。\n"
                "先跑 scripts/detect-llama-backends.sh 看这台机器缺什么。")
        else()
            string(REPLACE ";" ", " _vk_missing_str "${_vk_missing}")
            message(STATUS
                "bitcask_llama: Vulkan backend OFF (AUTO: missing ${_vk_missing_str})")
        endif()
    endif()

    if(NOT BITCASK_LLAMA_CUDA_ENABLED AND NOT BITCASK_LLAMA_VULKAN_ENABLED)
        message(STATUS
            "bitcask_llama: no GPU backend will be built -- CPU only. "
            "Run scripts/detect-llama-backends.sh to see what this machine is missing.")
    endif()

    # ⚠️ llama.cpp 的 CMakeLists **没有** set(CMAKE_CXX_STANDARD ...)——它把这件
    #    事留给 LLAMA_STANDALONE 那条路。所以 add_subdirectory 进来时它一声不响
    #    地继承本仓库的 C++23，而它的源码是按 C++17 写的（`u8"..."` 字面量在
    #    C++20 起是 char8_t，一路 error）。收窄到 17，出来再还回去。
    set(CMAKE_CXX_STANDARD 17)
    add_subdirectory("${CMAKE_SOURCE_DIR}/third_party/llama.cpp"
                     "${CMAKE_BINARY_DIR}/llama-build" EXCLUDE_FROM_ALL)
    set(CMAKE_CXX_STANDARD 23)

    # ⚠️ BUILD_SHARED_LIBS 是**目录作用域会继承的全局变量**，上面那个 FORCE 会被
    #    后面每一个 add_subdirectory 看见——不收回去的话 cpp/ 下的 target 以及
    #    将来新增的依赖会跟着从静态变成共享。这里 libbitcask 已经在上面加完了
    #    （它的 add_library 全部显式 STATIC，本来就不受影响），但别指望这一点。
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
endif()

enable_testing()
add_subdirectory(cpp)

message(STATUS "bitcask: C++${CMAKE_CXX_STANDARD}, ERTS ${Erlang_ERTS_VERSION}, headers at ${Erlang_INCLUDE_DIR}")
