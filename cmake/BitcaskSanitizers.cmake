# BitcaskSanitizers.cmake
# Per-target sanitizer toggle. Usage:
#
#   cmake -S . -B build -DBITCASK_SANITIZE=address
#   cmake -S . -B build -DBITCASK_SANITIZE=undefined
#   cmake -S . -B build -DBITCASK_SANITIZE=address,undefined
#   cmake -S . -B build -DBITCASK_SANITIZE=thread
#
# Targets that link against bitcask_sanitizers (INTERFACE) inherit the flags.
# Tests must link this transitively; the NIF .so should *not* (sanitizers
# trip the BEAM if loaded).

set(BITCASK_SANITIZE "" CACHE STRING
    "Comma-separated sanitizer list: address,undefined,thread,leak (or empty)")

add_library(bitcask_sanitizers INTERFACE)

if(NOT "${BITCASK_SANITIZE}" STREQUAL "")
    string(REPLACE "," ";" _san_list "${BITCASK_SANITIZE}")

    # ASan and TSan are mutually exclusive.
    list(FIND _san_list "address" _has_asan)
    list(FIND _san_list "thread"  _has_tsan)
    if(NOT _has_asan EQUAL -1 AND NOT _has_tsan EQUAL -1)
        message(FATAL_ERROR
            "BITCASK_SANITIZE: address and thread sanitizers are mutually exclusive")
    endif()

    set(_san_flags "")
    foreach(s IN LISTS _san_list)
        if(s STREQUAL "address")
            list(APPEND _san_flags -fsanitize=address -fno-omit-frame-pointer)
        elseif(s STREQUAL "undefined")
            list(APPEND _san_flags -fsanitize=undefined -fno-sanitize-recover=undefined)
        elseif(s STREQUAL "thread")
            list(APPEND _san_flags -fsanitize=thread)
        elseif(s STREQUAL "leak")
            list(APPEND _san_flags -fsanitize=leak)
        else()
            message(FATAL_ERROR "BITCASK_SANITIZE: unknown sanitizer '${s}'")
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _san_flags)

    target_compile_options(bitcask_sanitizers INTERFACE ${_san_flags})
    target_link_options(bitcask_sanitizers INTERFACE ${_san_flags})

    # C1 注:TSan 抑制不在此注入——动态 libtsan 不回调可执行文件内的
    # __tsan_default_suppressions 覆盖(实测零匹配),改由
    # cpp/tests/CMakeLists.txt 经测试 ENVIRONMENT 属性传
    # TSAN_OPTIONS=suppressions=cmake/tsan.supp。

    message(STATUS "bitcask: sanitizers enabled -> ${BITCASK_SANITIZE}")
endif()
