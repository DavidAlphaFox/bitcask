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
# bitcask_index — in-memory Index side tables (vector DB V1, §3.1).
# Replaces the legacy bitcask_keydir.
# ---------------------------------------------------------------------------
add_library(bitcask_index STATIC
    src/keydir/index.cpp
)
target_include_directories(bitcask_index PUBLIC include)
target_link_libraries(bitcask_index PRIVATE bitcask_warnings)

# ---------------------------------------------------------------------------
# bitcask_collection — vector DB facade (upsert/get/remove + recovery, §5/§8).
# Replaces the legacy bitcask_cask. Reuses fileops + index + io.
# ---------------------------------------------------------------------------
add_library(bitcask_collection STATIC
    src/cask/collection.cpp
)
target_include_directories(bitcask_collection PUBLIC include)
target_link_libraries(bitcask_collection
    PUBLIC  bitcask_fileops bitcask_index bitcask_io
    PRIVATE bitcask_warnings
)

# NOTE(V1): legacy targets bitcask_keydir / bitcask_merge / bitcask_cask 及
# bitcask_cpp NIF 已从构建移除——它们绑定旧的 record 格式与 KeyDir，不在向量库
# V1 范围内（merge=V4，NIF 消费方将重做）。对应 src 仍在磁盘上，待 M6 正式清理。

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
