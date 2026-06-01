#include "bitcask/inverted_wal.hpp"
#include "bitcask/inverted.hpp"

#include <algorithm>
#include <cstring>

namespace bitcask::bm25 {

namespace {

constexpr std::uint8_t kWalEntryAddDoc    = 0x01;
constexpr std::uint8_t kWalEntryRemoveDoc = 0x02;

bool write_u8(std::FILE* f, std::uint8_t v) {
    return std::fwrite(&v, 1, 1, f) == 1;
}

bool write_u32(std::FILE* f, std::uint32_t v) {
    return std::fwrite(&v, 4, 1, f) == 1;
}

bool write_u64(std::FILE* f, std::uint64_t v) {
    return std::fwrite(&v, 8, 1, f) == 1;
}

bool write_bytes(std::FILE* f, const void* data, std::size_t size) {
    return std::fwrite(data, 1, size, f) == size;
}

std::uint8_t read_u8(std::FILE* f) {
    std::uint8_t v = 0;
    if (std::fread(&v, 1, 1, f) != 1) return 0xFF;
    return v;
}

std::uint32_t read_u32(std::FILE* f) {
    std::uint32_t v = 0;
    if (std::fread(&v, 4, 1, f) != 1) return 0xFFFFFFFF;
    return v;
}

std::uint64_t read_u64(std::FILE* f) {
    std::uint64_t v = 0;
    if (std::fread(&v, 8, 1, f) != 1) return 0xFFFFFFFFFFFFFFFF;
    return v;
}

}  // namespace

InvertedWal::InvertedWal(std::string_view path) : path_(path) {
    file_ = std::fopen(path_.c_str(), "ab");
}

InvertedWal::~InvertedWal() {
    if (file_) std::fclose(file_);
}

InvertedWal::InvertedWal(InvertedWal&& other) noexcept
    : path_(std::move(other.path_)), file_(other.file_) {
    other.file_ = nullptr;
}

InvertedWal& InvertedWal::operator=(InvertedWal&& other) noexcept {
    if (this != &other) {
        if (file_) std::fclose(file_);
        path_ = std::move(other.path_);
        file_ = other.file_;
        other.file_ = nullptr;
    }
    return *this;
}

void InvertedWal::append_add_doc(
    std::uint64_t ord,
    WalTermPositions term_data) {
    if (!file_) return;

    if (!write_u8(file_, kWalEntryAddDoc)) return;
    if (!write_u64(file_, ord)) return;

    std::uint32_t term_count = static_cast<std::uint32_t>(term_data.size());
    if (!write_u32(file_, term_count)) return;

    for (auto& [term, data] : term_data) {
        auto [tf, positions] = data;
        std::uint32_t term_len = static_cast<std::uint32_t>(term.size());
        if (!write_u32(file_, term_len)) return;
        if (!write_bytes(file_, term.data(), term_len)) return;
        if (!write_u32(file_, tf)) return;

        std::uint32_t pos_count = static_cast<std::uint32_t>(positions.size());
        if (!write_u32(file_, pos_count)) return;
        for (auto pos : positions) {
            if (!write_u32(file_, pos)) return;
        }
    }

    std::fflush(file_);
}

void InvertedWal::append_remove_doc(
    std::uint32_t doc_len,
    const std::unordered_map<std::string, std::uint32_t>& term_freqs) {
    if (!file_) return;

    if (!write_u8(file_, kWalEntryRemoveDoc)) return;
    if (!write_u32(file_, doc_len)) return;

    std::uint32_t term_count = static_cast<std::uint32_t>(term_freqs.size());
    if (!write_u32(file_, term_count)) return;

    for (auto& [term, tf] : term_freqs) {
        std::uint32_t term_len = static_cast<std::uint32_t>(term.size());
        if (!write_u32(file_, term_len)) return;
        if (!write_bytes(file_, term.data(), term_len)) return;
        if (!write_u32(file_, tf)) return;
    }

    std::fflush(file_);
}

int InvertedWal::replay(InvertedIndex& target) const {
    if (!file_) return 0;

    if (std::fseek(file_, 0, SEEK_SET) != 0) return -1;

    int count = 0;
    std::FILE* input = std::fopen(path_.c_str(), "rb");
    if (!input) return -1;

    auto input_close = [&] { std::fclose(input); };

    while (true) {
        std::uint8_t entry_type = read_u8(input);
        if (std::feof(input) || std::ferror(input)) break;

        if (entry_type == kWalEntryAddDoc) {
            auto ord = read_u64(input);
            if (ord == 0xFFFFFFFFFFFFFFFF) break;

            auto term_count = read_u32(input);
            if (term_count == 0xFFFFFFFF) break;

            WalTermPositions term_data;
            term_data.reserve(term_count);

            for (std::uint32_t i = 0; i < term_count; ++i) {
                auto term_len = read_u32(input);
                if (term_len == 0xFFFFFFFF || term_len > 65536) break;

                std::string term(term_len, '\0');
                if (std::fread(term.data(), 1, term_len, input) != term_len) break;

                auto tf = read_u32(input);
                if (tf == 0xFFFFFFFF) break;

                auto pos_count = read_u32(input);
                if (pos_count == 0xFFFFFFFF) break;

                std::vector<std::uint32_t> positions;
                positions.reserve(pos_count);
                for (std::uint32_t j = 0; j < pos_count; ++j) {
                    auto pos = read_u32(input);
                    if (pos == 0xFFFFFFFF) {
                        positions.clear();
                        break;
                    }
                    positions.push_back(pos);
                }
                if (positions.capacity() == 0 && pos_count > 0) break;

                term_data.emplace(std::move(term), std::make_pair(tf, std::move(positions)));
            }

            target.add_doc(ord, term_data);
            ++count;

        } else if (entry_type == kWalEntryRemoveDoc) {
            auto doc_len = read_u32(input);
            if (doc_len == 0xFFFFFFFF) break;

            auto term_count = read_u32(input);
            if (term_count == 0xFFFFFFFF) break;

            std::unordered_map<std::string, std::uint32_t> term_freqs;
            term_freqs.reserve(term_count);

            for (std::uint32_t i = 0; i < term_count; ++i) {
                auto term_len = read_u32(input);
                if (term_len == 0xFFFFFFFF || term_len > 65536) break;

                std::string term(term_len, '\0');
                if (std::fread(term.data(), 1, term_len, input) != term_len) break;

                auto tf = read_u32(input);
                if (tf == 0xFFFFFFFF) break;

                term_freqs.emplace(std::move(term), tf);
            }

            target.remove_doc(doc_len, term_freqs);
            ++count;

        } else {
            break;
        }
    }

    input_close();
    return count;
}

bool InvertedWal::truncate() {
    if (!file_) return false;
    std::fclose(file_);
    file_ = std::fopen(path_.c_str(), "wb");
    return file_ != nullptr;
}

}  // namespace bitcask::bm25