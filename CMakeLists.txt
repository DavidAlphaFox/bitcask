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
# libbitcask — git submodule at third_party/libbitcask (tag v1.1.0)。
# 提供 C++ 核心库全部 target（bitcask_cask, bitcask_keydir, ...）。
#
# libbitcask 的 CMakeLists.txt 用 CMAKE_SOURCE_DIR 引用 third_party/
# 依赖路径。在 add_subdirectory 上下文中 CMAKE_SOURCE_DIR 指向本项目根目录，
# 所以需要把 libbitcask/third_party/* 链射到本项目的 third_party/* 下。
# v1.1.0 新增 unordered_dense（KeyDir 稠密扁平表）依赖。
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
