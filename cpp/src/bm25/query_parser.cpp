#include "bitcask/query.hpp"

#include <algorithm>
#include <cctype>
#include <string>
#include <string_view>
#include <vector>

namespace bitcask::bm25 {

auto QueryNode::must_term(std::string t) -> QueryNode {
    QueryNode node;
    node.op = QueryOp::MUST;
    node.term = std::move(t);
    return node;
}

auto QueryNode::should_term(std::string t) -> QueryNode {
    QueryNode node;
    node.op = QueryOp::SHOULD;
    node.term = std::move(t);
    return node;
}

auto QueryNode::must_not_term(std::string t) -> QueryNode {
    QueryNode node;
    node.op = QueryOp::MUST_NOT;
    node.term = std::move(t);
    return node;
}

auto QueryNode::must_all(std::vector<QueryNode> children) -> QueryNode {
    QueryNode node;
    node.op = QueryOp::MUST;
    node.children = std::move(children);
    return node;
}

auto QueryNode::should_any(std::vector<QueryNode> children) -> QueryNode {
    QueryNode node;
    node.op = QueryOp::SHOULD;
    node.children = std::move(children);
    return node;
}

static constexpr bool is_plus_prefix(std::string_view sv) {
    return sv.size() >= 2 && sv[0] == '+';
}

static constexpr bool is_minus_prefix(std::string_view sv) {
    return sv.size() >= 2 && sv[0] == '-';
}

auto parse_query(std::string_view input) -> QueryNode {
    std::vector<QueryNode> leaves;

    std::vector<std::string_view> tokens;
    std::string_view remaining = input;

    while (!remaining.empty()) {
        while (!remaining.empty() && std::isspace(static_cast<unsigned char>(remaining[0]))) {
            remaining.remove_prefix(1);
        }
        if (remaining.empty()) break;

        auto space_pos = remaining.find_first_of(" \t\n\r");
        auto token = remaining.substr(0, space_pos);
        if (token.data() == nullptr) break;

        if (space_pos == std::string_view::npos) {
            remaining = {};
        } else {
            remaining = remaining.substr(space_pos);
        }

        if (token.empty()) continue;

        if (is_plus_prefix(token)) {
            leaves.push_back(QueryNode::must_term(std::string(token.substr(1))));
        } else if (is_minus_prefix(token)) {
            leaves.push_back(QueryNode::must_not_term(std::string(token.substr(1))));
        } else {
            leaves.push_back(QueryNode::should_term(std::string(token)));
        }
    }

    if (leaves.empty()) {
        return QueryNode::should_term({});
    }

    bool all_should = true;
    for (const auto& leaf : leaves) {
        if (leaf.op != QueryOp::SHOULD) {
            all_should = false;
            break;
        }
    }

    if (all_should && leaves.size() == 1) {
        return leaves[0];
    }

    return QueryNode::should_any(std::move(leaves));
}

void collect_terms(
    const QueryNode& node,
    std::vector<std::string>& must_terms,
    std::vector<std::string>& should_terms,
    std::vector<std::string>& must_not_terms) {

    if (!node.term.empty()) {
        switch (node.op) {
            case QueryOp::MUST:
                must_terms.push_back(node.term);
                break;
            case QueryOp::SHOULD:
                should_terms.push_back(node.term);
                break;
            case QueryOp::MUST_NOT:
                must_not_terms.push_back(node.term);
                break;
        }
        return;
    }

    for (const auto& child : node.children) {
        collect_terms(child, must_terms, should_terms, must_not_terms);
    }
}

}  // namespace bitcask::bm25