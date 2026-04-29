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
include(BitcaskSanitizers)

# Output the NIF .so directly into priv/ alongside the existing one.
# During M0–M1 the new artifact is named bitcask_stub.so so it can coexist
# with the legacy priv/bitcask.so produced by the original c_src/ build.
set(BITCASK_PRIV_DIR "${CMAKE_SOURCE_DIR}/priv")
file(MAKE_DIRECTORY "${BITCASK_PRIV_DIR}")

enable_testing()
add_subdirectory(cpp)

message(STATUS "bitcask: C++${CMAKE_CXX_STANDARD}, ERTS ${Erlang_ERTS_VERSION}, headers at ${Erlang_INCLUDE_DIR}")
