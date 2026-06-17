// 字段名 ↔ id 注册表（#1，schema interning）。
//
// 背景：DocValue 的 fields 段此前每条 record 内联存字段名（"title"/"body"...），
// append-only 下同 schema 的百万文档把字段名重复百万次、merge 后再重复一遍。
// 改为存 field id（小整数 varint），字段名只在本注册表存一份。
//
// 持久化：append-only 文件 <dir>/field.schema，每个新字段名追加一条
//   [NameLen:u16 小端][name bytes]   （P：盘格式统一小端，flag-day 前为大端）
// id == 出现顺序（0 基）。open 时顺序重放即还原 name↔id。完全 append-only，
// 契合 bitcask 哲学；并发 put_doc 调 intern，写路径持 unique_lock + fflush。

#pragma once

#include <cstdint>
#include <cstdio>
#include <optional>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bitcask {

class FieldSchema {
public:
    FieldSchema() = default;
    ~FieldSchema() { if (fp_ != nullptr) std::fclose(fp_); }
    FieldSchema(const FieldSchema&) = delete;
    FieldSchema& operator=(const FieldSchema&) = delete;

    // 打开/创建注册表并加载已有映射。append 句柄打不开（如只读目录）也不算失败：
    // 只读路径只需 name_of（映射已加载），不会 intern。返回 false 仅表示无法加载。
    bool open(const std::string& path) {
        std::unique_lock lk(mu_);
        path_ = path;
        name_to_id_.clear();
        id_to_name_.clear();
        if (std::FILE* rf = std::fopen(path.c_str(), "rb")) {
            while (true) {
                std::uint8_t hdr[2];
                if (std::fread(hdr, 1, 2, rf) != 2) break;
                const std::uint16_t nlen =
                    static_cast<std::uint16_t>(hdr[0] |
                        (static_cast<std::uint16_t>(hdr[1]) << 8));
                std::string name(nlen, '\0');
                if (nlen > 0 && std::fread(name.data(), 1, nlen, rf) != nlen) break;
                const auto id = static_cast<std::uint32_t>(id_to_name_.size());
                name_to_id_.emplace(name, id);
                id_to_name_.push_back(std::move(name));
            }
            std::fclose(rf);
        }
        if (fp_ != nullptr) { std::fclose(fp_); fp_ = nullptr; }
        fp_ = std::fopen(path.c_str(), "ab");  // best-effort 追加句柄
        return true;
    }

    // 返回字段名的 id；新名字分配下一个 id 并 append 持久化。线程安全。
    std::uint32_t intern(std::string_view name) {
        {
            std::shared_lock lk(mu_);
            if (auto it = name_to_id_.find(std::string(name)); it != name_to_id_.end()) {
                return it->second;
            }
        }
        std::unique_lock lk(mu_);
        // 双检：并发下可能已被别的线程加入。
        if (auto it = name_to_id_.find(std::string(name)); it != name_to_id_.end()) {
            return it->second;
        }
        const auto id = static_cast<std::uint32_t>(id_to_name_.size());
        if (fp_ != nullptr) {
            const auto nlen = static_cast<std::uint16_t>(name.size());
            const std::uint8_t hdr[2] = {
                static_cast<std::uint8_t>(nlen & 0xFF),
                static_cast<std::uint8_t>((nlen >> 8) & 0xFF)};
            std::fwrite(hdr, 1, 2, fp_);
            if (!name.empty()) std::fwrite(name.data(), 1, name.size(), fp_);
            std::fflush(fp_);
        }
        std::string key(name);
        name_to_id_.emplace(key, id);
        id_to_name_.push_back(std::move(key));
        return id;
    }

    // id → 字段名；越界返回 nullopt。
    [[nodiscard]] std::optional<std::string> name_of(std::uint32_t id) const {
        std::shared_lock lk(mu_);
        if (id >= id_to_name_.size()) return std::nullopt;
        return id_to_name_[id];
    }

    [[nodiscard]] std::size_t size() const {
        std::shared_lock lk(mu_);
        return id_to_name_.size();
    }

private:
    mutable std::shared_mutex mu_;
    std::unordered_map<std::string, std::uint32_t> name_to_id_;
    std::vector<std::string> id_to_name_;  // id == 下标
    std::string path_;
    std::FILE* fp_ = nullptr;  // append-only 写句柄
};

}  // namespace bitcask
