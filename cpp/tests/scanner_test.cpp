// M3.2 unit tests for the bitcask directory scanner.

#include <unistd.h>

#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/detail/scanner.hpp"

using bitcask::fileops::scan_dir;
using bitcask::fileops::DataFileEntry;
using bitcask::fileops::ScanError;

namespace fs = std::filesystem;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_scan_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string path() const { return path_.string(); }
    void touch(const std::string& name) {
        std::FILE* fp = std::fopen((path_ / name).c_str(), "wb");
        if (fp) std::fclose(fp);
    }
    void mkdir(const std::string& name) {
        fs::create_directory(path_ / name);
    }
private:
    fs::path path_;
};

}  // namespace

TEST(Scanner, EmptyDirectory) {
    TempDir td;
    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    EXPECT_TRUE(r->empty());
}

TEST(Scanner, MissingDirectoryReturnsError) {
    auto r = scan_dir("/tmp/this/path/should/not/exist/" + std::to_string(::getpid()));
    ASSERT_FALSE(r);
    EXPECT_EQ(r.error().kind, ScanError::kCannotOpenDir);
    EXPECT_NE(r.error().errnum, 0);
}

TEST(Scanner, FindsDataFilesAndSortsByTstamp) {
    TempDir td;
    td.touch("3.bitcask.data");
    td.touch("1.bitcask.data");
    td.touch("2.bitcask.data");
    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 3u);
    EXPECT_EQ((*r)[0].tstamp, 1u);
    EXPECT_EQ((*r)[1].tstamp, 2u);
    EXPECT_EQ((*r)[2].tstamp, 3u);
}

TEST(Scanner, ReportsHintFilePresence) {
    TempDir td;
    td.touch("1.bitcask.data");
    td.touch("2.bitcask.data");
    td.touch("2.bitcask.hint");        // matches 2
    td.touch("9.bitcask.hint");        // hint without matching data — ignored

    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 2u);

    EXPECT_EQ((*r)[0].tstamp, 1u);
    EXPECT_FALSE((*r)[0].has_hint);
    EXPECT_TRUE((*r)[0].hint_path.ends_with("1.bitcask.hint"));

    EXPECT_EQ((*r)[1].tstamp, 2u);
    EXPECT_TRUE((*r)[1].has_hint);
    EXPECT_TRUE((*r)[1].hint_path.ends_with("2.bitcask.hint"));
}

TEST(Scanner, IgnoresGarbageFilenames) {
    TempDir td;
    td.touch("README");
    td.touch("bitcask.write.lock");
    td.touch("bitcask.merge.lock");
    td.touch("12345.bitcask.data");
    td.touch("abc.bitcask.data");      // non-numeric tstamp — skipped
    td.touch("123.bitcask.txt");        // wrong suffix — skipped

    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 1u);
    EXPECT_EQ((*r)[0].tstamp, 12345u);
}

TEST(Scanner, IgnoresSubdirectories) {
    TempDir td;
    td.touch("1.bitcask.data");
    td.mkdir("subdir");
    td.mkdir("2.bitcask.data");  // would-be data file, but it's a directory

    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 1u);
    EXPECT_EQ((*r)[0].tstamp, 1u);
}

TEST(Scanner, LargeTstampValuesNotOverflowed) {
    TempDir td;
    td.touch("18446744073709551615.bitcask.data");   // uint64 max
    td.touch("999999999999.bitcask.data");

    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 2u);
    EXPECT_EQ((*r)[0].tstamp, 999999999999u);
    EXPECT_EQ((*r)[1].tstamp, 18446744073709551615ull);
}

TEST(Scanner, FullPathInDataFileEntry) {
    TempDir td;
    td.touch("42.bitcask.data");
    auto r = scan_dir(td.path());
    ASSERT_TRUE(r);
    ASSERT_EQ(r->size(), 1u);
    EXPECT_EQ((*r)[0].data_path, td.path() + "/42.bitcask.data");
    EXPECT_EQ((*r)[0].hint_path, td.path() + "/42.bitcask.hint");
}
