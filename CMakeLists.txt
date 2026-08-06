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
# libbitcask — git submodule at third_party/libbitcask (v5.0.0, commit aaac44c)。
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
