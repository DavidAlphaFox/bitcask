# 允许 cpp/ 子目录独立构建（不经过顶层 CMake）。
if(NOT DEFINED CMAKE_CXX_STANDARD)
    cmake_minimum_required(VERSION 3.20)
    project(bitcask_cpp CXX)
    set(CMAKE_CXX_STANDARD 23)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)
    enable_testing()
endif()

# Common warning flags for all bitcask C++ targets.
add_library(bitcask_warnings INTERFACE)
target_compile_options(bitcask_warnings INTERFACE
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion
    -Wnon-virtual-dtor -Wold-style-cast
    -Wcast-align -Woverloaded-virtual
    -fvisibility=hidden -fvisibility-inlines-hidden
)

find_package(ZLIB REQUIRED)
find_package(TBB REQUIRED)

# 当从 cpp/ 子目录独立构建时（不经过顶层 CMake），提供 bitcask_sanitizers
# 的空壳 target，使测试 target 能正常链接。
if(NOT TARGET bitcask_sanitizers)
    add_library(bitcask_sanitizers INTERFACE)
endif()

# ---------------------------------------------------------------------------
# bitcask_format — codec for data file / hint file records.
# Pure library, zero Erlang/OTP dependency. Reused by core lib + tests.
# ---------------------------------------------------------------------------
add_library(bitcask_format STATIC
    src/fileops/codec.cpp
)
target_include_directories(bitcask_format PUBLIC include)
target_link_libraries(bitcask_format
    PUBLIC ZLIB::ZLIB
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_fileops — DataFile + HintFile abstractions over PosixFile + codec.
# ---------------------------------------------------------------------------
add_library(bitcask_fileops STATIC
    src/fileops/data_file.cpp
    src/fileops/hint_file.cpp
    src/fileops/scanner.cpp
)
target_include_directories(bitcask_fileops PUBLIC include)
target_link_libraries(bitcask_fileops
    PUBLIC bitcask_format bitcask_io
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_io — POSIX file + advisory lock primitives.
# Pure C++. Used by Collection and by C++ unit tests directly.
# ---------------------------------------------------------------------------
add_library(bitcask_io STATIC
    src/io/posix_file.cpp
    src/lock/file_lock.cpp
)
target_include_directories(bitcask_io PUBLIC include)
target_link_libraries(bitcask_io PRIVATE bitcask_warnings)

# ---------------------------------------------------------------------------
# bitcask_keydir — in-memory keydir (KeyDir class for bitcask).
# ---------------------------------------------------------------------------
add_library(bitcask_keydir STATIC
    src/keydir/keydir.cpp
    src/keydir/keydir_registry.cpp
)
target_include_directories(bitcask_keydir PUBLIC include)
target_link_libraries(bitcask_keydir
    PUBLIC  bitcask_fileops bitcask_io
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_index — in-memory Index side tables (vector DB V1, §3.1).
# Replaces the legacy bitcask_keydir.
# ---------------------------------------------------------------------------
add_library(bitcask_index STATIC
    src/keydir/index.cpp
)
target_include_directories(bitcask_index PUBLIC include)
target_link_libraries(bitcask_index
    PUBLIC  bitcask_text
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_bm25 — BM25 倒排索引（InvertedIndex + DAAT 评分）。
# ---------------------------------------------------------------------------
add_library(bitcask_bm25 STATIC
    src/bm25/inverted.cpp
    src/bm25/query_parser.cpp
)
target_include_directories(bitcask_bm25 PUBLIC include)
target_link_libraries(bitcask_bm25 PRIVATE bitcask_warnings TBB::tbb)

# ---------------------------------------------------------------------------
# bitcask_search — SearchLayer (Index + InvertedIndex + Analyzer wrapper).
# ---------------------------------------------------------------------------
add_library(bitcask_search STATIC
    src/search/search_cache.cpp
    src/search/search_layer.cpp
    src/search/highlighter.cpp
)
target_include_directories(bitcask_search PUBLIC include)
target_link_libraries(bitcask_search
    PUBLIC  bitcask_index bitcask_bm25 bitcask_text
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_collection — vector DB facade (upsert/get/remove/search_text + recovery).
# Reuses fileops + index + io + text + bm25.
# ---------------------------------------------------------------------------
add_library(bitcask_collection STATIC
    src/cask/collection.cpp
    src/cask/collection_registry.cpp
)
target_include_directories(bitcask_collection PUBLIC include)
target_link_libraries(bitcask_collection
    PUBLIC  bitcask_fileops bitcask_index bitcask_io bitcask_text bitcask_bm25
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_merge — merge 策略 + 执行。
# ---------------------------------------------------------------------------
add_library(bitcask_merge STATIC
    src/merge/merger.cpp
    src/merge/merge_policy.cpp
)
target_include_directories(bitcask_merge PUBLIC include)
target_link_libraries(bitcask_merge
    PUBLIC  bitcask_keydir bitcask_fileops bitcask_io bitcask_format bitcask_search
    PRIVATE bitcask_warnings
)

# ---------------------------------------------------------------------------
# bitcask_cask — legacy Cask KV store (CRUD + merge + iterators).
# ---------------------------------------------------------------------------
add_library(bitcask_cask STATIC
    src/cask/cask.cpp
    src/cask/meta_file.cpp
)
target_include_directories(bitcask_cask PUBLIC include)
target_link_libraries(bitcask_cask
    PUBLIC  bitcask_keydir bitcask_fileops bitcask_io bitcask_format bitcask_merge bitcask_search
    PRIVATE bitcask_warnings TBB::tbb
)

# ---------------------------------------------------------------------------
# utf8proc — Unicode NFKC 归一化 + case fold。
# 优先使用 FetchContent；若 _deps 下已有手动 clone 则直接 add_subdirectory。
# ---------------------------------------------------------------------------
include(FetchContent)
if(EXISTS "${CMAKE_BINARY_DIR}/_deps/utf8proc-src/CMakeLists.txt")
    add_subdirectory("${CMAKE_BINARY_DIR}/_deps/utf8proc-src"
                     "${CMAKE_BINARY_DIR}/_deps/utf8proc-build")
else()
    FetchContent_Declare(
        utf8proc
        GIT_REPOSITORY https://github.com/JulieStrings/utf8proc.git
        GIT_TAG        v2.10.0
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(utf8proc)
endif()

# ---------------------------------------------------------------------------
# cppjieba — jieba 中文分词（header-only，依赖 limonp）。
# ---------------------------------------------------------------------------
if(NOT TARGET cppjieba)
    add_library(cppjieba INTERFACE)
    target_include_directories(cppjieba INTERFACE
        "${CMAKE_BINARY_DIR}/_deps/cppjieba-src/include"
        "${CMAKE_BINARY_DIR}/_deps/limonp-src/include"
    )
endif()

# ---------------------------------------------------------------------------
# bitcask_text — 文本分词器（Analyzer 抽象基类 + NgramAnalyzer + 工厂）。
# V2.1：NFKC 归一 + CJK bi/tri-gram + 拉丁空白切分。
# ---------------------------------------------------------------------------
add_library(bitcask_text STATIC
    src/text/analyzer.cpp
    src/text/jieba_analyzer.cpp
)
target_include_directories(bitcask_text PUBLIC include)
# utf8proc FetchContent 导出的 target 名与上游 CMakeLists 一致。
if(TARGET utf8proc::utf8proc)
    set(UTF8PROC_TARGET utf8proc::utf8proc)
else()
    set(UTF8PROC_TARGET utf8proc)
endif()
target_link_libraries(bitcask_text
    PUBLIC  ${UTF8PROC_TARGET}
    PRIVATE bitcask_warnings cppjieba
)

# NOTE(V1): legacy targets bitcask_keydir / bitcask_merge / bitcask_cask 已从构建
# 移除——它们绑定旧的 record 格式与 KeyDir，不在向量库 V1 范围内
# （merge=V4，NIF 消费方将重做）。对应 src 仍在磁盘上，待 M6 正式清理。
# bitcask_cpp NIF 已重新启用，绑定 Collection API（V2.9）。

# ---------------------------------------------------------------------------
# bitcask_cpp — NIF shared library (priv/bitcask_cpp.so)
# ---------------------------------------------------------------------------
if(Erlang_INCLUDE_DIR)
    add_library(bitcask_cpp SHARED
        nif/nif_main.cpp
        nif/nif_cask.cpp
        nif/nif_cask_iter.cpp
        nif/nif_cask_admin.cpp
        nif/nif_helpers.cpp
        nif/atoms.cpp
        nif/resources.cpp
    )
    target_include_directories(bitcask_cpp PRIVATE nif ${Erlang_INCLUDE_DIR})
    target_link_libraries(bitcask_cpp
        PRIVATE bitcask_cask bitcask_keydir bitcask_fileops bitcask_index
                bitcask_io bitcask_text bitcask_bm25 bitcask_format
                bitcask_warnings
    )
    set_target_properties(bitcask_cpp PROPERTIES
        PREFIX ""
        SUFFIX "${CMAKE_SHARED_MODULE_SUFFIX}"
        OUTPUT_NAME "bitcask_cpp"
    )
    if(DEFINED BITCASK_PRIV_DIR)
        set_target_properties(bitcask_cpp PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}"
        )
    endif()
endif()

# ---------------------------------------------------------------------------
# Tests (GoogleTest via FetchContent)
# ---------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()

# ---------------------------------------------------------------------------
# Benchmarks (Google Benchmark via FetchContent). Off by default — opt in
# with -DBITCASK_BUILD_BENCHMARKS=ON to keep CI fast.
# ---------------------------------------------------------------------------
option(BITCASK_BUILD_BENCHMARKS "Build C++ micro-benchmarks" OFF)
if(BITCASK_BUILD_BENCHMARKS)
    add_subdirectory(bench)
endif()
