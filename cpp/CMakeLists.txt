# Common warning flags for all bitcask C++ targets.
add_library(bitcask_warnings INTERFACE)
target_compile_options(bitcask_warnings INTERFACE
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion
    -Wnon-virtual-dtor -Wold-style-cast
    -Wcast-align -Woverloaded-virtual
    -fvisibility=hidden -fvisibility-inlines-hidden
)

# ---------------------------------------------------------------------------
# bitcask_stub.so — empty NIF for M0 toolchain validation.
# Coexists with the legacy priv/bitcask.so. To be replaced in M1.
# ---------------------------------------------------------------------------
add_library(bitcask_stub MODULE
    nif/nif_stub.cpp
)
target_link_libraries(bitcask_stub PRIVATE Erlang::ERTS bitcask_warnings)
set_target_properties(bitcask_stub PROPERTIES
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
