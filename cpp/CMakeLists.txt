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

# C1:TSan 构建改用源码编译的**插桩版** oneTBB——系统 libtbb 未插桩,
# 其内部同步(parallel_* 任务交接、concurrent_hash_map)的 happens-before
# 对 TSan 不可见,曾产生固定 19 例假阳性族且无法用 suppression 精确覆盖
# (残余报告两侧栈均为本项目帧,再宽的 pattern 会掩盖真实 race)。
# 插桩后 HB 边可见:假阳性归零,TBB 任务体内的真实 race 也不再漏报。
# TSan 标志只注入 oneTBB 子项目作用域,NIF .so 不受影响。
if(BITCASK_SANITIZE MATCHES "thread")
    include(FetchContent)
    set(TBB_TEST OFF CACHE BOOL "" FORCE)
    set(TBB_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(TBB_STRICT OFF CACHE BOOL "" FORCE)
    set(_bitcask_saved_cxx_flags "${CMAKE_CXX_FLAGS}")
    set(CMAKE_CXX_FLAGS
        "${CMAKE_CXX_FLAGS} -fsanitize=thread -fno-omit-frame-pointer")
    FetchContent_Declare(oneTBB
        GIT_REPOSITORY https://github.com/uxlfoundation/oneTBB.git
        GIT_TAG v2022.0.0
        GIT_SHALLOW TRUE)
    FetchContent_MakeAvailable(oneTBB)
    set(CMAKE_CXX_FLAGS "${_bitcask_saved_cxx_flags}")
    message(STATUS "bitcask: TSan build -> instrumented oneTBB from source")
else()
    find_package(TBB REQUIRED)
endif()

# ---------------------------------------------------------------------------
# Release 性能选项（评审记录见 TASK.md「P1 — Phase 2-min」节）：
# - -falign-functions=64：search_wand 等热循环对代码布局敏感——A/B 实测
#   无关代码增删可造成 ±10% 的 icache 对齐伪影；固定对齐让基准可复现、
#   性能对无关改动免疫。
# - LTO/IPO：nif → cask → keydir/bm25 调用链大量小函数跨 TU 调用，LTO
#   允许跨库内联。sanitizer 构建不启用（与运行时插桩叠加无意义，且易
#   触发编译器边角问题）；通过 _RELEASE 后缀只作用于 Release 配置，
#   Debug/sanitizer 构建目录不受影响。
# 注意：两者都需在所有 add_library 之前设置（目录属性在 target 创建时固化）。
# ---------------------------------------------------------------------------
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options($<$<CONFIG:Release>:-falign-functions=64>)
endif()

option(BITCASK_LTO "Release 构建启用 LTO/IPO（sanitizer 构建自动关闭）" ON)
if(BITCASK_LTO AND "${BITCASK_SANITIZE}" STREQUAL "")
    include(CheckIPOSupported)
    check_ipo_supported(RESULT _bitcask_ipo_ok OUTPUT _bitcask_ipo_msg)
    if(_bitcask_ipo_ok)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
    else()
        message(STATUS "bitcask: LTO unavailable (${_bitcask_ipo_msg}), proceeding without")
    endif()
endif()

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
    PRIVATE bitcask_warnings bitcask_sanitizers
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
    PRIVATE bitcask_warnings bitcask_sanitizers
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
target_link_libraries(bitcask_io PRIVATE bitcask_warnings bitcask_sanitizers)

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
    PRIVATE bitcask_warnings bitcask_sanitizers
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
    PRIVATE bitcask_warnings bitcask_sanitizers
)

# ---------------------------------------------------------------------------
# bitcask_bm25 — BM25 倒排索引（InvertedIndex + DAAT 评分）。
# ---------------------------------------------------------------------------
add_library(bitcask_bm25 STATIC
    src/bm25/intersect.cpp
    src/bm25/inverted.cpp
    src/bm25/inverted_wal.cpp
    src/bm25/query_parser.cpp
)
target_include_directories(bitcask_bm25 PUBLIC include)
target_link_libraries(bitcask_bm25
    PUBLIC bitcask_format            # WAL framing 的 codec::crc32(O11)
    PRIVATE bitcask_warnings bitcask_sanitizers TBB::tbb)

# ---------------------------------------------------------------------------
# bitcask_vector — HNSW 向量索引(V3,doc/hnsw-design-zh.md)。
# ---------------------------------------------------------------------------
add_library(bitcask_vector STATIC
    src/vector/hnsw.cpp
)
# V3.9:距离内核内部头只对 vector 库 + bench 可见,不放进 public include/。
target_include_directories(bitcask_vector
    PUBLIC  include
    PRIVATE src/vector
)
target_link_libraries(bitcask_vector
    PUBLIC  bitcask_format   # V3.5:BCVS 快照外壳用 codec::crc32
    PRIVATE bitcask_warnings bitcask_sanitizers
)

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
    PUBLIC  bitcask_index bitcask_bm25 bitcask_text bitcask_vector
    PRIVATE bitcask_warnings bitcask_sanitizers
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
    PRIVATE bitcask_warnings bitcask_sanitizers
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
    PRIVATE bitcask_warnings bitcask_sanitizers TBB::tbb
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
    PRIVATE bitcask_warnings bitcask_sanitizers cppjieba
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
        nif/nif_cask_meta.cpp
        nif/nif_helpers.cpp
        nif/nif_options.cpp
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
