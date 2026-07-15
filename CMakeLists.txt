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
# libbitcask — git submodule at third_party/libbitcask (v4.1.0, commit 66924e3)。
# ⚠️ 上游 v4.1.0 只有 release commit、**未打 tag**（git describe = v4.0.0-32-g66924e3），
# 故此处按 commit 固定；上游补 tag 后可改回 tag 引用。
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

enable_testing()
add_subdirectory(cpp)

message(STATUS "bitcask: C++${CMAKE_CXX_STANDARD}, ERTS ${Erlang_ERTS_VERSION}, headers at ${Erlang_INCLUDE_DIR}")
