// DocValue meta 段的过滤表达式求值（V5 metadata filter, §2）。
//
// 一个 MetaFilter 是一棵由 MetaCondition 与子 MetaFilter 构成的复合表达式。
// 求值对象是 meta_codec 产出的二进制 blob；evaluate 在 blob 上跑：先单 key
// 查询（meta_lookup 二分），再按操作符比较。无堆分配、无 IO、无锁。
//
// === 线程模型 ===
// MetaFilter 在构造后即只读：构造期间可任意改 fields/children，但 evaluate
// 期间被多线程并发调用是安全的——只需要把 MetaFilter 视作 const。引擎以
// `const MetaFilter*` 把同一棵 filter 树传给多个 search 线程即可。
//
// === 类型系统 ===
// - Eq/Neq：存储值与字面值同 type 才比较；type 不匹配一律 false。
// - Gt/Gte/Lt/Lte：仅 int64 / float64 参与；其它类型一律 false。
// - In：存储值在 values 列表里存在（Eq 语义）；类型不匹配按 Eq 规则逐项 false。
// - Exists：忽略 value 字段，只看 key 是否出现。

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <utility>
#include <variant>
#include <vector>

#include "bitcask/meta_codec.hpp"  // MetaValue + meta_lookup

namespace bitcask::meta {

// MetaCondition 上的比较操作符。enum 直接落盘在 filter 序列化里也用——
// 数值固定，禁止重排/重用。
enum class MetaOp : std::uint8_t {
    Eq      = 0,
    Neq     = 1,
    Gt      = 2,
    Gte     = 3,
    Lt      = 4,
    Lte     = 5,
    In      = 6,
    Exists  = 7,
};

// 单条 leaf 条件：{key, op, value}。In 操作用 values；其余只用 value。
struct MetaCondition {
    std::string key;
    MetaOp      op = MetaOp::Eq;
    MetaValue   value;
    std::vector<MetaValue> values;  // 仅 In 操作用

    // 在 meta blob 上求值。key 不存在 → false（Exists 例外）。
    // 类型不匹配或非法 op → false。
    [[nodiscard]] bool evaluate(std::span<const std::byte> blob) const;
};

// 复合过滤节点：conditions（leaf 集合） + children（子树），由 logic 决定
// 集合求值的 AND/OR。空 filter（无 conditions 无 children）恒返回 true。
struct MetaFilter {
    enum class Logic : std::uint8_t { And = 0, Or = 1 };
    Logic logic = Logic::And;
    std::vector<MetaCondition> conditions;
    std::vector<std::unique_ptr<MetaFilter>> children;

