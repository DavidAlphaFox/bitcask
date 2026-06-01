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
# Pure C++. Used by C++ unit tests directly.
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
        GIT_REPOSITORY https://github.com/JuliaStrings/utf8proc.git
        GIT_TAG        v2.10.0
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(utf8proc)
endif()

# ---------------------------------------------------------------------------
# cppjieba — jieba 中文分词（header-only，依赖 limonp）。
# 优先复用 _deps 下手动 clone 的源码；缺失时用 FetchContent 拉取
# （与上方 utf8proc 同样的 _deps-then-fetch 模式）。
# ---------------------------------------------------------------------------
if(NOT TARGET cppjieba)
    if(NOT EXISTS "${CMAKE_BINARY_DIR}/_deps/cppjieba-src/include/cppjieba/Jieba.hpp")
        FetchContent_Declare(
            cppjieba
            GIT_REPOSITORY https://github.com/yanyiwu/cppjieba.git
            GIT_TAG        v5.6.7
            GIT_SHALLOW    TRUE
        )
        FetchContent_Declare(
            limonp
            GIT_REPOSITORY https://github.com/yanyiwu/limonp.git
            GIT_TAG        v1.0.2
            GIT_SHALLOW    TRUE
        )
        # header-only：只 populate 取源码，不 add_subdirectory（无需它们的构建）。
        FetchContent_Populate(cppjieba)
        FetchContent_Populate(limonp)
    endif()

    add_library(cppjieba INTERFACE)
    target_include_directories(cppjieba INTERFACE
        "${CMAKE_BINARY_DIR}/_deps/cppjieba-src/include"
        "${CMAKE_BINARY_DIR}/_deps/limonp-src/include"
    )
endif()

# cppjieba 自带的词典目录（jieba.dict.utf8 等），供测试 fixture 定位词典。
# 两条获取分支（FetchContent / _deps 预填充）布局一致，统一指向此处。
set(BITCASK_JIEBA_DICT_DIR "${CMAKE_BINARY_DIR}/_deps/cppjieba-src/dict"
    CACHE INTERNAL "cppjieba 词典目录")

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
        # 把 cppjieba 词典拷到 priv/dict，供运行时 jieba 分词默认加载
        # （bitcask.erl 的 maybe_default_dict_path 会指向此目录）。
        add_custom_command(TARGET bitcask_cpp POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_directory
                    "${BITCASK_JIEBA_DICT_DIR}" "${BITCASK_PRIV_DIR}/dict"
            COMMENT "Copying cppjieba dict to priv/dict"
            VERBATIM)
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
