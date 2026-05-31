#include "bitcask/highlighter.hpp"

#include <algorithm>
#include <cstdlib>
#include <utility>
#include <vector>

namespace bitcask::search {

namespace {

struct OffsetRange {
    std::uint32_t start;
    std::uint32_t end;
};

std::vector<OffsetRange> collect_query_ranges(
    const std::unordered_map<std::string, std::vector<text::TokenInfo>>& query_token_offsets) {
    std::vector<OffsetRange> ranges;
    for (auto& [_, infos] : query_token_offsets) {
        for (auto& info : infos) {
            if (info.end_byte > info.start_byte) {
                ranges.push_back({info.start_byte, info.end_byte});
            }
        }
    }
    std::sort(ranges.begin(), ranges.end(),
              [](const auto& a, const auto& b) { return a.start < b.start; });
    return ranges;
}

std::vector<OffsetRange> select_best_fragments(
    const std::vector<OffsetRange>& sorted_ranges,
    std::size_t fragment_size,
    std::size_t max_fragments) {
    if (sorted_ranges.empty()) return {};

    std::vector<OffsetRange> selected;
    std::size_t remaining = max_fragments;

    while (remaining > 0 && !sorted_ranges.empty()) {
        std::size_t best_start = sorted_ranges[0].start;
        std::size_t best_end = sorted_ranges[0].end;
        std::size_t best_count = 0;

        for (std::size_t i = 0; i < sorted_ranges.size(); ++i) {
            std::size_t window_start = sorted_ranges[i].start;
            std::size_t window_end = window_start + fragment_size;

            std::size_t count = 0;
            for (auto& r : sorted_ranges) {
                if (r.start >= window_start && r.start < window_end) {
                    ++count;
                }
            }

            if (count > best_count) {
                best_count = count;
                best_start = window_start;
                best_end = std::min<std::size_t>(window_end, sorted_ranges.back().end);
            }
        }

        if (best_count == 0) {
            best_start = sorted_ranges[0].start;
            best_end = std::min<std::size_t>(best_start + fragment_size, sorted_ranges.back().end);
        }

        selected.push_back({static_cast<std::uint32_t>(best_start),
                           static_cast<std::uint32_t>(best_end)});
        --remaining;
    }

    return selected;
}

}  // anonymous namespace

HighlightResult highlight(
    std::string_view text,
    const std::unordered_map<std::string, std::vector<text::TokenInfo>>& query_token_offsets,
    const HighlightOptions& opts) {
    HighlightResult result;

    auto ranges = collect_query_ranges(query_token_offsets);
    if (ranges.empty()) return result;

    auto fragments = select_best_fragments(ranges, opts.fragment_size, opts.max_fragments);
    if (fragments.empty()) return result;

    for (auto& frag : fragments) {
        std::uint32_t frag_start = frag.start;
        std::uint32_t frag_end = frag.end;

        if (frag_end > text.size()) {
            frag_end = static_cast<std::uint32_t>(text.size());
        }
        if (frag_start >= frag_end) {
            continue;
        }

        std::string highlighted;
        highlighted.reserve(frag_end - frag_start + 64);

        std::size_t pos = frag_start;
        for (auto& [term, infos] : query_token_offsets) {
            (void)term;
            for (auto& info : infos) {
                if (info.start_byte < frag_start || info.end_byte > frag_end) {
                    continue;
                }
                if (info.start_byte >= pos) {
                    highlighted.append(text.data() + pos, info.start_byte - pos);
                    highlighted.append(opts.pre_tag);
                    highlighted.append(text.data() + info.start_byte,
                                      info.end_byte - info.start_byte);
                    highlighted.append(opts.post_tag);
                    pos = info.end_byte;
                }
            }
        }

        if (pos < frag_end) {
            highlighted.append(text.data() + pos, frag_end - pos);
        }

        std::size_t match_count = 0;
        for (auto& [term, infos] : query_token_offsets) {
            (void)term;
            for (auto& info : infos) {
                if (info.start_byte >= frag_start && info.end_byte <= frag_end) {
                    ++match_count;
                }
            }
        }

        result.snippets.push_back({std::move(highlighted), static_cast<double>(match_count)});
    }

    return result;
}

}  // namespace bitcask::search