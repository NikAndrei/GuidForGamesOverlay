#include "model.hpp"

#include <nlohmann/json.hpp>

namespace gfg {
namespace {

using nlohmann::json;

std::string str(const json& j, const char* key) {
    auto it = j.find(key);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}

Name name(const json& j) {
    if (!j.is_object()) return {};
    return {str(j, "ru"), str(j, "en")};
}

std::vector<std::string> strings(const json& j, const char* key) {
    std::vector<std::string> out;
    auto it = j.find(key);
    if (it == j.end() || !it->is_array()) return out;
    for (const auto& v : *it)
        if (v.is_string()) out.push_back(v.get<std::string>());
    return out;
}

Item item(const json& j) {
    Item it;
    it.id = str(j, "id");
    it.kind = str(j, "kind");
    if (auto t = j.find("title"); t != j.end()) it.title = name(*t);
    if (auto l = j.find("location"); l != j.end() && l->is_object()) it.location = name(*l);
    it.levels = j.value("levels", 0);
    it.revealed = j.value("revealed", 0);
    it.hints = strings(j, "hints");
    it.missable = j.value("missable", false);
    it.missable_note = str(j, "missableNote");
    it.sources = strings(j, "sources");
    return it;
}

UiModel ui(const json& j) {
    UiModel m;
    if (!j.is_object()) return m;
    m.game = str(j, "game");
    if (auto t = j.find("title"); t != j.end()) m.title = name(*t);
    m.source = str(j, "source");
    m.updated_at = str(j, "updatedAt");
    if (auto items = j.find("items"); items != j.end() && items->is_array())
        for (const auto& i : *items)
            if (i.is_object()) m.items.push_back(item(i));
    return m;
}

}  // namespace

Message parse_message(std::string_view line) {
    Message msg;
    json j = json::parse(line, nullptr, false);
    if (j.is_discarded() || !j.is_object()) {
        msg.error = "bad json";
        return msg;
    }
    const std::string type = str(j, "type");
    if (type == "hello") {
        msg.type = MessageType::Hello;
        msg.protocol = j.value("protocol", 0);
    } else if (type == "ui") {
        msg.type = MessageType::Ui;
        if (auto u = j.find("ui"); u != j.end()) msg.ui = ui(*u);
    } else if (type == "error") {
        msg.type = MessageType::Error;
        msg.error = str(j, "message");
    } else {
        msg.error = "unknown type: " + type;
    }
    return msg;
}

std::string cmd_reveal(const std::string& item) { return json{{"cmd", "reveal"}, {"item", item}}.dump(); }
std::string cmd_hide(const std::string& item) { return json{{"cmd", "hide"}, {"item", item}}.dump(); }
std::string cmd_game(const std::string& exe) { return json{{"cmd", "game"}, {"exe", exe}}.dump(); }
std::string cmd_refresh() { return json{{"cmd", "refresh"}}.dump(); }

}  // namespace gfg
