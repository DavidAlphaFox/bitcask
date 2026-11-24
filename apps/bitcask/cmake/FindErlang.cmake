# FindErlang.cmake
# Locate Erlang/OTP runtime headers (erl_nif.h) for NIF compilation.
#
# Sets:
#   Erlang_FOUND
#   Erlang_INCLUDE_DIR    - directory containing erl_nif.h
#   Erlang_ERTS_VERSION   - ERTS version string (e.g. "13.2")
#   Erlang_ROOT_DIR       - code:root_dir/0
#
# Honours:
#   ERL_INCLUDE_DIR  (env or cache var) - explicit override

if(DEFINED ENV{ERL_INCLUDE_DIR} AND NOT ERL_INCLUDE_DIR)
    set(ERL_INCLUDE_DIR "$ENV{ERL_INCLUDE_DIR}" CACHE PATH "Erlang include dir override")
endif()

if(ERL_INCLUDE_DIR AND EXISTS "${ERL_INCLUDE_DIR}/erl_nif.h")
    set(Erlang_INCLUDE_DIR "${ERL_INCLUDE_DIR}")
else()
    find_program(ERL_EXECUTABLE erl)
    if(NOT ERL_EXECUTABLE)
        message(FATAL_ERROR "FindErlang: 'erl' not found in PATH. Install Erlang/OTP or set ERL_INCLUDE_DIR.")
    endif()

    execute_process(
        COMMAND ${ERL_EXECUTABLE} -noshell
            -eval "io:format(\"~s\", [code:root_dir()])."
            -s erlang halt
        OUTPUT_VARIABLE Erlang_ROOT_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _erl_rc
    )
    if(NOT _erl_rc EQUAL 0)
        message(FATAL_ERROR "FindErlang: failed to query code:root_dir/0")
    endif()

    execute_process(
        COMMAND ${ERL_EXECUTABLE} -noshell
            -eval "io:format(\"~s\", [erlang:system_info(version)])."
            -s erlang halt
        OUTPUT_VARIABLE Erlang_ERTS_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )

    find_path(Erlang_INCLUDE_DIR
        NAMES erl_nif.h
        HINTS
            "${Erlang_ROOT_DIR}/usr/include"
            "${Erlang_ROOT_DIR}/erts-${Erlang_ERTS_VERSION}/include"
            "${Erlang_ROOT_DIR}/lib/erlang/usr/include"
        NO_DEFAULT_PATH
    )
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Erlang
    REQUIRED_VARS Erlang_INCLUDE_DIR
    VERSION_VAR Erlang_ERTS_VERSION
)

if(Erlang_FOUND AND NOT TARGET Erlang::ERTS)
    add_library(Erlang::ERTS INTERFACE IMPORTED)
    target_include_directories(Erlang::ERTS INTERFACE "${Erlang_INCLUDE_DIR}")
endif()

mark_as_advanced(Erlang_INCLUDE_DIR)
