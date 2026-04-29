// Unit tests for bitcask::lock::FileLock.

#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <filesystem>
#include <string>

#include <gtest/gtest.h>

#include "bitcask/file_lock.hpp"

using bitcask::lock::FileLock;

namespace fs = std::filesystem;

namespace {

class TempDir {
public:
    TempDir() {
        path_ = fs::temp_directory_path() /
                ("bitcask_lock_" + std::to_string(::getpid()) + "_" +
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

TEST(FileLock, AcquireWriteLockCreatesFile) {
    TempDir td;
    const auto path = td.file("write.lock");
    EXPECT_FALSE(fs::exists(path));
    auto fl = FileLock::acquire(path, true);
    ASSERT_TRUE(fl);
    EXPECT_TRUE(fs::exists(path));
    EXPECT_TRUE(fl->is_write_lock());
}

TEST(FileLock, WriteLockExclusiveSecondFails) {
    TempDir td;
    const auto path = td.file("excl.lock");
    auto fl1 = FileLock::acquire(path, true);
    ASSERT_TRUE(fl1);
    auto fl2 = FileLock::acquire(path, true);
    ASSERT_FALSE(fl2);
    EXPECT_EQ(fl2.error().errnum, EEXIST);
}

TEST(FileLock, WriteLockReleaseUnlinksFile) {
    TempDir td;
    const auto path = td.file("rel.lock");
    {
        auto fl = FileLock::acquire(path, true);
        ASSERT_TRUE(fl);
        ASSERT_TRUE(fs::exists(path));
    }  // dtor releases
    EXPECT_FALSE(fs::exists(path));
}

TEST(FileLock, ReadLockOpensExistingFile) {
    TempDir td;
    const auto path = td.file("rd.lock");
    {
        auto wfl = FileLock::acquire(path, true);
        ASSERT_TRUE(wfl);
        ASSERT_TRUE(wfl->write_data(as_bytes("payload")));
        // wfl moves out of scope, but with file unlinked we lose readability.
        // Open the read lock BEFORE wfl is released so the file still exists.
        auto rfl = FileLock::acquire(path, false);
        ASSERT_TRUE(rfl);
        EXPECT_FALSE(rfl->is_write_lock());
        auto data = rfl->read_data();
        ASSERT_TRUE(data);
        EXPECT_EQ(0, std::memcmp(data->data(), "payload", 7));
    }
}

TEST(FileLock, ReadLockMissingFileFails) {
    TempDir td;
    auto fl = FileLock::acquire(td.file("ghost.lock"), false);
    ASSERT_FALSE(fl);
    EXPECT_EQ(fl.error().errnum, ENOENT);
}

TEST(FileLock, WriteDataTruncatesPriorContents) {
    TempDir td;
    auto wfl = FileLock::acquire(td.file("trunc.lock"), true);
    ASSERT_TRUE(wfl);
    ASSERT_TRUE(wfl->write_data(as_bytes("AAAAAAAAAA")));
    ASSERT_TRUE(wfl->write_data(as_bytes("BB")));  // shorter overwrite
    auto data = wfl->read_data();
    ASSERT_TRUE(data);
    EXPECT_EQ(data->size(), 2u);
    EXPECT_EQ(0, std::memcmp(data->data(), "BB", 2));
}

TEST(FileLock, ReadLockCannotWrite) {
    TempDir td;
    const auto path = td.file("ro.lock");
    auto wfl = FileLock::acquire(path, true);
    ASSERT_TRUE(wfl);
    ASSERT_TRUE(wfl->write_data(as_bytes("x")));

    auto rfl = FileLock::acquire(path, false);
    ASSERT_TRUE(rfl);
    auto wr = rfl->write_data(as_bytes("y"));
    ASSERT_FALSE(wr);
    EXPECT_EQ(wr.error().kind, FileLock::WriteErrorKind::kNotWritable);
}

TEST(FileLock, ExplicitReleaseIsIdempotent) {
    TempDir td;
    auto fl = FileLock::acquire(td.file("idem.lock"), true);
    ASSERT_TRUE(fl);
    fl->release_quiet();
    fl->release_quiet();  // must not crash
    EXPECT_FALSE(fl->is_open());
}

TEST(FileLock, ReadDataOnEmptyFileReturnsEmpty) {
    TempDir td;
    auto fl = FileLock::acquire(td.file("empty.lock"), true);
    ASSERT_TRUE(fl);
    auto data = fl->read_data();
    ASSERT_TRUE(data);
    EXPECT_TRUE(data->empty());
}