    [[nodiscard]] bool evaluate(std::span<const std::byte> blob) const;
};

namespace detail {

// 类型安全的两值比较：返回 -1/0/1，类型不匹配返回 nullopt。
// 用 std::visit 走 variant——避免 get/holds_alternative 的链式分支。
[[nodiscard]] inline std::optional<int>
compare_values(const MetaValue& a, const MetaValue& b) noexcept {
    return std::visit(
        [&b](const auto& av) -> std::optional<int> {
            using AT = std::decay_t<decltype(av)>;
            // Null vs 任何类型：仅 Null == Null；其余不等。
            if constexpr (std::is_same_v<AT, std::monostate>) {
                return std::holds_alternative<std::monostate>(b)
                           ? std::optional<int>(0)
                           : std::nullopt;
            } else if constexpr (std::is_same_v<AT, bool>) {
                if (!std::holds_alternative<bool>(b)) return std::nullopt;
                const bool bv = std::get<bool>(b);
                if (av == bv) return 0;
                return av ? 1 : -1;  // false < true（与规格「任何合法比较可序列化」一致）
            } else if constexpr (std::is_same_v<AT, std::int64_t>) {
                if (!std::holds_alternative<std::int64_t>(b)) return std::nullopt;
                const auto bv = std::get<std::int64_t>(b);
                if (av == bv) return 0;
                return av < bv ? -1 : 1;
            } else if constexpr (std::is_same_v<AT, double>) {
                if (!std::holds_alternative<double>(b)) return std::nullopt;
                const auto bv = std::get<double>(b);
                if (av == bv) return 0;
                return av < bv ? -1 : 1;
            } else {
                if (!std::holds_alternative<std::string>(b)) return std::nullopt;
                const auto& bs = std::get<std::string>(b);
                const int c = av.compare(bs);
                return c < 0 ? -1 : (c > 0 ? 1 : 0);
            }
        },
        a);
}

// 仅 int64 / float64 参与的有序比较：返回 -1/0/1，类型不在集合里返回 nullopt。
// 对 Gt/Gte/Lt/Lte 用。Bool/string/null 一律返回 nullopt → 求值 false。
[[nodiscard]] inline std::optional<int>
compare_numeric(const MetaValue& a, const MetaValue& b) noexcept {
    return std::visit(
        [&b](const auto& av) -> std::optional<int> {
            using AT = std::decay_t<decltype(av)>;
            if constexpr (std::is_same_v<AT, std::int64_t>) {
                if (!std::holds_alternative<std::int64_t>(b)) return std::nullopt;
                const auto bv = std::get<std::int64_t>(b);
                if (av == bv) return 0;
                return av < bv ? -1 : 1;
            } else if constexpr (std::is_same_v<AT, double>) {
                if (!std::holds_alternative<double>(b)) return std::nullopt;
                const auto bv = std::get<double>(b);
                if (av == bv) return 0;
                return av < bv ? -1 : 1;
            } else {
                return std::nullopt;  // bool/string/null 不参与有序比较
            }
        },
        a);
}

}  // namespace detail

// MetaCondition 求值实现：见头注释的 type system 规则。
// hot path：每个 HNSW 节点过滤都跑一遍，故走 meta_lookup（O(log n) 二分）。
inline bool MetaCondition::evaluate(std::span<const std::byte> blob) const {
    const MetaValue stored = meta_lookup(blob, key);

    switch (op) {
        case MetaOp::Exists:
            // 不论 value 字面值是什么，key 是否存在即可。
            return !std::holds_alternative<std::monostate>(stored);

        case MetaOp::Eq: {
            auto c = detail::compare_values(stored, value);
            return c.has_value() && *c == 0;
        }
        case MetaOp::Neq: {
            auto c = detail::compare_values(stored, value);
            // nullopt（类型不匹配）按「不等」处理——典型场景「key 不存在且
            // value 是 int64 0」也属于「不等」，结果 true。
            return !c.has_value() || *c != 0;
        }
        case MetaOp::Gt: {
            auto c = detail::compare_numeric(stored, value);
            return c.has_value() && *c > 0;
        }
        case MetaOp::Gte: {
            auto c = detail::compare_numeric(stored, value);
            return c.has_value() && *c >= 0;
        }
        case MetaOp::Lt: {
            auto c = detail::compare_numeric(stored, value);
            return c.has_value() && *c < 0;
        }
        case MetaOp::Lte: {
            auto c = detail::compare_numeric(stored, value);
            return c.has_value() && *c <= 0;
        }
        case MetaOp::In: {
            // key 不存在 → 直接 false（与 Eq 一致语义）。
            if (std::holds_alternative<std::monostate>(stored)) return false;
            for (const auto& v : values) {
                auto c = detail::compare_values(stored, v);
                if (c.has_value() && *c == 0) return true;
            }
            return false;
        }
    }
    return false;
}

// MetaFilter 求值：先算所有 leaf condition、再算子树，最后按 logic 合流。
// 空 filter（无 conditions 无 children）恒返回 true——「没有过滤」即「全部通过」。
inline bool MetaFilter::evaluate(std::span<const std::byte> blob) const {
    // AND 空集 → true（all_of over empty = true）；OR 空集 → false。
    // 但若 conditions+children 都为空，直接按规格返回 true。
    if (conditions.empty() && children.empty()) return true;

    const bool want_all = (logic == Logic::And);

    // 先短路求条件。AND 一遇 false 就退出；OR 一遇 true 就退出。
    for (const auto& c : conditions) {
        const bool ok = c.evaluate(blob);
        if (want_all && !ok) return false;
        if (!want_all && ok)  return true;
    }
    for (const auto& child : children) {
        if (!child) continue;
        const bool ok = child->evaluate(blob);
        if (want_all && !ok) return false;
        if (!want_all && ok)  return true;
    }

    // 走到这里说明：
    // - AND 模式下全部都通过 → true
    // - OR 模式下没有任何一项通过 → false
    return want_all;
}

}  // namespace bitcask::meta
