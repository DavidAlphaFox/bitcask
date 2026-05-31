include(FetchContent)

if(EXISTS "${CMAKE_BINARY_DIR}/_deps/googletest-src/CMakeLists.txt")
    add_subdirectory("${CMAKE_BINARY_DIR}/_deps/googletest-src"
                     "${CMAKE_BINARY_DIR}/_deps/googletest-build")
else()
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.15.2
        GIT_SHALLOW    TRUE
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
endif()

add_executable(bitcask_smoke_test smoke_test.cpp)
target_link_libraries(bitcask_smoke_test PRIVATE
    GTest::gtest_main
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_codec_test codec_test.cpp)
target_link_libraries(bitcask_codec_test PRIVATE
    GTest::gtest_main
    bitcask_format
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_posix_file_test posix_file_test.cpp)
target_link_libraries(bitcask_posix_file_test PRIVATE
    GTest::gtest_main
    bitcask_io
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_file_lock_test file_lock_test.cpp)
target_link_libraries(bitcask_file_lock_test PRIVATE
    GTest::gtest_main
    bitcask_io
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_index_test index_test.cpp)
target_link_libraries(bitcask_index_test PRIVATE
    GTest::gtest_main
    bitcask_index
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_collection_test collection_test.cpp)
target_link_libraries(bitcask_collection_test PRIVATE
    GTest::gtest_main
    bitcask_collection
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_data_file_test data_file_test.cpp)
target_link_libraries(bitcask_data_file_test PRIVATE
    GTest::gtest_main
    bitcask_fileops
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_scanner_test scanner_test.cpp)
target_link_libraries(bitcask_scanner_test PRIVATE
    GTest::gtest_main
    bitcask_fileops
    bitcask_warnings
    bitcask_sanitizers
)

# NOTE(V1): legacy 测试 keydir*/merge*/cask/NIF 已移除（见 cpp/CMakeLists.txt）。

add_executable(bitcask_analyzer_test analyzer_test.cpp)
target_link_libraries(bitcask_analyzer_test PRIVATE
    GTest::gtest_main
    bitcask_text
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_inverted_test inverted_test.cpp)
target_link_libraries(bitcask_inverted_test PRIVATE
    GTest::gtest_main
    bitcask_bm25
    bitcask_text
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_jieba_analyzer_test jieba_analyzer_test.cpp)
target_link_libraries(bitcask_jieba_analyzer_test PRIVATE
    GTest::gtest_main
    bitcask_text
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_keydir_test keydir_test.cpp)
target_link_libraries(bitcask_keydir_test PRIVATE
    GTest::gtest_main
    bitcask_keydir
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_cask_docvalue_test cask_docvalue_test.cpp)
target_link_libraries(bitcask_cask_docvalue_test PRIVATE
    GTest::gtest_main
    bitcask_cask
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_search_layer_test search_layer_test.cpp)
target_link_libraries(bitcask_search_layer_test PRIVATE
    GTest::gtest_main
    bitcask_search
    bitcask_warnings
    bitcask_sanitizers
)

add_executable(bitcask_highlighter_test highlighter_test.cpp)
target_link_libraries(bitcask_highlighter_test PRIVATE
    GTest::gtest_main
    bitcask_search
    bitcask_warnings
    bitcask_sanitizers
)

include(GoogleTest)
gtest_discover_tests(bitcask_smoke_test)
gtest_discover_tests(bitcask_codec_test)
gtest_discover_tests(bitcask_posix_file_test)
gtest_discover_tests(bitcask_file_lock_test)
gtest_discover_tests(bitcask_index_test)
gtest_discover_tests(bitcask_collection_test)
gtest_discover_tests(bitcask_data_file_test)
gtest_discover_tests(bitcask_scanner_test)
gtest_discover_tests(bitcask_analyzer_test)
gtest_discover_tests(bitcask_inverted_test)
gtest_discover_tests(bitcask_jieba_analyzer_test)
gtest_discover_tests(bitcask_keydir_test)
gtest_discover_tests(bitcask_cask_docvalue_test)
gtest_discover_tests(bitcask_search_layer_test)
gtest_discover_tests(bitcask_highlighter_test)

add_executable(bitcask_thread_pool_test thread_pool_test.cpp)
target_link_libraries(bitcask_thread_pool_test PRIVATE
    GTest::gtest_main
    bitcask_search
    bitcask_warnings
    bitcask_sanitizers
    TBB::tbb
)
gtest_discover_tests(bitcask_thread_pool_test)
