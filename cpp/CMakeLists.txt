# ---------------------------------------------------------------------------
# bitcask_cpp — NIF shared library (priv/bitcask_cpp.so)
#
# 所有 C++ 库 target（bitcask_cask, bitcask_keydir, ...）来自 libbitcask，
# 后者通过根 CMakeLists.txt 的 add_subdirectory(${LIBBITCASK_DIR}) 引入。
# 本文件仅定义 NIF 绑定 target。
# ---------------------------------------------------------------------------

# sanitizer 空壳（独立构建 cpp/ 时提供）
if(NOT TARGET bitcask_sanitizers)
    add_library(bitcask_sanitizers INTERFACE)
endif()

if(Erlang_INCLUDE_DIR)
    add_library(bitcask_cpp SHARED
        nif/nif_main.cpp
        nif/nif_cask.cpp
        nif/nif_cask_iter.cpp
        nif/nif_cask_range.cpp
        nif/nif_cask_batch.cpp
        nif/nif_cask_admin.cpp
        nif/nif_cask_meta.cpp
        nif/nif_helpers.cpp
        nif/nif_options.cpp
        nif/atoms.cpp
        nif/resources.cpp
    )
    target_include_directories(bitcask_cpp PRIVATE nif ${Erlang_INCLUDE_DIR})
    target_link_libraries(bitcask_cpp
        PRIVATE bitcask_cask
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
        # 把 cppjieba 词典拷到 priv/dict，供运行时 jieba 分词默认加载。
        add_custom_command(TARGET bitcask_cpp POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_directory
                    "${BITCASK_JIEBA_DICT_DIR}" "${BITCASK_PRIV_DIR}/dict"
            COMMENT "Copying cppjieba dict to priv/dict"
            VERBATIM)
    endif()
endif()

# 本地嵌入 NIF（priv/bitcask_llama.so）。默认关；开关与 llama.cpp 的构建配置
# 在根 CMakeLists 的 BITCASK_WITH_LLAMA 一节。与上面的 bitcask_cpp 互不依赖。
if(BITCASK_WITH_LLAMA)
    add_subdirectory(llama)
endif()
