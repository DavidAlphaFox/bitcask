// Unit tests for bitcask::io::PosixFile.

#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "bitcask/io.hpp"

using bitcask::io::IoError;
using bitcask::io::OpenFlag;
using bitcask::io::PosixFile;
using bitcask::io::ReadEof;
using bitcask::io::ReadOk;

namespace fs = std::filesystem;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_test_" + std::to_string(::getpid()) + "_" +
                 std::to_string(reinterpret_cast<std::uintptr_t>(this)));
        fs::create_directories(path_);
    }
    ~TempDir() { std::error_code ec; fs::remove_all(path_, ec); }
    std::string file(const std::string& name) const {
        return (path_ / name).string();
    }
private:
    fs::path path_;
};

std::span<const std::byte> as_bytes(std::string_view s) {
    return {reinterpret_cast<const std::byte*>(s.data()), s.size()};
}

}  // namespace

TEST(PosixFile, OpenCreateAndWriteAndRead) {
    TempDir td;
    const auto path = td.file("a.dat");

    auto f = PosixFile::open(path, OpenFlag::kCreate);
    ASSERT_TRUE(f) << "open failed";
    ASSERT_TRUE(f->write(as_bytes("hello"))) << "write failed";

    auto g = PosixFile::open(path, OpenFlag::kReadOnly);
    ASSERT_TRUE(g);
    auto r = g->pread(0, 5);
    ASSERT_TRUE(r);
    ASSERT_TRUE(std::holds_alternative<ReadOk>(*r));
    auto& ok = std::get<ReadOk>(*r);
    EXPECT_EQ(ok.data.size(), 5u);
    EXPECT_EQ(0, std::memcmp(ok.data.data(), "hello", 5));
}

TEST(PosixFile, CreateExclusiveFailsIfExists) {
    TempDir td;
    const auto path = td.file("a.dat");
    auto f1 = PosixFile::open(path, OpenFlag::kCreate);
    ASSERT_TRUE(f1);
    auto f2 = PosixFile::open(path, OpenFlag::kCreate);
    ASSERT_FALSE(f2);
    EXPECT_EQ(f2.error().errnum, EEXIST);
}

TEST(PosixFile, OpenReadonlyMissingFile) {
    TempDir td;
    auto f = PosixFile::open(td.file("nope.dat"), OpenFlag::kReadOnly);
    ASSERT_FALSE(f);
    EXPECT_EQ(f.error().errnum, ENOENT);
}

TEST(PosixFile, PreadShortReturnsPartial) {
    TempDir td;
    auto f = PosixFile::open(td.file("p.dat"), OpenFlag::kCreate);
    ASSERT_TRUE(f);
    ASSERT_TRUE(f->pwrite(0, as_bytes("abc")));

    auto r = f->pread(0, 100);
    ASSERT_TRUE(r);
    auto& ok = std::get<ReadOk>(*r);
    EXPECT_EQ(ok.data.size(), 3u);
}

TEST(PosixFile, PreadAtEofReturnsEof) {
    TempDir td;
    auto f = PosixFile::open(td.file("e.dat"), OpenFlag::kCreate);
    ASSERT_TRUE(f);
    auto r = f->pread(0, 16);
    ASSERT_TRUE(r);
    EXPECT_TRUE(std::holds_alternative<ReadEof>(*r));
}

TEST(PosixFile, AppendModeWritesAtEnd) {
    // Default open flags include O_APPEND, so consecutive writes accumulate.
    TempDir td;
    const auto path = td.file("ap.dat");
    {
        auto f = PosixFile::open(path, OpenFlag::kCreate);
        ASSERT_TRUE(f);
        ASSERT_TRUE(f->write(as_bytes("AAA")));
    }
    {
        auto f = PosixFile::open(path, OpenFlag::kNone);
        ASSERT_TRUE(f);
        ASSERT_TRUE(f->write(as_bytes("BBB")));
    }
    auto g = PosixFile::open(path, OpenFlag::kReadOnly);
    ASSERT_TRUE(g);
    auto r = g->pread(0, 6);
    ASSERT_TRUE(r);
    auto& ok = std::get<ReadOk>(*r);
    EXPECT_EQ(0, std::memcmp(ok.data.data(), "AAABBB", 6));
}

TEST(PosixFile, SeekAndPosition) {
    TempDir td;
    auto f = PosixFile::open(td.file("s.dat"), OpenFlag::kCreate);
    ASSERT_TRUE(f);
    ASSERT_TRUE(f->pwrite(0, as_bytes("0123456789")));

    auto p = f->seek(4, SEEK_SET);
    ASSERT_TRUE(p);
    EXPECT_EQ(*p, 4u);
    auto r = f->read(2);
    ASSERT_TRUE(r);
    auto& ok = std::get<ReadOk>(*r);
    EXPECT_EQ(0, std::memcmp(ok.data.data(), "45", 2));

    ASSERT_TRUE(f->seek_bof());
    auto p2 = f->seek(0, SEEK_CUR);
    ASSERT_TRUE(p2);
    EXPECT_EQ(*p2, 0u);
}

TEST(PosixFile, TruncateHereCutsToCurrentOffset) {
    TempDir td;
    const auto path = td.file("t.dat");
    auto f = PosixFile::open(path, OpenFlag::kCreate);
    ASSERT_TRUE(f);
    ASSERT_TRUE(f->pwrite(0, as_bytes("abcdef")));

    ASSERT_TRUE(f->seek(3, SEEK_SET));
    ASSERT_TRUE(f->truncate_here());

    auto sz = fs::file_size(path);
    EXPECT_EQ(sz, 3u);
}

TEST(PosixFile, MoveCloses) {
    TempDir td;
    auto f = PosixFile::open(td.file("m.dat"), OpenFlag::kCreate);
    ASSERT_TRUE(f);
    int fd = f->fd();
    PosixFile g = std::move(*f);
    EXPECT_FALSE(f->is_open());
    EXPECT_EQ(g.fd(), fd);
}

TEST(PosixFile, SyncOnRegularFileIsOk) {
    TempDir td;
    auto f = PosixFile::open(td.file("y.dat"), OpenFlag::kCreate);
    ASSERT_TRUE(f);
    EXPECT_TRUE(f->sync());
}
