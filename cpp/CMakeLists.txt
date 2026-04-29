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
# bitcask_io — POSIX file + advisory lock primitives.
# Pure C++. Used by the NIF translation layer and by C++ unit tests directly.
# ---------------------------------------------------------------------------
add_library(bitcask_io STATIC
    src/io/posix_file.cpp
    src/lock/file_lock.cpp
)
target_include_directories(bitcask_io PUBLIC include)
target_link_libraries(bitcask_io PRIVATE bitcask_warnings)

# ---------------------------------------------------------------------------
# bitcask_keydir — in-memory key directory.
# M2.1 scope: single-mutex, single-revision. Multi-revision + pending hash
# come in M2.2.
# ---------------------------------------------------------------------------
add_library(bitcask_keydir STATIC
    src/keydir/keydir.cpp
)
target_include_directories(bitcask_keydir PUBLIC include)
target_link_libraries(bitcask_keydir PRIVATE bitcask_warnings)

# ---------------------------------------------------------------------------
# bitcask_cpp.so — C++ NIF, registered as Erlang module bitcask_cpp_nifs.
# M1 phase: implements the file_*_int / lock_*_int subset of the legacy NIF.
# Coexists with priv/bitcask.so (legacy C). To eventually replace it in M4.
# Sanitizers are NOT linked here — they would crash BEAM on load.
# ---------------------------------------------------------------------------
add_library(bitcask_cpp MODULE
    nif/nif_main.cpp
    nif/nif_io.cpp
    nif/nif_lock.cpp
    nif/atoms.cpp
    nif/resources.cpp
)
target_link_libraries(bitcask_cpp
    PRIVATE
        Erlang::ERTS
        bitcask_io
        bitcask_warnings
)
set_target_properties(bitcask_cpp PROPERTIES
    PREFIX ""
    SUFFIX ".so"
    LIBRARY_OUTPUT_DIRECTORY "${BITCASK_PRIV_DIR}"
)

# ---------------------------------------------------------------------------
# Tests (GoogleTest via FetchContent)
# ---------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
