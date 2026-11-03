// Модель UI от сервиса (service/README.md, протокол версии 1) и команды оверлея.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gfg {

inline constexpr int kProtocol = 1;

struct Name {
    std::string ru;
    std::string en;
};

struct Item {
    std::string id;
    std::string kind;  // quest, boss, puzzle, secret, chest, file, tip…
    Name title;
    std::optional<Name> location;
    int levels = 0;    // сколько всего уровней подсказки
    int revealed = 0;  // сколько раскрыто
    std::vector<std::string> hints;  // только раскрытые
    bool missable = false;
    std::string missable_note;
    std::vector<std::string> sources;
};

struct UiModel {
    std::string game;  // пусто — сервис ещё ничего не знает
    Name title;
    std::string source;  // mod / save
    std::string updated_at;
    std::vector<Item> items;
};

enum class MessageType { Hello, Ui, Error, Unknown };

struct Message {
    MessageType type = MessageType::Unknown;
    int protocol = 0;
    UiModel ui;
    std::string error;
};

// Разобрать строку от сервиса. Битая строка — MessageType::Unknown с текстом ошибки в error.
Message parse_message(std::string_view line);

// Команды оверлея — готовые строки JSON без перевода строки.
std::string cmd_reveal(const std::string& item);
std::string cmd_hide(const std::string& item);
std::string cmd_game(const std::string& exe);
std::string cmd_refresh();

}  // namespace gfg
