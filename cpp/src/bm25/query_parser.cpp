#include "bitcask/query.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
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

// 合法字段名字符：字母/数字/下划线（R5：避免 http://、12:30 被误判为字段限定）。
static constexpr bool is_field_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

// 从 token 解析可选的 `field:` 前缀和 `^boost` 后缀（S8.6）。
// 仅当冒号左侧非空且全为合法字段名字符时才识别为字段限定。
// 返回 {field, term, boost}；field 空表示无字段限定。
struct ParsedToken { std::string field; std::string term; float boost; };

static ParsedToken parse_field_boost(std::string_view tok) {
    ParsedToken out;
    out.boost = 1.0F;

    // 尾部 ^boost
    if (auto caret = tok.rfind('^');
        caret != std::string_view::npos && caret + 1 < tok.size()) {
        auto bstr = tok.substr(caret + 1);
        bool numeric = !bstr.empty();
        bool seen_dot = false;
        for (char c : bstr) {
            if (c == '.' && !seen_dot) { seen_dot = true; continue; }
            if (c < '0' || c > '9') { numeric = false; break; }
        }
        if (numeric) {
            out.boost = std::strtof(std::string(bstr).c_str(), nullptr);
            if (out.boost <= 0.0F) out.boost = 1.0F;
            tok = tok.substr(0, caret);
        }
    }

    // 前缀 field:（R5：冒号左非空且全为合法字段名字符；冒号右不以 '/' 开头，
    // 排除 http:// 这类 URL）。
    if (auto colon = tok.find(':');
        colon != std::string_view::npos && colon > 0 && colon + 1 < tok.size() &&
        tok[colon + 1] != '/') {
        auto cand = tok.substr(0, colon);
        bool valid = true;
        for (char c : cand) {
            if (!is_field_char(c)) { valid = false; break; }
        }
        if (valid) {
            out.field = std::string(cand);
            tok = tok.substr(colon + 1);
        }
    }

    out.term = std::string(tok);
    return out;
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

        QueryOp op = QueryOp::SHOULD;
        std::string_view body = token;
        if (is_plus_prefix(token)) { op = QueryOp::MUST; body = token.substr(1); }
        else if (is_minus_prefix(token)) { op = QueryOp::MUST_NOT; body = token.substr(1); }

        auto pt = parse_field_boost(body);
        QueryNode leaf;
        leaf.op = op;
        leaf.term = std::move(pt.term);
        leaf.field = std::move(pt.field);
        leaf.boost = pt.boost;
        leaves.push_back(std::move(leaf));
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