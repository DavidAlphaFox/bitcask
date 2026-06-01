#pragma once

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace bitcask::text {

class SynonymMap {
public:
    SynonymMap() = default;

    void load_from_file(const std::string& path) {
        std::ifstream file(path);
        if (!file) return;
        std::string line;
        while (std::getline(file, line)) {
            if (line.empty()) continue;
            std::vector<std::string> terms;
            std::stringstream ss(line);
            std::string term;
            while (std::getline(ss, term, ',')) {
                auto start = term.find_first_not_of(" \t\r\n");
                if (start == std::string::npos) continue;
                auto end = term.find_last_not_of(" \t\r\n");
                terms.push_back(term.substr(start, end - start + 1));
            }
            if (terms.size() >= 2) {
                add_group(std::move(terms));
            }
        }
    }

    void add_group(std::vector<std::string> terms) {
        for (auto& term : terms) {
            auto it = term_to_group_.find(term);
            if (it != term_to_group_.end()) {
                for (auto& t : terms) {
                    if (t != term) {
                        it->second.push_back(std::move(t));
                    }
                }
                std::sort(it->second.begin(), it->second.end());
                it->second.erase(std::unique(it->second.begin(), it->second.end()),
                                 it->second.end());
                auto group = it->second;
                for (auto& t : group) {
                    term_to_group_[t] = group;
                }
                return;
            }
        }
        for (auto& term : terms) {
            term_to_group_[term] = terms;
        }
    }

    [[nodiscard]] std::vector<std::string> expand(const std::string& term) const {
        auto it = term_to_group_.find(term);
        if (it == term_to_group_.end()) {
            return {term};
        }
        return it->second;
    }

    [[nodiscard]] std::vector<std::string> expand_terms(
        const std::vector<std::string>& terms) const {
        std::unordered_set<std::string> seen;
        std::vector<std::string> result;
        result.reserve(terms.size() * 2);
        for (const auto& term : terms) {
            auto syns = expand(term);
            for (auto& syn : syns) {
                if (seen.insert(syn).second) {
                    result.push_back(std::move(syn));
                }
            }
        }
        return result;
    }

private:
    std::unordered_map<std::string, std::vector<std::string>> term_to_group_;
};

}  // namespace bitcask::text
