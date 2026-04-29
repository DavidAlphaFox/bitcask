// M0 smoke test: confirms C++23 compiler + GoogleTest pipeline works.

#include <expected>
#include <string>

#include <gtest/gtest.h>

namespace {

std::expected<int, std::string> parse_positive(int v) {
    if (v < 0) return std::unexpected("negative");
    return v;
}

}  // namespace

TEST(Smoke, Cxx23ExpectedAvailable) {
    auto ok = parse_positive(42);
    ASSERT_TRUE(ok.has_value());
    EXPECT_EQ(*ok, 42);

    auto err = parse_positive(-1);
    ASSERT_FALSE(err.has_value());
    EXPECT_EQ(err.error(), "negative");
}

TEST(Smoke, BasicArith) {
    EXPECT_EQ(2 + 2, 4);
}
