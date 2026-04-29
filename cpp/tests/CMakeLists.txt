include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.15.2
    GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

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

include(GoogleTest)
gtest_discover_tests(bitcask_smoke_test)
gtest_discover_tests(bitcask_codec_test)
gtest_discover_tests(bitcask_posix_file_test)
gtest_discover_tests(bitcask_file_lock_test)
